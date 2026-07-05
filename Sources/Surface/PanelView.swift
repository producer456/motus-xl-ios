import SwiftUI

/// Faithful top-down Ableton Move panel, laid out proportionally in a
/// 1000x470 design space (photo-derived) and scaled to fill the screen.
struct PanelView: View {
    @EnvironmentObject var client: Brain

    static let designSize = CGSize(width: 1000, height: 470)

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
            RoundedRectangle(cornerRadius: 24 * s)
                .fill(
                    LinearGradient(colors: [Color(white: 0.105), Chrome.body, Chrome.bodyEdge],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24 * s)
                        .strokeBorder(
                            LinearGradient(colors: [Color(white: 0.24), Chrome.bodyEdge],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5 * s)
                )
                .shadow(color: .black.opacity(0.8), radius: 18 * s, y: 6 * s)

            // ---- Top row: display, encoders, mic, volume ----
            DisplayView(image: client.displayImage)
                .frame(width: 116 * s, height: 58 * s)
                .position(x: 88 * s, y: 52 * s)

            ForEach(0..<8, id: \.self) { index in
                EncoderView(index: index, diameter: 46 * s)
                    .position(x: encoderX(index) * s, y: 47 * s)
                Circle() // touch indicator dot under each encoder
                    .fill(Color(white: 0.38))
                    .frame(width: 5 * s, height: 5 * s)
                    .position(x: encoderX(index) * s, y: 82 * s)
            }

            Circle() // microphone hole
                .fill(Color.black)
                .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 0.8 * s))
                .frame(width: 7 * s, height: 7 * s)
                .position(x: 855 * s, y: 38 * s)

            EncoderView(index: 8, diameter: 54 * s) // volume
                .position(x: 922 * s, y: 48 * s)

            // ---- Left cluster ----
            WheelView(diameter: 86 * s)
                .position(x: 76 * s, y: 148 * s)

            FunctionButton(id: "back", systemImage: "chevron.left", diameter: 34 * s)
                .position(x: 48 * s, y: 232 * s)
            FunctionButton(id: "note", systemImage: "line.3.horizontal", diameter: 34 * s)
                .position(x: 104 * s, y: 232 * s)

            FunctionButton(id: "play", systemImage: "play.fill", diameter: 40 * s, litColor: .green)
                .position(x: 36 * s, y: 396 * s)
            FunctionButton(id: "record", systemImage: "circle.fill", diameter: 40 * s, litColor: .red)
                .position(x: 88 * s, y: 396 * s)

            // ---- Track buttons ----
            ForEach(0..<4, id: \.self) { index in
                TrackButton(index: index, size: CGSize(width: 11 * s, height: 46 * s))
                    .position(x: 148 * s, y: (128 + CGFloat(index) * 62) * s)
            }

            // ---- Pad grid ----
            PadGridView(colors: client.noteColors, channels: client.noteChannels)
                .frame(width: 640 * s, height: 236 * s)
                .position(x: 490 * s, y: 224 * s)

            // ---- Right column ----
            rightButton("capture", icon: "viewfinder", column: 0, row: 0, s: s)
            rightButton("sample", icon: "waveform", column: 1, row: 0, s: s)
            rightButton("loop", icon: "repeat", column: 0, row: 1, s: s)
            rightButton("mute", label: "M", column: 1, row: 1, s: s)
            rightButton("delete", icon: "xmark", column: 0, row: 2, s: s)
            rightButton("copy", icon: "square.on.square", column: 1, row: 2, s: s)
            rightButton("undo", icon: "arrow.uturn.backward", column: 0, row: 3, s: s)
            rightButton("shift", icon: "ellipsis", column: 1, row: 3, s: s)

            // ---- Step row ----
            ForEach(0..<16, id: \.self) { index in
                StepButton(index: index, diameter: 30 * s)
                    .position(x: (183 + CGFloat(index) * 41) * s, y: 396 * s)
            }

            // Shift-function legends printed on the deck below their steps.
            ForEach(Array(Self.stepLegends.keys), id: \.self) { index in
                let legend = Self.stepLegends[index]!
                StepLegend(stepIndex: index, systemImage: legend.icon,
                           text: legend.text, size: 9 * s)
                    .position(x: (183 + CGFloat(index) * 41) * s, y: 424 * s)
            }

            // ---- Bottom right nav ----
            FunctionButton(id: "left", systemImage: "chevron.left", diameter: 26 * s)
                .position(x: 872 * s, y: 396 * s)
            FunctionButton(id: "plus", systemImage: "plus", diameter: 24 * s)
                .position(x: 912 * s, y: 380 * s)
            FunctionButton(id: "minus", systemImage: "minus", diameter: 24 * s)
                .position(x: 912 * s, y: 412 * s)
            FunctionButton(id: "right", systemImage: "chevron.right", diameter: 26 * s)
                .position(x: 952 * s, y: 396 * s)

        }
    }

    /// Legends for the steps that carry a Shift function (Brain.legendSteps).
    /// icon = SF Symbol; text used where a glyph reads better at 9 pt.
    static let stepLegends: [Int: (icon: String?, text: String?)] = [
        0:  ("circle.grid.2x2.fill", nil),   // Set Overview
        1:  ("gearshape.fill", nil),         // Setup
        4:  ("timer", nil),                  // Tempo
        5:  ("metronome.fill", nil),         // Metronome
        6:  ("shuffle", nil),                // Groove / swing
        8:  ("music.note", nil),             // Scale
        9:  ("bolt.fill", nil),              // Full Velocity
        14: (nil, "\u{00D7}2"),              // Double Loop  (×2)
        15: ("arrow.right.to.line", nil),    // Quantize
    ]

    private func encoderX(_ index: Int) -> CGFloat {
        215 + CGFloat(index) * 82
    }

    private func rightButton(_ id: String, icon: String? = nil, label: String? = nil,
                             column: Int, row: Int, s: CGFloat) -> some View {
        FunctionButton(id: id, systemImage: icon, label: label, diameter: 36 * s,
                       litColor: id == "record" ? .red : .white)
            .position(x: (848 + CGFloat(column) * 56) * s,
                      y: (128 + CGFloat(row) * 62) * s)
    }
}
