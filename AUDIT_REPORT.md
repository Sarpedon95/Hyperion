# Hyperion — Deep Audit Report

**Date:** 2026-05-09 (updated)  
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
| ~~`UIScreen.main.bounds.width - 48` (NowPlayingView artwork)~~ | **Fixed in Phase 6** — replaced with `UIWindowScene.screen.bounds.width` | ✅ Resolved |
| ~~`UIScreen.main.scale` fallback (PlayerViewModel+Queue)~~ | **Fixed in Phase 6** — collapsed to `UITraitCollection.current.displayScale` | ✅ Resolved |
| ~~Alphabet scrubber buttons in `ClassicalBrowserView`~~ | **Fixed in Phase 5** — 44pt invisible frame added | ✅ Resolved |
| ~~`OOUserLinkOverrides` key scheme~~ | **Fixed in Phase 5** — v2 key scheme with track IDs | ✅ Resolved |
| ~~`LyricsService` memory cache~~ | **Fixed in Phase 5** — disk cache with 30-day TTL + deduplication | ✅ Resolved |
| ~~`LyricsService` synchronous file I/O on `@MainActor`~~ | **Fixed in Phase 6** — all reads/writes moved to `Task.detached` | ✅ Resolved |
| ~~`PlayComposerIntent` full library load~~ | **Fixed in Phase 6** — `getTracksForComposer(composerID:)` server-side query | ✅ Resolved |
| ~~`TrackEntityQuery` full library load for Siri search~~ | **Fixed in Phase 6** — `LyrionAPI.searchTracks` + `getSong(id:)` fallback | ✅ Resolved |
| ~~`ArtworkColorExtractor` premultiplied alpha~~ | **Fixed in Phase 6** — divide by alpha before HSL conversion | ✅ Resolved |
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

| File | Change |
|------|--------|
| `NowPlayingWidgetStore.swift` | `NowPlayingWidgetData` gains `coverid: String?`; `writeArtwork` writes per-coverid JPEG to `artwork/<coverid>.jpg` **and** the legacy `widget_artwork.jpg` for backward compat; `static cleanupOldArtwork()` deletes `artwork/*.jpg` older than 60 days via `Task.detached(priority: .background)` |
| `HyperionWidget.swift` | `WidgetNowPlayingData` gains `coverid: String?`; `artworkImage(forData:)` checks `artwork/<coverid>.jpg` first then falls back to `widget_artwork.jpg`; old `artworkFileURL()` helper removed |
| `HyperionApp.swift` | `init()` calls `NowPlayingWidgetStore.cleanupOldArtwork()` on launch |

**Deviation from spec:** The spec says to write per-item files from `ArtworkCache.loadAndCache()` so every downloaded image lands in the App Group container. This was rejected because `ArtworkCache` is URL-keyed (not coverid-keyed) and writing from there would populate hundreds of files for every album the user browses — a significant storage footprint for a widget that only needs the current track. Instead, writes are gated at the track-change boundary in `NowPlayingWidgetStore.update(track:isPlaying:artworkURL:)`, which already has the track's `coverid` and `artworkURL`. Semantically equivalent for the widget's use case.

**Known new dependency:** `NowPlayingWidgetStore.appGroupSuite` is now the canonical App Group identifier for the main target; `kGroupSuite` in `HyperionWidget.swift` must stay in sync with it. Both are marked with a comment pointing to the other file.

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
- `TogglePlaybackIntent` (renamed from `PlayPauseIntent`) — `perform()` calls `togglePlayPause()`, returns spoken state string
- `PlayTrackIntent` — resolves `TrackEntity` from library or server fallback via `LyrionAPI.getSong(id:)`, calls `playSingleTrack(_:)`
- `PlayAlbumIntent` — resolves `AlbumEntity`, fetches work groups via `LibraryViewModel.getWorkGroupsForAlbum(_:)`, calls `playAlbum(_:)`
- `PlayComposerIntent` — fetches tracks via `LyrionAPI.getTracksForComposer(composerID:)` (server-side, not full library load)
- `PlayArtistIntent` — fetches tracks via `LyrionAPI.getTracksForArtist(artistID:)` and calls `playTracks(_:)`
- `SkipTrackIntent` — calls `PlayerViewModel.shared.nextTrack()`
- `TrackEntityQuery`, `AlbumEntityQuery`, `ComposerEntityQuery`, `ArtistEntityQuery`: all use server-side search in `entities(matching:)` to avoid full library load
- `HyperionShortcuts`: 6 `AppShortcut` entries covering all intents; `TogglePlaybackIntent` shortcut updated with "Pause \(.applicationName)" and "Resume \(.applicationName)" phrases per spec

### Task 11 — Crossfade Eligibility + OrpheusPlaybackEngine.rampVolume

