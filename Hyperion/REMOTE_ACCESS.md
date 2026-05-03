# Hyperion remote access and server logging

Hyperion can now connect from outside your home network through either:

1. **Tailscale** — set `Tailscale` to `http://100.x.y.z:9000` and choose `Tailscale` or `Auto`.
2. **HTTPS reverse proxy** — set `Remote` to `https://your-domain.example` and choose `Remote Proxy` or `Auto`.

The app accepts either the base URL or the full JSON-RPC endpoint. These are equivalent:

```text
https://your-domain.example
https://your-domain.example/jsonrpc.js
```

## Recommended Nginx reverse proxy

This example exposes Lyrion Music Server on `https://music.example.com`, passes JSON-RPC and music streaming paths through to the LMS host on your LAN, and writes much better logs for debugging remote failures.

```nginx
log_format hyperion '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    'host="$host" ref="$http_referer" ua="$http_user_agent" '
                    'xff="$http_x_forwarded_for" '
                    'rt=$request_time urt=$upstream_response_time '
                    'uaddr="$upstream_addr" ustatus="$upstream_status"';

upstream lyrion_lms {
    server 192.168.1.105:9000;
    keepalive 16;
}

server {
    listen 443 ssl http2;
    server_name music.example.com;

    access_log /var/log/nginx/hyperion_access.log hyperion;
    error_log  /var/log/nginx/hyperion_error.log warn;

    # Use your existing certificate paths here.
    ssl_certificate     /etc/letsencrypt/live/music.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/music.example.com/privkey.pem;

    # Optional but strongly recommended if this is public internet-facing.
    # auth_basic "Hyperion";
    # auth_basic_user_file /etc/nginx/.htpasswd-hyperion;

    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Connection "";

    # JSON-RPC API used by library/search/playback commands.
    location = /jsonrpc.js {
        proxy_pass http://lyrion_lms/jsonrpc.js;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    # Artwork and audio streams used by AVPlayer.
    location /music/ {
        proxy_pass http://lyrion_lms/music/;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    # Optional: expose the LMS web UI remotely too.
    location / {
        proxy_pass http://lyrion_lms/;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
```

After editing Nginx:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo tail -f /var/log/nginx/hyperion_access.log /var/log/nginx/hyperion_error.log
```


### Reverse proxy Basic Auth

If your HTTPS reverse proxy uses HTTP Basic Auth, enter the Remote URL as:

```text
https://username:password@music.example.com
```

Hyperion now sends that Authorization header for connection probes, JSON-RPC, artwork, and audio streams. Credentials are redacted from diagnostics and the Settings active URL display.

## What to check when remote fails

- **HTTP 404** in Hyperion diagnostics: the proxy is not forwarding `/jsonrpc.js` to LMS.
- **HTTP 502/504**: Nginx cannot reach your LMS host/port from the server.
- **HTTP 401/403**: proxy authentication or allow/deny rules are blocking the app.
- **TLS/certificate failure**: use a trusted public certificate for the remote domain.
- **JSON-RPC response error**: LMS received the request but rejected the command; check LMS logs too.

In Hyperion, open **Settings → Server Diagnostics → Copy Logs** and compare those entries with `hyperion_access.log` timestamps.

### Remote HTTP / App Transport Security

If diagnostics say **Blocked by App Transport Security** for a public `http://...:9000` address, iOS is blocking clear-text remote HTTP before Hyperion reaches your server. This build keeps ATS exceptions in both `Info.plist` and `project.yml`, but the safer remote setup is still an HTTPS reverse proxy or Tailscale. For public internet access, prefer `https://your-domain.example` over exposing LMS port `9000` directly.


### LyrPlay-style Tailscale/MagicDNS input

You no longer have to type the exact `http://host:9000` LMS URL for Tailscale. Hyperion probes the likely LMS endpoints automatically, so these are valid:

```text
my-lms.tailnet.ts.net
http://my-lms.tailnet.ts.net
100.x.y.z
http://100.x.y.z
http://100.x.y.z:9000
```

For HTTPS reverse proxies, these are also normalized to the same base URL:

```text
https://music.example.com
https://music.example.com/material
https://music.example.com/jsonrpc.js
```

The diagnostics log now shows every redacted endpoint candidate it probes, then uses the first successful LMS JSON-RPC response as the active base URL.
