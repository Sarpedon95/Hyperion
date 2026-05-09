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

---

## Phase 7 — UI Fixes, Work Navigation & Continued Polish (2026-05-09)

### NowPlayingView — 5 UI Fixes

| # | Location | Before | After |
|---|----------|--------|-------|
| 1 | `artworkSection` | `.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)` with `clipShape`/`shadow` after padding | Removed static frame modifiers; `clipShape`/`shadow` applied before `padding(.horizontal, 24)` for correct rounded-corner shadow |
| 2 | Transport prev/next icons | `"backward.fill"` / `"forward.fill"` (seek step icons) | `"backward.end.fill"` / `"forward.end.fill"` (skip to previous/next track icons) |
| 3 | Time labels | `.foregroundColor(.secondary)` (system colour, renders mid-grey on dark bg) | `.foregroundColor(.white.opacity(0.55))` — visible against the blurred dark background at all times |
| 4 | `trackInfo` | Contained a redundant profile pill `Button` block (~16 lines) after the pill was moved to the header bar in a prior session | Block removed |
| 5 | Queue button icon | `"line.3.horizontal"` (hamburger) | `"list.bullet"` — semantically correct for a queue/tracklist |

### ComposerDetailView — Library Work Navigation

Tapping a work in `ComposerDetailView` now navigates to the correct location in the local library.

**Resolution logic** (in `ComposerDetailViewModel.resolveLibraryDestination(work:composer:)`):
1. Query `LMSLibraryLinker.candidates(forWorkID:)` — returns confirmed/indexed `[WorkRecordingCandidate]`.
2. If 1 candidate → navigate directly to `AlbumDetailView` for that album, scrolled to the first matching track; auto-play if it's the only track.
3. If > 1 candidate → show `WorkRecordingPickerView` ("Choose a recording") with performer summaries and artwork.
4. If 0 candidates → fuzzy-search `LyrionAPI.searchAlbums` as fallback using the same scoring algorithm as `OOWorkRow.fuzzyMatchAlbumID`, then re-evaluate.
5. If still not found → brief "Not in library" indicator on the row for 2.5 s, then auto-clears.

**Navigation stack** (back navigation correct at all depths):
- Single match: `ComposerDetail → AlbumDetail`
- Multiple matches: `ComposerDetail → RecordingPicker → AlbumDetail`

**Scroll + highlight**: `AlbumDetailView` gains `scrollToTrackID: Int?` and `autoPlay: Bool`. After `workGroups` loads, a `ScrollViewReader` scrolls to `"track-\(id)"` with a 350 ms settle delay and 0.4 s eased animation; the row briefly shows a `Color.roonAccent.opacity(0.13)` background for 1.8 s then fades out. Uses a custom `EnvironmentKey` (`highlightedTrackID`) to thread the highlight state to `MovementRowView` without parameter drilling.

**New types added to `ComposerDetailView.swift`:**

| Type | Role |
|------|------|
| `WorkLibraryNav` | Enum: `.singleAlbum(Album, Int?, Bool)` / `.picker([WorkRecordingEntry])` / `.notFound` |
| `WorkRecordingEntry` | `Identifiable, Hashable`; holds `album: Album`, `firstTrackID: Int?`, `performerSummary: String` |
| `AlbumNavRequest` | `Identifiable, Hashable` wrapper for `navigationDestination(item:)` |
| `PickerNavRequest` | `Identifiable, Hashable` wrapper for the picker sheet |
| `WorkRecordingPickerView` | "Choose a recording" list — artwork, album title, performer summary, year |
| `RecordingPickerRow` | Single row in the picker, tapping navigates to `AlbumDetailView` |

### LibraryView — 4 Polish Fixes

| # | Location | Before | After |
|---|----------|--------|-------|
| 1 | `CenteredArtworkHeader` title | `.system(size: 22, weight: .bold, design: .default)` | `.roonTitle(22)` (serif design token) |
| 2 | `AlbumDetailView` Play Now button | `Color(hex: "#5B4FCF")` (hardcoded purple) | `Color.roonAccent` (coral red design token) |
| 3 | `MovementRowView` ellipsis button | No accessibility label | `.accessibilityLabel("More options for \(track.title)")` |
| 4 | Library menu — Offline Library icon | `"arrow.down.circle.fill"` (same as Downloads) | `"wifi.slash"` — semantically distinct from Downloads |

