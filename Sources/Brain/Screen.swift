import CoreGraphics
import Foundation

/// 128x64 1-bit framebuffer with a 5x7 pixel font — the Move OLED look.
struct Screen {
    static let width = 128, height = 64
    var pixels = [Bool](repeating: false, count: width * height)

    mutating func clear() {
        pixels = [Bool](repeating: false, count: Self.width * Self.height)
    }

    mutating func set(_ x: Int, _ y: Int, _ on: Bool = true) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        pixels[y * Self.width + x] = on
    }

    mutating func fillRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, on: Bool = true) {
        for yy in y..<(y + h) { for xx in x..<(x + w) { set(xx, yy, on) } }
    }

    mutating func frameRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for xx in x..<(x + w) { set(xx, y); set(xx, y + h - 1) }
        for yy in y..<(y + h) { set(x, yy); set(x + w - 1, yy) }
    }

    mutating func hline(_ x: Int, _ y: Int, _ w: Int) {
        for xx in x..<(x + w) { set(xx, y) }
    }

    /// Draw text; size multiplies the 5x7 glyphs. Returns end x.
    @discardableResult
    mutating func text(_ string: String, x: Int, y: Int, size: Int = 1, invert: Bool = false) -> Int {
        var cx = x
        for ch in string.uppercased() where cx < Self.width {
            let glyph = Font5x7.glyph(ch)
            for col in 0..<5 {
                let bits = glyph[col]
                for row in 0..<7 where bits & (1 << row) != 0 {
                    for sx in 0..<size {
                        for sy in 0..<size {
                            set(cx + col * size + sx, y + row * size + sy, !invert)
                        }
                    }
                }
            }
            cx += 6 * size
        }
        return cx
    }

    mutating func textCentered(_ string: String, y: Int, size: Int = 1) {
        let w = string.count * 6 * size - size
        text(string, x: max(0, (Self.width - w) / 2), y: y, size: size)
    }

    /// Horizontal value bar with frame.
    mutating func bar(_ x: Int, _ y: Int, _ w: Int, _ h: Int, value: Double) {
        frameRect(x, y, w, h)
        let fill = Int(Double(w - 4) * min(1, max(0, value)))
        fillRect(x + 2, y + 2, fill, h - 4)
    }

    mutating func invertRegion(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        for yy in y..<(y + h) {
            for xx in x..<(x + w) {
                guard xx >= 0, xx < Self.width, yy >= 0, yy < Self.height else { continue }
                pixels[yy * Self.width + xx].toggle()
            }
        }
    }

    func render() -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        for i in pixels.indices where pixels[i] {
            let j = i * 4
            rgba[j] = 255; rgba[j + 1] = 255; rgba[j + 2] = 255; rgba[j + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: Self.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// Classic 5x7 column-major font (LSB = top row). Uppercase + digits + symbols.
enum Font5x7 {
    static func glyph(_ ch: Character) -> [UInt8] {
        glyphs[ch] ?? glyphs["?"]!
    }

    static let glyphs: [Character: [UInt8]] = [
        " ": [0x00, 0x00, 0x00, 0x00, 0x00],
        "!": [0x00, 0x00, 0x5F, 0x00, 0x00],
        "\"": [0x00, 0x07, 0x00, 0x07, 0x00],
        "#": [0x14, 0x7F, 0x14, 0x7F, 0x14],
        "$": [0x24, 0x2A, 0x7F, 0x2A, 0x12],
        "%": [0x23, 0x13, 0x08, 0x64, 0x62],
        "&": [0x36, 0x49, 0x55, 0x22, 0x50],
        "'": [0x00, 0x05, 0x03, 0x00, 0x00],
        "(": [0x00, 0x1C, 0x22, 0x41, 0x00],
        ")": [0x00, 0x41, 0x22, 0x1C, 0x00],
        "*": [0x14, 0x08, 0x3E, 0x08, 0x14],
        "+": [0x08, 0x08, 0x3E, 0x08, 0x08],
        ",": [0x00, 0x50, 0x30, 0x00, 0x00],
        "-": [0x08, 0x08, 0x08, 0x08, 0x08],
        ".": [0x00, 0x60, 0x60, 0x00, 0x00],
        "/": [0x20, 0x10, 0x08, 0x04, 0x02],
        "0": [0x3E, 0x51, 0x49, 0x45, 0x3E],
        "1": [0x00, 0x42, 0x7F, 0x40, 0x00],
        "2": [0x42, 0x61, 0x51, 0x49, 0x46],
        "3": [0x21, 0x41, 0x45, 0x4B, 0x31],
        "4": [0x18, 0x14, 0x12, 0x7F, 0x10],
        "5": [0x27, 0x45, 0x45, 0x45, 0x39],
        "6": [0x3C, 0x4A, 0x49, 0x49, 0x30],
        "7": [0x01, 0x71, 0x09, 0x05, 0x03],
        "8": [0x36, 0x49, 0x49, 0x49, 0x36],
        "9": [0x06, 0x49, 0x49, 0x29, 0x1E],
        ":": [0x00, 0x36, 0x36, 0x00, 0x00],
        ";": [0x00, 0x56, 0x36, 0x00, 0x00],
        "<": [0x08, 0x14, 0x22, 0x41, 0x00],
        "=": [0x14, 0x14, 0x14, 0x14, 0x14],
        ">": [0x00, 0x41, 0x22, 0x14, 0x08],
        "?": [0x02, 0x01, 0x51, 0x09, 0x06],
        "@": [0x32, 0x49, 0x79, 0x41, 0x3E],
        "A": [0x7E, 0x11, 0x11, 0x11, 0x7E],
        "B": [0x7F, 0x49, 0x49, 0x49, 0x36],
        "C": [0x3E, 0x41, 0x41, 0x41, 0x22],
        "D": [0x7F, 0x41, 0x41, 0x22, 0x1C],
        "E": [0x7F, 0x49, 0x49, 0x49, 0x41],
        "F": [0x7F, 0x09, 0x09, 0x09, 0x01],
        "G": [0x3E, 0x41, 0x49, 0x49, 0x7A],
        "H": [0x7F, 0x08, 0x08, 0x08, 0x7F],
        "I": [0x00, 0x41, 0x7F, 0x41, 0x00],
        "J": [0x20, 0x40, 0x41, 0x3F, 0x01],
        "K": [0x7F, 0x08, 0x14, 0x22, 0x41],
        "L": [0x7F, 0x40, 0x40, 0x40, 0x40],
        "M": [0x7F, 0x02, 0x0C, 0x02, 0x7F],
        "N": [0x7F, 0x04, 0x08, 0x10, 0x7F],
        "O": [0x3E, 0x41, 0x41, 0x41, 0x3E],
        "P": [0x7F, 0x09, 0x09, 0x09, 0x06],
        "Q": [0x3E, 0x41, 0x51, 0x21, 0x5E],
        "R": [0x7F, 0x09, 0x19, 0x29, 0x46],
        "S": [0x46, 0x49, 0x49, 0x49, 0x31],
        "T": [0x01, 0x01, 0x7F, 0x01, 0x01],
        "U": [0x3F, 0x40, 0x40, 0x40, 0x3F],
        "V": [0x1F, 0x20, 0x40, 0x20, 0x1F],
        "W": [0x3F, 0x40, 0x38, 0x40, 0x3F],
        "X": [0x63, 0x14, 0x08, 0x14, 0x63],
        "Y": [0x07, 0x08, 0x70, 0x08, 0x07],
        "Z": [0x61, 0x51, 0x49, 0x45, 0x43],
        "[": [0x00, 0x7F, 0x41, 0x41, 0x00],
        "]": [0x00, 0x41, 0x41, 0x7F, 0x00],
        "^": [0x04, 0x02, 0x01, 0x02, 0x04],
        "_": [0x40, 0x40, 0x40, 0x40, 0x40],
        "|": [0x00, 0x00, 0x7F, 0x00, 0x00],
        "~": [0x08, 0x04, 0x08, 0x10, 0x08],
    ]
}
