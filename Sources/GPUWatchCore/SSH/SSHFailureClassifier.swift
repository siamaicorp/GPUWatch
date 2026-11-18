import Foundation

/// Maps raw `ssh` stderr onto the small set of causes the UI can act on.
///
/// This exists so the app can say "check your key" instead of dumping an ssh
/// diagnostic at the operator. Everything unmatched falls through to
/// `.unreachable`, because from the user's point of view an unexplained ssh
/// failure is still "could not reach it".
public enum SSHFailureClassifier {
    public static func classify(
        result: SSHCommandResult,
        transportConfirmed: Bool
    ) -> (kind: SSHFailureKind, detail: String) {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = firstMeaningfulLine(in: stderr)

        if result.cancelled {
            return (.cancelled, detail.isEmpty ? "Check cancelled" : detail)
        }
        if result.timedOut {
            return (.timedOut, detail.isEmpty ? "No response within the check deadline" : detail)
        }
        // The remote program ran to completion and printed our end marker, so
        // ssh definitely worked whatever its exit status says.
        if transportConfirmed {
            return (.unknown, detail)
        }
        // A non-255 status without our marker means the remote side ran
        // something but not our script — reached the host, found no driver.
        if !result.isSSHTransportFailure {
            return (.unknown, detail.isEmpty ? "Remote probe did not complete" : detail)
        }

        let haystack = stderr.lowercased()

        let hostKeyMarkers = [
            "host key verification failed",
            "remote host identification has changed",
            "host key has changed",
            "no matching host key",
            "host key algorithms"
        ]
        if hostKeyMarkers.contains(where: haystack.contains) {
            return (.hostKeyVerification, detail)
        }

        let authMarkers = [
            "permission denied",
            "too many authentication failures",
            "authentication failed",
            "no supported authentication methods",
            "agent refused operation",
            "sign_and_send_pubkey"
        ]
        if authMarkers.contains(where: haystack.contains) {
            return (.authenticationFailed, detail)
        }

        return (.unreachable, detail.isEmpty ? "SSH could not connect" : detail)
    }

    /// ssh often emits several lines; the last non-empty one is usually the
    /// actionable one, falling back to the first.
    private static func firstMeaningfulLine(in text: String) -> String {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        // Cap the length so a chatty remote banner can't push the row's layout
        // around; the full text is kept in the report for the detail pane.
        let chosen = lines.last ?? lines[0]
        return chosen.count > 240 ? String(chosen.prefix(240)) + "…" : chosen
    }
}
