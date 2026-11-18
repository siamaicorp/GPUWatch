import SwiftUI
import GPUWatchCore

/// Content of the host editor window.
///
/// The window is created once and keeps its hosting controller, so this view
/// reads the host being edited from `ui` rather than capturing one. Two things
/// follow from that:
///
/// - Opening a different host re-renders this view instead of needing a new
///   window.
/// - `.id(host.id)` resets the form's local field state when the target changes.
///   Without it, opening host B after abandoning an edit of host A would show
///   A's half-typed values.
struct HostEditorWindowContent: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if let host = coordinator.ui.editingHost {
            HostEditorView(
                coordinator: coordinator,
                draft: host,
                isCreating: coordinator.ui.isCreatingHost
            )
            .id(host.id)
        } else {
            // Never seen in practice: the coordinator closes the window at the
            // same moment it clears the host.
            Color.clear.frame(minWidth: 480, minHeight: 400)
        }
    }
}
