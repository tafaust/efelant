# Compiles the Flutter web client, then serves it beside the /ws adapter.
# Companies only need Docker. First build downloads the Flutter SDK.

FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.41.9
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}"
RUN git config --global --add safe.directory /opt/flutter \
    && flutter config --no-analytics --enable-web \
    && flutter precache --web

WORKDIR /src
COPY app/pubspec.yaml app/pubspec.lock ./
COPY app ./
RUN flutter pub get \
    && flutter build web --release --no-web-resources-cdn --base-href / \
    && test -s build/web/index.html \
    && test -s build/web/main.dart.js

FROM nginx:1.27-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/build/web /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=10 \
    CMD wget -qO- http://127.0.0.1/health || exit 1
