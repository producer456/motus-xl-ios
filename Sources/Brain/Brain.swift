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
    /// 0 = hardware chassis, 1 = bare glass, 2 = vintage (walnut + charcoal).
    @Published var themeStyle = UserDefaults.standard.object(forKey: "theme.style") == nil
        ? (UserDefaults.standard.bool(forKey: "theme.bare") ? 1 : 0)
        : UserDefaults.standard.integer(forKey: "theme.style")
    var bareTheme: Bool { themeStyle == 1 }
    /// Simulated power state (manual 2: power press → wheel confirms off).
    @Published var poweredOn = true
    /// Native AUv3 plugin view, presented as a sheet when non-nil.
    @Published var auSheetVC: UIViewController?
    /// Plugin icons per track, for the glass display.
    @Published var auIcons: [Int: UIImage] = [:]
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
        case auPresets, powerConfirm, repeatMenu
        case setColor(Int)   // Shift+pad in Set Overview
        case message(String)
    }
    private var menu = Menu.none
    private var browserIndex = 0
    private var scaleRow = 0   // scale menu: 0 layout, 1 key, 2 scale

    // Workflow settings (manual ch 13) — device settings, persisted outside the song.
    private var countInOn = UserDefaults.standard.bool(forKey: "wf.countIn")
    private var autoloadOn = UserDefaults.standard.bool(forKey: "wf.autoload")
    private var workflowRow = 0   // 0 quantize, 1 count-in, 2 autoload
    /// Record-quantize amount, hardware default 50% (manual 13.1): notes are
    /// pulled halfway to the nearest 1/16 — tight but human.
    private var quantizePercent = UserDefaults.standard.object(forKey: "wf.quantize") == nil
        ? 50 : UserDefaults.standard.integer(forKey: "wf.quantize")
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
    private var shiftPressedAt: Date?
    private var muteHeld = false
    private var deleteHeld = false
    private var copyHeld = false
    private var copyUsed = false            // a copy+target combo fired
    private var copiedClip: Clip?
    /// Steps clipboard (manual 11.8): notes rebased to 0, plus the span so
    /// ranges paste in sequence. Bars copy as a 16-step range.
    private var copiedSteps: (notes: [Note], span: Int)?
    private var copyAnchor: Int?            // range copy: first step pressed
    private var copiedSetSlot: Int?         // Set Overview clipboard
    private var pendingSetPaste: (src: Int, dst: Int)?
    private var pendingSetDelete: Int?
    private var selectedOverviewSlot = 0    // manual 6.1: select, then load
    private var heldSetPads: Set<Int> = []  // pad-hold + Volume = set volume

    // Manual 9.5 sequencing state: pad-then-step / step-then-pad note entry.
    private var heldPads: [Int: Int] = [:]     // melodic pad index -> MIDI note
    private var heldDrumCells: Set<Int> = []    // drum cells under fingers
    private var heldTracks: Set<Int> = []       // track buttons held (vol gesture)
    private var muteDownAt: Date?
    private var muteUsed = false                // a mute+target combo fired
    private var notePressAt: Date?              // mode-toggle hold preview
    private var modeBeforeOverview: Mode = .note
    /// Pending nav press for long-press variants (octave / full-step nudge).
    private var pendingNav: (id: String, at: Date)?
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
        var pitch: Int? = nil     // 16 Pitches semitone offset
    }
    private var captureBuffer: [CapturedNote] = []
    private var captureOpen: [Int: Int] = [:]  // track*1000+key -> buffer index

    // 16 Pitches (manual 9.2): right 4x4 plays the selected cell repitched.
    private var sixteenPitches = false
    // Repeat / Arp (manual 11.6): Shift+Step 11. Chain fires held pads at
    // the rate; melodic tracks add Up/Down/Random arp styles.
    private var repeatActive = false
    private var repeatRateIdx = 3
    private var repeatStyle = 0        // 0 repeat, 1 up, 2 down, 3 random
    private var repeatRow = 0          // menu row: 0 style, 1 rate
    private var repeatArpPos = 0
    private var repeatChainArmed = false
    static let repeatRates: [(name: String, steps: Double)] = [
        ("1/4", 4), ("1/8", 2), ("1/8T", 4.0 / 3),
        ("1/16", 1), ("1/16T", 2.0 / 3), ("1/32", 0.5),
    ]
    private var recording = false
    /// Recording began into an empty clip: it grows under the playhead
    /// instead of wrapping (manual: extending recording), up to 16 bars.
    private var recordExtendTarget: (track: Int, scene: Int)?
    private var fullVelocity = false
    private var metronomeOn = false
    private var mainVolume: Double = 0.85
    private var barPage = 0
    /// Session mode: which Set effect the wheel has focused (0 Dyn, 1 Sat).
    private var fxFocus = 0
    /// Lanes currently under a finger (automation touch-override, 14.2).
    private var touchedLanes: Set<String> = []

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
    static let legendSteps = [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15]

    // MARK: - Lifecycle

    func start() {
        engine.start()
        engine.onGraphRebuilt = { [weak self] in self?.reinstallAUs() }
        engine.setAllPlayingScenes(song.selectedScene)
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
        guard poweredOn else { return }
        if let nav = pendingNav, Date().timeIntervalSince(nav.at) > 0.55 {
            pendingNav = nil
            switch nav.id {
            case "plus": transposeHeldSteps(by: 12)
            case "minus": transposeHeldSteps(by: -12)
            case "left": nudgeHeldSteps(by: -1.0)
            case "right": nudgeHeldSteps(by: 1.0)
            default: break
            }
        }
        if overlay != nil && Date() > overlayUntil {
            overlay = nil
            refresh()
            return
        }
        guard engine.isPlaying else { return }
        if !engine.inCountIn { applyAUAutomation() }
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

    private func captureAUIcon(desc: AudioComponentDescription, track: Int) {
        var wildcard = desc
        guard let component = AVAudioUnitComponentManager.shared()
            .components(matching: wildcard).first else { auIcons[track] = nil; return }
        _ = wildcard
        auIcons[track] = AudioComponentGetIcon(component.audioComponent, 88)
    }

    private func selectAU(_ component: AVAudioUnitComponent, forTrack trackIndex: Int) {
        let desc = component.audioComponentDescription
        let id = "\(desc.componentType):\(desc.componentSubType):\(desc.componentManufacturer)"
        showOverlay("LOADING", 0.5, String(component.name.prefix(20)))
        Task { @MainActor in
            do {
                let name = try await engine.installAU(track: trackIndex, description: desc)
                captureAUIcon(desc: desc, track: trackIndex)
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
                        captureAUIcon(desc: desc, track: t)
                        auParamBank[t] = 0
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
                auIcons[t] = nil
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
        guard poweredOn else { return }
        let vel = fullVelocity ? 127 : velocity
        switch mode {
        case .setOverview:
            if down { setOverviewPad(index) } else { heldSetPads.remove(index) }
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
                if !down {
                    heldDrumCells.remove(cell)
                    return
                }
                if down {
                    if deleteHeld {
                        edit { $0.tracks[$0.selectedTrack].clips[$0.selectedScene].notes.removeAll { $0.key == cell } }
                        return
                    }
                    if muteHeld {
                        muteUsed = true
                        edit {
                            var cells = $0.tracks[$0.selectedTrack].mutedCells
                            if cells.contains(cell) { cells.remove(cell) } else { cells.insert(cell) }
                            $0.tracks[$0.selectedTrack].mutedCells = cells
                        }
                        return
                    }
                    adjust { $0.tracks[$0.selectedTrack].selectedPad = cell }
                    if barEditActive {
                        loopModeEdited = true
                        insertNotes([cell], atSteps: Array(heldAbsSteps()).sorted(), velocity: velocity)
                        return
                    }
                    heldDrumCells.insert(cell)
                    if repeatActive {
                        startRepeatChain()   // the chain fires it at the rate
                        refreshLeds()
                        return
                    }
                    engine.liveNote(track: song.selectedTrack, kind: .drum, key: cell,
                                    velocity: velocity, on: true)
                    captureNoteOn(key: cell, velocity: velocity)
                    // Step-then-pad works for drums too (manual 9.5/11.9).
                    if !heldSteps.isEmpty {
                        let clipSteps = track.clips[song.selectedScene].steps
                        let targets = heldSteps.map { barPage * 16 + $0 }
                        insertNotes([cell], atSteps: targets, velocity: velocity,
                                    extendTo: targets.contains { $0 >= clipSteps } ? barPage + 1 : nil)
                        stepEntryUsed.formUnion(heldSteps)
                    }
                    recordHit(key: cell, velocity: velocity)
                }
            } else if down {
                // 16 Pitches (manual 9.2): toggled via Shift+Step 8; the 16
                // right pads play the selected cell across the active layout.
                guard sixteenPitches, !deleteHeld, !muteHeld else { return }
                let p = (7 - row) * 4 + (col - 4)
                let offset = pitchPadNote(p) - 60
                let rate = Float(pow(2.0, Double(offset) / 12))
                engine.liveNote(track: song.selectedTrack, kind: .drum,
                                key: track.selectedPad, velocity: velocity, on: true, rate: rate)
                captureNoteOn(key: track.selectedPad, velocity: velocity, pitch: offset)
                recordHit(key: track.selectedPad, velocity: velocity, pitch: offset)
            }
        } else {
            let scale = Scales.all[song.scaleIndex].steps
            let note = Scales.padToNote(index, root: song.rootNote, scale: scale,
                                        octave: track.octave, chromatic: song.chromatic ?? false)
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
            if barEditActive {
                // Manual 11.9: held bar-step + pad fills the bar with the note.
                loopModeEdited = true
                insertNotes([note], atSteps: Array(heldAbsSteps()).sorted(), velocity: velocity)
                return
            }
            if repeatActive {
                heldPads[index] = note
                startRepeatChain()   // staccato hits at the rate, no sustain
                refreshLeds()
                return
            }
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

    /// Pull an exact (fractional) step position `amount` of the way to the
    /// nearest grid line, wrapped into `region` steps starting at `start`.
    /// Returns the note's floor step + fractional offset.
    private func quantized(_ exact: Double, start: Int, region: Int) -> (step: Int, offset: Double?) {
        let amount = Double(quantizePercent) / 100
        let nearest = exact.rounded()
        var q = exact + (nearest - exact) * amount
        let end = Double(start + region)
        if q >= end { q -= Double(region) }
        if q < Double(start) { q = Double(start) }
        var step = Int(q)
        var off = q - Double(step)
        if off > 0.98 { // effectively ON the next grid line — round up, wrapped
            step += 1
            if step >= start + region { step = start }
            off = 0
        }
        return (step, off < 0.02 ? nil : off)
    }

    private func recordHit(key: Int, velocity: Int, pitch: Int? = nil) {
        guard recording, engine.isPlaying, !engine.inCountIn else { return }
        var clip = track.clips[song.selectedScene]
        // Extending record: an empty clip grows under the playhead (whole
        // bars) rather than wrapping, until Record stops or the 16-bar cap.
        if let target = recordExtendTarget,
           target == (song.selectedTrack, song.selectedScene) {
            let needed = min(16, Int(engine.currentStep) / 16 + 1)
            if needed > clip.bars { clip.bars = needed }
        }
        // Hardware-default quantize (manual 13.1): pull the hit `amount` of
        // the way to the nearest 1/16, keeping the rest as a fractional
        // offset. The engine suppresses re-firing just-played notes, so
        // forward pulls can't flam against the live hit.
        let pos = engine.currentStep
        let region = clip.loopSteps
        let localExact = Double(clip.loopStartStep)
            + pos.truncatingRemainder(dividingBy: Double(region))
        let (step, off) = quantized(localExact, start: clip.loopStartStep, region: region)
        pendingRecordings[key] = (step, pos)
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            c.bars = max(c.bars, clip.bars)
            c.notes.removeAll { $0.step == step && $0.key == key && $0.pitch == pitch }
            c.notes.append(Note(step: step, key: key, velocity: velocity,
                                lengthSteps: 1, offset: off, pitch: pitch))
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
        // Selection change under an open browser = stale-list commits.
        if menu == .browser { cancelBrowserPreview(); menu = .none }
        if menu == .auPresets { cancelAUPresetPreview(); menu = .none }
        if deleteHeld {
            edit { $0.tracks[trackIndex].clips[scene] = Clip() }
            return
        }
        if copyHeld {
            copyUsed = true
            copiedClip = song.tracks[trackIndex].clips[scene]
            showOverlay("COPY", 1, "CLIP COPIED")
            return
        }
        if let clip = copiedClip {
            edit { $0.tracks[trackIndex].clips[scene] = clip }
            copiedClip = nil
            return
        }
        // Manual 17.1.2: a pad launches THAT track's clip, quantized to the
        // next bar; Shift+pad selects without launching; an empty slot stops
        // the track. Selection follows the launch.
        adjust {
            $0.selectedTrack = trackIndex
            $0.selectedScene = scene
        }
        guard !shiftHeld else { return }
        if song.tracks[trackIndex].clips[scene].isEmpty {
            engine.stopTrack(trackIndex)
        } else {
            engine.launchClip(track: trackIndex, scene: scene)
            if !engine.isPlaying {
                purgeGridCapture()
                engine.setTransport(playing: true, fromStart: true)
            }
        }
    }

    private func setOverviewPad(_ index: Int) {
        heldSetPads.insert(index)
        let exists = FileManager.default.fileExists(atPath: Self.slotURL(index).path)
            || index == currentSlot
        if deleteHeld {
            // Manual 6.1.5: deletion needs a second press to confirm.
            if pendingSetDelete == index {
                pendingSetDelete = nil
                try? FileManager.default.removeItem(at: Self.slotURL(index))
                UserDefaults.standard.removeObject(forKey: "setColor.\(index)")
                if index == currentSlot {
                    // Otherwise the in-memory song auto-saves it right back.
                    song = Song()
                    song.name = "Set \(index + 1)"
                    engine.update(song: song)
                }
                showOverlay("DELETE", 0, "SET \(index + 1) DELETED")
            } else if exists {
                pendingSetDelete = index
                showOverlay("DELETE", 0.5, "PRESS AGAIN TO DELETE \(index + 1)")
            }
            refresh()
            return
        }
        pendingSetDelete = nil
        if copyHeld {
            guard exists else { return }
            copyUsed = true
            saveCurrentSet()
            copiedSetSlot = index
            pendingSetPaste = nil
            showOverlay("COPY", 1, "SET \(index + 1) COPIED")
            return
        }
        if let src = copiedSetSlot, src != index {
            // Manual 6.1.4: pasting over an existing Set needs confirmation.
            let occupied = FileManager.default.fileExists(atPath: Self.slotURL(index).path)
            if occupied, pendingSetPaste?.dst != index {
                pendingSetPaste = (src, index)
                showOverlay("PASTE", 0.5, "PRESS AGAIN TO OVERWRITE \(index + 1)")
                return
            }
            pendingSetPaste = nil
            try? FileManager.default.removeItem(at: Self.slotURL(index))
            try? FileManager.default.copyItem(at: Self.slotURL(src), to: Self.slotURL(index))
            let color = UserDefaults.standard.object(forKey: "setColor.\(src)") as? Int ?? src % 8
            UserDefaults.standard.set(color, forKey: "setColor.\(index)")
            if index == currentSlot, let loaded = Self.loadSet(slot: index) {
                song = Self.migrated(loaded)
                engine.update(song: song)
            }
            copiedSetSlot = nil
            showOverlay("PASTE", 1, "SET PASTED TO \(index + 1)")
            refresh()
            return
        }
        if shiftHeld {
            guard exists else { return }
            menu = .setColor(index)
            refresh()
            return
        }
        // Manual 6.1: a pad press selects; Play previews; a track button,
        // Back, or the Note toggle opens the Set.
        selectedOverviewSlot = index
        refresh()
    }

    /// Load a Set slot into the engine (stays in whatever mode we're in).
    private func loadSlot(_ index: Int) {
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
        copiedSteps = nil
        clearEntryState()
        engine.resetMacros()
        for (i, t) in song.tracks.enumerated() where t.kind == .drum {
            loadKit(track: i, index: t.soundIndex)
        }
        reinstallAUs()
        engine.update(song: song)
        engine.setAllPlayingScenes(song.selectedScene)
        engine.setTransport(playing: false, fromStart: true)
        recording = false
        engine.setRecordingActive(false)
        refresh()
    }

    // MARK: - Surface API: steps

    func step(_ index: Int, down: Bool) {
        guard poweredOn else { return }
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
            let t = index / 2
            if index % 2 == 0 {
                if song.tracks.indices.contains(t) { trackButton(t) }
            } else if song.tracks.indices.contains(t) {
                engine.stopTrack(t)
                showOverlay("TRACK \(t + 1)", 0, "STOP QUEUED")
            }
        case .setOverview:
            break
        case .note:
            // Loop Mode (manual 12.1): steps are bars. Press start+end
            // together (or hold start, press end) to set the loop region;
            // double-press = loop that single bar; brief press selects it.
            if menu == .loopLength {
                if deleteHeld {
                    // Manual 12.4: Delete + bar step clears the bar's notes.
                    loopModeEdited = true
                    edit { song in
                        song.tracks[song.selectedTrack].clips[song.selectedScene]
                            .notes.removeAll { $0.step / 16 == index }
                    }
                    showOverlay("BAR \(index + 1)", 0, "NOTES DELETED")
                    return
                }
                if copyHeld {
                    copyUsed = true
                    copySteps(from: index * 16, to: index * 16 + 15)
                    showOverlay("BAR \(index + 1)", 1, "COPIED")
                    return
                }
                if copiedSteps != nil {
                    pasteSteps(at: index * 16)
                    return
                }
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
            // Copy/paste (manual 11.8): held Copy arms; a second press while
            // holding sets a range; with a loaded clipboard, steps paste.
            if copyHeld {
                copyUsed = true
                if let anchor = copyAnchor {
                    copySteps(from: min(anchor, step), to: max(anchor, step))
                } else {
                    copyAnchor = step
                    copySteps(from: step, to: step)
                }
                return
            }
            if copiedSteps != nil {
                pasteSteps(at: step)
                return
            }
            // Adding notes to the empty extra bar extends the loop (12.1).
            let extendsBar = step >= clip.steps && barPage >= clip.bars && clip.bars < 16
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

    /// Copy notes in [from...to] (abs steps), rebased to 0 (manual 11.8).
    /// Drum tracks scope to the selected cell, like the step LEDs.
    private func copySteps(from: Int, to: Int) {
        let drumKey = track.kind == .drum ? track.selectedPad : nil
        let notes = track.clips[song.selectedScene].notes
            .filter { $0.step >= from && $0.step <= to && (drumKey == nil || $0.key == drumKey) }
            .map { n -> Note in var m = n; m.step -= from; return m }
        copiedSteps = (notes, to - from + 1)
        showOverlay("COPY", 1, notes.isEmpty ? "EMPTY RANGE" : "NOTES COPIED")
    }

    /// Paste the clipboard starting at an absolute step, extending the loop
    /// (whole bars, max 16) when the range runs past the end.
    private func pasteSteps(at dest: Int) {
        guard let clipboard = copiedSteps else { return }
        let lastStep = dest + clipboard.span - 1
        let neededBars = min(16, lastStep / 16 + 1)
        guard dest < 16 * 16 else { return }
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            if neededBars > c.bars { c.bars = neededBars }
            for n in clipboard.notes {
                let step = dest + n.step
                guard step < c.steps else { continue }
                c.notes.removeAll { $0.step == step && $0.key == n.key && $0.pitch == n.pitch }
                var m = n; m.step = step
                c.notes.append(m)
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("PASTE", 1, "NOTES PASTED")
    }

    /// Bare Copy press (manual 12.3): duplicate the clip into the next empty
    /// slot and select it.
    private func duplicateClip() {
        let clip = track.clips[song.selectedScene]
        guard !clip.isEmpty else { return }
        guard let empty = (0..<8).first(where: { track.clips[$0].isEmpty }) else {
            showOverlay("COPY", 1, "ALL SLOTS USED")
            return
        }
        edit { song in
            song.tracks[song.selectedTrack].clips[empty] = clip
            song.selectedScene = empty
        }
        engine.setAllPlayingScenes(empty)
        barPage = 0
        showOverlay("COPY", 1, "CLIP DUPLICATED TO S\(empty + 1)")
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
            c.bars = min(16, max(1, endBar))
            c.loopStart = start > 0 ? start : nil
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        barPage = min(max(barPage, start), endBar - 1)
        let length = endBar - start
        showOverlay("LOOP \(start + 1)-\(endBar)", Double(endBar) / 16,
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
        heldDrumCells.removeAll()
        heldSteps.removeAll()
        stepEntryUsed.removeAll()
    }

    /// Apply the quantize amount to the selected clip's notes (manual 11.7).
    private func quantizeClip() {
        guard !track.clips[song.selectedScene].isEmpty else {
            showOverlay("QUANTIZE", 0, "EMPTY CLIP")
            return
        }
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            let amount = Double(quantizePercent) / 100
            for i in c.notes.indices {
                let exact = Double(c.notes[i].step) + c.notes[i].off
                let nearest = exact.rounded()
                var q = exact + (nearest - exact) * amount
                if q >= Double(c.steps) { q -= Double(c.steps) }
                if q < 0 { q = 0 }
                c.notes[i].step = Int(q)
                let off = q - Double(Int(q))
                c.notes[i].offset = (off < 0.02 || off > 0.98) ? nil : off
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("QUANTIZE", Double(quantizePercent) / 100, "\(quantizePercent)% APPLIED")
    }

    private func shiftStep(_ index: Int) {
        cancelBrowserPreview()   // any menu jump abandons an autoload preview
        cancelAUPresetPreview()
        if menu == .loopLength { clearLoopModeLatches() }
        switch index {
        case 0:
            if mode != .setOverview { modeBeforeOverview = mode }
            selectedOverviewSlot = currentSlot
            heldSetPads.removeAll()
            pendingSetDelete = nil; pendingSetPaste = nil
            mode = .setOverview; menu = .none; refresh()
        case 1: menu = .setup; refresh()
        case 2: menu = .workflow; refresh()
        case 4: menu = .tempo; refresh()
        case 5:
            metronomeOn.toggle()
            engine.setMetronome(metronomeOn)
            menu = .metronome
            refresh()
        case 6: menu = .groove; refresh()
        case 7: // 16 Pitches toggle (manual 9.2)
            guard track.kind == .drum else {
                showOverlay("16 PITCHES", 0, "DRUM TRACKS ONLY"); break
            }
            sixteenPitches.toggle()
            showOverlay("16 PITCHES", sixteenPitches ? 1 : 0, sixteenPitches ? "ON" : "OFF")
        case 8: menu = .scale; refresh()
        case 9:
            fullVelocity.toggle()
            showOverlay("FULL VELOCITY", fullVelocity ? 1 : 0, fullVelocity ? "ON" : "OFF")
        case 10: // Repeat / Arp (manual 11.6)
            repeatActive.toggle()
            repeatArpPos = 0
            menu = repeatActive ? .repeatMenu : .none
            if !repeatActive { showOverlay("REPEAT", 0, "OFF") }
            refresh()
        case 14: // double loop (pre-check so a no-op doesn't pollute undo)
            guard track.clips[song.selectedScene].bars * 2 <= 16 else { break }
            edit { song in
                var clip = song.tracks[song.selectedTrack].clips[song.selectedScene]
                let old = clip.notes
                clip.notes += old.map { n in
                    var m = n; m.step += clip.bars * 16; return m
                }
                clip.bars *= 2
                song.tracks[song.selectedTrack].clips[song.selectedScene] = clip
            }
        case 13: // Prepare next available clip slot (manual shift table).
            guard !track.clips[song.selectedScene].isEmpty else { break }
            if let empty = (0..<8).first(where: { track.clips[$0].isEmpty }) {
                adjust { $0.selectedScene = empty }
                engine.setAllPlayingScenes(empty)
                barPage = 0
                showOverlay("CLIP SLOT", Double(empty + 1) / 8, "SCENE \(empty + 1) READY")
            } else {
                showOverlay("CLIP SLOT", 1, "ALL SLOTS USED")
            }
        case 15: // Quantize the clip (manual 11.7).
            quantizeClip()
        default:
            break
        }
    }

    // MARK: - Surface API: buttons

    func button(_ id: String, down: Bool) {
        if id == "power" {
            if down { powerButton() }
            return
        }
        guard poweredOn else { return }
        switch id {
        case "shift":
            if down {
                if shiftLocked {
                    shiftLocked = false
                    shiftHeld = false
                    // The unlock tap must not arm the double-tap detector,
                    // or unlocking + quickly using shift re-locks instantly.
                    lastShiftTap = nil
                    shiftPressedAt = nil
                    showOverlay("SHIFT", 0, "UNLOCKED")
                } else {
                    shiftHeld = true
                    shiftPressedAt = Date()
                    if let tap = lastShiftTap, Date().timeIntervalSince(tap) < 0.4 {
                        shiftLocked = true
                        showOverlay("SHIFT", 1, "LOCKED")
                    }
                }
            } else if !shiftLocked {
                shiftHeld = false
                // Only a brief tap arms the double-tap lock — a shift+combo
                // hold followed by a quick tap must not lock.
                if let at = shiftPressedAt, Date().timeIntervalSince(at) < 0.35 {
                    lastShiftTap = Date()
                } else {
                    lastShiftTap = nil
                }
                shiftPressedAt = nil
            }
        case "mute":
            muteHeld = down
            if down {
                muteDownAt = Date()
                muteUsed = false
            } else if !muteUsed, let at = muteDownAt,
                      Date().timeIntervalSince(at) < 0.4 {
                // Bare Mute press mutes the selected track (manual 16.3).
                edit { $0.tracks[$0.selectedTrack].muted.toggle() }
                showOverlay("TRACK \(song.selectedTrack + 1)",
                            track.muted ? 1 : 0, track.muted ? "MUTED" : "UNMUTED")
            }
        case "delete": deleteHeld = down
        case "copy":
            copyHeld = down
            if down {
                copyUsed = false
                copyAnchor = nil
            } else {
                copyAnchor = nil
                if !copyUsed {
                    if copiedSteps != nil || copiedClip != nil || copiedSetSlot != nil {
                        // Manual 11.8: pressing Copy again clears the clipboard.
                        copiedSteps = nil; copiedClip = nil; copiedSetSlot = nil
                        pendingSetPaste = nil
                        showOverlay("COPY", 0, "CLIPBOARD CLEARED")
                    } else if mode == .note {
                        duplicateClip()   // manual 12.3: bare Copy press
                    }
                }
            }
        case let id where id.hasPrefix("track"):
            if let n = Int(id.dropFirst(5)) {
                if down {
                    heldTracks.insert(n - 1)
                    trackButton(n - 1)
                } else {
                    heldTracks.remove(n - 1)
                }
            }
        case "play":
            if down {
                if mode == .setOverview {
                    // Manual 6.1: Play previews the selected Set.
                    if selectedOverviewSlot != currentSlot { loadSlot(selectedOverviewSlot) }
                    togglePlay(restart: false)
                } else {
                    togglePlay(restart: shiftHeld)
                }
            }
        case "record":
            if down { toggleRecord() }
        case "undo":
            if down { shiftHeld ? redo() : undo() }
        case "note":
            if down {
                if mode == .setOverview, selectedOverviewSlot != currentSlot {
                    loadSlot(selectedOverviewSlot)
                }
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
        case "left", "right", "minus", "plus":
            // With steps held, short press acts on release; a 0.55 s hold
            // fires the long variant (octave / full-step nudge, manual 11.2/11.4).
            if down {
                if !heldSteps.isEmpty || barEditActive {
                    pendingNav = (id, Date())
                } else {
                    switch id {
                    case "left": leftRight(-1)
                    case "right": leftRight(1)
                    case "minus": octave(-1)
                    default: octave(1)
                    }
                }
            } else if let nav = pendingNav, nav.id == id {
                pendingNav = nil
                switch id {
                case "left": leftRight(-1)
                case "right": leftRight(1)
                case "minus": octave(-1)
                default: octave(1)
                }
            }
        case "quantize":
            if down { quantizeClip() }
        case "auview":
            if down {
                guard engine.hasAU(track: song.selectedTrack) else {
                    showOverlay("PLUGIN VIEW", 0, "NO AU ON TRACK")
                    break
                }
                let t = song.selectedTrack
                Task { @MainActor in
                    if let vc = await engine.auViewController(track: t) {
                        auSheetVC = vc
                    } else {
                        showOverlay("PLUGIN VIEW", 0, "NONE PROVIDED")
                    }
                }
            }
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
            muteUsed = true
            edit { $0.tracks[index].muted.toggle() }
        } else {
            if menu == .browser { cancelBrowserPreview(); menu = .none } // stale list would commit a random sound
            clearEntryState()
            if recording, index != song.selectedTrack {
                // Manual: switching tracks ends the recording pass.
                recording = false
                engine.setRecordingActive(false)
                pendingRecordings.removeAll()
                recordExtendTarget = nil
            }
            if mode == .setOverview, selectedOverviewSlot != currentSlot {
                loadSlot(selectedOverviewSlot)
            }
            adjust { $0.selectedTrack = min(index, song.tracks.count - 1) }
            barPage = 0
            if mode == .setOverview { mode = .note }
        }
    }

    private func togglePlay(restart: Bool) {
        if engine.isPlaying && !restart {
            engine.setTransport(playing: false)
            recording = false
            engine.setRecordingActive(false)
            pendingRecordings.removeAll()
            recordExtendTarget = nil
        } else {
            purgeGridCapture()
            engine.setTransport(playing: true, fromStart: true)
        }
        refresh()
    }

    private func toggleRecord() {
        if engine.isPlaying {
            recording.toggle()
            engine.setRecordingActive(recording)
            if !recording { pendingRecordings.removeAll() }
            recordExtendTarget = recording && track.clips[song.selectedScene].isEmpty
                ? (song.selectedTrack, song.selectedScene) : nil
        } else {
            recording = true
            recordExtendTarget = track.clips[song.selectedScene].isEmpty
                ? (song.selectedTrack, song.selectedScene) : nil
            engine.setRecordingActive(true)
            purgeGridCapture()
            // Count-in (manual 13.3): one bar of clicks before sequencing starts.
            engine.setTransport(playing: true, fromStart: true,
                                countInSteps: countInOn ? 16 : 0)
        }
        refresh()
    }

    /// Leaving the AU preset browser without committing: restore the preset
    /// that was active when it opened.
    private func cancelAUPresetPreview() {
        if menu == .auPresets, let original = auPresetOriginal {
            engine.setAUPreset(track: song.selectedTrack, preset: original)
        }
        auPresetOriginal = nil
    }

    /// Loop Mode latches must not survive leaving Loop Mode.
    private func clearLoopModeLatches() {
        loopModeHeld.removeAll()
        loopModeEdited = false
        lastLoopTap = nil
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
        copiedSteps = nil
        copiedSetSlot = nil
        pendingSetPaste = nil
        pendingSetDelete = nil
        cancelAUPresetPreview()
        if menu == .loopLength { clearLoopModeLatches() }
        if menu != .none {
            cancelBrowserPreview()
            menu = .none
        } else if mode == .setOverview {
            if selectedOverviewSlot != currentSlot { loadSlot(selectedOverviewSlot) }
            mode = modeBeforeOverview
        }
        refresh()
    }

    private func leftRight(_ direction: Int) {
        guard mode == .note else { return }
        // Step-hold + arrows = nudge notes by 10% of a step (Shift: 1%).
        if !heldSteps.isEmpty || barEditActive {
            if barEditActive { loopModeEdited = true }
            nudgeHeldSteps(by: Double(direction) * (shiftHeld ? 0.01 : 0.1))
            return
        }
        // Arrows move between bars (manual 9.5/12.1) — track selection is the
        // track buttons' job. One page past the end shows an empty bar; it
        // joins the loop if you add notes to it.
        let bars = track.clips[song.selectedScene].bars
        let maxPage = bars < 16 ? bars : bars - 1
        barPage = min(maxPage, max(0, barPage + direction))
        showOverlay("BAR \(barPage + 1)", Double(barPage + 1) / 16,
                    barPage >= bars ? "EMPTY: ADD TO KEEP" : "OF \(bars)")
    }

    private func transposeHeldSteps(by semitones: Int) {
        guard !heldSteps.isEmpty || barEditActive, track.kind == .synth else { return }
        let steps = heldAbsSteps()
        stepEntryUsed.formUnion(heldSteps)
        edit { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            for i in c.notes.indices where steps.contains(c.notes[i].step) {
                c.notes[i].key = min(126, max(1, c.notes[i].key + semitones))
            }
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
        showOverlay("NOTES", 0.5, "TRANSPOSED \(semitones > 0 ? "+" : "")\(semitones)")
    }

    private func octave(_ direction: Int) {
        // Step-hold + plus/minus transposes the held notes by a semitone
        // (manual 11.2); long press = an octave (handled via pendingNav).
        if !heldSteps.isEmpty || barEditActive, track.kind == .synth {
            if barEditActive { loopModeEdited = true }
            transposeHeldSteps(by: direction)
            return
        }
        guard track.kind == .synth || (track.kind == .drum && sixteenPitches) else { return }
        adjust { $0.tracks[$0.selectedTrack].octave = min(3, max(-3, $0.tracks[$0.selectedTrack].octave + direction)) }
        showOverlay("OCTAVE", 0.5, track.octave >= 0 ? "+\(track.octave)" : "\(track.octave)")
    }

    // MARK: - Repeat / Arp (manual 11.6)

    /// 16 Pitches pad (0 = bottom-left .. 15) -> MIDI note in the active
    /// layout; 60 = the sample's own pitch (samples are "assumed C", 9.2).
    private func pitchPadNote(_ p: Int) -> Int {
        let row = p / 4, col = p % 4
        let scale = Scales.all[song.scaleIndex].steps
        if song.chromatic ?? false {
            return min(126, max(1, 60 + song.rootNote + track.octave * 12 + row * 5 + col))
        }
        let degree = row * 4 + col
        return min(126, max(1, 60 + song.rootNote + track.octave * 12
            + degree / scale.count * 12 + scale[degree % scale.count]))
    }

    private func startRepeatChain() {
        guard repeatActive, !repeatChainArmed else { return }
        repeatChainArmed = true
        repeatFire()
    }

    /// One repeat hit, then self-schedules the next while pads stay held.
    /// Uses the plain live/record path so hits capture and record exactly
    /// like finger hits (manual: repeats land on the step buttons).
    private func repeatFire() {
        guard repeatActive, poweredOn else { repeatChainArmed = false; return }
        let isDrum = track.kind == .drum
        let keys = isDrum ? heldDrumCells.sorted() : heldPads.values.sorted()
        guard !keys.isEmpty else { repeatChainArmed = false; return }
        var fired: [Int]
        if isDrum || repeatStyle == 0 {
            fired = keys
        } else if repeatStyle == 3 {
            fired = [keys.randomElement()!]
        } else {
            let ordered = repeatStyle == 1 ? keys : keys.reversed()
            fired = [ordered[repeatArpPos % ordered.count]]
            repeatArpPos += 1
        }
        let vel = fullVelocity ? 127 : 100
        for key in fired {
            engine.liveNote(track: song.selectedTrack, kind: isDrum ? .drum : .synth,
                            key: key, velocity: vel, on: true)
            captureNoteOn(key: key, velocity: vel)
            recordHit(key: key, velocity: vel)
        }
        let interval = Self.repeatRates[repeatRateIdx].steps * 60 / song.tempo / 4
        let gated = fired
        DispatchQueue.main.asyncAfter(deadline: .now() + interval * 0.6) { [weak self] in
            guard let self else { return }
            for key in gated {
                if !isDrum {
                    self.engine.liveNote(track: self.song.selectedTrack, kind: .synth,
                                         key: key, velocity: 0, on: false)
                }
                self.captureNoteOff(key: key)
                self.recordRelease(key: key)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.repeatFire()
        }
    }

    // MARK: - Step-hold editing (manual ch 11)

    /// Absolute step numbers for the currently held step buttons. In Loop
    /// Mode, held steps are bars — edits cover every step in them (11.5).
    private func heldAbsSteps() -> Set<Int> {
        if menu == .loopLength, !loopModeHeld.isEmpty {
            var all = Set<Int>()
            for bar in loopModeHeld { for i in 0..<16 { all.insert(bar * 16 + i) } }
            return all
        }
        return Set(heldSteps.map { barPage * 16 + $0 })
    }

    /// Held bar-steps in Loop Mode enable the bulk-edit gestures.
    private var barEditActive: Bool { menu == .loopLength && !loopModeHeld.isEmpty }

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

    private func powerButton() {
        if poweredOn {
            menu = .powerConfirm
            refresh()
        } else {
            poweredOn = true
            engine.start()
            // Brief boot wordmark, then the main screen.
            var boot = Screen()
            boot.textCentered("MOVE XL", y: 52, size: 3)
            displayImage = boot.render()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                if poweredOn { refresh() }
            }
            refreshLeds()
        }
    }

    private func powerOff() {
        saveCurrentSet()
        engine.setTransport(playing: false)
        recording = false
        engine.setRecordingActive(false)
        releaseModifiers()
        menu = .none
        overlay = nil
        pendingNav = nil
        poweredOn = false
        displayImage = nil          // OLED dark
        noteColors = [:]            // every LED off
        noteChannels = [:]
        ccLeds = [:]
    }

    private func wheelPress() {
        guard poweredOn else { return }
        if menu == .powerConfirm {
            powerOff()
            return
        }
        // Shift+wheel press: next AU parameter bank (manual: parameter banks).
        if shiftHeld, menu == .none, engine.hasAU(track: song.selectedTrack) {
            let t = song.selectedTrack
            let total = engine.auParameters(track: t).count
            guard total > 0 else { showOverlay("PARAMS", 0, "NONE EXPOSED"); return }
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
                auIcons[song.selectedTrack] = nil
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
            scaleRow = (scaleRow + 1) % 3
        case .repeatMenu:
            if track.kind != .drum { repeatRow = (repeatRow + 1) % 2 }
        case .metronome:
            metronomeOn.toggle()
            engine.setMetronome(metronomeOn)
        case .workflow:
            workflowRow = (workflowRow + 1) % 3
        case .setup:
            setupEditingTheme.toggle()
        default:
            menu = .none
        }
        refresh()
    }

    // MARK: - Automation (manual 14.2)

    /// Lane key for an encoder on the selected track, honoring the AU bank.
    private func laneKey(_ index: Int) -> String? {
        let t = song.selectedTrack
        if engine.hasAU(track: t) {
            guard (1...7).contains(index) else { return nil }
            let params = engine.auParameters(track: t)
            let pIdx = (auParamBank[t] ?? 0) * 7 + (index - 1)
            guard params.indices.contains(pIdx) else { return nil }
            return "au.\(params[pIdx].address)"
        }
        let lanes = ["cutoff", "res", "attack", "release", "delay"]
        return index < lanes.count ? lanes[index] : nil
    }

    /// Encoder moved: while recording, write a breakpoint at the playhead;
    /// with step(s) held, write per-step automation instead (14.2.4).
    private func automationHook(lane: String?, value: Double) {
        guard let lane, mode == .note else { return }
        if !heldSteps.isEmpty || barEditActive {
            stepEntryUsed.formUnion(heldSteps)
            if barEditActive { loopModeEdited = true }
            for step in heldAbsSteps() {
                writeAutoPoint(lane: lane, pos: Double(step), value: value)
            }
            return
        }
        guard recording, engine.isPlaying, !engine.inCountIn else { return }
        let clip = track.clips[song.selectedScene]
        let pos = Double(clip.loopStartStep)
            + engine.currentStep.truncatingRemainder(dividingBy: Double(clip.loopSteps))
        writeAutoPoint(lane: lane, pos: pos, value: value)
    }

    private func writeAutoPoint(lane: String, pos: Double, value: Double) {
        adjust { song in
            var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
            var points = c.automation?[lane] ?? []
            points.removeAll { abs($0.pos - pos) < 0.1 }
            points.append(AutoPoint(pos: pos, value: value))
            points.sort { $0.pos < $1.pos }
            if points.count > 512 { points.removeFirst(points.count - 512) }
            var auto = c.automation ?? [:]
            auto[lane] = points
            c.automation = auto
            var off = c.autoOff ?? []
            off.removeAll { $0 == lane }   // writing re-activates the lane
            c.autoOff = off.isEmpty ? nil : off
            song.tracks[song.selectedTrack].clips[song.selectedScene] = c
        }
    }

    /// AU lanes can't be set from the render thread; step them at UI rate.
    private func applyAUAutomation() {
        for (t, tr) in song.tracks.enumerated() where engine.hasAU(track: t) {
            guard let scene = engine.playbackScene(track: t),
                  tr.clips.indices.contains(scene) else { continue }
            let clip = tr.clips[scene]
            guard let auto = clip.automation else { continue }
            let off = clip.autoOff ?? []
            let pos = Double(clip.loopStartStep)
                + engine.currentStep.truncatingRemainder(dividingBy: Double(clip.loopSteps))
            var params: [AUParameter]?
            for (lane, points) in auto where lane.hasPrefix("au.") && !points.isEmpty {
                guard !off.contains(lane) else { continue }
                if t == song.selectedTrack, touchedLanes.contains(lane) { continue }
                if params == nil { params = engine.auParameters(track: t) }
                guard let addr = UInt64(lane.dropFirst(3)),
                      let param = params?.first(where: { $0.address == addr }) else { continue }
                param.setValue(AUValue(AudioEngine.autoValue(points, at: pos)), originator: nil)
            }
        }
    }

    // MARK: - Surface API: wheel / encoders / volume

    func wheel(delta: Int) {
        guard poweredOn else { return }
        // Step-hold + wheel = note length (manual 11.3); in Loop Mode a held
        // bar-step scopes the edit to the whole bar (11.5).
        if (!heldSteps.isEmpty || barEditActive) && mode == .note {
            if barEditActive { loopModeEdited = true }
            adjustHeldLength(by: delta)
            return
        }
        switch menu {
        case .tempo:
            adjust { $0.tempo = min(240, max(40, $0.tempo + (shiftHeld ? 0.1 : 1) * Double(delta))) }
        case .groove:
            adjust { $0.swing = min(1.3, max(0, $0.swing + Double(delta) * 0.02)) }
        case .auPresets:
            browserIndex += delta
            let t = song.selectedTrack
            let presets = engine.auPresets(track: t)
            let count = presets.count + 1
            let sel = ((browserIndex % count) + count) % count
            if sel > 0 {
                engine.setAUPreset(track: t, preset: presets[sel - 1]) // live preview
            } else if let original = auPresetOriginal {
                engine.setAUPreset(track: t, preset: original) // back at "< CHANGE SOUND"
            }
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
            switch workflowRow {
            case 0:
                quantizePercent = min(100, max(0, quantizePercent + delta * 5))
                UserDefaults.standard.set(quantizePercent, forKey: "wf.quantize")
            case 1:
                countInOn = delta > 0
                UserDefaults.standard.set(countInOn, forKey: "wf.countIn")
            default:
                autoloadOn = delta > 0
                UserDefaults.standard.set(autoloadOn, forKey: "wf.autoload")
            }
            refresh()
        case .scale:
            adjust {
                switch scaleRow {
                case 0: $0.chromatic = delta > 0
                case 1: $0.rootNote = (($0.rootNote + delta) % 12 + 12) % 12
                default:
                    $0.scaleIndex = (($0.scaleIndex + delta) % Scales.all.count + Scales.all.count) % Scales.all.count
                }
            }
        case .repeatMenu:
            if track.kind != .drum && repeatRow == 0 {
                repeatStyle = ((repeatStyle + delta) % 4 + 4) % 4
            } else {
                let count = Self.repeatRates.count
                repeatRateIdx = min(count - 1, max(0, repeatRateIdx + delta))
            }
            refresh()
        case .loopLength:
            let clip0 = track.clips[song.selectedScene]
            let bars = clip0.bars
            let minBars = (clip0.loopStart ?? 0) + 1
            let newBars = max(minBars, min(16, bars + delta))
            guard newBars != bars else { break } // no-op detent: skip undo push
            edit { song in
                var clip = song.tracks[song.selectedTrack].clips[song.selectedScene]
                if newBars < clip.bars { clip.notes.removeAll { $0.step >= newBars * 16 } }
                clip.bars = newBars
                song.tracks[song.selectedTrack].clips[song.selectedScene] = clip
            }
        case .none:
            guard mode != .setOverview else { return }
            if mode == .session {
                // Manual 17.2: the wheel selects the Set effect to edit.
                fxFocus = delta > 0 ? 1 : 0
                showOverlay("SET FX", Double(fxFocus), fxFocus == 0 ? "DYNAMICS" : "SATURATOR")
                return
            }
            // Main screen: wheel nudges tempo (like grabbing it quickly).
            adjust { $0.tempo = min(240, max(40, $0.tempo + Double(delta))) }
        case .powerConfirm:
            break
        case .setup:
            if setupEditingTheme {
                themeStyle = ((themeStyle + (delta > 0 ? 1 : -1)) % 3 + 3) % 3
                UserDefaults.standard.set(themeStyle, forKey: "theme.style")
            } else {
                let count = Self.chassisColors.count
                chassisColorIndex = ((chassisColorIndex + delta) % count + count) % count
                UserDefaults.standard.set(chassisColorIndex, forKey: "theme.color")
            }
            refresh()
        case .metronome, .message:
            break
        case .setColor(let slot):
            let count = Self.trackColors.count
            let current = UserDefaults.standard.object(forKey: "setColor.\(slot)") as? Int ?? slot % 8
            let next = ((current + delta) % count + count) % count
            UserDefaults.standard.set(next, forKey: "setColor.\(slot)")
            if slot == currentSlot { adjust { $0.padColorIndex = next } }
            refresh()
        }
    }

    func wheelTouch(down: Bool) {}

    func encoderTouch(_ index: Int, down: Bool) {
        guard poweredOn, mode == .note, let lane = laneKey(index) else { return }
        if down, deleteHeld {
            // Manual 14.2.3: Delete + encoder tap deletes the lane.
            let has = track.clips[song.selectedScene].automation?[lane]?.isEmpty == false
            guard has else { return }
            edit { song in
                var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
                c.automation?[lane] = nil
                if c.automation?.isEmpty == true { c.automation = nil }
                c.autoOff?.removeAll { $0 == lane }
                song.tracks[song.selectedTrack].clips[song.selectedScene] = c
            }
            showOverlay("AUTOMATION", 0, "DELETED")
            return
        }
        if down, muteHeld {
            // Manual 14.2.1: Mute + encoder tap toggles the lane on/off.
            guard track.clips[song.selectedScene].automation?[lane]?.isEmpty == false else { return }
            muteUsed = true
            var nowOff = false
            edit { song in
                var c = song.tracks[song.selectedTrack].clips[song.selectedScene]
                var off = c.autoOff ?? []
                if off.contains(lane) { off.removeAll { $0 == lane } } else { off.append(lane); nowOff = true }
                c.autoOff = off.isEmpty ? nil : off
                song.tracks[song.selectedTrack].clips[song.selectedScene] = c
            }
            showOverlay("AUTOMATION", nowOff ? 0 : 1, nowOff ? "OFF" : "ON")
            return
        }
        // Touch-override (14.2): the finger wins while it's down.
        if down { touchedLanes.insert(lane) } else { touchedLanes.remove(lane) }
        engine.setAutoSuspend(track: song.selectedTrack, lane: lane, suspended: down)
    }

    func encoder(_ index: Int, delta: Int) {
        guard poweredOn else { return }
        if mode == .session {
            editSetFX(encoder: index, delta: delta)
            return
        }
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
            automationHook(lane: "au.\(param.address)", value: Double(value))
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
            automationHook(lane: "cutoff", value: Double(m.cutoff))
            showOverlay("CUTOFF", Double(min(1, m.cutoff / 4)), String(format: "%.0f%%", m.cutoff * 100))
        case 1:
            let base = m.res < 0 ? 0.3 : m.res
            m.res = min(0.95, max(0, base + d * 0.02))
            engine.setMacro(track: t, res: m.res)
            automationHook(lane: "res", value: Double(m.res))
            showOverlay("RESONANCE", Double(m.res), String(format: "%.0f%%", m.res * 100))
        case 2:
            m.attack = min(8, max(0.1, m.attack * (1 + d * 0.05)))
            engine.setMacro(track: t, attack: m.attack)
            automationHook(lane: "attack", value: Double(m.attack))
            showOverlay("ATTACK", Double(min(1, m.attack / 4)), String(format: "X%.2f", m.attack))
        case 3:
            m.release = min(8, max(0.1, m.release * (1 + d * 0.05)))
            engine.setMacro(track: t, release: m.release)
            automationHook(lane: "release", value: Double(m.release))
            showOverlay("RELEASE", Double(min(1, m.release / 4)), String(format: "X%.2f", m.release))
        case 4:
            m.delay = min(1, max(0, m.delay + d * 0.02))
            engine.setMacro(track: t, delay: m.delay)
            automationHook(lane: "delay", value: Double(m.delay))
            showOverlay("DELAY SEND", Double(m.delay), String(format: "%.0f%%", m.delay * 100))
        case 5:
            adjust { $0.tracks[t].volume = min(1, max(0, $0.tracks[t].volume + Double(d) * 0.02)) }
            engine.setAUVolume(track: t, volume: Float(track.volume))
            showOverlay("TRACK VOL", track.volume, String(format: "%.0f%%", track.volume * 100))
        case 6:
            adjust { $0.swing = min(1.3, max(0, $0.swing + Double(d) * 0.02)) }
            showOverlay("GROOVE", song.swing, String(format: "%.0f%%", song.swing * 100))
        case 7:
            adjust { $0.tempo = min(240, max(40, $0.tempo + Double(d) * (shiftHeld ? 0.1 : 1))) }
            showOverlay("TEMPO", (song.tempo - 40) / 200, String(format: "%.1f BPM", song.tempo))
        default:
            break
        }
    }

    /// Session-mode encoders edit the focused Set effect (manual 17.2).
    /// Dynamics: threshold / ratio / makeup. Saturator: drive / color / mix.
    private func editSetFX(encoder index: Int, delta: Int) {
        guard index < 3 else { return }
        var fx = song.fxParams ?? AudioEngine.fxDefaults
        if fx.count < 6 { fx = AudioEngine.fxDefaults }
        let p = fxFocus * 3 + index
        let d = Double(delta)
        let names = ["THRESHOLD", "RATIO", "MAKEUP", "DRIVE", "COLOR", "MIX"]
        switch p {
        case 0: fx[0] = min(0, max(-40, fx[0] + d))
        case 1: fx[1] = min(8, max(1, fx[1] + d * 0.1))
        case 2: fx[2] = min(12, max(0, fx[2] + d * 0.2))
        case 3: fx[3] = min(10, max(1, fx[3] + d * 0.15))
        case 4: fx[4] = min(1, max(0, fx[4] + d * 0.02))
        default: fx[5] = min(1, max(0, fx[5] + d * 0.02))
        }
        adjust { $0.fxParams = fx }
        let norms: [Double] = [(fx[0] + 40) / 40, (fx[1] - 1) / 7, fx[2] / 12,
                               (fx[3] - 1) / 9, fx[4], fx[5]]
        showOverlay(names[p], norms[p], String(format: "%.2f", fx[p]))
    }

    func volume(delta: Int) {
        guard poweredOn else { return }
        // Step-hold + volume encoder = note velocity (manual 11.1/11.5).
        if (!heldSteps.isEmpty || barEditActive) && mode == .note {
            if barEditActive { loopModeEdited = true }
            adjustHeldVelocity(by: delta)
            return
        }
        // Set-pad-hold + Volume = Set volume (manual 6.1: scales all track
        // volumes together, for balancing Sets).
        if mode == .setOverview, let slot = heldSetPads.first {
            let factor = 1 + Double(delta) * 0.03
            if slot == currentSlot {
                adjust { song in
                    for i in song.tracks.indices {
                        song.tracks[i].volume = min(1, max(0.02, song.tracks[i].volume * factor))
                    }
                }
                for (i, t) in song.tracks.enumerated() { engine.setAUVolume(track: i, volume: Float(t.volume)) }
                showOverlay("SET VOLUME", song.tracks[0].volume, "SET \(slot + 1)")
            } else if var other = Self.loadSet(slot: slot) {
                for i in other.tracks.indices {
                    other.tracks[i].volume = min(1, max(0.02, other.tracks[i].volume * factor))
                }
                if let data = try? JSONEncoder().encode(other) {
                    try? data.write(to: Self.slotURL(slot))
                }
                showOverlay("SET VOLUME", other.tracks[0].volume, "SET \(slot + 1)")
            }
            return
        }
        // Track-hold + volume = that track's volume (manual 16.2).
        if let t = heldTracks.first {
            muteUsed = true
            adjust { $0.tracks[t].volume = min(1, max(0, $0.tracks[t].volume + Double(delta) * 0.02)) }
            engine.setAUVolume(track: t, volume: Float(song.tracks[t].volume))
            showOverlay("T\(t + 1) VOLUME", song.tracks[t].volume,
                        String(format: "%.0f%%", song.tracks[t].volume * 100))
            return
        }
        // Pad-hold + volume = sample gain (manual 16.5), drum cells.
        if mode == .note, track.kind == .drum, let cell = heldDrumCells.first {
            adjust { song in
                var gains = song.tracks[song.selectedTrack].cellGains ?? [:]
                gains[cell] = min(2, max(0, (gains[cell] ?? 1) + Double(delta) * 0.04))
                song.tracks[song.selectedTrack].cellGains = gains
            }
            let gain = track.cellGains?[cell] ?? 1
            showOverlay("PAD \(cell + 1) GAIN", gain / 2, String(format: "%.0f%%", gain * 100))
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

    private func captureNoteOn(key: Int, velocity: Int, pitch: Int? = nil) {
        // During the count-in the step clock is about to be discarded.
        guard !engine.inCountIn else { return }
        let playing = engine.isPlaying
        let start = playing ? engine.currentStep : Date.timeIntervalSinceReferenceDate
        captureBuffer.append(CapturedNote(track: song.selectedTrack, key: key,
                                          velocity: velocity, start: start,
                                          length: playing ? 1 : 0.25, onGrid: playing,
                                          pitch: pitch))
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
            showOverlay("CAPTURE", 0, shiftLocked ? "CLEARED (SHIFT LOCKED)" : "BUFFER CLEARED")
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
                    let scene = engine.playbackScene(track: note.track) ?? song.selectedScene
                    var clip = song.tracks[note.track].clips[scene]
                    guard note.start >= now - Double(clip.loopSteps) else { continue }
                    let region = clip.loopSteps
                    let localExact = Double(clip.loopStartStep)
                        + note.start.truncatingRemainder(dividingBy: Double(region))
                    let (step, off) = quantized(localExact, start: clip.loopStartStep, region: region)
                    clip.notes.removeAll { $0.step == step && $0.key == note.key && $0.pitch == note.pitch }
                    clip.notes.append(Note(step: step, key: note.key, velocity: note.velocity,
                                           lengthSteps: max(0.25, (note.length * 4).rounded() / 4),
                                           offset: off, pitch: note.pitch))
                    song.tracks[note.track].clips[scene] = clip
                    involved.insert(note.track)
                }
            } else {
                // Free-time pass: quantize the last 16 seconds at current tempo.
                let cutoff = Date.timeIntervalSinceReferenceDate - 16
                let phrase = captureBuffer.filter { !$0.onGrid && $0.start >= cutoff }
                guard let t0 = phrase.map(\.start).min() else { return }
                // Tempo detection: treat the median gap between onsets as a
                // 16th note and fold the implied tempo into a musical range.
                if let bpm = Self.detectTempo(onsets: phrase.map(\.start).sorted()) {
                    song.tempo = bpm
                }
                let stepsPerSecond = song.tempo / 60 * 4
                let maxStep = phrase.map { (($0.start - t0) * stepsPerSecond).rounded() }.max() ?? 0
                let bars = min(16, max(1, Int(maxStep) / 16 + 1))
                for note in phrase {
                    guard song.tracks.indices.contains(note.track) else { continue }
                    var clip = song.tracks[note.track].clips[song.selectedScene]
                    clip.bars = max(clip.bars, bars)
                    let region = clip.loopSteps
                    let exact = Double(clip.loopStartStep)
                        + ((note.start - t0) * stepsPerSecond)
                            .truncatingRemainder(dividingBy: Double(region))
                    let (step, off) = quantized(exact, start: clip.loopStartStep, region: region)
                    let length = max(0.25, ((note.length * stepsPerSecond) * 4).rounded() / 4)
                    clip.notes.removeAll { $0.step == step && $0.key == note.key && $0.pitch == note.pitch }
                    clip.notes.append(Note(step: step, key: note.key, velocity: note.velocity,
                                           lengthSteps: length, offset: off, pitch: note.pitch))
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

    /// Median inter-onset interval read as a 16th note, folded into
    /// 70-180 BPM. Needs a few hits to say anything.
    private static func detectTempo(onsets: [Double]) -> Double? {
        guard onsets.count >= 4 else { return nil }
        var gaps: [Double] = []
        for i in 1..<onsets.count {
            let gap = onsets[i] - onsets[i - 1]
            if gap > 0.08, gap < 3 { gaps.append(gap) }
        }
        guard gaps.count >= 3 else { return nil }
        let median = gaps.sorted()[gaps.count / 2]
        var bpm = 15.0 / median
        while bpm > 180 { bpm /= 2 }
        while bpm < 70 { bpm *= 2 }
        return bpm.rounded()
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
        let oldAUs = song.tracks.map(\.auIdentifier)
        song = snapshot
        for (i, t) in song.tracks.enumerated()
        where t.kind == .drum && t.soundIndex != oldKits[i] {
            loadKit(track: i, index: t.soundIndex)
        }
        if song.tracks.enumerated().contains(where: { i, t in
            i < oldAUs.count && t.auIdentifier != oldAUs[i]
        }) {
            reinstallAUs()
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
        UserDefaults.standard.set(song.padColorIndex, forKey: "setColor.\(currentSlot)")
    }

    // MARK: - Rendering

    /// Panic-clear held modifier latches (gesture cancellation on app switch
    /// never delivers the release event).
    func releaseModifiers() {
        clearEntryState()
        clearLoopModeLatches()
        shiftHeld = false
        shiftLocked = false
        muteHeld = false
        deleteHeld = false
        copyHeld = false
    }

    private func refresh() {
        guard poweredOn else { return }
        // barPage can go stale via scene changes, loop shrink, set load, undo.
        // Allow one page past the end: the manual's "empty bar" you can fill.
        barPage = min(barPage, min(track.clips[song.selectedScene].bars, 15))
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
            let rows = [(song.chromatic ?? false) ? "CHROMATIC" : "IN-KEY",
                        Scales.noteNames[song.rootNote],
                        Scales.all[song.scaleIndex].name]
            for (i, row) in rows.enumerated() {
                let y = 26 + i * 24
                if scaleRow == i { s.fillRect(4, y - 5, 248, 20) }
                s.text(row, x: 12, y: y, size: 2, invert: scaleRow == i)
            }
            s.textCentered("TURN=SET PRESS=SWAP", y: 106)
        case .repeatMenu:
            let styles = ["REPEAT", "ARP UP", "ARP DOWN", "ARP RANDOM"]
            s.text(track.kind == .drum ? "REPEAT" : styles[repeatStyle], x: 8, y: 8)
            if track.kind != .drum {
                if repeatRow == 0 { s.fillRect(4, 33, 248, 22) }
                s.text("STYLE  \(styles[repeatStyle])", x: 12, y: 38, size: 2, invert: repeatRow == 0)
            }
            let rateY = track.kind == .drum ? 38 : 64
            if track.kind == .drum || repeatRow == 1 { s.fillRect(4, rateY - 5, 248, 22) }
            s.text("RATE  \(Self.repeatRates[repeatRateIdx].name)", x: 12, y: rateY, size: 2,
                   invert: track.kind == .drum || repeatRow == 1)
            s.textCentered("HOLD PADS TO PLAY", y: 106)
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
            let rows = ["QUANTIZE  \(quantizePercent)%",
                        "COUNT-IN  \(countInOn ? "ON" : "OFF")",
                        "AUTOLOAD  \(autoloadOn ? "ON" : "OFF")"]
            for (i, row) in rows.enumerated() {
                let y = 30 + i * 26
                if workflowRow == i { s.fillRect(4, y - 6, 248, 22) }
                s.text(row, x: 12, y: y, size: 2, invert: workflowRow == i)
            }
            s.textCentered("TURN=SET PRESS=SWAP", y: 106)
        case .setup:
            s.text("SETUP - MOTUS XL", x: 8, y: 8)
            s.text("\(DrumKits.names.count) KITS - 8 TRACKS", x: 8, y: 24)
            let colorName = Self.chassisColors[((chassisColorIndex % Self.chassisColors.count)
                + Self.chassisColors.count) % Self.chassisColors.count].name
            let themeName = ["HARDWARE", "BARE", "VINTAGE"][((themeStyle % 3) + 3) % 3]
            if setupEditingTheme { s.fillRect(4, 44, 248, 22) }
            s.text("THEME  \(themeName)", x: 12, y: 50, size: 2, invert: setupEditingTheme)
            if !setupEditingTheme { s.fillRect(4, 70, 248, 22) }
            s.text("COLOR  \(colorName)", x: 12, y: 76, size: 2, invert: !setupEditingTheme)
            s.textCentered("TURN=SET PRESS=SWAP", y: 108)
        case .powerConfirm:
            s.textCentered("POWER OFF?", y: 30, size: 2)
            s.textCentered("PRESS WHEEL TO CONFIRM", y: 66)
            s.textCentered("BACK TO CANCEL", y: 82)
        case .setColor(let slot):
            s.text("SET \(slot + 1) COLOR", x: 8, y: 8)
            let idx = UserDefaults.standard.object(forKey: "setColor.\(slot)") as? Int ?? slot % 8
            s.textCentered("COLOR \(idx + 1) OF \(Self.trackColors.count)", y: 52, size: 2)
            s.textCentered("TURN WHEEL - BACK TO EXIT", y: 100)
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
            let sel = selectedOverviewSlot
            let name = sel == currentSlot ? song.name
                : (Self.loadSet(slot: sel)?.name ?? "EMPTY SLOT \(sel + 1)")
            s.text(String(name.prefix(16)), x: 8, y: 34, size: 3)
            s.text("SLOT \(sel + 1)", x: 8, y: 66)
            s.text("PLAY=PREVIEW TRACK=OPEN", x: 8, y: 96)
            s.text("SHIFT+PAD=COLOR DEL 2X=CLEAR", x: 8, y: 108)
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
        s.text(String(soundName.prefix(20)), x: 4, y: 77, size: 2)
        if engine.hasAU(track: song.selectedTrack) {
            // Knob map: E1 = VOL, E2-E8 = the active parameter bank.
            let params = engine.auParameters(track: song.selectedTrack)
            let bank = auParamBank[song.selectedTrack] ?? 0
            var slots = ["VOL"]
            let auto = track.clips[song.selectedScene].automation ?? [:]
            for i in 0..<7 {
                let pIdx = bank * 7 + i
                if params.indices.contains(pIdx) {
                    let name = String(params[pIdx].displayName.prefix(6))
                    let lane = "au.\(params[pIdx].address)"
                    // * = the lane has recorded automation (manual 14.2).
                    slots.append(auto[lane]?.isEmpty == false ? "*" + String(name.prefix(5)) : name)
                } else {
                    slots.append("-")
                }
            }
            for (i, name) in slots.enumerated() {
                s.text(name, x: 4 + (i % 4) * 64, y: 92 + (i / 4) * 9)
            }
            let banks = max(1, (params.count + 6) / 7)
            if banks > 1 { s.text("B\(bank + 1)/\(banks)", x: 224, y: 68) }
        } else {
            let info: String
            if mode == .session {
                info = "FX \(fxFocus == 0 ? "DYNAMICS" : "SATURATOR") - WHEEL SWAPS"
            } else if track.kind == .synth {
                info = "\(Scales.noteNames[song.rootNote]) \(Scales.all[song.scaleIndex].name)  OCT \(track.octave >= 0 ? "+" : "")\(track.octave)"
            } else {
                info = "PAD \(track.selectedPad + 1)"
            }
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
        let slots = min(16, bars + (bars < 16 ? 1 : 0))
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
        guard poweredOn else { return }
        var colors: [Int: SIMD3<Double>] = [:]
        var channels: [Int: Int] = [:]

        switch mode {
        case .setOverview:
            let saved = Set((0..<64).filter { FileManager.default.fileExists(atPath: Self.slotURL($0).path) })
            for i in 0..<64 {
                let note = Self.padNote(i)
                let colorIdx = UserDefaults.standard.object(forKey: "setColor.\(i)") as? Int ?? i % 8
                if i == selectedOverviewSlot {
                    // Selected: pulse — white when the slot is empty (manual 6.1).
                    colors[note] = (saved.contains(i) || i == currentSlot)
                        ? Self.trackColors[colorIdx % 8] : SIMD3(0.95, 0.95, 0.92)
                    channels[note] = 9
                } else if i == currentSlot {
                    colors[note] = Self.trackColors[colorIdx % 8]
                } else if saved.contains(i) {
                    colors[note] = Self.trackColors[colorIdx % 8] * 0.55
                }
            }
        case .session:
            let session = engine.sessionState()
            for t in 0..<min(8, song.tracks.count) {
                for scene in 0..<8 {
                    let note = Self.padNote(t * 8 + scene)
                    let clip = song.tracks[t].clips[scene]
                    if session.queued.indices.contains(t), session.queued[t] == scene {
                        colors[note] = SIMD3(0.30, 0.95, 0.40)   // queued: pulsing green
                        channels[note] = 9
                    } else if session.playing.indices.contains(t), session.playing[t] == scene,
                              !clip.isEmpty {
                        colors[note] = Self.trackColors[t]        // playing: pulsing color
                        channels[note] = engine.isPlaying ? 9 : 0
                        if session.stopping.indices.contains(t), session.stopping[t] {
                            colors[note] = Self.trackColors[t] * 0.35 // stopping: dim pulse
                        }
                    } else if !clip.isEmpty {
                        colors[note] = Self.trackColors[t] * 0.45 // idle clip
                    } else if scene == song.selectedScene && t == song.selectedTrack {
                        colors[note] = SIMD3(0.25, 0.25, 0.25)    // selected empty slot
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
                            continue // muted = LED off = no color
                        } else if cell == track.selectedPad {
                            colors[note] = SIMD3(1, 1, 1)
                        } else if cellsWithNotes.contains(cell) {
                            colors[note] = trackColor
                        } else {
                            // Loaded sample = playable = dimly lit (real Move).
                            colors[note] = trackColor * 0.30
                        }
                    }
                    for col in 4..<8 where sixteenPitches {
                        let note = Self.padNote(row * 8 + col)
                        let midi = pitchPadNote((7 - row) * 4 + (col - 4))
                        let pc = ((midi - song.rootNote) % 12 + 12) % 12
                        let scale = Scales.all[song.scaleIndex].steps
                        if pc == 0 {
                            colors[note] = trackColor          // root: track color
                        } else if scale.contains(pc) {
                            colors[note] = SIMD3(0.55, 0.55, 0.53)
                        } // out of scale: unlit (chromatic), still playable
                    }
                }
            } else {
                // Manual pad colors: root notes white, scale notes in the
                // track color. Sounding notes (held or sequenced) flash green.
                let scale = Scales.all[song.scaleIndex].steps
                let chromatic = song.chromatic ?? false
                var soundingNotes = Set(heldPads.values)
                if engine.isPlaying {
                    let clip = track.clips[song.selectedScene]
                    let localStep = clip.localStep(Int(engine.currentStep))
                    for n in clip.notes where n.step == localStep {
                        soundingNotes.insert(n.key)
                    }
                }
                for i in 0..<64 {
                    let note = Scales.padToNote(i, root: song.rootNote, scale: scale,
                                                octave: track.octave, chromatic: chromatic)
                    let pc = ((note - song.rootNote) % 12 + 12) % 12
                    if soundingNotes.contains(note) {
                        colors[Self.padNote(i)] = SIMD3(0.35, 1.0, 0.45)
                    } else if pc == 0 {
                        // Manual 9.1: root pads in the track color, scale
                        // notes light gray, out-of-scale unlit (chromatic).
                        colors[Self.padNote(i)] = trackColor
                    } else if !chromatic || scale.contains(pc) {
                        colors[Self.padNote(i)] = SIMD3(0.55, 0.55, 0.53)
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
            let session = engine.sessionState()
            for i in 0..<16 {
                let t = i / 2
                guard song.tracks.indices.contains(t) else { break }
                if i % 2 == 0 {
                    colors[Self.stepNote(i)] = Self.trackColors[t]
                        * (t == song.selectedTrack ? 1.0 : 0.35)
                } else if session.playing.indices.contains(t), session.playing[t] != nil {
                    colors[Self.stepNote(i)] = SIMD3(0.6, 0.12, 0.10) // stop available
                }
            }
        }

        // Holding step(s) lights the pads for the notes they contain (11.9).
        if mode == .note, !heldSteps.isEmpty {
            let clip = track.clips[song.selectedScene]
            let held = heldAbsSteps()
            let keys = Set(clip.notes.filter { held.contains($0.step) }.map(\.key))
            if track.kind == .drum {
                for row in 4..<8 {
                    for col in 0..<4 where keys.contains((7 - row) * 4 + col) {
                        colors[Self.padNote(row * 8 + col)] = SIMD3(0.95, 0.95, 0.92)
                    }
                }
            } else {
                let scale = Scales.all[song.scaleIndex].steps
                for i in 0..<64 {
                    let note = Scales.padToNote(i, root: song.rootNote, scale: scale,
                                                octave: track.octave,
                                                chromatic: song.chromatic ?? false)
                    if keys.contains(note) {
                        colors[Self.padNote(i)] = SIMD3(0.95, 0.95, 0.92)
                    }
                }
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
        for t in 0..<min(8, song.tracks.count) where !song.tracks[t].muted {
            // Muted = LED off = no color at all.
            let base = Self.trackColors[t]
            colors[Self.trackNotes[t]] = base * (t == song.selectedTrack ? 1.0 : 0.35)
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
        let maxPage = bars < 16 ? bars : bars - 1
        ccs[Self.buttonCC["left"]!] = (barPage > 0 || !heldSteps.isEmpty) ? 40 : 8
        ccs[Self.buttonCC["right"]!] = (barPage < maxPage || !heldSteps.isEmpty) ? 40 : 8
        ccs[Self.buttonCC["minus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["plus"]!] = track.kind == .synth ? 40 : 8
        ccs[Self.buttonCC["capture"]!] = captureBuffer.isEmpty ? 12 : 90
        ccs[Self.buttonCC["quantize"]!] = track.clips[song.selectedScene].isEmpty ? 12 : 40
        ccs[Self.buttonCC["auview"]!] = engine.hasAU(track: song.selectedTrack) ? 60 : 8
        ccs[Self.buttonCC["sample"]!] = 12

        // Shift-function legends under the step row (synthetic CCs, 200 + step).
        // Bright while Shift is held (function available); soft steady glow when
        // the function's toggle is active so its state reads at a glance.
        for step in Self.legendSteps {
            var level = shiftHeld ? 127 : 0
            if step == 5, metronomeOn { level = max(level, 48) }
            if step == 7, sixteenPitches { level = max(level, 48) }
            if step == 9, fullVelocity { level = max(level, 48) }
            if step == 10, repeatActive { level = max(level, 48) }
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
        "quantize": 0x60, "auview": 0x62,
    ]
}

extension SIMD3 where Scalar == Double {
    static func * (lhs: SIMD3<Double>, rhs: Double) -> SIMD3<Double> {
        SIMD3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }
}
