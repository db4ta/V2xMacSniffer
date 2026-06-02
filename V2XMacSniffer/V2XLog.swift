import Foundation
import OSLog

// Zentralisierte Logger-Instanzen zur strukturellen Konsolidierung.
// WICHTIG: Nur Struktur, keine Änderung der Log-Strings an den Aufrufstellen erforderlich.
public enum V2XLog {
    public static let appLifecycle = Logger(subsystem: "V2XMacSniffer", category: "AppLifecycle")
    public static let serialIO      = Logger(subsystem: "V2XMacSniffer", category: "SerialIO")
    public static let network       = Logger(subsystem: "V2XMacSniffer", category: "Network")
    public static let offlineMaps   = Logger(subsystem: "V2XMacSniffer", category: "OfflineMaps")
}
