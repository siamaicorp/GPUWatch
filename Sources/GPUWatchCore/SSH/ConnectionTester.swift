import Foundation

/// Outcome of the "Test Connection" button, broken down by stage so the user
/// learns *where* it failed instead of just that it did.
public struct ConnectionTestResult: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        /// Configuration was rejected before anything ran.
        case invalidConfiguration
        /// ssh could not establish a session.
        case sshFailed
        /// ssh worked; `nvidia-smi` is not present on the host.
        case nvidiaSMIMissing
        /// ssh worked and nvidia-smi exists, but the query failed.
        case gpuQueryFailed
        /// Everything worked.
        case success

        public var label: String {
            switch self {
            case .invalidConfiguration: return "Configuration problem"
            case .sshFailed: return "SSH failed"
            case .nvidiaSMIMissing: return "SSH OK, no nvidia-smi"
            case .gpuQueryFailed: return "SSH OK, GPU query failed"
            case .success: return "Success"
            }
        }
    }

    public let stage: Stage
    public let summary: String
    public let detail: String
    public let gpuCount: Int?
    public let samples: [GPUSample]
    public let sshReachable: Bool

    public init(
        stage: Stage,
        summary: String,
        detail: String = "",
        gpuCount: Int? = nil,
        samples: [GPUSample] = [],
        sshReachable: Bool
    ) {
        self.stage = stage
        self.summary = summary
        self.detail = detail
        self.gpuCount = gpuCount
        self.samples = samples
        self.sshReachable = sshReachable
    }
}

/// Runs the same probe the poller uses and reports the result in stages.
///
/// Sharing the probe path means "Test Connection succeeded" and "the poller
/// works" cannot disagree with each other.
public struct ConnectionTester: Sendable {
    private let commands: SSHCommandRunning

    public init(commands: SSHCommandRunning) {
        self.commands = commands
    }

    public func test(_ host: HostConfig, now: Date) async -> ConnectionTestResult {
        let runner = HostProbeRunner(commands: commands)
        let probe = await runner.probe(host: host, now: now)

        if case let .failed(kind, detail) = probe.ssh {
            let isConfigProblem = probe.query == .notAttempted
                && detail.contains("Invalid")
            return ConnectionTestResult(
                stage: isConfigProblem ? .invalidConfiguration : .sshFailed,
                summary: isConfigProblem
                    ? (detail.isEmpty ? "Fix the host settings" : detail)
                    : kind.userFacingMessage,
                detail: detail,
                sshReachable: false
            )
        }

        switch probe.query {
        case let .failed(reason, detail):
            let stage: ConnectionTestResult.Stage =
                reason == .nvidiaSMINotFound ? .nvidiaSMIMissing : .gpuQueryFailed
            return ConnectionTestResult(
                stage: stage,
                summary: reason.userFacingMessage,
                detail: detail,
                sshReachable: true
            )
        case let .ok(samples, warnings):
            let count = samples.count
            let models = Set(samples.compactMap(\.model)).sorted()
            var summary = "SSH reachable. Found \(count) GPU\(count == 1 ? "" : "s")."
            if let first = models.first {
                summary = "SSH reachable. Found \(count) GPU\(count == 1 ? "" : "s") (\(first)"
                    + (models.count > 1 ? ", and \(models.count - 1) more" : "") + ")."
            }
            return ConnectionTestResult(
                stage: .success,
                summary: summary,
                detail: warnings.joined(separator: "\n"),
                gpuCount: count,
                samples: samples,
                sshReachable: true
            )
        case .notAttempted:
            return ConnectionTestResult(
                stage: .sshFailed,
                summary: "The check did not run.",
                sshReachable: false
            )
        }
    }
}
