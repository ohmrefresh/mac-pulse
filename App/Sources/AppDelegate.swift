import AppKit
import SwiftUI
import PulseCore
import PulseEngine
import PulseStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    /// History is optional: if the database cannot be opened the app still monitors live.
    let metrics: LiveMetrics = {
        let recorder = (try? HistoryStore(url: HistoryStore.defaultURL())).map { HistoryRecorder(store: $0) }
        return LiveMetrics(recorder: recorder)
    }()
    private(set) lazy var settings = AppSettings(metrics: metrics)
    let notifier = AlertNotifier()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting unit tests: don't touch the menu bar, the network or the real history database.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        popover.behavior = .transient
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = Self.statusFont
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        settings.onMenuBarChange = { [weak self] in
            self?.resizeStatusItem()
            self?.updateStatusTitle()
        }
        metrics.onAlert = { [weak self] event in self?.notifier.deliver(event) }
        settings.onAlertEnabled = { [weak self] in
            guard let notifier = self?.notifier else { return }
            Task { await notifier.requestAuthorizationIfNeeded() }
        }
        settings.applyAtLaunch()
        observeSleepWake()
        resizeStatusItem()
        metrics.start()
        updateStatusTitle()
    }

    private static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// Fixed width: a variable-length item relayouts the whole menu bar on every title change,
    /// which dominated idle CPU. Sized for the widest string the enabled items can produce.
    private func resizeStatusItem() {
        let items = settings.menuBarItems
        guard !items.isEmpty else {
            statusItem?.length = NSStatusItem.squareLength
            return
        }
        let widest = statusTitle(items.map { ($0, MenuBarFormatter.widestSegment($0)) })
        statusItem?.length = ceil(widest.size().width + 12)
    }

    /// Segment text with an optional template SF Symbol before each item. Template images follow the
    /// menu bar's light/dark/highlighted appearance like the system's own items.
    private func statusTitle(_ segments: [(item: MenuBarItem, text: String)]) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.statusFont]
        let title = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: MenuBarFormatter.separator, attributes: attributes)) }
            if settings.menuBarShowsIcons, let image = Self.symbolImage(for: segment.item) {
                let attachment = NSTextAttachment()
                attachment.image = image
                // Center the glyph on the text's cap height rather than sitting on the baseline.
                attachment.bounds = CGRect(x: 0, y: (Self.statusFont.capHeight - image.size.height) / 2,
                                           width: image.size.width, height: image.size.height)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: attributes))
            }
            title.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return title
    }

    private static var symbolImages: [MenuBarItem: NSImage] = [:]

    private static func symbolImage(for item: MenuBarItem) -> NSImage? {
        if let cached = symbolImages[item] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize - 1, weight: .regular)
        let image = NSImage(systemSymbolName: MenuBarFormatter.symbol(for: item), accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        symbolImages[item] = image
        return image
    }

    /// Each title change costs a menu-bar redraw (the largest idle CPU cost), so the text refreshes
    /// at most this often even though metrics are collected every second.
    private static let titleRefreshInterval: Duration = .seconds(2)
    private var lastTitleUpdate: ContinuousClock.Instant?
    private var titleUpdatePending = false
    /// What the title currently shows. `button.title` can't be compared: with attachments it contains
    /// placeholder characters, so every tick would look like a change and relayout the menu bar.
    private var shownTitleKey: String?

    /// Re-renders the menu-bar text when readings it depends on change, throttled.
    private func updateStatusTitle() {
        lastTitleUpdate = .now
        withObservationTracking {
            let items = settings.menuBarItems
            // With every metric disabled, show an icon so the app stays reachable.
            let segments = items.isEmpty ? [] : MenuBarFormatter.segments(items, metrics.menuBarInputs)
            let key = "\(settings.menuBarShowsIcons)|" + segments.map(\.text).joined(separator: MenuBarFormatter.separator)
            if key != shownTitleKey {
                shownTitleKey = key
                statusItem?.button?.attributedTitle = statusTitle(segments)
            }
            if items.isEmpty, statusItem?.button?.image == nil {
                statusItem?.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Mac Pulse")
            } else if !items.isEmpty {
                statusItem?.button?.image = nil
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.scheduleTitleUpdate() }
        }
    }

    private func scheduleTitleUpdate() {
        guard !titleUpdatePending else { return }
        titleUpdatePending = true
        let due = (lastTitleUpdate ?? .now) + Self.titleRefreshInterval
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: due, tolerance: .milliseconds(200))
            guard let self else { return }
            titleUpdatePending = false
            updateStatusTitle()
        }
    }

    /// Sleep/wake explain gaps in history (plan decision 9: system events).
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.metrics.post(TimelineEvent(time: Date(), category: .system, severity: .healthy, title: "Mac went to sleep"))
                Task { await self?.metrics.flushHistory() }
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.metrics.expedite([.disk]) }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.metrics.post(TimelineEvent(time: Date(), category: .system, severity: .healthy, title: "Mac woke up"))
            }
        }
    }

    /// Flush buffered history (up to 30 s) before exiting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard metrics.recorder != nil else { return .terminateNow }
        Task { @MainActor in
            await metrics.flushHistory()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func popoverDidClose(_ notification: Notification) {
        // A hidden hosted SwiftUI view keeps observing metrics and re-rendering; drop it.
        popover.contentViewController = nil
    }

    func openDashboard() {
        popover.performClose(nil)
        if dashboardWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: DashboardView(metrics: metrics, settings: settings, notifier: notifier)))
            window.title = "Mac Pulse"
            // Each section draws its own large title (mockup); keep the name for the Window menu and Mission Control.
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1100, height: 760))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("Dashboard")
            window.center()
            dashboardWindow = window
        }
        NSApp.activate()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        // Since macOS 14 activation is cooperative and can be declined, leaving the window behind
        // the active app. Still bring it forward, unfocused.
        if !NSApp.isActive { dashboardWindow?.orderFrontRegardless() }
    }

    func windowWillClose(_ notification: Notification) {
        // Same reason as the popover: a closed window must not keep re-rendering.
        dashboardWindow?.contentViewController = nil
        dashboardWindow = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentViewController = NSHostingController(
                rootView: PopoverView(metrics: metrics, openDashboard: { [weak self] in self?.openDashboard() }))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
