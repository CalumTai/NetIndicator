// Network state: which link carries traffic (via NWPathMonitor) plus Wi-Fi control (via CoreWLAN).
import AppKit
import CoreLocation
import CoreWLAN
import Network
import SystemConfiguration
import os

/// Read with: log show --last 10m --predicate 'subsystem == "local.netindicator"'
private let wifiLog = Logger(subsystem: "local.netindicator", category: "wifi")

enum SecurityKind: Equatable {
    case open, wep, wpa, wpa2, wpa3, enterprise

    var needsPassword: Bool { self != .open }

    /// Completes "The Wi-Fi network “X” requires …".
    var requirement: String {
        switch self {
        case .open: return "no password"
        case .wep: return "a WEP password"
        case .wpa: return "a WPA password"
        case .wpa2: return "a WPA2 password"
        case .wpa3: return "a WPA3 password"
        case .enterprise: return "WPA2 enterprise credentials"
        }
    }

    var minimumPasswordLength: Int {
        switch self {
        case .open: return 0
        case .enterprise: return 1
        case .wep: return 5
        case .wpa, .wpa2, .wpa3: return 8
        }
    }
}

struct WiFiNetwork: Identifiable, Equatable {
    let ssid: String
    let rssi: Int
    let security: SecurityKind
    var id: String { ssid }
}

struct EthernetLink: Identifiable, Equatable {
    let bsdName: String
    let displayName: String
    let ipv4: String?
    let inUse: Bool
    var id: String { bsdName }
}

/// Radio details for the connected Wi-Fi network (none of these need Location access).
struct WiFiStats: Equatable {
    let transmitRate: Double   // negotiated link rate, Mbps
    let rssi: Int              // dBm
    let noise: Int             // dBm
    let channel: Int?
    let band: String?
    let width: String?
    let standard: String

