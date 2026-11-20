import Foundation

/// GPU tallies for one host, or for the whole fleet.
///
/// The fields are deliberately non-overlapping so a caller cannot accidentally
/// count an unknown slot as a healthy GPU. `readable` counts only GPUs actually
/// read in the latest complete check; carried-forward values never increment
/// it.
public struct GPUCounts: Equatable, Sendable {
    public var expected: Int
    public var readable: Int
    public var warnings: Int
    /// GPUs we can positively state are gone, backed by a complete query.
    public var missing: Int
    /// Slots we know should exist but cannot account for, because the data is
    /// incomplete, stale or unavailable.
    public var unknown: Int
    /// GPUs present that are not in the baseline.
    public var unexpected: Int

    public init(
        expected: Int = 0,
        readable: Int = 0,
        warnings: Int = 0,
        missing: Int = 0,
        unknown: Int = 0,
        unexpected: Int = 0
    ) {
        self.expected = expected
        self.readable = readable
        self.warnings = warnings
        self.missing = missing
        self.unknown = unknown
        self.unexpected = unexpected
    }

    public static func + (lhs: GPUCounts, rhs: GPUCounts) -> GPUCounts {
        GPUCounts(
            expected: lhs.expected + rhs.expected,
            readable: lhs.readable + rhs.readable,
            warnings: lhs.warnings + rhs.warnings,
            missing: lhs.missing + rhs.missing,
            unknown: lhs.unknown + rhs.unknown,
            unexpected: lhs.unexpected + rhs.unexpected
        )
    }

    /// Compact `readable/expected` text. Shows `?` when the expected count is
    /// not configured, because a ratio against an unknown denominator is a
    /// fabricated claim.
    public var ratioText: String {
        expected > 0 ? "\(readable)/\(expected)" : "\(readable)/?"
    }


    /// Whether this host is fully accounted for: every expected GPU readable
    /// and nothing unexplained.
    ///
    /// When the user has not set an expected count (`expected == 0`) there is no
    /// denominator to fall short of, so the bar is simply "we read something and
    /// nothing is unexplained". Crucially, when an expectation *does* exist,
    /// reading more GPUs than expected is **not** complete — a surplus is a
    /// configuration problem, not a healthy host.
    public var isComplete: Bool {
        guard missing == 0, unknown == 0, unexpected == 0 else { return false }
        if expected == 0 { return readable > 0 }
        return readable == expected
    }
}

/// Everything known about one host at one moment.
public struct HostReport: Identifiable, Equatable, Sendable {
    public var id: UUID { host.id }
    public var host: HostConfig
    public var ssh: SSHOutcome
    public var query: GPUQueryOutcome
    public var freshness: Freshness
    public var gpus: [GPUReport]
    public var counts: GPUCounts
    /// When the most recent attempt started, successful or not.
    public var lastAttemptedAt: Date?
    /// When the last check completed with a usable GPU reading.
    public var lastSuccessfulAt: Date?
    /// Human-readable problems to surface in the row and detail pane.
    public var issues: [String]
    /// Warnings from the parser about rows or metrics it could not use.
    public var parseWarnings: [String]
    /// True when a baseline exists for this host.
    public var hasBaseline: Bool
    /// Baseline UUIDs that were confirmed absent by a complete query.
    public var missingUUIDs: [String]
    public var unexpectedGPUs: [UnexpectedGPU]
    /// Baseline UUIDs seen in the latest check. Empty when there is no baseline.
    public var confirmedBaselineUUIDs: Set<String>
    /// True when the host has never been checked in this session and we hold no
    /// earlier data either.
    public var neverChecked: Bool

    public init(
        host: HostConfig,
        ssh: SSHOutcome,
        query: GPUQueryOutcome,
        freshness: Freshness,
        gpus: [GPUReport],
        counts: GPUCounts,
        lastAttemptedAt: Date? = nil,
        lastSuccessfulAt: Date? = nil,
        issues: [String] = [],
        parseWarnings: [String] = [],
        hasBaseline: Bool = false,
        missingUUIDs: [String] = [],
        unexpectedGPUs: [UnexpectedGPU] = [],
        neverChecked: Bool = true,
        confirmedBaselineUUIDs: Set<String> = []
    ) {
        self.host = host
        self.ssh = ssh
        self.query = query
        self.freshness = freshness
        self.gpus = gpus
        self.counts = counts
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.issues = issues
        self.parseWarnings = parseWarnings
        self.hasBaseline = hasBaseline
        self.missingUUIDs = missingUUIDs
        self.unexpectedGPUs = unexpectedGPUs
        self.neverChecked = neverChecked
        self.confirmedBaselineUUIDs = confirmedBaselineUUIDs
    }

