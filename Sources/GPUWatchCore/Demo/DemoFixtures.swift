import Foundation

/// A self-contained fleet for trying the app without a server.
///
/// Two properties keep Demo Mode honest:
///
/// - The reports are produced by the **real** evaluator, fed synthetic probe
///   results. Nothing here reimplements status logic, so a demo that looks right
///   is evidence the production path works.
/// - Every destination ends in `.demo.invalid`, so even a bug that tried to
///   reach the network could not resolve anything.
///
/// The fleet is declarative: each entry names a host and the situation it is in,
/// and the builder turns that into the same probe result the poller would have
/// produced. Widening the fleet for a visual check is then a matter of adding
/// entries, not of writing new mock logic.
public enum DemoFixtures {

    public enum Behavior: Equatable, Sendable {
        /// Every registered GPU present and readable.
        case healthy
        /// `count` baseline GPUs absent. When `replacement` is set, a card the
        /// baseline has never seen takes one of the empty slots.
        case missing(count: Int, replacement: Bool)
        /// SSH fails now; a successful reading three minutes earlier is carried
        /// forward as last-known data.
        case unreachable
        /// SSH works, but neither supported GPU tool is installed.
        case noGPUTool
        /// Read twenty minutes ago, then demoted to stale, as after a wake.
        case stale
        /// All GPUs readable, with one above the host's warning threshold.
        case hotGPU
    }

    public struct Entry: Sendable {
        public var config: HostConfig
        /// UUIDs to register. `nil` leaves the host without a baseline, which is
        /// the state a freshly added host is in.
        public var baseline: [String]?
        public var behavior: Behavior

        public init(config: HostConfig, baseline: [String]?, behavior: Behavior) {
            self.config = config
            self.baseline = baseline
            self.behavior = behavior
        }
    }

    public static var entries: [Entry] {
        [
            Entry(
                config: HostConfig(
                    id: id(1), displayName: "5090-1",
                    destination: "5090-1.demo.invalid",
                    username: "ops", expectedGPUCount: 4,
                    enabled: true, temperatureWarningThreshold: 85
                ),
                baseline: uuids(seed: 1, count: 4),
                behavior: .healthy
            ),
            Entry(
                config: HostConfig(
                    id: id(2), displayName: "5090-2",
                    destination: "5090-2.demo.invalid",
                    username: "ops", expectedGPUCount: 4,
                    enabled: true, temperatureWarningThreshold: 85
                ),
                baseline: uuids(seed: 10, count: 4),
                // A card failed and a different one was fitted in its place: one
                // baseline UUID gone, one UUID the baseline has never seen.
                behavior: .missing(count: 1, replacement: true)
            ),
            Entry(
                config: HostConfig(
                    id: id(3), displayName: "H200-01",
                    destination: "h200-01.demo.invalid",
                    username: "ml", port: 2222, expectedGPUCount: 8,
                    enabled: true, temperatureWarningThreshold: 88
                ),
                baseline: nil,
                behavior: .healthy
            ),
            Entry(
                config: HostConfig(
                    id: id(4), displayName: "H100-02",
                    destination: "h100-02.demo.invalid",
                    username: "ml", expectedGPUCount: 8,
                    enabled: true, temperatureWarningThreshold: 88
                ),
                baseline: uuids(seed: 40, count: 8),
                behavior: .unreachable
            ),
            Entry(
                config: HostConfig(
                    id: id(5), displayName: "A100-03",
                    destination: "a100-03.demo.invalid",
                    username: "ops", expectedGPUCount: 4,
                    enabled: true, temperatureWarningThreshold: nil
                ),
                baseline: uuids(seed: 50, count: 4),
                behavior: .noGPUTool
            ),
            Entry(
                config: HostConfig(
                    id: id(6), displayName: "L40S-04",
                    destination: "l40s-04.demo.invalid",
                    username: "ops", expectedGPUCount: 2,
                    enabled: true, temperatureWarningThreshold: 80
                ),
                baseline: uuids(seed: 60, count: 2),
                behavior: .stale
            ),
            Entry(
                config: HostConfig(
                    id: id(7), displayName: "H100-05-hot-rack",
                    destination: "h100-05.demo.invalid",
                    username: "ml", expectedGPUCount: 3,
                    // One GPU is hotter than the rest, so exactly one dot goes
                    // amber and the warning state is easy to see.
                    enabled: true, temperatureWarningThreshold: 80
                ),
                baseline: uuids(seed: 70, count: 3),
                behavior: .hotGPU
            ),
            Entry(
                config: HostConfig(
                    id: id(8), displayName: "MI300X-06",
                    destination: "mi300x-06.demo.invalid",
                    username: "siamai", expectedGPUCount: 8,
                    enabled: true, vendor: .amd,
                    temperatureWarningThreshold: 90
                ),
                // No baseline, the state a newly added host starts in. It also
                // keeps the demo honest about AMD identity: these cards report a
                // GUID, so a baseline here would be a list of invented ones.
                baseline: nil,
                behavior: .healthy
            )
        ]
    }

