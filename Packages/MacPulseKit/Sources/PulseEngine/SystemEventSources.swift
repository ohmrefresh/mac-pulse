import Foundation
import IOKit.ps

/// System notifications that make a metric change worth sampling immediately instead of waiting
/// for its cadence: memory pressure, thermal state and power source (AC ↔ battery).
/// Disk mount/unmount lives in the app (NSWorkspace) and calls `LiveMetrics.expedite` directly.
@MainActor
final class SystemEventSources {
    private let onChange: @MainActor (Set<SamplingJob>) -> Void
    // Written only in init; read in deinit, which runs where the owner (LiveMetrics, main actor)
    // releases this object. `isolated deinit` would need a newer OS runtime than macOS 14.
    nonisolated(unsafe) private var memorySource: DispatchSourceMemoryPressure?
    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?

    init(onChange: @escaping @MainActor (Set<SamplingJob>) -> Void) {
        self.onChange = onChange

        let memory = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memory.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.onChange([.fast]) } }
        memory.resume()
        memorySource = memory

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onChange([.power]) } }

        // IOKit's C callback carries an unretained pointer back to self; the source is removed in deinit.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let sources = Unmanaged<SystemEventSources>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { sources.onChange([.power]) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    deinit {
        memorySource?.cancel()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }
}
