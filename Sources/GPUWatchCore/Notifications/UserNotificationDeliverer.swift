import Foundation
import UserNotifications

/// Presents alerts through UNUserNotificationCenter.
///
/// Permission is only ever requested after the operator turns notifications on
/// in Settings — never at launch, and never as a side effect of adding a host.
public final class UserNotificationDeliverer: NotificationDelivering, @unchecked Sendable {
    private let override: UNUserNotificationCenter?
    private let lock = NSLock()
    private var resolved: UNUserNotificationCenter?
    private var authorizationKnown = false
    private var authorized = false

    public init(center: UNUserNotificationCenter? = nil) {
        self.override = center
    }

    /// Resolved lazily. `UNUserNotificationCenter.current()` raises when the
    /// process is not a bundled application — which is true for the snapshot
    /// harness and for `swift test` — so it must not run during construction.
    private var center: UNUserNotificationCenter {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let value = override ?? UNUserNotificationCenter.current()
        resolved = value
        return value
    }

    public func requestAuthorization() async -> Bool {
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // A local ad-hoc-signed build can be refused here; the app stays
            // usable and the Settings pane reports that permission is missing.
            granted = false
        }
        recordAuthorization(granted)
        return granted
    }

    /// Whether we know we may post. `false` after the user has denied, which the
    /// Settings pane surfaces so the toggle is not silently ineffective.
    public var isAuthorized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return authorizationKnown && authorized
    }

    /// Kept synchronous and separate: locking directly inside an `async`
    /// function is an error under the Swift 6 language mode, and the state it
    /// guards is trivial.
    private func recordAuthorization(_ granted: Bool) {
        lock.lock()
        authorized = granted
        authorizationKnown = true
        lock.unlock()
    }

    public func deliver(_ notifications: [PendingNotification]) async {
        guard !notifications.isEmpty else { return }
        if !isAuthorized {
            // Re-check rather than trusting a stale local flag.
            let settings = await center.notificationSettings()
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard allowed else { return }
            recordAuthorization(true)
        }

        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            // Group per host so a burst for one machine stacks instead of
            // scattering across Notification Center.
            content.threadIdentifier = notification.hostID.uuidString

            let request = UNNotificationRequest(
                identifier: notification.identifier + "-" + UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

/// Used by Demo Mode and by tests: notifications never reach the system.
public struct NoopNotificationDeliverer: NotificationDelivering {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func deliver(_ notifications: [PendingNotification]) async {}
}
