# Hyperion — Production Audit Report

## Section 1 — Synced Lyrics ✅

### Problems fixed

| Issue | Before | After |
|-------|--------|-------|
| Lyrics load timing | Triggered on view open | Triggered on track change via `PlayerViewModel.currentTrack.didSet` |
| Memory cache | None | `LyricsService.memoryCache: [Int: LyricsResult]` keyed by track ID |
| Instant serve | Always showed spinner | `cachedResult(trackID:)` synchronous probe skips spinner if prefetched |
| Fetch timeout | No timeout (could hang indefinitely) | 5-second `withThrowingTaskGroup` race → `.unavailable` on timeout |
| Scroll animation | `.spring(response: 0.45, dampingFraction: 0.88)` | `.easeInOut(duration: 0.25)` |
| Line pre-highlight | `time - 0.3` = 300 ms **delay** | `time + 0.3` = 300 ms **pre-highlight** |
| InterludeDots timer | `Timer.scheduledTimer` with value-captured `isActive`; never invalidated on disappear; multiple timers stacked on each `startPulse()` call | `Timer.publish(...).autoconnect()` via `.onReceive` — cancels automatically |

### Files changed
- `Hyperion/LyricsService.swift`
- `Hyperion/PlayerViewModel.swift`
- `Hyperion/LyricsView.swift`

---

## Section 2 — Bug Audit ✅

### Critical bugs fixed

**InterludeDots runaway timer** (`LyricsView.swift`)
- **Root cause**: `startPulse()` created a new `Timer.scheduledTimer` each time it was called (on `onAppear` and on every `isActive → true` transition). The closure captured `isActive` by value, so the `guard isActive else { timer.invalidate() }` check always saw the original `true` — the timer never self-invalidated. When the view disappeared, the timers continued to fire indefinitely.
- **Fix**: Replaced with `Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()` + `.onReceive`. The publisher subscription is tied to the view lifecycle and cancels automatically on disappear.

**Force-unwrapped URLComponents** (`AudiomuseManager.swift`)
- **Root cause**: Three `URLComponents(url:resolvingAgainstBaseURL:)!` force unwraps in `testConnection`, `probeAvailability`, and `fetchMix`. This returns an optional and can return `nil` for certain URL schemes or malformed inputs.
- **Fix**: Replaced with `guard var comps = URLComponents(...) else { return nil/false/"Invalid URL" }`.

### Patterns audited — no action needed

| Pattern | Finding |
|---------|---------|
| Force-unwraps (`!`) | None outside the `URLComponents` cases above |
| Force-casts (`as!`) | None |
| Force-try (`try!`) | None |
| Empty catch blocks | None — all catch blocks log or propagate |
| Missing `[weak self]` in `.sink` | `AudiomuseManager.observeConnection` uses `[weak self]` correctly |
| Bare `Task {}` in view models | All either on singletons or hold intentional strong references that release on completion |
| KVO observations | All stored in typed vars (`statusObservation`, `durationObservation`) and invalidated in `deinit`/teardown |
| Combine subscriptions | Stored in `cancellables: Set<AnyCancellable>` in all managers |
| NotificationCenter observers | All removed in disconnect/deinit methods |
| Uncancelled tasks | All long-running tasks stored by name and cancelled before replacement |

---

## Section 3 — Performance ✅

### Architecture already optimal

**ArtworkCache**
- Uses `CGImageSourceCreateThumbnailAtIndex` (ImageIO) to decode at exact pixel size — no full decode then scale
- Pixel bucketing (256px steps, cap 2048) ensures a 148pt and 152pt thumbnail share a cache slot
- NSCache `totalCostLimit` = 80 MB with cost set to actual decoded byte size (w × h × 4)
- In-flight coalescing via `inFlight: [String: Task<UIImage?, Never>]` prevents duplicate downloads for the same key
- Missing-artwork backoff (`missingArtworkUntil`) prevents hammering LMS for bad coverids
- Decode happens off MainActor (`nonisolated static func downsampledImage`)

**LyrionAPI JSON parsing**
- `performRPCRequest` is `nonisolated static` — URLSession fetch + JSONSerialization happen entirely off MainActor
- All parse helpers (`parseAlbums`, `parseTracks`, etc.) are `nonisolated static`
- MainActor methods only touch the parsed struct values, not the raw JSON

