import SwiftUI

/// "Imagine-11": the Move re-imagined as if Ableton had designed the
/// enclosure at the 11" iPad Pro's footprint (aspect ~1.43:1) instead of
/// the long 2:1 desktop wedge. Same control vocabulary, reflowed: a larger
/// OLED, roomier encoders, near-square pads, and a bigger wheel.
/// Laid out proportionally in a 1000x699 design space.
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

            // ---- Top zone: big display, encoders, mic, volume ----
            DisplayView(image: client.displayImage)
                .frame(width: 220 * s, height: 110 * s)
                .position(x: 140 * s, y: 77 * s)

            ForEach(0..<8, id: \.self) { index in
                EncoderView(index: index, diameter: 54 * s)
                    .position(x: encoderX(index) * s, y: 58 * s)
                Circle() // touch indicator dot under each encoder
                    .fill(Color(white: 0.38))
                    .frame(width: 6 * s, height: 6 * s)
                    .position(x: encoderX(index) * s, y: 102 * s)
            }

            Circle() // microphone hole
                .fill(Color.black)
                .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 0.8 * s))
                .frame(width: 8 * s, height: 8 * s)
                .position(x: 903 * s, y: 26 * s)

            EncoderView(index: 8, diameter: 62 * s) // volume
                .position(x: 935 * s, y: 66 * s)

            // ---- Left rail: oversized wheel, back / mode ----
            WheelView(diameter: 115 * s)
                .position(x: 78 * s, y: 238 * s)

            FunctionButton(id: "back", systemImage: "chevron.left", diameter: 40 * s)
                .position(x: 46 * s, y: 336 * s)
            FunctionButton(id: "note", systemImage: "line.3.horizontal", diameter: 40 * s)
                .position(x: 110 * s, y: 336 * s)

            // ---- Track buttons, one per pad row ----
            ForEach(0..<4, id: \.self) { index in
                TrackButton(index: index, size: CGSize(width: 13 * s, height: 64 * s))
                    .position(x: 152 * s, y: padRowY(index) * s)
            }

            // ---- Pad grid: square pads (grid sized so cellW == cellH) ----
            PadGridView(colors: client.noteColors, channels: client.noteChannels)
                .frame(width: 708 * s, height: 350 * s)
                .position(x: 532 * s, y: 370 * s)

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
            FunctionButton(id: "play", systemImage: "play.fill", diameter: 50 * s, litColor: .green)
                .position(x: 46 * s, y: 634 * s)
            FunctionButton(id: "record", systemImage: "circle.fill", diameter: 50 * s, litColor: .red)
                .position(x: 110 * s, y: 634 * s)

            ForEach(0..<16, id: \.self) { index in
                StepButton(index: index, diameter: 36 * s)
                    .position(x: stepX(index) * s, y: 622 * s)
            }

            // Shift-function legends printed on the deck below their steps.
            ForEach(Array(Self.stepLegends.keys), id: \.self) { index in
                let legend = Self.stepLegends[index]!
                StepLegend(stepIndex: index, systemImage: legend.icon,
                           text: legend.text, size: 10 * s)
                    .position(x: stepX(index) * s, y: 656 * s)
            }

            FunctionButton(id: "left", systemImage: "chevron.left", diameter: 30 * s)
                .position(x: 908 * s, y: 634 * s)
            FunctionButton(id: "plus", systemImage: "plus", diameter: 26 * s)
                .position(x: 946 * s, y: 616 * s)
            FunctionButton(id: "minus", systemImage: "minus", diameter: 26 * s)
                .position(x: 946 * s, y: 652 * s)
            FunctionButton(id: "right", systemImage: "chevron.right", diameter: 30 * s)
                .position(x: 981 * s, y: 634 * s)
        }
    }

    /// Legends for the steps that carry a Shift function (Brain.legendSteps).
    /// icon = SF Symbol; text used where a glyph reads better at 9 pt.
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
        315 + CGFloat(index) * 77
    }

    private func padRowY(_ row: Int) -> CGFloat {
        235 + CGFloat(row) * 90
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
