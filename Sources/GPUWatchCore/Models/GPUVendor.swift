import Foundation

/// Which GPU tooling a host should be read with.
///
/// This exists because "which command do I run" is a question about the host's
/// driver stack, not about its hardware. Two hosts with the same cards can need
/// different answers, and a host can carry the leftovers of a vendor it no
/// longer uses — a machine that once had an NVIDIA card often still has
/// `nvidia-smi` on its PATH while its GPUs are AMD.
///
/// `.auto` is the default and the only value an existing configuration needs.
/// It asks the host itself: whichever tool answers with real rows is the one
/// used. The explicit cases exist for the operator who knows better than the
/// probe does, and they never guess — they only narrow what is tried.
public enum GPUVendor: String, Codable, Hashable, Sendable, CaseIterable {
    /// Detect from the host. NVIDIA is tried first, then ROCm.
    case auto
    /// Only `nvidia-smi` is run. A host that answers nothing is reported as
    /// having no readable NVIDIA driver, never silently re-routed to ROCm.
    case nvidia
    /// Only ROCm tooling is run (`rocm-smi`, later `amd-smi`).
    case amd

    public var label: String {
        switch self {
        case .auto: return "Detect automatically"
        case .nvidia: return "NVIDIA"
        case .amd: return "AMD (ROCm)"
        }
    }

    /// Shown under the picker so the choice is never a mystery.
    public var explanation: String {
        switch self {
        case .auto:
            return "Uses nvidia-smi when the host answers with it, otherwise ROCm."
        case .nvidia:
            return "Runs nvidia-smi only. A host without a working NVIDIA driver is reported as such."
        case .amd:
            return "Runs ROCm tooling only (rocm-smi)."
        }
    }

    /// The tool this vendor needs on the remote host. `nil` for `.auto`, which
    /// does not know yet — the probe decides.
    public var toolName: String? {
        switch self {
        case .auto: return nil
        case .nvidia: return "nvidia-smi"
        case .amd: return "rocm-smi"
        }
    }
}
