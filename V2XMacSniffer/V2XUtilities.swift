import Foundation

// MARK: - Sicherheits-Scoped Hilfsfunktion
/// Hilft beim sicheren Zugriff auf Verzeichnisse und Dateien unter macOS mit oder ohne Sandbox.
private func performWriteSecurely(to url: URL, writeBlock: () -> Void) {
    let fileScoped = url.startAccessingSecurityScopedResource()
    let parentURL = url.deletingLastPathComponent()
    let parentScoped = parentURL.startAccessingSecurityScopedResource()
    
    defer {
        if fileScoped { url.stopAccessingSecurityScopedResource() }
        if parentScoped { parentURL.stopAccessingSecurityScopedResource() }
    }
    
    writeBlock()
}

// MARK: - CSV Utilities (Hochkompatibler, fehlersicherer Dateischreiber)
public enum CSVUtils {
    public static let defaultHeader = "Timestamp;Type;ID;Latitude;Longitude;Speed;Heading;Braking;Extra\n"

    @discardableResult
    public static func ensureHeader(at url: URL, header: String = defaultHeader) -> Bool {
        var success = false
        
        performWriteSecurely(to: url) {
            let fileManager = FileManager.default
            let path = url.path
            
            // 1. Erstelle übergeordnete Ordner falls nicht existent
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("[-] Fehler beim Erstellen des CSV-Verzeichnisses: \(error.localizedDescription)")
                    return
                }
            }
            
