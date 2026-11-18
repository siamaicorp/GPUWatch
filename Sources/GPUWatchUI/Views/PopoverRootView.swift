import SwiftUI
import GPUWatchCore

/// The menu bar popover.
///
/// Structure mirrors a compact system monitor: a title with a verdict pill and
/// a refresh control, one subtitle line, the scrolling body, then a footer of
/// text actions. 400 pt wide, growing to a cap before the body scrolls.
struct PopoverRootView: View {
    @Bindable var coordinator: AppCoordinator

    private var model: AppModel { coordinator.model }
    private var now: Date { model.lastRefreshCompletedAt ?? Date() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if !model.storeIssues.isEmpty {
                storeIssueBanner
                Hairline()
            }

            if model.isEmpty {
                EmptyFleetView(coordinator: coordinator)
            } else {
                hostList
            }

            Hairline()
            footer
        }
        .frame(width: DS.popoverWidth)
        .background(.regularMaterial)
        .confirmationDialog(
            "Register GPU baseline",
            isPresented: Binding(
                get: { coordinator.ui.pendingBaselineHostID != nil },
                set: { if !$0 { coordinator.cancelRegisterBaseline() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Register") { coordinator.confirmRegisterBaseline() }
            Button("Cancel", role: .cancel) { coordinator.cancelRegisterBaseline() }
        } message: {
            Text(baselineConfirmationMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                BrandLogo(height: 18)

                Text("GPU Watch")
                    .font(DS.TextStyle.title)

                if model.isDemoMode {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(DS.Status.extra)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Status.extra.opacity(0.18)))
                        .accessibilityLabel("Demo mode")
                }

                Spacer(minLength: DS.Space.s)

                // With nothing configured there is no verdict to give, and an
                // amber "Attention" over an empty list is a false alarm.
                if !model.isEmpty {
                    StatusPill(state: overallState)
                }

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Refreshing")
                } else {
                    Button(action: coordinator.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh now")
                }
            }

            Text(subtitle)
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    private var subtitle: String {
        let summary = model.summary
        guard model.isEmpty == false else { return "No hosts configured" }

        // Compact tokens, because six listed items wrap to a second line at
        // this width and the wrap makes the line harder to scan, not easier.
        var parts: [String] = []
        if summary.readableGPUs == 0, summary.unknownGPUs > 0 {
            // "0/20 readable" reads as a result. Nothing has been confirmed, so
            // say that instead of implying every GPU is unreadable.
            parts.append("No GPUs confirmed")
        } else {
            parts.append("\(summary.readableGPUs)/\(summary.expectedGPUs) readable")
        }
        if summary.missingGPUs > 0 { parts.append("\(summary.missingGPUs) missing") }
        if summary.unknownGPUs > 0 { parts.append("\(summary.unknownGPUs) unknown") }
        if summary.unexpectedGPUs > 0 { parts.append("\(summary.unexpectedGPUs) unexpected") }
        if summary.staleHosts > 0 { parts.append("\(summary.staleHosts) stale") }
        return parts.joined(separator: " · ")
    }

    private var overallState: HostDisplayState {
        if model.isRefreshing { return .checking }
        let summary = model.summary
        if summary.isFullyHealthy { return .healthy }
        if summary.hasUnknowns && summary.unknownGPUs > 0 && summary.missingGPUs == 0 {
            // Nothing confirmed wrong, but we cannot vouch for everything.
            return summary.staleHosts > 0 ? .stale : .unknown
        }
        return .degraded
    }

    // MARK: - Body

    private var hostList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.visibleReports.enumerated()), id: \.element.id) { index, report in
                    if index > 0 {
                        Hairline().padding(.leading, DS.Space.l + 17)
                    }
                    HostRowView(
                        coordinator: coordinator,
                        report: report,
                        isExpanded: coordinator.ui.expandedHostID == report.id,
                        now: now,
                        onToggle: { coordinator.ui.toggleExpanded(report.id) }
                    )
                }
            }
        }
        .frame(maxHeight: DS.popoverMaxHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Store issues

    private var storeIssueBanner: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(model.storeIssues) { issue in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Status.warn)
                    Text(issue.message)
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.m) {
                LinkButton("Show folder", action: coordinator.revealConfigurationFolder)
                LinkButton("Dismiss", action: model.dismissStoreIssues)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Status.warn.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            if !model.isEmpty {
                Text("Checked \(DS.relative(model.lastRefreshCompletedAt, now: Date()))")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: DS.Space.s)

            LinkButton("Add Host", action: coordinator.beginAddHost)
            LinkButton("Settings", action: coordinator.openSettings)
            LinkButton(
                coordinator.ui.isPanelVisible ? "Unpin" : "Pin",
                action: coordinator.togglePanel
            )
            LinkButton("Quit", tint: .secondary, action: coordinator.quit)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private var baselineConfirmationMessage: String {
        guard
            let hostID = coordinator.ui.pendingBaselineHostID,
            let preview = model.baselinePreview(hostID: hostID)
        else {
            return "The current GPU list will be recorded as the accepted baseline."
        }
        let name = model.hosts.first { $0.id == hostID }?.effectiveName ?? "this host"
        return """
        GPU Watch will record \(preview.uuids.count) GPU UUID(s) for \(name).
        Expected count: \(preview.expected).

        \(preview.uuids.joined(separator: "\n"))
        """
    }
}

/// A footer action rendered as text, matching the platform idiom for popover
/// footers rather than a row of chunky buttons.
struct LinkButton: View {
    let title: String
    var tint: Color = .accentColor
    let action: () -> Void

    init(_ title: String, tint: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
