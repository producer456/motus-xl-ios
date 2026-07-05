import SwiftUI
import Combine

/// The standalone Move "firmware": owns the song, modes, OLED screen, LED
/// state, and drives the audio engine. Exposes the same surface API the
/// MoveOS network client had, so the panel views bind unchanged.
@MainActor
final class Brain: ObservableObject {
    @Published var displayImage: CGImage?
    @Published var noteColors: [Int: SIMD3<Double>] = [:]
    @Published var noteChannels: [Int: Int] = [:]
    @Published var ccLeds: [Int: Int] = [:]

    let engine = AudioEngine()

    // ---- Song / state ----
    private(set) var song = Song()
    private var currentSlot = 0
    private var undoStack: [Song] = []
    private var redoStack: [Song] = []

    enum Mode { case note, session, setOverview }
    private var mode = Mode.note

    enum Menu: Equatable {
        case none, tempo, groove, metronome, scale, browser, setup, loopLength
        case message(String)
    }
    private var menu = Menu.none
    private var browserIndex = 0
    private var scaleEditingRoot = true

    // Held modifiers
    private var shiftHeld = false
    private var muteHeld = false
    private var deleteHeld = false
    private var copyHeld = false
    private var copiedClip: Clip?

    // Manual 9.5 sequencing state: pad-then-step / step-then-pad note entry.
    private var heldPads: [Int: Int] = [:]     // melodic pad index -> MIDI note
    private var heldSteps: Set<Int> = []       // step-row indices currently held
    private var stepEntryUsed: Set<Int> = []   // steps that inserted notes while held

    private var recording = false
    private var fullVelocity = false
    private var metronomeOn = false
    private var mainVolume: Double = 0.85
    private var barPage = 0

    /// Momentary parameter overlay (encoder turns), auto-expires.
    private var overlay: (title: String, value: Double, label: String)?
    private var overlayUntil = Date.distantPast

    private var uiTimer: AnyCancellable?
    private var lastShownStep = -1

    static let trackColors: [SIMD3<Double>] = [
        SIMD3(0.25, 0.55, 1.0),   // blue
        SIMD3(1.0, 0.42, 0.30),   // coral
        SIMD3(0.30, 0.95, 0.60),  // mint
        SIMD3(0.75, 0.40, 1.0),   // violet
    ]

    /// Step indices that have a Shift function (see shiftStep) — these get an
    /// illuminated legend under the step button on the panel.
    static let legendSteps = [0, 1, 4, 5, 6, 8, 9, 14, 15]

    // MARK: - Lifecycle

    func start() {
        engine.start()
        // Resume the last-used slot so a background auto-save can never
        // overwrite a saved set with a blank one.
        currentSlot = UserDefaults.standard.integer(forKey: "currentSlot")
        if let saved = Self.loadSet(slot: currentSlot) { song = saved }
        for (i, t) in song.tracks.enumerated() where t.kind == .drum {
            loadKit(track: i, index: t.soundIndex)
        }
        engine.update(song: song)
        engine.setMainVolume(Float(mainVolume))
        uiTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
        refresh()
    }

    private func tick() {
        if overlay != nil && Date() > overlayUntil {
            overlay = nil
            refresh()
            return
        }
        guard engine.isPlaying else { return }
        let step = Int(engine.currentStep)
        if step != lastShownStep {
            lastShownStep = step
            refresh()
        }
    }

    private func loadKit(track: Int, index: Int) {
        Task.detached(priority: .userInitiated) { [engine] in
            guard let kit = DrumKits.load(index: index) else { return }
            engine.setKit(kit, track: track)
        }
    }

    // MARK: - Editing plumbing

    private func edit(_ mutate: (inout Song) -> Void) {
        undoStack.append(song)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        mutate(&song)
        engine.update(song: song)
        refresh()
    }

    /// Non-undoable tweak (selection, tempo nudges while browsing, etc).
    private func adjust(_ mutate: (inout Song) -> Void) {
        mutate(&song)
        engine.update(song: song)
        refresh()
    }

    private var track: Track { song.tracks[song.selectedTrack] }
    private var trackColor: SIMD3<Double> { Self.trackColors[song.selectedTrack] }

    private func showOverlay(_ title: String, _ value: Double, _ label: String) {
        overlay = (title, value, label)
        overlayUntil = Date().addingTimeInterval(1.0)
        refresh()
    }

    // MARK: - Surface API: pads

    func pad(_ index: Int, down: Bool, velocity: Int = 100) {
        let vel = fullVelocity ? 127 : velocity
        switch mode {
        case .setOverview: if down { setOverviewPad(index) }
        case .session: if down { sessionPad(index) }
        case .note: notePad(index, down: down, velocity: vel)
        }
    }

