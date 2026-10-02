// "Find and join a Wi-Fi network" (Other…) and password prompts, modelled on the system dialogs.
import AppKit
import SwiftUI

final class JoinWindowPresenter {
    var onShowNetworks: (() -> Void)?

    private let model: NetworkModel
    private var window: NSWindow?

    init(model: NetworkModel) {
        self.model = model
    }

    func showOther() { present(nil) }

    func showPassword(_ request: PasswordRequest) { present(request) }

    private func present(_ request: PasswordRequest?) {
        dismiss()
        let form = JoinForm(
            request: request,
            onJoin: { [weak self] ssid, security, password, username in
                self?.dismiss()
                self?.model.join(ssid: ssid, security: security, password: password, username: username)
            },
            onCancel: { [weak self] in self?.dismiss() },
            onShowNetworks: { [weak self] in
                self?.dismiss()
                self?.onShowNetworks?()
            })

        let controller = NSHostingController(rootView: form)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        window.title = ""
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(controller.view.fittingSize)
        Self.place(window)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
    }

    /// Matches where macOS puts its own "Find and join" dialog: centred horizontally, top edge a fifth of the
    /// way down the usable area (below the menu bar, above the Dock) of the screen the pointer is on.
    /// Anchoring the top keeps the window in place if it grows (e.g. Enterprise adds a Username field).
    private static func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        let top = area.maxY - area.height / 5
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: max(area.minY, top - size.height).rounded()))
    }
}

private enum SecurityChoice: String, CaseIterable, Identifiable {
    case none = "None"
    case enhancedOpen = "Enhanced Open"
    case wep = "WEP"
    case wpaPersonal = "WPA/WPA2 Personal"
    case wpa2wpa3Personal = "WPA2/WPA3 Personal"
    case wpa3Personal = "WPA3 Personal"
    case dynamicWEP = "Dynamic WEP"
    case wpaEnterprise = "WPA/WPA2 Enterprise"
    case wpa2Enterprise = "WPA2 Enterprise"
    case wpa2wpa3Enterprise = "WPA2/WPA3 Enterprise"
    case wpa3Enterprise = "WPA3 Enterprise"

    var id: String { rawValue }

    var kind: SecurityKind {
        switch self {
        case .none, .enhancedOpen: .open
        case .wep: .wep
        case .wpaPersonal, .wpa2wpa3Personal: .wpa2
        case .wpa3Personal: .wpa3
        case .dynamicWEP, .wpaEnterprise, .wpa2Enterprise, .wpa2wpa3Enterprise, .wpa3Enterprise: .enterprise
        }
    }

    static let groups: [[SecurityChoice]] = [
        [.none, .enhancedOpen],
        [.wep, .wpaPersonal, .wpa2wpa3Personal, .wpa3Personal],
        [.dynamicWEP, .wpaEnterprise, .wpa2Enterprise, .wpa2wpa3Enterprise, .wpa3Enterprise],
    ]
}

private struct JoinForm: View {
    /// nil = "Other…" (name + security entered by hand); otherwise a known SSID that needs a password.
    let request: PasswordRequest?
    let onJoin: (_ ssid: String, _ security: SecurityKind, _ password: String?, _ username: String?) -> Void
    let onCancel: () -> Void
    let onShowNetworks: () -> Void

    @State private var name = ""
    @State private var security: SecurityChoice = .wpa2wpa3Personal
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @FocusState private var focused: Field?

    private enum Field { case name, username, password }

    private var ssid: String { request?.ssid ?? name }
    private var kind: SecurityKind { request?.security ?? security.kind }

    private var canJoin: Bool {
        guard !ssid.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == .enterprise && username.isEmpty { return false }
        return password.count >= kind.minimumPasswordLength
    }

    private var title: String {
        guard let request else { return "Find and join a Wi-Fi network." }
        return "The Wi-Fi network “\(request.ssid)” requires \(request.security.requirement)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "wifi")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                    .frame(width: 80, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .bold))
                    if request == nil {
                        Text("Enter the name and security type of the network you want to join.")
                            .font(.system(size: 12))
                    }
                    if let message = request?.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                if request == nil {
                    TextField("Network Name:", text: $name).focused($focused, equals: .name)
                    Picker("Security:", selection: $security) {
                        ForEach(Array(SecurityChoice.groups.enumerated()), id: \.offset) { index, group in
                            if index > 0 { Divider() }
                            ForEach(group) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
                if kind == .enterprise {
                    TextField("Username:", text: $username).focused($focused, equals: .username)
                }
                if kind.needsPassword {
                    Group {
                        if showPassword {
                            TextField("Password:", text: $password)
                        } else {
                            SecureField("Password:", text: $password)
                        }
                    }
                    .focused($focused, equals: .password)
                    Toggle("Show password", isOn: $showPassword)
                }
            }
            .formStyle(.columns)
            .padding(.leading, 50)

            HStack(spacing: 10) {
                HelpButton()
                if request == nil {
                    Button("Show Networks", action: onShowNetworks)
                }
                Spacer()
                Button(action: onCancel) { Text("Cancel").frame(minWidth: 56) }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onJoin(ssid, kind, kind.needsPassword ? password : nil, kind == .enterprise ? username : nil)
                } label: {
                    Text("Join").frame(minWidth: 56)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canJoin)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            DispatchQueue.main.async {
                focused = request == nil ? .name : (kind == .enterprise ? .username : .password)
            }
        }
    }
}

private struct HelpButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.openHelp))
        button.bezelStyle = .helpButton
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        @objc func openHelp() {
            NSWorkspace.shared.open(URL(string: "https://support.apple.com/guide/mac-help/welcome/mac")!)
        }
    }
}
