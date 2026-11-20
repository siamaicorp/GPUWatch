import XCTest
@testable import GPUWatchUI

/// The About panel must never describe a build that is not the one running, so
/// the string is read from the bundle. The formatting rule is tested directly
/// rather than through `Bundle.main`, because under test the main bundle is the
/// test bundle — asserting on it would be asserting on XCTest, not on the app.
final class AppInfoTests: XCTestCase {

    func testVersionAndBuildAreBothShown() {
        XCTAssertEqual(
            AppInfo.display(shortVersion: "1.1.0", build: "2"),
            "Version 1.1.0 (build 2)"
        )
    }

    /// A build number equal to the version says nothing extra, so it is not
    /// repeated. The shipped `Info.plist` pairs 1.0.0 with 1.
    func testRedundantBuildNumberIsNotRepeated() {
        XCTAssertEqual(AppInfo.display(shortVersion: "1.0.0", build: "1.0.0"),
                       "Version 1.0.0")
        XCTAssertEqual(AppInfo.display(shortVersion: "1.0.0", build: nil),
                       "Version 1.0.0")
    }

    /// No bundle means no version to report. Guessing one would be inventing a
    /// fact about the build.
    func testMissingVersionIsReportedAsADevelopmentBuild() {
        XCTAssertEqual(AppInfo.display(shortVersion: nil, build: nil), "Development build")
        XCTAssertEqual(AppInfo.display(shortVersion: "", build: "2"), "Development build")
        XCTAssertEqual(AppInfo.display(shortVersion: "   ", build: "2"), "Development build")
    }

    func testDisplayIsNeverBlank() {
        XCTAssertFalse(AppInfo.display.isEmpty)
        XCTAssertFalse(AppInfo.display.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The link text is what a person reads before clicking, so it has to name
    /// the place the link actually goes. Two separate strings can drift apart;
    /// this keeps them from doing so silently.
    func testRepositoryLabelNamesTheRepositoryItLinksTo() throws {
        let url = try XCTUnwrap(AppInfo.repository)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(
            url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            AppInfo.repositoryLabel.replacingOccurrences(of: "github.com/", with: "")
        )
    }
}
