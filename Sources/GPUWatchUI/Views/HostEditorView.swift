import AppKit
import SwiftUI
import GPUWatchCore

/// Add / edit a host.
///
/// Validation is the same code the probe uses, so a host that passes here is a
/// host that will actually run. Test Connection reports the result by stage,
/// because "it failed" is not actionable and "SSH worked but nvidia-smi is not
/// installed" is.
struct HostEditorView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var draft: HostConfig
    let isCreating: Bool

    @State private var portText: String
    @State private var expectedText: String
    @State private var thresholdText: String
    @State private var testResult: ConnectionTestResult?
    @State private var isTesting = false
    @State private var confirmDelete = false

    init(coordinator: AppCoordinator, draft: HostConfig, isCreating: Bool) {
        self.coordinator = coordinator
        self.isCreating = isCreating
        _draft = State(initialValue: draft)
        _portText = State(initialValue: draft.port.map(String.init) ?? "")
        _expectedText = State(initialValue: draft.expectedGPUCount > 0 ? String(draft.expectedGPUCount) : "")
        _thresholdText = State(
            initialValue: draft.temperatureWarningThreshold.map {
                $0.rounded() == $0 ? String(Int($0)) : String($0)
            } ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    identitySection
                    connectionSection
                    expectationSection
                    if let error = validationMessage {
                        validationBanner(error)
                    }
                    testSection
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            Hairline()
            footer
        }
        .frame(minWidth: 480, minHeight: 400)
        .confirmationDialog(
            "Delete \(draft.effectiveName)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Host", role: .destructive) {
                coordinator.deleteHost(draft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the host and its registered baseline. Nothing is changed on the server.")
        }
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Identity")
            LabeledField(
                "Display name",
                help: "Shown in the list. Leave blank to use the host name."
            ) {
                TextField("5090-1", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "SSH")

            LabeledField(
                "Host or alias",
                help: "Anything your ssh config already knows: an alias, a hostname, or an IP."
            ) {
                TextField("dgx-prod-01", text: $draft.destination)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(alignment: .top, spacing: DS.Space.m) {
                LabeledField("Username", help: "Optional") {
                    TextField("ops", text: Binding(
                        get: { draft.username ?? "" },
                        set: { draft.username = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                LabeledField("Port", help: "Optional") {
                    TextField("22", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }

            LabeledField(
                "Identity file",
                help: "Optional. Only the path is used; GPU Watch never reads a key."
            ) {
                HStack(spacing: DS.Space.s) {
                    TextField("~/.ssh/id_ed25519", text: Binding(
                        get: { draft.identityFile ?? "" },
                        set: { draft.identityFile = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseIdentityFile)
                }
            }

            Text(
                "GPU Watch runs your system ssh, so your agent, config and ProxyJump settings apply. "
                + "It never writes to ~/.ssh/config and never stores a password."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var expectationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Expectations")

            HStack(alignment: .top, spacing: DS.Space.m) {
                LabeledField(
                    "Expected GPUs",
                    help: "Used as the denominator. It is never reduced by what is found."
                ) {
                    TextField("4", text: $expectedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                LabeledField(
                    "Temperature warning (°C)",
                    help: "Optional. At or above this, a readable GPU is flagged."
                ) {
                    TextField("85", text: $thresholdText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
            }

            Toggle("Enabled", isOn: $draft.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func validationBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Status.warn)
            Text(message)
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Status.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                SectionHeader(title: "Connection test")
                Spacer(minLength: DS.Space.s)
                Button {
                    runTest()
                } label: {
                    if isTesting {
                        HStack(spacing: DS.Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || validationMessage != nil)
            }

            if let testResult {
                TestResultView(result: testResult)
            } else {
                Text("Runs the same check the poller uses, against this host only.")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            if !isCreating {
                Button("Delete…") { confirmDelete = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Status.bad)
                    .font(DS.TextStyle.body)
            }
            Spacer(minLength: DS.Space.s)
            Button("Cancel") {
                coordinator.cancelEditing()
            }
            .keyboardShortcut(.cancelAction)
            Button(isCreating ? "Add Host" : "Save") {
                commit()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(validationMessage != nil)
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
    }

    // MARK: - Behaviour

    /// Assembles the draft exactly as it would be saved, then validates it with
    /// the same code path the probe uses.
    private var assembled: HostConfig {
        var host = draft
        host.username = draft.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.username?.isEmpty ?? false { host.username = nil }
        host.identityFile = draft.identityFile?.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.identityFile?.isEmpty ?? false { host.identityFile = nil }
        host.port = Int(portText.trimmingCharacters(in: .whitespaces))
        host.expectedGPUCount = max(0, Int(expectedText.trimmingCharacters(in: .whitespaces)) ?? 0)
        let threshold = Double(thresholdText.trimmingCharacters(in: .whitespaces))
        host.temperatureWarningThreshold = threshold
        return host
    }

    private var validationMessage: String? {
        let host = assembled
        if host.destination.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil    // an empty form is not an error yet, it is just empty
        }
        do {
            _ = try SSHTarget.make(from: host)
        } catch {
            return error.localizedDescription
        }
        if !portText.trimmingCharacters(in: .whitespaces).isEmpty, host.port == nil {
            return "Invalid port: must be a number between 1 and 65535"
        }
        if !expectedText.trimmingCharacters(in: .whitespaces).isEmpty, host.expectedGPUCount == 0 {
            return "Expected GPUs must be a positive number, or blank to leave it unset"
        }
        if !thresholdText.trimmingCharacters(in: .whitespaces).isEmpty, thresholdDouble == nil {
            return "Temperature warning must be a number, or blank to disable it"
        }
        return nil
    }

    private var thresholdDouble: Double? {
        Double(thresholdText.trimmingCharacters(in: .whitespaces))
    }

    private var canSave: Bool {
        validationMessage == nil
            && !assembled.destination.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func commit() {
        guard canSave else { return }
        coordinator.commitEditing(assembled)
    }

    private func runTest() {
        let host = assembled
        isTesting = true
        testResult = nil
        Task {
            let result = await coordinator.model.testConnection(host)
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key. GPU Watch stores the path only."
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }
}

// MARK: - Supporting views

/// Label above, control, hint below.
///
/// The hint deliberately sits *under* the field rather than beside the label: at
/// this width an inline hint pushes the label onto a second line and the two
/// become hard to tell apart.
struct LabeledField<Content: View>: View {
    let label: String
    let help: String?
    @ViewBuilder let content: Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.TextStyle.captionStrong)
                .foregroundStyle(.secondary)
            content
            if let help {
                Text(help)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders a connection test as stages rather than a pass/fail, so the operator
/// knows which layer to go and look at.
struct TestResultView: View {
    let result: ConnectionTestResult

    private var color: Color {
        switch result.stage {
        case .success: return DS.Status.ok
        case .invalidConfiguration: return DS.Status.warn
        case .sshFailed, .gpuQueryFailed: return DS.Status.bad
        case .nvidiaSMIMissing: return DS.Status.warn
        }
    }

    private var symbol: String {
        switch result.stage {
        case .success: return "checkmark.circle.fill"
        case .invalidConfiguration: return "exclamationmark.triangle.fill"
        case .sshFailed: return "bolt.horizontal.circle"
        case .nvidiaSMIMissing: return "questionmark.circle"
        case .gpuQueryFailed: return "display.trianglebadge.exclamationmark"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(result.stage.label)
                    .font(DS.TextStyle.captionStrong)
                    .foregroundStyle(color)
                Spacer(minLength: DS.Space.s)
                if let count = result.gpuCount {
                    Text("\(count) GPU\(count == 1 ? "" : "s")")
                        .font(DS.TextStyle.number)
                }
            }
            Text(result.summary)
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !result.detail.isEmpty {
                Text(result.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !result.samples.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.samples.enumerated()), id: \.offset) { _, sample in
                        Text(sampleSummary(sample))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.cornerRadius))
    }

    private func sampleSummary(_ sample: GPUSample) -> String {
        let index = sample.index.map { "\($0)" } ?? "?"
        let uuid = sample.uuid ?? "no uuid"
        return "  \(index)  \(uuid)  \(DS.temperature(sample.temperatureCelsius))  \(DS.memory(used: sample.memoryUsedMiB, total: sample.memoryTotalMiB))"
    }
}
