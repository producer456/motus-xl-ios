import AVFoundation
import UIKit
import CoreAudioKit

/// Standalone Move audio engine: drum sampler + poly synths + step sequencer
/// clock, all rendered sample-accurately inside one AVAudioSourceNode.
final class AudioEngine {
    static let sampleRate = 44100.0

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // ---- Shared state (audio thread reads under lock) ----
    private let lock = NSLock()
    private var song = Song()
    private var kits: [Int: LoadedKit] = [:]        // track index -> kit
    private var playing = false
    private var resetPending = false                // consumed by render under lock
    private var countInAbort = false                // stop pressed: clear count-in state
    private var stepPos = 0.0                       // position in steps (tempo-rate independent)
    private var pendingCountIn = 0                  // set under lock; consumed with resetPending
    private var countInStepsLeft = 0                // render-owned: clicks only, no sequencing
    private var inCountInShared = false             // published for the UI under lock
    private var metronomeOn = false
    private var recordingActive = false   // anti-flam guard applies only while recording
    private var mainVolume: Float = 0.85
    static let maxTracks = 8
    private var cutoffScale = [Float](repeating: 1, count: AudioEngine.maxTracks)
    private var resOverride = [Float](repeating: -1, count: AudioEngine.maxTracks)
    private var attackScale = [Float](repeating: 1, count: AudioEngine.maxTracks)
    private var releaseScale = [Float](repeating: 1, count: AudioEngine.maxTracks)
    private var delaySend = [Float](repeating: 0, count: AudioEngine.maxTracks)
    /// Lanes with a finger on the encoder: automation is overridden while
    /// touched (manual 14.2). Written under lock from the main thread.
    private var autoSuspend = [Set<String>](repeating: [], count: AudioEngine.maxTracks)
    // Master set-effects state (Dynamics -> Saturator, manual 17.2).
    private var compEnv: Float = 0
    private var satLPl: Float = 0
    private var satLPr: Float = 0
    static let fxDefaults: [Double] = [-18, 2.5, 3, 2, 0.6, 0.35]

    // UI-visible transport position (read by main thread each frame).
    private(set) var playheadStep: Double = 0
    /// Set by the Brain: re-create AUs after a media-services graph rebuild.
    var onGraphRebuilt: (() -> Void)?

    // ---- Voices (preallocated; audio thread only) ----
    private var drumVoices = (0..<32).map { _ in DrumVoice() }
    private var synthVoices = (0..<32).map { _ in SynthVoice() }

    // ---- Immediate events from the UI ----
    private struct LiveEvent {
        var track: Int
        var kind: TrackKind
        var key: Int          // drum cell or MIDI note
        var velocity: Int
        var on: Bool
        var rate: Float = 1   // pitched drum playback
    }
    private var eventQueue: [LiveEvent] = []
    private var renderEvents: [LiveEvent] = []      // audio-thread scratch (swap, no malloc)
    private var lastStepFired = -1
    private var voiceCounter: UInt64 = 0            // for oldest-voice stealing

    // ---- Tempo-synced stereo delay ----
    private var delayL = [Float](repeating: 0, count: 88200)
    private var delayR = [Float](repeating: 0, count: 88200)
    private var delayPos = 0

    private var metroPhase: Float = 0
    private var metroEnv: Float = 0
    private var trackGain = [Float](repeating: 1, count: AudioEngine.maxTracks) // render scratch

    // ---- Session playback (manual 17.1): each track plays its own clip ----
    private var playingScene = [Int?](repeating: nil, count: AudioEngine.maxTracks)
    private var queuedScene = [Int?](repeating: nil, count: AudioEngine.maxTracks)
    private var queuedStop = [Bool](repeating: false, count: AudioEngine.maxTracks)

