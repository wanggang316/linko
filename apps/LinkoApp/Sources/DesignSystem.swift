import SwiftUI

// =============================================================================
// MARK: - Theme
// =============================================================================

/// The single source of truth for linko's native macOS design language: color
/// tokens, spacing scale, corner radii, and the typography ramp. Everything is
/// derived from system colors and materials so it adapts to light/dark and the
/// user's accent color automatically — never hardcoded hex.
enum Theme {

    // MARK: Colors

    /// Semantic color tokens. All are built on `NSColor` system colors or
    /// `Color.accentColor`, so they track appearance and accent changes.
    enum Color {
        /// App accent; tints interactive controls and the active status.
        static let accent = SwiftUI.Color.accentColor

        /// Primary text on top of materials.
        static let label = SwiftUI.Color(nsColor: .labelColor)
        /// Secondary text (captions, metadata).
        static let secondaryLabel = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// Tertiary text (the faintest hierarchy level).
        static let tertiaryLabel = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        /// Quaternary fill, used for hairline separators and inert chips.
        static let separator = SwiftUI.Color(nsColor: .separatorColor)

        /// Hairline border for cards and chips, tuned to read on materials.
        static let cardBorder = SwiftUI.Color(nsColor: .separatorColor).opacity(0.7)
        /// Hover/selection tint laid over rows and buttons.
        static let hover = SwiftUI.Color(nsColor: .quaternaryLabelColor).opacity(0.6)

        // MARK: Status

        /// Active / running / online.
        static let active = SwiftUI.Color(nsColor: .systemGreen)
        /// Inactive / stopped — intentionally muted, not red.
        static let inactive = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// Error / failure.
        static let error = SwiftUI.Color(nsColor: .systemRed)
        /// Warning / degraded.
        static let warning = SwiftUI.Color(nsColor: .systemOrange)
        /// Informational accents (e.g. download direction).
        static let info = SwiftUI.Color(nsColor: .systemBlue)

        /// Download-direction tint (paired with `upload`).
        static let download = SwiftUI.Color(nsColor: .systemBlue)
        /// Upload-direction tint (paired with `download`).
        static let upload = SwiftUI.Color(nsColor: .systemGreen)
    }

    // MARK: Spacing

    /// A 4-point spacing scale. Use these instead of ad-hoc literals so
    /// rhythm stays consistent across every surface.
    enum Spacing {
        /// 4
        static let xxs: CGFloat = 4
        /// 8
        static let xs: CGFloat = 8
        /// 12
        static let sm: CGFloat = 12
        /// 16
        static let md: CGFloat = 16
        /// 20
        static let lg: CGFloat = 20
        /// 24
        static let xl: CGFloat = 24
        /// 32
        static let xxl: CGFloat = 32
    }

    // MARK: Radius

    /// Corner radii for chips, cards, and windows.
    enum Radius {
        /// 6 — chips, pills.
        static let small: CGFloat = 6
        /// 10 — buttons, rows.
        static let medium: CGFloat = 10
        /// 14 — cards.
        static let large: CGFloat = 14
        /// 20 — popover container.
        static let xlarge: CGFloat = 20
    }

    // MARK: Typography

    /// The type ramp. Numeric/rate values use `.monospacedDigit()` so columns
    /// don't jitter; headings use `.rounded` where it reads as premium.
    enum Font {
        /// Window / hero title.
        static let title = SwiftUI.Font.largeTitle.weight(.bold).leading(.tight)
        /// Section title inside a window.
        static let sectionTitle = SwiftUI.Font.title2.weight(.semibold)
        /// Card / group heading.
        static let heading = SwiftUI.Font.headline
        /// Default body copy.
        static let body = SwiftUI.Font.body
        /// Emphasized body (selected node name, etc.).
        static let bodyEmphasized = SwiftUI.Font.body.weight(.medium)
        /// Captions, metadata, secondary labels.
        static let caption = SwiftUI.Font.caption
        /// Smallest caption (timestamps, byte counters).
        static let caption2 = SwiftUI.Font.caption2

        /// Big rounded metric number (traffic rates, totals).
        static let metric = SwiftUI.Font.system(.title, design: .rounded)
            .weight(.semibold)
            .monospacedDigit()
        /// Medium rounded metric (counts).
        static let metricSmall = SwiftUI.Font.system(.title3, design: .rounded)
            .weight(.semibold)
            .monospacedDigit()
        /// Monospaced text for IPs, ports, log payloads.
        static let mono = SwiftUI.Font.system(.callout, design: .monospaced)
        /// Small monospaced (table cells, inline rates).
        static let monoSmall = SwiftUI.Font.system(.caption, design: .monospaced)
    }
}

// =============================================================================
// MARK: - Formatters
// =============================================================================

/// A `Sendable` box that serializes access to a non-`Sendable` formatter with a
/// lock, so a single configured instance can be shared across actors safely.
private final class LockedFormatter<F>: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: F

    init(_ make: () -> F) { self.formatter = make() }

    func use<R>(_ body: (F) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(formatter)
    }
}

/// Byte and rate formatting helpers shared across the dashboard and menu.
enum ByteFormatter {
    private static let countFormatter = LockedFormatter<ByteCountFormatter> {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter
    }

    /// Formats a byte count, e.g. `1.2 MB`.
    static func string(fromBytes bytes: Int64) -> String {
        countFormatter.use { $0.string(fromByteCount: max(0, bytes)) }
    }

    /// Formats a transfer rate, e.g. `1.2 MB/s`. `bytesPerSecond` is the bytes
    /// transferred over the last one-second interval.
    static func rateString(bytesPerSecond bytes: Int64) -> String {
        "\(string(fromBytes: bytes))/s"
    }
}

