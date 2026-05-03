

## 2026-05-02 — Pass 6 production polish

### Critical bugs

- **FIX — Queue swipe-to-remove was silently broken**: `QueueTrackRow` had `.swipeActions(edge: .trailing, allowsFullSwipe: true)` attached, but SwiftUI only fires swipeActions on the **top-level** row of a `List`. `QueueTrackRow` is nested inside `WorkQueueGroupView`'s `VStack`, so the swipe gesture was swallowed and remove never fired. Replaced with `.contextMenu` which works at any depth, with both "Play Now" and "Remove from Queue" actions plus an `.accessibilityAction` for VoiceOver users.
- **FIX — Now Playing artwork-swipe race on rapid drags**: each successful swipe spawned a `Task { sleep(180ms); nextTrack(); ... }` block. Repeated swipes spawned overlapping tasks, each animating the artwork in their own way and skipping multiple tracks unintentionally. Added an `artworkTransitioning` single-flight guard around the entire transition so only one skip animates at a time.
- **FIX — Mini-player progress strip animated backward on track change**: when `progress` snapped to 0 for the new track, the existing 0.5s linear animation visibly drained the bar from right to left. Re-keyed the bar's identity on `currentTrack.id` so it instantiates fresh per track, killing the cross-track interpolation.

### Performance — artwork pipeline rewrite

The single largest win in this pass. Previously the app maintained two parallel NSCaches (`ArtworkCache.shared` keyed by coverid, `PlayerViewModel.artworkCache` keyed by URL), and **both** stored full-resolution images. For a Pristine Classical FLAC library where covers are routinely 3000×3000+, scrolling a 200-album grid would decode and hold tens of megabytes per cell. Lock-screen artwork pulled the same data a third time at full res.

- **REWRITE — unified, downsampling-aware `ArtworkCache`**: one NSCache for the entire app. Keys include a target-pixel bucket (256/512/768/1024/...), so a 148pt thumbnail and a 600pt lock-screen artwork can coexist without evicting each other.
- **PERFORMANCE — ImageIO downsampling**: artwork decode now goes through `CGImageSourceCreateThumbnailAtIndex` at the requested display size. No full-res decode pass, no later scaling. Memory per cell drops by ~30–50× for typical Pristine artwork; fast-scrolling the album grid is now CPU-bound on layout, not on JPEG decode.
- **PERFORMANCE — decode and network off the main actor**: the loader hops to a `Task.detached(priority: .userInitiated)` for the URLSession fetch and ImageIO decode. The previous implementation ran decode on `@MainActor`, which is exactly what the rewrite sets out to avoid.
- **PERFORMANCE — request coalescing per (coverid, size-bucket)**: a fast-scrolling LazyVGrid that flicks past the same cell twice now collapses to a single in-flight load. Token-based ownership check on completion prevents a stale task from clearing a newer one's slot after a memory warning.
- **PERFORMANCE — URLSession disk cache layer**: the artwork session now uses a dedicated 50 MB disk URLCache with `.returnCacheDataElseLoad`, so scrolling back over previously-seen albums no longer hits the network at all.
- **PERFORMANCE — lock-screen artwork sized correctly**: `MPMediaItemArtwork` now receives a 600pt-decoded image, matching what `MPNowPlayingInfoCenter` actually displays. Previously every track change pushed a 3000px image to the lock-screen pipeline for iOS to scale down.
- **PERFORMANCE — blurred Now Playing background sized correctly**: the heavily-blurred background now requests a 400pt source image. The blur radius of 80pt + scale 1.5 reduces this to indistinguishable from a higher-res input.
- **PERFORMANCE — first-paint artwork loads avoided on size 0**: `ArtworkView` defers loading until it has a real size. Cells wrapped in a `GeometryReader` (album grid) used to issue a wasted 256-pixel-bucket fetch on the first layout pass before the real width was known. The task identity now keys on a coarse size bucket so a 0→full-size transition still triggers a load.

### Polish

