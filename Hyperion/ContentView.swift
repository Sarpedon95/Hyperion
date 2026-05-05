import SwiftUI
import UIKit
import ImageIO

struct ContentView: View {

    @StateObject private var player     = PlayerViewModel.shared
    @StateObject private var library    = LibraryViewModel.shared
    @StateObject private var connection = ConnectionManager.shared
    @StateObject private var orpheus    = OrpheusDSPEngine.shared

    @State private var selectedTab: Tab = .home
    @State private var showingNowPlaying: Bool = false
    /// Set to true after the first launch restore attempt so we only show
    /// the resume banner once per cold start.
    @State private var didAttemptRestore: Bool = false
    /// True while the "Resume where you left off" banner is visible.
    @State private var showResumeBanner: Bool = false
    /// Snapshot track title shown in the resume banner.
    @State private var resumeTrackTitle: String = ""
    /// Task for auto-dismissing the resume banner (can be cancelled if user dismisses manually).
    @State private var resumeBannerTask: Task<Void, Never>?
    /// Track whether initial data load has completed to prevent rapid tab switching during initialization.
    @State private var isInitialized: Bool = false

    enum Tab { case home, search, library, queue, orpheus }

    private let tabBarHeight: CGFloat     = 56
    private let miniPlayerHeight: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Bedrock — covers every pixel including status bar and
                // home indicator zones so there is never a black strip anywhere.
                Color.roonBase.ignoresSafeArea()

