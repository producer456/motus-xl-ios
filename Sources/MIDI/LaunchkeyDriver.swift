import Foundation
import CoreGraphics

/// Launchkey Mini 37 MK4 control surface for Motus XL.
/// Protocol: official MK4 Programmer's Reference v2, cross-verified against
/// Ableton's shipped script, Bitwig's official extension, and the proven
/// AUSeq driver. Everything runs on the DAW port (SysEx header
/// F0 00 20 29 02 13). Pad layers: SESSION (tracks + clip launch),
/// DRUM (ch10 takeover -> 16 cells), STEP (16 step buttons). Encoders are
/// relative with touch events (touch = automation override). The 128x64
/// OLED mirrors the XL's 256x128 screen as a 2:1 bitmap.
@MainActor
final class LaunchkeyDriver {
    enum PadLayer: Int, CaseIterable { case session, drum, step
        var name: String { ["SESSION", "DRUM", "STEP"][rawValue] }
    }

    weak var brain: Brain?
    let midi: MIDIManager
    private(set) var connected = false
    private(set) var layer: PadLayer = .session
    private var shiftHeld = false

    private let topRow:    [UInt8] = [0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67]
    private let bottomRow: [UInt8] = [0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77]
    /// Drum takeover grid (ch10): note - 36 = our cell index 0-15.
    private let drumBase: UInt8 = 36

    private var lastRGB: [UInt8: (UInt8, UInt8, UInt8)] = [:]
    private var lastPulse: [UInt8: UInt8] = [:]
    private var lastButton: [UInt8: UInt8] = [:]
    private var clockTimer: DispatchSourceTimer?
    private var clockTempo: Double = 0
    private var lastBitmap = [UInt8]()
    private var lastBitmapAt = Date.distantPast
    /// Mini MK4 knobs are absolute pots (ch16 CC 0x15-0x1C, proven on the
    /// actual unit) — convert to deltas for Brain's relative encoder API.
    private var lastPot = [Int?](repeating: nil, count: 8)
    /// OLED bitmap orientation (bit0 flipV, bit1 flipH) — tuned from Setup.
    var bitmapOrient = UserDefaults.standard.integer(forKey: "lk.orient") {
        didSet {
            UserDefaults.standard.set(bitmapOrient, forKey: "lk.orient")
            lastBitmap.removeAll()          // force an immediate repaint
            lastBitmapAt = .distantPast
        }
    }

    static func matches(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("launchkey") || n.contains("lkmk4")
    }

    init(midi: MIDIManager) { self.midi = midi }

    private func send(_ bytes: [UInt8]) {
        midi.send(bytes, toPortMatchingAll: ["launchkey|lkmk4", "daw"])
    }
    private func sysex(_ body: [UInt8]) {
        send([0xF0, 0x00, 0x20, 0x29, 0x02, 0x13] + body + [0xF7])
    }

    // MARK: - Lifecycle

    func connectIfPresent() {
        let present = midi.sourceNames.contains { Self.matches($0) }
        if present && !connected { connect() }
        if !present && connected { drop() }
    }

    private func connect() {
        send([0x9F, 0x0C, 0x7F])       // DAW mode on
        send([0xB6, 0x1D, 0x02])       // pad mode: DAW/session
        send([0xB6, 0x45, 0x7F])       // encoders -> relative output
        send([0xB6, 0x47, 0x7F])       // encoder touch events on
        sysex([0x04, 0x22, 0x01])      // silence the firmware's DAW-label popup
        connected = true
        layer = .session
        lastRGB.removeAll(); lastPulse.removeAll(); lastButton.removeAll()
        lastBitmap.removeAll()
        popup("MOTUS XL", "CONNECTED")
        brain?.surfaceChanged("LAUNCHKEY MK4", connected: true)
        refresh()
    }

    private func drop() {
        brain?.surfaceChanged("LAUNCHKEY MK4", connected: false)
        clockTimer?.cancel()
        clockTimer = nil
        clockTempo = 0
        connected = false
    }

