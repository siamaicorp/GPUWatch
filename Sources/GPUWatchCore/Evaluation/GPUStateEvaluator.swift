import Foundation

/// Turns a raw probe into the state the UI renders.
///
/// This type holds every policy decision that must not be made by accident in a
/// view. The three rules it exists to enforce:
///
/// 1. A failed transport marks every GPU *unknown*, never missing and never
///    healthy. We cannot see the GPUs, so we have nothing to say about them.
/// 2. A GPU is only called missing when a complete query positively did not
///    contain a baseline UUID.
/// 3. Numbers carried forward from an earlier check are never counted as
///    readable, so the headline total cannot be inflated by stale data.
public struct GPUStateEvaluator: Sendable {
    public init() {}

    public func evaluate(
        host: HostConfig,
        baseline: HostBaseline?,
        probe: HostProbeResult,
        previous: HostReport?,
        settings: PollSettings,
        now: Date
    ) -> HostReport {
        guard host.enabled else {
            return disabledReport(host: host, previous: previous)
        }

        switch probe.ssh {
        case .failed:
            return unavailableReport(
                host: host,
                baseline: baseline,
                probe: probe,
                previous: previous,
                settings: settings,
                now: now
            )
        case .ok:
            switch probe.query {
            case let .ok(samples, warnings):
                return successReport(
                    host: host,
                    baseline: baseline,
                    probe: probe,
                    samples: samples,
                    parserWarnings: warnings,
                    previous: previous,
                    settings: settings,
                    now: now
                )
            case let .failed(reason, detail):
                return unavailableReport(
                    host: host,
                    baseline: baseline,
                    probe: probe,
                    previous: previous,
                    settings: settings,
                    now: now,
                    queryFailure: (reason, detail)
                )
            case .notAttempted:
                return unavailableReport(
                    host: host,
                    baseline: baseline,
                    probe: probe,
                    previous: previous,
                    settings: settings,
                    now: now
                )
            }
        case .notAttempted, .checking, .disabled:
            // Nothing conclusive yet: fall back to the last known picture, or an
            // explicitly empty one.
            return unavailableReport(
                host: host,
                baseline: baseline,
                probe: probe,
                previous: previous,
                settings: settings,
                now: now
            )
        }
    }

    // MARK: - Disabled

    private func disabledReport(host: HostConfig, previous: HostReport?) -> HostReport {
        HostReport(
            host: host,
            ssh: .disabled,
            query: .notAttempted,
            freshness: .unknown,
            gpus: [],
            counts: GPUCounts(),
            lastAttemptedAt: previous?.lastAttemptedAt,
            lastSuccessfulAt: previous?.lastSuccessfulAt,
            hasBaseline: false,
            neverChecked: previous?.neverChecked ?? true
        )
    }

    // MARK: - Nothing readable this round

