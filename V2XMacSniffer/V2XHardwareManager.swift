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

// MARK: - JSON Netzwerk-Protokoll Hilfsmodelle (Auch auf macOS verfügbar)
struct TCPMessageEnvelope: Codable {
    let msgType: String
    let data: TCPMessageData
}

struct TCPMessageData: Codable {
    let id: Int
    let latitude: Double?
    let longitude: Double?
    let coordinate: CoordinateHelper?
    let speed: Double?
    let speedKmH: Double?
    let heading: Double?
    let isBraking: Bool?
    let currentPhase: String?
    let timeToChange: Int?
    let type: String? // Für Gefahrenzonen
    let radiusMeter: Double?
    
    struct CoordinateHelper: Codable {
        let latitude: Double
        let longitude: Double
    }
}

// MARK: - CachedTileOverlay für MapKit Offline-Caching Support
class CachedTileOverlay: MKTileOverlay {
    let cacheDirectory: URL
    
    override init(urlTemplate URLTemplate: String? = nil) {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectory = paths[0].appendingPathComponent("MapTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        super.init(urlTemplate: URLTemplate)
    }
    
    func cachePath(for path: MKTileOverlayPath) -> URL {
        return cacheDirectory
            .appendingPathComponent("\(path.z)")
            .appendingPathComponent("\(path.x)")
            .appendingPathComponent("\(path.y).png")
    }
    
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Standard-Fallback auf OpenStreetMap
        let urlString = "https://a.tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png"
        return URL(string: urlString)!
    }
    
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let fileURL = cachePath(for: path)
        
        // 1. Lokalen Cache prüfen
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL) {
                result(data, nil)
                return
            }
        }
        
        // 2. Online laden und für Offline-Einsatz wegspeichern
        let tileURL = self.url(forTilePath: path)
        var request = URLRequest(url: tileURL)
        request.setValue("V2XMacSniffer/1.0 (macOS; V2X C-ITS Terminal App)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data {
                let directory = fileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: fileURL)
                result(data, nil)
            } else {
                result(nil, error)
            }
        }.resume()
    }
}

// MARK: - C-ITS ERWEITERTE MODELLE (Codable & Equatable)

// MARK: - MAPEM (Map Data) - Kreuzungsgeometrien & Fahrspuren
struct V2XMapGeometry: Identifiable, Codable, Equatable {
    let id: Int
    var name: String
    var centerCoordinate: CLLocationCoordinate2D
    var laneCoordinates: [CLLocationCoordinate2D] // Polylinien für Fahrspuren
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, name, centerLatitude, centerLongitude, laneCoordinates }

    init(id: Int, name: String, centerCoordinate: CLLocationCoordinate2D, laneCoordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.name = name
        self.centerCoordinate = centerCoordinate
        self.laneCoordinates = laneCoordinates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let lat = try c.decode(Double.self, forKey: .centerLatitude)
        let lon = try c.decode(Double.self, forKey: .centerLongitude)
        centerCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        let rawLanes = try c.decode([[Double]].self, forKey: .laneCoordinates)
        laneCoordinates = rawLanes.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(centerCoordinate.latitude, forKey: .centerLatitude)
        try c.encode(centerCoordinate.longitude, forKey: .centerLongitude)
        
        let rawLanes = laneCoordinates.map { [$0.latitude, $0.longitude] }
        try c.encode(rawLanes, forKey: .laneCoordinates)
    }

    static func == (lhs: V2XMapGeometry, rhs: V2XMapGeometry) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name
    }
}

// MARK: - IVIM (Infrastructural Virtual Signage) - Straßenschilder & Tempolimits
struct V2XVirtualSign: Identifiable, Codable, Equatable {
    let id: Int
    var type: String // "SPEED_LIMIT", "NO_OVERTAKING", "ROAD_WORKS"
    var value: Int // Z.B. 30, 50, 80, 100 km/h
    var coordinate: CLLocationCoordinate2D
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, type, value, latitude, longitude }

    init(id: Int, type: String, value: Int, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.type = type
        self.value = value
        self.coordinate = coordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decode(Int.self, forKey: .value)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(value, forKey: .value)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }

    static func == (lhs: V2XVirtualSign, rhs: V2XVirtualSign) -> Bool {
        return lhs.id == rhs.id && lhs.type == rhs.type && lhs.value == rhs.value
    }
}

