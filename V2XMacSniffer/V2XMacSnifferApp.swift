import SwiftUI

@main
struct V2XMacSnifferApp: App {
    // Shared State für beide Fenster (Hauptfenster & Debugging-Zentrale)
    @State private var hw = V2XHardwareManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView(hw: hw)
        }
        
        // Deklaration des separaten Debugging-Fensters
        Window("Debugging-Zentrale", id: "debug_window") {
            DebugConsoleView(hw: hw)
        }
        .defaultSize(width: 700, height: 500)
    }
}
