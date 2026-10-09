import Foundation
import Look4SatShared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum SkyPalette {
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
            : UIColor(red: 1, green: 248 / 255, blue: 240 / 255, alpha: 1)
    })
    static let primary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 224 / 255, green: 224 / 255, blue: 224 / 255, alpha: 1)
            : UIColor(red: 30 / 255, green: 27 / 255, blue: 19 / 255, alpha: 1)
    })
    static let secondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 224 / 255, green: 224 / 255, blue: 224 / 255, alpha: 1)
            : UIColor(red: 104 / 255, green: 94 / 255, blue: 64 / 255, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 224 / 255, blue: 130 / 255, alpha: 1)
            : UIColor(red: 113 / 255, green: 92 / 255, blue: 12 / 255, alpha: 1)
    })
    static let muted = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 176 / 255, green: 176 / 255, blue: 176 / 255, alpha: 1)
            : UIColor(red: 76 / 255, green: 70 / 255, blue: 57 / 255, alpha: 1)
    })

    static func elevationColor(_ elevation: Double, low: Double, high: Double) -> Color {
        let lowThreshold = min(low, high)
        let highThreshold = max(low, high)
        if elevation < lowThreshold { return Color(red: 239 / 255, green: 83 / 255, blue: 80 / 255) }
        if elevation < highThreshold { return accent }
        return Color(red: 102 / 255, green: 187 / 255, blue: 106 / 255)
    }
}

