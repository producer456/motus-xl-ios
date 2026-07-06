import SwiftUI
import UIKit

/// Fine deterministic noise, tiled across the chassis — kills the
/// "flat vector" look that betrays drawn hardware.
enum Grain {
    static let image: UIImage = {
        let size = 128
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8((seed >> 33) & 0xFF)
            let j = i * 4
            pixels[j] = v; pixels[j + 1] = v; pixels[j + 2] = v; pixels[j + 3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let cg = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }()
}

struct GrainOverlay: View {
    var opacity: Double = 0.045

    var body: some View {
        Image(uiImage: Grain.image)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// Shared hardware-realism styling for the Move panel.
enum Chrome {
    static let body = Color(red: 0.082, green: 0.082, blue: 0.090)
    static let bodyEdge = Color(red: 0.048, green: 0.048, blue: 0.054)
    static let padUnlit = Color(red: 0.92, green: 0.915, blue: 0.90)
    static let buttonFace = Color(red: 0.115, green: 0.115, blue: 0.125)
    static let buttonRing = Color(red: 0.24, green: 0.24, blue: 0.255)
    static let legend = Color(red: 0.78, green: 0.78, blue: 0.80)
}

/// Near-black matte rubber encoder knob — cylinder wall + slightly lighter
/// top face. `tilt` steers the specular light with device motion.
struct KnobView: View {
    var diameter: CGFloat
    var tilt: CGPoint = .zero

    var body: some View {
        ZStack {
            // Outer wall of the cylinder (darkest).
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.11), Color(white: 0.045)],
                                   center: .center,
                                   startRadius: diameter * 0.30, endRadius: diameter * 0.55)
                )
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color(white: 0.30), Color(white: 0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(1, diameter * 0.03)
                )
            // Machined serration: radial grip ticks around the skirt.
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2 - 0.5
                let inner = outer - size.width * 0.075
                for i in 0..<36 {
                    let a = Double(i) / 36 * 2 * .pi
                    var path = Path()
                    path.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                    path.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
                    ctx.stroke(path, with: .color(.black.opacity(0.42)),
                               lineWidth: max(0.6, size.width * 0.018))
                }
            }
            .allowsHitTesting(false)
            // Top face, set in from the wall — reads as the flat rubber cap.
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.185), Color(white: 0.075)],
                                   center: .init(x: 0.38 - tilt.x * 0.20,
                                                 y: 0.32 - tilt.y * 0.20),
                                   startRadius: 0, endRadius: diameter * 0.55)
                )
                .padding(diameter * 0.12)
            // Faint matte sheen, gliding with the room light.
            Ellipse()
                .fill(Color.white.opacity(0.06))
                .frame(width: diameter * 0.55, height: diameter * 0.30)
                .offset(x: -diameter * 0.06 - tilt.x * diameter * 0.14,
                        y: -diameter * 0.20 - tilt.y * diameter * 0.12)
                .blur(radius: diameter * 0.08)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.6), radius: diameter * 0.07,
                x: -tilt.x * diameter * 0.05, y: diameter * 0.05 - tilt.y * diameter * 0.04)
    }
}

/// Round hardware button with optional LED backlight and bloom.
struct RoundButton: View {
    var diameter: CGFloat
    var lit: Double = 0            // 0...1 backlight
    var color: Color = .white
    var pressed = false

    var body: some View {
        ZStack {
            // Extruded cap: lit top face falling to a shadowed base.
            Circle()
                .fill(
                    LinearGradient(colors: [Color(white: 0.155), Chrome.buttonFace,
                                            Color(white: 0.085)],
                                   startPoint: .top, endPoint: .bottom)
                )
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color(white: 0.34), Color(white: 0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.8, diameter * 0.045)
                )
            // Crisp highlight along the top edge of the cap.
            Circle()
                .trim(from: 0.56, to: 0.94)
                .stroke(Color.white.opacity(0.10), lineWidth: max(0.7, diameter * 0.03))
                .padding(diameter * 0.055)
            if lit > 0.02 {
                // Subtle light bleed onto the deck — soft falloff only, the
                // surface itself never lights.
                Circle()
                    .fill(color.opacity(0.30 * lit))
                    .padding(-diameter * 0.06)
                    .blur(radius: diameter * 0.22)
                // Backlit face.
                Circle()
                    .fill(color.opacity(0.35 + 0.65 * lit))
                    .padding(diameter * 0.13)
                    .blur(radius: diameter * 0.04)
                // Hot core — makes lit buttons read at a glance, like the photo.
                Circle()
                    .fill(Color.white.opacity(0.55 * lit))
                    .padding(diameter * 0.32)
                    .blur(radius: diameter * 0.10)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(pressed ? 0.94 : 1)
        .shadow(color: .black.opacity(0.5), radius: diameter * 0.06, y: diameter * 0.04)
    }
}

/// Recessed tray that pads/steps sit in — dark floor with a bevel that
/// reads as depth (bright bottom lip, shadowed top lip).
struct RecessedWell: View {
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(white: 0.065))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(colors: [Color.black.opacity(0.9),
                                                Color(white: 0.20)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.4)
            )
            .overlay(alignment: .top) {
                // Inner shadow cast by the top lip.
                LinearGradient(colors: [Color.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: cornerRadius * 1.6)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            }
            .allowsHitTesting(false)
    }
}

/// Hex-cap chassis screw.
struct Screw: View {
    var diameter: CGFloat
    var angle: Double = 37

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.34), Color(white: 0.12)],
                                   center: .init(x: 0.35, y: 0.3),
                                   startRadius: 0, endRadius: diameter * 0.7)
                )
            Circle()
                .strokeBorder(Color.black.opacity(0.75), lineWidth: diameter * 0.08)
            Rectangle() // drive slot
                .fill(Color.black.opacity(0.65))
                .frame(width: diameter * 0.62, height: diameter * 0.11)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.6), radius: diameter * 0.1, y: diameter * 0.06)
        .allowsHitTesting(false)
    }
}
