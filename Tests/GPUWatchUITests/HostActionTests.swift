import AppKit
import SwiftUI
import XCTest
import GPUWatchCore
@testable import GPUWatchUI

/// The per-host actions existed in the coordinator from the start but had no
/// entry point, so an existing host could be added and then never changed. These
/// tests cover the wiring from intent to model, which is the part that was
/// missing rather than the logic underneath it.
@MainActor
final class HostActionTests: XCTestCase {
    private var directory: URL!
    private var coordinator: AppCoordinator!
    private var host: HostConfig!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpuwatch-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        coordinator = AppCoordinator(
            model: AppModel(
                store: ConfigurationStore(directory: directory),
                // Live mode with a throwaway store: no host is contactable, which
                // is the state the actions have to work in anyway.
                deliverer: NoopNotificationDeliverer()
            )
        )
        coordinator.model.start()

        host = HostConfig(
            displayName: "editable-01",
            destination: "editable-01.invalid",
            username: "ops",
            expectedGPUCount: 4
        )
        coordinator.model.addHost(host)
    }

    override func tearDownWithError() throws {
        coordinator?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The core of the reported bug: there was no path from the UI to the editor.
    func testBeginEditOpensTheEditorForThatHost() {
        coordinator.beginEdit(host)

        XCTAssertEqual(coordinator.ui.editingHost?.id, host.id)
        XCTAssertFalse(coordinator.ui.isCreatingHost)
        XCTAssertTrue(coordinator.ui.editingHost?.effectiveName == "editable-01")
    }

    func testAddHostOpensTheEditorInCreateMode() {
        coordinator.beginAddHost()

        XCTAssertTrue(coordinator.ui.isCreatingHost)
        XCTAssertNotNil(coordinator.ui.editingHost)
        XCTAssertTrue(coordinator.ui.editingHost?.destination.isEmpty == true)
    }

    func testSavingAnEditChangesTheStoredHost() {
        coordinator.beginEdit(host)
        var edited = host!
        edited.expectedGPUCount = 8
        edited.temperatureWarningThreshold = 82
        coordinator.commitEditing(edited)

        let stored = coordinator.model.hosts.first { $0.id == host.id }
        XCTAssertEqual(stored?.expectedGPUCount, 8)
        XCTAssertEqual(stored?.temperatureWarningThreshold, 82)
        XCTAssertNil(coordinator.ui.editingHost, "the editor closes after a save")
    }

    func testCancellingAnEditLeavesTheHostAlone() {
        coordinator.beginEdit(host)
        var edited = host!
        edited.displayName = "should not stick"
        coordinator.cancelEditing()

        XCTAssertEqual(
            coordinator.model.hosts.first { $0.id == host.id }?.displayName,
            "editable-01"
        )
        XCTAssertNil(coordinator.ui.editingHost)
    }

    func testDeletingAHostRemovesItAndClosesTheEditor() {
        coordinator.beginEdit(host)
        coordinator.deleteHost(host)

        XCTAssertFalse(coordinator.model.hosts.contains { $0.id == host.id })
        XCTAssertNil(coordinator.ui.editingHost)
    }

    func testEnablingAndDisablingAHostIsReachable() {
        coordinator.setHostEnabled(false, host: host)
        XCTAssertEqual(coordinator.model.hosts.first { $0.id == host.id }?.enabled, false)

        coordinator.setHostEnabled(true, host: host)
        XCTAssertEqual(coordinator.model.hosts.first { $0.id == host.id }?.enabled, true)
    }

    func testDisablingLeavesTheRowVisibleAndMarkedDisabled() {
        coordinator.setHostEnabled(false, host: host)
        let report = coordinator.model.reports[host.id]
        XCTAssertEqual(report?.displayState, .disabled)
        XCTAssertTrue(
            coordinator.model.visibleReports.contains { $0.id == host.id },
            "a disabled host must still be listed, or it looks deleted"
        )
    }

    /// Registering a baseline needs a reading. Offering it before one exists
    /// would open a confirmation dialog for nothing.
    func testRegisteringABaselineIsRefusedWithoutAReading() {
        coordinator.beginRegisterBaseline(hostID: host.id)
        // The confirmation is presented, but committing must not invent a
        // baseline out of an empty reading.
        coordinator.confirmRegisterBaseline()
        XCTAssertNil(coordinator.model.baselines.baseline(for: host.id))
    }

    func testDeleteConfirmationStateIsTrackedOnTheUIState() {
        coordinator.ui.pendingDeleteHostID = host.id
        XCTAssertEqual(coordinator.ui.pendingDeleteHostID, host.id)

        coordinator.stop()
        XCTAssertNil(
            coordinator.ui.pendingDeleteHostID,
            "a pending confirmation must not survive a stop"
        )
    }

    /// Closing the editor with the window's close button must clear the editing
    /// state. Otherwise reopening the same host reuses a form still holding an
    /// abandoned edit, because `.id(host.id)` has not changed.
    func testClosingTheEditorWindowClearsTheEditingHost() {
        let controller = HostEditorWindowController()
        controller.onClose = { [weak self] in
            self?.coordinator.ui.editingHost = nil
        }
        coordinator.beginEdit(host)
        XCTAssertNotNil(coordinator.ui.editingHost)

        controller.show(content: Color.clear, title: "Edit Host")
        controller.window?.close()

        XCTAssertNil(
            coordinator.ui.editingHost,
            "closing the window must not leave an abandoned edit attached to the host"
        )
    }

    func testEveryHostGetsARowEvenBeforeItsFirstCheck() {
        let reports = coordinator.model.visibleReports
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.id, host.id)
        XCTAssertNotEqual(
            reports.first?.displayState, .disabled,
            "an enabled host that has not been checked is unknown, not disabled"
        )
    }
}
