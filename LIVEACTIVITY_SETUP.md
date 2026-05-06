# Live Activity Setup — Manual Xcode Steps

The Live Activity implementation is fully written in two Swift files:

| File | Purpose |
|------|---------|
| `HyperionLiveActivity/HyperionLiveActivity.swift` | Widget extension: Dynamic Island + lock screen UI, `HyperionActivityAttributes` model, App Intents |
| `Hyperion/PlayerViewModel+LiveActivity.swift` | Main app: `startLiveActivity()`, `updateLiveActivity()`, `endLiveActivity()`, artwork thumbnail helper |

Because the Hyperion repo does not use a `.xcconfig`/`project.yml` workflow that supports adding targets programmatically, you must wire the extension target in Xcode manually.

---

## Step 1 — Add the Widget Extension target

1. In Xcode, open `Hyperion.xcodeproj`.
2. **File → New → Target…**
3. Choose **Widget Extension** (under iOS).
4. Fill in:
   - **Product Name**: `HyperionLiveActivity`
   - **Team**: your Apple Developer team
   - **Bundle Identifier**: `com.sarpedon.hyperion.liveactivity`  
     *(must be a sub-bundle of the main app's `com.sarpedon.hyperion`)*
   - Uncheck **Include Configuration App Intent** (intents are already defined in the file).
5. Click **Finish**.
6. Xcode will create a stub `HyperionLiveActivity.swift`. **Delete it** — the real file is already at `HyperionLiveActivity/HyperionLiveActivity.swift`.
7. Add the existing file to the new target: drag `HyperionLiveActivity/HyperionLiveActivity.swift` into the target's group in the Project Navigator and confirm the target membership checkbox.

---

## Step 2 — Entitlements

### Main app target (`Hyperion`)
Open `Hyperion.entitlements` and add:

```xml
<key>com.apple.developer.live-activities</key>
<true/>
```

Or in the **Signing & Capabilities** tab → **+ Capability** → **Push Notifications** (required for remote Live Activity updates) and **Background Modes → Remote notifications**.

The Live Activity entitlement itself (`com.apple.developer.live-activities`) is added automatically when you use `ActivityKit` in a provisioned build, but adding it explicitly avoids surprises.

### Extension target (`HyperionLiveActivity`)
Widget extensions do not need the Live Activity entitlement — they only render; they do not call `Activity.request()`.

---

## Step 3 — Info.plist (main app)

Add the `NSSupportsLiveActivities` key to `Hyperion/Info.plist`:

```xml
<key>NSSupportsLiveActivities</key>
<true/>
```

If you want the Live Activity to be updated remotely (push), also add:

```xml
<key>NSSupportsLiveActivitiesFrequentUpdates</key>
<true/>
```

---

## Step 4 — App Groups (shared data)

The Live Activity uses `HyperionActivityAttributes` which is defined in both the main app and the extension. Because it is embedded in the payload (not in UserDefaults), **no App Group is required** for basic functionality.

If you later want to share artwork via the file system (larger than the 4 KB ActivityKit attribute limit allows), create a shared App Group:

1. Both targets → **Signing & Capabilities → + Capability → App Groups**.
2. Use the same group ID, e.g. `group.com.sarpedon.hyperion`.

---

## Step 5 — Hook `PlayerViewModel` calls

The Live Activity is already integrated in `PlayerViewModel+LiveActivity.swift`. You just need to ensure these are called at the right lifecycle points. In `PlayerViewModel`, find the `currentTrack` `didSet` observer (or the play/pause handlers) and call:

```swift
// On new track start:
startLiveActivity()

// On play/pause toggle, seek, track change:
updateLiveActivity()

// On app background / playback end:
endLiveActivity()
```

Search for `#if canImport(ActivityKit)` in the file — the calls are guarded and will compile away on simulators without ActivityKit.

---

## Step 6 — Build & verify

1. Build the main app scheme — it should compile without errors.
2. Build the `HyperionLiveActivity` extension scheme to confirm the extension target is linked.
3. Run on a **physical device** (iOS 16.1+) — Live Activities are not supported in the Simulator.
4. Play a track; the Dynamic Island should show the compact artwork + title.

---

## Architecture notes

- `HyperionActivityAttributes` is defined **twice** (once in each target) with identical layouts. This is intentional — the widget extension cannot import the main app module, so the type must be redeclared. Both definitions must be kept in sync.
- Artwork is limited to ~4 KB by ActivityKit. The `artworkThumbnailJPEG()` helper in `PlayerViewModel+LiveActivity.swift` performs a synchronous cache probe at 40 × 40 pt @ 2× (80 × 80 px) with JPEG quality 0.7, which typically produces a 2–3 KB payload.
- The associated object trick (`objc_setAssociatedObject`) is used to store `Activity<HyperionActivityAttributes>?` in a `PlayerViewModel` extension without needing a stored property on the `@MainActor` class.
