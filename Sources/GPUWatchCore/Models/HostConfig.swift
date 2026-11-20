import Foundation

/// User-authored description of one GPU server reachable over SSH.
///
/// This type holds no secrets. It never carries a password, a passphrase or the
/// contents of a private key; authentication is delegated entirely to the
/// system `ssh` client and whatever agent / key material the user already has.
public struct HostConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    /// SSH alias from `~/.ssh/config`, a hostname, or an IP literal.
    public var destination: String
    public var username: String?
    public var port: Int?
    /// Absolute path to an identity file. The file is passed to ssh by path;
    /// its contents are never read by this application.
    public var identityFile: String?
    /// How many physical GPUs the operator expects to be present.
    public var expectedGPUCount: Int
    public var enabled: Bool
    /// Which GPU tooling to read this host with.
    ///
    /// Defaults to `.auto`, which is the right answer for almost every host and
    /// the only one an existing configuration carries. It is settable because
    /// auto-detection can be wrong on a machine that still has the previous
    /// vendor's tool on its PATH.
    public var vendor: GPUVendor
    /// Pressure thresholds. All optional, all operator-declared.
    ///
    /// These describe how hard the machine is being worked, not whether it is
    /// healthy: a card sitting at its power limit during a training run is doing
    /// exactly what it should. They exist so a busy card can be *told apart*
    /// from an idle one at a glance, never so a busy card can be called broken.
    ///
    /// Each is left unset by default, because a threshold that is not tied to
    /// what the operator expects of this host is a guess: 80% VRAM means
    /// opposite things on a shared inference box and on a workstation that
    /// should be idle.

    /// GPU temperature in degrees Celsius at or above which a readable GPU is
    /// flagged. `nil` disables it.
    public var temperatureWarningThreshold: Double?
    /// Fraction of VRAM in use, 0–1, at or above which a readable GPU is
    /// flagged. `nil` disables it.
    public var vramWarningFraction: Double?
    /// Fraction of the power limit being drawn, 0–1, at or above which a
    /// readable GPU is flagged. `nil` disables it.
    public var powerWarningFraction: Double?

    public init(
        id: UUID = UUID(),
        displayName: String,
        destination: String,
        username: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        expectedGPUCount: Int = 0,
        enabled: Bool = true,
        vendor: GPUVendor = .auto,
        temperatureWarningThreshold: Double? = nil,
        vramWarningFraction: Double? = nil,
        powerWarningFraction: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.destination = destination
        self.username = username
        self.port = port
        self.identityFile = identityFile
        self.expectedGPUCount = expectedGPUCount
        self.enabled = enabled
        self.vendor = vendor
        self.temperatureWarningThreshold = temperatureWarningThreshold
        self.vramWarningFraction = vramWarningFraction
        self.powerWarningFraction = powerWarningFraction
    }

    /// Decoded by hand for one reason: `vendor` was added after the first
    /// release, and Swift's synthesised decoder does **not** fall back to a
    /// property's default value. A synthesised `init(from:)` would therefore
    /// throw on every `config.json` written before this field existed, and the
    /// store's response to an undecodable file is to quarantine it — which
    /// would look to the operator like their host list had been lost.
    ///
    /// So absence means `.auto` here, and only absence: a value we do not
    /// recognise still fails, because silently reinterpreting a vendor we do
    /// not understand is the kind of guess this app avoids.
    ///
    /// Every other field keeps exactly the strictness it had before. Loosening
    /// them at the same time would quietly turn a truncated file into a host
    /// list with invented defaults, which is a worse failure than saying so.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.destination = try container.decode(String.self, forKey: .destination)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.port = try container.decodeIfPresent(Int.self, forKey: .port)
        self.identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        self.expectedGPUCount = try container.decode(Int.self, forKey: .expectedGPUCount)
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.vendor = try container.decodeIfPresent(GPUVendor.self, forKey: .vendor) ?? .auto
        self.temperatureWarningThreshold = try container.decodeIfPresent(
            Double.self, forKey: .temperatureWarningThreshold
        )
        self.vramWarningFraction = try container.decodeIfPresent(
            Double.self, forKey: .vramWarningFraction
        )
        self.powerWarningFraction = try container.decodeIfPresent(
            Double.self, forKey: .powerWarningFraction
        )
    }

    /// Whether this host has asked to be told about pressure at all.
    public var hasPressureThresholds: Bool {
        temperatureWarningThreshold != nil
            || vramWarningFraction != nil
            || powerWarningFraction != nil
    }

    /// Name shown in the UI. Falls back to the SSH destination so a row is
    /// never blank.
    public var effectiveName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? destination : trimmed
    }

    /// Destination rendered for humans, including the username when set.
    public var userFacingTarget: String {
        guard let username, !username.isEmpty else { return destination }
        return "\(username)@\(destination)"
    }
}
