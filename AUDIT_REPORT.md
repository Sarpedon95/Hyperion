# Hyperion — Deep Audit Report

**Date:** 2026-05-08  
**Scope:** All Swift source files in `/Hyperion/Hyperion/` (76 files, ~25,000 lines)  
**Phases:** Bug Fixing · Performance · Polish · Summary

---

## Phase 1 — Bugs Fixed

| # | File | Line(s) | Issue | Fix |
|---|------|---------|-------|-----|
| 1 | `LibraryViewModel.swift` | 307, 312, 316 | Raw `print()` calls not guarded by `#if DEBUG` — appeared in release build console output, inconsistent with rest of codebase | Replaced with `ServerLogStore.shared.debug()` |
| 2 | `ClassicalBrowserView.swift` | 613 | `UIScreen.main.scale` — deprecated API, already replaced elsewhere in codebase by `UITraitCollection.current.displayScale` | Replaced with `UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 2` |

### Bugs Investigated and Confirmed Safe

| File | Line(s) | Verdict |
|------|---------|---------|
| `ClassicalMatchingModels.swift` | 107–108 | Force unwraps `catAlbum[label]!` / `catOO[label]!` are safe — `label` is taken from the intersection of both dictionaries' keys, so it is guaranteed to be present in both |
| `StatsView.swift` | 255 | `calendar.date(byAdding: .day, value: -i, to: today)!` is safe — subtracting ≤370 days from any valid `Date()` always succeeds in every calendar system Swift supports |
| `OrpheusDSPEngine.swift` | 616 | `NotificationCenter.addObserver(self, selector:…)` — selector-based API, no closure, no retain cycle |

---

## Phase 2 — Performance

No new performance regressions found. The following improvements were already in place from the prior performance pass and are confirmed correct:

| Area | Status |
|------|--------|
| `OrpheusPlaybackEngine.load()` — concurrent `async let` for duration + tracks | ✅ In place |
| `PlayerViewModel` — Orpheus path reads `prefetchedNextAsset` cache | ✅ In place |
| `LyrionAPI.getTracksForArtist(artistID:)` — per-artist query replaces full `loadSongs()` | ✅ In place |
| `LyrionAPI.searchTracks(term:)` — server-side search for live results | ✅ In place |
| `SearchViewModel` — 150 ms debounce, in-memory results shown immediately | ✅ In place |
| `LibraryViewModel` — task coalescing on all major load paths | ✅ In place |
| `ArtworkCache` — ImageIO downsampling, in-flight request coalescing | ✅ In place |
| `AlbumListView` — cursor-pagination via `.onAppear` threshold | ✅ In place |
| `LazyVGrid` / `LazyHStack` — all large lists use lazy containers | ✅ In place |
| `LibraryViewModel.loadArtistDetail()` — concurrent album + track fetch, LRU cache | ✅ In place |

### Observations

- **No `DispatchQueue.main.async` patterns found** — all state mutations use `@MainActor` or `Task { @MainActor in }`.
- **No `AnyView` type erasure found** — all branching uses `@ViewBuilder`.
- **No duplicated URLSession instances** — each subsystem holds its own tuned session; `LyrionAPI` uses a single shared instance per-class.
- **No redundant re-renders detected** — `.id()` modifiers are used correctly to reset view identity on track change rather than animating stale state.
- **`NSCache` eviction limits** — `ArtworkCache` has 400-item count limit and 80 MB total-cost limit; automatic under memory pressure.
- **Memory warning handling** — `LibraryViewModel` and `ArtworkCache` both observe `didReceiveMemoryWarning` and flush appropriate caches.

---

## Phase 3 — Polish

### Tap Targets (44pt HIG minimum)

