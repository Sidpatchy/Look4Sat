import CoreLocation
import AVFAudio
import Combine
import Foundation
import Look4SatShared
import MapKit
import SwiftUI

private enum RadarPane: String, CaseIterable, Identifiable {
    case radar = "Radar"
    case transceivers = "Transceivers"
    case calculator = "Calculator"
    case sstv = "SSTV"

    var id: String { rawValue }
}

struct RadarView: View {
    @ObservedObject var store: SatelliteStore
    let selectedSatelliteID: Int32
    let onSelectSatellite: (SatelliteTarget) -> Void

    @State private var trajectory: [TrackedPosition] = []
    @State private var selectedPane: RadarPane = .radar

    private var satellite: SatelliteTarget? { store.satellite(withID: selectedSatelliteID) }
    private var position: TrackedPosition? {
        guard let satellite else { return nil }
        return store.position(for: satellite)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading(eyebrow: "LIVE LOOK ANGLES", title: "Radar")
                SatellitePicker(
                    satellites: store.trackedSatellites,
                    selectedSatelliteID: selectedSatelliteID,
                    onSelect: onSelectSatellite
                )
                Picker("Radar page", selection: $selectedPane) {
                    ForEach(RadarPane.allCases) { pane in Text(pane.rawValue).tag(pane) }
                }
                .pickerStyle(.segmented)

                switch selectedPane {
                case .radar:
                    radarContents
                case .transceivers:
                    TransceiversPanel(store: store, satelliteID: selectedSatelliteID)
                case .calculator:
                    DopplerCalculatorPanel(store: store, satelliteID: selectedSatelliteID)
                case .sstv:
                    SstvPanel()
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.recalculatePasses() }
        .task(id: selectedSatelliteID) {
            await loadTrajectory()
        }
    }

    private func loadTrajectory() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        trajectory = await store.trajectory(
            for: selectedSatelliteID,
            startTimeMillis: now - 15 * 60_000,
            endTimeMillis: now + 30 * 60_000,
            stepMillis: 30_000
        )
    }

    @ViewBuilder
    private var radarContents: some View {
        if let position {
            TimelineView(.animation(minimumInterval: 0.08, paused: !store.preferences.showSweep)) { timeline in
                let rotation = store.preferences.useCompass
                    ? -store.compassHeadingDegrees + store.preferences.compassAzimuthOffset
                    : 0
                let sweep = timeline.date.timeIntervalSinceReferenceDate * 45
                PolarRadarPlot(
                    position: position,
                    trajectory: trajectory,
                    rotationDegrees: rotation,
                    elevationOffsetDegrees: store.preferences.compassElevationOffset,
                    sweepDegrees: sweep,
                    showSweep: store.preferences.showSweep
                )
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .orbitalGlass(cornerRadius: 30)
            }

            HStack(spacing: 10) {
                radarMetric("AZIMUTH", value: String(format: "%.1f°", position.azimuthDegrees))
                radarMetric("ELEVATION", value: String(format: "%+.1f°", position.elevationDegrees))
                radarMetric("RANGE", value: String(format: "%.0f km", position.distanceKilometers))
            }

            Label(
                position.isAboveHorizon ? "Satellite is above your horizon" : "Satellite is below your horizon",
                systemImage: position.isAboveHorizon ? "dot.radiowaves.left.and.right" : "moon"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(position.isAboveHorizon ? SkyPalette.cyan : SkyPalette.muted)
            .padding(.horizontal, 4)
            Text("Polar view is north-up; distance from the center represents elevation.")
                .font(.caption)
                .foregroundStyle(SkyPalette.muted)
                .padding(.horizontal, 4)
        } else {
            observationEmptyState(store: store)
        }
    }
}

private struct TransceiversPanel: View {
    @ObservedObject var store: SatelliteStore
    let satelliteID: Int32

    private var radios: [IOSTransponder] {
        store.transceivers.filter { $0.catalogNumber == satelliteID && $0.isAlive }
    }

