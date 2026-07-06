import SwiftUI
import Combine
import AVFoundation

/// The standalone Move "firmware": owns the song, modes, OLED screen, LED
/// state, and drives the audio engine. Exposes the same surface API the
/// MoveOS network client had, so the panel views bind unchanged.
@MainActor
final class Brain: ObservableObject {
    @Published var displayImage: CGImage?
    @Published var noteColors: [Int: SIMD3<Double>] = [:]
    @Published var noteChannels: [Int: Int] = [:]
    @Published var ccLeds: [Int: Int] = [:]
    /// Bare theme: no chassis — controls float on the iPad's own glass.
    @Published var bareTheme = UserDefaults.standard.bool(forKey: "theme.bare")
    /// Hardware-theme chassis color (palette index, persisted).
    @Published var chassisColorIndex = UserDefaults.standard.integer(forKey: "theme.color")
    private var setupEditingTheme = true

    static let chassisColors: [(name: String, rgb: SIMD3<Double>)] = [
        ("BLACK",    SIMD3(0.095, 0.095, 0.102)),
        ("GRAPHITE", SIMD3(0.155, 0.155, 0.165)),
        ("SLATE",    SIMD3(0.115, 0.130, 0.165)),
        ("ESPRESSO", SIMD3(0.150, 0.115, 0.095)),
        ("OLIVE",    SIMD3(0.120, 0.135, 0.100)),
        ("OXBLOOD",  SIMD3(0.165, 0.095, 0.105)),
        ("SAND",     SIMD3(0.420, 0.395, 0.350)),
    ]
    var chassisColor: SIMD3<Double> {
        Self.chassisColors[((chassisColorIndex % Self.chassisColors.count)
                            + Self.chassisColors.count) % Self.chassisColors.count].rgb
    }

    let engine = AudioEngine()

    // ---- Song / state ----
    private(set) var song = Song()
    private var currentSlot = 0
    private var undoStack: [Song] = []
    private var redoStack: [Song] = []

    enum Mode { case note, session, setOverview }
    private var mode = Mode.note

    enum Menu: Equatable {
        case none, tempo, groove, metronome, scale, browser, setup, loopLength, workflow
        case auPresets
        case message(String)
    }
    private var menu = Menu.none
    private var browserIndex = 0
    private var scaleEditingRoot = true

    // Workflow settings (manual ch 13) — device settings, persisted outside the song.
    private var countInOn = UserDefaults.standard.bool(forKey: "wf.countIn")
    private var autoloadOn = UserDefaults.standard.bool(forKey: "wf.autoload")
    private var workflowEditingCountIn = true
    private var browserOriginalSound: Int?   // autoload preview rollback
    /// AU parameter bank per track (7 params per bank on encoders 2-8;
    /// encoder 1 = track volume, AUSeq-style). Shift+wheel press cycles.
    private var auParamBank: [Int: Int] = [:]
    // Loop Mode (12.1): pair-press sets start+end, double-press = one bar,
    // brief single press selects the bar.
    private var loopModeHeld: Set<Int> = []
    private var loopModeEdited = false
    private var lastLoopTap: (index: Int, at: Date)?
    /// Preset active when the AU preset browser opened (Back = rollback).
    private var auPresetOriginal: AUAudioUnitPreset?

    // Held modifiers
    private var shiftHeld = false
    private var shiftLocked = false
    private var lastShiftTap: Date?
    private var muteHeld = false
    private var deleteHeld = false
    private var copyHeld = false
    private var copiedClip: Clip?

    // Manual 9.5 sequencing state: pad-then-step / step-then-pad note entry.
    private var heldPads: [Int: Int] = [:]     // melodic pad index -> MIDI note
    private var heldSteps: Set<Int> = []       // step-row indices currently held
    private var stepEntryUsed: Set<Int> = []   // steps that inserted notes while held

    /// Retrospective capture (manual 14.3): everything played lands here even
    /// when not recording. start/length are in steps while the transport runs,
    /// in seconds while stopped.
    private struct CapturedNote {
        var track: Int
        var key: Int
        var velocity: Int
        var start: Double
        var length: Double
        var onGrid: Bool          // true = step units, false = seconds
    }
    private var captureBuffer: [CapturedNote] = []
    private var captureOpen: [Int: Int] = [:]  // track*1000+key -> buffer index

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

    // Lighter pastels — reads softer on the silicone pads.
    static let trackColors: [SIMD3<Double>] = [
        SIMD3(0.55, 0.72, 1.0),   // pastel blue
        SIMD3(1.0, 0.63, 0.55),   // pastel coral
        SIMD3(0.58, 0.97, 0.75),  // pastel mint
        SIMD3(0.85, 0.64, 1.0),   // pastel violet
        SIMD3(1.0, 0.85, 0.55),   // pastel amber
        SIMD3(0.55, 0.94, 0.97),  // pastel cyan
        SIMD3(1.0, 0.62, 0.85),   // pastel pink
        SIMD3(0.80, 0.97, 0.58),  // pastel lime
    ]

    /// Step indices that have a Shift function (see shiftStep) — these get an
    /// illuminated legend under the step button on the panel.
    static let legendSteps = [0, 1, 2, 4, 5, 6, 8, 9, 14, 15]

    // MARK: - Lifecycle

