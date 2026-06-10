import SwiftUI

/// Visual badge overlay indicating a streaming service (Tidal, Qobuz, Deezer).
/// Displayed in bottom-left corner of album artwork with service-specific branding colors.
struct StreamingServiceBadge: View {
    let service: StreamSourceType
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(backgroundColor)
                .shadow(color: Color.black.opacity(0.3), radius: size * 0.08, x: 0, y: size * 0.08)

            Text(service.badgeLabel)
                .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                .foregroundColor(foregroundColor)
                .lineLimit(1)
        }
        .frame(width: size, height: size * 0.8)
    }

    private var backgroundColor: Color {
        switch service {
        case .tidal, .squid:
            return Color(red: 0, green: 0, blue: 0) // Black
        case .qobuz:
            return Color(red: 0, green: 0.17, blue: 0.36) // #002B5C
        case .deezer:
            return Color(red: 0.635, green: 0.22, blue: 1) // #A238FF
        case .local:
            return .clear
        }
    }

    private var foregroundColor: Color {
        switch service {
        case .deezer:
            return .white
        case .qobuz, .tidal, .squid:
            return .white
        case .local:
            return .clear
        }
    }
}

extension StreamSourceType {
    var badgeLabel: String {
        switch self {
        case .tidal:
            return "TIDAL"
        case .qobuz:
            return "Qobuz"
        case .deezer:
            return "Deezer"
        case .squid:
            return "Squid"
        case .local:
            return ""
        }
    }

    var brandColor: Color {
        switch self {
        case .tidal, .squid:
            return Color(red: 0, green: 0, blue: 0)
        case .qobuz:
            return Color(red: 0, green: 0.17, blue: 0.36)
        case .deezer:
            return Color(red: 0.635, green: 0.22, blue: 1)
        case .local:
            return .clear
        }
    }
}

// MARK: - Badge Overlay Modifier

struct ServiceBadgeOverlay: ViewModifier {
    let service: StreamSourceType?
    let size: CGSize

    func body(content: Content) -> some View {
        ZStack(alignment: .bottomLeading) {
            content

            if let service = service, service != .local {
                StreamingServiceBadge(service: service, size: size.width * 0.22)
                    .padding(size.width * 0.05)
            }
        }
    }
}

extension View {
    /// Overlays a streaming service badge in the bottom-left corner of the view.
    /// Badge only appears for non-local streaming services.
    func withServiceBadge(_ service: StreamSourceType?, size: CGSize) -> some View {
        modifier(ServiceBadgeOverlay(service: service, size: size))
    }
}
