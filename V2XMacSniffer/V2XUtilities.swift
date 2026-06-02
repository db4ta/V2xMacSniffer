import Foundation

// MARK: - CSV Utilities (strukturierte Konsolidierung ohne Verhaltensänderung)
public enum CSVUtils {
    // Einheitlicher Headertext, identisch zu den bisherigen Aufrufen
    public static let defaultHeader = "Timestamp;Type;ID;Latitude;Longitude;Speed;Heading;Braking;Extra\n"

    // Falls eine Datei noch nicht existiert, schreibe den Header (keine Logikänderung)
    @discardableResult
    public static func ensureHeader(at url: URL, header: String = defaultHeader) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            return ((try? header.write(to: url, atomically: true, encoding: .utf8)) != nil)
        }
        return true
    }

    // Sichere Append-Operation (seekToEnd + write + close), exakt wie bisher praktiziert
    public static func appendLine(_ line: String, to url: URL) {
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

// MARK: - PCAP Utilities (strukturierte Konsolidierung ohne Verhaltensänderung)
public enum PCAPUtils {
    // PCAP Global Header (identisch zu deiner bisherigen Implementierung)
    public static func globalHeader() -> Data {
        var d = Data()
        d.append(contentsOf: [0xd4, 0xc3, 0xb2, 0xa1])
        d.append(contentsOf: [0x02, 0x00])
        d.append(contentsOf: [0x04, 0x00])
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        d.append(contentsOf: [0xff, 0xff, 0x00, 0x00])
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        return d
    }

    // Appendiere ein einzelnes Paket mit Zeitstempel (sekunden + mikrosekunden) und Länge
    public static func appendPacket(_ packet: Data, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }

        let timeInterval = Date().timeIntervalSince1970
        let seconds = UInt32(timeInterval)
        let microseconds = UInt32((timeInterval - Double(seconds)) * 1_000_000)
        let length = UInt32(packet.count)

        var header = Data()
        header.append(contentsOf: withUnsafeBytes(of: seconds.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: microseconds.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })

        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: header)
        try? handle.write(contentsOf: packet)
        try? handle.close()
    }

    // Schreibe Global Header, falls Datei noch nicht existiert
    public static func ensureGlobalHeader(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? globalHeader().write(to: url)
        }
    }
}

// MARK: - JSON Envelope Utilities (strukturierte Konsolidierung)
private struct JSONEnvelope<Payload: Encodable>: Encodable {
    let msgType: String
    let data: Payload
}

public enum JSONUtils {
    private static let encoder = JSONEncoder()

    // Encodiert ein beliebiges Encodable in einen JSON-String mit Newline (identisch zum bisherigen Sendeformat)
    public static func encodeLine<Payload: Encodable>(msgType: String, payload: Payload) -> String? {
        let env = JSONEnvelope(msgType: msgType, data: payload)
        guard let data = try? encoder.encode(env), let str = String(data: data, encoding: .utf8) else { return nil }
        return str + "\n"
    }
}
