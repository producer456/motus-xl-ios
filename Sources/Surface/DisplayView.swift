import SwiftUI

/// The 128x64 white OLED behind slightly glossy glass.
struct DisplayView: View {
    var image: CGImage?

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
                // Glass reflection.
                LinearGradient(colors: [.white.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .center)
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
