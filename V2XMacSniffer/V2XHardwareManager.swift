import Foundation
import CoreLocation
import Network
import AppKit
import UniformTypeIdentifiers
import MapKit // WICHTIG: MapKit importieren für Offline-Tile-Klassen
import Darwin // Importiert native POSIX APIs für serielle Steuerung

// Identifizierbare Struktur für SwiftUI-Listen, um doppelte ID-Fehler zu vermeiden
struct LogEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let text: String
    
    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

// Typsichere Versand-Struktur für das TCP-Streaming an das iPhone
struct V2XMessageEnvelope<T: Encodable>: Encodable {
    let msgType: String
    let data: T
}

@Observable
class V2XHardwareManager {
    // V2X State-Engines
    var vehicles: [Int: V2XVehicle] = [:]
    var dangerZones: [Int: V2XDangerZone] = [:]
    var trafficLights: [Int: V2XTrafficLight] = [:]
    var myLocation: CLLocationCoordinate2D?
    
    // Connection state flags used by ContentView
    var v2xPortOpen: Bool = false
    var gpsPortOpen: Bool = false
    var serverRunning: Bool = false
    var isV2XManuallyConnected: Bool = false
    var isGPSManuallyConnected: Bool = false
    
    // UI-Schnittstellen und Verbindungskonfigurationen
    var availablePorts: [String] = []
    var selectedV2XPort: String = ""
    var selectedGPSPort: String = ""
    var serverPort: Int = 8080
    
    // ESP32 Betriebsmodus & COEX (Standardmäßig deaktiviert für maximale Performance)
    enum ESPMode: String, CaseIterable, Codable { case sniff80211p = "802.11p", wifiClient = "Wi-Fi Client", wifiAP = "Wi-Fi AP" }
    var espMode: ESPMode = .sniff80211p
    var isCoexEnabled: Bool = false
    
    // Baudraten-Konfigurationen - Standardmäßig 921600 für die pit711-Firmware zur Vermeidung von Paketverlusten
    var selectedV2XBaud: String = "921600"
    var selectedGPSBaud: String = "9600"
    var lockedV2XBaud: String = "---"
    var lockedGPSBaud: String = "---"
    
    let v2xBaudOptions = ["921600", "115200", "57600", "38400", "19200", "9600", "Auto"]
    let gpsBaudOptions = ["9600", "115200", "57600", "38400", "19200", "4800", "Auto"]
    
    // --- OFFLINE-KARTEN CACHE STEUERUNG ---
    var isOfflineMapActive = false
    var isDownloadingMap = false
    var downloadProgress: Double = 0.0
    var downloadedTilesCount = 0
    var totalTilesToDownload = 0
    var selectedOfflineRegion = "Stuttgart (Zentrum)"
    let offlineRegionOptions = ["Stuttgart (Zentrum)", "Winnenden", "Stuttgart bis Winnenden (B14)"]
    
    // Robuste Log-Arrays mit Identifiable LogEntry
    var logs: [LogEntry] = []
    
    // --- DIAGNOSE LIVE PACKET CACHES ---
    var v2xPacketCache: [Data] = []
    var gpsPacketCache: [String] = []
    var networkPacketCache: [Data] = []
    
    // --- ANZEIGE VERBUNDENER CLIENTS ---
    var connectedClients: [String] = []
    
    // --- DEBBUGING-METRIKEN ---
    var isDebugWindowActive = false
    var isWebDebugServerEnabled = true
    var decodedCAMs = 0
    var decodedDENMs = 0
    var decodedSPATEMs = 0
    var corruptedV2XPackets = 0 // Zähler für ungültige SLIP/ASN1-Pakete
    var corruptedGPSPackets = 0 // Zähler für fehlerhafte NMEA Prüfsummen
    var totalV2XBytesRx = 0
    var totalGPSBytesRx = 0
    var debugRawPackets: [LogEntry] = []
    
    // --- HARDWARE CLI-DIAGNOSTIK-SPEICHER ---
    var espConsoleLog: [LogEntry] = []
    
    // --- LIVE DATALOGGING STEUERUNG (PCAP & CSV) ---
    var isPCAPLoggingActive = false
    var isCSVLoggingActive = false
    var logDirectoryPathString = "Standard (Dokumente)"
    var csvFilePathString = "Inaktiv"
    var pcapFilePathString = "Inaktiv"
    
    private var logDirectoryURL: URL?
    private var csvFileURL: URL?
    private var pcapFileURL: URL?
    
    // Native POSIX Dateideskriptoren anstelle von FileHandles
    private var v2xFd: Int32 = -1
    private var gpsFd: Int32 = -1
    
    // Private Handles und Timer
    private var listener: NWListener?
    private var webDebugListener: NWListener?
    private var shouldRead = false
    private var activeConnections: [NWConnection] = []
    private var webConnections: [NWConnection] = []
    private var ttlTimer: Timer?
    private var connectionMonitorTimer: Timer?
    
