import SwiftUI
import Observation
import UIKit

// =====================================================================
// Radio Remote: Phase 1 + 2 build
//
// PHASE 1 (works on someone else's phone)
//   - host and pin persisted; host defaults to empty
//   - dedicated URLSession with a 4 s timeout (fast failure when unreachable)
//   - friendly "can't reach radio" message
//   - Volume card layout fixed (.groupedCard() wraps the whole card)
//   - isScanning always resets, even when a scan is cancelled
//   - Settings opens automatically on first launch (no host yet)
//
// PHASE 2 (reliable, quiet behaviour)
//   - poll loop awaits each refresh (no overlapping requests)
//   - caps (volume steps) read once per connection
//   - presets fetched once (launch, mode change, power-on, settings close),
//     not toggling nav.state every poll
//   - controls dimmed/disabled in standby
//   - haptics only on user taps, not on polled changes
//   - preset highlight tracks the selected index instead of name matching
//   - polling pauses in the background, resumes when active
//
// PHASE 3 (settings and sources)
//   - Demo Mode, Detect Modes and the mode numbers moved to Settings > Advanced
//   - Settings > About shows version, build and build date (shareable)
//   - Internet / DAB / FM can be switched on or off; only sources the radio
//     supports are offered (detected once per radio, -1 = not supported)
// =====================================================================

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// UIKit equivalent, used to override the window's style (and reset it cleanly).
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The radio sources this app can switch between.
enum RadioSource: String, CaseIterable, Identifiable {
    case internet
    case dab
    case fm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internet: return "Internet"
        case .dab: return "DAB"
        case .fm: return "FM"
        }
    }

    var systemImage: String {
        switch self {
        case .internet: return "globe"
        case .dab: return "antenna.radiowaves.left.and.right"
        case .fm: return "radio"
        }
    }

    fileprivate var enabledKey: String { "fs_\(rawValue)_enabled" }
}

/// Version and build information shown in Settings > About.
enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Radio Remote"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Date the app binary was built (read from the executable's file date).
    static var buildDate: Date? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.modificationDate] as? Date) ?? (attrs[.creationDate] as? Date)
    }

    static var buildDateText: String {
        buildDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown"
    }

    /// Plain-text summary, handy for sharing in a bug report or message.
    static var summary: String {
        "\(name) \(version) (build \(build)), built \(buildDateText)"
    }
}

struct DiscoveredRadio: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: Int
    /// False when the radio gave no friendly name and `name` is just a placeholder.
    var hasRealName: Bool = true

    var displayHost: String {
        port == 80 ? host : "\(host):\(port)"
    }
}

struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let label: String
    let urlString: String
    let rawXML: String
}

enum RadioError: LocalizedError {
    case noHost

    var errorDescription: String? {
        switch self {
        case .noHost: return "No radio selected. Open Settings and tap Scan for Radios, or turn on Demo Mode under Advanced."
        }
    }
}

