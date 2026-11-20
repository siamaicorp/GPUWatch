import Foundation

/// The fixed remote programs sent to every host, and the envelope that carries
/// their output back.
///
/// Three rules make this safe and unambiguous:
///
/// 1. Every script is a compile-time constant. No user-supplied string is ever
///    interpolated into one, so a host alias cannot become remote code.
/// 2. A script always exits 0 and always prints an end marker. That gives us
///    positive proof the SSH transport worked even when the GPU tool is absent
///    or broken — which is why a failed GPU query is never mistaken for an
///    unreachable host.
/// 3. Which tool was used is reported explicitly, never inferred from the shape
///    of the output afterwards.
public enum RemoteProbe {
    public static let beginMarker = "__GPUW_BEGIN__"
    public static let smiPresentMarker = "__GPUW_SMI_PRESENT__"
    public static let smiAbsentMarker = "__GPUW_SMI_ABSENT__"
    public static let outBeginMarker = "__GPUW_OUT_BEGIN__"
    public static let outEndMarker = "__GPUW_OUT_END__"
    public static let endMarker = "__GPUW_END__"
    public static let returnCodePrefix = "__GPUW_RC__"
    /// Reported before the output block so the app knows which parser applies
    /// without having to recognise the output's dialect.
    public static let vendorPrefix = "__GPUW_VENDOR__"
    public static let vendorNVIDIASuffix = "nvidia"
    public static let vendorAMDSuffix = "amd"

    // MARK: - NVIDIA

    /// Query fields, verified against the nvidia-smi documentation and against
    /// real hardware.
    ///
    /// `index` and `uuid` identify the device. The rest split into two groups
    /// that the app keeps strictly apart:
    ///
    /// - **Readability** — is the driver answering at all for this card:
    ///   `temperature.gpu`, `utilization.gpu`, `memory.used`, `memory.total`.
    /// - **Pressure** — how hard the card is working, which says nothing about
    ///   whether it is healthy: `power.draw`, `power.limit`,
    ///   `temperature.memory`, `utilization.memory`.
    ///
    /// Deliberately absent: `clocks_throttle_reasons.active`. It returns a
    /// bitmask whose bit meanings are not stable across driver versions, and
    /// decoding it wrongly would produce exactly the kind of unsupported
    /// finding this app exists to avoid. Pressure the operator can see and set
    /// a threshold on is worth more than a throttle reason they cannot verify.
    public static let queryFields = [
        "index",
        "uuid",
        "name",
        "temperature.gpu",
        "utilization.gpu",
        "memory.used",
        "memory.total",
        "power.draw",
        "power.limit",
        "temperature.memory",
        "utilization.memory"
    ]

    public static var nvidiaSMIArguments: String {
        "--query-gpu=" + queryFields.joined(separator: ",")
            + " --format=csv,noheader,nounits"
    }

    /// The nvidia-smi command as it appears inside a script.
    private static var nvidiaQuery: String { "nvidia-smi \(nvidiaSMIArguments)" }

    /// The single argv element passed to ssh and executed by the remote shell.
    ///
    /// Written as one POSIX `sh` line so it survives being concatenated by ssh
    /// into a remote shell command regardless of the remote login shell.
    ///
    /// - `command -v` catches "no nvidia-smi" without relying on the exit code
    ///   of a command that may never have run.
    /// - stderr is folded into stdout so a driver error message travels back
    ///   inside the envelope instead of becoming unattributed ssh noise.
    /// - The exit code is printed *after* the bounded output block, and the
    ///   script always ends with `exit 0`, so a non-zero `nvidia-smi` status can
    ///   never be confused with an SSH failure.
    /// Written with `echo` and no quoting at all, so the whole program is plain
    /// ASCII with nothing for a remote shell to re-interpret. `exit 0` on the
    /// final statement is what makes a driver failure distinguishable from an
    /// SSH failure.
    ///
    /// Requires the remote login shell to understand POSIX `if ... then ... fi`,
    /// which is true of sh, bash, dash and zsh — the defaults on effectively
    /// every GPU server. A host running `csh` or `tcsh` will not print the
    /// markers, and the app reports that as an unclassified SSH problem rather
    /// than pretending it succeeded.
    public static let nvidiaScript: String = [
        "echo \(beginMarker);",
        "if command -v nvidia-smi >/dev/null 2>&1; then",
        "echo \(smiPresentMarker);",
        "echo \(outBeginMarker);",
        "\(nvidiaQuery) 2>&1;",
        "GPUW_RC=$?;",
        "echo \(outEndMarker);",
        "echo \(returnCodePrefix)$GPUW_RC;",
        "else",
        "echo \(smiAbsentMarker);",
        "fi;",
        "echo \(endMarker);",
        "exit 0"
    ].joined(separator: " ")