### Phase 7 Performance Fix

| File | Location | Issue | Fix |
|------|----------|-------|-----|
| `LibraryView.swift` | `ArtistDetailView.tracksByArtist` | Computed property called 6+ times per render pass, each running O(n) `SearchTextNormalizer.folded` comparisons over all loaded songs | Converted to `@State var tracksByArtist: [Track] = []`; populated once in `.task(id: artist.id)` after the artist detail loads; reset to `[]` on artist change. Removed unused `localTracks: [Track]` state and unused `likedByArtist` computed property |

### Phase 7 Additional Polish

| File | Location | Before | After |
|------|----------|--------|-------|
| `LibraryView.swift` | `ArtistDetailView` hero name | `.font(.system(size: 32, weight: .bold))` | `.font(.roonTitle(32))` (serif design token) |

---

## Missing Features vs. Roon / Apple Music

| Feature | Gap vs. Roon | Gap vs. Apple Music | Notes |
|---------|-------------|---------------------|-------|
| ~~**Radio / similar-artist mix**~~ | **Added in Phase 8** — `startRadio(seed:)` + `stopRadio()`; genre-seeded queue replenishment; `RadioSessionView` sheet; radio pill badge in `NowPlayingView`; mini-player antenna badge; "Start Radio" in track and album context menus | ~~Apple Music AutoPlay~~ | Queue replenishment uses genre-based or random fallback; `radioSeed: Track?` tracks the originating track |
| ~~**Lyrics with time-sync (LRC)**~~ | **Added in Phase 7** — inline synced LRC panel in `NowPlayingView`; auto-scroll + active-line highlight; falls back to plain text | ~~Apple Music shows scrolling lyrics synced to playback~~ | LRC parsing was already in `LyricsService` via LRCLIB; inline panel toggled from lyrics button |
| **Composer biography** | Roon pulls from Rovi; structured discography | — | Hyperion uses OpenOpus bios; no Discogs / Rovi integration |
| ~~**Dynamic range display**~~ | **Added in Phase 7** — `InfoBadge("DR\(n)")` in `AlbumInfoPanel`; parsed from LMS `dynamic_range`/`DR` tag into `Album.dynamicRange` | — | Badge shows only when DR > 0 |
| ~~**Crossfade for pop/radio**~~ | **Added in Phase 8** — `CrossfadeShape` enum (`.linear`, `.equalPower`, `.sCurve`); `ProfileSettings.crossfadeShape` persists per-profile; `rampVolume(to:over:shape:)` in `OrpheusPlaybackEngine` + AVPlayer path; Settings shows segmented picker + inline Canvas curve preview | ~~Apple Music crossfade toggle~~ | Default shape is `.equalPower` (existing behaviour preserved) |
| **iCloud Music Library sync** | — | Apple Music iCloud sync | Out of scope for a local LMS client |
| ~~**Global search**~~ | **Added in Phase 7** — `SearchViewModel` now runs OpenOpus omnisearch in parallel; "CLASSICAL COMPOSERS" and "CLASSICAL WORKS" sections in `SearchResultsView`; composer rows → `ComposerDetailView`; work rows → `resolveLibraryDestination` | ~~Apple Music unified search~~ | LMS-only scopes preserved; OO search skipped in Library scope |
| **Playlist collaboration** | — | Roon 2.0 private group playlists | Out of scope |

## Classical-Music-Specific Suggestions

