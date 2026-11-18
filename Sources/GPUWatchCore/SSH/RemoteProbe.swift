import Foundation

/// The fixed remote program sent to every host, and the envelope that carries
/// its output back.
///
/// Two rules make this safe and unambiguous:
///
/// 1. The script is a compile-time constant. No user-supplied string is ever
///    interpolated into it, so a host alias cannot become remote code.
/// 2. The script always exits 0 and always prints an end marker. That gives us
///    positive proof the SSH transport worked even when `nvidia-smi` is absent
///    or broken — which is why a failed GPU query is never mistaken for an
///    unreachable host.
public enum RemoteProbe {
    public static let beginMarker = "__GPUW_BEGIN__"
    public static let smiPresentMarker = "__GPUW_SMI_PRESENT__"
    public static let smiAbsentMarker = "__GPUW_SMI_ABSENT__"
    public static let outBeginMarker = "__GPUW_OUT_BEGIN__"
    public static let outEndMarker = "__GPUW_OUT_END__"
    public static let endMarker = "__GPUW_END__"
    public static let returnCodePrefix = "__GPUW_RC__"

    /// Query fields, verified against the nvidia-smi documentation. `index` and
    /// `uuid` identify the device; the rest are the health signals we display.
    public static let queryFields = [
        "index",
        "uuid",
        "name",
        "temperature.gpu",
        "utilization.gpu",
        "memory.used",
        "memory.total"
    ]

    public static var nvidiaSMIArguments: String {
        "--query-gpu=" + queryFields.joined(separator: ",")
            + " --format=csv,noheader,nounits"
    }

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
    public static let script: String = [
        "echo \(beginMarker);",
        "if command -v nvidia-smi >/dev/null 2>&1; then",
        "echo \(smiPresentMarker);",
        "echo \(outBeginMarker);",
        "nvidia-smi \(nvidiaSMIArguments) 2>&1;",
        "GPUW_RC=$?;",
        "echo \(outEndMarker);",
        "echo \(returnCodePrefix)$GPUW_RC;",
        "else",
        "echo \(smiAbsentMarker);",
        "fi;",
        "echo \(endMarker);",
        "exit 0"
    ].joined(separator: " ")

    /// Alternative spelling accepted when the user runs a probe manually through
    /// Terminal for troubleshooting. Documented in the README.
    public static let manualCommand: String = "nvidia-smi \(nvidiaSMIArguments)"
}

/// The remote script's output, decomposed into the two facts we need to keep
/// separate: did SSH work, and did the GPU query work.
public struct ProbeEnvelope: Equatable, Sendable {
    /// `false` when the end marker never arrived, meaning the transport died or
    /// something on the remote side replaced our output.
    public let transportConfirmed: Bool
    public let nvidiaSMIPresent: Bool
    public let queryOutput: String
    public let queryReturnCode: Int32?
    public let sawQueryOutputMarkers: Bool

    public init(
        transportConfirmed: Bool,
        nvidiaSMIPresent: Bool,
        queryOutput: String,
        queryReturnCode: Int32?,
        sawQueryOutputMarkers: Bool
    ) {
        self.transportConfirmed = transportConfirmed
        self.nvidiaSMIPresent = nvidiaSMIPresent
        self.queryOutput = queryOutput
        self.queryReturnCode = queryReturnCode
        self.sawQueryOutputMarkers = sawQueryOutputMarkers
    }

    /// Parses the marker-delimited stdout. Tolerant by design: a host running an
    /// unfamiliar shell may still produce usable rows even if a marker is
    /// missing, so we degrade rather than discard.
    public static func parse(stdout: String) -> ProbeEnvelope {
        var transportConfirmed = false
        var smiPresent: Bool?
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
                smiPresent = true
                continue
            case RemoteProbe.smiAbsentMarker:
                smiPresent = false
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
            } else if sawOutBegin == false, smiPresent == true, !trimmed.isEmpty {
                queryLines.append(line)
            }
        }

        return ProbeEnvelope(
            transportConfirmed: transportConfirmed,
            nvidiaSMIPresent: smiPresent ?? false,
            queryOutput: queryLines.joined(separator: "\n"),
            queryReturnCode: returnCode,
            sawQueryOutputMarkers: sawOutBegin && sawOutEnd
        )
    }
}