    public static var hosts: [HostConfig] { entries.map(\.config) }

    /// Baselines for the entries that register one.
    public static func baselines(registeredAt: Date) -> BaselineFile {
        var file = BaselineFile()
        for entry in entries {
            guard let uuids = entry.baseline else { continue }
            file.baselines[entry.config.id.uuidString] = HostBaseline(
                hostID: entry.config.id,
                gpuUUIDs: uuids,
                expectedCount: max(entry.config.expectedGPUCount, uuids.count),
                registeredAt: registeredAt
            )
        }
        return file
    }

    public static func reports(
        now: Date,
        settings: PollSettings = PollSettings(),
        evaluator: GPUStateEvaluator = GPUStateEvaluator()
    ) -> [HostReport] {
        reports(for: entries, now: now, settings: settings, evaluator: evaluator)
    }

    /// Builds reports for an arbitrary entry list, as the app would after a poll.
    public static func reports(
        for entries: [Entry],
        now: Date,
        settings: PollSettings = PollSettings(),
        evaluator: GPUStateEvaluator = GPUStateEvaluator()
    ) -> [HostReport] {
        entries.map { entry in
            build(entry, now: now, settings: settings, evaluator: evaluator)
        }
    }

    // MARK: - Filler entries

    /// Extra healthy hosts, for checking how a large fleet lays out and scrolls.
    public static func fillerEntries(
        count: Int,
        expectedGPUs: Int,
        namePrefix: String = "filler"
    ) -> [Entry] {
        (0..<count).map { index in
            let seed = 1000 + index * 10
            return Entry(
                config: HostConfig(
                    displayName: "\(namePrefix)-\(String(format: "%02d", index + 1))",
                    destination: "\(namePrefix)-\(index + 1).demo.invalid",
                    username: "ops",
                    expectedGPUCount: expectedGPUs,
                    enabled: true,
                    temperatureWarningThreshold: 80
                ),
                baseline: uuids(seed: seed, count: expectedGPUs),
                behavior: .healthy
            )
        }
    }

    // MARK: - Building

