import SwiftUI

// MARK: - Press/release hardware button wrapper

/// Sends press on touch-down and release on touch-up, like real hardware.
struct HardwareButton<Content: View>: View {
    var onPress: () -> Void
    var onRelease: () -> Void
    @ViewBuilder var content: (Bool) -> Content

    @State private var pressed = false

    var body: some View {
        content(pressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onPress() }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

// MARK: - Function button (round, icon, CC-backlit)

struct FunctionButton: View {
    @EnvironmentObject var client: Brain
    var id: String
    var systemImage: String? = nil
    var label: String? = nil
    var diameter: CGFloat
    var litColor: Color = .white

    var brightness: Double {
        guard let cc = Brain.buttonCC[id] else { return 0 }
        return Double(client.ccLeds[cc] ?? 0) / 127.0
    }

    var body: some View {
        HardwareButton {
            client.button(id, down: true)
        } onRelease: {
            client.button(id, down: false)
        } content: { pressed in
            ZStack {
                RoundButton(diameter: diameter, lit: brightness, color: litColor, pressed: pressed)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.36, weight: .medium))
                        .foregroundStyle(brightness > 0.3 ? Color.black.opacity(0.8) : Chrome.legend)
                } else if let label {
                    Text(label)
                        .font(.system(size: diameter * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(brightness > 0.3 ? Color.black.opacity(0.8) : Chrome.legend)
                }
            }
        }
    }
}

// MARK: - Step button (RGB-backlit round button, bottom row)

struct StepButton: View {
    @EnvironmentObject var client: Brain
    var index: Int
    var diameter: CGFloat

    var body: some View {
        let note = Brain.stepNote(index)
        let rgb = client.noteColors[note] ?? .zero
        let lit = rgb.max()
        HardwareButton {
            client.step(index, down: true)
        } onRelease: {
            client.step(index, down: false)
        } content: { pressed in
            ZStack {
                RoundButton(diameter: diameter,
                            lit: lit,
                            color: Color(red: rgb.x, green: rgb.y, blue: rgb.z),
                            pressed: pressed)
                Circle()
                    .fill(lit > 0.02 ? Color.white.opacity(0.9) : Color(white: 0.3))
                    .frame(width: diameter * 0.12, height: diameter * 0.12)
            }
        }
    }
}

// MARK: - Step legend (illuminated Shift-function label under a step button)

/// Tiny backlit legend printed on the deck below a step button. Nearly
/// invisible when dark (silkscreen on black); glows white when its function
/// is available (Shift held) or its toggle is active.
struct StepLegend: View {
    @EnvironmentObject var client: Brain
    var stepIndex: Int
    var systemImage: String? = nil
    var text: String? = nil
    var size: CGFloat