    func aftertouch(_ index: Int, value: Int) {} // not modeled in M1

    private func notePad(_ index: Int, down: Bool, velocity: Int) {
        let row = index / 8, col = index % 8
        if track.kind == .drum {
            if col < 4 {
                let cell = (3 - row) * 4 + col
                if down {
                    if deleteHeld {
                        edit { $0.tracks[$0.selectedTrack].clips[$0.selectedScene].notes.removeAll { $0.key == cell } }
                        return
                    }
                    if muteHeld {
                        edit {
                            var cells = $0.tracks[$0.selectedTrack].mutedCells
                            if cells.contains(cell) { cells.remove(cell) } else { cells.insert(cell) }
                            $0.tracks[$0.selectedTrack].mutedCells = cells
                        }
                        return
                    }
                    adjust { $0.tracks[$0.selectedTrack].selectedPad = cell }
                    engine.liveNote(track: song.selectedTrack, kind: .drum, key: cell,
                                    velocity: velocity, on: true)
                    recordHit(key: cell, velocity: velocity)
                }
            } else if down {
                guard !deleteHeld, !muteHeld else { return }
                // 16 Pitches: play the selected cell repitched.
                let p = (3 - row) * 4 + (col - 4)
                let rate = pow(2.0, Float(p - 7) / 12)
                engine.liveNote(track: song.selectedTrack, kind: .drum,
                                key: track.selectedPad, velocity: velocity, on: true, rate: rate)
            }
        } else {
            let scale = Scales.all[song.scaleIndex].steps
            let note = Scales.padToNote(index, root: song.rootNote, scale: scale, octave: track.octave)
            if deleteHeld {
                // Delete all occurrences of this note instead of playing it.
                if down {
                    edit { song in
                        song.tracks[song.selectedTrack].clips[song.selectedScene]
                            .notes.removeAll { $0.key == note }
                    }
                }
                return
            }
            guard !muteHeld else { return }
            engine.liveNote(track: song.selectedTrack, kind: .synth, key: note,
                            velocity: velocity, on: down)
            if down {
                heldPads[index] = note
                // Step-then-pad (manual 9.5): held step(s) receive this pitch.
                if !heldSteps.isEmpty {
                    insertNotes([note], atSteps: heldSteps.map { barPage * 16 + $0 },
                                velocity: velocity)
                    stepEntryUsed.formUnion(heldSteps)
                }
                recordHit(key: note, velocity: velocity)
            } else {
                heldPads.removeValue(forKey: index)
                recordRelease(key: note)
            }
        }
        refreshLeds()
    }

    /// Live-record bookkeeping: pad-down position per key, so pad-up can
    /// write the real note length.
    private var pendingRecordings: [Int: (step: Int, startPos: Double)] = [:]

    private func recordHit(key: Int, velocity: Int) {
        guard recording, engine.isPlaying else { return }
        let clip = track.clips[song.selectedScene]
        // Floor-quantize into the CURRENT step (which already fired) — nearest-
        // rounding wrote hits into the upcoming step, which the sequencer then
        // re-fired ~50ms later: an audible flam on almost every recorded note.
        let pos = engine.currentStep
        let step = Int(pos) % clip.steps
        pendingRecordings[key] = (step, pos)
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            c.notes.removeAll { $0.step == step && $0.key == key }
            c.notes.append(Note(step: step, key: key, velocity: velocity))
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
    }

