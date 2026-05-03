# Hyperion review notes

## What I changed

- Restored required `Combine` imports in `ConnectionManager`, `LibraryViewModel`, and `PlayerViewModel` so `ObservableObject` and `@Published` resolve cleanly.
- Added a full `Assets.xcassets/AppIcon.appiconset`; the XcodeGen spec referenced `Assets.xcassets`, but it was not included in the supplied archive.
- Updated `Info.plist` to use build-setting substitutions for version/build, added `CFBundleDisplayName`, kept the iPhone app portrait-only, and added the required iPad orientation key.
- Wired the App Store archive fixer into the GitHub Actions workflow after archive and before export, then added an exported IPA verification step before TestFlight upload.
- Quoted the workflow `on` key so non-GitHub YAML tools do not parse it as a boolean.
- Added the workflow at `.github/workflows/deploy-testflight.yml` while keeping the root `build.yml` copy.
- Fixed `NWPathMonitor` lifecycle so monitoring can be stopped and restarted safely.
- Prevented stale album art/background art from remaining visible while a new image loads.
- Improved shuffled-queue bookkeeping so repeated tracks are preserved correctly when deleting, moving, or de-shuffling.
- Switched the AVURLAsset HTTP-header option to the typed `AVURLAssetHTTPHeaderFieldsKey` constant.
- Added a defensive work-detail fallback for work search results that do not include a real `work_id`.
- Tightened bundle-fixer scripts and IPA verification to match the source plist orientation policy.

## Validation performed

- Parsed every Swift file with `swiftc -parse` for syntax errors.
- Validated `Info.plist` with `plutil -lint`.
- Validated `build.yml`, `project.yml`, and `.github/workflows/deploy-testflight.yml` as YAML.
- Validated asset catalog JSON files.
- Ran `bash -n` on all shell scripts.
- Checked that all source paths referenced by `project.yml` exist.

## What I could not run here

- I could not run a full iOS/Xcode archive in this Linux container because it does not include Xcode, iOS SDKs, SwiftUI, AVFoundation, or code-signing access.
