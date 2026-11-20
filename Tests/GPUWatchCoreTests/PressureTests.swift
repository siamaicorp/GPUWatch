import XCTest
@testable import GPUWatchCore

/// Pressure — how hard a card is being worked — must never be confused with
/// health. These tests pin that separation down, because it is the one thing a
/// GPU monitor most easily gets wrong: reporting a busy machine as a broken one
/// teaches an operator to ignore it.
final class PressureTests: XCTestCase {
    private let evaluator = GPUStateEvaluator()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let settings = PollSettings()

    private func report(
        host: HostConfig,
        rows: [String],
        complete: Bool = true
    ) -> HostReport {
        let parsed = NVIDIAQueryParser.parse(rows.joined(separator: "\n"))
        return evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: HostProbeResult(
                ssh: .ok,
                query: .ok(samples: parsed.samples, partialWarnings: parsed.warnings),
                attemptedAt: now,
                transportConfirmed: true,
                queryWasComplete: complete,
                parseWarnings: parsed.warnings
            ),
            previous: nil,
            settings: settings,
            now: now
        )
    }

    /// A threshold crossing on a card whose temperature came from the junction
    /// sensor has to say so. The same number means a hotter card on that scale
    /// than on the package sensor, so a warning that hides the difference is
    /// telling the operator something slightly untrue.
    func testJunctionThresholdWarningNamesTheSensor() {
        let headers = [
            "device", "Unique ID", "Temperature (Sensor junction) (C)",
            "GPU use (%)", "VRAM Total Memory (B)"
        ]
        let output = Fixtures.rocmOutput(headers: headers, rows: [
            "card0,\(Fixtures.rocmID(1)),95.0,0,206141652992"
        ])
        let parsed = ROCmSMIParser.parse(output)
        let host = Fixtures.host(vendor: .amd, temperatureThreshold: 90)

        let evaluated = evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: HostProbeResult(
                ssh: .ok,
                query: .ok(samples: parsed.samples, partialWarnings: parsed.warnings),
                attemptedAt: now,
                transportConfirmed: true,
                queryWasComplete: true,
                parseWarnings: parsed.warnings
            ),
            previous: nil,
            settings: settings,
            now: now
        )

        let text = evaluated.gpus.first?.pressureWarnings.first?.text
        XCTAssertEqual(text, "95°C (junction sensor) at or above the 90°C threshold")
    }

    // MARK: - Parsing

    func testPressureFieldsParseFromTheSameRow() throws {
        let parsed = NVIDIAQueryParser.parse(Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            powerDraw: "412", powerLimit: "575",
            memoryTemperature: "71", memoryUtilization: "88"
        ))
        let sample = try XCTUnwrap(parsed.samples.first)
        XCTAssertEqual(sample.powerDrawWatts, 412)
        XCTAssertEqual(sample.powerLimitWatts, 575)
        XCTAssertEqual(sample.memoryTemperatureCelsius, 71)
        XCTAssertEqual(sample.memoryUtilizationPercent, 88)
        XCTAssertEqual(try XCTUnwrap(sample.powerFraction), 412.0 / 575.0, accuracy: 0.0001)
    }

    /// Many cards do not report HBM temperature at all — every RTX 5090 among
    /// them, verified on real hardware. Absence must stay absent.
    func testUnsupportedMemoryTemperatureStaysNil() {
        let parsed = NVIDIAQueryParser.parse(Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            powerDraw: "412", powerLimit: "575",
            memoryTemperature: "N/A", memoryUtilization: "88"
        ))
        let sample = parsed.samples[0]
        XCTAssertNil(sample.memoryTemperatureCelsius)
        XCTAssertEqual(sample.memoryUtilizationPercent, 88)
        XCTAssertTrue(sample.hasPressureReadings, "the other pressure readings are still usable")
        XCTAssertFalse(sample.hasCoreMetrics == false)
    }

    // MARK: - The rule: load is not ill health

    /// The headline requirement. A card at 100% utilisation and 99% VRAM on a
    /// host with no thresholds declared is a *working* card.
    func testABusyGPUIsHealthyWhenNoThresholdsAreDeclared() {
        let host = Fixtures.host(expected: 1)
        let report = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            temperature: "78", utilization: "100",
            memoryUsed: "32300", memoryTotal: "32607",
            powerDraw: "570", powerLimit: "575",
            memoryTemperature: "94", memoryUtilization: "99"
        )])

        XCTAssertEqual(report.gpus[0].health, .healthy)
        XCTAssertEqual(report.counts.readable, 1)
        XCTAssertEqual(report.counts.warnings, 0)
        XCTAssertEqual(report.displayState, .healthy)
    }

    func testCrossingAThresholdFlagsTheGPUWithoutCallingItBroken() {
        let host = Fixtures.host(expected: 1, vramThreshold: 0.9)
        let report = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            memoryUsed: "32300", memoryTotal: "32607"
        )])

        XCTAssertEqual(report.gpus[0].pressureWarnings.count, 1)
        XCTAssertEqual(report.gpus[0].pressureWarnings.first?.kind, .pressure)
        XCTAssertTrue(report.gpus[0].pressureWarnings.first?.text.contains("VRAM") == true)
        // Still readable, still not missing, still not unknown.
        XCTAssertEqual(report.counts.readable, 1)
        XCTAssertEqual(report.counts.missing, 0)
        XCTAssertEqual(report.counts.unknown, 0)
        XCTAssertEqual(report.displayState, .degraded)
    }

    func testPowerThresholdFlagsAtTheLimitNotBefore() {
        let host = Fixtures.host(expected: 1, powerThreshold: 0.9)

        let below = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1), powerDraw: "500", powerLimit: "575"
        )])
        XCTAssertEqual(below.gpus[0].health, .healthy, "500/575 is 87%, below a 90% threshold")

        let above = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1), powerDraw: "560", powerLimit: "575"
        )])
        XCTAssertEqual(above.gpus[0].pressureWarnings.count, 1)
        XCTAssertTrue(above.gpus[0].pressureWarnings.first?.text.contains("power limit") == true)
    }

    func testThresholdsAreOnlyAppliedWhereTheOperatorSetThem() {
        // A temperature threshold with nothing else declared must not leak into
        // a VRAM or power complaint.
        let host = Fixtures.host(expected: 1, temperatureThreshold: 80)
        let report = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            temperature: "70", memoryUsed: "32000", memoryTotal: "32607",
            powerDraw: "574", powerLimit: "575"
        )])
        XCTAssertEqual(report.gpus[0].health, .healthy)
    }

    // MARK: - The two kinds are distinguishable

    func testReadabilityAndPressureWarningsAreSeparated() {
        let host = Fixtures.host(expected: 1, temperatureThreshold: 80)
        // No temperature reported *and* over a threshold on the one reading that
        // is present would be contradictory, so drive the readability warning
        // with a missing memory total instead.
        let report = report(host: host, rows: [
            "0, \(Fixtures.uuid(1)), NVIDIA H100, 84, 100, N/A, N/A, 570, 575, N/A, 99"
        ])
        let gpu = report.gpus[0]

        XCTAssertEqual(gpu.readabilityWarnings.count, 1, "memory total was not reported")
        XCTAssertEqual(gpu.pressureWarnings.count, 1, "temperature is over the threshold")
        XCTAssertEqual(gpu.readabilityWarnings.first?.kind, .readability)
        XCTAssertEqual(gpu.pressureWarnings.first?.kind, .pressure)
        XCTAssertTrue(gpu.readabilityWarnings.first?.text.contains("memory total") == true)
        XCTAssertTrue(gpu.pressureWarnings.first?.text.contains("84") == true)
        // Both kinds still make it amber, and neither makes it missing.
        XCTAssertEqual(report.counts.warnings, 1)
        XCTAssertEqual(report.counts.missing, 0)
    }

    // MARK: - Pressure readings reach the UI

    func testPressureReadingsAreCarriedThroughForDisplay() {
        let host = Fixtures.host(expected: 1)
        let report = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            powerDraw: "412", powerLimit: "575",
            memoryTemperature: "N/A", memoryUtilization: "88"
        )])
        let pressure = report.gpus[0].pressure
        XCTAssertNotNil(pressure)
        XCTAssertEqual(pressure?.powerDrawWatts, 412)
        XCTAssertNil(pressure?.memoryTemperatureCelsius, "unsupported stays unsupported")
        XCTAssertTrue(pressure?.hasAnyReading == true)
    }

    func testNoPressureReadingsMeansNoPressureLine() {
        let host = Fixtures.host(expected: 1)
        let report = report(host: host, rows: [
            "0, \(Fixtures.uuid(1)), NVIDIA H100, 60, 10, 100, 81920, N/A, N/A, N/A, N/A"
        ])
        XCTAssertNil(
            report.gpus[0].pressure,
            "a card that reports no load readings should show no load line at all"
        )
    }

    // MARK: - A failed check tells us nothing about load either

    func testTransportFailureLeavesNoPressureClaim() {
        let host = Fixtures.host(expected: 1, vramThreshold: 0.9)
        let previous = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1), memoryUsed: "32300", memoryTotal: "32607"
        )])
        XCTAssertEqual(previous.gpus[0].pressureWarnings.count, 1)

        let unreachable = evaluator.evaluate(
            host: host,
            baseline: nil,
            probe: HostProbeResult(
                ssh: .failed(kind: .unreachable, detail: "timed out"),
                query: .failed(reason: .transportFailure, detail: ""),
                attemptedAt: now.addingTimeInterval(30)
            ),
            previous: previous,
            settings: settings,
            now: now.addingTimeInterval(30)
        )

        // Carried-forward readings keep their values but stop being findings.
        XCTAssertEqual(unreachable.gpus[0].pressureWarnings.count, 0)
        XCTAssertEqual(unreachable.gpus[0].readabilityWarnings.count, 0)
        XCTAssertEqual(unreachable.counts.warnings, 0)
        XCTAssertEqual(unreachable.counts.missing, 0)
        XCTAssertEqual(unreachable.counts.readable, 0)
    }

    // MARK: - Notifications label the two kinds

    func testAPressureAlertIsLabelledAsLoad() {
        let service = NotificationService(options: .init(confirmationsRequired: 1))
        let host = Fixtures.host(expected: 1, vramThreshold: 0.9)
        let hot = report(host: host, rows: [Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1), memoryUsed: "32300", memoryTotal: "32607"
        )])
        let outgoing = service.evaluate(reports: [hot], now: now)

        XCTAssertEqual(outgoing.count, 1)
        XCTAssertTrue(
            outgoing[0].body.contains("load:"),
            "an operator must be able to tell a busy card from a broken one without opening the app"
        )
    }
}
