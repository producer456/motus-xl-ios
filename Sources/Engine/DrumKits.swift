import AVFoundation

/// A loaded drum kit: 16 cells of stereo float samples at 44.1 kHz.
final class LoadedKit {
    let name: String
    let cells: [SampleBuffer]   // exactly 16
    init(name: String, cells: [SampleBuffer]) {
        self.name = name
        self.cells = cells
    }
}

struct SampleBuffer {
    var left: [Float] = []
    var right: [Float] = []
    var frames: Int { left.count }
}

enum DrumKits {
    /// Kit folder names, sorted, discovered from the bundled DrumKits folder.
    static let names: [String] = {
        guard let root = Bundle.main.url(forResource: "DrumKits", withExtension: nil),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter(\.hasDirectoryPath).map(\.lastPathComponent).sorted()
    }()

    static func load(index: Int) -> LoadedKit? {
        guard names.indices.contains(index),
              let root = Bundle.main.url(forResource: "DrumKits", withExtension: nil) else { return nil }
        let name = names[index]
        let dir = root.appendingPathComponent(name)
        var cells: [SampleBuffer] = []
        for hit in 1...16 {
            let file = dir.appendingPathComponent(String(format: "hit_%02d.wav", hit))
            cells.append(loadSample(file) ?? SampleBuffer())
        }
        return LoadedKit(name: name, cells: cells)
    }

    /// Read any WAV into stereo 44.1k float arrays (converting if needed).
    static func loadSample(_ url: URL) -> SampleBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames),
              (try? file.read(into: inBuf)) != nil else { return nil }

        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buf: AVAudioPCMBuffer
        if inFormat.sampleRate == 44100 && inFormat.channelCount == 2 {
            buf = inBuf
        } else {
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
            let outFrames = AVAudioFrameCount(Double(frames) * 44100 / inFormat.sampleRate) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames) else { return nil }
            var fed = false
            converter.convert(to: outBuf, error: nil) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            buf = outBuf
        }
        let n = Int(buf.frameLength)
        guard n > 0, let data = buf.floatChannelData else { return nil }
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = buf.format.channelCount > 1
            ? Array(UnsafeBufferPointer(start: data[1], count: n))
            : left
        return SampleBuffer(left: left, right: right)
    }
}