- **POLISH — artwork fade-in**: artwork resolves with a 180ms ease-out fade instead of popping into place. Cached cells appearing during fast scrolls no longer flash to the placeholder.
- **POLISH — distinct selected icon for Queue tab**: previously the Queue tab used `list.bullet` for both states, so active state was indicated by colour alone (an accessibility lapse). Selected state now uses `list.bullet.rectangle.fill`.
- **POLISH — single source of truth for time formatting**: introduced `TimeFormatting.formatDuration(_:placeholder:)` and removed the three near-duplicate copies in `Track`, `WorkGroup`, and `NowPlayingView.formatTime`. Bug fixes to the H:MM:SS rollover now propagate everywhere automatically.

### Accessibility

- **A11Y — tab buttons announce their tab name**: `RoonTabButton` now exposes `accessibilityLabel` ("Home" / "Search" / "Library" / "Queue") and the `.isSelected` trait. Without this VoiceOver would announce the SF Symbol name to users.
- **A11Y — queue context menu carries an accessibilityAction**: VoiceOver users can use "Remove from queue" as a custom action on each track row, mirroring the visible context-menu entry.

### App Store hygiene

- **REMOVED — stale TLSv1.0 IP exception in Info.plist**: `NSExceptionDomains` for the hardcoded IP `31.223.16.10` was specific to one developer setup and explicitly listed `TLSv1.0` as the minimum, which trips an App Store reviewer warning. `NSAllowsArbitraryLoads` already covers the user-supplied LMS URLs that this exception was trying to authorise.

### Files changed
- `ContentView.swift` — `ArtworkCache` rewrite, `ArtworkView` size-aware loader, `MiniPlayerView` progress identity, `RoonTabButton` accessibility, distinct Queue tab icon, `ImageIO` import.
- `PlayerViewModel.swift` — removed parallel `artworkCache` + `artworkLoadTasks` + `artworkSession`; `loadImage(from:)` now thin-delegates to `ArtworkCache`.
- `NowPlayingView.swift` — `AsyncArtworkBackground` migrated to new ArtworkCache API at 400pt, `artworkTransitioning` single-flight guard, `formatTime` delegates to `TimeFormatting`.
- `QueueView.swift` — replaced broken `swipeActions` with `contextMenu` + accessibility action.
- `Models.swift` — added `TimeFormatting` enum, `Track.durationFormatted` and `WorkGroup.totalDurationFormatted` delegate to it.
- `Info.plist` — removed stale ATS IP exception.

### Risks and tradeoffs
- **Cache memory ceiling raised from 50 MB → 80 MB**, but per-image footprint is dramatically smaller because of downsampling. Net memory usage drops significantly while cache hit rate increases (more entries fit). The system still evicts under pressure via NSCache.
- **Existing artwork on disk is invalidated** by the new URLCache path (`hyperion-artwork`). First launch after upgrade will repopulate the disk cache from the network. No user-visible regression, just one slower scroll session.
- **Removed `ArtworkCache.image(for:)` and `setImage(_:for:cost:)`** APIs. All in-tree callers were migrated; any third-party Hyperion-derived fork would need to update too.
- **`UIRequiresFullScreen=YES`** is preserved (the existing project policy).



- **FIX — Like button state not reset on track change**: `isLiked` was a per-view `@State` variable that persisted across track changes, leaving the heart icon filled on the next track. It now resets in the same `onChange` block as the drag/artwork states.
- **FIX — `.m4a` incorrectly labelled as ALAC (lossless)**: `AudioFormat.from(track:)` conflated `.m4a` extension with ALAC encoding. `.m4a` is a container that can hold either AAC (lossy) or ALAC (lossless). It is now labelled `M4A` with `isLossless: false` so the signal-path dot and summary card no longer claim lossless for AAC-encoded M4A files.
- **POLISH — Queue drag-to-reorder**: the Up Next section now supports drag-to-reorder via `.onMove`. Dragging moves entire work groups (all movements) as a unit, translating group positions to absolute track indices for `moveInQueue`.
- **FIX — Search suggestions empty on cold start**: `SearchView` now triggers a composer load via `.task` if composers haven't been fetched yet (e.g. when Search is the first tab displayed), matching the same guard already in `ComposerListView`.




