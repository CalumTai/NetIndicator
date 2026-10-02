// NetIndicator — a stand-in for the macOS Wi-Fi menu that also shows when traffic goes over Ethernet.
import AppKit
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = NetworkModel()
    private lazy var panel = MenuPanelController(model: model)
    private lazy var joinWindows = JoinWindowPresenter(model: model)
    private var modelChanges: AnyCancellable?
    private var signalTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panel.statusButton = button
        panel.onOtherNetwork = { [weak self] in self?.joinWindows.showOther() }
        joinWindows.onShowNetworks = { [weak self] in self?.panel.show() }
        model.onPasswordNeeded = { [weak self] request in self?.joinWindows.showPassword(request) }
        model.onJoinFailed = { ssid, message in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The Wi-Fi network “\(ssid)” couldn’t be joined."
            alert.informativeText = message
            alert.runModal()
        }

        // objectWillChange fires before the new value lands, so hop to the next main-queue turn.
        modelChanges = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
        model.start(demo: CommandLine.arguments.contains("--demo"))
        updateIcon()

        // Keep the signal-strength bars in the icon current.
        signalTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.model.refreshWiFi()
        }
        if CommandLine.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.panel.show() }
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            panel.toggle()
        }
    }

    private func updateIcon() {
        let symbol: String, level: Double?, tooltip: String
        switch model.primary {
        case .ethernet:
            (symbol, level, tooltip) = ("cable.connector.horizontal", nil, "Using Ethernet")
        case .wifi:
            (symbol, level, tooltip) = ("wifi", model.currentRSSI.map(NetworkModel.signalLevel) ?? 1, "Using Wi-Fi")
        case .none:
            (symbol, level, tooltip) = model.wifiOn ? ("wifi", 0, "Wi-Fi: Not Connected") : ("wifi.slash", nil, "Wi-Fi: Off")
        }
        let image = level.map { NSImage(systemSymbolName: symbol, variableValue: $0, accessibilityDescription: tooltip) }
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip
    }

    /// Right-click (or Control-click) shows app options, keeping the main panel identical to the system one.
    private func showContextMenu() {
        panel.close()
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let network = NSMenuItem(title: "Network Settings…", action: #selector(openNetworkSettings), keyEquivalent: "")
        network.target = self
        menu.addItem(network)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NetIndicator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLaunchAtLogin() {
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

    @objc private func openNetworkSettings() {
        SystemSettings.open(SystemSettings.network)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