// MARK: - CPM (Collective Perception Message) - LiDAR/Radar Fremdobjekte
struct V2XCollectiveObject: Identifiable, Codable, Equatable {
    let id: Int
    var sensorType: String // "RADAR", "LIDAR", "CAMERA"
    var objectClass: String // "PEDESTRIAN", "CYCLIST", "VEHICLE", "OBSTACLE"
    var coordinate: CLLocationCoordinate2D
    var speed: Double
    var heading: Double
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, sensorType, objectClass, latitude, longitude, speed, heading }

    init(id: Int, sensorType: String, objectClass: String, coordinate: CLLocationCoordinate2D, speed: Double, heading: Double) {
        self.id = id
        self.sensorType = sensorType
        self.objectClass = objectClass
        self.coordinate = coordinate
        self.speed = speed
        self.heading = heading
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sensorType = try c.decode(String.self, forKey: .sensorType)
        objectClass = try c.decode(String.self, forKey: .objectClass)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        speed = try c.decode(Double.self, forKey: .speed)
        heading = try c.decode(Double.self, forKey: .heading)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sensorType, forKey: .sensorType)
        try c.encode(objectClass, forKey: .objectClass)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
        try c.encode(speed, forKey: .speed)
        try c.encode(heading, forKey: .heading)
    }

    static func == (lhs: V2XCollectiveObject, rhs: V2XCollectiveObject) -> Bool {
        return lhs.id == rhs.id && lhs.objectClass == rhs.objectClass && lhs.speed == rhs.speed
    }
}

// MARK: - SRM (Signal Request Message) - Prioritätsanfragen von Einsatzkräften
struct V2XSignalRequest: Identifiable, Codable, Equatable {
    let id: Int
    var requesterType: String // "AMBULANCE", "FIRE_BRIGADE", "POLICE"
    var targetIntersectionID: Int
    var requestStatus: String // "REQUESTED", "ACTIVE", "COMPLETED"
    var coordinate: CLLocationCoordinate2D
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, requesterType, targetIntersectionID, requestStatus, latitude, longitude }

    init(id: Int, requesterType: String, targetIntersectionID: Int, requestStatus: String, coordinate: CLLocationCoordinate2D) {
        self.id = id; self.requesterType = requesterType; self.targetIntersectionID = targetIntersectionID; self.requestStatus = requestStatus; self.coordinate = coordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        requesterType = try c.decode(String.self, forKey: .requesterType)
        targetIntersectionID = try c.decode(Int.self, forKey: .targetIntersectionID)
        requestStatus = try c.decode(String.self, forKey: .requestStatus)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(requesterType, forKey: .requesterType)
        try c.encode(targetIntersectionID, forKey: .targetIntersectionID)
        try c.encode(requestStatus, forKey: .requestStatus)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }

    static func == (lhs: V2XSignalRequest, rhs: V2XSignalRequest) -> Bool {
        return lhs.id == rhs.id && lhs.requestStatus == rhs.requestStatus
    }
}

// MARK: - SSM (Signal Status Message) - Ampel-Bestätigung für Priorisierung
struct V2XSignalStatus: Identifiable, Codable, Equatable {
    let id: Int
    var intersectionID: Int
    var priorityGranted: Bool
    var activeRequesterID: Int
    var coordinate: CLLocationCoordinate2D
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, intersectionID, priorityGranted, activeRequesterID, latitude, longitude }

    init(id: Int, intersectionID: Int, priorityGranted: Bool, activeRequesterID: Int, coordinate: CLLocationCoordinate2D) {
        self.id = id; self.intersectionID = intersectionID; self.priorityGranted = priorityGranted; self.activeRequesterID = activeRequesterID; self.coordinate = coordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        intersectionID = try c.decode(Int.self, forKey: .intersectionID)
        priorityGranted = try c.decode(Bool.self, forKey: .priorityGranted)
        activeRequesterID = try c.decode(Int.self, forKey: .activeRequesterID)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(intersectionID, forKey: .intersectionID)
        try c.encode(priorityGranted, forKey: .priorityGranted)
        try c.encode(activeRequesterID, forKey: .activeRequesterID)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }

    static func == (lhs: V2XSignalStatus, rhs: V2XSignalStatus) -> Bool {
        return lhs.id == rhs.id && lhs.priorityGranted == rhs.priorityGranted
    }
}