                // Tab content — we ignoresSafeArea on the top edge so the
                // NavigationStack doesn't add an inset gap above its content.
                // Each tab's ScrollView handles its own top padding via
                // .safeAreaInset or explicit padding so content stays below
                // the status bar / Dynamic Island.
                activeTabView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .top)
                    // Push scroll content clear of our custom bottom chrome.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: bottomChromeHeight(geo: geo))
                    }

                // Custom bottom chrome — extends physically into the
                // home-indicator zone via ignoresSafeArea(.bottom).
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.roonBorder)
                        .frame(height: 0.5)

                    if player.currentTrack != nil {
                        MiniPlayerView(showingNowPlaying: $showingNowPlaying)
                            .frame(height: miniPlayerHeight)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    tabBar
                        .frame(height: tabBarHeight)

                    // Explicitly fill the home-indicator inset with surface
                    // colour so it's never black or mismatched.
                    Color.roonSurface
                        .frame(height: geo.safeAreaInsets.bottom)
                }
                .background(Color.roonSurface)
                .ignoresSafeArea(edges: .bottom)

                // Error banner — floats above everything
                if let playerError = player.error {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 16))
                            Text(playerError)
                                .font(.roonBody(13))
                                .foregroundColor(.roonPrimary)
                                .lineLimit(2)
                            Spacer()
                            Button(action: { player.error = nil }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.roonTertiary)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let libError = library.error {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 16))
                            Text(libError)
                                .font(.roonBody(13))
                                .foregroundColor(.roonPrimary)
                                .lineLimit(2)
                            Spacer()
                            Button(action: { library.error = nil }) {
                                Image(systemName: "xmark")
                                    .foregroundColor(.roonTertiary)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.12))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Resume-session banner — floats above the mini-player.
                if showResumeBanner {
                    ResumeBannerView(
                        trackTitle: resumeTrackTitle,
                        onResume: {
                            resumeBannerTask?.cancel()
                            resumeBannerTask = nil
                            showResumeBanner = false
                            player.resume()
                            showingNowPlaying = true
                        },
                        onDismiss: {
                            resumeBannerTask?.cancel()
                            resumeBannerTask = nil
                            showResumeBanner = false
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, bottomChromeHeight(geo: geo) + 8)
                    .padding(.horizontal, 16)
                }
            }
        }
        // The outer GeometryReader must also ignore safe areas so it measures
        // the full screen and the ZStack fills edge-to-edge.
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showingNowPlaying) { NowPlayingView() }
        .task {
            // Mark the tab bar interactive immediately — each tab shows its own
            // loading/empty state while data arrives. Waiting for all network
            // loads here previously disabled the tab bar for 15+ seconds on a
            // slow or temporarily unreachable server.
            isInitialized = true

            // ConnectionManager.init() already sets baseURL from saved UserDefaults,
            // so API calls succeed immediately with the cached URL without waiting for
            // a full network probe. Start library warm-up immediately, but only await
            // connection resolution before the restore banner so a large library does
            // not delay “Resume where you left off”.
            async let resolve: Void              = connection.resolveConnection()
            async let composersWarmup: Void      = library.loadComposers()
            async let recentAlbumsWarmup: Void   = library.loadRecentAlbums()
            async let recentlyPlayedWarmup: Void = library.loadRecentlyPlayed()

            await resolve
            guard !Task.isCancelled else { return }

            // Attempt to restore the previous playback session exactly once
            // per cold start, after the connection URL is confirmed.
            if !didAttemptRestore {
                didAttemptRestore = true
                if player.queue.isEmpty {
                    // Only restore if the user hasn't already started playback
                    // (e.g. from a deep link or CarPlay before the view appeared).
                    if let snap = PlaybackStateStore.shared.loadSnapshot(),
                       !snap.queue.isEmpty {
                        let restored = player.restoreLastSession()
                        if restored, let title = player.currentTrack?.title {
                            resumeTrackTitle = title
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                showResumeBanner = true
                            }
                            // Auto-dismiss the banner after 7 seconds if the
                            // user hasn't tapped anything. Use a stored task so
                            // it can be cancelled if user dismisses manually.
                            resumeBannerTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 7_000_000_000)
                                guard !Task.isCancelled else { return }
                                withAnimation { showResumeBanner = false }
                                resumeBannerTask = nil
                            }
                        }
                    }
                }
            }

            // Keep the startup task alive long enough to observe warm-up
            // cancellation, but do not block any visible interaction or restore UI.
            _ = await (composersWarmup, recentAlbumsWarmup, recentlyPlayedWarmup)
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            resumeBannerTask?.cancel()
            resumeBannerTask = nil
        }
        .animation(.easeInOut(duration: 0.2), value: player.currentTrack != nil)
    }

    /// Height that scroll views should reserve at the bottom so content
    /// isn't hidden behind the chrome (includes home-indicator inset).
    private func bottomChromeHeight(geo: GeometryProxy) -> CGFloat {
        let miniH = player.currentTrack != nil ? miniPlayerHeight : 0
        return miniH + tabBarHeight + geo.safeAreaInsets.bottom
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            RoonTabButton(icon: "house",           selectedIcon: "house.fill",              tab: .home,    selected: $selectedTab)
            RoonTabButton(icon: "magnifyingglass", selectedIcon: "magnifyingglass.circle.fill", tab: .search,  selected: $selectedTab)
            RoonTabButton(icon: "books.vertical",  selectedIcon: "books.vertical.fill",     tab: .library, selected: $selectedTab)
            // PASS 6 — selected Queue icon now switches to a filled rect-list
            // variant so the user gets the same visual feedback as the other
            // tabs. Previously both states used `list.bullet` so the active
            // state was indicated by colour only — failed accessibility's
            // recommendation to not rely on colour alone.
            RoonTabButton(icon: "list.bullet",     selectedIcon: "list.bullet.rectangle.fill", tab: .queue,   selected: $selectedTab)
            RoonTabButton(icon: "waveform",        selectedIcon: "waveform.circle.fill",        tab: .orpheus, selected: $selectedTab)
        }
        .disabled(!isInitialized)
    }

    @ViewBuilder
    private var activeTabView: some View {
        switch selectedTab {
        case .home:    HomeView()
        case .search:  SearchView()
        case .library: LibraryView()
        case .queue:   QueueView()
        case .orpheus: OrpheusView()
        }
    }
}

// MARK: - Tab bar button

struct RoonTabButton: View {
    let icon: String
    let selectedIcon: String
    let tab: ContentView.Tab
    @Binding var selected: ContentView.Tab

    private var isSelected: Bool { selected == tab }

    /// PASS 6 — accessibility label for VoiceOver. The icon-only tab buttons
    /// would otherwise read out the SF Symbol name to users.
    private var accessibilityName: String {
        switch tab {
        case .home:    return "Home"
        case .search:  return "Search"
        case .library: return "Library"
        case .queue:   return "Queue"
        case .orpheus: return "Orpheus"
        }
    }

