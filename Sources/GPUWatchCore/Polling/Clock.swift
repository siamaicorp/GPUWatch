import Foundation

/// Injected time source so staleness, debounce and cooldown logic can be tested
/// deterministically without waiting on a real clock.
public protocol Clock: Sendable {
    var now: Date { get }
    /// Suspends for the given number of seconds, honouring task cancellation.
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Test double: manual time with an immediate, cooperative sleep.
public final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    public func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        advance(seconds: seconds)
    }
}
