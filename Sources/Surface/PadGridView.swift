import SwiftUI
import UIKit

/// UIKit multi-touch surface for the 32 pads: instant touchesBegan response
/// (no gesture-recognizer latency), slide between pads, and pressure-ish
/// aftertouch from touch radius changes.
struct PadGridView: UIViewRepresentable {
    @EnvironmentObject var client: Brain
    var colors: [Int: SIMD3<Double>]
    var channels: [Int: Int]
    var tilt: CGPoint = .zero

    func makeUIView(context: Context) -> PadGridUIView {
        let view = PadGridUIView()
        view.client = client
        return view
    }

    func updateUIView(_ view: PadGridUIView, context: Context) {
        view.client = client
        view.apply(colors: colors, channels: channels)
        view.applyTilt(tilt)
    }
}

final class PadGridUIView: UIView {
    weak var client: Brain?

    static let columns = 8, rows = 8
    private var padLayers: [CALayer] = []
    private var hotspotLayers: [CAGradientLayer] = []
    private var pillowLayers: [CAGradientLayer] = []
    private var touchPads: [UITouch: Int] = [:]
    private var lastColors: [Int: SIMD3<Double>] = [:]
    private var lastChannels: [Int: Int] = [:]

    // Unlit silicone: matte mid-gray. The pads are physically white, but on
    // an emissive display a bright fill reads as "lit white" — unpowered
    // rubber under panel lighting has to sit much darker.
    private static let unlitColor = UIColor(red: 0.62, green: 0.615, blue: 0.60, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for _ in 0..<(Self.columns * Self.rows) {
            let pad = CALayer()
            pad.backgroundColor = Self.unlitColor.cgColor
            pad.shadowColor = UIColor.black.cgColor
            pad.shadowOpacity = 0.5
            pad.shadowRadius = 3
            pad.shadowOffset = CGSize(width: 0, height: 2)
            layer.addSublayer(pad)
            padLayers.append(pad)

            // LED hotspot: a lit pad is brightest over the point source at
            // its center, falling off into saturated color at the edges.
            let hotspot = CAGradientLayer()
            hotspot.type = .radial
            hotspot.startPoint = CGPoint(x: 0.5, y: 0.48)
            hotspot.endPoint = CGPoint(x: 1.15, y: 1.15)
            hotspot.isHidden = true
            hotspot.masksToBounds = true
            layer.addSublayer(hotspot)
            hotspotLayers.append(hotspot)

            // Pillow shading: soft top highlight fading out, faint shade at the
            // bottom edge — makes the flat layer read as domed silicone.
            let pillow = CAGradientLayer()
            pillow.colors = [UIColor.white.withAlphaComponent(0.20).cgColor,
                             UIColor.clear.cgColor,
                             UIColor.black.withAlphaComponent(0.10).cgColor]
            pillow.locations = [0.0, 0.45, 1.0]
            layer.addSublayer(pillow)
            pillowLayers.append(pillow)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var gap: CGFloat { bounds.width * 0.014 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cellW = (bounds.width - gap * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
        let cellH = (bounds.height - gap * CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
        for index in padLayers.indices {
            let row = index / Self.columns, col = index % Self.columns
            let frame = CGRect(x: CGFloat(col) * (cellW + gap),
                               y: CGFloat(row) * (cellH + gap),
                               width: cellW, height: cellH)
            // Photo-matched: the real pads are near-square-cornered (~7%).
            let radius = min(cellW, cellH) * 0.07
            padLayers[index].frame = frame
            padLayers[index].cornerRadius = radius
            hotspotLayers[index].frame = frame
            hotspotLayers[index].cornerRadius = radius
            pillowLayers[index].frame = frame
            pillowLayers[index].cornerRadius = radius
        }
        apply(colors: lastColors, channels: lastChannels, force: true)
    }

    func apply(colors: [Int: SIMD3<Double>], channels: [Int: Int], force: Bool = false) {
        if !force && colors == lastColors && channels == lastChannels { return }
        lastColors = colors
        lastChannels = channels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in padLayers.indices {
            let note = Brain.padNote(index)
            let rgb = colors[note]
            let isLit = rgb.map { $0.max() > 0.02 } ?? false
            if let rgb, isLit {
                // Backlit silicone: saturated body color with a near-white
                // hotspot over the LED itself.
                let color = UIColor(red: 0.08 + 0.80 * rgb.x, green: 0.08 + 0.80 * rgb.y,
                                    blue: 0.08 + 0.80 * rgb.z, alpha: 1)
                padLayers[index].backgroundColor = color.cgColor
                let hot = UIColor(red: 0.38 + 0.62 * rgb.x, green: 0.38 + 0.62 * rgb.y,
                                  blue: 0.38 + 0.62 * rgb.z, alpha: 0.55)
                let mid = UIColor(red: 0.10 + 0.90 * rgb.x, green: 0.10 + 0.90 * rgb.y,
                                  blue: 0.10 + 0.90 * rgb.z, alpha: 1)
                hotspotLayers[index].colors = [hot.cgColor, mid.withAlphaComponent(0.10).cgColor,
                                               UIColor.clear.cgColor]
                hotspotLayers[index].locations = [0.0, 0.45, 1.0]
                hotspotLayers[index].isHidden = false
                // The pad IS the light source: its silicone rim glows brightest.
                padLayers[index].borderWidth = 1.5
                padLayers[index].borderColor = UIColor(
                    red: 0.72 * rgb.x, green: 0.72 * rgb.y,
                    blue: 0.72 * rgb.z, alpha: 0.85).cgColor
                // Deck bleed is minimal on the real unit — color shows only in the
                // narrow gaps between pads and dies before open deck. Tight radius,
                // low opacity.
                padLayers[index].shadowColor = UIColor(
                    red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1).cgColor
                padLayers[index].shadowOpacity = 0.38
                padLayers[index].shadowRadius = max(6, gap * 3)
                padLayers[index].shadowOffset = .zero
                if (channels[note] ?? 0) != 0 {
                    startPulse(padLayers[index])
                    startPulse(hotspotLayers[index])
                } else {
                    stopPulse(padLayers[index])
                    stopPulse(hotspotLayers[index])
                }
            } else {
                hotspotLayers[index].isHidden = true
                padLayers[index].backgroundColor = Self.unlitColor.cgColor
                padLayers[index].borderWidth = 0
                // Restore the plain dark contact shadow.
                padLayers[index].shadowColor = UIColor.black.cgColor
                padLayers[index].shadowOpacity = 0.5
                padLayers[index].shadowRadius = 3
                padLayers[index].shadowOffset = CGSize(width: 0, height: 2)
                stopPulse(padLayers[index])
                stopPulse(hotspotLayers[index])
            }
        }
        CATransaction.commit()
    }

    /// Steer the pillow shading + contact shadows with the device tilt so
    /// the silicone reads as lit from a fixed room light.
    func applyTilt(_ tilt: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = CGPoint(x: 0.5 - tilt.x * 0.35, y: 0)
        let end = CGPoint(x: 0.5 + tilt.x * 0.35, y: 1)
        for i in pillowLayers.indices {
            pillowLayers[i].startPoint = start
            pillowLayers[i].endPoint = end
            // Only steer the resting shadow, not a lit pad's colored bleed.
            if padLayers[i].shadowColor == UIColor.black.cgColor {
                padLayers[i].shadowOffset = CGSize(width: -tilt.x * 2.5,
                                                   height: 2 - tilt.y * 2)
            }
        }
        CATransaction.commit()
    }

    private func startPulse(_ layer: CALayer) {
        guard layer.animation(forKey: "pulse") == nil else { return }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0; anim.toValue = 0.55
        anim.duration = 0.45
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "pulse")
    }

    private func stopPulse(_ layer: CALayer) {
        layer.removeAnimation(forKey: "pulse")
    }

    private func padIndex(at point: CGPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let cellW = bounds.width / CGFloat(Self.columns)
        let cellH = bounds.height / CGFloat(Self.rows)
        let col = min(Self.columns - 1, max(0, Int(point.x / cellW)))
        let row = min(Self.rows - 1, max(0, Int(point.y / cellH)))
        return row * Self.columns + col
    }

    private func velocity(for touch: UITouch) -> Int {
        // No force on iPad touches; approximate from contact radius.
        let radius = touch.majorRadius
        return max(40, min(127, Int(40 + (radius - 8) * 6)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = padIndex(at: touch.location(in: self)) else { continue }
            touchPads[touch] = index
            client?.pad(index, down: true, velocity: velocity(for: touch))
            pressVisual(index, down: true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let previous = touchPads[touch] else { continue }
            guard let index = padIndex(at: touch.location(in: self)) else { continue }
            if index != previous {
                client?.pad(previous, down: false)
                pressVisual(previous, down: false)
                client?.pad(index, down: true, velocity: velocity(for: touch))
                pressVisual(index, down: true)
                touchPads[touch] = index
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = touchPads.removeValue(forKey: touch) else { continue }
            client?.pad(index, down: false)
            pressVisual(index, down: false)
        }
    }

    private func pressVisual(_ index: Int, down: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        let transform = down
            ? CATransform3DMakeScale(0.96, 0.96, 1)
            : CATransform3DIdentity
        padLayers[index].transform = transform
        pillowLayers[index].transform = transform
        CATransaction.commit()
    }
}
