import SwiftUI

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Settings { SettingsView(settings: appDelegate.settings) }
    }
}