| # | File | Location | Before | Fix |
|---|------|----------|--------|-----|
| 1 | `NowPlayingView.swift` | Repeat button | No frame (≈20pt icon) | Added `.frame(width: 44, height: 44).contentShape(Rectangle())` |
| 2 | `NowPlayingView.swift` | Previous track button | No frame (≈28pt icon) | Added `.frame(width: 44, height: 44).contentShape(Rectangle())` |
| 3 | `NowPlayingView.swift` | Next track button | No frame (≈28pt icon) | Added `.frame(width: 44, height: 44).contentShape(Rectangle())` |
| 4 | `NowPlayingView.swift` | Shuffle button | No frame (≈20pt icon) | Added `.frame(width: 44, height: 44).contentShape(Rectangle())` |
| 5 | `LibraryView.swift` | Work group collapse chevron | 36×36pt | Increased to 44×44pt + `.contentShape(Rectangle())` |
| 6 | `SearchAndSettingsView.swift` | Recent search dismiss button | 28×28pt | Increased to 44×44pt + `.contentShape(Rectangle())` |
| 7 | `ContentView.swift` | ResumeBannerView dismiss button | 28×28pt | Increased to 44×44pt + `.contentShape(Rectangle())` |

### Accessibility Labels

| # | File | Location | Added Label |
|---|------|----------|-------------|
| 1 | `NowPlayingView.swift` | Repeat button | Dynamic: "Repeat off" / "Repeat one" / "Repeat all" |
| 2 | `NowPlayingView.swift` | Previous track button | "Previous track" |
| 3 | `NowPlayingView.swift` | Next track button | "Next track" |
| 4 | `NowPlayingView.swift` | Shuffle button | Dynamic: "Shuffle on" / "Shuffle off" |
| 5 | `LibraryView.swift` | Work group collapse chevron | Dynamic: "Expand work" / "Collapse work" |
| 6 | `SearchAndSettingsView.swift` | Recent search remove button | "Remove recent search" |

### Deprecated API Removal (iOS 17+ target)

| # | File | Before | After |
|---|------|--------|-------|
| 1 | `NowPlayingView.swift` | `UIScreen.main.bounds.width - 48` for artwork square | `.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)` — adaptive layout |
| 2 | `NowPlayingView.swift` | `UIScreen.main.bounds.height * 0.65` for queue panel cap | `.containerRelativeFrame(.vertical) { h, _ in max(h * 0.65, 300) }` |
| 3 | `LibraryView.swift` | `UIScreen.main.bounds.height * 0.45` for artist hero | `.containerRelativeFrame(.vertical) { h, _ in max(h * 0.45, 280) }` |
| 4 | `ClassicalBrowserView.swift` | `UIScreen.main.scale` for image loading scale | `UITraitCollection.current.displayScale` (already pattern from PlayerViewModel) |

**Note:** `UIScreen.main.bounds.size` in `PlayerViewModel.swift` (lock screen `MPMediaItemArtwork`) is intentionally left — it provides the physical screen size needed for the system's media artwork renderer, and there is no cleaner iOS 17 alternative for `@MainActor`-isolated code outside of a `View`.

### Existing Polish (Confirmed)

| Feature | Status |
|---------|--------|
| Empty states on all major lists (no albums, no songs, no search results, etc.) | ✅ Present |
| Loading indicators on all async data loads | ✅ Present |
| Haptic feedback on all interactive controls | ✅ Present (`.light()` / `.medium()` via `Haptics` enum) |
| Dark mode | ✅ All colours use design tokens (`Color.roonBase`, etc.) with no hardcoded light-mode values |
| `preferredColorScheme(.dark)` on `NowPlayingView` | ✅ Prevents system colour-scheme bleed |
| `ConnectionBannerView` on `HomeView` for offline state | ✅ Present |
| Error messages on network failures | ✅ User-friendly descriptions via `userFriendlyErrorMessage(for:)` |
| Play count / heart display on track rows | ✅ Present |
| Focus Mode banner in `NowPlayingView` | ✅ Present with accessibility structure |

---

## Remaining Weaknesses

