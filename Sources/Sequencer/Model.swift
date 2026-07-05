import Foundation

/// One note in a clip, quantized to a 1/16 step grid (Move default).
struct Note: Codable, Equatable {
    var step: Int           // 0..<clip.steps
    var key: Int            // drum cell 0..15 or MIDI note
    var velocity: Int       // 1...127
    var lengthSteps: Double = 1
}

struct Clip: Codable, Equatable {
    var bars: Int = 1                   // 1/2/4/8
    var notes: [Note] = []
    var steps: Int { bars * 16 }
    var isEmpty: Bool { notes.isEmpty }

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
    var volume: Double = 0.8
    var muted = false
    var clips: [Clip] = Array(repeating: Clip(), count: 8)   // 8 scenes
    var selectedPad: Int = 0            // drum: selected cell for step editing
    var octave: Int = 0                 // melodic layout octave shift
    var mutedCells: Set<Int> = []       // drum cell mutes
}

struct Song: Codable, Equatable {
    var name: String = "New Set"
    var tempo: Double = 120
    var swing: Double = 0               // 0...1 groove amount
    var rootNote: Int = 0               // 0 = C
    var scaleIndex: Int = 0
    var tracks: [Track] = Song.defaultTracks()
    var selectedTrack: Int = 0
    var selectedScene: Int = 0
    var padColorIndex: Int = 0          // Set Overview pad color

    static func defaultTracks() -> [Track] {
        [
            Track(kind: .drum, name: "Drums"),
            Track(kind: .synth, name: "Bass", soundIndex: 0),
            Track(kind: .synth, name: "Keys", soundIndex: 2),
            Track(kind: .synth, name: "Lead", soundIndex: 4),
        ]
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

    /// MIDI note for a melodic pad (index 0..31, row-major from top-left).
    /// Bottom row starts at the root; each row up is +3 scale degrees
    /// (Push-style in-key fourths).
    static func padToNote(_ index: Int, root: Int, scale: [Int], octave: Int) -> Int {
        let row = 3 - index / 8      // 0 = bottom row
        let col = index % 8
        let degree = row * 3 + col
        let oct = degree / scale.count
        let step = scale[degree % scale.count]
        return min(126, max(1, 48 + root + octave * 12 + oct * 12 + step))
    }
}
