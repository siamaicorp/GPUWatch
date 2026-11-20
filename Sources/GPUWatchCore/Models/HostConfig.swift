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
        self.temperatureWarningThreshold = temperatureWarningThreshold
        self.vramWarningFraction = vramWarningFraction
        self.powerWarningFraction = powerWarningFraction
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
