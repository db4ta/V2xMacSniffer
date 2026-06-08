import Foundation
import CoreLocation

// MARK: - Dekodierte CAM-Struktur für die App-Logik
public struct CAMDecoded {
    public let stationID: Int
    public let latitude: Double
    public let longitude: Double
    public let speedMS: Double
    public let headingDeg: Double
    public let braking: Bool
}

// MARK: - Zentrale Decoder-Schnittstelle
public enum V2XDecoders {
    /// Dekodiert eine ETSI CAM-Nachricht aus einem binären UPER-Payload.
    /// ACHTUNG: Die genaue Feldreihenfolge/Bitbreite hängt von deiner Eingangsdatenkette ab
    /// (z. B. ob noch ein BTP/ITS-PDU-Header davor liegt). Passe die Reihenfolge/Offsets an
    /// deine reale Pipeline an. Diese Implementierung zeigt das korrekte bitgenaue Vorgehen
    /// (UPER, Two's Complement, Skalierung), verwendet aber generische Platzhalter für Felder,
    /// die je nach Spezifikation variieren können.
    public static func decodeCAM(from data: Data) -> CAMDecoded? {
        var r = UPERBitReader(data: data)

        // HINWEIS: Falls dein Payload einen zusätzlichen Header hat (z. B. BTP/ITS),
        // lies ihn hier zuerst mit r.readBits(...) und richte anschließend auf das CAM-PDU aus.
        // Beispiel: r.readBits(8) // messageID etc.

        // StationID: häufig 32 Bit unsigned (anpassen, falls anders)
        guard let stationIDRaw = r.readUnsigned(32) else { return nil }
        let stationID = Int(stationIDRaw)

        // Latitude/Longitude: 32 Bit signed, Two's Complement, Einheit 1e-7 Grad
        guard let latDeg = CITSDecoding.decodeLatitude(&r),
              let lonDeg = CITSDecoding.decodeLongitude(&r) else { return nil }

        // Speed: Beispiel 16 Bit, Skala 0.01 m/s (anpassen je nach CAM-Profile)
        let speedMS = CITSDecoding.decodeUnsignedScaled(&r, bits: 16, scale: 0.01) ?? 0.0

        // Heading: 12 Bit, 0.1°
        let headingDeg = CITSDecoding.decodeHeading(&r, bits: 12, scale: 0.1) ?? 0.0

        // Braking: 1 Bit (vereinfachtes Beispiel)
        let braking = (r.readBit() ?? 0) == 1

        // Plausibilisierung
        guard let normLat = GeoSanity.normalizeLatitude(latDeg) else { return nil }
        let normLon = GeoSanity.wrapLongitude(lonDeg)

        return CAMDecoded(
            stationID: stationID,
            latitude: normLat,
            longitude: normLon,
            speedMS: speedMS,
            headingDeg: headingDeg,
            braking: braking
        )
    }
}