- **PERFORMANCE — true paginated album browsing**: album list loading now fetches one LMS page per call and lets the existing scroll trigger request additional pages. This restores fast first paint on large libraries instead of blocking until every album has downloaded.
- **PERFORMANCE — duplicate Home requests suppressed**: Recently Added and Recently Played now share in-flight tasks, and Home starts totals / recent-section loads in parallel. Pull-to-refresh also reloads its independent sections concurrently.
- **PERFORMANCE — artwork request coalescing**: duplicate simultaneous artwork downloads for the same URL now share a single in-flight task; memory warnings cancel pending artwork loads and clear both artwork caches.
- **PERFORMANCE — album queue add batched**: adding a whole album to the queue now appends all work groups in one operation instead of recomputing queue groups once per work.
- **FIX — App Store/iPad bundle settings aligned**: source Info.plist, both XcodeGen specs, archive patching, and IPA verification now agree that Hyperion targets iPhone and iPad with explicit full-screen iPad behavior.
- **FIX — credentials redacted in offline banner**: Home's disconnected banner now uses the same URL redaction as Settings and diagnostics.
- **FIX — Settings test spinner cannot get stuck**: Test Connection now clears its loading state through `defer`, including cancellation/early-return paths.
- **FIX — duplicate Auto-mode probes avoided**: Settings → Test Connection deduplicates expanded candidate URLs before racing probes.
- **FIX — scene delegate actor isolation**: UIKit and CarPlay scene delegates are explicitly main-actor isolated.
- **POLISH — pagination feedback**: album browsing shows a bottom spinner while loading additional pages.
- **POLISH — album detail controls**: Play/Add buttons stay disabled until tracks are actually loaded, and the CLASSICAL badge is shown only when metadata indicates classical content.

## 2026-05-02 — Search repair and matching polish

- **FIX — album-name search restored**: broad LMS search now parses both canonical album rows and lightweight `album_id`/`albu` search rows, then hydrates matches through the albums endpoint so search results include usable album metadata.
- **FIX — resilient album search fallbacks**: album search now combines direct album search, broad catalog search, artist/composer album lookup, and a bounded server-side album scan for LMS installations whose search preferences miss mid-title matches.
- **POLISH — locale-stable search matching**: album, composer, and work filters now share one diacritic-insensitive, width-insensitive, stable-locale matcher so searches behave consistently on devices using Turkish or other locale-specific casing rules.
- **PERFORMANCE — duplicate broad search removed**: the search tab no longer runs an extra catalog search after the album search path has already done the same work.


## Build fix follow-up

- Fixed Swift concurrency compilation errors introduced in the LyrPlay-style remote probing pass.
- Replaced `?? await` fallback expressions with explicit async-safe fallback branches so Release archives compile under Xcode 26.2.


## Remote connection repair v2

- Added LyrPlay-style loose server address handling for bare Tailscale/MagicDNS names and 100.x.y.z addresses.
- Remote tests now probe multiple LMS endpoint candidates instead of assuming the typed URL already includes port 9000.
- Normalizes pasted `/material`, `/index.html`, and `/jsonrpc.js` URLs back to the LMS base before appending API/artwork/stream paths.
- Auto mode now expands each configured address into candidate endpoints and picks the first successful LMS JSON-RPC response.
- Settings → Test Connection uses the same candidate probing path as the real connection resolver.
- Rewrites private/LAN absolute stream URLs returned by LMS onto the active remote base URL before AVPlayer tries them.

# Hyperion — change log

## Remote connection repair pass

- Fixed legacy remote URL migration: an older single `serverURL` that points to a public IP, domain, or HTTPS reverse proxy now populates the Remote slot instead of only Home.
- Added recovery for users who opened/saved the previous cleanup build with the remote URL stranded in Home and an empty Remote field.
- Added Basic Auth forwarding for connection probes, JSON-RPC requests, artwork, and AVPlayer streams when the server URL includes `user:password@host`.
- Redacted credentials from the Settings active URL display.

## 2026-05-02 — Pass 3 polish + performance cleanup

