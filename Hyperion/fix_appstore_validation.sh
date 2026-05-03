#!/usr/bin/env bash
set -euo pipefail

# Hyperion App Store validation fixer
# Fixes these upload errors without opening Xcode:
# 1) Missing UISupportedInterfaceOrientations / UISupportedInterfaceOrientations~ipad
# 2) Missing UILaunchStoryboardName / launch screen bundle resource
#
# Preferred usage: patch the .xcarchive BEFORE export/signing:
#   ./fix_appstore_validation.sh /path/to/Hyperion.xcarchive
# Then export/upload the archive again.
#
# Also supports .app bundles directly. IPA patching is possible, but modifying a
# signed IPA invalidates its signature; re-export/re-sign after patching.

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/Hyperion.xcarchive|Hyperion.app|Hyperion.ipa" >&2
  exit 2
fi

INPUT="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_STORYBOARD_SRC="$SCRIPT_DIR/LaunchScreen.storyboard"
PLISTBUDDY="/usr/libexec/PlistBuddy"

patch_plist() {
  local plist="$1"

  if [[ ! -f "$plist" ]]; then
    echo "ERROR: Info.plist not found: $plist" >&2
    exit 1
  fi

  echo "Patching $plist"

  # Keep the phone app portrait-only, while declaring the full iPad set that
  # App Store validation expects when an iPhone app can run in compatibility mode.
  "$PLISTBUDDY" -c "Delete :UISupportedInterfaceOrientations" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations array" "$plist"
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations:0 string UIInterfaceOrientationPortrait" "$plist"

  "$PLISTBUDDY" -c "Delete :UISupportedInterfaceOrientations~ipad" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations~ipad array" "$plist"
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations~ipad:0 string UIInterfaceOrientationPortrait" "$plist"
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations~ipad:1 string UIInterfaceOrientationPortraitUpsideDown" "$plist"
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations~ipad:2 string UIInterfaceOrientationLandscapeLeft" "$plist"
  "$PLISTBUDDY" -c "Add :UISupportedInterfaceOrientations~ipad:3 string UIInterfaceOrientationLandscapeRight" "$plist"

  # Keep the source/build settings and final archive aligned: Hyperion is a
  # universal app so iPad gets the native full-screen layout instead of iPhone
  # compatibility letterboxing.
  "$PLISTBUDDY" -c "Delete :UIDeviceFamily" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :UIDeviceFamily array" "$plist"
  "$PLISTBUDDY" -c "Add :UIDeviceFamily:0 integer 1" "$plist"
  "$PLISTBUDDY" -c "Add :UIDeviceFamily:1 integer 2" "$plist"

  # Make iPad full-screen explicit. This prevents iPad multitasking validation
  # from being inferred when you do not intend to support multitasking.
  "$PLISTBUDDY" -c "Delete :UIRequiresFullScreen" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :UIRequiresFullScreen bool true" "$plist"


  # Preserve remote-connectivity ATS settings in the final archived app bundle.
  "$PLISTBUDDY" -c "Delete :NSAppTransportSecurity" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity dict" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSExceptionDomains:31.223.16.10 dict" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSExceptionDomains:31.223.16.10:NSExceptionAllowsInsecureHTTPLoads bool true" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSExceptionDomains:31.223.16.10:NSExceptionMinimumTLSVersion string TLSv1.0" "$plist"
  "$PLISTBUDDY" -c "Add :NSAppTransportSecurity:NSExceptionDomains:31.223.16.10:NSIncludesSubdomains bool false" "$plist"

  # Make storyboard launch screen explicit.
  "$PLISTBUDDY" -c "Delete :UILaunchStoryboardName" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :UILaunchStoryboardName string LaunchScreen" "$plist"

  plutil -convert binary1 "$plist"
  plutil -lint "$plist"
}

compile_launch_storyboard_if_needed() {
  local app_dir="$1"
  local storyboardc="$app_dir/LaunchScreen.storyboardc"

  if [[ -d "$storyboardc" ]]; then
    echo "LaunchScreen.storyboardc already exists."
    return 0
  fi

  if [[ ! -f "$LAUNCH_STORYBOARD_SRC" ]]; then
    echo "WARNING: LaunchScreen.storyboard not found beside this script; cannot add launch screen resource." >&2
    return 0
  fi

  if command -v ibtool >/dev/null 2>&1; then
    echo "Compiling LaunchScreen.storyboard into $storyboardc"
    ibtool --errors --warnings --notices --target-device iphone --target-device ipad \
      --minimum-deployment-target 14.0 --compile "$storyboardc" "$LAUNCH_STORYBOARD_SRC"
  else
    echo "WARNING: ibtool not found. Install/use Xcode command line tools, or patch before the normal Xcode archive/export step." >&2
  fi
}

find_app_in_archive() {
  local archive="$1"
  find "$archive/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -n 1
}

patch_app() {
  local app_dir="$1"
  if [[ ! -d "$app_dir" ]]; then
    echo "ERROR: .app not found: $app_dir" >&2
    exit 1
  fi
  patch_plist "$app_dir/Info.plist"
  compile_launch_storyboard_if_needed "$app_dir"
  echo "Final validation keys:"
  plutil -p "$app_dir/Info.plist" | grep -E "UISupportedInterfaceOrientations|UILaunchStoryboardName|UIRequiresFullScreen|UIDeviceFamily" || true
  ls -d "$app_dir"/LaunchScreen.storyboardc >/dev/null 2>&1 && echo "Launch screen resource: OK"
}

case "$INPUT" in
  *.xcarchive)
    APP_DIR="$(find_app_in_archive "$INPUT")"
    patch_app "$APP_DIR"
    echo "Done. Re-export this archive, then upload the newly exported IPA."
    ;;
  *.app)
    patch_app "$INPUT"
    echo "Done. Re-sign/package this app before upload."
    ;;
  *.ipa)
    WORKDIR="$(mktemp -d)"
    OUT="${INPUT%.ipa}-fixed-unsigned.ipa"
    unzip -q "$INPUT" -d "$WORKDIR"
    APP_DIR="$(find "$WORKDIR/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    patch_app "$APP_DIR"
    (cd "$WORKDIR" && zip -qry "$OUT" Payload)
    if [[ "$OUT" != /* ]]; then
      mv "$WORKDIR/$OUT" "$OUT"
    fi
    rm -rf "$WORKDIR"
    echo "Created $OUT"
    echo "IMPORTANT: This IPA was modified after signing. Re-sign/re-export before App Store upload."
    ;;
  *)
    echo "ERROR: Input must be .xcarchive, .app, or .ipa" >&2
    exit 2
    ;;
esac
