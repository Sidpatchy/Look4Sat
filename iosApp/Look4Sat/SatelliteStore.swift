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
    let timeMillis: Int64
    let azimuthDegrees: Double
    let elevationDegrees: Double
    let latitudeDegrees: Double
    let longitudeDegrees: Double
    let altitudeKilometers: Double
    let distanceKilometers: Double
    let distanceRateKilometersPerSecond: Double
    let isAboveHorizon: Bool
}

struct IOSTransponder: Identifiable, Sendable {
    let uuid: String
    let info: String
    let isAlive: Bool
    let downlinkLow: Int64?
    let downlinkHigh: Int64?
    let downlinkMode: String?
    let uplinkLow: Int64?
    let uplinkHigh: Int64?
    let uplinkMode: String?
    let isInverted: Bool
    let catalogNumber: Int32?

    var id: String { uuid }
    var isLinear: Bool {
        guard let uplinkLow, let uplinkHigh, let downlinkLow, let downlinkHigh else { return false }
        return uplinkLow != uplinkHigh && downlinkLow != downlinkHigh
    }
    var title: String {
        "\(isInverted ? "INV: " : "")\(info) (\(downlinkMode ?? "--")/\(uplinkMode ?? "--"))"
    }
}

private struct SatelliteSnapshot: Sendable {
    let catalogNumber: Int32
    let position: TrackedPosition
    let passes: [PredictedPass]
}

private struct ParsedCatalog: @unchecked Sendable {
    let satellites: [SatelliteTarget]
}

struct PassItem: Identifiable {
    let satellite: SatelliteTarget
    let prediction: PredictedPass

    var id: String { "\(satellite.catalogNumber):\(prediction.aosTimeMillis)" }
}

struct PassGroup: Identifiable {
    let dateLabel: String
    let items: [PassItem]
    var id: String { dateLabel }
}

struct AmsatReport: Identifiable, Sendable {
    let id: String
    let satelliteName: String
    let status: String
    let callsign: String
    let gridSquare: String
    let dateUtc: String
    let timeUtc: String
    let reportedAtMillis: Int64
}

struct AmsatStatusCell: Sendable {
    let status: String?
    let count: Int
    let reports: [AmsatReport]
}

struct AmsatStatusDay: Identifiable, Sendable {
    let label: String
    let startOfDayMillis: Int64
    var id: Int64 { startOfDayMillis }
}

struct AmsatStatusRow: Identifiable, Sendable {
    let name: String
    let cells: [AmsatStatusCell]
    var id: String { name }
}

private struct AmsatSubmissionError: Error {
    let message: String
}

struct Look4SatPreferences: Sendable, Equatable {
    var autoUpdate = true
    var isUTC = false
    var showSweep = true
    var useCompass = true
    var lightTheme = false
    var nightMode = false
    var compassAzimuthOffset = 0.0
    var compassElevationOffset = 0.0

    static func load() -> Look4SatPreferences {
        let defaults = UserDefaults.standard
        return Look4SatPreferences(
            autoUpdate: defaults.object(forKey: "autoUpdate") as? Bool ?? true,
            isUTC: defaults.bool(forKey: "useUTC"),
            showSweep: defaults.object(forKey: "showSweep") as? Bool ?? true,
            useCompass: defaults.object(forKey: "useCompass") as? Bool ?? true,
            lightTheme: defaults.bool(forKey: "lightTheme"),
            nightMode: defaults.bool(forKey: "nightMode"),
            compassAzimuthOffset: defaults.double(forKey: "compassAzimuthOffset"),
            compassElevationOffset: defaults.double(forKey: "compassElevationOffset")
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(autoUpdate, forKey: "autoUpdate")
        defaults.set(isUTC, forKey: "useUTC")
        defaults.set(showSweep, forKey: "showSweep")
        defaults.set(useCompass, forKey: "useCompass")
        defaults.set(lightTheme, forKey: "lightTheme")
        defaults.set(nightMode, forKey: "nightMode")
        defaults.set(compassAzimuthOffset, forKey: "compassAzimuthOffset")
        defaults.set(compassElevationOffset, forKey: "compassElevationOffset")
    }
}

struct PassFilterSettings: Sendable, Equatable {
    var hoursAhead = 24
    var minimumElevation = 16.0
    var lowHighlightElevation = 16.0
    var highHighlightElevation = 65.0
    var aosStartMinute = 0
    var aosEndMinute = 1_439
    var invertAosTimeWindow = false
    var showDeepSpace = true