@MainActor
@Observable
final class RadioController {
    // PHASE 1: host and pin persist; host starts empty instead of a hard-coded IP.
    var host: String = UserDefaults.standard.string(forKey: "fs_host") ?? "" {
        didSet { UserDefaults.standard.set(host, forKey: "fs_host") }
    }
    var pin: String = UserDefaults.standard.string(forKey: "fs_pin") ?? "1234" {
        didSet { UserDefaults.standard.set(pin, forKey: "fs_pin") }
    }
    // DEMO: simulates a radio locally; no network requests are made while on.
    var isDemoMode: Bool = UserDefaults.standard.bool(forKey: "fs_demo_mode") {
        didSet {
            guard oldValue != isDemoMode else { return }
            UserDefaults.standard.set(isDemoMode, forKey: "fs_demo_mode")
            resetStateForSourceChange()
        }
    }
    var internetMode: Int = UserDefaults.standard.object(forKey: "fs_internet_mode") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(internetMode, forKey: "fs_internet_mode") }
    }
    var dabMode: Int = UserDefaults.standard.object(forKey: "fs_dab_mode") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(dabMode, forKey: "fs_dab_mode") }
    }
    /// -1 means "not supported / not detected yet".
    var fmMode: Int = UserDefaults.standard.object(forKey: "fs_fm_mode") as? Int ?? -1 {
        didSet { UserDefaults.standard.set(fmMode, forKey: "fs_fm_mode") }
    }
    /// Shows the FSAPI XML debug (ant) button in the toolbar.
    var showDebugButton: Bool = UserDefaults.standard.object(forKey: "fs_show_debug_button") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showDebugButton, forKey: "fs_show_debug_button") }
    }
    // User choice: which sources appear in the Source switcher.
    var internetEnabled: Bool = UserDefaults.standard.object(forKey: RadioSource.internet.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(internetEnabled, forKey: RadioSource.internet.enabledKey) }
    }
    var dabEnabled: Bool = UserDefaults.standard.object(forKey: RadioSource.dab.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(dabEnabled, forKey: RadioSource.dab.enabledKey) }
    }
    var fmEnabled: Bool = UserDefaults.standard.object(forKey: RadioSource.fm.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(fmEnabled, forKey: RadioSource.fm.enabledKey) }
    }
    // Name of the radio as found by scanning, remembered together with the host it belongs to.
    var radioName: String = UserDefaults.standard.string(forKey: "fs_radio_name") ?? "" {
        didSet { UserDefaults.standard.set(radioName, forKey: "fs_radio_name") }
    }
    var radioNameHost: String = UserDefaults.standard.string(forKey: "fs_radio_name_host") ?? "" {
        didSet { UserDefaults.standard.set(radioNameHost, forKey: "fs_radio_name_host") }
    }
    var stationName: String = "— —"
    var stationSubtext: String = " "
    var isPoweredOn: Bool = true
    var modeIndex: UInt8?
    var maxVolume: Int = 20
    var volume: Double = 10
    var isMuted: Bool = false
    var isAdjustingVolume: Bool = false
    var presetNames: [Int: String] = [:]
    // PHASE 2: highlight by remembered index, not by name matching.
    var activePresetIndex: Int?
    var statusMessage: String?
    var debugLogs: [DebugLogEntry] = []
    var isDebugLoggingEnabled: Bool = false

    var discoveredRadios: [DiscoveredRadio] = []
    var isScanning: Bool = false
    var scanStatusMessage: String?
    var isDetectingModes: Bool = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var volumeSendTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var currentScanID = UUID()

    // PHASE 2: bookkeeping so quasi-static data is fetched once, not every poll.
    @ObservationIgnored private var capsLoaded = false
    @ObservationIgnored private var presetsLoaded = false
    @ObservationIgnored private var presetAttempts = 0
    private let maxPresetAttempts = 5

    // PHASE 1: dedicated session with a short timeout so an unreachable radio fails fast.
    // (A var so it can be replaced after the phone wakes: connections kept open
    // from before sleep are dead and would fail the first requests.)
    @ObservationIgnored private var session = RadioController.makeSession(timeout: 4)

    // Wake-from-sleep tolerance: Wi-Fi is often not back yet when the app becomes
    // active, so the first requests fail. Only show "can't reach" after a few
    // failures in a row, and retry quickly in the meantime.
    @ObservationIgnored private var connectionFailures = 0
    private let failuresBeforeMessage = 3
    private let normalPollSeconds = 4.0
    private let retryPollSeconds = 1.5

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    var cleanedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
    }

    var hasHost: Bool { isDemoMode || !cleanedHost.isEmpty }

    /// Navigation title: the radio's own name if we found it while scanning
    /// (and the host hasn't changed since), otherwise the app name.
    var deviceTitle: String {
        if !isDemoMode, !radioName.isEmpty, radioNameHost == cleanedHost {
            return radioName
        }
        return "Radio Remote"
    }

    /// Remembers the name of a radio found by scanning (ignores placeholder names).
    func rememberRadio(_ radio: DiscoveredRadio) {
        guard radio.hasRealName else { return }
        radioName = radio.name
        radioNameHost = radio.host
    }

    var activeSourceLabel: String? {
        guard let modeIndex else { return nil }
        return RadioSource.allCases.first { modeValue(for: $0) == Int(modeIndex) }?.title
    }

    // MARK: - Sources

    /// The radio's mode index for a source, or nil if the radio doesn't support it.
    func modeValue(for source: RadioSource) -> Int? {
        switch source {
        case .internet: return internetMode >= 0 ? internetMode : nil
        case .dab: return dabMode >= 0 ? dabMode : nil
        case .fm:
            if fmMode >= 0 { return fmMode }
            return isDemoMode ? 4 : nil   // the demo radio always has FM
        }
    }

    func isSupported(_ source: RadioSource) -> Bool {
        modeValue(for: source) != nil
    }

    func isEnabled(_ source: RadioSource) -> Bool {
        switch source {
        case .internet: return internetEnabled
        case .dab: return dabEnabled
        case .fm: return fmEnabled
        }
    }

    func setEnabled(_ source: RadioSource, _ value: Bool) {
        switch source {
        case .internet: internetEnabled = value
        case .dab: dabEnabled = value
        case .fm: fmEnabled = value
        }
    }

    /// Sources shown in the Source switcher: supported by the radio and enabled by the user.
    var visibleSources: [RadioSource] {
        RadioSource.allCases.filter { isSupported($0) && isEnabled($0) }
    }

    /// Host for which modes were last auto-detected (persisted), so detection
    /// runs once per radio instead of overwriting manual edits every launch.
    private var modesDetectedHost: String {
        get { UserDefaults.standard.string(forKey: "fs_modes_detected_host") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "fs_modes_detected_host") }
    }

    // MARK: - Polling (PHASE 2)

    /// Starts (or restarts) the poll loop. Each iteration awaits the full refresh
    /// before sleeping, so requests can never pile up. Restarting also acts as
    /// "refresh now": the in-flight request of the old loop is cancelled.
    func startPolling(immediate: Bool = true) {
        stopPolling()
        pollTask = Task { [weak self] in
            var skipSleep = immediate
            while !Task.isCancelled {
                if !skipSleep {
                    let wait = self?.pollInterval() ?? 4.0
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { break }
                }
                skipSleep = false
                await self?.refreshOnce()
                if self == nil { break }
            }
        }
    }

    /// Retry quickly while the connection is failing, relax once it works.
    private func pollInterval() -> Double {
        connectionFailures > 0 ? retryPollSeconds : normalPollSeconds
    }

    /// App became active again (e.g. after sleep): start with a fresh connection
    /// and a clean failure count, so brief Wi-Fi reconnect errors stay silent.
    func resume() {
        session.invalidateAndCancel()
        session = RadioController.makeSession(timeout: 4)
        connectionFailures = 0
        startPolling()
    }

    /// Pull-to-refresh: forget the preset bookkeeping (including the failed-attempt
    /// counter), reload everything once, then resume normal polling. Returns when done
    /// so the pull-to-refresh spinner stays visible for the duration.
    func forceRefresh() async {
        stopPolling()
        statusMessage = nil
        // The person asked for this refresh, so report a failure straight away.
        connectionFailures = failuresBeforeMessage - 1
        invalidatePresets(clearNames: false)
        await refreshOnce()
        startPolling(immediate: false)
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Refresh immediately (button taps, after actions).
    func refresh() {
        startPolling()
    }

    /// Call when host/pin changed (Settings closed): forget per-radio state and reconnect.
    func reconnect() {
        stopPolling()
        capsLoaded = false
        invalidatePresets(clearNames: true)
        activePresetIndex = nil
        statusMessage = nil
        startPolling()
    }

    func clearLogs() {
        debugLogs.removeAll()
    }

    private func invalidatePresets(clearNames: Bool) {
        presetsLoaded = false
        presetAttempts = 0
        if clearNames { presetNames = [:] }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func report(_ error: Error) {
        guard !Task.isCancelled, !isCancellation(error) else { return }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .notConnectedToInternet:
                connectionFailures += 1
                // Stay quiet for the first failures (typical right after wake-up);
                // the poll loop keeps retrying and clears this on the first success.
                if connectionFailures >= failuresBeforeMessage {
                    statusMessage = "Can't reach the radio at \(cleanedHost). Check that it's on and on the same Wi-Fi."
                }
                return
            default:
                break
            }
        }
        statusMessage = error.localizedDescription
    }

    private func refreshOnce() async {
        if isDemoMode {
            applyDemoState()
            return
        }
        guard hasHost else {
            statusMessage = RadioError.noHost.errorDescription
            return
        }
        do {
            if !capsLoaded,
               let steps = try? await getInt(node: "netRemote.sys.caps.volumeSteps"), steps > 1 {
                maxVolume = steps - 1
                capsLoaded = true
            }
            if let name = try await getString(node: "netRemote.play.info.name") {
                let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
                stationName = cleaned.isEmpty ? "— —" : cleaned
            }
            if let text = try await getString(node: "netRemote.play.info.text") {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                stationSubtext = cleaned.isEmpty ? " " : cleaned
            }
            if let power = try await getU8(node: "netRemote.sys.power") {
                let nowOn = (power != 0)
                // Radio just woke from standby: presets need (re)loading.
                if nowOn && !isPoweredOn { invalidatePresets(clearNames: false) }
                isPoweredOn = nowOn
            }
            if let mode = try await getU8(node: "netRemote.sys.mode") {
                // Mode changed (possibly on the radio itself): presets belong to the old mode.
                if let previous = modeIndex, previous != mode {
                    invalidatePresets(clearNames: true)
                    activePresetIndex = nil
                }
                modeIndex = mode
            }
            if let muted = try? await getU8(node: "netRemote.sys.audio.mute") {
                isMuted = (muted != 0)
            }
            if !isAdjustingVolume, let vol = try await getInt(node: "netRemote.sys.audio.volume") {
                volume = Double(min(maxVolume, max(0, vol)))
            }
            statusMessage = nil
            connectionFailures = 0

            // First successful connection to this radio: find out which sources it supports.
            if modesDetectedHost != cleanedHost {
                autoDetectModes()
            }

            await loadPresetsIfNeeded()
            syncActivePresetFromStationName()
        } catch {
            report(error)
        }
    }

    /// Presets are fetched only when needed, not on every poll.
    private func loadPresetsIfNeeded() async {
        guard isPoweredOn, !presetsLoaded, presetAttempts < maxPresetAttempts else { return }
        presetAttempts += 1
        if let names = try? await getPresetNames(), !names.isEmpty {
            presetNames = names
            presetsLoaded = true
        }
    }

    /// If the station name exactly matches a preset name (e.g. the preset was
    /// changed on the radio itself), adopt that index. Otherwise keep what we have,
    /// since internet stations often replace the name with a show title.
    private func syncActivePresetFromStationName() {
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "— —" else { return }
        if let match = presetNames.first(where: {
            $0.value.caseInsensitiveCompare(name) == .orderedSame
        }) {
            activePresetIndex = match.key
        }
    }

    // MARK: - Actions

    func togglePower() {
        if isDemoMode {
            isPoweredOn.toggle()
            updateDemoPlayback()
            return
        }
        let nextValue = isPoweredOn ? 0 : 1
        Task {
            do {
                try await setValue(node: "netRemote.sys.power", value: "\(nextValue)")
                isPoweredOn = (nextValue != 0)
                if nextValue == 1 { invalidatePresets(clearNames: false) }
            } catch {
                report(error)
            }
        }
    }

    func toggleMute() {
        if isDemoMode {
            isMuted.toggle()
            return
        }
        let nextMuted = !isMuted
        Task {
            do {
                try await setValue(node: "netRemote.sys.audio.mute", value: nextMuted ? "1" : "0")
                isMuted = nextMuted
            } catch {
                report(error)
            }
        }
    }

    func selectPreset(_ index: Int) {
        if isDemoMode {
            activePresetIndex = index
            updateDemoPlayback()
            return
        }
        Task {
            do {
                try await setValue(node: "netRemote.nav.state", value: "1")
                try await setValue(node: "netRemote.nav.action.selectPreset", value: "\(index)")
                try? await setValue(node: "netRemote.nav.state", value: "0")
                activePresetIndex = index
                try? await Task.sleep(for: .milliseconds(400))
                refresh()
            } catch {
                report(error)
            }
        }
    }

    func setMode(_ mode: Int) {
        if isDemoMode {
            modeIndex = UInt8(clamping: mode)
            presetNames = demoPresets(for: mode)
            activePresetIndex = 0
            updateDemoPlayback()
            return
        }
        Task {
            do {
                try await setValue(node: "netRemote.sys.mode", value: "\(mode)")
                modeIndex = UInt8(clamping: mode)
                activePresetIndex = nil
                invalidatePresets(clearNames: true)
                try? await Task.sleep(for: .milliseconds(600))
                refresh()
            } catch {
                report(error)
            }
        }
    }

    func applyVolume(_ newValue: Double, immediate: Bool = false) {
        let upper = max(1, maxVolume)
        let clamped = min(upper, max(0, Int(newValue.rounded())))
        volume = Double(clamped)

        if isDemoMode {
            if isMuted && clamped > 0 { isMuted = false }
            return
        }

        volumeSendTask?.cancel()
        volumeSendTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled else { return }
            do {
                try await setValue(node: "netRemote.sys.audio.volume", value: "\(clamped)")
                if isMuted && clamped > 0 {
                    try? await setValue(node: "netRemote.sys.audio.mute", value: "0")
                    isMuted = false
                }
            } catch {
                report(error)
            }
        }
    }

    func stepVolume(by delta: Int) {
        let upper = max(1, maxVolume)
        let current = min(upper, max(0, Int(volume.rounded())))
        let target = min(upper, max(0, current + delta))
        applyVolume(Double(target), immediate: true)
    }

    func fetchRawPresetsNow() {
        Task {
            _ = try? await getPresetNames()
        }
    }

    // MARK: - Demo Mode (no radio, no network)

    private static let demoInternetPresets: [Int: String] = [
        0: "Sunrise FM", 1: "Jazz Lounge", 2: "Classic Hits", 3: "News 24",
        4: "Indie Waves", 5: "Chill Radio", 6: "Rock Garage", 7: "Retro 80s"
    ]
    private static let demoDABPresets: [Int: String] = [
        0: "Digital Pop", 1: "Metro Talk", 2: "Smooth Sounds", 3: "Pulse Dance",
        4: "Heritage Radio", 5: "Kids Corner", 6: "Sport Live", 7: "Late Night"
    ]
    private static let demoSubtexts: [String] = [
        "The Sample Band – Morning Light",
        "Demo Quartet – Blue Hour",
        "Example Orchestra – Open Road",
        "Headlines at the top of the hour",
        "Studio Session – Paper Planes",
        "Ambient Collective – Slow Tide",
        "Test Pattern – Loud Garage",
        "The Placeholders – Neon Nights"
    ]

    private static let demoFMPresets: [Int: String] = [
        0: "88.1 City FM", 1: "90.3 Public Radio", 2: "93.5 Hits", 3: "96.7 Talk",
        4: "98.2 Classic Rock", 5: "101.1 Easy", 6: "103.4 Dance", 7: "106.0 Local"
    ]

    private func demoPresets(for mode: Int) -> [Int: String] {
        if mode == dabMode && mode != internetMode {
            return Self.demoDABPresets
        }
        if mode == modeValue(for: .fm) && mode != internetMode && mode != dabMode {
            return Self.demoFMPresets
        }
        return Self.demoInternetPresets
    }

    /// Fills in whatever the simulated radio doesn't have yet. User actions in
    /// demo mode change state directly, so this only supplies defaults.
    private func applyDemoState() {
        statusMessage = nil
        maxVolume = 20
        volume = min(Double(maxVolume), max(0, volume))
        if modeIndex == nil { modeIndex = UInt8(clamping: internetMode) }
        if presetNames.isEmpty { presetNames = demoPresets(for: Int(modeIndex ?? 0)) }
        if activePresetIndex == nil { activePresetIndex = 0 }
        updateDemoPlayback()
    }

    private func updateDemoPlayback() {
        guard isPoweredOn, let index = activePresetIndex, let name = presetNames[index] else {
            stationName = "— —"
            stationSubtext = " "
            return
        }
        stationName = name
        stationSubtext = Self.demoSubtexts[index % Self.demoSubtexts.count]
    }

    /// Called when demo mode is switched on or off: forget everything about the
    /// previous source (real radio or simulation) and start fresh.
    private func resetStateForSourceChange() {
        stopPolling()
        capsLoaded = false
        invalidatePresets(clearNames: true)
        activePresetIndex = nil
        modeIndex = nil
        isPoweredOn = true
        isMuted = false
        stationName = "— —"
        stationSubtext = " "
        statusMessage = nil
        startPolling()
    }

    // MARK: - Mode Auto-Detection (netRemote.sys.caps.validModes)

    func autoDetectModes() {
        guard !isDetectingModes, !isDemoMode else { return }
        isDetectingModes = true
        modesDetectedHost = cleanedHost
        Task {
            defer { isDetectingModes = false }
            do {
                if let steps = try? await getInt(node: "netRemote.sys.caps.volumeSteps"), steps > 1 {
                    maxVolume = steps - 1
                    capsLoaded = true
                    volume = min(Double(maxVolume), max(0, volume))
                }

                let modes = try await fetchValidModes()
                guard !modes.isEmpty else { return }

                let normalizedEntries: [(index: Int, combined: String, idText: String)] = modes.map { mode in
                    let idLower = mode.idText.lowercased()
                    let labelLower = mode.labelText.lowercased()
                    return (
                        index: mode.index,
                        combined: "\(idLower) \(labelLower)".trimmingCharacters(in: .whitespaces),
                        idText: idLower
                    )
                }

                // A source the radio doesn't list is marked unsupported (-1).
                let dabMatch = normalizedEntries.first(where: { $0.combined.contains("dab") })
                dabMode = dabMatch?.index ?? -1

                let internetMatch = normalizedEntries.first(where: {
                    $0.combined.contains("internet")
                        || $0.idText == "ir"
                        || $0.combined.split(whereSeparator: { !$0.isLetter }).contains("ir")
                })
                internetMode = internetMatch?.index ?? -1

                let fmMatch = normalizedEntries.first(where: {
                    $0.idText == "fm"
                        || $0.combined.split(whereSeparator: { !$0.isLetter }).contains("fm")
                })
                fmMode = fmMatch?.index ?? -1
            } catch {
                // Auto-detect is best-effort; failures are silent.
            }
        }
    }

    private struct ValidModeEntry {
        let index: Int
        let idText: String
        let labelText: String
    }

    private func fetchValidModes() async throws -> [ValidModeEntry] {
        let listURLString = "\(baseURL())/LIST_GET_NEXT/netRemote.sys.caps.validModes/-1?pin=\(pin)&maxItems=20"
        let listData = try await fetch(listURLString, label: "LIST netRemote.sys.caps.validModes")
        let parsed = ValidModesParser.parse(data: listData) { [self] raw in
            self.decodeHTMLEntities(raw)
        }
        if !parsed.isEmpty {
            return parsed
        }

        let getURLString = "\(baseURL())/GET/netRemote.sys.caps.validModes?pin=\(pin)"
        let getData = try await fetch(getURLString, label: "GET netRemote.sys.caps.validModes")
        return ValidModesParser.parse(data: getData) { [self] raw in
            self.decodeHTMLEntities(raw)
        }
    }

    private final class ValidModesParser: NSObject, XMLParserDelegate {
        private var entries: [ValidModeEntry] = []
        private var currentIndex: Int = 0
        private var currentID: String = ""
        private var currentLabel: String = ""
        private var activeFieldName: String?
        private var capturingText = false
        private var buffer = ""
        private let transform: (String) -> String

        init(transform: @escaping (String) -> String) {
            self.transform = transform
        }

        static func parse(data: Data, transform: @escaping (String) -> String) -> [ValidModeEntry] {
            let parser = XMLParser(data: data)
            let delegate = ValidModesParser(transform: transform)
            parser.delegate = delegate
            parser.parse()
            return delegate.entries
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "item" {
                if let keyStr = attributeDict["key"], let key = Int(keyStr) {
                    currentIndex = key
                }
                currentID = ""
                currentLabel = ""
                activeFieldName = nil
            } else if elementName == "field" {
                activeFieldName = attributeDict["name"]?.lowercased()
            } else if activeFieldName != nil && (elementName == "c8_array" || elementName == "c8_string") {
                capturingText = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturingText {
                buffer += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if capturingText && (elementName == "c8_array" || elementName == "c8_string") {
                let decoded = transform(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if activeFieldName == "id" {
                    currentID = decoded
                } else if activeFieldName == "label" || activeFieldName == "name" {
                    currentLabel = decoded
                } else if currentLabel.isEmpty {
                    currentLabel = decoded
                }
                capturingText = false
                buffer = ""
            } else if elementName == "field" {
                activeFieldName = nil
            } else if elementName == "item" {
                entries.append(ValidModeEntry(index: currentIndex, idText: currentID, labelText: currentLabel))
                currentIndex += 1
            }
        }
    }

    // MARK: - LAN Discovery (direct FSAPI probe of the local subnet; no multicast needed)

    func scanForRadios() {
        scanTask?.cancel()
        isScanning = true
        scanStatusMessage = "Scanning local network..."
        discoveredRadios = []

        let currentHost = host
        let currentPin = pin

        // PHASE 1: only the most recent scan owns the isScanning flag, and it
        // always resets it when finished or cancelled.
        let scanID = UUID()
        currentScanID = scanID

        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.currentScanID == scanID {
                    self.isScanning = false
                }
            }

            // One shared session for the whole sweep instead of one per probe.
            let sweepConfig = URLSessionConfiguration.ephemeral
            sweepConfig.timeoutIntervalForRequest = 0.4
            sweepConfig.timeoutIntervalForResource = 0.6
            let sweepSession = URLSession(configuration: sweepConfig)
            defer { sweepSession.finishTasksAndInvalidate() }

            let candidates = self.candidateSubnetHosts(currentHost: currentHost)
            var httpResults: [DiscoveredRadio] = []

            let batchSize = 32
            var startIndex = 0
            while startIndex < candidates.count && !Task.isCancelled {
                let endIndex = min(startIndex + batchSize, candidates.count)
                let batch = Array(candidates[startIndex..<endIndex])
                let foundInBatch = await withTaskGroup(of: DiscoveredRadio?.self) { group in
                    for ip in batch {
                        group.addTask {
                            await self.probeFSAPIRadio(host: ip, pin: currentPin, session: sweepSession)
                        }
                    }
                    var batchMatches: [DiscoveredRadio] = []
                    for await match in group {
                        if let match {
                            batchMatches.append(match)
                        }
                    }
                    return batchMatches
                }
                httpResults.append(contentsOf: foundInBatch)
                startIndex = endIndex
            }

            guard !Task.isCancelled else { return }

            let combined = httpResults.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            self.discoveredRadios = combined
            // If the radio we're already configured for turned up, pick up its name.
            if let current = combined.first(where: { $0.host == self.cleanedHost }) {
                self.rememberRadio(current)
            }
            self.scanStatusMessage = combined.isEmpty
                ? "No radios found on LAN."
                : "Found \(combined.count) radio(s)."
        }
    }

    private func probeFSAPIRadio(host candidateHost: String, pin: String, session: URLSession) async -> DiscoveredRadio? {
        let cleaned = candidateHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
        guard !cleaned.isEmpty,
              let url = URL(string: "http://\(cleaned)/fsapi/GET/netRemote.sys.info.friendlyName?pin=\(pin)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let status = extractFirstTagValue(from: data, tags: ["status"]), status == "FS_OK" else {
                return nil
            }
            let name = extractFirstTagValue(from: data, tags: ["c8_array", "c8_string"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let hasName = (name?.isEmpty == false)
            let resolvedName = hasName ? name! : "Frontier Silicon Radio (\(cleaned))"
            return DiscoveredRadio(id: cleaned, name: resolvedName, host: cleaned, port: 80, hasRealName: hasName)
        } catch {
            return nil
        }
    }

    private func candidateSubnetHosts(currentHost: String) -> [String] {
        var hosts: [String] = []
        let cleaned = currentHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
        if !cleaned.isEmpty {
            hosts.append(cleaned)
        }

        if let localIP = Self.localIPv4String() {
            let parts = localIP.split(separator: ".")
            if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) {
                let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
                for lastOctet in 1...254 {
                    let candidate = "\(prefix).\(lastOctet)"
                    if candidate != cleaned {
                        hosts.append(candidate)
                    }
                }
            }
        }
        return hosts
    }

    private static func localIPv4String() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            if isUp && !isLoopback,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &sin.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let ipStr = String(cString: ipBuf)
                let ifName = String(cString: current.pointee.ifa_name)
                if ifName == "en0" {
                    return ipStr
                }
                if fallback == nil {
                    fallback = ipStr
                }
            }
        }
        return fallback
    }

    // MARK: - FSAPI Transport

    private func baseURL() -> String {
        "http://\(cleanedHost)/fsapi"
    }

    private func recordLog(label: String, urlString: String, data: Data) {
        guard isDebugLoggingEnabled else { return }
        let raw = String(data: data, encoding: .utf8) ?? "<Non-UTF8 data: \(data.count) bytes>"
        let timeStr = Date.now.formatted(date: .omitted, time: .standard)
        let entry = DebugLogEntry(timestamp: timeStr, label: label, urlString: urlString, rawXML: raw)
        debugLogs.insert(entry, at: 0)
        if debugLogs.count > 60 {
            debugLogs.removeLast(debugLogs.count - 60)
        }
    }

    /// Single choke point for all FSAPI requests: uses the short-timeout session.
    private func fetch(_ urlString: String, label: String) async throws -> Data {
        guard !isDemoMode, !cleanedHost.isEmpty else { throw RadioError.noHost }
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(from: url)
        recordLog(label: label, urlString: urlString, data: data)
        return data
    }

    private func getString(node: String) async throws -> String? {
        let data = try await fetch("\(baseURL())/GET/\(node)?pin=\(pin)", label: "GET \(node)")
        return extractFirstTagValue(from: data, tags: ["c8_array", "c8_string"])
    }

    private func getInt(node: String) async throws -> Int? {
        let data = try await fetch("\(baseURL())/GET/\(node)?pin=\(pin)", label: "GET \(node)")
        if let raw = extractFirstTagValue(from: data, tags: ["u8", "u16", "u32", "s32", "value"]) {
            return Int(raw)
        }
        return nil
    }

    private func getU8(node: String) async throws -> UInt8? {
        guard let intValue = try await getInt(node: node) else { return nil }
        return UInt8(clamping: intValue)
    }

    private func getPresetNames() async throws -> [Int: String] {
        try? await setValue(node: "netRemote.nav.state", value: "1")
        let data: Data
        do {
            data = try await fetch(
                "\(baseURL())/LIST_GET_NEXT/netRemote.nav.presets/-1?pin=\(pin)&maxItems=10",
                label: "LIST netRemote.nav.presets"
            )
        } catch {
            try? await setValue(node: "netRemote.nav.state", value: "0")
            throw error
        }
        try? await setValue(node: "netRemote.nav.state", value: "0")
        return PresetListParser.parse(data: data) { [self] raw in
            self.decodeHTMLEntities(raw)
        }
    }

    private func setValue(node: String, value: String) async throws {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        let data = try await fetch(
            "\(baseURL())/SET/\(node)?pin=\(pin)&value=\(encoded)",
            label: "SET \(node)=\(value)"
        )
        if let status = extractFirstTagValue(from: data, tags: ["status"]), status != "FS_OK" {
            throw NSError(domain: "FSAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Radio returned \(status)"])
        }
    }

    private func extractFirstTagValue(from data: Data, tags: [String]) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        for tag in tags {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            if let startRange = xml.range(of: open),
               let endRange = xml.range(of: close, range: startRange.upperBound..<xml.endIndex) {
                let raw = String(xml[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return decodeHTMLEntities(raw)
            }
        }
        return nil
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&"), let data = text.data(using: .utf8) else {
            return text
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
        }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private final class PresetListParser: NSObject, XMLParserDelegate {
        private var result: [Int: String] = [:]
        private var currentIndex: Int = 0
        private var inNameField = false
        private var capturingText = false
        private var buffer = ""
        private let transform: (String) -> String

        init(transform: @escaping (String) -> String) {
            self.transform = transform
        }

        static func parse(data: Data, transform: @escaping (String) -> String) -> [Int: String] {
            let parser = XMLParser(data: data)
            let delegate = PresetListParser(transform: transform)
            parser.delegate = delegate
            parser.parse()
            return delegate.result
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "item" {
                if let keyStr = attributeDict["key"], let key = Int(keyStr) {
                    currentIndex = key
                }
                inNameField = false
            } else if elementName == "field", attributeDict["name"] == "name" {
                inNameField = true
            } else if inNameField && (elementName == "c8_array" || elementName == "c8_string") {
                capturingText = true
                buffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturingText {
                buffer += string
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if capturingText && (elementName == "c8_array" || elementName == "c8_string") {
                let decoded = transform(buffer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty {
                    result[currentIndex] = decoded
                }
                capturingText = false
                buffer = ""
            } else if elementName == "field" {
                inNameField = false
            } else if elementName == "item" {
                currentIndex += 1
            }
        }
    }
}

/// Keeps a button's own look (no system styling) but gives the press feedback
/// the plain style removes: it shrinks and dims slightly while held down.
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GroupedCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

private extension View {
    func groupedCard() -> some View {
        modifier(GroupedCardModifier())
    }

    /// PHASE 2: dim and disable a section (used while the radio is in standby).
    func dimmed(when condition: Bool) -> some View {
        self
            .disabled(condition)
            .opacity(condition ? 0.45 : 1.0)
    }
}

struct ContentView: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @Environment(\.scenePhase) private var scenePhase
    @State private var radio = RadioController()
    @State private var showingSettings = false
    @State private var showingDebug = false
    // PHASE 2: haptics fire from user taps only, never from polled state changes.
    @State private var feedbackTick = 0
    // Host + PIN as they were when Settings opened, to detect real changes.
    @State private var settingsSnapshot = ""
    @State private var advancedExpanded = false

    private var sliderUpperBound: Double {
        Double(max(1, radio.maxVolume))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // 1. Now Playing Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Label(
                                radio.isPoweredOn ? "Powered On" : "Standby",
                                systemImage: radio.isPoweredOn ? "dot.radiowaves.left.and.right" : "power"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(radio.isPoweredOn ? .green : .secondary)

                            if radio.isDemoMode {
                                Text("DEMO")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                            }

                            if let sourceLabel = radio.activeSourceLabel {
                                Text(sourceLabel)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }

                            Spacer()
                        }

                        Text(radio.stationName)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(radio.stationSubtext.isEmpty ? " " : radio.stationSubtext)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2, reservesSpace: true)
                            .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .topLeading)
                    }
                    .groupedCard()

                    // 2. Volume card
                    // The header sits outside the card, like Presets and Source;
                    // .groupedCard() wraps only the controls.
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Volume")
                                .font(.headline)
                            Spacer()
                            Text(radio.isMuted ? "Muted" : "\(Int(radio.volume.rounded())) / \(max(1, radio.maxVolume))")
                                .font(.subheadline.monospacedDigit().weight(.medium))
                                .foregroundStyle(radio.isMuted ? .red : .secondary)
                        }
                        .padding(.horizontal, 2)

                        HStack(spacing: 10) {
                            Button {
                                feedbackTick += 1
                                radio.toggleMute()
                            } label: {
                                Image(systemName: radio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(radio.isMuted ? .red : Color.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        radio.isMuted ? Color.red.opacity(0.14) : Color.accentColor.opacity(0.12),
                                        in: Circle()
                                    )
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel(radio.isMuted ? "Unmute" : "Mute")

                            Button {
                                feedbackTick += 1
                                radio.stepVolume(by: -1)
                            } label: {
                                Image(systemName: "speaker.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Volume down")
                            .disabled(Int(radio.volume.rounded()) <= 0)
                            .opacity(Int(radio.volume.rounded()) <= 0 ? 0.45 : 1.0)

                            Slider(
                                value: Binding(
                                    get: { min(sliderUpperBound, max(0, radio.volume)) },
                                    set: { newValue in
                                        radio.applyVolume(newValue, immediate: !radio.isAdjustingVolume)
                                    }
                                ),
                                in: 0...sliderUpperBound,
                                step: 1,
                                onEditingChanged: { editing in
                                    radio.isAdjustingVolume = editing
                                    if !editing {
                                        radio.applyVolume(radio.volume, immediate: true)
                                    }
                                }
                            )
                            .tint(radio.isMuted ? .secondary : .accentColor)
                            .opacity(radio.isMuted ? 0.65 : 1.0)
                            .accessibilityLabel("Volume")
                            .accessibilityValue(
                                radio.isMuted
                                    ? "Muted"
                                    : "\(Int(radio.volume.rounded())) of \(max(1, radio.maxVolume))"
                            )

                            Button {
                                feedbackTick += 1
                                radio.stepVolume(by: 1)
                            } label: {
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("Volume up")
                            .disabled(Int(radio.volume.rounded()) >= max(1, radio.maxVolume))
                            .opacity(Int(radio.volume.rounded()) >= max(1, radio.maxVolume) ? 0.45 : 1.0)
                        }
                        .groupedCard()
                    }
                    .dimmed(when: !radio.isPoweredOn)

                    // 3. Presets 1-8
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Presets")
                            .font(.headline)
                            .padding(.horizontal, 2)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(0..<8, id: \.self) { index in
                                let title = radio.presetNames[index] ?? "Preset \(index + 1)"
                                let active = radio.activePresetIndex == index

                                Button {
                                    feedbackTick += 1
                                    radio.selectPreset(index)
                                } label: {
                                    HStack(spacing: 6) {
                                        if active {
                                            Image(systemName: "waveform")
                                                .font(.caption.weight(.bold))
                                        }
                                        Text(title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .padding(.horizontal, 10)
                                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                                    .background(
                                        active
                                            ? Color.accentColor.opacity(0.16)
                                            : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                active ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07),
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                    }
                    .dimmed(when: !radio.isPoweredOn)

                    // 4. Source / Mode Switcher
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Source")
                            .font(.headline)
                            .padding(.horizontal, 2)

                        let sources = radio.visibleSources
                        if sources.isEmpty {
                            Text("No sources enabled. Choose which ones to show in Settings.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 2)
                        } else {
                            HStack(spacing: 12) {
                                ForEach(sources) { source in
                                    sourceButton(source)
                                }
                            }
                        }
                    }
                    .dimmed(when: !radio.isPoweredOn)

                    if let statusMessage = radio.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding()
            }
            // Pull down to reload everything, including preset names. Run in an
            // unstructured Task so state updates during the refresh can't cancel it.
            .refreshable {
                await Task { await radio.forceRefresh() }.value
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(radio.deviceTitle)
            .sensoryFeedback(.selection, trigger: feedbackTick)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        feedbackTick += 1
                        radio.togglePower()
                    } label: {
                        Image(systemName: "power")
                            .foregroundStyle(radio.isPoweredOn ? .green : .red)
                    }
                    .accessibilityLabel("Power")
                    .accessibilityValue(radio.isPoweredOn ? "On" : "Standby")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if radio.showDebugButton {
                            Button {
                                showingDebug = true
                            } label: {
                                Image(systemName: "ant")
                            }
                            .accessibilityLabel("FSAPI XML debug")
                        }
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: settingsDidDismiss) {
                @Bindable var boundRadio = radio
                NavigationStack {
                    Form {
                        Section("Connection") {
                            LabeledContent("Radio IP") {
                                TextField("Scan or enter IP", text: $boundRadio.host)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            LabeledContent("Radio PIN") {
                                TextField("1234", text: $boundRadio.pin)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numberPad)
                            }
                            Button {
                                radio.scanForRadios()
                            } label: {
                                HStack {
                                    Label("Scan for Radios", systemImage: "antenna.radiowaves.left.and.right.circle")
                                    Spacer()
                                    if radio.isScanning {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(radio.isScanning || radio.isDemoMode)

                            if let scanStatus = radio.scanStatusMessage {
                                Text(scanStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(radio.discoveredRadios) { device in
                                Button {
                                    boundRadio.host = device.host
                                    boundRadio.rememberRadio(device)
                                    radio.autoDetectModes()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .foregroundStyle(.primary)
                                            Text(device.displayHost)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if boundRadio.host == device.host {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                            }
                        }

                        Section {
                            let supported = RadioSource.allCases.filter { radio.isSupported($0) }
                            if supported.isEmpty {
                                Text("No sources detected yet. Connect to your radio to see what it supports.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(supported) { source in
                                    Toggle(isOn: Binding(
                                        get: { radio.isEnabled(source) },
                                        set: { radio.setEnabled(source, $0) }
                                    )) {
                                        Label(source.title, systemImage: source.systemImage)
                                    }
                                }
                            }
                        } header: {
                            Text("Sources")
                        } footer: {
                            Text("Choose which sources appear on the main screen. Only sources your radio supports are listed.")
                        }

                        Section("Appearance") {
                            Picker("Theme", selection: $appearanceMode) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Section {
                            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                                Toggle("Demo Mode", isOn: $boundRadio.isDemoMode)
                                Text("Simulates a radio so you can try the app without any hardware. No network requests are made while Demo Mode is on.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Toggle("Show FSAPI XML Debug Button", isOn: $boundRadio.showDebugButton)
                                Text("Shows the ant icon in the toolbar for inspecting raw radio responses.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    radio.autoDetectModes()
                                } label: {
                                    HStack {
                                        Label("Detect Modes from Radio", systemImage: "wand.and.stars")
                                        Spacer()
                                        if radio.isDetectingModes {
                                            ProgressView()
                                        }
                                    }
                                }
                                .disabled(radio.isDetectingModes || !radio.hasHost || radio.isDemoMode)

                                LabeledContent("Internet Mode") {
                                    TextField("0", value: $boundRadio.internetMode, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numbersAndPunctuation)
                                }
                                LabeledContent("DAB Mode") {
                                    TextField("5", value: $boundRadio.dabMode, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numbersAndPunctuation)
                                }
                                LabeledContent("FM Mode") {
                                    TextField("-1", value: $boundRadio.fmMode, format: .number)
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.numbersAndPunctuation)
                                }
                                Text("Mode numbers are normally detected automatically. Use -1 for a source the radio doesn't have.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section("About") {
                            LabeledContent("App", value: AppInfo.name)
                            LabeledContent("Version", value: AppInfo.version)
                            LabeledContent("Build", value: AppInfo.build)
                            LabeledContent("Build Date", value: AppInfo.buildDateText)
                            ShareLink(item: AppInfo.summary) {
                                Label("Share Version Info", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .navigationTitle("Radio Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingSettings = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingDebug) {
                DebugXMLView(radio: radio)
            }
            .onAppear {
                applyAppearance(appearanceMode)
                radio.startPolling()
                // PHASE 1: first launch has no host yet, so go straight to Settings.
                if !radio.hasHost {
                    showingSettings = true
                }
            }
            .onChange(of: appearanceMode) { _, newMode in
                applyAppearance(newMode)
            }
            .onChange(of: showingSettings) { _, isShowing in
                if isShowing {
                    settingsSnapshot = "\(radio.cleanedHost)|\(radio.pin)"
                }
            }
            .onDisappear { radio.stopPolling() }
            // PHASE 2: don't poll while backgrounded; refresh immediately on return.
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active: radio.resume()
                case .background: radio.stopPolling()
                default: break
                }
            }
        }
    }

    /// Runs whenever Settings closes (Done button or swipe down). Only a changed
    /// host or PIN justifies dropping presets and reconnecting; otherwise keep
    /// everything as is and just poll again.
    private func settingsDidDismiss() {
        let current = "\(radio.cleanedHost)|\(radio.pin)"
        if current != settingsSnapshot {
            radio.reconnect()
        } else {
            radio.refresh()
        }
    }

    /// Sets the appearance on every window so sheets follow along and
    /// "Follow System" really resets to the phone's setting.
    private func applyAppearance(_ mode: AppearanceMode) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = mode.interfaceStyle
            }
        }
    }

    private func sourceButton(_ source: RadioSource) -> some View {
        let mode = radio.modeValue(for: source) ?? 0
        let isSelected = radio.modeIndex.map { Int($0) == mode } ?? false
        return Button {
            feedbackTick += 1
            radio.setMode(mode)
        } label: {
            Label(source.title, systemImage: source.systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct DebugXMLView: View {
    @Bindable var radio: RadioController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Capture") {
                    Toggle("Log Raw XML Responses", isOn: $radio.isDebugLoggingEnabled)
                    Button {
                        radio.fetchRawPresetsNow()
                    } label: {
                        Label("Fetch Presets XML Now", systemImage: "list.bullet.rectangle")
                    }
                    Button(role: .destructive) {
                        radio.clearLogs()
                    } label: {
                        Label("Clear Log (\(radio.debugLogs.count))", systemImage: "trash")
                    }
                }

                Section("Recent FSAPI Responses") {
                    if radio.debugLogs.isEmpty {
                        Text("No XML captured yet. Enable logging, then tap Refresh, switch modes, or fetch presets.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(radio.debugLogs) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.label)
                                        .font(.caption.bold())
                                    Spacer()
                                    Text(entry.timestamp)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.urlString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                ScrollView(.horizontal, showsIndicators: true) {
                                    Text(entry.rawXML)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("FSAPI XML Debug")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
