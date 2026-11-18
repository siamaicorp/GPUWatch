import Foundation

// MARK: - A. SSH reachability

/// Why an SSH connection attempt did not produce a usable session.
///
/// These cases are deliberately about the *transport*. A working transport that
/// found no working NVIDIA driver is a different axis entirely — see
/// `GPUQueryOutcome`.
public enum SSHFailureKind: String, Codable, Equatable, Sendable {
    /// The host key is unknown, or it changed since the last connection.
    /// We never accept a key or touch `known_hosts` on the user's behalf.
    case hostKeyVerification
    /// The server rejected our credentials, or the agent had nothing to offer.
    case authenticationFailed
    /// TCP never came up: refused, timed out, unroutable, or name resolution
    /// failed. This says "we could not reach it", not "the machine is off".
    case unreachable
    /// The attempt was cancelled by the user or superseded by a newer check.
    case cancelled
    /// The whole check exceeded the deadline.
    case timedOut
    /// Anything we could not classify, including a remote script that exited
    /// unexpectedly.
    case unknown

    public var shortLabel: String {
        switch self {
        case .hostKeyVerification: return "Host key"
        case .authenticationFailed: return "Auth failed"
        case .unreachable: return "Unreachable"
        case .cancelled: return "Cancelled"
        case .timedOut: return "Timed out"
        case .unknown: return "SSH error"
        }
    }
}

public enum SSHOutcome: Equatable, Sendable {
    case notAttempted
    case checking
    case ok
    /// SSH could not establish a session. `detail` is the raw stderr line, kept
    /// for the expanded detail view and never used for control flow.
    case failed(kind: SSHFailureKind, detail: String)
    case disabled

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - B. GPU query status

/// Why the remote GPU query did not yield a usable sample set.
public enum GPUQueryFailureReason: String, Codable, Equatable, Sendable {
    /// `nvidia-smi` is not on PATH on the remote host.
    case nvidiaSMINotFound
    /// The command ran and exited non-zero, typically because the driver could
    /// not be reached from user space.
    case commandFailed
    /// The command produced no rows at all.
    case emptyOutput
    /// Rows were produced but none could be understood.
    case malformedOutput
    /// The transport died before the query could be read.
    case transportFailure
    public var shortLabel: String {
        switch self {
        case .nvidiaSMINotFound: return "No nvidia-smi"
        case .commandFailed: return "Query failed"
        case .emptyOutput: return "Empty output"
        case .malformedOutput: return "Unparsable output"
        case .transportFailure: return "No transport"
        }
    }
}

/// Outcome of the *remote* GPU command, kept strictly separate from the SSH
/// outcome. SSH can succeed while this fails, and that combination must not be
/// read as "host offline".
public enum GPUQueryOutcome: Equatable, Sendable {
    case notAttempted
    /// At least one row was parsed. `partialWarnings` records rows that were
    /// skipped or metrics that were unusable, so a partial result is never
    /// presented as a clean one.
    case ok(samples: [GPUSample], partialWarnings: [String])
    case failed(reason: GPUQueryFailureReason, detail: String)

    public var samples: [GPUSample] {
        if case let .ok(samples, _) = self { return samples }
        return []
    }

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var partialWarnings: [String] {
        if case let .ok(_, warnings) = self { return warnings }
        return []
    }
}

// MARK: - C. Data freshness

/// How trustworthy the numbers on screen are right now.
public enum Freshness: Equatable, Sendable {
    /// Last check succeeded and is inside the staleness window.
    case fresh
    /// We have data, but it is older than `max(2 x interval, 60s)`. It is shown
    /// with its timestamp and never counted as a current healthy reading.
    case stale
    /// We have nothing at all to show.
    case unknown

    public var isFresh: Bool { self == .fresh }
}

// MARK: - Host-level presentation state

/// The single label shown for a host row. Derived from the three axes above;
/// it is a summary, not a fourth source of truth.
public enum HostDisplayState: Equatable, Sendable {
    case disabled
    case checking
    /// SSH failed. The specific kind drives the accompanying message.
    case sshFailed(SSHFailureKind)
    /// SSH worked; the GPU command did not.
    case gpuQueryFailed(GPUQueryFailureReason)
    /// Query worked but the GPU set does not match expectations.
    case degraded
    case healthy
    case stale
    case unknown

    public var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .checking: return "Checking…"
        case let .sshFailed(kind): return kind.shortLabel
        case let .gpuQueryFailed(reason): return reason.shortLabel
        case .degraded: return "Attention"
        case .healthy: return "OK"
        case .stale: return "Stale"
        case .unknown: return "Unknown"
        }
    }

    /// Whether this state should be rendered with the warning glyph in the menu
    /// bar. Anything that is not a confirmed, current, complete picture warns.
    public var isWarning: Bool {
        switch self {
        case .healthy, .disabled, .checking: return false
        case .sshFailed, .gpuQueryFailed, .degraded, .stale, .unknown: return true
        }
    }
}

// MARK: - Per-GPU verdict

public enum GPUHealth: Equatable, Sendable {
    /// The driver identified it and answered the core metrics in the latest
    /// complete check.
    case healthy
    /// Identified and readable, but a configured threshold is exceeded.
    case warning(reasons: [String])
    /// Confirmed absent from a complete query, or we hold GPU-specific evidence
    /// that reading it failed.
    case missing(reason: String)
    /// Present but not part of the registered baseline.
    case unexpected
    /// No trustworthy reading: transport down, query failed, or stale data.
    case unknown(reason: String)

    public var isHealthy: Bool { self == .healthy }
}

/// One GPU as presented to the user, including whether its numbers are live.
public struct GPUReport: Identifiable, Equatable, Sendable {
    /// Stable within a render pass. Uses the UUID when we have one so SwiftUI
    /// does not animate a row into a different GPU's slot.
    public var id: String
    /// Position from the most recent successful query, for display only.
    public var index: Int?
    public var uuid: String?
    public var model: String?
    public var temperatureCelsius: Double?
    public var utilizationPercent: Double?
    public var memoryUsedMiB: Double?
    public var memoryTotalMiB: Double?
    public var health: GPUHealth
    /// `false` when the values shown were carried forward from an earlier
    /// successful check rather than read now.
    public var isLiveData: Bool

    public init(
        id: String,
        index: Int? = nil,
        uuid: String? = nil,
        model: String? = nil,
        temperatureCelsius: Double? = nil,
        utilizationPercent: Double? = nil,
        memoryUsedMiB: Double? = nil,
        memoryTotalMiB: Double? = nil,
        health: GPUHealth,
        isLiveData: Bool
    ) {
        self.id = id
        self.index = index
        self.uuid = uuid
        self.model = model
        self.temperatureCelsius = temperatureCelsius
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.health = health
        self.isLiveData = isLiveData
    }

    /// Whether any measurement was carried forward. Distinguishes "the values on
    /// screen are old" from "there are no values at all".
    public var hasReadings: Bool {
        temperatureCelsius != nil
            || utilizationPercent != nil
            || memoryUsedMiB != nil
            || memoryTotalMiB != nil
    }

    /// Short reason text shown under the host row or inside the detail pane.
    public var reasonText: String? {
        switch health {
        case .healthy: return nil
        case let .warning(reasons): return reasons.joined(separator: ", ")
        case let .missing(reason): return reason
        case .unexpected: return "Not in baseline"
        case let .unknown(reason): return reason
        }
    }
}
