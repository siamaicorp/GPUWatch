import SwiftUI
import GPUWatchCore

/// Window and disclosure state.
///
/// Kept out of `AppModel` on purpose: none of this belongs in the saved
/// configuration, and none of it should be able to influence a health verdict.
@MainActor
@Observable
public final class UIState {
    /// Host whose detail pane is open in the popover.
    public var expandedHostID: UUID?
    /// Whether the compact floating panel is on screen.
    public var isPanelVisible = false
    /// Whether the settings window is on screen.
    public var isSettingsPresented = false
    /// Host being edited in a sheet, or `nil` when the editor is closed.
    public var editingHost: HostConfig?
    /// `true` when the sheet is creating a new host rather than editing one.
    public var isCreatingHost = false
    /// Host whose baseline registration is awaiting confirmation.
    public var pendingBaselineHostID: UUID?
    /// Host whose deletion is awaiting confirmation. Kept here rather than as
    /// per-row state, so opening one row's confirmation does not depend on that
    /// row still being on screen.
    public var pendingDeleteHostID: UUID?

    public init() {}

    func toggleExpanded(_ hostID: UUID) {
        expandedHostID = expandedHostID == hostID ? nil : hostID
    }

    func beginCreate() {
        editingHost = HostConfig(displayName: "", destination: "", expectedGPUCount: 0)
        isCreatingHost = true
    }

    func beginEdit(_ host: HostConfig) {
        editingHost = host
        isCreatingHost = false
    }

    func endEditing() {
        editingHost = nil
        isCreatingHost = false
    }
}