    // MARK: - AMD (ROCm)

    /// The ROCm query. Every flag here is long-standing across ROCm releases.
    ///
    /// `--csv` is what makes the output parseable, but note what it produces:
    /// rocm-smi builds the header from the **union of keys present on each
    /// card**, so column order is not a stable contract. The parser therefore
    /// reads this by column *name*, never by position.
    ///
    /// Units are the other trap, and they differ from nvidia-smi: VRAM comes
    /// back in **bytes** and temperatures in whole degrees, where nvidia-smi
    /// reports MiB and degrees respectively. The parser converts; nothing
    /// downstream has to know which tool a sample came from.
    public static let rocmSMIArguments = [
        "--showproductname",
        "--showuniqueid",
        "--showtemp",
        "--showuse",
        "--showmemuse",
        "--showmeminfo vram",
        "--showpower",
        "--showmaxpower",
        "--csv"
    ].joined(separator: " ")

    private static var rocmQuery: String { "rocm-smi \(rocmSMIArguments)" }

    /// ROCm-only script. Mirrors the NVIDIA one exactly, including the guarantee
    /// that a driver failure cannot look like an SSH failure.
    public static let amdScript: String = [
        "echo \(beginMarker);",
        "if command -v rocm-smi >/dev/null 2>&1; then",
        "echo \(vendorPrefix)\(vendorAMDSuffix);",
        "echo \(outBeginMarker);",
        "\(rocmQuery) 2>&1;",
        "GPUW_RC=$?;",
        "echo \(outEndMarker);",
        "echo \(returnCodePrefix)$GPUW_RC;",
        "else",
        "echo \(smiAbsentMarker);",
        "fi;",
        "echo \(endMarker);",
        "exit 0"
    ].joined(separator: " ")

    // MARK: - Automatic detection

    /// Script used when the host has not declared a vendor.
    ///
    /// The order is deliberate and is not simply "whichever exists first".
    /// A machine that has moved from NVIDIA to AMD often still has `nvidia-smi`
    /// installed and answering with an error, and reporting that error would be
    /// true but useless. So NVIDIA is only chosen when it actually returns
    /// rows; a present-but-failing nvidia-smi yields to ROCm, and only if ROCm
    /// is absent too do we run nvidia-smi for real in order to report its own
    /// diagnosis.
    ///
    /// The query is run once for the trial and once for real. That is a second
    /// driver call on the happy path, which is cheap, and it buys a script with
    /// no captured multi-line variable — those are exactly where shell quoting
    /// bugs live.
    public static let autoScript: String = [
        "echo \(beginMarker);",
        "GPUW_VENDOR=none;",
        "if command -v nvidia-smi >/dev/null 2>&1; then",
        "if \(nvidiaQuery) >/dev/null 2>&1; then",
        "GPUW_VENDOR=nvidia;",
        "elif command -v rocm-smi >/dev/null 2>&1; then",
        "GPUW_VENDOR=amd;",
        "else",
        "GPUW_VENDOR=nvidia;",
        "fi;",
        "elif command -v rocm-smi >/dev/null 2>&1; then",
        "GPUW_VENDOR=amd;",
        "fi;",
        "if [ \"$GPUW_VENDOR\" = nvidia ]; then",
        "echo \(vendorPrefix)nvidia;",
        "echo \(outBeginMarker);",
        "\(nvidiaQuery) 2>&1;",
        "GPUW_RC=$?;",
        "echo \(outEndMarker);",
        "echo \(returnCodePrefix)$GPUW_RC;",
        "elif [ \"$GPUW_VENDOR\" = amd ]; then",
        "echo \(vendorPrefix)amd;",
        "echo \(outBeginMarker);",
        "\(rocmQuery) 2>&1;",
        "GPUW_RC=$?;",
        "echo \(outEndMarker);",
        "echo \(returnCodePrefix)$GPUW_RC;",
        "else",
        "echo \(smiAbsentMarker);",
        "fi;",
        "echo \(endMarker);",
        "exit 0"
    ].joined(separator: " ")

    // MARK: - Selection

