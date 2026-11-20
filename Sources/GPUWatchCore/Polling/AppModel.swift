import AppKit
import Foundation
import Observation

/// The single source of truth for the menu bar, the popover and the floating
/// panel.
///
/// There is one instance. Every window reads from it and none of them owns a
/// timer, which is what keeps "pin the panel" from doubling the poll rate.
/// All mutation happens on the main actor, so the UI never observes a
/// half-updated fleet; the only work that leaves the main actor is the ssh
/// probe itself.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Persisted state

    public private(set) var hosts: [HostConfig] = []
    public private(set) var settings = PollSettings()
    public private(set) var baselines = BaselineFile()

    // MARK: - Runtime state

    /// Current picture per host, keyed by host UUID.
    public private(set) var reports: [UUID: HostReport] = [:]
    /// `true` while a round is in progress, for the Refresh button.
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshCompletedAt: Date?
    /// Files we could not read. Surfaced as a banner; never silently discarded.
    public private(set) var storeIssues: [StoreIssue] = []
    public private(set) var isDemoMode = false
    /// Set when notification permission was refused, so the toggle can explain
    /// itself rather than appearing broken.
    public private(set) var notificationPermissionDenied = false

    // MARK: - Collaborators

    private let store: ConfigurationStore
    private let evaluator: GPUStateEvaluator
    private let probeRunner: HostProbeRunner
    private let tester: ConnectionTester
    private let notifications: NotificationService
    private let deliverer: NotificationDelivering
    private let clock: Clock
    private let commands: SSHCommandRunning

    // MARK: - Scheduling state

    private var loopTask: Task<Void, Never>?
    private var roundTask: Task<Void, Never>?
    /// Hosts with a check in flight. Prevents overlapping work for one host.
    private var inFlight: Set<UUID> = []
    /// Monotonic per-host counter. Bumped whenever a host changes, so a result
    /// that arrives after an edit or delete is discarded instead of overwriting
    /// newer state.
    private var generations: [UUID: Int] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var started = false
    /// Set while a mutation-triggered refresh is running or queued.
    private var mutationRefreshTask: Task<Void, Never>?
    /// Counts refresh requests that arrived while a round was in progress.
    private var pendingRefreshRequests = 0

    public init(
        store: ConfigurationStore = ConfigurationStore(),
        commands: SSHCommandRunning = SSHProcessRunner(),
        clock: Clock = SystemClock(),
        notifications: NotificationService = NotificationService(),
        deliverer: NotificationDelivering? = nil
    ) {
        self.store = store
        self.commands = commands
        self.clock = clock
        self.notifications = notifications
        self.deliverer = deliverer ?? UserNotificationDeliverer()
        self.evaluator = GPUStateEvaluator()
        self.probeRunner = HostProbeRunner(commands: commands)
        self.tester = ConnectionTester(commands: commands)
    }

    // MARK: - Lifecycle

    /// Loads persisted state and starts the single polling loop.
    public func start() {
        guard !started else { return }
        started = true

        let configuration = store.loadConfiguration()
        hosts = configuration.hosts
        settings = configuration.settings.normalized
        baselines = store.loadBaselines()
        storeIssues = store.currentIssues

        seedsReportsFromLastKnown()
        ensureReportsExist()
        observeWake()

        // Demo mode is chosen by the user and is not persisted; a fresh launch
        // always starts in live mode with the operator's real hosts.
        startLoop()
    }

    /// Cancels polling and ends any ssh child still running.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        roundTask?.cancel()
        roundTask = nil
        commands.terminateAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Derived presentation state

    /// Reports in the same order as `hosts`, so the list does not reshuffle.
    public var orderedReports: [HostReport] {
        hosts.compactMap { reports[$0.id] }
    }

    /// The rows the popover should show, in display order.
    ///
    /// Demo mode reads from its own host list, so the operator's saved hosts are
    /// left exactly as they were.
    public var visibleReports: [HostReport] {
        let order = isDemoMode ? demoHostIDs : hosts.map(\.id)
        return order.compactMap { reports[$0] }
    }

    private var demoHostIDs: [UUID] = []
    /// The synthetic fleet currently on screen. Held so a refresh regenerates
    /// what is being shown rather than resetting to the default set.
    private var demoEntries: [DemoFixtures.Entry] = DemoFixtures.entries

    public var summary: FleetSummary {
        FleetSummary.make(from: visibleReports)
    }

    public var isEmpty: Bool { visibleReports.isEmpty }

    // MARK: - Polling

    private func startLoop() {
        loopTask?.cancel()
        let interval = Double(settings.intervalSeconds)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runRound()
                do {
                    try await self.clock.sleep(seconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Immediate check of every enabled host.
    ///
    /// If a round is already running this simply waits for it, so a burst of
    /// Refresh clicks cannot multiply the work.
    public func refreshNow() async {
        // A refresh a mutation already asked for takes priority, so an edit is
        // never observed against a stale target list.
        if let pending = mutationRefreshTask {
            await pending.value
        }
        await runRound()
    }

    /// Requests a check after a configuration change, coalescing bursts.
    ///
    /// Ten hosts added in a row should produce one round, not ten. The request
    /// counter is re-checked after each round so a change made *during* a round
    /// still gets its own pass.
    private func scheduleRefresh() {
        pendingRefreshRequests += 1
        guard mutationRefreshTask == nil else { return }
        mutationRefreshTask = Task { [weak self] in
            guard let self else { return }
            while self.pendingRefreshRequests > 0 {
                self.pendingRefreshRequests = 0
                await self.runRound()
            }
            self.mutationRefreshTask = nil
        }
    }

    private func runRound() async {
        if let existing = roundTask {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRound()
        }
        roundTask = task
        await task.value
    }

    private func performRound() async {
        defer {
            roundTask = nil
            isRefreshing = false
        }
        isRefreshing = true

        guard !isDemoMode else {
            // Demo data is recomputed locally and never leaves the machine.
            applyDemoFleet()
            lastRefreshCompletedAt = clock.now
            return
        }

        let targets = hosts.filter(\.enabled).map(\.id)
        let generationSnapshot = generations

        await withBoundedConcurrency(limit: max(1, settings.maxConcurrentChecks), items: targets) { [weak self] hostID in
            guard let self else { return }
            await self.performCheck(hostID: hostID, generation: generationSnapshot[hostID] ?? 0)
        }

        lastRefreshCompletedAt = clock.now
        saveLastKnown()
        await dispatchNotifications()
    }

    /// Runs `items` through `operation` with at most `limit` in flight.
    ///
    /// A task group with a rolling window, rather than starting one task per
    /// host: a 200-host fleet must not spawn 200 concurrent ssh children.
    private func withBoundedConcurrency<T: Sendable>(
        limit: Int,
        items: [T],
        operation: @escaping @Sendable (T) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let initial = min(limit, items.count)
            while next < initial {
                let item = items[next]
                next += 1
                group.addTask { await operation(item) }
            }
            while await group.next() != nil {
                guard next < items.count else { continue }
                let item = items[next]
                next += 1
                group.addTask { await operation(item) }
            }
        }
    }

    /// Runs one host check and applies the result.
    ///
    /// Internal rather than private so tests can drive a single check and place
    /// a mutation exactly while it is in flight.
    func performCheck(hostID: UUID, generation: Int) async {
        guard let host = hosts.first(where: { $0.id == hostID }) else { return }
        guard !inFlight.contains(hostID) else { return }
        inFlight.insert(hostID)
        defer { inFlight.remove(hostID) }

        // Show "Checking…" without disturbing the numbers already on screen.
        if let existing = reports[hostID] {
            reports[hostID] = existing.markingChecking()
        } else {
            reports[hostID] = HostReport(
                host: host,
                ssh: .checking,
                query: .notAttempted,
                freshness: .unknown,
                gpus: [],
                counts: GPUCounts(expected: host.expectedGPUCount, unknown: 0),
                lastAttemptedAt: clock.now,
                neverChecked: true
            )
        }

        let attemptedAt = clock.now
        let probe = await probeRunner.probe(host: host, now: attemptedAt)

        // The host may have been edited or deleted while ssh was running. A
        // result computed against the old configuration must not land.
        //
        // The default must be read the same way it was when the round started:
        // a host loaded from disk has no entry in `generations`, and comparing
        // `nil` against `0` would discard every result for it, leaving the row
        // stuck on "Checking…" forever.
        guard !isDemoMode,
              let current = hosts.first(where: { $0.id == hostID }),
              (generations[hostID] ?? 0) == generation
        else { return }

        let report = evaluator.evaluate(
            host: current,
            baseline: baselines.baseline(for: hostID),
            probe: probe,
            previous: reports[hostID],
            settings: settings,
            now: clock.now
        )
        reports[hostID] = report
    }

    private func dispatchNotifications() async {
        guard settings.notificationsEnabled, !isDemoMode else { return }
        let pending = notifications.evaluate(reports: orderedReports, now: clock.now)
        guard !pending.isEmpty else { return }
        await deliverer.deliver(pending)
    }

    // MARK: - Wake handling

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    /// After a sleep, timestamps can still look recent while nothing has been
    /// verified. Everything is demoted to stale and re-checked immediately.
    private func handleWake() {
        for (id, report) in reports {
            reports[id] = report.markedStale(reason: "Not re-checked since wake")
        }
        scheduleRefresh()
    }

    // MARK: - Host management

    public func addHost(_ host: HostConfig) {
        hosts.append(host)
        bumpGeneration(for: host.id)
        ensureReportsExist()
        persistConfiguration()
        scheduleRefresh()
    }

    public func updateHost(_ host: HostConfig) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        // Any in-flight result for this host is now describing a configuration
        // that no longer exists.
        bumpGeneration(for: host.id)
        notifications.forget(hostID: host.id)
        reports[host.id] = nil
        ensureReportsExist()
        persistConfiguration()
        scheduleRefresh()
    }

    public func deleteHost(id: UUID) {
        hosts.removeAll { $0.id == id }
        bumpGeneration(for: id)
        notifications.forget(hostID: id)
        reports[id] = nil
        baselines.removeBaseline(for: id)
        try? store.saveBaselines(baselines)
        persistConfiguration()
        var lastKnown = store.loadLastKnown()
        lastKnown.removeSnapshot(for: id)
        try? store.saveLastKnown(lastKnown)
    }

    public func moveHosts(fromOffsets: IndexSet, toOffset destination: Int) {
        hosts = Self.reordering(hosts, moving: fromOffsets, to: destination)
        persistConfiguration()
    }

    /// Reorder matching the semantics SwiftUI's `onMove` expects.
    ///
    /// Implemented here rather than using `MutableCollection.move` because that
    /// helper lives in SwiftUI, and the core module deliberately has no UI
    /// dependency so its logic stays testable on its own.
    static func reordering<T>(_ items: [T], moving source: IndexSet, to destination: Int) -> [T] {
        let indices = source.sorted()
        let moving = indices.map { items[$0] }
        var remainder: [T] = []
        remainder.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() where !source.contains(offset) {
            remainder.append(item)
        }
        // Positions removed before the destination shift it left.
        let shift = indices.filter { $0 < destination }.count
        let insertion = max(0, min(destination - shift, remainder.count))
        remainder.insert(contentsOf: moving, at: insertion)
        return remainder
    }

    public func setEnabled(_ enabled: Bool, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].enabled = enabled
        bumpGeneration(for: hostID)
        notifications.forget(hostID: hostID)
        reports[hostID] = nil
        ensureReportsExist()
        persistConfiguration()
    }

    private func bumpGeneration(for hostID: UUID) {
        generations[hostID] = (generations[hostID] ?? 0) + 1
    }

    /// The generation a check must still match for its result to be applied.
    func currentGeneration(for hostID: UUID) -> Int {
        generations[hostID] ?? 0
    }

    /// Gives every configured host a row, even one that has never been checked.
    ///
    /// Without this a disabled host — or a host added while a check was in
    /// flight — vanishes from the list entirely, and the operator cannot tell
    /// whether it is disabled or gone.
    private func ensureReportsExist() {
        for host in hosts where reports[host.id] == nil {
            reports[host.id] = evaluator.evaluate(
                host: host,
                baseline: baselines.baseline(for: host.id),
                probe: HostProbeResult.notAttempted(at: clock.now),
                previous: nil,
                settings: settings,
                now: clock.now
            )
        }
    }

    // MARK: - Settings

    public func updateSettings(_ newValue: PollSettings) {
        let normalized = newValue.normalized
        let intervalChanged = normalized.intervalSeconds != settings.intervalSeconds
        settings = normalized
        if intervalChanged, !isDemoMode {
            startLoop()
        }
        persistConfiguration()
    }

    public func setNotificationsEnabled(_ enabled: Bool) async {
        var updated = settings
        updated.notificationsEnabled = enabled
        settings = updated
        persistConfiguration()

        if enabled, !isDemoMode {
            let granted = await deliverer.requestAuthorization()
            notificationPermissionDenied = !granted
        } else {
            notificationPermissionDenied = false
            // Stopping alerts must also stop pending streaks, or re-enabling
            // would fire immediately on a stale observation.
            notifications.forgetAll()
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        var updated = settings
        updated.launchAtLogin = enabled
        settings = updated
        persistConfiguration()
    }

    public func dismissStoreIssues() {
        store.clearIssues()
        storeIssues = []
    }

    public func revealConfigurationFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.configurationURL])
    }

    public var configurationFolderPath: String { store.directory.path }

    // MARK: - Baselines

    /// Records the currently readable GPUs as the accepted set.
    ///
    /// Always driven by an explicit user action after reviewing what was found;
    /// a missing or replaced GPU never rewrites the baseline on its own.
    public func registerBaseline(hostID: UUID) {
        guard let report = reports[hostID], report.query.isOK else { return }
        let uuids = report.query.samples.compactMap(\.uuid)
        guard !uuids.isEmpty || report.counts.expected == 0 else { return }

        let baseline = HostBaseline(
            hostID: hostID,
            gpuUUIDs: uuids,
            expectedCount: max(report.counts.expected, uuids.count),
            registeredAt: clock.now
        )
        baselines.baselines[hostID.uuidString] = baseline
        try? store.saveBaselines(baselines)
        bumpGeneration(for: hostID)
        // A baseline change is bookkeeping, not a health event, so alert state
        // is reset without emitting a recovery.
        notifications.forget(hostID: hostID)
        scheduleRefresh()
    }

    public func removeBaseline(hostID: UUID) {
        baselines.removeBaseline(for: hostID)
        try? store.saveBaselines(baselines)
        bumpGeneration(for: hostID)
        notifications.forget(hostID: hostID)
        scheduleRefresh()
    }

    /// What "Register GPU Baseline" would record, shown for confirmation first.
    public func baselinePreview(hostID: UUID) -> (uuids: [String], expected: Int)? {
        guard let report = reports[hostID], report.query.isOK else { return nil }
        return (report.query.samples.compactMap(\.uuid), report.counts.expected)
    }

    // MARK: - Connection test

    public func testConnection(_ host: HostConfig) async -> ConnectionTestResult {
        await tester.test(host, now: clock.now)
    }

    // MARK: - Demo mode

    /// Switches the whole app to a synthetic fleet.
    ///
    /// Demo data never touches the network and never raises a real
    /// notification, and it is held separately from the operator's
    /// configuration so leaving demo mode restores exactly what was there.
    public func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        isDemoMode = enabled
        reports.removeAll()
        notifications.forgetAll()
        notificationPermissionDenied = false

        if enabled {
            demoEntries = DemoFixtures.entries
            applyDemoFleet()
        } else {
            demoHostIDs = []
            seedsReportsFromLastKnown()
            ensureReportsExist()
        }
        lastRefreshCompletedAt = clock.now
    }

    /// Replaces the synthetic fleet.
    ///
    /// Demo Mode ships one fleet, but the set is swappable so a larger or more
    /// varied one can be shown — a 40-host layout problem is not visible in a
    /// seven-host one. Has no effect outside Demo Mode, so it can never be used
    /// to put synthetic data in front of real hosts.
    public func setDemoFleet(_ entries: [DemoFixtures.Entry]) {
        guard isDemoMode else { return }
        demoEntries = entries
        applyDemoFleet()
    }

    /// Rebuilds reports from the current demo entries. Called on refresh too, so
    /// a custom fleet is not silently replaced by the default one.
    private func applyDemoFleet() {
        let fleetReports = DemoFixtures.reports(for: demoEntries, now: clock.now, settings: settings)
        reports = Dictionary(uniqueKeysWithValues: fleetReports.map { ($0.host.id, $0) })
        demoHostIDs = fleetReports.map(\.host.id)
        lastRefreshCompletedAt = clock.now
    }

    // MARK: - Persistence

    private func persistConfiguration() {
        let configuration = AppConfiguration(hosts: hosts, settings: settings)
        do {
            try store.saveConfiguration(configuration)
        } catch {
            storeIssues = store.currentIssues
        }
    }

    /// Stores the last readable GPU set so a relaunch can show last-known values
    /// instead of an empty window. These are always labelled as carried-forward
    /// and never counted as current.
    private func saveLastKnown() {
        var file = LastKnownFile()
        for report in orderedReports {
            guard report.query.isOK else { continue }
            file.setSnapshot(HostSnapshot(
                hostID: report.host.id,
                lastAttemptedAt: report.lastAttemptedAt,
                lastSuccessfulAt: report.lastSuccessfulAt,
                gpus: report.query.samples.map(GPUSnapshot.init(from:))
            ))
        }
        try? store.saveLastKnown(file)
    }

    private func seedsReportsFromLastKnown() {
        guard !hosts.isEmpty else { return }
        let lastKnown = store.loadLastKnown()
        for host in hosts {
            guard let snapshot = lastKnown.snapshot(for: host.id) else { continue }
            let gpus = snapshot.gpus.map { stored in
                GPUReport(
                    id: stored.uuid ?? "index:\(stored.index.map(String.init) ?? "?")",
                    index: stored.index,
                    uuid: stored.uuid,
                    model: stored.model,
                    temperatureCelsius: stored.temperatureCelsius,
                    temperatureSensor: stored.temperatureSensor,
                    utilizationPercent: stored.utilizationPercent,
                    memoryUsedMiB: stored.memoryUsedMiB,
                    memoryTotalMiB: stored.memoryTotalMiB,
                    health: .unknown(reason: "Last known reading"),
                    isLiveData: false
                )
            }
            reports[host.id] = HostReport(
                host: host,
                ssh: .notAttempted,
                query: .notAttempted,
                freshness: .unknown,
                gpus: gpus,
                counts: GPUCounts(
                    expected: baselines.baseline(for: host.id)?.expectedCount ?? host.expectedGPUCount,
                    readable: 0,
                    warnings: 0,
                    missing: 0,
                    unknown: baselines.baseline(for: host.id)?.expectedCount ?? host.expectedGPUCount,
                    unexpected: 0
                ),
                lastAttemptedAt: snapshot.lastAttemptedAt,
                lastSuccessfulAt: snapshot.lastSuccessfulAt,
                issues: ["Showing last known data from a previous session"],
                hasBaseline: baselines.baseline(for: host.id) != nil,
                neverChecked: true
            )
        }
    }
}

// MARK: - Report transitions

private extension HostReport {
    /// Marks the host as being checked right now, leaving the last reading and
    /// its tally untouched so the row does not flicker to zero.
    func markingChecking() -> HostReport {
        var copy = self
        copy.ssh = .checking
        return copy
    }
}
