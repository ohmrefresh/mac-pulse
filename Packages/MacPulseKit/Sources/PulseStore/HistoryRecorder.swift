import Foundation
import PulseCore

/// Write side of the store, separated so failure handling can be tested.
protocol HistoryWriting: Sendable {
    func write(samples: [MetricSample], processes: [ProcessSample], events: [TimelineEvent],
               now: Date, retention: RetentionPreset) throws
}

extension HistoryStore: HistoryWriting {}

/// Buffers samples in memory and writes them in one transaction every `flushInterval`
/// (PRD §18: disk writes minimal/buffered). A crash loses at most one interval.
public actor HistoryRecorder {
    public nonisolated let store: HistoryStore
    private let writer: any HistoryWriting
    private let flushInterval: TimeInterval
    private var retention: RetentionPreset
    private var samples: [MetricSample] = []
    private var processes: [ProcessSample] = []
    private var events: [TimelineEvent] = []
    private var loop: Task<Void, Never>?
    /// Last write error, surfaced rather than silently dropping history.
    public private(set) var lastError: String?
    /// Called when `lastError` changes (set or cleared).
    private var onErrorChange: (@Sendable (String?) -> Void)?

    public func setErrorHandler(_ handler: @escaping @Sendable (String?) -> Void) {
        onErrorChange = handler
    }

    public init(store: HistoryStore, flushInterval: TimeInterval = 30, retention: RetentionPreset = .thirtyDays) {
        self.init(store: store, writer: store, flushInterval: flushInterval, retention: retention)
    }

    init(store: HistoryStore, writer: any HistoryWriting, flushInterval: TimeInterval = 30, retention: RetentionPreset = .thirtyDays) {
        self.store = store
        self.writer = writer
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

    public func record(event: TimelineEvent) {
        events.append(event)
    }

    public func setRetention(_ preset: RetentionPreset) {
        retention = preset
    }

    /// Writes everything buffered. Also call on quit.
    public func flush(now: Date = Date()) {
        let batch = samples, processBatch = processes, eventBatch = events
        samples.removeAll(keepingCapacity: true)
        processes.removeAll(keepingCapacity: true)
        events.removeAll(keepingCapacity: true)
        let previous = lastError
        do {
            try writer.write(samples: batch, processes: processBatch, events: eventBatch, now: now, retention: retention)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        if lastError != previous { onErrorChange?(lastError) }
    }

    public func clear() throws {
        samples.removeAll()
        processes.removeAll()
        events.removeAll()
        try store.clear()
    }
}
