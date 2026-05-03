# Hyperion Pass 4 Review Notes

Date: 2026-05-02

## Scope

Reviewed the uploaded Hyperion SwiftUI/iOS project with the goals of preserving every existing feature while improving correctness, responsiveness, app-store bundle consistency, and runtime efficiency.

## Changes Made

### Performance

- Reworked album browsing so `loadAlbums` fetches one LMS page per call instead of downloading the entire library before the first visible result. The existing scroll-near-end trigger now performs true incremental pagination.
- Added in-flight request coalescing for Recently Added and Recently Played so Home/Library callers share the same server request instead of racing duplicates.
- Started Home totals, Recently Added, and Recently Played loads concurrently.
- Started refresh loads for composers, Recently Added, and Recently Played concurrently.
- Added artwork request coalescing so simultaneous requests for the same image URL share a single download/decode task.
- Added batched album queue appends so adding a whole album recomputes queue grouping once instead of once per work group.
- Expanded memory-warning cleanup to cancel recent-section and artwork in-flight tasks in addition to clearing caches.

### Bug Fixes

- Aligned iPad/App Store bundle settings across source `Info.plist`, root XcodeGen spec, nested XcodeGen spec, archive patch script, bundle patch script, and IPA verifier.
- Restored universal device family metadata (`UIDeviceFamily = [1, 2]`) and retained explicit iPad full-screen behavior.
- Redacted the offline connection banner URL so embedded Basic Auth credentials cannot be displayed on Home.
- Fixed Settings → Test Connection loading state so the spinner is cleared with `defer`, including early returns and cancellation.
- Deduplicated expanded Auto-mode test candidates before probing server URLs.
- Explicitly main-actor isolated UIKit and CarPlay scene delegates.

### Polish

- Added bottom pagination feedback while album pages are loading.
- Kept album detail Play/Add disabled until tracks/work groups are actually loaded.
- Showed the `CLASSICAL` badge only when album/work metadata indicates classical content.
- Cleaned up indentation in the Library root menu for maintainability.
- Documented this pass in `Hyperion/CHANGELOG.md`.

## Validation Performed

- `swiftc -parse` on every Swift file in `Hyperion/*.swift`.
- `plutil -lint Hyperion/Info.plist`.
- `bash -n Hyperion/*.sh`.
- JSON parsing for all project JSON files.
- YAML parsing for `project.yml`, `Hyperion/project.yml`, and `.github/workflows/build.yml`.
- Explicit `Info.plist` assertions for universal device family, iPad full-screen mode, launch storyboard, and orientation metadata.

## Validation Limitation

A full Xcode build/archive was not possible in this Linux container because it does not include Xcode, Apple platform SDKs, or signing access. The performed checks are syntax/configuration checks rather than a complete iOS compile and code-sign pass.

## Packaging Note

The returned clean project zip intentionally excludes `.git`, private keys, certificates, provisioning profiles, archives, IPAs, and nested zips. The uploaded archive contained signing material; rotate any credentials/certificates/profiles that may have been exposed outside your trusted environment.
