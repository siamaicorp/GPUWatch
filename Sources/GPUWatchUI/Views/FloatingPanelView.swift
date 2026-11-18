import SwiftUI
import GPUWatchCore

/// The pinned panel.
///
/// Reads the same `AppModel` as the popover and owns no timer of its own, so
/// leaving it open cannot double the polling rate. Deliberately narrower and
/// flatter than the popover: this is meant to sit in a corner and be glanced at.
struct FloatingPanelView: View {
    @Bindable var coordinator: AppCoordinator

    private var model: AppModel { coordinator.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            if model.isEmpty {
                Text("No hosts configured")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(.secondary)
                    .padding(DS.Space.m)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.visibleReports.enumerated()), id: \.element.id) { index, report in
                            if index > 0 { Hairline().padding(.leading, DS.Space.m) }
                            CompactHostRow(report: report)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Hairline()
            footer
        }
        .frame(width: DS.panelWidth)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            BrandLogo(height: 14)
            Text("GPU Watch")
                .font(.system(size: 12, weight: .semibold))
            if model.isDemoMode {
                Text("DEMO")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Status.extra)
            }
            Spacer(minLength: DS.Space.s)
            Text(model.summary.menuBarRatio)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Image(systemName: statusSymbol)
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.m) {
            Toggle("On top", isOn: $coordinator.alwaysOnTop)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(DS.TextStyle.caption)
            Spacer(minLength: DS.Space.s)
            LinkButton("Unpin", tint: .secondary, action: coordinator.togglePanel)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
    }

    private var statusSymbol: String {
        model.summary.isFullyHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        model.summary.isFullyHealthy ? DS.Status.ok : DS.Status.warn
    }
}

/// One line per host: name, dots, ratio.
struct CompactHostRow: View {
    let report: HostReport

    private var state: HostDisplayState { report.displayState }

    private var ratioColor: Color {
        guard report.ratioIsConfirmed else { return .secondary }
        return state == .healthy ? .primary : DS.color(for: state)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: DS.symbol(for: state))
                .font(.system(size: 10))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.color(for: state))
                .frame(width: 13)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.s) {
                    Text(report.host.effectiveName)
                        .font(DS.TextStyle.captionStrong)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.xs)
                    Text(report.ratioDisplay)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ratioColor)
                }
                GPUDotGrid(gpus: report.gpus, dotSize: 8)
                if let detail = report.statusDetail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(report.host.effectiveName), \(state.label), \(report.ratioDisplay)")
    }
}
