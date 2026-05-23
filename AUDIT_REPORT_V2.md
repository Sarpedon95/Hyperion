# Hyperion — Deep Audit Report V2

**Date:** 2026-05-10  
**Scope:** All 89 Swift source files  
**Method:** Every file read in full before writing. Findings reference file:line where possible.

---

## Table of Contents

1. [Playback Engine](#1-playback-engine)
2. [EQ & DSP](#2-eq--dsp)
3. [Lyrics](#3-lyrics)
4. [OpenOpus Integration](#4-openopus-integration)
5. [Artist & Composer Pages](#5-artist--composer-pages)
6. [MusicBrainz](#6-musicbrainz)
7. [Last.fm](#7-lastfm)
8. [Discogs](#8-discogs)
9. [AudioMuse.ai](#9-audiomuse-ai)
10. [Login & Onboarding](#10-login--onboarding)
11. [Final Section](#11-final-section)

---

## 1. Playback Engine

**Files:** `OrpheusPlaybackEngine.swift` (1183 lines), `AudioPlayerManager.swift` (158 lines), `PlayerViewModel+Playback.swift` (1698 lines), `PlayerViewModel+Lifecycle.swift` (419 lines), `PlayerViewModel+NowPlayingInfo.swift` (175 lines)

### Architecture Overview

Hyperion uses two parallel playback paths that share the same AVAudioEngine:

- **Orpheus path** (primary): AVAssetReader decodes audio to raw Float32 PCM, which is pushed into an `AVAudioPlayerNode` for DSP processing. Used for all file-like, seekable, finite-duration formats.
- **AVPlayer fallback**: Used for AirPlay targets, streaming (HTTP Live Streaming), and formats where AVAssetReader can't get a handle (some remote transcoded tracks).

DSP chain order: `playerNode → mainEQNode (10-band) → headphoneEQNode (10-band) → crossfeedMixer → levelingMixer → balanceMixer → mainMixerNode → outputNode`

Gapless playback on the Orpheus path works by preloading the next `OrpheusPlaybackEngine` instance and scheduling its buffers into the same `AVAudioPlayerNode` session before the current track ends.

### Bugs

**[HIGH] Double gapless preload trigger**  
`prefetchNextTrackAsset()` is called in four separate places: at `onRoutingConfirmed` (start of audible playback), at `onNearEnd` (≤3 seconds from end), on route change fallback (`PlayerViewModel+Playback.swift:1263`), and after skip (`~:1328`). The `onRoutingConfirmed` + `onNearEnd` combination means every normal track triggers two preload attempts. The second call cancels the first via `orpheusLoadTask?.cancel()`, so there's no accumulation, but for short tracks (<3s long) both fire within milliseconds. This is wasteful and the cancellation logic is silently swallowing the first load's work.  
`PlayerViewModel+Playback.swift:199, 206, 216`

**[HIGH] Volume leveling is not loudness measurement**  
`applyVolumeLeveling()` computes `gainDB = volumeLevelingTargetLUFS - (-14.0)` and applies it as a static linear gain. This is a fixed offset from a −14 LUFS baseline, not a per-track LUFS measurement. The UI labels and Settings copy use "LUFS" throughout, creating a false impression that Hyperion measures and normalizes actual loudness. In practice every track receives the same gain regardless of its true loudness. Tracks mastered at −6 LUFS and tracks mastered at −23 LUFS are both adjusted by the same amount.  
`OrpheusDSPEngine.swift:290-299`

**[MEDIUM] onNearEnd fires once with no retry on preload failure**  
After `onNearEnd` fires, `engine.onNearEnd = nil` inside `OrpheusPlaybackEngine`. If `scheduleOrpheusGaplessPreload()` fails (network timeout, decode error), there is no second attempt. The track ends with a gap. A retry on next-track-start would help.  
`PlayerViewModel+Playback.swift:206-216`

**[MEDIUM] feedQueue cross-thread generation read is technically UB**  
`OPEReaderState.generation` is written from `@MainActor` and read on `feedQueue` (a serial DispatchQueue) with no lock, relying on ARM cache coherence. The code comments this as intentional. This is not undefined behavior on ARM in practice, but it violates Swift's strict concurrency model and will produce a warning (or error in future Swift versions). A `nonisolated(unsafe)` annotation or an atomic would make this correct by the type system.  
`OrpheusPlaybackEngine.swift` (OPEReaderState struct)

**[LOW] AVQueuePlayer gapless: second track inserted at routing-confirmed, not pre-loaded**  
On the AVPlayer path, `prefetchNextTrackAsset()` calls `avQueuePlayer.insert()` when `onRoutingConfirmed` fires. For very short tracks, this may arrive too late. Apple's recommendation is to pre-insert the next `AVPlayerItem` immediately after the current one begins playing.  
`PlayerViewModel+Playback.swift:255`

### Performance

- The Orpheus buffer loop polls `feedQueue` with a 50 ms `Task.sleep` between iterations. A `DispatchSemaphore` or `AsyncStream` would be more efficient and responsive.
- `rampVolume(to:over:shape:)` uses a `Task` with 16 ms `Task.sleep` to approximate 60 fps volume updates. This is not synchronized to display refresh. For crossfade, the shape gain error is negligible, but a `CADisplayLink`-based approach would be cleaner.
- `maxScheduledBuffers = 8` with `preloadTarget = 88,200 frames` (~2s). Buffer memory is bounded but the 2s preload means any network hiccup >2s causes underrun on the Orpheus path.

### Missing Features

- No bitperfect / exclusive audio mode. `AVAudioSession.setCategory(.playback)` is used, which allows iOS mixing.
- No DSD playback (DoP or native DSD). Hyperion transcodes DSD via LMS on the server side.
- No true LUFS measurement per track (would require real-time loudness metering or an offline analysis pass).
- No ReplayGain tag reading or application. LMS sends ReplayGain values in the songinfo response but Hyperion does not apply them.
- No audio fingerprinting (AcoustID) for tracks missing metadata.

---

## 2. EQ & DSP

**Files:** `OrpheusDSPEngine.swift` (746 lines), `OrpheusEQDetailView.swift`, `OrpheusCrossfeedView.swift`, `OrpheusBalanceView.swift`, `OrpheusSRCView.swift`, `OrpheusVolumeLevelingView.swift`, `CrossfeedAudioUnit.swift`, `PlaybackProfile.swift`

### Architecture Overview

Two 10-band `AVAudioUnitEQ` nodes: `mainEQNode` (listening EQ) and `headphoneEQNode` (headphone correction). Fixed center frequencies at 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz. Each band is a parametric (peak) filter by default; the user can switch individual bands to low shelf, high shelf, low pass, or high pass.

Bauer Stereophonic-to-Binaural (BS2B) crossfeed implemented as a custom `AUAudioUnit` (`CrossfeedAudioUnit.swift`), auto-enabled when headphones are detected via `AVAudioSession.routeChangeNotification`.

### Bugs

**[HIGH] EQ frequency response preview uses approximate formula**  
`responseDB(at:bands:bypassed:)` in `OrpheusDSPEngine` computes the displayed frequency curve using a simplified peak filter approximation. The formula is not the exact biquad transfer function. For shelving and low/high pass filter types the approximation error is larger. The visual curve shown to users is inaccurate enough to mislead when setting surgical cuts or steep shelves.  
`OrpheusDSPEngine.swift` (~line 200)

**[MEDIUM] CrossfeedAU hot-splice can cause brief audio artifact**  
`CrossfeedAudioUnit` loads asynchronously, then `AudioPlayerManager.buildDSPChain()` hot-splices it into the running engine by calling `engine.connect()`. The AVAudioEngine must temporarily reconfigure the graph, which can produce a brief click or silence. The `crossfeedMixer` pass-through is in place to prevent data starvation, but the reconnection itself is not glitch-free.  
`AudioPlayerManager.swift`

**[MEDIUM] Bandwidth (Q) not exposed per-band in the UI**  
`OrpheusEQBand.bandwidth` defaults to 1.0 octave and is stored per band, but the EQ detail view does not render a Q slider for each band. Users cannot set narrow surgical cuts (Q > 4). Audiophile EQ work requires per-band Q control.  
`OrpheusDSPEngine.swift:38, OrpheusEQDetailView.swift`

**[LOW] headphoneEQNode always processes signal even without headphone profile loaded**  
`headphoneEQNode` is always in the DSP chain with all bands at 0 dB gain when no headphone profile is active. This adds unnecessary audio graph complexity and a small CPU cost. The node should be bypassed when no headphone profile is active.  
`AudioPlayerManager.swift`

### Performance

- EQ response preview recomputes on every slider drag frame (~60 Hz per band adjustment). No throttling. On older devices with multiple bands adjusted simultaneously, this can cause UI jank.
- `applyEQ()` iterates over all 10 bands every time any single band changes. A delta-only update would be faster.

### Missing Features

- No EQ preset library (no factory presets like "Rock", "Classical", "Flat").
- No preset import/export (no AUPreset file format support).
- No convolution reverb / room correction (would require an `AVAudioUnitEffect` with IR loading).
- No per-album EQ override (profiles are per-genre or global; no per-album DSP).
- No mid/side EQ for stereo width control.

---

## 3. Lyrics

**Files:** `LyricsService.swift` (726 lines), `LyricsView.swift`

### Architecture Overview

Single provider: LRCLIB (lrclib.net) — free, community-maintained, no API key required. Provider result cached in-memory for the session and to a 30-day disk cache keyed by track ID. Users can pin lyrics (survives cache clear). Synced LRC format with line-level timestamps; falls back to plain text if no synced lyrics exist.

Scoring algorithm for candidate selection: title 45%, artist 35%, duration 15%, synced quality bonus 5%.

### Bugs

**[HIGH] Heart button does not trigger Last.fm love for lyrics-pinned tracks**  
Not a lyrics bug strictly, but noted here because `LyricsView` has no love integration either. The love action is entirely siloed in `LikedTracksStore` (see Section 7).

**[HIGH] Single provider: no failover**  
`LyricsService` has a `provider: any LyricsProvider` property initialized to `LRCLIBProvider()`. The protocol `LyricsProvider` and a multi-provider cascade were clearly planned but never implemented. If LRCLIB is down or rate-limits the client, every lyrics fetch silently fails. No Musixmatch, Genius, or Apple Music Lyrics fallback exists.  
`LyricsService.swift:69`

**[MEDIUM] LRC parser does not handle enhanced (word-level) LRC**  
LRCLIB can return Enhanced LRC with word-level timestamps in the form `<mm:ss.xx>word`. The parser's `parseTimestamp()` only handles the outer `[mm:ss.xx]` line timestamps and passes the inner `<>` tokens through into the displayed text as literal characters. Users see raw `<0:12.34>` strings instead of clean lyrics on tracks that have enhanced LRC.  
`LyricsService.swift:647-680`

**[MEDIUM] Tap-to-seek in LyricsView has no scrubber-conflict guard**  
Tapping a synced lyrics line calls `player.seek(to: ll.time)`. There is no check for whether the user is concurrently dragging the scrubber in NowPlayingView. On iPad split-view or large screens where both could theoretically be visible, a race is possible.  
`LyricsView.swift:81-83`

**[LOW] 5-second provider timeout for slow connections**  
`LyricsService` imposes a 5-second timeout per provider attempt. On slow LTE connections, LRCLIB can take 3-4 seconds just to open the TCP connection. With one provider and a 5s timeout, failed lookups on slow networks are nearly certain.  
`LyricsService.swift` (provider timeout configuration)

### Performance

- Candidate deduplication (`deduplicated()`) iterates all candidates in O(n²) on artist+title string matching. Fine for LRCLIB's typical 5-20 results, a concern if a secondary provider returns hundreds.
- Pin store loads and saves via `Task.detached` — correct approach, no issues.

### Missing Features

- No word-level karaoke highlighting (requires enhanced LRC parser).
- No CJK romanization or transliteration.
- No lyrics export (share sheet for plain text).
- No Musixmatch or Apple Music Lyrics integration.
- No "report lyrics error" flow back to LRCLIB.

---

## 4. OpenOpus Integration

**Files:** `OpenOpusService.swift` (425 lines), `OOComposerCache.swift`, `OOUserLinkOverrides.swift`, `ClassicalBrowserView.swift`, `ComposerDetailView.swift`, `OOWorkDetailView.swift`, `HIPEnsembleClassifier.swift`, `ClassicalMatchingModels.swift`, `LMSLibraryLinker.swift`, `RecordingComparatorSheet.swift`, `RandomWorksView.swift`

### Architecture Overview

OpenOpus (openopus.org) public API provides composer data (birth/death/epoch/portrait), work catalog, genre classification, and omnisearch. No authentication required. `URLCache` configured at 8MB memory / 64MB disk with `.returnCacheDataElseLoad` policy — sensible for mostly-static catalogue data.

`OOComposerCache` actor fetches all 26 alphabet-letter buckets in parallel on first use and caches to `Caches/oo_composer_cache.json` with a 7-day TTL. `HIPEnsembleClassifier` classifies album titles into ensemble types using phrase matching.

### Bugs

**[HIGH] 26-letter parallel fetch floods OpenOpus on cold cache**  
`OOComposerCache` fetches all 26 letter buckets simultaneously (`async let` inside a `withTaskGroup` or equivalent). That's 26 HTTP requests fired at once to a free public API. URLSession's per-host connection limit (typically 6) will serialize most of them, but the burst is unfriendly and risks triggering a rate limit or CDN block. A sequential or small-concurrency (4-at-a-time) approach with exponential backoff would be more polite.  
`OOComposerCache.swift`

**[MEDIUM] Silent background refresh failure**  
After the 7-day TTL expires, `OOComposerCache` triggers a background refresh. If the refresh fails (network error, API change), stale data persists with no notification to the user and no retry schedule. The cached TTL is not extended, so every subsequent app launch triggers another failing refresh attempt.  
`OOComposerCache.swift`

**[MEDIUM] epochByName() matching fails for non-ASCII composer names**  
`folded()` handles many Unicode transliterations but not all. Composers whose names differ between LMS tag romanizations and OpenOpus romanizations (e.g., "Takemitsu" vs "Tōru Takemitsu") will not match. The filter silently leaves them untagged rather than attempting a fuzzy match.  
`OOComposerCache.swift`

**[LOW] guessWorks() has no batch size limit**  
`OpenOpusService.guessWorks()` takes an arbitrary array of `OOGuessRequest` structs and POSTs them all in one request. No cap on batch size. A large queue (100+ tracks) could produce a very large POST body and a slow response.  
`OpenOpusService.swift:323`

**[LOW] downloadFullDump() exists but is never used for offline browsing**  
The method is implemented but no code path calls it to seed the local browser. The bulk dump (all composers/works in one JSON) would enable offline classical browsing without per-page API calls.  
`OpenOpusService.swift:345`

### Performance

- `composersByIDs()` POSTs an array and receives a batch response — efficient.
- `worksForComposer()` fetches all works for a composer (can be 200+) without pagination. On a slow connection, this stalls ComposerDetailView loading.
- OpenOpus has no explicit SLA or rate limit documentation, but a free community API running on donated infrastructure should be treated conservatively.

### Missing Features

- No offline mode for classical browser (composer cache helps, but work lists require network).
- No OO work recording count or historical performance popularity shown.
- No OO "featured" or "trending works" surface in the UI.
- No cross-reference between OO work IDs and MusicBrainz work IDs.

---

## 5. Artist & Composer Pages

**Files:** `LibraryView.swift` (2000+ lines), `ComposerDetailView.swift`, `LibraryViewModel.swift`, `MetadataService.swift`

### Architecture Overview

`ArtistDetailView` and `AlbumDetailView` are deeply nested inside `LibraryView.swift` as private structs. Both use `.task(id:)` for async data loading with retry tokens added in Phase 9. `ComposerDetailView` cross-references LMS tracks with OpenOpus work data via `LMSLibraryLinker`.

### Bugs

**[HIGH] ArtistDetailView loads all tracks via loadSongs() for "tracks by this artist"**  
`ArtistDetailView` previously used a computed property that scanned `libraryVM.songs` on every render. Phase 7 fixed the per-render recompute by populating a `@State` array on `onAppear`. However, `libraryVM.songs` itself is populated by `loadSongs()`, which pages through the entire LMS library. For a library with 50,000+ tracks, this fetch can take 30-60 seconds and holds all tracks in memory.  
`LibraryViewModel.swift:305-345`

**[MEDIUM] AlbumDetailView: getWorkGroupsForAlbum() fetches all tracks then groups client-side**  
`LibraryViewModel.getWorkGroupsForAlbum()` calls `getTracksForAlbum()` to fetch all tracks, then groups them into work groups entirely in memory. For box sets (200+ tracks), this produces a large intermediate array. A server-side work query via `loadWorks(composerID:)` filtered by album would be more efficient.  
`LibraryViewModel.swift:608-618`

**[MEDIUM] No skeleton/placeholder while artist header artwork loads**  
`ArtistDetailView` and `ComposerDetailView` use `AsyncImage` for the hero artwork. During network load, the background is empty — no shimmer, skeleton, or blurred placeholder. On slow connections, the hero area appears broken for 1-3 seconds.  
`LibraryView.swift:638+`

**[LOW] ComposerDetailView genre filter fetches new API call per genre change**  
Each genre chip tap triggers a `worksForComposer(composerID, genre: selected)` API call rather than filtering a pre-fetched "all works" list client-side. This causes a visible loading spinner on every genre switch and wastes API quota.  
`ComposerDetailView.swift`

### Performance

- `LibraryViewModel.search()` runs local search (`searchLocal`) and concurrent server search (`LyrionAPI.searchTracks`) in parallel. The local search is O(n) over potentially 50k songs. A prefix index or Fuse.js-style trie would help.
- `loadAlbums()` paginates correctly with a `pageSize` and a guard against re-entering. No issues.

### Missing Features

- No artist radio (start radio from artist page, not just from track).
- No discography timeline / chronological view.
- No genre breakdown pie chart for artists with diverse output.
- No "Similar Artists" carousel on artist page using Last.fm data (the data is fetched but not surfaced in `ArtistDetailView`).
- No concert/event date links (MusicBrainz events API not used).

---

## 6. MusicBrainz

**Files:** `MetadataService.swift` (lines 221-335)

### Architecture Overview

`MusicBrainzProvider` is a `@unchecked Sendable` singleton. A `RateLimiter` actor enforces 1.1s minimum between requests (correctly honoring the ToS). The provider searches by artist name, fetches MBID, then fetches tags and optionally release year/label. User-Agent is `"Hyperion/1.0 (iOS music player)"` — correct.

### Bugs

**[HIGH] Per-fetch can require 3 sequential rate-limited HTTP calls**  
`fetchInternal()` calls the private `fetch(url:)` method up to three times (artist search, artist detail, release query). Each `fetch()` invocation calls `await rateLimiter.wait()` independently. For a full fetch with an album query, the minimum wall time is `3 × 1.1s = 3.3 seconds` even on a perfect network. In practice this delays `AlbumDetailView` metadata by 4-6 seconds per album opened.  
`MetadataService.swift:262-327`

**[MEDIUM] JSON parsing uses manual dictionary casting**  
Both artist and release queries use `JSONSerialization` with unsafe `as? [[String: Any]]` casts. A single unexpected response structure (extra nesting, missing key) returns `nil` silently. No error is logged, no fallback is attempted. `Codable` structs would make parsing errors explicit and testable.  
`MetadataService.swift:262-310, 289-320`

**[MEDIUM] No retry on HTTP 503 (MusicBrainz overload)**  
MusicBrainz returns 503 when under load. The guard at line 329 throws `URLError(.badServerResponse)` on non-200 status. The caller catches and returns `nil`. There is no retry with backoff.  
`MetadataService.swift:329`

**[LOW] No recording-level lookup**  
Only artist and release queries are made. MusicBrainz recording-level data (ISRC, recording relationships, original release date, format) is never fetched. This data would significantly improve "Album Info" accuracy (first release year vs. reissue year, original label vs. reissue label).  
`MetadataService.swift:221+`

**[LOW] Artist name lookup is exact-match first result**  
`artists.first` is taken without verifying score or name disambiguation. "Mercury" as an artist name could match the wrong result from MB's search ranking.  
`MetadataService.swift:270`

### Performance

- Rate limiter serializes all MusicBrainz requests globally. On a library browse session where multiple albums are opened, requests queue behind each other with 1.1s gaps. Consider pre-fetching metadata for next/previous album in browse order.

### Missing Features

- No ISRC lookup for duplicate detection.
- No MusicBrainz release group artwork (CAA) as a fallback album art source.
- No MusicBrainz work → composer attribution for non-classical tracks.

---

## 7. Last.fm

**Files:** `LastFmAuthManager.swift` (234 lines), `MetadataService.swift` (LastFmProvider, lines 336-515), `SecretsProvider.swift`, `PlayerViewModel.swift` (scrobble logic, lines 181-220), `NowPlayingView.swift` (heart button), `PlayerViewModel+NowPlayingInfo.swift`

### Architecture Overview

Full session-based Last.fm auth (API key + shared secret → web browser auth → session key). Offline scrobble queue stores up to 50 entries in UserDefaults and flushes on reconnect. `love()` and `unlove()` methods exist in `LastFmAuthManager`. Scrobble threshold: `dur > 30 ? min(dur/2, 240) : .infinity` — correctly implements the Last.fm 50%/4-minute rule.

### Bugs

**[CRITICAL] Heart button does not call Last.fm love**  
The heart button in `NowPlayingView` calls `likedTracks.toggle(track)` (local `LikedTracksStore` only). `LastFmAuthManager.shared.love()` and `.unlove()` are implemented, tested, and working — but are never called from any UI element. From a user's perspective, liking a track in Hyperion has zero effect on their Last.fm profile. This is a high-visibility missing feature that users will notice and complain about.  
`NowPlayingView.swift:571-583`, `LastFmAuthManager.swift:146-153`

**[HIGH] Last.fm API key hardcoded as fallback in binary**  
`SecretsProvider.lastFmApiKey` falls back to `"1f3fd89f88c37df99a6dbc3a06b21642"` when the xcconfig key is absent. This means every build ships with a real Last.fm API key embedded in the binary. If Last.fm discovers this key is public (and they will — it's in the binary and now in this document), they can revoke it, disabling Last.fm for all users running a build that lacks xcconfig injection.  
`SecretsProvider.swift:8`

**[HIGH] MPFeedbackCommand (lock screen heart) not wired**  
`PlayerViewModel+NowPlayingInfo.swift` wires six remote commands (play, pause, togglePlayPause, nextTrack, previousTrack, changePlaybackPosition) but does not wire `commandCenter.likeCommand` or `commandCenter.bookmarkCommand`. Users cannot love a track from the lock screen, Control Centre, or CarPlay. This also means the lock screen heart icon never appears.  
`PlayerViewModel+NowPlayingInfo.swift`

**[MEDIUM] Offline scrobble queue stored in UserDefaults**  
Under iOS storage pressure, UserDefaults can be purged without user action. Scrobbles pending flush are lost silently. A SQLite file in `Application Support` (which is backed up and protected from purge) would be more reliable.  
`LastFmAuthManager.swift:31+`

**[MEDIUM] LikedTracksStore not synchronized with Last.fm loved tracks**  
On first login, or after a long offline period, `LikedTracksStore` and the user's Last.fm loved tracks list diverge with no reconciliation. Fetching `user.getLovedTracks` on auth and seeding `LikedTracksStore` would provide continuity.

**[LOW] Now Playing (track.updateNowPlaying) not sent before scrobble**  
Last.fm best practice is to call `track.updateNowPlaying` when a track starts and before scrobbling. Only `track.scrobble` is called. The Now Playing status on the user's Last.fm profile never updates.  
`PlayerViewModel.swift:195-220`

### Performance

- `LastFmProvider` bio fetch uses `artist.getinfo` with language parameter. No in-session cache. Multiple navigation visits to the same artist trigger repeated API calls. A simple `NSCache` keyed by artist name would eliminate this.

### Missing Features

- No `track.updateNowPlaying` call.
- No loved-tracks sync on login.
- No Last.fm recommendations or discovery feed.
- No Last.fm weekly chart in `StatsView`.

---

## 8. Discogs

**Files:** `DiscogsAuthManager.swift` (36 lines), `MetadataService.swift` (DiscogsProvider, lines 516-606)

### Architecture Overview

Discogs integration uses a Personal Access Token (PAT) flow, not OAuth 1.0a. `DiscogsAuthManager` stores the token in Keychain and exposes it to `DiscogsProvider`. The provider searches by artist + album title, takes the first result, and extracts image URL, release year, and label.

### Bugs

**[HIGH] Discogs rate limit not enforced**  
Discogs enforces 60 requests/minute for authenticated PAT users. `DiscogsProvider` has no rate limiter. During library metadata refresh (if ever triggered in bulk), it will hit the limit and receive HTTP 429 responses. The 429 guard throws `URLError(.badServerResponse)` and returns `nil` silently.  
`MetadataService.swift:516+`

**[MEDIUM] First search result used without artist name verification**  
`DiscogsProvider` takes `releases.first` without checking that `releases[0].artist` matches the requested artist. Discogs fuzzy search can return false positives, especially for common album titles. Checking Levenshtein distance or exact artist match would reduce wrong metadata.  
`MetadataService.swift:588+`

**[MEDIUM] DiscogsProvider is the last fallback, only reached when MB + LFM both return nothing**  
The non-classical metadata chain is: OpenOpus → Last.fm → MusicBrainz → Discogs (if MB returned empty). In practice, Discogs is almost never reached for well-tagged libraries. Its potential for cover art and detailed release information is underutilized.  
`MetadataService.swift:140-175`

**[LOW] Image URL from Discogs not cached aggressively**  
Artist images from Discogs have CDN URLs that can expire. The app fetches them on demand via `AsyncImage` without caching the URL or the image data to disk for offline access.

### Performance

- Discogs search returns up to 50 results. The provider uses only the first one without looking for a better match further down the list. A simple scan of the top 5 results checking artist name similarity would improve accuracy without significant overhead.

### Missing Features

- No Discogs marketplace / want list integration.
- No release format (vinyl, CD, etc.) displayed in Album Info.
- No Discogs master release linking for "definitive version" information.
- No Discogs community ratings displayed.

---

## 9. AudioMuse.ai

**Files:** `AudiomuseManager.swift` (263 lines), `MixViews.swift`, `MixGenerator.swift`

### Architecture Overview

AudioMuse is an LMS plugin (not an external cloud service). Hyperion communicates with it via the LMS web server's plugin endpoint. No external API key required — authentication is implicit via LMS connection. `isEnabled` flag stored in UserDefaults. `audiomuseAvailable` probed by hitting the plugin endpoint on startup.

### Bugs

**[HIGH] audiomuseAvailable not re-probed after reconnect**  
`checkAvailability()` is called once during app startup. If the LMS server reconnects after a dropout, or if the user switches servers (in multi-server mode), `audiomuseAvailable` retains its stale value. The AudioMuse section in Settings may show "Not Available" even after the plugin becomes reachable, or vice versa.  
`AudiomuseManager.swift:87-90`

**[MEDIUM] Mix results not paginated and have no TTL**  
`audiomuse_mixes.json` saves the entire mix list as a flat array with no expiration. Long-running installs will accumulate stale mixes indefinitely. A 30-item cap with LRU eviction (matching the LyricsService pattern) would keep the file bounded.  
`AudiomuseManager.swift:32+`

**[MEDIUM] isEnabled stored in UserDefaults, not Keychain**  
This is a preference, not a secret, so UserDefaults is technically correct. But because `audiomuseBaseURL()` constructs the URL from the LMS base URL (which may contain credentials), logging or exposing the URL elsewhere could leak the LMS address. Minor.  
`AudiomuseManager.swift:28-29`

**[LOW] No error differentiation between "plugin not installed" and "LMS unreachable"**  
`checkAvailability()` returns a simple `Bool`. The same `false` covers "plugin missing from LMS", "LMS is offline", and "wrong URL". The Settings test button shows the same message for all failure modes.  
`AudiomuseManager.swift:48-62`

### Performance

- Mix generation request is fire-and-forget with a `Task`. No loading indicator or timeout feedback to the user while the LMS plugin processes the request.
- `loadSavedMixes()` decodes the full JSON on main actor — fine for small files but should be moved to a background task if the file grows.

### Missing Features

- No mix history / session persistence.
- No mix quality rating or feedback loop.
- No visual mix graph (relationship between seed track and generated tracks).
- No AudioMuse-specific genre/mood filter controls in the mix generation UI.

---

## 10. Login & Onboarding

**Files:** `ServerSetupView.swift` (406 lines), `ConnectionManager.swift`, `HyperionApp.swift`, `SceneDelegate.swift`, `URLAuthSupport.swift`, `ListeningProfileOnboarding.swift`

### Architecture Overview

First-launch flow: `ServerSetupView` (server URL input + optional HTTP basic auth) → `ListeningProfileOnboarding` (listening profile selection). Connection is stored as a URL string in UserDefaults; HTTP basic auth credentials are embedded in the URL (`user:pass@host`). Auto-discovery probes a set of likely LMS addresses.

### Bugs

**[CRITICAL] No Bonjour/mDNS server discovery**  
"Discover Server" in `ServerSetupView` calls `ConnectionManager.probeFirstSuccessful(candidates:)`, which probes a hardcoded set of likely URL candidates. There is no `NetServiceBrowser`, `NWBrowser`, or `_lms._tcp` zero-configuration discovery. On networks with non-standard LMS addresses (non-192.168.x.x subnets, custom ports, WPA Enterprise), auto-discovery fails 100% of the time. LMS supports mDNS advertisement as `_lms._tcp`; using it would make first-time setup reliable.  
`ServerSetupView.swift:330-355`, `ConnectionManager.swift` (confirmed: no NetService or NWBrowser)

**[HIGH] NSAllowsArbitraryLoads: true in Info.plist**  
Required to support plain HTTP to LAN LMS servers, but it disables ATS globally — including for external API connections (Last.fm, MusicBrainz, Discogs, LRCLIB, OpenOpus). All those services support HTTPS and should not benefit from this exemption. A scoped `NSExceptionDomains` for local IP ranges with a tighter ATS policy for known HTTPS domains would be more secure. App Store reviewers flag `NSAllowsArbitraryLoads` without a clear justification, which can delay review.  
`Hyperion/Info.plist:25-37`

**[HIGH] HTTP basic auth credentials embedded in URL string**  
`URLAuthSupport.swift` extracts credentials from `user:pass@host:port` URLs and adds them as a `Basic` Authorization header. The URL with embedded credentials is stored in UserDefaults. Any log statement, crash report, or UserDefaults export that includes the URL leaks the server credentials in plaintext. Credentials should be stored in Keychain separately from the host URL.  
`URLAuthSupport.swift:1-26`, `ConnectionManager.swift:194+`

**[MEDIUM] No multi-server support**  
The app supports one LMS server at a time (local + tailscale + remote proxy variants of one server). Users with home and office LMS servers, or who want to switch between personal and shared libraries, must re-enter server details each time.

**[MEDIUM] No biometric app lock**  
No FaceID or TouchID gate on app launch. A music library can reveal personal listening habits. Settings to require biometric auth before app opens (or after a configurable idle period) would be a meaningful privacy feature.

**[LOW] Listening profile onboarding is non-skippable on first launch**  
`ListeningProfileOnboarding` blocks the main UI until a profile is selected or explicitly dismissed. A "Skip for now" path would reduce friction for users who just want to hear music immediately.

### Performance

- `ConnectionManager.performResolve()` tries multiple candidate URLs with `Task` concurrency and races them. Good approach. No issues.
- Connection probe timeout is 5s per candidate — acceptable.

### Missing Features

- No Bonjour discovery (critical gap).
- No multi-server support.
- No biometric lock.
- No LMS player selection (assumes the iOS device is the only LMS player; multi-room player switching not supported).
- No server health / version check after connect (Hyperion silently works with any LMS version; a minimum version warning would improve UX when running old LMS).

---

## 11. Final Section

### Top 10 Bugs by Severity

| # | Severity | Bug | File:Line |
|---|----------|-----|-----------|
| 1 | CRITICAL | Heart button does not call `LastFmAuthManager.love()` — love/unlove is dead code from the UI | `NowPlayingView.swift:571`, `LastFmAuthManager.swift:146` |
| 2 | CRITICAL | No Bonjour/mDNS discovery — "Discover Server" probes hardcoded IP ranges only | `ServerSetupView.swift:330`, `ConnectionManager.swift` |
| 3 | HIGH | Volume leveling labeled as "LUFS" but is a static gain offset, not per-track loudness measurement | `OrpheusDSPEngine.swift:290` |
| 4 | HIGH | Last.fm API key hardcoded in binary — revocation breaks scrobbling for all users | `SecretsProvider.swift:8` |
| 5 | HIGH | MPFeedbackCommand (lock screen heart) not wired — no love from lock screen or CarPlay | `PlayerViewModel+NowPlayingInfo.swift` |
| 6 | HIGH | HTTP basic auth credentials stored in UserDefaults inside the URL string | `URLAuthSupport.swift:16`, `ConnectionManager.swift:194` |
| 7 | HIGH | ArtistDetailView triggers full library load (50k+ tracks) to filter client-side | `LibraryViewModel.swift:305` |
| 8 | HIGH | MusicBrainz lookup can require 3 sequential rate-limited calls (≥3.3s per album) | `MetadataService.swift:262-327` |
| 9 | MEDIUM | Enhanced (word-level) LRC timestamps rendered as literal `<mm:ss.xx>` text | `LyricsService.swift:647` |
| 10 | MEDIUM | Discogs has no rate limiter — 60 req/min limit hit silently on bulk fetches | `MetadataService.swift:516` |

### Top Performance Improvements (Ranked by Impact)

**[HIGH IMPACT]**
1. **Replace ArtistDetailView full loadSongs() with a server-side artist tracks query** — LyrionAPI has `searchTracks` and `getTracksForAlbum`; an `artistTracks(artistID:)` endpoint or client-side filter on a cached album list would avoid loading 50k songs.
2. **Add in-session cache to LastFmProvider** — repeated visits to the same artist page re-fetch the same biography. An `NSCache` with a 1-hour TTL would eliminate this.
3. **Parallelize MusicBrainz artist+release calls** — artist search and release lookup are currently sequential. Artist MBID lookup can run in parallel with a speculative release search by title, cutting median fetch time roughly in half.

**[MEDIUM IMPACT]**
4. **Throttle EQ response preview recomputation** — limit to 30Hz during drag (debounce 33ms) to reduce CPU on older devices.
5. **OOComposerCache: sequential or limited-concurrency letter fetching** — replace simultaneous 26-request burst with 4 concurrent at most, respecting OpenOpus as a free community resource.
6. **ComposerDetailView: fetch all works once, filter client-side per genre** — eliminates per-chip-tap API round trips.

**[LOW IMPACT]**
7. **Adopt `containerRelativeFrame` for remaining GeometryReader usages** — 14 occurrences across 8 files (`LibraryView.swift:638,1217`, `ContentView.swift:165,231,461`, `OrpheusBalanceView.swift:78`, `NowPlayingView.swift:455,713`, `ServerSetupView.swift:41,82`, `StatsView.swift:372`, `LyricsView.swift:71`, `ListeningProfileOnboarding.swift:47`, `OrpheusEQDetailView.swift:195`).

### Missing Features vs. Roon / Apple Music / Spotify

| Feature | Roon | Apple Music | Spotify | Hyperion |
|---------|------|-------------|---------|---------|
| Lock screen love/heart | ✓ | ✓ | ✓ | ✗ Missing |
| Now Playing on Last.fm | ✓ | ✗ | ✓ | ✗ Missing |
| Loved tracks sync | ✓ | ✓ (library) | ✓ | ✗ Missing |
| LUFS measurement | ✓ | ✓ | ✓ | ✗ (static gain only) |
| Bonjour discovery | ✓ | N/A | N/A | ✗ Missing |
| Word-level lyrics | ✓ | ✓ | ✓ | ✗ LRC plain only |
| Multi-server | ✓ | N/A | N/A | ✗ Missing |
| Per-band Q EQ | ✓ | ✗ | ✗ | ✗ Missing UI |
| ReplayGain | ✓ | ✗ | ✗ | ✗ Missing |
| Biometric lock | ✓ | ✗ | ✗ | ✗ Missing |
| Offline lyrics | ✓ | ✓ | ✓ | ✓ (cached 30d) |
| Crossfade | ✓ | ✓ | ✓ | ✓ (3 shapes) |
| Gapless | ✓ | ✓ | ✓ | ✓ |
| Classical work/movement grouping | ✓ | ✗ | ✗ | ✓ |
| Ensemble classification | ✓ | ✗ | ✗ | ✓ |
| DR badge | ✗ | ✗ | ✗ | ✓ |
| OpenOpus integration | ✗ | ✗ | ✗ | ✓ |

### Suggested External APIs Not Yet Used

| API | Use Case | Difficulty |
|-----|----------|------------|
| MusicBrainz Cover Art Archive (CAA) | Fallback album artwork, release group images | Low — CAA URL is `coverartarchive.org/release/{mbid}/front` |
| MusicBrainz Events API | Concert/venue dates on artist pages | Medium — requires event relationship lookup |
| AcoustID / Chromaprint | Audio fingerprint for untagged/mislabeled tracks | High — requires on-device fingerprinting |
| Fanart.tv | High-res artist backgrounds, logos, banners | Low — REST API, free tier available |
| Apple Music API (MusicKit) | Word-level lyrics (authorized apps only), rich metadata | High — requires Apple developer agreement |
| ListenBrainz | Open scrobbling alternative to Last.fm | Low — submit-listen endpoint mirrors Last.fm's structure |

### Five-Dimension Rating

| Dimension | Score | Notes |
|-----------|-------|-------|
| **Audio Engine** | 8 / 10 | Orpheus DSP pipeline is genuinely impressive for a mobile client. Gapless is solid. Crossfade shapes, crossfeed, per-band EQ all work. Deductions: volume leveling is mislabeled; no true bitperfect or LUFS measurement. |
| **UI / UX** | 7 / 10 | Roon-inspired design language is cohesive and premium. Classical features (work grouping, conductor, DR badge, era filter) are deep. Deductions: no Bonjour discovery ruins first-time UX; heart button has no Last.fm effect; lock screen love absent. |
| **Metadata & Enrichment** | 6 / 10 | Good breadth: MB + Last.fm + OO + Discogs + AudioMuse. Serious deductions: love/scrobble disconnect, MB sequential slowness, LikedTracks siloed from Last.fm, no LUFS measurement, no ReplayGain. |
| **Classical Features** | 9 / 10 | Best-in-class for a self-hosted player. Work/movement grouping, conductor, HIP ensemble badge, DR badge, OpenOpus cross-reference, era filter, recording comparator, annotation store. Deduction: epoch filter misses non-ASCII romanizations. |
| **Reliability & Security** | 4 / 10 | Last.fm key hardcoded in binary; credentials in UserDefaults URL; NSAllowsArbitraryLoads=true for all domains; no Bonjour; MPFeedbackCommand missing; scrobble queue in UserDefaults; onNearEnd no-retry; no cert pinning for external APIs. |

**Overall: 6.8 / 10** — A technically sophisticated app with excellent classical music depth, let down by identifiable gaps in Last.fm integration, server discovery, and security hygiene that are all fixable.

---

*Report generated from full read of all 89 Swift source files. Line numbers reference the codebase as of 2026-05-10.*
