# navi-fiesta

One multi-arch image (`linux/amd64`, `linux/arm64`) with the
[navidrome](https://github.com/norifm/navidrome) and
[octo-fiesta](https://github.com/norifm/octo-fiesta) forks behind a single port.

```
:4533 nginx ─┬─ /rest/{search3,stream,getSong,getAlbum,…}  → octo-fiesta 127.0.0.1:5274
             └─ everything else (UI, /api, SSE, other /rest) → navidrome   127.0.0.1:4534
```

- **Small**: extends the prebuilt `ghcr.io/norifm/navidrome:develop` image and adds only the ASP.NET
  runtime, octo-fiesta, nginx, tini and cloudflared (~425 MB total, of which navidrome's base is ~250 MB).
  Only English ICU data is shipped.
- **Fast to build**: navidrome is not recompiled; octo-fiesta is cross-compiled for musl on the
  build host, so arm64 builds need no QEMU (~30 s warm).
- **Fast to run**: octo-fiesta is ReadyToRun-precompiled and uses workstation GC with memory
  conservation; nginx keeps upstream connections alive and does not buffer streams or write access logs.
- **One lifecycle**: if any of the three processes exits, the container exits and the restart
  policy brings the whole stack back.

## Running

```sh
cp .env.example .env    # fill in music service tokens
docker compose up -d
```

### octo-fiesta's navidrome account

octo-fiesta needs a navidrome admin for library scans and the upload API. No credentials are configured for
it. On every start the entrypoint runs the navidrome fork's `navidrome service-account` command, which
creates (or re-keys) an admin account named `octo-fiesta` with a random 256-bit password. The password is
never written to the volume. It is handed to octo-fiesta's environment only and changes on every restart.

- On a fresh install, the account is created on the first restart after you've made your own admin in the web UI.
  Until then, octo-fiesta uses the credentials of whichever admin client connects first.
- The account is only created and rotated by this command. A pre-existing user named `octo-fiesta` is never
  taken over (the stack still starts, with a warning).
- `NAVI_FIESTA_SERVICE_ACCOUNT=<name>` changes the account name; an empty value disables it.
- Setting `Subsonic__AdminUsername` + `Subsonic__AdminPassword_FILE` uses that existing account instead.

This account is separate from the logins your users play music with. Every client request octo-fiesta
handles is passed to navidrome with that client's own credentials.

Volumes: `/data` (navidrome DB/cache, octo-fiesta's Tidal tokens under `/data/octo-fiesta`) and
`/music` (library; octo-fiesta downloads straight into it).

Any environment variable can be read from a file by appending `_FILE`, e.g.
`Deezer__Arl_FILE=/run/secrets/deezer_arl`.

Tidal login: `docker compose run --rm navi-fiesta --tidal-login` (arguments go to octo-fiesta).

### Without port forwarding (Cloudflare Tunnel)

`cloudflared` is built in and starts only when `TUNNEL_TOKEN` is set:

1. Cloudflare Zero Trust -> Networks -> Tunnels -> create a tunnel and put its token in `.env` as `TUNNEL_TOKEN`
   (or mount it and set `TUNNEL_TOKEN_FILE`).
2. Add a public hostname for the tunnel with service `http://localhost:4533` (cloudflared runs in the same
   container as nginx).
3. `docker compose up -d`. The `ports:` mapping can then be dropped entirely.

Set `ND_BASEURL` to the tunnel's `https://` hostname. Client IPs arrive via `CF-Connecting-IP` and are
forwarded to navidrome as `X-Real-IP`. The token is only passed to cloudflared's process. Other
`TUNNEL_*` variables (e.g. `TUNNEL_TRANSPORT_PROTOCOL=http2` where UDP is blocked) go straight to cloudflared.

### Outer reverse proxy

All routing lives in the image, so the host proxy only needs one location:

```nginx
server {
    listen 80;
    server_name music.filipton.space;

    location / {
        proxy_pass http://192.168.1.159:4533;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

Headers set by the outer proxy (`X-Real-IP`, `X-Forwarded-Proto`, `X-Forwarded-Host`) are passed
through unchanged. A sub-path `ND_BASEURL` is not supported, because octo-fiesta's routes are rooted at `/rest`.

## Building locally

```sh
docker buildx build --platform linux/amd64,linux/arm64 -t navi-fiesta .

# against local checkouts of the forks
docker buildx build \
  --build-context octo-src=../octo-fiesta \
  --build-context navidrome=docker-image://my-local-navidrome \
  -t navi-fiesta .
```

CI (`.github/workflows/docker.yml`) publishes `ghcr.io/norifm/navi-fiesta:latest` on push,
daily, on manual dispatch, and on a `repository_dispatch` event of type `upstream-updated`.
