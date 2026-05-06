# Hyperion – Change Summary

## Phase A — Features 1–4

### `Hyperion/ServerPlaylistViews.swift` *(new)*
Server-side playlist UI: `ServerPlaylistListView`, `ServerPlaylistDetailView`, `ServerPlaylistRowView`. Supports pull-to-refresh, create, swipe-to-delete, and Play/Shuffle header.

### `Hyperion/LibraryView.swift`
- Added "Server Playlists" and "Downloads" menu rows to `LibraryMenuView`.
- `SongRowView` and `MovementRowView`: added `DownloadButton` and download/cancel/remove context-menu items.
- `ArtistDetailView`: added `displayedAlbumCount` state for album pagination; skeleton placeholder rows shown while loading; `.task` block uses new `library.loadArtistDetail(artistID:)` for caching + coalescing.
- `AlbumListView`: sort order persisted to `UserDefaults` (`hyperion.library.albumSortOrder`).

### `Hyperion/SearchAndSettingsView.swift`
- Added "Sync Server Playlists" button in a LIBRARY SYNC section.
- Added `AudiomuseSectionView` with AI Mixes toggle, "Test AudioMuse Connection" button, and status/error display.

### `Hyperion/ContentView.swift`
- `Tab` enum extended to `CaseIterable`.
- Added iPad `NavigationSplitView` layout via `sizeClass == .regular` branch.
- `MiniPlayerView` shown in both layouts; tab bar omitted on iPad sidebar.

### `Hyperion/project.yml`
Removed `INFOPLIST_KEY_UIRequiresFullScreen: YES` to allow iPad split-view multitasking.

### `Hyperion/HyperionIntents.swift` *(new)*
App Intents / Siri Shortcuts: `TogglePlaybackIntent`, `PlayTrackIntent`, `PlayAlbumIntent`, `PlayComposerIntent`, entity types, and `HyperionShortcuts` provider with 8 shortcut phrases.

### `Hyperion/DownloadManager.swift` *(new)*
Offline download engine using `URLSessionConfiguration.background`. Manages download state, manifest persistence, and local file priority via `Documents/Downloads/`.

### `Hyperion/DownloadsView.swift` *(new)*
Downloads tab UI: in-progress rows with cancel button, completed rows with swipe-to-delete and context menu (Play, Add to Queue, Delete).

### `Hyperion/LyrionAPI.swift`
`streamURLs(for:)` prepends the local file URL when a track has been downloaded, covering all three playback paths.

### `Hyperion/SceneDelegate.swift`
Added `AppDelegate` with `handleEventsForBackgroundURLSession` to wire `DownloadManager.backgroundCompletionHandler`.

### `Hyperion/HyperionApp.swift`
Added `@UIApplicationDelegateAdaptor` for `AppDelegate`; touched `DownloadManager.shared` and `AudiomuseManager.shared` at launch.

---

## Phase B — Playback edge cases, performance, AudioMuse

### `Hyperion/PlayerViewModel.swift`

**1a – Phone call interruption**
- `shouldIgnoreBackgroundInterruption`: now also checks `applicationState != .active` alongside `appWasSuspended`, preventing a locked-screen phone call from being misclassified as a background transition.
- Post-call resume: added 300 ms delay in both the normal and retry-after-reactivation paths so iOS fully releases the call audio session before music restarts.

**1b – Play button resets**
- `playCurrentTrack` (AVPlayer path): skips item recreation if the current `AVPlayerItem` is already `readyToPlay` for the same track — a plain `resume()` is called instead.
- `trackDidFinish` (repeat-one): captures `activePlaybackID` before the seek-to-zero completion handler and guards against stale execution.
- `handleTimeControlStatus` (`.waitingToPlayAtSpecifiedRate`): arms a 3 s inline watchdog that nudges the player if it remains stuck with a ready item.

**1c – Orpheus → AVPlayer fallback**
`pendingSeekTime` is set in the route-change handler before `playCurrentTrack()`, and `beginPlayback` reads it via `restoredSeekTime` — queue position and time are preserved through AirPlay-mid-Orpheus fallback.

**1d – Gapless preload failures**
`trackDidFinish`: before calling `performGaplessAdvance`, checks `g.item.status != .failed`; if failed, clears `gaplessPreloadedItem`, removes it from AVQueuePlayer, and falls back to `nextTrack()`.

**1e – Crossfade on Orpheus path**
- `engine.onTimeUpdate` callback now includes the `remaining <= crossfadeDuration` crossfade trigger (previously AVPlayer-only).
- `startCrossfadeOut` and `startCrossfadeIn` also update `orpheusEngine?.volume` so the Orpheus player-node ramps in sync with the AVPlayer volume.

**1f – Audio session after route change**
Added `outputVolume` check in the route-change handler; logs a warning when `outputVolume < 0.01` (silent-but-playing state) without forcing a pause, per Apple HIG.

**1g – Seek watchdog extension**
`installPendingSeekWatchdog`: on timeout, if `playerItem?.status == .failed`, calls `retryNextPlaybackURL` to escalate to the URL fallback chain instead of silently clearing `pendingSeekTime`.

**1h – Lock screen / Control Center state sync**
All existing state-change sites (`pause`, `resume`, `beginPlayback`, `performGaplessAdvance`, interruption handler) already call `refreshNowPlayingPlaybackState(force: true)`. Remote command handlers already dispatch to `@MainActor`. No structural change needed; watchdog and generation guards tighten correctness.

