import SwiftUI
import GPUWatchCore

/// Named views for the visual QA harness.
///
/// These are the *real* view types used by the app, driven by a real `AppModel`
/// in demo mode. Nothing here reimplements a screen, so what the harness renders
/// is what the menu bar shows.
public enum SnapshotScenarios {
    public struct Scenario {
        public let name: String
        public let size: CGSize
        public let view: AnyView
        /// Set for screens that should be captured over an opaque background
        /// rather than the transparent material the window supplies.
        public let opaqueBackground: Bool
        /// Scroll the body to its end before capturing, so content below the
        /// fold can be inspected.
        public let scrollToBottom: Bool

        public init(
            name: String,
            size: CGSize,
            view: AnyView,
            opaqueBackground: Bool,
            scrollToBottom: Bool = false
        ) {
            self.name = name
            self.size = size
            self.view = view
            self.opaqueBackground = opaqueBackground
            self.scrollToBottom = scrollToBottom
        }
    }

    /// Size of the popover as rendered by the harness.
    public static var popoverSize: CGSize {
        CGSize(width: DS.popoverWidth, height: 620)
    }

    /// The popover, for the harness to render frame by frame.
    ///
    /// A narrow accessor rather than exposing `PopoverRootView` itself: only the
    /// QA harness needs to reach the view layer directly.
    @MainActor
    public static func popoverView(coordinator: AppCoordinator) -> AnyView {
        AnyView(PopoverRootView(coordinator: coordinator))
    }

    /// A coordinator backed by a throwaway store, already in demo mode.
    @MainActor
    public static func makeDemoCoordinator(
        state: SnapshotState = SnapshotState(),
        commands: SSHCommandRunning? = nil
    ) -> AppCoordinator {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpuwatch-snapshot-\(UUID().uuidString)", isDirectory: true)
        var model = AppModel(
            store: ConfigurationStore(directory: directory),
            // The harness is not a bundled app, so it must never reach for the
            // notification centre.
            deliverer: NoopNotificationDeliverer()
        )
        if let commands {
            model = AppModel(
                store: ConfigurationStore(directory: directory),
                commands: commands,
                deliverer: NoopNotificationDeliverer()
            )
        }
        let coordinator = AppCoordinator(model: model)
        coordinator.model.start()
        apply(state, to: coordinator)
        return coordinator
    }

    /// A live-mode fleet for the harness, with a runner that never executes
    /// anything. Live mode is here to show the *no data yet* state, which is
    /// reached with real hosts and no answers.
    public struct InertRunner: SSHCommandRunning {
        public init() {}
        public func run(
            target: SSHTarget,
            remoteCommand: String,
            timeout: TimeInterval,
            maxOutputBytes: Int
        ) async throws -> SSHCommandResult {
            SSHCommandResult(
                terminationStatus: 255,
                stdout: "",
                stderr: "ssh: Could not resolve hostname \(target.destination): nodename nor servname provided",
                duration: 0.01
            )
        }
        public func terminateAll() {}
    }

    public static func liveHosts() -> [HostConfig] {
        [
            HostConfig(displayName: "dgx-prod-01", destination: "dgx-prod-01", username: "ops", expectedGPUCount: 8),
            HostConfig(displayName: "dgx-prod-02", destination: "dgx-prod-02", username: "ops", expectedGPUCount: 8),
            HostConfig(
                displayName: "a-very-long-production-hostname-01",
                destination: "gpu-node-with-a-long-name", username: "ml",
                expectedGPUCount: 4
            ),
            HostConfig(
                displayName: "reserved-04", destination: "reserved-04",
                expectedGPUCount: 4, enabled: false
            )
        ]
    }

    /// Knobs the harness uses to reach states that demo mode does not show by
    /// default, such as an expanded host or an open editor.
    public struct SnapshotState {
        public var expandedHostName: String?
        public var editingHost: HostConfig?
        public var isCreatingHost = false
        public var showSettings = false
        public var extraEntries: [DemoFixtures.Entry] = []
        /// Real hosts added in live mode. Only used by the harness, with an
        /// inert runner, to reach the "configured but no data" state.
        public var liveHosts: [HostConfig] = []
        public var demo = true

        public init() {}
    }

    @MainActor
    public static func apply(_ state: SnapshotState, to coordinator: AppCoordinator) {
        for host in state.liveHosts {
            coordinator.model.addHost(host)
        }
        coordinator.model.setDemoMode(state.demo)
        if state.demo, !state.extraEntries.isEmpty {
            coordinator.model.setDemoFleet(
                DemoFixtures.entries + state.extraEntries
            )
        }

        if let name = state.expandedHostName,
           let report = coordinator.model.visibleReports.first(where: {
               $0.host.effectiveName.hasPrefix(name)
           }) {
            coordinator.ui.expandedHostID = report.id
        }
        if let editing = state.editingHost {
            coordinator.ui.editingHost = editing
            coordinator.ui.isCreatingHost = state.isCreatingHost
        }
        coordinator.ui.isSettingsPresented = state.showSettings
    }