    // ---- AUv3 instrument hosting ----
    // Render thread talks to AUs only through captured schedule blocks.
    private var auSchedule = [AUScheduleMIDIEventBlock?](repeating: nil, count: AudioEngine.maxTracks)
    private var auUnits: [Int: AVAudioUnit] = [:]          // main thread
    private var auMixers: [Int: AVAudioMixerNode] = [:]    // main thread
    /// Sequenced AU note-offs (schedule blocks can't queue future events).
    private struct PendingOff { var track: Int32 = -1; var key: UInt8 = 0; var frames: Int32 = 0 }
    private var pendingOffs = [PendingOff](repeating: PendingOff(), count: 256)
    /// Just-played live notes: 50% record-quantize can write a note slightly
    /// AHEAD of the playhead, which the sequencer would re-fire moments after
    /// the finger hit — an audible flam. Suppress those for ~half a step.
    private struct RecentLive { var track: Int32 = -1; var key: Int32 = 0; var at: Double = -1 }
    private var recentLive = [RecentLive](repeating: RecentLive(), count: 64)
    private var recentLiveIdx = 0

    private func noteRecentlyPlayedLive(track: Int, key: Int, swing: Double) -> Bool {
        guard recordingActive else { return false }
        let window = 0.55 + swing * 0.55   // forward pull + swing delay
        for entry in recentLive where entry.track == Int32(track) && entry.key == Int32(key) {
            let age = stepPos - entry.at
            if age >= 0 && age < window { return true }
        }
        return false
    }

    func start() {
        configureSession()
        if sourceNode == nil {
            let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
            let node = AVAudioSourceNode { [weak self] _, _, frameCount, abl -> OSStatus in
                self?.render(frameCount: Int(frameCount), abl: abl)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sourceNode = node
        }
        engine.prepare()
        try? engine.start()
        observeInterruptions()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(Self.sampleRate)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
    }

    // MARK: - Main-thread API

    func update(song: Song) {
        lock.lock(); self.song = song; lock.unlock()
    }

    func setKit(_ kit: LoadedKit, track: Int) {
        lock.lock(); kits[track] = kit; lock.unlock()
    }

    func setTransport(playing: Bool, fromStart: Bool = false, countInSteps: Int = 0) {
        lock.lock()
        self.playing = playing
        if fromStart { resetPending = true }
        pendingCountIn = playing ? countInSteps : 0
        if !playing { countInAbort = true }  // aborting mid-count-in must not latch
        lock.unlock()
    }

    /// True while the count-in bar's clicks are sounding (before sequencing).
    /// Includes the not-yet-rendered pending state so a pad hit immediately
    /// after Record (before the first audio callback) can't slip into step 0.
    var inCountIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return inCountInShared || pendingCountIn > 0
    }

    func setMetronome(_ on: Bool) { lock.lock(); metronomeOn = on; lock.unlock() }

    /// Encoder touch-override: skip a lane's automation while it's held.
    func setAutoSuspend(track: Int, lane: String, suspended: Bool) {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock()
        if suspended { autoSuspend[t].insert(lane) } else { autoSuspend[t].remove(lane) }
        lock.unlock()
    }

    /// Last breakpoint at or before pos; wraps to the final point before the
    /// first (the loop carries the tail value around).
    static func autoValue(_ points: [AutoPoint], at pos: Double) -> Double {
        var best: AutoPoint?
        for p in points where p.pos <= pos {
            if best == nil || p.pos > best!.pos { best = p }
        }
        return best?.value ?? points.last!.value
    }
    func setRecordingActive(_ on: Bool) { lock.lock(); recordingActive = on; lock.unlock() }
    func setMainVolume(_ v: Float) { lock.lock(); mainVolume = v; lock.unlock() }

    func setMacro(track: Int, cutoff: Float? = nil, res: Float? = nil,
                  attack: Float? = nil, release: Float? = nil, delay: Float? = nil) {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock()
        if let cutoff { cutoffScale[t] = cutoff }
        if let res { resOverride[t] = res }
        if let attack { attackScale[t] = attack }
        if let release { releaseScale[t] = release }
        if let delay { delaySend[t] = delay }
        lock.unlock()
    }

