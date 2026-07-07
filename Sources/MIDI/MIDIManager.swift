import Foundation
import CoreMIDI

enum MIDIMessage {
    case noteOn(note: UInt8, velocity: UInt8, channel: UInt8)
    case noteOff(note: UInt8, channel: UInt8)
    case controlChange(controller: UInt8, value: UInt8, channel: UInt8)
    case pitchBend(value: UInt16, channel: UInt8)
    case other
}

/// CoreMIDI I/O, ported from AUSeq (proven with the Launchkey Mini MK4).
/// Connects every source, parses MIDI 1.0 UMP on main, sends raw bytes
/// (incl. SysEx) to name-matched destinations.
final class MIDIManager {
    private(set) var sourceNames: [String] = []
    var onMessage: ((MIDIMessage, String) -> Void)?
    var onSetupChanged: (() -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var nameByToken: [Int: String] = [:]
    private var connectedSources: [MIDIEndpointRef] = []
    /// Destination cache — MIDI clock sends 48x/sec; re-enumerating every
    /// destination per tick is waste. Invalidated on setup change.
    private var destCache: [String: MIDIEndpointRef] = [:]

    func start() {
        if client == 0 {
            MIDIClientCreateWithBlock("MotusXL" as CFString, &client) { [weak self] _ in
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        if inputPort == 0 {
            MIDIInputPortCreateWithProtocol(client, "MotusXL In" as CFString, ._1_0, &inputPort) { [weak self] listPtr, srcConnRefCon in
                let token = srcConnRefCon.map { Int(bitPattern: $0) } ?? 0
                let words = MIDIManager.extractWords(listPtr)
                DispatchQueue.main.async { self?.process(words: words, token: token) }
            }
        }
        if outputPort == 0 {
            MIDIOutputPortCreate(client, "MotusXL Out" as CFString, &outputPort)
        }
        connectAllSources()
    }

    /// Send to the first destination matching ALL needles, falling back to
    /// any destination matching the first.
    @discardableResult
    func send(_ bytes: [UInt8], toPortMatchingAll needles: [String]) -> Bool {
        guard outputPort != 0, !bytes.isEmpty else { return false }
        let cacheKey = needles.joined(separator: "|")
        if let cached = destCache[cacheKey] { return rawSend(bytes, to: cached) }
        // Each needle may hold "|"-separated aliases (e.g. "launchpad|lpminimk3"
        // — Novation ports often enumerate WITHOUT the product name).
        func hit(_ nm: String, _ needle: String) -> Bool {
            needle.lowercased().split(separator: "|").contains { nm.contains($0) }
        }
        var fallback: MIDIEndpointRef?
        for i in 0..<MIDIGetNumberOfDestinations() {
            let dst = MIDIGetDestination(i)
            let nm = displayName(of: dst).lowercased()
            if needles.allSatisfy({ hit(nm, $0) }) {
                destCache[cacheKey] = dst
                return rawSend(bytes, to: dst)
            }
            if let first = needles.first, hit(nm, first), fallback == nil { fallback = dst }
        }
        // Fallback is NOT cached: during USB enumeration the wrong sibling
        // port can appear first and would otherwise stick forever.
        if let fallback { return rawSend(bytes, to: fallback) }
        return false
    }

    private func rawSend(_ bytes: [UInt8], to dst: MIDIEndpointRef) -> Bool {
        var storage = [UInt8](repeating: 0, count: 256 + bytes.count)
        return storage.withUnsafeMutableBytes { raw -> Bool in
            let listPtr = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var pkt = MIDIPacketListInit(listPtr)
            pkt = MIDIPacketListAdd(listPtr, raw.count, pkt, 0, bytes.count, bytes)
            return MIDISend(outputPort, dst, listPtr) == noErr
        }
    }

    /// Reconnect-all on setup change; disconnect first (re-connecting with a
    /// new refCon is additive in CoreMIDI — double notes + stale tokens).
    private func connectAllSources() {
        for src in connectedSources { MIDIPortDisconnectSource(inputPort, src) }
        connectedSources.removeAll()
        var names: [String] = []
        nameByToken.removeAll()
        destCache.removeAll()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != 0 else { continue }
            let token = i + 1
            MIDIPortConnectSource(inputPort, src, UnsafeMutableRawPointer(bitPattern: token))
            connectedSources.append(src)
            let nm = displayName(of: src)
            nameByToken[token] = nm
            names.append(nm)
        }
        sourceNames = names
        onSetupChanged?()
    }

    private static func extractWords(_ listPtr: UnsafePointer<MIDIEventList>) -> [UInt32] {
        var out: [UInt32] = []
        let numPackets = Int(listPtr.pointee.numPackets)
        guard numPackets > 0, let offset = MemoryLayout<MIDIEventList>.offset(of: \.packet) else { return out }
        var p = UnsafeRawPointer(listPtr).advanced(by: offset).assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0..<numPackets {
            let wordCount = Int(p.pointee.wordCount)
            withUnsafeBytes(of: p.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                for i in 0..<min(wordCount, words.count) { out.append(words[i]) }
            }
            p = UnsafePointer(MIDIEventPacketNext(p))
        }
        return out
    }

    /// Walk the UMP stream; multi-word packets (SysEx etc.) must be skipped
    /// as a unit or their data words parse as junk messages.
    private func process(words: [UInt32], token: Int) {
        let source = nameByToken[token] ?? "?"
        var i = 0
        while i < words.count {
            let mt = (words[i] >> 28) & 0xF
            let span: Int
            switch mt {
            case 0x0, 0x1, 0x2: span = 1
            case 0x3, 0x4:      span = 2
            case 0x5, 0xD:      span = 4
            default:            span = 1
            }
            if mt == 0x2 { parse(words[i], source: source) }
            i += span
        }
    }

    private func parse(_ word: UInt32, source: String) {
        let status = UInt8((word >> 16) & 0xFF)
        let d1 = UInt8((word >> 8) & 0x7F)
        let d2 = UInt8(word & 0x7F)
        let channel = status & 0x0F
        let message: MIDIMessage
        switch status & 0xF0 {
        case 0x90: message = d2 == 0 ? .noteOff(note: d1, channel: channel)
                                     : .noteOn(note: d1, velocity: d2, channel: channel)
        case 0x80: message = .noteOff(note: d1, channel: channel)
        case 0xB0: message = .controlChange(controller: d1, value: d2, channel: channel)
        case 0xE0: message = .pitchBend(value: UInt16(d1) | (UInt16(d2) << 7), channel: channel)
        default:   message = .other
        }
        onMessage?(message, source)
    }

    private func displayName(of obj: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &name) == noErr,
           let cf = name?.takeRetainedValue() {
            return cf as String
        }
        return "MIDI Source"
    }
}