    /// Pad released while recording: write the held duration into the note.
    private func recordRelease(key: Int) {
        guard let pending = pendingRecordings.removeValue(forKey: key) else { return }
        guard recording, engine.isPlaying else { return }
        let held = engine.currentStep - pending.startPos
        let length = max(0.25, (held * 4).rounded() / 4) // quantize to 1/64
        adjust { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            if let i = c.notes.firstIndex(where: { $0.step == pending.step && $0.key == key }) {
                c.notes[i].lengthSteps = length
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
    }

    private func sessionPad(_ index: Int) {
        let trackIndex = index / 8, scene = index % 8
        if deleteHeld {
            edit { $0.tracks[trackIndex].clips[scene] = Clip() }
            return
        }
        if copyHeld {
            copiedClip = song.tracks[trackIndex].clips[scene]
            showOverlay("COPY", 1, "CLIP COPIED")
            return
        }
        if let clip = copiedClip {
            edit { $0.tracks[trackIndex].clips[scene] = clip }
            copiedClip = nil
            return
        }
        adjust {
            $0.selectedTrack = trackIndex
            $0.selectedScene = scene
        }
    }

    private func setOverviewPad(_ index: Int) {
        if deleteHeld {
            try? FileManager.default.removeItem(at: Self.slotURL(index))
            if index == currentSlot {
                // Otherwise the in-memory song just auto-saves it right back.
                song = Song()
                song.name = "Set \(index + 1)"
                engine.update(song: song)
            }
            refresh()
            return
        }
        saveCurrentSet()
        if let loaded = Self.loadSet(slot: index) {
            song = loaded
        } else {
            song = Song()
            song.name = "Set \(index + 1)"
        }
        currentSlot = index
        UserDefaults.standard.set(index, forKey: "currentSlot")
        undoStack.removeAll(); redoStack.removeAll()
        barPage = 0
        copiedClip = nil
        clearEntryState()
        engine.resetMacros()
        for (i, t) in song.tracks.enumerated() where t.kind == .drum {
            loadKit(track: i, index: t.soundIndex)
        }
        engine.update(song: song)
        engine.setTransport(playing: false, fromStart: true)
        recording = false
        mode = .note
        refresh()
    }

    // MARK: - Surface API: steps

    func step(_ index: Int, down: Bool) {
        if !down {
            stepReleased(index)
            refreshLeds()
            return
        }
        if shiftHeld { shiftStep(index); return }

        switch mode {
        case .session:
            if index < 8 { adjust { $0.selectedScene = index } }
        case .setOverview:
            break
        case .note:
            let clip = track.clips[song.selectedScene]
            let step = barPage * 16 + index
            guard step < clip.steps else { return }
            if track.kind == .drum {
                // Drums: pressing a pad selects the cell, so a plain step
                // toggle IS the manual's pad-then-step flow for drums.
                let key = track.selectedPad
                edit { song in
                    var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
                    if deleteHeld {
                        c.notes.removeAll { $0.step == step && $0.key == key }
                    } else {
                        c.toggle(step: step, key: key, velocity: fullVelocity ? 127 : 100)
                    }
                    song.tracks[song.selectedTrack].clips[song.selectedScene] = c
                }
            } else {
                // Melodic (manual 9.5): held pads insert their pitches at this
                // step; a bare press arms the step for step-then-pad entry, and
                // removal happens on release if nothing was inserted meanwhile.
                heldSteps.insert(index)
                if deleteHeld {
                    edit { song in
                        song.tracks[song.selectedTrack].clips[song.selectedScene]
                            .notes.removeAll { $0.step == step }
                    }
                    stepEntryUsed.insert(index)
                } else if !heldPads.isEmpty {
                    insertNotes(Array(heldPads.values), atSteps: [step],
                                velocity: fullVelocity ? 127 : 100)
                    stepEntryUsed.insert(index)
                }
            }
        }
    }

    /// Melodic brief-tap removal (manual: "to remove a note from a step,
    /// briefly press the respective step button").
    private func stepReleased(_ index: Int) {
        guard heldSteps.remove(index) != nil else { return }
        let used = stepEntryUsed.remove(index) != nil
        guard !used, mode == .note, track.kind == .synth else { return }
        let step = barPage * 16 + index
        guard track.clips[song.selectedScene].notes.contains(where: { $0.step == step }) else { return }
        edit { song in
            song.tracks[song.selectedTrack].clips[song.selectedScene]
                .notes.removeAll { $0.step == step }
        }
    }

    /// Insert pitches at steps in one undo unit; starts the transport when a
    /// first note lands in an empty clip (manual 9.5).
    private func insertNotes(_ keys: [Int], atSteps steps: [Int], velocity: Int) {
        let clip = track.clips[song.selectedScene]
        let wasEmpty = clip.isEmpty
        let valid = steps.filter { $0 < clip.steps }
        guard !valid.isEmpty else { return }
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            for step in valid {
                for key in keys where !c.notes.contains(where: { $0.step == step && $0.key == key }) {
                    c.notes.append(Note(step: step, key: key, velocity: velocity))
                }
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        if wasEmpty && !engine.isPlaying {
            engine.setTransport(playing: true, fromStart: true)
        }
    }

    /// Drop pad/step entry latches (mode, track, or set changed under them).
    private func clearEntryState() {
        heldPads.removeAll()
        heldSteps.removeAll()
        stepEntryUsed.removeAll()
    }

    private func shiftStep(_ index: Int) {
        switch index {
        case 0: mode = .setOverview; menu = .none; refresh()
        case 1: menu = .setup; refresh()
        case 4: menu = .tempo; refresh()
        case 5:
            metronomeOn.toggle()
            engine.setMetronome(metronomeOn)
            menu = .metronome
            refresh()
        case 6: menu = .groove; refresh()
        case 8: menu = .scale; refresh()
        case 9:
            fullVelocity.toggle()
            showOverlay("FULL VELOCITY", fullVelocity ? 1 : 0, fullVelocity ? "ON" : "OFF")
        case 14: // double loop (pre-check so a no-op doesn't pollute undo)
            guard track.clips[song.selectedScene].bars < 8 else { break }
            edit { song in
                var clip = song.tracks[song.selectedTrack].clips[song.selectedScene]
                let old = clip.notes
                clip.notes += old.map { n in
                    var m = n; m.step += clip.bars * 16; return m
                }
                clip.bars *= 2
                song.tracks[song.selectedTrack].clips[song.selectedScene] = clip
            }
        case 15:
            showOverlay("QUANTIZE", 1, "GRID 1/16")
        default:
            break
        }
    }

    // MARK: - Surface API: buttons

    func button(_ id: String, down: Bool) {
        switch id {
        case "shift": shiftHeld = down
        case "mute": muteHeld = down
        case "delete": deleteHeld = down
        case "copy": copyHeld = down
        case "track1", "track2", "track3", "track4":
            if down { trackButton(Int(String(id.last!))! - 1) }
        case "play":
            if down { togglePlay(restart: shiftHeld) }
        case "record":
            if down { toggleRecord() }
        case "undo":
            if down { shiftHeld ? redo() : undo() }
        case "note":
            if down {
                mode = mode == .note ? .session : .note
                menu = .none
                copiedClip = nil
                clearEntryState()
                refresh()
            }
        case "back":
            if down { backButton() }
        case "loop":
            if down { menu = menu == .loopLength ? .none : .loopLength; refresh() }
        case "capture":
            if down { showOverlay("CAPTURE", 0, "COMING IN M2") }
        case "sample":
            if down { showOverlay("SAMPLING", 0, "COMING IN M2") }
        case "left":
            if down { leftRight(-1) }
        case "right":
            if down { leftRight(1) }
        case "minus":
            if down { octave(-1) }
        case "plus":
            if down { octave(1) }
        case "wheelPress":
            if down { wheelPress() }
        default:
            break
        }
        refreshLeds()
    }

    private func trackButton(_ index: Int) {
        if muteHeld {
            edit { $0.tracks[index].muted.toggle() }
        } else {
            if menu == .browser { menu = .none } // stale list would commit a random sound
            clearEntryState()
            adjust { $0.selectedTrack = index }
            barPage = 0
            if mode == .setOverview { mode = .note }
        }
    }

    private func togglePlay(restart: Bool) {
        if engine.isPlaying && !restart {
            engine.setTransport(playing: false)
            recording = false
            pendingRecordings.removeAll()
        } else {
            engine.setTransport(playing: true, fromStart: true)
        }
        refresh()
    }

    private func toggleRecord() {
        if engine.isPlaying {
            recording.toggle()
            if !recording { pendingRecordings.removeAll() }
        } else {
            recording = true
            engine.setTransport(playing: true, fromStart: true)
        }
        refresh()
    }

    private func backButton() {
        copiedClip = nil
        if menu != .none {
            menu = .none
        } else if mode == .setOverview {
            mode = .note
        }
        refresh()
    }

    private func leftRight(_ direction: Int) {
        if shiftHeld {
            // Page through bars of the clip on the step row.
            let pages = max(1, track.clips[song.selectedScene].bars)
            barPage = min(pages - 1, max(0, barPage + direction))
            refresh()
        } else {
            if menu == .browser { menu = .none }
            clearEntryState()
            adjust { $0.selectedTrack = min(3, max(0, $0.selectedTrack + direction)) }
            barPage = 0
        }
    }

    private func octave(_ direction: Int) {
        guard track.kind == .synth else { return }
        adjust { $0.tracks[$0.selectedTrack].octave = min(3, max(-3, $0.tracks[$0.selectedTrack].octave + direction)) }
        showOverlay("OCTAVE", 0.5, track.octave >= 0 ? "+\(track.octave)" : "\(track.octave)")
    }

    private func wheelPress() {
        switch menu {
        case .none:
            browserIndex = track.soundIndex
            menu = .browser
        case .browser:
            let count = track.kind == .drum ? DrumKits.names.count : SynthPreset.all.count
            guard count > 0 else { menu = .none; break }
            let chosen = ((browserIndex % count) + count) % count
            edit { $0.tracks[$0.selectedTrack].soundIndex = chosen }
            if track.kind == .drum { loadKit(track: song.selectedTrack, index: chosen) }
            menu = .none
        case .scale:
            scaleEditingRoot.toggle()
        case .metronome:
            metronomeOn.toggle()
            engine.setMetronome(metronomeOn)
        default:
            menu = .none
        }
        refresh()
    }

    // MARK: - Surface API: wheel / encoders / volume

    func wheel(delta: Int) {
        switch menu {
        case .tempo:
            adjust { $0.tempo = min(240, max(40, $0.tempo + (shiftHeld ? 0.1 : 1) * Double(delta))) }
        case .groove:
            adjust { $0.swing = min(1, max(0, $0.swing + Double(delta) * 0.02)) }
        case .browser:
            browserIndex += delta
            refresh()
        case .scale:
            adjust {
                if scaleEditingRoot {
                    $0.rootNote = (($0.rootNote + delta) % 12 + 12) % 12
                } else {
                    $0.scaleIndex = (($0.scaleIndex + delta) % Scales.all.count + Scales.all.count) % Scales.all.count
                }
            }
        case .loopLength:
            let options = [1, 2, 4, 8]
            let bars = track.clips[song.selectedScene].bars
            let current = options.firstIndex(of: bars) ?? 0
            let newBars = options[min(options.count - 1, max(0, current + delta))]
            guard newBars != bars else { break } // no-op detent: skip undo push
            edit { song in
                var clip = song.tracks[song.selectedTrack].clips[song.selectedScene]
                if newBars < clip.bars { clip.notes.removeAll { $0.step >= newBars * 16 } }
                clip.bars = newBars
                song.tracks[song.selectedTrack].clips[song.selectedScene] = clip
            }
        case .none:
            guard mode != .setOverview else { return }
            // Main screen: wheel nudges tempo (like grabbing it quickly).
            adjust { $0.tempo = min(240, max(40, $0.tempo + Double(delta))) }
        case .setup, .metronome, .message:
            break
        }
    }

    func wheelTouch(down: Bool) {}
    func encoderTouch(_ index: Int, down: Bool) {}

    func encoder(_ index: Int, delta: Int) {
        let d = Float(delta)
        let t = song.selectedTrack
        var m = engine.macro(track: t)
        switch index {
        case 0:
            m.cutoff = min(8, max(0.05, m.cutoff * (1 + d * 0.04)))
            engine.setMacro(track: t, cutoff: m.cutoff)
            showOverlay("CUTOFF", Double(min(1, m.cutoff / 4)), String(format: "%.0f%%", m.cutoff * 100))
        case 1:
            let base = m.res < 0 ? 0.3 : m.res
            m.res = min(0.95, max(0, base + d * 0.02))
            engine.setMacro(track: t, res: m.res)
            showOverlay("RESONANCE", Double(m.res), String(format: "%.0f%%", m.res * 100))
        case 2:
            m.attack = min(8, max(0.1, m.attack * (1 + d * 0.05)))
            engine.setMacro(track: t, attack: m.attack)
            showOverlay("ATTACK", Double(min(1, m.attack / 4)), String(format: "X%.2f", m.attack))
        case 3:
            m.release = min(8, max(0.1, m.release * (1 + d * 0.05)))
            engine.setMacro(track: t, release: m.release)
            showOverlay("RELEASE", Double(min(1, m.release / 4)), String(format: "X%.2f", m.release))
        case 4:
            m.delay = min(1, max(0, m.delay + d * 0.02))
            engine.setMacro(track: t, delay: m.delay)
            showOverlay("DELAY SEND", Double(m.delay), String(format: "%.0f%%", m.delay * 100))
        case 5:
            adjust { $0.tracks[t].volume = min(1, max(0, $0.tracks[t].volume + Double(d) * 0.02)) }
            showOverlay("TRACK VOL", track.volume, String(format: "%.0f%%", track.volume * 100))
        case 6:
            adjust { $0.swing = min(1, max(0, $0.swing + Double(d) * 0.02)) }
            showOverlay("GROOVE", song.swing, String(format: "%.0f%%", song.swing * 100))
        case 7:
            adjust { $0.tempo = min(240, max(40, $0.tempo + Double(d) * (shiftHeld ? 0.1 : 1))) }
            showOverlay("TEMPO", (song.tempo - 40) / 200, String(format: "%.1f BPM", song.tempo))
        default:
            break
        }
    }

    func volume(delta: Int) {
        mainVolume = min(1, max(0, mainVolume + Double(delta) * 0.02))
        engine.setMainVolume(Float(mainVolume))
        showOverlay("MAIN VOLUME", mainVolume, String(format: "%.0f%%", mainVolume * 100))
    }

    // MARK: - Undo / persistence

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(song)
        restore(last)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(song)
        restore(next)
    }

    /// Swap in a snapshot and replay side effects (kits) the engine can't
    /// derive from the song struct alone.
    private func restore(_ snapshot: Song) {
        let oldKits = song.tracks.map { $0.kind == .drum ? $0.soundIndex : -1 }
        song = snapshot
        for (i, t) in song.tracks.enumerated()
        where t.kind == .drum && t.soundIndex != oldKits[i] {
            loadKit(track: i, index: t.soundIndex)
        }
        barPage = 0
        engine.update(song: song)
        refresh()
    }

    static func setsDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func slotURL(_ slot: Int) -> URL {
        setsDir().appendingPathComponent(String(format: "slot_%02d.json", slot))
    }

    static func loadSet(slot: Int) -> Song? {
        guard let data = try? Data(contentsOf: slotURL(slot)) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }

    func saveCurrentSet() {
        if let data = try? JSONEncoder().encode(song) {
            try? data.write(to: Self.slotURL(currentSlot))
        }
    }

    // MARK: - Rendering

    /// Panic-clear held modifier latches (gesture cancellation on app switch
    /// never delivers the release event).
    func releaseModifiers() {
        clearEntryState()
        shiftHeld = false
        muteHeld = false
        deleteHeld = false
        copyHeld = false
    }

    private func refresh() {
        // barPage can go stale via scene changes, loop shrink, set load, undo.
        barPage = min(barPage, max(0, track.clips[song.selectedScene].bars - 1))
        refreshScreen()
        refreshLeds()
    }

    private func refreshScreen() {
        var s = Screen()
        if let overlay {
            s.text(overlay.title, x: 4, y: 6)
            s.bar(4, 24, 120, 12, value: overlay.value)
            s.textCentered(overlay.label, y: 46)
            displayImage = s.render()
            return
        }
        switch menu {
        case .tempo:
            s.text("TEMPO", x: 4, y: 4)
            s.textCentered(String(format: "%.1f", song.tempo), y: 24, size: 3)
            s.textCentered("BPM", y: 52)
        case .groove:
            s.text("GROOVE", x: 4, y: 4)
            s.bar(14, 26, 100, 14, value: song.swing)
            s.textCentered(String(format: "%.0f%%", song.swing * 100), y: 48)
        case .metronome:
            s.text("METRONOME", x: 4, y: 4)
            s.textCentered(metronomeOn ? "ON" : "OFF", y: 24, size: 3)
        case .scale:
            s.text("KEY & SCALE", x: 4, y: 4)
            let root = Scales.noteNames[song.rootNote]
            let name = Scales.all[song.scaleIndex].name
            if scaleEditingRoot { s.fillRect(8, 22, 34, 15) }
            s.text(root, x: 14, y: 26, invert: scaleEditingRoot)
            if !scaleEditingRoot { s.fillRect(46, 22, 78, 15) }
            s.text(name, x: 50, y: 26, invert: !scaleEditingRoot)
            s.textCentered("PRESS WHEEL TO SWAP", y: 52)
        case .browser:
            s.text(track.kind == .drum ? "KITS" : "SOUNDS", x: 4, y: 2)
            let names = track.kind == .drum ? DrumKits.names : SynthPreset.all.map(\.name)
            guard !names.isEmpty else { break }
            let sel = ((browserIndex % names.count) + names.count) % names.count
            for line in -1...2 {
                let i = ((sel + line) % names.count + names.count) % names.count
                let y = 16 + (line + 1) * 12
                if line == 0 { s.fillRect(0, y - 2, 128, 11) }
                s.text(names[i], x: 4, y: y, invert: line == 0)
            }
        case .loopLength:
            s.text("LOOP LENGTH", x: 4, y: 4)
            s.textCentered("\(track.clips[song.selectedScene].bars) BAR\(track.clips[song.selectedScene].bars > 1 ? "S" : "")", y: 24, size: 2)
            s.textCentered("WHEEL: 1/2/4/8", y: 50)
        case .setup:
            s.text("SETUP", x: 4, y: 4)
            s.text("MOTUS 1.0", x: 4, y: 20)
            s.text("STANDALONE MOVE", x: 4, y: 32)
            s.text("\(DrumKits.names.count) KITS LOADED", x: 4, y: 44)
        case .message(let msg):
            s.textCentered(msg, y: 28)
        case .none:
            mainScreen(&s)
        }
        displayImage = s.render()
    }

    private func mainScreen(_ s: inout Screen) {
        switch mode {
        case .setOverview:
            s.text("SET OVERVIEW", x: 4, y: 4)
            s.text(song.name, x: 4, y: 22, size: 2)
            s.text("PAD LOAD / DEL CLEAR", x: 4, y: 54)
        case .session:
            s.text("SESSION", x: 4, y: 4)
            s.text("SCENE \(song.selectedScene + 1)", x: 84, y: 4)
            s.text(track.name, x: 4, y: 22, size: 2)
            s.text("T\(song.selectedTrack + 1)", x: 110, y: 22)
            transportRow(&s)
        case .note:
            // Header: track + mode
            s.text("T\(song.selectedTrack + 1) \(track.name)", x: 4, y: 4)
            if recording { s.fillRect(118, 3, 7, 7) }
            // Sound name big
            let soundName = track.kind == .drum
                ? (DrumKits.names.indices.contains(track.soundIndex) ? DrumKits.names[track.soundIndex] : "KIT")
                : SynthPreset.all[track.soundIndex % SynthPreset.all.count].name
            var display = soundName
            if display.count > 10 { display = String(display.prefix(10)) }
            s.text(display, x: 4, y: 18, size: 2)
            // Info row
            let scaleText = track.kind == .synth
                ? "\(Scales.noteNames[song.rootNote]) \(Scales.all[song.scaleIndex].name)"
                : "PAD \(track.selectedPad + 1)"
            s.text(scaleText, x: 4, y: 38)
            transportRow(&s)
        }
    }

    private func transportRow(_ s: inout Screen) {
        s.hline(0, 48, 128)
        s.text(String(format: "%.0f BPM", song.tempo), x: 4, y: 53)
        let clip = track.clips[song.selectedScene]
        if engine.isPlaying {
            let step = Int(engine.currentStep) % clip.steps
            s.text("\(step / 16 + 1).\(step % 16 / 4 + 1)", x: 76, y: 53)
            // play triangle
            for i in 0..<5 { s.fillRect(112 + i, 52 + i, 1, 9 - 2 * i) }
        } else {
            s.text("\(clip.bars)BAR", x: 76, y: 53)
            s.fillRect(112, 53, 7, 7, on: true)
            s.fillRect(113, 54, 5, 5, on: false)
        }
    }

    // MARK: - LEDs

    private func refreshLeds() {
        var colors: [Int: SIMD3<Double>] = [:]
        var channels: [Int: Int] = [:]

        switch mode {
        case .setOverview:
            let saved = Set((0..<32).filter { FileManager.default.fileExists(atPath: Self.slotURL($0).path) })
            for i in 0..<32 {
                let note = Self.padNote(i)
                if i == currentSlot {
                    colors[note] = SIMD3(1, 1, 1)
                    channels[note] = 9
                } else if saved.contains(i) {
                    colors[note] = Self.trackColors[i % 4] * 0.8
                }
            }
        case .session:
            for t in 0..<4 {
                for scene in 0..<8 {
                    let note = Self.padNote(t * 8 + scene)
                    let clip = song.tracks[t].clips[scene]
                    if !clip.isEmpty {
                        colors[note] = Self.trackColors[t]
                        if scene == song.selectedScene && engine.isPlaying {
                            channels[note] = 9
                        }
                    } else if scene == song.selectedScene && t == song.selectedTrack {
                        colors[note] = SIMD3(0.25, 0.25, 0.25)
                    }
                }
            }
        case .note:
            if track.kind == .drum {
                let clip = track.clips[song.selectedScene]
                let cellsWithNotes = Set(clip.notes.map(\.key))
                for row in 0..<4 {
                    for col in 0..<4 {
                        let cell = (3 - row) * 4 + col
                        let note = Self.padNote(row * 8 + col)
                        if track.mutedCells.contains(cell) {
                            colors[note] = SIMD3(0.15, 0.12, 0.05)
                        } else if cell == track.selectedPad {
                            colors[note] = SIMD3(1, 1, 1)
                        } else if cellsWithNotes.contains(cell) {
                            colors[note] = trackColor
                        } else {
                            colors[note] = trackColor * 0.25
                        }
                    }
                    for col in 4..<8 {
                        let note = Self.padNote(row * 8 + col)
                        let p = (3 - row) * 4 + (col - 4)
                        colors[note] = p == 7 ? trackColor : trackColor * 0.2
                    }
                }
            } else {
                // Manual pad colors: root notes white, scale notes in the
                // track color. Sounding notes (held or sequenced) flash green.
                let scale = Scales.all[song.scaleIndex].steps
                var soundingNotes = Set(heldPads.values)
                if engine.isPlaying {
                    let clip = track.clips[song.selectedScene]
                    let localStep = Int(engine.currentStep) % clip.steps
                    for n in clip.notes where n.step == localStep {
                        soundingNotes.insert(n.key)
                    }
                }
                for i in 0..<32 {
                    let note = Scales.padToNote(i, root: song.rootNote, scale: scale, octave: track.octave)
                    let isRoot = ((note - song.rootNote) % 12 + 12) % 12 == 0
                    if soundingNotes.contains(note) {
                        colors[Self.padNote(i)] = SIMD3(0.35, 1.0, 0.45)
                    } else {
                        colors[Self.padNote(i)] = isRoot ? SIMD3(0.92, 0.92, 0.9) : trackColor * 0.5
                    }
                }
            }
        }

        // Step row LEDs — manual: white = has note(s), dim track color =
        // empty in-bar, dim gray = outside loop, green = play position.
        if mode == .note {
            let clip = track.clips[song.selectedScene]
            let editKey = track.kind == .drum ? track.selectedPad : nil
            let playStep = engine.isPlaying ? Int(engine.currentStep) % clip.steps : -1
            for i in 0..<16 {
                let absStep = barPage * 16 + i
                let note = Self.stepNote(i)
                let hasNote = clip.notes.contains {
                    $0.step == absStep && (editKey == nil || $0.key == editKey)
                }
                if absStep == playStep {
                    colors[note] = SIMD3(0.2, 1.0, 0.3)
                } else if hasNote {
                    colors[note] = SIMD3(0.95, 0.95, 0.92)
                } else if absStep < clip.steps {
                    colors[note] = trackColor * 0.12
                } else {
                    colors[note] = SIMD3(0.05, 0.05, 0.05)
                }
            }
        } else if mode == .session {
            for i in 0..<8 {
                colors[Self.stepNote(i)] = i == song.selectedScene ? SIMD3(1, 1, 1) : SIMD3(0.1, 0.1, 0.1)
            }
        }

        // Track buttons.
        for t in 0..<4 {
            let base = Self.trackColors[t]
            let level: Double = song.tracks[t].muted ? 0.08 : (t == song.selectedTrack ? 1.0 : 0.35)
            colors[Self.trackNotes[t]] = base * level
        }

        // Function button LEDs.
        var ccs: [Int: Int] = [:]
        ccs[Self.buttonCC["play"]!] = engine.isPlaying ? 127 : 24
        ccs[Self.buttonCC["record"]!] = recording ? 127 : 24
        ccs[Self.buttonCC["note"]!] = 60
        ccs[Self.buttonCC["shift"]!] = shiftHeld ? 127 : 24
        ccs[Self.buttonCC["mute"]!] = muteHeld ? 127 : 24
        ccs[Self.buttonCC["delete"]!] = deleteHeld ? 127 : 24
        ccs[Self.buttonCC["copy"]!] = copyHeld ? 127 : 24
        ccs[Self.buttonCC["undo"]!] = undoStack.isEmpty ? 8 : 40
        ccs[Self.buttonCC["loop"]!] = menu == .loopLength ? 127 : 24
        ccs[Self.buttonCC["back"]!] = (menu != .none || mode == .setOverview) ? 60 : 12
        ccs[Self.buttonCC["left"]!] = song.selectedTrack > 0 || shiftHeld ? 40 : 8
        ccs[Self.buttonCC["right"]!] = song.selectedTrack < 3 || shiftHeld ? 40 : 8
        ccs[Self.buttonCC["minus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["plus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["capture"]!] = 12
        ccs[Self.buttonCC["sample"]!] = 12

        // Shift-function legends under the step row (synthetic CCs, 200 + step).
        // Bright while Shift is held (function available); soft steady glow when
        // the function's toggle is active so its state reads at a glance.
        for step in Self.legendSteps {
            var level = shiftHeld ? 127 : 0
            if step == 5, metronomeOn { level = max(level, 48) }
            if step == 9, fullVelocity { level = max(level, 48) }
            ccs[200 + step] = level
        }

        noteColors = colors
        noteChannels = channels
        ccLeds = ccs
    }

    // MARK: - Control id maps (shared with the panel views)

    static func padNote(_ index: Int) -> Int {
        let row = index / 8, col = index % 8
        return 0x5c - row * 8 + col
    }

    static func stepNote(_ index: Int) -> Int { 0x10 + index }

    static let trackNotes = [0x2b, 0x2a, 0x29, 0x28]

    static let buttonCC: [String: Int] = [
        "play": 0x55, "record": 0x56, "capture": 0x34, "sample": 0x76,
        "loop": 0x3a, "mute": 0x58, "delete": 0x77, "copy": 0x3c,
        "undo": 0x38, "shift": 0x31, "note": 0x32, "back": 0x33,
        "left": 0x3e, "right": 0x3f, "minus": 0x36, "plus": 0x37,
    ]
}

extension SIMD3 where Scalar == Double {
    static func * (lhs: SIMD3<Double>, rhs: Double) -> SIMD3<Double> {
        SIMD3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
}