    private var brightness: Double {
        Double(client.ccLeds[200 + stepIndex] ?? 0) / 127.0
    }

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size, weight: .semibold))
            } else if let text {
                Text(text)
                    .font(.system(size: size, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(brightness > 0.02
                         ? Color.white.opacity(0.35 + 0.65 * brightness)
                         : Color(white: 0.16))
        .shadow(color: .white.opacity(0.7 * brightness),
                radius: brightness > 0.1 ? size * 0.35 : 0)
        .animation(.easeOut(duration: 0.12), value: brightness)
    }
}

// MARK: - Track button (vertical color bar)

struct TrackButton: View {
    @EnvironmentObject var client: Brain
    var index: Int   // 0 (top) ... 3
    var size: CGSize

    var body: some View {
        let note = Brain.trackNotes[index]
        let rgb = client.noteColors[note] ?? .zero
        let lit = rgb.max()
        let color = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
        HardwareButton {
            client.button("track\(index + 1)", down: true)
        } onRelease: {
            client.button("track\(index + 1)", down: false)
        } content: { pressed in
            Capsule()
                .fill(lit > 0.02 ? color : Color(white: 0.17))
                .overlay(Capsule().strokeBorder(Color(white: 0.30), lineWidth: 0.8))
                .shadow(color: lit > 0.02 ? color.opacity(0.9) : .clear, radius: size.width * 1.0)
                .frame(width: size.width, height: size.height)
                .scaleEffect(pressed ? 0.92 : 1)
        }
    }
}

// MARK: - Encoder (touch-sensitive, relative)

struct EncoderView: View {
    @EnvironmentObject var client: Brain
    var index: Int        // 0..7, or 8 = volume
    var diameter: CGFloat

    @State private var accumulated: CGFloat = 0
    @State private var touching = false

    var body: some View {
        KnobView(diameter: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !touching {
                            touching = true
                            accumulated = 0
                            client.encoderTouch(index, down: true)
                        }
                        // Vertical drag; ~7 pt per detent.
                        let delta = -value.translation.height - accumulated
                        let ticks = Int(delta / 7)
                        if ticks != 0 {
                            accumulated += CGFloat(ticks) * 7
                            for _ in 0..<abs(ticks) {
                                if index == 8 {
                                    client.volume(delta: ticks > 0 ? 1 : -1)
                                } else {
                                    client.encoder(index, delta: ticks > 0 ? 1 : -1)
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        touching = false
                        client.encoderTouch(index, down: false)
                    }
            )
    }
}

// MARK: - Main wheel (capacitive ring + click)

struct WheelView: View {
    @EnvironmentObject var client: Brain
    var diameter: CGFloat

    @State private var lastAngle: CGFloat?
    @State private var touching = false
    @State private var moved = false
    @State private var residual: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(colors: [Color(white: 0.20), Color(white: 0.06)],
                                   center: .init(x: 0.38, y: 0.32),
                                   startRadius: 0, endRadius: diameter * 0.8)
                )
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [Color(white: 0.32), Color(white: 0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: diameter * 0.03
                )
            // Finger dimple ring — subtle on the real unit, just a matte recess.
            Circle()
                .strokeBorder(Color.black.opacity(0.22), lineWidth: diameter * 0.09)
                .padding(diameter * 0.13)
                .blur(radius: 2.5)
            // Faint sheen, upper-left, matching the knobs.
            Ellipse()
                .fill(Color.white.opacity(0.05))
                .frame(width: diameter * 0.6, height: diameter * 0.32)
                .offset(x: -diameter * 0.08, y: -diameter * 0.24)
                .blur(radius: diameter * 0.09)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.6), radius: diameter * 0.05, y: diameter * 0.03)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !touching {
                        touching = true
                        moved = false
                        residual = 0
                        lastAngle = nil
                        client.wheelTouch(down: true)
                    }
                    let center = CGPoint(x: diameter / 2, y: diameter / 2)
                    let dx = value.location.x - center.x
                    let dy = value.location.y - center.y
                    // Dead zone: near the hub, tiny wobbles swing the angle
                    // wildly — spurious detents and lost tap-clicks.
                    guard (dx * dx + dy * dy).squareRoot() > diameter * 0.16 else {
                        lastAngle = nil
                        return
                    }
                    let angle = atan2(dy, dx)
                    if let last = lastAngle {
                        var diff = angle - last
                        if diff > .pi { diff -= 2 * .pi }
                        if diff < -.pi { diff += 2 * .pi }
                        residual += diff
                        // ~15 degrees per detent.
                        let detent: CGFloat = .pi / 12
                        while residual >= detent {
                            residual -= detent
                            moved = true
                            client.wheel(delta: 1)
                        }
                        while residual <= -detent {
                            residual += detent
                            moved = true
                            client.wheel(delta: -1)
                        }
                    }
                    lastAngle = angle
                }
                .onEnded { _ in
                    touching = false
                    client.wheelTouch(down: false)
                    if !moved {
                        // Tap = wheel click (confirm/select).
                        client.button("wheelPress", down: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            client.button("wheelPress", down: false)
                        }
                    }
                }
        )
    }
}