    /// The script to send for a host, chosen by its vendor setting.
    public static func script(for vendor: GPUVendor) -> String {
        switch vendor {
        case .nvidia: return nvidiaScript
        case .amd: return amdScript
        case .auto: return autoScript
        }
    }

    /// The remote program with no markers around it, for a person running the
    /// query by hand in Terminal while troubleshooting. Documented in the README.
    public static var manualCommand: String { "\(nvidiaQuery)" }

    /// The ROCm equivalent, for the same purpose.
    public static var amdManualCommand: String { "\(rocmQuery)" }
}

/// The remote script's output, decomposed into the facts we need to keep
/// separate: did SSH work, which GPU tool answered, and did its query work.
public struct ProbeEnvelope: Equatable, Sendable {
    /// `false` when the end marker never arrived, meaning the transport died or
    /// something on the remote side replaced our output.
    public let transportConfirmed: Bool
    /// Which tool the host was read with. `nil` when no supported tool is
    /// installed there — a distinct outcome from a tool that ran and failed.
    public let vendor: GPUVendor?
    public let queryOutput: String
    public let queryReturnCode: Int32?
    public let sawQueryOutputMarkers: Bool

    public init(
        transportConfirmed: Bool,
        vendor: GPUVendor?,
        queryOutput: String,
        queryReturnCode: Int32?,
        sawQueryOutputMarkers: Bool
    ) {
        self.transportConfirmed = transportConfirmed
        self.vendor = vendor
        self.queryOutput = queryOutput
        self.queryReturnCode = queryReturnCode
        self.sawQueryOutputMarkers = sawQueryOutputMarkers
    }

    /// Whether a supported GPU tool was found at all, whichever vendor it is.
    public var toolPresent: Bool { vendor != nil }

    /// Kept for callers that specifically mean "the NVIDIA tool answered".
    public var nvidiaSMIPresent: Bool { vendor == .nvidia }

    /// Parses the marker-delimited stdout. Tolerant by design: a host running an
    /// unfamiliar shell may still produce usable rows even if a marker is
    /// missing, so we degrade rather than discard.
    public static func parse(stdout: String) -> ProbeEnvelope {
        var transportConfirmed = false
        var vendor: GPUVendor?
        var sawOutBegin = false
        var sawOutEnd = false
        var queryLines: [String] = []
        var returnCode: Int32?
        var insideQuery = false

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            switch trimmed {
            case RemoteProbe.beginMarker:
                continue
            case RemoteProbe.smiPresentMarker:
                // Older NVIDIA-only scripts report presence without naming a
                // vendor, so the marker itself means NVIDIA.
                if vendor == nil { vendor = .nvidia }
                continue
            case RemoteProbe.smiAbsentMarker:
                vendor = nil
                continue
            case RemoteProbe.outBeginMarker:
                sawOutBegin = true
                insideQuery = true
                continue
            case RemoteProbe.outEndMarker:
                sawOutEnd = true
                insideQuery = false
                continue
            case RemoteProbe.endMarker:
                transportConfirmed = true
                continue
            default:
                break
            }

            if trimmed.hasPrefix(RemoteProbe.vendorPrefix) {
                let value = trimmed
                    .dropFirst(RemoteProbe.vendorPrefix.count)
                    .trimmingCharacters(in: .whitespaces)
                switch value {
                case RemoteProbe.vendorNVIDIASuffix: vendor = .nvidia
                case RemoteProbe.vendorAMDSuffix: vendor = .amd
                default: vendor = nil
                }
                continue
            }

            if trimmed.hasPrefix(RemoteProbe.returnCodePrefix) {
                let value = trimmed.dropFirst(RemoteProbe.returnCodePrefix.count)
                returnCode = Int32(value.trimmingCharacters(in: .whitespaces))
                continue
            }

            // Between the output markers, or after them if the markers were
            // eaten by something: keep the line either way, provided it is not
            // one of our own markers.
            if insideQuery || (sawOutBegin && !sawOutEnd) {
                queryLines.append(line)
            } else if sawOutBegin == false, vendor != nil, !trimmed.isEmpty {
                queryLines.append(line)
            }
        }

        return ProbeEnvelope(
            transportConfirmed: transportConfirmed,
            vendor: vendor,
            queryOutput: queryLines.joined(separator: "\n"),
            queryReturnCode: returnCode,
            sawQueryOutputMarkers: sawOutBegin && sawOutEnd
        )
    }
}
