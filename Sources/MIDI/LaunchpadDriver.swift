import Foundation

/// Launchpad Mini MK3 — a 1:1 hardware mirror of the XL's 8x8 pad grid.
/// Programmer mode (SysEx F0 00 20 29 02 0D 0E 01): grid notes are
/// 10*(row+1)+(col+1) with row 0 at the BOTTOM; LEDs take batched RGB specs
/// (type 03) or palette pulse (type 02) synced to MIDI clock. Runs alongside
/// the Launchkey — grid here, keys/knobs/transport there.
@MainActor
final class LaunchpadDriver {
    weak var brain: Brain?
    let midi: MIDIManager
    private(set) var connected = false

    private var lastSpec: [UInt8: [UInt8]] = [:]                // note -> last LED spec sent
    private var lastCC: [UInt8: UInt8] = [:]
    private var clockTimer: DispatchSourceTimer?
    private var clockTempo: Double = 0

    /// Top row CCs: up down left right session drums keys user.
    private let topCC: [UInt8] = [91, 92, 93, 94, 95, 96, 97, 98]

    init(midi: MIDIManager) { self.midi = midi }

    private func send(_ bytes: [UInt8]) {
        midi.send(bytes, toPortMatchingAll: ["launchpad", "midi"])
    }
    private func sysex(_ body: [UInt8]) {
        send([0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D] + body + [0xF7])
    }

    func connectIfPresent() {
        let present = midi.sourceNames.contains { $0.localizedCaseInsensitiveContains("launchpad") }
        if present {
            // Re-send programmer mode on every setup change: during USB
            // enumeration the destination may not exist yet, so a single
            // latched attempt can be lost forever. Latch only on success.
            let sent = midi.send([0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D, 0x0E, 0x01, 0xF7],
                                 toPortMatchingAll: ["launchpad", "midi"])
            if sent {
                if !connected { brain?.surfaceChanged("LAUNCHPAD MINI", connected: true) }
                connected = true
                lastSpec.removeAll(); lastCC.removeAll()
                refresh()
            }
        } else if connected {
            clockTimer?.cancel(); clockTimer = nil; clockTempo = 0
            connected = false
            brain?.surfaceChanged("LAUNCHPAD MINI", connected: false)
        }
    }

    func powerDark() {
        guard connected else { return }
        var specs: [UInt8] = []
        for note in gridNotes() { specs += [0x00, note, 0x00] }   // type 0 = palette off
        sysex([0x03] + specs)
        for cc in topCC + Self.rightCC { send([0xB0, cc, 0]) }
        lastSpec.removeAll(); lastCC.removeAll()
        clockTimer?.cancel(); clockTimer = nil; clockTempo = 0
    }

    // MARK: - Input

    func handle(_ message: MIDIMessage) {
        guard connected, let brain else { return }
        switch message {
        case let .noteOn(note, velocity, _):
            if let idx = padIndex(note) { brain.pad(idx, down: true, velocity: max(1, Int(velocity))) }
        case let .noteOff(note, _):
            if let idx = padIndex(note) { brain.pad(idx, down: false) }
        case let .controlChange(cc, value, _):
            guard value > 0 else { return }
            if let col = Self.rightCC.firstIndex(of: cc) {
                // Right column: session mode = launch scene N; note mode =
                // select track N (rows read top-to-bottom like the app).
                if brain.isSessionMode {
                    brain.externalLaunchScene(col)
                } else {
                    brain.button("track\(col + 1)", down: true)
                    brain.button("track\(col + 1)", down: false)
                }
                return
            }
            switch cc {
            case 91: brain.button("plus", down: true); brain.button("plus", down: false)
            case 92: brain.button("minus", down: true); brain.button("minus", down: false)
            case 93: brain.button("left", down: true); brain.button("left", down: false)
            case 94: brain.button("right", down: true); brain.button("right", down: false)
            case 95: brain.button("note", down: true)      // session/note toggle
            case 96: brain.button("play", down: true)      // "drums" -> play
            case 97: brain.button("record", down: true)    // "keys" -> record
            case 98: brain.button("capture", down: true)   // "user" -> capture
            default: break
            }
        default:
            break
        }
    }

