import SwiftUI
import OSLog

@main
struct V2XMacSnifferApp: App {
    // Shared State für beide Fenster (Hauptfenster & Debugging-Zentrale)
    @State private var hw = V2XHardwareManager()
    @Environment(\.scenePhase) private var scenePhase
    private let logger = Logger(subsystem: "V2XMacSniffer", category: "AppLifecycle")
    
    private func handleScenePhaseChange(from oldPhase: ScenePhase?, to newPhase: ScenePhase) {
        switch newPhase {
        case .background, .inactive:
            logger.debug("ScenePhase changed to \(String(describing: newPhase)); initiating shutdown")
            hw.stopAll()
        case .active:
            logger.debug("ScenePhase active")
        @unknown default:
            logger.debug("ScenePhase unknown; performing defensive stop")
            hw.stopAll()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(hw: hw)
                .task { // early startup hook
                    logger.debug("App startup: initializing hardware manager")
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        
        // Deklaration des separaten Debugging-Fensters
        Window("Debugging-Zentrale", id: "debug_window") {
            DebugConsoleView(hw: hw)
        }
        .defaultSize(width: 700, height: 500)
    }
}

