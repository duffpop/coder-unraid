# Thin wrapper around the official Coder image for Unraid.
# Adds: PUID/PGID handling, docker socket group detection, appdata ownership
# fixes, and first-run bootstrap of the admin user and Premium license.
ARG CODER_VERSION=latest
FROM ghcr.io/coder/coder:${CODER_VERSION}

ARG CODER_VERSION
LABEL org.opencontainers.image.title="Coder for Unraid" \
      org.opencontainers.image.description="Coder (coder.com) with an Unraid-friendly entrypoint" \
      org.opencontainers.image.source="https://github.com/duffpop/coder-unraid" \
      org.opencontainers.image.base.name="ghcr.io/coder/coder:${CODER_VERSION}"

USER root
RUN apk add --no-cache tini su-exec jq shadow

COPY --chmod=755 rootfs/ /

ENV PUID=99 \
    PGID=100 \
    CODER_HTTP_ADDRESS=0.0.0.0:7080

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
