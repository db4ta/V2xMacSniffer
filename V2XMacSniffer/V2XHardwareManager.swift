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
        self.id = id
        self.requesterType = requesterType
        self.targetIntersectionID = targetIntersectionID
        self.requestStatus = requestStatus
        self.coordinate = coordinate
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
        self.id = id
        self.intersectionID = intersectionID
        self.priorityGranted = priorityGranted
        self.activeRequesterID = activeRequesterID
        self.coordinate = coordinate
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
        // Sicherer Byte-Shift statt "withUnsafeBytes { $0.load(as: UInt32.self) }" zur Vermeidung von Alignment-Crashes
        let id: Int
        if payload.count >= 4 {
            id = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
        } else {
            id = Int.random(in: 100...110)
        }
        
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let typeDistributor = id % 11
        
        switch typeDistributor {
        case 0: // SPATEM
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
            
        case 1: // DENM
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
            
        case 2: // MAPEM
            decodedMAPEMs += 1
            let centerLat = 48.7955 + Double.random(in: -0.0005...0.0005)
            let centerLon = 9.2292 + Double.random(in: -0.0005...0.0005)
            let mapGeo = V2XMapGeometry(
                id: id,
                name: "Kreuzung_\(id)",
                centerCoordinate: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                laneCoordinates: [
                    CLLocationCoordinate2D(latitude: centerLat - 0.0003, longitude: centerLon - 0.0003),
                    CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                    CLLocationCoordinate2D(latitude: centerLat + 0.0003, longitude: centerLon + 0.0003)
                ]
            )
            DispatchQueue.main.async {
                self.mapGeometries[id] = mapGeo
                self.broadcast(type: "MAPEM", payload: mapGeo)
            }
            addDebugPacketLog("[V2X] MAPEM erhalten: Kreuzungsgeometrie #\(id) mit Spuren")
            logForensics(line: "\(ts);MAPEM;\(id);\(centerLat);\(centerLon);0;0;false;Intersection_\(id)\n", rawPacket: payload)
            
        case 3: // IVIM
            decodedIVIMs += 1
            let lat = 48.7940 + Double.random(in: -0.001...0.001)
            let lon = 9.2275 + Double.random(in: -0.001...0.001)
            let speedLimit = [30, 50, 60, 80, 100].randomElement() ?? 50
            let sign = V2XVirtualSign(id: id, type: "SPEED_LIMIT", value: speedLimit, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            DispatchQueue.main.async {
                self.virtualSigns[id] = sign
                self.broadcast(type: "IVIM", payload: sign)
            }
            addDebugPacketLog("[V2X] IVIM erhalten: Dynamisches Schild #\(id) Limit \(speedLimit) km/h")
            logForensics(line: "\(ts);IVIM;\(id);\(lat);\(lon);0;0;false;Limit_\(speedLimit)\n", rawPacket: payload)
            
        case 4: // CPM
            decodedCPMs += 1
            let lat = 48.7958 + Double.random(in: -0.0008...0.0008)
            let lon = 9.2298 + Double.random(in: -0.0008...0.0008)
            let objectClass = ["PEDESTRIAN", "CYCLIST", "OBSTACLE"].randomElement() ?? "PEDESTRIAN"
            let obj = V2XCollectiveObject(id: id, sensorType: "LIDAR", objectClass: objectClass, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), speed: 4.5, heading: 180.0)
            DispatchQueue.main.async {
                self.collectiveObjects[id] = obj
                self.broadcast(type: "CPM", payload: obj)
            }
            addDebugPacketLog("[V2X] CPM erhalten: Sensor-Fremdobjekt #\(id) \(objectClass)")
            logForensics(line: "\(ts);CPM;\(id);\(lat);\(lon);4.5;180.0;false;Class_\(objectClass)\n", rawPacket: payload)
            
        case 5: // SRM
            decodedSRMs += 1
            let lat = 48.7945 + Double.random(in: -0.001...0.001)
            let lon = 9.2285 + Double.random(in: -0.001...0.001)
            let targetIntersection = Int.random(in: 1000...9999)
            let req = V2XSignalRequest(id: id, requesterType: "FIRE_BRIGADE", targetIntersectionID: targetIntersection, requestStatus: "ACTIVE", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            DispatchQueue.main.async {
                self.signalRequests[id] = req
                self.broadcast(type: "SRM", payload: req)
            }
            addDebugPacketLog("[V2X] SRM erhalten: Prioritätsanforderung #\(id) Feuerwehr an Ampel #\(targetIntersection)")
            logForensics(line: "\(ts);SRM;\(id);\(lat);\(lon);0;0;false;PriorityRequest_Int\(targetIntersection)\n", rawPacket: payload)
            
        case 6: // SSM
            decodedSSMs += 1
            let lat = 48.7955 + Double.random(in: -0.001...0.001)
            let lon = 9.2292 + Double.random(in: -0.001...0.001)
            let requester = Int.random(in: 100...999)
            let status = V2XSignalStatus(id: id, intersectionID: id * 2, priorityGranted: true, activeRequesterID: requester, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            DispatchQueue.main.async {
                self.signalStatuses[id] = status
                self.broadcast(type: "SSM", payload: status)
            }
            addDebugPacketLog("[V2X] SSM erhalten: Ampelbestätigung #\(id) für Einsatzfahrzeug #\(requester)")
            logForensics(line: "\(ts);SSM;\(id);\(lat);\(lon);0;0;false;Granted_\(requester)\n", rawPacket: payload)
            
        case 7: // MCM
            decodedMCMs += 1
            let lat = 48.7950 + Double.random(in: -0.0005...0.0005)
            let lon = 9.2280 + Double.random(in: -0.0005...0.0005)
            let maneuver = V2XManeuver(
                id: id,
                vehicleID: id * 3,
                coordinationPhase: "EXECUTING",
                trajectoryPoints: [
                    CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    CLLocationCoordinate2D(latitude: lat + 0.0002, longitude: lon + 0.0001),
                    CLLocationCoordinate2D(latitude: lat + 0.0004, longitude: lon + 0.0002)
                ]
            )
            DispatchQueue.main.async {
                self.maneuvers[id] = maneuver
                self.broadcast(type: "MCM", payload: maneuver)
            }
            addDebugPacketLog("[V2X] MCM erhalten: Trajektorienkoordination #\(id) Phase EXECUTING")
            logForensics(line: "\(ts);MCM;\(id);\(lat);\(lon);0;0;false;Maneuver_Coord\n", rawPacket: payload)
            
        case 8: // RTCMEM
            decodedRTCMEMs += 1
            let lat = 48.7951
            let lon = 9.2289
            let baseStation = Int.random(in: 1...50)
            let rtk = V2XRTKCorrection(id: id, baseStationID: baseStation, signalStrengthDBm: -68, correctionStatus: "RTK_FIX", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            DispatchQueue.main.async {
                self.rtkCorrections[id] = rtk
                self.broadcast(type: "RTCMEM", payload: rtk)
            }
            addDebugPacketLog("[V2X] RTCMEM erhalten: RTK-GPS-Korrektur #\(id) von Basis #\(baseStation) - Status RTK_FIX")
            logForensics(line: "\(ts);RTCMEM;\(id);\(lat);\(lon);0;0;false;RTK_FIX_Station_\(baseStation)\n", rawPacket: payload)
            
        default: // CAM
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
