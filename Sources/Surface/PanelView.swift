import SwiftUI

/// "Move XL" — the imagined big sibling of the Move, at the 11" iPad Pro's
/// footprint: 8 tracks, a 256x128 OLED that shows all of them at once, and
/// the original Move's wide pad shape. Laid out in a 1000x699 design space.
struct PanelView: View {
    @EnvironmentObject var client: Brain

    static let designSize = CGSize(width: 1000, height: 699)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.designSize.width,
                            geo.size.height / Self.designSize.height)
            ZStack {
                Color.black.ignoresSafeArea()
                panel(scale: scale)
                    .frame(width: Self.designSize.width * scale,
                           height: Self.designSize.height * scale)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }

    private func panel(scale s: CGFloat) -> some View {
        ZStack {
            // Body shell — matte black with a faint top-light sheen.
            RoundedRectangle(cornerRadius: 26 * s)
                .fill(
                    LinearGradient(colors: [Color(white: 0.105), Chrome.body, Chrome.bodyEdge],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26 * s)
                        .strokeBorder(
                            LinearGradient(colors: [Color(white: 0.24), Chrome.bodyEdge],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5 * s)
                )
                .shadow(color: .black.opacity(0.8), radius: 18 * s, y: 6 * s)

            // ---- Top zone: the XL's big OLED (256x128), encoders, volume ----
            DisplayView(image: client.displayImage)
                .frame(width: 360 * s, height: 180 * s)
                .position(x: 210 * s, y: 112 * s)

            ForEach(0..<8, id: \.self) { index in
                EncoderView(index: index, diameter: 50 * s)
                    .position(x: encoderX(index) * s, y: 60 * s)
                Circle() // touch indicator dot under each encoder
                    .fill(Color(white: 0.38))
                    .frame(width: 6 * s, height: 6 * s)
                    .position(x: encoderX(index) * s, y: 101 * s)
            }

            Circle() // microphone hole
                .fill(Color.black)
                .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 0.8 * s))
                .frame(width: 8 * s, height: 8 * s)
                .position(x: 936 * s, y: 28 * s)

            EncoderView(index: 8, diameter: 58 * s) // volume
                .position(x: 938 * s, y: 90 * s)

            // ---- Left rail: wheel, back / mode ----
            WheelView(diameter: 110 * s)
                .position(x: 78 * s, y: 330 * s)

            FunctionButton(id: "back", systemImage: "chevron.left", diameter: 40 * s)
                .position(x: 46 * s, y: 425 * s)
            FunctionButton(id: "note", systemImage: "line.3.horizontal", diameter: 40 * s)
                .position(x: 110 * s, y: 425 * s)

            // ---- 8 track buttons, a ladder spanning the grid ----
            ForEach(0..<8, id: \.self) { index in
                TrackButton(index: index, size: CGSize(width: 13 * s, height: 24 * s))
                    .position(x: 152 * s, y: (262 + CGFloat(index) * 31) * s)
            }

            // ---- Pad grid: original Move pad shape (wide 1.5:1) ----
            PadGridView(colors: client.noteColors, channels: client.noteChannels)
                .frame(width: 708 * s, height: 243 * s)
                .position(x: 532 * s, y: 371 * s)

            // ---- Right rail (2 x 4 function buttons) ----
            rightButton("capture", icon: "viewfinder", column: 0, row: 0, s: s)
            rightButton("sample", icon: "waveform", column: 1, row: 0, s: s)
            rightButton("loop", icon: "repeat", column: 0, row: 1, s: s)
            rightButton("mute", label: "M", column: 1, row: 1, s: s)
            rightButton("delete", icon: "xmark", column: 0, row: 2, s: s)
            rightButton("copy", icon: "square.on.square", column: 1, row: 2, s: s)
            rightButton("undo", icon: "arrow.uturn.backward", column: 0, row: 3, s: s)
            rightButton("shift", icon: "ellipsis", column: 1, row: 3, s: s)

            // ---- Bottom zone: transport, steps, nav ----
            FunctionButton(id: "play", systemImage: "play.fill", diameter: 48 * s, litColor: .green)
                .position(x: 46 * s, y: 600 * s)
            FunctionButton(id: "record", systemImage: "circle.fill", diameter: 48 * s, litColor: .red)
                .position(x: 110 * s, y: 600 * s)

            ForEach(0..<16, id: \.self) { index in
                StepButton(index: index, diameter: 36 * s)
                    .position(x: stepX(index) * s, y: 600 * s)
            }

            // Shift-function legends printed on the deck below their steps.
            ForEach(Array(Self.stepLegends.keys), id: \.self) { index in
                let legend = Self.stepLegends[index]!
                StepLegend(stepIndex: index, systemImage: legend.icon,
                           text: legend.text, size: 10 * s)
                    .position(x: stepX(index) * s, y: 634 * s)
            }

            FunctionButton(id: "left", systemImage: "chevron.left", diameter: 30 * s)
                .position(x: 908 * s, y: 600 * s)
            FunctionButton(id: "plus", systemImage: "plus", diameter: 26 * s)
                .position(x: 946 * s, y: 582 * s)
            FunctionButton(id: "minus", systemImage: "minus", diameter: 26 * s)
                .position(x: 946 * s, y: 618 * s)
            FunctionButton(id: "right", systemImage: "chevron.right", diameter: 30 * s)
                .position(x: 981 * s, y: 600 * s)

            // XL wordmark on the deck.
            Text("MOVE XL")
                .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                .kerning(2 * s)
                .foregroundStyle(Color(white: 0.30))
                .position(x: 78 * s, y: 668 * s)
        }
    }

    /// Legends for the steps that carry a Shift function (Brain.legendSteps).
    static let stepLegends: [Int: (icon: String?, text: String?)] = [
        0:  ("circle.grid.2x2.fill", nil),   // Set Overview
        1:  ("gearshape.fill", nil),         // Setup
        2:  ("slider.horizontal.3", nil),    // Workflow Settings
        4:  ("timer", nil),                  // Tempo
        5:  ("metronome.fill", nil),         // Metronome
        6:  ("shuffle", nil),                // Groove / swing
        8:  ("music.note", nil),             // Scale
        9:  ("bolt.fill", nil),              // Full Velocity
        14: (nil, "\u{00D7}2"),              // Double Loop  (×2)
        15: ("arrow.right.to.line", nil),    // Quantize
    ]

    private func encoderX(_ index: Int) -> CGFloat {
        425 + CGFloat(index) * 68
    }

    private func padRowY(_ row: Int) -> CGFloat {
        277 + CGFloat(row) * 63
    }

    private func stepX(_ index: Int) -> CGFloat {
        187 + CGFloat(index) * 45
    }

    private func rightButton(_ id: String, icon: String? = nil, label: String? = nil,
                             column: Int, row: Int, s: CGFloat) -> some View {
        FunctionButton(id: id, systemImage: icon, label: label, diameter: 44 * s,
                       litColor: id == "record" ? .red : .white)
            .position(x: (918 + CGFloat(column) * 52) * s,
                      y: padRowY(row) * s)
    }
}
