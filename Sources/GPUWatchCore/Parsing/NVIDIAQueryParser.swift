import Foundation

/// One line the parser refused to turn into a sample, kept so the UI can
/// explain exactly what was dropped instead of silently under-reporting.
public struct SkippedGPULine: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case wrongFieldCount(expected: Int, found: Int)
        case unterminatedQuote
        case unusableIndex
        /// A MIG compute instance rather than a physical GPU. Counted nowhere,
        /// because MIG slices are partitions of one card, not extra cards.
        case migInstance
        case blank
    }

    public let lineNumber: Int
    public let text: String
    public let reason: Reason

    public var explanation: String {
        switch reason {
        case let .wrongFieldCount(expected, found):
            return "line \(lineNumber): expected \(expected) fields, found \(found)"
        case .unterminatedQuote:
            return "line \(lineNumber): unterminated quoted field"
        case .unusableIndex:
            return "line \(lineNumber): no usable GPU index"
        case .migInstance:
            return "line \(lineNumber): MIG instance ignored (not a physical GPU)"
        case .blank:
            return "line \(lineNumber): empty"
        }
    }
}

/// Result of interpreting one `nvidia-smi` query.
///
/// The parser never decides whether the host is healthy. It only reports what
/// it could and could not read, and the evaluator applies policy.
public struct ParsedGPUQuery: Equatable, Sendable {
    public let samples: [GPUSample]
    public let skipped: [SkippedGPULine]
    /// Count of non-empty lines that looked like data.
    public let dataLineCount: Int
    /// UUIDs seen more than once, which would make identity ambiguous.
    public let duplicateUUIDs: [String]
    /// Samples whose UUID was absent, so identity is unverifiable.
    public let samplesWithoutUUID: Int
    /// Samples the driver identified but for which it answered no core metric.
    public let samplesWithoutCoreMetrics: Int

    public init(
        samples: [GPUSample] = [],
        skipped: [SkippedGPULine] = [],
        dataLineCount: Int = 0,
        duplicateUUIDs: [String] = [],
        samplesWithoutUUID: Int = 0,
        samplesWithoutCoreMetrics: Int = 0
    ) {
        self.samples = samples
        self.skipped = skipped
        self.dataLineCount = dataLineCount
        self.duplicateUUIDs = duplicateUUIDs
        self.samplesWithoutUUID = samplesWithoutUUID
        self.samplesWithoutCoreMetrics = samplesWithoutCoreMetrics
    }

    /// Nothing came back at all.
    public var isEmpty: Bool { dataLineCount == 0 }

    /// Lines arrived but not one of them produced a sample.
    public var isEntirelyUnusable: Bool { dataLineCount > 0 && samples.isEmpty }

    /// Non-fatal imperfections worth surfacing next to the numbers.
    public var warnings: [String] {
        var result: [String] = []
        result.append(contentsOf: skipped.map(\.explanation))
        if !duplicateUUIDs.isEmpty {
            result.append("duplicate GPU UUIDs reported: \(duplicateUUIDs.joined(separator: ", "))")
        }
        if samplesWithoutUUID > 0 {
            result.append("\(samplesWithoutUUID) GPU row(s) had no UUID, so they cannot be tracked")
        }
        if samplesWithoutCoreMetrics > 0 {
            result.append("\(samplesWithoutCoreMetrics) GPU row(s) reported no usable metrics")
        }
        return result
    }
}

/// Turns `nvidia-smi --format=csv,noheader,nounits` output into samples.
///
/// Field order matches `RemoteProbe.queryFields`:
/// `index, uuid, name, temperature.gpu, utilization.gpu, memory.used,
/// memory.total, power.draw, power.limit, temperature.memory,
/// utilization.memory`
public enum NVIDIAQueryParser {
    public static let expectedFieldCount = 11

    public static func parse(_ output: String) -> ParsedGPUQuery {
        var samples: [GPUSample] = []
        var skipped: [SkippedGPULine] = []
        var dataLineCount = 0
        var uuidCounts: [String: Int] = [:]
        var samplesWithoutUUID = 0
        var samplesWithoutCoreMetrics = 0

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            dataLineCount += 1

            guard let fields = CSVLine.values(line) else {
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber, text: line, reason: .unterminatedQuote
                ))
                continue
            }
            guard fields.count == expectedFieldCount else {
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber,
                    text: line,
                    reason: .wrongFieldCount(expected: expectedFieldCount, found: fields.count)
                ))
                continue
            }

            // A MIG slice is a partition of a physical card. Counting it would
            // inflate the GPU total, so it is dropped and reported instead.
            let uuid = GPUFieldValue.string(fields[1])
            if let uuid, uuid.uppercased().hasPrefix("MIG-") {
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber, text: line, reason: .migInstance
                ))
                continue
            }

            let index = GPUFieldValue.integer(fields[0])
            if index == nil, uuid == nil {
                // Neither a position nor an identity: nothing can be done with
                // this row, and guessing would create a phantom GPU.
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber, text: line, reason: .unusableIndex
                ))
                continue
            }

            let temperature = GPUFieldValue.double(fields[3])
            let sample = GPUSample(
                index: index,
                uuid: uuid,
                model: GPUFieldValue.string(fields[2]),
                temperatureCelsius: temperature,
                // `temperature.gpu` is the package sensor, so NVIDIA always
                // reports the same scale the ROCm path calls `core`.
                temperatureSensor: temperature == nil ? nil : .core,
                utilizationPercent: GPUFieldValue.double(fields[4]),
                memoryUsedMiB: GPUFieldValue.double(fields[5]),
                memoryTotalMiB: GPUFieldValue.double(fields[6]),
                powerDrawWatts: GPUFieldValue.double(fields[7]),
                powerLimitWatts: GPUFieldValue.double(fields[8]),
                memoryTemperatureCelsius: GPUFieldValue.double(fields[9]),
                memoryUtilizationPercent: GPUFieldValue.double(fields[10])
            )

            if let uuid {
                uuidCounts[uuid, default: 0] += 1
            } else {
                samplesWithoutUUID += 1
            }
            if !sample.hasCoreMetrics {
                samplesWithoutCoreMetrics += 1
            }
            samples.append(sample)
        }

        let duplicates = uuidCounts.filter { $0.value > 1 }.keys.sorted()

        return ParsedGPUQuery(
            samples: samples,
            skipped: skipped,
            dataLineCount: dataLineCount,
            duplicateUUIDs: Array(duplicates),
            samplesWithoutUUID: samplesWithoutUUID,
            samplesWithoutCoreMetrics: samplesWithoutCoreMetrics
        )
    }
}