    var body: some View {
        Button {
            if selected != tab {
                Haptics.light()
            }
            selected = tab
        } label: {
            Image(systemName: isSelected ? selectedIcon : icon)
                .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .roonAccent : .roonTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

// MARK: - Mini player

struct MiniPlayerView: View {

    @Binding var showingNowPlaying: Bool
    @ObservedObject private var player = PlayerViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.roonBorder)
                    Rectangle()
                        .fill(Color.roonAccent)
                        .frame(width: geo.size.width * CGFloat(min(max(player.progress, 0), 1)))
                        // PASS 6 — also key the animation on track id so the
                        // progress strip snaps to 0 (no animation) when the
                        // track changes, instead of visibly animating
                        // backward from the previous track's progress.
                        .animation(.linear(duration: 0.5), value: player.progress)
                        .id(player.currentTrack?.id ?? -1)
                }
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ArtworkView(coverid: player.currentTrack?.coverid, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "")
                            .font(.roonBody(14, weight: .semibold))
                            .foregroundColor(.roonPrimary)
                            .lineLimit(1)
                            // POLISH: slide-in when the track changes so text
                            // transitions smoothly rather than snapping.
                            .transition(.push(from: .trailing))
                            .id(player.currentTrack?.id)
                        Text(player.currentTrack?.composer ?? player.currentTrack?.albumartist ?? "")
                            .font(.roonBody(12))
                            .foregroundColor(.roonSecondary)
                            .lineLimit(1)
                            .transition(.push(from: .trailing))
                            .id(player.currentTrack?.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { showingNowPlaying = true }

                Button {
                    Haptics.light()
                    player.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.roonSecondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous track")

                Button {
                    Haptics.medium()
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.roonPrimary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    Haptics.light()
                    player.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.roonSecondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next track")
                .padding(.trailing, 8)
            }
            .frame(height: 62)
        }
        .background(Color.roonSurface)
    }
}

// MARK: - Artwork image cache
//
// PASS 6 — single unified, downsampling-aware artwork cache.
//
// Previously the app maintained two parallel NSCaches: ArtworkCache.shared
// (keyed by coverid) and PlayerViewModel.artworkCache (keyed by URL). Same
// data was decoded twice and held twice in memory. Worse, both caches stored
// full-resolution images — Pristine FLAC artwork can be 3000×3000+, so a
// scrolled grid of cells would each pay tens of MB of memory + decode CPU
// for what gets shown at 148 pt.
//
// The new pipeline:
//   1. ArtworkCache.shared owns the only NSCache. Keys include a target-pixel
//      bucket (per coverid + size bucket), so we can keep a ~144pt thumbnail
//      AND a ~1024pt full-screen artwork side-by-side without either evicting
//      the other on every scroll.
//   2. Loader uses ImageIO `CGImageSourceCreateThumbnailAtIndex` to decode at
//      the target pixel size in one pass — no full decode, no later scaling.
//   3. In-flight requests for the same key are coalesced through one task per
//      key, so a fast-scrolling LazyVGrid does not issue duplicate downloads.
//   4. PlayerViewModel.loadImage(from:) is preserved as a public API and now
//      delegates to ArtworkCache for the lock-screen + blurred-background
//      callers. Lock-screen artwork is requested at 600pt, which is what
//      MPNowPlayingInfoCenter actually displays.
//
// NSCache cost is set to RGBA byte size (width * height * 4) so the system
// evicts in proportion to actual memory pressure.

@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Monotonically-incrementing token assigned to each in-flight load.
    /// On completion we only clear `inFlight[key]` if its associated token
    /// matches ours, preventing a completing task from clobbering a newer
    /// load that started for the same key (e.g. after a memory warning).
    private var inFlightToken: [String: UInt64] = [:]
    private var nextInFlightToken: UInt64 = 0
    private var missingArtworkUntil: [String: Date] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    /// Shared session for artwork downloads.
    /// Configured to allow a few parallel connections per host so a freshly
    /// scrolled grid populates quickly without storming the LMS server.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        // Let URLSession manage its own on-disk artwork cache as a second
        // layer behind our in-memory NSCache. ~50 MB disk is plenty.
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity:  4 * 1024 * 1024,
            diskCapacity:   50 * 1024 * 1024,
            diskPath: "hyperion-artwork"
        )
        return URLSession(configuration: config)
    }()

    private init() {
        // ~80 MB of decoded artwork ceiling. With downsampling enabled, that's
        // hundreds of thumbnails or ~80 large hero images. NSCache evicts
        // automatically under memory pressure.
        cache.countLimit     = 400
        cache.totalCostLimit = 80 * 1024 * 1024

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees main-thread delivery; use assumeIsolated for
            // immediate synchronous execution so caches are freed without an extra
            // async dispatch (important under real memory pressure).
            MainActor.assumeIsolated { [weak self] in
                self?.inFlight.values.forEach { $0.cancel() }
                self?.inFlight.removeAll()
                self?.inFlightToken.removeAll()
                self?.missingArtworkUntil.removeAll()
                self?.clear()
            }
        }
    }

    /// Returns a cache key combining coverid (or URL) with a target-pixel
    /// bucket. We bucket to powers of two so a 148pt thumbnail and a 152pt
    /// thumbnail share an entry instead of fighting for cache slots.
    private static func cacheKey(identifier: String, targetPixels: Int) -> String {
        let bucket = bucketed(targetPixels)
        return "\(identifier)@\(bucket)"
    }

    private static func bucketed(_ pixels: Int) -> Int {
        // Round up to nearest 256-pixel bucket: 256, 512, 768, 1024, 1280, ...
        // Capped at 2048 — beyond that we return originals (rare).
        let rounded = ((max(1, pixels) + 255) / 256) * 256
        return min(rounded, 2048)
    }

    func cachedImage(coverid: String, targetPoints: CGFloat, scale: CGFloat) -> UIImage? {
        guard !coverid.isEmpty,
              let url = LyrionAPI.shared.artworkURL(coverid: coverid) else { return nil }
        let pixels = Int((targetPoints * scale).rounded(.up))
        let key = Self.cacheKey(identifier: url.absoluteString, targetPixels: pixels)
        guard !isTemporarilyMissing(key) else { return nil }
        return cache.object(forKey: key as NSString)
    }

    /// Loads (or returns cached) artwork for a coverid at the target display
    /// size. Decoding happens off the main thread via ImageIO. The returned
    /// image is sized for `targetPoints` rendered at `scale` and ready to
    /// hand straight to UIKit/SwiftUI without further decode work.
    func loadImage(coverid: String, targetPoints: CGFloat, scale: CGFloat) async -> UIImage? {
        guard !coverid.isEmpty,
              let url = LyrionAPI.shared.artworkURL(coverid: coverid) else { return nil }
        let pixels = Int((targetPoints * scale).rounded(.up))
        let key = Self.cacheKey(identifier: url.absoluteString, targetPixels: pixels)

        guard !isTemporarilyMissing(key) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        return await loadAndCache(key: key, url: url, targetPixels: pixels)
    }

    /// URL-keyed convenience for callers (Now Playing background, lock-screen
    /// artwork) that already have a URL rather than a coverid. Internally
    /// keys the cache by URL absoluteString.
    func loadImage(url: URL, targetPoints: CGFloat, scale: CGFloat) async -> UIImage? {
        let pixels = Int((targetPoints * scale).rounded(.up))
        let key = Self.cacheKey(identifier: url.absoluteString, targetPixels: pixels)
        guard !isTemporarilyMissing(key) else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }
        return await loadAndCache(key: key, url: url, targetPixels: pixels)
    }

    private func isTemporarilyMissing(_ key: String) -> Bool {
        guard let until = missingArtworkUntil[key] else { return false }
        if until > Date() { return true }
        missingArtworkUntil[key] = nil
        return false
    }

    private func loadAndCache(key: String, url: URL, targetPixels: Int) async -> UIImage? {
        // Capture HTTP headers on the main actor (LyrionAPI is @MainActor).
        let headers = LyrionAPI.shared.httpHeaders(accept: "image/*,*/*")
        let session = self.session
        let bucket  = Self.bucketed(targetPixels)

        // Hop OFF the main actor for the network fetch + ImageIO decode. This
        // is the whole point of downsampling — keeping it on @MainActor would
        // re-introduce the very main-thread stall we're trying to fix.
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.cachePolicy = .returnCacheDataElseLoad

            do {
                let (data, response) = try await session.data(for: request)
                if Task.isCancelled { return nil }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    return nil
                }
                return Self.downsampledImage(from: data, maxPixelSize: bucket)
            } catch {
                return nil
            }
        }
        nextInFlightToken &+= 1
        let myToken = nextInFlightToken
        inFlight[key]      = task
        inFlightToken[key] = myToken

        let image = await task.value

        // Only commit the result if this is still the latest load for `key`.
        // A memory warning or a newer request may have cancelled/removed our token;
        // in that case a nil result should not become a five-minute missing-art mark.
        guard inFlightToken[key] == myToken else { return image }
        inFlight[key]      = nil
        inFlightToken[key] = nil

        if let image {
            missingArtworkUntil[key] = nil
            let cgWidth  = image.cgImage?.width  ?? Int(image.size.width  * image.scale)
            let cgHeight = image.cgImage?.height ?? Int(image.size.height * image.scale)
            let cost = max(1, cgWidth * cgHeight * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            // Missing art is common on LMS. Avoid hammering /music/<id>/cover.jpg
            // every time a recycled cell appears; retry later in case scans update.
            missingArtworkUntil[key] = Date().addingTimeInterval(5 * 60)
        }
        return image
    }

    /// ImageIO-based downsampling. Decodes the image at exactly the requested
    /// max dimension, skipping the full-res decode entirely. This is what
    /// makes scrolling a 200-album grid feasible on older phones.
    private nonisolated static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return UIImage(data: data)
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately:         true,
            kCGImageSourceCreateThumbnailWithTransform:   true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    func clear() {
        cache.removeAllObjects()
        missingArtworkUntil.removeAll()
    }
}

