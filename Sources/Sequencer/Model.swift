import Foundation

/// One note in a clip, quantized to a 1/16 step grid (Move default).
struct Note: Codable, Equatable {
    var step: Int           // 0..<clip.steps
    var key: Int            // drum cell 0..15 or MIDI note
    var velocity: Int       // 1...127
    var lengthSteps: Double = 1
    /// Nudge as a fraction of a step (manual 11.4). Optional so sets saved
    /// before this field existed still decode.
    var offset: Double?
    /// 16 Pitches (manual 9.2): semitone offset from the sample's root for
    /// pitched drum-cell notes. nil = unpitched. Optional so old sets decode.
    var pitch: Int?

    var off: Double { offset ?? 0 }
}

/// One automation breakpoint: pos in (fractional) steps, raw param value.
struct AutoPoint: Codable, Equatable {
    var pos: Double
    var value: Double
}

struct Clip: Codable, Equatable {
    var bars: Int = 1                   // content END, in bars (1...16)
    var notes: [Note] = []
    /// Loop START bar (manual 12.1: press start+end steps in Loop Mode).
    /// Notes before it stay in the clip but don't play. Optional so old
    /// sets decode (nil = 0).
    var loopStart: Int?
    /// Parameter automation (manual 14.2): lane key -> breakpoints. Internal
    /// lanes: cutoff/res/attack/release/delay. AU lanes: "au.<address>".
    var automation: [String: [AutoPoint]]?
    /// Deactivated lanes (manual 14.2.1) — kept but not played.
    var autoOff: [String]?
    var steps: Int { bars * 16 }
    var isEmpty: Bool { notes.isEmpty }

    /// First step of the playing region.
    var loopStartStep: Int { min(max(0, loopStart ?? 0), max(0, bars - 1)) * 16 }
    /// Length of the playing region in steps (always >= 16).
    var loopSteps: Int { max(16, steps - loopStartStep) }
    /// Map an absolute transport step into the playing region.
    func localStep(_ absStep: Int) -> Int {
        loopStartStep + ((absStep % loopSteps) + loopSteps) % loopSteps
    }

    mutating func toggle(step: Int, key: Int, velocity: Int = 100) {
        if let i = notes.firstIndex(where: { $0.step == step && $0.key == key }) {
            notes.remove(at: i)
        } else {
            notes.append(Note(step: step, key: key, velocity: velocity))
        }
    }
}

enum TrackKind: String, Codable { case drum, synth }

struct Track: Codable, Equatable {
    var kind: TrackKind
    var name: String
    var soundIndex: Int = 0             // kit index (drum) or preset index (synth)
    /// AUv3 instrument on this track ("type:subtype:manufacturer" fourCC
    /// values, decimal). nil = internal synth. Optional so old sets decode.
    var auIdentifier: String?
    var auName: String?
    var auPresetName: String?
    var volume: Double = 0.8
    var muted = false
    var clips: [Clip] = Array(repeating: Clip(), count: 8)   // 8 scenes
    var selectedPad: Int = 0            // drum: selected cell for step editing
    var octave: Int = 0                 // melodic layout octave shift
    var mutedCells: Set<Int> = []       // drum cell mutes
    /// Per-drum-cell sample gain (pad-hold + Volume, manual 16.5). nil = 1.0.
    var cellGains: [Int: Double]?
    /// Sidechain (XL exclusive): this track ducks when `duckSource` fires.
    /// duckCell scopes drum sources to one cell (nil = any note);
    /// duckAmount = depth 0-1; duckRelease = seconds. All optional so old
    /// sets decode.
    var duckSource: Int?
    var duckCell: Int?
    var duckAmount: Double?
    var duckRelease: Double?
}

struct Song: Codable, Equatable {
    var name: String = "New Set"
    var tempo: Double = 120
    var swing: Double = 0               // 0...1 groove amount
    var rootNote: Int = 0               // 0 = C
    var scaleIndex: Int = 0
    /// Chromatic pad layout (manual 9.1); nil/false = In-Key. Saved with the Set.
    var chromatic: Bool?
    var tracks: [Track] = Song.defaultTracks()
    var selectedTrack: Int = 0
    var selectedScene: Int = 0
    /// Set effects (manual 17.2): Dynamics thresh dB/ratio/makeup dB +
    /// Saturator drive/color/mix. nil = defaults.
    var fxParams: [Double]?
    var padColorIndex: Int = 0          // Set Overview pad color

