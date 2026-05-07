import SwiftUI
import UIKit

// MARK: - UIActivityViewController bridge

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Share helpers

enum HyperionShare {

    /// Plain-text "Now Playing" share string for a track.
    static func nowPlayingText(track: Track) -> String {
        var parts: [String] = []
        if let artist = track.trackartist ?? track.albumartist { parts.append(artist) }
        parts.append(track.title)
        if let album = track.album { parts.append("(\(album))") }
        let body = parts.joined(separator: " – ")
        let link = deeplink(for: track)
        return "\(body)\n\(link)"
    }

    /// Deep-link URL for a track. Opens Hyperion on another device.
    static func deeplink(for track: Track) -> URL {
        var comps = URLComponents()
        comps.scheme = "hyperion"
        comps.host   = "track"
        comps.path   = "/\(track.id)"
        return comps.url ?? URL(string: "hyperion://track/\(track.id)")!
    }

    /// Plain-text share string for an album.
    static func albumText(album: Album) -> String {
        var parts: [String] = []
        if let artist = album.artist { parts.append(artist) }
        parts.append(album.album)
        if let year = album.year, year > 0 { parts.append("(\(year))") }
        return parts.joined(separator: " – ")
    }
}

// MARK: - Share button view (reusable)

struct ShareTrackButton: View {
    let track: Track
    @State private var showSheet = false

    var body: some View {
        Button {
            Haptics.light()
            showSheet = true
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .sheet(isPresented: $showSheet) {
            ShareSheet(items: [HyperionShare.nowPlayingText(track: track)])
                .ignoresSafeArea()
        }
    }
}
