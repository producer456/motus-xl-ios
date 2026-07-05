import Foundation

struct SynthPreset {
    var name: String
    var wave: Wave              // primary oscillator
    var detune: Float           // osc2 detune in cents (0 = single osc)
    var subLevel: Float         // sine sub-osc one octave down
    var cutoff: Float           // Hz
    var resonance: Float        // 0...0.95
    var filterEnv: Float        // env -> cutoff amount (Hz)
    var attack: Float           // seconds
    var decay: Float
    var sustain: Float
    var release: Float
    var glow: Float = 0         // slow analog drift depth

    enum Wave { case saw, square, triangle, sine }

    static let all: [SynthPreset] = [
        SynthPreset(name: "Deep Bass", wave: .square, detune: 0, subLevel: 0.7,
                    cutoff: 400, resonance: 0.2, filterEnv: 900,
                    attack: 0.003, decay: 0.25, sustain: 0.5, release: 0.12),
        SynthPreset(name: "Acid Bass", wave: .saw, detune: 0, subLevel: 0.2,
                    cutoff: 300, resonance: 0.85, filterEnv: 2600,
                    attack: 0.002, decay: 0.18, sustain: 0.1, release: 0.08),
        SynthPreset(name: "Lo-Fi Keys", wave: .triangle, detune: 6, subLevel: 0.15,
                    cutoff: 2200, resonance: 0.15, filterEnv: 600,
                    attack: 0.004, decay: 0.5, sustain: 0.4, release: 0.35, glow: 0.4),
        SynthPreset(name: "Dream Pad", wave: .saw, detune: 12, subLevel: 0.3,
                    cutoff: 1200, resonance: 0.25, filterEnv: 400,
                    attack: 0.6, decay: 1.2, sustain: 0.8, release: 1.2, glow: 0.6),
        SynthPreset(name: "Solar Lead", wave: .square, detune: 8, subLevel: 0,
                    cutoff: 3400, resonance: 0.35, filterEnv: 1200,
                    attack: 0.005, decay: 0.3, sustain: 0.7, release: 0.2),
        SynthPreset(name: "Pluck", wave: .saw, detune: 5, subLevel: 0.1,
                    cutoff: 900, resonance: 0.4, filterEnv: 3200,
                    attack: 0.001, decay: 0.16, sustain: 0.0, release: 0.14),
        SynthPreset(name: "Glass Organ", wave: .sine, detune: 4, subLevel: 0.5,
                    cutoff: 5000, resonance: 0.05, filterEnv: 0,
                    attack: 0.01, decay: 0.1, sustain: 0.9, release: 0.15),
        SynthPreset(name: "Saw Stack", wave: .saw, detune: 18, subLevel: 0.25,
                    cutoff: 2600, resonance: 0.2, filterEnv: 800,
                    attack: 0.01, decay: 0.4, sustain: 0.75, release: 0.3),
    ]
}

/// One polyphonic synth voice: 2 PolyBLEP oscillators + sub, SVF low-pass,
/// amp + filter envelopes. Everything runs per-sample on the render thread.
final class SynthVoice {
    var active = false
    var track = -1
    var note = -1
    var order: UInt64 = 0
    private var phase1: Float = 0
    private var phase2: Float = 0
    private var subPhase: Float = 0
    private var freq: Float = 440
    private var velocity: Float = 1
    private var preset = SynthPreset.all[0]

    // Envelope state
    private enum Stage { case attack, decay, sustain, release, done }
    private var stage = Stage.done
    private var env: Float = 0
    private var released = false

    // SVF state (Chamberlin)
    private var low: Float = 0
    private var band: Float = 0

    // Per-voice cutoff/res live-tweak (from encoders), applied on top of preset.
    var cutoffScale: Float = 1
    var resOverride: Float = -1
    /// Sequencer-scheduled note-off countdown (frames); 0 = held by finger.
    var autoOffFrames = 0

    private var drift: Float = 0
    private var driftTarget: Float = 0
    private var driftCounter = 0

    static let sampleRate: Float = 44100