    /// XL powered off: darken the whole surface (LEDs, buttons, screen).
    func powerDark() {
        guard connected else { return }
        for note in topRow + bottomRow { send([0x90, note, 0]) }
        for cell in 0..<16 { send([0x99, drumBase + UInt8(cell), 0]) }
        send([0xB3, 0x73, 0]); send([0xB3, 0x75, 0])
        lastRGB.removeAll(); lastPulse.removeAll(); lastButton.removeAll()
        lastBitmap = [UInt8](repeating: 0, count: 1216)
        sysex([0x09, 0x20] + lastBitmap)
        clockTimer?.cancel(); clockTimer = nil; clockTempo = 0
    }

    func disconnect() {
        guard connected else { return }
        for note in topRow + bottomRow { send([0x90, note, 0]) }
        send([0xB6, 0x54, 0x00])
        send([0x9F, 0x0C, 0x00])
        drop()
    }

    // MARK: - Input

    /// AUSeq-proven routing: one handler for both ports — DAW pads/buttons
    /// match by note/CC tables, everything else is the keybed.
    func handle(_ message: MIDIMessage, isDAWPort: Bool) {
        guard connected, let brain else { return }
        // Keybed lives on the MIDI port; only the DAW port carries pads —
        // keeps high keybed notes (96-119) from being eaten as pad hits.
        let padCapable = isDAWPort || !midi.sourceNames.contains {
            Self.matches($0) && $0.localizedCaseInsensitiveContains("daw")
        }
        switch message {
        case let .controlChange(cc, value, ch):
            if ch == 6 {                                 // ch7: shift + mode echoes
                if cc == 0x3F { shiftHeld = value > 0 }
                return
            }
            if ch == 15 {
                if (0x15...0x1C).contains(cc) {          // absolute pots (Mini)
                    let i = Int(cc - 0x15)
                    let v = Int(value)
                    if let last = lastPot[i] {
                        let ticks = (v - last) / 2
                        if ticks != 0 { brain.encoder(i, delta: ticks); lastPot[i] = last + ticks * 2 }
                    } else {
                        lastPot[i] = v
                    }
                    return
                }
                if (0x55...0x5C).contains(cc) {          // relative (full-size MK4)
                    let delta = Int(value) - 64
                    if delta != 0 { brain.encoder(Int(cc - 0x55), delta: delta) }
                    return
                }
            }
            if ch == 14, (0x55...0x5C).contains(cc) {    // encoder touch (full-size)
                brain.encoderTouch(Int(cc - 0x55), down: value > 0)
                return
            }
            if ch == 0 {
                if button(cc, down: value > 0) { return }
                // Keybed mod strip (CC1) + sustain: AU tracks only.
                if cc == 1 || cc == 64 {
                    brain.auPassthrough([0xB0, cc, value])
                }
            }
        case let .noteOn(note, velocity, ch):
            if ch == 9 {                                  // drum takeover pads
                if layer == .drum, note >= drumBase, note < drumBase + 16 {
                    brain.externalDrumCell(Int(note - drumBase), velocity: Int(velocity), on: true)
                }
                return
            }
            guard ch == 0 else { return }
            if padCapable, let idx = padIndex(note) { padPressed(idx, velocity: Int(velocity), down: true); return }
            brain.externalNote(Int(note), velocity: Int(velocity), on: true)
        case let .noteOff(note, ch):
            if ch == 9 {
                if layer == .drum, note >= drumBase, note < drumBase + 16 {
                    brain.externalDrumCell(Int(note - drumBase), velocity: 0, on: false)
                }
                return
            }
            guard ch == 0 else { return }
            if padCapable, let idx = padIndex(note) { padPressed(idx, velocity: 0, down: false); return }
            brain.externalNote(Int(note), velocity: 0, on: false)
        case let .pitchBend(value, ch):
            guard ch == 0 else { return }
            brain.auPassthrough([0xE0, UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)])
        case .other:
            break
        }
    }

    private func padIndex(_ note: UInt8) -> Int? {
        if let i = topRow.firstIndex(of: note) { return i }
        if let i = bottomRow.firstIndex(of: note) { return 8 + i }
        return nil
    }

    /// DAW-mode button CCs (ch1). Returns true when consumed.
    private func button(_ cc: UInt8, down: Bool) -> Bool {
        guard let brain else { return false }
        // Mini MK4's transmit set (captured on the unit): 0x73 play,
        // 0x75 rec, 0x6A/0x6B track -/+, 0x33/0x34 arrows, 0x68 pad-mode.
        switch cc {
        case 0x73:
            brain.button("play", down: down)
        case 0x75:
            brain.button(shiftHeld ? "capture" : "record", down: down)
        case 0x6A, 0x6B:
            guard down else { return true }
            let dir = cc == 0x6A ? -1 : 1
            if shiftHeld {
                brain.externalScene(dir)
            } else if layer == .step {
                // Bar paging; immediate release so held steps don't arm the
                // long-press transpose variant.
                brain.button(dir < 0 ? "left" : "right", down: true)
                brain.button(dir < 0 ? "left" : "right", down: false)
            } else {
                brain.externalTrackSelect(dir)
            }
        case 0x33: if down { brain.externalParamBank(-1) }     // arrow up
        case 0x34: if down { brain.externalParamBank(1) }      // arrow down
        case 0x68:                                             // pad-mode button
            guard down else { return true }
            if shiftHeld { brain.launchCurrentScene() } else { cycleLayer() }
        default: return false
        }
        return true
    }

    private func padPressed(_ idx: Int, velocity: Int, down: Bool) {
        guard let brain else { return }
        switch layer {
        case .session:
            guard down else { return }
            if idx < 8 {
                brain.button("track\(idx + 1)", down: true)
                brain.button("track\(idx + 1)", down: false)
            } else {
                brain.sessionLaunchTrack(idx - 8)
            }
        case .drum:
            // Pads stay on the DAW grid until takeover kicks in; mirror to cells.
            let cell = idx < 8 ? 8 + idx : idx - 8   // top row = cells 8-15
            brain.externalDrumCell(cell, velocity: velocity, on: down)
        case .step:
            brain.step(idx, down: down)
        }
    }

    private func cycleLayer() {
        brain?.releaseModifiers()   // strand no held pads/steps across layers
        layer = PadLayer(rawValue: (layer.rawValue + 1) % PadLayer.allCases.count) ?? .session
        if layer == .drum {
            send([0xB6, 0x1D, 0x01])   // drum pad mode
            send([0xB6, 0x54, 0x01])   // take drum grid onto the DAW port
        } else {
            send([0xB6, 0x54, 0x00])
            send([0xB6, 0x1D, 0x02])
        }
        lastRGB.removeAll(); lastPulse.removeAll()
        popup("PADS", layer.name)
        refresh()
    }

    // MARK: - Feedback

    func refresh() {
        guard connected, let brain, brain.poweredOn else { return }
        syncClock(brain.song.tempo)
        paintPads(brain)
        paintButtons(brain)
        mirrorDisplay(brain.displayImage)
    }

    /// MIDI clock out so pad flash/pulse animations track our tempo.
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

    private func setPad(_ note: UInt8, rgb: SIMD3<Double>, pulse: Bool, drumChannel: Bool = false) {
        if pulse {
            let pal = Self.palette(rgb)
            if lastPulse[note] != pal {
                send([drumChannel ? 0x9B : 0x92, note, pal])   // pulse channel
                lastPulse[note] = pal
                lastRGB[note] = nil
            }
            return
        }
        if lastPulse[note] != nil { lastPulse[note] = nil; lastRGB[note] = nil }
        let scaled = (UInt8(min(127, rgb.x * 127)), UInt8(min(127, rgb.y * 127)),
                      UInt8(min(127, rgb.z * 127)))
        guard lastRGB[note] ?? (255, 255, 255) != scaled else { return }
        lastRGB[note] = scaled
        if drumChannel {
            send([0x99, note, Self.palette(rgb)])   // RGB override unverified on ch10
        } else {
            sysex([0x01, 0x43, note, scaled.0, scaled.1, scaled.2])   // true RGB
        }
    }

    private func paintPads(_ brain: Brain) {
        switch layer {
        case .session:
            let session = brain.engine.sessionState()
            for t in 0..<8 {
                let color = Brain.trackColors[t]
                let selected = t == brain.song.selectedTrack
                setPad(topRow[t], rgb: color * (selected ? 1.0 : 0.25),
                       pulse: session.playing.indices.contains(t) && session.playing[t] != nil
                              && brain.engine.isPlaying)
                let scene = brain.song.selectedScene
                let clip = brain.song.tracks.indices.contains(t)
                    ? brain.song.tracks[t].clips[scene] : Clip()
                let queued = session.queued.indices.contains(t) && session.queued[t] == scene
                let playingThis = session.playing.indices.contains(t) && session.playing[t] == scene
                if queued {
                    setPad(bottomRow[t], rgb: SIMD3(0.2, 0.9, 0.3), pulse: true)
                } else if playingThis && !clip.isEmpty {
                    setPad(bottomRow[t], rgb: color, pulse: brain.engine.isPlaying)
                } else {
                    setPad(bottomRow[t], rgb: clip.isEmpty ? SIMD3(0.02, 0.02, 0.02) : color * 0.35,
                           pulse: false)
                }
            }
        case .drum:
            for cell in 0..<16 {
                let row = 7 - cell / 4, col = cell % 4
                let rgb = brain.noteColors[Brain.padNote(row * 8 + col)] ?? .zero
                setPad(drumBase + UInt8(cell), rgb: rgb, pulse: false, drumChannel: true)
            }
        case .step:
            for i in 0..<16 {
                let rgb = brain.noteColors[Brain.stepNote(i)] ?? .zero
                setPad(i < 8 ? topRow[i] : bottomRow[i - 8], rgb: rgb, pulse: false)
            }
        }
    }

    private func paintButtons(_ brain: Brain) {
        let states: [(UInt8, UInt8)] = [
            (0x73, brain.engine.isPlaying ? 127 : 20),
            (0x75, brain.isRecording ? 127 : 20),
        ]
        for (cc, level) in states where lastButton[cc] != level {
            send([0xB3, cc, level])   // mono brightness channel
            lastButton[cc] = level
        }
    }

    /// Nearest palette index for the pulse channels (they take palette only).
    private static func palette(_ c: SIMD3<Double>) -> UInt8 {
        let (r, g, b) = (c.x, c.y, c.z)
        if r < 0.05 && g < 0.05 && b < 0.05 { return 0 }
        if r > 0.7 && g > 0.7 && b > 0.7 { return 3 }        // white
        if r >= g && r >= b { return g > 0.4 ? 96 : 5 }      // orange / red
        if g >= r && g >= b { return b > 0.5 ? 37 : 21 }     // teal / green
        return r > 0.4 ? 49 : 41                             // purple / blue
    }

    // MARK: - OLED

    private func ascii(_ s: String, max: Int) -> [UInt8] {
        Array(s.unicodeScalars.compactMap { $0.value >= 0x20 && $0.value <= 0x7E ? UInt8($0.value) : nil }.prefix(max))
    }

    /// Transient two-line popup (target 0x21). Field | 0x40 triggers inline.
    private func popup(_ line1: String, _ line2: String) {
        sysex([0x04, 0x21, 0x01])
        sysex([0x06, 0x21, 0x00] + ascii(line1, max: 16))
        sysex([0x06, 0x21, 0x41] + ascii(line2, max: 16))
    }

    /// Mirror the XL's 256x128 OLED to the hardware's 128x64 as a bitmap
    /// (2:1 downsample, threshold, 7px/byte MSB-left, 19 bytes x 64 rows).
    private func mirrorDisplay(_ image: CGImage?) {
        guard let image, Date().timeIntervalSince(lastBitmapAt) > 0.15 else { return }
        var gray = [UInt8](repeating: 0, count: 128 * 64)
        var packed = [UInt8](repeating: 0, count: 1216)
        gray.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 128, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 128,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 64))
            let px = raw.bindMemory(to: UInt8.self)
            // Panel scan direction is set live from Setup (LK SCREEN row):
            // bit0 = vertical flip, bit1 = horizontal flip.
            let flipV = bitmapOrient & 1 != 0
            let flipH = bitmapOrient & 2 != 0
            for row in 0..<64 {
                let src = (flipV ? row : 63 - row) * 128   // CG is bottom-up
                for col in 0..<128 where px[src + col] > 90 {
                    let dcol = flipH ? 127 - col : col
                    // LSB = LEFTMOST pixel of each 7-px group (hardware-
                    // verified: MSB-first mirrored every glyph individually).
                    packed[row * 19 + dcol / 7] |= UInt8(1) << UInt8(dcol % 7)
                }
            }
        }
        guard packed != lastBitmap else { return }
        lastBitmap = packed
        lastBitmapAt = Date()
        sysex([0x09, 0x20] + packed)
    }
}
