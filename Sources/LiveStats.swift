// Speed graph, latency graph and link details shown under the Wi-Fi switch.
import AppKit
import SwiftUI

private extension Color {
    static let received = Color(nsColor: .controlAccentColor)
    static let sent = Color(nsColor: .systemOrange)
    static let latency = Color(nsColor: .systemGreen)
    static let loss = Color(nsColor: .systemRed)
}

struct LiveStatsBlock: View {
    @ObservedObject var model: NetworkModel
    @ObservedObject var traffic: TrafficMonitor
    @ObservedObject var latency: LatencyMonitor

    var body: some View {
        let history = traffic.history(for: model.primaryInterface)
        let latest = latency.samples.last
        VStack(alignment: .leading, spacing: 0) {
            GraphHeader(title: model.primary == .ethernet ? "Ethernet" : "Wi-Fi") {
                Text("↓ \(Units.bits(history.last?.received ?? 0))").foregroundStyle(Color.received)
                Text("↑ \(Units.bits(history.last?.sent ?? 0))").foregroundStyle(Color.sent)
            }
            ThroughputGraph(samples: history)
                .frame(height: 62)
            Spacer().frame(height: 6)
            GraphHeader(title: "Latency") {
                HStack(spacing: 3) {
                    LineSwatch(dashed: false, color: .latency)
                    Text(latency.routerReachable ? "Router \(Units.milliseconds(latest?.router))" : "Router blocked")
                        .foregroundStyle(Color.latency)
                        .help(latency.routerReachable ? "" : "The Mac can’t reach your router — usually a VPN blocking local network traffic.")
                }
                HStack(spacing: 3) {
                    LineSwatch(dashed: true, color: Color.latency.opacity(0.6))
                    Text("Internet \(Units.milliseconds(latest?.internet))")
                }
            }
            LatencyGraph(samples: latency.samples, loss: latency.loss)
                .frame(height: 38)
            Spacer().frame(height: 6)
            details
                .frame(height: 36, alignment: .top)
        }
        .padding(.horizontal, 8)
        .frame(height: MenuMetrics.statsHeight, alignment: .top)
    }

    @ViewBuilder private var details: some View {
        VStack(spacing: 0) {
            switch model.primary {
            case .wifi:
                if let stats = model.wifiStats {
                    DetailRow(left: "Link rate \(Int(stats.transmitRate.rounded())) Mbps",
                              right: "Signal \(stats.rssi) dBm · SNR \(stats.rssi - stats.noise) dB")
                    DetailRow(left: stats.channelDescription, right: stats.standard)
                } else {
                    DetailRow(left: "Reading Wi-Fi details…", right: "")
                }
            case .ethernet:
                let link = model.ethernetLinks.first { $0.inUse }
                let media = link.flatMap { model.ethernetMedia[$0.bsdName] }
                DetailRow(left: "Link speed \(media?.speed ?? "—")", right: media?.duplex ?? "")
                DetailRow(left: "IPv4 \(link?.ipv4 ?? "—")", right: link?.bsdName ?? "")
            case .none:
                EmptyView()
            }
        }
    }
}

private struct GraphHeader<Values: View>: View {
    let title: String
    @ViewBuilder let values: Values

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            values.font(.system(size: 11).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(height: 20)
    }
}

/// A short sample of a graph line, used as the legend key in front of its reading.
private struct LineSwatch: View {
    let dashed: Bool
    let color: Color

    var body: some View {
        Canvas { context, size in
            let line = Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 3] : []))
        }
        .frame(width: 12, height: 8)
    }
}

private struct DetailRow: View {
    let left: String
    let right: String

    var body: some View {
        HStack {
            Text(left)
            Spacer(minLength: 6)
            Text(right)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 18)
    }
}

/// Download as a filled area, upload as a line; newest sample at the right edge, like Task Manager.
private struct ThroughputGraph: View {
    let samples: [TrafficSample]

