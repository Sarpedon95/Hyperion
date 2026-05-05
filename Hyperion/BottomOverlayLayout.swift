import SwiftUI

// MARK: - Global bottom overlay layout

/// Height reserved by app-level bottom chrome (mini-player, custom tab bar,
/// home indicator fill, and any future bottom overlays).  Scrollable screens
/// consume this through `bottomOverlayAwareScroll()` so the last row/card can
/// always scroll fully above the mini-player instead of relying on one-off
/// padding constants in individual views.
private struct HyperionBottomOverlayHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var hyperionBottomOverlayHeight: CGFloat {
        get { self[HyperionBottomOverlayHeightKey.self] }
        set { self[HyperionBottomOverlayHeightKey.self] = max(0, newValue) }
    }
}

private struct BottomOverlayAwareScrollModifier: ViewModifier {
    @Environment(\.hyperionBottomOverlayHeight) private var bottomOverlayHeight
    let extra: CGFloat

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: max(0, bottomOverlayHeight + extra))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Reserve room for Hyperion's app-level bottom chrome in any vertical
    /// `ScrollView` or `List`.  The value is environment-driven, so it updates
    /// when the mini-player appears/disappears, across device safe areas,
    /// rotation, and pushed NavigationStack destinations.
    func bottomOverlayAwareScroll(extra: CGFloat = 0) -> some View {
        modifier(BottomOverlayAwareScrollModifier(extra: extra))
    }
}
