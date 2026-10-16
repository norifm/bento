# syntax=docker/dockerfile:1.7

# Navidrome is taken prebuilt from the fork's multi-arch image, so only octo-fiesta is compiled here.
# Override either source locally with:
#   --build-context navidrome=docker-image://<image>   (e.g. an image built from ../navidrome)
#   --build-context octo-src=../octo-fiesta
ARG NAVIDROME_IMAGE=ghcr.io/norifm/navidrome:develop
ARG OCTO_REPO=https://github.com/norifm/octo-fiesta.git
ARG OCTO_REF=dev
ARG CLOUDFLARED_IMAGE=cloudflare/cloudflared:latest

FROM ${NAVIDROME_IMAGE} AS navidrome
FROM ${CLOUDFLARED_IMAGE} AS cloudflared

FROM scratch AS octo-src
ARG OCTO_REPO
ARG OCTO_REF
ADD --keep-git-dir=false ${OCTO_REPO}#${OCTO_REF} /

########################################################################################################################
### Build octo-fiesta on the build host and cross-target musl (no QEMU needed for arm64)
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS octo-build
ARG TARGETARCH
ARG OCTO_VERSION=0.0.0-dev
WORKDIR /src

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

COPY --from=octo-src octo-fiesta/octo-fiesta.csproj octo-fiesta/
RUN --mount=type=cache,target=/root/.nuget/packages,sharing=locked <<EOT
    set -e
    case "$TARGETARCH" in
        amd64) RID=linux-musl-x64 ;;
        arm64) RID=linux-musl-arm64 ;;
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
    esac
    echo "$RID" > /rid
    dotnet restore octo-fiesta/octo-fiesta.csproj -r "$RID" -p:PublishReadyToRun=true
EOT

COPY --from=octo-src octo-fiesta/ octo-fiesta/
# ReadyToRun precompiles the IL, so the proxy starts fast and skips most JIT work on the phone.
RUN --mount=type=cache,target=/root/.nuget/packages,sharing=locked \
    dotnet publish octo-fiesta/octo-fiesta.csproj \
        -c Release -r "$(cat /rid)" --self-contained false --no-restore \
        -p:PublishReadyToRun=true \
        -p:Version=${OCTO_VERSION} \
        -p:DebugType=none \
        -p:SatelliteResourceLanguages=en \
        -o /out && \
    rm -f /out/*.pdb /out/appsettings.Development.json

########################################################################################################################
### Final image: navidrome's runtime (ffmpeg, mpv, sqlite, libwebp) + .NET runtime + nginx + cloudflared
FROM navidrome AS final
LABEL org.opencontainers.image.source="https://github.com/norifm/bento"
LABEL org.opencontainers.image.description="Navidrome + octo-fiesta behind one nginx port"

# icu-data-en instead of icu-data-full: octo-fiesta only needs Unicode normalization, not locale data (-27MB).
# (Alpine's dotnet9-runtime package hard-depends on icu-data-full, hence the runtime copy below.)
RUN apk add --no-cache icu-libs icu-data-en libgcc libstdc++ nginx tini && \
    rm -rf /etc/nginx/http.d /var/lib/nginx/logs /var/log/nginx /usr/share/nginx

COPY --from=mcr.microsoft.com/dotnet/aspnet:9.0-alpine /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet
COPY --from=octo-build /out /opt/octo-fiesta
# Static Go binary; only started when TUNNEL_TOKEN is set.
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY --chmod=755 rootfs/usr/local/bin/ /usr/local/bin/
COPY rootfs/etc/nginx/nginx.conf /etc/nginx/nginx.conf
RUN nginx -e stderr -t -q && rm -rf /tmp/nginx*

# Navidrome and octo-fiesta listen on loopback only; nginx on 4533 is the single public port.
ENV ND_ADDRESS=127.0.0.1 \
    ND_PORT=4534 \
    ASPNETCORE_URLS=http://127.0.0.1:5274 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_gcServer=0 \
    DOTNET_GCConserveMemory=5 \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_EnableDiagnostics=0 \
    Logging__LogLevel__Default=Information \
    Logging__LogLevel__Microsoft.AspNetCore=Warning \
    Library__DownloadPath=/music \
    Subsonic__Url=http://127.0.0.1:4534 \
    Tidal__TokenStore=/data/octo-fiesta/tidal-tokens.json \
    NAVI_FIESTA_SERVICE_ACCOUNT=octo-fiesta

EXPOSE 4533
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl -fsS -o /dev/null http://127.0.0.1:4533/ping && nc -z 127.0.0.1 5274 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/navi-fiesta"]