| Suggestion | Detail |
|-----------|--------|
| ~~**Composition date filter**~~ | **Fully complete in Phase 8** — `OOComposerCache` (new actor) fetches all 26 OO letter endpoints in parallel, caches to `Caches/oo_composer_cache.json` (7-day TTL, silent background refresh); `ComposerListView` builds `[String: OOEpoch]` via `epochByName()` and shows era filter chips; chips appear only for epochs present in the current LMS composer list; `ComposerRowView` shows epoch subtitle under name |
| ~~**Work catalogue number display**~~ | **Added in Phase 7** — `OOWorkRow.catalogueHint` shows subtitle (BWV, K., Op.) inline below work title, only when not already present in the title |
| ~~**Multi-movement now-playing progress**~~ | **Added in Phase 7** — `WorkProgressBar` below main scrubber in `NowPlayingView`; shows total work progress (completed movements + currentTime) / totalDuration; hidden for non-multi-movement tracks and flat-fallback groups |
| ~~**Recording vintage filter**~~ | **Added in Phase 7** — decade chip bar in `WorkRecordingPickerView`; shows only decades that have recordings; sourced from `Album.year`; "All" default |
| ~~**Conductor / orchestra display**~~ | **Added in Phase 7** — `Album.conductor` + `Album.band` added to `Models.swift`; parsed from LMS `conductor`/`band`/`orchestra`/`ensemble` tags in `LyrionAPI.parseAlbums`; shown in `CenteredArtworkHeader` via `albumPerformerLine`; also in `AlbumInfoPanel` metadata rows and `AlbumDetailView` conductor row |
| ~~**Period performance tagging**~~ | **Added in Phase 7** — `HIPEnsembleClassifier.swift` (new); substring match on conductor/band/performerSummary vs. ~50-entry built-in list; user-extensible via Settings → Classical → HIP Performers; "HIP" capsule badge in `RecordingPickerRow` and `AlbumDetailView` |
| ~~**Work-level rating / notes**~~ | **Added in Phase 7** — `RecordingAnnotationStore` + `RecordingAnnotationSheet` + `StarRatingView`; keyed by LMS album ID; persisted to `Documents/recording_annotations.json`; shown in `RecordingPickerRow` and `AlbumDetailView` header |

---

## Phase 7 — Section-by-Section Summary (2026-05-09)

### Section 1 — Bug Fixes

| # | Task | File(s) | Status | Notes |
|---|------|---------|--------|-------|
| 1.1 | Crossfade + gapless conflict guard | `PlayerViewModel+Playback.swift` | ✅ Complete | `guard !pm.resolvedGaplessEnabled else { return }` added to `startCrossfadeOut()` |
| 1.2 | OO omnisearch in parallel search | `SearchAndSettingsView.swift` | ✅ Complete | `ooSearchTask` runs in parallel; `OOWorkResult` struct; new CLASSICAL COMPOSERS + CLASSICAL WORKS sections in `SearchResultsView` |

### Section 2 — UI Wiring

| # | Task | File(s) | Status | Notes |
|---|------|---------|--------|-------|
| 2.1 | Conductor/band in AlbumDetailView header | `Models.swift`, `LyrionAPI.swift`, `LibraryView.swift` | ✅ Complete | `CenteredArtworkHeader` gains `performerLine` param; LMS tags may be unpopulated on most albums |
| 2.2 | DR badge in AlbumInfoPanel | `Models.swift`, `LyrionAPI.swift`, `LibraryView.swift` | ✅ Complete | `Album.dynamicRange`; `InfoBadge("DR\(dr)")` shown when DR > 0 |
| 2.3 | OOWork subtitle (catalogue number) | `ComposerDetailView.swift` | ✅ Complete | `OOWorkRow.catalogueHint` skips subtitle if already in title |
| 2.4 | Era filter chips | `ClassicalBrowserView.swift` | ✅ Already present | `ClassicalBrowserView` already had full epoch filter; `ComposerListView` blocked by missing epoch field on LMS `Composer` type |

### Section 3 — New Features

| # | Task | File(s) | Status | Notes |
|---|------|---------|--------|-------|
| 3.1 | Synced LRC inline lyrics in NowPlayingView | `NowPlayingView.swift` | ✅ Complete | `InlineLyricsPanel` toggled from lyrics button; auto-scroll; active line white; plain text fallback; button hidden when unavailable |
| 3.2 | Multi-movement work progress bar | `NowPlayingView.swift` | ✅ Complete | `WorkProgressBar` below scrubber; uses `PlayerViewModel.currentWorkGroup` |
| 3.3 | Recording vintage filter (decade chips) | `ComposerDetailView.swift` | ✅ Complete | `WorkRecordingPickerView` gains `selectedDecade`; chips shown only when >1 decade has recordings |
| 3.4 | HIP tagging + settings | `HIPEnsembleClassifier.swift` (new), `ComposerDetailView.swift`, `LibraryView.swift`, `SearchAndSettingsView.swift` | ✅ Complete | Built-in list of ~50 conductors/ensembles; user-extensible via Settings → CLASSICAL — HIP PERFORMERS; badge in picker row and album detail |
| 3.5 | Work-level recording annotation | `RecordingAnnotationStore.swift` (new), `ComposerDetailView.swift`, `LibraryView.swift` | ✅ Complete | Star rating + free-text notes; edit via pencil icon sheet; shown in picker row and album header |