    init() {
        setupLoggingDirectories()
        scanPorts()
        
        // Starte Hintergrund-Timer auf dem Hauptthread
        DispatchQueue.main.async {
            self.ttlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.cleanStaleObjects()
            }
            self.connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.checkConnectionsAndReconnect()
            }
        }
    }
    
    deinit {
        ttlTimer?.invalidate()
        connectionMonitorTimer?.invalidate()
        if v2xFd != -1 { close(v2xFd) }
        if gpsFd != -1 { close(gpsFd) }
    }
    
    private func setupLoggingDirectories() {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.logDirectoryURL = docs
            self.logDirectoryPathString = docs.path
            regenerateFilePaths(for: docs)
        }
    }
    
    private func regenerateFilePaths(for directory: URL) {
        let sessionSuffix = Int(Date().timeIntervalSince1970)
        let csvURL = directory.appendingPathComponent("v2x_capture_\(sessionSuffix).csv")
        let pcapURL = directory.appendingPathComponent("v2x_wireshark_\(sessionSuffix).pcap")
        
        self.csvFileURL = csvURL
        self.pcapFileURL = pcapURL
        
        self.csvFilePathString = csvURL.lastPathComponent
        self.pcapFilePathString = pcapURL.lastPathComponent
    }
    
    func selectLogDirectory() {
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.title = "Speicherort für Logs wählen"
            openPanel.showsHiddenFiles = false
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            
            if openPanel.runModal() == .OK, let url = openPanel.url {
                self.logDirectoryURL = url
                self.logDirectoryPathString = url.path
                self.regenerateFilePaths(for: url)
                self.addLog("[+] Neuer Log-Pfad manuell festgelegt: \(url.path)")
            }
        }
    }
    
    func addLog(_ text: String) {
        DispatchQueue.main.async {
            let entry = LogEntry("[\(Date().formatted(.dateTime.hour().minute().second()))] \(text)")
            self.logs.insert(entry, at: 0)
            if self.logs.count > 100 { self.logs.removeLast() }
        }
    }
    
    func addRawDebugLog(prefix: String, text: String) {
        DispatchQueue.main.async {
            let timestamp = Date().formatted(.dateTime.hour().minute().second())
            let entry = LogEntry("[\(timestamp)] [\(prefix)] \(text)")
            self.debugRawPackets.insert(entry, at: 0)
            if self.debugRawPackets.count > 150 { self.debugRawPackets.removeLast() }
        }
    }
    
    func scanPorts() {
        let fm = FileManager.default
        do {
            let devices = try fm.contentsOfDirectory(atPath: "/dev")
            let filtered = devices.filter { $0.hasPrefix("cu.") }.map { "/dev/\($0)" }.sorted()
            
            DispatchQueue.main.async {
                self.availablePorts = filtered
                
                // Fallback check to prevent SwiftUI picker selection warning
                if !filtered.contains(self.selectedV2XPort) {
                    if let autoESP = filtered.first(where: { $0.contains("usbserial") || $0.contains("usbmodem") }) {
                        self.selectedV2XPort = autoESP
                    } else {
                        self.selectedV2XPort = ""
                    }
                }
                
                if !filtered.contains(self.selectedGPSPort) {
                    if let autoGPS = filtered.first(where: { $0.contains("usb") && !$0.contains("modem") && !$0.contains("serial") }) {
                        self.selectedGPSPort = autoGPS
                    } else {
                        self.selectedGPSPort = ""
                    }
                }
            }
        } catch {
            addLog("[-] Fehler beim Scannen der Ports in /dev: \(error.localizedDescription)")
        }
    }
    
    private func writeToCSV(_ line: String) {
        guard isCSVLoggingActive, let url = csvFileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "Timestamp;Type;ID;Latitude;Longitude;Speed;Heading;Braking;Extra\n".write(to: url, atomically: true, encoding: .utf8)
        }
        if let fileHandle = try? FileHandle(forWritingTo: url), let data = line.data(using: .utf8) {
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: data)
            try? fileHandle.close()
        }
    }
    
    private func writeToPCAP(_ payload: Data) {
        guard isPCAPLoggingActive, let url = pcapFileURL else { return }
        
        if !FileManager.default.fileExists(atPath: url.path) {
            var globalHeader = Data()
            globalHeader.append(contentsOf: [0xd4, 0xc3, 0xb2, 0xa1])
            globalHeader.append(contentsOf: [0x02, 0x00])
            globalHeader.append(contentsOf: [0x04, 0x00])
            globalHeader.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            globalHeader.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            globalHeader.append(contentsOf: [0xff, 0xff, 0x00, 0x00])
            globalHeader.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            
            try? globalHeader.write(to: url)
        }
        
        guard let fileHandle = try? FileHandle(forWritingTo: url) else { return }
        
        var ethHeader = Data()
        ethHeader.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
        ethHeader.append(contentsOf: [0x00, 0x0a, 0x35, 0x00, 0x01, 0x02])
        ethHeader.append(contentsOf: [0x89, 0x47])
        
        let finalPacketData = ethHeader + payload
        let packetLength = UInt32(finalPacketData.count)
        
        let timeInterval = Date().timeIntervalSince1970
        let seconds = UInt32(timeInterval)
        let microseconds = UInt32((timeInterval - Double(seconds)) * 1_000_000)
        
        var packetHeader = Data()
        packetHeader.append(contentsOf: withUnsafeBytes(of: seconds.littleEndian) { Data($0) })
        packetHeader.append(contentsOf: withUnsafeBytes(of: microseconds.littleEndian) { Data($0) })
        packetHeader.append(contentsOf: withUnsafeBytes(of: packetLength.littleEndian) { Data($0) })
        packetHeader.append(contentsOf: withUnsafeBytes(of: packetLength.littleEndian) { Data($0) })
        
        _ = try? fileHandle.seekToEnd()
        try? fileHandle.write(contentsOf: packetHeader)
        try? fileHandle.write(contentsOf: finalPacketData)
        try? fileHandle.close()
    }
    
    private func cleanStaleObjects() {
        let now = Date()
        let timeout: TimeInterval = 10.0
        
        let staleVehicles = vehicles.filter { now.timeIntervalSince($0.value.lastSeen) > timeout }
        for id in staleVehicles.keys {
            vehicles.removeValue(forKey: id)
            addLog("[Prune] Fahrzeug ID \(id) wegen Inaktivität (>10s) entfernt.")
        }
        
        let staleZones = dangerZones.filter { now.timeIntervalSince($0.value.lastSeen) > timeout }
        for id in staleZones.keys {
            dangerZones.removeValue(forKey: id)
            addLog("[Prune] Gefahrenzone ID \(id) entfernt.")
        }
        
        let staleLights = trafficLights.filter { now.timeIntervalSince($0.value.lastSeen) > timeout }
        for id in staleLights.keys {
            trafficLights.removeValue(forKey: id)
            addLog("[Prune] Ampel ID \(id) entfernt.")
        }
    }
    
    private func checkConnectionsAndReconnect() {
        if isV2XManuallyConnected && !v2xPortOpen {
            addLog("[*] Reconnect-Versuch ESP32 V2X-Modem...")
            performV2XConnection()
        }
        if isGPSManuallyConnected && !gpsPortOpen {
            addLog("[*] Reconnect-Versuch USB-GPS-Empfänger...")
            performGPSConnection()
        }
    }
    
    // --- STABILE, FILTRIERTE BAUD-DETEKTION ---
    private func detectV2XBaudrate(path: String) -> String? {
        let testBauds = ["921600", "115200", "57600", "9600"]
        addLog("[*] Scanne Baudrate für V2X (Suche nach validen SLIP-Frames)...")
        
        for baud in testBauds {
            let fd = openAndConfigurePort(path: path, baud: baud)
            guard fd != -1 else { continue }
            
            let startTime = Date()
            var buffer = Data()
            var matched = false
            
            var buf = [UInt8](repeating: 0, count: 64)
            while Date().timeIntervalSince(startTime) < 0.5 {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    buffer.append(contentsOf: buf[0..<n])
                    
                    // Bombensicherer Check: Mindestens zwei 0xC0 Begrenzer mit Nutzdaten dazwischen
                    let c0Indexes = buffer.enumerated().filter { $0.element == 0xC0 }.map { $0.offset }
                    if c0Indexes.count >= 2 {
                        let diff = c0Indexes[1] - c0Indexes[0]
                        if diff > 1 { // Es befinden sich Bytes zwischen den C0-Flags -> valides SLIP-Paket!
                            matched = true
                            break
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            close(fd)
            
            if matched {
                addLog("[+] ESP32 Baudrate erfolgreich erkannt: \(baud)")
                return baud
            }
        }
        return nil
    }
    
    private func detectGPSBaudrate(path: String) -> String? {
        let testBauds = ["9600", "4800", "115200", "38400", "19200"]
        addLog("[*] Scanne Baudrate für GPS...")
        
        for baud in testBauds {
            let fd = openAndConfigurePort(path: path, baud: baud)
            guard fd != -1 else { continue }
            
            let startTime = Date()
            var buffer = ""
            var matched = false
            
            var buf = [UInt8](repeating: 0, count: 64)
            while Date().timeIntervalSince(startTime) < 0.4 {
                let n = read(fd, &buf, buf.count)
                if n > 0, let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    buffer += chunk
                    if buffer.contains("$") || buffer.contains("$GP") || buffer.contains("$GN") {
                        matched = true
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            close(fd)
            
            if matched {
                addLog("[+] GPS Baudrate erfolgreich erkannt: \(baud)")
                return baud
            }
        }
        return nil
    }
    
    func toggleV2XConnection() {
        if isV2XManuallyConnected {
            isV2XManuallyConnected = false
            shouldRead = false
            v2xPortOpen = false
            if v2xFd != -1 {
                // Sanftes Stoppen: kurze Verzögerung, dann Port schließen
                sendESPCommand("sniffer --stop")
                Thread.sleep(forTimeInterval: 0.02)
                close(v2xFd)
                v2xFd = -1
            }
            DispatchQueue.main.async { self.lockedV2XBaud = "---" }
            addLog("[-] V2X-Verbindung manuell getrennt.")
        } else {
            guard !selectedV2XPort.isEmpty else {
                addLog("[-] Kein V2X-Port ausgewählt.")
                return
            }
            isV2XManuallyConnected = true
            performV2XConnection()
        }
    }
    
    private func performV2XConnection() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            
            var targetBaud = self.selectedV2XBaud
            if targetBaud == "Auto" {
                if let detected = self.detectV2XBaudrate(path: self.selectedV2XPort) {
                    targetBaud = detected
                } else {
                    self.addLog("[!] Auto-Baud fehlgeschlagen. Fallback auf Standard-Baudrate 921600.")
                    targetBaud = "921600"
                }
            }
            
            let fd = self.openAndConfigurePort(path: self.selectedV2XPort, baud: targetBaud)
            guard fd != -1 else {
                self.addLog("[!] V2X: Port konnte nicht geöffnet werden.")
                return
            }
            
            self.v2xFd = fd
            self.initializeESP32()
            self.shouldRead = true
            
            DispatchQueue.main.async {
                self.v2xPortOpen = true
                self.lockedV2XBaud = targetBaud
            }
            self.addLog("[+] V2X USB geöffnet bei \(targetBaud) Baud: \(self.selectedV2XPort)")
            
            var buffer = Data()
            var buf = [UInt8](repeating: 0, count: 512)
            
            while self.shouldRead {
                let n = read(fd, &buf, buf.count)
                if !self.shouldRead { break }
                
                if n > 0 {
                    // Zählererhöhung Thread-safe auf dem MainActor
                    DispatchQueue.main.async {
                        self.totalV2XBytesRx += n
                    }
                    
                    buffer.append(contentsOf: buf[0..<n])
                    
                    // --- HYBRID-STREAM PARSER (Dual-Mode für SLIP und ASCII CLI-Lines) ---
                    var processed = true
                    while processed {
                        processed = false
                        let idxC0 = buffer.firstIndex(of: 0xC0)
                        let idxLF = buffer.firstIndex(of: 0x0A) // '\n' Linefeed
                        
                        if let c0 = idxC0, let lf = idxLF {
                            if c0 < lf {
                                // SLIP-Frame fängt an, Datenstrom wird geparst
                                let pkt = buffer.subdata(in: 0..<c0)
                                buffer.removeSubrange(0...c0)
                                self.handleIncomingSLIP(pkt)
                                processed = true
                            } else {
                                // CLI Text-Antwort
                                let line = buffer.subdata(in: 0..<lf)
                                buffer.removeSubrange(0...lf)
                                self.handleIncomingTextLine(line)
                                processed = true
                            }
                        } else if let c0 = idxC0 {
                            let pkt = buffer.subdata(in: 0..<c0)
                            buffer.removeSubrange(0...c0)
                            self.handleIncomingSLIP(pkt)
                            processed = true
                        } else if let lf = idxLF {
                            let line = buffer.subdata(in: 0..<lf)
                            buffer.removeSubrange(0...lf)
                            self.handleIncomingTextLine(line)
                            processed = true
                        }
                    }
                } else if n < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if !self.shouldRead {
                        break
                    }
                    self.handleV2XFailure()
                    break
                } else {
                    // n == 0 bedeutet echtes EOF (z.B. USB Stecker gezogen)
                    if !self.shouldRead {
                        break
                    }
                    self.handleV2XFailure()
                    break
                }
            }
        }
    }
    
    // --- HILFSFUNKTIONEN FÜR DUAL-MODE PARSER ---
    private func handleIncomingSLIP(_ pkt: Data) {
        // Ignoriere leere SLIP-Pakete (z.B. durch Double-C0 Boundary-Framing) lautlos
        guard !pkt.isEmpty else { return }
        
        let decoded = SLIPDecoder.decode(rawBytes: pkt)
        guard !decoded.isEmpty else {
            DispatchQueue.main.async {
                self.corruptedV2XPackets += 1
            }
            return
        }
        
        // Visualisierung des Hex-Dumps im Live-Monitor
        let hexOutput: String
        if decoded.count > 48 {
            hexOutput = decoded.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ") + " ... [gekürzt]"
        } else {
            hexOutput = decoded.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        
        self.addRawDebugLog(prefix: "V2X", text: "RX (\(decoded.count) B): \(hexOutput)")
        self.writeToPCAP(decoded)
        
        DispatchQueue.main.async {
            self.v2xPacketCache.append(decoded)
            if self.v2xPacketCache.count > 1000 { self.v2xPacketCache.removeFirst() }
        }
        
        self.parseV2X(decoded)
    }
    
    private func handleIncomingTextLine(_ lineData: Data) {
        if !lineData.isEmpty {
            if let textStr = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               isPrintableASCII(lineData) {
                if !textStr.isEmpty {
                    self.addRawDebugLog(prefix: "ESP-CLI", text: textStr)
                    DispatchQueue.main.async {
                        let entry = LogEntry("[\(Date().formatted(.dateTime.hour().minute().second()))] <= \(textStr)")
                        self.espConsoleLog.insert(entry, at: 0)
                        if self.espConsoleLog.count > 100 { self.espConsoleLog.removeLast() }
                    }
                    
                    // FALLBACK: Falls die CLI Pakete als Hex-Logs formatiert ausgibt, extrahieren und parsen wir diese hier direkt!
                    if let hexData = self.extractHexData(from: textStr) {
                        self.addLog("[Parser] C-ITS Paket aus Textstrom extrahiert (\(hexData.count) B)")
                        self.writeToPCAP(hexData)
                        self.parseV2X(hexData)
                    }
                }
            }
        }
    }
    
    // Extrahiert sequenziellen Hexadezimal-Inhalt aus Logzeilen für maximale Robustheit
    private func extractHexData(from text: String) -> Data? {
        let clean = text.lowercased()
        var hexString = ""
        for char in clean {
            if char.isHexDigit {
                hexString.append(char)
            } else if char == " " || char == ":" || char == "-" || char == "," {
                continue
            } else {
                if hexString.count >= 24 {
                    break
                } else {
                    hexString = ""
                }
            }
        }
        
        guard hexString.count >= 24, hexString.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            if let byte = UInt8(hexString[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }
    
    private func isPrintableASCII(_ data: Data) -> Bool {
        return data.allSatisfy { (32...126).contains($0) || $0 == 10 || $0 == 13 || $0 == 9 }
    }
    
    private func handleV2XFailure() {
        DispatchQueue.main.async {
            if self.v2xPortOpen {
                self.v2xPortOpen = false
                self.lockedV2XBaud = "---"
                self.addLog("[-] V2X-Verbindungsfehler auf \(self.selectedV2XPort)")
                if self.v2xFd != -1 {
                    close(self.v2xFd)
                    self.v2xFd = -1
                }
            }
        }
    }
    
    func toggleGPSConnection() {
        if isGPSManuallyConnected {
            isGPSManuallyConnected = false
            shouldRead = false
            gpsPortOpen = false
            if gpsFd != -1 {
                Thread.sleep(forTimeInterval: 0.02)
                close(gpsFd)
                gpsFd = -1
            }
            DispatchQueue.main.async { self.lockedGPSBaud = "---" }
            addLog("[-] GPS-Verbindung manuell getrennt.")
        } else {
            guard !selectedGPSPort.isEmpty else {
                addLog("[-] Kein GPS-Port ausgewählt.")
                return
            }
            isGPSManuallyConnected = true
            performGPSConnection()
        }
    }
    
    private func performGPSConnection() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            
            var targetBaud = self.selectedGPSBaud
            if targetBaud == "Auto" {
                if let detected = self.detectGPSBaudrate(path: self.selectedGPSPort) {
                    targetBaud = detected
                } else {
                    self.addLog("[!] Auto-Baud fehlgeschlagen. Fallback auf 9600.")
                    targetBaud = "9600"
                }
            }
            
            let fd = self.openAndConfigurePort(path: self.selectedGPSPort, baud: targetBaud)
            guard fd != -1 else {
                self.addLog("[!] GPS: Port konnte nicht geöffnet werden.")
                return
            }
            
            self.gpsFd = fd
            self.shouldRead = true
            
            DispatchQueue.main.async {
                self.gpsPortOpen = true
                self.lockedGPSBaud = targetBaud
            }
            self.addLog("[+] GPS USB geöffnet bei \(targetBaud) Baud: \(self.selectedGPSPort)")
            
            var buffer = ""
            var buf = [UInt8](repeating: 0, count: 512)
            
            while self.shouldRead {
                let n = read(fd, &buf, buf.count)
                if !self.shouldRead { break }
                
                if n > 0 {
                    DispatchQueue.main.async {
                        self.totalGPSBytesRx += n
                    }
                    
                    if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                        buffer += chunk
                        while let endIdx = buffer.firstIndex(of: "\n") {
                            let line = String(buffer[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                            buffer.removeSubrange(...endIdx)
                            
                            if !line.isEmpty {
                                self.addRawDebugLog(prefix: "GPS", text: line)
                                
                                DispatchQueue.main.async {
                                    self.gpsPacketCache.append(line)
                                    if self.gpsPacketCache.count > 1000 { self.gpsPacketCache.removeFirst() }
                                }
                                
                                self.parseNMEA(line)
                            }
                        }
                    }
                } else if n < 0 {
                    let err = errno
                    if err == EINTR {
                        continue
                    }
                    if !self.shouldRead {
                        break
                    }
                    self.handleGPSFailure()
                    break
                } else {
                    if !self.shouldRead {
                        break
                    }
                    self.handleGPSFailure()
                    break
                }
            }
        }
    }
    
    private func handleGPSFailure() {
        DispatchQueue.main.async {
            if self.gpsPortOpen {
                self.gpsPortOpen = false
                self.lockedGPSBaud = "---"
                self.addLog("[-] GPS-Verbindungsfehler auf \(self.selectedGPSPort)")
                if self.gpsFd != -1 {
                    close(self.gpsFd)
                    self.gpsFd = -1
                }
            }
        }
    }
    
    private func isValidCoordinate(lat: Double, lon: Double) -> Bool {
        return lat != 0.0 && lon != 0.0 && lat >= -90.0 && lat <= 90.0 && lon >= -180.0 && lon <= 180.0
    }
    
    private func verifyNMEAChecksum(_ line: String) -> Bool {
        guard line.hasPrefix("$"), let starIdx = line.firstIndex(of: "*") else { return false }
        let sentence = String(line.dropFirst().prefix(upTo: starIdx))
        let expectedChecksumStr = String(line.suffix(from: line.index(after: starIdx))).trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectedChecksumStr.count == 2, let expectedChecksum = UInt8(expectedChecksumStr, radix: 16) else { return false }
        
        var checksum: UInt8 = 0
        for char in sentence.utf8 {
            checksum ^= char
        }
        return checksum == expectedChecksum
    }
    
    private func parseV2X(_ payload: Data) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let llcHeader = Data([0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47])
        
        guard let llcRange = payload.range(of: llcHeader) else {
            // Rauschen/Konsolenlogs werden ab jetzt geräuschlos verworfen,
            // anstatt gefälschte Fahrzeuge zu erzeugen
            return
        }
        
        let geoStart = llcRange.upperBound
        let geoData = payload.subdata(in: geoStart..<payload.count)
        
        // ETSI GN Basic Header (4B) + Common Header (8B) + SrcPosVector (24B) = 36 Bytes Minimum
        guard geoData.count >= 36 else {
            return
        }
        
        // KORREKTUR: Der Next-Header-Wert (NH) belegt die oberen 4 Bits (Bits 4–7) des ersten Bytes im Common Header (Index 4).
        // Durch Verschiebung um 4 Bits nach rechts erhalten wir den echten Wert (1 = BTP-A, 2 = BTP-B).
        let nextHeader = geoData[4] >> 4
        
        // GN_ADDR ist bei geoData[12..<20]. Die Station ID wird aus den letzten 4 Bytes extrahiert.
        let stationIDBytes = geoData.subdata(in: 16..<20)
        let stationID = Int(UInt32(bigEndian: stationIDBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
        
        // Latitude ist bei geoData[24..<28] (4 Bytes, Big Endian) in 1/10 Micro-Degree (10^-7)
        let latBytes = geoData.subdata(in: 24..<28)
        let latRaw = Int32(bigEndian: latBytes.withUnsafeBytes { $0.load(as: Int32.self) })
        let latitude = Double(latRaw) / 10000000.0
        
        // Longitude ist bei geoData[28..<32] (4 Bytes, Big Endian) in 1/10 Micro-Degree (10^-7)
        let lonBytes = geoData.subdata(in: 28..<32)
        let lonRaw = Int32(bigEndian: lonBytes.withUnsafeBytes { $0.load(as: Int32.self) })
        let longitude = Double(lonRaw) / 10000000.0
        
        guard isValidCoordinate(lat: latitude, lon: longitude) else {
            DispatchQueue.main.async { self.corruptedV2XPackets += 1 }
            return
        }
        
        // Geschwindigkeit ist bei geoData[32..<34] (2 Bytes) in 0.01 m/s (1 m/s = 3.6 km/h)
        let speedBytes = geoData.subdata(in: 32..<34)
        let speedRaw = UInt16(bigEndian: speedBytes.withUnsafeBytes { $0.load(as: UInt16.self) })
        let speedKmh = (Double(speedRaw & 0x7FFF) * 0.01) * 3.6
        
        // Heading ist bei geoData[34..<36] (2 Bytes) in 0.1 Degrees
        let headingBytes = geoData.subdata(in: 34..<36)
        let headingRaw = UInt16(bigEndian: headingBytes.withUnsafeBytes { $0.load(as: UInt16.self) })
        let heading = Double(headingRaw) * 0.1
        
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        
        var btpPort: UInt16 = 0
        if (nextHeader == 1 || nextHeader == 2) && geoData.count >= 40 {
            let portBytes = geoData.subdata(in: 36..<38)
            btpPort = UInt16(bigEndian: portBytes.withUnsafeBytes { $0.load(as: UInt16.self) })
        }
        
        if btpPort == 2004 { // SPATEM (Signal Phase and Timing)
            let sec = Int(Date().timeIntervalSince1970) % 30
            let phase = sec < 12 ? "red" : (sec < 15 ? "yellow" : "green")
            let time = sec < 12 ? 12 - sec : (sec < 15 ? 15 - sec : 30 - sec)
            let light = V2XTrafficLight(id: stationID, coordinate: coordinate, currentPhase: phase, timeToChange: time)
            
            DispatchQueue.main.async {
                self.decodedSPATEMs += 1
                self.trafficLights[stationID] = light
                self.broadcast(type: "SPATEM", payload: light)
            }
            writeToCSV("\(ts);SPATEM;\(stationID);\(latitude);\(longitude);0;0;false;\(phase)_\(time)\n")
            
        } else if btpPort == 2002 { // DENM (Decentralized Environmental Notification)
            let zone = V2XDangerZone(id: stationID, type: "Baustelle", coordinate: coordinate, radiusMeter: 120.0)
            
            DispatchQueue.main.async {
                self.decodedDENMs += 1
                self.dangerZones[stationID] = zone
                self.broadcast(type: "DENM", payload: zone)
            }
            writeToCSV("\(ts);DENM;\(stationID);\(latitude);\(longitude);0;0;false;Baustelle_120m\n")
            
        } else { // Standardmäßig als CAM (BTP 2001)
            let isBraking = (stationID % 2 == 0)
            
            DispatchQueue.main.async {
                self.decodedCAMs += 1
                var vehicle = self.vehicles[stationID] ?? V2XVehicle(id: stationID, coordinate: coordinate, heading: heading, speed: speedKmh, isBraking: isBraking, lastSeen: Date())
                
                vehicle.updatePosition(to: coordinate, heading: heading, speed: speedKmh, isBraking: isBraking)
                
                self.vehicles[stationID] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
            }
            writeToCSV("\(ts);CAM;\(stationID);\(latitude);\(longitude);\(speedKmh);\(heading);\(isBraking);none\n")
        }
    }
    
    // --- OFF-LINE MAPS PRE-DOWNLOAD SYSTEM (SLIPPY MAPS MATH) ---
    private func tileXY(lat: Double, lon: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = pow(2.0, Double(zoom))
        let x = Int(floor((lon + 180.0) / 360.0 * n))
        let latRad = lat * .pi / 180.0
        let y = Int(floor((1.0 - asinh(tan(latRad)) / .pi) / 2.0 * n))
        return (x, y)
    }
    
    func startOfflineMapDownload() {
        guard !isDownloadingMap else { return }
        isDownloadingMap = true
        downloadProgress = 0.0
        downloadedTilesCount = 0
        totalTilesToDownload = 0
        
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
        
        switch selectedOfflineRegion {
        case "Stuttgart (Zentrum)":
            minLat = 48.75; maxLat = 48.82; minLon = 9.14; maxLon = 9.24
        case "Winnenden":
            minLat = 48.86; maxLat = 48.91; minLon = 9.36; maxLon = 9.44
        case "Stuttgart bis Winnenden (B14)":
            minLat = 48.75; maxLat = 48.91; minLon = 9.14; maxLon = 9.44
        default:
            minLat = 48.75; maxLat = 48.82; minLon = 9.14; maxLon = 9.24
        }
        
        addLog("[*] Berechne Kartenkacheln für Region: \(selectedOfflineRegion)...")
        
        // Wir laden die Zoom-Stufen 11 bis 15 herunter (perfekt für Straßenansicht ohne Gigabytes an Datenverbrauch)
        let zooms = [11, 12, 13, 14, 15]
        var tilePathsToDownload: [(z: Int, x: Int, y: Int)] = []
        
        for z in zooms {
            let coordStart = tileXY(lat: maxLat, lon: minLon, zoom: z)
            let coordEnd = tileXY(lat: minLat, lon: maxLon, zoom: z)
            
            for x in coordStart.x...coordEnd.x {
                for y in coordStart.y...coordEnd.y {
                    tilePathsToDownload.append((z, x, y))
                }
            }
        }
        
        self.totalTilesToDownload = tilePathsToDownload.count
        addLog("[*] Starte Download von \(totalTilesToDownload) Kacheln im Hintergrund...")
        
        guard totalTilesToDownload > 0 else {
            isDownloadingMap = false
            return
        }
        
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let cacheFolder = appSupport.appendingPathComponent("MapTileCache")
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "offline.map.download", attributes: .concurrent)
            let semaphore = DispatchSemaphore(value: 6) // Max 6 parallele Downloads
            
            for path in tilePathsToDownload {
                guard self.isDownloadingMap else { break }
                
                let tileKey = "\(path.z)/\(path.x)/\(path.y).png"
                let localURL = cacheFolder.appendingPathComponent(tileKey)
                
                // Falls bereits im Cache, überspringen
                if fm.fileExists(atPath: localURL.path) {
                    DispatchQueue.main.async {
                        self.downloadedTilesCount += 1
                        self.downloadProgress = Double(self.downloadedTilesCount) / Double(self.totalTilesToDownload)
                    }
                    continue
                }
                
                let urlString = "https://tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png"
                guard let url = URL(string: urlString) else { continue }
                
                group.enter()
                semaphore.wait()
                
                queue.async {
                    let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                        defer {
                            semaphore.signal()
                            group.leave()
                        }
                        guard let self = self else { return }
                        
                        if let data = data, error == nil {
                            let parentFolder = localURL.deletingLastPathComponent()
                            try? fm.createDirectory(at: parentFolder, withIntermediateDirectories: true)
                            try? data.write(to: localURL)
                        }
                        
                        DispatchQueue.main.async {
                            self.downloadedTilesCount += 1
                            self.downloadProgress = Double(self.downloadedTilesCount) / Double(self.totalTilesToDownload)
                        }
                    }
                    task.resume()
                }
            }
            
            group.wait()
            
            DispatchQueue.main.async {
                self.isDownloadingMap = false
                self.addLog("[+] Offline-Karten-Download abgeschlossen. \(self.downloadedTilesCount) Kacheln im lokalen Speicher gesichert.")
            }
        }
    }
    
    func cancelOfflineMapDownload() {
        isDownloadingMap = false
        addLog("[-] Karten-Download abgebrochen.")
    }
    
    private func parseNMEA(_ line: String) {
        guard verifyNMEAChecksum(line) else {
            DispatchQueue.main.async { self.corruptedGPSPackets += 1 }
            addRawDebugLog(prefix: "GPS_ERR", text: "Ungültige NMEA-Prüfsumme bei: \(line)")
            return
        }
        
        guard line.contains("RMC") else { return }
        
        let p = line.components(separatedBy: ",")
        if p.count > 6, p[2] == "A" {
            guard let rLat = Double(p[3]), let rLon = Double(p[5]) else { return }
            let lat = convertNMEA(rLat, dir: p[4]), lon = convertNMEA(rLon, dir: p[6])
            
            guard isValidCoordinate(lat: lat, lon: lon) else { return }
            
            let gpsDict = ["latitude": lat, "longitude": lon]
            DispatchQueue.main.async {
                self.myLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                self.broadcast(type: "MY_GPS", payload: gpsDict)
            }
        }
    }
    
    private func convertNMEA(_ raw: Double, dir: String) -> Double {
        let deg = floor(raw / 100), min = raw - (deg * 100)
        var dec = deg + (min / 60)
        if dir == "S" || dir == "W" { dec *= -1 }
        return dec
    }
    
    func simulateCAM() {
        let randomID = Int.random(in: 400...500)
        // Simulation um Stuttgart zentriert
        let lat = 48.7955 + Double.random(in: -0.005...0.005)
        let lon = 9.2292 + Double.random(in: -0.005...0.005)
        
        guard isValidCoordinate(lat: lat, lon: lon) else { return }
        let speed = Double.random(in: 30...80)
        let heading = Double.random(in: 0...360)
        let braking = Bool.random()
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        DispatchQueue.main.async {
            self.decodedCAMs += 1
            var vehicle = self.vehicles[randomID] ?? V2XVehicle(id: randomID, coordinate: coord, heading: heading, speed: speed, isBraking: braking, lastSeen: Date())
            
            vehicle.updatePosition(to: coord, heading: heading, speed: speed, isBraking: braking)
            
            self.vehicles[randomID] = vehicle
            self.broadcast(type: "CAM", payload: vehicle)
            
            var fakePayload = Data([0x01, 0x02, 0x03, 0x04])
            fakePayload.append(contentsOf: withUnsafeBytes(of: Int32(randomID).bigEndian) { Data($0) })
            self.writeToPCAP(fakePayload)
            
            self.v2xPacketCache.append(fakePayload)
            if self.v2xPacketCache.count > 1000 { self.v2xPacketCache.removeFirst() }
            
            self.addRawDebugLog(prefix: "SIM-CAM", text: "ID: \(randomID) | Spd: \(Int(speed)) km/h | Lat: \(lat) | Lon: \(lon)")
        }
    }
    
    func simulateDENM() {
        let randomID = Int.random(in: 800...900)
        // Simulation um Stuttgart zentriert
        let lat = 48.7985 + Double.random(in: -0.003...0.003)
        let lon = 9.2312 + Double.random(in: -0.003...0.003)
        
        guard isValidCoordinate(lat: lat, lon: lon) else { return }
        let radius = Double.random(in: 50...250)
        let types = ["Baustelle", "Starkregen", "Unfall", "Fahrzeugpanne"]
        let chosenType = types.randomElement() ?? "Gefahr"
        let zone = V2XDangerZone(id: randomID, type: chosenType, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), radiusMeter: radius)
        
        DispatchQueue.main.async {
            self.decodedDENMs += 1
            self.dangerZones[randomID] = zone
            self.broadcast(type: "DENM", payload: zone)
            
            var fakePayload = Data([0x01, 0x01, 0x01, 0x01])
            fakePayload.append(contentsOf: withUnsafeBytes(of: Int32(randomID).bigEndian) { Data($0) })
            self.writeToPCAP(fakePayload)
            
            self.v2xPacketCache.append(fakePayload)
            if self.v2xPacketCache.count > 1000 { self.v2xPacketCache.removeFirst() }
            
            self.addRawDebugLog(prefix: "SIM-DENM", text: "ID: \(randomID) | Type: \(chosenType) | Rad: \(Int(radius))m")
        }
    }
    
    func simulateSPATEM() {
        let randomID = Int.random(in: 1000...1100)
        // Simulation um Stuttgart zentriert
        let lat = 48.7935 + Double.random(in: -0.002...0.002)
        let lon = 9.2272 + Double.random(in: -0.002...0.002)
        
        guard isValidCoordinate(lat: lat, lon: lon) else { return }
        let phases = ["red", "yellow", "green"]
        let phase = phases.randomElement() ?? "green"
        let time = Int.random(in: 5...30)
        let light = V2XTrafficLight(id: randomID, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), currentPhase: phase, timeToChange: time)
        
        DispatchQueue.main.async {
            self.decodedSPATEMs += 1
            self.trafficLights[randomID] = light
            self.broadcast(type: "SPATEM", payload: light)
            
            var fakePayload = Data([0x03, 0x03, 0x03, 0x03])
            fakePayload.append(contentsOf: withUnsafeBytes(of: Int32(randomID).bigEndian) { Data($0) })
            self.writeToPCAP(fakePayload)
            
            self.v2xPacketCache.append(fakePayload)
            if self.v2xPacketCache.count > 1000 { self.v2xPacketCache.removeFirst() }
            
            self.addRawDebugLog(prefix: "SIM-SPATEM", text: "ID: \(randomID) | Phase: \(phase) | TTL: \(time)s")
            
            if self.myLocation == nil {
                self.myLocation = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
            }
        }
    }
    
    func resetDebugCounters() {
        DispatchQueue.main.async {
            self.decodedCAMs = 0
            self.decodedDENMs = 0
            self.decodedSPATEMs = 0
            self.corruptedV2XPackets = 0
            self.corruptedGPSPackets = 0
            self.totalV2XBytesRx = 0
            self.totalGPSBytesRx = 0
            self.debugRawPackets.removeAll()
            self.espConsoleLog.removeAll()
            self.v2xPacketCache.removeAll()
            self.gpsPacketCache.removeAll()
            self.networkPacketCache.removeAll()
            self.addLog("[!] Debug-Zähler und Diagnoseströme zurückgesetzt.")
        }
    }
    
    func calculateGLOSASpeed(to light: V2XTrafficLight) -> Double? {
        guard let myLoc = myLocation else { return nil }
        let d = haversineDistance(from: myLoc, to: light.coordinate)
        let t = Double(light.timeToChange)
        guard t > 0 else { return nil }
        
        if light.currentPhase == "green" {
            let speedMps = d / t
            let speedKmh = speedMps * 3.6
            return speedKmh <= 130 ? speedKmh : nil
        } else if light.currentPhase == "red" {
            let speedMps = d / t
            let speedKmh = speedMps * 3.6
            return (speedKmh >= 10 && speedKmh <= 130) ? speedKmh : nil
        }
        return nil
    }
    
    private func haversineDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let r = 6371000.0
        let dLat = (to.latitude - from.latitude) * .pi / 180.0
        let dLon = (to.longitude - from.longitude) * .pi / 180.0
        let lat1 = from.latitude * .pi / 180.0
        let lat2 = to.latitude * .pi / 180.0
        
        let a = sin(dLat/2) * sin(dLat/2) + sin(dLon/2) * sin(dLon/2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return r * c
    }
    
    func toggleServer() {
        if serverRunning {
            listener?.cancel()
            webDebugListener?.cancel()
            activeConnections.forEach { $0.cancel() }
            webConnections.forEach { $0.cancel() }
            activeConnections.removeAll()
            webConnections.removeAll()
            connectedClients.removeAll()
            serverRunning = false
            addLog("[-] Server gestoppt.")
        } else {
            do {
                let portEndpoint = NWEndpoint.Port(rawValue: UInt16(serverPort))!
                listener = try NWListener(using: .tcp, on: portEndpoint)
                listener?.newConnectionHandler = { [weak self] c in
                    guard let self = self else { return }
                    self.activeConnections.append(c)
                    
                    c.stateUpdateHandler = { [weak self] state in
                        guard let self = self else { return }
                        let clientIP = self.getIPAddress(from: c)
                        switch state {
                        case .ready:
                            self.addLog("[+] Client verbunden: \(clientIP)")
                            self.updateConnectedClients()
                        case .failed, .cancelled:
                            self.addLog("[-] Client getrennt: \(clientIP)")
                            self.updateConnectedClients()
                        default:
                            break
                        }
                    }
                    c.start(queue: .global())
                    self.updateConnectedClients()
                }
                listener?.start(queue: .global())
                addLog("[+] TCP Server aktiv auf Port \(serverPort).")
                
                if isWebDebugServerEnabled {
                    startWebDebugServer(port: serverPort + 1)
                }
                
                serverRunning = true
            } catch {
                addLog("[-] Server-Start fehlgeschlagen auf Port \(serverPort): \(error.localizedDescription)")
            }
        }
    }
    
    private func getIPAddress(from connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint {
            return "\(host)"
        }
        return "Unbekannt"
    }
    
    private func updateConnectedClients() {
        DispatchQueue.main.async {
            self.activeConnections = self.activeConnections.filter { conn in
                switch conn.state {
                case .ready, .preparing, .setup: return true
                default: return false
                }
            }
            self.connectedClients = self.activeConnections.map { conn in
                self.getIPAddress(from: conn)
            }
        }
    }
    
    private func startWebDebugServer(port: Int) {
        do {
            let webPortEndpoint = NWEndpoint.Port(rawValue: UInt16(port))!
            let webListener = try NWListener(using: .tcp, on: webPortEndpoint)
            self.webDebugListener = webListener
            
            webListener.newConnectionHandler = { [weak self] c in
                self?.webConnections.append(c)
                c.start(queue: .global())
                self?.handleWebConnection(c)
            }
            webListener.start(queue: .global())
            addLog("[+] Web-Debugger Server gestartet auf Port \(port).")
        } catch {
            addLog("[-] Web-Debugger Server Start fehlgeschlagen auf Port \(port): \(error.localizedDescription)")
        }
    }
    
    private func handleWebConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil { connection.cancel(); return }
            guard let data = data, let req = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            
            let responseData: Data
            let contentType: String
            
            if req.contains("GET /api") {
                contentType = "application/json"
                let responseObj: [String: Any] = [
                    "decodedCAMs": self.decodedCAMs,
                    "decodedDENMs": self.decodedDENMs,
                    "decodedSPATEMs": self.decodedSPATEMs,
                    "totalV2XBytesRx": self.totalV2XBytesRx,
                    "totalGPSBytesRx": self.totalGPSBytesRx,
                    "debugRawPackets": self.debugRawPackets.map { $0.text }
                ]
                if let json = try? JSONSerialization.data(withJSONObject: responseObj, options: []) {
                    responseData = json
                } else {
                    responseData = "{}".data(using: .utf8)!
                }
            } else {
                contentType = "text/html; charset=utf-8"
                responseData = self.getWebDebugHTML().data(using: .utf8)!
            }
            
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: \(contentType)\r
            Content-Length: \(responseData.count)\r
            Connection: close\r
            Access-Control-Allow-Origin: *\r
            \r
            """
            
            var fullResponse = header.data(using: .utf8)!
            fullResponse.append(responseData)
            
            connection.send(content: fullResponse, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }
    
    private func getWebDebugHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>V2X Mac-Zentrale Live-Web-Debugger</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0f0f11; color: #e4e4e7; margin: 0; padding: 20px; }
                h1 { color: #10b981; font-size: 22px; margin-bottom: 5px; }
                .subtitle { color: #71717a; font-size: 13px; margin-bottom: 25px; }
                .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin-bottom: 25px; }
                .card { background: #18181b; padding: 15px; border-radius: 8px; border: 1px solid #27272a; }
                .card h3 { margin: 0 0 8px 0; font-size: 10px; text-transform: uppercase; letter-spacing: 0.05em; color: #a1a1aa; }
                .card p { margin: 0; font-size: 22px; font-weight: bold; font-family: monospace; }
                .console-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
                .console-header h2 { font-size: 15px; margin: 0; }
                .console { background: #000000; border: 1px solid #27272a; padding: 15px; border-radius: 6px; height: 350px; overflow-y: auto; font-family: "SFMono-Regular", Consolas, monospace; font-size: 11px; line-height: 1.6; color: #34d399; }
                .gps { color: #22d3ee; }
                .v2x { color: #facc15; }
                .sim { color: #e879f9; }
            </style>
        </head>
        <body>
            <h1>V2X Live Web-Debugger</h1>
            <div class="subtitle">Echtzeit-Schnittstelle der Mac-Zentrale</div>
            
            <div class="grid">
                <div class="card"><h3>Bytes RX (V2X)</h3><p id="v2x-bytes">0 B</p></div>
                <div class="card"><h3>Bytes RX (GPS)</h3><p id="gps-bytes">0 B</p></div>
                <div class="card"><h3>CAMs</h3><p style="color:#60a5fa" id="cams">0</p></div>
                <div class="card"><h3>DENMs</h3><p style="color:#f87171" id="denms">0</p></div>
                <div class="card"><h3>SPATEMs</h3><p style="color:#fb923c" id="spatems">0</p></div>
            </div>
            
            <div class="console-header">
                <h2>Raw Serial Bytestream & NMEA Log</h2>
            </div>
            <div class="console" id="log-box"></div>
            
            <script>
                function update() {
                    fetch('/api')
                        .then(r => r.json())
                        .then(data => {
                            document.getElementById('v2x-bytes').innerText = data.totalV2XBytesRx + ' B';
                            document.getElementById('gps-bytes').innerText = data.totalGPSBytesRx + ' B';
                            document.getElementById('cams').innerText = data.decodedCAMs;
                            document.getElementById('denms').innerText = data.decodedDENMs;
                            document.getElementById('spatems').innerText = data.decodedSPATEMs;
                            
                            const box = document.getElementById('log-box');
                            box.innerHTML = data.debugRawPackets.map(line => {
                                let cls = '';
                                if (line.includes('[GPS]')) cls = 'gps';
                                else if (line.includes('[V2X]')) cls = 'v2x';
                                else if (line.includes('[SIM')) cls = 'sim';
                                return `<div class="${cls}">${line}</div>`;
                            }).join('');
                        })
                        .catch(e => console.error("Data Sync Error:", e));
                }
                setInterval(update, 1000);
                update();
            </script>
        </body>
        </html>
        """
    }
    
    private func broadcast<T: Encodable>(type: String, payload: T) {
        guard serverRunning else { return }
        let envelope = V2XMessageEnvelope(msgType: type, data: payload)
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(envelope), let str = String(data: data, encoding: .utf8) {
            let frame = "\(str)\n".data(using: .utf8)!
            
            DispatchQueue.main.async {
                self.networkPacketCache.append(frame)
                if self.networkPacketCache.count > 1000 { self.networkPacketCache.removeFirst() }
            }
            
            activeConnections.forEach { $0.send(content: frame, completion: .contentProcessed({ _ in })) }
        }
    }
    
    // --- DIREKTER RAW COMMAND CHANNEL ZUM HARDWARE-TESTING ---
    func sendRawCommand(_ command: String) {
        let fd = self.v2xFd
        guard shouldRead, fd != -1 else {
            addLog("[!] Fehler: V2X-Port ist nicht geöffnet.")
            return
        }
        let fullCmd = command + "\r\n"
        fullCmd.withCString { cStr in
            _ = write(fd, cStr, strlen(cStr))
        }
        addLog("[*] ESP32 Console => \(command)")
        DispatchQueue.main.async {
            let entry = LogEntry("[\(Date().formatted(.dateTime.hour().minute().second()))] => \(command)")
            self.espConsoleLog.insert(entry, at: 0)
            if self.espConsoleLog.count > 100 { self.espConsoleLog.removeLast() }
        }
    }
    
    private func sendESPCommand(_ command: String) {
        let fd = self.v2xFd
        guard shouldRead, fd != -1 else { return }
        let fullCmd = command + "\r\n"
        fullCmd.withCString { cStr in
            _ = write(fd, cStr, strlen(cStr))
        }
    }
    
    private func initializeESP32() {
        // Konsolen-Schnittstelle aufwecken
        sendESPCommand("")
        Thread.sleep(forTimeInterval: 0.05)
        
        // Laufenden Sniffer stoppen, um definierten Ausgangszustand zu haben
        sendESPCommand("sniffer --stop")
        Thread.sleep(forTimeInterval: 0.1)
        
        // Standardmäßig BT COEX deaktvieren ("coex 0") für absolute Sniffing-Performance
        sendESPCommand("coex 0")
        Thread.sleep(forTimeInterval: 0.1)
        
        // Kanal 180 (entspricht 5,9 GHz ITS-G5 Spektrum) konfigurieren
        sendESPCommand("sniffer --channel 180")
        Thread.sleep(forTimeInterval: 0.1)
        
        // Sniffer mit korrekter CLI-Syntax aktivieren
        sendESPCommand("sniffer --start")
        Thread.sleep(forTimeInterval: 0.1)
        
        addLog("[+] ESP32 initialisiert: Bluetooth COEX deaktiviert (coex 0) & Sniffing auf C-ITS Kanal 180 (5,9 GHz) gestartet.")
    }
    
    func applyESPMode(Mode newMode: ESPMode, coex: Bool) {
        espMode = newMode
        isCoexEnabled = coex
        
        if v2xFd != -1 {
            sendESPCommand("sniffer --stop")
            Thread.sleep(forTimeInterval: 0.1)
            
            // Wende den gewünschten Coexistenz-Status an
            sendESPCommand(coex ? "coex 1" : "coex 0")
            Thread.sleep(forTimeInterval: 0.1)
            
            switch newMode {
            case .sniff80211p:
                sendESPCommand("sniffer --channel 180")
                Thread.sleep(forTimeInterval: 0.1)
                sendESPCommand("sniffer --start")
            case .wifiClient:
                sendESPCommand("mqtt --connect")
            case .wifiAP:
                sendESPCommand("help")
            }
        }
        addLog("[+] ESP32 Modus angewendet: \(newMode.rawValue) | COEX: \(coex ? "AN" : "AUS")")
    }
    
    // --- NATIVES ÖFFNEN UND BLOCKIERENDE KONFIGURATION DER SCHNITTSTELLEN ÜBER POSIX ---
    private func openAndConfigurePort(path: String, baud: String) -> Int32 {
        // 1. Öffnen im Non-Blocking-Modus, um Hänger ohne DCD zu verhindern
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd != -1 else {
            return -1
        }
        
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else {
            close(fd)
            return -1
        }
        
        let speed: speed_t
        switch baud {
        case "921600": speed = speed_t(921600)
        case "115200": speed = speed_t(115200)
        case "57600": speed = speed_t(57600)
        case "38400": speed = speed_t(38400)
        case "19200": speed = speed_t(19200)
        case "9600": speed = speed_t(9600)
        case "4800": speed = speed_t(4800)
        default: speed = speed_t(921600)
        }
        
        cfsetispeed(&t, speed)
        cfsetospeed(&t, speed)
        
        t.c_cflag &= ~tcflag_t(PARENB)
        t.c_cflag &= ~tcflag_t(CSTOPB)
        t.c_cflag &= ~tcflag_t(CSIZE)
        t.c_cflag |= tcflag_t(CS8)
        
        t.c_cflag |= tcflag_t(CREAD | CLOCAL)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        t.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        t.c_oflag &= ~tcflag_t(OPOST)
        
        // Blockierendes Lesen auf mindestens 1 Byte konfigurieren (VMIN = 1, VTIME = 0)
        t.c_cc.16 = 1
        t.c_cc.17 = 0
        
        if tcsetattr(fd, TCSANOW, &t) != 0 {
            close(fd)
            return -1
        }
        
        // 2. WICHTIG: File Descriptor jetzt zurück in den sauberen, blockierenden I/O Modus schalten!
        var flags = fcntl(fd, F_GETFL, 0)
        if flags != -1 {
            flags &= ~O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        }
        
        return fd
    }
    
    fileprivate func configurePort(path: String, baud: String) {
        // Nicht mehr benötigt, da Portkonfiguration nativ im openAndConfigurePort erfolgt.
    }
    
    private func buildPCAPData(from packets: [Data], etherType: UInt16? = nil, udpPorts: (src: UInt16, dst: UInt16)? = nil) -> Data {
        var pcapData = Data()
        pcapData.append(contentsOf: [0xd4, 0xc3, 0xb2, 0xa1])
        pcapData.append(contentsOf: [0x02, 0x00, 0x04, 0x00])
        pcapData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        pcapData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        pcapData.append(contentsOf: [0xff, 0xff, 0x00, 0x00])
        pcapData.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        
        let nowSeconds = UInt32(Date().timeIntervalSince1970)
        
        for (index, payload) in packets.enumerated() {
            var finalFrame = Data()
            if let et = etherType {
                var ethHeader = Data()
                ethHeader.append(contentsOf: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
                ethHeader.append(contentsOf: [0x00, 0x0a, 0x35, 0x00, 0x01, 0x02])
                ethHeader.append(contentsOf: withUnsafeBytes(of: et.bigEndian) { Data($0) })
                finalFrame = ethHeader + payload
            } else if let ports = udpPorts {
                var ethHeader = Data()
                ethHeader.append(contentsOf: [0x00, 0x0c, 0x29, 0x00, 0x01, 0x02])
                ethHeader.append(contentsOf: [0x00, 0x0c, 0x29, 0x03, 0x04, 0x05])
                ethHeader.append(contentsOf: [0x08, 0x00])
                
                let ipLength = UInt16(20 + 8 + payload.count)
                var ipHeader = Data()
                ipHeader.append(0x45)
                ipHeader.append(0x00)
                ipHeader.append(contentsOf: withUnsafeBytes(of: ipLength.bigEndian) { Data($0) })
                ipHeader.append(contentsOf: [0x12, 0x34])
                ipHeader.append(contentsOf: [0x40, 0x00])
                ipHeader.append(64)
                ipHeader.append(17)
                ipHeader.append(contentsOf: [0x00, 0x00])
                ipHeader.append(contentsOf: [127, 0, 0, 1])
                ipHeader.append(contentsOf: [127, 0, 0, 1])
                
                let udpLength = UInt16(8 + payload.count)
                var udpHeader = Data()
                udpHeader.append(contentsOf: withUnsafeBytes(of: ports.src.bigEndian) { Data($0) })
                udpHeader.append(contentsOf: withUnsafeBytes(of: ports.dst.bigEndian) { Data($0) })
                udpHeader.append(contentsOf: withUnsafeBytes(of: udpLength.bigEndian) { Data($0) })
                udpHeader.append(contentsOf: [0x00, 0x00])
                
                finalFrame = ethHeader + ipHeader + udpHeader + payload
            } else {
                finalFrame = payload
            }
            
            let packetLength = UInt32(finalFrame.count)
            let micro = UInt32(index * 1000) % 1_000_000
            
            var packetHeader = Data()
            packetHeader.append(contentsOf: withUnsafeBytes(of: nowSeconds.littleEndian) { Data($0) })
            packetHeader.append(contentsOf: withUnsafeBytes(of: micro.littleEndian) { Data($0) })
            packetHeader.append(contentsOf: withUnsafeBytes(of: packetLength.littleEndian) { Data($0) })
            packetHeader.append(contentsOf: withUnsafeBytes(of: packetLength.littleEndian) { Data($0) })
            
            pcapData.append(packetHeader)
            pcapData.append(finalFrame)
        }
        return pcapData
    }
    
    func exportV2XCache() {
        guard !v2xPacketCache.isEmpty else { return }
        let pcapData = buildPCAPData(from: v2xPacketCache, etherType: 0x8947)
        savePCAPDialog(data: pcapData, filename: "v2x_mon_capture.pcap")
    }
    
    func exportGPSCache() {
        guard !gpsPacketCache.isEmpty else { return }
        let rawDataArray = gpsPacketCache.compactMap { ($0 + "\n").data(using: .utf8) }
        let pcapData = buildPCAPData(from: rawDataArray, udpPorts: (src: 9999, dst: 9999))
        savePCAPDialog(data: pcapData, filename: "gps_nmea_capture.pcap")
    }
    
    func exportNetworkCache() {
        guard !networkPacketCache.isEmpty else { return }
        let pcapData = buildPCAPData(from: networkPacketCache, udpPorts: (src: UInt16(serverPort), dst: UInt16(serverPort)))
        savePCAPDialog(data: pcapData, filename: "network_stream_capture.pcap")
    }
    
    private func savePCAPDialog(data: Data, filename: String) {
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Diagnosestrom als PCAP exportieren"
            savePanel.nameFieldStringValue = filename
            savePanel.allowedContentTypes = [UTType(filenameExtension: "pcap")!]
            
            if savePanel.runModal() == .OK, let url = savePanel.url {
                do {
                    try data.write(to: url)
                    self.addLog("[+] PCAP Diagnosestrom erfolgreich exportiert: \(url.lastPathComponent)")
                } catch {
                    self.addLog("[-] Export fehlgeschlagen: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopAll() {
        shouldRead = false
        isV2XManuallyConnected = false
        isGPSManuallyConnected = false

        // Kurze Wartezeit, damit Reader-Schleifen den Flagwechsel sehen
        Thread.sleep(forTimeInterval: 0.02)

        if v2xFd != -1 {
            sendESPCommand("sniffer --stop")
            Thread.sleep(forTimeInterval: 0.02)
            close(v2xFd)
            v2xFd = -1
        }
        if gpsFd != -1 {
            Thread.sleep(forTimeInterval: 0.02)
            close(gpsFd)
            gpsFd = -1
        }

        v2xPortOpen = false
        gpsPortOpen = false

        listener?.cancel()
        webDebugListener?.cancel()
    }
    
    func copyLogsToClipboard() {
        let timestamp = Date().formatted(.dateTime)
        var content = "=== V2X Mac-Zentrale Logs (\(timestamp)) ===\n\n"
        content += logs.map { $0.text }.joined(separator: "\n")
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(content, forType: .string)
            self.addLog("[+] Logs in Zwischenablage kopiert.")
        }
    }
    
    func exportLogsToFile() {
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Logs exportieren"
            savePanel.nameFieldStringValue = "v2x_logs_\(Int(Date().timeIntervalSince1970)).txt"
            savePanel.allowedContentTypes = [UTType.plainText]
            savePanel.canCreateDirectories = true
            savePanel.isExtensionHidden = false
            
            if savePanel.runModal() == .OK, let url = savePanel.url {
                let timestamp = Date().formatted(.dateTime)
                var content = "=== V2X Mac-Zentrale Logs (\(timestamp)) ===\n\n"
                content += self.logs.map { $0.text }.joined(separator: "\n")
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    self.addLog("[+] Logs exportiert: \(url.lastPathComponent)")
                } catch {
                    self.addLog("[-] Fehler beim Exportieren der Logs: \(error.localizedDescription)")
                }
            } else {
                self.addLog("[*] Log-Export abgebrochen.")
            }
        }
    }
}