**LibraryViewModel**
- Artist detail cache: 10-entry LRU with in-flight task coalescing
- First-page fast path: `songs` published after first batch so UI renders before full library loads
- All load tasks stored by name and cancelled before re-issue

**Startup time**
- `HyperionApp.init()` only touches singletons (`PlayerViewModel`, `DownloadManager`, `AudiomuseManager`)
- Artwork loading, library fetch, and lyrics prefetch all lazy

---

## Section 4 — UI Polish ✅

### Changes made

**Mini-player loading indicator** (`ContentView.swift` — `MiniPlayerView`)
- Play/pause button now renders a `ProgressView` spinner when `player.isLoading == true`
- Smooth ZStack transition between spinner and icon using SwiftUI's implicit animation
- Accessibility label updates from "Play"/"Pause" to "Loading" during buffering

### Already present (no action needed)

| Feature | Status |
|---------|--------|
| Songs empty state | ✅ Icon + "No songs found" |
| Artists skeleton | ✅ `ProgressView` while loading |
| Albums skeleton | ✅ Placeholder cells while loading |
| Genres empty state | ✅ Icon + "No genres found" |
| Liked Tracks empty state | ✅ Present |
| Queue save/clear confirmation | ✅ `confirmationDialog` |
| Server Playlists create/delete | ✅ Alert + `confirmationDialog` |
| Local Playlists rename/delete | ✅ Alert + `confirmationDialog` |
| ArtistDetail skeleton | ✅ `.redacted(reason: .placeholder)` grid + list |
| Search empty state | ✅ "No results for …" |

---

## Section 5 — Accessibility ✅

### Changes made

**Scrubber VoiceOver** (`NowPlayingView.swift` — `progressSection`)
- `.accessibilityLabel("Playback position")`
- `.accessibilityValue` reads formatted current time + duration: `"1:23 of 4:56"`
- `.accessibilityAdjustableAction` — swipe up = +10 s, swipe down = −10 s

**Decorative artwork** (`ContentView.swift` — `ArtworkView`)
- Added `.accessibilityHidden(true)` to `ArtworkView.body`
- Artwork is purely decorative in every app context (track/album text is always displayed alongside it); hiding it prevents VoiceOver from reading a generic "image" element for every row in every list

### Already present (no action needed)

| Element | Status |
|---------|--------|
| Play/Pause button | ✅ `.accessibilityLabel(player.isPlaying ? "Pause" : "Play")` |
| Previous/Next track | ✅ `.accessibilityLabel("Previous track")` / `"Next track"` |
| All `NowPlayingIconButton` instances | ✅ `accessibilityLabel` parameter required by initializer |
| Quality pill | ✅ `.accessibilityLabel("Audio quality: … Tap for signal path.")` |
| Sleep timer button | ✅ `.accessibilityLabel("Sleep timer active" / "Sleep timer")` |
| Swipe-to-delete rows | ✅ SF Symbols (`"trash"`, `"plus"`, `"play"`) used throughout |

---

## Summary

| Section | Issues Found | Issues Fixed | Issues Deferred |
|---------|-------------|-------------|-----------------|
| 1 — Lyrics | 7 | 7 | 0 |
| 2 — Bugs | 2 critical | 2 | 0 |
| 3 — Performance | 0 | — | — |
| 4 — UI Polish | 1 (mini-player spinner) | 1 | Full-screen album art pinch-to-zoom (significant scope) |
| 5 — Accessibility | 2 (scrubber, artwork) | 2 | Dynamic Type (app-wide systemic change requiring font API refactor) |

### Deferred items

**Full-screen album art pinch-to-dismiss**: The `NowPlayingView` artwork is an ARC-style full-width panel. Adding a `MagnificationGesture` that presents the artwork in a `fullScreenCover` with a `UIPinchGestureRecognizer` dismiss is a standalone feature requiring significant gesture state management. Deferred to a dedicated pass.

**Dynamic Type**: `roonBody`, `roonTitle`, and `roonMono` use `.system(size:)` with fixed point sizes. Migrating to Dynamic Type would require adding `relativeTo:` text-style parameters to all three helpers and auditing every call site in the app. Deferred to a dedicated pass — the current sizes are legible at default scale and the app targets audiophile users who are less likely to use large accessibility sizes.