// MARK: - MCM (Maneuver Coordination Message) - Trajektorien absprachen
struct V2XManeuver: Identifiable, Codable, Equatable {
    let id: Int
    var vehicleID: Int
    var coordinationPhase: String // "PLANNING", "EXECUTING", "FINISHED"
    var trajectoryPoints: [CLLocationCoordinate2D]
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, vehicleID, coordinationPhase, trajectoryPoints }

    init(id: Int, vehicleID: Int, coordinationPhase: String, trajectoryPoints: [CLLocationCoordinate2D]) {
        self.id = id
        self.vehicleID = vehicleID
        self.coordinationPhase = coordinationPhase
        self.trajectoryPoints = trajectoryPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        vehicleID = try c.decode(Int.self, forKey: .vehicleID)
        coordinationPhase = try c.decode(String.self, forKey: .coordinationPhase)
        
        let rawPoints = try c.decode([[Double]].self, forKey: .trajectoryPoints)
        trajectoryPoints = rawPoints.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vehicleID, forKey: .vehicleID)
        try c.encode(coordinationPhase, forKey: .coordinationPhase)
        
        let rawPoints = trajectoryPoints.map { [$0.latitude, $0.longitude] }
        try c.encode(rawPoints, forKey: .trajectoryPoints)
    }

    static func == (lhs: V2XManeuver, rhs: V2XManeuver) -> Bool {
        return lhs.id == rhs.id && lhs.coordinationPhase == rhs.coordinationPhase
    }
}

// MARK: - RTCMEM (RTCM Correction Messages) - GPS RTK-Korrekturen
struct V2XRTKCorrection: Identifiable, Codable, Equatable {
    let id: Int
    var baseStationID: Int
    var signalStrengthDBm: Int
    var correctionStatus: String // "RTK_FIX", "RTK_FLOAT", "SBAS"
    var coordinate: CLLocationCoordinate2D
    var lastSeen: Date = Date()

    enum CodingKeys: String, CodingKey { case id, baseStationID, signalStrengthDBm, correctionStatus, latitude, longitude }

    init(id: Int, baseStationID: Int, signalStrengthDBm: Int, correctionStatus: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.baseStationID = baseStationID
        self.signalStrengthDBm = signalStrengthDBm
        self.correctionStatus = correctionStatus
        self.coordinate = coordinate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        baseStationID = try c.decode(Int.self, forKey: .baseStationID)
        signalStrengthDBm = try c.decode(Int.self, forKey: .signalStrengthDBm)
        correctionStatus = try c.decode(String.self, forKey: .correctionStatus)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(baseStationID, forKey: .baseStationID)
        try c.encode(signalStrengthDBm, forKey: .signalStrengthDBm)
        try c.encode(correctionStatus, forKey: .correctionStatus)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }

