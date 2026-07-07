import SwiftUI

@main
struct MotusApp: App {
    @StateObject private var brain = Brain()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    PhonePanelView()   // "Move Go" rack for landscape iPhone
                } else {
                    PanelView()
                }
            }
                .environmentObject(brain)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    brain.start()
                    // Hands on hardware = no screen touches; don't sleep mid-jam.
                    UIApplication.shared.isIdleTimerDisabled = true
                    if ProcessInfo.processInfo.arguments.contains("-crashtest") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            brain.button("track2", down: true)
                            brain.button("track2", down: false)
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Gesture cancellation on app switch never delivers releases —
            // clear held modifiers so shift/delete can't stay latched.
            brain.releaseModifiers()
            if phase == .background { brain.saveCurrentSet() }
        }
    }
}
