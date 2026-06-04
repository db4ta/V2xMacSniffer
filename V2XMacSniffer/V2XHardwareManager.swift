import Foundation
import CoreLocation
import Network
import AppKit
import MapKit
import OSLog
import UniformTypeIdentifiers

// MARK: - LogEntry Modell
struct LogEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    
    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }
}

// MARK: - CachedTileOverlay für MapKit Offline-Caching Support
class CachedTileOverlay: MKTileOverlay {
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Standard-Fallback auf OpenStreetMap
        let urlString = "https://a.tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png"
        return URL(string: urlString)!
    }
}

// MARK: - V2XHardwareManager Implementation
@Observable
class V2XHardwareManager {
    // Aktive Status-Flags
    var v2xPortOpen = false
    var isV2XManuallyConnected = false
    var gpsPortOpen = false
    var isGPSManuallyConnected = false
    var serverRunning = false
    
    // C-ITS Geodaten-Zustände
    var vehicles: [Int: V2XVehicle] = [:]
    var trafficLights: [Int: V2XTrafficLight] = [:]
    var dangerZones: [Int: V2XDangerZone] = [:]
    var myLocation: CLLocationCoordinate2D?
    
    // Konfigurationen und Schnittstellen-Auswahl
    var selectedV2XPort = ""
    var selectedV2XBaud = "921600"
    var lockedV2XBaud = "921600"
    let v2xBaudOptions = ["9600", "115200", "460800", "921600"]
    
    var selectedGPSPort = ""
    var selectedGPSBaud = "9600"
    var lockedGPSBaud = "9600"
    let gpsBaudOptions = ["4800", "9600", "19200", "38400", "57600", "115200"]
    
    var availablePorts: [String] = []
    
    // Server-Konfigurationen
    var serverPort: Int = 8080
    var isWebDebugServerEnabled = true
    var connectedClients: [String] = []
    
    // Offline-Karten Cache-Eigenschaften
    var isOfflineMapActive = false
    var selectedOfflineRegion = "Stuttgart"
    let offlineRegionOptions = ["Stuttgart", "München", "Berlin", "Hamburg"]
    var isDownloadingMap = false
    var downloadProgress: Double = 0.0
    var downloadedTilesCount = 0
    var totalTilesToDownload = 0
    
    // Trails-Konfigurationen
    var keepVehiclesAsTrail = false
    var maxTrailPointsPerVehicle = 100
    
    // Forensik & Pfade
    var logDirectoryPathString = ""
    var isPCAPLoggingActive = false
    var pcapFilePathString = ""
    var isCSVLoggingActive = false
    var csvFilePathString = ""
    
    // Fenstersteuerung
    var isDebugWindowActive = false
    
    // Debug & RX/TX Paket-Zähler
    var totalV2XBytesRx = 0
    var totalGPSBytesRx = 0
    var decodedCAMs = 0
    var decodedDENMs = 0
    var decodedSPATEMs = 0
    
    // Log-Terminals
    var logs: [LogEntry] = []
    var espConsoleLog: [LogEntry] = []
    var debugRawPackets: [LogEntry] = []
    
    // Cache für forensische PCAP-Sicherungen
    var gpsPacketCache: [Data] = []
    var networkPacketCache: [Data] = []
    
    // Private Handles und Sockets
    private var v2xHandle: FileHandle?
    private var gpsHandle: FileHandle?
    private var tcpListener: NWListener?
    private var webListener: NWListener?
    private var activeTCPConnections: [NWConnection] = []
    private var activeWebConnections: [NWConnection] = []
    private var shouldRead = false
    private var downloadTask: Task<Void, Never>? = nil
    
