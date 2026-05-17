ARG NODE_IMAGE=node:22-alpine
ARG DART_IMAGE=dart:stable
ARG DEBIAN_IMAGE=debian:bookworm-slim

FROM ${NODE_IMAGE} AS web-builder
WORKDIR /app/web
COPY web/package*.json ./
RUN npm ci
COPY web ./
RUN npm run build

FROM ${DART_IMAGE} AS server-builder
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
COPY --from=web-builder /app/web/dist /app/web/dist
RUN mkdir -p /app/build \
    && dart compile exe bin/server.dart -o /app/build/server

FROM ${DEBIAN_IMAGE} AS runtime
ARG APT_MIRROR=
RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s|http://deb.debian.org/debian|$APT_MIRROR|g; s|http://deb.debian.org/debian-security|$APT_MIRROR-security|g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=server-builder /app/build/server /app/server
COPY --from=web-builder /app/web/dist /app/public
ENV PACKER_HOST=0.0.0.0 \
    PACKER_PORT=8080 \
    PACKER_DATA_DIR=/app/data \
    PACKER_PUBLIC_DIR=/app/public \
    PACKER_MAX_CONCURRENT=1 \
    PACKER_CHAPTER_CONCURRENCY=6 \
    PACKER_IMAGE_CONCURRENCY=8 \
    PACKER_SOURCE_RATE_MODE=stable \
    PACKER_FILE_TTL_HOURS=24
VOLUME ["/app/data"]
EXPOSE 8080
ENTRYPOINT ["/app/server"]
