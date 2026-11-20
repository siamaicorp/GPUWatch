import Foundation

/// Turns `rocm-smi --csv` output into the same `ParsedGPUQuery` the NVIDIA path
/// produces, so everything downstream — evaluation, baselines, notifications —
/// is vendor-blind.
///
/// Three things about rocm-smi shape this parser, and all three are reasons to
/// read by column *name* rather than by position:
///
/// 1. **Column order is not a contract.** rocm-smi builds its header from the
///    union of keys present across the cards it found, so a machine whose cards
///    report different metric sets gets a different order than a machine whose
///    cards agree.
/// 2. **Units differ from nvidia-smi.** VRAM arrives in bytes, where the
///    NVIDIA path deals in MiB. That conversion happens here, once, so no other
///    code has to know which tool produced a `GPUSample`.
/// 3. **Absence is spelled `N/A`.** As with nvidia-smi that becomes `nil`,
///    never zero.
public enum ROCmSMIParser {
    /// Name of the first column, which rocm-smi uses to label the row rather
    /// than to carry a metric.
    private static let rowLabelHeader = "device"

    /// The prefix a data row carries, e.g. `card0`.
    private static let rowPrefix = "card"

    public static func parse(_ output: String) -> ParsedGPUQuery {
        var samples: [GPUSample] = []
        var skipped: [SkippedGPULine] = []
        var dataLineCount = 0
        var uuidCounts: [String: Int] = [:]
        var samplesWithoutUUID = 0
        var samplesWithoutCoreMetrics = 0

        // The header is not guaranteed to be the first line: rocm-smi prints
        // warnings (low-power state, missing permissions) onto the same stream.
        // So the header is located explicitly rather than assumed, and anything
        // before it is ignored rather than parsed as data.
        var columns: [Column] = []

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            guard let fields = CSVLine.values(line) else {
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber, text: line, reason: .unterminatedQuote
                ))
                continue
            }

            if columns.isEmpty {
                // Only a line whose first cell is the known row-label header is
                // accepted, so a stray warning line cannot masquerade as one.
                if fields.first.map(normalize) == rowLabelHeader, fields.count > 1 {
                    columns = fields.map(Column.init(header:))
                }
                continue
            }

            // Everything after the header is either a row or noise. Only rows
            // are counted, so a trailing summary line cannot inflate the total.
            let label = fields.first.map(normalize) ?? ""
            guard label.hasPrefix(rowPrefix) else { continue }
            dataLineCount += 1

            guard fields.count == columns.count else {
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber,
                    text: line,
                    reason: .wrongFieldCount(expected: columns.count, found: fields.count)
                ))
                continue
            }

            let indexed = Row(columns: columns, fields: fields)

            let index = GPUFieldValue.integer(String(label.dropFirst(rowPrefix.count)))
            let uuid = uniqueID(from: indexed)
            if index == nil, uuid == nil {
                // Neither a position nor an identity: nothing can be done with
                // this row, and guessing would create a phantom GPU.
                skipped.append(SkippedGPULine(
                    lineNumber: lineNumber, text: line, reason: .unusableIndex
                ))
                continue
            }

            let headline = headlineTemperature(from: indexed)
            let sample = GPUSample(
                index: index,
                uuid: uuid,
                model: modelName(from: indexed),
                temperatureCelsius: headline?.value,
                temperatureSensor: headline?.sensor,
                utilizationPercent: utilization(from: indexed),
                memoryUsedMiB: memoryMiB(from: indexed, used: true),
                memoryTotalMiB: memoryMiB(from: indexed, used: false),
                powerDrawWatts: powerDraw(from: indexed),
                powerLimitWatts: powerLimit(from: indexed),
                memoryTemperatureCelsius: memoryTemperature(from: indexed),
                memoryUtilizationPercent: memoryUtilization(from: indexed)
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

    // MARK: - Column matching

    /// One header cell, reduced once to the form the matchers compare against.
    private struct Column {
        let normalized: String

        init(header: String) {
            self.normalized = ROCmSMIParser.normalize(header)
        }
    }

    /// A parsed data row, keeping the header order.
    ///
    /// Deliberately an ordered pair rather than a dictionary: matching walks the
    /// columns in the order the host printed them, so a given output always
    /// yields the same sample. Dictionary iteration order is not stable across
    /// runs, and a monitor whose readings depend on it would be unpredictable in
    /// exactly the way this app is built to avoid.
    private struct Row {
        let columns: [Column]
        let fields: [String]

        /// The first value, in header order, whose column name satisfies `test`.
        func value(matching test: (String) -> Bool) -> String? {
            for (column, field) in zip(columns, fields) where test(column.normalized) {
                return field
            }
            return nil
        }
    }

    /// Lowercase, trimmed, with runs of whitespace collapsed. Used on both the
    /// header and the literals below so the two are always compared in the same
    /// shape.
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    // MARK: - Individual metrics

    private enum TemperatureSensor: String {
        case edge
        /// The hotspot. Runs hotter than the edge sensor by design, which is why
        /// it is not used for the headline temperature.
        case junction
        case memory
    }

    /// The raw cell for one sensor.
    ///
    /// Matched as "contains the sensor word" rather than on a bracketed form
    /// like `(edge)`: rocm-smi spells the header `Temperature (Sensor edge)
    /// (C)`, so the sensor word is not parenthesised on its own. Requiring
    /// "temperature" as well keeps the memory sensor from colliding with any
    /// other column that happens to carry the word "memory".
    private static func rawTemperature(from row: Row, sensor: TemperatureSensor) -> String? {
        row.value { name in
            name.contains("temperature") && name.contains(sensor.rawValue)
        }
    }

    /// The headline temperature, and the sensor it came from.
    ///
    /// Edge is preferred, because it is the sensor that corresponds to
    /// nvidia-smi's `temperature.gpu`. Junction is the fallback, and it exists
    /// because it has to: AMD's Instinct cards report **no edge sensor at all**
    /// — verified against an 8× MI300X host, whose only temperature columns are
    /// junction and memory. Insisting on edge there left every card on a
    /// perfectly healthy host flagged as reporting no temperature, which is the
    /// false alarm this app exists to avoid.
    ///
    /// The sensor is returned rather than discarded because the two scales are
    /// not the same: junction runs hotter for the same card, so quietly
    /// substituting it would move an operator's threshold onto a different
    /// number without saying so.
    private static func headlineTemperature(
        from row: Row
    ) -> (value: Double, sensor: GPUTemperatureSensor)? {
        if let value = GPUFieldValue.double(rawTemperature(from: row, sensor: .edge) ?? "") {
            return (value, .core)
        }
        if let value = GPUFieldValue.double(rawTemperature(from: row, sensor: .junction) ?? "") {
            return (value, .junction)
        }
        return nil
    }

    private static func memoryTemperature(from row: Row) -> Double? {
        GPUFieldValue.double(rawTemperature(from: row, sensor: .memory) ?? "")
    }

    private static func utilization(from row: Row) -> Double? {
        let raw = row.value { name in
            name.contains("gpu use")
        }
        return GPUFieldValue.double(raw ?? "")
    }

    private static func memoryUtilization(from row: Row) -> Double? {
        let raw = row.value { name in
            name.contains("vram") && name.contains("allocated")
        }
        return GPUFieldValue.double(raw ?? "")
    }

    /// VRAM, converted from the bytes rocm-smi reports into the MiB the rest of
    /// the app speaks.
    private static func memoryMiB(from row: Row, used: Bool) -> Double? {
        let raw = row.value { name in
            if used {
                return name.contains("vram") && name.contains("total used memory")
            }
            return name.contains("vram") && name.contains("total memory")
                && !name.contains("used")
        }
        guard let bytes = GPUFieldValue.double(raw ?? ""), bytes >= 0 else { return nil }
        return bytes / (1024 * 1024)
    }

    private static func powerDraw(from row: Row) -> Double? {
        let raw = row.value { name in
            name.contains("graphics package power") && !name.contains("max")
        }
        return GPUFieldValue.double(raw ?? "")
    }

    private static func powerLimit(from row: Row) -> Double? {
        let raw = row.value { name in
            name.contains("graphics package power") && name.contains("max")
        }
        return GPUFieldValue.double(raw ?? "")
    }

    /// `Card Series` is the human-readable name. `Card Model` is a device id on
    /// most ROCm cards and is only used when no series was reported.
    private static func modelName(from row: Row) -> String? {
        if let series = row.value(matching: { $0 == "card series" }),
           let name = GPUFieldValue.string(series) {
            return name
        }
        return row.value(matching: { $0 == "card model" })
            .flatMap(GPUFieldValue.string)
    }

    // MARK: - Identity

    /// ROCm's identity is a 64-bit GUID rather than NVIDIA's `GPU-…` string.
    ///
    /// Two quirks are handled here because both would otherwise be read as a
    /// finding about the hardware:
    ///
    /// - Some cards report `0` for every GPU. A zero GUID is not an identity, so
    ///   it becomes `nil` — the GPU is then reported as unidentifiable, not as
    ///   several cards sharing one identity.
    /// - The same value across cards is caught downstream by the duplicate
    ///   check, which already exists on the NVIDIA path.
    private static func uniqueID(from row: Row) -> String? {
        guard let raw = row.value(matching: { $0.contains("unique id") }),
              let text = GPUFieldValue.string(raw) else { return nil }
        let digits = text.hasPrefix("0x") || text.hasPrefix("0X")
            ? String(text.dropFirst(2))
            : text
        guard let value = UInt64(digits, radix: 16) ?? UInt64(digits), value != 0 else {
            return nil
        }
        return text
    }
}