    private static func build(
        _ entry: Entry,
        now: Date,
        settings: PollSettings,
        evaluator: GPUStateEvaluator
    ) -> HostReport {
        let host = entry.config
        let baseline = entry.baseline.map {
            HostBaseline(
                hostID: host.id,
                gpuUUIDs: $0,
                expectedCount: max(host.expectedGPUCount, $0.count),
                registeredAt: now.addingTimeInterval(-86_400)
            )
        }
        let slotCount = max(host.expectedGPUCount, entry.baseline?.count ?? 0)

        switch entry.behavior {
        case .healthy, .hotGPU:
            var rows = (0..<slotCount).map { offset in
                GPUCSVRow(
                    index: offset,
                    uuid: entry.baseline?[safe: offset] ?? uuidText(seed: 9000 + offset),
                    name: model(for: host),
                    temperature: 60 + Double((offset * 3) % 8),
                    utilization: Double((offset * 17) % 90),
                    memoryUsed: Double(1024 + offset * 2048),
                    memoryTotal: memoryTotal(for: host)
                )
            }
            if case .hotGPU = entry.behavior, !rows.isEmpty {
                let target = rows.count / 2
                rows[target].temperature = (host.temperatureWarningThreshold ?? 80) + 3
            }
            return evaluate(
                host: host, baseline: baseline,
                probe: successProbe(for: host, rows: rows, at: now),
                previous: nil, evaluator: evaluator, settings: settings, now: now
            )

        case let .missing(count, replacement):
            var rows = (0..<slotCount).map { offset in
                GPUCSVRow(
                    index: offset,
                    uuid: entry.baseline?[safe: offset] ?? uuidText(seed: 9000 + offset),
                    name: model(for: host),
                    temperature: 58 + Double((offset * 2) % 6),
                    utilization: Double((offset * 11) % 70),
                    memoryUsed: Double(2048 + offset * 1024),
                    memoryTotal: memoryTotal(for: host)
                )
            }
            // Drop from the end so the surviving indices stay stable, which is
            // what makes the "missing" dot land in an obvious place.
            rows.removeLast(min(count, rows.count))
            if replacement, let uuid = entry.baseline?.last.map({ _ in uuidText(seed: 999) }) {
                rows.append(GPUCSVRow(
                    index: rows.count,
                    uuid: uuid,
                    name: model(for: host),
                    temperature: 60, utilization: 4,
                    memoryUsed: 512, memoryTotal: memoryTotal(for: host)
                ))
            }
            return evaluate(
                host: host, baseline: baseline,
                probe: successProbe(for: host, rows: rows, at: now),
                previous: nil, evaluator: evaluator, settings: settings, now: now
            )

        case .unreachable:
            let earlier = now.addingTimeInterval(-180)
            let rows = (0..<slotCount).map { offset in
                GPUCSVRow(
                    index: offset,
                    uuid: entry.baseline?[safe: offset] ?? uuidText(seed: 9100 + offset),
                    name: model(for: host),
                    temperature: 66, utilization: 20,
                    memoryUsed: 4096, memoryTotal: memoryTotal(for: host)
                )
            }
            let previous = evaluate(
                host: host, baseline: baseline,
                probe: successProbe(for: host, rows: rows, at: earlier),
                previous: nil, evaluator: evaluator, settings: settings, now: earlier
            )
            return evaluator.evaluate(
                host: host,
                baseline: baseline,
                probe: HostProbeResult(
                    ssh: .failed(
                        kind: .unreachable,
                        detail: "ssh: connect to host \(host.destination) port "
                            + "\(host.port ?? 22): Operation timed out"
                    ),
                    query: .failed(
                        reason: .transportFailure,
                        detail: "SSH session ended before the GPU query finished"
                    ),
                    attemptedAt: now,
                    sshDetail: "ssh: connect to host \(host.destination): Operation timed out"
                ),
                previous: previous,
                settings: settings,
                now: now
            )

        case .noGPUTool:
            return evaluator.evaluate(
                host: host,
                baseline: baseline,
                probe: HostProbeResult(
                    ssh: .ok,
                    query: .failed(
                        reason: .gpuToolNotFound,
                        detail: "neither nvidia-smi nor rocm-smi is on PATH"
                    ),
                    attemptedAt: now,
                    queryDetail: "no supported GPU tool found",
                    transportConfirmed: true
                ),
                previous: nil,
                settings: settings,
                now: now
            )

        case .stale:
            let earlier = now.addingTimeInterval(-1200)
            let rows = (0..<slotCount).map { offset in
                GPUCSVRow(
                    index: offset,
                    uuid: entry.baseline?[safe: offset] ?? uuidText(seed: 9200 + offset),
                    name: model(for: host),
                    temperature: 55, utilization: 6,
                    memoryUsed: 1024, memoryTotal: memoryTotal(for: host)
                )
            }
            var report = evaluate(
                host: host, baseline: baseline,
                probe: successProbe(for: host, rows: rows, at: earlier),
                previous: nil, evaluator: evaluator, settings: settings, now: earlier
            )
            report.lastSuccessfulAt = earlier
            report.lastAttemptedAt = earlier
            return report.markedStale(reason: "Not re-checked since wake")
        }
    }

    private static func evaluate(
        host: HostConfig,
        baseline: HostBaseline?,
        probe: HostProbeResult,
        previous: HostReport?,
        evaluator: GPUStateEvaluator,
        settings: PollSettings,
        now: Date
    ) -> HostReport {
        evaluator.evaluate(
            host: host,
            baseline: baseline,
            probe: probe,
            previous: previous,
            settings: settings,
            now: now
        )
    }

    private static func successProbe(
        for host: HostConfig,
        rows: [GPUCSVRow],
        at date: Date
    ) -> HostProbeResult {
        let parsed: ParsedGPUQuery
        if host.vendor == .amd {
            let output = ([rocmHeader] + rows.map(\.rocmLine)).joined(separator: "\n")
            parsed = ROCmSMIParser.parse(output)
        } else {
            let output = rows.map(\.csvLine).joined(separator: "\n")
            parsed = NVIDIAQueryParser.parse(output)
        }
        return HostProbeResult(
            ssh: .ok,
            query: .ok(samples: parsed.samples, partialWarnings: parsed.warnings),
            attemptedAt: date,
            queryDetail: "",
            transportConfirmed: true,
            queryWasComplete: true,
            parseWarnings: parsed.warnings
        )
    }

    // MARK: - Naming

    /// Column names taken from real `rocm-smi --csv` output on an MI300X host.
    private static let rocmHeader = [
        "device",
        "Unique ID",
        "Temperature (Sensor junction) (C)",
        "Temperature (Sensor memory) (C)",
        "Max Graphics Package Power (W)",
        "Current Socket Graphics Package Power (W)",
        "GPU use (%)",
        "GPU Memory Allocated (VRAM%)",
        "VRAM Total Memory (B)",
        "VRAM Total Used Memory (B)",
        "Card Series"
    ].joined(separator: ",")

