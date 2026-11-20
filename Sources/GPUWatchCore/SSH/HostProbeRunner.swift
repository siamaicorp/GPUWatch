import Foundation

/// Runs one check against one host and reports what happened on each axis.
///
/// The ordering here is the whole point: we decide whether SSH worked from the
/// remote script's own end marker, and only then ask whether the GPU query
/// succeeded. A driver that refuses to talk is never allowed to look like a
/// machine that is off.
public struct HostProbeRunner: Sendable {
    private let commands: SSHCommandRunning

    public init(commands: SSHCommandRunning) {
        self.commands = commands
    }

    public func probe(host: HostConfig, now: Date) async -> HostProbeResult {
        let target: SSHTarget
        do {
            target = try SSHTarget.make(from: host)
        } catch {
            return HostProbeResult(
                ssh: .failed(kind: .unknown, detail: error.localizedDescription),
                query: .notAttempted,
                attemptedAt: now,
                sshDetail: error.localizedDescription
            )
        }

        let result: SSHCommandResult
        do {
            result = try await commands.run(
                target: target,
                remoteCommand: RemoteProbe.script(for: host.vendor),
                timeout: CheckTimeoutBudget.wholeCheckSeconds,
                maxOutputBytes: CheckTimeoutBudget.maxOutputBytes
            )
        } catch {
            return HostProbeResult(
                ssh: .failed(kind: .unknown, detail: error.localizedDescription),
                query: .notAttempted,
                attemptedAt: now,
                sshDetail: error.localizedDescription
            )
        }

        let envelope = ProbeEnvelope.parse(stdout: result.stdout)

        // Two independent signals that the transport worked: our own end marker,
        // or a remote exit status that is not ssh's own failure sentinel.
        let transportOK = envelope.transportConfirmed
            || (result.didReachRemote && !result.timedOut && !result.cancelled)

        guard transportOK else {
            let classified = SSHFailureClassifier.classify(
                result: result,
                transportConfirmed: envelope.transportConfirmed
            )
            return HostProbeResult(
                ssh: .failed(kind: classified.kind, detail: classified.detail),
                query: .failed(reason: .transportFailure, detail: classified.detail),
                attemptedAt: now,
                queryDetail: "",
                sshDetail: result.stderr,
                transportConfirmed: false
            )
        }

        let (query, queryDetail, complete) = interpretQuery(
            envelope: envelope,
            result: result,
            requestedVendor: host.vendor
        )

        return HostProbeResult(
            ssh: .ok,
            query: query,
            attemptedAt: now,
            queryDetail: queryDetail,
            sshDetail: result.stderr,
            transportConfirmed: envelope.transportConfirmed,
            queryWasComplete: complete,
            parseWarnings: query.partialWarnings
        )
    }

    private func interpretQuery(
        envelope: ProbeEnvelope,
        result: SSHCommandResult,
        requestedVendor: GPUVendor
    ) -> (GPUQueryOutcome, String, Bool) {
        guard envelope.transportConfirmed else {
            // We reached the host but the remote probe never completed, so we
            // have no evidence about its GPUs at all.
            return (
                .failed(reason: .malformedOutput, detail: "Remote probe did not complete"),
                "Remote probe produced no end marker",
                false
            )
        }

        // No supported tool answered. This is a statement about the host's
        // software, not about its cards, so it must not be read as "no GPUs".
        guard let vendor = envelope.vendor else {
            let detail = missingToolDetail(for: requestedVendor)
            return (
                .failed(reason: .gpuToolNotFound, detail: detail),
                detail,
                false
            )
        }

        let parsed: ParsedGPUQuery
        let toolName: String
        switch vendor {
        case .amd:
            parsed = ROCmSMIParser.parse(envelope.queryOutput)
            toolName = "rocm-smi"
        case .nvidia, .auto:
            // `.auto` is a host's setting, never something a script reports: the
            // auto script resolves to a concrete vendor before it runs a query.
            // It is grouped with NVIDIA only to keep this exhaustive rather than
            // to assign it a meaning.
            parsed = NVIDIAQueryParser.parse(envelope.queryOutput)
            toolName = "nvidia-smi"
        }
        let exitCode = envelope.queryReturnCode
        var detail = ""
        if let exitCode, exitCode != 0 {
            detail = envelope.queryOutput
                .split(separator: "\n")
                .first
                .map(String.init) ?? "\(toolName) exited \(exitCode)"
        }

        // A driver that exited non-zero and produced no usable row is a driver
        // problem, whatever else came back. Its own message ("couldn't
        // communicate with the NVIDIA driver", or ROCm's equivalent) is a better
        // diagnosis than "unparsable output", so this is checked before the
        // malformed branch.
        let producedNoUsableRows = parsed.isEntirelyUnusable || parsed.isEmpty
        if producedNoUsableRows, let exitCode, exitCode != 0 {
            return (
                .failed(
                    reason: .commandFailed,
                    detail: detail.isEmpty ? "exit \(exitCode)" : detail
                ),
                detail,
                false
            )
        }

        if parsed.isEmpty {
            return (.failed(reason: .emptyOutput, detail: "no rows reported"), "", false)
        }

        if parsed.isEntirelyUnusable {
            let warnings = parsed.warnings
            return (
                .failed(
                    reason: .malformedOutput,
                    detail: warnings.first ?? "no row could be understood"
                ),
                warnings.joined(separator: "; "),
                false
            )
        }

        var warnings = parsed.warnings
        if let exitCode, exitCode != 0 {
            warnings.append("\(toolName) exited with status \(exitCode)")
        }
        if result.stdoutTruncated {
            warnings.append("output was truncated at the size limit")
        }

        // A non-zero exit means the driver is unhappy, so the row set cannot be
        // treated as a complete inventory. Missing GPUs are never claimed from a
        // query that reported an error.
        let complete = parsed.skipped.filter { $0.reason != .migInstance }.isEmpty
            && parsed.duplicateUUIDs.isEmpty
            && (exitCode ?? 0) == 0

        return (.ok(samples: parsed.samples, partialWarnings: warnings), detail, complete)
    }

    /// What to say when no GPU tool answered, worded for the setting the
    /// operator actually chose. An explicit vendor names the one tool that was
    /// tried, so the message does not suggest a remedy that was never on the
    /// table.
    private func missingToolDetail(for requestedVendor: GPUVendor) -> String {
        switch requestedVendor {
        case .nvidia:
            return "nvidia-smi not on PATH"
        case .amd:
            return "rocm-smi not on PATH"
        case .auto:
            return "neither nvidia-smi nor rocm-smi is on PATH"
        }
    }
}
