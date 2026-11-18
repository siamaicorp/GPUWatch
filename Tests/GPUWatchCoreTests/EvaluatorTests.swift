import XCTest
@testable import GPUWatchCore

/// The rules that protect operators from false confidence live here.
final class GPUStateEvaluatorTests: XCTestCase {
    private let evaluator = GPUStateEvaluator()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let settings = PollSettings()

    private func baseline(_ host: HostConfig, _ uuids: [String], expected: Int? = nil) -> HostBaseline {
        HostBaseline(
            hostID: host.id,
            gpuUUIDs: uuids,
            expectedCount: expected ?? uuids.count,
            registeredAt: now.addingTimeInterval(-3600)
        )
    }

    private func okProbe(_ rows: [String], complete: Bool = true, exitStatus: Int = 0) -> HostProbeResult {
        let parsed = NVIDIAQueryParser.parse(rows.joined(separator: "\n"))
        return HostProbeResult(
            ssh: .ok,
            query: .ok(samples: parsed.samples, partialWarnings: parsed.warnings),
            attemptedAt: now,
            transportConfirmed: true,
            queryWasComplete: complete,
            parseWarnings: parsed.warnings
        )
    }

    private func failedProbe(_ kind: SSHFailureKind = .unreachable) -> HostProbeResult {
        HostProbeResult(
            ssh: .failed(kind: kind, detail: "ssh: connect: Connection refused"),
            query: .failed(reason: .transportFailure, detail: "transport down"),
            attemptedAt: now,
            sshDetail: "ssh: connect: Connection refused"
        )
    }

    private func queryFailedProbe(_ reason: GPUQueryFailureReason) -> HostProbeResult {
        HostProbeResult(
            ssh: .ok,
            query: .failed(reason: reason, detail: "detail"),
            attemptedAt: now,
            transportConfirmed: true
        )
    }

    // MARK: - Healthy