- **PERFORMANCE — search matching**: search now normalizes and tokenizes the query once per search instead of re-splitting/re-normalizing it for every composer, work, and album candidate. Matching also ignores diacritics for better classical-library lookups.
- **PERFORMANCE — duplicate request suppression**: work lists, work tracks, and album tracks now share in-flight load tasks, so fast navigation or concurrent view refreshes no longer launch duplicate identical LMS requests.
- **FIX — album pagination race**: album loads now snapshot the requested sort order and only clear the loading flag for the active generation, avoiding stale loaders hiding the spinner during sort changes.
- **FIX — metadata fallbacks**: track parsing now accepts `discnum` and `artwork_track_id` fallbacks in addition to the existing `disc` / `coverid` keys.
- **FIX — artist album search resilience**: one failed artist-scoped album request no longer fails the whole artist search; cancellation still propagates correctly.
- **PERFORMANCE — diagnostics timestamps**: server log entries no longer allocate a new `DateFormatter` for every rendered row.
- **PERFORMANCE — log ring trim**: diagnostics trimming now keeps the suffix in one array replacement instead of repeatedly shifting entries.
- **POLISH — artwork cache memory handling**: the shared artwork cache now has a count limit and clears itself on memory warnings; player artwork cache clearing also clears the shared SwiftUI artwork cache.
- **POLISH — launch audio session behavior**: the audio category is configured on startup, but the session activates only when playback starts or resumes.
- **FIX — remote command setup**: explicitly enables lock-screen / CarPlay playback-position scrubbing.
- **FIX — no force unwrap in initials formatting**: `NameFormatting.initials` no longer force-unwraps first/last tokens.
- **FIX — IPA helper with absolute paths**: `fix_appstore_validation.sh` no longer fails when given an absolute `.ipa` path.
- **BUILD — asset catalog restored**: added a complete root `Assets.xcassets/AppIcon.appiconset` matching `project.yml` / `ASSETCATALOG_COMPILER_APPICON_NAME`.


## 2026-05-02 — Restored Recent Activity + quality marker

- **RESTORED — Recently Played visibility on Home**: the homepage now always shows the Recently Played section. If there is no app-local or LMS play history yet, it shows a clear empty-state card instead of disappearing.
- **RESTORED — Now Playing quality marker**: the signal/quality marker is always visible in Now Playing. If LMS does not report a source file extension for proxied/remote streams, the marker stays present as `SIGNAL` and still opens the signal-path sheet.
- **POLISH — Home loading**: Home now explicitly loads both Recently Added and Recently Played on appearance, not just totals and recent playback.

## 2026-05-02 — Now Playing layout + local play history

- **FIX — Now Playing artwork oversized/cropped**: replaced the unbounded ScrollView GeometryReader sizing path with an explicit safe-area-aware artwork size. The full-screen player now keeps the cover contained so the queue position, track title, progress, and controls remain visible.
- **POLISH — Now Playing artwork rendering**: the large artwork now uses aspect-fit inside a rounded square, preventing non-square or oddly served covers from being cropped like a zoomed background.
- **FIX — Recently Played only reflected server-side plays**: added app-local per-server playback history. Hyperion records an album when an AVPlayer stream becomes playable, then merges that local history ahead of any LMS history.
- **FIX — Recently Added was not actually recently added**: Home now requests albums with `sort:new` instead of the default alphabetical album sort.
- **FIX — progress remaining time while scrubbing**: the remaining-time label now follows the drag position instead of lagging behind the underlying player time.
- **POLISH — remote controls**: explicitly enabled the lock-screen / CarPlay toggle play-pause command.


## Pass 2 fixes (this session)

### Models.swift
- **BUG — `Track.durationFormatted` overflows at 60 min**: used `%d:%02d`
  with raw minutes, producing "75:30" for a 75-minute symphony movement.
  Now emits `H:MM:SS` whenever total seconds ≥ 3600.  Same fix applied to
  `WorkGroup.totalDurationFormatted`.
- **BUG — `Work.id` collision on fabricated works**: `var id: Int { work_id }`
  returns `0` for every Work that comes from search or is otherwise
  server-assigned a zero/missing id. Multiple such Works have the same
  `Identifiable` id, causing `ForEach` to collapse them to one row and
  producing "duplicate id" runtime warnings. Changed `id` to `String`,
  using the numeric id for real server works and a content-derived key for
  fabricated ones. All call sites that need the numeric id use `work.work_id`
  directly — no call site used `work.id` for API calls.

### LyrionAPI.swift
- **CLEANUP — dead `ObservableObject` / `Combine` conformance**: The class had
  zero `@Published` properties and was never used as `@ObservedObject` /
  `@StateObject`. Removed the conformance and the `import Combine`.
- **FIX — `parseAlbums` / `parseTracks` capture `self` unnecessarily**: Made
  both `private static` since they touch no instance state. Eliminates a
  spurious `self` capture in async call sites.
