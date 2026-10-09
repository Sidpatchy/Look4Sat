import CoreLocation
import AVFAudio
import Combine
import CoreMotion
import EventKit
import EventKitUI
import Foundation
import Look4SatShared
import MapKit
import Photos
import SwiftUI
import UIKit

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
    @StateObject private var sstvCapture = SstvAudioCapture()

    private var selectedPass: PassItem? { store.relevantPass(for: selectedSatelliteID) }
    private var trajectoryTaskKey: String { "\(selectedSatelliteID):\(selectedPass?.id ?? "none")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeading(eyebrow: "LIVE LOOK ANGLES", title: "Radar")
                SatellitePicker(
                    satellites: store.trackedSatellites,
                    selectedSatelliteID: selectedSatelliteID,
                    onSelect: onSelectSatellite
                )
                RadarPassTimer(store: store, satelliteID: selectedSatelliteID, allowsCalendar: true)
                Picker("Radar page", selection: $selectedPane) {
                    ForEach(RadarPane.allCases) { pane in Text(pane.rawValue).tag(pane) }
                }
                .pickerStyle(.segmented)

                switch selectedPane {
                case .radar:
                    RadarDisplay(
                        store: store,
                        livePosition: store.livePosition,
                        satelliteID: selectedSatelliteID,
                        trajectory: trajectory
                    )
                case .transceivers:
                    TransceiversPanel(store: store, satelliteID: selectedSatelliteID)
                case .calculator:
                    DopplerCalculatorPanel(store: store, satelliteID: selectedSatelliteID)
                case .sstv:
                    SstvPanel(capture: sstvCapture)
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.recalculatePasses() }
        .task(id: trajectoryTaskKey) {
            await loadTrajectory()
        }
        .onChange(of: selectedPane) { oldValue, newValue in
            if oldValue == .sstv && newValue != .sstv { sstvCapture.stop() }
        }
        .onDisappear { sstvCapture.stop() }
    }

    private func loadTrajectory() async {
        guard let pass = selectedPass else {
            trajectory = []
            return
        }
        let duration = pass.prediction.losTimeMillis - pass.prediction.aosTimeMillis
        let sampledTrajectory = await store.trajectory(
            for: selectedSatelliteID,
            startTimeMillis: pass.prediction.aosTimeMillis,
            endTimeMillis: pass.prediction.losTimeMillis,
            stepMillis: max(5_000, duration / 120)
        )
        guard !Task.isCancelled else { return }
        trajectory = sampledTrajectory
    }

}

private struct RadarDisplay: View {
    @ObservedObject var store: SatelliteStore
    @ObservedObject var livePosition: LiveSatellitePositionStore
    let satelliteID: Int32
    let trajectory: [TrackedPosition]
    @StateObject private var orientation = RadarOrientationManager()

    private var position: TrackedPosition? {
        if let reading = livePosition.reading, reading.catalogNumber == satelliteID {
            return reading.position
        }
        guard let satellite = store.satellite(withID: satelliteID) else { return nil }
        return store.position(for: satellite)
    }

    var body: some View {
        Group {
            if let position {
                let correctedAimElevation = orientation.elevationDegrees + store.preferences.compassElevationOffset
                let correctedAimAzimuth = orientation.azimuthDegrees + store.preferences.compassAzimuthOffset
                let displayedAimAzimuth = (correctedAimAzimuth.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let rotation = store.preferences.useCompass
                    ? -orientation.rotationHeadingDegrees - store.preferences.compassAzimuthOffset
                    : 0
                PolarRadarPlot(
                    position: position,
                    trajectory: trajectory,
                    rotationDegrees: rotation,
                    positionColor: SkyPalette.elevationColor(
                        position.elevationDegrees,
                        low: store.passFilters.lowHighlightElevation,
                        high: store.passFilters.highHighlightElevation
                    ),
                    pointingElevationDegrees: correctedAimElevation,
                    showsPointingMarker: store.preferences.useCompass && orientation.isAvailable,
                    showsSweep: store.preferences.showSweep
                )
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .orbitalGlass(cornerRadius: 30)

                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .foregroundStyle(orientation.isAvailable ? SkyPalette.accent : SkyPalette.muted)
                    if store.preferences.useCompass && orientation.isAvailable {
                        Text("PHONE AIM  ·  AZ \(String(format: "%.0f°", displayedAimAzimuth))  EL \(String(format: "%+.0f°", correctedAimElevation))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SkyPalette.primary)
                        Spacer(minLength: 4)
                        Text(orientation.northReference)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyPalette.muted)
                    } else if store.preferences.useCompass {
                        Text("Phone orientation sensor unavailable")
                            .font(.caption)
                            .foregroundStyle(SkyPalette.muted)
                    } else {
                        Text("Pointing indicator disabled in Settings")
                            .font(.caption)
                            .foregroundStyle(SkyPalette.muted)
                    }
                }
                .padding(.horizontal, 4)

                if orientation.shouldWarnCalibration {
                    Label(
                        "Compass accuracy is low. Move away from magnets and move the phone in a figure-eight.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                }

                HStack(spacing: 10) {
                    radarMetric("AZIMUTH", value: String(format: "%.1f°", position.azimuthDegrees))
                    radarElevationMetric(position.elevationDegrees, filters: store.passFilters)
                    radarMetric("RANGE", value: String(format: "%.0f km", position.distanceKilometers))
                }

                Label(
                    position.isAboveHorizon ? "Satellite is above your horizon" : "Satellite is below your horizon",
                    systemImage: position.isAboveHorizon ? "dot.radiowaves.left.and.right" : "moon"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(position.isAboveHorizon ? SkyPalette.accent : SkyPalette.muted)
                .padding(.horizontal, 4)
                Text(store.preferences.useCompass && orientation.isAvailable
                    ? (store.preferences.useBackSideAsAim
                        ? "Phone-relative radar; the red reticle marks where the back of your phone points."
                        : "Phone-relative radar; the red reticle marks where the top of your phone points.")
                    : "North-up polar view; distance from the center represents elevation.")
                    .font(.caption)
                    .foregroundStyle(SkyPalette.muted)
                    .padding(.horizontal, 4)
            } else {
                observationEmptyState(store: store)
            }
        }
        .onAppear { updateOrientationUpdates() }
        .onChange(of: store.preferences.useCompass) { _, _ in updateOrientationUpdates() }
        .onChange(of: store.preferences.useBackSideAsAim) { _, _ in updateOrientationUpdates() }
        .onDisappear { orientation.stop() }
    }

    private func updateOrientationUpdates() {
        guard store.preferences.useCompass else {
            orientation.stop()
            return
        }
        orientation.start(useBackSideAsAim: store.preferences.useBackSideAsAim)
    }
}

private struct CalendarPass: Identifiable {
    let name: String
    let startTimeMillis: Int64
    let endTimeMillis: Int64

    var id: String { "\(name):\(startTimeMillis)" }
}

private struct CalendarEventEditor: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let pass: CalendarPass

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let eventStore = EKEventStore()
        let controller = EKEventEditViewController()
        let event = EKEvent(eventStore: eventStore)
        event.title = pass.name
        event.notes = "Look4Sat satellite pass"
        event.startDate = Date(timeIntervalSince1970: TimeInterval(pass.startTimeMillis) / 1000)
        event.endDate = Date(timeIntervalSince1970: TimeInterval(pass.endTimeMillis) / 1000)
        event.calendar = eventStore.defaultCalendarForNewEvents
        controller.eventStore = eventStore
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        private let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            onDismiss()
        }
    }
}