    var body: some View {
        VStack(spacing: 12) {
            if radios.isEmpty {
                ContentUnavailableView(
                    "No transceivers found",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Refresh the transceiver catalog or choose another satellite.")
                )
                Button { Task { await store.refreshTransceivers() } } label: {
                    Label("Refresh transceivers", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.cyan)
                }
            } else {
                HStack {
                    Text("TRANSPONDERS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(SkyPalette.cyan)
                    Spacer()
                    Text("\(radios.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(SkyPalette.muted)
                }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(radios) { radio in transceiverRow(radio) }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .orbitalGlass(cornerRadius: 24)
    }

    private func transceiverRow(_ radio: IOSTransponder) -> some View {
        let selected = store.selectedTransponderUUID == radio.uuid
        return Button {
            store.selectTransponder(selected ? nil : radio.uuid)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 9) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(selected ? SkyPalette.cyan : SkyPalette.violet)
                    Text(radio.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: selected ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SkyPalette.muted)
                }
                HStack {
                    frequencyColumn("TX", low: radio.uplinkLow, high: radio.uplinkHigh)
                    Spacer()
                    frequencyColumn("RX", low: radio.downlinkLow, high: radio.downlinkHigh)
                }
                if selected {
                    HStack(spacing: 8) {
                        Label("Doppler calculator available", systemImage: "arrow.left.arrow.right")
                        Spacer()
                        Text(store.radioSettings.catEnabled ? "CAT not connected" : "CAT disabled")
                    }
                    .font(.caption2)
                    .foregroundStyle(SkyPalette.muted)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitalGlass(cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private func frequencyColumn(_ title: String, low: Int64?, high: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(SkyPalette.muted)
            Text(frequencyRange(low, high))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(SkyPalette.cyan)
        }
    }

    private func frequencyRange(_ low: Int64?, _ high: Int64?) -> String {
        guard let low else { return "—" }
        let lowMHz = Double(low) / 1_000_000
        guard let high, high != low else { return String(format: "%.4f MHz", lowMHz) }
        return String(format: "%.4f–%.4f MHz", lowMHz, Double(high) / 1_000_000)
    }
}

private struct DopplerCalculatorPanel: View {
    @ObservedObject var store: SatelliteStore
    let satelliteID: Int32
    @State private var selectedUUID = ""
    @State private var txFrequencyHz = 0.0
    @State private var rxFrequencyHz = 0.0
    @State private var offsetKHz = ""
    @State private var lastEditedField: DopplerEditedField = .tx

    private var radios: [IOSTransponder] {
        store.transceivers.filter { $0.catalogNumber == satelliteID && $0.isAlive && $0.isLinear }
    }
    private var transponder: IOSTransponder? {
        radios.first { $0.uuid == selectedUUID } ?? radios.first
    }
    private var position: TrackedPosition? {
        store.positions[satelliteID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DOPPLER CALCULATOR")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(SkyPalette.cyan)
                Spacer()
                Text("TX ↔ RX")
                    .font(.caption2.monospaced())
                    .foregroundStyle(SkyPalette.muted)
            }
            if radios.isEmpty {
                Text("No linear transponder is available for this satellite.")
                    .font(.subheadline)
                    .foregroundStyle(SkyPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let transponder {
                if radios.count > 1 {
                    Picker("Transponder", selection: $selectedUUID) {
                        ForEach(radios) { radio in Text(radio.info).tag(radio.uuid) }
                    }
                    .onChange(of: selectedUUID) { _, _ in resetFrequencies() }
                }
                HStack {
                    TextField("Downlink offset (kHz)", text: $offsetKHz)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 190)
                    Spacer()
                    Text(transponder.isInverted ? "INVERTED" : "NORMAL")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(transponder.isInverted ? .orange : SkyPalette.cyan)
                }
                frequencyControl(
                    title: "UPLINK · TX",
                    value: $txFrequencyHz,
                    low: transponder.uplinkLow ?? 0,
                    high: transponder.uplinkHigh ?? 0,
                    onChange: updateDownlink
                )
                frequencyControl(
                    title: "DOWNLINK · RX",
                    value: $rxFrequencyHz,
                    low: transponder.downlinkLow ?? 0,
                    high: transponder.downlinkHigh ?? 0,
                    onChange: updateUplink
                )
                Text(position == nil
                    ? "Waiting for a location fix…"
                    : "Live Doppler correction · range rate \(String(format: "%+.2f km/s", position!.distanceRateKilometersPerSecond))")
                    .font(.caption2)
                    .foregroundStyle(SkyPalette.muted)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .orbitalGlass(cornerRadius: 24)
        .task(id: satelliteID) { resetFrequencies() }
        .onChange(of: position?.timeMillis) { _, _ in updateFromCurrentPosition() }
        .onChange(of: offsetKHz) { _, _ in updateFromCurrentPosition() }
    }

    private func frequencyControl(
        title: String,
        value: Binding<Double>,
        low: Int64,
        high: Int64,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1).foregroundStyle(SkyPalette.muted)
                Spacer()
                Text(String(format: "%.6f MHz", value.wrappedValue / 1_000_000))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(SkyPalette.primary)
            }
            HStack(spacing: 8) {
                Button { onChange(max(Double(low), value.wrappedValue - 1_000)) } label: {
                    Image(systemName: "minus.circle").font(.title3).foregroundStyle(SkyPalette.cyan)
                }
                Slider(value: Binding(get: { value.wrappedValue }, set: onChange), in: Double(low)...Double(max(low, high)))
                    .tint(SkyPalette.cyan)
                Button { onChange(min(Double(high), value.wrappedValue + 1_000)) } label: {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(SkyPalette.cyan)
                }
            }
            HStack {
                Text(String(format: "%.4f", Double(low) / 1_000_000))
                Spacer()
                Text(String(format: "%.4f", Double(high) / 1_000_000))
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(SkyPalette.muted)
        }
    }

    private func resetFrequencies() {
        guard let radio = transponder,
              let txLow = radio.uplinkLow, let txHigh = radio.uplinkHigh else { return }
        selectedUUID = radio.uuid
        txFrequencyHz = Double(txLow + (txHigh - txLow) / 2)
        rxFrequencyHz = dopplerDownlink(mapUplinkToDownlink(txFrequencyHz, radio: radio) + offsetHz, position: position)
    }

    private func updateDownlink(_ tx: Double) {
        guard let radio = transponder else { return }
        lastEditedField = .tx
        txFrequencyHz = tx
        rxFrequencyHz = dopplerDownlink(mapUplinkToDownlink(tx, radio: radio) + offsetHz, position: position)
    }

    private func updateUplink(_ rx: Double) {
        guard let radio = transponder else { return }
        lastEditedField = .rx
        rxFrequencyHz = rx
        let baseRx = inverseDownlinkDoppler(rx, position: position) - offsetHz
        txFrequencyHz = dopplerUplink(mapDownlinkToUplink(baseRx, radio: radio), position: position)
    }

    private func updateFromCurrentPosition() {
        guard let radio = transponder else { return }
        if lastEditedField == .tx {
            rxFrequencyHz = dopplerDownlink(mapUplinkToDownlink(txFrequencyHz, radio: radio) + offsetHz, position: position)
        } else {
            let baseRx = inverseDownlinkDoppler(rxFrequencyHz, position: position) - offsetHz
            txFrequencyHz = dopplerUplink(mapDownlinkToUplink(baseRx, radio: radio), position: position)
        }
    }

    private var offsetHz: Double { (Double(offsetKHz) ?? 0) * 1_000 }

    private func mapUplinkToDownlink(_ frequency: Double, radio: IOSTransponder) -> Double {
        guard let low = radio.uplinkLow, let downLow = radio.downlinkLow else { return 0 }
        guard let upHigh = radio.uplinkHigh, let downHigh = radio.downlinkHigh, upHigh != low, downHigh != downLow else {
            return Double(downLow)
        }
        let position = (frequency - Double(low)) / Double(upHigh - low)
        return radio.isInverted
            ? Double(downHigh) - position * Double(downHigh - downLow)
            : Double(downLow) + position * Double(downHigh - downLow)
    }

    private func mapDownlinkToUplink(_ frequency: Double, radio: IOSTransponder) -> Double {
        guard let upLow = radio.uplinkLow, let downLow = radio.downlinkLow else { return 0 }
        guard let upHigh = radio.uplinkHigh, let downHigh = radio.downlinkHigh, upHigh != upLow, downHigh != downLow else {
            return Double(upLow)
        }
        let position = radio.isInverted
            ? (Double(downHigh) - frequency) / Double(downHigh - downLow)
            : (frequency - Double(downLow)) / Double(downHigh - downLow)
        return Double(upLow) + position * Double(upHigh - upLow)
    }

    private func dopplerDownlink(_ frequency: Double, position: TrackedPosition?) -> Double {
        guard let position else { return frequency }
        return frequency * (299_792_458 - position.distanceRateKilometersPerSecond * 1_000) / 299_792_458
    }

    private func dopplerUplink(_ frequency: Double, position: TrackedPosition?) -> Double {
        guard let position else { return frequency }
        return frequency * (299_792_458 + position.distanceRateKilometersPerSecond * 1_000) / 299_792_458
    }

    private func inverseDownlinkDoppler(_ frequency: Double, position: TrackedPosition?) -> Double {
        guard let position else { return frequency }
        return frequency * 299_792_458 / (299_792_458 - position.distanceRateKilometersPerSecond * 1_000)
    }
}

private enum DopplerEditedField: Equatable {
    case tx
    case rx
}

private struct SstvPanel: View {
    @StateObject private var capture = SstvAudioCapture()
    @AppStorage("sstvMode") private var selectedMode = "Auto"
    private let modes = [
        "Auto", "Wraase SC2-180", "Martin 1", "Martin 2", "Robot 36 Color", "Robot 72 Color",
        "Scottie 1", "Scottie 2", "Scottie DX", "PD 50", "PD 90", "PD 120", "PD 160", "PD 180", "PD 240", "PD 290"
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("SSTV IMAGE DECODER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(SkyPalette.cyan)
                Spacer()
                Text(capture.isRecording ? "LISTENING" : "STANDBY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(capture.isRecording ? SkyPalette.cyan : SkyPalette.muted)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.7))
                VStack(spacing: 12) {
                    Image(systemName: capture.isRecording ? "waveform" : "photo")
                        .font(.system(size: 38))
                        .foregroundStyle(SkyPalette.violet)
                    Text(capture.isRecording ? "Waiting for SSTV signal" : "Decoded image appears here")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                    if capture.isRecording {
                        ProgressView(value: Double(capture.inputLevel), total: 1)
                            .tint(SkyPalette.cyan)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .frame(minHeight: 210)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Picker("SSTV mode", selection: $selectedMode) {
                ForEach(modes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(SkyPalette.cyan)
            HStack(spacing: 10) {
                Button { capture.reset() } label: {
                    Label("Reset", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.white)
                }
                Button {
                    if capture.isRecording { capture.stop() }
                    else { capture.start() }
                } label: {
                    Label(capture.isRecording ? "Stop" : "Record", systemImage: capture.isRecording ? "pause.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(capture.isRecording ? SkyPalette.violet : SkyPalette.cyan, in: Capsule())
                        .foregroundStyle(SkyPalette.ink)
                }
            }
            if let error = capture.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Microphone audio is processed on device.")
                .font(.caption2)
                .foregroundStyle(SkyPalette.muted)
            Text("Image decoding and saving are not available in this iOS build yet.")
                .font(.caption2)
                .foregroundStyle(.orange.opacity(0.85))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .orbitalGlass(cornerRadius: 24)
        .onDisappear { capture.stop() }
    }
}

@MainActor
private final class SstvAudioCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var errorMessage: String?
    private let engine = AVAudioEngine()

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is required to receive SSTV audio."
                    return
                }
                self.startCapture()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
        inputLevel = 0
    }

    func reset() {
        inputLevel = 0
        errorMessage = nil
    }

    private func startCapture() {
        guard !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var squares = 0.0
                for index in 0..<count { squares += Double(channel[index] * channel[index]) }
                let level = Float(min(1, sqrt(squares / Double(count)) * 3))
                Task { @MainActor in self?.inputLevel = level }
            }
            engine.prepare()
            try engine.start()
            errorMessage = nil
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }
}

struct OrbitMapView: View {
    @ObservedObject var store: SatelliteStore
    let selectedSatelliteID: Int32
    let onSelectSatellite: (SatelliteTarget) -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var groundTrack: [TrackedPosition] = []

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                ForEach(groundTrackSegments(groundTrack).indices, id: \.self) { index in
                    let segment = groundTrackSegments(groundTrack)[index]
                    if segment.count > 1 {
                        MapPolyline(coordinates: segment.map { coordinate(for: $0) })
                            .stroke(SkyPalette.cyan, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                    }
                }

                if let location = store.observerLocation {
                    Annotation("You", coordinate: location.coordinate) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SkyPalette.cyan)
                            .padding(9)
                            .background(.black.opacity(0.72), in: Circle())
                    }
                }

                ForEach(store.trackedSatellites, id: \.catalogNumber) { satellite in
                    if let position = store.position(for: satellite) {
                        Annotation(satellite.name, coordinate: coordinate(for: position)) {
                            Button { onSelectSatellite(satellite) } label: {
                                Image(systemName: satellite.catalogNumber == selectedSatelliteID ? "dot.radiowaves.left.and.right" : "satellite")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(SkyPalette.primary)
                                    .padding(10)
                                    .background(
                                        satellite.catalogNumber == selectedSatelliteID ? SkyPalette.violet : SkyPalette.ink,
                                        in: Circle()
                                    )
                                    .overlay(Circle().strokeBorder(SkyPalette.primary.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 12) {
                pageHeading(eyebrow: "GROUND TRACK", title: "Map")
                SatellitePicker(
                    satellites: store.trackedSatellites,
                    selectedSatelliteID: selectedSatelliteID,
                    onSelect: onSelectSatellite
                )
                if let satellite = store.satellite(withID: selectedSatelliteID),
                   let position = store.position(for: satellite) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(position.isAboveHorizon ? SkyPalette.cyan : SkyPalette.violet)
                            .frame(width: 7, height: 7)
                        Text("\(satellite.name)  ·  \(String(format: "%+.0f° elevation", position.elevationDegrees))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SkyPalette.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .orbitalGlass(cornerRadius: 18)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: selectedSatelliteID) { await loadGroundTrack() }
        .onChange(of: store.locationDescription) { _, _ in
            Task { await loadGroundTrack() }
        }
    }

    private func loadGroundTrack() async {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        groundTrack = await store.trajectory(
            for: selectedSatelliteID,
            startTimeMillis: now - 45 * 60_000,
            endTimeMillis: now + 45 * 60_000,
            stepMillis: 90_000
        )
    }
}

struct AmsatStatusView: View {
    @ObservedObject var store: SatelliteStore
    @State private var selectedCell: AmsatCellSelection?

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                pageHeading(eyebrow: "AMSAT  /  LIVE REPORTS", title: "Satellite status")
                Spacer()
                Button { Task { await store.refreshAmsatStatus() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SkyPalette.primary)
                        .frame(width: 44, height: 44)
                        .orbitalGlass(cornerRadius: 22)
                }
                .disabled(store.isRefreshingAmsat)
                .accessibilityLabel("Refresh AMSAT status")
            }
            if let fetchedAt = store.amsatFetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(SkyPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            statusLegend
            if let error = store.amsatError {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.amsatRows.isEmpty && store.isRefreshingAmsat {
                Spacer()
                ProgressView("Loading satellite activity…").tint(SkyPalette.cyan)
                Spacer()
            } else if store.amsatRows.isEmpty {
                ContentUnavailableView(
                    "Status unavailable",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(store.amsatError ?? "Pull down to retry when you have a connection.")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text("SATELLITE")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(SkyPalette.cyan)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(store.amsatDays) { day in
                                Text(day.label.uppercased())
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .tracking(0.5)
                                    .foregroundStyle(SkyPalette.cyan)
                                    .frame(width: 50)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)

                        ForEach(store.amsatRows) { row in
                            HStack(spacing: 5) {
                                Text(row.name)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(SkyPalette.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                                    Button {
                                        guard index < store.amsatDays.count else { return }
                                        selectedCell = AmsatCellSelection(
                                            satelliteName: row.name,
                                            day: store.amsatDays[index],
                                            cell: cell
                                        )
                                    } label: {
                                        Text(cell.count == 0 ? "" : "\(cell.count)")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .frame(width: 50, height: 32)
                                            .background(statusColor(cell.status), in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(row.name), \(store.amsatDays[index].label), \(cell.count) reports")
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(SkyPalette.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
                .refreshable { await store.refreshAmsatStatus() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $selectedCell) { selection in
            AmsatReportSheet(selection: selection, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var statusLegend: some View {
        HStack(spacing: 7) {
            legendItem("Heard", color: Color(red: 0.39, green: 0.56, blue: 1.0))
            legendItem("Telemetry", color: Color(red: 1.0, green: 0.69, blue: 0.0))
            legendItem("Not heard", color: Color(red: 0.86, green: 0.13, blue: 0.50))
            legendItem("Crew", color: Color(red: 1.0, green: 0.38, blue: 0.0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(SkyPalette.muted)
        }
    }
}

struct PassFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PassFilterSettings
    let onApply: (PassFilterSettings) -> Void

    init(filters: PassFilterSettings, onApply: @escaping (PassFilterSettings) -> Void) {
        _draft = State(initialValue: filters)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Prediction window") {
                    Picker("Hours ahead", selection: $draft.hoursAhead) {
                        ForEach(PassFilterSettings.hourChoices, id: \.self) { hours in
                            Text(hoursLabel(hours)).tag(hours)
                        }
                    }
                    Toggle("Show deep-space satellites", isOn: $draft.showDeepSpace)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Minimum elevation")
                            Spacer()
                            Text("\(Int(draft.minimumElevation))°")
                                .monospacedDigit()
                                .foregroundStyle(SkyPalette.cyan)
                        }
                        Slider(value: $draft.minimumElevation, in: 0...60, step: 1)
                            .tint(SkyPalette.cyan)
                    }
                } header: {
                    Text("Pass quality")
                } footer: {
                    Text("Only passes reaching this elevation or higher are listed.")
                }
                Section {
                    minuteSlider("From", value: $draft.aosStartMinute)
                    minuteSlider("To", value: $draft.aosEndMinute)
                    Toggle("Invert time range", isOn: $draft.invertAosTimeWindow)
                } header: {
                    Text("AOS local time")
                } footer: {
                    Text("The time window applies to acquisition of signal. Deep-space satellites are not restricted by this window.")
                }
                Section {
                    minuteDegreeSlider("Low threshold", value: $draft.lowHighlightElevation)
                    minuteDegreeSlider("High threshold", value: $draft.highHighlightElevation)
                } header: {
                    Text("Elevation highlighting")
                } footer: {
                    Text("Pass elevations are colored according to these thresholds.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .navigationTitle("Pass filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func minuteSlider(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(timeLabel(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(SkyPalette.cyan)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                in: 0...1_439,
                step: 15
            )
            .tint(SkyPalette.cyan)
        }
    }

    private func minuteDegreeSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))°")
                    .monospacedDigit()
                    .foregroundStyle(SkyPalette.cyan)
            }
            Slider(value: value, in: 0...90, step: 1).tint(SkyPalette.cyan)
        }
    }

    private func timeLabel(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    private func hoursLabel(_ hours: Int) -> String {
        guard hours >= 24 else { return "\(hours) hours" }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(days) days" : "\(days)d \(remainder)h"
    }
}

struct DataSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IOSDataSourceSettings
    @State private var editMode: EditMode = .inactive
    let statuses: [String: Int]
    let onApply: (IOSDataSourceSettings) -> Void

    init(settings: IOSDataSourceSettings, statuses: [String: Int], onApply: @escaping (IOSDataSourceSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.statuses = statuses
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            List {
                sourceSection(title: "Orbital elements", entries: $draft.satellites)
                sourceSection(title: "Transceivers", entries: $draft.transceivers)
                Section {
                    Text("Enabled sources are queried in order. TLE, 3LE and OMM CSV are supported; ZIP sources are not imported on iOS.")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .environment(\.editMode, $editMode)
            .navigationTitle("Data sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onApply(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func sourceSection(title: String, entries: Binding<[IOSDataSource]>) -> some View {
        Section {
            ForEach(entries) { $entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("", isOn: $entry.isEnabled).labelsHidden().tint(SkyPalette.cyan)
                        TextField("Source URL", text: $entry.url)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if let code = statuses[entry.url] {
                        Text(code == -1 ? "Last request failed" : "Last response: HTTP \(code)")
                            .font(.caption2)
                            .foregroundStyle(code == 200 ? SkyPalette.cyan : .orange)
                            .padding(.leading, 45)
                    }
                }
                .padding(.vertical, 4)
            }
            .onMove { entries.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { entries.wrappedValue.remove(atOffsets: $0) }
            Button {
                entries.wrappedValue.append(IOSDataSource(url: ""))
            } label: {
                Label("Add source", systemImage: "plus")
            }
            Button("Restore defaults", role: .destructive) {
                if title == "Orbital elements" { draft.satellites = IOSDataSourceSettings.defaults.satellites }
                else { draft.transceivers = IOSDataSourceSettings.defaults.transceivers }
            }
        } header: {
            Text(title)
        }
    }
}

enum RadioSettingsPage: String, Identifiable {
    case network
    case bluetooth
    case cat

    var id: String { rawValue }
    var title: String {
        switch self {
        case .network: return "Network output"
        case .bluetooth: return "Bluetooth output"
        case .cat: return "CAT radio control"
        }
    }
}

struct RadioSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IOSRadioSettings
    let page: RadioSettingsPage
    let onSave: (IOSRadioSettings) -> Void

    init(settings: IOSRadioSettings, page: RadioSettingsPage, onSave: @escaping (IOSRadioSettings) -> Void) {
        _draft = State(initialValue: settings)
        self.page = page
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                switch page {
                case .network: networkFields
                case .bluetooth: bluetoothFields
                case .cat: catFields
                }
                Section {
                    Text("Settings are stored on this device. Live CAT hardware control requires a supported iOS radio connection.")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var networkFields: some View {
        Section("Rotator") {
            Toggle("Enable network rotator", isOn: $draft.networkRotatorEnabled)
            TextField("Host / IP", text: $draft.networkRotatorAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.networkRotatorEnabled)
            TextField("Port", text: $draft.networkRotatorPort).keyboardType(.numberPad)
                .disabled(!draft.networkRotatorEnabled)
            TextField("Command format", text: $draft.networkRotatorFormat)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.networkRotatorEnabled)
        }
        Section("Frequency display") {
            Toggle("Enable frequency output", isOn: $draft.networkFrequencyEnabled)
            TextField("Host / IP", text: $draft.networkFrequencyAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.networkFrequencyEnabled)
            TextField("Port", text: $draft.networkFrequencyPort).keyboardType(.numberPad)
                .disabled(!draft.networkFrequencyEnabled)
            TextField("Command format", text: $draft.networkFrequencyFormat)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.networkFrequencyEnabled)
            TextField("Frequency offset (Hz)", value: $draft.networkFrequencyOffsetHz, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .disabled(!draft.networkFrequencyEnabled)
        }
    }

    @ViewBuilder
    private var bluetoothFields: some View {
        Section("Rotator") {
            Toggle("Enable Bluetooth rotator", isOn: $draft.bluetoothRotatorEnabled)
            TextField("Device name", text: $draft.bluetoothRotatorName).disabled(!draft.bluetoothRotatorEnabled)
            TextField("Device address", text: $draft.bluetoothRotatorAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.bluetoothRotatorEnabled)
            TextField("Command format", text: $draft.bluetoothRotatorFormat)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.bluetoothRotatorEnabled)
        }
        Section("Frequency display") {
            Toggle("Enable Bluetooth frequency output", isOn: $draft.bluetoothFrequencyEnabled)
            TextField("Device name", text: $draft.bluetoothFrequencyName).disabled(!draft.bluetoothFrequencyEnabled)
            TextField("Device address", text: $draft.bluetoothFrequencyAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.bluetoothFrequencyEnabled)
            TextField("Command format", text: $draft.bluetoothFrequencyFormat)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.bluetoothFrequencyEnabled)
        }
    }

    @ViewBuilder
    private var catFields: some View {
        Section("CAT radio") {
            Toggle("Enable radio control", isOn: $draft.catEnabled)
            Picker("Radio model", selection: $draft.radioModel) {
                ForEach(["Yaesu FT-817/818", "Yaesu FT-857/897", "Icom IC-705"], id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .disabled(!draft.catEnabled)
            TextField("TX radio name", text: $draft.txRadioName).disabled(!draft.catEnabled)
            TextField("TX radio address", text: $draft.txRadioAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(!draft.catEnabled)
            if draft.radioModel == "Icom IC-705" {
                Toggle("Single-radio split mode", isOn: $draft.splitMode).disabled(!draft.catEnabled)
            }
            if !draft.splitMode {
                TextField("RX radio name", text: $draft.rxRadioName).disabled(!draft.catEnabled)
                TextField("RX radio address", text: $draft.rxRadioAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!draft.catEnabled)
            }
            Picker("Baud rate", selection: $draft.baudRate) {
                ForEach(draft.radioModel == "Icom IC-705"
                    ? [4_800, 9_600, 19_200, 38_400, 57_600, 115_200]
                    : [4_800, 9_600, 38_400], id: \.self) { baud in
                    Text("\(baud)").tag(baud)
                }
            }
            .disabled(!draft.catEnabled)
        }
    }
}

struct SatelliteModesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>
    let modes: [String]
    let title: String
    let onApply: (Set<String>) -> Void

    init(
        modes: [String],
        selection: Set<String>,
        title: String,
        onApply: @escaping (Set<String>) -> Void
    ) {
        self.modes = modes
        self.title = title
        self.onApply = onApply
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button("All") { selection = Set(modes) }
                        Spacer()
                        Button("Clear") { selection.removeAll() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .listRowBackground(Color.clear)
                    ForEach(modes, id: \.self) { mode in
                        Button {
                            if selection.contains(mode) { selection.remove(mode) }
                            else { selection.insert(mode) }
                        } label: {
                            HStack {
                                Text(mode).foregroundStyle(SkyPalette.primary)
                                Spacer()
                                if selection.contains(mode) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SkyPalette.cyan)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(SkyPalette.muted)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(selection.isEmpty ? "No mode filter: show every satellite." : "Showing satellites with at least one selected radio mode.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        onApply(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct AmsatCellSelection: Identifiable {
    let satelliteName: String
    let day: AmsatStatusDay
    let cell: AmsatStatusCell
    var id: String { "\(satelliteName):\(day.id)" }
}

private struct AmsatReportSheet: View {
    let selection: AmsatCellSelection
    @ObservedObject var store: SatelliteStore
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingUpload = false
    @State private var isConfirmingUpload = false
    @State private var selectedReport = "Heard"
    @State private var callsign = UserDefaults.standard.string(forKey: "amsatCallsign") ?? ""
    @State private var gridSquare = ""

    private var reportOptions: [String] {
        selection.satelliteName.hasPrefix("ISS")
            ? ["Heard", "Telemetry Only", "Not Heard", "Crew Active"]
            : ["Heard", "Telemetry Only", "Not Heard"]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(selection.satelliteName) · \(selection.day.label)") {
                    if selection.cell.reports.isEmpty {
                        Text("No reports for this day.").foregroundStyle(SkyPalette.muted)
                    } else {
                        ForEach(selection.cell.reports) { report in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle().fill(statusColor(report.status)).frame(width: 8, height: 8)
                                    Text(report.status).font(.subheadline.weight(.semibold))
                                }
                                Text("\(report.callsign)  ·  \(report.dateUtc)  \(report.timeUtc)")
                                    .font(.caption)
                                    .foregroundStyle(SkyPalette.muted)
                                if !report.gridSquare.isEmpty && report.gridSquare != "-" {
                                    Text(report.gridSquare).font(.caption2).foregroundStyle(SkyPalette.muted)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                Section {
                    Button {
                        isShowingUpload.toggle()
                        store.clearAmsatUploadMessages()
                    } label: {
                        Label(isShowingUpload ? "Hide report form" : "Submit status report", systemImage: "square.and.pencil")
                    }
                    if isShowingUpload {
                        Picker("Status", selection: $selectedReport) {
                            ForEach(reportOptions, id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Callsign", text: $callsign)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("Grid square (optional)", text: $gridSquare)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        if let error = store.amsatUploadError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if let message = store.amsatUploadMessage {
                            Text(message).font(.caption).foregroundStyle(SkyPalette.cyan)
                        }
                        Button {
                            isConfirmingUpload = true
                        } label: {
                            HStack {
                                Text("Review and submit")
                                Spacer()
                                if store.isSubmittingAmsatReport { ProgressView() }
                            }
                        }
                        .disabled(store.isSubmittingAmsatReport)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .navigationTitle("AMSAT reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Submit \(selectedReport) for \(selection.satelliteName)?",
                isPresented: $isConfirmingUpload,
                titleVisibility: .visible
            ) {
                Button("Submit report") {
                    Task {
                        await store.submitAmsatReport(
                            satelliteName: selection.satelliteName,
                            report: selectedReport,
                            callsign: callsign,
                            gridSquare: gridSquare
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private func statusColor(_ status: String?) -> Color {
    switch status?.lowercased() {
    case "heard", "crew active": Color(red: 0.39, green: 0.56, blue: 1.0)
    case "telemetry only": Color(red: 1.0, green: 0.69, blue: 0.0)
    case "not heard": Color(red: 0.86, green: 0.13, blue: 0.50)
    case nil, "": Color(red: 0.75, green: 0.75, blue: 0.75)
    default: Color(red: 1.0, green: 0.38, blue: 0.0)
    }
}

private struct SatellitePicker: View {
    let satellites: [SatelliteTarget]
    let selectedSatelliteID: Int32
    let onSelect: (SatelliteTarget) -> Void

    private var selectedSatellite: SatelliteTarget? {
        satellites.first { $0.catalogNumber == selectedSatelliteID }
    }

    var body: some View {
        Menu {
            ForEach(satellites, id: \.catalogNumber) { satellite in
                Button { onSelect(satellite) } label: {
                    if satellite.catalogNumber == selectedSatelliteID {
                        Label(satellite.name, systemImage: "checkmark")
                    } else {
                        Text(satellite.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "satellite")
                    .foregroundStyle(SkyPalette.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSatellite?.name ?? "No satellite selected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.primary)
                        .lineLimit(1)
                    if let selectedSatellite {
                        Text("NORAD  \(selectedSatellite.catalogNumber)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(SkyPalette.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SkyPalette.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitalGlass(cornerRadius: 18)
        }
        .disabled(satellites.isEmpty)
    }
}

private struct PolarRadarPlot: View {
    let position: TrackedPosition
    let trajectory: [TrackedPosition]
    let rotationDegrees: Double
    let elevationOffsetDegrees: Double
    let sweepDegrees: Double
    let showSweep: Bool

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = diameter * 0.405
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Canvas { context, _ in
                    for elevation in [0.0, 30.0, 60.0] {
                        let ringRadius = radius * CGFloat(1 - elevation / 90)
                        let rect = CGRect(
                            x: center.x - ringRadius,
                            y: center.y - ringRadius,
                            width: ringRadius * 2,
                            height: ringRadius * 2
                        )
                        context.stroke(Path(ellipseIn: rect), with: .color(SkyPalette.primary.opacity(0.22)), lineWidth: 1)
                    }
                    var axes = Path()
                    axes.move(to: CGPoint(x: center.x - radius, y: center.y))
                    axes.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    axes.move(to: CGPoint(x: center.x, y: center.y - radius))
                    axes.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    context.stroke(axes, with: .color(SkyPalette.primary.opacity(0.2)), lineWidth: 1)

                    if showSweep {
                        let angle = (sweepDegrees.truncatingRemainder(dividingBy: 360) - 90) * .pi / 180
                        var sweep = Path()
                        sweep.move(to: center)
                        sweep.addLine(to: CGPoint(
                            x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius
                        ))
                        context.stroke(sweep, with: .color(SkyPalette.cyan.opacity(0.75)), lineWidth: 1.5)
                    }

                    if trajectory.count > 1 {
                        var path = Path()
                        for (index, point) in trajectory.enumerated() {
                            let projected = radarPoint(point, center: center, radius: radius)
                            if index == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                        }
                        context.stroke(path, with: .color(SkyPalette.violet.opacity(0.75)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }

                    let satellitePoint = radarPoint(position, center: center, radius: radius)
                    let dotRadius: CGFloat = 7
                    let dot = Path(ellipseIn: CGRect(
                        x: satellitePoint.x - dotRadius,
                        y: satellitePoint.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    ))
                    context.fill(dot, with: .color(position.isAboveHorizon ? SkyPalette.cyan : .orange))
                    context.stroke(dot, with: .color(SkyPalette.primary), lineWidth: 1.5)
                }
                Text("N").position(x: center.x, y: center.y - radius - 13)
                Text("E").position(x: center.x + radius + 13, y: center.y)
                Text("S").position(x: center.x, y: center.y + radius + 13)
                Text("W").position(x: center.x - radius - 13, y: center.y)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(SkyPalette.muted)
        }
        .rotationEffect(.degrees(rotationDegrees))
        .aspectRatio(1, contentMode: .fit)
        .padding(12)
    }

    private func radarPoint(_ point: TrackedPosition, center: CGPoint, radius: CGFloat) -> CGPoint {
        let elevation = min(90, max(0, point.elevationDegrees + elevationOffsetDegrees))
        let radialDistance = radius * CGFloat(1 - elevation / 90)
        let angle = (point.azimuthDegrees - 90) * .pi / 180
        return CGPoint(
            x: center.x + cos(angle) * radialDistance,
            y: center.y + sin(angle) * radialDistance
        )
    }
}

private func pageHeading(eyebrow: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(eyebrow)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(SkyPalette.cyan)
        Text(title)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(SkyPalette.primary)
    }
}

private func radarMetric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(SkyPalette.muted)
        Text(value)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(SkyPalette.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .orbitalGlass(cornerRadius: 18)
}

@MainActor
private func observationEmptyState(store: SatelliteStore) -> some View {
    VStack(spacing: 14) {
        Image(systemName: store.observerLocation == nil ? "location.slash" : "dot.scope")
            .font(.system(size: 30))
            .foregroundStyle(SkyPalette.violet)
        Text(store.observerLocation == nil ? "Location needed" : "Tracking data unavailable")
            .font(.headline)
            .foregroundStyle(SkyPalette.primary)
        Text(store.observerLocation == nil
            ? "Allow location access to calculate the sky around you."
            : "Select a satellite from the catalog to begin tracking.")
            .font(.subheadline)
            .foregroundStyle(SkyPalette.muted)
            .multilineTextAlignment(.center)
        if store.observerLocation == nil {
            Button(action: store.useDeviceLocation) {
                Label("Use my location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyPalette.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(SkyPalette.cyan, in: Capsule())
            }
        }
    }
    .frame(maxWidth: .infinity)
    .padding(28)
    .orbitalGlass()
}

private func coordinate(for position: TrackedPosition) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: position.latitudeDegrees, longitude: position.longitudeDegrees)
}

private func groundTrackSegments(_ positions: [TrackedPosition]) -> [[TrackedPosition]] {
    guard let first = positions.first else { return [] }
    var segments: [[TrackedPosition]] = [[first]]
    for position in positions.dropFirst() {
        if let previous = segments[segments.count - 1].last,
           abs(position.longitudeDegrees - previous.longitudeDegrees) > 180 {
            segments.append([])
        }
        segments[segments.count - 1].append(position)
    }
    return segments.filter { $0.count > 1 }
}

struct LocationSettings: View {
    @ObservedObject var store: SatelliteStore
    @State private var isShowingEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.locationDescription)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SkyPalette.primary)
            Text(store.manualLocation == nil ? "Using device location. Coordinates stay on this device." : "Using a saved station position on this device.")
                .font(.caption)
                .foregroundStyle(SkyPalette.muted)
            HStack(spacing: 18) {
                Button(action: store.useDeviceLocation) {
                    Label("Use GPS", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.cyan)
                }
                Button { isShowingEditor = true } label: {
                    Label("Enter location", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.cyan)
                }
            }
            if store.manualLocation != nil {
                Button("Return to device location", action: store.useDeviceLocation)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SkyPalette.muted)
            }
        }
        .sheet(isPresented: $isShowingEditor) {
            ManualLocationSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct PreferenceToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(SkyPalette.primary)
                Text(detail).font(.caption).foregroundStyle(SkyPalette.muted)
            }
        }
        .tint(SkyPalette.cyan)
        .disabled(isDisabled)
        .padding(.vertical, 3)
    }
}

struct OffsetSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(SkyPalette.muted)
                Spacer()
                Text("\(Int(value))°").font(.caption.monospacedDigit()).foregroundStyle(SkyPalette.primary)
            }
            Slider(value: $value, in: range, step: 1).tint(SkyPalette.cyan)
        }
    }
}

private struct ManualLocationSheet: View {
    @ObservedObject var store: SatelliteStore
    @Environment(\.dismiss) private var dismiss
    @State private var latitude: String
    @State private var longitude: String
    @State private var locator = ""
    @State private var altitude = "0"
    @State private var entryMode = "Coordinates"
    @State private var error: String?

    init(store: SatelliteStore) {
        self.store = store
        let coordinate = store.observerLocation?.coordinate
        _latitude = State(initialValue: coordinate.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: coordinate.map { String($0.longitude) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Entry method", selection: $entryMode) {
                    Text("Coordinates").tag("Coordinates")
                    Text("Maidenhead locator").tag("Locator")
                }
                .pickerStyle(.segmented)
                if entryMode == "Coordinates" {
                    TextField("Latitude", text: $latitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitude)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Altitude (meters)", text: $altitude)
                        .keyboardType(.numbersAndPunctuation)
                } else {
                    TextField("4- or 6-character locator", text: $locator)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("Example: CN87")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SkyPalette.ink)
            .navigationTitle("Station position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let coordinate: (Double, Double)?
        if entryMode == "Coordinates" {
            if let lat = Double(latitude), let lon = Double(longitude) { coordinate = (lat, lon) }
            else { coordinate = nil }
        } else {
            coordinate = parseMaidenhead(locator)
        }
        guard let (lat, lon) = coordinate else {
            error = entryMode == "Coordinates" ? "Enter valid numeric coordinates." : "Enter a valid 4- or 6-character locator."
            return
        }
        guard store.setManualLocation(latitude: lat, longitude: lon, altitudeMeters: Double(altitude) ?? 0) else {
            error = "Latitude must be −90…90 and longitude −180…180."
            return
        }
        dismiss()
    }

    private func parseMaidenhead(_ text: String) -> (Double, Double)? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 4 || value.count == 6 else { return nil }
        let chars = Array(value)
        guard ("A"..."R").contains(chars[0]), ("A"..."R").contains(chars[1]),
              chars[2].isNumber, chars[3].isNumber else { return nil }
        var lon = Double(chars[0].asciiValue! - Character("A").asciiValue!) * 20 - 180
        var lat = Double(chars[1].asciiValue! - Character("A").asciiValue!) * 10 - 90
        lon += Double(chars[2].wholeNumberValue!) * 2
        lat += Double(chars[3].wholeNumberValue!)
        if chars.count == 6 {
            guard ("A"..."X").contains(chars[4]), ("A"..."X").contains(chars[5]) else { return nil }
            lon += Double(chars[4].asciiValue! - Character("A").asciiValue!) / 12 + 1.0 / 24
            lat += Double(chars[5].asciiValue! - Character("A").asciiValue!) / 24 + 1.0 / 48
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }
}
