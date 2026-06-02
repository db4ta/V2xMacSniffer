//
//  TCPReceiver.swift
//  v2x2map
//
//  Created for iOS 26.
//  Hochperformanter, asynchroner TCP-Client für den Empfang von JSON-Streams der macOS-Zentrale.
//

#if os(iOS) // Verhindert, dass der macOS-Compiler diese iOS-Client-Klasse fälschlicherweise baut

import Foundation
import Network
import OSLog
import CoreLocation

/// Hilfsstrukturen zum typsicheren Decodieren der JSON-Nachrichten vom macOS-Server
public struct TCPMessageEnvelope: Decodable {
    public let msgType: String
    public let data: TCPMessageData
}

public struct TCPMessageData: Decodable {
    public let id: Int
    public let latitude: Double?
    public let longitude: Double?
    public let coordinate: CoordinateHelper?
    public let speed: Double?
    public let speedKmH: Double?
    public let heading: Double?
    public let isBraking: Bool?
    public let currentPhase: String?
    public let timeToChange: Int?
    public let type: String? // Für Gefahrenzonen
    
    public struct CoordinateHelper: Decodable {
        public let latitude: Double
        public let longitude: Double
    }
}

@MainActor
public final class TCPReceiver: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.v2x2map.app", category: "TCPReceiver")
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.v2x2map.tcp.receiver", qos: .userInteractive)
    
    public var onNodeReceived: (@Sendable (CITSNode) -> Void)?
    public var onConnectionStatusChanged: (@Sendable (Bool) -> Void)?
    
    private var buffer = Data()
    
    public init() {}
    
    public func connect(host: String, port: UInt16) {
        disconnect()
        
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        
        let parameters = NWParameters.tcp
        connection = NWConnection(to: .hostPort(host: endpointHost, port: endpointPort), using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.logger.info("[+] TCP-Verbindung zur macOS-Zentrale hergestellt.")
                    self.onConnectionStatusChanged?(true)
                    self.startReading()
                case .failed(let error):
                    self.logger.error("[-] TCP-Verbindungsfehler: \(error.localizedDescription)")
                    self.onConnectionStatusChanged?(false)
                    self.disconnect()
                case .cancelled:
                    self.logger.info("[!] TCP-Verbindung beendet.")
                    self.onConnectionStatusChanged?(false)
                default:
                    break
                }
            }
        }
        
        connection?.start(queue: queue)
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }
    
    private func startReading() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            Task { @MainActor in
                if let data = data, !data.isEmpty {
                    self.buffer.append(data)
                    self.processBuffer()
                }
                
                if error == nil && !isComplete {
                    self.startReading()
                } else {
                    self.disconnect()
                }
            }
        }
    }
    
    private func processBuffer() {
        while let lfIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: 0..<lfIndex)
            buffer.removeSubrange(0...lfIndex)
            
            guard !lineData.isEmpty else { continue }
            
            do {
                let envelope = try JSONDecoder().decode(TCPMessageEnvelope.self, from: lineData)
                let node = self.mapEnvelopeToNode(envelope)
                self.onNodeReceived?(node)
            } catch {
                self.logger.error("[-] JSON Parsing fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
    
    private func mapEnvelopeToNode(_ envelope: TCPMessageEnvelope) -> CITSNode {
        let payload = envelope.data
        
        let lat = payload.coordinate?.latitude ?? payload.latitude ?? 0.0
        let lon = payload.coordinate?.longitude ?? payload.longitude ?? 0.0
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        
        let stationType: Int
        switch envelope.msgType.uppercased() {
        case "CAM":
            stationType = 1
        case "SPATEM":
            stationType = 2
        case "DENM":
            stationType = 3
        default:
            stationType = 1
        }
        
        let speed = payload.speedKmH ?? payload.speed ?? 0.0
        
        return CITSNode(
            id: UInt32(payload.id),
            coordinate: coordinate,
            speedKmH: speed,
            timestamp: Date(),
            stationType: stationType
        )
    }
}

#endif
