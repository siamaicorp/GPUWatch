import Foundation

/// The GPU set the operator has explicitly accepted as correct for one host.
///
/// A baseline is only ever created or replaced by an explicit user action. A
/// missing GPU never shrinks the baseline, and a successful query never
/// silently rewrites it — otherwise a failing card would erase its own
/// evidence.
public struct HostBaseline: Codable, Equatable, Sendable {
    public var hostID: UUID
    /// UUIDs recorded when the user registered the baseline, in reported order.
    public var gpuUUIDs: [String]
    /// How many physical GPUs the user expects. Set by the user, never derived
    /// from the most recent query.
    public var expectedCount: Int
    public var registeredAt: Date

    public init(hostID: UUID, gpuUUIDs: [String], expectedCount: Int, registeredAt: Date) {
        self.hostID = hostID
        self.gpuUUIDs = gpuUUIDs
        self.expectedCount = expectedCount
        self.registeredAt = registeredAt
    }
}

/// A GPU the driver reported that is not part of the registered baseline.
public struct UnexpectedGPU: Equatable, Sendable {
    public var uuid: String
    public var index: Int?
    public var model: String?
}

/// Result of comparing a successful, complete query against the baseline.
public struct BaselineComparison: Equatable, Sendable {
    /// Baseline UUIDs that were not present in a complete query result. These
    /// are the only GPUs we are entitled to call missing.
    public var missingUUIDs: [String]
    /// GPUs present in the query but absent from the baseline.
    public var unexpected: [UnexpectedGPU]
    /// `true` only when the query covered every enabled expectation, so absence
    /// of a UUID is real evidence rather than a gap in the data.
    public var queryWasComplete: Bool
    /// Baseline UUIDs confirmed present in the latest complete query.
    public var confirmedUUIDs: Set<String>

    public init(
        missingUUIDs: [String] = [],
        unexpected: [UnexpectedGPU] = [],
        queryWasComplete: Bool = false,
        confirmedUUIDs: Set<String> = []
    ) {
        self.missingUUIDs = missingUUIDs
        self.unexpected = unexpected
        self.queryWasComplete = queryWasComplete
        self.confirmedUUIDs = confirmedUUIDs
    }
}
