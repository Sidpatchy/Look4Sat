import Foundation
import Look4SatShared
import SwiftUI

private enum SkyPalette {
    static let ink = Color(red: 0.025, green: 0.035, blue: 0.09)
    static let violet = Color(red: 0.50, green: 0.42, blue: 1.0)
    static let cyan = Color(red: 0.32, green: 0.88, blue: 0.95)
    static let muted = Color.white.opacity(0.58)
}

struct ContentView: View {
    @ObservedObject var store: SatelliteStore

    var body: some View {
        ZStack {
            Starfield()
                .ignoresSafeArea()
            TabView {
                NavigationStack { PassesView(store: store) }
                    .tabItem { Label("Passes", systemImage: "sparkles") }
                NavigationStack { SatellitesView(store: store) }
                    .tabItem { Label("Satellites", systemImage: "satellite") }
                NavigationStack { SettingsView(store: store) }
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }
            .tint(SkyPalette.cyan)
        }
    }
}

private struct PassesView: View {
    @ObservedObject var store: SatelliteStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if store.location == nil {
                    locationPrompt
                } else if let next = store.passes.first {
                    featuredPass(next)
                    if store.passes.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("UP NEXT", detail: "Your selected satellites")
                            ForEach(store.passes.dropFirst()) { item in passRow(item) }
                        }
                    }
                } else if store.isLoading {
                    emptyCard("Finding satellites", detail: "Calculating their next passes over your location.", icon: "dot.radiowaves.left.and.right")
                } else {
                    emptyCard("No passes found", detail: "Try selecting more satellites or refreshing orbital data.", icon: "moon.stars")
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
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(SkyPalette.cyan).frame(width: 7, height: 7)
                    Text("LOOK4SAT  /  LIVE SKY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.cyan)
                }
                Text("Passes")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Label(store.locationDescription, systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(SkyPalette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
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
                .foregroundStyle(SkyPalette.cyan)
            Text("Your sky, precisely")
                .font(.title2.bold())
            Text("Look4Sat uses your location to calculate satellite passes overhead. Your coordinates stay on this device.")
                .font(.subheadline)
                .foregroundStyle(SkyPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: store.requestLocation) {
                Label("Use my location", systemImage: "location.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyPalette.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(SkyPalette.cyan, in: Capsule())
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitalGlass()
    }

    private func featuredPass(_ item: PassItem) -> some View {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let isInProgress = item.prediction.aosTimeMillis <= now && item.prediction.losTimeMillis > now
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(isInProgress ? "PASS IN PROGRESS" : "NEXT PASS", systemImage: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(SkyPalette.cyan)
                Spacer()
                Text("NORAD  \(item.satellite.catalogNumber)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.satellite.name)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(isInProgress
                    ? "LOS  \(store.formattedTime(item.prediction.losTimeMillis, dateStyle: .none))"
                    : store.formattedTime(item.prediction.aosTimeMillis))
                    .font(.subheadline)
                    .foregroundStyle(SkyPalette.muted)
            }
            OrbitArt(progress: 0.58)
                .frame(height: 94)
                .accessibilityHidden(true)
            if let position = store.position(for: item.satellite) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(position.isAboveHorizon ? SkyPalette.cyan : SkyPalette.violet)
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
                .foregroundStyle(.white)
            }
            HStack(spacing: 0) {
                metric("MAX ELEVATION", value: String(format: "%.0f°", item.prediction.maximumElevationDegrees))
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
                Circle().fill(SkyPalette.violet.opacity(0.2)).frame(width: 42, height: 42)
                Image(systemName: "satellite")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(SkyPalette.violet)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.satellite.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("MAX  \(String(format: "%.0f°", item.prediction.maximumElevationDegrees))  ·  \(duration(item.prediction.losTimeMillis - item.prediction.aosTimeMillis))")
                    .font(.caption)
                    .foregroundStyle(SkyPalette.muted)
            }
            Spacer()
            Text(time)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(SkyPalette.cyan)
        }
        .padding(15)
        .orbitalGlass(cornerRadius: 20)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(SkyPalette.muted)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.6).foregroundStyle(SkyPalette.cyan)
            Text(detail).font(.caption).foregroundStyle(SkyPalette.muted)
        }
    }

    private func emptyCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(SkyPalette.violet)
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
}

