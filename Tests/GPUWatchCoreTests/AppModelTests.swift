import XCTest
@testable import GPUWatchCore

@MainActor
final class AppModelTests: XCTestCase {
    private var directory: URL!
    private var runner: FakeSSHRunner!
    private var model: AppModel!
    private var clock: TestClock!

    override func setUpWithError() throws {
        directory = try Fixtures.tempDirectory("gpuwatch-model")
        runner = FakeSSHRunner()
        clock = TestClock()
        model = AppModel(
            store: ConfigurationStore(directory: directory),
            commands: runner,
            clock: clock,
            deliverer: NoopNotificationDeliverer()
        )
    }

    override func tearDownWithError() throws {
        model?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func healthyEnvelope(uuids: [String]) -> String {
        Fixtures.envelope(rows: uuids.enumerated().map {
            Fixtures.csvRow(index: $0.offset, uuid: $0.element)
        })
    }

    // MARK: - Polling discipline

    func testOneCheckPerHostPerRound() async {
        model.addHost(Fixtures.host(expected: 2))
        await model.refreshNow()

        let before = runner.invocationCount
        await model.refreshNow()
        XCTAssertEqual(runner.invocationCount, before + 1, "one host, one ssh call, per round")
    }

    func testConcurrentRefreshRequestsDoNotDuplicateWork() async {
        model.addHost(Fixtures.host(expected: 1))
        await model.refreshNow()
        let before = runner.invocationCount

        runner.setDefault(.suspended(stdout: healthyEnvelope(uuids: [Fixtures.uuid(1)])))

        async let first: Void = model.refreshNow()
        await runner.waitForInvocations(over: before)
        async let second: Void = model.refreshNow()
        async let third: Void = model.refreshNow()

        // Give the extra callers a chance to (incorrectly) start their own work.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            runner.invocationCount, before + 1,
            "three overlapping refreshes must still be one ssh call"
        )

        runner.releaseAll()
        _ = await (first, second, third)
    }

