# CI failure patch notes

This update addresses the Xcode 26.2 archive failure shown in the GitHub Actions log.

## Fixed

- Replaced the unavailable `AVURLAssetHTTPHeaderFieldsKey` Swift symbol with the raw AVFoundation option key string so the code compiles with the Xcode 26.2 SDK overlay.
- Added explicit `AVPlayerItem` root types and `NSKeyValueObservedChange` closure annotations to the KVO observers for `status` and `duration`, fixing Swift's key-path inference failures during whole-module Release compilation.
- Removed two unused local variables reported by the archive build:
  - `HyperionApp.configureAppearance()` no longer creates an unused `base` color.
  - `PlayerViewModel.removeFromQueue(at:)` no longer creates an unused `removedTrack`.
- Added a CI cleanup step that deletes stale `Assets.xcassets/AppIcon.appiconset` PNGs not referenced by `Contents.json`. This prevents Xcode's "AppIcon has unassigned children" warning when older icon files survive a local copy/merge.

## Validation performed here

- Parsed both workflow YAML files and `project.yml`.
- Parsed `Assets.xcassets/AppIcon.appiconset/Contents.json` and confirmed every referenced PNG exists and no extra PNGs are present in the packaged project.
- Performed static checks against the edited Swift files for the exact failing constructs from the CI log.

A full `xcodebuild archive` still needs to run on macOS/Xcode because this environment is Linux and does not include Apple's SDKs.
