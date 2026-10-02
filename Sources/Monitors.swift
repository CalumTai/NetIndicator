// Live measurements for the panel graphs: interface throughput and ping latency.
import Foundation
import Darwin

/// One second of traffic, in bits per second.
struct TrafficSample {
    let received: Double
    let sent: Double
}

/// Reads the kernel's per-interface byte counters once a second, all the time, so the graph already
/// shows the last minute when the panel opens. One sysctl call per second; negligible cost.
final class TrafficMonitor: ObservableObject {
    static let window = 60

    /// Only redraw while the panel is visible; samples are still recorded when it isn't.
    var isObserved = false

    private var histories: [String: [TrafficSample]] = [:]
    private var lastCounters: [String: (received: UInt64, sent: UInt64)] = [:]
    private var lastTime: TimeInterval = 0
    private var timer: Timer?

    func start() {
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Oldest first, up to `window` samples.
    func history(for interface: String?) -> [TrafficSample] {
        interface.flatMap { histories[$0] } ?? []
    }

    func loadDemo(interface: String) {
        histories[interface] = (0..<Self.window).map { i in
            let t = Double(i)
            return TrafficSample(received: max(0, 18e6 + 14e6 * sin(t / 6) + 6e6 * sin(t / 2.3)),
                                 sent: max(0, 1.5e6 + 1.2e6 * sin(t / 4 + 1)))
        }
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let counters = Self.readCounters()
        let elapsed = now - lastTime
        if lastTime > 0, elapsed > 0 {
            // Physical interfaces only (en0 Wi-Fi, USB/Thunderbolt Ethernet, iPhone USB).
            for (name, value) in counters where name.hasPrefix("en") {
                guard let previous = lastCounters[name] else { continue }
                // A counter that went backwards means the interface was reset; count that second as zero.
                let received = value.received >= previous.received ? Double(value.received - previous.received) : 0
                let sent = value.sent >= previous.sent ? Double(value.sent - previous.sent) : 0
                var history = histories[name, default: []]
                history.append(TrafficSample(received: received * 8 / elapsed, sent: sent * 8 / elapsed))
                if history.count > Self.window { history.removeFirst(history.count - Self.window) }
                histories[name] = history
            }
        }
        lastCounters = counters
        lastTime = now
        if isObserved { objectWillChange.send() }
    }

    /// 64-bit counters from the routing socket (`NET_RT_IFLIST2`); getifaddrs' counters are 32-bit and wrap at 4 GB.
    private static func readCounters() -> [String: (received: UInt64, sent: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: (received: UInt64, sent: UInt64)] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        result[String(cString: name)] = (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }
}

/// Round-trip times in milliseconds; nil means no reply in time (counted as loss) unless the
/// router was unreachable, which means the Mac itself refused to send (e.g. a VPN blocking the local network).
struct LatencySample {
    let router: Double?
    let internet: Double?
    var routerReachable = true

    var hasLoss: Bool { internet == nil || (router == nil && routerReachable) }
}

enum PingResult {
    case reply(milliseconds: Double)
    case timeout
    /// The Mac refused to send: "No route to host", typically a VPN kill switch blocking LAN traffic.
    case unreachable

    var milliseconds: Double? {
        if case .reply(let value) = self { return value }
        return nil
    }
}

/// Pings the router and a public server once a second while the panel is open.
/// The router ping is pinned to the physical interface so it measures only the Wi-Fi/Ethernet hop,
/// even with a VPN on; the internet ping follows normal routing (through the VPN if one is active).
final class LatencyMonitor: ObservableObject {
    static let internetHost = "1.1.1.1"

    @Published private(set) var samples: [LatencySample] = []
    @Published private(set) var routerAddress: String?
    /// False while the Mac refuses to reach the router at all (as opposed to the router not answering).
    @Published private(set) var routerReachable = true

    private var interface: String?
    private var timer: Timer?
    private var sequence: UInt16 = 0
    private let queue = DispatchQueue(label: "NetIndicator.ping", attributes: .concurrent)

    /// Share of seconds in the window where a ping got no reply (matches the red ticks on the graph).
    var loss: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.filter(\.hasLoss).count) / Double(samples.count)
    }

    func setTarget(router: String?, interface: String?) {
        guard router != routerAddress || interface != self.interface else { return }
        routerAddress = router
        self.interface = interface
        samples = []
    }

    func start() {
        guard timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func loadDemo() {
        routerAddress = "192.168.0.1"
        samples = (0..<TrafficMonitor.window).map { i in
            let spike = i == 41 ? 14.0 : 0
            return LatencySample(router: i == 52 ? nil : 3 + Double(i % 5) * 0.6 + spike,
                                 internet: 190 + Double((i * 7) % 9) + spike * 1.5)
        }
    }

    private func tick() {
        sequence &+= 1
        let sequence = self.sequence, router = routerAddress, interface = self.interface
        let group = DispatchGroup()
        var routerResult = PingResult.unreachable
        var internetResult = PingResult.timeout
        if let router {
            group.enter()
            queue.async {
                routerResult = Pinger.ping(router, boundTo: interface, sequence: sequence)
                group.leave()
            }
        }
        group.enter()
        queue.async {
            internetResult = Pinger.ping(Self.internetHost, boundTo: nil, sequence: sequence)
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.timer != nil, router == self.routerAddress else { return }
            if case .unreachable = routerResult { self.routerReachable = false } else { self.routerReachable = true }
            self.samples.append(LatencySample(router: routerResult.milliseconds, internet: internetResult.milliseconds,
                                              routerReachable: self.routerReachable))
            if self.samples.count > TrafficMonitor.window { self.samples.removeFirst(self.samples.count - TrafficMonitor.window) }
        }
    }
}

/// ICMP echo over an unprivileged datagram socket (macOS allows these without admin rights).
enum Pinger {
    static func ping(_ host: String, boundTo interface: String?, sequence: UInt16, timeout: TimeInterval = 0.9) -> PingResult {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return .unreachable }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .unreachable }
        defer { close(fd) }
        if let interface {
            var index = if_nametoindex(interface)
            if index != 0 { setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) }
        }

        // 8-byte ICMP header (type 8 = echo request) plus 8 bytes of payload.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        let identifier = UInt16(truncatingIfNeeded: getpid())
        packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xff)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xff)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else {
            return [EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN].contains(errno) ? .unreachable : .timeout
        }

        let deadline = start + UInt64(timeout * 1e9)
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { return .timeout }
            // ICMP sockets can see replies meant for other pings, so only accept one from the host we pinged.
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &senderLength) }
            }
            guard count > 0 else { return .timeout }
            guard sender.sin_addr.s_addr == address.sin_addr.s_addr else { continue }
            // macOS includes the IPv4 header on ICMP datagram sockets; skip it.
            let offset = buffer[0] >> 4 == 4 ? Int(buffer[0] & 0x0f) * 4 : 0
            guard count >= offset + 8, buffer[offset] == 0 else { continue }   // type 0 = echo reply
            let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            guard replySequence == sequence else { continue }
            return .reply(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count - 1, by: 2) {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
