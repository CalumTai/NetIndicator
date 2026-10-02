// The drop-down panel, styled after the macOS Sequoia Wi-Fi menu.
import AppKit
import Combine
import SwiftUI
import os

/// Every row has a fixed height, so the panel's size is calculated from these rather than measured.
enum MenuMetrics {
    static let width: CGFloat = 294
    static let cornerRadius: CGFloat = 10
    static let inset: CGFloat = 5
    static let headerHeight: CGFloat = 34
    static let separatorHeight: CGFloat = 9   // 1pt line with 4pt above and below
    static let sectionHeaderHeight: CGFloat = 24
    static let rowHeight: CGFloat = 32
    static let footerHeight: CGFloat = 26
    /// Speed graph, latency graph and two detail rows (see LiveStatsBlock).
    static let statsHeight: CGFloat = 190
    /// The network quality test row: title plus two caption lines.
    static let qualityHeight: CGFloat = 44

    static func panelHeight(listHeight: CGFloat, showsStats: Bool) -> CGFloat {
        inset * 2 + headerHeight
            + (showsStats ? separatorHeight + statsHeight + separatorHeight + qualityHeight : 0)
            + (listHeight > 0 ? separatorHeight + listHeight : 0)
            + separatorHeight + footerHeight
    }
}

enum MenuSection: Hashable { case ethernet, vpn, location, hotspots, known, other }

extension NetworkModel {
    /// The graphs only make sense while some link is carrying traffic.
    var showsLiveStats: Bool { primary != .none }

    var menuSections: [MenuSection] {
        var sections: [MenuSection] = []
        if !ethernetLinks.isEmpty { sections.append(.ethernet) }
        if vpnName != nil { sections.append(.vpn) }
        guard wifiOn else { return sections }
        guard locationAuthorized else { return sections + [.location] }
        if !hotspots.isEmpty { sections.append(.hotspots) }
        if !knownNetworks.isEmpty { sections.append(.known) }
        return sections + [.other]
    }

    /// Full height of the scrolling list, before it is capped to fit the screen.
    var menuListHeight: CGFloat {
        let sections = menuSections
        guard !sections.isEmpty else { return 0 }
        let header = MenuMetrics.sectionHeaderHeight, row = MenuMetrics.rowHeight
        let content = sections.map { section -> CGFloat in
            switch section {
            case .ethernet: return header + row * CGFloat(ethernetLinks.count)
            case .vpn: return header + row
            case .location: return row
            case .hotspots: return header + row * CGFloat(hotspots.count)
            case .known: return header + row * CGFloat(knownNetworks.count)
            case .other: return header + (showsOtherNetworks ? row * CGFloat(otherNetworks.count + 1) : 0)
            }
        }
        return content.reduce(0, +) + MenuMetrics.separatorHeight * CGFloat(sections.count - 1)
    }
}

final class PanelLayout: ObservableObject {
    @Published var maxListHeight: CGFloat = 600
}

private final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class MenuPanelController: NSObject {
    weak var statusButton: NSStatusBarButton?
    var onOtherNetwork: (() -> Void)?

    private let model: NetworkModel
    private let layout = PanelLayout()
    private let panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 100),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let log = Logger(subsystem: "local.netindicator", category: "panel")
    private var modelChanges: AnyCancellable?
    private var clickMonitor: Any?
    private var lastClosed = Date.distantPast
    private var topLeft = NSPoint.zero

    init(model: NetworkModel) {
        self.model = model
        super.init()
        configurePanel()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 100))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: MenuMetrics.cornerRadius)
        panel.contentView = effect

        let root = PanelRoot(model: model, layout: layout,
                             close: { [weak self] in self?.close() },
                             showOther: { [weak self] in
                                 self?.close()
                                 self?.onOtherNetwork?()
                             })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        // objectWillChange fires before the new value lands, so resize on the next main-queue turn.
        modelChanges = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resizeToFit() }

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            self?.close()
        }
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.2 {
            // The click that dismissed the panel (via resign-key) shouldn't immediately reopen it.
            show()
        }
    }

    func show() {
        guard !panel.isVisible, let button = statusButton, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let fixedParts = MenuMetrics.panelHeight(listHeight: 0, showsStats: true) + MenuMetrics.separatorHeight
        layout.maxListHeight = max(160, anchor.minY - visible.minY - 12 - fixedParts)
        topLeft = NSPoint(x: min(max(anchor.minX, visible.minX + 6), visible.maxX - MenuMetrics.width - 6),
                          y: anchor.minY - 1)

        model.menuOpened()
        resizeToFit()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        log.notice("panel opened, key window: \(self.panel.isKeyWindow)")
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusButton?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        lastClosed = Date()
        model.menuClosed()
    }

    /// Keeps the top edge pinned under the menu bar while the content grows or shrinks.
    private func resizeToFit() {
        let listHeight = min(model.menuListHeight, layout.maxListHeight)
        let height = MenuMetrics.panelHeight(listHeight: listHeight, showsStats: model.showsLiveStats)
        let target = NSRect(x: topLeft.x, y: topLeft.y - height, width: MenuMetrics.width, height: height)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: panel.isVisible)
        panel.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - SwiftUI content

