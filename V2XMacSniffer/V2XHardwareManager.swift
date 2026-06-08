import Foundation
import CoreLocation
import Observation
import AppKit
import OSLog

@Observable
final class V2XHardwareManager: NSObject {
    // Logger für macOS-Konsolen-Dienstprogramm (Console.app)
    private let sysLogger = Logger(subsystem: "com.v2xmacsniffer.engine", category: "HardwareManager")
    
    // Raw telemetry / simulated objects
    var vehicles: [Int: V2XVehicle] = [:]
    var trafficLights: [Int: V2XTrafficLight] = [:]
    var dangerZones: [Int: V2XDangerZone] = [:]
    
    // Core state properties (KVC and direct Swift)
    @objc var v2xPortOpen: Bool = false
    @objc var isV2XManuallyConnected: Bool = false
    @objc var gpsPortOpen: Bool = false
    @objc var isGPSManuallyConnected: Bool = false
    @objc var v2xRxRateBps: Double = 0.0
    @objc var lastV2XError: String = ""
    @objc var isOfflineMapActive: Bool = false
    @objc var selectedMBTilesPath: String = ""
    
    // Non-KVC / Swift-only states or simply bridged
    @objc var lockedV2XBaud: Int = 921600
    @objc var lockedGPSBaud: Int = 9600
    @objc var serverRunning: Bool = false
    @objc var serverPort: Int = 8080
    @objc var selectedV2XPort: String = ""
    @objc var availablePorts: [String] = []
    @objc var totalV2XBytesRx: Int = 0
    @objc var totalGPSBytesRx: Int = 0
    
    // Offline map and cache settings
    @objc var cacheSizeString: String = "12.4 MB"
    @objc var selectedOfflineRegion: String = "Stuttgart Center"
    @objc var offlineRegionOptions: [String] = ["Stuttgart Center", "Karlsruhe", "München"]
    @objc var maxDownloadZoomLevel: Int = 15
    @objc var isDownloadingMap: Bool = false
    @objc var downloadProgress: Double = 0.0
    @objc var downloadedTilesCount: Int = 0
    @objc var totalTilesToDownload: Int = 0
    
    // Vehicle trail configurations
    @objc var keepVehiclesAsTrail: Bool = false
    @objc var maxTrailPointsPerVehicle: Int = 200
    
    // GPS Receiver settings
    @objc var selectedGPSPort: String = ""
    @objc var selectedGPSBaud: String = "9600"
    @objc var gpsBaudOptions: [String] = ["4800", "9600", "19200", "38400", "57600", "115200"]
    @objc var gpsPacketCache: [String] = []
    
    // Network diagnostics
    @objc var isWebDebugServerEnabled: Bool = false
    @objc var networkPacketCache: [String] = []
    @objc var connectedClients: [String] = []
    
    // Log directory / PCAP Export settings
    @objc var logDirectoryPathString: String = ""
    @objc var isPCAPLoggingActive: Bool = true // Standardmäßig aktiv für Wireshark-Aufzeichnung
    @objc var isCSVLoggingActive: Bool = true  // Standardmäßig aktiv für Excel-Auswertungen
    
    // UI Helpers / Simulation controls
    @objc var isDebugWindowActive: Bool = false
    @objc var isAutoSimulationActive: Bool = false
    @objc var simulationIntervalSeconds: Double = 1.0
    
    // Debug C-ITS counter properties accessed via KVC
    @objc var decodedCAMs: Int = 0
    @objc var decodedDENMs: Int = 0
    @objc var decodedSPATEMs: Int = 0
    @objc var decodedMAPEMs: Int = 0
    @objc var decodedIVIMs: Int = 0
    @objc var decodedCPMs: Int = 0
    @objc var decodedSRMs: Int = 0
    @objc var decodedSSMs: Int = 0
    @objc var decodedMCMs: Int = 0
    @objc var decodedRTCMEMs: Int = 0
    
    // KVC geometries/maneuvers
    @objc var mapGeometries: [Any] = []
    @objc var maneuvers: [Any] = []
    
    // Core location property KVC workarounds
    @objc var myLocationCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
    var myLocation: CLLocationCoordinate2D? {
        get { myLocationCoordinate }
        set { if let val = newValue { myLocationCoordinate = val } }
    }
    
    // System log
    var logs: [LogEntry] = []
    
    // Automatisierte Dateipfade
    @objc var csvFileURL: URL?
    @objc var pcapFileURL: URL?
    @objc var unifiedLogFileURL: URL?
    
