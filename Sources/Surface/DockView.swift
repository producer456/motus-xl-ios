import SwiftUI

/// The phone with the FULL hardware rig (Launchpad grid + Launchkey keys):
/// every performance control lives on hardware, so the screen stops being a
/// replica and becomes the color command deck the rig never had — glanceable
/// track state, and direct touch where Shift+Step menus used to be. The
/// dot-matrix screen appears large only while a menu or overlay needs the
/// wheel; otherwise it's cards.
struct DockView: View {
    @EnvironmentObject var client: Brain
    @StateObject private var motion = MotionSource()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / 932, geo.size.height / 430)
            ZStack {
                Color.black.ignoresSafeArea()
                GrainOverlay(opacity: 0.05).ignoresSafeArea()
                content(scale: s)
                    .frame(width: 932 * s, height: 430 * s)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .ignoresSafeArea()
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? motion.start() : motion.stop()
        }
        .sheet(isPresented: Binding(get: { client.auSheetVC != nil },
                                    set: { if !$0 { client.auSheetVC = nil } })) {
            if let vc = client.auSheetVC {
                AUPluginView(viewController: vc).ignoresSafeArea()
            }
        }
    }

    private func color(_ i: Int) -> Color {
        let c = Brain.trackColors[i % 8]
        return Color(red: c.x, green: c.y, blue: c.z)
    }

    @ViewBuilder
    private func content(scale s: CGFloat) -> some View {
        let song = client.songInfo
        VStack(spacing: 10 * s) {
            // ---- Header: set · transport · BPM (tap = tempo) · key (tap = scale) ----
            HStack(spacing: 14 * s) {
                Text(song.name.uppercased())
                    .font(.system(size: 15 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Circle()
                    .fill(client.isRecording ? Color.red
                          : client.playingNow ? Color.green : Color(white: 0.25))
                    .frame(width: 10 * s, height: 10 * s)
                Spacer()
                Button { client.openShiftMenu(4) } label: {
                    Text("\(Int(song.tempo)) BPM")
                        .font(.system(size: 24 * s, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button { client.openShiftMenu(8) } label: {
                    chip("\(Scales.noteNames[song.rootNote]) \(Scales.all[song.scaleIndex].name.uppercased())", s: s)
                }
                chip("SCENE \(song.selectedScene + 1)", s: s)
                Button { client.openShiftMenu(0) } label: {   // Set Overview
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Button { client.openShiftMenu(5) } label: {   // Metronome
                    Image(systemName: "metronome.fill")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Button { client.openShiftMenu(10) } label: {  // Repeat / Arp
                    Image(systemName: "repeat.1")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Button { client.openShiftMenu(2) } label: {   // Workflow
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Button { client.openShiftMenu(1) } label: {   // Setup
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 36 * s)
            .padding(.top, 10 * s)

            // ---- Center: menu screen when needed, else the track cards ----
            if client.menuOpen || client.overlayActive {
                DisplayView(image: client.displayImage, tilt: motion.tilt)
                    .frame(width: (client.launchkeyOn ? 560 : 440) * s,
                           height: (client.launchkeyOn ? 280 : 220) * s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                trackCards(song: song, s: s)
            }

            // Launchpad-only rig: the deck carries what nothing covers —
            // the 8 encoders (+ volume) and transport.
            if !client.launchkeyOn {
                HStack(spacing: 16 * s) {
                    FunctionButton(id: "play", systemImage: "play.fill", diameter: 40 * s, litColor: .green)
                    FunctionButton(id: "record", systemImage: "circle.fill", diameter: 40 * s, litColor: .red)
                    Spacer()
                    ForEach(0..<8, id: \.self) { i in
                        EncoderView(index: i, diameter: 40 * s, tilt: motion.tilt)
                    }
                    Spacer()
                    EncoderView(index: 8, diameter: 40 * s, tilt: motion.tilt)
                }
                .padding(.horizontal, 40 * s)
            }

            // ---- Bottom bar: only what hardware can't do ----
            HStack(spacing: 20 * s) {
                WheelView(diameter: 62 * s, tilt: motion.tilt)
                FunctionButton(id: "back", systemImage: "chevron.left", diameter: 34 * s)
                FunctionButton(id: "loop", systemImage: "repeat", diameter: 34 * s)
                FunctionButton(id: "mute", label: "M", diameter: 34 * s)
                FunctionButton(id: "delete", systemImage: "xmark", diameter: 34 * s)
                FunctionButton(id: "copy", systemImage: "square.on.square", diameter: 34 * s)
                FunctionButton(id: "undo", systemImage: "arrow.uturn.backward", diameter: 34 * s)
                FunctionButton(id: "quantize", systemImage: "arrow.right.to.line", diameter: 34 * s)
                FunctionButton(id: "auview", systemImage: "macwindow", diameter: 34 * s)
                Spacer()
                Text("MOTUS XL DOCK")
                    .font(.system(size: 9 * s, weight: .bold, design: .rounded))
                    .kerning(2 * s)
                    .foregroundStyle(Color(white: 0.30))
                HardwareButton {
                    client.button("power", down: true)
                } onRelease: {
                    client.button("power", down: false)
                } content: { pressed in
                    ZStack {
                        RoundButton(diameter: 26 * s, lit: 0, pressed: pressed)
                        Image(systemName: "power")
                            .font(.system(size: 10 * s, weight: .bold))
                            .foregroundStyle(client.poweredOn ? Color(white: 0.9) : Color(white: 0.3))
                    }
                }
            }
            .padding(.horizontal, 40 * s)
            .padding(.bottom, 8 * s)
        }
    }

    private func chip(_ text: String, s: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11 * s, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10 * s)
            .padding(.vertical, 4 * s)
            .background(Capsule().fill(Color(white: 0.13)))
    }

    /// 8 tracks as color cards: tap = select, tap the selected one = browser.
    private func trackCards(song: Song, s: CGFloat) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10 * s), count: 4)
        return LazyVGrid(columns: cols, spacing: 10 * s) {
            ForEach(0..<8, id: \.self) { t in
                let track = song.tracks[t]
                let selected = t == song.selectedTrack
                Button {
                    if selected {
                        client.openBrowserForSelected()
                    } else {
                        client.button("track\(t + 1)", down: true)
                        client.button("track\(t + 1)", down: false)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4 * s) {
                        HStack {
                            RoundedRectangle(cornerRadius: 2 * s)
                                .fill(color(t))
                                .frame(width: 22 * s, height: 5 * s)
                            Spacer()
                            if track.muted {
                                Text("M")
                                    .font(.system(size: 10 * s, weight: .heavy))
                                    .foregroundStyle(.black)
                                    .padding(3 * s)
                                    .background(Circle().fill(Color(white: 0.75)))
                            }
                        }
                        Text(track.name.uppercased())
                            .font(.system(size: 13 * s, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                        Text(soundName(track).uppercased())
                            .font(.system(size: 9.5 * s, weight: .medium, design: .rounded))
                            .foregroundStyle(color(t).opacity(0.9))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Level bar + clip dots for the 8 scenes.
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2 * s)
                                .fill(Color(white: 0.16))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2 * s)
                                        .fill(color(t).opacity(0.8))
                                        .frame(width: g.size.width * track.volume)
                                }
                        }
                        .frame(height: 5 * s)
                        HStack(spacing: 3 * s) {
                            ForEach(0..<8, id: \.self) { scene in
                                Circle()
                                    .fill(track.clips[scene].isEmpty
                                          ? Color(white: 0.18)
                                          : (scene == song.selectedScene ? color(t) : color(t).opacity(0.45)))
                                    .frame(width: 5 * s, height: 5 * s)
                            }
                        }
                    }
                    .padding(10 * s)
                    .frame(maxWidth: .infinity,
                           minHeight: (client.launchkeyOn ? 118 : 88) * s,
                           alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 12 * s)
                            .fill(Color(white: selected ? 0.14 : 0.085))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12 * s)
                            .strokeBorder(selected ? color(t).opacity(0.8) : Color(white: 0.16),
                                          lineWidth: selected ? 1.6 * s : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 36 * s)
    }

    private func soundName(_ track: Track) -> String {
        if let preset = track.auPresetName { return preset }
        if let au = track.auName { return au }
        if track.kind == .drum {
            return DrumKits.names.indices.contains(track.soundIndex)
                ? DrumKits.names[track.soundIndex] : "KIT"
        }
        return SynthPreset.all[track.soundIndex % SynthPreset.all.count].name
    }
}