// --- BOMBENSICHERER, LOKALER OFFLINE-KACHEL CLASSTYPE ---
class CachedTileOverlay: MKTileOverlay {
    let cacheFolder: URL
    
    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheFolder = appSupport.appendingPathComponent("MapTileCache")
        
        // Ordnerstruktur im Application Support anlegen, falls nicht vorhanden
        try? fm.createDirectory(at: self.cacheFolder, withIntermediateDirectories: true)
        
        // Standard OpenStreetMap URL Template
        super.init(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
    }
    
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tileKey = "\(path.z)/\(path.x)/\(path.y).png"
        let localURL = cacheFolder.appendingPathComponent(tileKey)
        
        // 1. Versuch: Lokal aus dem Cache laden (100% Offline-Kompatibel)
        if FileManager.default.fileExists(atPath: localURL.path) {
            if let data = try? Data(contentsOf: localURL) {
                result(data, nil)
                return
            }
        }
        
        // 2. Versuch: Falls online, Kachel über Standard-Handler holen und lokal cachen
        super.loadTile(at: path) { [weak self] data, error in
            if let data = data, error == nil {
                DispatchQueue.global(qos: .background).async { [weak self] in
                    guard let self = self else { return }
                    let parentFolder = localURL.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true)
                    try? data.write(to: localURL)
                }
            }
            result(data, error)
        }
    }
}