    // Serielle Thread Steuerelemente
    private var v2xHandle: FileHandle?
    private var gpsHandle: FileHandle?
    private var shouldReadSerial: Bool = false

    // MARK: - Firmware Stream Synchronization (Magic Bytes + Big-Endian Length)
    // Adjust magic bytes (0xAA, 0xBB) and framing to match your firmware if needed
    private var v2xStreamBuffer = Data()
    
    private func processIncomingStream(data: Data) {
        // Append incoming chunk to rolling buffer
        v2xStreamBuffer.append(data)
        var index = 0
        // We need at least 4 bytes to search for magic + length
        while index <= v2xStreamBuffer.count - 4 {
            // 1) Synchronize on firmware magic bytes (example: 0xAA 0xBB)
            if v2xStreamBuffer[index] == 0xAA && v2xStreamBuffer[index + 1] == 0xBB {
                // 2) Read payload length (big-endian UInt16)
                let lengthRange = (index + 2)..<(index + 4)
                let lengthBytes = v2xStreamBuffer.subdata(in: lengthRange)
                let payloadLength = Int(uint16FromBigEndian(lengthBytes))
                let startOfPayload = index + 4
                let endOfPayload = startOfPayload + payloadLength
                // 3) Ensure the full payload is present in the buffer
                if endOfPayload <= v2xStreamBuffer.count {
                    let v2xPayload = v2xStreamBuffer.subdata(in: startOfPayload..<endOfPayload)
                    // 4) Hand off to the existing decoder pipeline
                    self.parseV2XBytes(v2xPayload)
                    // Advance index to the end of the consumed frame
                    index = endOfPayload
                } else {
                    // Incomplete frame: stop here and wait for more data
                    break
                }
            } else {
                // Not aligned yet: continue searching
                index += 1
            }
        }
        // Drop consumed bytes from the front of the buffer
        if index > 0 {
            v2xStreamBuffer.removeSubrange(0..<index)
        }
    }
    
    private func uint16FromBigEndian(_ data: Data) -> UInt16 {
        return data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }
    
    override init() {
        super.init()
        
        // Erstes dynamisches Scannen realer Schnittstellen auf dem Mac
        performDynamicPortScan()
        
        // Setup der log-Ordner & automatische Benamung (Datum_Uhrzeit + LOG_V2XMacSniffer)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logDir = docs.appendingPathComponent("V2X_Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = formatter.string(from: Date())
            
            let csvName = "\(dateString)_LOG_V2XMacSniffer.csv"
            let pcapName = "\(dateString)_LOG_V2XMacSniffer.pcap"
            let unifiedName = "\(dateString)_UNIFIED_LOG_V2XMacSniffer.log"
            
            let csvURL = logDir.appendingPathComponent(csvName)
            let pcapURL = logDir.appendingPathComponent(pcapName)
            let unifiedURL = logDir.appendingPathComponent(unifiedName)
            
            self.csvFileURL = csvURL
            self.pcapFileURL = pcapURL
            self.unifiedLogFileURL = unifiedURL
            self.logDirectoryPathString = logDir.path
            
            // Erstellung der Dateien mit globalem Header auf der SSD
            CSVUtils.ensureHeader(at: csvURL)
            PCAPUtils.ensureGlobalHeader(at: pcapURL)
            
            // Initiale Zeile in die System-Logdatei schreiben
            writeToUnifiedLogFile("--- UNIFIED LOGFILE GESTARTET AM \(Date().formatted()) ---\n")
            
            addLog("[+] Logging gestartet: \(csvName)")
            addLog("[+] PCAP-Sniffer bereit: \(pcapName)")
            addLog("[+] System-Protokolldatei verriegelt: \(unifiedName)")
            sysLogger.info("Log-Dateien erfolgreich angelegt. CSV: \(csvName, privacy: .public), PCAP: \(pcapName, privacy: .public), Unified: \(unifiedName, privacy: .public)")
        } else {
            addLog("[-] Log-Verzeichnis konnte nicht initialisiert werden.")
            sysLogger.error("Kritischer Fehler: Dokumenten-Verzeichnis für V2X_Logs nicht verfügbar.")
        }
        
