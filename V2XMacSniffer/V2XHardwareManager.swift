import Foundation
import CoreLocation
import Network
import AppKit
import MapKit
import OSLog
import UniformTypeIdentifiers
import SwiftUI
import SQLite3

// MARK: - LogEntry Modell
/// Repräsentiert einen einzelnen Log-Eintrag innerhalb der Applikation samt Zeitstempel und einer eindeutigen ID für Listenschlüssel.
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

// MARK: - JSON Netzwerk-Protokoll Hilfsmodelle
/// Ein Umschlag-Objekt für JSON-basierte V2X/C-ITS Datenpakete aus dem TCP-Netzwerkstrom.
struct TCPMessageEnvelope: Codable {
    let msgType: String
    let data: TCPMessageData
}

/// Enthält alle optionalen Attribute, die in den verschiedenen C-ITS Nachrichten übertragen werden können.
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
    let type: String?                // Für DENM (Gefahrenzonen) und IVIM (Verkehrsschilder)
    let value: Int?                  // Für IVIM (z.B. Geschwindigkeitsbegrenzung)
    let radiusMeter: Double?
    let name: String?                // Für MAPEM (Kreuzungsname)
    let laneCoordinates: [CoordinateHelper]? // Für MAPEM (Fahrspuren)
    let sensorType: String?          // Für CPM (Sensortyp)
    let objectClass: String?         // Für CPM (Objektklasse wie Fußgänger/Radfahrer)
    let requesterType: String?       // Für SRM (Einsatzfahrzeugtyp)
    let targetIntersectionID: Int?   // Für SRM (Ziel-Kreuzung)
    let requestStatus: String?       // Für SRM (Status)
    let intersectionID: Int?         // Für SSM (Kreuzungs-ID)
    let priorityGranted: Bool?       // Für SSM (Priorisierung gewährt/abgelehnt)
    let activeRequesterID: Int?      // Für SSM (Aktive ID)
    let coordinationPhase: String?   // Für MCM (Planungsphase)
    let trajectoryPoints: [CoordinateHelper]? // Für MCM (Trajektorien)
    let baseStationID: Int?          // Für RTCMEM (Basisstation)
    let signalStrengthDBm: Int?      // Für RTCMEM (Signalstärke)
    let correctionStatus: String?    // Für RTCMEM (RTK-Status)
    
    struct CoordinateHelper: Codable {
        let latitude: Double
        let longitude: Double
    }
}

// MARK: - MBTilesDatabase Hilfsklasse für SQLite3
/// Ermöglicht das Lesen und Schreiben von Kartenkacheln aus bzw. in lokale SQLite-Datenbanken im standardisierten MBTiles-Format.
class MBTilesDatabase {
    private var db: OpaquePointer?

    init?(path: String) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            return nil
        }
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Erstellt die standardmäßigen MBTiles-Datenstrukturen, falls diese noch nicht existieren.
    private func createTables() {
        let createMetadata = "CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);"
        let createTiles = "CREATE TABLE IF NOT EXISTS tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);"
        let createIndex = "CREATE UNIQUE INDEX IF NOT EXISTS tile_index ON tiles (zoom_level, tile_column, tile_row);"
        
        sqlite3_exec(db, createMetadata, nil, nil, nil)
        sqlite3_exec(db, createTiles, nil, nil, nil)
        sqlite3_exec(db, createIndex, nil, nil, nil)
    }

    /// Schreibt Metadaten-Schlüssel-Wert-Paare in die Datenbank.
    func writeMetadata(name: String, value: String) {
        let query = "INSERT OR REPLACE INTO metadata (name, value) VALUES (?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Speichert eine Kartenkachel (PNG-Daten) mit Berücksichtigung der TMS-Spezifikation (Y-Achsen-Invertierung).
    func writeTile(z: Int, x: Int, y: Int, data: Data) {
        let tmsY = (1 << z) - 1 - y
        let query = "INSERT OR REPLACE INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(z))
            sqlite3_bind_int(statement, 2, Int32(x))
            sqlite3_bind_int(statement, 3, Int32(tmsY))
            
            data.withUnsafeBytes { pointer in
                sqlite3_bind_blob(statement, 4, pointer.baseAddress, Int32(data.count), nil)
            }
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Liest eine PNG-Bildkachel anhand der Koordinaten aus der MBTiles-Datenbank.
    func readTile(z: Int, x: Int, y: Int) -> Data? {
        let tmsY = (1 << z) - 1 - y
        let query = "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?;"
        var statement: OpaquePointer?
        var data: Data? = nil
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(z))
            sqlite3_bind_int(statement, 2, Int32(x))
            sqlite3_bind_int(statement, 3, Int32(tmsY))
            
            if sqlite3_step(statement) == SQLITE_ROW {
                if let blob = sqlite3_column_blob(statement, 0) {
                    let length = sqlite3_column_bytes(statement, 0)
                    data = Data(bytes: blob, count: Int(length))
                }
            }
        }
        sqlite3_finalize(statement)
        return data
    }
}

// MARK: - CachedTileOverlay für MapKit Offline-Caching & MBTiles Support
class CachedTileOverlay: MKTileOverlay {
    let cacheDirectory: URL
    var mbtilesDB: MBTilesDatabase?
    
    init(urlTemplate URLTemplate: String? = nil, mbtilesURL: URL? = nil) {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        self.cacheDirectory = paths[0].appendingPathComponent("MapTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        
        if let mbtilesURL = mbtilesURL {
            self.mbtilesDB = MBTilesDatabase(path: mbtilesURL.path)
        }
        super.init(urlTemplate: URLTemplate)
    }
    
    func cachePath(for path: MKTileOverlayPath) -> URL {
        return cacheDirectory
            .appendingPathComponent("\(path.z)")
            .appendingPathComponent("\(path.x)")
            .appendingPathComponent("\(path.y).png")
    }
    
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let urlString = "https://a.tile.openstreetmap.org/\(path.z)/\(path.x)/\(path.y).png"
        return URL(string: urlString)!
    }
    
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        if let db = mbtilesDB, let tileData = db.readTile(z: path.z, x: path.x, y: path.y) {
            result(tileData, nil)
            return
        }
        
        let fileURL = cachePath(for: path)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL) {
                result(data, nil)
                return
            }
        }
        
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

// MARK: - MAPEM (Map Data)
struct V2XMapGeometry: Identifiable, Codable, Equatable {
    let id: Int
    var name: String
    var centerCoordinate: CLLocationCoordinate2D
    var laneCoordinates: [CLLocationCoordinate2D]
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

    func encode(to encoder: Error) throws { }

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

// MARK: - IVIM (Infrastructural Virtual Signage)
struct V2XVirtualSign: Identifiable, Codable, Equatable {
    let id: Int
    var type: String
    var value: Int
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

// MARK: - CPM (Collective Perception Message)
struct V2XCollectiveObject: Identifiable, Codable, Equatable {
    let id: Int
    var sensorType: String
    var objectClass: String
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

// MARK: - SRM (Signal Request Message)
struct V2XSignalRequest: Identifiable, Codable, Equatable {
    let id: Int
    var requesterType: String
    var targetIntersectionID: Int
    var requestStatus: String
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

// MARK: - SSM (Signal Status Message)
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

// MARK: - MCM (Maneuver Coordination Message)
struct V2XManeuver: Identifiable, Codable, Equatable {
    let id: Int
    var vehicleID: Int
    var coordinationPhase: String
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

// MARK: - RTCMEM (RTCM Correction Messages)
struct V2XRTKCorrection: Identifiable, Codable, Equatable {
    let id: Int
    var baseStationID: Int
    var signalStrengthDBm: Int
    var correctionStatus: String
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
class V2XHardwareManager: NSObject {
    // Aktive Status-Flags
    var v2xPortOpen = false
    var isV2XManuallyConnected = false
    var gpsPortOpen = false
    var isGPSManuallyConnected = false
    var serverRunning = false
    
