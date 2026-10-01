// NetIndicator — menu bar icon showing whether traffic goes over Ethernet or Wi-Fi.
import AppKit
import Network
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = NWPathMonitor()
    private let linkItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let vpnItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(linkItem)
        menu.addItem(vpnItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Open Network Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NetIndicator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon("network", tooltip: "Checking…")

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.update(path) }
        }
        monitor.start(queue: DispatchQueue(label: "NetIndicator.monitor"))
    }

    private func update(_ path: NWPath) {
        // availableInterfaces is in routing-preference order. A VPN (utun, type .other) sits on top,
        // so skip it and take the first physical link — that is what actually carries the traffic.
        let interfaces = path.availableInterfaces
        let physical = interfaces.first { $0.type == .wiredEthernet || $0.type == .wifi }
        let tunnel = interfaces.first.flatMap { $0.type == .other ? $0 : nil }

        guard path.status == .satisfied, let link = physical else {
            setIcon("network.slash", tooltip: "Offline")
            linkItem.title = "Not connected"
            vpnItem.isHidden = true
            return
        }

        let isEthernet = link.type == .wiredEthernet
        let kind = isEthernet ? "Ethernet (LAN)" : "Wi-Fi"
        let ip = ipv4Address(of: link.name).map { " — \($0)" } ?? ""
        setIcon(isEthernet ? "cable.connector.horizontal" : "wifi", tooltip: "Using \(kind)")
        linkItem.title = "Using \(kind) · \(link.name)\(ip)"
        vpnItem.title = "VPN active · \(tunnel?.name ?? "")"
        vpnItem.isHidden = tunnel == nil
    }

    private func setIcon(_ symbol: String, tooltip: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip
    }

    private func ipv4Address(of name: String) -> String? {
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

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Add it manually in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
