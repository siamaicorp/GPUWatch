import XCTest
@testable import GPUWatchCore

/// The ROCm path has to produce the same kind of `ParsedGPUQuery` the NVIDIA
/// path does, because everything downstream is vendor-blind. These tests are
/// mostly about the ways rocm-smi differs from nvidia-smi: column order is not
/// fixed, VRAM arrives in bytes, identity is a 64-bit GUID, and the stream can
/// carry warnings before the table.
final class ROCmSMIParserTests: XCTestCase {
    func testReadsAFullRow() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))
        ])
        let parsed = ROCmSMIParser.parse(output)

        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.dataLineCount, 1)
        XCTAssertTrue(parsed.skipped.isEmpty)

        let sample = parsed.samples[0]
        XCTAssertEqual(sample.index, 0)
        XCTAssertEqual(sample.uuid, Fixtures.rocmID(1))
        XCTAssertEqual(sample.model, "AMD Radeon RX 7900 XTX")
        XCTAssertEqual(sample.temperatureCelsius, 42.0)
        XCTAssertEqual(sample.utilizationPercent, 7)
        XCTAssertEqual(sample.memoryUtilizationPercent, 12)
        XCTAssertEqual(sample.memoryTemperatureCelsius, 48.0)
        XCTAssertEqual(sample.powerDrawWatts, 180.0)
        XCTAssertEqual(sample.powerLimitWatts, 300.0)
    }

    /// rocm-smi reports VRAM in bytes; the app speaks MiB. A parser that forgot
    /// this would report 24 TB of VRAM, which is not a subtle failure.
    func testConvertsVRAMFromBytesToMiB() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(
                index: 0,
                id: Fixtures.rocmID(1),
                memoryTotalBytes: "25753026560",
                memoryUsedBytes: "1234567890"
            )
        ])
        let sample = ROCmSMIParser.parse(output).samples[0]

        XCTAssertEqual(sample.memoryTotalMiB ?? -1, 24560, accuracy: 0.0001)
        XCTAssertEqual(sample.memoryUsedMiB ?? -1, 1177.3756, accuracy: 0.01)
        XCTAssertEqual(
            sample.memoryUtilizationFraction ?? -1,
            1234567890.0 / 25753026560.0,
            accuracy: 0.0001
        )
    }

    /// The property the whole parser is built around: rocm-smi builds its header
    /// from the union of keys present across the cards, so the order of the
    /// metric columns is not a contract. The same row with those columns moved
    /// must parse identically.
    ///
    /// The `device` label stays first because rocm-smi always writes it there —
    /// that is what lets the header be recognised at all.
    func testMetricColumnOrderDoesNotChangeTheResult() {
        // `device` stays first, since that is what makes the header recognisable;
        // the metric columns are reversed around it. Header and values move
        // together, so a parser reading by position would get the wrong numbers
        // rather than fail loudly.
        let reordered = ["device"] + Fixtures.rocmHeaders.dropFirst().reversed()
        XCTAssertNotEqual(reordered, Fixtures.rocmHeaders, "the columns really are reordered")

        let forward = Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))])
        let shuffled = Fixtures.rocmOutput(
            headers: reordered,
            rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1), order: reordered)]
        )

        XCTAssertEqual(ROCmSMIParser.parse(forward).samples, ROCmSMIParser.parse(shuffled).samples)
    }

    /// A missing reading is `nil`, never `0`. Zero utilisation is a real
    /// measurement and must stay distinguishable from silence.
    func testUnsupportedValuesAreNilNotZero() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(
                index: 0,
                id: Fixtures.rocmID(1),
                utilization: "N/A",
                memoryUtilization: "N/A",
                temperature: "N/A",
                junctionTemperature: "N/A",
                memoryTemperature: "N/A",
                memoryTotalBytes: "N/A",
                memoryUsedBytes: "N/A",
                powerDraw: "N/A",
                powerLimit: "N/A"
            )
        ])
        let parsed = ROCmSMIParser.parse(output)
        let sample = parsed.samples[0]

        XCTAssertNil(sample.temperatureCelsius)
        XCTAssertNil(sample.utilizationPercent)
        XCTAssertNil(sample.memoryUtilizationPercent)
        XCTAssertNil(sample.memoryTotalMiB)
        XCTAssertNil(sample.memoryUsedMiB)
        XCTAssertNil(sample.powerDrawWatts)
        XCTAssertNil(sample.powerLimitWatts)
        XCTAssertNil(sample.memoryTemperatureCelsius)
        XCTAssertFalse(sample.hasCoreMetrics)
        XCTAssertEqual(parsed.samplesWithoutCoreMetrics, 1, "and that must be reported, not hidden")
    }

    /// When both sensors exist, edge wins: it is the one that corresponds to
    /// nvidia-smi's `temperature.gpu`, so a threshold means the same thing on
    /// both vendors.
    func testEdgeSensorIsPreferredWhenBothExist() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(
                index: 0,
                id: Fixtures.rocmID(1),
                temperature: "42.0",
                junctionTemperature: "91.0"
            )
        ])
        let sample = ROCmSMIParser.parse(output).samples[0]

        XCTAssertEqual(sample.temperatureCelsius, 42.0, "not the hotter junction reading")
        XCTAssertEqual(sample.temperatureSensor, .core)
    }

    /// An edge column that is present but unanswered is the same situation as
    /// no edge column at all: the driver did tell us a temperature, just not
    /// from that sensor.
    func testEdgeColumnPresentButUnansweredStillFallsBackToJunction() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(
                index: 0,
                id: Fixtures.rocmID(1),
                temperature: "N/A",
                junctionTemperature: "67.0"
            )
        ])
        let sample = ROCmSMIParser.parse(output).samples[0]

        XCTAssertEqual(sample.temperatureCelsius, 67.0)
        XCTAssertEqual(sample.temperatureSensor, .junction)
    }

    /// AMD's Instinct cards report no edge sensor at all. Falling back to
    /// junction is what keeps a healthy host from looking unreadable — but the
    /// sample has to say which sensor it used, because junction reads hotter and
    /// a threshold must not silently move onto a different scale.
    func testJunctionIsUsedAsTheFallbackAndTheSensorIsRecorded() {
        let headers = [
            "device",
            "Unique ID",
            "Temperature (Sensor junction) (C)",
            "Temperature (Sensor memory) (C)",
            "GPU use (%)",
            "VRAM Total Memory (B)"
        ]
        let output = Fixtures.rocmOutput(headers: headers, rows: [
            "card0,\(Fixtures.rocmID(1)),50.0,43.0,0,206141652992"
        ])
        let parsed = ROCmSMIParser.parse(output)
        let sample = parsed.samples[0]

        XCTAssertEqual(sample.temperatureCelsius, 50.0)
        XCTAssertEqual(sample.temperatureSensor, .junction)
        XCTAssertEqual(sample.memoryTemperatureCelsius, 43.0)
        XCTAssertTrue(sample.hasCoreMetrics, "a junction reading is still a reading")
        XCTAssertEqual(parsed.samplesWithoutCoreMetrics, 0)
        XCTAssertTrue(parsed.warnings.isEmpty, "and nothing should be flagged on a healthy card")
    }

    /// No temperature column at all is still a readability problem, and must
    /// stay distinguishable from the fallback case above.
    func testNoTemperatureColumnAtAllIsStillAReadabilityProblem() {
        let headers = ["device", "VRAM Total Memory (B)", "GPU use (%)"]
        let parsed = ROCmSMIParser.parse(
            Fixtures.rocmOutput(headers: headers, rows: ["card0,206141652992,0"])
        )

        XCTAssertNil(parsed.samples[0].temperatureCelsius)
        XCTAssertNil(parsed.samples[0].temperatureSensor)
        XCTAssertEqual(parsed.samplesWithoutCoreMetrics, 1)
    }

    // MARK: - Captured from real hardware

    /// The whole row set captured from an 8× MI300X host must parse cleanly.
    ///
    /// This is the fixture that matters most: it is the only one not written by
    /// hand, and it is what showed that these cards have no edge sensor.
    func testRealMI300XOutputParsesCleanly() {
        let parsed = ROCmSMIParser.parse(Fixtures.realMI300XOutput)

        XCTAssertEqual(parsed.samples.count, 8)
        XCTAssertEqual(parsed.dataLineCount, 8, "the warning line and the blank line are not GPUs")
        XCTAssertTrue(parsed.skipped.isEmpty)
        XCTAssertEqual(parsed.samplesWithoutUUID, 0, "every card reported a distinct GUID")
        XCTAssertEqual(parsed.samplesWithoutCoreMetrics, 0)
        XCTAssertTrue(parsed.duplicateUUIDs.isEmpty)
        XCTAssertTrue(parsed.warnings.isEmpty, "nothing on this host is worth flagging")
    }

    func testRealMI300XReadingsAreCorrect() {
        let first = ROCmSMIParser.parse(Fixtures.realMI300XOutput).samples[0]

        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.uuid, "0xf867a5aff611c0cc")
        XCTAssertEqual(first.model, "AMD Instinct MI300X")
        XCTAssertEqual(first.temperatureCelsius, 50.0)
        XCTAssertEqual(first.temperatureSensor, .junction)
        XCTAssertEqual(first.memoryTemperatureCelsius, 43.0)
        // 206141652992 bytes of VRAM, and 297771008 bytes in use.
        XCTAssertEqual(first.memoryTotalMiB ?? 0, 196592, accuracy: 0.001)
        XCTAssertEqual(first.memoryUsedMiB ?? 0, 283.9765625, accuracy: 0.001)
        XCTAssertEqual(first.powerDrawWatts, 162.0, "the socket reading, not the 750 W cap")
        XCTAssertEqual(first.powerLimitWatts, 750.0)
        // An idle card genuinely reads zero, and zero must survive as zero.
        XCTAssertEqual(first.utilizationPercent, 0)
        XCTAssertEqual(first.memoryUtilizationPercent, 0)
    }

    /// The real header puts the columns in a different order than the synthetic
    /// fixture does, which is the case the by-name parser exists for.
    func testRealHeaderOrderDiffersFromTheSyntheticFixture() {
        let realHeader = Fixtures.realMI300XOutput
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("device,") }

        XCTAssertNotNil(realHeader)
        XCTAssertNotEqual(realHeader, Fixtures.rocmHeaders.joined(separator: ","))
    }

    /// Some cards report a zero GUID for every GPU. Zero is not an identity.
    func testAllZeroUniqueIDIsTreatedAsNoIdentity() {
        for zero in ["0x0000000000000000", "0", "0x0"] {
            let output = Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: zero)])
            let parsed = ROCmSMIParser.parse(output)

            XCTAssertNil(parsed.samples[0].uuid, "\(zero) is not an identity")
            XCTAssertFalse(parsed.samples[0].hasIdentity)
            XCTAssertEqual(parsed.samplesWithoutUUID, 1)
            XCTAssertTrue(
                parsed.warnings.contains { $0.contains("no UUID") },
                "the operator has to be told identity could not be verified"
            )
        }
    }

    /// The same GUID on two cards is ambiguous, and the duplicate check that
    /// already exists on the NVIDIA path has to fire here too.
    func testDuplicateIdentifiersAreReported() {
        let output = Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1)),
            Fixtures.rocmRow(index: 1, id: Fixtures.rocmID(1))
        ])
        let parsed = ROCmSMIParser.parse(output)

        XCTAssertEqual(parsed.duplicateUUIDs, [Fixtures.rocmID(1)])
        XCTAssertEqual(parsed.samples.count, 2, "both rows still parse; identity is what is doubtful")
    }

    /// rocm-smi prints warnings onto the same stream — a low-power state, a
    /// permissions note. None of that is a GPU, and a line count that included
    /// it would overstate what was read.
    func testWarningsBeforeTheHeaderAreIgnored() {
        let noise = [
            "WARNING: AMD GPU device(s) is/are in a low-power state. Check power control.",
            "======================= ROCm System Management Interface ======================="
        ]
        let output = (noise + [
            Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))])
        ]).joined(separator: "\n")

        let parsed = ROCmSMIParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.dataLineCount, 1)
        XCTAssertTrue(parsed.skipped.isEmpty)
    }

    /// Trailing output after the table is not a GPU either.
    func testTrailingSummaryLinesAreNotCountedAsGPUs() {
        let output = Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))])
            + "\n======================= End of ROCm SMI Log ============================"
        let parsed = ROCmSMIParser.parse(output)

        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.dataLineCount, 1)
    }

    /// A row whose arity disagrees with the header cannot be mapped by name, so
    /// it is refused and reported rather than partially used.
    func testRowWithWrongFieldCountIsSkipped() {
        let rows = [
            Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1)),
            "card1,AMD Radeon RX 7900 XTX,0x1000000000000002"
        ]
        let parsed = ROCmSMIParser.parse(Fixtures.rocmOutput(rows: rows))

        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.skipped.count, 1)
        if case let .wrongFieldCount(expected, found) = parsed.skipped[0].reason {
            XCTAssertEqual(expected, Fixtures.rocmHeaders.count)
            XCTAssertEqual(found, 3)
        } else {
            XCTFail("expected a field-count problem, got \(parsed.skipped[0].reason)")
        }
    }

    /// Output with no recognisable header at all: we hold nothing, and the
    /// caller must be able to tell that from "the host has no GPUs".
    func testOutputWithNoHeaderIsEntirelyUnusable() {
        let parsed = ROCmSMIParser.parse("rocm-smi: command failed: no such device")

        XCTAssertTrue(parsed.samples.isEmpty)
        XCTAssertTrue(parsed.isEmpty, "no data rows were ever counted")
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertTrue(ROCmSMIParser.parse("").isEmpty)
        XCTAssertTrue(ROCmSMIParser.parse("\n\n   \n").isEmpty)
    }

    /// A row that was dropped has to say which line it was, so the operator can
    /// go and look rather than guess what went missing.
    func testDroppedRowsAreReportedWithTheirLineNumber() {
        let parsed = ROCmSMIParser.parse(Fixtures.rocmOutput(rows: [
            Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1)),
            "card1,short"
        ]))

        XCTAssertEqual(parsed.skipped.count, 1)
        XCTAssertEqual(parsed.skipped[0].lineNumber, 3, "header, then the first row")
        XCTAssertTrue(parsed.warnings.contains(parsed.skipped[0].explanation))
    }
}
