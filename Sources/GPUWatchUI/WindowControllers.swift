import AppKit
import SwiftUI

/// Base for the app's AppKit windows.
///
/// SwiftUI content is attached **once**. An earlier version replaced the window's
/// hosting view on every `show` call, and because the coordinator re-showed
/// windows on a timer that tore down and rebuilt the whole view tree several
/// times a second. The visible symptoms were a settings page that would not
/// scroll and switches that reset under the pointer — the view was being replaced
/// mid-gesture. SwiftUI views observe the shared model themselves, so there is
/// nothing to rebuild.
/// Forwards a window's close to the owner.
///
/// Needed so state that mirrors "this window is open" is cleared when the user
/// closes the window with the traffic light rather than with the in-page button.
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func windowWillClose(_ notification: Notification) {
        // AppKit delivers window notifications on the main thread, so this
        // assertion is safe and lets the handler run synchronously. Deferring it
        // to a Task left the mirrored state stale for a turn, which is
        // observable — the flag would still read "open" right after a close.
        MainActor.assumeIsolated {
            handler()
        }
    }
}

@MainActor
class HostedWindowController {
    private(set) var window: NSWindow?
    private var hasPositioned = false
    private var closeObserver: WindowCloseObserver?

    /// Called when the window is closed by any route, including the close button.
    var onClose: (() -> Void)? {
        didSet { installCloseObserverIfNeeded() }
    }

    private func installCloseObserverIfNeeded() {
        guard let window, closeObserver == nil else { return }
        let observer = WindowCloseObserver { [weak self] in
            self?.onClose?()
        }
        closeObserver = observer
        window.delegate = observer
    }

    /// Attaches content to a window and sets the window's content size.
    ///
    /// Re-attaching replaces the hosting controller, so callers must only do it
    /// when the window is created.
    ///
    /// The size is set *after* the controller is assigned and it is set here
    /// rather than by the SwiftUI view. Two traps this avoids:
    ///
    /// - Assigning `contentViewController` makes AppKit resize the window to the
    ///   controller's preferred content size. With sizing disabled that is zero,
    ///   so the window collapses to its minimum. The explicit `setContentSize`
    ///   afterwards is what actually gives it its size.
    /// - Letting SwiftUI declare the size instead (`.frame(width:height:)` inside
    ///   the view) couples a scrollable page's layout to a fixed number and makes
    ///   resizing impossible.
    func attach<Content: View>(_ content: Content, to window: NSWindow, contentSize: CGSize) {
        self.window = window
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(content))
        // No automatic sizing: these windows have deliberate sizes the user can
        // change, and a scrollable page's ideal height is its whole content.
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(contentSize)
        installCloseObserverIfNeeded()
    }

    func present() {
        guard let window else { return }
        if !hasPositioned {
            hasPositioned = true
            if !window.setFrameUsingName(window.frameAutosaveName) {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }

    func orderOut() {
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}

// MARK: - Pinned panel

/// The compact always-available panel.
///
/// A `.nonactivatingPanel` so clicking it does not pull focus away from whatever
/// the operator was doing — this is a monitor, not a document. It is movable by
/// its background and remembers where it was left.
@MainActor
final class FloatingPanelController: HostedWindowController {
    /// The panel's own `window` accessor, exposed so diagnostics can report it.
    var panelWindow: NSWindow? { panel }

    private var panel: NSPanel?

    func show(content: some View, width: CGFloat, alwaysOnTop: Bool) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "GPU Watch"
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.setFrameAutosaveName("GPUWatchFloatingPanel")

            attach(content, to: panel, contentSize: NSSize(width: width, height: 360))
            self.panel = panel
            positionNearMenuBar(panel)
        }

        setAlwaysOnTop(alwaysOnTop)
        guard let panel, !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        panel?.level = enabled ? .floating : .normal
    }

    func bringToFront() {
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func positionNearMenuBar(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - 16,
            y: visible.maxY - panel.frame.height - 12
        ))
    }
}

// MARK: - Settings

/// The settings window. A plain window rather than the `Settings` scene, because
/// the app runs as an accessory (`LSUIElement`) and has no application menu from
/// which to open one.
@MainActor
final class SettingsWindowController: HostedWindowController {
    func show(content: some View) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                // Resizable so a tall screen can show the whole page at once; the
                // page scrolls when the window is smaller than its content.
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "GPU Watch Settings"
            window.minSize = NSSize(width: 420, height: 300)
            attach(content, to: window, contentSize: NSSize(width: 460, height: 620))
        }
        present()
    }

    func close() {
        orderOut()
    }
}

// MARK: - Host editor

/// The add / edit host form, in its own window.
///
/// Deliberately not a sheet on the popover: the form is larger than the popover
/// that would host it, and a transient popover dismisses itself the moment a
/// sibling window takes focus — which would close the form mid-edit.
@MainActor
final class HostEditorWindowController: HostedWindowController {
    func show(content: some View, title: String) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.minSize = NSSize(width: 480, height: 420)
            attach(content, to: window, contentSize: NSSize(width: 520, height: 640))
        }
        window?.title = title
        present()
    }

    func close() {
        orderOut()
    }
}