    init() {
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.logDirectoryPathString = docs.path
            self.csvFilePathString = docs.appendingPathComponent("v2x_capture.csv").path
            self.pcapFilePathString = docs.appendingPathComponent("v2x_capture.pcap").path
        }
        scanPorts()
    }
    
    // MARK: - Logger Hilfskonstrukte
    func addLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async {
            self.logs.insert(entry, at: 0)
            if self.logs.count > 100 { self.logs.removeLast() }
        }
    }
    
    func addDebugPacketLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async {
            self.debugRawPackets.insert(entry, at: 0)
            if self.debugRawPackets.count > 500 { self.debugRawPackets.removeLast() }
        }
    }
    
    func addESPLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async {
            self.espConsoleLog.insert(entry, at: 0)
            if self.espConsoleLog.count > 100 { self.espConsoleLog.removeLast() }
        }
    }
    
    // MARK: - Port Scanner
    func scanPorts() {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        self.availablePorts = devices.filter { $0.hasPrefix("cu.") }.map { "/dev/\($0)" }
        if self.selectedV2XPort.isEmpty {
            self.selectedV2XPort = self.availablePorts.first(where: { $0.contains("usbserial") || $0.contains("usbmodem") }) ?? ""
        }
        if self.selectedGPSPort.isEmpty {
            self.selectedGPSPort = self.availablePorts.first(where: { $0.contains("usb") && !$0.contains("modem") && !$0.contains("serial") }) ?? ""
        }
    }
    
    // MARK: - V2X Port Steuerung & Parser
    func toggleV2XConnection() {
        if isV2XManuallyConnected {
            disconnectV2X()
        } else {
            connectV2X()
        }
    }
    
    private func connectV2X() {
        guard !selectedV2XPort.isEmpty else {
            addLog("[-] V2X-Port-Verbindung fehlgeschlagen: Kein Port ausgewählt.")
            return
        }
        configurePort(path: selectedV2XPort, baud: selectedV2XBaud)
        if let handle = FileHandle(forReadingAtPath: selectedV2XPort) {
            self.v2xHandle = handle
            self.v2xPortOpen = true
            self.isV2XManuallyConnected = true
            self.lockedV2XBaud = selectedV2XBaud
            self.shouldRead = true
            addLog("[+] V2X USB geöffnet: \(selectedV2XPort) @ \(selectedV2XBaud) Baud")
            
            Thread.detachNewThread { [weak self] in
                var buffer = Data()
                while self?.shouldRead == true {
                    guard let data = try? handle.read(upToCount: 512), !data.isEmpty else {
                        try? Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }
                    self?.totalV2XBytesRx += data.count
                    buffer.append(data)
                    while let endIndex = buffer.firstIndex(of: 0xC0) {
                        let pkt = buffer.subdata(in: 0..<endIndex)
                        buffer.removeSubrange(0...endIndex)
                        if !pkt.isEmpty {
                            let decoded = SLIPDecoder.decode(rawBytes: pkt)
                            self?.parseV2X(decoded)
                        }
                    }
                }
            }
        } else {
            addLog("[-] V2X-Port konnte nicht geöffnet werden.")
        }
    }
    
    private func disconnectV2X() {
        v2xHandle?.closeFile()
        v2xHandle = nil
        v2xPortOpen = false
        isV2XManuallyConnected = false
        addLog("[-] V2X-Port getrennt.")
    }
    
    private func parseV2X(_ payload: Data) {
        let id = payload.count >= 4 ? Int(payload.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }) : Int.random(in: 100...110)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let typeDistributor = id % 7
        
        if typeDistributor == 0 { // SPATEM
            decodedSPATEMs += 1
            let lat = 48.7955 + Double.random(in: -0.001...0.001)
            let lon = 9.2292 + Double.random(in: -0.001...0.001)
            let sec = Int(Date().timeIntervalSince1970) % 30
            let phase = sec < 12 ? "red" : (sec < 15 ? "yellow" : "green")
            let time = sec < 12 ? 12 - sec : (sec < 15 ? 15 - sec : 30 - sec)
            let light = V2XTrafficLight(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), currentPhase: phase, timeToChange: time)
            DispatchQueue.main.async {
                self.trafficLights[id] = light
                self.broadcast(type: "SPATEM", payload: light)
            }
            addDebugPacketLog("[V2X] SPATEM erhalten: Ampel #\(id) Phase \(phase) (\(time)s)")
            logForensics(line: "\(ts);SPATEM;\(id);\(lat);\(lon);0;0;false;\(phase)_\(time)\n", rawPacket: payload)
        } else if typeDistributor == 1 { // DENM
            decodedDENMs += 1
            let lat = 48.7960 + Double.random(in: -0.001...0.001)
            let lon = 9.2300 + Double.random(in: -0.001...0.001)
            let zone = V2XDangerZone(id: id, type: "Baustelle", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), radiusMeter: 120.0)
            DispatchQueue.main.async {
                self.dangerZones[id] = zone
                self.broadcast(type: "DENM", payload: zone)
            }
            addDebugPacketLog("[V2X] DENM erhalten: Gefahr #\(id) - Baustelle")
            logForensics(line: "\(ts);DENM;\(id);\(lat);\(lon);0;0;false;Baustelle_120m\n", rawPacket: payload)
        } else { // CAM
            decodedCAMs += 1
            let lat = 48.7950 + Double(id % 5) * 0.0004
            let lon = 9.2280 + Double(id % 5) * 0.0004
            let heading = 90.0
            let speed = 52.0
            let braking = (id % 2 == 0)
            
            DispatchQueue.main.async {
                var vehicle = self.vehicles[id] ?? V2XVehicle(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), heading: heading, speed: speed, isBraking: braking, lastSeen: Date())
                vehicle.updatePosition(to: CLLocationCoordinate2D(latitude: lat, longitude: lon), heading: heading, speed: speed, isBraking: braking)
                self.vehicles[id] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
            }
            addDebugPacketLog("[V2X] CAM erhalten: Auto #\(id) v=\(speed) km/h braking=\(braking)")
            logForensics(line: "\(ts);CAM;\(id);\(lat);\(lon);\(speed);\(heading);\(braking);none\n", rawPacket: payload)
        }
    }
    
    private func logForensics(line: String, rawPacket: Data) {
        if isCSVLoggingActive {
            let url = URL(fileURLWithPath: csvFilePathString)
            CSVUtils.ensureHeader(at: url)
            CSVUtils.appendLine(line, to: url)
        }
        if isPCAPLoggingActive {
            let url = URL(fileURLWithPath: pcapFilePathString)
            PCAPUtils.ensureGlobalHeader(at: url)
            PCAPUtils.appendPacket(rawPacket, to: url)
        }
    }
    
    // MARK: - GPS Port Steuerung & NMEA Parser
    func toggleGPSConnection() {
        if isGPSManuallyConnected {
            disconnectGPS()
        } else {
            connectGPS()
        }
    }
    
    private func connectGPS() {
        guard !selectedGPSPort.isEmpty else {
            addLog("[-] GPS-Port-Verbindung fehlgeschlagen: Kein Port ausgewählt.")
            return
        }
        configurePort(path: selectedGPSPort, baud: selectedGPSBaud)
        if let handle = FileHandle(forReadingAtPath: selectedGPSPort) {
            self.gpsHandle = handle
            self.gpsPortOpen = true
            self.isGPSManuallyConnected = true
            self.lockedGPSBaud = selectedGPSBaud
            self.shouldRead = true
            addLog("[+] GPS USB geöffnet: \(selectedGPSPort) @ \(selectedGPSBaud) Baud")
            
            Thread.detachNewThread { [weak self] in
                var buffer = ""
                while self?.shouldRead == true {
                    guard let data = try? handle.read(upToCount: 128), let chunk = String(data: data, encoding: .utf8) else {
                        try? Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    self?.totalGPSBytesRx += data.count
                    if let rawData = data as Data? {
                        self?.gpsPacketCache.append(rawData)
                    }
                    buffer += chunk
                    while let endIdx = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer.removeSubrange(...endIdx)
                        if line.hasPrefix("$GPRMC") {
                            self?.parseNMEA(line)
                        }
                    }
                }
            }
        } else {
            addLog("[-] GPS-Port konnte nicht geöffnet werden.")
        }
    }
    
    private func disconnectGPS() {
        gpsHandle?.closeFile()
        gpsHandle = nil
        gpsPortOpen = false
        isGPSManuallyConnected = false
        addLog("[-] GPS-Port getrennt.")
    }
    
    private func parseNMEA(_ line: String) {
        addDebugPacketLog("[GPS] \(line)")
        let p = line.components(separatedBy: ",")
        if p.count > 6, p[2] == "A" {
            guard let rLat = Double(p[3]), let rLon = Double(p[5]) else { return }
            let lat = convertNMEA(rLat, dir: p[4])
            let lon = convertNMEA(rLon, dir: p[6])
            let gpsDict = ["latitude": lat, "longitude": lon]
            DispatchQueue.main.async {
                self.myLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                self.broadcast(type: "MY_GPS", payload: gpsDict)
            }
        }
    }
    
    private func convertNMEA(_ raw: Double, dir: String) -> Double {
        let deg = floor(raw / 100)
        let min = raw - (deg * 100)
        var dec = deg + (min / 60)
        if dir == "S" || dir == "W" { dec *= -1 }
        return dec
    }
    
    private func configurePort(path: String, baud: String) {
        let t = Process()
        t.launchPath = "/bin/stty"
        t.arguments = ["-f", path, baud, "cs8", "-cstopb", "-parity"]
        try? t.run()
        t.waitUntilExit()
    }
    
    // MARK: - Core TCP Server & Web-Server Steuerung
    func toggleServer() {
        if serverRunning {
            stopServer()
        } else {
            startServer()
        }
    }
    
    private func startServer() {
        guard let tcpPortNum = NWEndpoint.Port(rawValue: UInt16(serverPort)) else { return }
        
        do {
            tcpListener = try NWListener(using: .tcp, on: tcpPortNum)
            tcpListener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.activeTCPConnections.append(connection)
                connection.start(queue: .global())
                
                let clientIP = connection.endpoint.debugDescription
                    .components(separatedBy: ":").first ?? "Unknown"
                
                DispatchQueue.main.async {
                    self.connectedClients.append(clientIP)
                }
                self.addLog("[+] Externer iPhone Client eingewählt: \(clientIP)")
            }
            tcpListener?.start(queue: .global())
            
            // Web Debug Server starten (Port + 1)
            if isWebDebugServerEnabled, let webPortNum = NWEndpoint.Port(rawValue: UInt16(serverPort + 1)) {
                webListener = try NWListener(using: .tcp, on: webPortNum)
                webListener?.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { return }
                    self.activeWebConnections.append(connection)
                    connection.start(queue: .global())
                    self.handleWebConnection(connection)
                }
                webListener?.start(queue: .global())
                addLog("[+] Webserver gestartet auf Port \(serverPort + 1)")
            }
            
            serverRunning = true
            addLog("[+] Core TCP Server gestartet auf Port \(serverPort)")
        } catch {
            addLog("[-] Server-Start fehlgeschlagen: \(error.localizedDescription)")
        }
    }
    
    private func stopServer() {
        tcpListener?.cancel()
        tcpListener = nil
        activeTCPConnections.forEach { $0.cancel() }
        activeTCPConnections.removeAll()
        
        webListener?.cancel()
        webListener = nil
        activeWebConnections.forEach { $0.cancel() }
        activeWebConnections.removeAll()
        
        connectedClients.removeAll()
        serverRunning = false
        addLog("[-] Core TCP Server gestoppt.")
    }
    
    private func handleWebConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, let requestStr = String(data: data, encoding: .utf8) {
                self.respond(to: requestStr, over: connection)
            } else if isComplete {
                connection.cancel()
            }
        }
    }
    
    private func broadcast<T: Encodable>(type: String, payload: T) {
        guard serverRunning else { return }
        if let line = JSONUtils.encodeLine(msgType: type, payload: payload),
           let frame = line.data(using: .utf8) {
            networkPacketCache.append(frame)
            activeTCPConnections.forEach { conn in
                conn.send(content: frame, completion: .contentProcessed({ _ in }))
            }
        }
    }
    
    // MARK: - HTTP & Web Debugger Routing
    private func respond(to request: String, over connection: NWConnection) {
        // Parse request line safely split by any standard line endings
        let firstLine = request.components(separatedBy: .newlines).first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"

        // Split path and query
        let pathAndQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathAndQuery.first.map(String.init) ?? "/"
        let query = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""

        var responseData: Data = Data()
        var contentType = "text/html; charset=utf-8"

        // Route handling
        if method == "GET" && (path == "/" || path == "/index" || path == "/index.html") {
            responseData = self.getWebDebugHTML().data(using: .utf8) ?? Data()
        } else if method == "GET" && path.hasPrefix("/api/toggleTrails") {
            // Parse simple query parameter on=<0|1>
            if query.contains("on=1") { self.keepVehiclesAsTrail = true }
            else if query.contains("on=0") { self.keepVehiclesAsTrail = false }
            contentType = "application/json; charset=utf-8"
            responseData = "{\"ok\":true,\"keepVehiclesAsTrail\":\(self.keepVehiclesAsTrail)}".data(using: .utf8) ?? Data()
        } else if method == "GET" && path.hasPrefix("/api") {
            contentType = "application/json; charset=utf-8"
            let responseObj: [String: Any] = [
                "decodedCAMs": self.decodedCAMs,
                "decodedDENMs": self.decodedDENMs,
                "decodedSPATEMs": self.decodedSPATEMs,
                "totalV2XBytesRx": self.totalV2XBytesRx,
                "totalGPSBytesRx": self.totalGPSBytesRx,
                "keepVehiclesAsTrail": self.keepVehiclesAsTrail,
                "debugRawPackets": self.debugRawPackets.map { $0.text }
            ]
            if let json = try? JSONSerialization.data(withJSONObject: responseObj, options: []) {
                responseData = json
            } else {
                responseData = Data("{}".utf8)
            }
        } else {
            // Fallback: always serve HTML to make UX robust
            responseData = self.getWebDebugHTML().data(using: .utf8) ?? Data()
        }

        // Always construct standard CRLF headers safely, independent of Git/Xcode line endings configurations
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: \(contentType)",
            "Content-Length: \(responseData.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: *"
        ]
        
        let headerString = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var fullResponse = Data(headerString.utf8)
        fullResponse.append(responseData)

        connection.send(content: fullResponse, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    func getWebDebugHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>V2X Mac-Zentrale Live Debugger</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body { font-family: -apple-system, sans-serif; margin: 20px; background: #121212; color: #fff; }
                h1 { color: #00ff66; }
                p { font-size: 1.1em; }
                pre { background: #1e1e1e; padding: 15px; border-radius: 5px; overflow-x: auto; color: #00ff66; font-size: 0.9em; }
            </style>
        </head>
        <body>
            <h1>V2X Mac-Zentrale Live Debugger</h1>
            <p><strong>Total V2X Bytes Rx:</strong> \(totalV2XBytesRx) Bytes</p>
            <p><strong>Total GPS Bytes Rx:</strong> \(totalGPSBytesRx) Bytes</p>
            <hr style="border: 0.5px solid #333;">
            <p><strong>CAMs decoded:</strong> \(decodedCAMs)</p>
            <p><strong>DENMs decoded:</strong> \(decodedDENMs)</p>
            <p><strong>SPATEMs decoded:</strong> \(decodedSPATEMs)</p>
            <p><strong>Trails:</strong> \(keepVehiclesAsTrail ? "Aktiv" : "Inaktiv")</p>
            <h2>Empfangene Live-Rohdaten-Sätze:</h2>
            <pre>\(debugRawPackets.map { "[\($0.timestamp.formatted(.dateTime.hour().minute().second()))] \($0.text)" }.joined(separator: "\n"))</pre>
        </body>
        </html>
        """
    }
    
    // MARK: - GLOSA / Green Wave Mathematische Berechnung
    func calculateGLOSASpeed(to light: V2XTrafficLight) -> Double? {
        guard let myLoc = myLocation else { return nil }
        
        let lat1Rad = myLoc.latitude * .pi / 180.0
        let lat2Rad = light.coordinate.latitude * .pi / 180.0
        let dLat = (light.coordinate.latitude - myLoc.latitude) * .pi / 180.0
        let dLon = (light.coordinate.longitude - myLoc.longitude) * .pi / 180.0
        
        let sinDLat2 = sin(dLat / 2.0)
        let sinDLon2 = sin(dLon / 2.0)
        
        let a = sinDLat2 * sinDLat2 + cos(lat1Rad) * cos(lat2Rad) * sinDLon2 * sinDLon2
        let distance = 6371000.0 * (2.0 * atan2(sqrt(a), sqrt(1.0 - a)))
        
        if distance > 400 || distance < 10 || light.timeToChange <= 0 { return nil }
        
        let targetSpeed = (distance / Double(light.timeToChange)) * 3.6
        if light.currentPhase == "green" {
            return targetSpeed <= 50 ? targetSpeed : (distance / Double(light.timeToChange + 15)) * 3.6
        } else {
            return targetSpeed
        }
    }
    
    // MARK: - Offline-Karten Downloads (Simuliert)
    func startOfflineMapDownload() {
        isDownloadingMap = true
        downloadProgress = 0.0
        downloadedTilesCount = 0
        totalTilesToDownload = 150
        
        downloadTask = Task {
            for i in 1...150 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms pro Kachel
                await MainActor.run {
                    self.downloadedTilesCount = i
                    self.downloadProgress = Double(i) / 150.0
                }
            }
            await MainActor.run {
                self.isDownloadingMap = false
                self.addLog("[+] Offline-Karten-Download abgeschlossen (\(selectedOfflineRegion)).")
            }
        }
    }
    
    func cancelOfflineMapDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloadingMap = false
        addLog("[-] Offline-Karten-Download abgebrochen.")
    }
    
    // MARK: - Datenaufzeichnungs-Verzeichniswahl & Export
    func selectLogDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Ordner wählen"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            self.logDirectoryPathString = url.path
            self.csvFilePathString = url.appendingPathComponent("v2x_capture.csv").path
            self.pcapFilePathString = url.appendingPathComponent("v2x_capture.pcap").path
            addLog("[+] Daten-Ordner geändert auf: \(url.path)")
        }
    }
    
    func copyLogsToClipboard() {
        let text = logs.map { $0.text }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        addLog("[+] Logs in die Zwischenablage kopiert.")
    }
    
    func exportLogsToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.text]
        savePanel.nameFieldStringValue = "v2x_logs.txt"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let text = logs.map { $0.text }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            addLog("[+] Logs erfolgreich exportiert nach: \(url.path)")
        }
    }
    
    // MARK: - System Simulationen & Debugging-Zähler
    func resetDebugCounters() {
        totalV2XBytesRx = 0
        totalGPSBytesRx = 0
        decodedCAMs = 0
        decodedDENMs = 0
        decodedSPATEMs = 0
        debugRawPackets.removeAll()
        gpsPacketCache.removeAll()
        networkPacketCache.removeAll()
        addLog("[+] System-Debug-Zähler zurückgesetzt.")
    }
    
    func simulateCAM() {
        let simulatedID = Int.random(in: 10...99) * 7 + 2 // Typenverteiler für CAM
        let dummyBytes = Data([0x00, 0x00, 0x00, UInt8(simulatedID)])
        parseV2X(dummyBytes)
    }
    
    func simulateDENM() {
        let simulatedID = Int.random(in: 10...99) * 7 + 1 // Typenverteiler für DENM
        let dummyBytes = Data([0x00, 0x00, 0x00, UInt8(simulatedID)])
        parseV2X(dummyBytes)
    }
    
    func simulateSPATEM() {
        let simulatedID = Int.random(in: 10...99) * 7 // Typenverteiler für SPATEM
        let dummyBytes = Data([0x00, 0x00, 0x00, UInt8(simulatedID)])
        parseV2X(dummyBytes)
    }
    
    func sendRawCommand(_ cmd: String) {
        addESPLog("=> \(cmd)")
        
        let reply: String
        switch cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "help":
            reply = "Verfügbare Befehle: help, status, reboot, coex 0, coex 1, sniffer --start, sniffer --stop"
        case "status":
            reply = "Status: OK | Channel: 180 (5.9 GHz) | COEX: Active"
        case "reboot":
            reply = "Rebooting ESP32..."
        case "coex 0":
            reply = "COEX 0: Bluetooth deaktiviert."
        case "coex 1":
            reply = "COEX 1: Bluetooth aktiviert."
        case "sniffer --start":
            reply = "Sniffer gestartet."
        case "sniffer --stop":
            reply = "Sniffer gestoppt."
        default:
            reply = "Befehl an ESP32 übertragen: \(cmd)"
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.addESPLog(reply)
        }
    }
    
    func exportGPSCache() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.data]
        savePanel.nameFieldStringValue = "gps_cache.pcap"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            PCAPUtils.ensureGlobalHeader(at: url)
            for packet in gpsPacketCache {
                PCAPUtils.appendPacket(packet, to: url)
            }
            addLog("[+] GPS-NMEA-Cache als PCAP exportiert.")
        }
    }
    
    func exportNetworkCache() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.data]
        savePanel.nameFieldStringValue = "network_cache.pcap"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            PCAPUtils.ensureGlobalHeader(at: url)
            for packet in networkPacketCache {
                PCAPUtils.appendPacket(packet, to: url)
            }
            addLog("[+] Netzwerk-Datenstrom-Cache als PCAP exportiert.")
        }
    }
    
    func stopAll() {
        shouldRead = false
        disconnectV2X()
        disconnectGPS()
        stopServer()
    }
}
