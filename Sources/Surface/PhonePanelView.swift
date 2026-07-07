import SwiftUI

/// "Move Go" — the XL re-racked for an iPhone in landscape. Same material
/// kit and Brain, different chassis: the 8x8 grid takes the full height as
/// the hero, everything else splits into a slim left column (wheel, modes,
/// plugin bay, transport) and a right control bay (OLED, encoders 2x4,
/// function cluster, steps 2x8, nav). 932x430 design space = iPhone 15
/// Pro Max landscape points.
///
/// Dynamic Island: in landscape it occupies either short edge, vertically
/// centered (roughly y 145-285 within x<60 / x>872). Controls keep clear
/// of both bands; only decorative chassis sits under them.
struct PhonePanelView: View {
    @EnvironmentObject var client: Brain
    @StateObject private var motion = MotionSource()
    @Environment(\.scenePhase) private var scenePhase

    static let designSize = CGSize(width: 932, height: 430)

    var body: some View {
        // Launchpad docked: the panel replica retires and the color command
        // deck takes over (it grows knobs/transport until a Launchkey also
        // connects and covers them).
        if client.launchpadOn {
            DockView()
        } else {
            panelBody
        }
    }

    private var panelBody: some View {
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
            switch client.themeStyle {
            case 1: EmptyView()                    // bare: glass only
            case 2: vintageChassis(scale: s)
            default: chassis(scale: s)
            }
            controls(scale: s)
                .offset(x: motion.tilt.x * 2.5 * s, y: motion.tilt.y * 2.5 * s)
        }
    }

    // MARK: - Chassis (hardware theme)

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
            RoundedRectangle(cornerRadius: 18 * s)
                .fill(
                    LinearGradient(colors: [light, shell, edge],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18 * s)
                        .strokeBorder(
                            LinearGradient(colors: [rim, edge],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5 * s)
                )
                .shadow(color: .black.opacity(0.8), radius: 14 * s, y: 5 * s)

            GrainOverlay()
                .clipShape(RoundedRectangle(cornerRadius: 18 * s))

            RadialGradient(colors: [Color.white.opacity(0.05), .clear],
                           center: .init(x: 0.5 - motion.tilt.x * 0.35,
                                         y: 0.10 - motion.tilt.y * 0.25),
                           startRadius: 30 * s, endRadius: 560 * s)
                .clipShape(RoundedRectangle(cornerRadius: 18 * s))
                .allowsHitTesting(false)

            RadialGradient(colors: [.clear, .black.opacity(0.16)],
                           center: .center,
                           startRadius: 220 * s, endRadius: 640 * s)
                .clipShape(RoundedRectangle(cornerRadius: 18 * s))
                .allowsHitTesting(false)

            Screw(diameter: 7 * s, angle: 37).position(x: 20 * s, y: 18 * s)
            Screw(diameter: 7 * s, angle: 104).position(x: 912 * s, y: 18 * s)
            Screw(diameter: 7 * s, angle: 61).position(x: 20 * s, y: 412 * s)
            Screw(diameter: 7 * s, angle: 158).position(x: 912 * s, y: 412 * s)

            sharedWells(scale: s)

            // Display bezel plate.
            RoundedRectangle(cornerRadius: 7 * s)
                .fill(Color(white: 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 7 * s)
                        .strokeBorder(
                            LinearGradient(colors: [Color.black, Color(white: 0.24)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.2 * s)
                )
                .frame(width: 164 * s, height: 89 * s)
                .position(x: 784 * s, y: 58 * s)

            Circle() // microphone hole
                .fill(Color.black)
                .overlay(Circle().strokeBorder(Color(white: 0.3), lineWidth: 0.8 * s))
                .frame(width: 7 * s, height: 7 * s)
                .position(x: 894 * s, y: 80 * s)

            Text("MOVE XL")
                .font(.system(size: 9 * s, weight: .bold, design: .rounded))
                .kerning(1.6 * s)
                .foregroundStyle(Color(white: 0.30))
                .position(x: 92 * s, y: 340 * s)
        }
    }

    // MARK: - Chassis (vintage theme)

    @ViewBuilder
    private func vintageChassis(scale s: CGFloat) -> some View {
        Group {
            RoundedRectangle(cornerRadius: 14 * s)
                .fill(
                    LinearGradient(colors: [Color(red: 0.170, green: 0.160, blue: 0.148),
                                            Color(red: 0.128, green: 0.120, blue: 0.110),
                                            Color(red: 0.085, green: 0.080, blue: 0.072)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14 * s)
                        .strokeBorder(Color.black.opacity(0.8), lineWidth: 1.5 * s)
                )
            GrainOverlay(opacity: 0.07)
                .clipShape(RoundedRectangle(cornerRadius: 14 * s))
            RadialGradient(colors: [.clear, .black.opacity(0.22)],
                           center: .center, startRadius: 220 * s, endRadius: 640 * s)
                .clipShape(RoundedRectangle(cornerRadius: 14 * s))
                .allowsHitTesting(false)

            // Walnut cheeks — slim on the Go.
            WoodRail(scale: s)
                .frame(width: 12 * s, height: 430 * s)
                .position(x: 6 * s, y: 215 * s)
            WoodRail(scale: s)
                .frame(width: 12 * s, height: 430 * s)
                .position(x: 926 * s, y: 215 * s)

            // Engraved zone frames: encoder block + plugin bay.
            RoundedRectangle(cornerRadius: 7 * s)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1 * s)
                .frame(width: 180 * s, height: 92 * s)
                .position(x: 772 * s, y: 154 * s)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 7 * s)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1 * s)
                .frame(width: 56 * s, height: 96 * s)
                .position(x: 92 * s, y: 232 * s)
                .allowsHitTesting(false)

            sharedWells(scale: s)

            RoundedRectangle(cornerRadius: 7 * s)
                .fill(Color(white: 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 7 * s)
                        .strokeBorder(Color(red: 0.55, green: 0.44, blue: 0.30).opacity(0.5),
                                      lineWidth: 1.2 * s)
                )
                .frame(width: 164 * s, height: 89 * s)
                .position(x: 784 * s, y: 58 * s)

            Screw(diameter: 7 * s, angle: 37).position(x: 30 * s, y: 18 * s)
            Screw(diameter: 7 * s, angle: 104).position(x: 902 * s, y: 18 * s)
            Screw(diameter: 7 * s, angle: 61).position(x: 30 * s, y: 412 * s)
            Screw(diameter: 7 * s, angle: 158).position(x: 902 * s, y: 412 * s)

            Text("MOVE XL")
                .font(.system(size: 9 * s, weight: .bold, design: .rounded))
                .kerning(1.6 * s)
                .foregroundStyle(Color(red: 0.85, green: 0.80, blue: 0.68).opacity(0.65))
                .position(x: 92 * s, y: 340 * s)
        }
    }

    /// Recessed wells shared by both physical themes.
    @ViewBuilder
    private func sharedWells(scale s: CGFloat) -> some View {
        RecessedWell(cornerRadius: 10 * s)   // pad well
            .frame(width: 516 * s, height: 412 * s)
            .position(x: 406 * s, y: 215 * s)
        RecessedWell(cornerRadius: 8 * s)    // step well (2x8)
            .frame(width: 246 * s, height: 104 * s)
            .position(x: 794 * s, y: 336 * s)
    }

    // MARK: - Controls

    @ViewBuilder
    private func controls(scale s: CGFloat) -> some View {
        ZStack {
            // ---- Left column: power, wheel, modes, plugin bay, transport ----
            HardwareButton {
                client.button("power", down: true)
            } onRelease: {
                client.button("power", down: false)
            } content: { pressed in
                ZStack {
                    RoundButton(diameter: 18 * s, lit: 0, pressed: pressed)
                    Image(systemName: "power")
                        .font(.system(size: 8 * s, weight: .bold))
                        .foregroundStyle(client.poweredOn
                                         ? Color(white: 0.95)
                                         : Color(white: 0.28))
                        .shadow(color: Color.white
                            .opacity(client.poweredOn ? 0.6 : 0), radius: 2.5 * s)
                }
            }
            .position(x: 46 * s, y: 18 * s)

            FunctionButton(id: "wheelUp", systemImage: "chevron.up", diameter: 24 * s)
                .position(x: 78 * s, y: 18 * s)
            FunctionButton(id: "wheelDown", systemImage: "chevron.down", diameter: 24 * s)
                .position(x: 110 * s, y: 18 * s)
            WheelView(diameter: 62 * s, tilt: motion.tilt, deepShadow: client.themeStyle == 2)
                .position(x: 92 * s, y: 66 * s)

            FunctionButton(id: "back", systemImage: "chevron.left", diameter: 26 * s)
                .position(x: 74 * s, y: 122 * s)
            FunctionButton(id: "note", systemImage: "line.3.horizontal", diameter: 26 * s)
                .position(x: 110 * s, y: 122 * s)
            FunctionButton(id: "quantize", systemImage: "arrow.right.to.line", diameter: 26 * s)
                .position(x: 92 * s, y: 160 * s)

            PluginGlass(icon: client.auIcons[client.song.selectedTrack], scale: s * 0.8)
                .frame(width: 44 * s, height: 44 * s)
                .position(x: 92 * s, y: 216 * s)
            FunctionButton(id: "auview", systemImage: "macwindow", diameter: 24 * s)
                .position(x: 92 * s, y: 258 * s)

            // Transport hides when the Launchkey's Play/Rec cover it.
            if !client.launchkeyOn {
                FunctionButton(id: "play", systemImage: "play.fill", diameter: 38 * s, litColor: .green)
                    .position(x: 68 * s, y: 384 * s)
                FunctionButton(id: "record", systemImage: "circle.fill", diameter: 38 * s, litColor: .red)
                    .position(x: 110 * s, y: 384 * s)
            }

            // ---- Track bars + grid — hidden when a Launchpad covers them:
            // the phone docks into "just a screen" (manual-style big OLED).
            if client.launchpadOn {
                RoundedRectangle(cornerRadius: 10 * s)
                    .fill(Color(white: 0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10 * s)
                            .strokeBorder(
                                LinearGradient(colors: [Color.black, Color(white: 0.24)],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1.4 * s)
                    )
                    .frame(width: 516 * s, height: 276 * s)
                    .position(x: 406 * s, y: 215 * s)
                DisplayView(image: client.displayImage, tilt: motion.tilt)
                    .frame(width: 492 * s, height: 246 * s)
                    .position(x: 406 * s, y: 215 * s)
            } else {
                ForEach(0..<8, id: \.self) { index in
                    TrackButton(index: index, size: CGSize(width: 14 * s, height: 40 * s))
                        .position(x: 140 * s, y: padRowY(index) * s)
                }
                PadGridView(colors: client.noteColors, channels: client.noteChannels, tilt: motion.tilt)
                    .frame(width: 500 * s, height: 396 * s)
                    .position(x: 406 * s, y: 215 * s)
            }

            // ---- Right bay: OLED + volume ----
            DisplayView(image: client.displayImage, tilt: motion.tilt)
                .frame(width: 150 * s, height: 75 * s)
                .position(x: 784 * s, y: 58 * s)
            EncoderView(index: 8, diameter: 30 * s, tilt: motion.tilt,
                        deepShadow: client.themeStyle == 2) // volume
                .position(x: 894 * s, y: 36 * s)

            // ---- Encoders, 2 rows of 4 — the Launchkey's knobs cover these ----
            if !client.launchkeyOn {
                ForEach(0..<8, id: \.self) { index in
                    EncoderView(index: index, diameter: 34 * s, tilt: motion.tilt,
                                deepShadow: client.themeStyle == 2)
                        .position(x: (706 + CGFloat(index % 4) * 44) * s,
                                  y: (132 + CGFloat(index / 4) * 46) * s)
                }
            }

            // ---- Function cluster, 2 rows of 4 ----
            bayButton("capture", icon: "viewfinder", column: 0, row: 0, s: s)
            bayButton("sample", icon: "waveform", column: 1, row: 0, s: s)
            bayButton("loop", icon: "repeat", column: 2, row: 0, s: s)
            bayButton("mute", label: "M", column: 3, row: 0, s: s)
            bayButton("delete", icon: "xmark", column: 0, row: 1, s: s)
            bayButton("copy", icon: "square.on.square", column: 1, row: 1, s: s)
            bayButton("undo", icon: "arrow.uturn.backward", column: 2, row: 1, s: s)
            bayButton("shift", icon: "ellipsis", column: 3, row: 1, s: s)

            // ---- Steps, 2 rows of 8 (bar halves), legends under each ----
            ForEach(0..<16, id: \.self) { index in
                StepButton(index: index, diameter: 24 * s)
                    .position(x: stepX(index) * s, y: stepY(index) * s)
            }
            ForEach(Array(PanelView.stepLegends.keys), id: \.self) { index in
                let legend = PanelView.stepLegends[index]!
                StepLegend(stepIndex: index, systemImage: legend.icon,
                           text: legend.text, size: 6.5 * s)
                    .position(x: stepX(index) * s, y: (stepY(index) + 21) * s)
            }

            // ---- Nav ----
            FunctionButton(id: "left", systemImage: "chevron.left", diameter: 24 * s)
                .position(x: 722 * s, y: 410 * s)
            FunctionButton(id: "minus", systemImage: "minus", diameter: 22 * s)
                .position(x: 758 * s, y: 410 * s)
            FunctionButton(id: "plus", systemImage: "plus", diameter: 22 * s)
                .position(x: 792 * s, y: 410 * s)
            FunctionButton(id: "right", systemImage: "chevron.right", diameter: 24 * s)
                .position(x: 828 * s, y: 410 * s)
        }
    }

    private func padRowY(_ row: Int) -> CGFloat {
        17 + 50.375 * CGFloat(row) + 21.6875
    }

    private func stepX(_ index: Int) -> CGFloat {
        688 + CGFloat(index % 8) * 30
    }

    private func stepY(_ index: Int) -> CGFloat {
        index < 8 ? 302 : 350
    }

    private func bayButton(_ id: String, icon: String? = nil, label: String? = nil,
                           column: Int, row: Int, s: CGFloat) -> some View {
        FunctionButton(id: id, systemImage: icon, label: label, diameter: 30 * s)
            .position(x: (710 + CGFloat(column) * 40) * s,
                      y: (222 + CGFloat(row) * 38) * s)
    }
}