// MARK: - Artwork view

struct ArtworkView: View {

    let coverid: String?
    let size: CGFloat
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @ObservedObject private var connection = ConnectionManager.shared

    @State private var image: UIImage?        = nil
    @State private var loadedTaskKey: String? = nil

    /// Composite task identity: changing either coverid or the visible size
    /// (bucketed to 16pt steps so micro-changes don't churn the task) will
    /// kick off a new load. This handles the GeometryReader 0→full-size
    /// first-paint case correctly without re-firing the task on every
    /// fractional layout-system size update.
    private var taskKey: String {
        let bucket = Int((max(0, size) / 16).rounded())
        return "\(connection.currentURL)|\(coverid ?? "")|\(bucket)"
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    // POLISH: gentle fade-in when artwork resolves. Without
                    // this, cached cells flash visibly as they pop into the
                    // viewport during fast scrolls.
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(Color.roonElevated)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.35))
                            .foregroundColor(.roonTertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .background(Color.roonElevated)
        .clipped()
        .task(id: taskKey) { await loadArtwork(for: coverid) }
    }

    private func loadArtwork(for requestedCoverid: String?) async {
        guard let requestedCoverid, !requestedCoverid.isEmpty else {
            image         = nil
            loadedTaskKey = nil
            return
        }
        // PASS 6 — defer loading until we have a real size. Some callers
        // wrap ArtworkView in a GeometryReader and the first layout pass
        // hands us `size: 0`. Loading at that point would issue a wasted
        // 256-pixel-bucket fetch that the second pass replaces immediately.
        guard size > 0 else { return }
        // Already showing the right image at this display-size bucket — nothing to do.
        if loadedTaskKey == taskKey, image != nil { return }

        // Synchronous cache fast-path: avoids the one-frame flash to placeholder
        // when cells are recycled during scrolling.
        let scale = max(displayScale, 1)
        if let cached = ArtworkCache.shared.cachedImage(
            coverid: requestedCoverid,
            targetPoints: size,
            scale: scale
        ) {
            image         = cached
            loadedTaskKey = taskKey
            return
        }

        // Avoid showing stale artwork while a newly-navigated row/card loads.
        image         = nil
        loadedTaskKey = nil

        let loaded = await ArtworkCache.shared.loadImage(
            coverid: requestedCoverid,
            targetPoints: size,
            scale: scale
        )
        // Re-check identity in case the cell was recycled mid-load.
        guard !Task.isCancelled, self.coverid == requestedCoverid else { return }
        if loaded != nil {
            withAnimation(.easeOut(duration: 0.18)) {
                image         = loaded
                loadedTaskKey = taskKey
            }
        } else {
            image         = nil
            loadedTaskKey = nil
        }
    }
}

