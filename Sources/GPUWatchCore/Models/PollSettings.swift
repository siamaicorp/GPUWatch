import Foundation

/// User-tunable runtime behaviour.
public struct PollSettings: Codable, Equatable, Sendable {
    /// Allowed poll intervals, in seconds, exposed in Settings.
    public static let allowedIntervals: [Int] = [15, 30, 60, 120]
    public static let defaultInterval = 30
    /// Ceiling on hosts checked at once. Keeps a large fleet from opening more
    /// ssh children than the machine or the network wants to carry.
    public static let maxConcurrencyCeiling = 8

    public var intervalSeconds: Int
    public var maxConcurrentChecks: Int
    public var notificationsEnabled: Bool
    public var launchAtLogin: Bool

    public init(
        intervalSeconds: Int = PollSettings.defaultInterval,
        maxConcurrentChecks: Int = 5,
        notificationsEnabled: Bool = false,
        launchAtLogin: Bool = false
    ) {
        self.intervalSeconds = intervalSeconds
        self.maxConcurrentChecks = maxConcurrentChecks
        self.notificationsEnabled = notificationsEnabled
        self.launchAtLogin = launchAtLogin
    }

    /// A reading older than this is no longer presented as current. Scales with
    /// the poll interval so a slow poll cadence is not punished, but never dips
    /// below a minute so a fast cadence still tolerates a hiccup.
    public var staleWindowSeconds: TimeInterval {
        max(2 * Double(intervalSeconds), 60)
    }

    /// Sanitised copy: guards against a hand-edited config file producing an
    /// unusable poller.
    public var normalized: PollSettings {
        var copy = self
        if !PollSettings.allowedIntervals.contains(copy.intervalSeconds) {
            copy.intervalSeconds = PollSettings.defaultInterval
        }
        copy.maxConcurrentChecks = min(max(copy.maxConcurrentChecks, 1), PollSettings.maxConcurrencyCeiling)
        return copy
    }
}