    var body: some View {
        let peak = samples.reduce(0) { max($0, $1.received, $1.sent) }
        let scale = Units.niceCeiling(max(peak, 1_000_000))
        GraphFrame(label: Units.bits(scale)) {
            Canvas { context, size in
                let received = GraphGeometry.points(samples.map(\.received), scale: scale, in: size)
                if let first = received.first, let last = received.last, received.count > 1 {
                    // addLines would start a new subpath, so add each point to keep one closed shape.
                    var area = Path()
                    area.move(to: CGPoint(x: first.x, y: size.height))
                    received.forEach { area.addLine(to: $0) }
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(Color.received.opacity(0.3)))
                    context.stroke(Path { $0.addLines(received) }, with: .color(.received), lineWidth: 1.5)
                }
                let sent = GraphGeometry.points(samples.map(\.sent), scale: scale, in: size)
                if sent.count > 1 {
                    context.stroke(Path { $0.addLines(sent) }, with: .color(.sent), lineWidth: 1.5)
                }
            }
        }
    }
}

/// Router as a solid line, internet as a dashed one; gaps and red ticks mark pings with no reply.
private struct LatencyGraph: View {
    let samples: [LatencySample]
    let loss: Double

    var body: some View {
        let peak = samples.reduce(0) { max($0, $1.router ?? 0, $1.internet ?? 0) }
        let scale = Units.niceCeiling(max(peak, 10))
        let lossPercent = Int((loss * 100).rounded())
        GraphFrame(label: "\(Int(scale)) ms",
                   note: "\(lossPercent)% loss", noteColor: lossPercent > 0 ? .loss : .secondary) {
            Canvas { context, size in
                let internet = GraphGeometry.segments(samples.map(\.internet), scale: scale, in: size)
                context.stroke(internet, with: .color(Color.latency.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                let router = GraphGeometry.segments(samples.map(\.router), scale: scale, in: size)
                context.stroke(router, with: .color(.latency), lineWidth: 1.5)

                for (index, sample) in samples.enumerated() where sample.hasLoss {
                    let x = GraphGeometry.x(index, count: samples.count, width: size.width)
                    let tick = Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - 5)) }
                    context.stroke(tick, with: .color(.loss), lineWidth: 1.5)
                }
            }
        }
    }
}

private struct GraphFrame<Content: View>: View {
    let label: String
    var note: String?
    var noteColor: Color = .secondary
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    let y = (size.height * fraction).rounded() + 0.5
                    context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
                }
            }
            content.clipped()
            Text(label)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            if let note {
                Text(note)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(noteColor)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

private enum GraphGeometry {
    /// The newest sample sits at the right edge; a partly filled window grows in from the right.
    static func x(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        let step = width / CGFloat(TrafficMonitor.window - 1)
        return width - CGFloat(count - 1 - index) * step
    }

    static func y(_ value: Double, scale: Double, height: CGFloat) -> CGFloat {
        let fraction = min(max(value / scale, 0), 1)
        return 1 + (height - 2) * (1 - CGFloat(fraction))
    }

    static func points(_ values: [Double], scale: Double, in size: CGSize) -> [CGPoint] {
        values.enumerated().map { CGPoint(x: x($0.offset, count: values.count, width: size.width),
                                          y: y($0.element, scale: scale, height: size.height)) }
    }

    /// A path that breaks wherever a value is missing.
    static func segments(_ values: [Double?], scale: Double, in size: CGSize) -> Path {
        var path = Path()
        var drawing = false
        for (index, value) in values.enumerated() {
            guard let value else { drawing = false; continue }
            let point = CGPoint(x: x(index, count: values.count, width: size.width), y: y(value, scale: scale, height: size.height))
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
        return path
    }
}

enum Units {
    /// 1, 2 or 5 × 10ⁿ — the smallest such value at or above `value`.
    static func niceCeiling(_ value: Double) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 2, 5, 10] where step * magnitude >= value { return step * magnitude }
        return 10 * magnitude
    }

    static func bits(_ bitsPerSecond: Double) -> String {
        let units: [(Double, String)] = [(1e9, "Gbps"), (1e6, "Mbps"), (1e3, "Kbps")]
        for (size, name) in units where bitsPerSecond >= size {
            let value = bitsPerSecond / size
            return value < 10 ? String(format: "%.1f %@", value, name) : "\(Int(value.rounded())) \(name)"
        }
        return "\(Int(bitsPerSecond.rounded())) bps"
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }
}
