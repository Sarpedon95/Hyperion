# Hyperion patched build

Open this folder, run `xcodegen generate` if you use XcodeGen, then open `Hyperion.xcodeproj`.

Before uploading to TestFlight:
1. Select your Apple Developer team under Signing & Capabilities.
2. Confirm the bundle identifier is available in App Store Connect.
3. Archive with the Release configuration and distribute to App Store Connect.

Changes applied include safer networking, better HTTP errors, duplicate queue-clear fix, release-build settings, a valid project layout, and generated placeholder app icons.
