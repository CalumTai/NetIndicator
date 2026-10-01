# NetIndicator

A tiny macOS menu bar app that shows whether your traffic is going over **Ethernet** or **Wi-Fi**.

- Icon switches between a cable (Ethernet), Wi-Fi, or a slashed network (offline)
- Menu shows the active interface and its IPv4 address
- Detects an active VPN tunnel and shows it separately, while still reporting the physical link underneath
- "Launch at Login" toggle built in

## Build & install

```bash
./build.sh
```

Compiles `main.swift` with `swiftc`, assembles `~/Applications/NetIndicator.app`, ad-hoc signs it, and launches it. Re-run after any change.

Requires macOS 13+ and the Xcode Command Line Tools.
