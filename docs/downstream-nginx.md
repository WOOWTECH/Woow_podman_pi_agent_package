# Downstream reverse-proxy contract

This deployment publishes pi-web on `127.0.0.1:30141` and ships **no** reverse
proxy of its own. A same-host nginx (or Nginx Proxy Manager) is expected to
sit in front of it and satisfy both halves of the contract below.

Without a proxy that does these things, either the UI loads and every data
route returns `403 Untrusted API request`, or the endpoint is trivially
scrape-able for the provider API key. Neither state is one you want to ship.

---

## Non-negotiable: rewrite two headers

pi-web's `isApiRequestAllowed()` rejects any `Host` that is not a loopback
name or a raw IP, and any `Origin` that does not match. A hostname in front
— a Cloudflare Tunnel, an internal DNS name, an NPM Proxy Host — fails both
halves and every auth-gated route (`/api/models`, `/api/models-config`,
`/api/skills`, `/api/plugins`, `/api/sessions`, …) answers 403. The UI
renders and then does nothing, which is the diagnostic tell.

The downstream proxy MUST forward with:

```nginx
proxy_set_header Host localhost;
proxy_set_header Origin "";
```

Anything else — passing through the original Host, forwarding the browser's
Origin, leaving Host unset — will fail. That includes CF Tunnel's
`httpHostHeader` option: it covers Host only, not Origin, so it is not
enough by itself.

---

## Non-negotiable: enforce authentication

pi-web has **no** authentication of its own. Zero `AUTH_*` environment
variables. `GET /api/models-config` returns the configured provider API key
in cleartext to any caller that gets past the Host/Origin guard, confirmed on
a live deployment (not inferred from source).

Since pi-web 0.9.0 the stakes are higher than the key: `/api/terminal` is a
browser terminal, a login shell that runs as root inside the container, which
rootless Podman maps to the host account running pi-web. With the host-control
profile that account's home directory, Podman socket and user systemd are all
reachable from that shell.

The downstream proxy is therefore the deployment's only credential boundary.
Whatever mechanism the proxy supports — HTTP Basic, CF Access, mTLS, an
OIDC gate — must be **on**, and must apply to every path, not just `/`.

---

