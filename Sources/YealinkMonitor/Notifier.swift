import Foundation
import UserNotifications
import YMCSKit

/// Turns confirmed status changes into user notifications.
///
/// Everything here is about *not* notifying: the debounce upstream, plus quiet
/// hours and per-device mutes here. A monitor that cries wolf gets muted
/// entirely, which is worse than one that occasionally tells you late.
@MainActor
final class Notifier {
    private var isAuthorized = false
    private var hasRequestedAuthorization = false

    /// Requests permission. Safe to call repeatedly.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        do {
            isAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // Unsigned or unbundled builds cannot show notifications. The app
            // must still run and display status in the menu bar.
            isAuthorized = false
        }
    }

    var canNotify: Bool { isAuthorized }

    func post(_ change: StatusChange, settings: AppSettings, snapshot: MonitorSnapshot, now: Date = Date()) {
        guard settings.notificationsEnabled, isAuthorized else { return }
        guard !settings.mutedDeviceIDs.contains(change.device.id) else { return }
        if change.isRecovery && !settings.notifyOnRecovery { return }
        // Quiet hours suppress routine alerts. The status is still recorded and
        // still visible in the menu bar; only the interruption is withheld.
        if settings.isQuietHour(now) { return }

        let content = UNMutableNotificationContent()
        let name = change.device.displayName
        let site = snapshot.siteName(for: change.device)

        switch change.to {
        case .online:
            content.title = "\(name) is back online"
        case .offline:
            content.title = "\(name) went offline"
        case .pending:
            content.title = "\(name) has never reported in"
        case .unknown(let raw):
            content.title = "\(name) reported an unrecognised status (\(raw))"
        }

        var lines: [String] = [Device.formatMAC(change.device.mac)]
        if let model = snapshot.modelName(for: change.device) { lines.append(model) }
        if let site { lines.append(site) }
        content.body = lines.joined(separator: " · ")
        content.sound = change.isRegression ? .default : nil

        let request = UNNotificationRequest(
            identifier: change.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
