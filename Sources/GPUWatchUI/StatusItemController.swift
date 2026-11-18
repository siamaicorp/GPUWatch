import AppKit
import SwiftUI
import GPUWatchCore

/// Owns the menu bar item and the popover it opens.
///
/// This is an explicit `NSStatusItem` rather than SwiftUI's `MenuBarExtra`. Two
/// concrete reasons:
///
/// - `MenuBarExtra` exposes no handle on the item, so there is no way to tell
///   whether it was actually installed, to open it programmatically, or to
///   report its state when something on the machine hides it. During development
///   the item did not appear and there was no way to find out why.
/// - Everything else in this app is already AppKit windows, so the popover and
///   the pinned panel now share one lifecycle story.
///
/// The label is drawn with an `NSAttributedString` and a template image so the
/// menu bar renders it with the same vibrancy and metrics as the system items
/// beside it.
@MainActor
public final class StatusItemController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let coordinator: AppCoordinator
    private var hosting: NSHostingController<AnyView>?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        // `variableLength` lets the ratio widen as the fleet grows; a fixed
        // width would clip a four-digit count.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Template rendering so the glyph adapts to light, dark and the
            // tinted menu bars macOS draws over wallpapers.
            button.imagePosition = .imageLeading
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = makeHostingController()
    }

    private func makeHostingController() -> NSHostingController<AnyView> {
        let controller = NSHostingController(
            rootView: AnyView(PopoverRootView(coordinator: coordinator))
        )
        // Let SwiftUI's ideal size drive the popover, so it is exactly as tall as
        // the host list needs and no taller.
        controller.sizingOptions = [.preferredContentSize]
        hosting = controller
        return controller
    }

    // MARK: - Label

    /// Rebuilds the menu bar label from the current summary.
    public func refreshLabel() {
        guard let button = item.button else { return }
        let summary = coordinator.model.summary
        let isDemo = coordinator.model.isDemoMode
        let idle = summary.enabledHosts == 0

        let text = NSMutableAttributedString(
            string: idle ? "GPU Watch" : "GPU \(summary.menuBarRatio)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if isDemo {
            text.append(NSAttributedString(
                string: " DEMO",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.systemPurple
                ]
            ))
        }

        button.attributedTitle = text
        button.image = NSImage(
            systemSymbolName: symbol(summary: summary, idle: idle),
            accessibilityDescription: nil
        )
        button.image?.isTemplate = true
        button.toolTip = tooltip(summary: summary, idle: idle, isDemo: isDemo)
        button.setAccessibilityLabel(accessibilityLabel(summary: summary, idle: idle))
    }

    private func symbol(summary: FleetSummary, idle: Bool) -> String {
        if idle { return "rectangle.stack" }
        if coordinator.model.isRefreshing, summary.readableGPUs == 0 {
            return "arrow.triangle.2.circlepath"
        }
        if summary.isFullyHealthy { return "checkmark.circle.fill" }
        if summary.missingGPUs > 0 || summary.reachableHosts < summary.enabledHosts {
            return "exclamationmark.triangle.fill"
        }
        return "questionmark.circle.fill"
    }

    private func tooltip(summary: FleetSummary, idle: Bool, isDemo: Bool) -> String {
        guard !idle else { return "GPU Watch — no hosts configured yet" }
        var lines = [summary.tooltip]
        if isDemo { lines.append("Demo mode — no server is being contacted") }
        lines.append("")
        lines.append(DS.healthScopeNote)
        return lines.joined(separator: "\n")
    }

    private func accessibilityLabel(summary: FleetSummary, idle: Bool) -> String {
        guard !idle else { return "GPU Watch, no hosts configured" }
        var parts = [
            "GPU Watch",
            "\(summary.readableGPUs) of \(summary.expectedGPUs) GPUs readable"
        ]
        if summary.unknownGPUs > 0 { parts.append("\(summary.unknownGPUs) unknown") }
        if summary.missingGPUs > 0 { parts.append("\(summary.missingGPUs) missing") }
        if summary.staleHosts > 0 { parts.append("\(summary.staleHosts) hosts stale") }
        if summary.isFullyHealthy { parts.append("all healthy") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    /// Opens the popover. Exposed so the diagnostics mode can present the real
    /// popover for inspection — clicking a menu bar item is not scriptable here.
    public func presentPopover() {
        guard !popover.isShown else { return }
        showPopover()
    }

    /// Where the popover is on screen, for troubleshooting.
    public var popoverFrameDescription: String {
        guard let window = popover.contentViewController?.view.window else {
            return "popover: not presented"
        }
        let frame = window.frame
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        let origin = "(\(Int(frame.minX)), \(Int(frame.minY)))"
        return "popover: \(size) at \(origin)"
    }

    private func showPopover() {
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover to the front without stealing focus from the app the
        // operator was using.
        popover.contentViewController?.view.window?.makeKey()
    }

    public var isInstalled: Bool { item.button != nil }

    /// A short description used by diagnostics, so "the icon is not there" can
    /// be told apart from "the icon is installed but hidden".
    public var diagnostics: String {
        guard let button = item.button else { return "menu bar item: not installed" }
        let frame = button.window?.frame ?? .zero
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        let origin = "(\(Int(frame.minX)), \(Int(frame.minY)))"
        let hidden = button.window?.isVisible == true ? "on screen" : "not on screen"
        return "menu bar item: installed, \(size) at \(origin), \(hidden)"
    }

    public func remove() {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
    }
}