    func testAllExpectedGPUsReadableIsHealthy() {
        let host = Fixtures.host(expected: 2)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)]),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
                Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(2))
            ]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.expected, 2)
        XCTAssertEqual(report.counts.readable, 2)
        XCTAssertEqual(report.counts.missing, 0)
        XCTAssertEqual(report.counts.unknown, 0)
        XCTAssertEqual(report.displayState, .healthy)
        XCTAssertEqual(report.counts.ratioText, "2/2")
        XCTAssertTrue(report.hasCurrentCompleteReading)
    }

    // MARK: - Missing GPU

    func testBaselineGPUAbsentFromCompleteQueryIsMissing() {
        let host = Fixtures.host(expected: 4)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...4).map(Fixtures.uuid)),
            probe: okProbe((1...3).map { Fixtures.csvRow(index: $0 - 1, uuid: Fixtures.uuid($0)) }),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 1)
        XCTAssertEqual(report.missingUUIDs, [Fixtures.uuid(4)])
        XCTAssertEqual(report.counts.readable, 3)
        XCTAssertEqual(report.displayState, .degraded)
        XCTAssertEqual(report.counts.ratioText, "3/4")

        // The missing GPU still gets a row so the dot count matches expectations.
        let missing = report.gpus.first { $0.uuid == Fixtures.uuid(4) }
        XCTAssertNotNil(missing)
        if case .missing = missing?.health {} else {
            XCTFail("expected a missing verdict, got \(String(describing: missing?.health))")
        }
    }

    func testMissingIsNeverClaimedWhenTheQueryWasIncomplete() {
        let host = Fixtures.host(expected: 4)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...4).map(Fixtures.uuid)),
            probe: okProbe(
                (1...3).map { Fixtures.csvRow(index: $0 - 1, uuid: Fixtures.uuid($0)) },
                complete: false
            ),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 0, "an incomplete query proves nothing")
        XCTAssertEqual(report.missingUUIDs, [])
        XCTAssertGreaterThan(report.counts.unknown, 0)
        XCTAssertNotEqual(report.displayState, .healthy)
    }

    func testPartialQueryLeavesUnconfirmedGPUsUnknownNotMissing() {
        let host = Fixtures.host(expected: 3)
        let partial = "0, \(Fixtures.uuid(1)), NVIDIA H100, 60, 10, 100, 81920\nthis row is broken"
        let parsed = NVIDIAQueryParser.parse(partial)
        let probe = HostProbeResult(
            ssh: .ok,
            query: .ok(samples: parsed.samples, partialWarnings: parsed.warnings),
            attemptedAt: now,
            transportConfirmed: true,
            queryWasComplete: false,
            parseWarnings: parsed.warnings
        )

        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...3).map(Fixtures.uuid)),
            probe: probe,
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 0)
        XCTAssertEqual(report.counts.readable, 1)
        XCTAssertEqual(report.counts.unknown, 2)
        XCTAssertFalse(report.counts.isComplete)
    }

    // MARK: - Replacement

    func testNewUUIDAppearsAsUnexpectedAlongsideMissingBaselineUUID() {
        let host = Fixtures.host(expected: 2)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)]),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
                Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(99))
            ]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 1)
        XCTAssertEqual(report.missingUUIDs, [Fixtures.uuid(2)])
        XCTAssertEqual(report.counts.unexpected, 1)
        XCTAssertEqual(report.unexpectedGPUs.map(\.uuid), [Fixtures.uuid(99)])

        let swapped = report.gpus.first { $0.uuid == Fixtures.uuid(99) }
        XCTAssertEqual(swapped?.health, .unexpected)
    }

    func testIndexSwapDoesNotChangeIdentity() {
        let host = Fixtures.host(expected: 2)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)]),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(2)),
                Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(1))
            ]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 0)
        XCTAssertEqual(report.counts.unexpected, 0)
        XCTAssertEqual(report.counts.readable, 2)
        XCTAssertEqual(report.displayState, .healthy)
    }

    // MARK: - Transport failure

    func testTransportFailureMarksEveryGPUUnknownAndNoneMissing() {
        let host = Fixtures.host(expected: 4)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...4).map(Fixtures.uuid)),
            probe: failedProbe(),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.readable, 0, "we cannot claim any GPU is readable")
        XCTAssertEqual(report.counts.missing, 0, "an unreachable host has no confirmed missing GPUs")
        XCTAssertEqual(report.counts.unknown, 4)
        XCTAssertEqual(report.displayState, .sshFailed(.unreachable))
        XCTAssertFalse(report.hasCurrentCompleteReading)
    }

    func testTransportFailureCarriesLastKnownValuesWithoutCallingThemLive() {
        let host = Fixtures.host(expected: 2)
        let good = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)]),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1), temperature: "55"),
                Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(2), temperature: "57")
            ]),
            previous: nil,
            settings: settings,
            now: now
        )
        XCTAssertEqual(good.counts.readable, 2)

        let later = now.addingTimeInterval(30)
        let degraded = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)]),
            probe: failedProbe(),
            previous: good,
            settings: settings,
            now: later
        )

        XCTAssertEqual(degraded.counts.readable, 0, "old readings must not keep the total inflated")
        XCTAssertEqual(degraded.gpus.count, 2, "but the values are still shown")
        XCTAssertTrue(degraded.gpus.allSatisfy { $0.isLiveData == false })
        XCTAssertTrue(degraded.gpus.allSatisfy {
            if case .unknown = $0.health { return true }
            return false
        })
        XCTAssertEqual(degraded.gpus.first?.temperatureCelsius, 55)
        XCTAssertEqual(degraded.lastSuccessfulAt, now)
    }

    func testAllGpusFailWhenTheWholeQueryFails() {
        let host = Fixtures.host(expected: 8)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...8).map(Fixtures.uuid)),
            probe: queryFailedProbe(.nvidiaSMINotFound),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.unknown, 8)
        XCTAssertEqual(report.counts.missing, 0)
        XCTAssertEqual(report.displayState, .gpuQueryFailed(.nvidiaSMINotFound))
        XCTAssertEqual(report.statusDetail, "SSH OK, nvidia-smi not installed")
    }

    // MARK: - Staleness

    func testOldDataIsStaleWhenTheCheckNoLongerSucceeds() {
        let host = Fixtures.host(expected: 1)
        let carrier = HostReport(
            host: host,
            ssh: .ok,
            query: .ok(samples: [GPUSample(index: 0, uuid: Fixtures.uuid(1))], partialWarnings: []),
            freshness: .fresh,
            gpus: [],
            counts: GPUCounts(expected: 1, readable: 1),
            lastSuccessfulAt: now.addingTimeInterval(-600),
            neverChecked: false
        )

        let report = evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: HostProbeResult(
                ssh: .notAttempted, query: .notAttempted,
                attemptedAt: now, transportConfirmed: false
            ),
            previous: carrier,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.freshness, .stale)
        XCTAssertEqual(report.lastSuccessfulAt, now.addingTimeInterval(-600))
    }

    func testStaleWindowScalesWithTheInterval() {
        XCTAssertEqual(PollSettings(intervalSeconds: 15).staleWindowSeconds, 60)
        XCTAssertEqual(PollSettings(intervalSeconds: 30).staleWindowSeconds, 60)
        XCTAssertEqual(PollSettings(intervalSeconds: 120).staleWindowSeconds, 240)
    }

    func testMarkedStaleDropsReadableToZero() {
        let host = Fixtures.host(expected: 1)
        let fresh = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1)]),
            probe: okProbe([Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1))]),
            previous: nil,
            settings: settings,
            now: now
        )
        let stale = fresh.markedStale()

        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.counts.readable, 0)
        XCTAssertEqual(stale.counts.unknown, 1)
        XCTAssertEqual(stale.displayState, .stale)
        XCTAssertFalse(stale.hasCurrentCompleteReading)
    }

    // MARK: - Thresholds

    func testTemperatureAboveThresholdIsAWarningNotAFailure() {
        let host = Fixtures.host(expected: 1, temperatureThreshold: 80)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1)]),
            probe: okProbe([Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1), temperature: "84")]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.warnings, 1)
        XCTAssertEqual(report.counts.readable, 1, "a hot GPU is still readable")
        guard case let .warning(reasons) = report.gpus[0].health else {
            return XCTFail("expected a warning")
        }
        XCTAssertTrue(reasons.contains { $0.contains("84") })
    }

    func testHighUtilizationAndVRAMAreNotFailures() {
        let host = Fixtures.host(expected: 1, temperatureThreshold: 80)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1)]),
            probe: okProbe([
                Fixtures.csvRow(
                    index: 0, uuid: Fixtures.uuid(1),
                    temperature: "70", utilization: "100",
                    memoryUsed: "81900", memoryTotal: "81920"
                )
            ]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.warnings, 0)
        XCTAssertEqual(report.displayState, .healthy)
    }

    func testUnsupportedMetricsAreAWarningNotASilentPass() {
        let host = Fixtures.host(expected: 1)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1)]),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1), temperature: "N/A", utilization: "N/A")
            ]),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertNotEqual(report.displayState, .healthy)
        XCTAssertEqual(report.counts.warnings, 1)
    }

    // MARK: - Expected count

    func testMoreGpusThanExpectedIsNotReportedAsHealthy() {
        let host = Fixtures.host(expected: 2)
        let report = evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: okProbe((1...4).map { Fixtures.csvRow(index: $0 - 1, uuid: Fixtures.uuid($0)) }),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.readable, 4)
        XCTAssertEqual(report.counts.expected, 2)
        XCTAssertFalse(report.counts.isComplete)
        XCTAssertNotEqual(report.displayState, .healthy)
        XCTAssertTrue(report.issues.contains { $0.contains("only 2 expected") })
    }

    func testWithoutABaselineMissingGpusAreUnknownNotNamed() {
        let host = Fixtures.host(expected: 4)
        let report = evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: okProbe((1...3).map { Fixtures.csvRow(index: $0 - 1, uuid: Fixtures.uuid($0)) }),
            previous: nil,
            settings: settings,
            now: now
        )

        XCTAssertEqual(report.counts.missing, 0, "without a baseline we cannot name a missing card")
        XCTAssertEqual(report.missingUUIDs, [])
        XCTAssertEqual(report.counts.unknown, 1)
        XCTAssertTrue(report.issues.contains { $0.contains("register a baseline") })
    }

    func testExpectedCountIsNotReducedByWhatWasFound() {
        let host = Fixtures.host(expected: 4)
        let first = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...4).map(Fixtures.uuid)),
            probe: okProbe((1...4).map { Fixtures.csvRow(index: $0 - 1, uuid: Fixtures.uuid($0)) }),
            previous: nil, settings: settings, now: now
        )
        XCTAssertEqual(first.counts.expected, 4)

        let second = evaluator.evaluate(
            host: host,
            baseline: baseline(host, (1...4).map(Fixtures.uuid)),
            probe: okProbe([Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1))]),
            previous: first, settings: settings, now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(second.counts.expected, 4, "expectation must survive a shrinking fleet")
        XCTAssertEqual(second.counts.missing, 3)
    }

    func testUnregisteredExpectedSlotsAreUnknown() {
        let host = Fixtures.host(expected: 4)
        let report = evaluator.evaluate(
            host: host,
            baseline: baseline(host, [Fixtures.uuid(1), Fixtures.uuid(2)], expected: 4),
            probe: okProbe([
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
                Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(2))
            ]),
            previous: nil, settings: settings, now: now
        )

        XCTAssertEqual(report.counts.expected, 4)
        XCTAssertEqual(report.counts.readable, 2)
        XCTAssertEqual(report.counts.unknown, 2)
        XCTAssertFalse(report.counts.isComplete)
    }

    // MARK: - Disabled

    func testDisabledHostIsNotCounted() {
        let host = Fixtures.host(expected: 4, enabled: false)
        let report = evaluator.evaluate(
            host: host, baseline: nil, probe: failedProbe(),
            previous: nil, settings: settings, now: now
        )

        XCTAssertEqual(report.displayState, .disabled)
        XCTAssertEqual(report.counts.expected, 0)
        let summary = FleetSummary.make(from: [report])
        XCTAssertEqual(summary.enabledHosts, 0)
        XCTAssertTrue(summary.isFullyHealthy == false)
    }
}

