import SwiftUI
import MapKit
import AppKit

// MARK: - ERWEITERTES C-ITS DATENMODELL
enum V2XMessageType: String, Codable, CaseIterable {
    case CAM = "CAM"
    case DENM = "DENM"
    case SPATEM = "SPATEM"
    case MAPEM = "MAPEM"
    case IVIM = "IVIM"
    case CPM = "CPM"
}

struct V2XPacket: Identifiable, Equatable {
    let id = UUID()
    let stationID: UInt32
    let messageType: V2XMessageType
    let timestamp: Date
    let coordinates: CLLocationCoordinate2D
    let rawHex: String
    let fullJsonString: String
    let specificPayload: [String: Any]

    static func == (lhs: V2XPacket, rhs: V2XPacket) -> Bool {
        return lhs.id == rhs.id
    }
}

// Dedizierter Formatter für Ports, der jegliche Tausendertrennung (Gruppierung) unterdrückt
private let portFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.usesGroupingSeparator = false
    return formatter
}()

struct ContentView: View {
    // Shared State Schnittstelle
    var hw: V2XHardwareManager
    
    // Nativer SwiftUI Fenstermanager
    @Environment(\.openWindow) private var openSwiftUIWindow
    @Environment(\.dismissWindow) private var dismissSwiftUIWindow

    // Typsichere Direktzugriffe ohne unsicheres KVC-AnyObject-Casting zur Vermeidung von Laufzeit-Crashes
    private var v2xIsOpen: Bool { hw.v2xPortOpen }
    private var v2xIsManuallyConnected: Bool { hw.isV2XManuallyConnected }
    private var gpsIsOpen: Bool { hw.gpsPortOpen }
    private var gpsIsManuallyConnected: Bool { hw.isGPSManuallyConnected }
    
    // Live-Feed der neu strukturierten tshark V2X Pakete
    @State private var livePackets: [V2XPacket] = []
    @State private var selectedPacket: V2XPacket? = nil
    @State private var lastIncomingCoordinate: CLLocationCoordinate2D? = nil
    @State private var isShowingDetailPopover = false
    
