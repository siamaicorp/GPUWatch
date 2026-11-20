import Foundation

/// One row of `nvidia-smi --query-gpu` output.
///
/// Every metric that the driver reported as unsupported (`N/A`,
/// `[Not Supported]`, `Unknown`) is stored as `nil`. It is never coerced to
/// zero, because zero is a meaningful measurement and conflating the two would
/// hide real hardware problems.
public struct GPUSample: Equatable, Sendable {
    /// Position reported by the driver. Used for display only — indices are
    /// reassigned after a reboot, so UUID is the identity we track.
    public var index: Int?
    /// Stable identity of the physical GPU. `nil` when the driver did not
    /// report one, which makes the GPU unidentifiable rather than missing.
    public var uuid: String?
    public var model: String?

    // MARK: Readability — is the driver answering for this card at all

    public var temperatureCelsius: Double?
    public var utilizationPercent: Double?
    public var memoryUsedMiB: Double?
    public var memoryTotalMiB: Double?

    // MARK: Pressure — how hard the card is working

    /// These say nothing about whether the hardware is healthy. A card at its
    /// power limit during a training run is working as intended. They are
    /// carried separately so a busy GPU is never reported as a broken one.

    public var powerDrawWatts: Double?
    public var powerLimitWatts: Double?
    /// HBM temperature on cards that report it; `nil` on those that do not.
    public var memoryTemperatureCelsius: Double?
    /// Memory-controller utilisation, which is usually the interesting number
    /// for inference and data-movement workloads where SM utilisation is low.
    public var memoryUtilizationPercent: Double?

    public init(
        index: Int? = nil,
        uuid: String? = nil,
        model: String? = nil,
        temperatureCelsius: Double? = nil,
        utilizationPercent: Double? = nil,
        memoryUsedMiB: Double? = nil,
        memoryTotalMiB: Double? = nil,
        powerDrawWatts: Double? = nil,
        powerLimitWatts: Double? = nil,
        memoryTemperatureCelsius: Double? = nil,
        memoryUtilizationPercent: Double? = nil
    ) {
        self.index = index
        self.uuid = uuid
        self.model = model
        self.temperatureCelsius = temperatureCelsius
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.powerDrawWatts = powerDrawWatts
        self.powerLimitWatts = powerLimitWatts
        self.memoryTemperatureCelsius = memoryTemperatureCelsius
        self.memoryUtilizationPercent = memoryUtilizationPercent
    }

    /// True when the driver both identified the GPU and answered every core
    /// health question for it. A GPU can be present and still fail this if the
    /// driver returned nothing useful.
    public var hasIdentity: Bool {
        guard let uuid else { return false }
        return !uuid.isEmpty
    }

    public var hasCoreMetrics: Bool {
        temperatureCelsius != nil && utilizationPercent != nil && memoryTotalMiB != nil
    }

    /// Memory used as a fraction of total, or `nil` when either side is
    /// unsupported or the total is zero.
    public var memoryUtilizationFraction: Double? {
        guard let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0 else { return nil }
        return used / total
    }

    /// Power drawn as a fraction of the limit, or `nil` when either side is
    /// unsupported or the limit is zero.
    public var powerFraction: Double? {
        guard let draw = powerDrawWatts, let limit = powerLimitWatts, limit > 0 else { return nil }
        return draw / limit
    }

    /// Whether any pressure reading was available for this card. Used to decide
    /// whether a pressure line is worth showing at all.
    public var hasPressureReadings: Bool {
        powerDrawWatts != nil
            || powerLimitWatts != nil
            || memoryTemperatureCelsius != nil
            || memoryUtilizationPercent != nil
    }
}
