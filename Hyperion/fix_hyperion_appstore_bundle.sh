#!/usr/bin/env bash
set -euo pipefail

# Hyperion App Store bundle fixer, v2
# Fixes App Store validation failures for missing:
# - UISupportedInterfaceOrientations
# - UISupportedInterfaceOrientations~ipad
# - UILaunchStoryboardName / LaunchScreen.storyboardc
#
# Best place to run this:
#   AFTER xcodebuild archive
#   BEFORE xcodebuild -exportArchive / altool upload
#
# Usage:
#   ./fix_hyperion_appstore_bundle.sh /path/to/Hyperion.xcarchive
#   ./fix_hyperion_appstore_bundle.sh /path/to/Hyperion.app
#   ./fix_hyperion_appstore_bundle.sh /path/to/Hyperion.ipa --resign --identity "Apple Distribution: ..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLISTBUDDY="/usr/libexec/PlistBuddy"
LAUNCH_SRC="$SCRIPT_DIR/LaunchScreen.storyboard"

INPUT="${1:-}"
shift || true
RESIGN=0
IDENTITY=""
PROFILE=""
OUT_IPA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resign) RESIGN=1; shift ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --out) OUT_IPA="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Usage: $0 /path/to/Hyperion.xcarchive|Hyperion.app|Hyperion.ipa [--resign --identity 'Apple Distribution: ...' --profile profile.mobileprovision --out fixed.ipa]" >&2
  exit 2
fi

if [[ ! -x "$PLISTBUDDY" ]]; then
  echo "ERROR: PlistBuddy not found at $PLISTBUDDY" >&2
  exit 1
fi

add_or_replace_string() {
  local plist="$1" key="$2" value="$3"
  "$PLISTBUDDY" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :$key string $value" "$plist"
}

add_or_replace_bool() {
  local plist="$1" key="$2" value="$3"
  "$PLISTBUDDY" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :$key bool $value" "$plist"
}

add_or_replace_int_array() {
  local plist="$1" key="$2"; shift 2
  "$PLISTBUDDY" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :$key array" "$plist"
  local index=0
  local value
  for value in "$@"; do
    "$PLISTBUDDY" -c "Add :$key:$index integer $value" "$plist"
    index=$((index + 1))
  done
}

add_or_replace_orientations() {
  local plist="$1" key="$2"; shift 2
  "$PLISTBUDDY" -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
  "$PLISTBUDDY" -c "Add :$key array" "$plist"
  local index=0
  local orientation
  for orientation in "$@"; do
    "$PLISTBUDDY" -c "Add :$key:$index string $orientation" "$plist"
    index=$((index + 1))
  done
}

patch_plist() {
  local plist="$1"
  [[ -f "$plist" ]] || { echo "ERROR: Info.plist not found: $plist" >&2; exit 1; }

  echo "Patching plist: $plist"
  add_or_replace_orientations "$plist" "UISupportedInterfaceOrientations" \
    UIInterfaceOrientationPortrait
  add_or_replace_orientations "$plist" "UISupportedInterfaceOrientations~ipad" \
    UIInterfaceOrientationPortrait \
    UIInterfaceOrientationPortraitUpsideDown \
    UIInterfaceOrientationLandscapeLeft \
    UIInterfaceOrientationLandscapeRight
  add_or_replace_int_array "$plist" "UIDeviceFamily" 1 2
  add_or_replace_bool "$plist" "UIRequiresFullScreen" "true"
  add_or_replace_string "$plist" "UILaunchStoryboardName" "LaunchScreen"

  # Keep binary/xml format valid. Do not force XML because Xcode often emits binary plists.
  plutil -lint "$plist" >/dev/null
}

compile_launch_storyboard() {
  local app_dir="$1"
  local storyboardc="$app_dir/LaunchScreen.storyboardc"

  if [[ -d "$storyboardc" ]]; then
    echo "Launch screen already present: $storyboardc"
    return 0
  fi

  [[ -f "$LAUNCH_SRC" ]] || { echo "ERROR: Missing $LAUNCH_SRC" >&2; exit 1; }

  if ! command -v ibtool >/dev/null 2>&1; then
    echo "ERROR: ibtool not found. This script must run on a macOS/Xcode runner to compile LaunchScreen.storyboard." >&2
    exit 1
  fi

  echo "Compiling launch screen into app bundle: $storyboardc"
  ibtool --errors --warnings --notices \
    --target-device iphone --target-device ipad \
    --minimum-deployment-target 14.0 \
    --compile "$storyboardc" "$LAUNCH_SRC" >/dev/null

  [[ -d "$storyboardc" ]] || { echo "ERROR: ibtool did not produce $storyboardc" >&2; exit 1; }
}

find_app_in_archive() {
  local archive="$1"
  find "$archive/Products/Applications" -maxdepth 1 -type d -name "*.app" | head -n 1
}

