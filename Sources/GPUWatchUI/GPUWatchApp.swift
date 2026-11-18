import AppKit
import SwiftUI
import GPUWatchCore

/// Entry point for the `GPUWatch` executable.
///
/// The app itself is a library so the snapshot harness can render the same views.
public enum GPUWatchUI {
    public static func runApplication() {
        // `main.swift` top-level code runs on the main thread, so the
        // main-actor diagnostics entry points can be called directly.
        if CommandLine.arguments.contains("--show-popover") {
            MainActor.assumeIsolated { Diagnostics.runShowPopover() }
        }
        if CommandLine.arguments.contains("--show-settings") {
            MainActor.assumeIsolated {
                Diagnostics.runShowWindow(.settings, stayOpenSeconds: 25)
            }
        }
        if CommandLine.arguments.contains("--show-editor") {
            MainActor.assumeIsolated {
                Diagnostics.runShowWindow(.hostEditor, stayOpenSeconds: 25)
            }
        }
        if CommandLine.arguments.contains("--diagnose") {
            MainActor.assumeIsolated { Diagnostics.runAndExit() }
        }
        if let hostArgument = Diagnostics.checkArgument {
            MainActor.assumeIsolated { Diagnostics.runCheck(hostArgument) }
        }
        GPUWatchApp.main()
    }
}