    var body: some View {
        // Lokale Bindable-Deklaration für fehlerfreie SwiftUI-Bindings
        @Bindable var hw = hw
        
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("V2X Mac-Zentrale").font(.headline).bold()
                        Spacer()
                        Button(action: { hw.scanPorts() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Ports scannen")
                    }
                    
                    // Live Test-Generator zur Simulation von echtem tshark-Datenfluss
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TSHARK LIVE-SIMULATOR").font(.caption2).bold().foregroundColor(.secondary)
                        Button(action: simulateIncomingTsharkJSON) {
                            Label("tshark JSON einspeisen", systemImage: "bolt.horizontal.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                    
                    Divider()
                    
                    // Status-Leuchtdioden
                    Group {
                        HStack {
                            Circle()
                                .fill(v2xIsOpen ? .green : (v2xIsManuallyConnected ? .yellow : .red))
                                .frame(width: 8, height: 8)
                            Text("V2X-USB (\(hw.lockedV2XBaud))")
                        }
                        HStack {
                            Circle()
                                .fill(gpsIsOpen ? .green : (gpsIsManuallyConnected ? .yellow : .red))
                                .frame(width: 8, height: 8)
                            Text("GPS-USB (\(hw.lockedGPSBaud))")
                        }
                        HStack {
                            Circle()
                                .fill(hw.serverRunning ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text("iOS-Server (Port \(hw.serverPort.description))")
                        }
                    }.font(.caption)
                    
                    Divider()
                    
                    // ESP32 V2X-Empfänger Steuerung
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ESP32 V2X MODEM").font(.caption).bold().foregroundColor(.gray)
                        
                        Picker("Port:", selection: $hw.selectedV2XPort) {
                            Text("Kein Port ausgewählt").tag("")
                            ForEach(hw.availablePorts, id: \.self) { port in
                                Text(port.replacingOccurrences(of: "/dev/cu.", with: "")).tag(port)
                            }
                        }
                        .labelsHidden()
                        .disabled(v2xIsManuallyConnected)
                        
                        HStack {
                            Text("Baudrate:").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $hw.selectedV2XBaud) {
                                ForEach(hw.v2xBaudOptions, id: \.self) { baud in
                                    if baud == "921600" {
                                        Text("\(baud) (pit711 Standard)").tag(baud).font(.headline).bold()
                                    } else {
                                        Text(baud).tag(baud)
                                    }
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            .disabled(v2xIsManuallyConnected)
                        }
                        
                        Button(action: { hw.toggleV2XConnection() }) {
                            Text(v2xIsManuallyConnected ? "V2X trennen" : "V2X verbinden")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(v2xIsManuallyConnected ? .red : .blue)
                    }
                    
                    Divider()
                    
                    // --- OFFLINE-KARTEN CACHE MANAGER ---
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OFFLINE-KARTEN CACHE").font(.caption).bold().foregroundColor(.gray)
                        
                        Toggle("Offline-Modus aktivieren", isOn: $hw.isOfflineMapActive)
                            .font(.caption).bold()
                            .toggleStyle(.checkbox)
                        
                        Text("Kacheln werden bei aktivem Internet geladen und für den Offline-Einsatz automatisch auf der Festplatte zwischengespeichert.").font(.system(size: 10)).foregroundColor(.secondary)
                        
                        Divider().padding(.vertical, 2)
                        
                        Text("Region vorab herunterladen:").font(.caption2).bold().foregroundColor(.secondary)
                        Picker("", selection: $hw.selectedOfflineRegion) {
                            ForEach(hw.offlineRegionOptions, id: \.self) { region in
                                Text(region).tag(region)
                            }
                        }
                        .labelsHidden()
                        .disabled(hw.isDownloadingMap)
                        
                        if hw.isDownloadingMap {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: hw.downloadProgress)
                                    .progressViewStyle(.linear)
                                HStack {
                                    Text("\(hw.downloadedTilesCount) / \(hw.totalTilesToDownload) Kacheln")
                                        .font(.system(size: 9, design: .monospaced))
                                    Spacer()
                                    Button("Abbrechen") {
                                        hw.cancelOfflineMapDownload()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 9))
                                    .foregroundColor(.red)
                                }
                            }
                            .padding(.top, 4)
                        } else {
                            Button(action: { hw.startOfflineMapDownload() }) {
                                Label("Region herunterladen", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                        }
                    }
                    
                    Divider()
                    
                    // --- FAHRZEUGSPUREN (TRAILS) STEUERUNG ---
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FAHRZEUGSPUREN (TRAILS)").font(.caption).bold().foregroundColor(.gray)

                        Toggle("Trails behalten (kein Auto-Prune)", isOn: $hw.keepVehiclesAsTrail)
                            .font(.caption).bold()
                            .toggleStyle(.checkbox)
                            .help("Wenn aktiv, werden inaktive Fahrzeuge nicht automatisch nach 10s entfernt; ihre Spur bleibt erhalten.")

                        HStack(spacing: 8) {
                            Text("Max. Punkte pro Spur:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Stepper(value: $hw.maxTrailPointsPerVehicle, in: 20...2000, step: 20) {
                                Text("\(hw.maxTrailPointsPerVehicle)")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .disabled(!hw.keepVehiclesAsTrail)
                            .help("Begrenzt die Anzahl der gespeicherten Trailpunkte pro Fahrzeug.")
                        }
                    }

                    Divider()
                    
                    // GPS Empfänger Steuerung
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GPS-EMPFÄNGER (NMEA)").font(.caption).bold().foregroundColor(.gray)
                        
                        Picker("Port:", selection: $hw.selectedGPSPort) {
                            Text("Kein Port ausgewählt").tag("")
                            ForEach(hw.availablePorts, id: \.self) { port in
                                Text(port.replacingOccurrences(of: "/dev/cu.", with: "")).tag(port)
                            }
                        }
                        .labelsHidden()
                        .disabled(gpsIsManuallyConnected)
                        
                        HStack {
                            Text("Baudrate:").font(.caption).foregroundColor(.secondary)
                            Picker("", selection: $hw.selectedGPSBaud) {
                                ForEach(hw.gpsBaudOptions, id: \.self) { baud in
                                    Text(baud).tag(baud)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            .disabled(gpsIsManuallyConnected)
                        }
                        
                        Button(action: { hw.toggleGPSConnection() }) {
                            Text(gpsIsManuallyConnected ? "GPS trennen" : "GPS verbinden")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(gpsIsManuallyConnected ? .red : .blue)
                    }
                    
                    Divider()
                    
                    // iOS TCP-Server Konfiguration & Web-Server
                    VStack(alignment: .leading, spacing: 6) {
                        Text("iOS INTERACTIVE SERVER").font(.caption).bold().foregroundColor(.gray)
                        HStack {
                            Text("TCP Port:")
                            TextField("Port", value: $hw.serverPort, formatter: portFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .disabled(hw.serverRunning)
                            Spacer()
                            Stepper("", value: $hw.serverPort, in: 1024...65535)
                                .labelsHidden()
                                .disabled(hw.serverRunning)
                        }.font(.caption)
                        
                        Toggle("Web-Debugger auf Port \((hw.serverPort + 1).description) aktiv", isOn: $hw.isWebDebugServerEnabled)
                            .font(.caption)
                            .disabled(hw.serverRunning)
                            .padding(.vertical, 2)
                        
                        Button(action: { hw.toggleServer() }) {
                            Text(hw.serverRunning ? "Server stoppen" : "Server starten")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(hw.serverRunning ? .red : .green)
                        .buttonStyle(.borderedProminent)
                        
                        // Anzeige verbundener Clients
                        if hw.serverRunning {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Verbundene Clients:")
                                        .font(.caption)
                                        .bold()
                                    Spacer()
                                    Text("\(hw.connectedClients.count)")
                                        .font(.caption)
                                        .bold()
                                        .foregroundColor(.green)
                                }
                                
                                if !hw.connectedClients.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(hw.connectedClients, id: \.self) { ip in
                                            HStack {
                                                Image(systemName: "iphone")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                Text(ip)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.primary)
                                            }
                                        }
                                    }
                                    .padding(6)
                                    .background(Color.black.opacity(0.15))
                                    .cornerRadius(4)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    
                    Divider()
                    
                    // DATEN-AUFZEICHNUNG (FORENSIK) MIT SPEICHERORT-WAHL
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DATEN-AUFZEICHNUNG (FORENSIK)").font(.caption).bold().foregroundColor(.gray)
                        
                        HStack {
                            Text("Ordner:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(hw.logDirectoryPathString)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.blue)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button("Ändern...") {
                                hw.selectLogDirectory()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        
                        Toggle("Wireshark PCAP Exporter", isOn: $hw.isPCAPLoggingActive)
                            .font(.caption)
                        if hw.isPCAPLoggingActive {
                            Text("Datei: \(hw.pcapFilePathString)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Toggle("CSV Tabellen-Logger", isOn: $hw.isCSVLoggingActive)
                            .font(.caption)
                            .padding(.top, 2)
                        if hw.isCSVLoggingActive {
                            Text("Datei: \(hw.csvFilePathString)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Divider()
                    
                    // Debug-Schalter zum Ein- und Ausschalten des separaten macOS Fensters
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Natives Debugger-Fenster", isOn: $hw.isDebugWindowActive)
                            .font(.caption).bold()
                            .onChange(of: hw.isDebugWindowActive) { _, newValue in
                                if newValue {
                                    openSwiftUIWindow(id: "debug_window")
                                } else {
                                    dismissSwiftUIWindow(id: "debug_window")
                                }
                            }
                        
                        if hw.isDebugWindowActive {
                            Button(action: { openSwiftUIWindow(id: "debug_window") }) {
                                Label("Debugger anzeigen", systemImage: "terminal.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.purple)
                        }
                    }
                    
                    // GLOSA Dashboard-Anzeige
                    if hw.myLocation != nil && !hw.trafficLights.isEmpty {
                        Divider()
                        Text("GLOSA Grüne Welle").font(.caption).bold().foregroundColor(.blue)
                        ForEach(Array(hw.trafficLights.values)) { light in
                            if let speedRecommendation = hw.calculateGLOSASpeed(to: light) {
                                HStack {
                                    Circle()
                                        .fill(light.currentPhase == "green" ? .green : (light.currentPhase == "yellow" ? .yellow : .red))
                                        .frame(width: 10, height: 10)
                                    Text("Licht #\(light.id):")
                                    Spacer()
                                    Text("\(Int(speedRecommendation)) km/h")
                                        .bold()
                                        .foregroundColor(.green)
                                }.font(.caption2)
                            }
                        }
                    }
                    
                    Divider()
                    Text("Log-Terminal").font(.caption).foregroundColor(.gray)
                    
                    HStack(spacing: 8) {
                        Button {
                            hw.copyLogsToClipboard()
                        } label: {
                            Label("Logs kopieren", systemImage: "doc.on.doc")
                        }
                        Button {
                            hw.exportLogsToFile()
                        } label: {
                            Label("Logs exportieren…", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    
                    // Haupt-Log-Terminal
                    List(Array(hw.logs.enumerated()), id: \.offset) { _, log in
                        Text(displayText(log))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    .background(.black).cornerRadius(4)
                    .frame(minHeight: 120)
                }
                .padding()
            }
            .frame(minWidth: 260, maxWidth: 350)
        } detail: {
            ZStack {
                CITSMapView(
                    hw: hw,
                    livePackets: livePackets,
                    selectedPacket: $selectedPacket,
                    lastIncomingCoordinate: $lastIncomingCoordinate
                )
                .edgesIgnoringSafeArea(.all)
            }
            .popover(item: $selectedPacket) { packet in
                PacketDetailPopover(packet: packet)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
    }
    
    // Liefert eine String-Darstellung für beliebige LogEntry-Objekte
    private func displayText(_ entry: LogEntry) -> String {
        return entry.text
    }
    
    // Simuliert den asynchronen tshark JSON Parser-Prozess im Hintergrund
    private func simulateIncomingTsharkJSON() {
        let types: [V2XMessageType] = [.CAM, .DENM, .SPATEM, .MAPEM, .IVIM, .CPM]
        let selectedType = types.randomElement() ?? .CAM
        
        let randomStationID = UInt32.random(in: 1000...9999)
        let stuttgartCenter = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
        let packetCoordinate = CLLocationCoordinate2D(
            latitude: stuttgartCenter.latitude + Double.random(in: -0.005...0.005),
            longitude: stuttgartCenter.longitude + Double.random(in: -0.005...0.005)
        )
        
        // Simulierter originaler tshark JSON-Output
        let mockJSON = """
        {
          "timestamp": "\(ISO8601DateFormatter().string(from: Date()))",
          "stationID": \(randomStationID),
          "messageType": "\(selectedType.rawValue)",
          "coordinates": {
            "latitude": \(packetCoordinate.latitude),
            "longitude": \(packetCoordinate.longitude)
          },
          "rawHex": "00C0DECAFE\(String(randomStationID, radix: 16).uppercased())",
          "protocol": "ETSI C-ITS V2X Over ITS-G5",
          "details": {
            "speed": \(Double.random(in: 30...120)),
            "heading": \(Double.random(in: 0...359)),
            "phase": "\(["green", "yellow", "red"].randomElement() ?? "green")",
            "countdown": \(Int.random(in: 5...45)),
            "dangerType": "\(["Crash", "Roadworks", "Ice"].randomElement() ?? "Roadworks")"
          }
        }
        """
        
        // Striktes Threading: JSON Parsing im Hintergrund-Worker
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = mockJSON.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            
            let timestampString = jsonObject["timestamp"] as? String ?? ""
            let formatter = ISO8601DateFormatter()
            let parsedDate = formatter.date(from: timestampString) ?? Date()
            
            let details = jsonObject["details"] as? [String: Any] ?? [:]
            
            let parsedPacket = V2XPacket(
                stationID: randomStationID,
                messageType: selectedType,
                timestamp: parsedDate,
                coordinates: packetCoordinate,
                rawHex: jsonObject["rawHex"] as? String ?? "",
                fullJsonString: mockJSON,
                specificPayload: details
            )
            
            // Zurück auf dem Main-Thread (@MainActor) das UI aktualisieren & Kamera zentrieren
            DispatchQueue.main.async {
                self.livePackets.append(parsedPacket)
                self.lastIncomingCoordinate = packetCoordinate // Löst automatische Kamera-Zentrierung aus
                self.hw.addLog("[tshark] Neues \(selectedType.rawValue) Paket verarbeitet (Station: \(randomStationID))")
            }
        }
    }
}

// --- INTERAKTIVES POPUP DETAILFENSTER (OpenTrafficMap-Style) ---
struct PacketDetailPopover: View {
    let packet: V2XPacket
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Übersicht").tag(0)
                Text("Geräte-JSON").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            if selectedTab == 0 {
                // TAB 1: Lesbare Meta- und Zustandsdaten
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("C-ITS Paketübersicht")
                            .font(.headline)
                        Spacer()
                        Text(packet.messageType.rawValue)
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Stations-ID:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(packet.stationID)")
                                .bold()
                        }
                        HStack {
                            Text("Zeitstempel:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(packet.timestamp.formatted(date: .omitted, time: .standard))
                        }
                        HStack {
                            Text("Breitengrad:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.6f", packet.coordinates.latitude))
                                .monospaced()
                        }
                        HStack {
                            Text("Längengrad:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.6f", packet.coordinates.longitude))
                                .monospaced()
                        }
                    }
                    .font(.subheadline)
                    
                    Divider()
                    
                    Text("Spezifische Payload-Attribute:")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(packet.specificPayload.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(key.capitalized)
                                        .font(.caption)
                                        .bold()
                                    Spacer()
                                    Text("\(String(describing: packet.specificPayload[key] ?? ""))")
                                        .font(.caption)
                                        .monospaced()
                                }
                            }
                        }
                    }
                }
                .padding()
            } else {
                // TAB 2: Geräte-JSON mit Syntax-Darstellung & Clipboard-Schnittstelle
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Originales Wireshark tshark-Dokument")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(packet.fullJsonString, forType: .string)
                        }) {
                            Label("JSON kopieren", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding([.horizontal, .top])
                    
                    ScrollView {
                        Text(packet.fullJsonString)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                    }
                    .padding([.horizontal, .bottom])
                }
            }
        }
        .frame(width: 440, height: 380)
    }
}

// --- ERWEITERTE ANNOTATIONS-KLASSE FÜR LIVE-TSHARK INTERACTION ---
class CITSPacketAnnotation: MKPointAnnotation {
    var packet: V2XPacket?
    var customIconType: V2XMessageType?
}

// --- NATIVE MAPKIT-SCHNITTSTELLE FÜR macOS ---
struct CITSMapView: NSViewRepresentable {
    let hw: V2XHardwareManager
    var livePackets: [V2XPacket]
    @Binding var selectedPacket: V2XPacket?
    @Binding var lastIncomingCoordinate: CLLocationCoordinate2D?
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Initialer Fokus auf Stuttgart / Winnenden
        let center = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
        mapView.setRegion(region, animated: false)
        
        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        updateTileOverlay(mapView)
        updateOverlays(mapView)
        updateAnnotations(mapView)
        
        // VOLLAUTOMATISCHE KARTEN-ZENTRIERUNG
        if let newCoord = lastIncomingCoordinate {
            DispatchQueue.main.async {
                mapView.setCenter(newCoord, animated: true)
                self.lastIncomingCoordinate = nil // Trigger zurücksetzen
            }
        }
    }
    
    private func updateTileOverlay(_ mapView: MKMapView) {
        let hasOverlay = mapView.overlays.contains { $0 is CachedTileOverlay }
        
        if hw.isOfflineMapActive && !hasOverlay {
            let overlay = CachedTileOverlay()
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveRoads)
        } else if !hw.isOfflineMapActive && hasOverlay {
            let overlays = mapView.overlays.filter { $0 is CachedTileOverlay }
            mapView.removeOverlays(overlays)
        }
    }

    private func updateOverlays(_ mapView: MKMapView) {
        // Bereinigung alter Polylines
        let existingPolylines = mapView.overlays.filter { $0 is MKPolyline && !($0 is CachedTileOverlay) }
        mapView.removeOverlays(existingPolylines)
        
        // 1. MAPEM - Fahrspuren einzeichnen
        for mapGeo in hw.mapGeometries.values {
            guard mapGeo.laneCoordinates.count >= 2 else { continue }
            let polyline = MKPolyline(coordinates: mapGeo.laneCoordinates, count: mapGeo.laneCoordinates.count)
            polyline.title = "MAPEM_Polyline"
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
        
        // 2. MCM - Fahrt-Trajektorien einzeichnen
        for maneuver in hw.maneuvers.values {
            guard maneuver.trajectoryPoints.count >= 2 else { continue }
            let polyline = MKPolyline(coordinates: maneuver.trajectoryPoints, count: maneuver.trajectoryPoints.count)
            polyline.title = "MCM_Polyline"
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
        
        // 3. DYNAMISCHE SPATEM SPUREN (Aus tshark Live-Datenstrom)
        for packet in livePackets where packet.messageType == .SPATEM {
            let phase = packet.specificPayload["phase"] as? String ?? "red"
            let polyline = MKPolyline(coordinates: [
                CLLocationCoordinate2D(latitude: packet.coordinates.latitude - 0.0004, longitude: packet.coordinates.longitude - 0.0004),
                packet.coordinates
            ], count: 2)
            polyline.title = "SPATEM_LANE_\(phase)"
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
    }
    
    private func updateAnnotations(_ mapView: MKMapView) {
        // Lösche alle Annotationen vor dem Neuzeichnen, um Drift zu verhindern
        mapView.removeAnnotations(mapView.annotations)
        
        // Eigene GPS-Position einzeichnen
        if let myLoc = hw.myLocation {
            let annotation = MKPointAnnotation()
            annotation.coordinate = myLoc
            annotation.title = "Ich"
            mapView.addAnnotation(annotation)
        }
        
        // CAM Fahrzeuge
        for vehicle in hw.vehicles.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = vehicle.coordinate
            annotation.title = "Fahrzeug #\(vehicle.id)"
            mapView.addAnnotation(annotation)
        }
        
        // SPATEM Ampelanlagen
        for light in hw.trafficLights.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = light.coordinate
            annotation.title = "Ampel #\(light.id)"
            annotation.subtitle = "\(light.currentPhase.uppercased()) | \(light.timeToChange)s"
            mapView.addAnnotation(annotation)
        }
        
        // DENM Gefahrenzonen
        for zone in hw.dangerZones.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = zone.coordinate
            annotation.title = "Gefahr #\(zone.id)"
            annotation.subtitle = zone.type
            mapView.addAnnotation(annotation)
        }

        // IVIM Digitale Straßenschilder
        for sign in hw.virtualSigns.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = sign.coordinate
            annotation.title = "Schild #\(sign.id)"
            annotation.subtitle = "Tempolimit: \(sign.value) km/h"
            mapView.addAnnotation(annotation)
        }

        // CPM Radar/LiDAR-Fremdobjekte
        for obj in hw.collectiveObjects.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = obj.coordinate
            annotation.title = "Objekt #\(obj.id)"
            annotation.subtitle = "\(obj.objectClass) | \(obj.sensorType)"
            mapView.addAnnotation(annotation)
        }

        // SRM Prioritätsanfragen
        for req in hw.signalRequests.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = req.coordinate
            annotation.title = "SRM #\(req.id)"
            annotation.subtitle = "\(req.requesterType) -> Kreuzung \(req.targetIntersectionID)"
            mapView.addAnnotation(annotation)
        }

        // SSM Bestätigungen
        for status in hw.signalStatuses.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = status.coordinate
            annotation.title = "SSM #\(status.id)"
            annotation.subtitle = "Kreuzung \(status.intersectionID) -> \(status.priorityGranted ? "Gewährt" : "Abgelehnt")"
            mapView.addAnnotation(annotation)
        }

