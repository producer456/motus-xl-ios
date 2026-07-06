import SwiftUI

/// "Move XL" — the imagined big sibling of the Move, at the 11" iPad Pro's
/// footprint: 8 tracks with an 8x8 grid (full session parity: rows = tracks,
/// columns = scenes), a 256x128 OLED showing all tracks at once, and the
/// original Move's wide pad shape. Laid out in a 1000x699 design space.
struct PanelView: View {
    @EnvironmentObject var client: Brain
    @StateObject private var motion = MotionSource()
    @Environment(\.scenePhase) private var scenePhase

    static let designSize = CGSize(width: 1014, height: 699)

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.designSize.width,
                            geo.size.height / Self.designSize.height)
            ZStack {
                Color.black.ignoresSafeArea()
                panel(scale: scale)
                    .onAppear { motion.start() }
                    .onChange(of: scenePhase) { _, phase in
                        phase == .active ? motion.start() : motion.stop()
                    }
                    .frame(width: Self.designSize.width * scale,
                           height: Self.designSize.height * scale)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        // The panel is a hardware fascia — fill the physical screen, not the
        // safe area (device insets are larger than the sim's, leaving a
        // black border otherwise).
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { client.auSheetVC != nil },
                                    set: { if !$0 { client.auSheetVC = nil } })) {
            if let vc = client.auSheetVC {
                AUPluginView(viewController: vc)
                    .ignoresSafeArea()
            }
        }
    }

    private func panel(scale s: CGFloat) -> some View {
        ZStack {
            if !client.bareTheme { chassis(scale: s) }
            controls(scale: s)
                .offset(x: motion.tilt.x * 2.5 * s, y: motion.tilt.y * 2.5 * s)
        }
    }

    /// The physical-device illusion: shell, wells, screws, bezel, wordmark.
    /// The bare theme drops all of it — controls float on the iPad's glass.
    @ViewBuilder
    private func chassis(scale s: CGFloat) -> some View {
        let base = client.chassisColor
        let shell = Color(red: base.x, green: base.y, blue: base.z)
        let light = Color(red: min(1, base.x * 1.22), green: min(1, base.y * 1.22),
                          blue: min(1, base.z * 1.22))
        let edge = Color(red: base.x * 0.55, green: base.y * 0.55, blue: base.z * 0.55)
        let rim = Color(red: min(1, base.x * 2.2 + 0.08), green: min(1, base.y * 2.2 + 0.08),
                        blue: min(1, base.z * 2.2 + 0.08))
        Group {
            // Body shell — matte, user-tinted, faint top-light sheen.
            RoundedRectangle(cornerRadius: 26 * s)
                .fill(
                    LinearGradient(colors: [light, shell, edge],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26 * s)
                        .strokeBorder(
                            LinearGradient(colors: [rim, edge],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5 * s)
                )
                .shadow(color: .black.opacity(0.8), radius: 18 * s, y: 6 * s)

            // Micro-grain so the deck reads as material, not vector fill.
            GrainOverlay()
                .clipShape(RoundedRectangle(cornerRadius: 26 * s))

            // Room light: a broad soft sheen that glides with device tilt.
            RadialGradient(colors: [Color.white.opacity(0.05), .clear],
                           center: .init(x: 0.5 - motion.tilt.x * 0.35,
                                         y: 0.12 - motion.tilt.y * 0.25),
                           startRadius: 40 * s, endRadius: 620 * s)
                .clipShape(RoundedRectangle(cornerRadius: 26 * s))
                .allowsHitTesting(false)

            // Edge vignette: light falls off toward the chassis edges.
            RadialGradient(colors: [.clear, .black.opacity(0.16)],
                           center: .center,
                           startRadius: 260 * s, endRadius: 720 * s)
                .clipShape(RoundedRectangle(cornerRadius: 26 * s))
                .allowsHitTesting(false)

            // Chassis screws.
            Screw(diameter: 9 * s, angle: 37).position(x: 24 * s, y: 24 * s)
            Screw(diameter: 9 * s, angle: 104).position(x: 990 * s, y: 24 * s)
            Screw(diameter: 9 * s, angle: 61).position(x: 24 * s, y: 676 * s)
            Screw(diameter: 9 * s, angle: 158).position(x: 990 * s, y: 676 * s)

            // Recessed wells the pads and steps sit in.
            RecessedWell(cornerRadius: 12 * s)
                .frame(width: 712 * s, height: 508 * s)
                .position(x: 520 * s, y: 372 * s)
            RecessedWell(cornerRadius: 10 * s)
                .frame(width: 694 * s, height: 48 * s)
                .position(x: 520 * s, y: 653 * s)

            // Display bezel plate.
            RoundedRectangle(cornerRadius: 8 * s)
                .fill(Color(white: 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 8 * s)
                        .strokeBorder(
                            LinearGradient(colors: [Color.black, Color(white: 0.24)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.2 * s)
                )
                .frame(width: 190 * s, height: 102 * s)
                .position(x: 507 * s, y: 66 * s)

            Circle() // microphone hole
                .fill(Color.black)
                .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 0.8 * s))
                .frame(width: 8 * s, height: 8 * s)
                .position(x: 920 * s, y: 22 * s)


            // XL wordmark on the deck.
            Text("MOVE XL")
                .font(.system(size: 11 * s, weight: .bold, design: .rounded))
                .kerning(2 * s)
                .foregroundStyle(Color(white: 0.30))
                .position(x: 72 * s, y: 428 * s)
        }
    }

    /// Everything you actually touch — shared by both themes.
    @ViewBuilder
    private func controls(scale s: CGFloat) -> some View {
        ZStack {
            // ---- Top zone: the XL's big OLED (256x128), encoders, volume ----
            DisplayView(image: client.displayImage, tilt: motion.tilt)
                .frame(width: 176 * s, height: 88 * s)
                .position(x: 507 * s, y: 66 * s)

            ForEach(0..<8, id: \.self) { index in
                EncoderView(index: index, diameter: 42 * s, tilt: motion.tilt)
                    .position(x: encoderX(index) * s, y: 58 * s)
                Circle() // touch indicator dot under each encoder
                    .fill(Color(white: 0.38))
                    .frame(width: 6 * s, height: 6 * s)
                    .position(x: encoderX(index) * s, y: 92 * s)
            }

            EncoderView(index: 8, diameter: 48 * s, tilt: motion.tilt) // volume
                .position(x: 966 * s, y: 58 * s)

            // Power button (the real unit's yellow rear button, surfaced).
            HardwareButton {
                client.button("power", down: true)
            } onRelease: {
                client.button("power", down: false)
            } content: { pressed in
                ZStack {
                    RoundButton(diameter: 20 * s, lit: 0, pressed: pressed)
                    Image(systemName: "power")
                        .font(.system(size: 9 * s, weight: .bold))
                        .foregroundStyle(client.poweredOn
                                         ? Color(white: 0.95)
                                         : Color(white: 0.28))
                        .shadow(color: Color.white
                            .opacity(client.poweredOn ? 0.6 : 0), radius: 3 * s)
                }
            }
            .position(x: 62 * s, y: 22 * s)

            // ---- Left rail: wheel steppers, wheel, back / mode ----
            FunctionButton(id: "wheelUp", systemImage: "chevron.up", diameter: 30 * s)
                .position(x: 50 * s, y: 150 * s)
            FunctionButton(id: "wheelDown", systemImage: "chevron.down", diameter: 30 * s)
                .position(x: 94 * s, y: 150 * s)
            WheelView(diameter: 88 * s, tilt: motion.tilt)
                .position(x: 72 * s, y: 222 * s)

            FunctionButton(id: "back", systemImage: "chevron.left", diameter: 34 * s)
                .position(x: 43 * s, y: 294 * s)
            FunctionButton(id: "note", systemImage: "line.3.horizontal", diameter: 34 * s)
                .position(x: 101 * s, y: 294 * s)

            // Dedicated quantize — same 72-unit rail rhythm.
            FunctionButton(id: "quantize", systemImage: "arrow.right.to.line", diameter: 34 * s)
                .position(x: 72 * s, y: 366 * s)

            // ---- 8 track buttons, one per pad row ----
            ForEach(0..<8, id: \.self) { index in
                TrackButton(index: index, size: CGSize(width: 18 * s, height: 52 * s))
                    .position(x: 153 * s, y: padRowY(index) * s)
            }

            // ---- 8x8 pad grid: original Move pad shape (wide 1.5:1) ----
            PadGridView(colors: client.noteColors, channels: client.noteChannels, tilt: motion.tilt)
                .frame(width: 692 * s, height: 488 * s)
                .position(x: 520 * s, y: 372 * s)

            // ---- Right rail (2 x 4 function buttons) ----
            rightButton("capture", icon: "viewfinder", column: 0, row: 0, s: s)
            rightButton("sample", icon: "waveform", column: 1, row: 0, s: s)
            rightButton("loop", icon: "repeat", column: 0, row: 1, s: s)
            rightButton("mute", label: "M", column: 1, row: 1, s: s)
            rightButton("delete", icon: "xmark", column: 0, row: 2, s: s)
            rightButton("copy", icon: "square.on.square", column: 1, row: 2, s: s)
            rightButton("undo", icon: "arrow.uturn.backward", column: 0, row: 3, s: s)
            rightButton("shift", icon: "ellipsis", column: 1, row: 3, s: s)

            // ---- Plugin bay: glass icon display + native-view button ----
            PluginGlass(icon: client.auIcons[client.song.selectedTrack], scale: s)
                .frame(width: 58 * s, height: 58 * s)
                .position(x: 72 * s, y: 505 * s)
            FunctionButton(id: "auview", systemImage: "macwindow", diameter: 32 * s)
                .position(x: 72 * s, y: 578 * s)

            // ---- Bottom zone: transport, steps, nav ----
            FunctionButton(id: "play", systemImage: "play.fill", diameter: 48 * s, litColor: .green)
                .position(x: 46 * s, y: 651 * s)
            FunctionButton(id: "record", systemImage: "circle.fill", diameter: 48 * s, litColor: .red)
                .position(x: 110 * s, y: 651 * s)

            ForEach(0..<16, id: \.self) { index in
                StepButton(index: index, diameter: 32 * s)
                    .position(x: stepX(index) * s, y: 651 * s)
            }

            // Shift-function legends printed on the deck below their steps.
            ForEach(Array(Self.stepLegends.keys), id: \.self) { index in
                let legend = Self.stepLegends[index]!
                StepLegend(stepIndex: index, systemImage: legend.icon,
                           text: legend.text, size: 9 * s)
                    .position(x: stepX(index) * s, y: 687 * s)
            }

            FunctionButton(id: "left", systemImage: "chevron.left", diameter: 30 * s)
                .position(x: 886 * s, y: 651 * s)
            FunctionButton(id: "plus", systemImage: "plus", diameter: 26 * s)
                .position(x: 926 * s, y: 633 * s)
            FunctionButton(id: "minus", systemImage: "minus", diameter: 26 * s)
                .position(x: 926 * s, y: 669 * s)
            FunctionButton(id: "right", systemImage: "chevron.right", diameter: 30 * s)
                .position(x: 964 * s, y: 651 * s)
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
        13: ("plus.square", nil),            // Prepare next clip slot
        14: (nil, "\u{00D7}2"),              // Double Loop  (×2)
        15: ("arrow.right.to.line", nil),    // Quantize
    ]

    /// Encoders 1-4 flank the centered OLED on the left, 5-8 on the right.
    private func encoderX(_ index: Int) -> CGFloat {
        index < 4 ? 120 + CGFloat(index) * 75
                  : 669 + CGFloat(index - 4) * 75
    }

    private func padRowY(_ row: Int) -> CGFloat {
        154 + CGFloat(row) * 62.2
    }

    private func stepX(_ index: Int) -> CGFloat {
        205 + CGFloat(index) * 42
    }

    private func rightButton(_ id: String, icon: String? = nil, label: String? = nil,
                             column: Int, row: Int, s: CGFloat) -> some View {
        FunctionButton(id: id, systemImage: icon, label: label, diameter: 40 * s,
                       litColor: id == "record" ? .red : .white)
            .position(x: (921 + CGFloat(column) * 48) * s,
                      y: (189 + CGFloat(row) * 122) * s)
    }
}


/// A tiny display window showing the loaded plugin's icon behind glass.
struct PluginGlass: View {
    var icon: UIImage?
    var scale: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9 * scale)
                .fill(Color(white: 0.045))
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6 * scale))
                    .padding(7 * scale)
                    .opacity(0.92)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 18 * scale, weight: .light))
                    .foregroundStyle(Color(white: 0.22))
            }
            // Glass: diagonal gloss sweep + edge reflection + deep bezel.
            LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.02), .clear],
                           startPoint: .topLeading, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: 9 * scale))
            LinearGradient(colors: [.clear, .white.opacity(0.05)],
                           startPoint: .center, endPoint: .bottomTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 9 * scale))
            RoundedRectangle(cornerRadius: 9 * scale)
                .strokeBorder(
                    LinearGradient(colors: [Color.black, Color(white: 0.26)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.3 * scale)
        }
        .allowsHitTesting(false)
    }
}

/// Hosts the AUv3's own view controller inside the sheet.
struct AUPluginView: UIViewControllerRepresentable {
    let viewController: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { viewController }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