final class FleetSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testUnknownIsNeverAddedToTheReadableTotal() {
        let host = Fixtures.host(expected: 4)
        let unknown = HostReport(
            host: host,
            ssh: .failed(kind: .unreachable, detail: ""),
            query: .failed(reason: .transportFailure, detail: ""),
            freshness: .stale,
            gpus: [],
            counts: GPUCounts(expected: 4, readable: 0, warnings: 0, missing: 0, unknown: 4),
            neverChecked: false
        )

        let summary = FleetSummary.make(from: [unknown])
        XCTAssertEqual(summary.expectedGPUs, 4)
        XCTAssertEqual(summary.readableGPUs, 0)
        XCTAssertEqual(summary.unknownGPUs, 4)
        XCTAssertFalse(summary.isFullyHealthy)
        XCTAssertTrue(summary.hasUnknowns)
        XCTAssertEqual(summary.menuBarRatio, "0/4")
    }

    func testATransientFailureRemovesThoseGpusFromTheConfirmedTotal() {
        let host = Fixtures.host(expected: 2)
        let good = HostReport(
            host: host, ssh: .ok,
            query: .ok(samples: [], partialWarnings: []),
            freshness: .fresh, gpus: [],
            counts: GPUCounts(expected: 2, readable: 2),
            neverChecked: false
        )
        let bad = HostReport(
            host: host, ssh: .failed(kind: .unreachable, detail: ""),
            query: .failed(reason: .transportFailure, detail: ""),
            freshness: .stale, gpus: [],
            counts: GPUCounts(expected: 2, unknown: 2),
            neverChecked: false
        )

        XCTAssertEqual(FleetSummary.make(from: [good]).readableGPUs, 2)
        XCTAssertEqual(FleetSummary.make(from: [bad]).readableGPUs, 0)
    }

    func testWarningsPreventAFullyHealthyHeadline() {
        let host = Fixtures.host(expected: 1)
        let report = HostReport(
            host: host, ssh: .ok,
            query: .ok(samples: [], partialWarnings: []),
            freshness: .fresh, gpus: [],
            counts: GPUCounts(expected: 1, readable: 1, warnings: 1),
            neverChecked: false
        )
        let summary = FleetSummary.make(from: [report])
        XCTAssertEqual(summary.menuBarRatio, "1/1")
        XCTAssertFalse(summary.isFullyHealthy, "a warning must not render as healthy")
        XCTAssertTrue(summary.tooltip.contains("warnings"))
    }
}
