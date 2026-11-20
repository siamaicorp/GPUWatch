import Foundation

/// The facts an About panel states about this build.
///
/// The version is read from the running bundle rather than written into the
/// source, because the one thing an About panel must never do is describe a
/// build that is not the one running. A hardcoded string here would be wrong
/// the first time a release happened and nobody would notice.
public enum AppInfo {
    /// The running bundle's version, e.g. `Version 1.2.0 (build 2)`.
    public static var display: String {
        let info = Bundle.main.infoDictionary
        return display(
            shortVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }

    /// The bundle identifier, so a support question can be answered from a
    /// screenshot.
    public static var identifier: String? {
        nonEmpty(Bundle.main.bundleIdentifier)
    }

    /// Where the project lives. `nil` rather than a crash if the literal ever
    /// stops parsing — an About panel is not worth taking the app down for.
    public static var repository: URL? {
        URL(string: "https://github.com/siamaicorp/GPUWatch")
    }

    /// Shown as the link text, so it is legible without hovering.
    public static var repositoryLabel: String { "github.com/siamaicorp/GPUWatch" }

    /// The formatting rule, separated from the bundle lookup so it can be
    /// exercised directly. The lookup cannot be: every process has exactly one
    /// main bundle, and under test that is the test bundle, not the app's.
    ///
    /// A missing version is reported as a development build rather than
    /// guessed at. That case is real — `swift run` and the snapshot harness
    /// execute the binary with no app bundle at all.
    public static func display(shortVersion: String?, build: String?) -> String {
        guard let short = nonEmpty(shortVersion) else { return "Development build" }
        guard let build = nonEmpty(build), build != short else { return "Version \(short)" }
        return "Version \(short) (build \(build))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