| Area | Detail | Severity |
|------|--------|----------|
| ~~`UIScreen.main.bounds.size` (PlayerViewModel lock screen art)~~ | **Fixed in Phase 5** — replaced with `connectedScenes` | ✅ Resolved |
| ~~Alphabet scrubber buttons in `ClassicalBrowserView`~~ | **Fixed in Phase 5** — 44pt invisible frame added | ✅ Resolved |
| ~~`OOUserLinkOverrides` key scheme~~ | **Fixed in Phase 5** — v2 key scheme with track IDs | ✅ Resolved |
| ~~`LyricsService` memory cache~~ | **Fixed in Phase 5** — disk cache with 30-day TTL + deduplication | ✅ Resolved |
| `LibraryViewModel.loadSongs()` | Still a blocking full-library load for non-search flows; `loadSongs(matching:)` added for filtered lookups | Low |
| ~~`PlayerViewModel.swift` file size (~3,000 lines)~~ | **Fixed in Phase 5** — split into 6 focused extension files | ✅ Resolved |

---

## Suggested Features

| Feature | Status |
|---------|--------|
| ~~**Smart cached artwork colour extraction**~~ | **Added in Phase 5** — `ArtworkColorExtractor` actor; `PlayerViewModel.accentColor: Color` |
| **Full `containerRelativeFrame` adoption** | Still open — remaining `GeometryReader` usages |
| ~~**Widget artwork prefetch**~~ | Already implemented — `NowPlayingWidgetStore.writeArtwork` confirmed complete |
| ~~**Background library refresh**~~ | **Added in Phase 5** — `BGAppRefreshTask` in `SceneDelegate`; scheduled on background transition |
| ~~**Siri integration**~~ | **Added in Phase 5** — `PlayArtistIntent`, `SkipTrackIntent` added to `HyperionIntents.swift` + `HyperionShortcuts` |
| ~~**Crossfade between tracks**~~ | **Added in Phase 5** — `OrpheusPlaybackEngine.crossfadeEligible` + `rampVolume(to:over:)`; disabled for streams/short tracks |

---

## Phase 5 — Fixes & Features Applied

**Date:** 2026-05-08

### Task 1 — OOUserLinkOverrides v2 Key Scheme

| File | Change |
|------|--------|
| `OOUserLinkOverrides.swift` | New `exactKey = workID:albumID:sortedTrackIDs` scheme; `albumKey` fallback for backward compat; custom decoder defaults `lmsTrackIDs=[]` for pre-v2 records |
| `LMSLibraryLinker.swift` | `isConfirmed/isRejected` calls updated with `trackIDs: $0.lmsTrackIDs`; `confirmCandidate/rejectCandidate` updated with `trackIDs:` parameter |
| `OOWorkDetailView.swift` | `isConfirmed`, `remove`, `confirmCandidate`, `rejectCandidate` calls updated with `trackIDs: candidate.lmsTrackIDs` |

### Task 2 — PlayerViewModel Split

`PlayerViewModel.swift` (2988 lines) split into 6 focused files:

| File | Contents |
|------|---------|
| `PlayerViewModel.swift` | Core state, init/deinit, scrobbling, save/restore, work-group bookkeeping |
| `PlayerViewModel+Lifecycle.swift` | Audio session, app lifecycle, interruption/route-change handlers |
| `PlayerViewModel+NowPlayingInfo.swift` | Lock-screen remote controls, MPNowPlayingInfoCenter updates |
| `PlayerViewModel+PlaybackAPI.swift` | All public playback entry points (play, pause, skip, seek, shuffle, etc.) |
| `PlayerViewModel+Queue.swift` | Queue management (clear, remove, reorder) + artwork loading |
| `PlayerViewModel+Playback.swift` | Private Orpheus path, gapless, crossfade, radio queue refresh |

### Task 3 — UIScreen.main.bounds.size Replacement

`PlayerViewModel+NowPlayingInfo.swift` line in `updateNowPlayingInfo`: replaced `UIScreen.main.bounds.size` with `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.size ?? CGSize(width: 390, height: 844)`.

### Task 4 — Alphabet Scrubber 44pt Tap Target

