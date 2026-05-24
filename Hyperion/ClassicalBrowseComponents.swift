import SwiftUI

// MARK: - Shared sort logic for ensemble / conductor album grids

enum ClassicalAlbumSort: String, CaseIterable, Identifiable {
    case yearDescending   = "Year"
    case composer         = "Composer"
    case alphabetical     = "Title"

    var id: String { rawValue }

    static func sorted(_ albums: [Album], by order: ClassicalAlbumSort) -> [Album] {
        switch order {
        case .yearDescending:
            // Newest first; albums without a year sink to the bottom.
            return albums.sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        case .composer:
            return albums.sorted {
                let a = $0.composer ?? ""
                let b = $1.composer ?? ""
                let primary = a.localizedCaseInsensitiveCompare(b)
                if primary != .orderedSame { return primary == .orderedAscending }
                return $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending
            }
        case .alphabetical:
            return albums.sorted {
                $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending
            }
        }
    }
}

struct ClassicalAlbumSortPicker: View {
    @Binding var sortOrder: ClassicalAlbumSort

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClassicalAlbumSort.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { sortOrder = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.roonBody(12, weight: sortOrder == option ? .semibold : .regular))
                            .foregroundColor(sortOrder == option ? .roonBase : .roonSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(sortOrder == option ? Color.roonAccent : Color.roonElevated)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Reusable album grid card for classical browse destinations

struct ClassicalAlbumGridCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ArtworkView(coverid: album.artwork_track_id, size: 320) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.album)
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
                if let composer = album.composer, !composer.isEmpty {
                    Text(composer)
                        .font(.roonBody(12))
                        .foregroundColor(.roonSecondary)
                        .lineLimit(1)
                } else if let year = album.year, year > 0 {
                    Text(String(year))
                        .font(.roonMono(12))
                        .foregroundColor(.roonTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}
