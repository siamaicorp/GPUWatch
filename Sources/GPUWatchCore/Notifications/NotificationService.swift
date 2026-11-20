import Foundation

/// A notification the service has decided is worth delivering.
public struct PendingNotification: Equatable, Sendable {
    public let identifier: String
    public let hostID: UUID
    public let title: String
    public let body: String
    /// Distinguishes a new problem from a recovery, so the caller can pick an
    /// icon or sound without re-deriving anything.
    public let isRecovery: Bool
}

/// The alarming condition a host is currently in, as far as alerts are
/// concerned. Deliberately coarse: one condition per host, so a flapping
/// host cannot generate a burst of different alerts.
public enum HostAlertCondition: Equatable, Sendable {
    case normal
    case unreachable(SSHFailureKind)
    case gpuQueryFailed(GPUQueryFailureReason)
    case gpusMissing(count: Int)
    case gpuWarning(count: Int)

    /// Stable key used for cooldown tracking and for "did the condition change".
    var key: String {
        switch self {
        case .normal: return "normal"
        case let .unreachable(kind): return "unreachable.\(kind.rawValue)"
        case let .gpuQueryFailed(reason): return "queryFailed.\(reason.rawValue)"
        case .gpusMissing: return "gpusMissing"
        case .gpuWarning: return "gpuWarning"
        }
    }

    var isProblem: Bool { self != .normal }
}

/// Decides when a notification is warranted.
///
/// The rules exist because the underlying signals are noisy:
///
/// - **Two consecutive confirmations.** A single failed poll is usually a
///   hiccup; a laptop lid, a wifi blip, a server under load. Alerting on the
///   first failure trains people to ignore the app.
/// - **Change only.** A host that stays broken says so once, not every 30s.
/// - **Cooldown.** Even a genuinely flapping host is capped to one alert per
///   window.
/// - **Recovery is announced.** Otherwise the last thing the operator saw was a
///   problem, and a silent fix is indistinguishable from a broken monitor.
///   Recovery goes through the same confirmation streak as a problem, so a host
///   bouncing between states does not produce an alternating pair of banners.
/// - **Recovery is never announced from a cache.** Recovery requires a current,
///   complete reading; a stale carry-forward or a baseline reset can't fake it.
///
/// The "never alert missing GPUs from a transport failure" rule is enforced
/// upstream rather than here: a failed transport produces `missing == 0`, so
/// this type cannot construct that alert even if it wanted to.
public final class NotificationService: @unchecked Sendable {
    public struct Options: Equatable, Sendable {
        /// Consecutive matching observations required before alerting.
        public var confirmationsRequired: Int
        /// Minimum gap between two deliveries of the same alert key.
        public var cooldownSeconds: TimeInterval

        public init(confirmationsRequired: Int = 2, cooldownSeconds: TimeInterval = 1800) {
            self.confirmationsRequired = confirmationsRequired
            self.cooldownSeconds = cooldownSeconds
        }

        public static let `default` = Options()
    }

    private struct Pending {
        var condition: HostAlertCondition
        var observations: Int
    }

    private let options: Options
    private let lock = NSLock()
    /// Condition awaiting its confirmation streak, per host.
    private var pending: [UUID: Pending] = [:]
    /// Last condition we actually told the user about, per host.
    private var announced: [UUID: HostAlertCondition] = [:]
    /// Last delivery time per alert key, for cooldown.
    private var lastDelivery: [String: Date] = [:]

    public init(options: Options = .default) {
        self.options = options
    }

    /// Feeds one round of results in and returns whatever should be delivered.
    ///
    /// Synchronous and side-effect-free apart from its own bookkeeping, so the
    /// debounce and cooldown behaviour can be tested without a notification
    /// centre or a real clock.
    public func evaluate(reports: [HostReport], now: Date) -> [PendingNotification] {
        lock.lock()
        defer { lock.unlock() }

        var outgoing: [PendingNotification] = []

        for report in reports {
            let hostID = report.host.id
            guard report.host.enabled else { continue }
            let condition = Self.condition(for: report)

            // A condition we have not confirmed yet accumulates observations.
            var candidate = pending[hostID] ?? Pending(condition: condition, observations: 0)
            if candidate.condition == condition {
                candidate.observations += 1
            } else {
                candidate = Pending(condition: condition, observations: 1)
            }
            pending[hostID] = candidate

            guard candidate.observations >= options.confirmationsRequired else { continue }

            let previous = announced[hostID] ?? .normal
            guard previous != condition else { continue }

            if condition.isProblem {
                if let notification = makeProblemNotification(
                    report: report, condition: condition, now: now
                ) {
                    outgoing.append(notification)
                    announced[hostID] = condition
                }
            } else {
                // Recovery must be backed by a reading taken right now. Without
                // this check, a stale cache or a wiped baseline would look like
                // a fix and we would tell the user something we cannot support.
                guard report.hasCurrentCompleteReading || report.ssh.isOK else { continue }
                if let notification = makeRecoveryNotification(report: report, previous: previous, now: now) {
                    outgoing.append(notification)
                    announced[hostID] = .normal
                }
            }
        }

        return outgoing
    }

