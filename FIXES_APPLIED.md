# Fixes Applied

## Playback

- Replaced the primary LMS playback URL from `/music/<id>/download?player=0` to an ordered set of AVPlayer-safe candidates.
- Added extension-hinted stream URLs such as `/music/<id>/download.flac` when LMS exposes the source extension in the track `url` tag.
- Added automatic playback fallback through:
  1. extension-hinted download URL,
  2. canonical `/music/<id>/download`,
  3. legacy `/music/<id>/download?player=0`,
  4. last-resort `/music/<id>/download.mp3` transcode hint.
- Added retry handling when `AVPlayerItem.status == .failed` so one bad stream format no longer leaves the app silently stopped.
- Added playback generation IDs so stale AVPlayer callbacks from previous tracks cannot mutate the current player state.
- Expanded audio `Accept` headers to prefer common audio MIME types.

## Build/API compatibility

- Replaced `.allowBluetoothHFP` with `.allowBluetoothA2DP` in the audio session. `.allowBluetoothHFP` is not appropriate for this iOS 17 / Swift 5.9 playback target and can break builds depending on SDK/toolchain.

## Security/repo hygiene

- Removed Apple signing/private materials from the returned project archive:
  - `distribution.key`
  - `distribution.p12`
  - `distribution.pem`
  - `distribution.cer`
  - `distribution.csr`
  - `AuthKey_BR3MM2GB7H.p8`
  - `Hyperion/Hyperion_AppStore.mobileprovision`
- Removed the `.git` directory from the returned archive.

Important: those signing files were present in the ZIP you uploaded. Treat them as exposed. Revoke/rotate the App Store Connect API key and certificate/private key before using this project in CI or sharing it.

## Second-pass review fixes

- Hardened URL sanitizing in both `LyrionAPI` and `ConnectionManager` so malformed scheme-only values such as `http://` or `https://` do not become invalid relative URLs.
- Guarded JSON-RPC, artwork, and stream URL creation against an empty base URL.
- Prevented cancelled/stale connection resolution tasks from overwriting a newer connection choice after the user changes settings or taps reconnect.
- Snapshot connection settings during auto-resolution so an in-flight race uses one consistent set of candidate URLs.
- Changed the lightweight LMS probe request to use the same string player id style as the app's JSON-RPC calls.
- Improved repeat-one playback by waiting for the seek-to-zero operation to complete before resuming playback.
- Invalidated pending lock-screen artwork loads when the queue is cleared, preventing stale artwork from reappearing after clearing playback.
- Removed a debug `print` from audio-session setup and retained the failure description internally for diagnostics.

## Full-screen / letterbox fix

- Changed the app from iPhone-only (`TARGETED_DEVICE_FAMILY = 1`) to universal (`1,2`). This prevents iPad from running the app in iPhone compatibility mode, which causes the app to appear as a smaller rounded rectangle with black borders.
- Updated `UIDeviceFamily` to include both iPhone and iPad.
- Replaced the storyboard launch-screen dependency in `Info.plist` with the modern iOS 14+ `UILaunchScreen` dictionary and a `LaunchBackground` color asset. This prevents iPhone letterboxing caused by a missing or mis-detected launch screen.
- Made the root SwiftUI container explicitly ignore container safe areas so the app paints the entire window.
- Added explicit `INFOPLIST_FILE` / `GENERATE_INFOPLIST_FILE = NO` settings to make XcodeGen keep using the checked-in plist.

## Third pass: fullscreen launch hardening
- Switched from the newer `UILaunchScreen` dictionary to the classic explicit `UILaunchStoryboardName = LaunchScreen` key. The included `LaunchScreen.storyboard` is now definitely referenced by the built app.
- Kept `UIDeviceFamily = [1, 2]`, `TARGETED_DEVICE_FAMILY = "1,2"`, and `UIRequiresFullScreen = true`.
- Added a GitHub Actions validation block that prints/fails on launch-screen and device-family settings after XcodeGen runs.
