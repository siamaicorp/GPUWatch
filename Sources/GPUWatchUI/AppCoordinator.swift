import AppKit
import SwiftUI
import GPUWatchCore

/// Wires the core model to the windows and turns user intent into model calls.
///
/// One coordinator per app. The windows are created lazily and never own their
/// own timers, so a pinned panel cannot start a second polling loop.
@MainActor
@Observable
public final class AppCoordinator {
    public let model: AppModel
    /// A stored `var` so views can form bindings into it (`$coordinator.ui.…`).
    public var ui = UIState()

    @ObservationIgnored private let panelController = FloatingPanelController()
    @ObservationIgnored private let settingsController = SettingsWindowController()
    @ObservationIgnored private let editorController = HostEditorWindowController()

    var alwaysOnTop: Bool = UserDefaults.standard.object(forKey: "panelAlwaysOnTop") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alwaysOnTop, forKey: "panelAlwaysOnTop")
            panelController.setAlwaysOnTop(alwaysOnTop)
        }
    }

    /// `model` is an optional rather than a defaulted value so the main-actor
    /// initialiser is only ever called from inside this main-actor body.
    public init(model: AppModel? = nil) {
        self.model = model ?? AppModel()
        // The windows mirror their open state in `ui`; closing one with the
        // traffic light has to clear that, or the next open would reuse a form
        // still holding an abandoned edit.
        settingsController.onClose = { [weak self] in
            self?.ui.isSettingsPresented = false
        }
        editorController.onClose = { [weak self] in
            self?.ui.editingHost = nil
            self?.ui.isCreatingHost = false
        }
        panelController.onClose = { [weak self] in
            self?.ui.isPanelVisible = false
        }
    }

    func start() {
        model.start()
        syncPanel()
        syncSettings()
    }

    func stop() {
        ui.pendingDeleteHostID = nil
        ui.pendingBaselineHostID = nil
        panelController.close()
        settingsController.close()
        editorController.close()
        model.stop()
    }

    // MARK: - Window plumbing
    //
    // Windows are opened and closed by the intent methods below, not by a timer.
    // An earlier version polled and re-showed them every 120 ms, which rebuilt
    // the SwiftUI tree that often and made scrolling and switches impossible.

    private func syncPanel() {
        guard ui.isPanelVisible else {
            panelController.close()
            return
        }
        panelController.show(
            content: FloatingPanelView(coordinator: self),
            width: DS.panelWidth,
            alwaysOnTop: alwaysOnTop
        )
    }

    private func syncSettings() {
        if ui.isSettingsPresented {
            settingsController.show(content: SettingsView(coordinator: self))
        } else {
            settingsController.close()
        }
    }

    /// The editor window stays attached to one view for its whole life; the view
    /// reads the host being edited from `ui`, so switching hosts re-renders
    /// rather than requiring a new window.
    private func syncEditor() {
        if ui.editingHost == nil {
            editorController.close()
            return
        }
        editorController.show(
            content: HostEditorWindowContent(coordinator: self),
            title: ui.isCreatingHost ? "Add GPU Host" : "Edit Host"
        )
    }

    // MARK: - Intents

    func refresh() {
        Task { await model.refreshNow() }
    }

    func togglePanel() {
        ui.isPanelVisible.toggle()
        syncPanel()
        if ui.isPanelVisible { panelController.bringToFront() }
    }

    func openSettings() {
        ui.isSettingsPresented = true
        syncSettings()
    }

    func closeSettings() {
        ui.isSettingsPresented = false
        syncSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func beginAddHost() {
        ui.beginCreate()
        syncEditor()
    }

    func beginEdit(_ host: HostConfig) {
        ui.beginEdit(host)
        syncEditor()
    }

    func cancelEditing() {
        editorController.close()
        ui.endEditing()
    }

    /// Saves the host in the editor, creating or updating as appropriate.
    func commitEditing(_ host: HostConfig) {
        editorController.close()
        if ui.isCreatingHost {
            model.addHost(host)
        } else {
            model.updateHost(host)
        }
        ui.endEditing()
    }

    func deleteHost(_ host: HostConfig) {
        editorController.close()
        model.deleteHost(id: host.id)
        if ui.expandedHostID == host.id { ui.expandedHostID = nil }
        ui.endEditing()
    }

    func setHostEnabled(_ enabled: Bool, host: HostConfig) {
        model.setEnabled(enabled, for: host.id)
    }

    func beginRegisterBaseline(hostID: UUID) {
        ui.pendingBaselineHostID = hostID
    }

    /// Runs a check against one host right now, for the detail pane's Test
    /// Connection action.
    func testHost(_ host: HostConfig) async -> ConnectionTestResult {
        await model.testConnection(host)
    }

    func confirmRegisterBaseline() {
        guard let hostID = ui.pendingBaselineHostID else { return }
        model.registerBaseline(hostID: hostID)
        ui.pendingBaselineHostID = nil
    }

    func cancelRegisterBaseline() {
        ui.pendingBaselineHostID = nil
    }

    func removeBaseline(hostID: UUID) {
        model.removeBaseline(hostID: hostID)
    }

    func setDemoMode(_ enabled: Bool) {
        model.setDemoMode(enabled)
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        Task { await model.setNotificationsEnabled(enabled) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        model.setLaunchAtLogin(enabled)
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            // The preference is saved either way; the message explains why the
            // switch will not actually take effect.
            launchAtLoginError = error.localizedDescription
        }
    }

    var launchAtLoginError: String?

    func revealConfigurationFolder() {
        model.revealConfigurationFolder()
    }

    // MARK: - Diagnostics

    /// Geometry of the ordinary windows, in the same shape as the menu bar item's
    /// diagnostics. `screencapture -R` uses a top-left origin while AppKit frames
    /// are bottom-left, so the caller needs these frames plus the screen height.
    func windowDiagnostics() -> String {
        var lines: [String] = []
        if let frame = settingsController.window?.frame, settingsController.isVisible {
            lines.append("settings window: \(describe(frame))")
        }
        if let frame = editorController.window?.frame, editorController.isVisible {
            let target = ui.editingHost.map {
                "\(ui.isCreatingHost ? "new" : "existing") host \($0.effectiveName)"
            } ?? "no host"
            lines.append("editor window: \(describe(frame)), \(target)")
        }
        if let frame = panelController.panelWindow?.frame, panelController.isVisible {
            lines.append("panel window: \(describe(frame))")
        }
        if lines.isEmpty { lines.append("no auxiliary window is open") }
        return lines.joined(separator: "\n")
    }

    private func describe(_ frame: NSRect) -> String {
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        return "\(size) at (\(Int(frame.minX)), \(Int(frame.minY)))"
    }
}
