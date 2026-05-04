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

    // Accent — ARC uses muted olive-green
    static let roonAccent   = Color(hex: "#8db84a")

    // Quality indicators
    static let roonQualityGreen  = Color(red: 0.20, green: 0.85, blue: 0.40)
    static let roonQualityPurple = Color(hex: "#8db84a")

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

// MARK: - Typography tokens

extension Font {
    /// Serif title font — track/work/composer headings.
    static func roonTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Default body font — labels, descriptions, UI copy.
    static func roonBody(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced font — time displays and track numbers.
    static func roonMono(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
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