struct GPUWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item and its popover are AppKit objects owned by the
        // delegate (see `StatusItemController`). A scene is still required to
        // install the app, so this one exists but shows no window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private var statusItem: StatusItemController?
    private var labelTimer: Timer?
    private var lastLabel: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberately no `setActivationPolicy` call: `LSUIElement` in
        // Info.plist already makes this an accessory app, and changing the
        // policy after launch tears down menu bar state that was just set up.
        ProcessInfo.processInfo.disableAutomaticTermination("GPU Watch polls in the background")

        coordinator.start()

        let controller = StatusItemController(coordinator: coordinator)
        statusItem = controller
        updateLabel(force: true)

        // The menu bar is an AppKit surface, so it is refreshed by a timer rather
        // than by SwiftUI's observation. Once a second is far cheaper than the
        // 30-second poll and keeps the count honest while a check is running.
        labelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateLabel(force: false)
            }
        }
    }

    private func updateLabel(force: Bool) {
        let signature = labelSignature
        guard force || signature != lastLabel else { return }
        lastLabel = signature
        statusItem?.refreshLabel()
    }

    /// Everything the menu bar label depends on. Updating only when this changes
    /// keeps the status bar from redrawing every second for no reason.
    private var labelSignature: String {
        let summary = coordinator.model.summary
        return [
            String(summary.readableGPUs),
            String(summary.expectedGPUs),
            String(summary.missingGPUs),
            String(summary.unknownGPUs),
            String(summary.staleHosts),
            String(summary.reachableHosts),
            String(summary.enabledHosts),
            String(summary.warningGPUs),
            String(coordinator.model.isDemoMode),
            String(coordinator.model.isRefreshing)
        ].joined(separator: "|")
    }

    func applicationWillTerminate(_ notification: Notification) {
        labelTimer?.invalidate()
        labelTimer = nil
        statusItem?.remove()
        // Cancels the poll loop and ends every ssh child still running.
        coordinator.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Diagnostics

/// `GPUWatch --diagnose` prints the facts needed to tell a configuration problem
/// from an environment one — most usefully, whether the menu bar item exists.
///
/// It runs long enough to install the status item and read back its geometry,
/// then exits without polling.
enum Diagnostics {
    /// Diagnostics go to stderr, which is unbuffered. Standard output is block
    /// buffered when redirected, and a diagnostic that is lost because the
    /// process was interrupted is worse than no diagnostic.
    static func report(_ lines: [String]) {
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// `GPUWatch --show-popover` installs the menu bar item, opens the popover
    /// and stays open.
    ///
    /// Shows whatever the app would really show: the configured hosts in live
    /// mode, or the demo fleet when nothing is configured yet. The menu bar item
    /// cannot be clicked by a script, so this is the only way to inspect the real
    /// popover — its sizing, anchoring and material — rather than the view in
    /// isolation.
    @MainActor
    static func runShowPopover() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let coordinator = AppCoordinator()
        coordinator.model.start()
        if coordinator.model.hosts.isEmpty {
            coordinator.model.setDemoMode(true)
        } else {
            // Give a live check time to land before the popover is presented.
            // The run loop must keep spinning: the refresh is main-actor work, so
            // blocking the main thread here would deadlock instead of waiting.
            Task { @MainActor in await coordinator.model.refreshNow() }
            var waited: TimeInterval = 0
            while coordinator.model.lastRefreshCompletedAt == nil, waited < 25 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                waited += 0.1
            }
        }

        let statusItem = StatusItemController(coordinator: coordinator)
        statusItem.refreshLabel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        statusItem.presentPopover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        report([statusItem.diagnostics, statusItem.popoverFrameDescription])

        // Stay open long enough for an external capture.
        RunLoop.current.run(until: Date().addingTimeInterval(25))
        statusItem.remove()
        coordinator.stop()
        exit(0)
    }

    /// `GPUWatch --check <host>` runs one real check against one host and prints
    /// the staged result, then exits.
    ///
    /// This is the same path the Test Connection button and the poller use, so a
    /// green result here means the app will work against that host. It reads the
    /// operator's existing SSH configuration, runs only the fixed `nvidia-smi`
    /// query, and writes nothing to the configuration store.
    static var checkArgument: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--check"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    @MainActor
    static func runCheck(_ destination: String) -> Never {
        let arguments = CommandLine.arguments
        var expectedGPUs = 0
        if let index = arguments.firstIndex(of: "--expected"), index + 1 < arguments.count {
            expectedGPUs = Int(arguments[index + 1]) ?? 0
        }

        let host = HostConfig(
            displayName: destination,
            destination: destination,
            expectedGPUCount: expectedGPUs,
            enabled: true
        )

        report(["GPU Watch live check", "target: \(host.userFacingTarget)"])

        let tester = ConnectionTester(commands: SSHProcessRunner())
        let result = runBlocking { await tester.test(host, now: Date()) }

        report([
            "",
            "stage: \(result.stage.label)",
            "ssh reachable: \(result.sshReachable ? "yes" : "no")",
            "summary: \(result.summary)"
        ])
        if !result.detail.isEmpty {
            report(["detail: \(result.detail)"])
        }
        if let count = result.gpuCount {
            report(["gpus found: \(count)"])
        }
        if !result.samples.isEmpty {
            report(["", "index  uuid                                            temp   util   vram          model"])
            for sample in result.samples {
                let index = sample.index.map(String.init) ?? "?"
                let uuid = sample.uuid ?? "(no uuid)"
                let temperature = sample.temperatureCelsius.map { "\(Int($0))C" } ?? "N/A"
                let utilization = sample.utilizationPercent.map { "\(Int($0))%" } ?? "N/A"
                let memory: String
                if let used = sample.memoryUsedMiB, let total = sample.memoryTotalMiB {
                    memory = "\(Int(used))/\(Int(total)) MiB"
                } else {
                    memory = "N/A"
                }
                report(["\(index.padding(toLength: 6, withPad: " ", startingAt: 0))"
                    + " \(uuid.padding(toLength: 46, withPad: " ", startingAt: 0))"
                    + " \(temperature.padding(toLength: 6, withPad: " ", startingAt: 0))"
                    + " \(utilization.padding(toLength: 6, withPad: " ", startingAt: 0))"
                    + " \(memory.padding(toLength: 13, withPad: " ", startingAt: 0))"
                    + " \(sample.model ?? "—")"])
            }
        }

        // The evaluator decides what the app would actually show, including with
        // no baseline registered — which is the state a new host starts in.
        let report0 = runBlocking {
            GPUStateEvaluator().evaluate(
                host: host,
                baseline: nil,
                probe: HostProbeResult(
                    ssh: result.sshReachable ? .ok : .failed(kind: .unreachable, detail: result.detail),
                    query: result.stage == .success
                        ? .ok(samples: result.samples, partialWarnings: [])
                        : .failed(reason: .commandFailed, detail: result.detail),
                    attemptedAt: Date(),
                    transportConfirmed: result.sshReachable,
                    queryWasComplete: result.stage == .success
                ),
                previous: nil,
                settings: PollSettings(),
                now: Date()
            )
        }
        report([
            "",
            "what the list would show:",
            "  state: \(report0.displayState.label)",
            "  ratio: \(report0.ratioDisplay)",
            "  readable: \(report0.counts.readable)  missing: \(report0.counts.missing)"
                + "  unknown: \(report0.counts.unknown)  warnings: \(report0.counts.warnings)",
            "  detail line: \(report0.statusDetail ?? "—")"
        ])
        exit(0)
    }

    /// Bridges a *non-isolated* async call into the synchronous diagnostic path.
    ///
    /// Blocks the calling thread, so the operation must not need the main actor
    /// — blocking it would deadlock rather than wait. Main-actor work is driven
    /// by spinning the run loop instead (see the refresh in `runShowPopover`).
    static func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            let value = await operation()
            result = value
            semaphore.signal()
        }
        semaphore.wait()
        // Safe: the semaphore guarantees the write happened-before this read.
        return result!
    }

    enum WindowKind { case settings, hostEditor }

    /// Opens one of the ordinary windows so it can be inspected or captured.
    ///
    /// Same reason as `--show-popover`: nothing in a menu bar app can be reached
    /// by a script, so the only honest way to verify a real window is to ask the
    /// app to open it.
    @MainActor
    static func runShowWindow(_ kind: WindowKind, stayOpenSeconds: TimeInterval) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let coordinator = AppCoordinator()
        coordinator.model.start()
        coordinator.model.setDemoMode(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        switch kind {
        case .settings:
            coordinator.openSettings()
        case .hostEditor:
            if let report = coordinator.model.visibleReports.first(where: {
                $0.host.effectiveName.hasPrefix("5090-2")
            }) {
                coordinator.beginEdit(report.host)
            }
        }

        // Let the window be created and composited before reporting its frame.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        report([coordinator.windowDiagnostics()])

        RunLoop.current.run(until: Date().addingTimeInterval(stayOpenSeconds))
        coordinator.stop()
        exit(0)
    }

    @MainActor
    static func runAndExit() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let coordinator = AppCoordinator()
        coordinator.model.start()
        let statusItem = StatusItemController(coordinator: coordinator)
        statusItem.refreshLabel()

        // Let AppKit place the item before reading its frame back.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let configuration = coordinator.model.settings
        var lines: [String] = [
            "GPU Watch diagnostics",
            "bundle identifier: \(Bundle.main.bundleIdentifier ?? "(no bundle)")",
            "bundle path: \(Bundle.main.bundlePath)",
            "menu bar accessory: \(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") != nil ? "yes (LSUIElement set)" : "not declared")",
            "status item: \(statusItem.diagnostics)",
            "storage folder: \(coordinator.model.configurationFolderPath)",
            "hosts configured: \(coordinator.model.hosts.count)",
            "poll interval: \(configuration.intervalSeconds)s",
            "concurrency limit: \(configuration.maxConcurrentChecks)",
            "ssh executable: \(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") ? "present at /usr/bin/ssh" : "MISSING")"
        ]
        if coordinator.model.hosts.isEmpty {
            lines.append("note: no hosts configured, so the menu bar shows \"GPU Watch\"")
        }
        statusItem.remove()
        coordinator.stop()

        report(lines)
        exit(0)
    }
}