/// Human-readable connection-age formatting from an RFC 3339 start timestamp.
enum DurationFormatter {
    private static let parser = LockedFormatter<ISO8601DateFormatter> {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static let parserNoFraction = LockedFormatter<ISO8601DateFormatter> {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Parses an RFC 3339 timestamp string (with or without fractional seconds).
    static func date(fromRFC3339 string: String) -> Date? {
        parser.use { $0.date(from: string) } ?? parserNoFraction.use { $0.date(from: string) }
    }

    /// Compact elapsed-time string since `start`, e.g. `12s`, `3m`, `1h2m`.
    /// Returns `"—"` when the timestamp cannot be parsed.
    static func ageString(sinceRFC3339 start: String, now: Date = Date()) -> String {
        guard let startDate = date(fromRFC3339: start) else { return "—" }
        return ageString(seconds: max(0, now.timeIntervalSince(startDate)))
    }

    /// Compact elapsed-time string from a raw second count.
    static func ageString(seconds rawSeconds: TimeInterval) -> String {
        let total = Int(rawSeconds)
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 {
            return remMinutes == 0 ? "\(hours)h" : "\(hours)h\(remMinutes)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d\(remHours)h"
    }
}

// =============================================================================
// MARK: - StatusPill
// =============================================================================

/// Semantic status for `StatusPill`, mapping to a color + SF Symbol.
enum StatusKind {
    case active
    case inactive
    case error
    case warning

    var color: Color {
        switch self {
        case .active: return Theme.Color.active
        case .inactive: return Theme.Color.inactive
        case .error: return Theme.Color.error
        case .warning: return Theme.Color.warning
        }
    }

    var symbolName: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .inactive: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }
}

/// A colored capsule with an SF Symbol and a label — the canonical way to show
/// core / proxy status. Tinted to the status color with a soft fill.
struct StatusPill: View {
    let kind: StatusKind
    let title: String
    /// Optional override symbol; defaults to the kind's symbol.
    var symbolName: String?

    init(_ title: String, kind: StatusKind, symbolName: String? = nil) {
        self.title = title
        self.kind = kind
        self.symbolName = symbolName
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs + 2) {
            Image(systemName: symbolName ?? kind.symbolName)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(Theme.Font.caption.weight(.medium))
        }
        .foregroundStyle(kind.color)
        .padding(.horizontal, Theme.Spacing.xs + 2)
        .padding(.vertical, Theme.Spacing.xxs + 1)
        .background(kind.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(kind.color.opacity(0.22), lineWidth: 1))
    }
}

// =============================================================================
// MARK: - Card
// =============================================================================

/// A rounded container backed by a system material with a subtle hairline
/// border. The native "surface" primitive — group related content in one of
/// these rather than nesting boxes inside boxes.
struct Card<Content: View>: View {
    var padding: CGFloat
    var material: Material
    @ViewBuilder var content: () -> Content

    init(
        padding: CGFloat = Theme.Spacing.md,
        material: Material = .regularMaterial,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.material = material
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(material, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.Color.cardBorder, lineWidth: 1)
            )
    }
}

// =============================================================================
// MARK: - MetricView
// =============================================================================

/// A big monospaced number with a caption underneath, for traffic rates and
/// totals. Optional SF Symbol + tint marks direction (up/down).
struct MetricView: View {
    let value: String
    let caption: String
    var symbolName: String?
    var tint: Color = Theme.Color.label

    init(value: String, caption: String, symbolName: String? = nil, tint: Color = Theme.Color.label) {
        self.value = value
        self.caption = caption
        self.symbolName = symbolName
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xxs + 2) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.headline)
                        .foregroundStyle(tint)
                }
                Text(value)
                    .font(Theme.Font.metric)
                    .foregroundStyle(Theme.Color.label)
            }
            Text(caption)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Color.secondaryLabel)
        }
    }
}

// =============================================================================
// MARK: - SectionHeader
// =============================================================================

/// A section heading with an optional SF Symbol and trailing accessory
/// (e.g. a count badge or an action button).
struct SectionHeader<Accessory: View>: View {
    let title: String
    var symbolName: String?
    @ViewBuilder var accessory: () -> Accessory

    init(
        _ title: String,
        symbolName: String? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.symbolName = symbolName
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.accent)
            }
            Text(title)
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.Color.label)
            Spacer(minLength: Theme.Spacing.xs)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, symbolName: String? = nil) {
        self.init(title, symbolName: symbolName, accessory: { EmptyView() })
    }
}

/// A small pill-shaped count badge, e.g. for "connections: 12".
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(Theme.Font.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(Theme.Color.secondaryLabel)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .background(Theme.Color.hover, in: Capsule())
    }
}

// =============================================================================
// MARK: - Row primitives
// =============================================================================

/// A leading SF Symbol + title (+ optional subtitle) and a trailing accessory.
/// The native list-row primitive used across the menu and dashboard.
struct Row<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var symbolName: String?
    var tint: Color
    @ViewBuilder var accessory: () -> Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        tint: Color = Theme.Color.secondaryLabel,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.tint = tint
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 20, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Font.bodyEmphasized)
                    .foregroundStyle(Theme.Color.label)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.secondaryLabel)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            accessory()
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

extension Row where Accessory == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        symbolName: String? = nil,
        tint: Color = Theme.Color.secondaryLabel
    ) {
        self.init(
            title,
            subtitle: subtitle,
            symbolName: symbolName,
            tint: tint,
            accessory: { EmptyView() }
        )
    }
}

// =============================================================================
// MARK: - HoverHighlight
// =============================================================================

/// Applies a rounded hover highlight — the native "row reacts to the pointer"
/// affordance. Attach to interactive rows/buttons.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.medium
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Theme.Color.hover : SwiftUI.Color.clear)
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Adds a rounded hover highlight behind this view.
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.medium) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