    /// Move XL: 8 tracks — two drum, six synth.
    static func defaultTracks() -> [Track] {
        [
            Track(kind: .drum, name: "Drums"),
            Track(kind: .drum, name: "Perc", soundIndex: 5),
            Track(kind: .synth, name: "Bass", soundIndex: 0),
            Track(kind: .synth, name: "Keys", soundIndex: 2),
            Track(kind: .synth, name: "Pad", soundIndex: 3),
            Track(kind: .synth, name: "Lead", soundIndex: 4),
            Track(kind: .synth, name: "Pluck", soundIndex: 5),
            Track(kind: .synth, name: "Stack", soundIndex: 7),
        ]
    }
}

extension Song {
    /// Seeded on first launch so there's something to play with immediately:
    /// a two-bar C-minor groove across drums, perc, bass, keys, and pad.
    static func demo() -> Song {
        var song = Song()
        song.name = "XL Demo"
        song.tempo = 112
        song.swing = 0.10
        song.rootNote = 0
        song.scaleIndex = 1 // minor

        func fill(_ track: Int, _ notes: [(Int, Int, Int, Double)]) {
            var clip = Clip(bars: 2)
            clip.notes = notes.map { Note(step: $0.0, key: $0.1, velocity: $0.2, lengthSteps: $0.3) }
            song.tracks[track].clips[0] = clip
        }

        // Drums: four-on-the-floor kick, backbeat snare, offbeat hats.
        var drums: [(Int, Int, Int, Double)] = []
        for step in stride(from: 0, to: 32, by: 4) { drums.append((step, 0, 118, 1)) }
        for step in [4, 12, 20, 28] { drums.append((step, 1, 108, 1)) }
        for step in stride(from: 2, to: 32, by: 4) { drums.append((step, 2, 78, 1)) }
        for step in [14, 30] { drums.append((step, 3, 92, 1)) }
        fill(0, drums)

        // Perc accents.
        fill(1, [(3, 4, 70, 1), (11, 4, 70, 1), (19, 4, 70, 1), (27, 4, 74, 1),
                 (7, 6, 86, 1), (23, 6, 86, 1)])

        // Bass: C minor line.
        fill(2, [(0, 36, 112, 1.5), (3, 36, 96, 0.5), (6, 39, 104, 1),
                 (8, 36, 112, 1.5), (11, 36, 96, 0.5), (14, 34, 104, 1.5),
                 (16, 36, 112, 1.5), (19, 36, 96, 0.5), (22, 39, 104, 1),
                 (24, 41, 110, 1.5), (27, 41, 94, 0.5), (30, 43, 106, 1.5)])

        // Keys: Cm / Ab / Cm / Bb stabs.
        fill(3, [(0, 60, 82, 6), (0, 63, 82, 6), (0, 67, 82, 6),
                 (8, 56, 78, 6), (8, 60, 78, 6), (8, 63, 78, 6),
                 (16, 60, 82, 6), (16, 63, 82, 6), (16, 67, 82, 6),
                 (24, 58, 80, 6), (24, 62, 80, 6), (24, 65, 80, 6)])

        // Pad: one long Cm drone underneath.
        fill(4, [(0, 48, 68, 32), (0, 51, 68, 32), (0, 55, 68, 32)])

        return song
    }
}

enum Scales {
    static let all: [(name: String, steps: [Int])] = [
        ("Major", [0, 2, 4, 5, 7, 9, 11]),
        ("Minor", [0, 2, 3, 5, 7, 8, 10]),
        ("Dorian", [0, 2, 3, 5, 7, 9, 10]),
        ("Mixolydian", [0, 2, 4, 5, 7, 9, 10]),
        ("Lydian", [0, 2, 4, 6, 7, 9, 11]),
        ("Phrygian", [0, 1, 3, 5, 7, 8, 10]),
        ("Minor Pent", [0, 3, 5, 7, 10]),
        ("Major Pent", [0, 2, 4, 7, 9]),
        ("Harm Minor", [0, 2, 3, 5, 7, 8, 11]),
        ("Chromatic", Array(0...11)),
    ]
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// MIDI note for a melodic pad (index 0..63, row-major from top-left).
    /// In-Key (manual 9.1): each row is an octave walking the scale from the
    /// root; short scales roll into the next octave within the row.
    /// Chromatic: fretboard — right = +1 semitone, up = +5 (perfect fourth).
    static func padToNote(_ index: Int, root: Int, scale: [Int], octave: Int,
                          chromatic: Bool = false) -> Int {
        let row = 7 - index / 8      // 0 = bottom row
        let col = index % 8
        if chromatic {
            return min(126, max(1, 36 + root + octave * 12 + row * 5 + col))
        }
        let oct = col / scale.count
        let step = scale[col % scale.count]
        return min(126, max(1, 36 + root + (octave + row) * 12 + oct * 12 + step))
    }
}
