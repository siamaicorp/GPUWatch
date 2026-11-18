import SwiftUI
import GPUWatchCore

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    private var model: AppModel { coordinator.model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                pollingSection
                notificationSection
                appearanceSection
                storageSection
                aboutSection
            }
            .padding(DS.Space.xl)
        }
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button {
                coordinator.closeSettings()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(DS.Space.m)
            .help("Close")
        }
    }

    // MARK: - Polling

    private var pollingSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Polling")

            Picker("Check every", selection: Binding(
                get: { model.settings.intervalSeconds },
                set: { newValue in
                    var settings = model.settings
                    settings.intervalSeconds = newValue
                    model.updateSettings(settings)
                }
            )) {
                ForEach(PollSettings.allowedIntervals, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                "Maximum concurrent hosts: \(model.settings.maxConcurrentChecks)",
                value: Binding(
                    get: { model.settings.maxConcurrentChecks },
                    set: { newValue in
                        var settings = model.settings
                        settings.maxConcurrentChecks = newValue
                        model.updateSettings(settings)
                    }
                ),
                in: 1...PollSettings.maxConcurrencyCeiling
            )
            .font(DS.TextStyle.caption)

            Text(
                "A reading older than \(Int(model.settings.staleWindowSeconds))s is treated as stale, "
                + "so it is never presented as current."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Notifications

    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Notifications")

            Toggle("Notify on status changes", isOn: Binding(
                get: { model.settings.notificationsEnabled },
                set: { coordinator.setNotificationsEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if model.notificationPermissionDenied {
                Text(
                    "macOS refused notification permission, so alerts will not appear. "
                    + "Allow GPU Watch in System Settings › Notifications."
                )
                .font(DS.TextStyle.caption)
                .foregroundStyle(DS.Status.warn)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "A problem must be seen twice in a row before it is announced, a recovery is announced "
                + "once a host is genuinely back, and repeat alerts are rate limited. Missing GPUs are "
                + "never announced from an SSH failure."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Appearance and startup

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Window and startup")

            Toggle("Keep the pinned panel on top", isOn: $coordinator.alwaysOnTop)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Launch at login", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { coordinator.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            if let error = coordinator.launchAtLoginError {
                Text(error)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Status.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Demo mode", isOn: Binding(
                get: { model.isDemoMode },
                set: { coordinator.setDemoMode($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Demo mode shows a synthetic fleet. It opens no connections and raises no real notifications.")
                .font(DS.TextStyle.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Storage")

            Text(model.configurationFolderPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.m) {
                LinkButton("Reveal folder", action: coordinator.revealConfigurationFolder)
            }

            Text(
                "Hosts, registered baselines and the last readable values are stored here as JSON. "
                + "No password, key, or key content is ever written."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "About")

            BrandLogo(height: 30)
                .padding(.bottom, DS.Space.xs)
            Text("GPU Watch")
                .font(DS.TextStyle.bodyStrong)
            Text("An open-source GPU monitor by SIAM.AI Corporation. Checks NVIDIA GPUs "
                + "on remote hosts over SSH; no agent is installed on the server.")
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Hairline()

            Text("What a reading means")
                .font(DS.TextStyle.captionStrong)
            Text(DS.healthScopeNote)
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "High utilisation and high VRAM use are not failures. Values the driver reports as "
                + "unsupported are shown as unknown, never as zero. MIG instances are partitions of a "
                + "physical card and are not counted as additional GPUs. AMD GPUs are not supported."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "SSH host keys are always verified. GPU Watch never accepts a new key or edits "
                + "known_hosts for you."
            )
            .font(DS.TextStyle.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            Hairline()

            Text("GPL-3.0-or-later · Copyright © 2026 SIAM.AI Corporation")
                .font(DS.TextStyle.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}