    func noteOn(track: Int, note: Int, velocity: Int, preset: SynthPreset,
                cutoffScale: Float, resOverride: Float) {
        self.track = track
        self.note = note
        self.velocity = Float(velocity) / 127
        self.preset = preset
        self.cutoffScale = cutoffScale
        self.resOverride = resOverride
        freq = 440 * pow(2, (Float(note) - 69) / 12)
        stage = .attack
        env = 0
        released = false
        autoOffFrames = 0   // stale countdown from a reused voice kills new notes early
        active = true
        // Phase-randomize so stacked notes don't comb (DSP research note).
        phase1 = Float.random(in: 0..<1)
        phase2 = Float.random(in: 0..<1)
        subPhase = 0
        low = 0; band = 0
    }

    func noteOff() { released = true }
    func kill() { active = false; stage = .done }

    private func polyBlep(_ t: Float, dt: Float) -> Float {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    private func osc(_ phase: inout Float, freq: Float) -> Float {
        let dt = freq / Self.sampleRate
        phase += dt
        if phase >= 1 { phase -= 1 }
        switch preset.wave {
        case .sine:
            return sin(2 * .pi * phase)
        case .triangle:
            // Integrated square would drift; cheap triangle is fine here.
            return 4 * abs(phase - 0.5) - 1
        case .saw:
            return (2 * phase - 1) - polyBlep(phase, dt: dt)
        case .square:
            var v: Float = phase < 0.5 ? 1 : -1
            v += polyBlep(phase, dt: dt)
            v -= polyBlep(fmod(phase + 0.5, 1), dt: dt)
            return v
        }
    }

    func render() -> Float {
        guard active else { return 0 }

        if autoOffFrames > 0 {
            autoOffFrames -= 1
            if autoOffFrames == 0 { released = true }
        }

        // Envelope
        switch stage {
        case .attack:
            env += 1 / max(0.001, preset.attack) / Self.sampleRate
            if env >= 1 { env = 1; stage = .decay }
        case .decay:
            env -= (1 - preset.sustain) / max(0.005, preset.decay) / Self.sampleRate
            if env <= preset.sustain { env = preset.sustain; stage = .sustain }
        case .sustain:
            break
        case .release, .done:
            break
        }
        if released && stage != .release {
            stage = .release
        }
        if stage == .release {
            env -= 1 / max(0.005, preset.release) / Self.sampleRate
            if env <= 0 { kill(); return 0 }
        }

        // Slow analog drift (few cents), updated at control-ish rate.
        driftCounter -= 1
        if driftCounter <= 0 {
            driftCounter = 512
            driftTarget = Float.random(in: -1...1) * preset.glow * 0.003
        }
        drift += (driftTarget - drift) * 0.001

        let f = freq * (1 + drift)
        var sample = osc(&phase1, freq: f)
        if preset.detune > 0 {
            sample += osc(&phase2, freq: f * pow(2, preset.detune / 1200))
            sample *= 0.55
        }
        if preset.subLevel > 0 {
            subPhase += (f / 2) / Self.sampleRate
            if subPhase >= 1 { subPhase -= 1 }
            sample += sin(2 * .pi * subPhase) * preset.subLevel
        }

        // SVF low-pass with filter envelope and keytracking. The Chamberlin
        // topology goes unstable above ~sr/6, so clamp fc hard (7 kHz) —
        // musically plenty for a low-pass — and cap the coefficient.
        let envHz = preset.filterEnv * env * velocity
        var fc = (preset.cutoff * cutoffScale + envHz + freq * 0.35)
        fc = min(7000, max(30, fc))
        let f1 = min(0.95, 2 * sin(.pi * fc / Self.sampleRate))
        let res = resOverride >= 0 ? resOverride : preset.resonance
        let q = 1 - res
        low += f1 * band
        let high = sample - low - max(0.1, 2 * q) * band
        band += f1 * high
        var out = low

        out *= env * velocity * 0.5
        if !out.isFinite {
            // Filter blew up (extreme settings): reset state, stay silent.
            low = 0; band = 0
            return 0
        }
        return out
    }
}
