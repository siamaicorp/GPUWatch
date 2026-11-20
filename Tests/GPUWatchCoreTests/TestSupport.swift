import Foundation
@testable import GPUWatchCore

/// Scripted stand-in for `/usr/bin/ssh`.
///
/// Records every invocation so tests can assert on how many ssh processes would
/// have been spawned, and can hold a response until the test releases it — which
/// is what makes "a result arriving after the host was edited" testable.
final class FakeSSHRunner: SSHCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let arguments: [String]
        let remoteCommand: String
    }

    enum Response {
        /// A normal ssh run: exit status, stdout, stderr.
        case result(terminationStatus: Int32, stdout: String, stderr: String)
        /// A run that never returns on its own; the test releases it.
        case suspended(stdout: String, onRelease: (@Sendable () -> Void)? = nil)
        /// A run that takes a measurable amount of wall time, for exercising
        /// the concurrency limiter.
        case delayed(terminationStatus: Int32, stdout: String, stderr: String, seconds: Double)
        /// Launch failure.
        case failure(Error)
    }

    private let lock = NSLock()
    private var queue: [Response] = []
    private var defaultResponse: Response
    private var invocations: [Invocation] = []
    private var released: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    /// Waiters keyed by the invocation count they are waiting to exceed, so a
    /// call that has already started cannot be missed.
    private var startedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var concurrent = 0
    private var peakConcurrent = 0

    init(defaultResponse: Response = .result(terminationStatus: 0, stdout: "", stderr: "")) {
        self.defaultResponse = defaultResponse
    }

    func enqueue(_ response: Response) {
        lock.lock()
        queue.append(response)
        lock.unlock()
    }

    func setDefault(_ response: Response) {
        lock.lock()
        defaultResponse = response
        lock.unlock()
    }

    var recordedInvocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    var invocationCount: Int { recordedInvocations.count }

    /// Highest number of `run` calls that were ever in flight at once.
    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakConcurrent
    }

    /// Suspends until `run` has been entered more than `count` times.
    ///
    /// Threshold-based rather than "next", because the call being waited for may
    /// already have started by the time the waiter registers.
    func waitForInvocations(over count: Int) async {
        while true {
            lock.lock()
            let ready = invocations.count > count
            lock.unlock()
            if ready { return }
            await withCheckedContinuation { continuation in
                lock.lock()
                if invocations.count > count {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                startedWaiters.append((threshold: count, continuation: continuation))
                lock.unlock()
            }
        }
    }

    /// Lets every suspended call finish.
    func releaseAll() {
        lock.lock()
        isReleased = true
        let waiting = released
        released = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func run(
        target: SSHTarget,
        remoteCommand: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> SSHCommandResult {
        let response = beginRun(target: target, remoteCommand: remoteCommand)
        defer { endRun() }

        switch response {
        case let .result(status, stdout, stderr):
            return SSHCommandResult(
                terminationStatus: status, stdout: stdout, stderr: stderr, duration: 0.01
            )
        case let .failure(error):
            throw error
        case let .delayed(status, stdout, stderr, seconds):
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return SSHCommandResult(
                terminationStatus: status, stdout: stdout, stderr: stderr, duration: seconds
            )
        case let .suspended(stdout, onRelease):
            await withCheckedContinuation { continuation in
                if !enqueueIfNotReleased(continuation) { continuation.resume() }
            }
            onRelease?()
            return SSHCommandResult(
                terminationStatus: 0, stdout: stdout, stderr: "", duration: 0.01
            )
        }
    }

    /// Synchronous, so no lock is ever taken from an async context.
    private func beginRun(target: SSHTarget, remoteCommand: String) -> Response {
        lock.lock()
        invocations.append(Invocation(
            arguments: target.probeArguments(remoteCommand: remoteCommand),
            remoteCommand: remoteCommand
        ))
        concurrent += 1
        peakConcurrent = max(peakConcurrent, concurrent)
        let response = queue.isEmpty ? defaultResponse : queue.removeFirst()
        let count = invocations.count
        var satisfied: [CheckedContinuation<Void, Never>] = []
        startedWaiters.removeAll { waiter in
            guard waiter.threshold < count else { return false }
            satisfied.append(waiter.continuation)
            return true
        }
        lock.unlock()
        for continuation in satisfied { continuation.resume() }
        return response
    }

    private func endRun() {
        lock.lock()
        concurrent -= 1
        lock.unlock()
    }

    /// Returns `false` when the run was already released and the caller should
    /// resume immediately.
    private func enqueueIfNotReleased(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return false }
        released.append(continuation)
        return true
    }

    func terminateAll() {}
}

// MARK: - Fixtures

enum Fixtures {
    /// Builds a host with a fresh UUID by default. A shared UUID would make
    /// distinct hosts collide in the coordinator's per-host bookkeeping.
    static func host(
        id: UUID = UUID(),
        name: String = "gpu-1",
        destination: String = "gpu-1.example.invalid",
        username: String? = "ops",
        port: Int? = nil,
        identityFile: String? = nil,
        expected: Int = 4,
        enabled: Bool = true,
        vendor: GPUVendor = .auto,
        temperatureThreshold: Double? = nil,
        vramThreshold: Double? = nil,
        powerThreshold: Double? = nil
    ) -> HostConfig {
        HostConfig(
            id: id,
            displayName: name,
            destination: destination,
            username: username,
            port: port,
            identityFile: identityFile,
            expectedGPUCount: expected,
            enabled: enabled,
            vendor: vendor,
            temperatureWarningThreshold: temperatureThreshold,
            vramWarningFraction: vramThreshold,
            powerWarningFraction: powerThreshold
        )
    }

    static func uuid(_ seed: Int) -> String {
        String(format: "GPU-%08x-0000-0000-0000-000000000000", seed)
    }

    /// A full `nvidia-smi` row: the seven readability fields followed by the
    /// four pressure fields, in `RemoteProbe.queryFields` order. A row with the
    /// wrong count is rejected outright by the parser, so this has to stay in
    /// step with that list.
    static func csvRow(
        index: Int,
        uuid: String,
        name: String = "NVIDIA H100 80GB HBM3",
        temperature: String = "60",
        utilization: String = "10",
        memoryUsed: String = "1024",
        memoryTotal: String = "81920",
        powerDraw: String = "250",
        powerLimit: String = "700",
        memoryTemperature: String = "68",
        memoryUtilization: String = "35"
    ) -> String {
        [
            "\(index)", uuid, name, temperature, utilization, memoryUsed, memoryTotal,
            powerDraw, powerLimit, memoryTemperature, memoryUtilization
        ].joined(separator: ", ")
    }

    /// Wraps `nvidia-smi` rows in the envelope the remote script produces.
    static func envelope(
        rows: [String],
        exitStatus: Int = 0,
        nvidiaSMIPresent: Bool = true,
        stderrText: String? = nil
    ) -> String {
        var lines = [RemoteProbe.beginMarker]
        if nvidiaSMIPresent {
            lines.append(RemoteProbe.smiPresentMarker)
            lines.append(RemoteProbe.outBeginMarker)
            lines.append(contentsOf: rows)
            if let stderrText { lines.append(stderrText) }
            lines.append(RemoteProbe.outEndMarker)
            lines.append("\(RemoteProbe.returnCodePrefix)\(exitStatus)")
        } else {
            lines.append(RemoteProbe.smiAbsentMarker)
        }
        lines.append(RemoteProbe.endMarker)
        return lines.joined(separator: "\n")
    }

    // MARK: - ROCm

    /// A `rocm-smi --csv` header.
    ///
    /// The names are those rocm-smi builds its output from (it concatenates the
    /// metric label with its unit, e.g. `Temperature (Sensor edge) (C)`), and
    /// they are what the parser matches on. The parser reads by name, so the
    /// order here is only the order a particular host happened to print.
    static let rocmHeaders = [
        "device",
        "Card Series",
        "Unique ID",
        "GPU use (%)",
        "GPU Memory Allocated (VRAM%)",
        "Temperature (Sensor edge) (C)",
        "Temperature (Sensor junction) (C)",
        "Temperature (Sensor memory) (C)",
        "VRAM Total Memory (B)",
        "VRAM Total Used Memory (B)",
        "Average Graphics Package Power (W)",
        "Max Graphics Package Power (W)"
    ]

    /// A ROCm unique id: a 64-bit GUID as hexadecimal, which is what
    /// `--showuniqueid` reports.
    static func rocmID(_ seed: Int) -> String {
        String(format: "0x%016x", 0x1000_0000_0000 + seed)
    }

    /// One `rocm-smi --csv` data row.
    ///
    /// Rendered from a header→value mapping rather than a positional list, so
    /// the same values can be written in any column order a host might choose.
    /// Note the units: ROCm reports VRAM in bytes and temperatures as decimals
    /// with one place, both unlike nvidia-smi.
    static func rocmRow(
        index: Int,
        id: String,
        series: String = "AMD Radeon RX 7900 XTX",
        utilization: String = "7",
        memoryUtilization: String = "12",
        temperature: String = "42.0",
        junctionTemperature: String = "55.0",
        memoryTemperature: String = "48.0",
        memoryTotalBytes: String = "25753026560",
        memoryUsedBytes: String = "1234567890",
        powerDraw: String = "180.0",
        powerLimit: String = "300.0",
        order: [String] = rocmHeaders
    ) -> String {
        let values: [String: String] = [
            "device": "card\(index)",
            "Card Series": series,
            "Unique ID": id,
            "GPU use (%)": utilization,
            "GPU Memory Allocated (VRAM%)": memoryUtilization,
            "Temperature (Sensor edge) (C)": temperature,
            "Temperature (Sensor junction) (C)": junctionTemperature,
            "Temperature (Sensor memory) (C)": memoryTemperature,
            "VRAM Total Memory (B)": memoryTotalBytes,
            "VRAM Total Used Memory (B)": memoryUsedBytes,
            "Average Graphics Package Power (W)": powerDraw,
            "Max Graphics Package Power (W)": powerLimit
        ]
        return order.map { values[$0] ?? "N/A" }.joined(separator: ",")
    }

    /// Output captured verbatim from a real host: 8× AMD Instinct MI300X,
    /// ROCm 7.8.0 (`rocm-smi` 4.0.0), with the command the app actually sends.
    ///
    /// Kept verbatim, warning line and all, because it is the only fixture here
    /// that was not written by hand. It is what caught the thing the synthetic
    /// fixtures could not: these cards report **no edge sensor**, so a parser
    /// that insisted on edge marked all eight cards as reporting no temperature
    /// on a perfectly healthy machine.
    static let realMI300XOutput = """
    WARNING: AMD GPU device(s) is/are in a low-power state. Check power control/runtime_status

    device,Unique ID,Temperature (Sensor junction) (C),Temperature (Sensor memory) (C),Max Graphics Package Power (W),Current Socket Graphics Package Power (W),GPU use (%),GPU Memory Allocated (VRAM%),GPU Memory Read/Write Activity (%),Memory Activity,VRAM Total Memory (B),VRAM Total Used Memory (B),Card Series,Card Model,Card Vendor,Card SKU,Subsystem ID,Device Rev,Node ID,GUID,GFX Version
    card0,0xf867a5aff611c0cc,50.0,43.0,750.0,162.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,2,55354,gfx942
    card1,0x3bc9200b9aa38d58,45.0,39.0,750.0,159.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,3,41632,gfx942
    card2,0x8c8539323ec8d753,46.0,41.0,750.0,160.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,4,47045,gfx942
    card3,0x16139b95daf44483,51.0,47.0,750.0,166.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,5,60169,gfx942
    card4,0x117755ab77ed4aa7,50.0,45.0,750.0,166.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,6,56024,gfx942
    card5,0xdfe53f69871f1ee1,47.0,40.0,750.0,161.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,7,705,gfx942
    card6,0x1a496a08099f3f06,50.0,46.0,750.0,162.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,8,59108,gfx942
    card7,0x6b67cb0bdc5501e5,46.0,39.0,750.0,145.0,0,0,0,N/A,206141652992,297771008,AMD Instinct MI300X,0x74a1,Advanced Micro Devices Inc. [AMD/ATI],M3000100,0x74a1,0x00,9,10985,gfx942
    """

    /// A complete ROCm CSV block: header then rows.
    static func rocmOutput(headers: [String] = rocmHeaders, rows: [String]) -> String {
        ([headers.joined(separator: ",")] + rows).joined(separator: "\n")
    }

    /// Wraps ROCm output in the envelope the AMD remote script produces, which
    /// differs from the NVIDIA one only in the vendor marker it carries.
    static func amdEnvelope(
        rows: [String],
        exitStatus: Int = 0,
        stderrText: String? = nil
    ) -> String {
        var lines = [
            RemoteProbe.beginMarker,
            "\(RemoteProbe.vendorPrefix)\(RemoteProbe.vendorAMDSuffix)",
            RemoteProbe.outBeginMarker
        ]
        lines.append(contentsOf: rows)
        if let stderrText { lines.append(stderrText) }
        lines.append(RemoteProbe.outEndMarker)
        lines.append("\(RemoteProbe.returnCodePrefix)\(exitStatus)")
        lines.append(RemoteProbe.endMarker)
        return lines.joined(separator: "\n")
    }

    static func tempDirectory(_ label: String = "gpuwatch-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