    // MARK: - Condition derivation

    /// Maps a report onto one alert condition, in priority order: transport
    /// first, then the GPU query, then GPU-level findings.
    public static func condition(for report: HostReport) -> HostAlertCondition {
        if case let .failed(kind, _) = report.ssh {
            // A cancelled check is something the user did, not a fault.
            return kind == .cancelled ? .normal : .unreachable(kind)
        }
        if case let .failed(reason, _) = report.query {
            return .gpuQueryFailed(reason)
        }
        if report.counts.missing > 0 {
            return .gpusMissing(count: report.counts.missing)
        }
        if report.counts.warnings > 0 {
            return .gpuWarning(count: report.counts.warnings)
        }
        return .normal
    }

    // MARK: - Notification construction

    private func makeProblemNotification(
        report: HostReport,
        condition: HostAlertCondition,
        now: Date
    ) -> PendingNotification? {
        let key = "host:\(report.host.id.uuidString):\(condition.key)"
        guard isOutsideCooldown(key: key, now: now) else { return nil }

        let name = report.host.effectiveName
        let title: String
        let body: String

        switch condition {
        case .normal:
            return nil
        case let .unreachable(kind):
            title = "\(name) unreachable"
            body = kind == .authenticationFailed
                ? "SSH authentication failed. GPU status is unknown."
                : "Could not reach the host over SSH. GPU status is unknown."
        case let .gpuQueryFailed(reason):
            title = "\(name) GPU query failed"
            body = "\(reason.userFacingMessage) GPU status is unknown."
        case let .gpusMissing(count):
            let uuids = report.missingUUIDs.prefix(3).joined(separator: ", ")
            title = "\(count) GPU\(count == 1 ? "" : "s") missing on \(name)"
            body = uuids.isEmpty
                ? "A complete check did not find them."
                : "Not present in the latest complete check: \(uuids)"
        case let .gpuWarning(count):
            let warnings = report.gpus.flatMap(\.health.warnings).prefix(2)
            // The two kinds are labelled in the body. An alert that only said
            // "GPU warning" would leave the operator unable to tell a card that
            // stopped answering from one that is simply busy — which is the
            // distinction the whole app is about.
            let described = warnings.map { warning -> String in
                switch warning.kind {
                case .readability: return warning.text
                case .pressure: return "load: \(warning.text)"
                }
            }
            title = "\(name): \(count) GPU warning\(count == 1 ? "" : "s")"
            body = described.isEmpty
                ? "A configured threshold was exceeded."
                : described.joined(separator: "; ")
        }

        lastDelivery[key] = now
        return PendingNotification(
            identifier: key,
            hostID: report.host.id,
            title: title,
            body: body,
            isRecovery: false
        )
    }

    private func makeRecoveryNotification(
        report: HostReport,
        previous: HostAlertCondition,
        now: Date
    ) -> PendingNotification? {
        guard previous.isProblem else { return nil }
        let key = "host:\(report.host.id.uuidString):recovered"
        guard isOutsideCooldown(key: key, now: now) else { return nil }

        lastDelivery[key] = now
        let name = report.host.effectiveName
        let detail = report.counts.expected > 0
            ? "\(report.counts.readable)/\(report.counts.expected) GPUs readable."
            : "\(report.counts.readable) GPUs readable."
        return PendingNotification(
            identifier: key,
            hostID: report.host.id,
            title: "\(name) recovered",
            body: detail,
            isRecovery: true
        )
    }

    private func isOutsideCooldown(key: String, now: Date) -> Bool {
        guard let last = lastDelivery[key] else { return true }
        return now.timeIntervalSince(last) >= options.cooldownSeconds
    }

    // MARK: - State resets

    /// Forgets everything about one host. Called when a host is deleted or
    /// edited, so a stale streak cannot follow the old identity.
    public func forget(hostID: UUID) {
        lock.lock()
        pending.removeValue(forKey: hostID)
        announced.removeValue(forKey: hostID)
        lastDelivery = lastDelivery.filter { !$0.key.contains(hostID.uuidString) }
        lock.unlock()
    }

    /// Forgets everything. Called when the baseline is re-registered, when demo
    /// mode is toggled, or when the user disables notifications.
    ///
    /// Deliberately emits no recovery: a baseline reset is a bookkeeping action,
    /// not evidence that a host got better.
    public func forgetAll() {
        lock.lock()
        pending.removeAll()
        announced.removeAll()
        lastDelivery.removeAll()
        lock.unlock()
    }

    /// Exposed for tests and for the Settings pane.
    public func announcedCondition(for hostID: UUID) -> HostAlertCondition {
        lock.lock()
        defer { lock.unlock() }
        return announced[hostID] ?? .normal
    }
}

// MARK: - Delivery

/// Anything that can ask for permission and present a banner.
public protocol NotificationDelivering: Sendable {
    /// Returns `true` when notifications are authorised.
    func requestAuthorization() async -> Bool
    func deliver(_ notifications: [PendingNotification]) async
}
