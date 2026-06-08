import SwiftUI
import MapKit
import AppKit

/// Einfache Log-Datenstruktur für Terminal- und Listenanzeigen
struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let text: String

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ERWEITERTES C-ITS DATENMODELL
/// Beschreibt den Typ einer empfangenen oder simulierten kooperativen V2X-Nachricht.
enum V2XMessageType: String, Codable, CaseIterable {
    case CAM = "CAM"
    case DENM = "DENM"
    case SPATEM = "SPATEM"
    case MAPEM = "MAPEM"
    case IVIM = "IVIM"
    case CPM = "CPM"
}

/// Datenstruktur für den tshark Live-Datenstrom zur Anzeige im Cockpit.
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

/// Port-Formatierer ohne Tausendertrennzeichen (Gruppierung).
private let portFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.usesGroupingSeparator = false
    return formatter
}()

// MARK: - Custom Reusable UI components
/// Eine standardisierte "Card" für das Sidebar-Design-System zur strukturellen Visualisierung.
struct SidebarCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    
    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.system(size: 11, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 2)
            
            content
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Terminal-Ansicht (Putty-Stil)
/// Eine wiederverwendbare Terminal-Ansicht, die eintreffende Log-Einträge fortlaufend im Putty-Stil darstellt.
struct PuttyTerminalView: View {
    let entries: [LogEntry]
    let textColor: Color
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        Text("[\(entry.timestamp.formatted(.dateTime.hour().minute().second()))] \(entry.text)")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundColor(textColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .background(Color.black)
            .cornerRadius(6)
            .onChange(of: entries) { _, _ in
                if let last = entries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - ContentView Hauptansicht
struct ContentView: View {
    // Shared State Schnittstelle zur Hardwaresteuerung
    var hw: V2XHardwareManager
    
    // Nativer SwiftUI Fenstermanager
    @Environment(\.openWindow) private var openSwiftUIWindow
    @Environment(\.dismissWindow) private var dismissSwiftUIWindow

    private var v2xIsOpen: Bool { (hw as? NSObject)?.value(forKey: "v2xPortOpen") as? Bool ?? false }
    private var v2xIsManuallyConnected: Bool { (hw as? NSObject)?.value(forKey: "isV2XManuallyConnected") as? Bool ?? false }
    private var gpsIsOpen: Bool { (hw as? NSObject)?.value(forKey: "gpsPortOpen") as? Bool ?? false }
    private var gpsIsManuallyConnected: Bool { (hw as? NSObject)?.value(forKey: "isGPSManuallyConnected") as? Bool ?? false }
    
    // Live-Feed-Datenströme
    @State private var livePackets: [V2XPacket] = []
    @State private var selectedPacket: V2XPacket? = nil
    @State private var lastIncomingCoordinate: CLLocationCoordinate2D? = nil
    @State private var isShowingDetailPopover = false
    
    // Fehler- und Puffer-Zustände
    @State private var showErrorAlert: Bool = false
    @State private var lastErrorMessage: String = ""
    @State private var tsharkJSONBuffer: Data = Data()
    @AppStorage("isTsharkSimulationEnabled") private var isTsharkSimulationEnabled: Bool = false

    var body: some View {
        @Bindable var hw = hw
        
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    
                    // Kopfzeile mit Aktualisierungs-Trigger
                    HStack {
                        Text("V2X Mac-Zentrale")
                            .font(.system(size: 16, weight: .bold))
                        Spacer()
                        Button(action: {
                            if let obj = hw as? NSObject, obj.responds(to: Selector(("scanPorts"))) {
                                obj.perform(Selector(("scanPorts")))
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Verfügbare Ports neu scannen")
                    }
                    .padding(.bottom, 4)
                    
                    // 1. SYSTEMSTATUS LEDS
                    SidebarCard("Systemstatus", icon: "bolt.heart.fill") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle()
                                    .fill(v2xIsOpen ? .green : (v2xIsManuallyConnected ? .yellow : .red))
                                    .frame(width: 8, height: 8)
                                Text("V2X-USB: ")
                                    .foregroundColor(.secondary)
                                Text(v2xIsOpen ? "Verbunden (\(hw.lockedV2XBaud))" : "Getrennt")
                                    .bold()
                            }
                            HStack {
                                Circle()
                                    .fill(gpsIsOpen ? .green : (gpsIsManuallyConnected ? .yellow : .red))
                                    .frame(width: 8, height: 8)
                                Text("GPS-USB: ")
                                    .foregroundColor(.secondary)
                                Text(gpsIsOpen ? "Verbunden (\(hw.lockedGPSBaud))" : "Getrennt")
                                    .bold()
                            }
                            HStack {
                                Circle()
                                    .fill(hw.serverRunning ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text("iOS-Server: ")
                                    .foregroundColor(.secondary)
                                Text(hw.serverRunning ? "Aktiv (Port \(hw.serverPort.description))" : "Inaktiv")
                                    .bold()
                            }
                        }
                        .font(.system(size: 11))
                    }
                    
                    // 2. VERBINDUNGSSTATUS (RX-RATE)
                    SidebarCard("Verbindungsstatus", icon: "activity") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Port:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(hw.selectedV2XPort.isEmpty ? "–" : hw.selectedV2XPort.replacingOccurrences(of: "/dev/cu.", with: ""))
                                    .monospaced()
                                    .bold()
                            }
                            
                            HStack {
                                Text("Rx-Übertragung:")
                                    .foregroundColor(.secondary)
                                Spacer()
                                if let obj = hw as? NSObject, let rxRateBps = obj.value(forKey: "v2xRxRateBps") as? Double {
                                    Text(String(format: "%.2f kB/s", rxRateBps / 1000.0))
                                        .monospaced()
                                        .bold()
                                } else {
                                    Text(String(format: "%.2f kB/s", Double(hw.totalV2XBytesRx) / 1000.0))
                                        .monospaced()
                                        .bold()
                                }
                            }
                            
                            Button(action: {
                                if let obj = hw as? NSObject, let lastError = obj.value(forKey: "lastV2XError") as? String, !lastError.isEmpty {
                                    lastErrorMessage = lastError
                                } else {
                                    lastErrorMessage = "Keine aufgezeichneten Fehler auf dem Bus."
                                }
                                showErrorAlert = true
                            }) {
                                Label("Bus-Fehler prüfen", systemImage: "exclamationmark.bubble")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .font(.system(size: 11))
                    }
                    
                    // 3. ESP32 V2X MODEM STEUERUNG (PROMINENTER HAUPTKNOPF)
                    SidebarCard("ESP32 V2X Modem", icon: "cpu") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Port:", selection: $hw.selectedV2XPort) {
                                Text("Kein Port ausgewählt").tag("")
                                ForEach(hw.availablePorts, id: \.self) { port in
                                    Text(port.replacingOccurrences(of: "/dev/cu.", with: "")).tag(port)
                                }
                            }
                            .controlSize(.small)
                            .disabled(v2xIsManuallyConnected)
                            
                            HStack {
                                Text("Baudrate:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("921600 Baud")
                                    .font(.caption)
                                    .bold()
                            }
                            .help("Die Hardware benötigt zwingend 921600 Baud.")
                            
                            Button(action: { hw.toggleV2XConnection() }) {
                                HStack {
                                    Image(systemName: v2xIsManuallyConnected ? "bolt.slash.fill" : "bolt.fill")
                                    Text(v2xIsManuallyConnected ? "V2X trennen" : "V2X verbinden")
                                        .bold()
                                }
                                .frame(maxWidth: .infinity, minHeight: 22)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(v2xIsManuallyConnected ? .red : .blue)
                        }
                    }
                    
                    // 4. OFFLINE-KARTEN CACHE MANAGER (MIT CACHE-GRÖSSE & RATELIMIT)
                    SidebarCard("Offline-Karten & Cache", icon: "map.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Offline-Modus aktivieren", isOn: $hw.isOfflineMapActive)
                                .font(.caption).bold()
                                .toggleStyle(.checkbox)
                            
                            HStack {
                                Text("Lokaler Cache:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(hw.cacheSizeString)
                                    .font(.system(size: 11, design: .monospaced))
                                    .bold()
                            }
                            
                            Divider()
                            
                            Text("Region vorab herunterladen:").font(.caption2).bold().foregroundColor(.secondary)
                            Picker("", selection: $hw.selectedOfflineRegion) {
                                ForEach(hw.offlineRegionOptions, id: \.self) { region in
                                    Text(region).tag(region)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .disabled(hw.isDownloadingMap)
                            
                            HStack {
                                Text("Max. Zoom:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Stepper(value: $hw.maxDownloadZoomLevel, in: 10...17) {
                                    Text("\(hw.maxDownloadZoomLevel)")
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .disabled(hw.isDownloadingMap)
                            }
                            
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
                                    Label("Region laden", systemImage: "arrow.down.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                            
                            Divider()
                            
                            HStack(spacing: 8) {
                                Button(action: { hw.importMBTilesFile() }) {
                                    Label("Import", systemImage: "doc.badge.plus")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                
                                Button(action: { hw.exportCacheToMBTiles() }) {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            Button(role: .destructive, action: { hw.clearTileCache() }) {
                                Label("Cache leeren", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                        }
                    }
                    
                    // 5. VEHICLE TRAILS
                    SidebarCard("Fahrzeugspuren", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Spur behalten (Kein Auto-Prune)", isOn: $hw.keepVehiclesAsTrail)
                                .font(.caption).bold()
                                .toggleStyle(.checkbox)
                            
                            HStack {
                                Text("Max. Punkte pro Spur:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Stepper(value: $hw.maxTrailPointsPerVehicle, in: 20...2000, step: 20) {
                                    Text("\(hw.maxTrailPointsPerVehicle)")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                                .disabled(!hw.keepVehiclesAsTrail)
                            }
                        }
                    }
                    
                    // 6. GPS EMPFÄNGER (NMEA)
                    SidebarCard("GPS-Empfänger", icon: "location") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Port:", selection: $hw.selectedGPSPort) {
                                Text("Kein Port ausgewählt").tag("")
                                ForEach(hw.availablePorts, id: \.self) { port in
                                    Text(port.replacingOccurrences(of: "/dev/cu.", with: "")).tag(port)
                                }
                            }
                            .controlSize(.small)
                            .disabled(gpsIsManuallyConnected)
                            
                            HStack {
                                Text("Baudrate:").font(.caption).foregroundColor(.secondary)
                                Picker("", selection: $hw.selectedGPSBaud) {
                                    ForEach(hw.gpsBaudOptions, id: \.self) { baud in
                                        Text(baud).tag(baud)
                                    }
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .disabled(gpsIsManuallyConnected)
                            }
                            
                            Button(action: { hw.toggleGPSConnection() }) {
                                Text(gpsIsManuallyConnected ? "GPS trennen" : "GPS verbinden")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(gpsIsManuallyConnected ? .red : .blue)
                            .controlSize(.small)
                        }
                    }
                    
                    // 7. iOS INTERACTIVE SERVER
                    SidebarCard("iOS Server", icon: "phone") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("TCP Port:")
                                TextField("Port", value: $hw.serverPort, formatter: portFormatter)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .disabled(hw.serverRunning)
                                Spacer()
                                Stepper("", value: $hw.serverPort, in: 1024...65535)
                                    .labelsHidden()
                                    .disabled(hw.serverRunning)
                            }
                            
                            Toggle("Web-Debugger aktiv", isOn: $hw.isWebDebugServerEnabled)
                                .font(.caption)
                                .disabled(hw.serverRunning)
                            
                            Button(action: { hw.toggleServer() }) {
                                Text(hw.serverRunning ? "Server stoppen" : "Server starten")
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(hw.serverRunning ? .red : .green)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    
                    // 8. DATA FORENSICS
                    SidebarCard("Forensische Protokollierung", icon: "opticaldisc") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Log-Verzeichnis:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Wählen...") { hw.selectLogDirectory() }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                            
                            Text(hw.logDirectoryPathString)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.blue)
                                .lineLimit(1)
                                .truncationMode(.head)
                            
                            Toggle("Wireshark PCAP Exporter", isOn: $hw.isPCAPLoggingActive)
                                .font(.caption)
                            Toggle("CSV Tabellen-Logger", isOn: $hw.isCSVLoggingActive)
                                .font(.caption)
                        }
                    }
                    
                    // 9. COCKPIT-WINDOW TOGGLE
                    SidebarCard("Hilfswerkzeuge", icon: "macwindow") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Debug-Fenster aktiv", isOn: $hw.isDebugWindowActive)
                                .font(.caption).bold()
                                .toggleStyle(.checkbox)
                                .onChange(of: hw.isDebugWindowActive) { _, newValue in
                                    if newValue {
                                        openSwiftUIWindow(id: "debug_window")
                                    } else {
                                        dismissSwiftUIWindow(id: "debug_window")
                                    }
                                }
                        }
                    }
                    
                    // 10. KONSOLIDIERTER TSHARK & C-ITS SIMULATOR (ZUSAMMENGEFÜHRTES DESIGN)
                    SidebarCard("Simulations-Zentrale", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Automatischer Ablauf", isOn: .init(
                                get: { hw.isAutoSimulationActive },
                                set: { _ in hw.toggleAutoSimulation() }
                            ))
                            .font(.caption).bold()
                            .toggleStyle(.switch)
                            
                            HStack {
                                Text("Timer Intervall:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Stepper(value: $hw.simulationIntervalSeconds, in: 0.5...10.0, step: 0.5) {
                                    Text(String(format: "%.1f s", hw.simulationIntervalSeconds))
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .disabled(hw.isAutoSimulationActive)
                            }
                            
                            Divider()
                            
                            // Manuelle Einzeleinspeisung als Fallback
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Manuelle Einspeisung:").font(.caption2).foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Button(action: {
                                        simulateIncomingTsharkJSON()
                                    }) {
                                        Label("tshark JSON", systemImage: "doc.plaintext.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    
                                    Button(action: {
                                        let center = hw.myLocation ?? CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
                                        hw.simulateCAM(lat: center.latitude, lon: center.longitude)
                                    }) {
                                        Label("CAM (PKW)", systemImage: "car.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .background(Color.purple.opacity(0.05).cornerRadius(8))
                    
                    // 11. GLOSA INFO PANEL
                    if hw.myLocation != nil && !hw.trafficLights.isEmpty {
                        SidebarCard("GLOSA Assistent", icon: "traffic.light.fill") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(hw.trafficLights.values)) { light in
                                    if let speedRecommendation = hw.calculateGLOSASpeed(to: light) {
                                        HStack {
                                            Circle()
                                                .fill(light.currentPhase == "green" ? .green : (light.currentPhase == "yellow" ? .yellow : .red))
                                                .frame(width: 8, height: 8)
                                            Text("Kreuzung #\(light.id):")
                                            Spacer()
                                            Text("\(Int(speedRecommendation)) km/h")
                                                .bold()
                                                .foregroundColor(.green)
                                        }
                                        .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                    }
                    
                    // 12. LOG COCKPIT EXPORT & VIEW
                    SidebarCard("Echtzeit-Terminal", icon: "scroll") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Button {
                                    hw.copyLogsToClipboard()
                                } label: {
                                    Label("Kopieren", systemImage: "doc.on.doc").font(.system(size: 10))
                                }
                                .buttonStyle(.bordered)
                                
                                Button {
                                    hw.exportLogsToFile()
                                } label: {
                                    Label("Sichern", systemImage: "square.and.arrow.down").font(.system(size: 10))
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                            }
                            
                            List(Array(hw.logs.enumerated()), id: \.offset) { _, log in
                                Text(log.text)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                            .background(Color.black)
                            .cornerRadius(4)
                            .frame(minHeight: 120)
                        }
                    }
                }
                .padding()
            }
            .frame(minWidth: 280, maxWidth: 350)
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
        .alert("V2X Fehler", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastErrorMessage)
        }
    }
    
    /// Simuliert den asynchronen tshark JSON Parser-Prozess im Hintergrund
    private func simulateIncomingTsharkJSON() {
        let types: [V2XMessageType] = [.CAM, .DENM, .SPATEM, .MAPEM, .IVIM, .CPM]
        let selectedType = types.randomElement() ?? .CAM
        
        let randomStationID = UInt32.random(in: 1000...9999)
        let stuttgartCenter = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
        let packetCoordinate = CLLocationCoordinate2D(
            latitude: stuttgartCenter.latitude + Double.random(in: -0.005...0.005),
            longitude: stuttgartCenter.longitude + Double.random(in: -0.005...0.005)
        )
        
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
            
            DispatchQueue.main.async {
                self.livePackets.append(parsedPacket)
                self.lastIncomingCoordinate = packetCoordinate
                if let obj = self.hw as? NSObject {
                    _ = obj.perform(Selector(("addLog:")), with: "[tshark] Simuliertes \(selectedType.rawValue) Paket verarbeitet (Station: \(randomStationID))")
                    _ = obj.perform(Selector(("addDebugPacketLog:")), with: "[SIM tshark] Simuliertes \(selectedType.rawValue) (Station: \(randomStationID)) - Lat: \(packetCoordinate.latitude), Lon: \(packetCoordinate.longitude)")
                }
            }
        }
    }
}

// MARK: - INTERAKTIVES POPUP DETAILFENSTER (OpenTrafficMap-Style)
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

// MARK: - ANNOTATIONS-KLASSE FÜR LIVE-TSHARK INTERACTION
class CITSPacketAnnotation: MKPointAnnotation {
    var packet: V2XPacket?
    var customIconType: V2XMessageType?
}

// Minimal placeholder overlay to satisfy compiler when offline tiles are not integrated yet.
class CachedTileOverlay: MKTileOverlay {}

// MARK: - NATIVE MAPKIT-SCHNITTSTELLE FÜR macOS
struct CITSMapView: NSViewRepresentable {
    let hw: V2XHardwareManager
    var livePackets: [V2XPacket]
    @Binding var selectedPacket: V2XPacket?
    @Binding var lastIncomingCoordinate: CLLocationCoordinate2D?
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        let center = CLLocationCoordinate2D(latitude: 48.7955, longitude: 9.2292)
        let region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
        mapView.setRegion(region, animated: false)
        
        return mapView
    }
    
    func updateNSView(_ mapView: MKMapView, context: Context) {
        updateTileOverlay(mapView)
        updateOverlays(mapView)
        updateAnnotations(mapView)
        
        if let newCoord = lastIncomingCoordinate {
            DispatchQueue.main.async {
                mapView.setCenter(newCoord, animated: true)
                self.lastIncomingCoordinate = nil
            }
        }
    }
    
    private func updateTileOverlay(_ mapView: MKMapView) {
        let overlays = mapView.overlays.filter { $0 is CachedTileOverlay }
        mapView.removeOverlays(overlays)

        let isOffline = ((hw as? NSObject)?.value(forKey: "isOfflineMapActive") as? Bool) ?? false
        guard isOffline else { return }

        let overlay: CachedTileOverlay
        if let path = (hw as? NSObject)?.value(forKey: "selectedMBTilesPath") as? String, !path.isEmpty {
            // Placeholder: ignore MBTiles URL, we still add a basic overlay
            overlay = CachedTileOverlay()
        } else {
            overlay = CachedTileOverlay()
        }
        overlay.canReplaceMapContent = true
        mapView.addOverlay(overlay, level: .aboveRoads)
    }

    private func updateOverlays(_ mapView: MKMapView) {
        let existingPolylines = mapView.overlays.filter { $0 is MKPolyline && !($0 is CachedTileOverlay) }
        mapView.removeOverlays(existingPolylines)
        
        // 1. MAPEM (optional via KVC)
        if let mapGeos = (hw as? NSObject)?.value(forKey: "mapGeometries") as? [Any] {
            for any in mapGeos {
                if let coords = (any as AnyObject).value(forKey: "laneCoordinates") as? [CLLocationCoordinate2D], coords.count >= 2 {
                    let polyline = MKPolyline(coordinates: coords, count: coords.count)
                    polyline.title = "MAPEM_Polyline"
                    mapView.addOverlay(polyline, level: .aboveRoads)
                }
            }
        }
        
        // 2. MCM (optional via KVC)
        if let mans = (hw as? NSObject)?.value(forKey: "maneuvers") as? [Any] {
            for any in mans {
                if let coords = (any as AnyObject).value(forKey: "trajectoryPoints") as? [CLLocationCoordinate2D], coords.count >= 2 {
                    let polyline = MKPolyline(coordinates: coords, count: coords.count)
                    polyline.title = "MCM_Polyline"
                    mapView.addOverlay(polyline, level: .aboveRoads)
                }
            }
        }
        
        // 3. DYNAMISCHE SPATEM SPUREN
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
        mapView.removeAnnotations(mapView.annotations)

        if let myLoc = (hw as? NSObject)?.value(forKey: "myLocation") as? CLLocationCoordinate2D {
            let annotation = MKPointAnnotation()
            annotation.coordinate = myLoc
            annotation.title = "Ich"
            mapView.addAnnotation(annotation)
        }

        if let vehicles = (hw as? NSObject)?.value(forKey: "vehicles") as? [Int: Any] {
            for (id, any) in vehicles {
                if let coord = (any as AnyObject).value(forKey: "coordinate") as? CLLocationCoordinate2D {
                    let annotation = MKPointAnnotation()
                    annotation.coordinate = coord
                    annotation.title = "Fahrzeug #\(id)"
                    mapView.addAnnotation(annotation)
                }
            }
        }

        if let lights = (hw as? NSObject)?.value(forKey: "trafficLights") as? [Int: Any] {
            for (id, any) in lights {
                if let coord = (any as AnyObject).value(forKey: "coordinate") as? CLLocationCoordinate2D {
                    let annotation = MKPointAnnotation()
                    annotation.coordinate = coord
                    annotation.title = "Ampel #\(id)"
                    mapView.addAnnotation(annotation)
                }
            }
        }

        if let zones = (hw as? NSObject)?.value(forKey: "dangerZones") as? [Int: Any] {
            for (id, any) in zones {
                if let coord = (any as AnyObject).value(forKey: "coordinate") as? CLLocationCoordinate2D {
                    let annotation = MKPointAnnotation()
                    annotation.coordinate = coord
                    annotation.title = "Gefahr #\(id)"
                    mapView.addAnnotation(annotation)
                }
            }
        }

        for packet in livePackets {
            let annotation = CITSPacketAnnotation()
            annotation.coordinate = packet.coordinates
            annotation.packet = packet
            annotation.customIconType = packet.messageType
            annotation.title = "\(packet.messageType.rawValue) (Station \(packet.stationID))"
            annotation.subtitle = String(format: "%@ · %.5f, %.5f", packet.messageType.rawValue, packet.coordinates.latitude, packet.coordinates.longitude)
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
                view?.markerTintColor = NSColor.systemBlue
                view?.glyphImage = NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
            } else if title.hasPrefix("Ampel #") {
                view?.markerTintColor = NSColor.systemRed
                view?.glyphImage = NSImage(systemSymbolName: "traffic.light.fill", accessibilityDescription: nil)
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

// MARK: - DEBUGGING-FENSTER MIT EIGENER SEGMENTED-PICKER NAVIGATION
struct DebugConsoleView: View {
    var hw: V2XHardwareManager
    @State private var selectedTab = 0
    
    var body: some View {
        @Bindable var hw = hw
        
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BYTES RX (V2X)").font(.system(size: 9)).foregroundColor(.gray)
                    Text("\(((hw as? NSObject)?.value(forKey: "totalV2XBytesRx") as? Int ?? 0)) B").font(.title3).bold().monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("BYTES RX (GPS)").font(.system(size: 9)).foregroundColor(.gray)
                    Text("\(((hw as? NSObject)?.value(forKey: "totalGPSBytesRx") as? Int ?? 0)) B").font(.title3).bold().monospacedDigit()
                }
                Divider().frame(height: 35)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEKODIERTE C-ITS INFRASTRUKTUR-PAKETE").font(.system(size: 9)).foregroundColor(.gray)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("CAM: \(((hw as? NSObject)?.value(forKey: "decodedCAMs") as? Int ?? 0))").foregroundColor(.blue).bold()
                            Text("DENM: \(((hw as? NSObject)?.value(forKey: "decodedDENMs") as? Int ?? 0))").foregroundColor(.red).bold()
                            Text("SPATEM: \(((hw as? NSObject)?.value(forKey: "decodedSPATEMs") as? Int ?? 0))").foregroundColor(.orange).bold()
                            Text("MAPEM: \(((hw as? NSObject)?.value(forKey: "decodedMAPEMs") as? Int ?? 0))").foregroundColor(.gray).bold()
                            Text("IVIM: \(((hw as? NSObject)?.value(forKey: "decodedIVIMs") as? Int ?? 0))").foregroundColor(.red).bold()
                        }
                        HStack(spacing: 8) {
                            Text("CPM: \(((hw as? NSObject)?.value(forKey: "decodedCPMs") as? Int ?? 0))").foregroundColor(.purple).bold()
                            Text("SRM: \(((hw as? NSObject)?.value(forKey: "decodedSRMs") as? Int ?? 0))").foregroundColor(.cyan).bold()
                            Text("SSM: \(((hw as? NSObject)?.value(forKey: "decodedSSMs") as? Int ?? 0))").foregroundColor(.blue).bold()
                            Text("MCM: \(((hw as? NSObject)?.value(forKey: "decodedMCMs") as? Int ?? 0))").foregroundColor(.yellow).bold()
                            Text("RTCMEM: \(((hw as? NSObject)?.value(forKey: "decodedRTCMEMs") as? Int ?? 0))").foregroundColor(Color(nsColor: .magenta)).bold()
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
                Label("Dashboard", systemImage: "chart.bar.xaxis").tag(0)
                Label("V2X SLIP", systemImage: "cpu").tag(1)
                Label("GPS NMEA", systemImage: "location.circle").tag(2)
                Label("Netzwerk", systemImage: "network").tag(3)
                Label("Gesamt-Monitor (Log)", systemImage: "doc.text.magnifyingglass").tag(4)
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
                        Toggle("Automatischer Ablauf", isOn: .init(
                            get: { hw.isAutoSimulationActive },
                            set: { _ in hw.toggleAutoSimulation() }
                        ))
                        .font(.caption).bold()
                        .toggleStyle(.switch)

                        HStack(spacing: 8) {
                            Button(action: {
                                let center = hw.myLocation ?? CLLocationCoordinate2D(latitude: 48.775, longitude: 9.182)
                                hw.simulateCAM(lat: center.latitude, lon: center.longitude)
                                hw.simulateSPATEM(lat: center.latitude, lon: center.longitude)
                                hw.addLog("[sim] Manuelle Signalsimulation aus der Debug-Zentrale ausgelöst.")
                            }) {
                                Label("Jetzt simulieren", systemImage: "bolt.horizontal.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                if hw.isAutoSimulationActive {
                                    hw.toggleAutoSimulation()
                                }
                            }) {
                                Label("Simulation stoppen", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(!hw.isAutoSimulationActive)
                        }
                        
                        Text("C-ITS SIGNAL-GENERATOR (HARDWARE-FREIE SIMULATION)").font(.caption).bold().foregroundColor(.secondary)
                        
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            let center = hw.myLocation ?? CLLocationCoordinate2D(latitude: 48.775, longitude: 9.182)
                            
                            Button(action: { hw.simulateCAM(lat: center.latitude, lon: center.longitude) }) {
                                Label("CAM (Car)", systemImage: "car.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateDENM(lat: center.latitude, lon: center.longitude) }) {
                                Label("DENM (Hazard)", systemImage: "exclamationmark.triangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSPATEM(lat: center.latitude, lon: center.longitude) }) {
                                Label("SPATEM (LSA)", systemImage: "traffic.light.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateMAPEM(lat: center.latitude, lon: center.longitude) }) {
                                Label("MAPEM (Lane)", systemImage: "map.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateIVIM(lat: center.latitude, lon: center.longitude) }) {
                                Label("IVIM (Limit)", systemImage: "speedometer")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateCPM(lat: center.latitude, lon: center.longitude) }) {
                                Label("CPM (Objects)", systemImage: "figure.walk")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSRM(lat: center.latitude, lon: center.longitude) }) {
                                Label("SRM (Priority Req)", systemImage: "light.beacon.max.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateSSM(lat: center.latitude, lon: center.longitude) }) {
                                Label("SSM (Priority OK)", systemImage: "checkmark.shield.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateMCM(lat: center.latitude, lon: center.longitude) }) {
                                Label("MCM (Cooperation)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                    .frame(maxWidth: .infinity)
                            }
                            Button(action: { hw.simulateRTCMEM(lat: center.latitude, lon: center.longitude) }) {
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
                            Text("[\(log.timestamp.formatted(.dateTime.hour().minute().second()))] \(log.text)")
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
                        Button("Ping Test") { if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "") } }
                        Button("Hilfemenü") { if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "help") } }
                        Button("Modem-Status") { if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "status") } }
                        Button("Reboot ESP32") { if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "reboot") } }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    HStack(spacing: 12) {
                        Label("Hardware-Optimierung:", systemImage: "cpu.fill")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                        
                        Button("COEX 0 (BT aus - Max Performance)") {
                            if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "coex 0") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        
                        Button("COEX 1 (BT an)") {
                            if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "coex 1") }
                        }
                        .buttonStyle(.bordered)
                        
                        Divider().frame(height: 18)
                        
                        Button("Sniffer Start") {
                            if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "sniffer --start") }
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Sniffer Stop") {
                            if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "sniffer --stop") }
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Kanal 180 (5.9 GHz)") {
                            if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: "sniffer --channel 180") }
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    
                    ESPCommandInputView(hw: hw)
                    .padding(.horizontal)

                    PuttyTerminalView(entries: v2xLogs, textColor: .green)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
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
                            Label("NMEA as PCAP sichern", systemImage: "square.and.arrow.down.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(hw.gpsPacketCache.isEmpty)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    PuttyTerminalView(entries: gpsLogs, textColor: .cyan)
                        .padding(8)
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
                        
                        PuttyTerminalView(entries: simLogs, textColor: .purple)
                            .padding(8)
                    }
                }
                
            case 4:
                // Kombinierter Gesamt-Monitor (Unified Terminal)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gesamt-Monitor (Alle Datenströme)").font(.caption).bold()
                            Text("Echtzeit-Sicherung in: \(hw.unifiedLogFileURL?.lastPathComponent ?? "Inaktiv")").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            if let url = hw.unifiedLogFileURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }) {
                            Label("Im Finder anzeigen", systemImage: "folder.fill")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: {
                            hw.copyLogsToClipboard()
                        }) {
                            Label("Kopieren", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    // Gesamt-Terminal zeigt ungefiltert chronologisch alle Ereignisse
                    PuttyTerminalView(entries: hw.logs, textColor: .green)
                        .padding(8)
                }
                
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }
    
    // MARK: - FILTERUNG DER ROHDATENSTRÖME FÜR DIE TERMINALS
    /// Filtert Befehlseingaben, ESP-Antworten und dekodierten Sniffer-Verkehr für das Modem-Terminal
    private var v2xLogs: [LogEntry] {
        hw.logs.filter { 
            $0.text.contains("[V2X]") || 
            $0.text.contains("Modem") || 
            $0.text.contains("ESP32") || 
            $0.text.contains("Decoder") || 
            $0.text.contains("CAM") || 
            $0.text.contains("SPATEM") || 
            $0.text.contains("DENM") 
        }
    }
    /// Filtert GPS-NMEA-Datensätze und GPS-Bus-Fehler
    private var gpsLogs: [LogEntry] { 
        hw.logs.filter { 
            $0.text.contains("[GPS]") || 
            $0.text.contains("$GP") || 
            $0.text.contains("NMEA") || 
            $0.text.contains("GPS-Empfänger") 
        }
    }
    /// Filtert Simulationsströme, Wireshark tshark Logs und Netzwerkmeldungen
    private var simLogs: [LogEntry] { 
        hw.logs.filter { 
            $0.text.contains("[SIM]") || 
            $0.text.contains("[tshark]") || 
            $0.text.contains("TCP-Server") || 
            $0.text.contains("Server") || 
            $0.text.contains("Client") 
        }
    }
}

// MARK: - ESPCommandInputView
struct ESPCommandInputView: View {
    let hw: V2XHardwareManager
    @State private var inputCommand = ""
    
    var body: some View {
        HStack {
            TextField("Befehl an ESP32 senden (z. B. 'channel 172' oder 'coex 0')...", text: $inputCommand)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !inputCommand.isEmpty else { return }
                    if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: inputCommand) }
                    inputCommand = ""
                }
            Button("Senden") {
                guard !inputCommand.isEmpty else { return }
                if let obj = hw as? NSObject { _ = obj.perform(Selector(("sendRawCommand:")), with: inputCommand) }
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