    func resetMacros() {
        lock.lock()
        cutoffScale = [Float](repeating: 1, count: Self.maxTracks)
        resOverride = [Float](repeating: -1, count: Self.maxTracks)
        attackScale = [Float](repeating: 1, count: Self.maxTracks)
        releaseScale = [Float](repeating: 1, count: Self.maxTracks)
        delaySend = [Float](repeating: 0, count: Self.maxTracks)
        lock.unlock()
    }

    func macro(track: Int) -> (cutoff: Float, res: Float, attack: Float, release: Float, delay: Float) {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock(); defer { lock.unlock() }
        return (cutoffScale[t], resOverride[t], attackScale[t], releaseScale[t], delaySend[t])
    }

    func liveNote(track: Int, kind: TrackKind, key: Int, velocity: Int, on: Bool, rate: Float = 1) {
        lock.lock()
        if eventQueue.count < 128 {
            eventQueue.append(LiveEvent(track: track, kind: kind, key: key,
                                        velocity: velocity, on: on, rate: rate))
        }
        lock.unlock()
    }

    var currentStep: Double {
        lock.lock(); defer { lock.unlock() }
        return playheadStep
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    /// Launch a track's clip: immediate when stopped, else queued to the
    /// next bar (manual 17.1.2).
    func launchClip(track: Int, scene: Int) {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock()
        queuedStop[t] = false
        if playing {
            queuedScene[t] = scene
        } else {
            playingScene[t] = scene
            queuedScene[t] = nil
        }
        lock.unlock()
    }

    /// Stop one track's clip at the next bar (immediate when stopped).
    func stopTrack(_ track: Int) {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock()
        queuedScene[t] = nil
        if playing { queuedStop[t] = true } else { playingScene[t] = nil }
        lock.unlock()
    }

    /// Note-mode scene selection: every track follows (legacy behavior).
    func setAllPlayingScenes(_ scene: Int) {
        lock.lock()
        for t in 0..<Self.maxTracks {
            playingScene[t] = scene
            queuedScene[t] = nil
            queuedStop[t] = false
        }
        lock.unlock()
    }

    /// (playing, queued, stopQueued) per track, for LEDs.
    func sessionState() -> (playing: [Int?], queued: [Int?], stopping: [Bool]) {
        lock.lock(); defer { lock.unlock() }
        return (playingScene, queuedScene, queuedStop)
    }

    func playbackScene(track: Int) -> Int? {
        let t = max(0, min(Self.maxTracks - 1, track))
        lock.lock(); defer { lock.unlock() }
        return playingScene[t]
    }

    // MARK: - AUv3 instrument hosting (main thread)

    /// Instantiate and wire an AUv3 instrument onto a track. Returns its name.
    private var auGeneration = [Int](repeating: 0, count: AudioEngine.maxTracks)

    @MainActor
    func installAU(track: Int, description: AudioComponentDescription) async throws -> String {
        removeAU(track: track)
        auGeneration[track] += 1
        let generation = auGeneration[track]
        let avAU = try await AVAudioUnit.instantiate(with: description,
                                                     options: .loadOutOfProcess)
        // A newer install/remove won the race while we were instantiating.
        guard auGeneration[track] == generation else {
            struct Superseded: Error {}
            throw Superseded()
        }
        let mixer = AVAudioMixerNode()
        engine.attach(avAU)
        engine.attach(mixer)
        engine.connect(avAU, to: mixer, format: nil)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.outputVolume = 0.8
        auUnits[track] = avAU
        auMixers[track] = mixer
        let block = avAU.auAudioUnit.scheduleMIDIEventBlock
        lock.lock(); auSchedule[track] = block; lock.unlock()
        return avAU.auAudioUnit.audioUnitName ?? avAU.name
    }

    @MainActor
    func removeAU(track: Int) {
        auGeneration[track] += 1
        lock.lock(); auSchedule[track] = nil; lock.unlock()
        // Defer the detach past any render cycle that already snapshotted the
        // schedule block this buffer.
        let au = auUnits.removeValue(forKey: track)
        let mixer = auMixers.removeValue(forKey: track)
        if au != nil || mixer != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if let au { self.engine.detach(au) }
                if let mixer { self.engine.detach(mixer) }
            }
        }
    }

    func hasAU(track: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return auSchedule[max(0, min(Self.maxTracks - 1, track))] != nil
    }

    /// All parameters of the track's AU, for banked encoder mapping.
    func auParameters(track: Int) -> [AUParameter] {
        guard let au = auUnits[track],
              let params = au.auAudioUnit.parameterTree?.allParameters else { return [] }
        return params
    }

    @MainActor
    func setAUVolume(track: Int, volume: Float) {
        auMixers[track]?.outputVolume = volume
    }

    /// The AU's own view controller (its native plugin UI), if it offers one.
    @MainActor
    func auViewController(track: Int) async -> UIViewController? {
        guard let au = auUnits[track]?.auAudioUnit else { return nil }
        return await withCheckedContinuation { continuation in
            au.requestViewController { viewController in
                continuation.resume(returning: viewController)
            }
        }
    }

    /// User presets first, then factory. Key by array index — AU preset
    /// .number values repeat across banks on some vendors.
    func auPresets(track: Int) -> [AUAudioUnitPreset] {
        guard let au = auUnits[track]?.auAudioUnit else { return [] }
        let user = au.supportsUserPresets ? au.userPresets : []
        return user + (au.factoryPresets ?? [])
    }

    @MainActor
    func setAUPreset(track: Int, preset: AUAudioUnitPreset) {
        auUnits[track]?.auAudioUnit.currentPreset = preset
    }

    func currentAUPreset(track: Int) -> AUAudioUnitPreset? {
        auUnits[track]?.auAudioUnit.currentPreset
    }

    // MARK: - Render

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= 2,
              let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            // Never leave the hardware buffer with stale garbage.
            for buffer in buffers {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        lock.lock()
        let song = self.song
        let playing = self.playing
        if resetPending {
            resetPending = false
            stepPos = 0
            lastStepFired = -1
            countInStepsLeft = pendingCountIn
            pendingCountIn = 0
            inCountInShared = countInStepsLeft > 0  // publish before render body
            for i in recentLive.indices { recentLive[i].track = -1 } // stale step clocks
        }
        if countInAbort {
            countInAbort = false
            countInStepsLeft = 0
            inCountInShared = false
        }
        swap(&eventQueue, &renderEvents)   // no copy, no malloc
        let kits = self.kits
        let metronomeOn = self.metronomeOn
        let volume = self.mainVolume
        var cutoff = cutoffScale, res = resOverride
        var attack = attackScale, release = releaseScale
        var delaySendAmt = delaySend
        let suspend = autoSuspend
        let au = auSchedule
        var scenes = playingScene
        lock.unlock()

        // Clip automation (manual 14.2): evaluate internal lanes once per
        // block and override the encoder-set values. AU lanes are applied
        // from the main thread (parameter trees aren't render-safe).
        if playing && countInStepsLeft == 0 {
            for (t, track) in song.tracks.enumerated() where t < Self.maxTracks {
                guard t < scenes.count, let scene = scenes[t],
                      track.clips.indices.contains(scene) else { continue }
                let clip = track.clips[scene]
                guard let auto = clip.automation, !auto.isEmpty else { continue }
                let local = Double(clip.loopStartStep)
                    + stepPos.truncatingRemainder(dividingBy: Double(clip.loopSteps))
                let offLanes = clip.autoOff ?? []
                for (lane, points) in auto where !points.isEmpty {
                    guard !offLanes.contains(lane), !suspend[t].contains(lane) else { continue }
                    let v = Float(Self.autoValue(points, at: local))
                    switch lane {
                    case "cutoff": cutoff[t] = v
                    case "res": res[t] = v
                    case "attack": attack[t] = v
                    case "release": release[t] = v
                    case "delay": delaySendAmt[t] = v
                    default: break
                    }
                }
            }
        }

        // Fire due AU note-offs (scheduled by frame countdown).
        for i in pendingOffs.indices where pendingOffs[i].track >= 0 {
            if pendingOffs[i].frames <= Int32(frameCount) {
                let off = pendingOffs[i]
                if let block = au[Int(off.track)] {
                    var bytes: [UInt8] = [0x80, off.key, 0]
                    block(AUEventSampleTimeImmediate + Int64(max(0, off.frames)), 0, 3, &bytes)
                }
                pendingOffs[i].track = -1
            } else {
                pendingOffs[i].frames -= Int32(frameCount)
            }
        }

        // Fire immediate UI events.
        for event in renderEvents {
            trigger(event, song: song, kits: kits, cutoff: cutoff, res: res,
                    attack: attack, release: release, auBlocks: au)
            if event.on {
                recentLive[recentLiveIdx] = RecentLive(track: Int32(event.track),
                                                       key: Int32(event.key), at: stepPos)
                recentLiveIdx = (recentLiveIdx + 1) % recentLive.count
            }
        }
        renderEvents.removeAll(keepingCapacity: true) // uniquely owned here

        // Nudged notes (fractional step offsets) fire on a per-block scan:
        // early by at most one buffer (~3 ms), which beats per-frame scans.
        // Held back during the count-in bar just like on-grid notes.
        if playing && countInStepsLeft == 0 {
            let framesPerStepLocal = Self.sampleRate * 60 / max(20, song.tempo) / 4
            let windowStart = stepPos
            let windowEnd = stepPos + Double(frameCount) / framesPerStepLocal
            for (trackIndex, track) in song.tracks.enumerated() where !track.muted {
                guard trackIndex < scenes.count, let scene = scenes[trackIndex],
                      track.clips.indices.contains(scene) else { continue }
                let clip = track.clips[scene]
                let steps = Double(clip.loopSteps)
                for note in clip.notes where note.off != 0 {
                    if track.kind == .drum && track.mutedCells.contains(note.key) { continue }
                    if noteRecentlyPlayedLive(track: trackIndex, key: note.key, swing: song.swing) { continue }
                    let start = Double(note.step) + note.off - Double(clip.loopStartStep)
                    guard start >= 0 && start < steps else { continue } // outside the loop
                    // Does start (mod loop) fall inside this block's window?
                    let base = (windowStart / steps).rounded(.down) * steps
                    var wrap = base
                    while wrap <= base + steps {
                        let absolute = wrap + start
                        if absolute > windowStart && absolute <= windowEnd {
                            let lengthFrames = Int(note.lengthSteps * framesPerStepLocal)
                            let started = trigger(
                                LiveEvent(track: trackIndex, kind: track.kind, key: note.key,
                                          velocity: note.velocity, on: true,
                                          rate: note.pitch.map { powf(2, Float($0) / 12) } ?? 1),
                                song: song, kits: kits, cutoff: cutoff, res: res,
                                attack: attack, release: release, auBlocks: au,
                                frameOffset: Int((absolute - windowStart) * framesPerStepLocal),
                                offAfterFrames: lengthFrames)
                            started?.autoOffFrames = lengthFrames
                        }
                        wrap += steps
                    }
                }
            }
        }

        let framesPerStep = Self.sampleRate * 60 / max(20, song.tempo) / 4
        let stepInc = 1.0 / framesPerStep
        // Set effects: constants for this block (hoisted off the frame loop).
        let fx = song.fxParams ?? Self.fxDefaults
        let fxOn = fx.count >= 6
        let fxThresh: Float = fxOn ? pow(10, Float(fx[0]) / 20) : 1
        let fxRatio: Float = fxOn ? max(1, Float(fx[1])) : 1
        let fxMakeup: Float = fxOn ? pow(10, Float(fx[2]) / 20) : 1
        let fxDrive: Float = fxOn ? max(1, Float(fx[3])) : 1
        let fxTone: Float = fxOn ? 0.10 + 0.88 * Float(fx[4]) : 1
        let fxMix: Float = fxOn ? Float(fx[5]) : 0
        if !compEnv.isFinite { compEnv = 0 }
        if !satLPl.isFinite { satLPl = 0 }
        if !satLPr.isFinite { satLPr = 0 }
        var wetL: Float = 0, wetR: Float = 0
        // Per-track gain, applied at the voice sum (preallocated scratch).
        for i in 0..<Self.maxTracks {
            trackGain[i] = i < song.tracks.count ? Float(song.tracks[i].volume) : 1
        }

        for frame in 0..<frameCount {
            if playing, countInStepsLeft > 0 {
                // Count-in bar: metronome clicks only — the sequencer holds
                // until the bar completes, then position resets to step 0.
                let rawStep = Int(stepPos)
                if rawStep != lastStepFired {
                    lastStepFired = rawStep
                    if rawStep % 4 == 0 {
                        metroEnv = 1
                        metroPhase = 0
                    }
                }
                stepPos += stepInc
                if Int(stepPos) >= countInStepsLeft {
                    countInStepsLeft = 0
                    stepPos = 0
                    lastStepFired = -1
                }
            } else if playing {
                // Step boundary crossing (with swing on offbeat 16ths).
                // stepPos advances by rate, so tempo changes never warp position.
                let rawStep = Int(stepPos)
                if rawStep != lastStepFired {
                    let swingDelay = rawStep % 2 == 1 ? song.swing * 0.5 : 0
                    if stepPos >= Double(rawStep) + swingDelay {
                        lastStepFired = rawStep
                        if rawStep % 16 == 0 {
                            // Bar boundary: promote queued launches/stops.
                            lock.lock()
                            for t in 0..<Self.maxTracks {
                                if queuedStop[t] { playingScene[t] = nil; queuedStop[t] = false }
                                if let q = queuedScene[t] { playingScene[t] = q; queuedScene[t] = nil }
                            }
                            scenes = playingScene
                            lock.unlock()
                        }
                        fireStep(rawStep, song: song, kits: kits, scenes: scenes,
                                 cutoff: cutoff, res: res,
                                 attack: attack, release: release, auBlocks: au, frameOffset: frame)
                        if metronomeOn && rawStep % 4 == 0 {
                            metroEnv = 1
                            metroPhase = 0
                        }
                    }
                }
                stepPos += stepInc
            }

            var l: Float = 0, r: Float = 0
            for voice in drumVoices where voice.active {
                let (vl, vr) = voice.render()
                let t = max(0, min(Self.maxTracks - 1, voice.track))
                let gain = trackGain[t]
                l += vl * gain; r += vr * gain
                wetL += vl * gain * delaySendAmt[t]
                wetR += vr * gain * delaySendAmt[t]
            }
            for voice in synthVoices where voice.active {
                let v = voice.render()
                let t = max(0, min(Self.maxTracks - 1, voice.track))
                let gain = trackGain[t]
                l += v * gain; r += v * gain
                wetL += v * gain * delaySendAmt[t]
                wetR += v * gain * delaySendAmt[t]
            }

            // Metronome click (short sine blip).
            if metroEnv > 0.001 {
                metroPhase += 1800 / Float(Self.sampleRate)
                if metroPhase >= 1 { metroPhase -= 1 }
                let click = sin(2 * .pi * metroPhase) * metroEnv * 0.25
                l += click; r += click
                metroEnv *= 0.9992
            }

            // Tempo-synced delay (3/16), simple feedback, ping-ponged a bit.
            let delayFrames = min(delayL.count - 1, Int(framesPerStep * 3))
            let readPos = (delayPos - delayFrames + delayL.count) % delayL.count
            let dl = delayL[readPos], dr = delayR[readPos]
            delayL[delayPos] = wetL + dr * 0.45
            delayR[delayPos] = wetR + dl * 0.45
            delayPos = (delayPos + 1) % delayL.count
            wetL = 0; wetR = 0
            l += dl * 0.8; r += dr * 0.8

            // Set effects (manual 17.2): Dynamics -> Saturator, then limiter.
            if fxOn {
                let peak = max(abs(l), abs(r))
                compEnv = max(peak, compEnv * 0.9995)
                var gain: Float = 1
                if compEnv > fxThresh, fxRatio > 1 {
                    gain = pow(compEnv / fxThresh, 1 / fxRatio - 1)
                }
                l *= gain * fxMakeup
                r *= gain * fxMakeup
                if fxMix > 0.001 {
                    satLPl += (tanh(l * fxDrive) - satLPl) * fxTone
                    satLPr += (tanh(r * fxDrive) - satLPr) * fxTone
                    l = l * (1 - fxMix) + satLPl * fxMix * 0.9
                    r = r * (1 - fxMix) + satLPr * fxMix * 0.9
                }
            }

            // Master soft limiter.
            outL[frame] = tanh(l * volume * 1.2)
            outR[frame] = tanh(r * volume * 1.2)
        }

        // Publish playhead for the UI.
        lock.lock()
        playheadStep = stepPos
        inCountInShared = countInStepsLeft > 0
        lock.unlock()
    }

    private func fireStep(_ absStep: Int, song: Song, kits: [Int: LoadedKit], scenes: [Int?],
                          cutoff: [Float], res: [Float], attack: [Float], release: [Float],
                          auBlocks: [AUScheduleMIDIEventBlock?], frameOffset: Int) {
        for (trackIndex, track) in song.tracks.enumerated() where !track.muted {
            guard trackIndex < scenes.count, let scene = scenes[trackIndex],
                  track.clips.indices.contains(scene) else { continue }
            let clip = track.clips[scene]
            guard !clip.notes.isEmpty else { continue }
            let localStep = clip.localStep(absStep)
            for note in clip.notes where note.step == localStep && note.off == 0 {
                if track.kind == .drum && track.mutedCells.contains(note.key) { continue }
                if noteRecentlyPlayedLive(track: trackIndex, key: note.key, swing: song.swing) { continue }
                let lengthFrames = Int(note.lengthSteps * Self.sampleRate * 60 / max(20, song.tempo) / 4)
                let started = trigger(LiveEvent(track: trackIndex, kind: track.kind, key: note.key,
                                                velocity: note.velocity, on: true,
                                                rate: note.pitch.map { powf(2, Float($0) / 12) } ?? 1),
                                      song: song, kits: kits, cutoff: cutoff, res: res,
                                      attack: attack, release: release, auBlocks: auBlocks,
                                      frameOffset: frameOffset, offAfterFrames: lengthFrames)
                // Schedule the note-off on exactly the voice this step started
                // (matching by pitch would also cut finger-held notes short).
                started?.autoOffFrames = lengthFrames
            }
        }
    }

    /// Returns the synth voice it started (for length scheduling), else nil.
    @discardableResult
    private func trigger(_ event: LiveEvent, song: Song, kits: [Int: LoadedKit],
                         cutoff: [Float], res: [Float], attack: [Float], release: [Float],
                         auBlocks: [AUScheduleMIDIEventBlock?]? = nil,
                         frameOffset: Int = 0, offAfterFrames: Int = 0) -> SynthVoice? {
        let t = max(0, min(Self.maxTracks - 1, event.track))
        // AU-hosted track: translate to MIDI, schedule sample-accurately.
        if event.kind == .synth, let blocks = auBlocks, let block = blocks[t] {
            let key = UInt8(max(0, min(127, event.key)))
            if event.on {
                var bytes: [UInt8] = [0x90, key, UInt8(max(1, min(127, event.velocity)))]
                block(AUEventSampleTimeImmediate + Int64(frameOffset), 0, 3, &bytes)
                if offAfterFrames > 0 {
                    if let slot = pendingOffs.firstIndex(where: { $0.track < 0 }) {
                        pendingOffs[slot] = PendingOff(track: Int32(t), key: key,
                                                       frames: Int32(offAfterFrames + frameOffset))
                    } else {
                        // Ring full: a zero-length blip beats an infinite drone.
                        var offBytes: [UInt8] = [0x80, key, 0]
                        block(AUEventSampleTimeImmediate + Int64(frameOffset + 64), 0, 3, &offBytes)
                    }
                }
            } else {
                var bytes: [UInt8] = [0x80, key, 0]
                block(AUEventSampleTimeImmediate + Int64(frameOffset), 0, 3, &bytes)
            }
            return nil
        }
        voiceCounter += 1
        if event.kind == .drum {
            guard event.on, let kit = kits[t],
                  event.key >= 0, event.key < 16 else { return nil }
            let voice = drumVoices.first(where: { !$0.active })
                ?? drumVoices.min(by: { $0.order < $1.order })!   // steal oldest
            voice.order = voiceCounter
            let gain = song.tracks.indices.contains(t)
                ? Float(song.tracks[t].cellGains?[event.key] ?? 1.0) : 1.0
            voice.start(sample: kit.cells[event.key], track: t,
                        velocity: min(127, Int(Float(event.velocity) * gain)),
                        rate: event.rate)
        } else {
            if event.on {
                let soundIndex = song.tracks.indices.contains(t)
                    ? song.tracks[t].soundIndex : 0
                var preset = SynthPreset.all[soundIndex % SynthPreset.all.count]
                preset.attack *= attack[t]
                preset.release *= release[t]
                let voice = synthVoices.first(where: { !$0.active })
                    ?? synthVoices.min(by: { $0.order < $1.order })!   // steal oldest
                voice.order = voiceCounter
                voice.noteOn(track: t, note: event.key, velocity: event.velocity,
                             preset: preset, cutoffScale: cutoff[t],
                             resOverride: res[t])
                return voice
            } else {
                // Finger release: only end finger-held voices, not sequenced
                // ones running their own length countdown.
                for voice in synthVoices
                where voice.active && voice.track == t && voice.note == event.key
                    && voice.autoOffFrames == 0 {
                    voice.noteOff()
                }
            }
        }
        return nil
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                self?.configureSession()
                self?.engine.prepare()
                try? self?.engine.start()
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.engine.isRunning == false { try? self?.engine.start() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // The old graph is invalid after a media-services reset: rebuild.
            self.configureSession()
            lock.lock()
            for i in self.auSchedule.indices { self.auSchedule[i] = nil }
            lock.unlock()
            if let node = self.sourceNode { self.engine.detach(node) }
            self.sourceNode = nil
            for (_, au) in self.auUnits { self.engine.detach(au) }
            for (_, mixer) in self.auMixers { self.engine.detach(mixer) }
            self.auUnits.removeAll()
            self.auMixers.removeAll()
            self.start()
            self.onGraphRebuilt?()
        }
    }
}

/// Sample-playback voice for drum cells (with rate for 16 Pitches).
final class DrumVoice {
    var active = false
    var track = -1
    var order: UInt64 = 0
    private var sample = SampleBuffer()
    private var pos: Float = 0
    private var rate: Float = 1
    private var gain: Float = 1

    func start(sample: SampleBuffer, track: Int, velocity: Int, rate: Float) {
        guard sample.frames > 0 else { return }
        self.sample = sample
        self.track = track
        self.rate = max(0.05, rate)   // rate <= 0 would trap or hang the voice
        self.gain = Float(velocity) / 127
        pos = 0
        active = true
    }

    func render() -> (Float, Float) {
        let index = Int(pos)
        guard index < sample.frames - 1 else { active = false; return (0, 0) }
        // Linear interpolation between frames for pitched playback.
        let frac = pos - Float(index)
        let l = sample.left[index] * (1 - frac) + sample.left[index + 1] * frac
        let r = sample.right[index] * (1 - frac) + sample.right[index + 1] * frac
        pos += rate
        return (l * gain, r * gain)
    }
}
