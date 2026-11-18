import AppKit
import SwiftUI
import XCTest
@testable import GPUWatchUI

/// These cover the two defects that made the settings page unscrollable and the
/// pinned panel's controls unusable. Both had the same root cause and neither
/// showed up in a view-level test, so they are pinned down here instead.
@MainActor
final class WindowControllerTests: XCTestCase {

    private struct Sample: View {
        var body: some View {
            ScrollView { Color.gray.frame(height: 4000) }
        }
    }

    // MARK: - Content must not be rebuilt

    func testPresentingTwiceKeepsTheSameHostingController() {
        let controller = SettingsWindowController()
        controller.show(content: Sample())

        let first = controller.window?.contentViewController
        XCTAssertNotNil(first)

        controller.show(content: Sample())
        controller.show(content: Sample())

        XCTAssertTrue(
            controller.window?.contentViewController === first,
            "re-showing a window must not replace its hosting controller — replacing it "
                + "rebuilds the SwiftUI tree and makes scrolling and switches impossible"
        )
    }

    func testShowingAgainDoesNotCreateASecondWindow() {
        let controller = SettingsWindowController()
        controller.show(content: Sample())
        let first = controller.window

        controller.show(content: Sample())
        XCTAssertTrue(controller.window === first)
    }

    func testEditorWindowKeepsItsHostingControllerAcrossPresentations() {
        let controller = HostEditorWindowController()
        controller.show(content: Sample(), title: "Edit Host")
        let first = controller.window?.contentViewController

        controller.show(content: Sample(), title: "Add GPU Host")
        XCTAssertTrue(controller.window?.contentViewController === first)
        XCTAssertEqual(controller.window?.title, "Add GPU Host", "the title still tracks the mode")
    }

    func testPanelKeepsItsHostingControllerAcrossPresentations() {
        let controller = FloatingPanelController()
        controller.show(content: Sample(), width: 300, alwaysOnTop: true)
        let first = controller.panelWindow?.contentViewController

        controller.show(content: Sample(), width: 300, alwaysOnTop: false)
        XCTAssertTrue(controller.panelWindow?.contentViewController === first)
    }

    // MARK: - Sizing

    /// Assigning `contentViewController` makes AppKit adopt the controller's
    /// preferred size, which is zero when automatic sizing is off. Without the
    /// explicit `setContentSize` the window collapses to its minimum — the first
    /// symptom was a 460×600 settings page opening at 420×300.
    func testWindowsOpenAtTheirIntendedContentSize() throws {
        let settings = SettingsWindowController()
        settings.show(content: Sample())
        let settingsContent = try XCTUnwrap(settings.window?.contentLayoutRect)
        XCTAssertEqual(settingsContent.width, 460, accuracy: 1)
        XCTAssertEqual(settingsContent.height, 620, accuracy: 1)

        let editor = HostEditorWindowController()
        editor.show(content: Sample(), title: "Edit Host")
        let editorContent = try XCTUnwrap(editor.window?.contentLayoutRect)
        XCTAssertEqual(editorContent.width, 520, accuracy: 1)
        XCTAssertEqual(editorContent.height, 640, accuracy: 1)

        let panel = FloatingPanelController()
        panel.show(content: Sample(), width: 300, alwaysOnTop: true)
        XCTAssertEqual(try XCTUnwrap(panel.panelWindow?.contentLayoutRect).width, 300, accuracy: 1)
    }

    func testWindowsAreWideEnoughToBeUsableAfterShrinking() throws {
        let settings = SettingsWindowController()
        settings.show(content: Sample())
        let window = try XCTUnwrap(settings.window)
        XCTAssertGreaterThanOrEqual(window.minSize.width, 420)
        XCTAssertTrue(
            window.styleMask.contains(.resizable),
            "the settings page scrolls, so the window must be resizable"
        )
    }

    func testClosingAndReopeningReusesTheWindow() {
        let settings = SettingsWindowController()
        settings.show(content: Sample())
        let window = settings.window
        settings.close()
        XCTAssertFalse(settings.isVisible)

        settings.show(content: Sample())
        XCTAssertTrue(settings.window === window)
        XCTAssertTrue(settings.isVisible)
    }
}