struct PanelRoot: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject var layout: PanelLayout
    let close: () -> Void
    let showOther: () -> Void

    var body: some View {
        MenuView(model: model, listHeight: min(model.menuListHeight, layout.maxListHeight), close: close, showOther: showOther)
            .frame(width: MenuMetrics.width)
            .overlay(RoundedRectangle(cornerRadius: MenuMetrics.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct MenuView: View {
    @ObservedObject var model: NetworkModel
    let listHeight: CGFloat
    let close: () -> Void
    let showOther: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wi-Fi").font(.system(size: 13, weight: .bold))
                Spacer()
                MenuSwitch(isOn: model.wifiOn) { model.setWiFiPower(!model.wifiOn) }
            }
            .padding(.horizontal, 8)
            .frame(height: MenuMetrics.headerHeight)

            if model.showsLiveStats {
                MenuSeparator()
                LiveStatsBlock(model: model, traffic: model.traffic, latency: model.latency)
                MenuSeparator()
                QualityRow(quality: model.quality)
            }

            if listHeight > 0 {
                MenuSeparator()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.menuSections.enumerated()), id: \.element) { index, section in
                            if index > 0 { MenuSeparator() }
                            content(for: section)
                        }
                    }
                }
                .frame(height: listHeight)
            }

            MenuSeparator()
            MenuRow(height: MenuMetrics.footerHeight, action: { close(); SystemSettings.open(SystemSettings.wifi) }) {
                Text("Wi-Fi Settings…").font(.system(size: 13))
            }
        }
        .padding(MenuMetrics.inset)
    }

    @ViewBuilder private func content(for section: MenuSection) -> some View {
        switch section {
        case .ethernet:
            SectionHeader(title: "Ethernet")
            ForEach(model.ethernetLinks) { link in
                MenuRow(action: { close(); SystemSettings.open(SystemSettings.network) }) {
                    IconCircle(symbol: "cable.connector.horizontal", active: link.inUse)
                    TitleStack(title: link.displayName,
                               caption: [link.inUse ? "In use" : "Connected — not in use", link.ipv4].compactMap { $0 }.joined(separator: " · "))
                }
            }
        case .vpn:
            SectionHeader(title: "VPN")
            MenuRow(action: nil) {
                IconCircle(symbol: "lock.fill", active: true)
                TitleStack(title: model.vpnName ?? "VPN", caption: "Connected")
            }
        case .location:
            MenuRow(action: { close(); model.requestLocationAccess() }) {
                IconCircle(symbol: "location.fill", active: false)
                TitleStack(title: "Allow Location Access…", caption: "macOS requires it to show network names")
            }
        case .hotspots:
            SectionHeader(title: "Personal Hotspot")
            ForEach(model.hotspots) { networkRow($0, symbol: "personalhotspot") }
        case .known:
            SectionHeader(title: "Known Networks")
            ForEach(model.knownNetworks) { networkRow($0) }
        case .other:
            MenuRow(height: MenuMetrics.sectionHeaderHeight, action: { model.showsOtherNetworks.toggle() }) {
                Text("Other Networks").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.isScanning && model.showsOtherNetworks {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: model.showsOtherNetworks ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            if model.showsOtherNetworks {
                ForEach(model.otherNetworks) { networkRow($0) }
                MenuRow(action: showOther) {
                    IconCircle(symbol: "ellipsis", active: false)
                    Text("Other…").font(.system(size: 13))
                }
            }
        }
    }

    private func networkRow(_ network: WiFiNetwork, symbol: String = "wifi") -> some View {
        let connected = network.ssid == model.currentSSID
        return MenuRow(action: { close(); model.join(network) }) {
            IconCircle(symbol: symbol, level: symbol == "wifi" ? NetworkModel.signalLevel(network.rssi) : nil, active: connected)
            TitleStack(title: network.ssid, caption: connected ? wifiCaption : nil)
            Spacer(minLength: 4)
            if model.joiningSSID == network.ssid {
                ProgressView().controlSize(.small)
            } else if network.security.needsPassword {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// Only worth saying which link is in use when Ethernet is also plugged in.
    private var wifiCaption: String? {
        guard !model.ethernetLinks.isEmpty else { return nil }
        return model.primary == .wifi ? "In use" : "Connected — not in use"
    }
}

/// Runs `networkQuality` on click (click again to stop) and keeps the last result on show.
private struct QualityRow: View {
    @ObservedObject var quality: QualityTest

    var body: some View {
        MenuRow(height: MenuMetrics.qualityHeight, action: quality.toggle) {
            IconCircle(symbol: "speedometer", active: quality.isRunning)
            VStack(alignment: .leading, spacing: 0) {
                // Time and spinner sit on the title line so the result lines get the full width.
                HStack(spacing: 4) {
                    title.font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if quality.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if let result = quality.lastResult {
                        Text(result.date, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Group { captions }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var title: some View {
        if case .running(let since) = quality.state {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("Testing… \(Int(context.date.timeIntervalSince(since))) s")
            }
        } else {
            Text("Test Network Quality")
        }
    }

    @ViewBuilder private var captions: some View {
        switch quality.state {
        case .running:
            Text("Watch the graphs above")
            Text("Click to stop")
        case .failed(let reason):
            Text("The test didn’t finish")
            Text(reason)
        case .idle:
            if let result = quality.lastResult {
                Text("↓ \(Units.bits(result.download)) · ↑ \(Units.bits(result.upload))"
                     + (result.idleLatency.map { " · idle \($0)" } ?? ""))
                Text("Responsiveness ")
                    + Text(result.responsiveness).foregroundColor(Self.color(for: result.responsiveness))
                    + Text(result.delayUnderLoad.map { " · \($0) under load" } ?? "")
            } else {
                Text("Speed and responsiveness, under a minute")
                Text("Uses a few hundred MB of data")
            }
        }
    }

    private static func color(for rating: String) -> Color {
        switch rating.lowercased() {
        case "high": return Color(nsColor: .systemGreen)
        case "medium": return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }
}

/// Drawn in SwiftUI rather than using NSSwitch: it takes the first click in a background panel
/// and stays blue like Control Center's switches instead of turning grey when the app isn't frontmost.
private struct MenuSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Capsule()
            .fill(isOn ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.18))
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .accessibilityElement()
            .accessibilityLabel("Wi-Fi")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isButton)
    }
}

private struct MenuRow<Content: View>: View {
    var height: CGFloat = MenuMetrics.rowHeight
    let action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(hovering && action != nil ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { action?() }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: MenuMetrics.sectionHeaderHeight,
                   maxHeight: MenuMetrics.sectionHeaderHeight, alignment: .leading)
    }
}

private struct IconCircle: View {
    let symbol: String
    var level: Double?
    let active: Bool

    var body: some View {
        ZStack {
            Circle().fill(active ? Color(nsColor: .controlAccentColor) : Color.primary.opacity(0.12))
            image
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.primary)
        }
        .frame(width: 26, height: 26)
    }

    private var image: Image {
        if let level { return Image(systemName: symbol, variableValue: level) }
        return Image(systemName: symbol)
    }
}

private struct TitleStack: View {
    let title: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, (MenuMetrics.separatorHeight - 1) / 2)
    }
}
