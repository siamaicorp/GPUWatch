import SwiftUI
import GPUWatchCore

// MARK: - Level icon

/// A circular status level. Colour, symbol and tooltip always agree.
struct LevelIcon: View {
    let color: Color
    let symbol: String
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: size + 3, height: size + 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Status pill

/// The headline verdict. Matches the "pill + label" idiom: a tinted capsule with
/// an icon and a word, never colour alone.
struct StatusPill: View {
    let state: HostDisplayState
    var compact = false

    private var color: Color { DS.color(for: state) }

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: DS.symbol(for: state))
                .font(.system(size: compact ? 9 : 11, weight: .bold))
            Text(text)
                .font(compact ? DS.TextStyle.captionStrong : DS.TextStyle.captionStrong)
                .fixedSize()
        }
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule(style: .continuous).fill(color.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(color.opacity(0.30), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(state.label)")
    }

    private var text: String {
        switch state {
        case .healthy: return "Healthy"
        case .degraded: return "Attention"
        case .checking: return "Checking"
        case .disabled: return "Disabled"
        case .stale: return "Stale"
        case .unknown: return "Unknown"
        case .sshFailed, .gpuQueryFailed: return state.label
        }
    }
}

// MARK: - GPU dots

/// One dot per GPU, wrapping into as many lines as needed.
struct GPUDotGrid: View {
    let gpus: [GPUReport]
    var dotSize: CGFloat = 10

    var body: some View {
        FlowLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xs) {
            ForEach(gpus) { gpu in
                Image(systemName: DS.symbol(for: gpu.health))
                    .font(.system(size: dotSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DS.color(for: gpu.health))
                    .help(tooltip(for: gpu))
                    .accessibilityLabel(tooltip(for: gpu))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tooltip(for gpu: GPUReport) -> String {
        var parts: [String] = []
        if let index = gpu.index {
            parts.append("GPU \(index)")
        } else {
            parts.append("GPU")
        }
        if let uuid = gpu.uuid { parts.append(uuid) }
        else { parts.append("no UUID reported") }

        parts.append(DS.word(for: gpu.health))

        var readings: [String] = []
        if let temperature = gpu.temperatureCelsius {
            readings.append(DS.temperature(temperature, sensor: gpu.temperatureSensor))
        }
        if let utilization = gpu.utilizationPercent {
            readings.append("\(DS.percent(utilization)) util")
        }
        if gpu.memoryTotalMiB != nil {
            readings.append("\(DS.memory(used: gpu.memoryUsedMiB, total: gpu.memoryTotalMiB)) VRAM")
        }
        if !readings.isEmpty { parts.append(readings.joined(separator: ", ")) }

        if !gpu.isLiveData { parts.append("last known, not current") }
        if let reason = gpu.reasonText { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Value bar

/// Thin usage bar. Purely a reading aid — VRAM saturation is deliberately not a
/// health signal, so the bar is tinted by GPU health, not by how full it is.
struct ValueBar: View {
    let fraction: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: DS.barHeight)
        .accessibilityHidden(true)
    }
}

// MARK: - Metric row

/// `symbol  label ……… value`, matching the system-monitor idiom.
struct MetricRow: View {
    let symbol: String
    let label: String
    let value: String
    var valueColor: Color = .primary
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(label)
                .font(DS.TextStyle.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(DS.TextStyle.number)
                    .foregroundStyle(valueColor)
                if let detail {
                    Text(detail)
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Spacer(minLength: DS.Space.s)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Hairline rule with the generous breathing room the reference design uses.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