    var channelDescription: String {
        [channel.map { "Channel \($0)" }, band, width].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Negotiated Ethernet link, parsed from ifconfig's "media: autoselect (2500Base-T <full-duplex>)".
struct EthernetMedia: Equatable {
    let speed: String?
    let duplex: String?

    init(_ description: String) {
        let token = description.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let digits = Double(token.prefix { $0.isNumber }) ?? 0
        let mbps = token.contains("gbase") ? digits * 1000 : digits
        if mbps >= 1000 {
            let gbps = mbps / 1000
            speed = gbps == gbps.rounded() ? "\(Int(gbps)) Gbps" : String(format: "%.1f Gbps", gbps)
        } else {
            speed = mbps > 0 ? "\(Int(mbps)) Mbps" : nil
        }
        duplex = description.contains("full-duplex") ? "Full duplex" : description.contains("half-duplex") ? "Half duplex" : nil
    }
}

struct PasswordRequest {
    let ssid: String
    let security: SecurityKind
    var message: String?
}

enum SystemSettings {
    static let wifi = "com.apple.wifi-settings-extension"
    static let network = "com.apple.Network-Settings.extension"
    static let locationPrivacy = "com.apple.preference.security?Privacy_LocationServices"

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}

final class NetworkModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Link { case ethernet, wifi, none }

    @Published private(set) var primary: Link = .none
    /// BSD name (en0, en10…) of the link carrying traffic; the speed graph follows it.
    @Published private(set) var primaryInterface: String?
    @Published private(set) var ethernetLinks: [EthernetLink] = []
    @Published private(set) var ethernetMedia: [String: EthernetMedia] = [:]
    @Published private(set) var wifiStats: WiFiStats?
    @Published private(set) var vpnName: String?
    @Published private(set) var wifiOn = false
    @Published private(set) var currentSSID: String?
    @Published private(set) var currentRSSI: Int?
    @Published private(set) var hotspots: [WiFiNetwork] = []
    @Published private(set) var knownNetworks: [WiFiNetwork] = []
    @Published private(set) var otherNetworks: [WiFiNetwork] = []
    @Published private(set) var isScanning = false
    @Published private(set) var joiningSSID: String?
    @Published private(set) var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var showsOtherNetworks = false

    var onPasswordNeeded: ((PasswordRequest) -> Void)?
    var onJoinFailed: ((_ ssid: String, _ message: String) -> Void)?

    /// macOS hides Wi-Fi network names from apps without Location access.
    var locationAuthorized: Bool { locationStatus == .authorizedAlways }

    let traffic = TrafficMonitor()
    let latency = LatencyMonitor()
    let quality = QualityTest()

    private let pathMonitor = NWPathMonitor()
    private let locationManager = CLLocationManager()
    private let wifiQueue = DispatchQueue(label: "NetIndicator.wifi")
    private var scanned: [String: CWNetwork] = [:]
    private var knownSSIDs: [String] = []
    /// iPhone/iPad hotspots heard in a fresh scan or a targeted check, with when they were last heard.
    private var hotspotSightings: [String: (network: CWNetwork, seen: Date)] = [:]
    private var probeQueue: [String] = []
    private var probeTimer: Timer?
    private var tunnelActive = false
    private var scanTimer: Timer?
    private var statsTimer: Timer?
    private var isDemo = false

    func start(demo: Bool = false) {
        if demo { return loadDemo() }
        traffic.start()
        locationManager.delegate = self
        locationStatus = locationManager.authorizationStatus
        wifiLog.notice("started, location status \(self.locationStatus.rawValue) (3 = allowed, 2 = denied, 0 = not asked)")
        if locationStatus == .notDetermined { requestLocationAccess() }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.apply(path) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "NetIndicator.path"))
        refreshWiFi()
        refreshKnownNetworks()
    }

    // MARK: Menu lifecycle

    func menuOpened() {
        guard !isDemo else { return }
        refreshWiFi()
        refreshKnownNetworks()
        refreshVPNName()
        loadCachedScan()
        scan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.scan() }
        traffic.isObserved = true
        latency.start()
        refreshWiFiStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshWiFiStats() }
    }

    func menuClosed() {
        scanTimer?.invalidate()
        scanTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        probeTimer?.invalidate()
        probeTimer = nil
        probeQueue = []
        traffic.isObserved = false
        latency.stop()
    }

    // MARK: Which link is in use

    private func apply(_ path: NWPath) {
        let interfaces = path.status == .satisfied ? path.availableInterfaces : []
        // availableInterfaces is in routing-preference order. A VPN (utun, type .other) sits on top,
        // so skip it and take the first physical link — that is what actually carries the traffic.
        let physical = interfaces.first { $0.type == .wiredEthernet || $0.type == .wifi }
        primary = physical.map { $0.type == .wiredEthernet ? .ethernet : .wifi } ?? .none
        primaryInterface = physical?.name
        ethernetLinks = interfaces.filter { $0.type == .wiredEthernet }.map {
            EthernetLink(bsdName: $0.name, displayName: Self.displayName(of: $0.name),
                         ipv4: Self.ipv4Address(of: $0.name), inUse: $0 == physical)
        }
        tunnelActive = interfaces.first?.type == .other
        latency.setTarget(router: physical.flatMap { Self.routerAddress(for: $0.name) }, interface: physical?.name)
        refreshEthernetMedia()
        refreshVPNName()
        refreshWiFi()
    }

    private func refreshEthernetMedia() {
        let names = ethernetLinks.map(\.bsdName)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var media: [String: EthernetMedia] = [:]
            for name in names {
                let output = Self.run("/sbin/ifconfig", [name]).output
                guard let line = output.split(separator: "\n").first(where: { $0.contains("media:") }),
                      let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
                media[name] = EthernetMedia(String(line[line.index(after: open)..<close]))
            }
            DispatchQueue.main.async { self?.ethernetMedia = media }
        }
    }

    /// The router for one interface, from its service's IPv4 state — not the global default route,
    /// which points into the VPN tunnel while a VPN is on.
    private static func routerAddress(for interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NetIndicator" as CFString, nil, nil),
              let values = SCDynamicStoreCopyMultiple(store, nil, ["State:/Network/Service/[^/]+/IPv4"] as CFArray) as? [String: Any]
        else { return nil }
        for case let entry as [String: Any] in values.values where entry["InterfaceName"] as? String == interface {
            if let router = entry["Router"] as? String { return router }
        }
        return nil
    }

    private func refreshVPNName() {
        guard tunnelActive else { vpnName = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Lines look like: * (Connected)  <UUID> VPN (ch.protonvpn.mac) "ProtonVPN"  [VPN:…]
            let line = Self.run("/usr/sbin/scutil", ["--nc", "list"]).output
                .split(separator: "\n").first { $0.contains("(Connected)") }
            let quoted = line?.split(separator: "\"", omittingEmptySubsequences: false)
            let name = (quoted?.count ?? 0) >= 3 ? quoted.map { String($0[1]) } : nil
            DispatchQueue.main.async {
                guard let self, self.tunnelActive else { return }
                self.vpnName = name ?? "VPN"
            }
        }
    }

    // MARK: Wi-Fi state

    func refreshWiFi() {
        guard !isDemo else { return }
        wifiQueue.async { [weak self] in
            let iface = CWWiFiClient.shared().interface()
            let on = iface?.powerOn() ?? false
            let ssid = iface?.ssid()
            let rssi = iface?.rssiValue() ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.wifiOn = on
                self.currentSSID = ssid
                self.currentRSSI = rssi == 0 ? nil : rssi
                if !on { self.scanned = [:] }
                self.rebuildLists()
            }
        }
    }

    private func refreshWiFiStats() {
        wifiQueue.async { [weak self] in
            var stats: WiFiStats?
            // rssiValue is 0 when not associated with any network.
            if let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 {
                let channel = iface.wlanChannel()
                stats = WiFiStats(transmitRate: iface.transmitRate(), rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                                  channel: channel?.channelNumber, band: channel.flatMap { Self.bandName($0.channelBand) },
                                  width: channel.flatMap { Self.widthName($0.channelWidth) },
                                  standard: Self.standardName(iface.activePHYMode(), band: channel?.channelBand))
            }
            DispatchQueue.main.async {
                guard let self, self.wifiStats != stats else { return }
                self.wifiStats = stats
            }
        }
    }

    private static func bandName(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }

    private static func widthName(_ width: CWChannelWidth) -> String? {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return nil
        }
    }

    private static func standardName(_ mode: CWPHYMode, band: CWChannelBand?) -> String {
        switch mode {
        case .mode11ax: return band == .band6GHz ? "Wi-Fi 6E (802.11ax)" : "Wi-Fi 6 (802.11ax)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11a: return "802.11a"
        case .mode11g: return "802.11g"
        case .mode11b: return "802.11b"
        default: return "Wi-Fi"
        }
    }

    private func refreshKnownNetworks() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let device = CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
            // First line is a header; each network follows on its own tab-indented line.
            let ssids = Self.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device]).output
                .split(separator: "\n").dropFirst()
                .filter { $0.hasPrefix("\t") }
                .map { String($0.dropFirst()) }
            wifiLog.notice("saved networks: \(ssids.count)")
            DispatchQueue.main.async {
                self?.knownSSIDs = ssids
                self?.rebuildLists()
            }
        }
    }

    func setWiFiPower(_ on: Bool) {
        wifiOn = on
        guard !isDemo else { return }
        if !on { scanned = [:]; rebuildLists() }
        wifiQueue.async { [weak self] in
            let iface = CWWiFiClient.shared().interface()
            do {
                try iface?.setPower(on)
                wifiLog.notice("power \(on ? "on" : "off"): CoreWLAN ok")
            } catch {
                let fallback = Self.run("/usr/sbin/networksetup", ["-setairportpower", iface?.interfaceName ?? "en0", on ? "on" : "off"])
                wifiLog.error("power \(on ? "on" : "off"): CoreWLAN failed (\(error.localizedDescription, privacy: .public)); networksetup exit \(fallback.status): \(fallback.output, privacy: .public)")
            }
            wifiLog.notice("power is now \(iface?.powerOn() == true ? "on" : "off")")
            DispatchQueue.main.async {
                self?.refreshWiFi()
                // Give the radio a moment to come up before scanning.
                if on { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.scan() } }
            }
        }
    }

    // MARK: Scanning

    private func loadCachedScan() {
        guard locationAuthorized else { return }
        wifiQueue.async { [weak self] in
            let results = CWWiFiClient.shared().interface()?.cachedScanResults()
            Self.logScan("cached scan", results)
            // Cached results can be minutes old, so they never count as a hotspot being in range.
            DispatchQueue.main.async { if let results { self?.ingest(results, fresh: false) } }
        }
    }

    func scan() {
        guard !isDemo, wifiOn, locationAuthorized, !isScanning else { return }
        isScanning = true
        wifiQueue.async { [weak self] in
            var results: Set<CWNetwork>?
            do {
                results = try CWWiFiClient.shared().interface()?.scanForNetworks(withName: nil)
                Self.logScan("scan", results)
            } catch {
                wifiLog.error("scan failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async {
                self?.isScanning = false
                if let results { self?.ingest(results, fresh: true) }
            }
        }
    }

    /// Logs counts only; "with names" stays 0 until Location access is granted.
    private static func logScan(_ label: String, _ results: Set<CWNetwork>?) {
        let total = results?.count ?? 0
        let named = results?.filter { $0.ssid != nil }.count ?? 0
        wifiLog.notice("\(label, privacy: .public): \(total) networks, \(named) with names")
    }

    private func ingest(_ results: Set<CWNetwork>, fresh: Bool) {
        var strongest: [String: CWNetwork] = [:]
        for network in results {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            if let existing = strongest[ssid], existing.rssiValue >= network.rssiValue { continue }
            strongest[ssid] = network
        }
        scanned = strongest
        if fresh {
            let now = Date()
            for (ssid, network) in strongest where Self.isHotspotName(ssid) {
                hotspotSightings[ssid] = (network, now)
            }
            // iPhones don't always broadcast while their hotspot is on, so ask for each saved one the scan missed.
            scheduleHotspotChecks(knownSSIDs.filter { Self.isHotspotName($0) && strongest[$0] == nil })
        }
        rebuildLists()
    }

    private func rebuildLists() {
        guard wifiOn else {
            hotspots = []; knownNetworks = []; otherNetworks = []
            return
        }
        let known = Set(knownSSIDs)
        let now = Date()
        hotspotSightings = hotspotSightings.filter { now.timeIntervalSince($0.value.seen) < Self.hotspotFreshness }

        // Personal Hotspot: hotspots you can join right now without typing anything — saved (password on file)
        // or open — heard recently with a usable signal. Anything else iPhone-like falls through to Other Networks.
        var connectable = hotspotSightings.compactMap { ssid, sighting -> WiFiNetwork? in
            let security = Self.securityKind(of: sighting.network)
            guard sighting.network.rssiValue > Self.minimumHotspotRSSI,
                  known.contains(ssid) || security == .open || ssid == currentSSID else { return nil }
            return WiFiNetwork(ssid: ssid, rssi: sighting.network.rssiValue, security: security)
        }
        if let current = currentSSID, Self.isHotspotName(current), !connectable.contains(where: { $0.ssid == current }) {
            connectable.append(WiFiNetwork(ssid: current, rssi: currentRSSI ?? -50, security: .wpa2))
        }
        hotspots = connectable.sorted { $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending }
        let hotspotNames = Set(hotspots.map(\.ssid))

        var networks = scanned.values.compactMap { network -> WiFiNetwork? in
            guard let ssid = network.ssid, !hotspotNames.contains(ssid) else { return nil }
            return WiFiNetwork(ssid: ssid, rssi: network.rssiValue, security: Self.securityKind(of: network))
        }
        if let current = currentSSID, !hotspotNames.contains(current), !networks.contains(where: { $0.ssid == current }) {
            networks.append(WiFiNetwork(ssid: current, rssi: currentRSSI ?? -50, security: .wpa2))
        }
        networks.sort { $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending }

        // Saved hotspots belong in Personal Hotspot or nowhere, never in Known Networks.
        knownNetworks = networks.filter { ($0.ssid == currentSSID || known.contains($0.ssid)) && !Self.isHotspotName($0.ssid) }
        otherNetworks = networks.filter { $0.ssid != currentSSID && !known.contains($0.ssid) }
    }

    private static let hotspotFreshness: TimeInterval = 30
    private static let minimumHotspotRSSI = -85

    /// Instant Hotspot is private Apple API, so iPhone/iPad hotspots are recognised by name.
    private static func isHotspotName(_ ssid: String) -> Bool {
        let name = ssid.lowercased()
        return name.contains("iphone") || name.contains("ipad")
    }

    /// Targeted checks, one every 2 seconds while the panel is open, so the radio isn't kept off-channel.
    private func scheduleHotspotChecks(_ names: [String]) {
        probeQueue = names
        guard probeTimer == nil, !names.isEmpty, scanTimer != nil else { return }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, !self.probeQueue.isEmpty else {
                timer.invalidate()
                self?.probeTimer = nil
                return
            }
            self.checkHotspot(self.probeQueue.removeFirst())
        }
    }

    private func checkHotspot(_ ssid: String) {
        guard wifiOn, locationAuthorized else { return }
        wifiQueue.async { [weak self] in
            let found = try? CWWiFiClient.shared().interface()?.scanForNetworks(withName: ssid)
            let best = found?.filter { $0.ssid == ssid }.max { $0.rssiValue < $1.rssiValue }
            wifiLog.notice("hotspot check: \(best == nil ? "not found" : "found", privacy: .public)")
            DispatchQueue.main.async {
                guard let self, let best else { return }
                self.hotspotSightings[ssid] = (best, Date())
                self.rebuildLists()
            }
        }
    }

    private static func securityKind(of network: CWNetwork) -> SecurityKind {
        let supports = network.supportsSecurity
        if [CWSecurity.enterprise, .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .dynamicWEP].contains(where: supports) {
            return .enterprise
        }
        if supports(.wpa3Personal) && !supports(.wpa2Personal) && !supports(.wpa3Transition) { return .wpa3 }
        if [CWSecurity.wpa2Personal, .personal, .wpa3Transition, .wpa3Personal].contains(where: supports) { return .wpa2 }
        if [CWSecurity.wpaPersonal, .wpaPersonalMixed].contains(where: supports) { return .wpa }
        if supports(.WEP) { return .wep }
        return .open
    }

    /// Maps RSSI to the fill level of the variable "wifi" SF Symbol (dot, inner arc, outer arc).
    static func signalLevel(_ rssi: Int) -> Double {
        if rssi >= -60 { return 1.0 }
        if rssi >= -72 { return 0.6 }
        return 0.3
    }

    // MARK: Joining

    func join(_ network: WiFiNetwork) {
        guard !isDemo, network.ssid != currentSSID, joiningSSID == nil else { return }
        let isKnown = knownSSIDs.contains(network.ssid)
        if !isKnown && network.security.needsPassword {
            onPasswordNeeded?(PasswordRequest(ssid: network.ssid, security: network.security))
            return
        }
        associate(ssid: network.ssid, security: network.security, password: nil, username: nil, usingSavedPassword: isKnown)
    }

    func join(ssid: String, security: SecurityKind, password: String?, username: String?) {
        guard !isDemo, joiningSSID == nil else { return }
        associate(ssid: ssid, security: security, password: password, username: username, usingSavedPassword: false)
    }

    private func associate(ssid: String, security: SecurityKind, password: String?, username: String?, usingSavedPassword: Bool) {
        joiningSSID = ssid
        let cached = scanned[ssid] ?? hotspotSightings[ssid]?.network
        wifiQueue.async { [weak self] in
            var failure: String?
            let iface = CWWiFiClient.shared().interface()
            do {
                guard let iface else { throw JoinError("No Wi-Fi interface found.") }
                let target = try cached ?? Self.directedScan(for: ssid, on: iface)
                if security == .enterprise {
                    try iface.associate(toEnterpriseNetwork: target, identity: nil, username: username, password: password)
                } else {
                    try iface.associate(to: target, password: password)
                }
            } catch {
                // For a known network, let networksetup pull the saved password from the keychain.
                let device = iface?.interfaceName ?? "en0"
                if !(usingSavedPassword && Self.joinWithSavedPassword(ssid, device: device)) {
                    failure = error.localizedDescription
                }
            }
            if let failure {
                wifiLog.error("join failed (saved password: \(usingSavedPassword)): \(failure, privacy: .public)")
            } else {
                wifiLog.notice("join succeeded (saved password: \(usingSavedPassword))")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.joiningSSID = nil
                self.refreshWiFi()
                self.refreshKnownNetworks()
                guard let failure else { return }
                if security.needsPassword {
                    let message = usingSavedPassword ? nil : "The password was incorrect, or the network couldn’t be joined."
                    self.onPasswordNeeded?(PasswordRequest(ssid: ssid, security: security, message: message))
                } else {
                    self.onJoinFailed?(ssid, failure)
                }
            }
        }
    }

    private static func directedScan(for ssid: String, on iface: CWInterface) throws -> CWNetwork {
        let found = try iface.scanForNetworks(withName: ssid, includeHidden: true)
        guard let best = found.max(by: { $0.rssiValue < $1.rssiValue }) else {
            throw JoinError("No network named “\(ssid)” was found nearby.")
        }
        return best
    }

    private static func joinWithSavedPassword(_ ssid: String, device: String) -> Bool {
        // networksetup prints nothing on success and an error message on failure (exit status is unreliable).
        let result = run("/usr/sbin/networksetup", ["-setairportnetwork", device, ssid])
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Location permission

    func requestLocationAccess() {
        if locationStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            locationManager.requestWhenInUseAuthorization()
        } else {
            SystemSettings.open(SystemSettings.locationPrivacy)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
        wifiLog.notice("location status changed to \(self.locationStatus.rawValue)")
        if locationAuthorized {
            refreshWiFi()
            loadCachedScan()
            scan()
        }
    }

    // MARK: Helpers

    private struct JoinError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func displayName(of bsdName: String) -> String {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = interfaces.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? "Ethernet"
    }

    private static func ipv4Address(of name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            if String(cString: ifa.ifa_name) == name, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = ifa.ifa_next
        }
        return nil
    }

    // MARK: Demo data (`--demo`), for checking the layout without touching real networks

    private func loadDemo() {
        isDemo = true
        locationStatus = .authorizedAlways
        primary = .wifi
        primaryInterface = "en0"
        ethernetLinks = [EthernetLink(bsdName: "en10", displayName: "USB 10/100/1G/2.5G LAN", ipv4: "192.168.0.151", inUse: false)]
        ethernetMedia = ["en10": EthernetMedia("2500Base-T <full-duplex>")]
        wifiStats = WiFiStats(transmitRate: 866, rssi: -48, noise: -92, channel: 149, band: "5 GHz", width: "80 MHz",
                              standard: "Wi-Fi 6 (802.11ax)")
        traffic.loadDemo(interface: "en0")
        latency.loadDemo()
        quality.loadDemo()
        vpnName = "Example VPN"
        wifiOn = true
        currentSSID = "Home-5G"
        currentRSSI = -48
        hotspots = [WiFiNetwork(ssid: "Example iPhone", rssi: -52, security: .wpa2)]
        knownNetworks = [("Home-2.4G", -63), ("Home-5G", -48), ("Office", -78)]
            .map { WiFiNetwork(ssid: $0.0, rssi: $0.1, security: .wpa2) }
        otherNetworks = [("Cafe Guest", -70, SecurityKind.open), ("Neighbour-5G", -58, .wpa3), ("Printer-Setup", -81, .open), ("TP-Link_1E18", -66, .wpa2)]
            .map { WiFiNetwork(ssid: $0.0, rssi: $0.1, security: $0.2) }
    }
}
