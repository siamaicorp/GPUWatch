import SwiftUI
import GPUWatchCore

/// Shared visual vocabulary.
///
/// Direction: a native macOS dark surface, one accent for interactive controls,
/// and a four-step semantic ramp for status. Status is never carried by colour
/// alone — every state also has its own symbol and its own tooltip, because a
/// red/green distinction is invisible to a meaningful share of operators.
enum DS {

    // MARK: - Spacing (4 pt rhythm)

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Type (four sizes)

    /// Four sizes only. Named to avoid colliding with the `.Type` metatype syntax.
    enum TextStyle {
        /// Titles and headline numbers.
        static let title = Font.system(size: 15, weight: .semibold)
        /// Body copy and host names.
        static let body = Font.system(size: 13)
        static let bodyStrong = Font.system(size: 13, weight: .medium)
        /// Values that should line up between rows.
        static let number = Font.system(size: 13, weight: .semibold).monospacedDigit()
        /// Labels, hints, secondary explanations.
        static let caption = Font.system(size: 11)
        static let captionStrong = Font.system(size: 11, weight: .medium)
    }

    // MARK: - Status ramp

    /// The SIAM.AI mark runs from a deep blue to a teal. Kept separate from the
    /// status ramp on purpose: brand colour must never be read as a health
    /// signal, so it is only ever used for identity.
    static let brandDeepBlue = Color(red: 0.00, green: 0.44, blue: 0.80)
    static let brandTeal = Color(red: 0.11, green: 0.72, blue: 0.72)

    /// One accent (the system accent, for controls) plus four status colours.
    enum Status {
        /// Identity only. Never used to mean "healthy".
        static let brand = Color(red: 0.11, green: 0.72, blue: 0.72)

        /// The driver saw this GPU and answered its core metrics.
        static let ok = Color(nsColor: .systemGreen)
        /// Readable, but a configured threshold is exceeded.
        static let warn = Color(nsColor: .systemOrange)
        /// Confirmed absent from a complete check.
        static let bad = Color(nsColor: .systemRed)
        /// Present but not part of the registered baseline.
        static let extra = Color(nsColor: .systemPurple)
        /// No trustworthy reading: stale, unreachable, or unqueryable.
        static let unknown = Color(nsColor: .tertiaryLabelColor)
    }

    // MARK: - Geometry

    static let popoverWidth: CGFloat = 400
    static let popoverMaxHeight: CGFloat = 560
    static let panelWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 6
    /// Width of the thin value bars, matching the "usage bar" idiom.
    static let barHeight: CGFloat = 4

    // MARK: - Status mapping

    static func color(for health: GPUHealth) -> Color {
        switch health {
        case .healthy: return Status.ok
        case .warning: return Status.warn
        case .missing: return Status.bad
        case .unexpected: return Status.extra
        case .unknown: return Status.unknown
        }
    }

    /// Symbol per GPU verdict. Shape carries the same information as colour.
    static func symbol(for health: GPUHealth) -> String {
        switch health {
        case .healthy: return "circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .missing: return "minus.circle.fill"
        case .unexpected: return "plus.circle.fill"
        case .unknown: return "circle.dashed"
        }
    }

    static func word(for health: GPUHealth) -> String {
        switch health {
        case .healthy: return "readable"
        case .warning: return "warning"
        case .missing: return "missing"
        case .unexpected: return "not in baseline"
        case .unknown: return "unknown"
        }
    }

    static func color(for state: HostDisplayState) -> Color {
        switch state {
        case .healthy: return Status.ok
        case .checking: return Status.unknown
        case .disabled: return Status.unknown
        case .degraded: return Status.warn
        case .stale: return Status.unknown
        case .unknown: return Status.unknown
        case let .sshFailed(kind):
            // A check the user cancelled, or an ssh failure we could not
            // classify, is not evidence of a fault.
            return (kind == .cancelled || kind == .unknown) ? Status.unknown : Status.bad
        case .gpuQueryFailed:
            // The host answered; the driver did not. That is a warning, not a
            // confirmed failure, and it must not look like one.
            return Status.warn
        }
    }

    static func symbol(for state: HostDisplayState) -> String {
        switch state {
        case .healthy: return "checkmark.circle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .disabled: return "pause.circle"
        case .degraded: return "exclamationmark.triangle.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .unknown: return "questionmark.circle"
        case .sshFailed: return "bolt.horizontal.circle"
        case .gpuQueryFailed: return "display.trianglebadge.exclamationmark"
        }
    }

    // MARK: - Formatting

    /// A temperature, annotated with its sensor when it is not the package one.
    ///
    /// The annotation is what keeps a threshold honest: a junction reading is
    /// hotter than the package sensor for the same card, so the number alone
    /// would not say which scale it sits on.
    static func temperature(_ value: Double?, sensor: GPUTemperatureSensor? = nil) -> String {
        guard let value else { return "—" }
        let number = value.rounded() == value
            ? "\(Int(value))°C"
            : String(format: "%.1f°C", value)
        guard let annotation = sensor?.annotation else { return number }
        return "\(number) \(annotation)"
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func memory(used: Double?, total: Double?) -> String {
        guard let total else { return "—" }
        let totalText = gibibytes(total)
        guard let used else { return "— / \(totalText)" }
        return "\(gibibytes(used)) / \(totalText)"
    }

    static func memoryFraction(used: Double?, total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    static func power(draw: Double?, limit: Double?) -> String {
        guard let draw else { return "—" }
        let drawn = Int(draw.rounded())
        guard let limit else { return "\(drawn) W" }
        return "\(drawn)/\(Int(limit.rounded())) W"
    }

    /// Percentage of the power limit being drawn, or `nil` when the card does
    /// not report a limit.
    static func powerPercent(draw: Double?, limit: Double?) -> String? {
        guard let draw, let limit, limit > 0 else { return nil }
        return "\(Int((draw / limit * 100).rounded()))%"
    }

    private static func gibibytes(_ mebibytes: Double) -> String {
        let gib = mebibytes / 1024
        return gib >= 10 ? String(format: "%.0f GB", gib) : String(format: "%.1f GB", gib)
    }

    /// "12s ago", "4m ago", "2h ago" — compact and unambiguous.
    static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// Absolute timestamp. Today's readings show a bare time, because a monitor
    /// is read dozens of times a day and a repeated date is just noise.
    static func absolute(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The boundary of what a green dot means. Shown in tooltips and About so the
    /// claim is never read as more than it is.
    static let healthScopeNote =
        "Green means the driver reported the GPU and answered its core metrics. "
        + "It is not a check of CUDA or ROCm workloads, NCCL, or inference servers."
}

/// Wrapping grid used for GPU dots.
///
/// A hand-written `Layout` rather than a `LazyVGrid`, because the dots must be
/// packed left-to-right with uniform gaps and no ragged column widths — a grid
/// with fixed columns leaves a visible hole when a host has a prime number of
/// GPUs, which is exactly the common case (3, 7, 8).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalHeight += lineHeight + lineSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += lineWidth > 0 ? spacing + size.width : size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalHeight += lineHeight
        return CGSize(width: min(maxWidth, lineWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
