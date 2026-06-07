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