    @MainActor
    public static func scenarios() -> [Scenario] {
        var list: [Scenario] = []

        list.append(Scenario(
            name: "01-popover-demo",
            size: CGSize(width: DS.popoverWidth, height: 560),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator())),
            opaqueBackground: true
        ))

        var emptyFleet = SnapshotState()
        emptyFleet.demo = false
        list.append(Scenario(
            name: "05-empty-state",
            size: CGSize(width: DS.popoverWidth, height: 400),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: emptyFleet))),
            opaqueBackground: true
        ))

        var expanded = SnapshotState()
        expanded.expandedHostName = "5090-2"
        list.append(Scenario(
            name: "02-popover-expanded-missing-gpu",
            size: CGSize(width: DS.popoverWidth, height: 700),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: expanded))),
            opaqueBackground: true
        ))
        var noBaseline = SnapshotState()
        noBaseline.expandedHostName = "H200-01"
        list.append(Scenario(
            name: "02d-popover-actions-no-baseline",
            size: CGSize(width: DS.popoverWidth, height: 700),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: noBaseline))),
            opaqueBackground: true,
            scrollToBottom: true
        ))
        list.append(Scenario(
            name: "02c-popover-host-actions",
            size: CGSize(width: DS.popoverWidth, height: 700),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: expanded))),
            opaqueBackground: true,
            scrollToBottom: true
        ))
        list.append(Scenario(
            name: "02b-popover-expanded-scrolled",
            size: CGSize(width: DS.popoverWidth, height: 700),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: expanded))),
            opaqueBackground: true,
            scrollToBottom: true
        ))

        var manyHosts = SnapshotState()
        manyHosts.extraEntries = DemoFixtures.fillerEntries(
            count: 14,
            expectedGPUs: 16,
            namePrefix: "gpu-node-with-an-absurdly-long-production-name-for-truncation-check"
        )
        list.append(Scenario(
            name: "03-popover-many-hosts-and-long-names",
            size: CGSize(width: DS.popoverWidth, height: 900),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: manyHosts))),
            opaqueBackground: true
        ))

        var wide = SnapshotState()
        wide.extraEntries = DemoFixtures.fillerEntries(
            count: 1, expectedGPUs: 16, namePrefix: "16x-H200-wide"
        )
        wide.expandedHostName = "16x-H200"
        list.append(Scenario(
            name: "04-popover-many-gpus-expanded",
            size: CGSize(width: DS.popoverWidth, height: 700),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(state: wide))),
            opaqueBackground: true
        ))

        var editing = SnapshotState()
        editing.editingHost = HostConfig(
            displayName: "dgx-prod-01",
            destination: "dgx-prod-01",
            username: "ops",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            expectedGPUCount: 8,
            temperatureWarningThreshold: 85
        )
        list.append(Scenario(
            name: "06-host-editor",
            size: CGSize(width: 520, height: 560),
            view: AnyView(HostEditorView(
                coordinator: makeDemoCoordinator(state: editing),
                draft: editing.editingHost!,
                isCreating: false
            )),
            opaqueBackground: true
        ))

        list.append(Scenario(
            name: "07-settings",
            size: CGSize(width: 460, height: 600),
            view: AnyView(SettingsView(coordinator: makeDemoCoordinator())),
            opaqueBackground: true
        ))
        list.append(Scenario(
            name: "07b-settings-scrolled",
            size: CGSize(width: 460, height: 600),
            view: AnyView(SettingsView(coordinator: makeDemoCoordinator())),
            opaqueBackground: true,
            scrollToBottom: true
        ))
        list.append(Scenario(
            name: "07c-settings-small-window",
            size: CGSize(width: 430, height: 320),
            view: AnyView(SettingsView(coordinator: makeDemoCoordinator())),
            opaqueBackground: true
        ))

        list.append(Scenario(
            name: "08-pinned-panel",
            size: CGSize(width: DS.panelWidth, height: 380),
            view: AnyView(FloatingPanelView(coordinator: makeDemoCoordinator())),
            opaqueBackground: true
        ))

        var live = SnapshotState()
        live.demo = false
        live.liveHosts = SnapshotScenarios.liveHosts()
        list.append(Scenario(
            name: "09-live-mode-no-data",
            size: CGSize(width: DS.popoverWidth, height: 460),
            view: AnyView(PopoverRootView(coordinator: makeDemoCoordinator(
                state: live,
                commands: InertRunner()
            ))),
            opaqueBackground: true
        ))

        return list
    }

}
