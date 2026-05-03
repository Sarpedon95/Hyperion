#!/usr/bin/env bash
set -euo pipefail
IPA="${1:-}"
if [[ -z "$IPA" || ! -f "$IPA" ]]; then
  echo "Usage: $0 /path/to/Hyperion.ipa" >&2
  exit 2
fi
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
unzip -q "$IPA" -d "$WORKDIR"
APP_DIR="$(find "$WORKDIR/Payload" -maxdepth 1 -type d -name "*.app" | head -n 1)"
if [[ -z "$APP_DIR" ]]; then
  echo "FAILED: no .app found in IPA Payload" >&2
  exit 1
fi
PLIST="$APP_DIR/Info.plist"
/usr/bin/python3 - "$PLIST" "$APP_DIR" <<'PY'
import plistlib, sys, os
plist_path, app_dir = sys.argv[1], sys.argv[2]
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
    if p.get(key) != expected:
        errors.append(f'{key} missing/wrong: {p.get(key)!r}, expected {expected!r}')
if p.get('UILaunchStoryboardName') != 'LaunchScreen':
    errors.append(f"UILaunchStoryboardName missing/wrong: {p.get('UILaunchStoryboardName')!r}")
if p.get('UIRequiresFullScreen') is not True:
    errors.append(f"UIRequiresFullScreen missing/wrong: {p.get('UIRequiresFullScreen')!r}")
if p.get('UIDeviceFamily') != [1, 2]:
    errors.append(f"UIDeviceFamily missing/wrong: {p.get('UIDeviceFamily')!r}, expected [1, 2]")
if not os.path.isdir(os.path.join(app_dir, 'LaunchScreen.storyboardc')):
    errors.append('LaunchScreen.storyboardc missing from app bundle')
if errors:
    print('IPA IS NOT READY FOR APP STORE UPLOAD')
    for e in errors:
        print(' - ' + e)
    sys.exit(1)
print('IPA App Store validation precheck: OK')
PY