- **FIX — `normalizeString` missing "various" placeholder**: Added `"various"`
  to the set of stripped LMS placeholders.
- **FIX — `getAlbums` tag string**: Changed `"tags:alyj"` to `"tags:aljyS"`
  to include the `S` (albumartist) tag, which `parseAlbums` reads as `"artist"`.

### LibraryViewModel.swift
- **BUG — concurrent `loadComposers` double-fetch**: `ContentView.task` and
  `HomeView.task` both call `loadComposers`. Without the early-exit guard, both
  callers slip past the `composerCache == nil` check before the first await,
  issuing two identical paginated fetches. Added `guard !isLoadingComposers`
  before setting the flag.
- **FIX — search task not checking cancellation between awaits**: The three
  `async let` tasks are awaited sequentially. If the user types another
  character while the first await is in flight, the search task is cancelled
  but merging still runs on stale results. Added `guard !Task.isCancelled`
  checks between each await.
- **CLEANUP — removed unused `import Combine`**: the ViewModel uses no Combine
  pipelines; `@Published` and `ObservableObject` are in SwiftUI/Observation.

### PlayerViewModel.swift
- **BUG — missing `durationObservation` KVO**: `duration` was set once from the
  LMS database tag and never updated from the actual loaded stream. Added a KVO
  observer on `AVPlayerItem.duration` that updates the published `duration` once
  the asset is loaded, so the progress bar and time display reflect the real stream.
- **BUG — `durationObservation` not torn down in `clearQueue`**: The new KVO
  observer is also invalidated in `clearQueue`, `beginPlayback` setup, and
  alongside `statusObservation`.
- **BUG — double `player?.volume = volume` in `beginPlayback`**: In the `else`
  branch the assignment appeared both inside the block and immediately after the
  if/else. Removed the duplicate.
- **BUG — `toggleShuffle` early-exit clobbers shuffle-off path**: The original
  `guard !queue.isEmpty` at the top set `isShuffle = false` and cleared
  `originalQueueBeforeShuffle` even on the de-shuffle path. Moved the guard to
  the turn-on path only so turning shuffle off is always clean.
- **FIX — `moveInQueue` insertion index underflows**: When all source indices are
  ≥ `destination`, `destination - removedBeforeDestination` evaluates to a
  negative index. Added `max(0, ...)` clamp.

### ContentView.swift — `ArtworkView`
- **BUG — stale-coverid race in `loadArtwork`**: the original captured
  `self.coverid` inside the async closure, but after the `await` the SwiftUI
  task might have been re-created for a new coverid. Refactored to pass the
  coverid captured at task-creation time (`for requestedCoverid`) through the
  load function, eliminating the window where a returning download could paint
  the wrong image on a recycled view.
- **BUG — stale image not cleared on nil coverid**: the original only cleared
  `image` when `loadedCoverid != nil` (previous image existed). Added an
  unconditional clear when `coverid` is nil/empty.

### LibraryView.swift
- **FIX — `Divider().background(Color.roonBorder)`**: `.background()` sets the
  container background, not the Divider line colour. Replaced with an explicit
  `Color.roonBorder.frame(height: 0.5)` rectangle in all separator locations
  throughout WorkDetailView and WorkGroupSectionView.
- **FIX — missing `toolbarColorScheme(.dark)`** on all NavigationStack-based
  views (ComposerListView, WorkListView, WorkDetailView, AlbumListView,
  AlbumDetailView). Without this the nav bar title renders in system default
  colour (black on Light appearance in hosted contexts).
- **POLISH — haptic feedback** on all primary playback buttons (Play, Add to
  Queue, movement tap) using `UIImpactFeedbackGenerator`.
- **FIX — `formatDuration` in MovementRowView**: Same H:MM:SS fix as Models.

### HomeView.swift
- **FIX — `RoonStatTile.format` allocates a new `NumberFormatter` per call**:
  `NumberFormatter` is expensive to create (locale resources, ICU). Replaced
  with a `private static let` instance created once.

### NowPlayingView.swift / QueueView.swift / ContentView (MiniPlayerView)
- **POLISH — haptic feedback** on all transport controls (play/pause, next,
  previous, shuffle, repeat, queue play buttons).
- **FIX — `formatTime` missing H:MM:SS** in NowPlayingView and QueueView
  duration formatters.

