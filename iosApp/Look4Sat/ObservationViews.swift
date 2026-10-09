import CoreLocation
import Foundation
import Look4SatShared
import MapKit
import SwiftUI

struct RadarView: View {
    @ObservedObject var store: SatelliteStore
    let selectedSatelliteID: Int32
    let onSelectSatellite: (SatelliteTarget) -> Void

    @State private var trajectory: [TrackedPosition] = []

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

                if let satellite, let position {
                    PolarRadarPlot(position: position, trajectory: trajectory)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .orbitalGlass(cornerRadius: 30)

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

                if let location = store.location {
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
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(
                                        satellite.catalogNumber == selectedSatelliteID ? SkyPalette.violet : SkyPalette.ink,
                                        in: Circle()
                                    )
                                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
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
                            .foregroundStyle(.white)
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
                        .foregroundStyle(.white)
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
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.22)), lineWidth: 1)
                    }
                    var axes = Path()
                    axes.move(to: CGPoint(x: center.x - radius, y: center.y))
                    axes.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    axes.move(to: CGPoint(x: center.x, y: center.y - radius))
                    axes.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    context.stroke(axes, with: .color(.white.opacity(0.2)), lineWidth: 1)

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
                    context.stroke(dot, with: .color(.white), lineWidth: 1.5)
                }
                Text("N").position(x: center.x, y: center.y - radius - 13)
                Text("E").position(x: center.x + radius + 13, y: center.y)
                Text("S").position(x: center.x, y: center.y + radius + 13)
                Text("W").position(x: center.x - radius - 13, y: center.y)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(SkyPalette.muted)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(12)
    }

    private func radarPoint(_ point: TrackedPosition, center: CGPoint, radius: CGFloat) -> CGPoint {
        let elevation = min(90, max(0, point.elevationDegrees))
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
            .foregroundStyle(.white)
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
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(13)
    .orbitalGlass(cornerRadius: 18)
}

private func observationEmptyState(store: SatelliteStore) -> some View {
    VStack(spacing: 14) {
        Image(systemName: store.location == nil ? "location.slash" : "dot.scope")
            .font(.system(size: 30))
            .foregroundStyle(SkyPalette.violet)
        Text(store.location == nil ? "Location needed" : "Tracking data unavailable")
            .font(.headline)
            .foregroundStyle(.white)
        Text(store.location == nil
            ? "Allow location access to calculate the sky around you."
            : "Select a satellite from the catalog to begin tracking.")
            .font(.subheadline)
            .foregroundStyle(SkyPalette.muted)
            .multilineTextAlignment(.center)
        if store.location == nil {
            Button(action: store.requestLocation) {
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