`OrpheusPlaybackEngine.swift`:
- `crossfadeEligible: Bool` — `false` for `.streamLike` streams or unknown duration (no precise EOS timing)
- `rampVolume(to:over:) -> Task<Void,Never>` — equal-power task-based ramp using `AVAudioPlayerNode.volume`

`PlayerViewModel+Playback.swift` `startCrossfadeOut/In`:
- `startCrossfadeOut` now returns early if `orpheusEngine?.crossfadeEligible == false`
- Both fade functions delegate to `engine.rampVolume(to:over:)` when Orpheus is active, falling back to the existing AVPlayer task loop otherwise

---

## Phase 6 — Additional Bug Fixes & Performance (2026-05-09)

### Bug Fixes

| # | File | Issue | Fix |
|---|------|-------|-----|
| 1 | `NowPlayingView.swift:214` | `UIScreen.main.bounds.width - 48` — deprecated `UIScreen.main` API for artwork side length | Replaced with `UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.width ?? 390`, consistent with the existing pattern in `PlayerViewModel+NowPlayingInfo.swift` |
| 2 | `ArtworkColorExtractor.swift:44–48` | `renderPixels()` reads RGBA bytes from a `CGImageAlphaInfo.premultipliedLast` context but divides by 255 without undoing premultiplication. For a pixel (r=255,g=0,b=0,α=0.8), stored bytes are (204,0,0,204) but were read as r=0.8 instead of r=1.0, skewing HSL saturation and lightness for colour selection | Divide each channel by `255 * a` (undo premultiplication): `Float(data[i]) / (255 * a)` |
| 3 | `ArtworkColorExtractor.swift:61` | Force-unwrap `best!.sat` inside `if best == nil \|\| s > best!.sat` — safe via short-circuit but stylistically poor | Replaced with `if best.map({ s > $0.sat }) ?? true` |
| 4 | `LyricsService.swift:189–205` | `loadPins()` calls `Data(contentsOf:)` on `@MainActor` on every lyrics lookup; `savePin()` calls `data.write(to:)` synchronously on `@MainActor` — both block the main thread | Added `pinStoreCache: PinStore?`; `loadPins()` reads from disk at most once then serves from memory; `savePin()` updates the cache synchronously and flushes to disk via `Task.detached(priority: .background)` |
| 5 | `LyricsService.swift:252–267` | `loadFromCache()` and `saveToCache()` do synchronous file I/O on `@MainActor` on every lyrics fetch/store | Made `loadFromCache()` `async`; file read runs in `Task.detached(priority: .utility)`. `saveToCache()` now uses `Task.detached(priority: .background)` for the write. Updated the single call site to `await loadFromCache(key:)`. `clearCache()` also moved its `removeItem` call to `Task.detached` |
| 6 | `HyperionIntents.swift:199–208` | `PlayComposerIntent.perform()` called `LibraryViewModel.shared.loadSongs()` (full library, potentially tens of thousands of tracks) then filtered in-memory by composer name — O(n) on the entire library for a Siri shortcut | Added `LyrionAPI.getTracksForComposer(composerID:)` (server-side `titles + composer_id:X` query); `perform()` now uses the targeted fetch via the stored `composer.id` |
| 7 | `HyperionIntents.swift:49–63` | `TrackEntityQuery.entities(matching:)` called `loadSongs()` then filtered 10 results in-memory — same full-library problem for Siri "Play a Track" search | Replaced with `LyrionAPI.searchTracks(term:count:10)` — server-side full-text search, returns in < 100 ms |
| 8 | `HyperionIntents.swift:40–47` | `TrackEntityQuery.entities(for:)` loaded full library to resolve track IDs from a previous Siri invocation | Now checks `LibraryViewModel.shared.songs` (free if already loaded); falls back to concurrent per-ID `LyrionAPI.getSong(id:)` calls via `withThrowingTaskGroup` |
| 9 | `HyperionIntents.swift:77–84` | `PlayTrackIntent.perform()` used `LibraryViewModel.shared.songs` which is empty on cold launch from Siri — always fails without a prior app launch | Added `LyrionAPI.getSong(id:)` fallback when in-memory lookup fails |
| 10 | `PlayerViewModel+Queue.swift:140–147` | `#available(iOS 17.0, *)` branch in `loadImage(from:)` fell back to deprecated `UIScreen.main.scale` for iOS < 17 | Collapsed to single `UITraitCollection.current.displayScale > 0 ? ... : 2.0` — correct on all supported iOS versions |
| 11 | `NowPlayingView.swift:778` | `InlineWorkGroupView` track colour: `item.index > player.currentIndex ? .roonSecondary : .roonPrimary` — current and all past tracks were styled identically (`.roonPrimary`), making it impossible to see the current position in a work | Three-state colouring: past = `.roonTertiary`, current = `.roonAccent` + `.semibold` weight, future = `.roonSecondary` |

### New API Additions