    /// The single label for this host row.
    public var displayState: HostDisplayState {
        if !host.enabled { return .disabled }
        if case .checking = ssh { return .checking }
        if neverChecked && !ssh.isOK && !ssh.isFailure { return .unknown }

        if case let .failed(kind, _) = ssh {
            // A transport failure leaves the GPU picture unknown; we do not
            // report the host as having missing GPUs.
            return .sshFailed(kind)
        }
        if case let .failed(reason, _) = query { return .gpuQueryFailed(reason) }
        if freshness == .stale { return .stale }
        if freshness == .unknown { return .unknown }
        // A warning does not make the count wrong — a hot GPU is still readable,
        // so the ratio stays 4/4 — but it does stop the row from reading "OK".
        if counts.isComplete, counts.warnings == 0 { return .healthy }
        return .degraded
    }

    /// One-line explanation for the row's second line, or `nil` when the host
    /// is fine and needs no explanation.
    public var statusDetail: String? {
        switch displayState {
        case .healthy, .disabled, .checking:
            return nil
        case let .sshFailed(kind):
            switch kind {
            case .hostKeyVerification:
                return "Verify the host key in Terminal, then retry"
            case .authenticationFailed:
                return "Check your SSH agent or key for this host"
            case .unreachable:
                return "Not reachable over SSH"
            case .cancelled:
                return "Check cancelled"
            case .timedOut:
                return "Check exceeded \(Int(CheckTimeoutBudget.wholeCheckSeconds))s"
            case .unknown:
                return issues.first ?? "SSH error"
            }
        case let .gpuQueryFailed(reason):
            return queryFailureDetail(reason)
        case .degraded:
            return issues.first ?? degradedSummary
        case .stale:
            return "Last known data only"
        case .unknown:
            return "No data yet"
        }
    }

    private func queryFailureDetail(_ reason: GPUQueryFailureReason) -> String {
        switch reason {
        case .gpuToolNotFound: return "SSH OK, GPU tool not installed"
        case .commandFailed: return "SSH OK, GPU query failed"
        case .emptyOutput: return "SSH OK, GPU query returned nothing"
        case .malformedOutput: return "SSH OK, GPU output not understood"
        case .transportFailure: return "SSH dropped before the query finished"
        }
    }

    private var degradedSummary: String {
        var parts: [String] = []
        if counts.missing > 0 { parts.append("\(counts.missing) missing") }
        if counts.unknown > 0 { parts.append("\(counts.unknown) unknown") }
        if counts.unexpected > 0 { parts.append("\(counts.unexpected) unexpected") }
        if counts.warnings > 0 { parts.append("\(counts.warnings) warning") }
        if counts.readable < counts.expected { parts.append("expected \(counts.expected)") }
        return parts.isEmpty ? "Incomplete data" : parts.joined(separator: ", ")
    }

    /// True only when the numbers on screen came from the latest complete
    /// check. Used to gate notifications and the menu bar headline.
    public var hasCurrentCompleteReading: Bool {
        ssh.isOK && query.isOK && freshness.isFresh
    }

    /// The headline count for a row: how many GPUs we can vouch for right now,
    /// over how many we expect.
    ///
    /// The numerator is `?` whenever there is no current reading. Rendering `0`
    /// there would read as "every GPU is dead" at the exact moment the truth is
    /// "we could not look" — the one confusion this app exists to avoid.
    public var ratioDisplay: String {
        // A disabled host has no reading to report, so a ratio would be noise.
        guard host.enabled else { return "—" }
        let expectedText = counts.expected > 0 ? String(counts.expected) : "?"
        guard hasCurrentCompleteReading else { return "?/\(expectedText)" }
        return "\(counts.readable)/\(expectedText)"
    }

    /// Whether `ratioDisplay`'s numerator is a confirmed count, so the UI knows
    /// whether it may present it as a finding.
    public var ratioIsConfirmed: Bool { hasCurrentCompleteReading }
}