        // MAPEM Kreuzungszentren
        for mapGeo in hw.mapGeometries.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = mapGeo.centerCoordinate
            annotation.title = "MAPEM #\(mapGeo.id)"
            annotation.subtitle = mapGeo.name
            mapView.addAnnotation(annotation)
        }

        // MCM Manöver-Startpunkte
        for maneuver in hw.maneuvers.values {
            guard let startPoint = maneuver.trajectoryPoints.first else { continue }
            let annotation = MKPointAnnotation()
            annotation.coordinate = startPoint
            annotation.title = "Maneuver #\(maneuver.id)"
            annotation.subtitle = "Phase: \(maneuver.coordinationPhase)"
            mapView.addAnnotation(annotation)
        }

        // RTCMEM Referenzstationen
        for rtk in hw.rtkCorrections.values {
            let annotation = MKPointAnnotation()
            annotation.coordinate = rtk.coordinate
            annotation.title = "RTK-Basis #\(rtk.id)"
            annotation.subtitle = "RTK: \(rtk.correctionStatus) (\(rtk.signalStrengthDBm)dBm)"
            mapView.addAnnotation(annotation)
        }
        
        // LIVE TSHARK C-ITS ANNOTATIONEN RENDERN
        for packet in livePackets {
            let annotation = CITSPacketAnnotation()
            annotation.coordinate = packet.coordinates
            annotation.packet = packet
            annotation.customIconType = packet.messageType
            annotation.title = "\(packet.messageType.rawValue) (Station \(packet.stationID))"
            annotation.subtitle = "Klicke für detaillierte tshark JSON Analyse"
            mapView.addAnnotation(annotation)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CITSMapView
        
        init(_ parent: CITSMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            } else if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                
                if let title = polyline.title {
                    if title == "MAPEM_Polyline" {
                        renderer.strokeColor = .lightGray
                        renderer.lineWidth = 4.0
                        renderer.lineDashPattern = [6, 4]
                    } else if title == "MCM_Polyline" {
                        renderer.strokeColor = .systemYellow
                        renderer.lineWidth = 3.0
                    } else if title.hasPrefix("SPATEM_LANE_") {
                        let phase = title.replacingOccurrences(of: "SPATEM_LANE_", with: "")
                        renderer.strokeColor = (phase == "green") ? .systemGreen : ((phase == "yellow") ? .systemOrange : .systemRed)
                        renderer.lineWidth = 6.0
                    } else {
                        renderer.strokeColor = .systemBlue
                        renderer.lineWidth = 2.0
                    }
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        // INTERAKTIVE SELEKTIONS-VERNETZUNG ZU SWIFTUI POPUP
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let customAnnotation = view.annotation as? CITSPacketAnnotation,
               let packet = customAnnotation.packet {
                parent.selectedPacket = packet
            }
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "CITS_Annotation"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
            } else {
                view?.annotation = annotation
            }
            
            // Handelt es sich um ein dynamisches tshark-Paket?
            if let citsAnno = annotation as? CITSPacketAnnotation, let msgType = citsAnno.customIconType {
                switch msgType {
                case .CAM:
                    view?.markerTintColor = NSColor.systemBlue
                    view?.glyphImage = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
                case .DENM:
                    view?.markerTintColor = NSColor.systemRed
                    view?.glyphImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                case .SPATEM:
                    view?.markerTintColor = NSColor.systemOrange
                    view?.glyphImage = NSImage(systemSymbolName: "traffic.light.fill", accessibilityDescription: nil)
                case .MAPEM:
                    view?.markerTintColor = NSColor.systemGray
                    view?.glyphImage = NSImage(systemSymbolName: "map.fill", accessibilityDescription: nil)
                case .IVIM:
                    view?.markerTintColor = NSColor.systemRed
                    view?.glyphImage = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
                case .CPM:
                    view?.markerTintColor = Color(nsColor: .magenta).resolvedValue()
                    view?.glyphImage = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
                }
                return view
            }
            
            guard let title = annotation.title ?? "" else { return view }
            
            if title == "Ich" {
                view?.markerTintColor = NSColor.green
                view?.glyphImage = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("Fahrzeug #") {
                let idString = title.replacingOccurrences(of: "Fahrzeug #", with: "")
                if let id = Int(idString), let vehicle = parent.hw.vehicles[id] {
                    view?.markerTintColor = vehicle.isBraking ? NSColor.red : NSColor.blue
                    view?.glyphImage = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
                }
            } else if title.hasPrefix("Ampel #") {
                let idString = title.replacingOccurrences(of: "Ampel #", with: "")
                if let id = Int(idString), let light = parent.hw.trafficLights[id] {
                    switch light.currentPhase.lowercased() {
                    case "green": view?.markerTintColor = NSColor.green
                    case "yellow": view?.markerTintColor = NSColor.orange
                    default: view?.markerTintColor = NSColor.red
                    }
                    view?.glyphImage = NSImage(systemSymbolName: "traffic.light.fill", accessibilityDescription: nil)
                }
            } else if title.hasPrefix("Gefahr #") {
                view?.markerTintColor = NSColor.orange
                view?.glyphImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("Schild #") {
                view?.markerTintColor = NSColor.red
                view?.glyphImage = NSImage(systemSymbolName: "speedometer", accessibilityDescription: nil)
            } else if title.hasPrefix("Objekt #") {
                view?.markerTintColor = NSColor.purple
                view?.glyphImage = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: nil)
            } else if title.hasPrefix("SRM #") {
                view?.markerTintColor = NSColor.cyan
                view?.glyphImage = NSImage(systemSymbolName: "light.beacon.max.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("SSM #") {
                view?.markerTintColor = NSColor.blue
                view?.glyphImage = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("MAPEM #") {
                view?.markerTintColor = NSColor.gray
                view?.glyphImage = NSImage(systemSymbolName: "map.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("Maneuver #") {
                view?.markerTintColor = NSColor.yellow
                view?.glyphImage = NSImage(systemSymbolName: "point.topleft.down.to.point.bottomright.curvepath", accessibilityDescription: nil)
            } else if title.hasPrefix("RTK-Basis #") {
                view?.markerTintColor = Color(nsColor: .magenta).resolvedValue()
                view?.glyphImage = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            }
            
            return view
        }
    }
}

// --- DEBBUGING-FENSTER MIT EIGENER SEGMENTED-PICKER NAVIGATION ---
struct DebugConsoleView: View {
    var hw: V2XHardwareManager
    @State private var selectedTab = 0
    
    var body: some View {
        @Bindable var hw = hw
        
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BYTES RX (V2X)").font(.system(size: 9)).foregroundColor(.gray)
                    Text("\(hw.totalV2XBytesRx) B").font(.title3).bold().monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("BYTES RX (GPS)").font(.system(size: 9)).foregroundColor(.gray)
                    Text("\(hw.totalGPSBytesRx) B").font(.title3).bold().monospacedDigit()
                }
                Divider().frame(height: 35)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEKODIERTE C-ITS INFRASTRUKTUR-PAKETE").font(.system(size: 9)).foregroundColor(.gray)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("CAM: \(hw.decodedCAMs)").foregroundColor(.blue).bold()
                            Text("DENM: \(hw.decodedDENMs)").foregroundColor(.red).bold()
                            Text("SPATEM: \(hw.decodedSPATEMs)").foregroundColor(.orange).bold()
                            Text("MAPEM: \(hw.decodedMAPEMs)").foregroundColor(.gray).bold()
                            Text("IVIM: \(hw.decodedIVIMs)").foregroundColor(.red).bold()
                        }
                        HStack(spacing: 8) {
                            Text("CPM: \(hw.decodedCPMs)").foregroundColor(.purple).bold()
                            Text("SRM: \(hw.decodedSRMs)").foregroundColor(.cyan).bold()
                            Text("SSM: \(hw.decodedSSMs)").foregroundColor(.blue).bold()
                            Text("MCM: \(hw.decodedMCMs)").foregroundColor(.yellow).bold()
                            Text("RTCMEM: \(hw.decodedRTCMEMs)").foregroundColor(Color(nsColor: .magenta)).bold()
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                Spacer()
                Button(action: { hw.resetDebugCounters() }) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Zähler zurücksetzen")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            Picker("", selection: $selectedTab) {
                Label("Dashboard & Generator", systemImage: "chart.bar.xaxis").tag(0)
                Label("V2X Modem (SLIP)", systemImage: "cpu").tag(1)
                Label("GPS Empfänger (NMEA)", systemImage: "location.circle").tag(2)
                Label("Netzwerk-Diagnose & PCAP", systemImage: "network").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            switch selectedTab {
            case 0:
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("C-ITS SIGNAL-GENERATOR (HARDWARE-FREIE SIMULATION)").font(.caption).bold().foregroundColor(.secondary)
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            Button(action: { hw.simulateCAM() }) {
                                Label("CAM (Car)", systemImage: "car.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateDENM() }) {
                                Label("DENM (Hazard)", systemImage: "exclamationmark.triangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSPATEM() }) {
                                Label("SPATEM (LSA)", systemImage: "traffic.light.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateMAPEM() }) {
                                Label("MAPEM (Lane)", systemImage: "map.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateIVIM() }) {
                                Label("IVIM (Limit)", systemImage: "speedometer")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateCPM() }) {
                                Label("CPM (Objects)", systemImage: "figure.walk")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSRM() }) {
                                Label("SRM (Priority Req)", systemImage: "light.beacon.max.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSSM() }) {
                                Label("SSM (Priority OK)", systemImage: "checkmark.shield.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateMCM() }) {
                                Label("MCM (Cooperation)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateRTCMEM() }) {
                                Label("RTCMEM (RTK)", systemImage: "antenna.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    VStack(spacing: 0) {
                        HStack {
                            Text("Globaler System-Log").font(.caption).bold()
                            Spacer()
                            Button {
                                hw.copyLogsToClipboard()
                            } label: {
                                Label("Kopieren", systemImage: "doc.on.doc").font(.caption2)
                            }
                            Button {
                                hw.exportLogsToFile()
                            } label: {
                                Label("Exportieren", systemImage: "square.and.arrow.down").font(.caption2)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(NSColor.windowBackgroundColor))
                        
                        List(Array(hw.logs.enumerated()), id: \.offset) { _, log in
                            Text(displayText(log))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        .background(.black)
                    }
                }
                
            case 1:
                VStack(spacing: 8) {
                    HStack {
                        Text("ESP32 CLI Command Terminal").font(.caption).bold().foregroundColor(.secondary)
                        Spacer()
                        Button("Ping Test") { hw.sendRawCommand("") }
                        Button("Hilfemenü") { hw.sendRawCommand("help") }
                        Button("Modem-Status") { hw.sendRawCommand("status") }
                        Button("Reboot ESP32") { hw.sendRawCommand("reboot") }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    HStack(spacing: 12) {
                        Label("Hardware-Optimierung:", systemImage: "cpu.fill")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                        
                        Button("COEX 0 (BT aus - Max Performance)") {
                            hw.sendRawCommand("coex 0")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        
                        Button("COEX 1 (BT an)") {
                            hw.sendRawCommand("coex 1")
                        }
                        .buttonStyle(.bordered)
                        
                        Divider().frame(height: 18)
                        
                        Button("Sniffer Start") {
                            hw.sendRawCommand("sniffer --start")
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Sniffer Stop") {
                            hw.sendRawCommand("sniffer --stop")
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Kanal 180 (5.9 GHz)") {
                            hw.sendRawCommand("sniffer --channel 180")
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    
                    ESPCommandInputView(hw: hw)
                    .padding(.horizontal)

                    List(hw.espConsoleLog, id: \.id) { line in
                        Text(displayText(line))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(displayText(line).contains("=>") ? .cyan : .green)
                    }
                    .background(.black)
                }

            case 2:
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("GPS Port Monitor (NMEA Sätze)").font(.caption).bold()
                            Text("Schnittstelle: \(hw.selectedGPSPort.isEmpty ? "Inaktiv" : hw.selectedGPSPort) | Baudrate: \(hw.lockedGPSBaud)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(hw.gpsPacketCache.count) Sätze im Cache").font(.caption2).foregroundColor(.secondary)
                        Button(action: { hw.exportGPSCache() }) {
                            Label("NMEA als PCAP sichern", systemImage: "square.and.arrow.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(hw.gpsPacketCache.isEmpty)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    List(Array(gpsLogs.enumerated()), id: \.offset) { _, log in
                        Text(displayText(log))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    .background(.black)
                }
                
            case 3:
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live Netzwerk-Schnittstellen Monitor").font(.caption).bold()
                            Text("TCP Server Port: \(hw.serverPort.description) | Web-Debugger: \((hw.serverPort + 1).description)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(hw.networkPacketCache.count) Transaktionen im Cache").font(.caption2).foregroundColor(.secondary)
                        Button(action: { hw.exportNetworkCache() }) {
                            Label("Datenstrom als PCAP sichern", systemImage: "square.and.arrow.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(hw.networkPacketCache.isEmpty)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Verbundene iPhone Clients:").font(.caption).bold().padding(.horizontal).padding(.top, 8)
                        if hw.connectedClients.isEmpty {
                            Text("Keine aktiven Client-Verbindungen").font(.caption2).foregroundColor(.secondary).padding(.horizontal)
                        } else {
                            List(hw.connectedClients, id: \.self) { client in
                                HStack {
                                    Image(systemName: "iphone.radiowaves.left.and.right")
                                        .foregroundColor(.green)
                                    Text(client)
                                        .font(.system(.caption2, design: .monospaced))
                                    Spacer()
                                    Text("Port: \(hw.serverPort.description) (TCP Live Stream)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(height: 100)
                        }
                    }
                    
                    Divider()
                    
                    VStack(spacing: 0) {
                        HStack {
                            Text("Simulierter und Live Netzwerk-Datenfluss").font(.caption).bold()
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(NSColor.windowBackgroundColor))
                        
                        List(Array(simLogs.enumerated()), id: \.offset) { _, log in
                            Text(displayText(log))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                        .background(.black)
                    }
                }
                
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
    
    private func displayText(_ entry: LogEntry) -> String {
        return entry.text
    }
    
    private var v2xLogs: [LogEntry] { hw.debugRawPackets.filter { displayText($0).contains("[V2X]") } }
    private var gpsLogs: [LogEntry] { hw.debugRawPackets.filter { displayText($0).contains("[GPS]") } }
    private var simLogs: [LogEntry] { hw.debugRawPackets.filter { displayText($0).contains("[SIM") || displayText($0).contains("[NET") } }
}

// Hilfs-View für text input state in Switch Cases
struct ESPCommandInputView: View {
    let hw: V2XHardwareManager
    @State private var inputCommand = ""
    
    var body: some View {
        HStack {
            TextField("Befehl an ESP32 senden (z. B. 'channel 172' oder 'coex 0')...", text: $inputCommand)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !inputCommand.isEmpty else { return }
                    hw.sendRawCommand(inputCommand)
                    inputCommand = ""
                }
            Button("Senden") {
                guard !inputCommand.isEmpty else { return }
                hw.sendRawCommand(inputCommand)
                inputCommand = ""
            }
        }
    }
}

// MARK: - SYSTEMÜBERGREIFENDE HELFER
extension Color {
    func resolvedValue() -> NSColor {
        return NSColor(self)
    }
}