verify_app() {
  local app_dir="$1"
  local plist="$app_dir/Info.plist"
  echo "Verifying final app bundle: $app_dir"

  /usr/bin/python3 - "$plist" <<'PY'
import plistlib, sys
plist_path = sys.argv[1]
with open(plist_path, 'rb') as f:
    p = plistlib.load(f)
required_phone = ['UIInterfaceOrientationPortrait']
required_ipad = [
    'UIInterfaceOrientationPortrait',
    'UIInterfaceOrientationPortraitUpsideDown',
    'UIInterfaceOrientationLandscapeLeft',
    'UIInterfaceOrientationLandscapeRight',
]
errors = []
checks = {
    'UISupportedInterfaceOrientations': required_phone,
    'UISupportedInterfaceOrientations~ipad': required_ipad,
}
for key, expected in checks.items():
    value = p.get(key)
    if value != expected:
        errors.append(f'{key} is {value!r}, expected {expected!r}')
if p.get('UILaunchStoryboardName') != 'LaunchScreen':
    errors.append(f"UILaunchStoryboardName is {p.get('UILaunchStoryboardName')!r}, expected 'LaunchScreen'")
if p.get('UIRequiresFullScreen') is not True:
    errors.append(f"UIRequiresFullScreen is {p.get('UIRequiresFullScreen')!r}, expected True")
if p.get('UIDeviceFamily') != [1, 2]:
    errors.append(f"UIDeviceFamily is {p.get('UIDeviceFamily')!r}, expected [1, 2]")
if errors:
    print('FAILED Info.plist validation:')
    for e in errors:
        print(' - ' + e)
    sys.exit(1)
print('Info.plist validation: OK')
PY

  if [[ ! -d "$app_dir/LaunchScreen.storyboardc" ]]; then
    echo "FAILED: $app_dir/LaunchScreen.storyboardc is missing" >&2
    exit 1
  fi
  echo "LaunchScreen.storyboardc: OK"
}

patch_app() {
  local app_dir="$1"
  [[ -d "$app_dir" ]] || { echo "ERROR: app bundle not found: $app_dir" >&2; exit 1; }
  patch_plist "$app_dir/Info.plist"
  compile_launch_storyboard "$app_dir"
  verify_app "$app_dir"
}

resign_app() {
  local app_dir="$1"
  [[ -n "$IDENTITY" ]] || { echo "ERROR: --identity is required with --resign" >&2; exit 1; }

  if [[ -n "$PROFILE" ]]; then
    [[ -f "$PROFILE" ]] || { echo "ERROR: provisioning profile not found: $PROFILE" >&2; exit 1; }
    cp "$PROFILE" "$app_dir/embedded.mobileprovision"
  fi

  local entitlements
  entitlements="$(mktemp /tmp/hyperion-entitlements.XXXXXX.plist)"
  if codesign -d --entitlements :- "$app_dir" > "$entitlements" 2>/dev/null; then
    if ! plutil -lint "$entitlements" >/dev/null 2>&1; then
      echo "Existing entitlements were not extractable; signing without explicit entitlements."
      rm -f "$entitlements"
      entitlements=""
    fi
  else
    rm -f "$entitlements"
    entitlements=""
  fi

  find "$app_dir" \( -type d \( -name "*.framework" -o -name "*.appex" \) -o -type f -name "*.dylib" \) -print0 | while IFS= read -r -d '' item; do
    codesign --force --sign "$IDENTITY" "$item"
  done

  rm -rf "$app_dir/_CodeSignature"
  if [[ -n "$entitlements" ]]; then
    codesign --force --sign "$IDENTITY" --entitlements "$entitlements" "$app_dir"
    rm -f "$entitlements"
  else
    codesign --force --sign "$IDENTITY" "$app_dir"
  fi

  codesign --verify --deep --strict --verbose=2 "$app_dir"
}

case "$INPUT" in
  *.xcarchive)
    APP_DIR="$(find_app_in_archive "$INPUT")"
    [[ -n "$APP_DIR" ]] || { echo "ERROR: no .app found inside archive: $INPUT" >&2; exit 1; }
    patch_app "$APP_DIR"
    echo "DONE: archive patched. Now export a NEW IPA from this archive and upload that IPA."
    ;;
  *.app)
    patch_app "$INPUT"
    if [[ "$RESIGN" -eq 1 ]]; then resign_app "$INPUT"; fi
    echo "DONE: app patched."
    ;;
  *.ipa)
    WORKDIR="$(mktemp -d)"
    unzip -q "$INPUT" -d "$WORKDIR"
    APP_DIR="$(find "$WORKDIR/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
    [[ -n "$APP_DIR" ]] || { echo "ERROR: no .app found in IPA Payload" >&2; exit 1; }
    patch_app "$APP_DIR"
    if [[ "$RESIGN" -eq 1 ]]; then
      resign_app "$APP_DIR"
      OUT_IPA="${OUT_IPA:-${INPUT%.ipa}-fixed-resigned.ipa}"
    else
      OUT_IPA="${OUT_IPA:-${INPUT%.ipa}-fixed-UNSIGNED.ipa}"
      echo "WARNING: IPA was modified after signing and is not App-Store-valid unless re-signed."
    fi
    (cd "$WORKDIR" && zip -qry "$OUT_IPA" Payload SwiftSupport Symbols 2>/dev/null || zip -qry "$OUT_IPA" Payload)
    mv "$WORKDIR/$OUT_IPA" "$OUT_IPA" 2>/dev/null || true
    rm -rf "$WORKDIR"
    echo "DONE: wrote $OUT_IPA"
    ;;
  *)
    echo "ERROR: input must be .xcarchive, .app, or .ipa: $INPUT" >&2
    exit 2
    ;;
esac