### SearchAndSettingsView.swift
- **FIX — `SearchSuggestionsView` `.ignoresSafeArea(.all)` on ScrollView
  background**: Caused flicker when the keyboard was dismissed. The parent
  SearchView already paints roonBase. Changed to plain `.background(Color.roonBase)`.
- **FIX — `NoResultsView` `.ignoresSafeArea(.all)`**: Redundant (same reason).
  Removed.
- **FIX — missing `toolbarColorScheme(.dark)`** on SettingsView NavigationStack.
- **FIX — missing `scrollContentBackground(.hidden)`** on SearchResultsView and
  SearchSuggestionsView ScrollViews.

### HyperionApp.swift
- **FIX — `UIScrollView.appearance().backgroundColor = .clear`**: SwiftUI's
  `ScrollView` bridges to UIScrollView on some iOS versions. Without clearing
  the background, pushing into a detail view could briefly show the UIScrollView
  default white background behind the SwiftUI content.

### DesignSystem.swift
- **FIX — hex initialiser doesn't verify full scan**: `scanHexInt64` on an
  invalid string like "GGGGGG" returns `true` (stops at first non-hex char,
  yields 0) while the length check passes. Added `scanner.currentIndex ==
  h.endIndex` verification so garbage input falls through to the black fallback
  rather than silently giving a black colour with no diagnostic.
- **NEW — `roonDivider` semantic token**: slightly stronger than `roonBorder`
  for use inside cards/surfaces where the background contrast is lower.

### ConnectionManager.swift
- **CLEANUP — removed unused `import Combine`**: ConnectionManager uses no
  Combine pipelines.
- **NEW — `stopMonitoring()`**: public method to cancel the NWPathMonitor when
  the app enters the background long-term, preventing unnecessary CPU wakeups.

---

## Pass 1 fixes (prior session — from CHANGELOG.md)
- Added missing `Combine` imports for `ObservableObject` / `@Published` types.
- Added explicit `UIKit` import to `HyperionApp.swift`.
- Removed the duplicated `works_loop` guard in `LyrionAPI.getWorks`.
- Made `ConnectionManager.testURL`/`probeURL` nonisolated; moved URL probing
  into a nonisolated static helper for true parallel Auto-mode racing.
- Hardened JSON-RPC handling: cancellation checked, non-2xx throws,
  JSON-RPC `error` payloads surface as `HyperionError.rpcError`.
- Replaced unsafe `MainActor.assumeIsolated` in AVPlayer time observer.
- Moved now-playing artwork updates onto the MainActor.
- Replaced `queue.move(fromOffsets:toOffset:)` with a local implementation.
- Guarded `symbolEffect` in QueueView with an iOS 17 availability check.
- Stopped activating the audio session at app launch.
- Made path-component percent encoding stricter for artwork/stream URLs.
- Made `getWorksCount()` handle both `count` and `_count`.
- Hardened `Color(hex:)` against invalid input (further tightened in Pass 2).
- Updated Settings connection testing to use the nonisolated probe helper.

## Remote connectivity and diagnostics pass

- Removed the source-level hard-coded default `192.168.1.105:9000` server URL. Fresh installs now start unconfigured instead of accidentally targeting a private home IP.
- Fixed manual Remote Proxy/Tailscale modes so they do not silently fall back to the Home LAN URL.
- Added URL normalization for pasted `/jsonrpc.js` endpoints.
- Added real Lyrion JSON-RPC validation during connection probes, so an HTTPS proxy returning a generic 200 HTML page no longer appears connected.
- Added in-app Server Diagnostics with copyable logs and OS Console logging.
- Added detailed probe/RPC logging for HTTP status, DNS/TLS/timeout failures, JSON-RPC errors, selected URL, and request duration.
- Added remote-access documentation and an Nginx sample with upstream-aware access logging.

### Remote HTTP / App Transport Security

If diagnostics say **Blocked by App Transport Security** for a public `http://...:9000` address, iOS is blocking clear-text remote HTTP before Hyperion reaches your server. This build keeps ATS exceptions in both `Info.plist` and `project.yml`, but the safer remote setup is still an HTTPS reverse proxy or Tailscale. For public internet access, prefer `https://your-domain.example` over exposing LMS port `9000` directly.

