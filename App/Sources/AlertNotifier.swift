import Foundation
import Observation
import UserNotifications
import PulseCore
import PulseEngine

/// Delivers alert notifications (PRD §11). Permission is requested only when the user first
/// enables a rule (plan decision 7), never at launch.
@MainActor
@Observable
final class AlertNotifier {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func deliver(_ event: AlertEvent, unit: TemperatureUnit = .celsius) {
        guard event.kind == .fired, event.shouldNotify else { return }
        let rule = event.rule
        let content = UNMutableNotificationContent()
        content.title = rule.name
        content.body = "\(rule.metric.displayName) is \(Format.alertValue(rule.metric, event.value, unit: unit))"
            + (rule.duration > 0 ? " (held for \(Int(rule.duration)) s)." : ".")
        if rule.severity == .critical { content.sound = .default }
        // Same identifier per rule: a repeat replaces the previous banner instead of stacking.
        let request = UNNotificationRequest(identifier: "alert-\(rule.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
