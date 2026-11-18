import SwiftUI
import GPUWatchCore

/// The per-host actions shown inside an expanded row.
///
/// These were missing entirely at first: the host editor, baseline registration
/// and delete all existed but had no entry point, so an existing host could be
/// added and then never changed. Everything an operator needs to do to one host
/// is here, in the place they already opened to look at it.
struct HostActionsView: View {
    @Bindable var coordinator: AppCoordinator
    let report: HostReport

    @State private var testResult: ConnectionTestResult?
    @State private var isTesting = false

    private var host: HostConfig { report.host }

    /// Registering a baseline needs a reading to record. Offering the button
    /// without one would open a confirmation for nothing.
    private var canRegisterBaseline: Bool {
        report.query.isOK && !report.query.samples.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Hairline()
            SectionHeader(title: "Actions")

            HStack(spacing: DS.Space.s) {
                ActionButton("Edit…", symbol: "slider.horizontal.3") {
                    coordinator.beginEdit(host)
                }
                ActionButton("Test Connection", symbol: "bolt.horizontal", isBusy: isTesting) {
                    runTest()
                }
                .disabled(isTesting)
            }

            HStack(spacing: DS.Space.s) {
                if report.hasBaseline {
                    ActionButton("Re-register…", symbol: "checklist") {
                        coordinator.beginRegisterBaseline(hostID: host.id)
                    }
                    ActionButton("Remove Baseline", symbol: "xmark.bin") {
                        coordinator.removeBaseline(hostID: host.id)
                    }
                } else {
                    ActionButton("Register GPU Baseline", symbol: "checklist") {
                        coordinator.beginRegisterBaseline(hostID: host.id)
                    }
                    .disabled(!canRegisterBaseline)
                }
            }

            HStack(spacing: DS.Space.s) {
                ActionButton(
                    host.enabled ? "Disable" : "Enable",
                    symbol: host.enabled ? "pause.circle" : "play.circle"
                ) {
                    coordinator.setHostEnabled(!host.enabled, host: host)
                }
                ActionButton("Delete…", symbol: "trash", tint: DS.Status.bad) {
                    coordinator.ui.pendingDeleteHostID = host.id
                }
            }

            if !report.hasBaseline {
                Text(canRegisterBaseline
                    ? "A baseline records which GPUs this host should have, so GPU Watch can tell you which card went missing."
                    : "A baseline can be registered once a check has read this host's GPUs.")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let testResult {
                TestResultView(result: testResult)
            }
        }
        .confirmationDialog(
            "Delete \(host.effectiveName)?",
            isPresented: Binding(
                get: { coordinator.ui.pendingDeleteHostID == host.id },
                set: { if !$0 { coordinator.ui.pendingDeleteHostID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Host", role: .destructive) {
                coordinator.ui.pendingDeleteHostID = nil
                coordinator.deleteHost(host)
            }
            Button("Cancel", role: .cancel) {
                coordinator.ui.pendingDeleteHostID = nil
            }
        } message: {
            Text("This removes the host and its registered baseline. Nothing is changed on the server.")
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await coordinator.testHost(host)
            testResult = result
            isTesting = false
        }
    }
}

/// A small, uniform action control. Deliberately not a bordered button: eight
/// bordered buttons in a 400 pt column read as noise rather than as choices.
struct ActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    var isBusy: Bool = false
    let action: () -> Void

    init(
        _ title: String,
        symbol: String,
        tint: Color = .accentColor,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isBusy = isBusy
        self.action = action
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(DS.TextStyle.captionStrong)
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? tint : Color.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous)
                    .fill((isEnabled ? tint : Color.secondary).opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