    static let hourChoices = [1, 2, 4, 8, 12, 24, 48, 72, 96, 120, 144, 168, 192, 216, 240]

    static func load() -> PassFilterSettings {
        let defaults = UserDefaults.standard
        return PassFilterSettings(
            hoursAhead: defaults.object(forKey: "passHoursAhead") as? Int ?? 24,
            minimumElevation: defaults.object(forKey: "passMinimumElevation") as? Double ?? 16,
            lowHighlightElevation: defaults.object(forKey: "lowHighlightElevation") as? Double ?? 16,
            highHighlightElevation: defaults.object(forKey: "highHighlightElevation") as? Double ?? 65,
            aosStartMinute: defaults.object(forKey: "aosStartMinute") as? Int ?? 0,
            aosEndMinute: defaults.object(forKey: "aosEndMinute") as? Int ?? 1_439,
            invertAosTimeWindow: defaults.bool(forKey: "invertAosTimeWindow"),
            showDeepSpace: defaults.object(forKey: "showDeepSpace") as? Bool ?? true
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(hoursAhead, forKey: "passHoursAhead")
        defaults.set(minimumElevation, forKey: "passMinimumElevation")
        defaults.set(lowHighlightElevation, forKey: "lowHighlightElevation")
        defaults.set(highHighlightElevation, forKey: "highHighlightElevation")
        defaults.set(aosStartMinute, forKey: "aosStartMinute")
        defaults.set(aosEndMinute, forKey: "aosEndMinute")
        defaults.set(invertAosTimeWindow, forKey: "invertAosTimeWindow")
        defaults.set(showDeepSpace, forKey: "showDeepSpace")
    }
}

struct IOSDataSource: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String
    var isEnabled: Bool

    init(id: UUID = UUID(), url: String, isEnabled: Bool = true) {
        self.id = id
        self.url = url
        self.isEnabled = isEnabled
    }
}

struct IOSDataSourceSettings: Codable, Equatable {
    var satellites: [IOSDataSource]
    var transceivers: [IOSDataSource]

    static let defaults = IOSDataSourceSettings(
        satellites: [
            IOSDataSource(url: "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=csv"),
            IOSDataSource(url: "https://db.satnogs.org/api/tle/?format=3le")
        ],
        transceivers: [
            IOSDataSource(url: "https://db.satnogs.org/api/transmitters/?format=json&status=active")
        ]
    )

    static func load() -> IOSDataSourceSettings {
        guard let data = UserDefaults.standard.data(forKey: "iosDataSources"),
              let decoded = try? JSONDecoder().decode(IOSDataSourceSettings.self, from: data) else { return defaults }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "iosDataSources")
    }
}

struct IOSRadioSettings: Codable, Equatable {
    var networkRotatorEnabled = false
    var networkRotatorAddress = "127.0.0.1"
    var networkRotatorPort = "4533"
    var networkRotatorFormat = "P $AZ $EL"
    var networkFrequencyEnabled = false
    var networkFrequencyAddress = "127.0.0.1"
    var networkFrequencyPort = "4532"
    var networkFrequencyFormat = "F $FREQ"
    var networkFrequencyOffsetHz = 0
    var bluetoothRotatorEnabled = false
    var bluetoothRotatorName = "Default"
    var bluetoothRotatorAddress = ""
    var bluetoothRotatorFormat = "P $AZ $EL"
    var bluetoothFrequencyEnabled = false
    var bluetoothFrequencyName = "Default"
    var bluetoothFrequencyAddress = ""
    var bluetoothFrequencyFormat = "F $FREQ"
    var catEnabled = false
    var radioModel = "Yaesu FT-817/818"
    var txRadioName = "TX Radio"
    var txRadioAddress = ""
    var rxRadioName = "RX Radio"
    var rxRadioAddress = ""
    var baudRate = 4_800
    var splitMode = false

    static func load() -> IOSRadioSettings {
        guard let data = UserDefaults.standard.data(forKey: "iosRadioSettings"),
              let decoded = try? JSONDecoder().decode(IOSRadioSettings.self, from: data) else { return IOSRadioSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "iosRadioSettings")
    }
}