    /// Used for every case where we hold no current GPU reading: transport
    /// failure, query failure, or a check that has not run yet.
    ///
    /// Last-known values are preserved so the operator can still see what the
    /// host looked like, but every GPU is downgraded to `unknown` and the
    /// readable tally drops to zero.
    private func unavailableReport(
        host: HostConfig,
        baseline: HostBaseline?,
        probe: HostProbeResult,
        previous: HostReport?,
        settings: PollSettings,
        now: Date,
        queryFailure: (GPUQueryFailureReason, String)? = nil
    ) -> HostReport {
        let expected = effectiveExpectedCount(host: host, baseline: baseline)
        let lastSuccessfulAt = previous?.lastSuccessfulAt
        let freshness = freshnessOf(
            lastSuccessfulAt: lastSuccessfulAt,
            now: now,
            window: settings.staleWindowSeconds
        )

        var issues: [String] = []
        switch probe.ssh {
        case let .failed(kind, detail):
            issues.append(kind.userFacingMessage)
            if !detail.isEmpty { issues.append(detail) }
        case .ok:
            if let (reason, detail) = queryFailure {
                issues.append(reason.userFacingMessage)
                if !detail.isEmpty { issues.append(detail) }
            }
        default:
            break
        }

        let carriedReason: String
        if case let .failed(kind, _) = probe.ssh {
            carriedReason = kind == .cancelled ? "Check cancelled" : "Not read now"
        } else if queryFailure != nil {
            carriedReason = "Not read now"
        } else {
            carriedReason = "No data yet"
        }

        var carried = (previous?.gpus ?? []).map { gpu -> GPUReport in
            var copy = gpu
            copy.health = .unknown(reason: carriedReason)
            copy.isLiveData = false
            return copy
        }

        // Pad up to the expected count with anonymous unknown slots.
        //
        // Without this, an unreachable 8-GPU host draws no dots at all, and the
        // row gives no sense of how much is unaccounted for. The slot count is a
        // claim about the denominator the operator set, not about any GPU, so
        // these placeholders carry no UUID and can never be mistaken for a
        // finding about an identifiable card.
        if expected > carried.count {
            carried.append(contentsOf: (carried.count..<expected).map { index in
                GPUReport(id: "slot:\(index)", health: .unknown(reason: carriedReason), isLiveData: false)
            })
        }

        // Every expected slot is unaccounted for. Nothing is promoted to
        // missing, because we have no observation to base that on.
        let counts = GPUCounts(
            expected: expected,
            readable: 0,
            warnings: 0,
            missing: 0,
            unknown: expected,
            unexpected: 0
        )

        return HostReport(
            host: host,
            ssh: probe.ssh,
            query: probe.query,
            freshness: freshness,
            gpus: carried,
            counts: counts,
            lastAttemptedAt: probe.attemptedAt,
            lastSuccessfulAt: lastSuccessfulAt,
            issues: issues,
            parseWarnings: [],
            hasBaseline: baseline != nil,
            missingUUIDs: [],
            unexpectedGPUs: [],
            neverChecked: (previous?.neverChecked ?? true) && !probe.ssh.isFailure
        )
    }

    // MARK: - Successful query

    private func successReport(
        host: HostConfig,
        baseline: HostBaseline?,
        probe: HostProbeResult,
        samples: [GPUSample],
        parserWarnings: [String],
        previous: HostReport?,
        settings: PollSettings,
        now: Date
    ) -> HostReport {
        let expected = effectiveExpectedCount(host: host, baseline: baseline)
        let baselineUUIDs = baseline?.gpuUUIDs ?? []
        let baselineSet = Set(baselineUUIDs)
        let seenUUIDs = Set(samples.compactMap { $0.uuid })

        let confirmed = Set(baselineUUIDs).intersection(seenUUIDs)
        let absentFromBaseline = Set(baselineUUIDs).subtracting(seenUUIDs)
        let extraUUIDs = seenUUIDs.subtracting(baselineSet)

        var issues: [String] = []
        issues.append(contentsOf: parserWarnings)

        // ---- Per-sample verdicts -------------------------------------------
        var reports: [GPUReport] = []
        for sample in samples {
            let health = healthFor(
                sample: sample,
                host: host,
                baseline: baseline,
                extraUUIDs: extraUUIDs
            )
            reports.append(
                GPUReport(
                    id: sample.uuid ?? "index:\(sample.index.map(String.init) ?? "?")",
                    index: sample.index,
                    uuid: sample.uuid,
                    model: sample.model,
                    temperatureCelsius: sample.temperatureCelsius,
                    utilizationPercent: sample.utilizationPercent,
                    memoryUsedMiB: sample.memoryUsedMiB,
                    memoryTotalMiB: sample.memoryTotalMiB,
                    pressure: pressureFor(sample),
                    health: health,
                    isLiveData: true
                )
            )
        }

        // ---- Slots the baseline expects but the query did not show ---------
        let complete = probe.queryWasComplete
        var missingUUIDs: [String] = []
        var unconfirmedSlots = 0

        if baseline != nil {
            if complete {
                missingUUIDs = absentFromBaseline.sorted()
            } else {
                // An incomplete query cannot prove absence, so the slots stay
                // unknown and are never labelled missing.
                unconfirmedSlots = absentFromBaseline.count
            }
            for uuid in absentFromBaseline.sorted() {
                let health: GPUHealth = complete
                    ? .missing(reason: "Not present in the latest complete check")
                    : .unknown(reason: "Not confirmed — last check was incomplete")
                reports.append(
                    GPUReport(id: uuid, uuid: uuid, health: health, isLiveData: false)
                )
            }
            // Expected slots the user asked for but never registered.
            let unregistered = max(0, expected - baselineUUIDs.count)
            unconfirmedSlots += unregistered
            if unregistered > 0 {
                issues.append(
                    "\(unregistered) expected slot(s) have no registered GPU UUID"
                )
            }
        } else if expected > 0 {
            let shortfall = max(0, expected - samples.count)
            unconfirmedSlots = shortfall
            if shortfall > 0 {
                issues.append(
                    "\(shortfall) GPU(s) cannot be accounted for; register a baseline to identify them"
                )
            }
        }

        // ---- Tallies -------------------------------------------------------
        let healthyCount = reports.filter { $0.health == .healthy }.count
        let warningCount = reports.filter {
            if case .warning = $0.health { return true }
            return false
        }.count
        let unexpectedCount = reports.filter { $0.health == .unexpected }.count
        let unidentifiable = samples.filter { !$0.hasIdentity }.count

        if unidentifiable > 0 {
            issues.append("\(unidentifiable) GPU(s) reported without a UUID and cannot be tracked")
        }
        if expected > 0, samples.count > expected {
            issues.append("\(samples.count) GPUs found but only \(expected) expected")
        }

        let counts = GPUCounts(
            expected: expected,
            // A GPU is readable when the driver identified it and answered its
            // core metrics — a threshold warning does not make it unreadable.
            readable: healthyCount + warningCount,
            warnings: warningCount,
            missing: missingUUIDs.count,
            unknown: unconfirmedSlots,
            unexpected: unexpectedCount
        )

        return HostReport(
            host: host,
            ssh: .ok,
            query: probe.query,
            freshness: .fresh,
            gpus: reports,
            counts: counts,
            lastAttemptedAt: probe.attemptedAt,
            lastSuccessfulAt: now,
            issues: issues,
            parseWarnings: parserWarnings,
            hasBaseline: baseline != nil,
            missingUUIDs: missingUUIDs,
            unexpectedGPUs: samples.compactMap { sample in
                guard let uuid = sample.uuid, extraUUIDs.contains(uuid) else { return nil }
                return UnexpectedGPU(uuid: uuid, index: sample.index, model: sample.model)
            },
            neverChecked: false,
            confirmedBaselineUUIDs: confirmed
        )
    }

