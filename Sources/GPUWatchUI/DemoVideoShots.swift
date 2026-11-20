import SwiftUI
import GPUWatchCore

/// The storyboard for the demo video.
///
/// Frames are rendered from the **real** popover view driven by the **real**
/// evaluator over the demo fleet, so what the video shows is what the app shows.
/// Nothing here is a mock-up of the UI.
///
/// The narrative is deliberately one idea, not a feature tour: a host that cannot
/// be reached is reported as *unknown*, while a host whose card is genuinely gone
/// is reported as *missing* — and those two are shown one after the other so the
/// difference is visible rather than described.
public enum DemoVideoShots {

    public struct Shot {
        public let name: String
        /// Host to expand, matched by name prefix. `nil` collapses everything.
        public let expandedHostName: String?
        /// Scroll position as a fraction of the scrollable range: 0 is the top,
        /// 1 is the bottom.
        public let scrollFrom: Double
        public let scrollTo: Double
        public let durationSeconds: Double
        /// Burned-in caption. English, because the video sits in the English
        /// README; the Thai README carries its own text.
        public let caption: String?

        public init(
            name: String,
            expandedHostName: String? = nil,
            scrollFrom: Double,
            scrollTo: Double,
            durationSeconds: Double,
            caption: String? = nil
        ) {
            self.name = name
            self.expandedHostName = expandedHostName
            self.scrollFrom = scrollFrom
            self.scrollTo = scrollTo
            self.durationSeconds = durationSeconds
            self.caption = caption
        }
    }

    /// Roughly 40 seconds in total.
    public static var shots: [Shot] {
        [
            Shot(
                name: "01-intro",
                scrollFrom: 0, scrollTo: 0, durationSeconds: 5.0,
                caption: "GPU Watch — every GPU on every server, in the menu bar"
            ),
            Shot(
                name: "02-missing-gpu",
                expandedHostName: "5090-2",
                scrollFrom: 0, scrollTo: 0.30, durationSeconds: 8.0,
                caption: "A card that is genuinely gone is reported as MISSING"
            ),
            Shot(
                name: "03-scroll-to-unreachable",
                expandedHostName: "5090-2",
                scrollFrom: 0, scrollTo: 0.55, durationSeconds: 7.0,
                caption: "Now the same fleet, but one host stops answering"
            ),
            Shot(
                name: "04-unreachable-detail",
                // Scrolled back up so this host's own row — `?/8` with eight
                // hollow dots — is on screen, not just its notes. That row is
                // the whole point of the shot.
                expandedHostName: "H100-02",
                scrollFrom: 0.55, scrollTo: 0.10, durationSeconds: 9.0,
                caption: "SSH failed — so every GPU is UNKNOWN, not missing"
            ),
            Shot(
                name: "05-unknown-vs-missing",
                expandedHostName: nil,
                scrollFrom: 0.10, scrollTo: 0, durationSeconds: 7.0,
                caption: "?/8 and 3/4 are different facts. The app keeps them apart."
            ),
            Shot(
                name: "06-outro",
                expandedHostName: nil,
                scrollFrom: 0, scrollTo: 0, durationSeconds: 5.0,
                caption: "github.com/siamaicorp/GPUWatch"
            )
        ]
    }

    public static var totalSeconds: Double {
        shots.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Applies a shot's *content* state to the coordinator.
    ///
    /// Scrolling is deliberately not handled here: the harness drives the scroll
    /// position directly on the underlying `NSScrollView`, so the app's own view
    /// code carries nothing that exists only for the video.
    @MainActor
    public static func apply(_ shot: Shot, to coordinator: AppCoordinator) {
        guard let name = shot.expandedHostName else {
            coordinator.ui.expandedHostID = nil
            return
        }
        coordinator.ui.expandedHostID = coordinator.model.visibleReports.first {
            $0.host.effectiveName.hasPrefix(name)
        }?.id
    }

    /// Frames per second for the rendered sequence. Low on purpose: the content
    /// changes slowly, and a high rate would only make the file larger.
    public static let framesPerSecond: Double = 12

    /// Eases so a scroll does not start and stop abruptly.
    public static func ease(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return clamped < 0.5
            ? 2 * clamped * clamped
            : 1 - pow(-2 * clamped + 2, 2) / 2
    }
}