struct ElevationAngleSymbol: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let vertex = CGPoint(x: size.width * 0.14, y: size.height * 0.86)
            var angle = Path()
            angle.move(to: vertex)
            angle.addLine(to: CGPoint(x: size.width * 0.91, y: vertex.y))
            angle.move(to: vertex)
            angle.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.12))
            context.stroke(angle, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            let point = Path(ellipseIn: CGRect(x: vertex.x - 1.5, y: vertex.y - 1.5, width: 3, height: 3))
            context.fill(point, with: .color(color))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

struct ContentView: View {
    @ObservedObject var store: SatelliteStore
    @State private var selectedTab: Look4SatTab = .passes
    @State private var selectedSatelliteID: Int32 = 25544

    var body: some View {
        ZStack {
            Starfield()
                .ignoresSafeArea()
            TabView(selection: $selectedTab) {
                NavigationStack { PassesView(store: store, onSelectSatellite: openRadar) }
                    .tabItem { Label("Passes", systemImage: "sparkles") }
                    .tag(Look4SatTab.passes)
                NavigationStack { SatelliteAreaView(store: store, onSelectSatellite: openRadar) }
                    .tabItem { Label("Satellites", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(Look4SatTab.satellites)
                NavigationStack {
                    RadarView(
                        store: store,
                        selectedSatelliteID: selectedSatelliteID,
                        onSelectSatellite: selectSatellite
                    )
                }
                .tabItem { Label("Radar", systemImage: "dot.scope") }
                .tag(Look4SatTab.radar)
                NavigationStack {
                    OrbitMapView(
                        store: store,
                        livePosition: store.livePosition,
                        selectedSatelliteID: selectedSatelliteID,
                        onSelectSatellite: openRadar
                    )
                }
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Look4SatTab.map)
                NavigationStack { SettingsView(store: store) }
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                    .tag(Look4SatTab.settings)
            }
            .tint(SkyPalette.accent)
        }
    }

    private func selectSatellite(_ satellite: SatelliteTarget) {
        if !store.isSelected(satellite) { store.toggle(satellite) }
        store.focusSatellite(satellite.catalogNumber)
        selectedSatelliteID = satellite.catalogNumber
    }

    private func openRadar(_ satellite: SatelliteTarget) {
        selectSatellite(satellite)
        selectedTab = .radar
    }
}

private enum Look4SatTab: Hashable {
    case passes
    case satellites
    case radar
    case map
    case settings
}

private enum SatelliteSection: Hashable {
    case catalog
    case amsat
}

private struct SatelliteAreaView: View {
    @ObservedObject var store: SatelliteStore
    let onSelectSatellite: (SatelliteTarget) -> Void
    @State private var selectedSection: SatelliteSection = .catalog

    var body: some View {
        VStack(spacing: 8) {
            Picker("Satellite section", selection: $selectedSection) {
                Label("Satellites", systemImage: "antenna.radiowaves.left.and.right")
                    .tag(SatelliteSection.catalog)
                Label("AMSAT", systemImage: "chart.bar.xaxis")
                    .tag(SatelliteSection.amsat)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.top, 8)

            Group {
                switch selectedSection {
                case .catalog:
                    SatellitesView(store: store, onSelectSatellite: onSelectSatellite)
                case .amsat:
                    AmsatStatusView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct PassesView: View {
    @ObservedObject var store: SatelliteStore
    let onSelectSatellite: (SatelliteTarget) -> Void
    @State private var isShowingFilters = false
    @State private var isShowingModes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                passSearchAndFilters
                if store.observerLocation == nil {
                    locationPrompt
                } else {
                    if let next = store.visibleScheduledPasses.first {
                        Button { onSelectSatellite(next.satellite) } label: { featuredPass(next) }
                            .buttonStyle(.plain)
                    }
                    if !store.visibleDeepSpaceObjects.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle(
                                "DEEP SPACE OBJECTS",
                                detail: "Orbital period ≥225 min · \(store.visibleDeepSpaceObjects.count) entries"
                            )
                            ForEach(store.visibleDeepSpaceObjects) { item in
                                Button { onSelectSatellite(item.satellite) } label: { deepSpaceRow(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    if !store.remainingPassGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(store.remainingPassGroups) { group in
                                sectionTitle(group.dateLabel, detail: "\(group.items.count) upcoming passes")
                                    .padding(.top, 8)
                                ForEach(group.items) { item in
                                    Button { onSelectSatellite(item.satellite) } label: { passRow(item) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if store.visibleScheduledPasses.isEmpty && store.visibleDeepSpaceObjects.isEmpty {
                        if store.isLoading {
                            emptyCard("Finding satellites", detail: "Calculating their next passes over your location.", icon: "dot.radiowaves.left.and.right")
                        } else if !store.passSearchText.isEmpty {
                            emptyCard("No matching passes", detail: "Try another satellite name or NORAD catalog number.", icon: "magnifyingglass")
                        } else {
                            emptyCard("No passes found", detail: store.satellites.isEmpty
                                ? "Download orbital data to start tracking satellites."
                                : "Try adjusting filters or tracking more satellites.", icon: "moon.stars")
                        }
                    }
                }
                if let message = store.statusMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(SkyPalette.muted)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await store.refresh() }
        .sheet(isPresented: $isShowingFilters) {
            PassFilterSheet(filters: store.passFilters) { filters in
                store.passFilters = filters
                Task { await store.recalculatePasses() }
            }
        }
        .sheet(isPresented: $isShowingModes) {
            SatelliteModesSheet(
                modes: store.availableSatelliteModes,
                selection: store.selectedSatelliteModes,
                title: "Pass modes"
            ) { store.setSelectedSatelliteModes($0) }
        }
    }

    private var passSearchAndFilters: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(SkyPalette.muted)
                TextField("Search passes", text: $store.passSearchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(SkyPalette.primary)
            }
            .padding(13)
            .orbitalGlass(cornerRadius: 18)
            Button { isShowingModes = true } label: {
                Image(systemName: "waveform.path")
                    .foregroundStyle(store.selectedSatelliteModes.isEmpty ? SkyPalette.primary : SkyPalette.accent)
                    .frame(width: 46, height: 46)
                    .orbitalGlass(cornerRadius: 18)
            }
            .accessibilityLabel("Filter by satellite modes")
            Button { isShowingFilters = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(SkyPalette.primary)
                    .frame(width: 46, height: 46)
                    .orbitalGlass(cornerRadius: 18)
            }
            .accessibilityLabel("Pass filters")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(SkyPalette.accent).frame(width: 7, height: 7)
                    Text("LOOK4SAT  /  LIVE SKY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.accent)
                }
                Text("Passes")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyPalette.primary)
                Label(store.locationDescription, systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SkyPalette.primary)
                    .frame(width: 46, height: 46)
                    .orbitalGlass(cornerRadius: 23)
            }
            .disabled(store.isLoading)
            .accessibilityLabel("Refresh orbital data")
        }
    }

    private var locationPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(SkyPalette.accent)
            Text("Your sky, precisely")
                .font(.title2.bold())
            Text("Look4Sat uses your location to calculate satellite passes overhead. Your coordinates stay on this device.")
                .font(.subheadline)
                .foregroundStyle(SkyPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: store.useDeviceLocation) {
                Label("Use my location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyPalette.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(SkyPalette.accent, in: Capsule())
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitalGlass()
    }

    private func featuredPass(_ item: PassItem) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let isInProgress = item.prediction.aosTimeMillis <= now && item.prediction.losTimeMillis > now
        let passDuration = max(1, item.prediction.losTimeMillis - item.prediction.aosTimeMillis)
        let passProgress = isInProgress
            ? Double(now - item.prediction.aosTimeMillis) / Double(passDuration)
            : 0
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(isInProgress ? "PASS IN PROGRESS" : "NEXT PASS", systemImage: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(SkyPalette.accent)
                Spacer()
                Text("NORAD  \(item.satellite.catalogNumber)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.satellite.name)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyPalette.primary)
                    .lineLimit(2)
                Text("AOS  \(store.formattedTime(item.prediction.aosTimeMillis, dateStyle: .none))   ·   LOS  \(store.formattedTime(item.prediction.losTimeMillis, dateStyle: .none))")
                    .font(.subheadline)
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            PassProfile(
                maximumElevation: item.prediction.maximumElevationDegrees,
                progress: min(1, max(0, passProgress)),
                color: elevationColor(item.prediction.maximumElevationDegrees)
            )
            if let position = store.position(for: item.satellite) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(position.isAboveHorizon ? SkyPalette.accent : SkyPalette.secondary)
                        .frame(width: 6, height: 6)
                    Text(position.isAboveHorizon ? "ABOVE HORIZON" : "BELOW HORIZON")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(SkyPalette.muted)
                    Spacer()
                    Text("AZ  \(String(format: "%.0f°", position.azimuthDegrees))")
                    Text("EL  \(String(format: "%+.0f°", position.elevationDegrees))")
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SkyPalette.primary)
            }
            HStack(spacing: 0) {
                metric(
                    "MAX ELEVATION",
                    value: String(format: "%.0f°", item.prediction.maximumElevationDegrees),
                    color: elevationColor(item.prediction.maximumElevationDegrees)
                )
                Spacer(minLength: 8)
                metric("DURATION", value: duration(item.prediction.losTimeMillis - item.prediction.aosTimeMillis))
                Spacer(minLength: 8)
                metric("ALTITUDE", value: String(format: "%.0f km", item.prediction.altitudeKilometers))
            }
        }
        .padding(21)
        .orbitalGlass(cornerRadius: 30)
    }

    private func passRow(_ item: PassItem) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let time = item.prediction.aosTimeMillis <= now
            ? "NOW"
            : store.formattedTime(item.prediction.aosTimeMillis, dateStyle: .none)
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(SkyPalette.secondary.opacity(0.2)).frame(width: 42, height: 42)
                 Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SkyPalette.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.satellite.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyPalette.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ElevationAngleSymbol(color: elevationColor(item.prediction.maximumElevationDegrees))
                Text("MAX  \(String(format: "%.0f°", item.prediction.maximumElevationDegrees))  ·  \(duration(item.prediction.losTimeMillis - item.prediction.aosTimeMillis))")
                    .font(.caption)
                    .foregroundStyle(elevationColor(item.prediction.maximumElevationDegrees))
                Text("AOS \(store.formattedTime(item.prediction.aosTimeMillis, dateStyle: .none))  ·  LOS \(store.formattedTime(item.prediction.losTimeMillis, dateStyle: .none))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(1)
                }
            }
            Spacer()
            Text(time)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(SkyPalette.accent)
        }
        .padding(15)
        .orbitalGlass(cornerRadius: 20)
    }

    private func deepSpaceRow(_ item: PassItem) -> some View {
        let position = store.position(for: item.satellite)
        let azimuth = position?.azimuthDegrees ?? item.prediction.aosAzimuthDegrees
        let elevation = position?.elevationDegrees ?? item.prediction.maximumElevationDegrees
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(SkyPalette.accent.opacity(0.16)).frame(width: 42, height: 42)
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SkyPalette.accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.satellite.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyPalette.primary)
                    .lineLimit(1)
                Text("NORAD \(item.satellite.catalogNumber) · \(Int(item.satellite.orbitalPeriodMinutes.rounded())) min orbit")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(1)
                Text("AZ \(String(format: "%.0f°", azimuth)) · EL \(String(format: "%+.0f°", elevation))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(elevationColor(elevation))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .orbitalGlass(cornerRadius: 20)
    }

    private func metric(_ title: String, value: String, color: Color = SkyPalette.primary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(SkyPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.6).foregroundStyle(SkyPalette.accent)
            Text(detail).font(.caption).foregroundStyle(SkyPalette.muted)
        }
    }

    private func emptyCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(SkyPalette.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(SkyPalette.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(25)
        .orbitalGlass()
    }

    private func duration(_ milliseconds: Int64) -> String {
        let minutes = max(1, Int(milliseconds / 60_000))
        return "\(minutes) min"
    }

    private func elevationColor(_ elevation: Double) -> Color {
        SkyPalette.elevationColor(
            elevation,
            low: store.passFilters.lowHighlightElevation,
            high: store.passFilters.highHighlightElevation
        )
    }
}

private struct SatellitesView: View {
    @ObservedObject var store: SatelliteStore
    let onSelectSatellite: (SatelliteTarget) -> Void
    @State private var isShowingModes = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CATALOG")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.accent)
                    Text("Satellites")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                Spacer()
                Text("\(store.satellites.count.formatted())")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(SkyPalette.muted)
            }
            .padding(.top, 16)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(SkyPalette.muted)
                TextField("Name or NORAD ID", text: $store.searchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(SkyPalette.primary)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(SkyPalette.muted)
                    }
                }
            }
            .padding(14)
            .orbitalGlass(cornerRadius: 18)
            HStack(spacing: 8) {
                Button { isShowingModes = true } label: {
                    Label(
                        store.selectedSatelliteModes.isEmpty ? "Modes: all" : "Modes: \(store.selectedSatelliteModes.count)",
                        systemImage: "waveform.path"
                    )
                }
                Spacer(minLength: 0)
                Button("Select all") { store.selectAllSatellitesInFilter() }
                Button("Clear") { store.clearAllSatellitesInFilter() }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(SkyPalette.accent)
            .padding(.horizontal, 2)

            if store.satellites.isEmpty && store.isLoading {
                Spacer()
                ProgressView("Loading orbital catalog…").tint(SkyPalette.accent)
                Spacer()
            } else if store.satellites.isEmpty {
                ContentUnavailableView("Catalog unavailable", systemImage: "antenna.radiowaves.left.and.right", description: Text("Pull down to retry when you have a network connection."))
                Spacer()
            } else if store.filteredSatellites.isEmpty {
                ContentUnavailableView("No matching satellites", systemImage: "magnifyingglass", description: Text("Try a different name, NORAD number, or radio-mode filter."))
                Spacer()
            } else {
                List {
                    if store.searchText.isEmpty {
                        Section("TRACKING  ·  \(store.trackedSatellites.count)") {
                            ForEach(store.filteredSatellites, id: \.catalogNumber) { satellite in
                                satelliteRow(satellite, onSelectSatellite: onSelectSatellite)
                            }
                        }
                    } else {
                        Section("RESULTS") {
                            ForEach(store.filteredSatellites, id: \.catalogNumber) { satellite in
                                satelliteRow(satellite, onSelectSatellite: onSelectSatellite)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .refreshable { await store.refresh() }
            }
        }
        .padding(.horizontal, 18)
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingModes) {
            SatelliteModesSheet(
                modes: store.availableSatelliteModes,
                selection: store.selectedSatelliteModes,
                title: "Satellite modes",
                onApply: store.setSelectedSatelliteModes
            )
        }
    }

    private func satelliteRow(
        _ satellite: SatelliteTarget,
        onSelectSatellite: @escaping (SatelliteTarget) -> Void
    ) -> some View {
        let selected = store.isSelected(satellite)
        let detail = store.position(for: satellite).map {
            "EL  \(String(format: "%+.0f°", $0.elevationDegrees))  ·  NORAD  \(satellite.catalogNumber)"
        } ?? "NORAD  \(satellite.catalogNumber)  ·  \(satellite.isDeepSpace ? "DEEP SPACE" : "LEO")"
        let pass = store.relevantPass(for: satellite.catalogNumber)
        return HStack(spacing: 12) {
            Button { onSelectSatellite(satellite) } label: {
                HStack(spacing: 13) {
                    ZStack {
                        Circle().fill(selected ? SkyPalette.accent.opacity(0.16) : SkyPalette.primary.opacity(0.06))
                            .frame(width: 40, height: 40)
                         Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16))
                            .foregroundStyle(selected ? SkyPalette.accent : SkyPalette.muted)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(satellite.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(SkyPalette.primary)
                            .lineLimit(1)
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(SkyPalette.muted)
                        if let pass {
                            Text("AOS \(store.formattedTime(pass.prediction.aosTimeMillis, dateStyle: .none)) · LOS \(store.formattedTime(pass.prediction.losTimeMillis, dateStyle: .none))")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(SkyPalette.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    Spacer(minLength: 5)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SkyPalette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { store.toggle(satellite) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? SkyPalette.accent : SkyPalette.muted)
                    .frame(width: 34, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "Stop tracking \(satellite.name)" : "Track \(satellite.name)")
        }
        .padding(.vertical, 5)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(SkyPalette.primary.opacity(0.08))
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SatelliteStore
    @State private var isShowingSources = false
    @State private var isImportingElements = false
    @State private var importMessage: String?
    @State private var radioSettingsPage: RadioSettingsPage?
    @State private var isShowingWhatsNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PREFERENCES")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.accent)
                    Text("Settings")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                settingsCard(title: "OBSERVING LOCATION", icon: "location.fill") {
                    LocationSettings(store: store)
                }
                settingsCard(title: "ORBITAL DATA", icon: "arrow.triangle.2.circlepath") {
                    HStack {
                        Text("Active satellites")
                        Spacer()
                        Text(store.satellites.isEmpty ? "Not loaded" : store.satellites.count.formatted())
                            .foregroundStyle(SkyPalette.muted)
                    }
                    HStack {
                        Text("Last updated")
                        Spacer()
                        Text(store.lastUpdated.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .foregroundStyle(SkyPalette.muted)
                    }
                    Button { Task { await store.refresh() } } label: {
                        HStack {
                            Label("Download latest elements", systemImage: "arrow.down.circle")
                            Spacer()
                            if store.isLoading { ProgressView().tint(SkyPalette.accent) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.accent)
                    }
                    .disabled(store.isLoading)
                    .padding(.top, 5)
                    Button { isShowingSources = true } label: {
                        Label("Manage data sources", systemImage: "list.bullet.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SkyPalette.accent)
                    }
                    Button { isImportingElements = true } label: {
                        Label("Import TLE / OMM file", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SkyPalette.accent)
                    }
                    Button(role: .destructive) { store.clearOrbitalData() } label: {
                        Label("Clear saved orbital data", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(store.satellites.isEmpty || store.isLoading)
                }
                settingsCard(title: "APP BEHAVIOR", icon: "slider.horizontal.3") {
                    PreferenceToggle(title: "Automatic orbital updates", detail: "Refresh stale data when the app opens.", isOn: $store.preferences.autoUpdate)
                    PreferenceToggle(title: "UTC pass times", detail: "Show pass times in UTC instead of local time.", isOn: $store.preferences.isUTC)
                    PreferenceToggle(title: "Light appearance", detail: "Use a light interface instead of dark space colors.", isOn: $store.preferences.lightTheme)
                    PreferenceToggle(title: "Red night filter", detail: "Keep the night vision option available in the radar.", isOn: $store.preferences.nightMode, isDisabled: store.preferences.lightTheme)
                }
                settingsCard(title: "RADAR & COMPASS", icon: "dot.scope") {
                    PreferenceToggle(title: "Radar sweep", detail: "Animate the radar sweep line.", isOn: $store.preferences.showSweep)
                    PreferenceToggle(title: "Show phone pointing direction", detail: "Use device motion to align the radar and show its aim reticle.", isOn: $store.preferences.useCompass)
                    PreferenceToggle(title: "Use phone back as aim direction", detail: "Off: use the phone’s top edge. On: use the screen’s outward-facing direction.", isOn: $store.preferences.useBackSideAsAim, isDisabled: !store.preferences.useCompass)
                    OffsetSlider(title: "Azimuth offset", value: $store.preferences.compassAzimuthOffset, range: -180...180)
                    OffsetSlider(title: "Elevation offset", value: $store.preferences.compassElevationOffset, range: -90...90)
                }
                settingsCard(title: "SATELLITE FILTERS", icon: "waveform.path") {
                    Text(store.selectedSatelliteModes.isEmpty
                        ? "All radio modes are included in the satellite catalog."
                        : "\(store.selectedSatelliteModes.count) radio modes selected for the satellite catalog.")
                        .font(.subheadline)
                        .foregroundStyle(SkyPalette.muted)
                    SatelliteModesSheetButton(store: store)
                }
                settingsCard(title: "RADIO OUTPUT & CAT", icon: "antenna.radiowaves.left.and.right") {
                    Button { radioSettingsPage = .network } label: {
                        Label("Network rotator and frequency output", systemImage: "network")
                            .foregroundStyle(SkyPalette.accent)
                    }
                    Button { radioSettingsPage = .bluetooth } label: {
                        Label("Bluetooth output", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(SkyPalette.accent)
                    }
                    Button { radioSettingsPage = .cat } label: {
                        Label("CAT radio control", systemImage: "radio")
                            .foregroundStyle(SkyPalette.accent)
                    }
                }
                settingsCard(title: "ABOUT LOOK4SAT", icon: "sparkles") {
                    Text("Precise satellite tracking, powered by shared Kotlin orbital math and native SwiftUI.")
                        .font(.subheadline)
                        .foregroundStyle(SkyPalette.muted)
                    Text("Offline after your first orbital data download. No ads. No tracking.")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") · Powered by Look4Sat KMP")
                        .font(.caption2)
                        .foregroundStyle(SkyPalette.muted)
                    HStack(spacing: 16) {
                        Link("F-Droid", destination: URL(string: "https://f-droid.org/en/packages/com.rtbishop.look4sat/")!)
                        Link("GitHub", destination: URL(string: "https://github.com/rt-bishop/Look4Sat/")!)
                        Link("Donate", destination: URL(string: "https://ko-fi.com/rt_bishop")!)
                    }
                    HStack(spacing: 16) {
                        Link("License", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                        Link("Privacy", destination: URL(string: "https://sites.google.com/view/look4sat-privacy-policy/home")!)
                        Button("What’s new") { isShowingWhatsNew = true }
                    }
                    .font(.caption.weight(.semibold))
                    .tint(SkyPalette.accent)
                }
            }
            .padding(20)
        }
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingSources) {
            DataSourcesSheet(settings: store.dataSourceSettings, statuses: store.dataSourceStatuses) { settings in
                store.dataSourceSettings = settings
                Task { await store.refresh() }
            }
        }
        .sheet(item: $radioSettingsPage) { page in
            RadioSettingsSheet(settings: store.radioSettings, page: page) { store.radioSettings = $0 }
        }
        .sheet(isPresented: $isShowingWhatsNew) {
            NavigationStack {
                ScrollView {
                    Text("• Fixed the acquisition-of-signal time filter to follow the UTC setting.\n\n• Applied elevation color thresholds to radar and passes.\n\n• Improved fuzzy satellite search.\n\n• Added light appearance support.\n\n• Fixed dual-radio frequency handling.\n\n• Improved day/night map display.")
                        .font(.body)
                        .foregroundStyle(SkyPalette.primary)
                        .padding(22)
                }
                .background(SkyPalette.ink)
                .navigationTitle("What’s new in Look4Sat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isShowingWhatsNew = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .fileImporter(
            isPresented: $isImportingElements,
            allowedContentTypes: [.plainText, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let file = try result.get().first else { return }
                let didAccess = file.startAccessingSecurityScopedResource()
                defer { if didAccess { file.stopAccessingSecurityScopedResource() } }
                let contents = try String(contentsOf: file, encoding: .utf8)
                Task {
                    let imported = await store.importOrbitalElements(contents)
                    importMessage = imported ? nil : "The selected file does not contain readable TLE or OMM elements."
                }
            } catch {
                importMessage = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(SkyPalette.accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .orbitalGlass(cornerRadius: 24)
    }
}

private struct SatelliteModesSheetButton: View {
    @ObservedObject var store: SatelliteStore
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label("Choose radio modes", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SkyPalette.accent)
        }
        .sheet(isPresented: $isPresented) {
            SatelliteModesSheet(
                modes: store.availableSatelliteModes,
                selection: store.selectedSatelliteModes,
                title: "Satellite modes",
                onApply: store.setSelectedSatelliteModes
            )
        }
    }
}

private struct PassProfile: View {
    let maximumElevation: Double
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let horizonY = height * 0.76
            let normalizedElevation = CGFloat(min(90, max(0, maximumElevation)) / 90)
            let peakHeight = height * (0.12 + 0.5 * normalizedElevation)
            let peakY = horizonY - peakHeight
            let profileProgress = CGFloat(progress)
            let x = width * profileProgress
            let oneMinusProgress = 1 - profileProgress
            let y = oneMinusProgress * oneMinusProgress * oneMinusProgress * horizonY
                + 3 * oneMinusProgress * oneMinusProgress * profileProgress * peakY
                + 3 * oneMinusProgress * profileProgress * profileProgress * peakY
                + profileProgress * profileProgress * profileProgress * horizonY

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: horizonY))
                    path.addLine(to: CGPoint(x: width, y: horizonY))
                }
                .stroke(SkyPalette.muted.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                Path { path in
                    path.move(to: CGPoint(x: 0, y: horizonY))
                    path.addCurve(
                        to: CGPoint(x: width, y: horizonY),
                        control1: CGPoint(x: width * 0.28, y: peakY),
                        control2: CGPoint(x: width * 0.72, y: peakY)
                    )
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.65), radius: 5)
                    .position(x: x, y: y)

                Text("PASS ELEVATION · NOT TO SCALE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(SkyPalette.muted)
                    .position(x: width * 0.5, y: 7)
                Text("MAX \(Int(maximumElevation.rounded()))°")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .position(x: width * 0.5, y: max(20, peakY - 9))
                Text("AOS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .position(x: 13, y: height - 5)
                Text("LOS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .position(x: width - 14, y: height - 5)
            }
        }
        .frame(height: 94)
        .accessibilityLabel("Pass elevation profile, maximum elevation \(Int(maximumElevation)) degrees")
    }
}

private struct Starfield: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SkyPalette.ink
                if colorScheme == .dark {
                    RadialGradient(
                        colors: [SkyPalette.accent.opacity(0.035), .clear],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: geometry.size.width * 0.85
                    )
                    Canvas { context, size in
                        for index in 0..<36 {
                            let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                            let y = CGFloat((index * 137 + 43) % 991) / 991 * size.height
                            let diameter: CGFloat = 1
                            let star = Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter))
                            context.fill(star, with: .color(SkyPalette.primary.opacity(0.08)))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func orbitalGlass(cornerRadius: CGFloat = 26) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(SkyPalette.primary.opacity(0.11), lineWidth: 0.7)
                }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(SkyPalette.primary.opacity(0.11), lineWidth: 0.7)
                }
        }
    }
}
