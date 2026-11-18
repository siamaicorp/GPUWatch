import XCTest
@testable import GPUWatchCore

final class CSVLineTests: XCTestCase {
    func testPlainFieldsSplit() {
        XCTAssertEqual(CSVLine.values("a, b, c"), ["a", " b", " c"])
    }

    func testQuotedFieldContainingCommaStaysOneField() {
        // The space nvidia-smi writes between fields is a separator, not part of
        // the quoted value, so it is dropped along with the quotes.
        XCTAssertEqual(
            CSVLine.values("0, GPU-1, \"Tesla V100, 32GB\", 41, 10, 100, 32000"),
            ["0", " GPU-1", "Tesla V100, 32GB", " 41", " 10", " 100", " 32000"]
        )
    }

    func testDoubledQuoteEscapes() {
        XCTAssertEqual(CSVLine.values("\"a \"\"quoted\"\" name\",1"), ["a \"quoted\" name", "1"])
    }

    func testTrailingCarriageReturnIsDropped() {
        XCTAssertEqual(CSVLine.values("a,b\r"), ["a", "b"])
    }

    func testUnterminatedQuoteIsReported() {
        XCTAssertNil(CSVLine.values("0, GPU-1, \"broken, 41, 10"))
    }

    func testEmptyLineYieldsSingleEmptyField() {
        XCTAssertEqual(CSVLine.values(""), [""])
    }
}

final class GPUFieldValueTests: XCTestCase {
    func testUnsupportedSpellingsBecomeNil() {
        for value in ["N/A", "n/a", "[N/A]", "[Not Supported]", "Not Supported", "Unknown", "", "  "] {
            XCTAssertNil(GPUFieldValue.double(value), "\(value) should be unsupported")
            XCTAssertNil(GPUFieldValue.string(value), "\(value) should be unsupported")
        }
    }

    func testZeroIsARealMeasurement() {
        XCTAssertEqual(GPUFieldValue.double("0"), 0)
        XCTAssertEqual(GPUFieldValue.integer("0"), 0)
    }

    func testIntegerAcceptsDriverStyleDecimals() {
        XCTAssertEqual(GPUFieldValue.integer("3.0"), 3)
        XCTAssertNil(GPUFieldValue.integer("3.5"))
    }
}

final class NVIDIAQueryParserTests: XCTestCase {
    func testNormalRowsParse() {
        let output = [
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1), temperature: "41", utilization: "12"),
            Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(2), temperature: "45", utilization: "0")
        ].joined(separator: "\n")

        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 2)
        XCTAssertEqual(parsed.samples[0].index, 0)
        XCTAssertEqual(parsed.samples[0].uuid, Fixtures.uuid(1))
        XCTAssertEqual(parsed.samples[0].temperatureCelsius, 41)
        XCTAssertTrue(parsed.skipped.isEmpty)
        XCTAssertTrue(parsed.warnings.isEmpty)
    }

    func testQuotedModelNameParsesAsOneField() {
        let output = "0, \(Fixtures.uuid(1)), \"Tesla V100, 32GB\", 41, 10, 100, 32000"
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.samples[0].model, "Tesla V100, 32GB")
    }

    func testUnsupportedMetricsStayNilRatherThanZero() {
        let output = Fixtures.csvRow(
            index: 0, uuid: Fixtures.uuid(1),
            temperature: "N/A", utilization: "[Not Supported]", memoryUsed: "N/A"
        )
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertNil(parsed.samples[0].temperatureCelsius)
        XCTAssertNil(parsed.samples[0].utilizationPercent)
        XCTAssertNil(parsed.samples[0].memoryUsedMiB)
        XCTAssertEqual(parsed.samples[0].memoryTotalMiB, 81920)
        // Identity plus memory total is not enough; this GPU cannot be called
        // fully readable.
        XCTAssertFalse(parsed.samples[0].hasCoreMetrics)
        XCTAssertEqual(parsed.samplesWithoutCoreMetrics, 1)
    }

    func testEmptyOutputIsEmpty() {
        let parsed = NVIDIAQueryParser.parse("")
        XCTAssertTrue(parsed.isEmpty)
        XCTAssertFalse(parsed.isEntirelyUnusable)
    }

    func testOnlyBlankLinesIsNotEmpty() {
        let parsed = NVIDIAQueryParser.parse("\n\n   \n")
        XCTAssertTrue(parsed.isEmpty)
    }

    func testMalformedRowsAreSkippedAndExplained() {
        let output = [
            "this is not csv at all",
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1))
        ].joined(separator: "\n")
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1)
        XCTAssertEqual(parsed.skipped.count, 1)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("expected 7 fields") })
    }

    func testEntirelyUnusableOutput() {
        let parsed = NVIDIAQueryParser.parse("garbage\nalso garbage")
        XCTAssertTrue(parsed.isEntirelyUnusable)
        XCTAssertTrue(parsed.samples.isEmpty)
    }

    func testPartialResultKeepsGoodRowsAndReportsTheBad() {
        let output = [
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
            "0, GPU-1, broken row",
            Fixtures.csvRow(index: 2, uuid: Fixtures.uuid(3))
        ].joined(separator: "\n")
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 2)
        XCTAssertEqual(parsed.skipped.count, 1)
        XCTAssertFalse(parsed.isEntirelyUnusable)
    }

    func testMIGInstancesAreNotCountedAsPhysicalGPUs() {
        let output = [
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
            Fixtures.csvRow(index: 1, uuid: "MIG-1a2b3c4d-0000-0000-0000-000000000000")
        ].joined(separator: "\n")
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1, "a MIG slice is not an extra card")
        XCTAssertEqual(parsed.skipped.count, 1)
        XCTAssertTrue(parsed.warnings.contains { $0.contains("MIG") })
        // A MIG skip must not make the physical inventory look incomplete.
        XCTAssertTrue(parsed.skipped.allSatisfy { $0.reason == .migInstance })
    }

    func testDuplicateUUIDsAreFlagged() {
        let output = [
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
            Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(1))
        ].joined(separator: "\n")
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.duplicateUUIDs, [Fixtures.uuid(1)])
        XCTAssertTrue(parsed.warnings.contains { $0.contains("duplicate GPU UUIDs") })
    }

    func testRowWithoutUUIDIsRecordedAsUnidentifiable() {
        let output = "0, N/A, NVIDIA H100, 60, 10, 100, 81920"
        let parsed = NVIDIAQueryParser.parse(output)
        XCTAssertEqual(parsed.samples.count, 1, "the GPU was reported, just not identified")
        XCTAssertEqual(parsed.samplesWithoutUUID, 1)
    }

    /// The core anti-corruption test: identity must survive a reboot that
    /// reassigns indices.
    func testUUIDRemainsIdentityWhenIndicesSwap() {
        let before = NVIDIAQueryParser.parse([
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1)),
            Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(2))
        ].joined(separator: "\n"))

        let after = NVIDIAQueryParser.parse([
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(2)),
            Fixtures.csvRow(index: 1, uuid: Fixtures.uuid(1))
        ].joined(separator: "\n"))

        XCTAssertEqual(Set(before.samples.compactMap(\.uuid)), Set(after.samples.compactMap(\.uuid)))
    }
}
