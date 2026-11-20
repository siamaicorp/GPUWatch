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

    static func tempDirectory(_ label: String = "gpuwatch-tests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