@MainActor
final class SatelliteStore: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var satellites: [SatelliteTarget] = []
    @Published private(set) var passes: [PassItem] = []
    @Published private(set) var positions: [Int32: TrackedPosition] = [:]
    @Published private(set) var transceivers: [IOSTransponder] = []
    @Published var selectedTransponderUUID: String? = UserDefaults.standard.string(forKey: "selectedTransponderUUID") {
        didSet { UserDefaults.standard.set(selectedTransponderUUID, forKey: "selectedTransponderUUID") }
    }
    @Published private(set) var location: CLLocation?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var dataSourceStatuses: [String: Int] = [:]
    @Published private(set) var amsatDays: [AmsatStatusDay] = []
    @Published private(set) var amsatRows: [AmsatStatusRow] = []
    @Published private(set) var isRefreshingAmsat = false
    @Published private(set) var amsatError: String?
    @Published private(set) var amsatFetchedAt: Date?
    @Published private(set) var isSubmittingAmsatReport = false
    @Published private(set) var amsatUploadMessage: String?
    @Published private(set) var amsatUploadError: String?
    @Published var searchText = ""
    @Published private(set) var manualLocation: CLLocation? = SatelliteStore.loadManualLocation()
    @Published var selectedIDs: Set<Int32> = {
        let saved = (UserDefaults.standard.array(forKey: "trackedSatelliteIDs") as? [NSNumber])?.map(\.int32Value)
        return Set(saved ?? [25544, 28654, 33591])
    }() {
        didSet {
            UserDefaults.standard.set(selectedIDs.map { Int($0) }, forKey: "trackedSatelliteIDs")
        }
    }
    @Published var selectedSatelliteModes: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "selectedSatelliteModes") ?? []) {
        didSet { UserDefaults.standard.set(selectedSatelliteModes.sorted(), forKey: "selectedSatelliteModes") }
    }
    @Published var passSearchText = ""
    @Published var preferences = Look4SatPreferences.load() {
        didSet { preferences.save() }
    }
    @Published var passFilters = PassFilterSettings.load() {
        didSet { passFilters.save() }
    }
    @Published var dataSourceSettings = IOSDataSourceSettings.load() {
        didSet { dataSourceSettings.save() }
    }
    @Published var radioSettings = IOSRadioSettings.load() {
        didSet { radioSettings.save() }
    }
    @Published private(set) var modesBySatellite: [Int32: Set<String>] = [:]

    private let locationManager = CLLocationManager()
    private var hasStarted = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.headingFilter = 1
    }

    var filteredSatellites: [SatelliteTarget] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let modeFilteredSatellites = filterBySelectedModes(satellites)
        guard !query.isEmpty else {
            return modeFilteredSatellites.filter { selectedIDs.contains($0.catalogNumber) }
                + Array(modeFilteredSatellites.filter { !selectedIDs.contains($0.catalogNumber) }.prefix(30))
        }
        return modeFilteredSatellites.filter { matchesSatellite($0, query: query) }.prefix(100).map { $0 }
    }

    var trackedSatellites: [SatelliteTarget] {
        filterBySelectedModes(satellites).filter { selectedIDs.contains($0.catalogNumber) }
    }

    var availableSatelliteModes: [String] {
        SatelliteModeCatalog.shared.modes as? [String] ?? []
    }

    var visiblePasses: [PassItem] {
        let query = passSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return passes }
        if let catalogNumber = Int32(query) {
            return passes.filter { $0.satellite.catalogNumber == catalogNumber }
        }
        return passes.filter { matchesSatellite($0.satellite, query: query) }
    }

    var locationDescription: String {
        guard let location = observerLocation else { return "Location not set" }
        return String(format: "%.4f°, %.4f°", location.coordinate.latitude, location.coordinate.longitude)
    }

    var observerLocation: CLLocation? { manualLocation ?? location }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if manualLocation != nil {
            // A manually configured station position works without granting location access.
        } else if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            statusMessage = "Enable location access to calculate passes for your sky."
        } else {
            requestLocation()
        }
        await loadCache()
        if modesBySatellite.isEmpty { await refreshTransceivers() }
        Task { await refreshAmsatStatus() }
        if satellites.isEmpty || (preferences.autoUpdate &&
            (lastUpdated.map({ Date().timeIntervalSince($0) > 7 * 24 * 60 * 60 }) ?? true)) {
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

    @discardableResult
    func setManualLocation(latitude: Double, longitude: Double, altitudeMeters: Double = 0) -> Bool {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude), altitudeMeters.isFinite else {
            return false
        }
        let timestamp = Date()
        let position = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitudeMeters,
            horizontalAccuracy: 0,
            verticalAccuracy: 0,
            timestamp: timestamp
        )
        manualLocation = position
        let defaults = UserDefaults.standard
        defaults.set(latitude, forKey: "observerLatitude")
        defaults.set(longitude, forKey: "observerLongitude")
        defaults.set(altitudeMeters, forKey: "observerAltitude")
        Task { await recalculatePasses() }
        return true
    }

    func useDeviceLocation() {
        manualLocation = nil
        ["observerLatitude", "observerLongitude", "observerAltitude"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        requestLocation()
    }

    func clearOrbitalData() {
        satellites = []
        passes = []
        positions = [:]
        transceivers = []
        modesBySatellite = [:]
        selectedTransponderUUID = nil
        lastUpdated = nil
        statusMessage = nil
        [cacheURL, transceiverCacheURL].compactMap { $0 }.forEach {
            try? FileManager.default.removeItem(at: $0)
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var catalogByID: [Int32: SatelliteTarget] = [:]
        var cacheText: String?
        var statuses: [String: Int] = [:]
        for source in dataSourceSettings.satellites where source.isEnabled && !source.url.isEmpty {
            guard let url = Self.url(for: source.url) else {
                statuses[source.url] = -1
                continue
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                request.setValue("Look4Sat iOS", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                statuses[source.url] = code
                guard code == 200, let text = String(data: data, encoding: .utf8) else { continue }
                let parsed = await Self.parseCatalog(text)
                if parsed.count > (cacheText == nil ? 0 : 5_000) { cacheText = text }
                for target in parsed {
                    if let old = catalogByID[target.catalogNumber],
                       old.elementEpochDaynum >= target.elementEpochDaynum { continue }
                    catalogByID[target.catalogNumber] = target
                }
            } catch {
                statuses[source.url] = -1
            }
        }
        dataSourceStatuses = statuses
        guard !catalogByID.isEmpty else {
            statusMessage = "Orbital data is unavailable. Connect to the internet and try again."
            return
        }
        satellites = catalogByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastUpdated = Date()
        statusMessage = nil
        if let cacheText { try? saveCache(cacheText) }
        await refreshTransceivers()
        await recalculatePasses()
    }

    func importOrbitalElements(_ text: String) async -> Bool {
        let parsed = await Self.parseCatalog(text)
        guard !parsed.isEmpty else { return false }
        var byID = Dictionary(uniqueKeysWithValues: satellites.map { ($0.catalogNumber, $0) })
        for satellite in parsed {
            if let old = byID[satellite.catalogNumber], old.elementEpochDaynum >= satellite.elementEpochDaynum { continue }
            byID[satellite.catalogNumber] = satellite
        }
        satellites = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastUpdated = Date()
        try? saveCache(text)
        await recalculatePasses()
        return true
    }

    func resetDataSources() {
        dataSourceSettings = .defaults
    }

    private static func url(for source: String) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)")
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

    func selectTransponder(_ uuid: String?) {
        selectedTransponderUUID = uuid
    }

    func clearAmsatUploadMessages() {
        amsatUploadMessage = nil
        amsatUploadError = nil
    }

    func setSelectedSatelliteModes(_ modes: Set<String>) {
        selectedSatelliteModes = modes
        Task { await recalculatePasses() }
    }

    var remainingPassGroups: [PassGroup] {
        let remaining = Array(visiblePasses.dropFirst())
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.timeZone = preferences.isUTC ? TimeZone(secondsFromGMT: 0) : .current
        let grouped = Dictionary(grouping: remaining) { item in
            formatter.string(from: Date(timeIntervalSince1970: TimeInterval(item.prediction.aosTimeMillis) / 1000))
        }
        return grouped.map { dateLabel, items in
            PassGroup(dateLabel: dateLabel, items: items.sorted { $0.prediction.aosTimeMillis < $1.prediction.aosTimeMillis })
        }.sorted {
            ($0.items.first?.prediction.aosTimeMillis ?? 0) < ($1.items.first?.prediction.aosTimeMillis ?? 0)
        }
    }

    func selectAllSatellitesInFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = filterBySelectedModes(satellites).filter { matchesSatellite($0, query: query) }
        selectedIDs.formUnion(visible.map(\.catalogNumber))
        Task { await recalculatePasses() }
    }

    func clearAllSatellitesInFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleIDs = Set(filterBySelectedModes(satellites).filter { matchesSatellite($0, query: query) }.map(\.catalogNumber))
        selectedIDs.subtract(visibleIDs)
        Task { await recalculatePasses() }
    }

    func recalculatePasses() async {
        guard let location = observerLocation, !satellites.isEmpty else {
            passes = []
            return
        }
        let selected = filterBySelectedModes(satellites).filter { selectedIDs.contains($0.catalogNumber) }
        let inputs = selected.map(PredictionInput.init)
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let altitude = location.altitude
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let filters = passFilters
        let timeZoneIdentifier = preferences.isUTC ? "GMT" : TimeZone.current.identifier
        let snapshots = await Task.detached(priority: .userInitiated) {
            inputs.map { input -> SatelliteSnapshot in
                let position = input.satellite.currentPosition(
                    latitude: lat,
                    longitude: lon,
                    altitudeMeters: altitude,
                    timeMillis: now
                )
                var predictions: [PredictedPass] = []
                let searchEnd = now + Int64(filters.hoursAhead) * 3_600_000
                var passStart = now
                var attempts = 0
                while passStart < searchEnd && attempts < 128 {
                    guard let pass = input.satellite.nextPass(
                        latitude: lat,
                        longitude: lon,
                        altitudeMeters: altitude,
                        startTimeMillis: passStart
                    ) else { break }
                    if pass.aosTimeMillis >= searchEnd { break }
                    let eventDate = Date(timeIntervalSince1970: TimeInterval(pass.aosTimeMillis) / 1000)
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
                    let time = calendar.dateComponents([.hour, .minute], from: eventDate)
                    let minute = (time.hour ?? 0) * 60 + (time.minute ?? 0)
                    let inWindow: Bool
                    if filters.aosStartMinute <= filters.aosEndMinute {
                        inWindow = minute >= filters.aosStartMinute && minute <= filters.aosEndMinute
                    } else {
                        inWindow = minute >= filters.aosStartMinute || minute <= filters.aosEndMinute
                    }
                    let passesTimeFilter = input.satellite.isDeepSpace ||
                        (filters.invertAosTimeWindow ? !inWindow : inWindow)
                    if pass.maximumElevationDegrees >= filters.minimumElevation &&
                        (!input.satellite.isDeepSpace || filters.showDeepSpace) && passesTimeFilter {
                        predictions.append(PredictedPass(
                            catalogNumber: input.satellite.catalogNumber,
                            aosTimeMillis: pass.aosTimeMillis,
                            aosAzimuthDegrees: pass.aosAzimuthDegrees,
                            losTimeMillis: pass.losTimeMillis,
                            losAzimuthDegrees: pass.losAzimuthDegrees,
                            maximumElevationDegrees: pass.maximumElevationDegrees,
                            altitudeKilometers: pass.altitudeKilometers
                        ))
                    }
                    if input.satellite.isDeepSpace { break }
                    passStart = max(pass.losTimeMillis + 1_000, passStart + 60_000)
                    attempts += 1
                }
                let reading = TrackedPosition(
                    timeMillis: now,
                    azimuthDegrees: position.azimuthDegrees,
                    elevationDegrees: position.elevationDegrees,
                    latitudeDegrees: position.latitudeDegrees,
                    longitudeDegrees: position.longitudeDegrees,
                    altitudeKilometers: position.altitudeKilometers,
                    distanceKilometers: position.distanceKilometers,
                    distanceRateKilometersPerSecond: position.distanceRateKilometersPerSecond,
                    isAboveHorizon: position.isAboveHorizon
                )
                return SatelliteSnapshot(
                    catalogNumber: input.satellite.catalogNumber,
                    position: reading,
                    passes: predictions
                )
            }
        }.value
        positions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.catalogNumber, $0.position) })
        let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.catalogNumber, $0) })
        passes = snapshots.flatMap { snapshot -> [PassItem] in
            guard let satellite = byID[snapshot.catalogNumber] else { return [] }
            return snapshot.passes.map { PassItem(satellite: satellite, prediction: $0) }
        }.sorted { $0.prediction.aosTimeMillis < $1.prediction.aosTimeMillis }
    }

    func position(for satellite: SatelliteTarget) -> TrackedPosition? {
        positions[satellite.catalogNumber]
    }

    func satellite(withID id: Int32) -> SatelliteTarget? {
        satellites.first { $0.catalogNumber == id }
    }

    func refreshTransceivers() async {
        var combined: [String: IOSTransponder] = [:]
        for source in dataSourceSettings.transceivers where source.isEnabled && !source.url.isEmpty {
            guard let url = Self.url(for: source.url) else {
                dataSourceStatuses[source.url] = -1
                continue
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                request.setValue("Look4Sat iOS", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dataSourceStatuses[source.url] = code
                guard code == 200 else { continue }
                for transponder in Self.parseTransceivers(data) {
                    combined[transponder.uuid] = transponder
                }
                if !combined.isEmpty { try? data.write(to: transceiverCacheURL, options: .atomic) }
            } catch {
                dataSourceStatuses[source.url] = -1
            }
        }
        guard !combined.isEmpty else { return }
        transceivers = combined.values.sorted {
            $0.info.localizedStandardCompare($1.info) == .orderedAscending
        }
        if let selectedTransponderUUID,
           !transceivers.contains(where: { $0.uuid == selectedTransponderUUID }) {
            self.selectedTransponderUUID = nil
        }
        modesBySatellite = Self.modesBySatellite(transceivers)
        await recalculatePasses()
    }

    func refreshAmsatStatus() async {
        guard !isRefreshingAmsat else { return }
        isRefreshingAmsat = true
        defer { isRefreshingAmsat = false }
        do {
            let catalog = try await getJSON(from: "https://www.amsat.org/status/api/v1/catalog.php")
            let reports = try await getJSON(from: "https://www.amsat.org/status/api/v1/reports.php?hours=72&limit=500")
            let names = Self.parseAmsatCatalog(catalog)
            let parsedReports = Self.parseAmsatReports(reports)
            guard !names.isEmpty else { throw URLError(.cannotParseResponse) }
            let page = Self.makeAmsatStatus(names: names, reports: parsedReports, now: Date())
            amsatDays = page.days
            amsatRows = page.rows
            amsatFetchedAt = Date()
            amsatError = nil
        } catch {
            amsatError = amsatRows.isEmpty ? "AMSAT status is unavailable." : "Showing the last loaded status."
        }
    }

    func submitAmsatReport(
        satelliteName: String,
        report: String,
        callsign: String,
        gridSquare: String
    ) async {
        let normalizedCall = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedGrid = gridSquare.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedCall.isEmpty else {
            amsatUploadError = "Enter a callsign before submitting."
            return
        }
        guard normalizedGrid.isEmpty || normalizedGrid.range(of: #"^[A-R]{2}[0-9]{2}([A-X]{2})?$"#, options: .regularExpression) != nil else {
            amsatUploadError = "Grid square must be 4 or 6 Maidenhead characters."
            return
        }

        isSubmittingAmsatReport = true
        amsatUploadError = nil
        amsatUploadMessage = nil
        UserDefaults.standard.set(normalizedCall, forKey: "amsatCallsign")
        defer { isSubmittingAmsatReport = false }
        do {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            var payload: [String: Any] = [
                "name": satelliteName,
                "report": report,
                "callsign": normalizedCall,
                "reported_at": formatter.string(from: Date())
            ]
            if !normalizedGrid.isEmpty { payload["grid_square"] = normalizedGrid }
            var request = URLRequest(url: URL(string: "https://www.amsat.org/status/api/v1/reports.php")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 45
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Look4Sat iOS", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            let responseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errorObject = responseObject?["error"] as? [String: Any]
            let apiError = errorObject?["message"] as? String
            guard let code = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(code), apiError == nil else {
                throw AmsatSubmissionError(message: apiError ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            amsatUploadMessage = "Report submitted. Thank you!"
            await refreshAmsatStatus()
        } catch let error as AmsatSubmissionError {
            amsatUploadError = error.message
        } catch {
            amsatUploadError = error.localizedDescription
        }
    }

    private func filterBySelectedModes(_ satellites: [SatelliteTarget]) -> [SatelliteTarget] {
        guard !selectedSatelliteModes.isEmpty else { return satellites }
        guard !modesBySatellite.isEmpty else { return satellites }
        let matchingIDs = Set(modesBySatellite.compactMap { id, modes in
            modes.isDisjoint(with: selectedSatelliteModes) ? nil : id
        })
        return satellites.filter { matchingIDs.contains($0.catalogNumber) }
    }

    private func matchesSatellite(_ satellite: SatelliteTarget, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if query.allSatisfy(\.isNumber) {
            return String(satellite.catalogNumber).contains(query)
        }
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map { token in
            token.filter { $0.isLetter || $0.isNumber }
        }
        let name = satellite.name.lowercased().filter { $0.isLetter || $0.isNumber }
        return tokens.allSatisfy { $0.isEmpty || name.contains($0) }
    }

    private func getJSON(from address: String) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 45
        request.setValue("Look4Sat iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    func trajectory(
        for satelliteID: Int32,
        startTimeMillis: Int64,
        endTimeMillis: Int64,
        stepMillis: Int64
    ) async -> [TrackedPosition] {
        guard let satellite = satellite(withID: satelliteID) else { return [] }
        let input = PredictionInput(satellite: satellite)
        let observer = observerLocation
        let latitude = observer?.coordinate.latitude ?? 0
        let longitude = observer?.coordinate.longitude ?? 0
        let altitude = observer?.altitude ?? 0
        let step = max(1_000, stepMillis)

        return await Task.detached(priority: .utility) {
            var positions: [TrackedPosition] = []
            var time = startTimeMillis
            while time <= endTimeMillis {
                let position = input.satellite.currentPosition(
                    latitude: latitude,
                    longitude: longitude,
                    altitudeMeters: altitude,
                    timeMillis: time
                )
                positions.append(TrackedPosition(
                    timeMillis: time,
                    azimuthDegrees: position.azimuthDegrees,
                    elevationDegrees: position.elevationDegrees,
                    latitudeDegrees: position.latitudeDegrees,
                    longitudeDegrees: position.longitudeDegrees,
                    altitudeKilometers: position.altitudeKilometers,
                    distanceKilometers: position.distanceKilometers,
                    distanceRateKilometersPerSecond: position.distanceRateKilometersPerSecond,
                    isAboveHorizon: position.isAboveHorizon
                ))
                time += step
            }
            return positions
        }.value
    }

    func formattedTime(_ milliseconds: Int64, dateStyle: DateFormatter.Style = .medium) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = dateStyle
        formatter.timeZone = preferences.isUTC ? TimeZone(secondsFromGMT: 0) : .current
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
        if let url = cacheURL, let csv = try? String(contentsOf: url, encoding: .utf8) {
            satellites = await Self.parseCatalog(csv)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attributes[.modificationDate] as? Date {
                lastUpdated = modified
            }
        }
        if let radioData = try? Data(contentsOf: transceiverCacheURL) {
            transceivers = Self.parseTransceivers(radioData)
            modesBySatellite = Self.modesBySatellite(transceivers)
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

    private var transceiverCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("transceivers.json")
    }

    nonisolated private static func parseTransceivers(_ data: Data) -> [IOSTransponder] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let uuid = row["uuid"] as? String, !uuid.isEmpty else { return nil }
            return IOSTransponder(
                uuid: uuid,
                info: row["description"] as? String ?? "",
                isAlive: row["alive"] as? Bool ?? true,
                downlinkLow: (row["downlink_low"] as? NSNumber)?.int64Value,
                downlinkHigh: (row["downlink_high"] as? NSNumber)?.int64Value,
                downlinkMode: row["mode"] as? String,
                uplinkLow: (row["uplink_low"] as? NSNumber)?.int64Value,
                uplinkHigh: (row["uplink_high"] as? NSNumber)?.int64Value,
                uplinkMode: row["uplink_mode"] as? String,
                isInverted: row["invert"] as? Bool ?? false,
                catalogNumber: (row["norad_cat_id"] as? NSNumber)?.int32Value
            )
        }
    }

    nonisolated private static func modesBySatellite(_ transceivers: [IOSTransponder]) -> [Int32: Set<String>] {
        var result: [Int32: Set<String>] = [:]
        for transceiver in transceivers where transceiver.isAlive {
            guard let number = transceiver.catalogNumber else { continue }
            var modes = result[number, default: []]
            if let mode = transceiver.downlinkMode, !mode.isEmpty { modes.insert(mode) }
            if let mode = transceiver.uplinkMode, !mode.isEmpty { modes.insert(mode) }
            result[number] = modes
        }
        return result
    }

    nonisolated private static func parseAmsatCatalog(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["data"] as? [[String: Any]] else { return [] }
        return records.compactMap { $0["name"] as? String }
    }

    nonisolated private static func parseAmsatReports(_ data: Data) -> [AmsatReport] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = root["data"] as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard let id = record["id"] as? String,
                  let name = record["name"] as? String,
                  let reportedAt = record["reported_time"] as? String,
                  let timestamp = parseISODate(reportedAt) else { return nil }
            return AmsatReport(
                id: id,
                satelliteName: name,
                status: record["report"] as? String ?? "",
                callsign: record["callsign"] as? String ?? "",
                gridSquare: record["grid_square"] as? String ?? "",
                dateUtc: statusDate(timestamp),
                timeUtc: statusTime(timestamp),
                reportedAtMillis: Int64(timestamp.timeIntervalSince1970 * 1000)
            )
        }
    }

    nonisolated private static func makeAmsatStatus(
        names: [String],
        reports: [AmsatReport],
        now: Date
    ) -> (days: [AmsatStatusDay], rows: [AmsatStatusRow]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let days = (0..<3).compactMap { offset -> AmsatStatusDay? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return AmsatStatusDay(label: statusDayLabel(date), startOfDayMillis: Int64(date.timeIntervalSince1970 * 1000))
        }
        let byName = Dictionary(grouping: reports, by: \.satelliteName)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let rows = names.map { name in
            let satelliteReports = byName[name] ?? []
            let cells = days.enumerated().map { index, day in
                let end = nowMillis - Int64(index) * 86_400_000
                let start = end - 86_400_000
                let dayReports = satelliteReports.filter { $0.reportedAtMillis >= start && $0.reportedAtMillis < end }
                let latestSlot = (0..<12).lazy.compactMap { slotIndex -> [AmsatReport]? in
                    let slotEnd = end - Int64(slotIndex) * 7_200_000
                    let slotStart = slotEnd - 7_200_000
                    let slotReports = dayReports.filter {
                        $0.reportedAtMillis >= slotStart && $0.reportedAtMillis < slotEnd
                    }
                    return slotReports.isEmpty ? nil : slotReports
                }.first
                let latest = latestSlot?.max { $0.reportedAtMillis < $1.reportedAtMillis }
                return AmsatStatusCell(status: latest?.status, count: latestSlot?.count ?? 0, reports: dayReports)
            }
            return AmsatStatusRow(name: name, cells: cells)
        }
        return (days, rows)
    }

    nonisolated private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    nonisolated private static func statusDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated private static func statusTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    nonisolated private static func statusDayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    nonisolated private static func parseCatalog(_ csv: String) async -> [SatelliteTarget] {
        let parsed = await Task.detached(priority: .userInitiated) {
            let parser = SatelliteCatalogParser()
            let csvValues = parser.parseCatalog(csv: csv).compactMap { $0 as? SatelliteTarget }
            let values = csvValues.isEmpty
                ? parser.parseTLE(tle: csv).compactMap { $0 as? SatelliteTarget }
                : csvValues
            return ParsedCatalog(satellites: values)
        }.value
        return parsed.satellites
    }

    private static func loadManualLocation() -> CLLocation? {
        let defaults = UserDefaults.standard
        guard let latitude = defaults.object(forKey: "observerLatitude") as? Double,
              let longitude = defaults.object(forKey: "observerLongitude") as? Double else { return nil }
        let altitude = defaults.double(forKey: "observerAltitude")
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: 0,
            verticalAccuracy: 0,
            timestamp: Date()
        )
    }
}