    /// Programmer-mode note -> our pad index (row 0 = top on screen).
    private func padIndex(_ note: UInt8) -> Int? {
        let row = Int(note) / 10 - 1, col = Int(note) % 10 - 1
        guard (0..<8).contains(row), (0..<8).contains(col) else { return nil }
        return (7 - row) * 8 + col
    }

    private func gridNotes() -> [UInt8] {
        var notes: [UInt8] = []
        for i in 0..<64 {
            let row: Int = 8 - i / 8
            let col: Int = i % 8 + 1
            notes.append(UInt8(row * 10 + col))
        }
        return notes
    }

    /// Right column CCs, top row first (scene/track 1..8).
    static let rightCC: [UInt8] = [89, 79, 69, 59, 49, 39, 29, 19]

    // MARK: - Feedback

    func refresh() {
        guard connected, let brain, brain.poweredOn else { return }
        syncClock(brain.song.tempo)
        var specs: [UInt8] = []
        for i in 0..<64 {
            let lpRow: Int = 8 - i / 8
            let note = UInt8(lpRow * 10 + i % 8 + 1)
            let rgb = brain.noteColors[Brain.padNote(i)] ?? .zero
            let pulse = brain.noteChannels[Brain.padNote(i)] == 9
            let spec: [UInt8] = pulse
                ? [0x02, note, Self.palette(rgb)]
                : [0x03, note, UInt8(min(127, rgb.x * 127)),
                   UInt8(min(127, rgb.y * 127)), UInt8(min(127, rgb.z * 127))]
            if lastSpec[note] != spec {
                lastSpec[note] = spec
                specs += spec
            }
            // The LED-spec message caps well above this; send in one batch.
        }
        if !specs.isEmpty { sysex([0x03] + specs) }
        // Button LEDs: right column = track colors (note) / scene states
        // (session); top = transport hints.
        for (row, cc) in Self.rightCC.enumerated() {
            let level: UInt8 = brain.isSessionMode
                ? (row == brain.song.selectedScene ? 3 : 1)
                : Self.palette(Brain.trackColors[row]
                               * (row == brain.song.selectedTrack ? 1.0 : 0.3))
            if lastCC[cc] != level { lastCC[cc] = level; send([0xB0, cc, level]) }
        }
        let tops: [(UInt8, UInt8)] = [
            (95, brain.isSessionMode ? 3 : 1),
            (96, brain.engine.isPlaying ? 21 : 1),
            (97, brain.isRecording ? 5 : 1),
            (98, 1), (91, 1), (92, 1), (93, 1), (94, 1),
        ]
        for (cc, level) in tops where lastCC[cc] != level {
            lastCC[cc] = level
            send([0xB0, cc, level])
        }
    }

    private func syncClock(_ tempo: Double) {
        guard abs(tempo - clockTempo) > 0.5 || clockTimer == nil else { return }
        clockTempo = tempo
        clockTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 60.0 / (max(40, tempo) * 24))
        timer.setEventHandler { [weak self] in self?.send([0xF8]) }
        timer.resume()
        clockTimer = timer
    }

    /// Nearest palette index (pulse specs take palette colors only).
    private static func palette(_ c: SIMD3<Double>) -> UInt8 {
        let (r, g, b) = (c.x, c.y, c.z)
        if r < 0.05 && g < 0.05 && b < 0.05 { return 0 }
        if r > 0.7 && g > 0.7 && b > 0.7 { return 3 }
        if r >= g && r >= b { return g > 0.4 ? 96 : 5 }
        if g >= r && g >= b { return b > 0.5 ? 37 : 21 }
        return r > 0.4 ? 49 : 41
    }
}