    func start() {
        engine.start()
        // Resume the last-used slot so a background auto-save can never
        // overwrite a saved set with a blank one.
        currentSlot = UserDefaults.standard.integer(forKey: "currentSlot")
        if let saved = Self.loadSet(slot: currentSlot) {
            song = Self.migrated(saved)
        } else {
            song = .demo() // first launch: seed something playable
        }
        for (i, t) in song.tracks.enumerated() where t.kind == .drum {
            loadKit(track: i, index: t.soundIndex)
        }
        reinstallAUs()
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

    // MARK: - AUv3 instruments

    /// Installed AUv3 instruments (plus internal presets) for the browser.
    private lazy var auComponents: [AVAudioUnitComponent] = {
        var wildcard = AudioComponentDescription()
        wildcard.componentType = kAudioUnitType_MusicDevice
        return AVAudioUnitComponentManager.shared().components(matching: wildcard)
    }()

    private func browserEntries() -> [String] {
        if track.kind == .drum { return DrumKits.names }
        return SynthPreset.all.map(\.name)
            + auComponents.map { "\($0.name) - \($0.manufacturerName)" }
    }

    private static func auDescription(from id: String) -> AudioComponentDescription? {
        let parts = id.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 3 else { return nil }
        return AudioComponentDescription(componentType: parts[0], componentSubType: parts[1],
                                         componentManufacturer: parts[2],
                                         componentFlags: 0, componentFlagsMask: 0)
    }

    private func selectAU(_ component: AVAudioUnitComponent, forTrack trackIndex: Int) {
        let desc = component.audioComponentDescription
        let id = "\(desc.componentType):\(desc.componentSubType):\(desc.componentManufacturer)"
        showOverlay("LOADING", 0.5, String(component.name.prefix(20)))
        Task { @MainActor in
            do {
                let name = try await engine.installAU(track: trackIndex, description: desc)
                auParamBank[trackIndex] = 0
                engine.setAUVolume(track: trackIndex,
                                   volume: Float(song.tracks[trackIndex].volume))
                edit { song in
                    song.tracks[trackIndex].auIdentifier = id
                    song.tracks[trackIndex].auName = name
                    song.tracks[trackIndex].auPresetName = nil
                }
                showOverlay("LOADED", 1, String(name.prefix(20)))
            } catch {
                engine.removeAU(track: trackIndex)
                showOverlay("AU FAILED", 0, String(component.name.prefix(20)))
            }
        }
    }

    /// Re-instantiate the AUs a loaded set references (or drop stale ones).
    private func reinstallAUs() {
        for (t, tr) in song.tracks.enumerated() {
            if let id = tr.auIdentifier, let desc = Self.auDescription(from: id) {
                let volume = Float(tr.volume)
                let presetName = tr.auPresetName
                Task { @MainActor in
                    if let name = try? await engine.installAU(track: t, description: desc) {
                        engine.setAUVolume(track: t, volume: volume)
                        if let presetName,
                           let preset = engine.auPresets(track: t).first(where: { $0.name == presetName }) {
                            engine.setAUPreset(track: t, preset: preset)
                        }
                        adjust { $0.tracks[t].auName = name }
                    } else {
                        engine.removeAU(track: t)
                        adjust {
                            $0.tracks[t].auIdentifier = nil
                            $0.tracks[t].auName = nil
                        }
                    }
                }
            } else {
                engine.removeAU(track: t)
            }
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
            guard row >= 4 else { return } // classic layout on the bottom 4 rows
            if col < 4 {
                let cell = (7 - row) * 4 + col
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
                    captureNoteOn(key: cell, velocity: velocity)
                    recordHit(key: cell, velocity: velocity)
                }
            } else if down {
                guard !deleteHeld, !muteHeld else { return }
                // 16 Pitches: play the selected cell repitched.
                let p = (7 - row) * 4 + (col - 4)
                let rate = pow(2.0, Float(p - 7) / 12)
                engine.liveNote(track: song.selectedTrack, kind: .drum,
                                key: track.selectedPad, velocity: velocity, on: true, rate: rate)
            }
        } else {
            let scale = Scales.all[song.scaleIndex].steps
            let note = Scales.padToNote(index, root: song.rootNote, scale: scale, octave: track.octave)
            if !down {
                // Releases always land, even with delete/mute held.
                let released = heldPads.removeValue(forKey: index) ?? note
                engine.liveNote(track: song.selectedTrack, kind: .synth,
                                key: released, velocity: velocity, on: false)
                captureNoteOff(key: released)
                recordRelease(key: released)
                return
            }
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
                            velocity: velocity, on: true)
            captureNoteOn(key: note, velocity: velocity)
            heldPads[index] = note
            // Step-then-pad (manual 9.5): held step(s) receive this pitch —
            // a held step on the empty extra bar extends the loop (12.1).
            if !heldSteps.isEmpty {
                let clipSteps = track.clips[song.selectedScene].steps
                let targets = heldSteps.map { barPage * 16 + $0 }
                let needsExtension = targets.contains { $0 >= clipSteps }
                insertNotes([note], atSteps: targets, velocity: velocity,
                            extendTo: needsExtension ? barPage + 1 : nil)
                stepEntryUsed.formUnion(heldSteps)
            }
            recordHit(key: note, velocity: velocity)
        }
        refreshLeds()
    }

    /// Live-record bookkeeping: pad-down position per key, so pad-up can
    /// write the real note length.
    private var pendingRecordings: [Int: (step: Int, startPos: Double)] = [:]

    private func recordHit(key: Int, velocity: Int) {
        guard recording, engine.isPlaying, !engine.inCountIn else { return }
        let clip = track.clips[song.selectedScene]
        // Floor-quantize into the CURRENT step (which already fired) — nearest-
        // rounding wrote hits into the upcoming step, which the sequencer then
        // re-fired ~50ms later: an audible flam on almost every recorded note.
        let pos = engine.currentStep
        let step = clip.localStep(Int(pos))
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
        // XL 8x8 session grid: rows are tracks (same semantics as the real
        // Move, just 8 of them), columns are the 8 scenes. No paging.
        let trackIndex = index / 8, scene = index % 8
        guard song.tracks.indices.contains(trackIndex) else { return }
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
            song = Self.migrated(loaded)
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
        reinstallAUs()
        engine.update(song: song)
        engine.setTransport(playing: false, fromStart: true)
        recording = false
        mode = .note
        refresh()
    }

    // MARK: - Surface API: steps

    func step(_ index: Int, down: Bool) {
        if !down {
            if menu == .loopLength, mode == .note, loopModeHeld.remove(index) != nil {
                if loopModeHeld.isEmpty {
                    if !loopModeEdited, index < track.clips[song.selectedScene].bars {
                        barPage = index
                        showOverlay("BAR \(index + 1)", Double(index + 1) / 8, "SELECTED")
                    }
                    loopModeEdited = false
                }
                refreshLeds()
                return
            }
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
            // Loop Mode (manual 12.1): steps are bars. Press start+end
            // together (or hold start, press end) to set the loop region;
            // double-press = loop that single bar; brief press selects it.
            if menu == .loopLength {
                guard index < 8 else { return }
                if let anchor = loopModeHeld.first(where: { $0 != index }) {
                    setLoopRegion(start: min(anchor, index), endBar: max(anchor, index) + 1)
                    loopModeEdited = true
                } else if let tap = lastLoopTap, tap.index == index,
                          Date().timeIntervalSince(tap.at) < 0.4 {
                    setLoopRegion(start: index, endBar: index + 1)
                    loopModeEdited = true
                }
                loopModeHeld.insert(index)
                lastLoopTap = (index, Date())
                return
            }
            let clip = track.clips[song.selectedScene]
            let step = barPage * 16 + index
            // Adding notes to the empty extra bar extends the loop (12.1).
            let extendsBar = step >= clip.steps && barPage >= clip.bars && clip.bars < 8
            guard step < clip.steps || extendsBar else { return }
            heldSteps.insert(index)
            if deleteHeld {
                stepEntryUsed.insert(index)
                guard step < clip.steps else { return }
                let drumKey = track.kind == .drum ? track.selectedPad : nil
                edit { song in
                    song.tracks[song.selectedTrack].clips[song.selectedScene]
                        .notes.removeAll { $0.step == step && (drumKey == nil || $0.key == drumKey) }
                }
                return
            }
            if track.kind == .drum {
                // Pressing a pad selects the cell, so a plain step press IS
                // the manual's pad-then-step flow for drums: empty step adds
                // on press; a lit step clears on brief release (stepReleased),
                // so holding it to edit velocity/length never deletes it.
                let key = track.selectedPad
                if extendsBar || !clip.notes.contains(where: { $0.step == step && $0.key == key }) {
                    stepEntryUsed.insert(index)
                    edit { song in
                        var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
                        if extendsBar { c.bars = barPage + 1 }
                        c.notes.append(Note(step: step, key: key,
                                            velocity: fullVelocity ? 127 : 100))
                        song.tracks[song.selectedTrack].clips[song.selectedScene] = c
                    }
                }
            } else if !heldPads.isEmpty {
                // Melodic pad-then-step (manual 9.5).
                insertNotes(Array(heldPads.values), atSteps: [step],
                            velocity: fullVelocity ? 127 : 100, extendTo: extendsBar ? barPage + 1 : nil)
                stepEntryUsed.insert(index)
            }
        }
    }

    /// Melodic brief-tap removal (manual: "to remove a note from a step,
    /// briefly press the respective step button").
    private func stepReleased(_ index: Int) {
        guard heldSteps.remove(index) != nil else { return }
        let used = stepEntryUsed.remove(index) != nil
        guard !used, mode == .note else { return }
        let step = barPage * 16 + index
        let drumKey = track.kind == .drum ? track.selectedPad : nil
        guard track.clips[song.selectedScene].notes.contains(where: {
            $0.step == step && (drumKey == nil || $0.key == drumKey)
        }) else { return }
        edit { song in
            song.tracks[song.selectedTrack].clips[song.selectedScene]
                .notes.removeAll { $0.step == step && (drumKey == nil || $0.key == drumKey) }
        }
    }

    /// Insert pitches at steps in one undo unit; starts the transport when a
    /// first note lands in an empty clip (manual 9.5). extendTo grows the
    /// loop first (adding notes to the empty extra bar keeps it, 12.1).
    private func insertNotes(_ keys: [Int], atSteps steps: [Int], velocity: Int,
                             extendTo newBars: Int? = nil) {
        let clip = track.clips[song.selectedScene]
        let wasEmpty = clip.isEmpty
        let limit = (newBars ?? clip.bars) * 16
        let valid = steps.filter { $0 < limit }
        guard !valid.isEmpty else { return }
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            if let newBars, newBars > c.bars { c.bars = newBars }
            for step in valid {
                for key in keys where !c.notes.contains(where: { $0.step == step && $0.key == key }) {
                    c.notes.append(Note(step: step, key: key, velocity: velocity))
                }
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        if wasEmpty && !engine.isPlaying {
            purgeGridCapture()
            engine.setTransport(playing: true, fromStart: true)
        }
    }

    /// Loop Mode region change: start bar + end bar (exclusive). Growing the
    /// end keeps/extends content; shrinking trims notes beyond it. Notes
    /// before the start are kept but silent (manual 12.1 semantics).
    private func setLoopRegion(start: Int, endBar: Int) {
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            if endBar < c.bars {
                let limit = endBar * 16
                c.notes.removeAll { $0.step >= limit }
            }
            c.bars = min(8, max(1, endBar))
            c.loopStart = start > 0 ? start : nil
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        barPage = min(max(barPage, start), endBar - 1)
        let length = endBar - start
        showOverlay("LOOP \(start + 1)-\(endBar)", Double(endBar) / 8,
                    "\(length) BAR\(length > 1 ? "S" : "")")
    }

    /// Drop pad/step entry latches (mode, track, or set changed under them).
    /// Held melodic voices are released first or they sustain forever.
    private func clearEntryState() {
        for (_, key) in heldPads {
            engine.liveNote(track: song.selectedTrack, kind: .synth,
                            key: key, velocity: 0, on: false)
            captureNoteOff(key: key)
        }
        heldPads.removeAll()
        heldSteps.removeAll()
        stepEntryUsed.removeAll()
    }

    private func shiftStep(_ index: Int) {
        cancelBrowserPreview()   // any menu jump abandons an autoload preview
        switch index {
        case 0: mode = .setOverview; menu = .none; refresh()
        case 1: menu = .setup; refresh()
        case 2: menu = .workflow; refresh()
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
            guard track.clips[song.selectedScene].bars * 2 <= 8 else { break }
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
        case "shift":
            if down {
                if shiftLocked {
                    shiftLocked = false
                    shiftHeld = false
                    showOverlay("SHIFT", 0, "UNLOCKED")
                } else {
                    shiftHeld = true
                    if let tap = lastShiftTap, Date().timeIntervalSince(tap) < 0.4 {
                        shiftLocked = true
                        showOverlay("SHIFT", 1, "LOCKED")
                    }
                    lastShiftTap = Date()
                }
            } else if !shiftLocked {
                shiftHeld = false
            }
        case "mute": muteHeld = down
        case "delete": deleteHeld = down
        case "copy": copyHeld = down
        case let id where id.hasPrefix("track"):
            if down, let n = Int(id.dropFirst(5)) { trackButton(n - 1) }
        case "play":
            if down { togglePlay(restart: shiftHeld) }
        case "record":
            if down { toggleRecord() }
        case "undo":
            if down { shiftHeld ? redo() : undo() }
        case "note":
            if down {
                mode = mode == .note ? .session : .note
                cancelBrowserPreview()
                menu = .none
                copiedClip = nil
                clearEntryState()
                refresh()
            }
        case "back":
            if down { backButton() }
        case "loop":
            if down {
                cancelBrowserPreview()
                menu = menu == .loopLength ? .none : .loopLength
                refresh()
            }
        case "capture":
            if down { captureButton() }
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
        case "wheelUp":
            if down { wheel(delta: 1) }
        case "wheelDown":
            if down { wheel(delta: -1) }
        case "wheelPress":
            if down { wheelPress() }
        default:
            break
        }
        refreshLeds()
    }

    private func trackButton(_ index: Int) {
        guard song.tracks.indices.contains(index) else { return }
        if muteHeld {
            edit { $0.tracks[index].muted.toggle() }
        } else {
            if menu == .browser { cancelBrowserPreview(); menu = .none } // stale list would commit a random sound
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
            purgeGridCapture()
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
            purgeGridCapture()
            // Count-in (manual 13.3): one bar of clicks before sequencing starts.
            engine.setTransport(playing: true, fromStart: true,
                                countInSteps: countInOn ? 16 : 0)
        }
        refresh()
    }

    /// Leaving the browser without committing: roll back an autoload preview.
    private func cancelBrowserPreview() {
        guard menu == .browser else { return }
        if autoloadOn, let original = browserOriginalSound, original != track.soundIndex {
            adjust { $0.tracks[$0.selectedTrack].soundIndex = original }
            if track.kind == .drum { loadKit(track: song.selectedTrack, index: original) }
        }
        browserOriginalSound = nil
    }

    private func backButton() {
        copiedClip = nil
        if menu == .auPresets, let original = auPresetOriginal {
            engine.setAUPreset(track: song.selectedTrack, preset: original)
            auPresetOriginal = nil
        }
        if menu != .none {
            cancelBrowserPreview()
            menu = .none
        } else if mode == .setOverview {
            mode = .note
        }
        refresh()
    }

    private func leftRight(_ direction: Int) {
        guard mode == .note else { return }
        // Step-hold + arrows = nudge notes by 10% of a step (Shift: 1%).
        if !heldSteps.isEmpty {
            nudgeHeldSteps(by: Double(direction) * (shiftHeld ? 0.01 : 0.1))
            return
        }
        // Arrows move between bars (manual 9.5/12.1) — track selection is the
        // track buttons' job. One page past the end shows an empty bar; it
        // joins the loop if you add notes to it.
        let bars = track.clips[song.selectedScene].bars
        let maxPage = bars < 8 ? bars : bars - 1
        barPage = min(maxPage, max(0, barPage + direction))
        showOverlay("BAR \(barPage + 1)", Double(barPage + 1) / 8,
                    barPage >= bars ? "EMPTY: ADD TO KEEP" : "OF \(bars)")
    }

    private func octave(_ direction: Int) {
        // Step-hold + plus/minus transposes the held notes by a semitone
        // (manual 11.2, melodic only).
        if !heldSteps.isEmpty, track.kind == .synth {
            let steps = heldAbsSteps()
            stepEntryUsed.formUnion(heldSteps)
            edit { song in
                var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
                for i in c.notes.indices where steps.contains(c.notes[i].step) {
                    c.notes[i].key = min(126, max(1, c.notes[i].key + direction))
                }
                song.tracks[song.selectedTrack].clips[song.selectedScene] = c
            }
            showOverlay("NOTES", 0.5, "TRANSPOSED \(direction > 0 ? "+1" : "-1")")
            return
        }
        guard track.kind == .synth else { return }
        adjust { $0.tracks[$0.selectedTrack].octave = min(3, max(-3, $0.tracks[$0.selectedTrack].octave + direction)) }
        showOverlay("OCTAVE", 0.5, track.octave >= 0 ? "+\(track.octave)" : "\(track.octave)")
    }

    // MARK: - Step-hold editing (manual ch 11)

    /// Absolute step numbers for the currently held step buttons.
    private func heldAbsSteps() -> Set<Int> {
        Set(heldSteps.map { barPage * 16 + $0 })
    }

    /// Notes at the held steps — drum edits are scoped to the selected cell,
    /// melodic edits cover all notes at the step (matches the LEDs).
    private func heldStepMatches(_ note: Note, _ steps: Set<Int>) -> Bool {
        steps.contains(note.step) && (track.kind == .synth || note.key == track.selectedPad)
    }

    /// Step-hold + Volume encoder (manual 11.1): note velocity.
    private func adjustHeldVelocity(by delta: Int) {
        let steps = heldAbsSteps()
        stepEntryUsed.formUnion(heldSteps)
        var shown = 100
        adjust { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            for i in c.notes.indices where heldStepMatches(c.notes[i], steps) {
                c.notes[i].velocity = min(127, max(1, c.notes[i].velocity + delta * 2))
                shown = c.notes[i].velocity
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("VELOCITY", Double(shown) / 127, "\(shown)")
    }

    /// Step-hold + wheel (manual 11.3): note length, 10% of a step per click.
    private func adjustHeldLength(by delta: Int) {
        let steps = heldAbsSteps()
        stepEntryUsed.formUnion(heldSteps)
        var shown = 1.0
        adjust { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            for i in c.notes.indices where heldStepMatches(c.notes[i], steps) {
                var length = c.notes[i].lengthSteps + Double(delta) * 0.1
                length = max(0.1, min(Double(c.steps), length))
                // Manual: cannot extend past the next note with the same key.
                if delta > 0 {
                    let next = c.notes
                        .filter { $0.key == c.notes[i].key && $0.step > c.notes[i].step }
                        .map(\.step).min()
                    if let next { length = min(length, Double(next - c.notes[i].step)) }
                }
                c.notes[i].lengthSteps = (length * 10).rounded() / 10
                shown = c.notes[i].lengthSteps
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("NOTE LENGTH", min(1, shown / 4), String(format: "%.1f", shown))
    }

    /// Step-hold + arrows (manual 11.4): nudge by a fraction of a step.
    private func nudgeHeldSteps(by amount: Double) {
        let steps = heldAbsSteps()
        stepEntryUsed.formUnion(heldSteps)
        var shownPercent = 0
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            for i in c.notes.indices where heldStepMatches(c.notes[i], steps) {
                var position = Double(c.notes[i].step) + c.notes[i].off + amount
                let total = Double(c.steps)
                position = (position.truncatingRemainder(dividingBy: total) + total)
                    .truncatingRemainder(dividingBy: total)
                let newStep = Int(position)
                let newOff = ((position - Double(newStep)) * 100).rounded() / 100
                c.notes[i].step = newStep
                c.notes[i].offset = newOff == 0 ? nil : newOff
                shownPercent = Int(newOff * 100)
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("NOTES NUDGED", Double(shownPercent) / 100, "TO \(shownPercent)%")
    }

    private func wheelPress() {
        // Shift+wheel press: next AU parameter bank (manual: parameter banks).
        if shiftHeld, menu == .none, engine.hasAU(track: song.selectedTrack) {
            let t = song.selectedTrack
            let total = engine.auParameters(track: t).count
            let banks = max(1, (total + 6) / 7)
            let bank = ((auParamBank[t] ?? 0) + 1) % banks
            auParamBank[t] = bank
            let first = bank * 7 + 1, last = min(total, bank * 7 + 7)
            showOverlay("PARAM BANK \(bank + 1)/\(banks)",
                        Double(bank + 1) / Double(banks), "\(first)-\(last) OF \(total)")
            return
        }
        switch menu {
        case .none:
            if engine.hasAU(track: song.selectedTrack) {
                // Move behavior: wheel press on a device opens its presets.
                auPresetOriginal = engine.currentAUPreset(track: song.selectedTrack)
                let presets = engine.auPresets(track: song.selectedTrack)
                browserIndex = (presets.firstIndex { $0.name == track.auPresetName } ?? -1) + 1
                menu = .auPresets
                break
            }
            browserIndex = track.soundIndex
            browserOriginalSound = track.soundIndex
            menu = .browser
        case .browser:
            let entries = browserEntries()
            guard !entries.isEmpty else { menu = .none; break }
            let chosen = ((browserIndex % entries.count) + entries.count) % entries.count
            // Autoload preview already set soundIndex without an undo entry;
            // rewind to the original first so the commit is a real undo step.
            if autoloadOn, let original = browserOriginalSound {
                adjust { $0.tracks[$0.selectedTrack].soundIndex = original }
            }
            browserOriginalSound = nil
            menu = .none
            if track.kind == .synth && chosen >= SynthPreset.all.count {
                selectAU(auComponents[chosen - SynthPreset.all.count],
                         forTrack: song.selectedTrack)
            } else {
                engine.removeAU(track: song.selectedTrack)
                edit { song in
                    song.tracks[song.selectedTrack].soundIndex = chosen
                    song.tracks[song.selectedTrack].auIdentifier = nil
                    song.tracks[song.selectedTrack].auName = nil
                }
                if track.kind == .drum { loadKit(track: song.selectedTrack, index: chosen) }
            }
        case .auPresets:
            let t = song.selectedTrack
            let presets = engine.auPresets(track: t)
            let count = presets.count + 1
            let chosen = ((browserIndex % count) + count) % count
            menu = .none
            if chosen == 0 {
                // "< CHANGE SOUND": fall through to the instrument browser.
                if let original = auPresetOriginal { engine.setAUPreset(track: t, preset: original) }
                auPresetOriginal = nil
                browserIndex = track.soundIndex
                browserOriginalSound = track.soundIndex
                menu = .browser
            } else {
                let preset = presets[chosen - 1]
                engine.setAUPreset(track: t, preset: preset)
                auPresetOriginal = nil
                edit { $0.tracks[t].auPresetName = preset.name }
                showOverlay("PRESET", 1, String(preset.name.prefix(20)))
            }
        case .scale:
            scaleEditingRoot.toggle()
        case .metronome:
            metronomeOn.toggle()
            engine.setMetronome(metronomeOn)
        case .workflow:
            workflowEditingCountIn.toggle()
        case .setup:
            setupEditingTheme.toggle()
        default:
            menu = .none
        }
        refresh()
    }

    // MARK: - Surface API: wheel / encoders / volume

    func wheel(delta: Int) {
        // Step-hold + wheel = note length (manual 11.3), regardless of menu.
        if !heldSteps.isEmpty && mode == .note {
            adjustHeldLength(by: delta)
            return
        }
        switch menu {
        case .tempo:
            adjust { $0.tempo = min(240, max(40, $0.tempo + (shiftHeld ? 0.1 : 1) * Double(delta))) }
        case .groove:
            adjust { $0.swing = min(1, max(0, $0.swing + Double(delta) * 0.02)) }
        case .auPresets:
            browserIndex += delta
            let t = song.selectedTrack
            let presets = engine.auPresets(track: t)
            let count = presets.count + 1
            let sel = ((browserIndex % count) + count) % count
            if sel > 0 { engine.setAUPreset(track: t, preset: presets[sel - 1]) } // live preview
            refresh()
        case .browser:
            browserIndex += delta
            // Autoload (manual 13.3): preview the highlighted sound immediately
            // (internal sounds only — AU instantiation is async and heavy).
            if autoloadOn {
                let count = browserEntries().count
                if count > 0 {
                    let sel = ((browserIndex % count) + count) % count
                    if sel < (track.kind == .drum ? DrumKits.names.count : SynthPreset.all.count) {
                        adjust { $0.tracks[$0.selectedTrack].soundIndex = sel }
                        if track.kind == .drum { loadKit(track: song.selectedTrack, index: sel) }
                    }
                }
            }
            refresh()
        case .workflow:
            // Wheel right = ON, left = OFF for the highlighted setting.
            if workflowEditingCountIn {
                countInOn = delta > 0
                UserDefaults.standard.set(countInOn, forKey: "wf.countIn")
            } else {
                autoloadOn = delta > 0
                UserDefaults.standard.set(autoloadOn, forKey: "wf.autoload")
            }
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
            let clip0 = track.clips[song.selectedScene]
            let bars = clip0.bars
            let minBars = (clip0.loopStart ?? 0) + 1
            let current = options.lastIndex(where: { $0 <= bars }) ?? 0
            let newBars = max(minBars, options[min(options.count - 1, max(0, current + delta))])
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
        case .setup:
            if setupEditingTheme {
                bareTheme.toggle()
                UserDefaults.standard.set(bareTheme, forKey: "theme.bare")
            } else {
                let count = Self.chassisColors.count
                chassisColorIndex = ((chassisColorIndex + delta) % count + count) % count
                UserDefaults.standard.set(chassisColorIndex, forKey: "theme.color")
            }
            refresh()
        case .metronome, .message:
            break
        }
    }

    func wheelTouch(down: Bool) {}
    func encoderTouch(_ index: Int, down: Bool) {}

    func encoder(_ index: Int, delta: Int) {
        let d = Float(delta)
        let t = song.selectedTrack
        // AU-hosted track (AUSeq convention): encoder 1 = track volume,
        // encoders 2-8 = the active 7-parameter bank.
        if engine.hasAU(track: t) && index < 8 {
            if index == 0 {
                adjust { $0.tracks[t].volume = min(1, max(0, $0.tracks[t].volume + Double(d) * 0.02)) }
                engine.setAUVolume(track: t, volume: Float(track.volume))
                showOverlay("TRACK VOL", track.volume, String(format: "%.0f%%", track.volume * 100))
                return
            }
            let params = engine.auParameters(track: t)
            let bank = auParamBank[t] ?? 0
            let pIdx = bank * 7 + (index - 1)
            guard params.indices.contains(pIdx) else { return }
            let param = params[pIdx]
            let span = param.maxValue - param.minValue
            let value = max(param.minValue,
                            min(param.maxValue, param.value + d * span / 64))
            param.setValue(value, originator: nil)
            let label = param.string(fromValue: nil) ?? String(format: "%.2f", value)
            showOverlay(String(param.displayName.prefix(18)),
                        Double((value - param.minValue) / max(0.0001, span)),
                        String(label.prefix(18)))
            return
        }
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
            engine.setAUVolume(track: t, volume: Float(track.volume))
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
        // Step-hold + volume encoder = note velocity (manual 11.1).
        if !heldSteps.isEmpty && mode == .note {
            adjustHeldVelocity(by: delta)
            return
        }
        mainVolume = min(1, max(0, mainVolume + Double(delta) * 0.02))
        engine.setMainVolume(Float(mainVolume))
        showOverlay("MAIN VOLUME", mainVolume, String(format: "%.0f%%", mainVolume * 100))
    }

    // MARK: - Capture (manual 14.3)

    /// On-grid capture entries reference the transport's step clock; a
    /// restart from zero invalidates them.
    private func purgeGridCapture() {
        captureBuffer.removeAll { $0.onGrid }
        captureOpen.removeAll()
    }

    private func captureNoteOn(key: Int, velocity: Int) {
        // During the count-in the step clock is about to be discarded.
        guard !engine.inCountIn else { return }
        let playing = engine.isPlaying
        let start = playing ? engine.currentStep : Date.timeIntervalSinceReferenceDate
        captureBuffer.append(CapturedNote(track: song.selectedTrack, key: key,
                                          velocity: velocity, start: start,
                                          length: playing ? 1 : 0.25, onGrid: playing))
        captureOpen[song.selectedTrack * 1000 + key] = captureBuffer.count - 1
        if captureBuffer.count > 512 {
            captureBuffer.removeFirst(captureBuffer.count - 512)
            captureOpen.removeAll() // indices invalidated; lengths stay default
        }
    }

    private func captureNoteOff(key: Int) {
        guard let i = captureOpen.removeValue(forKey: song.selectedTrack * 1000 + key),
              captureBuffer.indices.contains(i) else { return }
        let end = captureBuffer[i].onGrid ? engine.currentStep : Date.timeIntervalSinceReferenceDate
        captureBuffer[i].length = max(0.05, end - captureBuffer[i].start)
    }

    private func captureButton() {
        if shiftHeld {
            captureBuffer.removeAll()
            captureOpen.removeAll()
            showOverlay("CAPTURE", 0, "BUFFER CLEARED")
            return
        }
        guard !captureBuffer.isEmpty else {
            showOverlay("CAPTURE", 0, "NOTHING PLAYED YET")
            return
        }
        let wasPlaying = engine.isPlaying
        // Check eligibility BEFORE edit{} so a fruitless capture doesn't
        // push a no-op undo snapshot.
        if wasPlaying {
            let now = engine.currentStep
            let anyInWindow = captureBuffer.contains { note in
                note.onGrid && song.tracks.indices.contains(note.track)
                    && note.start >= now - Double(song.tracks[note.track].clips[song.selectedScene].loopSteps)
            }
            guard anyInWindow else { showOverlay("CAPTURE", 0, "NOTHING IN WINDOW"); return }
        } else {
            let cutoff = Date.timeIntervalSinceReferenceDate - 16
            guard captureBuffer.contains(where: { !$0.onGrid && $0.start >= cutoff }) else {
                showOverlay("CAPTURE", 0, "NOTHING IN WINDOW"); return
            }
        }
        var involved = Set<Int>()
        edit { song in
            if wasPlaying {
                // On-grid pass: pull each track's last loop-length of playing.
                let now = engine.currentStep
                for note in captureBuffer where note.onGrid {
                    guard song.tracks.indices.contains(note.track) else { continue }
                    var clip = song.tracks[note.track].clips[song.selectedScene]
                    guard note.start >= now - Double(clip.loopSteps) else { continue }
                    let step = clip.localStep(Int(note.start.rounded()))
                    clip.notes.removeAll { $0.step == step && $0.key == note.key }
                    clip.notes.append(Note(step: step, key: note.key, velocity: note.velocity,
                                           lengthSteps: max(0.25, (note.length * 4).rounded() / 4)))
                    song.tracks[note.track].clips[song.selectedScene] = clip
                    involved.insert(note.track)
                }
            } else {
                // Free-time pass: quantize the last 16 seconds at current tempo.
                let cutoff = Date.timeIntervalSinceReferenceDate - 16
                let phrase = captureBuffer.filter { !$0.onGrid && $0.start >= cutoff }
                guard let t0 = phrase.map(\.start).min() else { return }
                let stepsPerSecond = song.tempo / 60 * 4
                let maxStep = phrase.map { (($0.start - t0) * stepsPerSecond).rounded() }.max() ?? 0
                let bars = min(8, max(1, Int(maxStep) / 16 + 1))
                for note in phrase {
                    guard song.tracks.indices.contains(note.track) else { continue }
                    var clip = song.tracks[note.track].clips[song.selectedScene]
                    clip.bars = max(clip.bars, bars)
                    let step = Int(((note.start - t0) * stepsPerSecond).rounded()) % clip.steps
                    let length = max(0.25, ((note.length * stepsPerSecond) * 4).rounded() / 4)
                    clip.notes.removeAll { $0.step == step && $0.key == note.key }
                    clip.notes.append(Note(step: step, key: note.key, velocity: note.velocity,
                                           lengthSteps: length))
                    song.tracks[note.track].clips[song.selectedScene] = clip
                    involved.insert(note.track)
                }
            }
        }
        guard !involved.isEmpty else { return } // pre-check makes this unreachable
        captureBuffer.removeAll()
        captureOpen.removeAll()
        if !wasPlaying { engine.setTransport(playing: true, fromStart: true) }
        showOverlay("CAPTURED", 1, "\(involved.count) TRACK\(involved.count > 1 ? "S" : "")")
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

    /// Sets saved by the 4-track Move layout gain XL's extra tracks.
    static func migrated(_ song: Song) -> Song {
        var s = song
        let defaults = Song.defaultTracks()
        while s.tracks.count < defaults.count {
            s.tracks.append(defaults[s.tracks.count])
        }
        for i in s.tracks.indices {
            while s.tracks[i].clips.count < 8 { s.tracks[i].clips.append(Clip()) }
        }
        return s
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
        shiftLocked = false
        muteHeld = false
        deleteHeld = false
        copyHeld = false
    }

    private func refresh() {
        // barPage can go stale via scene changes, loop shrink, set load, undo.
        // Allow one page past the end: the manual's "empty bar" you can fill.
        barPage = min(barPage, min(track.clips[song.selectedScene].bars, 7))
        refreshScreen()
        refreshLeds()
    }

    // XL display: 256x128 — menus get room, the main screen earns the extra
    // pixels with an always-on 8-track overview strip.

    private func refreshScreen() {
        var s = Screen()
        if let overlay {
            s.text(overlay.title, x: 8, y: 12, size: 2)
            s.bar(8, 48, 240, 22, value: overlay.value)
            s.textCentered(overlay.label, y: 88, size: 2)
            displayImage = s.render()
            return
        }
        switch menu {
        case .tempo:
            s.text("TEMPO", x: 8, y: 8)
            s.textCentered(String(format: "%.1f", song.tempo), y: 44, size: 5)
            s.textCentered("BPM", y: 104)
        case .groove:
            s.text("GROOVE", x: 8, y: 8)
            s.bar(28, 50, 200, 26, value: song.swing)
            s.textCentered(String(format: "%.0f%%", song.swing * 100), y: 94, size: 2)
        case .metronome:
            s.text("METRONOME", x: 8, y: 8)
            s.textCentered(metronomeOn ? "ON" : "OFF", y: 48, size: 5)
        case .scale:
            s.text("KEY & SCALE", x: 8, y: 8)
            let root = Scales.noteNames[song.rootNote]
            let name = Scales.all[song.scaleIndex].name
            if scaleEditingRoot { s.fillRect(14, 42, 62, 26) }
            s.text(root, x: 24, y: 48, size: 2, invert: scaleEditingRoot)
            if !scaleEditingRoot { s.fillRect(88, 42, 156, 26) }
            s.text(name, x: 94, y: 48, size: 2, invert: !scaleEditingRoot)
            s.textCentered("PRESS WHEEL TO SWAP", y: 106)
        case .browser:
            s.text(track.kind == .drum ? "KITS" : "SOUNDS + AU", x: 8, y: 4)
            let names = browserEntries()
            guard !names.isEmpty else { break }
            let sel = ((browserIndex % names.count) + names.count) % names.count
            for line in -2...2 {
                let i = ((sel + line) % names.count + names.count) % names.count
                let y = 34 + (line + 2) * 18
                if line == 0 { s.fillRect(0, y - 3, 256, 17) }
                s.text(names[i], x: 8, y: y, size: line == 0 ? 2 : 1, invert: line == 0)
            }
        case .auPresets:
            s.text("AU PRESETS", x: 8, y: 4)
            let names = ["< CHANGE SOUND"] + engine.auPresets(track: song.selectedTrack).map(\.name)
            let sel = ((browserIndex % names.count) + names.count) % names.count
            for line in -2...2 {
                let i = ((sel + line) % names.count + names.count) % names.count
                let y = 34 + (line + 2) * 18
                if line == 0 { s.fillRect(0, y - 3, 256, 17) }
                s.text(String(names[i].prefix(21)), x: 8, y: y,
                       size: line == 0 ? 2 : 1, invert: line == 0)
            }
        case .loopLength:
            let clip = track.clips[song.selectedScene]
            let from = clip.loopStartStep / 16 + 1
            s.text("LOOP", x: 8, y: 8)
            s.textCentered(from == 1 && clip.bars == 1 ? "1 BAR" : "\(from)-\(clip.bars)",
                           y: 40, size: 4)
            s.textCentered("\(clip.bars - from + 1) BAR\(clip.bars - from > 0 ? "S" : "") LOOPED", y: 88)
            s.textCentered("2 STEPS=REGION 2X=1BAR", y: 106)
        case .workflow:
            s.text("WORKFLOW", x: 8, y: 8)
            if workflowEditingCountIn { s.fillRect(4, 34, 248, 24) }
            s.text("COUNT-IN  \(countInOn ? "ON" : "OFF")", x: 12, y: 40, size: 2, invert: workflowEditingCountIn)
            if !workflowEditingCountIn { s.fillRect(4, 62, 248, 24) }
            s.text("AUTOLOAD  \(autoloadOn ? "ON" : "OFF")", x: 12, y: 68, size: 2, invert: !workflowEditingCountIn)
            s.textCentered("TURN=SET PRESS=SWAP", y: 106)
        case .setup:
            s.text("SETUP - MOTUS XL", x: 8, y: 8)
            s.text("\(DrumKits.names.count) KITS - 8 TRACKS", x: 8, y: 24)
            let colorName = Self.chassisColors[((chassisColorIndex % Self.chassisColors.count)
                + Self.chassisColors.count) % Self.chassisColors.count].name
            if setupEditingTheme { s.fillRect(4, 44, 248, 22) }
            s.text("THEME  \(bareTheme ? "BARE" : "HARDWARE")", x: 12, y: 50, size: 2, invert: setupEditingTheme)
            if !setupEditingTheme { s.fillRect(4, 70, 248, 22) }
            s.text("COLOR  \(colorName)", x: 12, y: 76, size: 2, invert: !setupEditingTheme)
            s.textCentered("TURN=SET PRESS=SWAP", y: 108)
        case .message(let msg):
            s.textCentered(msg, y: 56, size: 2)
        case .none:
            mainScreen(&s)
        }
        displayImage = s.render()
    }

    private func mainScreen(_ s: inout Screen) {
        switch mode {
        case .setOverview:
            s.text("SET OVERVIEW", x: 8, y: 8)
            s.text(song.name, x: 8, y: 40, size: 3)
            s.text("PAD LOAD / DEL CLEAR", x: 8, y: 108)
        case .session, .note:
            header(&s)
            trackStrip(&s)
            selectedDetail(&s)
            footer(&s)
        }
    }

    private func header(_ s: inout Screen) {
        s.text(String(song.name.prefix(18)), x: 4, y: 3)
        s.text(String(format: "%.0f BPM", song.tempo), x: 130, y: 3)
        s.text("S\(song.selectedScene + 1)", x: 186, y: 3)
        if mode == .session { s.text("SESSION", x: 204, y: 3) }
        if recording {
            s.fillRect(246, 2, 8, 8)
        } else if engine.isPlaying {
            for i in 0..<4 { s.fillRect(246 + i, 2 + i, 1, 8 - 2 * i) }
        }
        s.hline(0, 13, 256)
    }

    /// The XL's reason to exist: all 8 tracks at a glance — name, level,
    /// clip states for the scene bank, and mute, selected track inverted.
    private func trackStrip(_ s: inout Screen) {
        let colW = 32
        for (t, tr) in song.tracks.prefix(8).enumerated() {
            let x = t * colW
            s.text(String(tr.name.prefix(4)), x: x + 2, y: 18)
            // Level bar.
            s.frameRect(x + 2, 28, colW - 6, 7)
            s.fillRect(x + 3, 29, Int(Double(colW - 8) * tr.volume), 5)
            // Clip dots, one per scene: filled = has notes.
            for scene in 0..<8 {
                let dx = x + 2 + scene * 3
                if tr.clips.indices.contains(scene) && !tr.clips[scene].isEmpty {
                    s.fillRect(dx, 40, 2, 4)
                } else {
                    s.frameRect(dx, 40, 2, 4)
                }
            }
            if tr.muted { s.text("M", x: x + 22, y: 50) }
            if t == song.selectedTrack {
                s.invertRegion(x, 16, colW - 2, 44)
            }
        }
        s.hline(0, 62, 256)
    }

    private func selectedDetail(_ s: inout Screen) {
        let soundName = track.auName ?? (track.kind == .drum
            ? (DrumKits.names.indices.contains(track.soundIndex) ? DrumKits.names[track.soundIndex] : "KIT")
            : SynthPreset.all[track.soundIndex % SynthPreset.all.count].name)
        s.text("T\(song.selectedTrack + 1)", x: 4, y: 68)
        if let presetName = track.auPresetName {
            s.text(String(presetName.prefix(16)), x: 40, y: 68)
        }
        s.text(String(soundName.prefix(20)), x: 4, y: 80, size: 2)
        if engine.hasAU(track: song.selectedTrack) {
            // Knob map: E1 = VOL, E2-E8 = the active parameter bank.
            let params = engine.auParameters(track: song.selectedTrack)
            let bank = auParamBank[song.selectedTrack] ?? 0
            var slots = ["VOL"]
            for i in 0..<7 {
                let pIdx = bank * 7 + i
                slots.append(params.indices.contains(pIdx)
                             ? String(params[pIdx].displayName.prefix(6)) : "-")
            }
            for (i, name) in slots.enumerated() {
                s.text(name, x: 4 + (i % 4) * 64, y: 92 + (i / 4) * 9)
            }
            let banks = max(1, (params.count + 6) / 7)
            if banks > 1 { s.text("B\(bank + 1)/\(banks)", x: 224, y: 68) }
        } else {
            let info = track.kind == .synth
                ? "\(Scales.noteNames[song.rootNote]) \(Scales.all[song.scaleIndex].name)  OCT \(track.octave >= 0 ? "+" : "")\(track.octave)"
                : "PAD \(track.selectedPad + 1)"
            s.text(info, x: 4, y: 99)
        }
    }

    private func footer(_ s: inout Screen) {
        s.hline(0, 109, 256)
        let clip = track.clips[song.selectedScene]
        if engine.isPlaying {
            let step = clip.localStep(Int(engine.currentStep))
            s.text("\(step / 16 + 1).\(step % 16 / 4 + 1)", x: 228, y: 116)
        } else {
            s.text("\(clip.bars)BAR", x: 224, y: 116)
        }
        // Loop-length lines with playhead tick (manual 12.1).
        let bars = clip.bars
        let loopFrom = clip.loopStartStep / 16
        let slots = min(8, bars + (bars < 8 ? 1 : 0))
        let slotW = 216 / slots
        for b in 0..<slots {
            let x = b * slotW + 2
            if b >= bars {
                s.text("+", x: x + slotW / 2 - 3, y: 116)
            } else if b == barPage {
                s.fillRect(x, 120, slotW - 4, 5)
            } else if b >= loopFrom {
                s.fillRect(x, 122, slotW - 4, 2)
            } else {
                s.fillRect(x, 123, slotW - 4, 1) // in the clip, outside the loop
            }
        }
        if engine.isPlaying {
            let region = Double(clip.loopSteps)
            let local = Double(clip.loopStartStep)
                + engine.currentStep.truncatingRemainder(dividingBy: region)
            let x = Int(local / Double(clip.steps) * Double(bars * slotW))
            s.fillRect(min(213, x), 117, 2, 10)
        }
    }

    // MARK: - LEDs

    private func refreshLeds() {
        var colors: [Int: SIMD3<Double>] = [:]
        var channels: [Int: Int] = [:]

        switch mode {
        case .setOverview:
            let saved = Set((0..<64).filter { FileManager.default.fileExists(atPath: Self.slotURL($0).path) })
            for i in 0..<64 {
                let note = Self.padNote(i)
                if i == currentSlot {
                    colors[note] = SIMD3(1, 1, 1)
                    channels[note] = 9
                } else if saved.contains(i) {
                    colors[note] = Self.trackColors[i % 8] * 0.8
                }
            }
        case .session:
            for t in 0..<min(8, song.tracks.count) {
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
                for row in 4..<8 {
                    for col in 0..<4 {
                        let cell = (7 - row) * 4 + col
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
                        let p = (7 - row) * 4 + (col - 4)
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
                for i in 0..<64 {
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
            let playStep = engine.isPlaying ? clip.localStep(Int(engine.currentStep)) : -1
            // Steps covered by a note's length glow brighter (manual 11.3).
            var tailSteps = Set<Int>()
            for n in clip.notes where n.lengthSteps > 1
                && (editKey == nil || n.key == editKey) {
                let last = n.step + Int(n.lengthSteps.rounded(.up)) - 1
                for s in (n.step + 1)...max(n.step + 1, last) { tailSteps.insert(s % clip.steps) }
            }
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
                } else if tailSteps.contains(absStep) {
                    colors[note] = SIMD3(0.38, 0.38, 0.36)
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

        // Loop Mode overrides the step row: steps are bars (manual 12.1) —
        // white = selected bar, track color = in the loop, dim = outside.
        if menu == .loopLength && mode == .note {
            let clip = track.clips[song.selectedScene]
            let loopFrom = clip.loopStartStep / 16
            for i in 0..<16 {
                if i == barPage {
                    colors[Self.stepNote(i)] = SIMD3(0.95, 0.95, 0.92)
                } else if i >= loopFrom && i < clip.bars {
                    colors[Self.stepNote(i)] = trackColor
                } else if i < clip.bars {
                    colors[Self.stepNote(i)] = trackColor * 0.15 // in clip, outside loop
                } else {
                    colors[Self.stepNote(i)] = SIMD3(0.05, 0.05, 0.05)
                }
            }
        }

        // Track buttons.
        for t in 0..<min(8, song.tracks.count) {
            let base = Self.trackColors[t]
            let level: Double = song.tracks[t].muted ? 0.08 : (t == song.selectedTrack ? 1.0 : 0.35)
            colors[Self.trackNotes[t]] = base * level
        }

        // Function button LEDs.
        var ccs: [Int: Int] = [:]
        ccs[Self.buttonCC["play"]!] = engine.isPlaying ? 127 : 24
        ccs[Self.buttonCC["record"]!] = recording ? 127 : 24
        ccs[Self.buttonCC["note"]!] = 60
        ccs[Self.buttonCC["shift"]!] = shiftLocked ? 127 : (shiftHeld ? 100 : 24)
        ccs[Self.buttonCC["mute"]!] = muteHeld ? 127 : 24
        ccs[Self.buttonCC["delete"]!] = deleteHeld ? 127 : 24
        ccs[Self.buttonCC["copy"]!] = copyHeld ? 127 : 24
        ccs[Self.buttonCC["undo"]!] = undoStack.isEmpty ? 8 : 40
        ccs[Self.buttonCC["loop"]!] = menu == .loopLength ? 127 : 24
        ccs[Self.buttonCC["back"]!] = (menu != .none || mode == .setOverview) ? 60 : 12
        let bars = track.clips[song.selectedScene].bars
        let maxPage = bars < 8 ? bars : bars - 1
        ccs[Self.buttonCC["left"]!] = (barPage > 0 || !heldSteps.isEmpty) ? 40 : 8
        ccs[Self.buttonCC["right"]!] = (barPage < maxPage || !heldSteps.isEmpty) ? 40 : 8
        ccs[Self.buttonCC["minus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["plus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["capture"]!] = captureBuffer.isEmpty ? 12 : 90
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
        return 0x7c - row * 8 + col
    }

    static func stepNote(_ index: Int) -> Int { 0x10 + index }

    static let trackNotes = [0x2b, 0x2a, 0x29, 0x28, 0x27, 0x26, 0x25, 0x24]

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
