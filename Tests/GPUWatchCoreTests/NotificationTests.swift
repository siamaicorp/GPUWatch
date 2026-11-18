import XCTest
@testable import GPUWatchCore

final class NotificationServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let host = Fixtures.host(expected: 4)

    private func report(
        ssh: SSHOutcome = .ok,
        query: GPUQueryOutcome = .ok(samples: [], partialWarnings: []),
        counts: GPUCounts = GPUCounts(expected: 4, readable: 4),
        freshness: Freshness = .fresh,
        missingUUIDs: [String] = [],
        gpus: [GPUReport] = [],
        host: HostConfig? = nil
    ) -> HostReport {
        HostReport(
            host: host ?? self.host,
            ssh: ssh,
            query: query,
            freshness: freshness,
            gpus: gpus,
            counts: counts,
            lastAttemptedAt: now,
            lastSuccessfulAt: freshness == .fresh ? now : now.addingTimeInterval(-3600),
            missingUUIDs: missingUUIDs,
            neverChecked: false
        )
    }

    private func unreachableReport() -> HostReport {
        report(
            ssh: .failed(kind: .unreachable, detail: "connection refused"),
            query: .failed(reason: .transportFailure, detail: ""),
            counts: GPUCounts(expected: 4, readable: 0, missing: 0, unknown: 4),
            freshness: .stale
        )
    }

    // MARK: - Debounce

    func testASingleFailureDoesNotNotify() {
        let service = NotificationService()
        let first = service.evaluate(reports: [unreachableReport()], now: now)
        XCTAssertTrue(first.isEmpty, "one bad poll is a hiccup, not an incident")
    }

    func testTwoConsecutiveFailuresNotify() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        let second = service.evaluate(
            reports: [unreachableReport()], now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].isRecovery, false)
        XCTAssertTrue(second[0].title.contains(host.effectiveName))
    }

    func testARecoveryBetweenFailuresResetsTheStreak() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        _ = service.evaluate(reports: [report()], now: now.addingTimeInterval(30))
        let afterAgain = service.evaluate(
            reports: [unreachableReport()], now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(afterAgain.isEmpty, "the streak should have restarted")
    }

    // MARK: - Change and cooldown

    func testASustainedProblemIsAnnouncedOnceOnly() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        XCTAssertEqual(
            service.evaluate(reports: [unreachableReport()], now: now.addingTimeInterval(30)).count,
            1
        )
        for step in 2...6 {
            let later = service.evaluate(
                reports: [unreachableReport()],
                now: now.addingTimeInterval(Double(step) * 30)
            )
            XCTAssertTrue(later.isEmpty, "a host that stays broken should go quiet")
        }
    }

    func testCooldownBlocksARepeatOfTheSameAlertAfterRecovery() {
        let service = NotificationService(options: .init(confirmationsRequired: 1, cooldownSeconds: 3600))
        XCTAssertEqual(service.evaluate(reports: [unreachableReport()], now: now).count, 1)
        _ = service.evaluate(reports: [report()], now: now.addingTimeInterval(60))
        let repeatAlert = service.evaluate(
            reports: [unreachableReport()], now: now.addingTimeInterval(120)
        )
        XCTAssertTrue(repeatAlert.isEmpty, "the cooldown should still be in force")
    }

    // MARK: - Recovery

    func testRecoveryIsAnnouncedOnceTheHostComesBackForTwoRounds() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        _ = service.evaluate(reports: [unreachableReport()], now: now.addingTimeInterval(30))

        // One good round is not enough — the same confirmation streak a problem
        // has to clear also applies to good news, so a flapping host stays quiet.
        let firstGood = service.evaluate(reports: [report()], now: now.addingTimeInterval(60))
        XCTAssertTrue(firstGood.isEmpty)

        let recovered = service.evaluate(reports: [report()], now: now.addingTimeInterval(90))
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(recovered[0].isRecovery)
        XCTAssertTrue(recovered[0].title.contains("recovered"))
        XCTAssertTrue(recovered[0].body.contains("4/4"))
    }

    func testNoRecoveryIsAnnouncedWithoutAProblemFirst() {
        let service = NotificationService()
        _ = service.evaluate(reports: [report()], now: now)
        let second = service.evaluate(reports: [report()], now: now.addingTimeInterval(30))
        XCTAssertTrue(second.isEmpty)
    }

    func testRecoveryIsNotAnnouncedFromStaleCache() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        _ = service.evaluate(reports: [unreachableReport()], now: now.addingTimeInterval(30))

        // A host whose reading is stale and whose transport is down again is not
        // a recovery, however healthy its carried-forward tally looks.
        let cached = report(
            ssh: .failed(kind: .unreachable, detail: ""),
            query: .failed(reason: .transportFailure, detail: ""),
            counts: GPUCounts(expected: 4, readable: 0, unknown: 4),
            freshness: .stale
        )
        let outgoing = service.evaluate(reports: [cached], now: now.addingTimeInterval(60))
        XCTAssertTrue(outgoing.isEmpty)
    }

    func testBaselineResetAnnouncesNoRecovery() {
        let service = NotificationService()
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        _ = service.evaluate(reports: [unreachableReport()], now: now.addingTimeInterval(30))

        service.forgetAll()

        let afterReset = service.evaluate(reports: [report()], now: now.addingTimeInterval(60))
        XCTAssertTrue(afterReset.isEmpty, "a bookkeeping change is not evidence of a fix")
    }

    // MARK: - The rule that matters most

    func testMissingGPUsFromATransportFailureNeverNotify() {
        let service = NotificationService(options: .init(confirmationsRequired: 1))
        // Structurally impossible: a transport failure produces no missing
        // count, so no missing-GPU alert can be constructed from one.
        XCTAssertEqual(
            NotificationService.condition(for: unreachableReport()),
            .unreachable(.unreachable)
        )
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        let titles = service.evaluate(
            reports: [unreachableReport()], now: now.addingTimeInterval(30)
        ).map(\.title)
        XCTAssertFalse(titles.contains { $0.lowercased().contains("missing") })
    }

    func testConfirmedMissingGPUsDoNotify() {
        let service = NotificationService(options: .init(confirmationsRequired: 1))
        let degraded = report(
            counts: GPUCounts(expected: 4, readable: 3, missing: 1),
            missingUUIDs: [Fixtures.uuid(4)]
        )
        let outgoing = service.evaluate(reports: [degraded], now: now)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertTrue(outgoing[0].title.contains("1 GPU missing"))
        XCTAssertTrue(outgoing[0].body.contains(Fixtures.uuid(4)))
    }

    func testWarningThresholdsDoNotify() {
        let service = NotificationService(options: .init(confirmationsRequired: 1))
        let hot = report(
            counts: GPUCounts(expected: 1, readable: 1, warnings: 1),
            gpus: [GPUReport(id: "g", health: .warning(reasons: ["84°C above threshold"]), isLiveData: true)]
        )
        let outgoing = service.evaluate(reports: [hot], now: now)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertTrue(outgoing[0].body.contains("84°C"))
    }

    func testCancelledChecksDoNotAlert() {
        let service = NotificationService(options: .init(confirmationsRequired: 1))
        let cancelled = report(
            ssh: .failed(kind: .cancelled, detail: ""),
            query: .notAttempted,
            counts: GPUCounts(expected: 4, unknown: 0)
        )
        XCTAssertEqual(NotificationService.condition(for: cancelled), .normal)
        XCTAssertTrue(service.evaluate(reports: [cancelled], now: now).isEmpty)
    }

    func testDisablingAlertsClearsTheStreak() {
        let service = NotificationService(options: .init(confirmationsRequired: 2))
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        service.forgetAll()
        let afterReEnable = service.evaluate(
            reports: [unreachableReport()], now: now.addingTimeInterval(30)
        )
        XCTAssertTrue(afterReEnable.isEmpty, "re-enabling must not fire on a stale observation")
    }

    func testDeletedHostIsForgotten() {
        let service = NotificationService(options: .init(confirmationsRequired: 2))
        _ = service.evaluate(reports: [unreachableReport()], now: now)
        service.forget(hostID: host.id)
        XCTAssertEqual(service.announcedCondition(for: host.id), .normal)
    }
}