private struct RadarPassTimer: View {
    @ObservedObject var store: SatelliteStore
    let satelliteID: Int32
    let allowsCalendar: Bool
    @State private var calendarPass: CalendarPass?

    var body: some View {
        Group {
            if store.satellite(withID: satelliteID)?.isDeepSpace == true {
                HStack(spacing: 12) {
                    Image(systemName: "globe.americas.fill")
                        .foregroundStyle(SkyPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DEEP SPACE OBJECT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1)
                            .foregroundStyle(SkyPalette.accent)
                        Text("No AOS/LOS pass cycle")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(SkyPalette.primary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .orbitalGlass(cornerRadius: 18)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let now = Int64(timeline.date.timeIntervalSince1970 * 1000)
                    let satellitePasses = store.passes.filter { $0.satellite.catalogNumber == satelliteID }
                    let currentPass = satellitePasses.first {
                        $0.prediction.aosTimeMillis <= now && $0.prediction.losTimeMillis > now
                    }
                    let nextPass = satellitePasses.first { $0.prediction.aosTimeMillis > now }
                    let active = currentPass != nil
                    let pass = currentPass ?? nextPass

                    HStack(spacing: 10) {
                        timerEndpoint("AOS", millis: pass?.prediction.aosTimeMillis, emphasized: !active)
                        Spacer(minLength: 2)
                        VStack(spacing: 2) {
                            Text(active ? "TIME TO LOS" : "TIME TO AOS")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(1)
                                .foregroundStyle(SkyPalette.accent)
                            Text(pass.map { countdown(until: active ? $0.prediction.losTimeMillis : $0.prediction.aosTimeMillis, now: now) } ?? "—")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(SkyPalette.primary)
                        }
                        Spacer(minLength: 2)
                        timerEndpoint("LOS", millis: pass?.prediction.losTimeMillis, emphasized: active)
                        if allowsCalendar {
                            Button {
                                if let pass {
                                    calendarPass = CalendarPass(
                                        name: pass.satellite.name,
                                        startTimeMillis: pass.prediction.aosTimeMillis,
                                        endTimeMillis: pass.prediction.losTimeMillis
                                    )
                                }
                            } label: {
                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(pass == nil ? SkyPalette.muted : SkyPalette.accent)
                                    .frame(width: 30, height: 40)
                            }
                            .buttonStyle(.plain)
                            .disabled(pass == nil)
                            .accessibilityLabel("Add pass to calendar")
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .orbitalGlass(cornerRadius: 18)
                }
            }
        }
        .sheet(item: $calendarPass) { pass in
            CalendarEventEditor(pass: pass)
                .ignoresSafeArea()
        }
    }

    private func timerEndpoint(_ title: String, millis: Int64?, emphasized: Bool) -> some View {
        VStack(alignment: title == "AOS" ? .leading : .trailing, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(emphasized ? SkyPalette.accent : SkyPalette.muted)
            Text(millis.map { store.formattedTime($0, dateStyle: .none) } ?? "—")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(SkyPalette.primary)
                .monospacedDigit()
        }
        .frame(minWidth: 52, alignment: title == "AOS" ? .leading : .trailing)
    }

    private func countdown(until target: Int64, now: Int64) -> String {
        let totalSeconds = max(0, (target - now) / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
    }
}

@MainActor
private final class RadarOrientationManager: ObservableObject {
    private struct Sample: Equatable {
        var azimuthDegrees = 0.0
        var rotationHeadingDegrees = 0.0
        var elevationDegrees = 0.0
        var isAvailable = false
        var northReference = "REL"
        var shouldWarnCalibration = false
    }

    @Published private var sample = Sample()

    var azimuthDegrees: Double { sample.azimuthDegrees }
    var rotationHeadingDegrees: Double { sample.rotationHeadingDegrees }
    var elevationDegrees: Double { sample.elevationDegrees }
    var isAvailable: Bool { sample.isAvailable }
    var northReference: String { sample.northReference }
    var shouldWarnCalibration: Bool { sample.shouldWarnCalibration }

    private let motionManager = CMMotionManager()
    private var recentAzimuths: [Double] = []
    private var recentElevations: [Double] = []
    private var useBackSideAsAim = false

    func start(useBackSideAsAim: Bool) {
        let shouldRestart = motionManager.isDeviceMotionActive && self.useBackSideAsAim != useBackSideAsAim
        self.useBackSideAsAim = useBackSideAsAim
        if shouldRestart {
            motionManager.stopDeviceMotionUpdates()
            recentAzimuths.removeAll(keepingCapacity: true)
            recentElevations.removeAll(keepingCapacity: true)
            sample.isAvailable = false
        }
        guard !motionManager.isDeviceMotionActive, motionManager.isDeviceMotionAvailable else { return }
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let referenceFrame: CMAttitudeReferenceFrame
        if availableFrames.contains(.xTrueNorthZVertical) {
            referenceFrame = .xTrueNorthZVertical
            sample.northReference = "TRUE N"
        } else if availableFrames.contains(.xMagneticNorthZVertical) {
            referenceFrame = .xMagneticNorthZVertical
            sample.northReference = "MAG N"
        } else if availableFrames.contains(.xArbitraryCorrectedZVertical) {
            referenceFrame = .xArbitraryCorrectedZVertical
            sample.northReference = "REL"
        } else {
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
        let aimWithBack = useBackSideAsAim
        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, error in
            guard error == nil, let motion else { return }
            let magneticAccuracy = motion.magneticField.accuracy
            let calibrationWarning = magneticAccuracy == .uncalibrated || magneticAccuracy == .low
            let matrix = motion.attitude.rotationMatrix
            // The matrix maps world coordinates into device coordinates, so each
            // device axis expressed in world space is read from its matrix row.
            let north = aimWithBack ? Double(matrix.m31) : Double(matrix.m21)
            let west = aimWithBack ? Double(matrix.m32) : Double(matrix.m22)
            let up = aimWithBack ? Double(matrix.m33) : Double(matrix.m23)
            var azimuth = atan2(-west, north) * 180 / .pi
            if azimuth < 0 { azimuth += 360 }
            let elevation = asin(min(1, max(-1, up))) * 180 / .pi
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recentAzimuths.append(azimuth)
                self.recentElevations.append(elevation)
                if self.recentAzimuths.count > 5 { self.recentAzimuths.removeFirst() }
                if self.recentElevations.count > 5 { self.recentElevations.removeFirst() }
                let filteredAzimuth = (Self.circularMean(self.recentAzimuths) * 10).rounded() / 10
                let filteredElevation = (self.recentElevations.reduce(0, +) / Double(self.recentElevations.count) * 10).rounded() / 10
                var updated = self.sample
                if !updated.isAvailable {
                    updated.azimuthDegrees = filteredAzimuth
                    updated.rotationHeadingDegrees = filteredAzimuth
                    updated.elevationDegrees = filteredElevation
                } else {
                    let delta = (filteredAzimuth - updated.azimuthDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
                    if abs(delta) >= 0.15 {
                        updated.rotationHeadingDegrees += delta
                        updated.azimuthDegrees = (updated.azimuthDegrees + delta + 360).truncatingRemainder(dividingBy: 360)
                    }
                    let elevationDelta = filteredElevation - updated.elevationDegrees
                    if abs(elevationDelta) >= 0.2 {
                        updated.elevationDegrees = filteredElevation
                    }
                }
                updated.shouldWarnCalibration = calibrationWarning && updated.northReference != "REL"
                updated.isAvailable = true
                if updated != self.sample { self.sample = updated }
            }
        }
    }

    func stop() {
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        recentAzimuths.removeAll(keepingCapacity: true)
        recentElevations.removeAll(keepingCapacity: true)
        sample.isAvailable = false
    }

    private static func circularMean(_ angles: [Double]) -> Double {
        guard !angles.isEmpty else { return 0 }
        let radians = angles.map { $0 * .pi / 180 }
        let sine = radians.reduce(0) { $0 + sin($1) }
        let cosine = radians.reduce(0) { $0 + cos($1) }
        let degrees = atan2(sine, cosine) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
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
                        .foregroundStyle(SkyPalette.accent)
                }
            } else {
                HStack {
                    Text("TRANSPONDERS")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(SkyPalette.accent)
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
                        .foregroundStyle(selected ? SkyPalette.accent : SkyPalette.secondary)
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
                .foregroundStyle(SkyPalette.accent)
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
                    .foregroundStyle(SkyPalette.accent)
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
                        .foregroundStyle(transponder.isInverted ? .orange : SkyPalette.accent)
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
                    Image(systemName: "minus.circle").font(.title3).foregroundStyle(SkyPalette.accent)
                }
                Slider(value: Binding(get: { value.wrappedValue }, set: onChange), in: Double(low)...Double(max(low, high)))
                    .tint(SkyPalette.accent)
                Button { onChange(min(Double(high), value.wrappedValue + 1_000)) } label: {
                    Image(systemName: "plus.circle").font(.title3).foregroundStyle(SkyPalette.accent)
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
    @ObservedObject var capture: SstvAudioCapture
    @AppStorage("sstvMode") private var selectedMode = "Auto"

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("SSTV IMAGE DECODER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(SkyPalette.accent)
                Spacer()
                Text(capture.isRecording ? "LISTENING" : "STANDBY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(capture.isRecording ? SkyPalette.accent : SkyPalette.muted)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.black.opacity(0.7))
                if let image = capture.decodedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: capture.isRecording ? "waveform" : "photo")
                            .font(.system(size: 38))
                            .foregroundStyle(SkyPalette.accent)
                        Text(capture.isRecording ? "Listening for SSTV signal" : "Decoded image appears here")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                        if capture.isRecording {
                            ProgressView(value: Double(capture.inputLevel), total: 1)
                                .tint(SkyPalette.accent)
                                .padding(.horizontal, 24)
                        }
                    }
                }
            }
            .frame(minHeight: 210)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Picker("SSTV mode", selection: $selectedMode) {
                ForEach(capture.supportedModes, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(SkyPalette.accent)
            .onChange(of: selectedMode) { _, mode in capture.selectMode(mode) }
            .onChange(of: capture.supportedModes) { _, modes in
                if !modes.contains(selectedMode) { selectedMode = "Auto" }
                capture.selectMode(selectedMode)
            }
            HStack(spacing: 10) {
                Button { capture.reset() } label: {
                    Label("Reset", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Reset decoded SSTV image")
                Button { capture.saveImage() } label: {
                    HStack(spacing: 7) {
                        if capture.isSavingImage { ProgressView().tint(SkyPalette.primary) }
                        else { Image(systemName: "square.and.arrow.down") }
                        Text("Save")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SkyPalette.secondary, in: Capsule())
                    .foregroundStyle(SkyPalette.primary)
                }
                .disabled(capture.decodedImage == nil || capture.isSavingImage)
                Button {
                    if capture.isRecording { capture.stop() }
                    else { capture.start(mode: selectedMode) }
                } label: {
                    Label(capture.isRecording ? "Stop" : "Record", systemImage: capture.isRecording ? "pause.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(capture.isRecording ? SkyPalette.secondary : SkyPalette.accent, in: Capsule())
                        .foregroundStyle(SkyPalette.ink)
                }
            }
            if let quality = capture.qualitySummary {
                Text(quality)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = capture.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let saveMessage = capture.saveMessage {
                Text(saveMessage).font(.caption).foregroundStyle(SkyPalette.accent)
            }
            Text("Microphone audio is processed on device.")
                .font(.caption2)
                .foregroundStyle(SkyPalette.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .orbitalGlass(cornerRadius: 24)
        .task { capture.selectMode(selectedMode) }
    }
}

private struct DecodedSstvFrame: Sendable {
    let rgbaPixels: [UInt8]
    let width: Int
    let height: Int
    let modeName: String
    let imageComplete: Bool
    let inputRms: Float
    let appliedGain: Float
    let syncHitRate: Float
    let predictedLineBursts: Int
    let maxPredictedStreak: Int
    let timingErrorSamples: Int
}

private final class SstvDecoderWorker: @unchecked Sendable {
    var onFrame: ((DecodedSstvFrame) -> Void)?
    var onModes: (([String]) -> Void)?

    private let queue = DispatchQueue(label: "com.look4sat.sstv.decoder", qos: .userInitiated)
    private let lock = NSLock()
    private var isProcessing = false
    private var decoder: SstvDecoderBridge?

    func configure(sampleRate: Int, mode: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let decoder = SstvDecoderBridge(sampleRate: Int32(sampleRate))
            decoder.lockMode(modeName: mode)
            self.decoder = decoder
            let modes = (decoder.supportedModes as? [String]) ?? []
            DispatchQueue.main.async { self.onModes?(modes) }
        }
    }

    func selectMode(_ mode: String) {
        queue.async { [weak self] in self?.decoder?.lockMode(modeName: mode) }
    }

    func clear() {
        queue.async { [weak self] in self?.decoder?.clearPixels() }
    }

    func submit(samples: [Float]) {
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        queue.async { [weak self] in
            defer { self?.finishProcessing() }
            guard let self, let decoder = self.decoder else { return }
            let kotlinSamples = KotlinFloatArray(size: Int32(samples.count))
            for (index, sample) in samples.enumerated() {
                kotlinSamples.set(index: Int32(index), value: sample)
            }
            guard let frame = decoder.processSamples(samples: kotlinSamples),
                  let decoded = Self.convert(frame) else { return }
            self.onFrame?(decoded)
        }
    }

    private func finishProcessing() {
        lock.lock()
        isProcessing = false
        lock.unlock()
    }

    private static func convert(_ frame: SstvFrame) -> DecodedSstvFrame? {
        guard let pixels = frame.imagePixels,
              frame.imageWidth > 0,
              frame.imageHeight > 0 else { return nil }
        let width = Int(frame.imageWidth)
        let height = Int(frame.imageHeight)
        let count = width * height
        var rgba = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<count {
            let argb = UInt32(bitPattern: pixels.get(index: Int32(index)))
            let offset = index * 4
            rgba[offset] = UInt8((argb >> 16) & 0xff)
            rgba[offset + 1] = UInt8((argb >> 8) & 0xff)
            rgba[offset + 2] = UInt8(argb & 0xff)
            rgba[offset + 3] = UInt8((argb >> 24) & 0xff)
        }
        return DecodedSstvFrame(
            rgbaPixels: rgba,
            width: width,
            height: height,
            modeName: frame.modeName,
            imageComplete: frame.imageComplete,
            inputRms: frame.inputRms,
            appliedGain: frame.appliedGain,
            syncHitRate: frame.syncHitRate,
            predictedLineBursts: Int(frame.predictedLineBursts),
            maxPredictedStreak: Int(frame.maxPredictedStreak),
            timingErrorSamples: Int(frame.timingErrorSamples)
        )
    }
}

@MainActor
private final class SstvAudioCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var saveMessage: String?
    @Published private(set) var decodedImage: UIImage?
    @Published private(set) var supportedModes = [
        "Auto", "Wraase SC2-180", "Martin 1", "Martin 2", "Robot 36 Color", "Robot 72 Color",
        "Scottie 1", "Scottie 2", "Scottie DX", "PD 50", "PD 90", "PD 120", "PD 160", "PD 180", "PD 240", "PD 290"
    ]
    @Published private(set) var qualitySummary: String?

    private let engine = AVAudioEngine()
    private let decoderWorker = SstvDecoderWorker()
    private var hasInputTap = false
    private var hasActiveAudioSession = false

    init() {
        decoderWorker.onModes = { [weak self] modes in
            Task { @MainActor [weak self] in
                self?.supportedModes = ["Auto"] + modes
            }
        }
        decoderWorker.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in self?.display(frame) }
        }
    }

    func start(mode: String) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.errorMessage = "Microphone access is required to receive SSTV audio."
                    return
                }
                self.startCapture(mode: mode)
            }
        }
    }

    func stop() {
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if engine.isRunning { engine.stop() }
        if hasActiveAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false)
            hasActiveAudioSession = false
        }
        isRecording = false
        inputLevel = 0
    }

    func reset() {
        inputLevel = 0
        errorMessage = nil
        saveMessage = nil
        decodedImage = nil
        qualitySummary = nil
        decoderWorker.clear()
    }

    func selectMode(_ mode: String) {
        decoderWorker.selectMode(mode)
    }

    func saveImage() {
        guard let decodedImage else { return }
        isSavingImage = true
        saveMessage = nil
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized else {
                Task { @MainActor [weak self] in
                    self?.isSavingImage = false
                    self?.saveMessage = "Allow Photos access to save decoded images."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: decodedImage)
            } completionHandler: { [weak self] saved, error in
                Task { @MainActor [weak self] in
                    self?.isSavingImage = false
                    self?.saveMessage = saved ? "Saved to Photos." : (error?.localizedDescription ?? "Could not save the image.")
                }
            }
        }
    }

    @Published private(set) var isSavingImage = false

    private func startCapture(mode: String) {
        guard !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true)
            hasActiveAudioSession = true
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            decoderWorker.configure(sampleRate: Int(format.sampleRate.rounded()), mode: mode)
            input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                let samples = Array(UnsafeBufferPointer(start: channel, count: count))
                var squares = 0.0
                for sample in samples { squares += Double(sample * sample) }
                let level = Float(min(1, sqrt(squares / Double(count)) * 3))
                Task { @MainActor [weak self] in
                    self?.inputLevel = level
                    self?.decoderWorker.submit(samples: samples)
                }
            }
            hasInputTap = true
            engine.prepare()
            try engine.start()
            errorMessage = nil
            saveMessage = nil
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    private func display(_ frame: DecodedSstvFrame) {
        guard let image = Self.makeImage(frame) else { return }
        decodedImage = image
        qualitySummary = "\(frame.modeName) · RMS \(String(format: "%.3f", frame.inputRms)) · Sync \(Int(frame.syncHitRate * 100))% · \(frame.imageComplete ? "Complete" : "Receiving")"
    }

    private static func makeImage(_ frame: DecodedSstvFrame) -> UIImage? {
        let data = Data(frame.rgbaPixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let image = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct OrbitMapView: View {
    @ObservedObject var store: SatelliteStore
    @ObservedObject var livePosition: LiveSatellitePositionStore
    let selectedSatelliteID: Int32
    let onSelectSatellite: (SatelliteTarget) -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var groundTrack: [TrackedPosition] = []

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                if let sky = store.skyMapPositions {
                    let nightPolygons = nightSidePolygons(
                        sunLatitudeDegrees: sky.sunLatitudeDegrees,
                        sunLongitudeDegrees: sky.sunLongitudeDegrees
                    )
                    ForEach(nightPolygons.indices, id: \.self) { index in
                        MapPolygon(coordinates: nightPolygons[index])
                            .foregroundStyle(.black.opacity(0.22))
                    }
                    Annotation(
                        "Sun",
                        coordinate: CLLocationCoordinate2D(
                            latitude: sky.sunLatitudeDegrees,
                            longitude: sky.sunLongitudeDegrees
                        )
                    ) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(7)
                            .background(.black.opacity(0.75), in: Circle())
                    }
                    Annotation(
                        "Moon",
                        coordinate: CLLocationCoordinate2D(
                            latitude: sky.moonLatitudeDegrees,
                            longitude: sky.moonLongitudeDegrees
                        )
                    ) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(.black.opacity(0.75), in: Circle())
                    }
                }

                if let satellite = store.satellite(withID: selectedSatelliteID),
                   let position = currentPosition(for: satellite) {
                    let footprint = footprintBoundary(for: position)
                    MapPolygon(coordinates: footprint)
                        .foregroundStyle(SkyPalette.accent.opacity(0.12))
                    MapPolyline(coordinates: footprint, contourStyle: .geodesic)
                        .stroke(SkyPalette.accent.opacity(0.7), lineWidth: 1.5)
                }

                ForEach(groundTrackSegments(groundTrack).indices, id: \.self) { index in
                    let segment = groundTrackSegments(groundTrack)[index]
                    if segment.count > 1 {
                        MapPolyline(coordinates: segment.map { coordinate(for: $0) })
                            .stroke(SkyPalette.accent, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                    }
                }

                if let location = store.observerLocation {
                    Annotation("You", coordinate: location.coordinate) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SkyPalette.accent)
                            .padding(9)
                            .background(.black.opacity(0.72), in: Circle())
                    }
                }

                ForEach(store.trackedSatellites, id: \.catalogNumber) { satellite in
                    if let position = currentPosition(for: satellite) {
                        Annotation(satellite.name, coordinate: coordinate(for: position)) {
                            Button { onSelectSatellite(satellite) } label: {
                                Image(systemName: satellite.catalogNumber == selectedSatelliteID ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(SkyPalette.primary)
                                    .padding(10)
                                    .background(
                                        satellite.catalogNumber == selectedSatelliteID ? SkyPalette.secondary : SkyPalette.ink,
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
                RadarPassTimer(store: store, satelliteID: selectedSatelliteID, allowsCalendar: false)
                if let satellite = store.satellite(withID: selectedSatelliteID),
                   let position = currentPosition(for: satellite) {
                    HStack(spacing: 8) {
                        Circle().fill(SkyPalette.accent.opacity(0.65)).frame(width: 8, height: 8)
                        Text("\(satellite.name)  ·  \(String(format: "%+.0f° elevation", position.elevationDegrees))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SkyPalette.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("FOOTPRINT")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(SkyPalette.accent)
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

    private func currentPosition(for satellite: SatelliteTarget) -> TrackedPosition? {
        if let reading = livePosition.reading, reading.catalogNumber == satellite.catalogNumber {
            return reading.position
        }
        return store.position(for: satellite)
    }

    private func footprintBoundary(for position: TrackedPosition) -> [CLLocationCoordinate2D] {
        let earthRadius = 6_371.0
        let orbitalRadius = earthRadius + max(0, position.altitudeKilometers)
        let angularRadius = acos(min(1, earthRadius / orbitalRadius))
        let centerLatitude = position.latitudeDegrees * .pi / 180
        let centerLongitude = position.longitudeDegrees * .pi / 180
        let sampleCount = 72

        var coordinates = (0..<sampleCount).map { index -> CLLocationCoordinate2D in
            let bearing = Double(index) * 2 * .pi / Double(sampleCount)
            let latitude = asin(
                sin(centerLatitude) * cos(angularRadius) +
                    cos(centerLatitude) * sin(angularRadius) * cos(bearing)
            )
            let longitude = centerLongitude + atan2(
                sin(bearing) * sin(angularRadius) * cos(centerLatitude),
                cos(angularRadius) - sin(centerLatitude) * sin(latitude)
            )
            let longitudeDegrees = (longitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
            return CLLocationCoordinate2D(latitude: latitude * 180 / .pi, longitude: longitudeDegrees)
        }
        if let first = coordinates.first { coordinates.append(first) }
        return coordinates
    }

    private struct MapPoint {
        let longitude: Double
        let latitude: Double
    }

    /// Build narrow, antimeridian-clipped bands for the hemisphere facing away from the Sun.
    private func nightSidePolygons(
        sunLatitudeDegrees: Double,
        sunLongitudeDegrees: Double
    ) -> [[CLLocationCoordinate2D]] {
        let sunLatitude = sunLatitudeDegrees * .pi / 180
        let sunCenterLongitude = Self.normalizedLongitude(sunLongitudeDegrees + 180)
        let minimumLatitude = -85.0
        let maximumLatitude = 85.0
        let step = 1.0
        var polygons: [[CLLocationCoordinate2D]] = []

        func halfWidth(at latitudeDegrees: Double) -> Double {
            let latitude = latitudeDegrees * .pi / 180
            let denominator = cos(latitude) * cos(sunLatitude)
            let ratio: Double
            if abs(denominator) < 1e-12 {
                ratio = sin(latitude) * sin(sunLatitude) < 0 ? -1 : 1
            } else {
                ratio = sin(latitude) * sin(sunLatitude) / denominator
            }
            return acos(min(1, max(-1, ratio))) * 180 / .pi
        }

        var latitude = minimumLatitude
        while latitude < maximumLatitude {
            let nextLatitude = min(maximumLatitude, latitude + step)
            let bottomHalfWidth = halfWidth(at: latitude)
            let topHalfWidth = halfWidth(at: nextLatitude)
            if bottomHalfWidth + topHalfWidth > 0.01 {
                let band = [
                    MapPoint(longitude: sunCenterLongitude - bottomHalfWidth, latitude: latitude),
                    MapPoint(longitude: sunCenterLongitude - topHalfWidth, latitude: nextLatitude),
                    MapPoint(longitude: sunCenterLongitude + topHalfWidth, latitude: nextLatitude),
                    MapPoint(longitude: sunCenterLongitude + bottomHalfWidth, latitude: latitude)
                ]
                for worldOffset in -1...1 {
                    let shifted = band.map {
                        MapPoint(longitude: $0.longitude + Double(worldOffset) * 360, latitude: $0.latitude)
                    }
                    let clipped = Self.clipToWorldLongitude(shifted)
                    guard clipped.count >= 3, Self.polygonArea(clipped) > 1e-8 else { continue }
                    polygons.append(clipped.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                }
            }
            latitude = nextLatitude
        }
        return polygons
    }

    private static func clipToWorldLongitude(_ polygon: [MapPoint]) -> [MapPoint] {
        func clip(_ points: [MapPoint], boundary: Double, keepGreater: Bool) -> [MapPoint] {
            guard !points.isEmpty else { return [] }
            var result: [MapPoint] = []
            var previous = points[points.count - 1]
            var previousInside = keepGreater ? previous.longitude >= boundary : previous.longitude <= boundary

            for current in points {
                let currentInside = keepGreater ? current.longitude >= boundary : current.longitude <= boundary
                if currentInside != previousInside {
                    let span = current.longitude - previous.longitude
                    let fraction = abs(span) < 1e-12 ? 0 : (boundary - previous.longitude) / span
                    result.append(MapPoint(
                        longitude: boundary,
                        latitude: previous.latitude + fraction * (current.latitude - previous.latitude)
                    ))
                }
                if currentInside { result.append(current) }
                previous = current
                previousInside = currentInside
            }
            return result
        }

        return clip(clip(polygon, boundary: -180, keepGreater: true), boundary: 180, keepGreater: false)
    }

    private static func polygonArea(_ polygon: [MapPoint]) -> Double {
        guard polygon.count > 2 else { return 0 }
        return abs(polygon.indices.reduce(0.0) { area, index in
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            return area + current.longitude * next.latitude - next.longitude * current.latitude
        }) / 2
    }

    private static func normalizedLongitude(_ longitude: Double) -> Double {
        (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
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
                ProgressView("Loading satellite activity…").tint(SkyPalette.accent)
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
                    LazyVStack(spacing: 5, pinnedViews: [.sectionHeaders]) {
                        Section {
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
                        } header: {
                            tableHeader
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

    private var tableHeader: some View {
        HStack(spacing: 5) {
            Text("SATELLITE")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(SkyPalette.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(store.amsatDays) { day in
                Text(day.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(SkyPalette.accent)
                    .frame(width: 50)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SkyPalette.ink)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SkyPalette.muted.opacity(0.25)).frame(height: 0.5)
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
                                .foregroundStyle(SkyPalette.accent)
                        }
                        Slider(value: $draft.minimumElevation, in: 0...60, step: 1)
                            .tint(SkyPalette.accent)
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
                    .foregroundStyle(SkyPalette.accent)
            }
            Slider(
                value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                in: 0...1_439,
                step: 15
            )
            .tint(SkyPalette.accent)
        }
    }

    private func minuteDegreeSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))°")
                    .monospacedDigit()
                    .foregroundStyle(SkyPalette.accent)
            }
            Slider(value: value, in: 0...90, step: 1).tint(SkyPalette.accent)
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
                        Toggle("", isOn: $entry.isEnabled).labelsHidden().tint(SkyPalette.accent)
                        TextField("Source URL", text: $entry.url)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if let code = statuses[entry.url] {
                        Text(code == -1 ? "Last request failed" : "Last response: HTTP \(code)")
                            .font(.caption2)
                            .foregroundStyle(code == 200 ? SkyPalette.accent : .orange)
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
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SkyPalette.accent)
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
                            Text(message).font(.caption).foregroundStyle(SkyPalette.accent)
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
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(SkyPalette.accent)
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
    let positionColor: Color
    let pointingElevationDegrees: Double
    let showsPointingMarker: Bool
    let showsSweep: Bool

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let radius = diameter * 0.405
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ZStack {
                    if showsSweep {
                        RadarSweepOverlay()
                    }

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

                        for path in visibleTrackPaths(trajectory, center: center, radius: radius) {
                            context.stroke(path, with: .color(SkyPalette.secondary.opacity(0.75)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }

                        if position.elevationDegrees > 0 {
                            let satellitePoint = radarPoint(position, center: center, radius: radius)
                            let dotRadius: CGFloat = 7
                            let dot = Path(ellipseIn: CGRect(
                                x: satellitePoint.x - dotRadius,
                                y: satellitePoint.y - dotRadius,
                                width: dotRadius * 2,
                                height: dotRadius * 2
                            ))
                            context.fill(dot, with: .color(positionColor))
                            context.stroke(dot, with: .color(SkyPalette.primary), lineWidth: 1.5)
                        }
                    }
                    Text("N").position(x: center.x, y: center.y - radius - 13)
                    Text("E").position(x: center.x + radius + 13, y: center.y)
                    Text("S").position(x: center.x, y: center.y + radius + 13)
                    Text("W").position(x: center.x - radius - 13, y: center.y)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(SkyPalette.muted)
                .rotationEffect(.degrees(rotationDegrees))
        .animation(.linear(duration: 1.0 / 120.0), value: rotationDegrees)

                if showsPointingMarker {
                    let magnitude = min(90, abs(pointingElevationDegrees))
                    let distance = radius * CGFloat(1 - magnitude / 90)
                    let verticalDirection: CGFloat = pointingElevationDegrees < 0 ? 1 : -1
                    let aim = CGPoint(x: center.x, y: center.y + verticalDirection * distance)
                    let reticleRadius: CGFloat = 9
                    let reticle = Path(ellipseIn: CGRect(
                        x: aim.x - reticleRadius,
                        y: aim.y - reticleRadius,
                        width: reticleRadius * 2,
                        height: reticleRadius * 2
                    ))
                    Canvas { context, _ in
                        context.stroke(reticle, with: .color(.red), lineWidth: 2)
                        var crosshair = Path()
                        crosshair.move(to: CGPoint(x: aim.x - 14, y: aim.y))
                        crosshair.addLine(to: CGPoint(x: aim.x + 14, y: aim.y))
                        crosshair.move(to: CGPoint(x: aim.x, y: aim.y - 14))
                        crosshair.addLine(to: CGPoint(x: aim.x, y: aim.y + 14))
                        context.stroke(crosshair, with: .color(.red.opacity(0.9)), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(12)
    }

    private func radarPoint(_ point: TrackedPosition, center: CGPoint, radius: CGFloat) -> CGPoint {
        radarPoint(
            azimuth: point.azimuthDegrees,
            elevation: point.elevationDegrees,
            center: center,
            radius: radius
        )
    }

    private func visibleTrackPaths(_ points: [TrackedPosition], center: CGPoint, radius: CGFloat) -> [Path] {
        guard points.count > 1 else { return [] }
        var paths: [Path] = []
        var path = Path()
        var isDrawing = false

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let previousVisible = previous.elevationDegrees > 0
            let currentVisible = current.elevationDegrees > 0

            switch (previousVisible, currentVisible) {
            case (true, true):
                if !isDrawing {
                    path = Path()
                    path.move(to: radarPoint(previous, center: center, radius: radius))
                    isDrawing = true
                }
                path.addLine(to: radarPoint(current, center: center, radius: radius))
            case (false, true):
                path = Path()
                path.move(to: horizonPoint(previous, current, center: center, radius: radius))
                path.addLine(to: radarPoint(current, center: center, radius: radius))
                isDrawing = true
            case (true, false):
                if isDrawing {
                    path.addLine(to: horizonPoint(previous, current, center: center, radius: radius))
                    paths.append(path)
                    path = Path()
                    isDrawing = false
                }
            case (false, false):
                break
            }
        }

        if isDrawing { paths.append(path) }
        return paths
    }

    private func horizonPoint(
        _ first: TrackedPosition,
        _ second: TrackedPosition,
        center: CGPoint,
        radius: CGFloat
    ) -> CGPoint {
        let denominator = first.elevationDegrees - second.elevationDegrees
        let fraction = denominator == 0 ? 0 : first.elevationDegrees / denominator
        var azimuthDelta = (second.azimuthDegrees - first.azimuthDegrees + 540).truncatingRemainder(dividingBy: 360) - 180
        azimuthDelta = min(180, max(-180, azimuthDelta))
        let azimuth = (first.azimuthDegrees + azimuthDelta * fraction + 360)
            .truncatingRemainder(dividingBy: 360)
        return radarPoint(azimuth: azimuth, elevation: 0, center: center, radius: radius)
    }

    private func radarPoint(azimuth: Double, elevation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let elevation = min(90, max(0, elevation))
        let radialDistance = radius * CGFloat(1 - elevation / 90)
        let angle = (azimuth - 90) * .pi / 180
        return CGPoint(
            x: center.x + cos(angle) * radialDistance,
            y: center.y + sin(angle) * radialDistance
        )
    }
}

private struct RadarSweepOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) * 0.405
            TimelineView(.animation(minimumInterval: 1.0 / 120.0)) { timeline in
                let angle = (timeline.date.timeIntervalSinceReferenceDate * 45).truncatingRemainder(dividingBy: 360)
                ZStack {
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.77),
                                    .init(color: SkyPalette.accent.opacity(0.015), location: 0.80),
                                    .init(color: SkyPalette.accent.opacity(0.08), location: 0.91),
                                    .init(color: SkyPalette.accent.opacity(0.28), location: 0.995),
                                    .init(color: .clear, location: 1)
                                ]),
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .rotationEffect(.degrees(angle))

                    Rectangle()
                        .fill(SkyPalette.accent.opacity(0.92))
                        .frame(width: 1.5, height: radius)
                        .offset(y: -radius / 2)
                        .shadow(color: SkyPalette.accent.opacity(0.7), radius: 2)
                        .rotationEffect(.degrees(angle))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private func pageHeading(eyebrow: String, title: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(eyebrow)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.8)
            .foregroundStyle(SkyPalette.accent)
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

private func radarElevationMetric(_ elevation: Double, filters: PassFilterSettings) -> some View {
    let color = SkyPalette.elevationColor(
        elevation,
        low: filters.lowHighlightElevation,
        high: filters.highHighlightElevation
    )
    return VStack(alignment: .leading, spacing: 5) {
        Text("ELEVATION")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1)
            .foregroundStyle(SkyPalette.muted)
        HStack(spacing: 4) {
            ElevationAngleSymbol(color: color)
            Text(String(format: "%+.1f°", elevation))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
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
            .foregroundStyle(SkyPalette.secondary)
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
                    .background(SkyPalette.accent, in: Capsule())
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
                        .foregroundStyle(SkyPalette.accent)
                }
                Button { isShowingEditor = true } label: {
                    Label("Enter location", systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.accent)
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
        .tint(SkyPalette.accent)
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
            Slider(value: $value, in: range, step: 1).tint(SkyPalette.accent)
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
