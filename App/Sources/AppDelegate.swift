import AppKit
import SwiftUI
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
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        settings.applyAtLaunch()
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
        let widest = MenuBarFormatter.widestText(items)
        let width = (widest as NSString).size(withAttributes: [.font: Self.statusFont]).width + 12
        statusItem?.length = ceil(width)
    }

    /// Each title change costs a menu-bar redraw (the largest idle CPU cost), so the text refreshes
    /// at most this often even though metrics are collected every second.
    private static let titleRefreshInterval: Duration = .seconds(2)
    private var lastTitleUpdate: ContinuousClock.Instant?
    private var titleUpdatePending = false

    /// Re-renders the menu-bar text when readings it depends on change, throttled.
    private func updateStatusTitle() {
        lastTitleUpdate = .now
        withObservationTracking {
            let items = settings.menuBarItems
            // With every metric disabled, show an icon so the app stays reachable.
            let title = items.isEmpty ? "" : MenuBarFormatter.text(items, metrics.menuBarInputs)
            if statusItem?.button?.title != title { statusItem?.button?.title = title }
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: DashboardView(metrics: metrics)))
            window.title = "Mac Pulse"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 980, height: 660))
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