## Sample nginx block (plain nginx)

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name pi.example.com;

    ssl_certificate     /etc/letsencrypt/live/pi.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pi.example.com/privkey.pem;

    # SSE responses stream for minutes; a proxy that buffers or times out
    # truncates the assistant mid-sentence, which the UI shows as a
    # spontaneous stop.
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    proxy_request_buffering off;
    client_max_body_size 100M;

    # Basic auth — swap for whatever your edge already does.
    auth_basic "Pi Agent";
    auth_basic_user_file /etc/nginx/pi-agent.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:30141;
        proxy_http_version 1.1;

        # The point of this whole file. Do not omit either line.
        proxy_set_header Host localhost;
        proxy_set_header Origin "";

        proxy_set_header X-Real-IP        $remote_addr;
        proxy_set_header X-Forwarded-For  $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade          $http_upgrade;
        proxy_set_header Connection       $connection_upgrade;
    }
}
```

Create the htpasswd once with:

```bash
htpasswd -c /etc/nginx/pi-agent.htpasswd woow          # prompted; $6$ SHA-512
```

Or if openssl is what you have:

```bash
printf 'woow:'                                     >  /etc/nginx/pi-agent.htpasswd
openssl passwd -6 -stdin                           >> /etc/nginx/pi-agent.htpasswd
chown root:nginx /etc/nginx/pi-agent.htpasswd && chmod 640 /etc/nginx/pi-agent.htpasswd
```

---

## Sample setup (Nginx Proxy Manager, the pi-web front)

[Woow_podman_nginxpm](https://github.com/WOOWTECH/Woow_podman_nginxpm) ships
the NPM side of this contract. On the same host, as the same account:

```bash
cd Woow_podman_nginxpm
./scripts/install.sh --with-pi-web-front      # records NPM_PI_WEB_FRONT=true in ~/.config/npm/npm.env
```

That makes NPM join the `pi-agent` network (ordering on
`pi-agent-network.service`, never a hard dependency) and mounts two files from
`~/.config/npm/pi-web-front/`:

- `proxy.conf` replaces NPM's `conf.d/include/proxy.conf`, which every proxy
  host includes inside its `location /`. It is the stock 2.15.1 file with the
  Host and Origin lines taken from two maps;
- `maps.conf` defines those maps, keyed on `$server` (the proxy host's Forward
  Hostname): for `pi-web` they give `Host: localhost` and a blank `Origin`,
  for every other upstream the stock `$host` and the client's own Origin.

Then create the proxy host in the NPM admin UI:

- Details: domain `pi.example.com`, scheme `http`, **Forward Hostname `pi-web`**,
  Forward Port `30141`, Websockets Support **on**. The hostname must be the
  container name: the rewrite is keyed on it, and NPM reaches pi-web over the
  shared network, not over the host's loopback (a rootless bridge cannot reach
  `127.0.0.1` of the host).
- Access List: an access list with Basic auth entries, attached to this proxy
  host. NPM stores the hashed credentials.
- SSL: enable Force SSL and HTTP/2 when NPM terminates TLS. Behind a
  Cloudflare tunnel TLS already ends at Cloudflare.
- Advanced: optionally raise the SSE timeouts:

  ```nginx
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;
  proxy_buffering off;
  proxy_request_buffering off;
  client_max_body_size 100M;
  ```

  Do **not** set `proxy_set_header Host`, `Origin` or `proxy_http_version`
  there: NPM emits its own `proxy_set_header Host $host` inside `location /`,
  nginx does not inherit server-level `proxy_set_header` into a location that
  sets any, so an Advanced-tab override is silently shadowed and every `/api/*`
  route answers `403 "Untrusted API request"`. That is the reason the rewrite
  lives in the global `proxy.conf` instead.

Symptoms and fixes:

| Symptom | Cause |
|---|---|
| UI loads, every `/api/*` answers 403 | Forward Hostname is not `pi-web` (for example `127.0.0.1`), so the maps give the stock Host |
| 502 from NPM | NPM is not on the `pi-agent` network (front not enabled), or pi-web is down |
| NPM fails to start after someone "hardened" the mounts to `:ro` | NPM 2.15.1 runs `chown -R` over `/etc/nginx/conf.d` at start; the mounts must stay read-write |

Earlier revisions of this document described a per-host `server_proxy.conf`
with hardcoded aardvark resolver IPs and a manual `podman network connect
pi-agent npm-app`. Both are obsolete: NPM generates its resolvers from
`/etc/resolv.conf` (aardvark-dns, `valid=10s`, so a pi-web restart needs no NPM
restart), and the network membership is part of the NPM unit.

---

## What still leaks despite this proxy

Even with Host/Origin rewritten and Basic auth on:

- The agent can still `cat /data/pi-agent/models.json` and read the provider
  API key from inside a session. That file is mode `600`, but the agent
  runs as its owner. This is upstream pi-web behaviour; the proxy cannot fix
  it.
- Anything else on the Podman host that can reach `127.0.0.1:30141`
  bypasses the proxy entirely: a tailnet `tailscale serve` forward to that
  port, an `ssh -L` shared with others, another container that can reach the
  host's loopback. Since pi-web 0.9.0 each of those is an unauthenticated
  browser terminal, i.e. a shell as the account running pi-web with its home
  directory mounted read-write. Rootless namespacing helps, but do not put
  untrusted containers on the same host expecting network isolation.
- A public hostname protected by NPM Basic auth alone has one password between
  the Internet and that shell. Put Cloudflare Access (or another identity-aware
  gate) in front of it as a second, independent layer.
- Basic auth over plain HTTP sends the password base64-encoded on every
  request. Terminate TLS at this proxy; do not skip that step because "it
  is only on the LAN".

None of these are new; they were true when the sidecar shipped in this repo
too. Removing the sidecar just moves the credential boundary out of this
repo's scope, not into a stronger place.