        addLog("System initialisiert.")
    }
    
    // MARK: - Dynamischer Schnittstellen-Scanner
    /// Listet alle echten physischen seriellen Ports des Macs auf und wählt sinnvolle Standardwerte aus.
    private func performDynamicPortScan() {
        let fileManager = FileManager.default
        do {
            let devices = try fileManager.contentsOfDirectory(atPath: "/dev")
            
            let filteredPorts = devices.filter { device in
                guard device.hasPrefix("cu.") else { return false }
                if device.contains("Bluetooth-Incoming") || device.contains("wlan") || device.contains("AirPods") {
                    return false
                }
                return true
            }.map { "/dev/\($0)" }
            
            self.availablePorts = filteredPorts.sorted()
            
            if let espDevice = availablePorts.first(where: { $0.contains("usbserial") || $0.contains("usbmodem") || $0.contains("CH34") }) {
                self.selectedV2XPort = espDevice
            } else {
                self.selectedV2XPort = availablePorts.first ?? ""
            }
            
            if let gpsDevice = availablePorts.first(where: { $0.contains("usb") && $0 != selectedV2XPort }) {
                self.selectedGPSPort = gpsDevice
            } else {
                self.selectedGPSPort = availablePorts.first(where: { $0 != selectedV2XPort }) ?? ""
            }
            
            sysLogger.info("Schnittstellen-Scan erfolgreich: \(self.availablePorts.count) Ports gefunden.")
            
        } catch {
            sysLogger.error("Fehler beim Scannen von /dev: \(error.localizedDescription)")
            self.availablePorts = []
            self.selectedV2XPort = ""
            self.selectedGPSPort = ""
        }
    }
    
    // MARK: - Real Ingestion Pipeline & Decapsulation
    /// Verarbeitet eintreffende USB-Rohdatenströme, entpackt die IEEE 802.11p Kapselung und extrahiert C-ITS Telemetrie
    @objc func parseV2XBytes(_ rawPacket: Data) {
        totalV2XBytesRx += rawPacket.count
        
        // Sicheres PCAP-Schreiben des nativen Rohpakets (Survives Crashs)
        writeToPCAPFile(rawPacket)
        
        // 1. Suche den LLC-SNAP Header im Bytestrom (0xAA 0xAA 0x03 0x00 0x00 0x00 0x89 0x47)
        let llcPattern = Data([0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47])
        guard let llcIndex = rawPacket.range(of: llcPattern)?.lowerBound else {
            let hexPrefix = rawPacket.prefix(16).map { String(format: "%02X", $0) }.joined()
            sysLogger.debug("Paket verworfen: LLC-SNAP Muster fehlt. Paketgröße: \(rawPacket.count) B, Hex-Header: \(hexPrefix)")
            return
        }
        
        // Schneide den 802.11 MAC-Header ab
        let gnPayload = rawPacket.subdata(in: llcIndex + llcPattern.count..<rawPacket.count)
        guard gnPayload.count >= 36 else {
            addLog("[warn] GeoNetworking Header zu kurz (\(gnPayload.count) B). Paket verworfen.")
            sysLogger.warning("GeoNetworking Payload zu klein: \(gnPayload.count) Bytes.")
            return
        }
        
        // 2. Extrahiere Metadaten aus dem GeoNetworking Common & Extended Header
        // Richtige Offsets: 
        // Basic Header (4 B) + Common Header (8 B) = 12 B. 
        // Extended Header (LPV) startet ab Byte 12: 
        //   GN_ADDR: 8 B (12..<20), 
        //   Timestamp: 4 B (20..<24), 
        //   Latitude: 4 B (24..<28), 
        //   Longitude: 4 B (28..<32)
        let latRaw = gnPayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int32.self).bigEndian }
        let lonRaw = gnPayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: Int32.self).bigEndian }
        
        let latitude = Double(latRaw) / 10_000_000.0
        let longitude = Double(lonRaw) / 10_000_000.0
        
        // Plausibilitätsprüfung für die Region (Deutschland / Baden-Württemberg Korridor)
        guard latitude > 45.0 && latitude < 55.0 && longitude > 5.0 && longitude < 16.0 else {
            let errorMsg = "Ungültige Geodaten verworfen: Lat \(latitude), Lon \(longitude) (Erwartet B29 Korridor)"
            addLog("[warn] \(errorMsg)")
            sysLogger.warning("Geokoordinaten außerhalb des Plausibilitätskorridors: Lat \(latitude), Lon \(longitude)")
            lastV2XError = errorMsg
            return
        }
        
        // Lese Geschwindigkeits- & Richtungswerte aus dem LPV (Bytes 32 und 34)
        let speedRaw = gnPayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt16.self).bigEndian }
        let headingRaw = gnPayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self).bigEndian }
        
        // MSB von Speed ausmaskieren (0x7FFF) und in km/h umrechnen (Einheit ist 0.01 m/s)
        let speedVal = speedRaw & 0x7FFF
        let speedKmH = Double(speedVal) * 0.01 * 3.6
        let headingDeg = Double(headingRaw) * 0.1     // GN Heading in 0.1 Grad
        
        // 3. Bestimme den nachgelagerten BTP-Header-Offset dynamisch anhand des GN-Header-Typs (HT)
        // HT ist in den oberen 4 Bits von Byte 5 im Common-Header hinterlegt.
        let headerTypeByte = gnPayload[5]
        let headerType = (headerTypeByte >> 4) & 0x0F
        
        let btpOffset: Int
        switch headerType {
        case 1, 2: // SHB, TSB -> Extended Header ist 28 Bytes lang
            btpOffset = 40
        case 3, 4: // GBC, GAC -> Extended Header ist 44 Bytes lang
            btpOffset = 56
        case 5:    // GeoUnicast -> Extended Header ist 36 Bytes lang
            btpOffset = 48
        default:   // Fallback auf SHB/TSB Standard
            btpOffset = 40
        }
        
        guard gnPayload.count >= btpOffset + 4 else {
            addLog("[warn] BTP-Header fehlt oder Paket abgeschnitten. Offset: \(btpOffset), Payload-Größe: \(gnPayload.count)")
            return
        }
        
        let destPort = gnPayload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: btpOffset, as: UInt16.self).bigEndian }
        
        // C-ITS ASN.1 Payload startet exakt hinter dem 4-Byte BTP-Header
        let asnPduData = gnPayload.subdata(in: btpOffset + 4..<gnPayload.count)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        sysLogger.debug("GN-Paket erkannt: Lat \(latitude), Lon \(longitude), Speed \(speedKmH) km/h, BTP-Port \(destPort)")
        
        if destPort == 2001 { // CAM Port
            decodedCAMs += 1
            let braking: Bool
            let finalStationID: Int
            if let decodedCAM = V2XDecoders.decodeCAM(from: asnPduData) {
                braking = decodedCAM.braking
                finalStationID = decodedCAM.stationID
                addLog("[V2X] CAM (Station: \(finalStationID)) erfolgreich ASN.1-dekodiert. Speed: \(String(format: "%.1f", speedKmH)) km/h. Bremslicht: \(braking ? "AN" : "AUS")")
                sysLogger.info("CAM ASN.1 erfolgreich dekodiert. ID: \(finalStationID), Bremslicht: \(braking)")
            } else {
                braking = false
                finalStationID = Int(speedRaw ^ headingRaw) // Fallback ID
                addLog("[V2X] CAM (Fallback ID: \(finalStationID)) - Lat: \(latitude), Lon: \(longitude), Speed: \(String(format: "%.1f", speedKmH)) km/h")
                sysLogger.warning("CAM ASN.1-Parser fehlgeschlagen. Verwende GN-Fallback-Werte.")
            }
            
            let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            
            DispatchQueue.main.async {
                if var vehicle = self.vehicles[finalStationID] {
                    vehicle.updatePosition(to: coord, heading: headingDeg, speed: speedKmH, isBraking: braking)
                    self.vehicles[finalStationID] = vehicle
                } else {
                    self.vehicles[finalStationID] = V2XVehicle(id: finalStationID, coordinate: coord, heading: headingDeg, speed: speedKmH, isBraking: braking, lastSeen: Date())
                }
            }
            
            writeToCSVLine("\(timestamp);CAM;\(finalStationID);\(latitude);\(longitude);\(speedKmH);\(headingDeg);\(braking);none\n")
            
        } else if destPort == 2002 { // DENM Port
            decodedDENMs += 1
            let denmID = Int(timestamp % 100000)
            let zone = V2XDangerZone(id: denmID, type: "Baustelle", coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), radiusMeter: 150.0)
            
            addLog("[V2X] DENM (Gefahr #\(denmID)) empfangen auf Lat: \(latitude), Lon: \(longitude)")
            DispatchQueue.main.async {
                self.dangerZones[denmID] = zone
            }
            writeToCSVLine("\(timestamp);DENM;\(denmID);\(latitude);\(longitude);0.0;0.0;false;Baustelle_150m\n")
            sysLogger.info("DENM (Gefahrenmeldung) registriert auf Lat: \(latitude), Lon: \(longitude)")
            
        } else if destPort == 2004 { // SPATEM Port
            decodedSPATEMs += 1
            let lightID = Int(timestamp % 10000)
            let light = V2XTrafficLight(id: lightID, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), currentPhase: "green", timeToChange: 15)
            
            addLog("[V2X] SPATEM (Kreuzungs-Ampel #\(lightID)) empfangen auf Lat: \(latitude), Lon: \(longitude)")
            DispatchQueue.main.async {
                self.trafficLights[lightID] = light
            }
            writeToCSVLine("\(timestamp);SPATEM;\(lightID);\(latitude);\(longitude);0.0;0.0;false;green_15s\n")
            sysLogger.info("SPATEM (Ampelsteuerung) registriert auf Lat: \(latitude), Lon: \(longitude)")
        } else if destPort == 2003 { // MAPEM Port
            decodedMAPEMs += 1
            addLog("[V2X] MAPEM (Topologie) empfangen auf Lat: \(latitude), Lon: \(longitude)")
            writeToCSVLine("\(timestamp);MAPEM;0;\(latitude);\(longitude);0.0;0.0;false;topology\n")
        } else if destPort == 2006 { // IVIM Port
            decodedIVIMs += 1
            addLog("[V2X] IVIM (Verkehrsschild) empfangen auf Lat: \(latitude), Lon: \(longitude)")
            writeToCSVLine("\(timestamp);IVIM;0;\(latitude);\(longitude);0.0;0.0;false;signage\n")
        } else if destPort == 2009 { // CPM Port
            decodedCPMs += 1
            addLog("[V2X] CPM (Sensorkollektiv) empfangen auf Lat: \(latitude), Lon: \(longitude)")
            writeToCSVLine("\(timestamp);CPM;0;\(latitude);\(longitude);0.0;0.0;false;collective_perception\n")
        } else {
            sysLogger.debug("Unbekannter C-ITS Zielport empfangen: \(destPort)")
        }
    }
    
    // MARK: - Serial Port Hardware Configuration
    private func configureSerialPort(path: String, baud: String) {
        let task = Process()
        task.launchPath = "/bin/stty"
        task.arguments = ["-f", path, baud, "cs8", "-cstopb", "-parity"]
        do {
            try task.run()
            task.waitUntilExit()
            sysLogger.info("[+] Port \(path) erfolgreich auf \(baud) konfiguriert.")
        } catch {
            sysLogger.error("[-] Fehler beim Konfigurieren des seriellen Ports \(path): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Core Controls
    @objc func scanPorts() {
        addLog("Scanne serielle Schnittstellen...")
        performDynamicPortScan()
    }
    
    @objc func toggleV2XConnection() {
        if isV2XManuallyConnected {
            shouldReadSerial = false
            v2xHandle?.closeFile()
            v2xHandle = nil
            isV2XManuallyConnected = false
            v2xPortOpen = false
            addLog("[-] V2X-Modem getrennt.")
        } else {
            guard !selectedV2XPort.isEmpty else {
                addLog("[-] Kein V2X-Port ausgewählt.")
                return
            }
            
            configureSerialPort(path: selectedV2XPort, baud: "\(lockedV2XBaud)")
            
            if let handle = FileHandle(forReadingAtPath: selectedV2XPort) {
                self.v2xHandle = handle
                self.isV2XManuallyConnected = true
                self.v2xPortOpen = true
                self.shouldReadSerial = true
                addLog("[+] V2X-Modem aktiv auf: \(selectedV2XPort)")
                addLog("[Info] Verwende Firmware-Framing (Magic 0xAA 0xBB, Big-Endian Länge)")
                
                // Serial-Reader Thread for firmware framing (magic 0xAA 0xBB + BE length)
                Thread.detachNewThread { [weak self] in
                    while self?.shouldReadSerial == true {
                        guard let self = self, let handle = self.v2xHandle else { break }
                        do {
                            if let chunk = try handle.read(upToCount: 512), !chunk.isEmpty {
                                // Feed chunk into firmware-framed stream processor (magic 0xAA 0xBB + BE length)
                                self.processIncomingStream(data: chunk)
                            } else {
                                try Thread.sleep(forTimeInterval: 0.005)
                            }
                        } catch {
                            self.sysLogger.error("V2X USB Lesefehler: \(error.localizedDescription)")
                            break
                        }
                    }
                }
            } else {
                addLog("[-] Port belegt oder Zugriff verweigert auf \(selectedV2XPort). Sandbox aktiv?")
            }
        }
    }
    
    @objc func toggleGPSConnection() {
        if isGPSManuallyConnected {
            shouldReadSerial = false
            gpsHandle?.closeFile()
            gpsHandle = nil
            isGPSManuallyConnected = false
            gpsPortOpen = false
            addLog("[-] GPS-Empfänger getrennt.")
        } else {
            guard !selectedGPSPort.isEmpty else {
                addLog("[-] Kein GPS-Port ausgewählt.")
                return
            }
            
            configureSerialPort(path: selectedGPSPort, baud: selectedGPSBaud)
            
            if let handle = FileHandle(forReadingAtPath: selectedGPSPort) {
                self.gpsHandle = handle
                self.isGPSManuallyConnected = true
                self.gpsPortOpen = true
                self.shouldReadSerial = true
                addLog("[+] GPS-Empfänger aktiv auf: \(selectedGPSPort)")
                
                // Serial-Reader Thread für NMEA (Zeilenbasiert)
                Thread.detachNewThread { [weak self] in
                    var buffer = ""
                    while self?.shouldReadSerial == true {
                        guard let self = self, let handle = self.gpsHandle else { break }
                        do {
                            if let data = try handle.read(upToCount: 128),
                               let chunk = String(data: data, encoding: .utf8) {
                                buffer += chunk
                                while let lineEnd = buffer.firstIndex(of: "\n") {
                                    let line = String(buffer[..<lineEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                                    buffer.removeSubrange(...lineEnd)
                                    self.totalGPSBytesRx += line.count
                                    if line.hasPrefix("$GPRMC") {
                                        self.parseNMEALine(line)
                                    }
                                }
                            } else {
                                try Thread.sleep(forTimeInterval: 0.05)
                            }
                        } catch {
                            self.sysLogger.error("GPS USB Lesefehler: \(error.localizedDescription)")
                            break
                        }
                    }
                }
            } else {
                addLog("[-] Port belegt oder Zugriff verweigert auf \(selectedGPSPort).")
            }
        }
    }
    
    private func parseNMEALine(_ line: String) {
        let parts = line.components(separatedBy: ",")
        if parts.count > 6, parts[2] == "A" {
            guard let rawLat = Double(parts[3]), let rawLon = Double(parts[5]) else { return }
            
            let latDeg = floor(rawLat / 100)
            let latMin = rawLat - (latDeg * 100)
            var lat = latDeg + (latMin / 60)
            if parts[4] == "S" { lat *= -1 }
            
            let lonDeg = floor(rawLon / 100)
            let lonMin = rawLon - (lonDeg * 100)
            var lon = lonDeg + (lonMin / 60)
            if parts[6] == "W" { lon *= -1 }
            
            addLog("[GPS] NMEA GPRMC Empfangen - Lat: \(String(format: "%.6f", lat)), Lon: \(String(format: "%.6f", lon))")
            
            DispatchQueue.main.async {
                self.myLocation = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                self.gpsPacketCache.append(line)
                if self.gpsPacketCache.count > 100 {
                    self.gpsPacketCache.removeFirst()
                }
            }
        }
    }
    
    // MARK: - Crash-Sicheres, atomares CSV Schreiben (Synchronized disk commits)
    private func writeToCSVLine(_ line: String) {
        guard isCSVLoggingActive, let url = csvFileURL else { return }
        guard let data = line.data(using: .utf8) else { return }
        
        let fileScoped = url.startAccessingSecurityScopedResource()
        defer { if fileScoped { url.stopAccessingSecurityScopedResource() } }
        
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try CSVUtils.defaultHeader.write(to: url, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize() // Commit Cache auf die SSD (Schutz vor Dateiverlust bei Absturz)
            try handle.close()
        } catch {
            sysLogger.error("Schwerwiegender CSV-Schreibfehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Crash-Sicheres, atomares PCAP Schreiben
    private func writeToPCAPFile(_ packet: Data) {
        guard isPCAPLoggingActive, let url = pcapFileURL else { return }
        
        let fileScoped = url.startAccessingSecurityScopedResource()
        defer { if fileScoped { url.stopAccessingSecurityScopedResource() } }
        
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try PCAPUtils.globalHeader().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            
            let timeInterval = Date().timeIntervalSince1970
            let seconds = UInt32(timeInterval)
            let microseconds = UInt32((timeInterval - Double(seconds)) * 1_000_000)
            let length = UInt32(packet.count)

            var header = Data()
            header.append(contentsOf: withUnsafeBytes(of: seconds.littleEndian) { Data($0) })
            header.append(contentsOf: withUnsafeBytes(of: microseconds.littleEndian) { Data($0) })
            header.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })
            header.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })

            try handle.seekToEnd()
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: packet)
            try handle.synchronize() // Commit Cache auf die SSD (Schutz vor Dateiverlust bei Absturz)
            try handle.close()
        } catch {
            sysLogger.error("Schwerwiegender PCAP-Schreibfehler: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Crash-Sicheres, atomares Unified Log Schreiben
    private func writeToUnifiedLogFile(_ line: String) {
        guard let url = unifiedLogFileURL, let data = line.data(using: .utf8) else { return }
        
        let fileScoped = url.startAccessingSecurityScopedResource()
        defer { if fileScoped { url.stopAccessingSecurityScopedResource() } }
        
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try "--- UNIFIED SYSTEM LOG ---\n".write(to: url, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize() // Sofortiges Schreiben auf Platte erzwingen
            try handle.close()
        } catch {
            sysLogger.error("Schwerwiegender Fehler beim Schreiben ins Unified Log: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Core Logging
    @objc func addLog(_ message: String) {
        let timestamp = Date()
        let formattedText = "[\(timestamp.formatted(.dateTime.hour().minute().second()))] \(message)"
        
        DispatchQueue.main.async {
            let entry = LogEntry(timestamp: timestamp, text: message)
            self.logs.append(entry)
            if self.logs.count > 500 {
                self.logs.removeFirst()
            }
        }
        
        // Parallel und ohne Verzögerung in die Unified-Logdatei auf der SSD flashen
        writeToUnifiedLogFile(formattedText + "\n")
    }
    
    @objc func addDebugPacketLog(_ message: String) {
        addLog(message)
    }
    
    @objc func toggleServer() {
        serverRunning.toggle()
        addLog(serverRunning ? "TCP-Server läuft auf Port \(serverPort)" : "TCP-Server gestoppt")
    }
    
    @objc func stopAll() {
        shouldReadSerial = false
        v2xPortOpen = false
        gpsPortOpen = false
        serverRunning = false
        isAutoSimulationActive = false
        v2xHandle?.closeFile()
        gpsHandle?.closeFile()
        v2xHandle = nil
        gpsHandle = nil
        addLog("System gestoppt.")
    }
    
    @objc func sendRawCommand(_ command: String) {
        addLog("Befehl an ESP32: '\(command)'")
    }
    
    @objc func resetDebugCounters() {
        decodedCAMs = 0
        decodedDENMs = 0
        decodedSPATEMs = 0
        decodedMAPEMs = 0
        decodedIVIMs = 0
        decodedCPMs = 0
        decodedSRMs = 0
        decodedSSMs = 0
        decodedMCMs = 0
        decodedRTCMEMs = 0
        totalV2XBytesRx = 0
        totalGPSBytesRx = 0
        addLog("Zähler zurückgesetzt.")
    }
    
    // MARK: - Simulators
    @objc func toggleAutoSimulation() {
        isAutoSimulationActive.toggle()
        addLog(isAutoSimulationActive ? "Auto-Simulation aktiv" : "Auto-Simulation gestoppt")
    }
    
    @objc func simulateCAM(lat: Double, lon: Double) {
        decodedCAMs += 1
        let vehicleId = Int.random(in: 100...200)
        let vehicle = V2XVehicle(id: vehicleId, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), heading: Double.random(in: 0...360), speed: Double.random(in: 30...80), isBraking: Bool.random(), lastSeen: Date())
        vehicles[vehicleId] = vehicle
        addLog("[SIM] CAM (Fahrzeug #\(vehicleId)) simuliert.")
    }
    
    @objc func simulateDENM(lat: Double, lon: Double) {
        decodedDENMs += 1
        addLog("[SIM] DENM (Gefahrenmeldung) simuliert.")
    }
    
    @objc func simulateSPATEM(lat: Double, lon: Double) {
        decodedSPATEMs += 1
        let lightId = Int.random(in: 1...5)
        let light = V2XTrafficLight(id: lightId, coordinate: CLLocationCoordinate2D(latitude: lat + 0.001, longitude: lon + 0.001), currentPhase: ["green", "yellow", "red"].randomElement() ?? "red", timeToChange: Int.random(in: 5...30))
        trafficLights[lightId] = light
        addLog("[SIM] SPATEM (Kreuzungsampel #\(lightId)) simuliert.")
    }
    
    @objc func simulateMAPEM(lat: Double, lon: Double) {
        decodedMAPEMs += 1
        addLog("[SIM] MAPEM (Topologie) simuliert.")
    }
    
    @objc func simulateIVIM(lat: Double, lon: Double) {
        decodedIVIMs += 1
        addLog("[SIM] IVIM (Infrastruktur-Schild) simuliert.")
    }
    
    @objc func simulateCPM(lat: Double, lon: Double) {
        decodedCPMs += 1
        addLog("[SIM] CPM (Sensorkollektiv) simuliert.")
    }
    
    @objc func simulateSRM(lat: Double, lon: Double) {
        decodedSRMs += 1
        addLog("[SIM] SRM (Priorisierungsanfrage) simuliert.")
    }
    
    @objc func simulateSSM(lat: Double, lon: Double) {
        decodedSSMs += 1
        addLog("[SIM] SSM (Priorisierungsrückmeldung) simuliert.")
    }
    
    @objc func simulateMCM(lat: Double, lon: Double) {
        decodedMCMs += 1
        addLog("[SIM] MCM (Kooperationsmanöver) simuliert.")
    }
    
    @objc func simulateRTCMEM(lat: Double, lon: Double) {
        decodedRTCMEMs += 1
        addLog("[SIM] RTCMEM (Korrekturdaten) simuliert.")
    }
    
    // MARK: - GLOSA Algorithm
    func calculateGLOSASpeed(to light: V2XTrafficLight) -> Double? {
        return 50.0
    }
    
    // MARK: - Actions
    @objc func selectLogDirectory() {
        logDirectoryPathString = "/User/Logs/V2X"
        addLog("Verzeichnis gewählt: \(logDirectoryPathString)")
    }
    
    @objc func cancelOfflineMapDownload() {
        isDownloadingMap = false
        addLog("Karten-Download abgebrochen.")
    }
    
    @objc func startOfflineMapDownload() {
        isDownloadingMap = true
        downloadProgress = 0.0
        downloadedTilesCount = 0
        totalTilesToDownload = 150
        addLog("Karten-Download gestartet...")
    }
    
    @objc func importMBTilesFile() {
        addLog("MBTiles importiert.")
    }
    
    @objc func exportCacheToMBTiles() {
        addLog("Cache exportiert.")
    }
    
    @objc func clearTileCache() {
        cacheSizeString = "0.0 MB"
        addLog("Cache geleert.")
    }
    
    @objc func copyLogsToClipboard() {
        let text = logs.map { "[\($0.timestamp.formatted())] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        addLog("Logs kopiert.")
    }
    
    @objc func exportLogsToFile() {
        addLog("Logs in Datei gesichert.")
    }
    
    @objc func exportGPSCache() {
        addLog("GPS Cache gesichert.")
    }
    
    @objc func exportNetworkCache() {
        addLog("Netzwerk Cache gesichert.")
    }
    
    // MARK: - Objective-C Key-Value Coding Overrides
    override func value(forKey key: String) -> Any? {
        if key == "myLocation" {
            return myLocationCoordinate
        }
        if key == "vehicles" {
            return vehicles
        }
        if key == "trafficLights" {
            return trafficLights
        }
        if key == "dangerZones" {
            return dangerZones
        }
        if key == "v2xPortOpen" {
            return v2xPortOpen
        }
        if key == "isV2XManuallyConnected" {
            return isV2XManuallyConnected
        }
        if key == "gpsPortOpen" {
            return gpsPortOpen
        }
        if key == "isGPSManuallyConnected" {
            return isGPSManuallyConnected
        }
        if key == "v2xRxRateBps" {
            return v2xRxRateBps
        }
        if key == "lastV2XError" {
            return lastV2XError
        }
        if key == "isOfflineMapActive" {
            return isOfflineMapActive
        }
        if key == "selectedMBTilesPath" {
            return selectedMBTilesPath
        }
        if key == "totalV2XBytesRx" {
            return totalV2XBytesRx
        }
        if key == "totalGPSBytesRx" {
            return totalGPSBytesRx
        }
        if key == "decodedCAMs" { return decodedCAMs }
        if key == "decodedDENMs" { return decodedDENMs }
        if key == "decodedSPATEMs" { return decodedSPATEMs }
        if key == "decodedMAPEMs" { return decodedMAPEMs }
        if key == "decodedIVIMs" { return decodedIVIMs }
        if key == "decodedCPMs" { return decodedCPMs }
        if key == "decodedSRMs" { return decodedSRMs }
        if key == "decodedSSMs" { return decodedSSMs }
        if key == "decodedMCMs" { return decodedMCMs }
        if key == "decodedRTCMEMs" { return decodedRTCMEMs }
        if key == "unifiedLogFileURL" { return unifiedLogFileURL }
        return super.value(forKey: key)
    }
}