    // Automatisches Kartennachführen (Zentrierung auf eigene Position)
    var isMapTrackingActive = true
    
    // Automatisches Framing (Ausschnitt so wählen, dass alle Objekte sichtbar sind)
    var isAutoFitAllActive = false
    
    // Durchsatz-Raten für die Key-Value-Coding-Schnittstelle
    @objc var v2xRxRateBps: Double = 0.0
    @objc var gpsRxRateBps: Double = 0.0
    
    // C-ITS Geodaten-Zustände (Strict Main-Thread Mutated)
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
    var selectedGPSBaud = "Auto"
    var lockedGPSBaud = "9600"
    let gpsBaudOptions = ["Auto", "4800", "9600", "19200", "38400", "57600", "115200"]
    
    var availablePorts: [String] = []
    
    // Server-Konfigurationen
    var serverPort: Int = 8080
    var isWebDebugServerEnabled = true
    var connectedClients: [String] = []
    
    // Offline-Karten Cache-Eigenschaften (Mit Cache-Größenberechnung)
    var isOfflineMapActive = false
    var selectedOfflineRegion = "Baden-Württemberg"
    let offlineRegionOptions = ["Baden-Württemberg", "Bayern", "Nordrhein-Westfalen", "Hessen"]
    var isDownloadingMap = false
    var downloadProgress: Double = 0.0
    var downloadedTilesCount = 0
    var totalTilesToDownload = 0
    var selectedMBTilesPath = ""
    var maxDownloadZoomLevel = 13
    var cacheSizeString = "0 B"
    
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
    
    // Debug & RX/TX Paket-Zähler (Strict Main-Thread Mutated)
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
    
    // Log-Terminals (Threadsicher über dispatch)
    var logs: [LogEntry] = []
    var espConsoleLog: [LogEntry] = []
    var debugRawPackets: [LogEntry] = []
    
    // Cache für forensische PCAP-Sicherungen
    var gpsPacketCache: [Data] = []
    var networkPacketCache: [Data] = []
    
    // --- SIMULATIONSEIGENSCHAFTEN ---
    var isAutoSimulationActive = false
    var simulationIntervalSeconds: Double = 2.0
    private var simulationTimer: Timer?
    private var rateTimer: Timer?
    
    // Private Handles und Sockets
    private var v2xHandle: FileHandle?
    private var gpsHandle: FileHandle?
    private var tcpListener: NWListener?
    private var webListener: NWListener?
    private var activeTCPConnections: [NWConnection] = []
    private var activeWebConnections: [NWConnection] = []
    private var shouldRead = false
    private var downloadTask: Task<Void, Never>? = nil
    
    override init() {
        super.init()
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            self.logDirectoryPathString = docs.path
            self.csvFilePathString = docs.appendingPathComponent("v2x_capture.csv").path
            self.pcapFilePathString = docs.appendingPathComponent("v2x_capture.pcap").path
        }
        scanPorts()
        updateCacheSizeString()
        startRateTimer()
    }
    
    // MARK: - Datenübertragungs-Ratenrechner (1Hz Frequenz)
    private func startRateTimer() {
        var lastV2XBytes = 0
        var lastGPSBytes = 0
        
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentV2X = self.totalV2XBytesRx
            let currentGPS = self.totalGPSBytesRx
            
            // Ermittle die Differenz im Datenstrom pro Sekunde
            self.v2xRxRateBps = Double(currentV2X - lastV2XBytes)
            self.gpsRxRateBps = Double(currentGPS - lastGPSBytes)
            
            lastV2XBytes = currentV2X
            lastGPSBytes = currentGPS
        }
    }
    
    // MARK: - Logger Hilfskonstrukte (Threadsicher)
    func addLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            if self.logs.count > 100 { self.logs.removeLast() }
        }
    }
    
    func addDebugPacketLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debugRawPackets.insert(entry, at: 0)
            if self.debugRawPackets.count > 500 { self.debugRawPackets.removeLast() }
        }
    }
    
