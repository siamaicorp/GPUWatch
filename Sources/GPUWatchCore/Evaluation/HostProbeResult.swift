import Foundation

/// Everything one check of one host produced, before any policy is applied.
///
/// The two axes are kept structurally separate: `ssh` describes the transport
/// and `query` describes the remote GPU command. Collapsing them is exactly the
/// mistake that makes an unreachable-host false alarm out of a broken driver.
public struct HostProbeResult: Equatable, Sendable {
    public var ssh: SSHOutcome
    public var query: GPUQueryOutcome
    /// When the attempt started.
    public var attemptedAt: Date
    /// Diagnostics from the remote command, shown in the detail pane.
    public var queryDetail: String
    /// Raw ssh stderr, retained for troubleshooting and never parsed by the UI.
    public var sshDetail: String
    /// `true` when the remote script printed its end marker.
    public var transportConfirmed: Bool
    /// `true` when every reported GPU line was understood and identity is
    /// unambiguous. Only then may absence of a baseline UUID be called missing.
    public var queryWasComplete: Bool
    /// Individual warnings from the parser, carried through so a partial result
    /// is never presented as a clean one.
    public var parseWarnings: [String]

    public init(
        ssh: SSHOutcome,
        query: GPUQueryOutcome,
        attemptedAt: Date,
        queryDetail: String = "",
        sshDetail: String = "",
        transportConfirmed: Bool = false,
        queryWasComplete: Bool = false,
        parseWarnings: [String] = []
    ) {
        self.ssh = ssh
        self.query = query
        self.attemptedAt = attemptedAt
        self.queryDetail = queryDetail
        self.sshDetail = sshDetail
        self.transportConfirmed = transportConfirmed
        self.queryWasComplete = queryWasComplete
        self.parseWarnings = parseWarnings
    }

    /// A reading we are willing to count: transport worked, the query produced
    /// rows, and the row set was complete.
    public var isCompleteCurrentReading: Bool {
        ssh.isOK && query.isOK && queryWasComplete
    }

    public static func notAttempted(at date: Date) -> HostProbeResult {
        HostProbeResult(ssh: .notAttempted, query: .notAttempted, attemptedAt: date)
    }
}