`ClassicalBrowserView.swift` `letterButton`: added `.frame(width: 44, height: 44).contentShape(Rectangle())` outside the 28×28 circle — visual size unchanged, hit target meets HIG minimum.

### Task 5 — LyricsService Disk Cache TTL + Deduplication

`LyricsService.swift`:
- Cache directory moved from `Documents` to `Caches` (OS can evict on low storage)
- `CacheDTO` gains `fetchedAt: Date?`; `loadFromCache` rejects entries older than 30 days
- Key bumped from `v2|artist|track|album` to `v3|artist|track` — album dropped so the same track on multiple albums shares one cache entry

### Task 6 — loadSongs(matching:) Server-side Filter

`LibraryViewModel.swift`: added `func loadSongs(matching query: String, limit: Int = 100) async throws -> [Track]` that delegates to `LyrionAPI.searchTracks(term:count:)` — avoids full-library load for filtered lookups.

### Task 7 — Widget Artwork App Group Cache

Already fully implemented: `NowPlayingWidgetStore.writeArtwork` writes a JPEG thumbnail to the App Group container; `HyperionWidget` reads `widget_artwork.jpg` from the same container. No changes required.

### Task 8 — BGAppRefreshTask

`SceneDelegate.swift` `AppDelegate`:
- Registered handler for `com.sarpedon.hyperion.libraryRefresh` in `application(_:didFinishLaunchingWithOptions:)`
- `scheduleLibraryRefresh()` submits a `BGAppRefreshTaskRequest` with 15-minute earliest begin date
- `handleLibraryRefresh(_:)` calls `loadRecentAlbums(force:)` and `loadRecentlyPlayed(force:)` on the main actor
- `HyperionApp.swift`: `scheduleLibraryRefresh()` called on every `.background` scene phase transition

> **Note:** Add `com.sarpedon.hyperion.libraryRefresh` to `BGTaskSchedulerPermittedIdentifiers` in `Info.plist` and declare `UIBackgroundModes = [fetch]` for the task to be approved at runtime.

### Task 9 — ArtworkColorExtractor

`ArtworkColorExtractor.swift` (new file):
- `actor ArtworkColorExtractor` with `extract(from:) -> Color`
- 8×8 downsampled render via `CGContext`; picks most saturated non-black/white pixel using HSL
- Normalises lightness to ~0.55 for legibility on dark backgrounds; falls back to `.roonAccent`

`PlayerViewModel.swift`: `@Published var accentColor: Color = .roonAccent` + `accentColorExtractionTask`

`PlayerViewModel+NowPlayingInfo.swift` `updateNowPlayingInfo`: kicks off extraction on each track change using a 80pt artwork thumbnail; cancels any in-flight task for the previous track.

### Task 10 — Siri / AppIntents

`HyperionIntents.swift`:
- `ArtistEntity` + `ArtistEntityQuery` (delegates to `LibraryViewModel.shared.artists`)
- `PlayArtistIntent` — fetches tracks via `LyrionAPI.getTracksForArtist(artistID:)` and calls `playTracks(_:)`
- `SkipTrackIntent` — calls `PlayerViewModel.shared.nextTrack()`
- `HyperionShortcuts`: two new `AppShortcut` entries for "Play [artist]" and "Skip the track"

### Task 11 — Crossfade Eligibility + OrpheusPlaybackEngine.rampVolume

`OrpheusPlaybackEngine.swift`:
- `crossfadeEligible: Bool` — `false` for `.streamLike` streams or unknown duration (no precise EOS timing)
- `rampVolume(to:over:) -> Task<Void,Never>` — equal-power task-based ramp using `AVAudioPlayerNode.volume`

`PlayerViewModel+Playback.swift` `startCrossfadeOut/In`:
- `startCrossfadeOut` now returns early if `orpheusEngine?.crossfadeEligible == false`
- Both fade functions delegate to `engine.rampVolume(to:over:)` when Orpheus is active, falling back to the existing AVPlayer task loop otherwise
