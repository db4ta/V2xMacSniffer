import SwiftUI
import MapKit

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
            CITSMapView(hw: hw)
                .edgesIgnoringSafeArea(.all)
        }
        .frame(minWidth: 960, minHeight: 600)
    }
    
    // Liefert eine String-Darstellung für beliebige LogEntry-Objekte
    private func displayText(_ entry: LogEntry) -> String {
        return entry.text
    }
}

// --- NATIVE MAPKIT-SCHNITTSTELLE FÜR macOS ---
struct CITSMapView: NSViewRepresentable {
    let hw: V2XHardwareManager
    
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
        // Redraw non-tile polylines cleanly
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
    }
    
    private func updateAnnotations(_ mapView: MKMapView) {
        let currentAnnotations = mapView.annotations
        
        // Eigene GPS-Position
        if let myLoc = hw.myLocation {
            let myPinExists = currentAnnotations.contains { $0.title == "Ich" }
            if !myPinExists {
                let annotation = MKPointAnnotation()
                annotation.coordinate = myLoc
                annotation.title = "Ich"
                mapView.addAnnotation(annotation)
            } else if let myPin = currentAnnotations.first(where: { $0.title == "Ich" }) as? MKPointAnnotation {
                myPin.coordinate = myLoc
            }
        }
        
        // CAM Fahrzeuge
        for vehicle in hw.vehicles.values {
            let vehicleTitle = "Fahrzeug #\(vehicle.id)"
            if let existing = currentAnnotations.first(where: { $0.title == vehicleTitle }) as? MKPointAnnotation {
                existing.coordinate = vehicle.coordinate
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = vehicle.coordinate
                annotation.title = vehicleTitle
                mapView.addAnnotation(annotation)
            }
        }
        
        // Aufräumen inaktiver CAM Fahrzeuge
        for annotation in currentAnnotations {
            guard let title = annotation.title ?? "", title.hasPrefix("Fahrzeug #") else { continue }
            let idString = title.replacingOccurrences(of: "Fahrzeug #", with: "")
            if let id = Int(idString), hw.vehicles[id] == nil {
                mapView.removeAnnotation(annotation)
            }
        }
        
        // SPATEM Ampelanlagen
        for light in hw.trafficLights.values {
            let lightTitle = "Ampel #\(light.id)"
            if let existing = currentAnnotations.first(where: { $0.title == lightTitle }) as? MKPointAnnotation {
                existing.coordinate = light.coordinate
                existing.subtitle = "\(light.currentPhase.uppercased()) | \(light.timeToChange)s"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = light.coordinate
                annotation.title = lightTitle
                annotation.subtitle = "\(light.currentPhase.uppercased()) | \(light.timeToChange)s"
                mapView.addAnnotation(annotation)
            }
        }
        
        // DENM Gefahrenzonen
        for zone in hw.dangerZones.values {
            let zoneTitle = "Gefahr #\(zone.id)"
            if let existing = currentAnnotations.first(where: { $0.title == zoneTitle }) as? MKPointAnnotation {
                existing.coordinate = zone.coordinate
                existing.subtitle = zone.type
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = zone.coordinate
                annotation.title = zoneTitle
                annotation.subtitle = zone.type
                mapView.addAnnotation(annotation)
            }
        }

        // IVIM Digitale Straßenschilder
        for sign in hw.virtualSigns.values {
            let signTitle = "Schild #\(sign.id)"
            if let existing = currentAnnotations.first(where: { $0.title == signTitle }) as? MKPointAnnotation {
                existing.coordinate = sign.coordinate
                existing.subtitle = "Tempolimit: \(sign.value) km/h"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = sign.coordinate
                annotation.title = signTitle
                annotation.subtitle = "Tempolimit: \(sign.value) km/h"
                mapView.addAnnotation(annotation)
            }
        }

        // CPM Radar/LiDAR-Fremdobjekte
        for obj in hw.collectiveObjects.values {
            let objTitle = "Objekt #\(obj.id)"
            if let existing = currentAnnotations.first(where: { $0.title == objTitle }) as? MKPointAnnotation {
                existing.coordinate = obj.coordinate
                existing.subtitle = "\(obj.objectClass) | \(obj.sensorType)"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = obj.coordinate
                annotation.title = objTitle
                annotation.subtitle = "\(obj.objectClass) | \(obj.sensorType)"
                mapView.addAnnotation(annotation)
            }
        }

        // SRM Prioritätsanfragen
        for req in hw.signalRequests.values {
            let reqTitle = "SRM #\(req.id)"
            if let existing = currentAnnotations.first(where: { $0.title == reqTitle }) as? MKPointAnnotation {
                existing.coordinate = req.coordinate
                existing.subtitle = "\(req.requesterType) -> Kreuzung \(req.targetIntersectionID)"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = req.coordinate
                annotation.title = reqTitle
                annotation.subtitle = "\(req.requesterType) -> Kreuzung \(req.targetIntersectionID)"
                mapView.addAnnotation(annotation)
            }
        }

        // SSM Bestätigungen
        for status in hw.signalStatuses.values {
            let statusTitle = "SSM #\(status.id)"
            if let existing = currentAnnotations.first(where: { $0.title == statusTitle }) as? MKPointAnnotation {
                existing.coordinate = status.coordinate
                existing.subtitle = "Kreuzung \(status.intersectionID) -> \(status.priorityGranted ? "Gewährt" : "Abgelehnt")"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = status.coordinate
                annotation.title = statusTitle
                annotation.subtitle = "Kreuzung \(status.intersectionID) -> \(status.priorityGranted ? "Gewährt" : "Abgelehnt")"
                mapView.addAnnotation(annotation)
            }
        }

        // MAPEM Kreuzungszentren
        for mapGeo in hw.mapGeometries.values {
            let mapTitle = "MAPEM #\(mapGeo.id)"
            if let existing = currentAnnotations.first(where: { $0.title == mapTitle }) as? MKPointAnnotation {
                existing.coordinate = mapGeo.centerCoordinate
                existing.subtitle = mapGeo.name
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = mapGeo.centerCoordinate
                annotation.title = mapTitle
                annotation.subtitle = mapGeo.name
                mapView.addAnnotation(annotation)
            }
        }

        // MCM Manöver-Startpunkte
        for maneuver in hw.maneuvers.values {
            guard let startPoint = maneuver.trajectoryPoints.first else { continue }
            let maneuverTitle = "Maneuver #\(maneuver.id)"
            if let existing = currentAnnotations.first(where: { $0.title == maneuverTitle }) as? MKPointAnnotation {
                existing.coordinate = startPoint
                existing.subtitle = "Phase: \(maneuver.coordinationPhase)"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = startPoint
                annotation.title = maneuverTitle
                annotation.subtitle = "Phase: \(maneuver.coordinationPhase)"
                mapView.addAnnotation(annotation)
            }
        }

        // RTCMEM Referenzstationen
        for rtk in hw.rtkCorrections.values {
            let rtkTitle = "RTK-Basis #\(rtk.id)"
            if let existing = currentAnnotations.first(where: { $0.title == rtkTitle }) as? MKPointAnnotation {
                existing.coordinate = rtk.coordinate
                existing.subtitle = "RTK: \(rtk.correctionStatus) (\(rtk.signalStrengthDBm)dBm)"
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = rtk.coordinate
                annotation.title = rtkTitle
                annotation.subtitle = "RTK: \(rtk.correctionStatus) (\(rtk.signalStrengthDBm)dBm)"
                mapView.addAnnotation(annotation)
            }
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
                if polyline.title == "MAPEM_Polyline" {
                    renderer.strokeColor = .lightGray
                    renderer.lineWidth = 4.0
                    renderer.lineDashPattern = [6, 4] // Gestrichelte Spurlinie
                } else if polyline.title == "MCM_Polyline" {
                    renderer.strokeColor = .systemYellow
                    renderer.lineWidth = 3.0 // Gelber Pfad für Absprachen
                } else {
                    renderer.strokeColor = .systemBlue
                    renderer.lineWidth = 2.0
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
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
                view?.markerTintColor = NSColor.magenta
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
                            Text("RTCMEM: \(hw.decodedRTCMEMs)").foregroundColor(Color(NSColor.magenta)).bold()
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