    // MARK: - Per-GPU policy

    private func healthFor(
        sample: GPUSample,
        host: HostConfig,
        baseline: HostBaseline?,
        extraUUIDs: Set<String>
    ) -> GPUHealth {
        var warnings: [GPUWarning] = []

        // ---- Readability: the driver did not answer something we asked ------
        // These are the only warnings that are about the card or its driver.
        if !sample.hasIdentity {
            warnings.append(GPUWarning(kind: .readability, text: "driver reported no UUID"))
        }
        if !sample.hasCoreMetrics {
            var missingMetrics: [String] = []
            if sample.temperatureCelsius == nil { missingMetrics.append("temperature") }
            if sample.utilizationPercent == nil { missingMetrics.append("utilization") }
            if sample.memoryTotalMiB == nil { missingMetrics.append("memory total") }
            warnings.append(GPUWarning(
                kind: .readability,
                text: "no \(missingMetrics.joined(separator: "/")) reported"
            ))
        }

        // ---- Pressure: an operator-declared threshold was crossed -----------
        // These say the card is working hard. They never say it is unwell, and
        // they are only reported at all if the operator asked for them.
        if let threshold = host.temperatureWarningThreshold,
           let temperature = sample.temperatureCelsius,
           temperature >= threshold {
            warnings.append(GPUWarning(
                kind: .pressure,
                text: "\(format(temperature))°C at or above the \(format(threshold))°C threshold"
            ))
        }

        if let threshold = host.vramWarningFraction,
           let fraction = sample.memoryUtilizationFraction,
           fraction >= threshold {
            warnings.append(GPUWarning(
                kind: .pressure,
                text: "VRAM \(percent(fraction)) full at or above the \(percent(threshold)) threshold"
            ))
        }

        if let threshold = host.powerWarningFraction,
           let fraction = sample.powerFraction,
           fraction >= threshold {
            warnings.append(GPUWarning(
                kind: .pressure,
                text: "drawing \(percent(fraction)) of its power limit at or above the "
                    + "\(percent(threshold)) threshold"
            ))
        }

        if !warnings.isEmpty {
            return .warning(warnings: warnings)
        }

        if let uuid = sample.uuid, baseline != nil, extraUUIDs.contains(uuid) {
            return .unexpected
        }

        return .healthy
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: - Helpers

    /// Load readings for one GPU, or `nil` when the driver reported none of
    /// them — in which case the detail pane shows no pressure line at all
    /// rather than a row of dashes for values the card never had.
    private func pressureFor(_ sample: GPUSample) -> GPUPressure? {
        let pressure = GPUPressure(
            powerDrawWatts: sample.powerDrawWatts,
            powerLimitWatts: sample.powerLimitWatts,
            memoryTemperatureCelsius: sample.memoryTemperatureCelsius,
            memoryUtilizationPercent: sample.memoryUtilizationPercent,
            memoryUsedMiB: sample.memoryUsedMiB,
            memoryTotalMiB: sample.memoryTotalMiB
        )
        return pressure.hasAnyReading ? pressure : nil
    }

    /// The user's expectation wins over anything the driver reported. A baseline
    /// freezes the count the user accepted; otherwise the host's own field is
    /// used, and zero means "not configured" rather than "no GPUs".
    private func effectiveExpectedCount(host: HostConfig, baseline: HostBaseline?) -> Int {
        if let baseline { return baseline.expectedCount }
        return max(0, host.expectedGPUCount)
    }

    private func freshnessOf(lastSuccessfulAt: Date?, now: Date, window: TimeInterval) -> Freshness {
        guard let lastSuccessfulAt else { return .unknown }
        return now.timeIntervalSince(lastSuccessfulAt) <= window ? .fresh : .stale
    }

    private func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Wake handling

public extension HostReport {
    /// Downgrades a report whose reading predates a system sleep.
    ///
    /// Freshness is normally derived from age alone, but a laptop that was
    /// asleep for two minutes can wake with timestamps that still look recent
    /// while nothing has actually been verified. This makes the app treat
    /// post-wake data as stale until a real check lands.
    func markedStale(reason: String = "Not re-checked since wake") -> HostReport {
        guard ssh.isOK, query.isOK else {
            var copy = self
            if copy.freshness == .fresh { copy.freshness = .stale }
            return copy
        }
        var copy = self
        copy.freshness = .stale
        copy.gpus = gpus.map { gpu in
            var updated = gpu
            updated.health = .unknown(reason: reason)
            updated.isLiveData = false
            return updated
        }
        copy.counts = GPUCounts(
            expected: counts.expected,
            readable: 0,
            warnings: 0,
            missing: 0,
            unknown: counts.expected,
            unexpected: 0
        )
        copy.missingUUIDs = []
        copy.unexpectedGPUs = []
        return copy
    }
}

// MARK: - User-facing wording

public extension SSHFailureKind {
    var userFacingMessage: String {
        switch self {
        case .hostKeyVerification:
            return "SSH host key could not be verified. Confirm the fingerprint in Terminal, then retry."
        case .authenticationFailed:
            return "SSH authentication failed. Check your agent or key for this host."
        case .unreachable:
            return "Could not reach the host over SSH. This does not confirm the machine is down."
        case .cancelled:
            return "The check was cancelled."
        case .timedOut:
            return "The check did not finish within \(Int(CheckTimeoutBudget.wholeCheckSeconds)) seconds."
        case .unknown:
            return "SSH failed for an unfamiliar reason."
        }
    }
}

public extension GPUQueryFailureReason {
    var userFacingMessage: String {
        switch self {
        case .nvidiaSMINotFound:
            return "SSH worked, but nvidia-smi was not found on this host."
        case .commandFailed:
            return "SSH worked, but nvidia-smi could not query the driver."
        case .emptyOutput:
            return "SSH worked, but nvidia-smi reported no GPUs."
        case .malformedOutput:
            return "SSH worked, but the GPU output could not be understood."
        case .transportFailure:
            return "The SSH session ended before the GPU query finished."
        }
    }
}
