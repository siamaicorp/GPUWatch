import SwiftUI
import GPUWatchCore

/// One host line: SSH level, name, GPU dots, count, and the short reason when
/// something is wrong.
struct HostRowView: View {
    @Bindable var coordinator: AppCoordinator
    let report: HostReport
    let isExpanded: Bool
    let now: Date
    let onToggle: () -> Void

    private var state: HostDisplayState { report.displayState }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header
            GPUDotGrid(gpus: report.gpus)
            if let detail = report.statusDetail {
                Text(detail)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded {
                HostDetailView(report: report, now: now)
                    .padding(.top, DS.Space.xs)
                HostActionsView(coordinator: coordinator, report: report)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu {
            Button("Edit Host…") { coordinator.beginEdit(report.host) }
            Button(report.host.enabled ? "Disable" : "Enable") {
                coordinator.setHostEnabled(!report.host.enabled, host: report.host)
            }
            Divider()
            Button("Delete Host…", role: .destructive) {
                coordinator.ui.pendingDeleteHostID = report.id
            }
            Divider()
            Button("Refresh Now") { coordinator.refresh() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded ? "Collapses details" : "Expands details")
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            LevelIcon(color: DS.color(for: state), symbol: DS.symbol(for: state))
                .accessibilityHidden(true)

            Text(report.host.effectiveName)
                .font(DS.TextStyle.bodyStrong)
                .foregroundStyle(report.host.enabled ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: DS.Space.s)

            Text(report.ratioDisplay)
                .font(DS.TextStyle.number)
                .foregroundStyle(ratioColor)
                .help(countTooltip)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
    }

    /// An unconfirmed numerator is muted rather than alarming: `?/8` in red
    /// would still read as a fault, and there is no fault to report yet.
    private var ratioColor: Color {
        if !report.ratioIsConfirmed { return .secondary }
        return state == .healthy ? .primary : DS.color(for: state)
    }

    private var countTooltip: String {
        var lines: [String] = []
        if report.ratioIsConfirmed {
            lines.append("Readable now: \(report.counts.readable)")
        } else {
            lines.append("Readable now: not confirmed")
            if report.counts.readable > 0 {
                lines.append("Last known readable: \(report.counts.readable)")
            }
        }
        lines.append("Expected: \(report.counts.expected > 0 ? "\(report.counts.expected)" : "not set")")
        if report.counts.missing > 0 { lines.append("Confirmed missing: \(report.counts.missing)") }
        if report.counts.unknown > 0 { lines.append("Unknown: \(report.counts.unknown)") }
        if report.counts.unexpected > 0 { lines.append("Unexpected: \(report.counts.unexpected)") }
        if report.counts.warnings > 0 { lines.append("Warnings: \(report.counts.warnings)") }
        if report.freshness == .stale { lines.append("Data is stale") }
        return lines.joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        var parts = [report.host.effectiveName, "\(state.label)."]
        parts.append(
            report.ratioIsConfirmed
                ? "\(report.counts.readable) of \(report.counts.expected) GPUs readable."
                : "GPU count not confirmed."
        )
        if let detail = report.statusDetail { parts.append(detail) }
        return parts.joined(separator: " ")
    }
}

// MARK: - Detail pane

/// Everything known about one host, including the provenance of each number.
struct HostDetailView: View {
    let report: HostReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Hairline()
            connectionSection
            if !report.gpus.isEmpty {
                gpuSection
            } else if report.neverChecked {
                Text("No reading yet. Add the host and press Refresh.")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.issues.isEmpty {
                issuesSection
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Connection")
            MetricRow(
                symbol: "network",
                label: "SSH",
                value: sshValue,
                valueColor: sshColor
            )
            MetricRow(
                symbol: "display",
                label: "GPU query",
                value: queryValue,
                valueColor: queryColor
            )
            MetricRow(
                symbol: "clock.arrow.circlepath",
                label: "Last attempted",
                value: DS.relative(report.lastAttemptedAt, now: now),
                detail: DS.absolute(report.lastAttemptedAt, now: now)
            )
            MetricRow(
                symbol: "checkmark.circle",
                label: "Last successful",
                value: DS.relative(report.lastSuccessfulAt, now: now),
                detail: DS.absolute(report.lastSuccessfulAt, now: now)
            )
            if report.freshness != .fresh, report.lastSuccessfulAt != nil {
                Text("The values below are last known, not current.")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Status.warn)
            }
        }
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(
                title: "GPUs",
                trailing: report.hasBaseline ? "baseline registered" : "no baseline"
            )
            ForEach(report.gpus) { gpu in
                GPUDetailRow(gpu: gpu)
            }
            if !report.missingUUIDs.isEmpty {
                Text("Missing from the latest complete check: "
                    + report.missingUUIDs.joined(separator: ", "))
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Status.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SectionHeader(title: "Notes")
            ForEach(report.issues, id: \.self) { issue in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(issue)
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sshValue: String {
        switch report.ssh {
        case .ok: return "Connected"
        case .disabled: return "Disabled"
        case .checking: return "Checking…"
        case .notAttempted: return "Not checked"
        case let .failed(kind, _): return kind.shortLabel
        }
    }

    private var sshColor: Color {
        report.ssh.isOK ? DS.Status.ok : (report.ssh.isFailure ? DS.Status.bad : .secondary)
    }

    private var queryValue: String {
        switch report.query {
        case .ok: return "\(report.query.samples.count) reported"
        case .notAttempted: return "—"
        case let .failed(reason, _): return reason.shortLabel
        }
    }

    private var queryColor: Color {
        report.query.isOK ? DS.Status.ok : (report.query.isFailure ? DS.Status.bad : .secondary)
    }
}

// MARK: - One GPU

struct GPUDetailRow: View {
    let gpu: GPUReport

    private var tint: Color { DS.color(for: gpu.health) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: DS.symbol(for: gpu.health))
                    .font(.system(size: 10))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                Text(title)
                    .font(DS.TextStyle.captionStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.xs)
                // Only meaningful when there is something carried forward. A
                // missing or never-read slot has no earlier value to be "last
                // known" from.
                if !gpu.isLiveData, gpu.hasReadings {
                    Text("last known")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let model = gpu.model {
                Text(model)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: DS.Space.l) {
                reading("thermometer.medium", DS.temperature(gpu.temperatureCelsius))
                reading("gauge.medium", DS.percent(gpu.utilizationPercent))
                reading("memorychip", DS.memory(used: gpu.memoryUsedMiB, total: gpu.memoryTotalMiB))
            }

            ValueBar(
                fraction: DS.memoryFraction(used: gpu.memoryUsedMiB, total: gpu.memoryTotalMiB),
                tint: tint
            )

            // Problems the driver has answering for this card.
            ForEach(gpu.readabilityWarnings, id: \.text) { warning in
                Text(warning.text)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            pressureRow

            // Problems of load. Prefixed so the two can never be read as the
            // same kind of statement.
            ForEach(gpu.pressureWarnings, id: \.text) { warning in
                Text("load: \(warning.text)")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .missing(reason) = gpu.health {
                Text(reason)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case let .unknown(reason) = gpu.health {
                Text(reason)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .unexpected = gpu.health {
                Text("Not in baseline")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// How hard the card is working, on its own line and under its own label.
    ///
    /// Shown only when the driver actually reported something. Several cards —
    /// including consumer ones — do not report HBM temperature at all, and a row
    /// of dashes for values the hardware never had would look like a fault.
    @ViewBuilder
    private var pressureRow: some View {
        if let pressure = gpu.pressure, pressure.hasAnyReading {
            HStack(spacing: DS.Space.s) {
                Text("load")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .leading)

                HStack(spacing: DS.Space.m) {
                    if pressure.powerDrawWatts != nil {
                        reading("bolt", DS.power(
                            draw: pressure.powerDrawWatts, limit: pressure.powerLimitWatts
                        ))
                    }
                    if let memoryTemperature = pressure.memoryTemperatureCelsius {
                        reading("thermometer.sun", DS.temperature(memoryTemperature) + " mem")
                    }
                    if let memoryUtilization = pressure.memoryUtilizationPercent {
                        reading("arrow.left.arrow.right", DS.percent(memoryUtilization) + " mem")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(pressureAccessibilityLabel(pressure))
        }
    }

    private func pressureAccessibilityLabel(_ pressure: GPUPressure) -> String {
        var parts = ["Load"]
        if pressure.powerDrawWatts != nil {
            parts.append("power \(DS.power(draw: pressure.powerDrawWatts, limit: pressure.powerLimitWatts))")
        }
        if let memoryTemperature = pressure.memoryTemperatureCelsius {
            parts.append("memory temperature \(DS.temperature(memoryTemperature))")
        }
        if let memoryUtilization = pressure.memoryUtilizationPercent {
            parts.append("memory utilisation \(DS.percent(memoryUtilization))")
        }
        parts.append("this describes the workload, not the card's health")
        return parts.joined(separator: ", ")
    }

    private func reading(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Identifies the card as precisely as the data allows. A GPU known only by
    /// UUID must not be shown as a bare "GPU", which reads like a slot number the
    /// driver failed to report rather than a specific missing card.
    private var title: String {
        if let index = gpu.index { return "GPU \(index)" }
        if let uuid = gpu.uuid {
            return String(uuid.prefix(12))
        }
        return "GPU (unreportable slot)"
    }

    private var accessibilityLabel: String {
        var parts = [title, DS.word(for: gpu.health)]
        parts.append(DS.temperature(gpu.temperatureCelsius))
        parts.append("\(DS.percent(gpu.utilizationPercent)) utilisation")
        parts.append("\(DS.memory(used: gpu.memoryUsedMiB, total: gpu.memoryTotalMiB)) VRAM")
        if let pressure = gpu.pressure, pressure.hasAnyReading {
            parts.append(pressureAccessibilityLabel(pressure))
        }
        if !gpu.isLiveData { parts.append("last known, not current") }
        if let reason = gpu.reasonText { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}
