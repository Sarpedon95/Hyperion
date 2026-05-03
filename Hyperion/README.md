# Hyperion

Hyperion is a dark, Roon-inspired iOS client for Lyrion Music Server. It supports library browsing, composer/work views, queue management, direct AVPlayer streaming, CarPlay metadata, and configurable local/Tailscale/reverse-proxy server access.

## Connection setup

Open **Settings** in the app and configure one or more addresses:

- **Home**: your LAN LMS address, for example `http://192.168.1.25:9000`.
- **Tailscale**: your tailnet LMS address, for example `http://100.x.y.z:9000`.
- **Remote**: your HTTPS reverse proxy, for example `https://music.example.com`.

Modes:

- **Auto** probes every configured address and uses the first real Lyrion JSON-RPC endpoint that answers.
- **Home LAN**, **Tailscale**, and **Remote Proxy** use only that configured URL. They no longer silently fall back to a hard-coded home address.

The app normalizes pasted URLs, so both `https://music.example.com` and `https://music.example.com/jsonrpc.js` are accepted.

## Diagnostics

Settings includes **Server Diagnostics** with the last probe result and recent server/RPC logs. The diagnostics show:

- URL selected by the resolver
- `/jsonrpc.js` probe success/failure
- HTTP status codes
- DNS, TLS, timeout, and proxy/upstream failures
- JSON-RPC errors from LMS
- RPC duration for app requests

Tap **Copy Logs** to copy the in-app ring buffer. The same messages are emitted through `os.Logger` under subsystem `com.sarpedon.hyperion`, category `Server`.


### Remote proxy authentication

For an HTTPS reverse proxy protected by Basic Auth, put credentials in the Remote URL:

```text
https://username:password@music.example.com
```

Hyperion forwards the Authorization header for diagnostics, JSON-RPC, artwork, and audio streams, while redacting credentials from logs.

## Remote proxy

See [`REMOTE_ACCESS.md`](REMOTE_ACCESS.md) and [`nginx-hyperion-remote.conf`](nginx-hyperion-remote.conf) for an Nginx reverse-proxy example with improved access/error logging.

## Build notes

The project is set up for XcodeGen via `project.yml` and targets iOS 17+. From the directory that contains the `Hyperion/` folder, run:

```bash
xcodegen generate --spec Hyperion/project.yml
open Hyperion.xcodeproj
```

App Store archive helper scripts are still included:

- `fix_hyperion_appstore_bundle.sh`
- `verify_ipa_before_upload.sh`

The archive also includes a complete `Assets.xcassets/AppIcon.appiconset` at
the project root so XcodeGen can resolve the configured `AppIcon` catalog
without requiring a separate asset handoff.

### Remote HTTP / App Transport Security

If diagnostics say **Blocked by App Transport Security** for a public `http://...:9000` address, iOS is blocking clear-text remote HTTP before Hyperion reaches your server. This build keeps ATS exceptions in both `Info.plist` and `project.yml`, but the safer remote setup is still an HTTPS reverse proxy or Tailscale. For public internet access, prefer `https://your-domain.example` over exposing LMS port `9000` directly.


### LyrPlay-style remote address handling

Hyperion now accepts the same loose style of server input that LyrPlay users commonly use for Tailscale/MagicDNS:

- `my-lms.tailnet.ts.net`
- `http://my-lms.tailnet.ts.net`
- `http://100.x.y.z`
- `http://100.x.y.z:9000`
- `https://music.example.com/material`
- `https://music.example.com/jsonrpc.js`

At connection time it probes the likely LMS endpoints, including `:9000/jsonrpc.js` for local/Tailscale hosts, and keeps the winning base URL for API, artwork, and stream requests.