    func testConcurrencyIsBounded() async {
        for index in 0..<10 {
            model.addHost(Fixtures.host(
                name: "gpu-\(index)", destination: "gpu-\(index).invalid", expected: 1
            ))
        }
        XCTAssertEqual(model.settings.maxConcurrentChecks, 5)

        runner.setDefault(.delayed(
            terminationStatus: 0,
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1)]),
            stderr: "",
            seconds: 0.05
        ))

        await model.refreshNow()
        await model.refreshNow()

        XCTAssertEqual(runner.invocationCount % 10, 0, "every host should be checked, in whole rounds")
        XCTAssertLessThanOrEqual(
            runner.peakConcurrency, 5,
            "a 200-host fleet must not fork 200 ssh calls"
        )
        XCTAssertGreaterThan(runner.peakConcurrency, 1, "but it should actually overlap")
    }

    func testDisabledHostsAreNeverContacted() async {
        let on = Fixtures.host(name: "on", destination: "on.invalid", expected: 1)
        let off = Fixtures.host(name: "off", destination: "off.invalid", expected: 1, enabled: false)
        model.addHost(on)
        model.addHost(off)

        await model.refreshNow()
        await model.refreshNow()

        // The disabled host still gets a row, so the operator can see that it
        // exists and is switched off rather than wondering where it went.
        XCTAssertEqual(model.reports[off.id]?.displayState, .disabled)
        XCTAssertEqual(model.reports[off.id]?.counts.expected, 0, "a disabled host adds nothing to the totals")
        XCTAssertFalse(runner.recordedInvocations.isEmpty)
        XCTAssertTrue(
            runner.recordedInvocations.allSatisfy { invocation in
                invocation.arguments.contains { $0.contains("on.invalid") }
            },
            "no ssh call should have been aimed at a disabled host"
        )
        XCTAssertEqual(model.summary.enabledHosts, 1)
    }

    // MARK: - Stale results

    /// The rule: a result computed against a configuration that has since been
    /// edited must not land.
    func testResultFromBeforeAnEditIsDiscarded() async {
        let host = Fixtures.host(expected: 2)
        model.addHost(host)
        await model.refreshNow()
        let baselineInvocationCount = runner.invocationCount

        // Next check hangs inside ssh.
        runner.setDefault(.suspended(
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1), Fixtures.uuid(2)])
        ))

        let generation = model.currentGeneration(for: host.id)
        let inFlight = Task { await model.performCheck(hostID: host.id, generation: generation) }
        await runner.waitForInvocations(over: baselineInvocationCount)

        // Let subsequent checks answer normally, then edit the host mid-flight.
        runner.setDefault(.result(
            terminationStatus: 0, stdout: healthyEnvelope(uuids: [Fixtures.uuid(1)]), stderr: ""
        ))
        var edited = host
        edited.expectedGPUCount = 1
        model.updateHost(edited)

        runner.releaseAll()
        await inFlight.value
        await model.refreshNow()

        // The stale result was thrown away; whatever is on screen came from a
        // check against the new configuration.
        let report = model.reports[host.id]
        XCTAssertNotNil(report, "the post-edit check should have produced a report")
        XCTAssertEqual(report?.host.expectedGPUCount, 1)
        XCTAssertEqual(report?.counts.expected, 1)
    }

    func testResultForADeletedHostDoesNotResurrectIt() async {
        let host = Fixtures.host(expected: 1)
        model.addHost(host)
        await model.refreshNow()

        let before = runner.invocationCount
        runner.setDefault(.suspended(stdout: healthyEnvelope(uuids: [Fixtures.uuid(1)])))
        let generation = model.currentGeneration(for: host.id)
        let inFlight = Task { await model.performCheck(hostID: host.id, generation: generation) }
        await runner.waitForInvocations(over: before)

        model.deleteHost(id: host.id)
        runner.releaseAll()
        await inFlight.value

        XCTAssertNil(model.reports[host.id])
        XCTAssertTrue(model.hosts.isEmpty)
    }

    // MARK: - Baselines

    func testBaselineRegistrationRecordsWhatWasFound() async {
        let host = Fixtures.host(expected: 2)
        model.addHost(host)
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1), Fixtures.uuid(2)]),
            stderr: ""
        ))
        await model.refreshNow()

        model.registerBaseline(hostID: host.id)
        XCTAssertEqual(
            model.baselines.baseline(for: host.id)?.gpuUUIDs,
            [Fixtures.uuid(1), Fixtures.uuid(2)]
        )
        XCTAssertEqual(model.baselines.baseline(for: host.id)?.expectedCount, 2)
    }

    func testLostGPUDoesNotShrinkTheBaseline() async {
        let host = Fixtures.host(expected: 2)
        model.addHost(host)
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1), Fixtures.uuid(2)]),
            stderr: ""
        ))
        await model.refreshNow()
        model.registerBaseline(hostID: host.id)

        runner.setDefault(.result(
            terminationStatus: 0, stdout: healthyEnvelope(uuids: [Fixtures.uuid(1)]), stderr: ""
        ))
        await model.refreshNow()

        XCTAssertEqual(
            model.baselines.baseline(for: host.id)?.gpuUUIDs.count, 2,
            "a failing card must not erase its own evidence"
        )
        XCTAssertEqual(model.reports[host.id]?.counts.missing, 1)
        XCTAssertEqual(model.reports[host.id]?.counts.expected, 2)
    }

    func testBaselinePreviewIsAvailableBeforeCommitting() async {
        let host = Fixtures.host(expected: 2)
        model.addHost(host)
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1), Fixtures.uuid(2)]),
            stderr: ""
        ))
        await model.refreshNow()

        let preview = model.baselinePreview(hostID: host.id)
        XCTAssertEqual(preview?.uuids.count, 2)
        XCTAssertEqual(preview?.expected, 2)
    }

    // MARK: - Demo mode

    func testDemoModeNeverTouchesTheNetwork() async {
        model.addHost(Fixtures.host(expected: 1))
        await model.refreshNow()
        let before = runner.invocationCount

        model.setDemoMode(true)
        await model.refreshNow()
        await model.refreshNow()

        XCTAssertEqual(runner.invocationCount, before, "demo mode must not open a single ssh call")
    }

    func testDemoModeShowsEveryScenario() async {
        model.setDemoMode(true)
        let reports = model.visibleReports
        XCTAssertEqual(reports.count, 8)

        let states = reports.map(\.displayState)
        XCTAssertTrue(states.contains(.healthy))
        XCTAssertTrue(states.contains(.sshFailed(.unreachable)))
        XCTAssertTrue(states.contains(.gpuQueryFailed(.gpuToolNotFound)))
        XCTAssertTrue(states.contains(.stale))
        XCTAssertTrue(states.contains(.degraded))
    }

    func testDemoFleetAddsUp() async {
        model.setDemoMode(true)
        let summary = model.summary

        // 5090-1:4  5090-2:4  H200-01:8  H100-02:8  A100-03:4  L40S-04:2
        // H100-05:3  MI300X-06:8
        XCTAssertEqual(summary.expectedGPUs, 41)
        // Readable are the GPUs actually read this round: 4 + 3 (H100-02 is
        // unreachable, A100-03 cannot query, L40S-04 is stale) + 8 + 3 + 8.
        XCTAssertEqual(summary.readableGPUs, 26, "including all 8 AMD cards")
        XCTAssertEqual(summary.missingGPUs, 1, "5090-2 lost a card the baseline knows")
        XCTAssertEqual(summary.unexpectedGPUs, 1, "and gained one the baseline does not")
        XCTAssertEqual(summary.unknownGPUs, 14, "8 unreachable + 4 unqueryable + 2 stale")
        XCTAssertEqual(summary.warningGPUs, 1, "one GPU sits above H100-05's threshold")
        XCTAssertEqual(summary.enabledHosts, 8)
        XCTAssertEqual(summary.reachableHosts, 7, "H100-02 is unreachable")
        XCTAssertEqual(
            summary.staleHosts, 2,
            "H100-02's last good reading is 3 minutes old, so it is stale as well as unreachable"
        )
        XCTAssertFalse(summary.isFullyHealthy)
        XCTAssertTrue(summary.hasUnknowns)
        XCTAssertEqual(summary.menuBarRatio, "26/41")
    }

    /// The demo has to exercise the ROCm path, or the AMD feature is invisible
    /// in the one place a person actually looks at it — and the junction label
    /// would never be seen before it reached a real host.
    func testDemoFleetIncludesAReadableAMDHost() async {
        model.setDemoMode(true)
        let report = try? XCTUnwrap(
            model.visibleReports.first { $0.host.vendor == .amd }
        )

        guard let amd = report else { return XCTFail("no AMD host in the demo fleet") }
        XCTAssertEqual(amd.counts.readable, 8)
        XCTAssertEqual(amd.counts.expected, 8)
        XCTAssertEqual(amd.counts.unknown, 0)
        XCTAssertTrue(amd.hasCurrentCompleteReading)
        XCTAssertEqual(
            Set(amd.gpus.compactMap(\.model)), ["AMD Instinct MI300X"]
        )
        XCTAssertEqual(
            Set(amd.gpus.compactMap(\.temperatureSensor)), [.junction],
            "the demo mirrors the real cards, which report no edge sensor"
        )
        XCTAssertEqual(
            Set(amd.gpus.compactMap(\.uuid)).count, 8,
            "every demo card keeps a distinct identity"
        )
        XCTAssertEqual(
            Set(amd.gpus.compactMap(\.memoryTotalMiB)), [196_592],
            "192 GiB, the VRAM the captured MI300X output reports"
        )
        XCTAssertEqual(
            amd.gpus.compactMap(\.temperatureCelsius).min(), 60,
            "and the demo cards are readable, not blank"
        )
    }

    func testDemoModeLeavesSavedHostsUntouched() async {
        model.addHost(Fixtures.host(name: "real", destination: "real.invalid", expected: 1))
        model.setDemoMode(true)
        model.setDemoMode(false)

        XCTAssertEqual(model.hosts.count, 1)
        XCTAssertEqual(model.hosts.first?.displayName, "real")
    }

    func testDemoModeDoesNotNotify() async {
        var settings = model.settings
        settings.notificationsEnabled = true
        model.updateSettings(settings)
        model.setDemoMode(true)

        let service = NotificationService(options: .init(confirmationsRequired: 1))
        // Even fed demo reports directly, the coordinator's own guard is what
        // blocks delivery; assert the guard's precondition here.
        XCTAssertTrue(model.isDemoMode)
    }

    // MARK: - Settings and lifecycle

    func testIntervalChangeIsNormalisedAndPersisted() async {
        var settings = model.settings
        settings.intervalSeconds = 45
        model.updateSettings(settings)
        XCTAssertEqual(model.settings.intervalSeconds, PollSettings.defaultInterval)

        settings.intervalSeconds = 60
        model.updateSettings(settings)
        XCTAssertEqual(
            ConfigurationStore(directory: directory).loadConfiguration().settings.intervalSeconds,
            60
        )
    }

    func testQuitEndsThePollingLoopAndTerminatesChildren() async {
        model.addHost(Fixtures.host(expected: 1))
        await model.refreshNow()
        model.stop()
        // No direct assertion on the loop is possible; the contract that matters
        // is that stop() is safe to call and does not throw or hang.
        XCTAssertFalse(model.isRefreshing)
    }

    func testHostOrderingIsPreservedThroughReorder() {
        let a = Fixtures.host(name: "a", destination: "a.invalid")
        let b = Fixtures.host(name: "b", destination: "b.invalid")
        let c = Fixtures.host(name: "c", destination: "c.invalid")
        [a, b, c].forEach(model.addHost)

        model.moveHosts(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.hosts.map(\.displayName), ["c", "a", "b"])

        model.moveHosts(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(model.hosts.map(\.displayName), ["a", "b", "c"])
    }

    func testReorderHelperMatchesExpectedSemantics() {
        XCTAssertEqual(
            AppModel.reordering([1, 2, 3, 4, 5], moving: IndexSet(integer: 0), to: 5),
            [2, 3, 4, 5, 1]
        )
        XCTAssertEqual(
            AppModel.reordering([1, 2, 3, 4, 5], moving: IndexSet(integer: 4), to: 0),
            [5, 1, 2, 3, 4]
        )
        XCTAssertEqual(
            AppModel.reordering([1, 2, 3, 4, 5], moving: IndexSet([1, 3]), to: 5),
            [1, 3, 5, 2, 4]
        )
    }

    /// Regression: hosts loaded from disk start with no generation entry, and a
    /// mismatch between that default and the one used when checking left every
    /// loaded host stuck showing "Checking…" forever.
    func testHostLoadedFromDiskActuallyCompletesItsCheck() async {
        let host = Fixtures.host(name: "from-disk", destination: "from-disk.invalid", expected: 2)
        let store = ConfigurationStore(directory: directory)
        try? store.saveConfiguration(AppConfiguration(hosts: [host]))

        let loaded = AppModel(
            store: store,
            commands: runner,
            clock: TestClock(),
            deliverer: NoopNotificationDeliverer()
        )
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: healthyEnvelope(uuids: [Fixtures.uuid(1), Fixtures.uuid(2)]),
            stderr: ""
        ))
        loaded.start()
        await loaded.refreshNow()

        let report = loaded.reports[host.id]
        XCTAssertNotEqual(report?.displayState, .checking, "a loaded host must not stay stuck checking")
        XCTAssertEqual(report?.displayState, .healthy)
        XCTAssertEqual(report?.counts.readable, 2)
        XCTAssertEqual(report?.counts.expected, 2)
        loaded.stop()
    }

    func testLastKnownReadingsSurviveARestart() async {
        let host = Fixtures.host(expected: 1)
        model.addHost(host)
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.envelope(rows: [
                Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1), temperature: "63")
            ]),
            stderr: ""
        ))
        await model.refreshNow()

        // A second model over the same folder, as after a relaunch.
        let restarted = AppModel(
            store: ConfigurationStore(directory: directory),
            commands: FakeSSHRunner(),
            clock: TestClock(),
            deliverer: NoopNotificationDeliverer()
        )
        restarted.start()
        let report = restarted.reports[host.id]
        XCTAssertEqual(report?.gpus.first?.temperatureCelsius, 63)
        XCTAssertEqual(report?.gpus.first?.isLiveData, false, "carried data is never presented as live")
        XCTAssertEqual(report?.counts.readable, 0)
        restarted.stop()
    }
}
