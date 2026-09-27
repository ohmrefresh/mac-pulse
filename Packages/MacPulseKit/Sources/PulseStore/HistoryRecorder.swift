import Foundation
import PulseCore

/// Buffers samples in memory and writes them in one transaction every `flushInterval`
/// (PRD §18: disk writes minimal/buffered). A crash loses at most one interval.
public actor HistoryRecorder {
    public nonisolated let store: HistoryStore
    private let flushInterval: TimeInterval
    private var retention: RetentionPreset
    private var samples: [MetricSample] = []
    private var processes: [ProcessSample] = []
    private var loop: Task<Void, Never>?
    /// Last write error, surfaced rather than silently dropping history.
    public private(set) var lastError: String?

    public init(store: HistoryStore, flushInterval: TimeInterval = 30, retention: RetentionPreset = .thirtyDays) {
        self.store = store
        self.flushInterval = flushInterval
        self.retention = retention
    }

    public func start() {
        loop?.cancel()
        let interval = flushInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.2))
                await self?.flush()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func record(_ newSamples: [MetricSample]) {
        samples.append(contentsOf: newSamples)
    }

    public func record(processes newProcesses: [ProcessSample]) {
        processes.append(contentsOf: newProcesses)
    }

    public func setRetention(_ preset: RetentionPreset) {
        retention = preset
    }

    /// Writes everything buffered. Also call on quit.
    public func flush(now: Date = Date()) {
        let batch = samples, processBatch = processes
        samples.removeAll(keepingCapacity: true)
        processes.removeAll(keepingCapacity: true)
        do {
            try store.write(samples: batch, processes: processBatch, now: now, retention: retention)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    public func clear() throws {
        samples.removeAll()
        processes.removeAll()
        try store.clear()
    }
}
