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

## Sample setup (Nginx Proxy Manager)

Details Tab
- Domain names: `pi.example.com`
- Scheme: `http`
- Forward hostname / IP: `127.0.0.1`
- Forward port: `30141`
- Enable Websockets Support: **on**
- Block Common Exploits: on (optional)

Advanced Tab — paste this verbatim into the *Custom Nginx Configuration*
field (NPM does not surface `proxy_set_header` directly):

```nginx
proxy_set_header Host localhost;
proxy_set_header Origin "";
proxy_http_version 1.1;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
proxy_buffering off;
proxy_request_buffering off;
client_max_body_size 100M;
```

SSL Tab — enable Force SSL and HTTP/2, use a Let's Encrypt cert.

Access List — create an *Access List* with Basic Auth entries and attach it
to this Proxy Host. NPM stores the hashed credentials for you; the pi-agent
package no longer has a `set-password.sh` because that responsibility has
moved here.

---

## What still leaks despite this proxy

Even with Host/Origin rewritten and Basic auth on:

- The agent can still `cat /data/pi-agent/models.json` and read the provider
  API key from inside a session. That file is mode `600`, but the agent
  runs as its owner. This is upstream pi-web behaviour; the proxy cannot fix
  it.
- Anything else on the Podman host that can reach `127.0.0.1:30141`
  bypasses the proxy entirely. Rootless namespacing helps, but do not put
  untrusted containers on the same host expecting network isolation.
- Basic auth over plain HTTP sends the password base64-encoded on every
  request. Terminate TLS at this proxy; do not skip that step because "it
  is only on the LAN".

None of these are new; they were true when the sidecar shipped in this repo
too. Removing the sidecar just moves the credential boundary out of this
repo's scope, not into a stronger place.
