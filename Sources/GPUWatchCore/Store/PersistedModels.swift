import Foundation

/// On-disk schema version. Bumped when a stored shape changes incompatibly, so
/// a newer app never silently misreads an older file.
public enum StoreSchema {
    public static let currentVersion = 1
}

/// The user's configuration: hosts plus runtime settings.
public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var hosts: [HostConfig]
    public var settings: PollSettings

    public init(
        schemaVersion: Int = StoreSchema.currentVersion,
        hosts: [HostConfig] = [],
        settings: PollSettings = PollSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.hosts = hosts
        self.settings = settings
    }

    /// A fresh install: nothing configured, notifications off by default.
    public static let `default` = AppConfiguration()
}

/// Registered GPU baselines, keyed by host UUID.
public struct BaselineFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var baselines: [String: HostBaseline]

    public init(
        schemaVersion: Int = StoreSchema.currentVersion,
        baselines: [String: HostBaseline] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.baselines = baselines
    }

    public func baseline(for hostID: UUID) -> HostBaseline? {
        baselines[hostID.uuidString]
    }

    public mutating func setBaseline(_ baseline: HostBaseline?) {
        let key = baseline?.hostID.uuidString ?? ""
        guard let baseline else {
            return
        }
        baselines[key] = baseline
    }

    public mutating func removeBaseline(for hostID: UUID) {
        baselines.removeValue(forKey: hostID.uuidString)
    }
}

/// GPU readings from the last successful check. Used to show last-known values
/// after a restart, always labelled as such and never counted as current.
public struct GPUSnapshot: Codable, Equatable, Sendable {
    public var index: Int?
    public var uuid: String?
    public var model: String?
    public var temperatureCelsius: Double?
    /// Stored so a carried-forward AMD reading keeps saying which sensor it
    /// came from. Optional, so `last-known.json` written before this existed
    /// still loads.
    public var temperatureSensor: GPUTemperatureSensor?
    public var utilizationPercent: Double?
    public var memoryUsedMiB: Double?
    public var memoryTotalMiB: Double?

    public init(from sample: GPUSample) {
        self.index = sample.index
        self.uuid = sample.uuid
        self.model = sample.model
        self.temperatureCelsius = sample.temperatureCelsius
        self.temperatureSensor = sample.temperatureSensor
        self.utilizationPercent = sample.utilizationPercent
        self.memoryUsedMiB = sample.memoryUsedMiB
        self.memoryTotalMiB = sample.memoryTotalMiB
    }

    public init(
        index: Int? = nil,
        uuid: String? = nil,
        model: String? = nil,
        temperatureCelsius: Double? = nil,
        temperatureSensor: GPUTemperatureSensor? = nil,
        utilizationPercent: Double? = nil,
        memoryUsedMiB: Double? = nil,
        memoryTotalMiB: Double? = nil
    ) {
        self.index = index
        self.uuid = uuid
        self.model = model
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSensor = temperatureSensor
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
    }
}

public struct HostSnapshot: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var lastAttemptedAt: Date?
    public var lastSuccessfulAt: Date?
    public var gpus: [GPUSnapshot]

    public init(
        hostID: UUID,
        lastAttemptedAt: Date? = nil,
        lastSuccessfulAt: Date? = nil,
        gpus: [GPUSnapshot] = []
    ) {
        self.hostID = hostID
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.gpus = gpus
    }
}

public struct LastKnownFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var snapshots: [String: HostSnapshot]

    public init(
        schemaVersion: Int = StoreSchema.currentVersion,
        snapshots: [String: HostSnapshot] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.snapshots = snapshots
    }

    public func snapshot(for hostID: UUID) -> HostSnapshot? {
        snapshots[hostID.uuidString]
    }

    public mutating func setSnapshot(_ snapshot: HostSnapshot?) {
        guard let snapshot else { return }
        snapshots[snapshot.hostID.uuidString] = snapshot
    }

    public mutating func removeSnapshot(for hostID: UUID) {
        snapshots.removeValue(forKey: hostID.uuidString)
    }
}