/// Fleet-wide roll-up across every enabled host.
public struct FleetSummary: Equatable, Sendable {
    public var expectedGPUs: Int
    public var readableGPUs: Int
    public var warningGPUs: Int
    public var missingGPUs: Int
    public var unknownGPUs: Int
    public var unexpectedGPUs: Int
    public var enabledHosts: Int
    public var reachableHosts: Int
    public var staleHosts: Int
    public var hostCount: Int

    public init(
        expectedGPUs: Int = 0,
        readableGPUs: Int = 0,
        warningGPUs: Int = 0,
        missingGPUs: Int = 0,
        unknownGPUs: Int = 0,
        unexpectedGPUs: Int = 0,
        enabledHosts: Int = 0,
        reachableHosts: Int = 0,
        staleHosts: Int = 0,
        hostCount: Int = 0
    ) {
        self.expectedGPUs = expectedGPUs
        self.readableGPUs = readableGPUs
        self.warningGPUs = warningGPUs
        self.missingGPUs = missingGPUs
        self.unknownGPUs = unknownGPUs
        self.unexpectedGPUs = unexpectedGPUs
        self.enabledHosts = enabledHosts
        self.reachableHosts = reachableHosts
        self.staleHosts = staleHosts
        self.hostCount = hostCount
    }

    /// Compact headline for the menu bar, e.g. `15/16`.
    public var menuBarRatio: String {
        expectedGPUs > 0 ? "\(readableGPUs)/\(expectedGPUs)" : "\(readableGPUs)/?"
    }

    /// `true` only when every enabled host gave a current, complete reading with
    /// no warnings. This is the sole condition under which the UI may present
    /// itself as healthy.
    public var isFullyHealthy: Bool {
        guard enabledHosts > 0, hostCount > 0 else { return false }
        return readableGPUs == expectedGPUs
            && missingGPUs == 0
            && unknownGPUs == 0
            && unexpectedGPUs == 0
            && warningGPUs == 0
            && staleHosts == 0
            && reachableHosts == enabledHosts
    }

    /// True when we cannot vouch for part of the fleet.
    public var hasUnknowns: Bool {
        unknownGPUs > 0 || staleHosts > 0 || reachableHosts < enabledHosts
    }

    public var tooltip: String {
        var lines = [
            "Readable GPUs: \(readableGPUs)",
            "Expected GPUs: \(expectedGPUs > 0 ? "\(expectedGPUs)" : "not set")",
            "Hosts reachable: \(reachableHosts)/\(enabledHosts)"
        ]
        if unknownGPUs > 0 { lines.append("Unknown GPUs: \(unknownGPUs)") }
        if staleHosts > 0 { lines.append("Hosts with stale data: \(staleHosts)") }
        if missingGPUs > 0 { lines.append("Confirmed missing GPUs: \(missingGPUs)") }
        if unexpectedGPUs > 0 { lines.append("Unexpected GPUs: \(unexpectedGPUs)") }
        if warningGPUs > 0 { lines.append("GPUs with warnings: \(warningGPUs)") }
        return lines.joined(separator: "\n")
    }

    public static func make(from reports: [HostReport]) -> FleetSummary {
        var summary = FleetSummary()
        summary.hostCount = reports.count
        for report in reports {
            guard report.host.enabled else { continue }
            summary.enabledHosts += 1
            if report.ssh.isOK { summary.reachableHosts += 1 }
            if report.freshness == .stale { summary.staleHosts += 1 }
            // The evaluator guarantees that a report without a current complete
            // reading carries readable == 0, missing == 0 and unknown == all
            // expected slots. That makes a plain sum safe here: an unconfirmed
            // GPU can never be added to the readable tally.
            summary.expectedGPUs += report.counts.expected
            summary.readableGPUs += report.counts.readable
            summary.warningGPUs += report.counts.warnings
            summary.missingGPUs += report.counts.missing
            summary.unknownGPUs += report.counts.unknown
            summary.unexpectedGPUs += report.counts.unexpected
        }
        return summary
    }
}

/// Shared timing budget for one whole check of one host.
public enum CheckTimeoutBudget {
    /// Whole-check deadline. Covers SSH handshake plus the remote query plus
    /// teardown, so a hung host cannot pin a worker slot.
    public static let wholeCheckSeconds: Double = 12
    /// Passed to ssh itself so the handshake cannot outlive the budget.
    public static let connectTimeoutSeconds: Int = 5
    /// Hard cap on bytes we will buffer from a single stream.
    public static let maxOutputBytes: Int = 512 * 1024
}