// MARK: - Shared formatting helpers

enum NameFormatting {
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return "?" }
        if parts.count >= 2 {
            let firstInitial = parts.first?.prefix(1) ?? ""
            let lastInitial  = parts.last?.prefix(1) ?? ""
            return "\(firstInitial)\(lastInitial)".uppercased()
        }
        return String(parts[0].prefix(2)).uppercased()
    }
    static func lastName(_ name: String) -> String {
        String(name.split(whereSeparator: \.isWhitespace).last ?? Substring(name))
    }
}

// MARK: - Resume Banner

/// A compact toast-style banner that appears on cold launch when a previous
/// playback session was restored. Offers a "Resume" action and a dismiss
/// button. Auto-dismisses after 7 seconds if untouched.
struct ResumeBannerView: View {
    let trackTitle: String
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.roonAccent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Resume where you left off")
                    .font(.roonBody(12, weight: .semibold))
                    .foregroundColor(.roonSecondary)
                Text(trackTitle)
                    .font(.roonBody(14, weight: .semibold))
                    .foregroundColor(.roonPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Haptics.medium()
                onResume()
            } label: {
                Text("Play")
                    .font(.roonBody(13, weight: .semibold))
                    .foregroundColor(.roonBase)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.roonAccent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.roonTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.roonSurface)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.roonBorder, lineWidth: 0.5)
        )
    }
}