    func addESPLog(_ text: String) {
        let entry = LogEntry(text: text)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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
                    do {
                        guard let data = try handle.read(upToCount: 512), !data.isEmpty else {
                            try Thread.sleep(forTimeInterval: 0.01)
                            continue
                        }
                        
                        let incomingBytes = data.count
                        DispatchQueue.main.async { [weak self] in
                            self?.totalV2XBytesRx += incomingBytes
                        }
                        
                        buffer.append(data)
                        while let endIndex = buffer.firstIndex(of: 0xC0) {
                            let pkt = buffer.subdata(in: 0..<endIndex)
                            buffer.removeSubrange(0...endIndex)
                            if !pkt.isEmpty {
                                let decoded = SLIPDecoder.decode(rawBytes: pkt)
                                self?.parseV2X(decoded)
                            }
                        }
                    } catch {
                        self?.addLog("[-] V2X Lese-Fehler: \(error.localizedDescription)")
                        self?.addESPLog("[-] Serial-Error auf dem Bus: \(error.localizedDescription)")
                        try? Thread.sleep(forTimeInterval: 0.5)
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
    
    // MARK: - DUAL-FORMAT KOORDINATEN DETEKTION & ENDIANNESS-RETTUNG
    private func parseCoordinateField(from data: Data, offset: Int) -> Double? {
        guard data.count >= offset + 4 else { return nil }
        let sub = data.subdata(in: offset..<offset+4)
        
        let floatLE = sub.withUnsafeBytes { $0.load(as: Float.self) }
        let floatBE = Data(sub.reversed()).withUnsafeBytes { $0.load(as: Float.self) }
        
        if floatLE.isFinite && abs(floatLE) > 0.01 && abs(floatLE) <= 180.0 {
            return Double(floatLE)
        }
        if floatBE.isFinite && abs(floatBE) > 0.01 && abs(floatBE) <= 180.0 {
            return Double(floatBE)
        }
        
        let intLE = sub.withUnsafeBytes { $0.load(as: Int32.self) }
        let intBE = intLE.byteSwapped
        
        let degLE = Double(intLE) / 10_000_000.0
        let degBE = Double(intBE) / 10_000_000.0
        
        if abs(degBE) > 0.0001 && abs(degBE) <= 180.0 {
            return degBE
        }
        if abs(degLE) > 0.0001 && abs(degLE) <= 180.0 {
            return degLE
        }
        
        return degLE
    }
    
    private func parseSpeedField(from data: Data, offset: Int, isBigEndian: Bool) -> Double {
        guard data.count >= offset + 2 else { return 0.0 }
        let rawLE = data.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        let rawBE = rawLE.byteSwapped
        let raw = isBigEndian ? rawBE : rawLE
        
        let speedKMH = (Double(raw) / 100.0) * 3.6
        if speedKMH > 250.0 {
            let alternativeSpeed = Double(raw)
            return alternativeSpeed <= 250.0 ? alternativeSpeed : 0.0
        }
        return speedKMH
    }
    
    private func parseV2X(_ payload: Data) {
        guard payload.count >= 13 else { return }
        
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        
        if payload[0] == 0x7B {
            if let decodedStr = String(data: payload, encoding: .utf8) {
                addDebugPacketLog("[V2X JSON] \(decodedStr)")
                if let envelope = try? JSONDecoder().decode(TCPMessageEnvelope.self, from: payload) {
                    processJSONEnvelope(envelope, payload: payload, ts: ts)
                    return
                }
            }
        }
        
        let typeByte = payload[0]
        
        let rawLatBytes = payload.subdata(in: 5..<9)
        let latLE = rawLatBytes.withUnsafeBytes { $0.load(as: Int32.self) }
        let latBE = latLE.byteSwapped
        let degBE = Double(latBE) / 10_000_000.0
        
        let isBigEndian = (degBE > 35.0 && degBE < 72.0)
        
        func readUInt32(offset: Int) -> UInt32? {
            guard payload.count >= offset + 4 else { return nil }
            let val = payload.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            return isBigEndian ? val.byteSwapped : val
        }
        
        func readUInt16(offset: Int) -> UInt16? {
            guard payload.count >= offset + 2 else { return nil }
            let val = payload.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
            return isBigEndian ? val.byteSwapped : val
        }
        
        guard let stationIDVal = readUInt32(offset: 1),
              let lat = parseCoordinateField(from: payload, offset: 5),
              let lon = parseCoordinateField(from: payload, offset: 9) else {
            return
        }
        
        let id = Int(stationIDVal)
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        guard lat != 0.0 && lon != 0.0 else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch typeByte {
            case 1, 0x43:
                self.decodedCAMs += 1
                
                let rawHeading = readUInt16(offset: 13) ?? 0
                let heading = Double(rawHeading) / 10.0
                let speedKMH = self.parseSpeedField(from: payload, offset: 15, isBigEndian: isBigEndian)
                let brakeByte = payload.count >= 18 ? payload[17] : 0
                let isBraking = brakeByte != 0
                
                var vehicle = self.vehicles[id] ?? V2XVehicle(id: id, coordinate: coordinate, heading: heading, speed: speedKMH, isBraking: isBraking, lastSeen: Date())
                vehicle.updatePosition(to: coordinate, heading: heading, speed: speedKMH, isBraking: isBraking)
                self.vehicles[id] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
                
                self.addDebugPacketLog("[V2X CAM] Auto #\(id): Lat \(String(format: "%.6f", lat)), Lon \(String(format: "%.6f", lon)), Speed: \(String(format: "%.1f", speedKMH)) km/h")
                self.logForensics(line: "\(ts);CAM;\(id);\(lat);\(lon);\(speedKMH);\(heading);\(isBraking);none\n", rawPacket: payload)
                
            case 2, 0x44:
                self.decodedDENMs += 1
                
                let causeCode = payload.count >= 14 ? payload[13] : 3
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
                
                self.dangerZones[id] = zone
                self.broadcast(type: "DENM", payload: zone)
                
                self.addDebugPacketLog("[V2X DENM] Gefahr #\(id): Typ \(type) bei Lat \(String(format: "%.6f", lat)), Lon \(String(format: "%.6f", lon))")
                self.logForensics(line: "\(ts);DENM;\(id);\(lat);\(lon);0;0;false;\(type)_\(radius)m\n", rawPacket: payload)
                
            case 3, 0x53:
                self.decodedSPATEMs += 1
                
                let phaseByte = payload.count >= 14 ? payload[13] : 3
                let rawTime = payload.count >= 16 ? readUInt16(offset: 14) ?? 100 : 100
                
                let phase: String
                switch phaseByte {
                case 2, 3: phase = "red"
                case 4, 5: phase = "yellow"
                case 6, 7: phase = "green"
                default: phase = "red"
                }
                
                let timeToChange = Int(rawTime) / 10
                let light = V2XTrafficLight(id: id, coordinate: coordinate, currentPhase: phase, timeToChange: timeToChange)
                
                self.trafficLights[id] = light
                self.broadcast(type: "SPATEM", payload: light)
                
                self.addDebugPacketLog("[V2X SPATEM] Ampel #\(id): Phase \(phase.uppercased()) Countdown: \(timeToChange)s")
                self.logForensics(line: "\(ts);SPATEM;\(id);\(lat);\(lon);0;0;false;\(phase)_\(timeToChange)\n", rawPacket: payload)
                
            case 4, 0x4D:
                self.decodedMAPEMs += 1
                let mapGeo = V2XMapGeometry(
                    id: id,
                    name: "Kreuzung_\(id)",
                    centerCoordinate: coordinate,
                    laneCoordinates: [
                        CLLocationCoordinate2D(latitude: coordinate.latitude - 0.0003, longitude: coordinate.longitude - 0.0003),
                        coordinate,
                        CLLocationCoordinate2D(latitude: coordinate.latitude + 0.0003, longitude: coordinate.longitude + 0.0003)
                    ]
                )
                self.mapGeometries[id] = mapGeo
                self.broadcast(type: "MAPEM", payload: mapGeo)
                self.addDebugPacketLog("[V2X MAPEM] Kreuzungsgeometrie #\(id) erfasst")
                self.logForensics(line: "\(ts);MAPEM;\(id);\(lat);\(lon);0;0;false;Intersection_\(id)\n", rawPacket: payload)

            case 5, 0x49:
                self.decodedIVIMs += 1
                let value = payload.count >= 14 ? Int(payload[13]) : 50
                let sign = V2XVirtualSign(id: id, type: "SPEED_LIMIT", value: value, coordinate: coordinate)
                self.virtualSigns[id] = sign
                self.broadcast(type: "IVIM", payload: sign)
                self.addDebugPacketLog("[V2X IVIM] Dynamisches Verkehrsschild #\(id): Tempolimit \(value) km/h")
                self.logForensics(line: "\(ts);IVIM;\(id);\(lat);\(lon);0;0;false;Limit_\(value)\n", rawPacket: payload)

            case 6, 0x50:
                self.decodedCPMs += 1
                let speed = payload.count >= 14 ? Double(payload[13]) : 0.0
                let obj = V2XCollectiveObject(id: id, sensorType: "RADAR", objectClass: "PEDESTRIAN", coordinate: coordinate, speed: speed, heading: 0.0)
                self.collectiveObjects[id] = obj
                self.broadcast(type: "CPM", payload: obj)
                self.addDebugPacketLog("[V2X CPM] LiDAR/Radar-Fremdhypothese #\(id) detektiert")
                self.logForensics(line: "\(ts);CPM;\(id);\(lat);\(lon);\(speed);0;false;Radar_Pedestrian\n", rawPacket: payload)

            case 7, 0x52:
                self.decodedSRMs += 1
                let targetIntersection = payload.count >= 15 ? Int(readUInt16(offset: 13) ?? 1) : 1
                let req = V2XSignalRequest(id: id, requesterType: "AMBULANCE", targetIntersectionID: targetIntersection, requestStatus: "ACTIVE", coordinate: coordinate)
                self.signalRequests[id] = req
                self.broadcast(type: "SRM", payload: req)
                self.addDebugPacketLog("[V2X SRM] Einsatzwagen-Anforderung #\(id) an Kreuzung \(targetIntersection)")
                self.logForensics(line: "\(ts);SRM;\(id);\(lat);\(lon);0;0;false;PriorityRequest_\(targetIntersection)\n", rawPacket: payload)

            case 8, 0x4F:
                self.decodedSSMs += 1
                let granted = payload.count >= 14 ? (payload[13] != 0) : true
                let status = V2XSignalStatus(id: id, intersectionID: id, priorityGranted: granted, activeRequesterID: id * 2, coordinate: coordinate)
                self.signalStatuses[id] = status
                self.broadcast(type: "SSM", payload: status)
                self.addDebugPacketLog("[V2X SSM] Ampel-Bestätigung #\(id): Freigabe=\(granted)")
                self.logForensics(line: "\(ts);SSM;\(id);\(lat);\(lon);0;0;granted;SSM_Intersection_\(id)\n", rawPacket: payload)

            case 9, 0x4E:
                self.decodedMCMs += 1
                let maneuver = V2XManeuver(
                    id: id,
                    vehicleID: id,
                    coordinationPhase: "PLANNING",
                    trajectoryPoints: [coordinate]
                )
                self.maneuvers[id] = maneuver
                self.broadcast(type: "MCM", payload: maneuver)
                self.addDebugPacketLog("[V2X MCM] Trajektorienvereinbarung #\(id) im Planungszustand")
                self.logForensics(line: "\(ts);MCM;\(id);\(lat);\(lon);0;0;false;Maneuver_Coord\n", rawPacket: payload)

            case 10, 0x4B:
                self.decodedRTCMEMs += 1
                let strength = payload.count >= 14 ? Int(payload[13]) - 140 : -70
                let rtk = V2XRTKCorrection(id: id, baseStationID: id, signalStrengthDBm: strength, correctionStatus: "RTK_FIX", coordinate: coordinate)
                self.rtkCorrections[id] = rtk
                self.broadcast(type: "RTCMEM", payload: rtk)
                self.addDebugPacketLog("[V2X RTCMEM] RTK-Korrektursignal erhalten, Stärke: \(strength) dBm")
                self.logForensics(line: "\(ts);RTCMEM;\(id);\(lat);\(lon);0;0;false;RTK_Correction_\(strength)dBm\n", rawPacket: payload)

            default:
                self.addDebugPacketLog("[V2X] Unbekanntes Binärpaket Typ \(typeByte) von ID \(id)")
            }
        }
    }
    
    // MARK: - Forensik Logging (Schreiben von CSV und PCAP Dateien)
    private func logForensics(line: String, rawPacket: Data) {
        if isCSVLoggingActive, !csvFilePathString.isEmpty {
            let url = URL(fileURLWithPath: csvFilePathString)
            CSVUtils.ensureHeader(at: url)
            CSVUtils.appendLine(line, to: url)
        }
        
        if isPCAPLoggingActive, !pcapFilePathString.isEmpty {
            let url = URL(fileURLWithPath: pcapFilePathString)
            PCAPUtils.ensureGlobalHeader(at: url)
            PCAPUtils.appendPacket(rawPacket, to: url)
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
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            switch envelope.msgType.uppercased() {
            case "CAM":
                self.decodedCAMs += 1
                let speed = p.speedKmH ?? p.speed ?? 0.0
                let heading = p.heading ?? 0.0
                let braking = p.isBraking ?? false
                
                var vehicle = self.vehicles[id] ?? V2XVehicle(id: id, coordinate: coordinate, heading: heading, speed: speed, isBraking: braking, lastSeen: Date())
                vehicle.updatePosition(to: coordinate, heading: heading, speed: speed, isBraking: braking)
                self.vehicles[id] = vehicle
                self.broadcast(type: "CAM", payload: vehicle)
                self.logForensics(line: "\(ts);CAM;\(id);\(lat);\(lon);\(speed);\(heading);\(braking);none\n", rawPacket: payload)
                
            case "DENM":
                self.decodedDENMs += 1
                let type = p.type ?? "Baustelle"
                let radius = p.radiusMeter ?? 150.0
                let zone = V2XDangerZone(id: id, type: type, coordinate: coordinate, radiusMeter: radius)
                
                self.dangerZones[id] = zone
                self.broadcast(type: "DENM", payload: zone)
                self.logForensics(line: "\(ts);DENM;\(id);\(lat);\(lon);0;0;false;\(type)_\(radius)m\n", rawPacket: payload)
                
            case "SPATEM":
                self.decodedSPATEMs += 1
                let phase = p.currentPhase ?? "red"
                let time = p.timeToChange ?? 10
                let light = V2XTrafficLight(id: id, coordinate: coordinate, currentPhase: phase, timeToChange: time)
                
                self.trafficLights[id] = light
                self.broadcast(type: "SPATEM", payload: light)
                self.logForensics(line: "\(ts);SPATEM;\(id);\(lat);\(lon);0;0;false;\(phase)_\(time)\n", rawPacket: payload)
                
            case "MAPEM":
                self.decodedMAPEMs += 1
                let laneCoords = p.laneCoordinates?.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? []
                let mapGeo = V2XMapGeometry(id: id, name: p.name ?? "Kreuzung", centerCoordinate: coordinate, laneCoordinates: laneCoords)
                self.mapGeometries[id] = mapGeo
                self.broadcast(type: "MAPEM", payload: mapGeo)
                self.logForensics(line: "\(ts);MAPEM;\(id);\(lat);\(lon);0;0;false;\(p.name ?? "Kreuzung")\n", rawPacket: payload)
                
            case "IVIM":
                self.decodedIVIMs += 1
                let value = p.value ?? 50
                let sign = V2XVirtualSign(id: id, type: p.type ?? "SPEED_LIMIT", value: value, coordinate: coordinate)
                self.virtualSigns[id] = sign
                self.broadcast(type: "IVIM", payload: sign)
                self.logForensics(line: "\(ts);IVIM;\(id);\(lat);\(lon);0;0;false;Limit_\(value)\n", rawPacket: payload)
                
            case "CPM":
                self.decodedCPMs += 1
                let obj = V2XCollectiveObject(id: id, sensorType: p.sensorType ?? "RADAR", objectClass: p.objectClass ?? "PEDESTRIAN", coordinate: coordinate, speed: p.speed ?? 0.0, heading: p.heading ?? 0.0)
                self.collectiveObjects[id] = obj
                self.broadcast(type: "CPM", payload: obj)
                self.logForensics(line: "\(ts);CPM;\(id);\(lat);\(lon);\(p.speed ?? 0.0);0;false;LiDAR\n", rawPacket: payload)
                
            case "SRM":
                self.decodedSRMs += 1
                let req = V2XSignalRequest(id: id, requesterType: p.requesterType ?? "FIRE_BRIGADE", targetIntersectionID: p.targetIntersectionID ?? 1, requestStatus: p.requestStatus ?? "ACTIVE", coordinate: coordinate)
                self.signalRequests[id] = req
                self.broadcast(type: "SRM", payload: req)
                self.logForensics(line: "\(ts);SRM;\(id);\(lat);\(lon);0;0;false;Signal_Request\n", rawPacket: payload)
                
            case "SSM":
                self.decodedSSMs += 1
                let status = V2XSignalStatus(id: id, intersectionID: p.intersectionID ?? 1, priorityGranted: p.priorityGranted ?? true, activeRequesterID: p.activeRequesterID ?? 0, coordinate: coordinate)
                self.signalStatuses[id] = status
                self.broadcast(type: "SSM", payload: status)
                self.logForensics(line: "\(ts);SSM;\(id);\(lat);\(lon);0;0;false;Signal_Status\n", rawPacket: payload)
                
            case "MCM":
                self.decodedMCMs += 1
                let points = p.trajectoryPoints?.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } ?? []
                let maneuver = V2XManeuver(id: id, vehicleID: id, coordinationPhase: p.coordinationPhase ?? "PLANNING", trajectoryPoints: points)
                self.maneuvers[id] = maneuver
                self.broadcast(type: "MCM", payload: maneuver)
                self.logForensics(line: "\(ts);MCM;\(id);\(lat);\(lon);0;0;false;MCM\n", rawPacket: payload)
                
            case "RTCMEM":
                self.decodedRTCMEMs += 1
                let rtk = V2XRTKCorrection(id: id, baseStationID: p.baseStationID ?? 1, signalStrengthDBm: p.signalStrengthDBm ?? -70, correctionStatus: p.correctionStatus ?? "RTK_FIX", coordinate: coordinate)
                self.rtkCorrections[id] = rtk
                self.broadcast(type: "RTCMEM", payload: rtk)
                self.logForensics(line: "\(ts);RTCMEM;\(id);\(lat);\(lon);0;0;false;RTCM\n", rawPacket: payload)
                
            default:
                break
            }
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
        
        let baudsToTry = selectedGPSBaud == "Auto" ? ["9600", "4800", "115200", "38400", "19200", "57600"] : [selectedGPSBaud]
        
        self.gpsPortOpen = true
        self.isGPSManuallyConnected = true
        self.shouldRead = true
        
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            
            var activeBaud = "9600"
            var openedHandle: FileHandle? = nil
            
            // Loop durch alle möglichen Baudraten (Auto-Baud Scanner)
            for baud in baudsToTry {
                guard self.shouldRead else { break }
                self.addLog("[i] Teste GPS Baudrate: \(baud)...")
                self.configurePort(path: self.selectedGPSPort, baud: baud)
                
                if let handle = FileHandle(forReadingAtPath: self.selectedGPSPort) {
                    var testBuffer = Data()
                    let startTime = Date()
                    var foundNMEA = false
                    
                    // Lese für maximal 1,5 Sekunden pro Geschwindigkeit, um nach dem '$'-Symbol zu suchen
                    while Date().timeIntervalSince(startTime) < 1.5 {
                        if let data = try? handle.read(upToCount: 256), !data.isEmpty {
                            testBuffer.append(data)
                            if let str = String(data: testBuffer, encoding: .ascii) {
                                // Suche robust nach gültigen NMEA-Tags, um Fehldetektionen durch Rauschen auszuschließen
                                if str.contains("$GP") || str.contains("$GN") || str.contains("$GL") || str.contains("$BD") {
                                    foundNMEA = true
                                    break
                                }
                            }
                        }
                        try? Thread.sleep(forTimeInterval: 0.1)
                    }
                    
                    if foundNMEA || baudsToTry.count == 1 {
                        activeBaud = baud
                        openedHandle = handle
                        self.addLog("[+] GPS NMEA Signal erfolgreich erkannt bei \(baud) Baud!")
                        DispatchQueue.main.async {
                            self.lockedGPSBaud = baud
                        }
                        break
                    } else {
                        try? handle.close()
                    }
                }
            }
            
            guard let handle = openedHandle else {
                self.addLog("[-] GPS-Empfänger konnte auf \(self.selectedGPSPort) nicht erfolgreich initialisiert werden.")
                DispatchQueue.main.async {
                    self.gpsPortOpen = false
                    self.isGPSManuallyConnected = false
                }
                return
            }
            
            self.gpsHandle = handle
            var buffer = ""
            
            while self.shouldRead {
                do {
                    guard let data = try handle.read(upToCount: 512) else {
                        try Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    if data.isEmpty {
                        try Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    
                    let incomingBytes = data.count
                    DispatchQueue.main.async {
                        self.totalGPSBytesRx += incomingBytes
                        self.gpsPacketCache.append(data)
                    }
                    
                    if let chunk = String(data: data, encoding: .ascii) {
                        buffer += chunk
                        var lines = buffer.components(separatedBy: "\n")
                        if !lines.isEmpty {
                            // Letzte unvollständige Zeile im Buffer halten
                            buffer = lines.removeLast()
                            for rawLine in lines {
                                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !line.isEmpty {
                                    // Alle empfangenen Zeilen an das Debug-Terminal ausgeben
                                    self.addDebugPacketLog("[GPS] \(line)")
                                    
                                    // RMC Sätze identifizieren ($GPRMC, $GNRMC, $GLRMC etc.)
                                    if line.contains("RMC") {
                                        self.parseNMEA(line)
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    self.addLog("[-] GPS Lese-Fehler: \(error.localizedDescription)")
                    self.addDebugPacketLog("[GPS ERROR] \(error.localizedDescription)")
                    try? Thread.sleep(forTimeInterval: 0.5)
                }
            }
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
        guard let startIdx = line.firstIndex(of: "$") else { return }
        let cleanLine = String(line[startIdx...])
        let p = cleanLine.components(separatedBy: ",")
        
        if p.count > 6, p[2] == "A" {
            guard let rLat = Double(p[3]), let rLon = Double(p[5]) else { return }
            let lat = convertNMEA(rLat, dir: p[4])
            let lon = convertNMEA(rLon, dir: p[6])
            let gpsDict = ["latitude": lat, "longitude": lon]
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
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
            
            DispatchQueue.main.async { [weak self] in
                self?.networkPacketCache.append(frame)
            }
            
            activeTCPConnections.forEach { conn in
                conn.send(content: frame, completion: .contentProcessed({ _ in }))
            }
        }
    }
    
    // MARK: - HTTP & Web Debugger Routing
    private func respond(to request: String, over connection: NWConnection) {
        let firstLine = request.components(separatedBy: .newlines).first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"

        let pathAndQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathAndQuery.first.map(String.init) ?? "/"
        let query = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""

        var responseData: Data = Data()
        var contentType = "text/html; charset=utf-8"

        if method == "GET" && (path == "/" || path == "/index" || path == "/index.html") {
            responseData = self.getWebDebugHTML().data(using: .utf8) ?? Data()
        } else if method == "GET" && path.hasPrefix("/api/toggleTrails") {
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
            responseData = self.getWebDebugHTML().data(using: .utf8) ?? Data()
        }

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
        
        let minZoom = 10
        let zoomLevels = Array(minZoom...max(minZoom, maxDownloadZoomLevel))
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
                
                if FileManager.default.fileExists(atPath: localURL.path) {
                    completed += 1
                    await MainActor.run {
                        self.downloadedTilesCount = completed
                        self.downloadProgress = Double(completed) / Double(self.totalTilesToDownload)
                        self.updateCacheSizeString()
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
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    self.addLog("[-] Kacheldownload-Fehler (Z:\(tile.z) X:\(tile.x) Y:\(tile.y)): \(error.localizedDescription)")
                }
                
                completed += 1
                await MainActor.run {
                    self.downloadedTilesCount = completed
                    self.downloadProgress = Double(completed) / Double(self.totalTilesToDownload)
                    self.updateCacheSizeString()
                }
            }
            
            await MainActor.run {
                self.isDownloadingMap = false
                self.updateCacheSizeString()
                self.addLog("[+] Offline-Karten-Download abgeschlossen (\(selectedOfflineRegion)).")
            }
        }
    }
    
    // MARK: - Karten-Cache-Anzeige (ASYNCHRON & ABSTURZSICHER BERECHNET)
    func updateCacheSizeString() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            let paths = fm.urls(for: .cachesDirectory, in: .userDomainMask)
            let cacheDirectory = paths[0].appendingPathComponent("MapTiles", isDirectory: true)
            
            guard fm.fileExists(atPath: cacheDirectory.path) else {
                DispatchQueue.main.async {
                    self?.cacheSizeString = "0 B"
                }
                return
            }
            
            guard let enumerator = fm.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
                DispatchQueue.main.async {
                    self?.cacheSizeString = "0 B"
                }
                return
            }
            
            var totalSize: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            let formattedString = formatter.string(fromByteCount: totalSize)
            
            DispatchQueue.main.async {
                self?.cacheSizeString = formattedString
            }
        }
    }
    
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
        updateCacheSizeString()
        addLog("[-] Offline-Karten-Download abgebrochen.")
    }
    
    // MARK: - MBTiles Importer, Exporter & Cache Löschung
    func importMBTilesFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [UTType(filenameExtension: "mbtiles") ?? .data]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "MBTiles auswählen"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            self.selectedMBTilesPath = url.path
            self.isOfflineMapActive = true
            addLog("[+] MBTiles Karte geladen: \(url.lastPathComponent)")
        }
    }
    
    func exportCacheToMBTiles() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "mbtiles") ?? .data]
        savePanel.nameFieldStringValue = "offline_map_\(selectedOfflineRegion).mbtiles"
        savePanel.prompt = "Speichern"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            let overlay = CachedTileOverlay()
            let fm = FileManager.default
            
            try? fm.removeItem(at: url)
            
            guard let db = MBTilesDatabase(path: url.path) else {
                addLog("[-] MBTiles-Export fehlgeschlagen: Datenbank konnte nicht initialisiert werden.")
                return
            }
            
            db.writeMetadata(name: "name", value: "Offline-Karte \(selectedOfflineRegion)")
            db.writeMetadata(name: "format", value: "png")
            db.writeMetadata(name: "type", value: "baselayer")
            db.writeMetadata(name: "version", value: "1.0")
            
            let cacheDir = overlay.cacheDirectory
            let enumerator = fm.enumerator(at: cacheDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            
            var count = 0
            while let fileURL = enumerator?.nextObject() as? URL {
                guard fileURL.pathExtension == "png" else { continue }
                
                let components = fileURL.pathComponents
                let countComponents = components.count
                guard countComponents >= 3 else { continue }
                
                let yStr = fileURL.deletingPathExtension().lastPathComponent
                let xStr = components[countComponents - 2]
                let zStr = components[countComponents - 3]
                
                if let z = Int(zStr), let x = Int(xStr), let y = Int(yStr),
                   let data = try? Data(contentsOf: fileURL) {
                    db.writeTile(z: z, x: x, y: y, data: data)
                    count += 1
                }
            }
            
            addLog("[+] MBTiles-Export abgeschlossen: \(count) Kacheln erfolgreich exportiert.")
        }
    }
    
    func clearTileCache() {
        let fm = FileManager.default
        let paths = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        let cacheDirectory = paths[0].appendingPathComponent("MapTiles", isDirectory: true)
        
        do {
            if fm.fileExists(atPath: cacheDirectory.path) {
                try fm.removeItem(at: cacheDirectory)
                try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                self.downloadedTilesCount = 0
                self.downloadProgress = 0.0
                self.selectedMBTilesPath = ""
                self.updateCacheSizeString()
                addLog("[+] Karten-Cache erfolgreich gelöscht.")
            } else {
                self.updateCacheSizeString()
                addLog("[i] Karten-Cache bereits leer.")
            }
        } catch {
            addLog("[-] Fehler beim Löschen des Karten-Caches: \(error.localizedDescription)")
        }
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
    
    // Generiert ein robustes, ETSI-konformes Binärpaket für Simulationszwecke
    private func mockPayload(type: UInt8, id: Int, lat: Double, lon: Double) -> Data {
        var data = Data(repeating: 0, count: 20)
        data[0] = type
        
        // Station ID (UInt32, Big Endian)
        let idVal = UInt32(id).bigEndian
        withUnsafeBytes(of: idVal) { data.replaceSubrange(1..<5, with: $0) }
        
        // Breitengrad im standardmäßigen ETSI-Format (* 10^7)
        let latVal = Int32(lat * 10_000_000.0).bigEndian
        withUnsafeBytes(of: latVal) { data.replaceSubrange(5..<9, with: $0) }
        
        // Längengrad im standardmäßigen ETSI-Format (* 10^7)
        let lonVal = Int32(lon * 10_000_000.0).bigEndian
        withUnsafeBytes(of: lonVal) { data.replaceSubrange(9..<13, with: $0) }
        
        // Standard Heading (120.0 Grad)
        let headingVal = UInt16(1200).bigEndian
        withUnsafeBytes(of: headingVal) { data.replaceSubrange(13..<15, with: $0) }
        
        // Standard Geschwindigkeit (50 km/h -> 13.88 m/s -> 1388 in m/s * 100)
        let speedVal = UInt16(1388).bigEndian
        withUnsafeBytes(of: speedVal) { data.replaceSubrange(15..<17, with: $0) }
        
        return data
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
    
    // MARK: - Zusammenführung: Simulations-Zentrale Logik
    func toggleAutoSimulation() {
        if isAutoSimulationActive {
            simulationTimer?.invalidate()
            simulationTimer = nil
            isAutoSimulationActive = false
            addLog("[-] Automatische Signal-Simulation gestoppt.")
        } else {
            isAutoSimulationActive = true
            addLog("[+] Automatische Signal-Simulation gestartet (\(simulationIntervalSeconds)s Intervall).")
            simulationTimer = Timer.scheduledTimer(withTimeInterval: simulationIntervalSeconds, repeats: true) { [weak self] _ in
                self?.triggerRandomSimulationStep()
            }
        }
    }
    
    private func triggerRandomSimulationStep() {
        // Eigene Position als Ankerpunkt verwenden, ansonsten im Großraum Stuttgart simulieren (48.775, 9.182)
        let centerLat = myLocation?.latitude ?? 48.775
        let centerLon = myLocation?.longitude ?? 9.182
        
        let lat = centerLat + Double.random(in: -0.015...0.015)
        let lon = centerLon + Double.random(in: -0.015...0.015)
        
        let actions = [
            { self.simulateCAM(lat: lat, lon: lon) },
            { self.simulateDENM(lat: lat, lon: lon) },
            { self.simulateSPATEM(lat: lat, lon: lon) },
            { self.simulateMAPEM(lat: lat, lon: lon) },
            { self.simulateIVIM(lat: lat, lon: lon) },
            { self.simulateCPM(lat: lat, lon: lon) },
            { self.simulateSRM(lat: lat, lon: lon) },
            { self.simulateSSM(lat: lat, lon: lon) },
            { self.simulateMCM(lat: lat, lon: lon) },
            { self.simulateRTCMEM(lat: lat, lon: lon) }
        ]
        if let randomAction = actions.randomElement() {
            randomAction()
        }
    }
    
    func simulateCAM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 9
        let dummyBytes = mockPayload(type: 1, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere CAM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateDENM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 1
        let dummyBytes = mockPayload(type: 2, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere DENM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSPATEM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11
        let dummyBytes = mockPayload(type: 3, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere SPATEM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateMAPEM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 2
        let dummyBytes = mockPayload(type: 4, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere MAPEM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateIVIM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 3
        let dummyBytes = mockPayload(type: 5, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere IVIM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateCPM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 4
        let dummyBytes = mockPayload(type: 6, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere CPM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSRM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 5
        let dummyBytes = mockPayload(type: 7, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere SRM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateSSM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 6
        let dummyBytes = mockPayload(type: 8, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere SSM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateMCM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 7
        let dummyBytes = mockPayload(type: 9, id: simulatedID, lat: lat, lon: lon)
        addDebugPacketLog("[SIM] Generiere MCM Paket für ID \(simulatedID)")
        parseV2X(dummyBytes)
    }
    
    func simulateRTCMEM(lat: Double, lon: Double) {
        let simulatedID = Int.random(in: 10...99) * 11 + 8
        let dummyBytes = mockPayload(type: 10, id: simulatedID, lat: lat, lon: lon)
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
        simulationTimer?.invalidate()
        simulationTimer = nil
        rateTimer?.invalidate()
        rateTimer = nil
        isAutoSimulationActive = false
        disconnectV2X()
        disconnectGPS()
        stopServer()
    }
}

// MARK: - SelectedV2XObject Selektions-Wrapper
enum SelectedV2XObject: Identifiable {
    case vehicle(V2XVehicle)
    case trafficLight(V2XTrafficLight)
    case dangerZone(V2XDangerZone)
    case virtualSign(V2XVirtualSign)
    case collectiveObject(V2XCollectiveObject)
    case rtkCorrection(V2XRTKCorrection)
    
    var id: String {
        switch self {
        case .vehicle(let o): return "vehicle-\(o.id)"
        case .trafficLight(let o): return "light-\(o.id)"
        case .dangerZone(let o): return "zone-\(o.id)"
        case .virtualSign(let o): return "sign-\(o.id)"
        case .collectiveObject(let o): return "cpm-\(o.id)"
        case .rtkCorrection(let o): return "rtk-\(o.id)"
        }
    }
}

// MARK: - MKAnnotation Custom Subklasse für C-ITS
class V2XAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let object: SelectedV2XObject
    
    init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?, object: SelectedV2XObject) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.object = object
    }
}

// MARK: - V2XMapView (Brücke zwischen MKMapView und SwiftUI)
struct V2XMapView: NSViewRepresentable {
    @Bindable var hardwareManager: V2XHardwareManager
    
    // Explizite Übergabe der observed-Eigenschaften, um SwiftUI's Observation-Update zu garantieren
    var vehicles: [Int: V2XVehicle]
    var trafficLights: [Int: V2XTrafficLight]
    var dangerZones: [Int: V2XDangerZone]
    var virtualSigns: [Int: V2XVirtualSign]
    var collectiveObjects: [Int: V2XCollectiveObject]
    var rtkCorrections: [Int: V2XRTKCorrection]
    var myLocation: CLLocationCoordinate2D?
    var isOfflineMapActive: Bool
    var selectedMBTilesPath: String
    var isMapTrackingActive: Bool
    var isAutoFitAllActive: Bool
    
    @Binding var selectedObject: SelectedObjectWrapper?
    
    struct SelectedObjectWrapper {
        let value: SelectedV2XObject
    }
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        return mapView
    }
    
    func updateNSView(_ nsView: MKMapView, context: Context) {
        nsView.removeOverlays(nsView.overlays)
        
        if isOfflineMapActive {
            let tileOverlay: CachedTileOverlay
            if !selectedMBTilesPath.isEmpty {
                let mbtilesURL = URL(fileURLWithPath: selectedMBTilesPath)
                tileOverlay = CachedTileOverlay(mbtilesURL: mbtilesURL)
            } else {
                tileOverlay = CachedTileOverlay()
            }
            tileOverlay.canReplaceMapContent = true
            nsView.addOverlay(tileOverlay, level: .aboveRoads)
        }
        
        for zone in dangerZones.values {
            let circle = MKCircle(center: zone.coordinate, radius: zone.radiusMeter)
            nsView.addOverlay(circle, level: .aboveRoads)
        }
        
        for vehicle in vehicles.values {
            if vehicle.history.count > 1 {
                let polyline = MKPolyline(coordinates: vehicle.history, count: vehicle.history.count)
                nsView.addOverlay(polyline, level: .aboveRoads)
            }
        }
        
        nsView.removeAnnotations(nsView.annotations)
        var newAnnotations: [V2XAnnotation] = []
        
        if let myLoc = myLocation {
            let dummyVehicle = V2XVehicle(id: 0, coordinate: myLoc, heading: 0, speed: 0, isBraking: false, lastSeen: Date())
            newAnnotations.append(V2XAnnotation(coordinate: myLoc, title: "Eigene Position", subtitle: nil, object: .vehicle(dummyVehicle)))
        }
        
        for vehicle in vehicles.values {
            newAnnotations.append(V2XAnnotation(coordinate: vehicle.coordinate, title: "Auto #\(vehicle.id)", subtitle: "\(Int(vehicle.speed)) km/h", object: .vehicle(vehicle)))
        }
        
        for light in trafficLights.values {
            newAnnotations.append(V2XAnnotation(coordinate: light.coordinate, title: "Ampel #\(light.id)", subtitle: "\(light.currentPhase.uppercased()) (\(light.timeToChange)s)", object: .trafficLight(light)))
        }
        
        for zone in dangerZones.values {
            newAnnotations.append(V2XAnnotation(coordinate: zone.coordinate, title: zone.type, subtitle: "Radius: \(Int(zone.radiusMeter))m", object: .dangerZone(zone)))
        }
        
        for sign in virtualSigns.values {
            newAnnotations.append(V2XAnnotation(coordinate: sign.coordinate, title: "Tempolimit", subtitle: "\(sign.value) km/h", object: .virtualSign(sign)))
        }
        
        for obj in collectiveObjects.values {
            newAnnotations.append(V2XAnnotation(coordinate: obj.coordinate, title: obj.objectClass, subtitle: "CPM Objekt", object: .collectiveObject(obj)))
        }
        
        for rtk in rtkCorrections.values {
            newAnnotations.append(V2XAnnotation(coordinate: rtk.coordinate, title: "RTK Station #\(rtk.baseStationID)", subtitle: rtk.correctionStatus, object: .rtkCorrection(rtk)))
        }
        
        nsView.addAnnotations(newAnnotations)
        
        // Auto-Framing: Wählt Kartenausschnitt so, dass ALLE annotations gleichzeitig sichtbar sind!
        if isAutoFitAllActive {
            let validAnnotations = nsView.annotations.filter { !($0 is MKUserLocation) }
            if !validAnnotations.isEmpty {
                nsView.showAnnotations(validAnnotations, animated: true)
            }
        } else if isMapTrackingActive, let myLoc = myLocation {
            // Klassische Nachführung der eigenen GPS-Position
            let currentRegion = nsView.region
            let delta = 0.005
            if abs(currentRegion.center.latitude - myLoc.latitude) > delta || abs(currentRegion.center.longitude - myLoc.longitude) > delta {
                let region = MKCoordinateRegion(center: myLoc, latitudinalMeters: 500, longitudinalMeters: 500)
                nsView.setRegion(region, animated: true)
            } else {
                nsView.setCenter(myLoc, animated: true)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: V2XMapView
        
        init(_ parent: V2XMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let v2xAnn = annotation as? V2XAnnotation else { return nil }
            
            let identifier = "V2XAnnotationNode"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: v2xAnn, reuseIdentifier: identifier)
            
            view.annotation = v2xAnn
            view.canShowCallout = true
            
            switch v2xAnn.object {
            case .vehicle(let v):
                if v.id == 0 {
                    view.markerTintColor = .systemBlue
                    view.glyphImage = NSImage(systemSymbolName: "location.north.navigation.fill", accessibilityDescription: nil)
                } else {
                    view.markerTintColor = v.isBraking ? .systemRed : .systemGreen
                    view.glyphImage = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
                }
            case .trafficLight(let l):
                view.markerTintColor = l.currentPhase == "green" ? .systemGreen : (l.currentPhase == "yellow" ? .systemYellow : .systemRed)
                view.glyphImage = NSImage(systemSymbolName: "trafficlight.fill", accessibilityDescription: nil)
            case .dangerZone:
                view.markerTintColor = .systemOrange
                view.glyphImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            case .virtualSign:
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "nosign", accessibilityDescription: nil)
            case .collectiveObject:
                view.markerTintColor = .systemTeal
                view.glyphImage = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
            case .rtkCorrection:
                view.markerTintColor = .systemPurple
                view.glyphImage = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            }
            
            return view
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = NSColor.orange.withAlphaComponent(0.15)
                renderer.strokeColor = NSColor.orange
                renderer.lineWidth = 1.5
                return renderer
            }
            
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = NSColor.green.withAlphaComponent(0.4)
                renderer.lineWidth = 3.0
                return renderer
            }
            
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let v2xAnn = view.annotation as? V2XAnnotation {
                DispatchQueue.main.async {
                    self.parent.selectedObject = SelectedObjectWrapper(value: v2xAnn.object)
                }
            }
        }
        
        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            DispatchQueue.main.async {
                self.parent.selectedObject = nil
            }
        }
    }
}

// MARK: - V2XMapViewContainer mit HUD Panel
struct V2XMapViewContainer: View {
    @Bindable var hardwareManager: V2XHardwareManager
    @State private var selectedObject: V2XMapView.SelectedObjectWrapper? = nil
    
    var body: some View {
        ZStack {
            V2XMapView(
                hardwareManager: hardwareManager,
                vehicles: hardwareManager.vehicles,
                trafficLights: hardwareManager.trafficLights,
                dangerZones: hardwareManager.dangerZones,
                virtualSigns: hardwareManager.virtualSigns,
                collectiveObjects: hardwareManager.collectiveObjects,
                rtkCorrections: hardwareManager.rtkCorrections,
                myLocation: hardwareManager.myLocation,
                isOfflineMapActive: hardwareManager.isOfflineMapActive,
                selectedMBTilesPath: hardwareManager.selectedMBTilesPath,
                isMapTrackingActive: hardwareManager.isMapTrackingActive,
                isAutoFitAllActive: hardwareManager.isAutoFitAllActive,
                selectedObject: $selectedObject
            )
            
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🗺️ Offline-Karten & MBTiles")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.white)
                        
                        Toggle("Offline-Modus aktiv", isOn: $hardwareManager.isOfflineMapActive)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                        
                        Toggle("Automatisch nachführen (GPS)", isOn: $hardwareManager.isMapTrackingActive)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .disabled(hardwareManager.isAutoFitAllActive)
                        
                        // Neues Steuerungselement für Auto-Framing (Ausschnitt an alle Empfangsobjekte anpassen)
                        Toggle("Kartenausschnitt an alle Objekte anpassen", isOn: $hardwareManager.isAutoFitAllActive)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                        
                        HStack(spacing: 8) {
                            Button(action: { hardwareManager.importMBTilesFile() }) {
                                Label("Laden", systemImage: "square.and.arrow.down")
                            }
                            .controlSize(.small)
                            
                            Button(action: { hardwareManager.exportCacheToMBTiles() }) {
                                Label("Exportieren", systemImage: "square.and.arrow.up")
                            }
                            .controlSize(.small)
                            
                            Button(action: { hardwareManager.clearTileCache() }) {
                                Label("Cache leeren", systemImage: "trash")
                            }
                            .controlSize(.small)
                            .buttonStyle(.plain)
                            .foregroundColor(.red)
                        }
                        
                        if !hardwareManager.selectedMBTilesPath.isEmpty {
                            Text("Aktiv: \(URL(fileURLWithPath: hardwareManager.selectedMBTilesPath).lastPathComponent)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.green)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .padding()
                    Spacer()
                }
                Spacer()
            }
            
            if let selected = selectedObject {
                GeometryReader { _ in
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            V2XInspectorCard(selection: selected.value) {
                                selectedObject = nil
                            }
                            .frame(width: 320)
                            .padding()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .animation(.spring(), value: selectedObject != nil)
    }
}

// MARK: - Telemetry Inspector Card
struct V2XInspectorCard: View {
    let selection: SelectedV2XObject
    var onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
                .background(Color.gray)
            
            VStack(alignment: .leading, spacing: 6) {
                switch selection {
                case .vehicle(let v):
                    telemetryRow(label: "Station ID", value: "#\(v.id)")
                    telemetryRow(label: "Geschwindigkeit", value: String(format: "%.1f km/h", v.speed))
                    telemetryRow(label: "Kurs (Heading)", value: "\(Int(v.heading))°")
                    telemetryRow(label: "Status", value: v.isBraking ? "BREMST (Warnung!)" : "Rolle", valueColor: v.isBraking ? .red : .green)
                    telemetryRow(label: "Breiten-/Längengrad", value: String(format: "%.5f, %.5f", v.coordinate.latitude, v.coordinate.longitude))
                    telemetryRow(label: "Letztes Paket", value: v.lastSeen.formatted(.dateTime.hour().minute().second()))
                    
                case .trafficLight(let l):
                    telemetryRow(label: "Kreuzungs ID", value: "#\(l.id)")
                    telemetryRow(label: "Signalphase", value: l.currentPhase.uppercased(), valueColor: phaseColor(l.currentPhase))
                    telemetryRow(label: "Phasenwechsel", value: "in \(l.timeToChange) Sekunden")
                    telemetryRow(label: "Breiten-/Längengrad", value: String(format: "%.5f, %.5f", l.coordinate.latitude, l.coordinate.longitude))
                    
                case .dangerZone(let d):
                    telemetryRow(label: "Ereignis ID", value: "#\(d.id)")
                    telemetryRow(label: "Gefahrentyp", value: d.type.uppercased(), valueColor: .orange)
                    telemetryRow(label: "Wirkungsradius", value: "\(Int(d.radiusMeter)) Meter")
                    telemetryRow(label: "Breiten-/Längengrad", value: String(format: "%.5f, %.5f", d.coordinate.latitude, d.coordinate.longitude))
                    
                case .virtualSign(let s):
                    telemetryRow(label: "Schilder ID", value: "#\(s.id)")
                    telemetryRow(label: "Typ", value: s.type)
                    telemetryRow(label: "Zulässiges Limit", value: "\(s.value) km/h", valueColor: .red)
                    telemetryRow(label: "Breiten-/Längengrad", value: String(format: "%.5f, %.5f", s.coordinate.latitude, s.coordinate.longitude))
                    
                case .collectiveObject(let c):
                    telemetryRow(label: "Sensorquelle", value: c.sensorType)
                    telemetryRow(label: "Klassifikation", value: c.objectClass)
                    telemetryRow(label: "Relativgeschw.", value: String(format: "%.1f m/s", c.speed))
                    
                case .rtkCorrection(let r):
                    telemetryRow(label: "Basisstation ID", value: "#\(r.baseStationID)")
                    telemetryRow(label: "RTK-Status", value: r.correctionStatus, valueColor: .purple)
                    telemetryRow(label: "Signalstärke", value: "\(r.signalStrengthDBm) dBm")
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                .shadow(radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var title: String {
        switch selection {
        case .vehicle: return "🚙 CAM Telemetriedaten"
        case .trafficLight: return "🚦 SPATEM Phasensteuerung"
        case .dangerZone: return "⚠️ DENM Gefahrenmeldung"
        case .virtualSign: return "🛑 IVIM Elektronisches Schild"
        case .collectiveObject: return "👁️ CPM Fremdwahrnehmung"
        case .rtkCorrection: return "🛰️ RTCMEM Korrekturdaten"
        }
    }
    
    private func telemetryRow(label: String, value: String, valueColor: Color = .white) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }
    
    private func phaseColor(_ phase: String) -> Color {
        switch phase.lowercased() {
        case "green": return .green
        case "yellow": return .yellow
        default: return .red
        }
    }
}