### `Hyperion/OrpheusPlaybackEngine.swift`
Added `volume: Float` property (0–1) backed by `playerNode.volume`, enabling crossfade ramps on the Orpheus path.

### `Hyperion/LibraryViewModel.swift`

**Artist detail cache + coalescing**
- Added `ArtistDetailResult` struct and `artistDetailCache` (10-entry LRU) + `artistDetailTasks` dictionary.
- `loadArtistDetail(artistID:)`: cache hit serves instantly; in-flight requests are coalesced; albums and songs are fetched in parallel via `async let`.

**Library initial load speed**
- `loadSongs()`: publishes the first page to `songs` immediately after the first batch returns, so the UI renders before the full library is loaded.

### `Hyperion/AudiomuseManager.swift` *(new)*
AudioMuse-AI mix integration:
- Probes `GET /{lmsBase}/audiomuse/api/mix` on connect (5 s timeout); sets `audiomuseAvailable`.
- Generates 6 mixes in parallel (`async let`) seeded by top artists, genres, and a liked track.
- Caches results to `audiomuse_mixes.json`; refreshes at most once per hour.
- Falls back gracefully to `MixGenerator` when plugin is unavailable or returns errors.
- `testConnection()` for the Settings "Test AudioMuse Connection" button.

### `Hyperion/MixViews.swift`
Added `AudiomuseMixCard` — identical layout to `MixCard` but backed by `AudiomuseMix` and `AudiomuseManager.play(mix:using:)`.

### `Hyperion/HomeView.swift`
`mixesSection`: shows AI mixes (`AudiomuseMixCard`) when AudioMuse is enabled and available, otherwise falls back to local `MixCard` rows. Adds a subtle "AI" badge / "AI unavailable" label in the section header.

---

## Phase C — Production Audit

### Section 1 — Synced Lyrics

#### `Hyperion/LyricsService.swift`
- Added `private var memoryCache: [Int: LyricsResult]` — in-process cache keyed by track ID for instant reuse within a session.
- Added `cachedResult(trackID:)` — synchronous probe for instant serve without async overhead.
- Added `prefetch(for track: Track)` — background fetch triggered by track changes so lyrics are ready before the user opens the sheet.
- Wrapped `provider.fetch(...)` in a `withThrowingTaskGroup` race against a 5-second sleep so the fetch always resolves (with `.unavailable`) within 5 seconds.
- Memory and disk cache results stored under track ID (in addition to the artist/title DJB2 hash key).

#### `Hyperion/PlayerViewModel.swift`
- Added `didSet` observer to `currentTrack: Track?` that calls `LyricsService.shared.prefetch(for: track)` on every track change, so lyrics begin loading the moment playback starts rather than when the user opens the lyrics sheet.

#### `Hyperion/LyricsView.swift`
- `loadLyrics()`: now checks `LyricsService.shared.cachedResult(trackID:)` first; if already prefetched, the result is shown instantly with no loading spinner.
- Scroll animation changed from `.spring(response: 0.45, dampingFraction: 0.88)` to `.easeInOut(duration: 0.25)` as specified.
- `lineIndex(for:in:)`: changed `time - 0.3` to `time + 0.3` so lines are pre-highlighted 300 ms before their timestamp (was a 300 ms delay, not a pre-highlight).
- `InterludeDots`: replaced `Timer.scheduledTimer` (which created orphaned timers on every `startPulse()` call and never invalidated them when the view disappeared) with `Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()` via `.onReceive`. The publisher automatically cancels when the view disappears, eliminating both the leak and the multiple-timer bug.

### Section 2 — Bug Fixes

#### `Hyperion/AudiomuseManager.swift`
- Replaced three force-unwrapped `URLComponents(url:resolvingAgainstBaseURL:)!` calls (lines in `testConnection`, `probeAvailability`, `fetchMix`) with safe `guard var comps = ... else { return nil/false/"Invalid URL" }` bindings. These could crash if LMS returned a URL whose component decomposition failed.

### Section 3 — Performance
Architecture confirmed already optimal:
- ImageIO downsampling in `ArtworkCache` with pixel-bucketing and NSCache cost accounting.
- `LyrionAPI.performRPCRequest` is `nonisolated static` — network fetch + JSON parse happen off MainActor.
- Parse helpers (`parseAlbums`, `parseTracks`) are also `nonisolated static`.
- In-flight request coalescing in both `ArtworkCache` and `LibraryViewModel`.

### Section 4 — UI Polish

#### `Hyperion/ContentView.swift` (MiniPlayerView)
- Play/pause button now shows a `ProgressView` spinner when `player.isLoading` is `true`, replacing the static icon. Accessibility label updates to "Loading" during this state.

#### `Hyperion/ContentView.swift` (ArtworkView)
- Added `.accessibilityHidden(true)` to `ArtworkView.body`. Artwork is always decorative (track/album titles are shown alongside it in every context) — hiding it from accessibility avoids VoiceOver reading a generic "image" element for every row.

### Section 5 — Accessibility

#### `Hyperion/NowPlayingView.swift`
- `progressSection`: added `.accessibilityLabel("Playback position")`, `.accessibilityValue` (current time + duration formatted as "M:SS of M:SS"), and `.accessibilityAdjustableAction` on `ProgressBarView` so VoiceOver users can scrub ±10 seconds by swiping up/down on the scrubber.