private struct SatellitesView: View {
    @ObservedObject var store: SatelliteStore

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CATALOG")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.cyan)
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
                    .foregroundStyle(.white)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(SkyPalette.muted)
                    }
                }
            }
            .padding(14)
            .orbitalGlass(cornerRadius: 18)

            if store.satellites.isEmpty && store.isLoading {
                Spacer()
                ProgressView("Loading orbital catalog…").tint(SkyPalette.cyan)
                Spacer()
            } else if store.satellites.isEmpty {
                ContentUnavailableView("Catalog unavailable", systemImage: "antenna.radiowaves.left.and.right", description: Text("Pull down to retry when you have a network connection."))
                Spacer()
            } else {
                List {
                    if store.searchText.isEmpty {
                        Section("TRACKING  ·  \(store.selectedIDs.count)") {
                            ForEach(store.filteredSatellites, id: \.catalogNumber) { satellite in satelliteRow(satellite) }
                        }
                    } else {
                        Section("RESULTS") {
                            ForEach(store.filteredSatellites, id: \.catalogNumber) { satellite in satelliteRow(satellite) }
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
    }

    private func satelliteRow(_ satellite: SatelliteTarget) -> some View {
        let selected = store.isSelected(satellite)
        let detail = store.position(for: satellite).map {
            "EL  \(String(format: "%+.0f°", $0.elevationDegrees))  ·  NORAD  \(satellite.catalogNumber)"
        } ?? "NORAD  \(satellite.catalogNumber)  ·  \(satellite.isDeepSpace ? "DEEP SPACE" : "LEO")"
        return Button { store.toggle(satellite) } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(selected ? SkyPalette.cyan.opacity(0.16) : .white.opacity(0.06))
                        .frame(width: 40, height: 40)
                    Image(systemName: "satellite")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? SkyPalette.cyan : SkyPalette.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(satellite.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(SkyPalette.muted)
                }
                Spacer(minLength: 5)
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? SkyPalette.cyan : SkyPalette.muted)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.08))
    }
}

private struct SettingsView: View {
    @ObservedObject var store: SatelliteStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PREFERENCES")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(SkyPalette.cyan)
                    Text("Settings")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                settingsCard(title: "OBSERVING LOCATION", icon: "location.fill") {
                    Text(store.locationDescription)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text("Used only on this device to predict passes.")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                    Button(action: store.requestLocation) {
                        Label("Update location", systemImage: "location")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SkyPalette.cyan)
                    }
                    .padding(.top, 5)
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
                            if store.isLoading { ProgressView().tint(SkyPalette.cyan) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SkyPalette.cyan)
                    }
                    .disabled(store.isLoading)
                    .padding(.top, 5)
                }
                settingsCard(title: "ABOUT LOOK4SAT", icon: "sparkles") {
                    Text("Precise satellite tracking, powered by shared Kotlin orbital math and native SwiftUI.")
                        .font(.subheadline)
                        .foregroundStyle(SkyPalette.muted)
                    Text("Offline after your first orbital data download. No ads. No tracking.")
                        .font(.caption)
                        .foregroundStyle(SkyPalette.muted)
                }
            }
            .padding(20)
        }
        .background(SkyPalette.ink.opacity(0.4))
        .toolbar(.hidden, for: .navigationBar)
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(SkyPalette.cyan)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(19)
        .orbitalGlass(cornerRadius: 24)
    }
}

private struct OrbitArt: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 0.78))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.22),
                        control1: CGPoint(x: width * 0.28, y: -height * 0.15),
                        control2: CGPoint(x: width * 0.69, y: height * 1.2)
                    )
                }
                .stroke(SkyPalette.violet.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 6]))
                Circle()
                    .fill(SkyPalette.cyan)
                    .frame(width: 9, height: 9)
                    .shadow(color: SkyPalette.cyan.opacity(0.8), radius: 9)
                    .position(x: width * progress, y: height * 0.43)
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.white.opacity(0.83))
                    .position(x: width * 0.5, y: height * 0.5)
                Text("AOS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .position(x: 13, y: height * 0.88)
                Text("LOS")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(SkyPalette.muted)
                    .position(x: width - 14, y: height * 0.12)
            }
        }
    }
}

private struct Starfield: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.035, green: 0.05, blue: 0.14), SkyPalette.ink, Color(red: 0.075, green: 0.045, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [SkyPalette.violet.opacity(0.15), .clear], center: .topTrailing, startRadius: 20, endRadius: geometry.size.width * 0.85)
                Canvas { context, size in
                    for index in 0..<110 {
                        let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                        let y = CGFloat((index * 137 + 43) % 991) / 991 * size.height
                        let diameter: CGFloat = index.isMultiple(of: 9) ? 2.1 : 1.2
                        let star = Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter))
                        context.fill(star, with: .color(.white.opacity(index.isMultiple(of: 5) ? 0.62 : 0.26)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private extension View {
    @ViewBuilder
    func orbitalGlass(cornerRadius: CGFloat = 26) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.11), lineWidth: 0.7)
                }
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.11), lineWidth: 0.7)
                }
        }
    }
}