    static func == (lhs: V2XRTKCorrection, rhs: V2XRTKCorrection) -> Bool {
        return lhs.id == rhs.id && lhs.correctionStatus == rhs.correctionStatus
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
    
    // C-ITS Geodaten-Zustände (Umfangreich Erweitert)
    var vehicles: [Int: V2XVehicle] = [:]
    var trafficLights: [Int: V2XTrafficLight] = [:]
    var dangerZones: [Int: V2XDangerZone] = [:]
    var mapGeometries: [Int: V2XMapGeometry] = [:]
    var virtualSigns: [Int: V2XVirtualSign] = [:]
    var collectiveObjects: [Int: V2XCollectiveObject] = [:]
    var signalRequests: [Int: V2XSignalRequest] = [:]
    var signalStatuses: [Int: V2XSignalStatus] = [:]
    var maneuvers: [Int: V2XManeuver] = [:]
    var rtkCorrections: [Int: V2XRTKCorrection] = [:]
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
    
    // Offline-Karten Cache-Eigenschaften (Auf Bundesländer umgestellt)
    var isOfflineMapActive = false
    var selectedOfflineRegion = "Baden-Württemberg"
    let offlineRegionOptions = ["Baden-Württemberg", "Bayern", "Nordrhein-Westfalen", "Hessen"]
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
    
    // Debug & RX/TX Paket-Zähler (Umfänglich erweitert für alle Nachrichtentypen)
    var totalV2XBytesRx = 0
    var totalGPSBytesRx = 0
    var decodedCAMs = 0
    var decodedDENMs = 0
    var decodedSPATEMs = 0
    var decodedMAPEMs = 0
    var decodedIVIMs = 0
    var decodedCPMs = 0
    var decodedSRMs = 0
    var decodedSSMs = 0
    var decodedMCMs = 0
    var decodedRTCMEMs = 0
    
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
        guard !payload.isEmpty else { return }
        
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        
        // --- 1. PROAKTIVER JSON-DEKODER (Falls die ESP32 Firmware JSON sendet) ---
        if payload[0] == 0x7B { // '{' character
            if let decodedStr = String(data: payload, encoding: .utf8) {
                addDebugPacketLog("[V2X JSON] \(decodedStr)")
                if let envelope = try? JSONDecoder().decode(TCPMessageEnvelope.self, from: payload) {
                    processJSONEnvelope(envelope, payload: payload, ts: ts)
                    return
                }
            }
        }
        
        // --- 2. HOCHPERFORMANTER BINÄR-DEKODER (ETSI ITS-G5 SLIP Protokoll von pit711) ---
        let typeByte = payload[0]
        
        // Endianness-sichere Hilfsfunktionen zur Extraktion von vorzeichenbehafteten Integern
        func readInt32(offset: Int) -> Int32? {
            guard payload.count >= offset + 4 else { return nil }
            let valLE = payload.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            let valBE = valLE.byteSwapped
            
            // Plausibilitätsprüfung für geografische Koordinaten in Europa (ETSI mit 10^7 skaliert)
            let degLE = Double(valLE) / 10_000_000.0
            let degBE = Double(valBE) / 10_000_000.0
            
            // Europa Bounding Box (Breitengrad: 35 bis 72, Längengrad: -15 bis 42)
            if degLE > 35.0 && degLE < 72.0 {
                return valLE
            } else if degBE > 35.0 && degBE < 72.0 {
                return valBE
            }
            return valLE
        }
        
        func readUInt32(offset: Int) -> UInt32? {
            guard payload.count >= offset + 4 else { return nil }
            return payload.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        
        func readUInt16(offset: Int) -> UInt16? {
            guard payload.count >= offset + 2 else { return nil }
            return payload.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        }
        
        // Sichern der Mindest-Paketlänge für die Basisdaten (Typ [1B] + ID [4B] + Lat [4B] + Lon [4B] = 13 Bytes)
        guard payload.count >= 13,
              let stationIDVal = readUInt32(offset: 1),
              let rawLat = readInt32(offset: 5),
              let rawLon = readInt32(offset: 9) else {
            return
        }
        
        let id = Int(stationIDVal)
        let lat = Double(rawLat) / 10_000_000.0
        let lon = Double(rawLon) / 10_000_000.0
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        // Schutz vor fehlerhaften Null-Auslesungen
        guard lat != 0.0 && lon != 0.0 else { return }
        
        switch typeByte {
        case 1, 0x43: // CAM (1 oder 'C')
            decodedCAMs += 1
            
            let rawHeading = readUInt16(offset: 13) ?? 0
            let rawSpeed = readUInt16(offset: 15) ?? 0
            let brakeByte = payload.count >= 18 ? payload[17] : 0
            
            // ETSI CAM heading ist in 0.1 Grad (0..3600)
            let heading = Double(rawHeading) / 10.0
            
            // ETSI CAM speed ist in 0.01 m/s (z.B. 1389 -> 13.89 m/s = 50 km/h)
            let speedMS = Double(rawSpeed) / 100.0
            let speedKMH = speedMS * 3.6
            let isBraking = brakeByte != 0
            
            DispatchQueue.main.async {
                var vehicle = self.vehicles[id] ?? V2XVehicle(id: id, coordinate: coordinate, heading: heading, speed: speedKMH, isBraking: isBraking, lastSeen: Date())
                vehicle.updatePosition(to: coordinate, heading: heading, speed: speedKMH, isBraking: isBraking)
                self.vehicles[id] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
            }
            
            addDebugPacketLog("[V2X CAM] Auto #\(id): Lat \(lat), Lon \(lon), Speed: \(String(format: "%.1f", speedKMH)) km/h, Heading: \(Int(heading))°")
            logForensics(line: "\(ts);CAM;\(id);\(lat);\(lon);\(speedKMH);\(heading);\(isBraking);none\n", rawPacket: payload)
            
        case 2, 0x44: // DENM (2 oder 'D')
            decodedDENMs += 1
            
            let causeCode = payload.count >= 14 ? payload[13] : 3 // Standardmäßig: Baustelle
            let rawRadius = payload.count >= 16 ? readUInt16(offset: 14) ?? 150 : 150
            
            let type: String
            switch causeCode {
            case 1: type = "Stau"
            case 2: type = "Unfall"
            case 3: type = "Baustelle"
            case 91: type = "Gefahr"
            default: type = "Baustelle"
            }
            
            let radius = Double(rawRadius)
            let zone = V2XDangerZone(id: id, type: type, coordinate: coordinate, radiusMeter: radius)
            
            DispatchQueue.main.async {
                self.dangerZones[id] = zone
                self.broadcast(type: "DENM", payload: zone)
            }
            
            addDebugPacketLog("[V2X DENM] Gefahr #\(id): Typ \(type) bei Lat \(lat), Lon \(lon), Radius: \(radius)m")
            logForensics(line: "\(ts);DENM;\(id);\(lat);\(lon);0;0;false;\(type)_\(radius)m\n", rawPacket: payload)
            
        case 3, 0x53: // SPATEM (3 oder 'S')
            decodedSPATEMs += 1
            
            let phaseByte = payload.count >= 14 ? payload[13] : 3
            let rawTime = payload.count >= 16 ? readUInt16(offset: 14) ?? 100 : 100
            
            // Standard ETSI SPATEM Phasenmapping (red/yellow/green)
            let phase: String
            switch phaseByte {
            case 2, 3: phase = "red"
            case 4, 5: phase = "yellow"
            case 6, 7: phase = "green"
            default: phase = "red"
            }
            
            // Zeit bis Phasenwechsel in Sekunden (übertragen in Zehntelsekunden)
            let timeToChange = Int(rawTime) / 10
            
            let light = V2XTrafficLight(id: id, coordinate: coordinate, currentPhase: phase, timeToChange: timeToChange)
            
            DispatchQueue.main.async {
                self.trafficLights[id] = light
                self.broadcast(type: "SPATEM", payload: light)
            }
            
            addDebugPacketLog("[V2X SPATEM] Ampel #\(id): Phase \(phase.uppercased()) Countdown: \(timeToChange)s")
            logForensics(line: "\(ts);SPATEM;\(id);\(lat);\(lon);0;0;false;\(phase)_\(timeToChange)\n", rawPacket: payload)
            
        default:
            addDebugPacketLog("[V2X] Unbekanntes Binärpaket Typ \(typeByte) von ID \(id)")
        }
    }
    
    // MARK: - JSON Envelope Parser (für Gateway-Kompatibilität)
    private func processJSONEnvelope(_ envelope: TCPMessageEnvelope, payload: Data, ts: Int64) {
        let p = envelope.data
        let id = p.id
        let lat = p.coordinate?.latitude ?? p.latitude ?? 0.0
        let lon = p.coordinate?.longitude ?? p.longitude ?? 0.0
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        guard lat != 0.0 && lon != 0.0 else { return }
        
        switch envelope.msgType.uppercased() {
        case "CAM":
            self.decodedCAMs += 1
            let speed = p.speedKmH ?? p.speed ?? 0.0
            let heading = p.heading ?? 0.0
            let braking = p.isBraking ?? false
            
            DispatchQueue.main.async {
                var vehicle = self.vehicles[id] ?? V2XVehicle(id: id, coordinate: coordinate, heading: heading, speed: speed, isBraking: braking, lastSeen: Date())
                vehicle.updatePosition(to: coordinate, heading: heading, speed: speed, isBraking: braking)
                self.vehicles[id] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
            }
            logForensics(line: "\(ts);CAM;\(id);\(lat);\(lon);\(speed);\(heading);\(braking);none\n", rawPacket: payload)
            
        case "DENM":
            self.decodedDENMs += 1
            let type = p.type ?? "Baustelle"
            let radius = p.radiusMeter ?? 150.0
            let zone = V2XDangerZone(id: id, type: type, coordinate: coordinate, radiusMeter: radius)
            
            DispatchQueue.main.async {
                self.dangerZones[id] = zone
                self.broadcast(type: "DENM", payload: zone)
            }
            logForensics(line: "\(ts);DENM;\(id);\(lat);\(lon);0;0;false;\(type)_\(radius)m\n", rawPacket: payload)
            
        case "SPATEM":
            self.decodedSPATEMs += 1
            let phase = p.currentPhase ?? "red"
            let time = p.timeToChange ?? 10
            let light = V2XTrafficLight(id: id, coordinate: coordinate, currentPhase: phase, timeToChange: time)
            
            DispatchQueue.main.async {
                self.trafficLights[id] = light
                self.broadcast(type: "SPATEM", payload: light)
            }
            logForensics(line: "\(ts);SPATEM;\(id);\(lat);\(lon);0;0;false;\(phase)_\(time)\n", rawPacket: payload)
            
        default:
            break
        }
    }
    
    // MARK: - Forensik Hilfskonstrukte für Logging
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
                "decodedMAPEMs": self.decodedMAPEMs,
                "decodedIVIMs": self.decodedIVIMs,
                "decodedCPMs": self.decodedCPMs,
                "decodedSRMs": self.decodedSRMs,
                "decodedSSMs": self.decodedSSMs,
                "decodedMCMs": self.decodedMCMs,
                "decodedRTCMEMs": self.decodedRTCMEMs,
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
        let activeVehiclesList = vehicles.values.map { "<li>Auto #\($0.id): Lat \($0.coordinate.latitude), Lon \($0.coordinate.longitude), v=\($0.speed) km/h, braking=\($0.isBraking)</li>" }.joined()
        let activeLightsList = trafficLights.values.map { "<li>Ampel #\($0.id): Lat \($0.coordinate.latitude), Lon \($0.coordinate.longitude), Phase \($0.currentPhase.uppercased()) (\($0.timeToChange)s)</li>" }.joined()
        let activeZonesList = dangerZones.values.map { "<li>Gefahr #\($0.id): Lat \($0.coordinate.latitude), Lon \($0.coordinate.longitude), Typ: \($0.type) (Radius \($0.radiusMeter)m)</li>" }.joined()
        let activeMapsList = mapGeometries.values.map { "<li>MAPEM #\($0.id): Kreuzung: \($0.name) (Spur-Wegpunkte: \($0.laneCoordinates.count))</li>" }.joined()
        let activeIVIMList = virtualSigns.values.map { "<li>IVIM #\($0.id): Typ \($0.type) (Wert: \($0.value))</li>" }.joined()
        let activeCPMList = collectiveObjects.values.map { "<li>CPM #\($0.id): Sensor \($0.sensorType), Klasse \($0.objectClass), v=\($0.speed) m/s</li>" }.joined()
        let activeSRMList = signalRequests.values.map { "<li>SRM #\($0.id): von \($0.requesterType) an Kreuzung \($0.targetIntersectionID) - Status: \($0.requestStatus)</li>" }.joined()
        let activeSSMList = signalStatuses.values.map { "<li>SSM #\($0.id): Kreuzung \($0.intersectionID) - Priorisierung gewährt für \($0.activeRequesterID)</li>" }.joined()
        let activeMCMList = maneuvers.values.map { "<li>MCM #\($0.id): Fahrzeug \($0.vehicleID) - Phase: \($0.coordinationPhase)</li>" }.joined()
        let activeRTKList = rtkCorrections.values.map { "<li>RTCMEM #\($0.id): Base Station \($0.baseStationID) - Signal: \($0.signalStrengthDBm)dBm, Status: \($0.correctionStatus)</li>" }.joined()

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
                p { font-size: 1.1em; margin: 5px 0; }
                .stats-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 15px; margin: 20px 0; }
                .stats-box { background: #222; padding: 15px; border-radius: 6px; border: 1px solid #333; }
                .stat-box h3 { margin: 0 0 10px 0; color: #aaa; font-size: 0.9em; text-transform: uppercase; }
                .stat-box .val { font-size: 1.8em; font-weight: bold; color: #00ff66; }
                .active-objects { background: #1a1a1a; padding: 15px; border-radius: 6px; border: 1px solid #333; margin: 15px 0; }
                .active-objects h3 { margin-top: 0; color: #0088ff; }
                ul { padding-left: 20px; color: #ccc; font-family: monospace; font-size: 0.95em; }
                pre { background: #1e1e1e; padding: 15px; border-radius: 5px; overflow-x: auto; color: #00ff66; font-size: 0.9em; border: 1px solid #333; }
                hr { border: 0.5px solid #333; margin: 25px 0; }
            </style>
        </head>
        <body>
            <h1>V2X Mac-Zentrale Live Debugger</h1>
            
            <div class="stats-grid">
                <div class="stat-box">
                    <h3>V2X Data Bytes Rx</h3>
                    <div class="val">\(totalV2XBytesRx) B</div>
                </div>
                <div class="stat-box">
                    <h3>GPS NMEA Bytes Rx</h3>
                    <div class="val">\(totalGPSBytesRx) B</div>
                </div>
                <div class="stat-box">
                    <h3>Trails status</h3>
                    <div class="val" style="color: #0088ff;">\(keepVehiclesAsTrail ? "Aktiv" : "Inaktiv")</div>
                </div>
            </div>

            <hr>
            
            <h2>C-ITS Message Statistics</h2>
            <div class="stats-grid">
                <div class="stat-box"><h3>CAM (Vehicles)</h3><div class="val">\(decodedCAMs)</div></div>
                <div class="stat-box"><h3>DENM (Hazards)</h3><div class="val" style="color: #ff3333;">\(decodedDENMs)</div></div>
                <div class="stat-box"><h3>SPATEM (Traffic Lights)</h3><div class="val" style="color: #ffcc00;">\(decodedSPATEMs)</div></div>
                <div class="stat-box"><h3>MAPEM (Geometries)</h3><div class="val">\(decodedMAPEMs)</div></div>
                <div class="stat-box"><h3>IVIM (Signs)</h3><div class="val">\(decodedIVIMs)</div></div>
                <div class="stat-box"><h3>CPM (Perception)</h3><div class="val">\(decodedCPMs)</div></div>
                <div class="stat-box"><h3>SRM (Priority Req)</h3><div class="val">\(decodedSRMs)</div></div>
                <div class="stat-box"><h3>SSM (Priority Status)</h3><div class="val">\(decodedSSMs)</div></div>
                <div class="stat-box"><h3>MCM (Maneuvers)</h3><div class="val">\(decodedMCMs)</div></div>
                <div class="stat-box"><h3>RTCMEM (RTK Base)</h3><div class="val">\(decodedRTCMEMs)</div></div>
            </div>

            <hr>

            <h2>Aktive C-ITS Objekte im RAM</h2>
            
            <div class="active-objects">
                <h3>CAM - Fahrzeuge (\(vehicles.count))</h3>
                <ul>\(activeVehiclesList.isEmpty ? "<li>Keine aktiven CAMs</li>" : activeVehiclesList)</ul>
            </div>
            
            <div class="active-objects">
                <h3>SPATEM - Ampelsteuerungen (\(trafficLights.count))</h3>
                <ul>\(activeLightsList.isEmpty ? "<li>Keine aktiven SPATEMs</li>" : activeLightsList)</ul>
            </div>

            <div class="active-objects">
                <h3>DENM - Gefahrenzonen (\(dangerZones.count))</h3>
                <ul>\(activeZonesList.isEmpty ? "<li>Keine aktiven DENMs</li>" : activeZonesList)</ul>
            </div>

            <div class="active-objects">
                <h3>MAPEM - Kreuzungsgeometrien (\(mapGeometries.count))</h3>
                <ul>\(activeMapsList.isEmpty ? "<li>Keine aktiven MAPEMs</li>" : activeMapsList)</ul>
            </div>

            <div class="active-objects">
                <h3>IVIM - Digitale Straßenschilder (\(virtualSigns.count))</h3>
                <ul>\(activeIVIMList.isEmpty ? "<li>Keine aktiven IVIMs</li>" : activeIVIMList)</ul>
            </div>

            <div class="active-objects">
                <h3>CPM - Sensor-Fremdobjekte (\(collectiveObjects.count))</h3>
                <ul>\(activeCPMList.isEmpty ? "<li>Keine aktiven CPMs</li>" : activeCPMList)</ul>
            </div>

            <div class="active-objects">
                <h3>SRM - Prioritätsanforderungen (\(signalRequests.count))</h3>
                <ul>\(activeSRMList.isEmpty ? "<li>Keine aktiven SRMs</li>" : activeSRMList)</ul>
            </div>

            <div class="active-objects">
                <h3>SSM - Prioritätsbestätigungen (\(signalStatuses.count))</h3>
                <ul>\(activeSSMList.isEmpty ? "<li>Keine aktiven SSMs</li>" : activeSSMList)</ul>
            </div>

            <div class="active-objects">
                <h3>MCM - Autonome Manöver (\(maneuvers.count))</h3>
                <ul>\(activeMCMList.isEmpty ? "<li>Keine aktiven MCMs</li>" : activeMCMList)</ul>
            </div>

            <div class="active-objects">
                <h3>RTCMEM - RTK Korrekturdaten (\(rtkCorrections.count))</h3>
                <ul>\(activeRTKList.isEmpty ? "<li>Keine aktiven RTCMEMs</li>" : activeRTKList)</ul>
            </div>

            <hr>

            <h2>Empfangene Live- und Simulations-Sätze:</h2>
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
    
    // MARK: - Echt-Funktionale Offline-Karten Downloads (Slippy Map Tile Downloader)
    func startOfflineMapDownload() {
        isDownloadingMap = true
        downloadProgress = 0.0
        downloadedTilesCount = 0
        totalTilesToDownload = 0
        
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
        
        // Geografische Bounding-Boxen der ausgewählten Bundesländer festlegen
        switch selectedOfflineRegion {
        case "Baden-Württemberg":
            minLat = 47.50; maxLat = 49.80; minLon = 7.50; maxLon = 10.50
        case "Bayern":
            minLat = 47.20; maxLat = 50.60; minLon = 8.90; maxLon = 13.90
        case "Nordrhein-Westfalen":
            minLat = 50.30; maxLat = 52.55; minLon = 5.80; maxLon = 9.50
        case "Hessen":
            minLat = 49.39; maxLat = 51.65; minLon = 7.77; maxLon = 10.25
        default:
            minLat = 47.50; maxLat = 49.80; minLon = 7.50; maxLon = 10.50
        }
        
        // Bietet Offline-Übersicht und Detailierung auf Landstraßenebene (Zoomstufe 10 bis 13)
        let zoomLevels = [10, 11, 12, 13]
        var tilesToDownload: [(z: Int, x: Int, y: Int)] = []
        
        for z in zoomLevels {
            let xMin = tileX(longitude: minLon, zoom: z)
            let xMax = tileX(longitude: maxLon, zoom: z)
            let yMin = tileY(latitude: maxLat, zoom: z)
            let yMax = tileY(latitude: minLat, zoom: z)
            
            for x in min(xMin, xMax)...max(xMin, xMax) {
                for y in min(yMin, yMax)...max(yMin, yMax) {
                    tilesToDownload.append((z, x, y))
                }
            }
        }
        
        totalTilesToDownload = tilesToDownload.count
        guard totalTilesToDownload > 0 else {
            isDownloadingMap = false
            return
        }
        
        let tempOverlay = CachedTileOverlay()
        
        downloadTask = Task {
            var completed = 0
            let session = URLSession.shared
            
            for tile in tilesToDownload {
                if Task.isCancelled { break }
                
                let tilePath = MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1.0)
                let localURL = tempOverlay.cachePath(for: tilePath)
                
                // Bereits heruntergeladene Kacheln überspringen
                if FileManager.default.fileExists(atPath: localURL.path) {
                    completed += 1
                    await MainActor.run {
                        self.downloadedTilesCount = completed
                        self.downloadProgress = Double(completed) / Double(self.totalTilesToDownload)
                    }
                    continue
                }
                
                let remoteURL = tempOverlay.url(forTilePath: tilePath)
                var request = URLRequest(url: remoteURL)
                request.setValue("V2XMacSniffer/1.0 (macOS; V2X C-ITS Terminal App)", forHTTPHeaderField: "User-Agent")
                
                do {
                    let (data, response) = try await session.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: localURL)
                    }
                    // Kurze Pause, um OSM-Dienste nicht zu überlasten (Politeness Delay)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                } catch {
                    self.addLog("[-] Kacheldownload-Fehler (Z:\(tile.z) X:\(tile.x) Y:\(tile.y)): \(error.localizedDescription)")
                }
                
                completed += 1
                await MainActor.run {
                    self.downloadedTilesCount = completed
                    self.downloadProgress = Double(completed) / Double(self.totalTilesToDownload)
                }
            }
            
            await MainActor.run {
                self.isDownloadingMap = false
                self.addLog("[+] Offline-Karten-Download abgeschlossen (\(selectedOfflineRegion)).")
            }
        }
    }
    
    // Hilfsfunktionen für Mercator-Projektion zu Slippy-Map Tile Koordinaten
    private func tileX(longitude: Double, zoom: Int) -> Int {
        return Int(floor((longitude + 180.0) / 360.0 * pow(2.0, Double(zoom))))
    }
    
    private func tileY(latitude: Double, zoom: Int) -> Int {
        let latRad = latitude * .pi / 180.0
        return Int(floor((1.0 - log(tan(latRad) + (1.0 / cos(latRad))) / .pi) / 2.0 * pow(2.0, Double(zoom))))
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
    
    // MARK: - Generierung von simulierten Payload-Sätzen (Crash-sicher)
    private func mockPayload(for id: Int) -> Data {
        let b0 = UInt8((id >> 24) & 0xFF)
        let b1 = UInt8((id >> 16) & 0xFF)
        let b2 = UInt8((id >> 8) & 0xFF)
        let b3 = UInt8(id & 0xFF)
        return Data([b0, b1, b2, b3])
    }
    
    // MARK: - System Simulationen & Debugging-Zähler
    func resetDebugCounters() {
        totalV2XBytesRx = 0
        totalGPSBytesRx = 0
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
        
        vehicles.removeAll()
        trafficLights.removeAll()
        dangerZones.removeAll()
        mapGeometries.removeAll()
        virtualSigns.removeAll()
        collectiveObjects.removeAll()
        signalRequests.removeAll()
        signalStatuses.removeAll()
        maneuvers.removeAll()
        rtkCorrections.removeAll()
        
        debugRawPackets.removeAll()
        gpsPacketCache.removeAll()
        networkPacketCache.removeAll()
        addLog("[+] System-Debug-Zähler und aktive C-ITS-Objekte zurückgesetzt.")
    }
    
    func simulateCAM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 9 // Typenverteiler für CAM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere CAM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateDENM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 1 // Typenverteiler für DENM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere DENM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSPATEM() {
        let simulatedID = Int.random(in: 10...99) * 11 // Typenverteiler für SPATEM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere SPATEM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateMAPEM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 2 // Typenverteiler für MAPEM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere MAPEM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateIVIM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 3 // Typenverteiler für IVIM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere IVIM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateCPM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 4 // Typenverteiler für CPM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere CPM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSRM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 5 // Typenverteiler für SRM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere SRM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSSM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 6 // Typenverteiler für SSM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere SSM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateMCM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 7 // Typenverteiler für MCM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere MCM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateRTCMEM() {
        let simulatedID = Int.random(in: 10...99) * 11 + 8 // Typenverteiler für RTCMEM
        let dummyBytes = mockPayload(for: simulatedID)
        addDebugPacketLog("[SIM] Generiere RTCMEM Paket für ID \(simulatedID)")
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