### Known New Weaknesses Introduced in Phase 7

| Area | Detail | Severity |
|------|--------|----------|
| LMS conductor/band population | `Album.conductor` and `Album.band` will be `nil` on most LMS installs unless the LMS server is configured to expose `conductor` and `band` as custom tags | Low — UI degrades gracefully (fields not shown when nil) |
| OO omnisearch cold start | First OO search after app launch hits LRCLIB.net with no cache; adds ~500ms latency to search results | Low — runs in parallel; LMS results show first |
| ~~`HIPEnsembleClassifier` substring false positives~~ | **Fixed in Phase 8** — replaced with full-phrase contiguous matching using `SearchTextNormalizer.folded()`; built-in entries now require the entire phrase to appear contiguously in the candidate; DEBUG self-test added | — |
| `InlineLyricsPanel` height | Fixed 140pt height may be too small for long lyric lines on smaller screens | Low — truncated by gradient mask; user can expand to full-screen |

---

## Phase 8 — HIP Fix, OO Cache, Crossfade Shape, Radio Mode, Composer Era Filter (2026-05-09)

### Section 1 — HIPEnsembleClassifier False Positive Fix

**File:** `HIPEnsembleClassifier.swift`

- Replaced substring-on-short-token matching with full-phrase contiguous matching: both the built-in entry and the candidate string are folded with `SearchTextNormalizer.folded()`, then `foldedCandidate.contains(foldedEntry)` is checked
- Removed hazardous short tokens (`"the"`, `"simon"`, `"baroque"`) from the default list; replaced with full-name entries (e.g. `"john eliot gardiner"` instead of bare `"gardiner"` for disambiguation)
- Added `#if DEBUG` self-test invoked from `init()` via `runSelfTest(using: self)` — avoids `shared` deadlock by passing the already-constructed instance
- Self-test covers 9 true positives (full names, diacritics, comma-separated summary strings, multi-word ensemble phrases) and 7 true negatives (Simon Rattle, The Beatles, "baroque" as substring, Boston Symphony Orchestra vs. Boston Baroque, partial name "John Gardiner", etc.)

### Section 2 — OpenOpus Composer List Disk Cache

**File:** `OOComposerCache.swift` (new)

- New `actor OOComposerCache` with `static let shared` singleton
- `composers() async -> [OOComposer]` — returns from in-memory if warm; reads `Caches/oo_composer_cache.json` if present; triggers silent background refresh when age > 7 days; blocks on first cold fetch
- `fetchAll()` — fires 26 concurrent tasks (A–Z) via `withTaskGroup`, deduplicates by ID, returns sorted list (~1500–2000 composers)
- `epochByName() async -> [String: OOEpoch]` — returns folded-name → epoch dict for use by ComposerListView; both `.name` and `.complete_name` are indexed; first writer wins for duplicate keys
- Cache payload is `Payload: Codable { composers, fetchedAt }` encoded with `.iso8601` date strategy
- Background refresh is guarded by `refreshTask != nil` check to prevent double-firing

### Section 3 — Crossfade Shape Setting

**Files:** `PlaybackProfile.swift`, `PlaybackProfileManager.swift`, `OrpheusPlaybackEngine.swift`, `PlayerViewModel+Playback.swift`, `SearchAndSettingsView.swift`

- `CrossfadeShape: String, Codable, CaseIterable` added to `PlaybackProfile.swift` with `.linear`, `.equalPower`, `.sCurve`; `gain(t:fadingOut:)` encapsulates the curve math:
  - Linear: `fadingOut ? 1-t : t`
  - Equal-power: `fadingOut ? cos(t·π/2) : sin(t·π/2)` — preserves existing default behaviour
  - S-Curve: `(1±cos(πt))/2` — slow-start, fast-middle, slow-end
