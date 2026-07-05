import SwiftUI

@main
struct MotusApp: App {
    @StateObject private var brain = Brain()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PanelView()
                .environmentObject(brain)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear { brain.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Gesture cancellation on app switch never delivers releases —
            // clear held modifiers so shift/delete can't stay latched.
            brain.releaseModifiers()
            if phase == .background { brain.saveCurrentSet() }
        }
    }
}