    private static func model(for host: HostConfig) -> String {
        if host.vendor == .amd { return "AMD Instinct MI300X" }
        let name = host.effectiveName.uppercased()
        if name.contains("5090") { return "NVIDIA GeForce RTX 5090" }
        if name.contains("H200") { return "NVIDIA H200" }
        if name.contains("L40S") { return "NVIDIA L40S" }
        if name.contains("A100") { return "NVIDIA A100-SXM4-80GB" }
        return "NVIDIA H100 80GB HBM3"
    }

    private static func memoryTotal(for host: HostConfig) -> Double {
        // 192 GiB on the MI300X, which is what the captured output reports:
        // 206141652992 bytes. An AMD host showing 32 GB would be visibly wrong.
        if host.vendor == .amd { return 196_592 }
        return host.effectiveName.uppercased().contains("H200") ? 143_771 : 32_607
    }

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }

    private static func uuidText(seed: Int) -> String {
        String(format: "GPU-%08x-0000-0000-0000-00000000%04x", seed, seed)
    }

    private static func uuids(seed: Int, count: Int) -> [String] {
        (0..<count).map { uuidText(seed: seed * 100 + $0) }
    }
}

/// A synthetic `nvidia-smi` row, rendered to CSV so the demo exercises the real
/// parser rather than bypassing it.
///
/// Field order must match `RemoteProbe.queryFields` exactly, or every row is
/// rejected for having the wrong field count.
struct GPUCSVRow {
    var index: Int
    var uuid: String
    var name: String
    var temperature: Double?
    var utilization: Double?
    var memoryUsed: Double?
    var memoryTotal: Double?
    var powerDraw: Double?
    var powerLimit: Double?
    var memoryTemperature: Double?
    var memoryUtilization: Double?

    /// Fills in plausible pressure readings when the caller did not set them.
    ///
    /// The demo fleet is generated by varying utilisation, so power and memory
    /// pressure are derived from it rather than left blank — otherwise every
    /// demo card would show an empty pressure line and the feature would look
    /// broken in the demo.
    var csvLine: String {
        let limit = powerLimit ?? 575
        let draw = powerDraw ?? (95 + (utilization ?? 0) / 100 * (limit - 130))
        let memTemperature = memoryTemperature ?? temperature.map { $0 + 7 }
        let memUtilization = memoryUtilization ?? min(100, (utilization ?? 0) + 25)

        let fields: [String] = [
            String(index),
            uuid,
            name,
            Self.render(temperature),
            Self.render(utilization),
            Self.render(memoryUsed),
            Self.render(memoryTotal),
            Self.render(draw),
            Self.render(limit),
            Self.render(memTemperature),
            Self.render(memUtilization)
        ]
        return fields.joined(separator: ", ")
    }

    /// The same readings rendered as `rocm-smi` CSV.
    ///
    /// The columns and their order come from output captured from a real 8×
    /// MI300X host, including the detail that matters most: **there is no edge
    /// sensor**, so the demo shows the junction reading and the `junction` label
    /// that goes with it. A demo built on invented column names would hide
    /// exactly the thing worth seeing.
    var rocmLine: String {
        let limit = powerLimit ?? 750
        let draw = powerDraw ?? (95 + (utilization ?? 0) / 100 * (limit - 130))
        let memTemperature = memoryTemperature ?? temperature.map { $0 + 7 }
        let memUtilization = memoryUtilization ?? min(100, (utilization ?? 0) + 25)

        let fields: [String] = [
            "card\(index)",
            rocmUniqueID,
            Self.render(temperature),
            Self.render(memTemperature),
            Self.render(limit),
            Self.render(draw),
            Self.render(utilization),
            Self.render(memUtilization),
            // rocm-smi reports VRAM in bytes, where the NVIDIA path uses MiB.
            Self.renderBytes(memoryTotal),
            Self.renderBytes(memoryUsed),
            name
        ]
        return fields.joined(separator: ",")
    }

    /// A stable 64-bit id derived from the demo UUID, so a card keeps the same
    /// identity across renders the way a real GUID does. FNV-1a, purely so the
    /// demo does not need a random source.
    private var rocmUniqueID: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in uuid.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "0x%016x", hash | 0x1000_0000_0000_0000)
    }

    private static func renderBytes(_ mebibytes: Double?) -> String {
        guard let mebibytes else { return "N/A" }
        return String(Int(mebibytes * 1024 * 1024))
    }

    /// Unsupported values are emitted as `N/A`, which is exactly what the real
    /// driver does, so the demo exercises the parser's unsupported-value path.
    private static func render(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return String(Int(value))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