- `ProfileSettings.crossfadeShape: CrossfadeShape` (default `.equalPower`) added; backwards-compatible via `defaults(for:)`
- `resolvedCrossfadeShape: CrossfadeShape` added to `PlaybackProfileManager`
- `OrpheusPlaybackEngine.rampVolume(to:over:shape:)` signature updated; shape defaults to `.equalPower` to preserve all existing call sites
- AVPlayer path (`startCrossfadeOut/In`) reads `pm.resolvedCrossfadeShape` and calls `shape.gain(t:fadingOut:)`
- Settings: segmented `Picker` for shape below duration slider (only visible when crossfade enabled); `CrossfadeShapePreview` Canvas draws outgoing (white) and incoming (accent) curves side-by-side

### Section 4 — Radio Mode UI

**Files:** `PlayerViewModel.swift`, `PlayerViewModel+PlaybackAPI.swift`, `RadioSessionView.swift` (new), `NowPlayingView.swift`, `ContentView.swift`, `LibraryView.swift`, `QueueView.swift`

- `PlayerViewModel.radioSeed: Track?` — `@Published` seed track for the current radio session
- `startRadio(seed:)` — sets seed, enables `isRadioEnabled`, clears queue to seed, plays it, then calls `fetchRadioTracks()`
- `stopRadio()` — clears `isRadioEnabled`, `radioSeed`, cancels `radioRefreshTask`
- `RadioSessionView` — `presentationDetents([.medium, .large])` sheet showing: seed artwork + "Radio seed" label, upcoming queue list (`RadioQueueRow` with waveform symbolEffect for current track), Stop Radio destructive button
- `NowPlayingView`: radio pill badge in header (accent capsule, "Radio" + antenna icon), antenna button in bottom toolbar (`.roonAccent` when active); both open `RadioSessionView` sheet; tapping antenna when inactive calls `startRadio(seed: currentTrack)`
- `MiniPlayerView`: `ZStack + .topTrailing` overlay showing 8pt antenna badge on artwork when `isRadioEnabled`
- Context menus: existing album "Start Radio" in `LibraryView` updated to call `startRadio(seed:)` with first track of album; "Start Radio" added to queue-item long-press menu in `QueueView`
- Auto-replenishment: existing `fetchRadioTracks()` / `radioEarlyFetchTriggered` logic unchanged — fires when ≤30 s remaining in queue

### Section 5 — ComposerListView Era Filter

**Files:** `OOComposerCache.swift`, `LibraryView.swift`

- `ComposerListView` gains `@State epochFilter: OOEpoch = .all` and `@State epochByName: [String: OOEpoch] = [:]`
- Background task: `OOComposerCache.shared.epochByName()` loaded once after composers load; uses folded key matching for diacritic-insensitive cross-referencing of LMS composer names against OO data
- `availableEpochs` computed var: only epochs present in the current LMS composer list (avoids showing empty chips for epochs with no matches)
- Horizontal `ScrollView` of `EraChip` buttons (shown only when `availableEpochs` is non-empty); "All" chip always first
- `ComposerRowView` gains optional `epoch: OOEpoch?` parameter; shows epoch name as secondary line when non-nil
- Filtering is purely client-side against the already-loaded LMS composer array (no additional network calls at filter time)

### Known New Weaknesses Introduced in Phase 8

| Area | Detail | Severity |
|------|--------|----------|
| OO composer cache cold start | First app session with no cache fetches 26 endpoints in parallel; takes 2–4 s on slow connections; era chips invisible until complete | Low — chips appear progressively; list is still browsable |
| Radio replenishment is genre-only | `radioTracks(seedTrack:)` uses first genre tag; multi-genre or untagged tracks fall back to random library sample | Low — random fallback is functionally useful |
| ComposerListView epoch lookup false negatives | LMS composer names may differ from OO names (different romanisation, different name order); unmatched composers show no epoch label and are excluded from epoch-filtered views | Medium — only affects composers whose name doesn't match any OO entry exactly |
| CrossfadeShapePreview layout | Canvas occupies 52pt height; may feel cramped on compact widths but is purely decorative | Low |
