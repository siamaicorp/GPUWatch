import Foundation

/// Raw outcome of running one child process to completion.
///
/// A non-zero exit status is a *result*, not an error: callers need to inspect
/// it to tell an ssh transport failure apart from a remote command failure.
public struct SSHCommandResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let stdout: String
    public let stderr: String
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let timedOut: Bool
    public let cancelled: Bool
    public let duration: TimeInterval

    public init(
        terminationStatus: Int32,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        timedOut: Bool = false,
        cancelled: Bool = false,
        duration: TimeInterval = 0
    ) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.duration = duration
    }

    /// ssh reserves 255 for its own failures.
    public var isSSHTransportFailure: Bool { terminationStatus == 255 }
    /// ssh clearly worked: any exit code other than its own sentinel means the
    /// remote program ran and returned a status.
    public var didReachRemote: Bool { terminationStatus != 255 }
}

/// Seam for the polling layer so host checks can be driven by fixtures in tests
/// without spawning anything.
public protocol SSHCommandRunning: Sendable {
    func run(
        target: SSHTarget,
        remoteCommand: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> SSHCommandResult

    /// Terminates every child still running. Called on quit.
    func terminateAll()
}

public extension SSHCommandRunning {
    func run(target: SSHTarget, remoteCommand: String) async throws -> SSHCommandResult {
        try await run(
            target: target,
            remoteCommand: remoteCommand,
            timeout: CheckTimeoutBudget.wholeCheckSeconds,
            maxOutputBytes: CheckTimeoutBudget.maxOutputBytes
        )
    }
}

/// Errors that prevent a process from being started at all, as distinct from a
/// process that started and failed.
public enum SSHProcessError: Error, LocalizedError, Sendable {
    case launchFailed(String)
    case executableMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(reason): return "Could not start ssh: \(reason)"
        case let .executableMissing(path): return "\(path) is not available on this Mac"
        }
    }
}

/// Runs `/usr/bin/ssh` with an argument vector and no shell.
///
/// Guarantees relied on by callers:
/// - No local shell is ever involved; the remote command is one argv element.
/// - stdout and stderr are drained concurrently so the child can never block on
///   a full pipe.
/// - A whole-call deadline always ends in teardown: SIGTERM, then SIGKILL.
/// - Buffered output is capped; bytes past the cap are read and discarded
///   rather than left in the pipe, which would deadlock the child.
public final class SSHProcessRunner: SSHCommandRunning, @unchecked Sendable {
    private let executableURL: URL
    private let registry = ProcessRegistry()

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.executableURL = executableURL
    }

    public func terminateAll() {
        registry.terminateAll()
    }

    public func run(
        target: SSHTarget,
        remoteCommand: String,
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> SSHCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SSHProcessError.executableMissing(executableURL.path)
        }

        let session = ProbeSession(
            executableURL: executableURL,
            arguments: target.probeArguments(remoteCommand: remoteCommand),
            maxOutputBytes: maxOutputBytes,
            registry: registry
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(
                    timeout: timeout,
                    continuation: continuation,
                    registry: registry
                )
            }
        } onCancel: {
            session.terminate()
        }
    }
}

// MARK: - One probe run

/// Owns everything for a single ssh invocation, so the completion path is a
/// method on a reference type rather than a closure that captures mutable
/// locals across threads.
private final class ProbeSession: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutBuffer: CappedBuffer
    private let stderrBuffer: CappedBuffer
    private let registry: ProcessRegistry
    private let started = Date()

    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<SSHCommandResult, Error>?
    private var timer: DispatchSourceTimer?

    init(
        executableURL: URL,
        arguments: [String],
        maxOutputBytes: Int,
        registry: ProcessRegistry
    ) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // ssh must never read from our terminal. A null device is safer than a
        // closed descriptor because ssh sees a valid, immediately-EOF stream.
        process.standardInput = FileHandle.nullDevice
        self.stdoutBuffer = CappedBuffer(limit: maxOutputBytes)
        self.stderrBuffer = CappedBuffer(limit: maxOutputBytes)
        self.registry = registry
    }

    func start(
        timeout: TimeInterval,
        continuation: CheckedContinuation<SSHCommandResult, Error>,
        registry: ProcessRegistry
    ) {
        self.continuation = continuation

        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutBuffer] handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrBuffer] handle in
            stderrBuffer.append(handle.availableData)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let status = proc.terminationStatus
            self.finish(terminationStatus: status)
        }

        do {
            try process.run()
        } catch {
            fail(with: SSHProcessError.launchFailed(error.localizedDescription))
            return
        }
        registry.add(process)

        if Task.isCancelled {
            // Never hand back a running child to a caller that has gone away.
            terminate()
            finish(terminationStatus: -1, cancelled: true)
            return
        }

        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.process.terminate()
            let pid = self.process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                guard self.process.isRunning, pid > 0 else { return }
                kill(pid, SIGKILL)
            }
            self.finish(terminationStatus: -1, timedOut: true)
        }
        source.resume()
        timer = source
    }

    func terminate() {
        registry.terminate(process)
        finish(terminationStatus: -1, cancelled: true)
    }

    private func finish(
        terminationStatus: Int32,
        timedOut: Bool = false,
        cancelled: Bool = false
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        continuation = nil
        let source = timer
        timer = nil
        lock.unlock()

        source?.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain whatever landed between the last callback and exit.
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.availableData)
        stderrBuffer.append(stderrPipe.fileHandleForReading.availableData)
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        registry.remove(process)

        pending?.resume(returning: SSHCommandResult(
            terminationStatus: terminationStatus,
            stdout: stdoutBuffer.text,
            stderr: stderrBuffer.text,
            stdoutTruncated: stdoutBuffer.truncated,
            stderrTruncated: stderrBuffer.truncated,
            timedOut: timedOut,
            cancelled: cancelled,
            duration: Date().timeIntervalSince(started)
        ))
    }

    private func fail(with error: Error) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        registry.remove(process)
        pending?.resume(throwing: error)
    }
}

// MARK: - Supporting types

/// Reads bytes up to a cap, then keeps draining without retaining. Draining
/// matters: leaving a pipe full would deadlock the child.
private final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var didTruncate = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else {
            didTruncate = true
            return
        }
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            didTruncate = true
        } else {
            data.append(chunk)
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy decoding on purpose: a partially-read multi-byte sequence at the
        // truncation boundary must not discard everything else.
        return String(decoding: data, as: UTF8.self)
    }

    var truncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTruncate
    }
}

/// Tracks in-flight children so the app can end them on quit.
private final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []

    func add(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    func terminateAll() {
        lock.lock()
        let snapshot = processes
        lock.unlock()
        for process in snapshot {
            terminate(process)
        }
    }
}
