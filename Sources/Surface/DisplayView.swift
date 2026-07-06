import SwiftUI

/// The 128x64 white OLED behind slightly glossy glass.
struct DisplayView: View {
    var image: CGImage?
    var tilt: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: geo.size.height * 0.07)
                    .fill(Color.black)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .padding(geo.size.height * 0.06)
                        .shadow(color: .white.opacity(0.35), radius: 1.2) // OLED bloom
                }
                // Glass reflection, steered by the light direction.
                LinearGradient(colors: [.white.opacity(0.10 + 0.05 * abs(tilt.y)), .clear],
                               startPoint: .init(x: 0.15 - tilt.x * 0.3,
                                                 y: 0.0 - tilt.y * 0.2),
                               endPoint: .init(x: 0.55 - tilt.x * 0.3,
                                               y: 0.55 - tilt.y * 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: geo.size.height * 0.07))
                // Recess: the screen sits below the deck, so its top edge shades.
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .center)
                    .frame(height: geo.size.height * 0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: geo.size.height * 0.07))
                RoundedRectangle(cornerRadius: geo.size.height * 0.07)
                    .strokeBorder(Color(white: 0.18), lineWidth: 1)
            }
        }
    }
}
