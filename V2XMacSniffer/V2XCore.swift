import Foundation
import CoreLocation

// Fahrzeug-Struktur mit Pfadhistorie (Schleppkurve)
struct V2XVehicle: Identifiable, Codable {
    let id: Int
    var coordinate: CLLocationCoordinate2D
    var heading: Double
    var speed: Double
    var isBraking: Bool
    var lastSeen: Date
    var history: [CLLocationCoordinate2D] = []
    
    enum CodingKeys: String, CodingKey { case id, heading, speed, isBraking, latitude, longitude }
    
    init(id: Int, coordinate: CLLocationCoordinate2D, heading: Double, speed: Double, isBraking: Bool, lastSeen: Date) {
        self.id = id
        self.coordinate = coordinate
        self.heading = heading
        self.speed = speed
        self.isBraking = isBraking
        self.lastSeen = lastSeen
        self.history = [coordinate]
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        heading = try c.decode(Double.self, forKey: .heading)
        speed = try c.decode(Double.self, forKey: .speed)
        isBraking = try c.decode(Bool.self, forKey: .isBraking)
        let lat = try c.decode(Double.self, forKey: .latitude)
        let lon = try c.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        lastSeen = Date()
        history = [coordinate]
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(heading, forKey: .heading)
        try c.encode(speed, forKey: .speed)
        try c.encode(isBraking, forKey: .isBraking)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }
    
    // Aktualisiert die Position und verhindert MapKit-Polygon-Triangulationsfehler
    mutating func updatePosition(to newCoordinate: CLLocationCoordinate2D, heading: Double, speed: Double, isBraking: Bool) {
        // Schutz vor ungültigen GPS-Ausreißern
        guard newCoordinate.latitude != 0.0 && newCoordinate.longitude != 0.0 else { return }
        
        // Verhindert das Schreiben identischer Koordinaten-Punkte (Schutz vor MapKit Triangulation Warnings)
        if let last = self.history.last, 
           abs(last.latitude - newCoordinate.latitude) < 0.000001 && 
           abs(last.longitude - newCoordinate.longitude) < 0.000001 {
            self.lastSeen = Date()
            return
        }
        
        self.coordinate = newCoordinate
        self.heading = heading
        self.speed = speed
        self.isBraking = isBraking
        self.lastSeen = Date()
        
        self.history.append(newCoordinate)
        if self.history.count > 15 {
            self.history.removeFirst()
        }
    }
}

// Gefahrenzonen-Struktur (DENM)
struct V2XDangerZone: Identifiable, Codable {
    let id: Int
    let type: String
    var coordinate: CLLocationCoordinate2D
    let radiusMeter: Double
    var lastSeen: Date = Date()
    
    enum CodingKeys: String, CodingKey { case id, type, radiusMeter, latitude, longitude }
    
    init(id: Int, type: String, coordinate: CLLocationCoordinate2D, radiusMeter: Double) {
        self.id = id
        self.type = type
        self.coordinate = coordinate
        self.radiusMeter = radiusMeter
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        radiusMeter = try c.decode(Double.self, forKey: .radiusMeter)
        coordinate = CLLocationCoordinate2D(latitude: try c.decode(Double.self, forKey: .latitude), longitude: try c.decode(Double.self, forKey: .longitude))
        lastSeen = Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(radiusMeter, forKey: .radiusMeter)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }
}

// Ampel-Struktur (SPATEM)
struct V2XTrafficLight: Identifiable, Codable {
    let id: Int
    var coordinate: CLLocationCoordinate2D
    var currentPhase: String
    var timeToChange: Int
    var lastSeen: Date = Date()
    
    enum CodingKeys: String, CodingKey { case id, currentPhase, timeToChange, latitude, longitude }
    
    init(id: Int, coordinate: CLLocationCoordinate2D, currentPhase: String, timeToChange: Int) {
        self.id = id
        self.coordinate = coordinate
        self.currentPhase = currentPhase
        self.timeToChange = timeToChange
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        currentPhase = try c.decode(String.self, forKey: .currentPhase)
        timeToChange = try c.decode(Int.self, forKey: .timeToChange)
        coordinate = CLLocationCoordinate2D(latitude: try c.decode(Double.self, forKey: .latitude), longitude: try c.decode(Double.self, forKey: .longitude))
        lastSeen = Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(currentPhase, forKey: .currentPhase)
        try c.encode(timeToChange, forKey: .timeToChange)
        try c.encode(coordinate.latitude, forKey: .latitude)
        try c.encode(coordinate.longitude, forKey: .longitude)
    }
}

// SLIP-Protokoll Dekoder
class SLIPDecoder {
    static func decode(rawBytes: Data) -> Data {
        var decoded = Data()
        var i = 0
        while i < rawBytes.count {
            let byte = rawBytes[i]
            if byte == 0xDB && i + 1 < rawBytes.count {
                let next = rawBytes[i + 1]
                if next == 0xDC { decoded.append(0xC0) }
                else if next == 0xDD { decoded.append(0xDB) }
                i += 1
            } else { decoded.append(byte) }
            i += 1
        }
        return decoded
    }
}
