import CoreLocation
import Combine
import Foundation
import Look4SatShared
import UIKit

private struct PredictionInput: @unchecked Sendable {
    let satellite: SatelliteTarget
}

struct PredictedPass: Sendable {
    let catalogNumber: Int32
    let aosTimeMillis: Int64
    let aosAzimuthDegrees: Double
    let losTimeMillis: Int64
    let losAzimuthDegrees: Double
    let maximumElevationDegrees: Double
    let altitudeKilometers: Double
}

struct TrackedPosition: Sendable {
    let azimuthDegrees: Double
    let elevationDegrees: Double
    let altitudeKilometers: Double
    let distanceKilometers: Double
    let isAboveHorizon: Bool
}

private struct SatelliteSnapshot: Sendable {
    let catalogNumber: Int32
    let position: TrackedPosition
    let pass: PredictedPass?
}

private struct ParsedCatalog: @unchecked Sendable {
    let satellites: [SatelliteTarget]
}

struct PassItem: Identifiable {
    let satellite: SatelliteTarget
    let prediction: PredictedPass

    var id: Int32 { satellite.catalogNumber }
}

@MainActor
final class SatelliteStore: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var satellites: [SatelliteTarget] = []
    @Published private(set) var passes: [PassItem] = []
    @Published private(set) var positions: [Int32: TrackedPosition] = [:]
    @Published private(set) var location: CLLocation?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published var searchText = ""
    @Published var selectedIDs: Set<Int32> = {
        let saved = (UserDefaults.standard.array(forKey: "trackedSatelliteIDs") as? [NSNumber])?.map(\.int32Value)
        return Set(saved ?? [25544, 28654, 33591])
    }() {
        didSet {
            UserDefaults.standard.set(selectedIDs.map { Int($0) }, forKey: "trackedSatelliteIDs")
        }
    }

    private let locationManager = CLLocationManager()
    private var hasStarted = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var filteredSatellites: [SatelliteTarget] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return satellites.filter { selectedIDs.contains($0.catalogNumber) }
                + Array(satellites.filter { !selectedIDs.contains($0.catalogNumber) }.prefix(30))
        }
        return satellites.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || String($0.catalogNumber).contains(query)
        }.prefix(100).map { $0 }
    }

    var locationDescription: String {
        guard let location else { return "Location not set" }
        return String(format: "%.4f°, %.4f°", location.coordinate.latitude, location.coordinate.longitude)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            statusMessage = "Enable location access to calculate passes for your sky."
        } else {
            requestLocation()
        }
        await loadCache()
        if lastUpdated.map({ Date().timeIntervalSince($0) > 7 * 24 * 60 * 60 }) ?? true {
            await refresh()
        }
    }

    func requestLocation() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settings)
            }
        default:
            statusMessage = "Enable location access to calculate passes for your sky."
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=csv")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            request.setValue("Look4Sat iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let csv = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            let parsed = await Self.parseCatalog(csv)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            satellites = parsed
            lastUpdated = Date()
            statusMessage = nil
            try saveCache(csv)
            await recalculatePasses()
        } catch {
            statusMessage = satellites.isEmpty
                ? "Orbital data is unavailable. Connect to the internet and try again."
                : "Using saved orbital data. Refresh when you’re back online."
        }
    }

    func toggle(_ satellite: SatelliteTarget) {
        let id = satellite.catalogNumber
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        Task { await recalculatePasses() }
    }

    func isSelected(_ satellite: SatelliteTarget) -> Bool {
        selectedIDs.contains(satellite.catalogNumber)
    }

    func recalculatePasses() async {
        guard let location, !satellites.isEmpty else {
            passes = []
            return
        }
        let selected = satellites.filter { selectedIDs.contains($0.catalogNumber) }
        let inputs = selected.map(PredictionInput.init)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let altitude = location.altitude
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let snapshots = await Task.detached(priority: .userInitiated) {
            inputs.map { input -> SatelliteSnapshot in
                let position = input.satellite.currentPosition(
                    latitude: lat,
                    longitude: lon,
                    altitudeMeters: altitude,
                    timeMillis: now
                )
                let nextPass = input.satellite.nextPass(
                    latitude: lat,
                    longitude: lon,
                    altitudeMeters: altitude,
                    startTimeMillis: now
                )
                let reading = TrackedPosition(
                    azimuthDegrees: position.azimuthDegrees,
                    elevationDegrees: position.elevationDegrees,
                    altitudeKilometers: position.altitudeKilometers,
                    distanceKilometers: position.distanceKilometers,
                    isAboveHorizon: position.isAboveHorizon
                )
                let prediction = nextPass.map { pass in
                    PredictedPass(
                        catalogNumber: input.satellite.catalogNumber,
                        aosTimeMillis: pass.aosTimeMillis,
                        aosAzimuthDegrees: pass.aosAzimuthDegrees,
                        losTimeMillis: pass.losTimeMillis,
                        losAzimuthDegrees: pass.losAzimuthDegrees,
                        maximumElevationDegrees: pass.maximumElevationDegrees,
                        altitudeKilometers: pass.altitudeKilometers
                    )
                }
                return SatelliteSnapshot(
                    catalogNumber: input.satellite.catalogNumber,
                    position: reading,
                    pass: prediction
                )
            }
        }.value
        positions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.catalogNumber, $0.position) })
        let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.catalogNumber, $0) })
        passes = snapshots.compactMap { snapshot in
            guard let prediction = snapshot.pass,
                  let satellite = byID[snapshot.catalogNumber] else { return nil }
            return PassItem(satellite: satellite, prediction: prediction)
        }.sorted { $0.prediction.aosTimeMillis < $1.prediction.aosTimeMillis }
    }

    func position(for satellite: SatelliteTarget) -> TrackedPosition? {
        positions[satellite.catalogNumber]
    }

    func formattedTime(_ milliseconds: Int64, dateStyle: DateFormatter.Style = .medium) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = dateStyle
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = latest
        Task { await recalculatePasses() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if location == nil { statusMessage = "Waiting for a location fix…" }
    }

    private func loadCache() async {
        guard let url = cacheURL, let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = await Self.parseCatalog(csv)
        satellites = parsed
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date {
            lastUpdated = modified
        }
        await recalculatePasses()
    }

    private func saveCache(_ csv: String) throws {
        guard let url = cacheURL else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("orbital-elements.csv")
    }

    nonisolated private static func parseCatalog(_ csv: String) async -> [SatelliteTarget] {
        let parsed = await Task.detached(priority: .userInitiated) {
            let values = SatelliteCatalogParser().parseCatalog(csv: csv)
            return ParsedCatalog(satellites: values.compactMap { $0 as? SatelliteTarget })
        }.value
        return parsed.satellites
    }
}