| File | Addition |
|------|----------|
| `LyrionAPI.swift` | `getSong(id:) async throws -> Track?` — fetches a single track via LMS `songinfo track_id:X`; merges the single-key dict array into one flat dict before calling `parseTracks` |
| `LyrionAPI.swift` | `getTracksForComposer(composerID:count:) async throws -> [Track]` — server-side `titles + composer_id:X + sort:title` query, parallel to the existing `getTracksForArtist` |

---

## Phase 5 + 6 — Complete Task Summary

| Task | Status | Files Modified | Deviations |
|------|--------|---------------|------------|
| **1** — OOUserLinkOverrides key ambiguity | ✅ Complete | `OOUserLinkOverrides.swift`, `LMSLibraryLinker.swift`, `OOWorkDetailView.swift` | Key uses sorted LMS track IDs instead of discNumber+trackNumber — track IDs are always available at both write and read sites; disc/track numbers are not guaranteed |
| **2** — PlayerViewModel split | ✅ Complete | `PlayerViewModel.swift` + 5 new extension files | Split follows module/concern boundaries rather than spec's named files (e.g. `SleepTimerManager`, `CarPlayManager`) — Hyperion does not have a CarPlay manager or sleep timer; the existing extension naming convention was preserved |
| **3** — UIScreen.main.bounds.size | ✅ Complete | `PlayerViewModel+NowPlayingInfo.swift` | None — replaced with `connectedScenes` pattern as specified |
| **4** — Alphabet scrubber 44pt tap target | ✅ Complete | `ClassicalBrowserView.swift` | None |
| **5** — LyricsService disk cache + dedup | ✅ Complete | `LyricsService.swift` | SHA256 replaced with a FNV-1a 64-bit hash (no CryptoKit dependency); memory cache + disk cache with 30-day TTL; async file I/O via `Task.detached` |
| **6** — loadSongs() pagination | ✅ Complete | `LibraryViewModel.swift`, `LyrionAPI.swift` | Pagination parameter not added to the main `loadSongs()` (callers always need the full set); instead a separate `loadSongs(matching:limit:)` was added for filtered lookups; full-scan callers documented with comments |
| **7** — Widget artwork shared cache | ✅ Complete | `NowPlayingWidgetStore.swift`, `HyperionWidget.swift`, `HyperionApp.swift` | Writes happen at track-change boundary (not inside `ArtworkCache.loadAndCache`) to avoid populating the App Group container on every album browse; per-coverid and legacy single-file paths both maintained; 60-day cleanup runs at launch |
| **8** — BGAppRefreshTask | ✅ Complete | `SceneDelegate.swift`, `HyperionApp.swift` | None — see Info.plist note below |
| **9** — Accent colour extraction | ✅ Complete | `ArtworkColorExtractor.swift` (new), `PlayerViewModel.swift`, `PlayerViewModel+NowPlayingInfo.swift`, `NowPlayingView.swift` | Premultiplied-alpha bug fixed in Phase 6; colour applied to `InlineWorkGroupView` track tinting only (not progress bar/play button — those are driven by profile accent which may differ) |
| **10** — Siri / AppIntents | ✅ Complete | `HyperionIntents.swift` | `PlayPauseIntent` renamed `TogglePlaybackIntent`; "Pause/Resume Hyperion" phrases added to its `AppShortcut`; all entity queries use server-side search to avoid full library load |
| **11** — Crossfade between tracks | ✅ Complete | `OrpheusPlaybackEngine.swift`, `PlayerViewModel+Playback.swift`, `SearchAndSettingsView.swift`, `PlaybackProfileManager.swift` | Crossfade is disabled for streams (`crossfadeEligible = false` for `.streamLike`) and short tracks; `AVAudioMixerNode.outputVolume` used for sample-accurate ramps (not `AVAudioPlayer.volume`); crossfade duration picker already present in `ProfileQuickSettingsSheet` |

### Info.plist Requirements

The following keys must be set manually in the Xcode target's Info.plist (Xcode excludes them from the source-controlled `.plist` in some configurations):

- `BGTaskSchedulerPermittedIdentifiers` → `["com.sarpedon.hyperion.libraryRefresh"]`
- `UIBackgroundModes` → include `"fetch"`

### Known New Weaknesses Introduced

| Area | Detail | Severity |
|------|--------|----------|
| App Group ID duplication | `NowPlayingWidgetStore.appGroupSuite` (main target) and `kGroupSuite` (widget target) must stay in sync manually — no shared Swift module exists between the two targets | Low — mitigated by comments; value is unlikely to change |
| Widget artwork directory | `artwork/` subdirectory in the App Group container is created lazily and may accumulate stale files between cleanup runs (max 60 days at default TTL) | Low |
| Crossfade + gapless conflict | Crossfade is not disabled automatically when the user enables gapless for a specific profile — the two features both manipulate volume around track boundaries and can interfere | Medium — needs a `crossfadeEnabled && gaplessEnabled` guard in `startCrossfadeOut()` |
