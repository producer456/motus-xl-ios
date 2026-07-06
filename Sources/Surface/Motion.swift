import SwiftUI
import CoreMotion
import UIKit

/// Device tilt as a "room light" direction for the fascia: gravity is
/// low-passed into a -1...1 screen-space vector at 20 Hz. Flat on a table
/// reads as (0, 0) — the light sits straight overhead.
final class MotionSource: ObservableObject {
    @Published var tilt: CGPoint = .zero

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let g = motion?.gravity else { return }
            // Map portrait-referenced gravity into landscape screen space.
            var x = CGFloat(g.y), y = CGFloat(-g.x)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               scene.interfaceOrientation == .landscapeLeft {
                x = -x; y = -y
            }
            let target = CGPoint(x: max(-1, min(1, x * 2.2)),
                                 y: max(-1, min(1, y * 2.2)))
            // Low-pass so the light glides instead of jittering.
            tilt = CGPoint(x: tilt.x + (target.x - tilt.x) * 0.12,
                           y: tilt.y + (target.y - tilt.y) * 0.12)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}
