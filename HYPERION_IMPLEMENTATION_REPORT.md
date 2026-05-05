# Hyperion Spotify/Roon-style client pass

## Implemented

- Added a shared bottom overlay layout environment and `bottomOverlayAwareScroll()` modifier so scrollable screens reserve space for the custom mini-player/tab-bar/safe-area chrome instead of relying on isolated padding hacks.
- Applied the shared bottom-inset modifier across Home, Library, albums, album detail, artists, artist detail, genre lists, search/settings, queue, lyrics picker results, classical browser, composer/work detail, Orpheus screens, signal path, diagnostics, and other list/grid/scroll screens.
- Added persistent local liked tracks with `LikedTracksStore`, a Library > Liked Tracks screen, persistent Now Playing heart state, and like/unlike actions from track/movement rows and Now Playing.
- Added local playlist persistence with `PlaylistStore`, Library > Playlists, playlist create/rename/delete, play/shuffle, reorder/remove, save queue as playlist, and Add to Playlist actions from songs, movements, work groups, queue rows, and Now Playing.
- Improved classical work grouping to prefer LMS WORK tags, then safe local inference from catalogue/movement-style titles, with a flat fallback for non-classical releases/playlists.
- Album detail now renders non-classical albums as normal track lists and classical albums/playlists with work headers, movement rows, collapse/expand, work playback, queue, and playlist actions.
- Playlist detail reuses the work grouping model so classical playlist tracks are grouped under work headers while non-classical playlists stay flat.
- Reworked the Now Playing quality badge and signal path to use known LMS/player/Orpheus state conservatively rather than decorative claims.
- Signal path now reports source codec, LMS sample/depth when known, stream path, sample-rate mismatch, Orpheus DSP state, active preset, digital volume attenuation, output device, and bit-perfect verification/unknown state.
- Added EQ clipping/headroom guidance to Orpheus EQ screens with boost/headroom values and plain-language explanation.
- Added richer Artist detail pages with album discography, locally derived top tracks, liked songs by artist, and play/shuffle controls.
- Added a Genre browser and genre album detail pages backed by LMS genre metadata.
- Improved Queue with save-as-playlist and add-to-playlist actions.

## Skipped / deferred

- Sleep timer, local radio/autoplay, listening stats/history expansion, Roon-style library filters, smart playlists, Daily Mix/local mixes, DSP preset auto-switch, crossfade, and widgets/Live Activities were deferred.
- OpenOpus work-link confirmation UI and user-correction flows were not added in this pass.
- LMS-native playlist/star APIs were not wired; playlists and likes persist locally.
- No new XCTest suite was added yet; this pass focused on the app foundations and UI flow.

## Files changed

- New: `Hyperion/BottomOverlayLayout.swift`
- New: `Hyperion/LikedTracksStore.swift`
- New: `Hyperion/PlaylistStore.swift`
- New: `Hyperion/PlaylistViews.swift`
- Modified: `Hyperion/ContentView.swift`
- Modified: `Hyperion/LibraryView.swift`
- Modified: `Hyperion/LyrionAPI.swift`
- Modified: `Hyperion/Models.swift`
- Modified: `Hyperion/NowPlayingView.swift`
- Modified: `Hyperion/PlayerViewModel.swift`
- Modified: `Hyperion/QueueView.swift`
- Modified: `Hyperion/AudioSignalPathView.swift`
- Modified: `Hyperion/OrpheusEQDetailView.swift`
- Modified: scroll/list screens across Home, Search/Settings, Classical, Composer/Work detail, Lyrics, Orpheus detail screens, and diagnostics.

## Verification performed

- Ran `swiftc -parse` across every Swift file to catch syntax-level errors.
- Ran `git diff --check` to catch whitespace/conflict-marker issues.

## Build status

- Full iOS build was not run in this Linux container because SwiftUI/UIKit/iOS SDK and `xcodebuild` are unavailable here.
- The project uses XcodeGen-style `project.yml`; new Swift files live under the existing `Hyperion` source path, so they should be picked up by project generation.

## Known risks / TODOs

- Device testing is still needed for all bottom overlay cases because safe-area, keyboard, custom tab bar, and mini-player behavior must be verified on real iPhone sizes/orientations.
- The signal path is intentionally conservative; LMS installations that expose richer transcoding/output metadata can improve the sheet further.
- Work inference is safe but basic; more advanced OpenOpus/local-link confidence scoring and manual correction should be added next.
- Local playlist/liked persistence stores full track snapshots in `UserDefaults`; this is fine for a first pass but could move to SQLite/files if libraries/playlists become very large.
- Some screens with empty states are not scrollable by design; the bottom-inset fix targets scroll/list/grid content.

## Manual device testing checklist

- Home, Library, Songs, Liked Tracks, Playlists, Albums, Album detail, Artists, Artist detail, Genres, Genre detail.
- Search, Settings, Queue, Lyrics selection/results, Classical Browser, Composer detail, OpenOpus work detail, diagnostics.
- Orpheus overview and all EQ/DSP detail screens.
- Mini-player visible/hidden, tab switching, Now Playing full-screen sheet, keyboard in search fields, portrait/landscape, small and large iPhones.
- Classical albums with LMS WORK tags, inferred classical albums, mixed playlists, and normal pop/rock/jazz playlists.
- Now Playing quality badge with known FLAC/MP3 sources, DSP on/off, digital volume attenuation, and unknown LMS quality metadata.
