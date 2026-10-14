import Foundation
import os

/// Opt-in, bounded local timing. Labels are fixed; documents, paths and pixels are never recorded.
nonisolated final class PerformanceRecorder: @unchecked Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case toolSwitch, brushUpdate, brushCommit, liquifyPreview, filterPreview, gpuWait, gifPreview, gifEncode, gifDecode, recoveryCapture, recoveryWrite
    }
    struct Summary: Sendable {
        let operation: Operation
        let count: Int
        let medianMS: Double
        let p95MS: Double
        let maximumMS: Double
    }
    private struct Samples {
        var count = 0
        var recent: [Double] = []
        var maximum = 0.0
    }
    static let shared = PerformanceRecorder(enabled: ProcessInfo.processInfo.environment["COMPOSITOR_PERFORMANCE"] == "1", logs: true)
    private let enabled: Bool
    private let logs: Bool
    private let lock = NSLock()
    private var samples: [Operation: Samples] = [:]
    private let logger = Logger(subsystem: "com.wonderassembly.compositor.performance", category: "timing")
    init(enabled: Bool, logs: Bool = false) { self.enabled = enabled; self.logs = logs }
    func begin() -> UInt64 { enabled ? DispatchTime.now().uptimeNanoseconds : 0 }
    func end(_ operation: Operation, since started: UInt64) {
        guard enabled, started != 0 else { return }
        record(operation, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }
    func record(_ operation: Operation, milliseconds: Double) {
        guard enabled, milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        var entry = samples[operation] ?? Samples()
        entry.count += 1
        entry.maximum = max(entry.maximum, milliseconds)
        if entry.recent.count == 512 { entry.recent.removeFirst() }
        entry.recent.append(milliseconds)
        samples[operation] = entry
        let report = logs && (entry.count == 1 || entry.count % 60 == 0)
        lock.unlock()
        if report {
            logger.info("\(operation.rawValue, privacy: .public) sample_ms=\(milliseconds, privacy: .public)")
        }
    }
    func summaries() -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        return Operation.allCases.compactMap { operation in
            guard let entry = samples[operation], !entry.recent.isEmpty else { return nil }
            let sorted = entry.recent.sorted()
            return Summary(operation: operation, count: entry.count, medianMS: sorted[(sorted.count - 1) / 2],
                p95MS: sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)], maximumMS: entry.maximum)
        }
    }
}