            // 2. Erstelle die Datei, falls sie noch nicht existiert
            if !fileManager.fileExists(atPath: path) {
                success = fileManager.createFile(atPath: path, contents: header.data(using: .utf8), attributes: nil)
                if success {
                    print("[+] CSV-Protokolldatei erfolgreich angelegt: \(url.lastPathComponent)")
                } else {
                    print("[-] CSV-Datei konnte nicht erstellt werden bei: \(path)")
                }
            } else {
                success = true
            }
        }
        
        return success
    }

    public static func appendLine(_ line: String, to url: URL) {
        performWriteSecurely(to: url) {
            _ = ensureHeader(at: url)

            guard let data = line.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                // Protokollierung ohne UI-Blockade
                print("[-] CSV-Schreibfehler bei \(url.lastPathComponent): \(error.localizedDescription)")
                
                // Automatischer Fallback in das temporäre macOS Verzeichnis bei persistenten Fehlern
                fallbackWrite(line: line, filename: url.lastPathComponent)
            }
        }
    }
    
    /// Schreibt im Notfall in das sichere temporäre Verzeichnis des Benutzers
    private static func fallbackWrite(line: String, filename: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let fallbackURL = tempDir.appendingPathComponent("fallback_\(filename)")
        if !FileManager.default.fileExists(atPath: fallbackURL.path) {
            try? defaultHeader.write(to: fallbackURL, atomically: true, encoding: .utf8)
        }
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: fallbackURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

// MARK: - PCAP Utilities (Robuste PCAP-Schreiber für Wireshark)
public enum PCAPUtils {
    public static func globalHeader() -> Data {
        var d = Data()
        d.append(contentsOf: [0xd4, 0xc3, 0xb2, 0xa1]) // Magic Number (Mikrosekunden Auflösung)
        d.append(contentsOf: [0x02, 0x00])             // Major Version
        d.append(contentsOf: [0x04, 0x00])             // Minor Version
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // GMT Abweichung
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Genauigkeit der Zeitstempel
        d.append(contentsOf: [0xff, 0xff, 0x00, 0x00]) // Maximale Paketlänge (65535 Bytes)
        d.append(contentsOf: [0x69, 0x00, 0x00, 0x00]) // Link-Layer-Type: 105 (IEEE 802.11p für Wireshark C-ITS Decoder)
        return d
    }

    public static func ensureGlobalHeader(at url: URL) {
        performWriteSecurely(to: url) {
            let fileManager = FileManager.default
            let path = url.path
            
            let directory = url.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            }
            
            if !fileManager.fileExists(atPath: path) {
                let success = fileManager.createFile(atPath: path, contents: globalHeader(), attributes: nil)
                if success {
                    print("[+] PCAP-Protokolldatei erfolgreich angelegt: \(url.lastPathComponent)")
                } else {
                    print("[-] PCAP-Datei konnte nicht erstellt werden bei: \(path)")
                }
            }
        }
    }

    public static func appendPacket(_ packet: Data, to url: URL) {
        performWriteSecurely(to: url) {
            ensureGlobalHeader(at: url)

            do {
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
                try handle.close()
            } catch {
                print("[-] PCAP-Schreibfehler bei \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - JSON Envelope Utilities
private struct JSONEnvelope<Payload: Encodable>: Encodable {
    let msgType: String
    let data: Payload
}

public enum JSONUtils {
    private static let encoder = JSONEncoder()

    public static func encodeLine<Payload: Encodable>(msgType: String, payload: Payload) -> String? {
        let env = JSONEnvelope(msgType: msgType, data: payload)
        guard let data = try? encoder.encode(env), let str = String(data: data, encoding: .utf8) else { return nil }
        return str + "\n"
    }
}
/// MARK: - ASN.1 UPER Bit-Reader (unaligned, big-endian bit order)
public struct BitReader {
    private let bytes: [UInt8]
    private(set) public var bitIndex: Int = 0 // absolute bit position from start

    public init(data: Data) {
        self.bytes = Array(data)
        self.bitIndex = 0
    }

    public var bitsRemaining: Int { bytes.count * 8 - bitIndex }
    public var isAtEnd: Bool { bitsRemaining <= 0 }

    /// Aligns to next byte boundary (if currently not aligned)
    public mutating func alignToByte() {
        let rem = bitIndex & 7
        if rem != 0 { bitIndex += (8 - rem) }
    }

    /// Reads a single bit (MSB-first within each byte). Returns nil if no bits remain.
    public mutating func readBit() -> UInt8? {
        guard bitIndex < bytes.count * 8 else { return nil }
        let byteOffset = bitIndex >> 3
        let bitOffsetInByte = 7 - (bitIndex & 7) // MSB-first
        let b = bytes[byteOffset]
        let bit = (b >> bitOffsetInByte) & 0x01
        bitIndex += 1
        return bit
    }

    /// Reads `count` bits as an unsigned value (up to 64). Returns nil on overflow/end.
    public mutating func readBits(_ count: Int) -> UInt64? {
        precondition(count >= 0 && count <= 64, "readBits count out of range")
        if count == 0 { return 0 }
        guard bitsRemaining >= count else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            guard let bit = readBit() else { return nil }
            value = (value << 1) | UInt64(bit)
        }
        return value
    }

    /// Reads an unsigned integer with exactly `bitCount` bits and returns as UInt.
    public mutating func readUnsigned(_ bitCount: Int) -> UInt? {
        guard let v = readBits(bitCount) else { return nil }
        return UInt(v)
    }

    /// Reads a signed two's complement integer occupying exactly `bitCount` bits.
    /// Example: for ETSI DE_Latitude/Longitude use bitCount=32 and convert to Int32.
    public mutating func readSigned(_ bitCount: Int) -> Int64? {
        precondition(bitCount >= 1 && bitCount <= 64, "readSigned bitCount out of range")
        guard let raw = readBits(bitCount) else { return nil }
        // If top bit (sign) is set, extend with ones.
        let signMask: UInt64 = 1 << (bitCount - 1)
        if (raw & signMask) != 0 {
            // Negative number: sign-extend into 64 bits
            let extensionMask: UInt64 = ~((1 << bitCount) - 1)
            let extended = raw | extensionMask
            return Int64(bitPattern: extended)
        } else {
            return Int64(raw)
        }
    }

    /// Reads exactly `byteCount` bytes, regardless of current bit alignment (bit-accurate copy).
    /// Useful when UPER encodes octet strings that may not be byte-aligned (rare but possible via length + bits).
    public mutating func readBytes(_ byteCount: Int) -> Data? {
        guard byteCount >= 0 else { return nil }
        if byteCount == 0 { return Data() }
        // If already byte-aligned, we can slice fast.
        if (bitIndex & 7) == 0 {
            let start = bitIndex >> 3
            let end = start + byteCount
            guard end <= bytes.count else { return nil }
            bitIndex += byteCount * 8
            return Data(bytes[start..<end])
        }
        // Otherwise, assemble byte-by-byte via readBits(8)
        var out = Data(capacity: byteCount)
        for _ in 0..<byteCount {
            guard let v = readBits(8) else { return nil }
            out.append(UInt8(v & 0xFF))
        }
        return out
    }
}

// MARK: - ETSI / C-ITS Decoding Helpers
public enum CITSDecoding {
    /// Reads a presence map of `count` bits and returns them as a boolean array (MSB-first within the sequence).
    public static func readPresenceMap(_ reader: inout BitReader, count: Int) -> [Bool]? {
        guard count >= 0 else { return nil }
        if count == 0 { return [] }
        var flags: [Bool] = []
        flags.reserveCapacity(count)
        for _ in 0..<count {
            guard let b = reader.readBit() else { return nil }
            flags.append(b != 0)
        }
        return flags
    }

    /// Decodes ETSI DE_Latitude (32-bit signed, unit = 1e-7 degree). Returns degrees as Double.
    public static func decodeLatitude(_ reader: inout BitReader) -> Double? {
        guard let v = reader.readSigned(32) else { return nil }
        // Clamp to ETSI range if needed: [-900000000 .. 900000001] (optional)
        let int32 = Int32(truncatingIfNeeded: v)
        return Double(int32) / 10_000_000.0
    }

    /// Decodes ETSI DE_Longitude (32-bit signed, unit = 1e-7 degree). Returns degrees as Double.
    public static func decodeLongitude(_ reader: inout BitReader) -> Double? {
        guard let v = reader.readSigned(32) else { return nil }
        let int32 = Int32(truncatingIfNeeded: v)
        return Double(int32) / 10_000_000.0
    }

    /// Decodes an unsigned integer with a given bit width and scale factor.
    /// Example: speed (e.g., 16 bits) with scale to m/s or km/h depending on spec.
    public static func decodeUnsignedScaled(_ reader: inout BitReader, bits: Int, scale: Double) -> Double? {
        guard let v = reader.readBits(bits) else { return nil }
        return Double(v) * scale
    }

    /// Decodes a signed integer with a given bit width and scale factor.
    public static func decodeSignedScaled(_ reader: inout BitReader, bits: Int, scale: Double) -> Double? {
        guard let v = reader.readSigned(bits) else { return nil }
        return Double(v) * scale
    }
}

// MARK: - Sanity helpers for angles and ranges
public enum GeoSanity {
    /// Normalizes latitude to [-90, 90]. If value is out of range, returns nil to indicate corrupted parse.
    public static func normalizeLatitude(_ lat: Double) -> Double? {
        guard lat >= -90.0, lat <= 90.0 else { return nil }
        return lat
    }

    /// Normalizes longitude to [-180, 180]. If out of range, wraps to [-180, 180].
    public static func wrapLongitude(_ lon: Double) -> Double {
        var x = lon
        while x < -180.0 { x += 360.0 }
        while x > 180.0 { x -= 360.0 }
        return x
    }
}

// MARK: - Example parse snippet (documentation only)
/*
 Usage example inside your CAM/DENM/SPATEM/MAPEM decoders:

 var reader = BitReader(data: payloadData)
 // Read optional fields presence bits first, as defined by the specific ASN.1 spec.
 if let presence = CITSDecoding.readPresenceMap(&reader, count: N) {
     // presence[i] tells whether the next field is present; only read it if true.
 }
 // Latitude/Longitude (32-bit signed, 1e-7 degrees):
 if let lat = CITSDecoding.decodeLatitude(&reader), let normLat = GeoSanity.normalizeLatitude(lat) {
     // use normLat
 }
 if let lon = CITSDecoding.decodeLongitude(&reader) {
     let wrappedLon = GeoSanity.wrapLongitude(lon)
     // use wrappedLon
 }
*/

// MARK: - UPER alias for clarity
public typealias UPERBitReader = BitReader

// MARK: - Additional C-ITS field helpers
public extension CITSDecoding {
    /// Decodes ETSI heading (typisch 12 Bit, 0.1° Auflösung). Ergebnis in Grad [0, 360).
    /// Hinweis: Konkrete Bitbreite/Skalierung je nach Nachrichtentyp prüfen (CAM, DENM, SPATEM, MAPEM).
    static func decodeHeading(_ reader: inout BitReader, bits: Int = 12, scale: Double = 0.1) -> Double? {
        guard let raw = reader.readBits(bits) else { return nil }
        let deg = Double(raw) * scale
        // Begrenze auf [0, 360)
        if deg >= 360.0 { return deg.truncatingRemainder(dividingBy: 360.0) }
        if deg < 0.0 { return (deg.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) }
        return deg
    }

    /// Decodes speed with given bit width and scale. Example: 16 Bits, 0.01 m/s etc.
    static func decodeSpeed(_ reader: inout BitReader, bits: Int, scale: Double) -> Double? {
        decodeUnsignedScaled(&reader, bits: bits, scale: scale)
    }
}

// MARK: - Guarded extraction helpers
public enum SafeExtract {
    /// Returns nil if value is out of plausible latitude range.
    public static func latitude(_ lat: Double) -> Double? { GeoSanity.normalizeLatitude(lat) }
    /// Always wraps longitude to [-180, 180].
    public static func longitude(_ lon: Double) -> Double { GeoSanity.wrapLongitude(lon) }
}
