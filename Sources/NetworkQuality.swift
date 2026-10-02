// Runs Apple's built-in `networkQuality` speed and responsiveness test from the panel.
import Foundation
import os

private let qualityLog = Logger(subsystem: "local.netindicator", category: "quality")

struct QualityResult: Equatable {
    let download: Double          // bits per second
    let upload: Double            // bits per second
    let responsiveness: String    // Apple's rating: High, Medium or Low
    let delayUnderLoad: String?   // e.g. "1.5 s", how long requests took while the line was busy
    let idleLatency: String?      // e.g. "524 ms"
    let date: Date

    /// Parses the summary networkQuality prints, e.g.
    ///     Uplink capacity: 102.019 Mbps
    ///     Downlink capacity: 167.813 Mbps
    ///     Responsiveness: Low (1.543 seconds | 38 RPM)
    ///     Idle Latency: 524.478 milliseconds | 114 RPM
    init?(summary: String, date: Date = Date()) {
        var values: [String: String] = [:]
        for line in summary.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let download = values["downlink capacity"].flatMap(Self.bitsPerSecond),
              let upload = values["uplink capacity"].flatMap(Self.bitsPerSecond),
              let responsiveness = values["responsiveness"] else { return nil }
        self.download = download
        self.upload = upload
        self.responsiveness = responsiveness.split(separator: " ").first.map(String.init) ?? responsiveness
        // "(1.543 seconds | 38 RPM)" -> "1.5 s"
        let inParentheses = responsiveness.split(separator: "(").dropFirst().first.map { String($0) }
        delayUnderLoad = inParentheses.flatMap(Self.duration)
        idleLatency = values["idle latency"].flatMap(Self.duration)
        self.date = date
    }

    private static func bitsPerSecond(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0]) else { return nil }
        switch parts[1].lowercased() {
        case "gbps": return value * 1e9
        case "mbps": return value * 1e6
        case "kbps": return value * 1e3
        case "bps": return value
        default: return nil
        }
    }

    /// "1.543 seconds | 38 RPM" -> "1.5 s"; "524.478 milliseconds | 114 RPM" -> "524 ms".
    private static func duration(_ text: String) -> String? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0]) else { return nil }
        let seconds = parts[1].hasPrefix("milli") ? value / 1000 : value
        return seconds >= 1 ? String(format: "%.1f s", seconds) : "\(Int((seconds * 1000).rounded())) ms"
    }
}

final class QualityTest: ObservableObject {
    enum State: Equatable {
        case idle
        case running(since: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastResult: QualityResult?

    private var process: Process?
    private var stoppedByUser = false

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func loadDemo() {
        lastResult = QualityResult(summary: """
            Uplink capacity: 102.019 Mbps
            Downlink capacity: 167.813 Mbps
            Responsiveness: Low (1.543 seconds | 38 RPM)
            Idle Latency: 524.478 milliseconds | 114 RPM
            """)
    }

    private func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        stoppedByUser = false
        do {
            try process.run()
        } catch {
            state = .failed("Couldn’t start the test: \(error.localizedDescription)")
            return
        }
        self.process = process
        state = .running(since: Date())
        qualityLog.notice("test started")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Reading to end of file drains the pipe as the test runs, so it can never fill up and stall.
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let result = QualityResult(summary: output)
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if let result {
                    self.lastResult = result
                    self.state = .idle
                    qualityLog.notice("test finished: down \(Int(result.download / 1e6)) Mbps, up \(Int(result.upload / 1e6)) Mbps, responsiveness \(result.responsiveness, privacy: .public)")
                } else if self.stoppedByUser {
                    self.state = .idle
                    qualityLog.notice("test stopped")
                } else {
                    let reason = output.split(separator: "\n").last.map(String.init) ?? "No result"
                    self.state = .failed(reason)
                    qualityLog.error("test failed (exit \(process.terminationStatus)): \(reason, privacy: .public)")
                }
            }
        }
    }

    private func stop() {
        stoppedByUser = true
        process?.terminate()
    }
}
