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
    public var temperatureCelsius: Double?
    public var utilizationPercent: Double?
    public var memoryUsedMiB: Double?
    public var memoryTotalMiB: Double?

    public init(
        index: Int? = nil,
        uuid: String? = nil,
        model: String? = nil,
        temperatureCelsius: Double? = nil,
        utilizationPercent: Double? = nil,
        memoryUsedMiB: Double? = nil,
        memoryTotalMiB: Double? = nil
    ) {
        self.index = index
        self.uuid = uuid
        self.model = model
        self.temperatureCelsius = temperatureCelsius
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
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
}
