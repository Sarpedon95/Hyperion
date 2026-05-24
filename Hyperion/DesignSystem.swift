import SwiftUI
import UIKit

// MARK: - Roon-inspired design tokens

extension Color {

    // Backgrounds — Roon ARC dark olive/green theme
    static let roonBase     = Color(hex: "#1a1e14")   // deep olive-black
    static let roonSurface  = Color(hex: "#232a1b")   // surface olive
    static let roonElevated = Color(hex: "#2c3522")   // elevated olive

    // Borders / separators
    static let roonBorder   = Color(white: 1, opacity: 0.07)
    static let roonDivider  = Color(white: 1, opacity: 0.11)

    // Accent — Roon Arc coral/red
    static let roonAccent   = Color(hex: "#C0392B")

    // Quality indicators
    static let roonQualityGreen  = Color(hex: "#4CAF50")   // lossless / hi-res
    static let roonQualityAmber  = Color(hex: "#F59E0B")   // lossy / transcoded
    static let roonQualityPurple = Color(hex: "#F59E0B")   // legacy alias → amber

    // Text hierarchy
    static let roonPrimary   = Color.white
    static let roonSecondary = Color(white: 1, opacity: 0.55)
    static let roonTertiary  = Color(white: 1, opacity: 0.30)

    // MARK: Hex initialiser
    // BUGFIX: verify scanner consumed all 6 hex characters.
    // Invalid hex (e.g. "GGGGGG") previously produced silent black.
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        let scanner = Scanner(string: h)

        guard h.count == 6,
              scanner.scanHexInt64(&rgb),
              scanner.currentIndex == h.endIndex else {
            self.init(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
            return
        }

        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >>  8) & 0xFF) / 255
        let b = Double( rgb        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Typography tokens — Dynamic Type aware
//
// All Hyperion text routes through three factories that take a raw point size
// (preserving the original visual layout) and return a Font whose point size
// has been scaled by `UIFontMetrics(forTextStyle:)`. The size is recomputed
// every time SwiftUI rebuilds the view, so Dynamic Type changes propagate.
//
// Why UIFontMetrics for all three: SwiftUI's `Font.system(size:relativeTo:)`
// only accepts the default design family, so we can't use it for `.serif`
// (roonTitle) or `.monospaced` (roonMono). To keep behaviour consistent,
// `roonBody` also goes through UIFontMetrics rather than mixing two
// scaling APIs.
//
// Mapping (point size → UIFont.TextStyle anchor for scaling):
//   ≥34: .largeTitle  ≥28: .title1    ≥22: .title2   ≥20: .title3
//   ≥17: .body        ≥15: .callout   ≥13: .subheadline
//   ≥12: .footnote    ≥11: .caption1  otherwise: .caption2

extension Font {

    /// Maps a raw point size to the closest standard UIFont.TextStyle so the
    /// font scales with Dynamic Type while preserving the visual hierarchy.
    fileprivate static func uiKitTextStyle(forPointSize size: CGFloat) -> UIFont.TextStyle {
        switch size {
        case 34...:   return .largeTitle
        case 28..<34: return .title1
        case 22..<28: return .title2
        case 20..<22: return .title3
        case 17..<20: return .body
        case 15..<17: return .callout
        case 13..<15: return .subheadline
        case 12..<13: return .footnote
        case 11..<12: return .caption1
        default:      return .caption2
        }
    }

    /// UIFontMetrics-scaled point size, anchored to the matched text style.
    /// Pure function — re-runs each SwiftUI redraw so it picks up Dynamic
    /// Type changes automatically.
    fileprivate static func scaledPointSize(_ size: CGFloat) -> CGFloat {
        let style = uiKitTextStyle(forPointSize: size)
        return UIFontMetrics(forTextStyle: style).scaledValue(for: size)
    }

    /// Serif title font — track/work/composer headings. Scales with Dynamic Type.
    static func roonTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: scaledPointSize(size), weight: weight, design: .serif)
    }

    /// Default body font — labels, descriptions, UI copy. Scales with Dynamic Type.
    static func roonBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaledPointSize(size), weight: weight, design: .default)
    }

    /// Monospaced font — time displays, track numbers, and compact controls.
    /// Scales with Dynamic Type.
    static func roonMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaledPointSize(size), weight: weight, design: .monospaced)
    }
}

// MARK: - ScaledFont view modifier (explicit anchor variant)
//
// For text whose call site wants to control the Dynamic Type anchor
// independently of the base point size (e.g. a small "caption" that should
// still scale at the body rate). Observes `dynamicTypeSize` directly so
// SwiftUI recomputes the size when the user changes Settings.

private struct ScaledFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let textStyle: UIFont.TextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let scaled  = metrics.scaledValue(for: size)
        content.font(.system(size: scaled, weight: weight, design: design))
    }
}

extension View {
    /// Drop-in alternative to `.font(.roonBody(size, weight:))` that takes an
    /// explicit Dynamic Type anchor. Useful for hero titles where the body
    /// anchor would scale too aggressively, or icons sized in points.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo style: UIFont.TextStyle = .body
    ) -> some View {
        modifier(ScaledFontModifier(size: size, weight: weight, design: design, textStyle: style))
    }
}

// MARK: - Quality badge view

struct QualityBadge: View {
    enum Level {
        case lossless
        case hiRes
        case standard

        var label: String {
            switch self {
            case .lossless: return "Lossless"
            case .hiRes:    return "Hi-Res"
            case .standard: return "Standard"
            }
        }

        var dotColor: Color {
            switch self {
            case .lossless: return .roonQualityGreen
            case .hiRes:    return .roonQualityPurple
            case .standard: return .roonTertiary
            }
        }
    }

    let level: Level

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(level.dotColor)
                .frame(width: 7, height: 7)
            Text(level.label)
                .font(.roonBody(13, weight: .semibold))
                .foregroundColor(.roonPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.roonSurface)
        .clipShape(Capsule())
    }
}

// MARK: - Haptic feedback helpers

// PERF: UIImpactFeedbackGenerator is expensive to allocate per-tap.
// These shared instances are created once and reused.
// UIKit feedback generators are not thread-safe; @MainActor ensures that.

@MainActor
enum Haptics {
    private static let _light  = UIImpactFeedbackGenerator(style: .light)
    private static let _medium = UIImpactFeedbackGenerator(style: .medium)
    private static let _heavy  = UIImpactFeedbackGenerator(style: .heavy)

    /// Tap confirmation, list selection, minor actions.
    static func light()  { _light.impactOccurred() }
    /// Significant actions: play, skip, drag-drop release.
    static func medium() { _medium.impactOccurred() }
    /// Destructive / irreversible actions.
    static func heavy()  { _heavy.impactOccurred() }
}
