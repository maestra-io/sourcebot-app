# syntax=docker/dockerfile:1
# ------ Global scope variables ------

# Set of global build arguments.
# These are considered "public" and will be baked into the image.
# The convention is to prefix these with `NEXT_PUBLIC_` so that
# they can be optionally be passed as client-side environment variables
# in the webapp.
# @see: https://docs.docker.com/build/building/variables/#scoping

ARG NEXT_PUBLIC_SENTRY_ENVIRONMENT
ARG NEXT_PUBLIC_SENTRY_WEBAPP_DSN
ARG NEXT_PUBLIC_SENTRY_BACKEND_DSN
ARG NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY
ARG NEXT_PUBLIC_LANGFUSE_BASE_URL
ARG NEXT_PUBLIC_BUILD_COMMIT_SHA

FROM packages.maestra.io/docker-hub/library/node:24-alpine3.23@sha256:0efee1e068d21f6edcab7fa8c962fc4ecd50d4e28727bc23963379b63ee318ab AS node-alpine
FROM packages.maestra.io/docker-hub/library/golang:1.26.10-alpine@sha256:87c65a688975c0b1d4585d204874c45ca78354670e3a5f11368c5a492303d696 AS go-alpine
# ----------------------------------

# ------ Build Zoekt ------
FROM go-alpine AS zoekt-builder
# apk, Go modules and yarn packages go through nora (packages.maestra.io, 3-day hold,
# maestra-io/issues-maestra#1649); the token is the PRIVATE_PACKAGES_TOKEN BuildKit secret.
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true --mount=type=bind,from=public.ecr.aws/g5f9s8a4/nora-apk:1.0.0@sha256:55df38687c301e6fefa230dc1c71a8841618214cc549ade71be740b25822a00e,target=/nora-apk \
    /nora-apk/nora-apk add --no-cache ca-certificates
WORKDIR /zoekt
COPY vendor/zoekt/go.mod vendor/zoekt/go.sum ./
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=NORA_TOKEN,required=true \
    GOPROXY="https://token:${NORA_TOKEN}@packages.maestra.io/go" go mod download
COPY vendor/zoekt ./
# Newest releases nora serves (3-day quarantine) of the direct and security-relevant zoekt deps;
# x/net 0.62.0 is CVE-2026-78661. The submodule pins older ones; refresh this list when it moves.
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=NORA_TOKEN,required=true \
    export GOPROXY="https://token:${NORA_TOKEN}@packages.maestra.io/go"&& \
    go get \
        github.com/go-git/go-billy/v5@v5.9.2 \
        github.com/go-git/go-git/v5@v5.19.3 \
        github.com/klauspost/compress@v1.20.3 \
        github.com/prometheus/client_golang@v1.25.0 \
        github.com/prometheus/common@v0.73.1 \
        github.com/prometheus/procfs@v0.23.0 \
        go.opentelemetry.io/otel@v1.47.0 \
        go.opentelemetry.io/otel/bridge/opentracing@v1.47.0 \
        go.opentelemetry.io/otel/exporters/otlp/otlptrace@v1.47.0 \
        go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@v1.47.0 \
        go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.47.0 \
        go.opentelemetry.io/otel/sdk@v1.47.0 \
        go.opentelemetry.io/otel/trace@v1.47.0 \
        go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc@v0.72.0 \
        go.opentelemetry.io/contrib/propagators/jaeger@v1.47.0 \
        go.opentelemetry.io/contrib/propagators/ot@v1.47.0 \
        golang.org/x/crypto@v0.58.0 \
        golang.org/x/net@v0.62.0 \
        golang.org/x/oauth2@v0.38.0 \
        golang.org/x/sync@v0.25.0 \
        golang.org/x/sys@v0.50.0 \
        golang.org/x/text@v0.43.0 \
        google.golang.org/grpc@v1.85.0 \
        google.golang.org/protobuf@v1.36.12 \
    && go mod tidy
ENV GOPROXY=off
RUN CGO_ENABLED=0 GOOS=linux go build -o /cmd/ ./cmd/...
# -------------------------

# ------ Build shared libraries ------
FROM node-alpine AS shared-libs-builder
WORKDIR /app

COPY package.json yarn.lock* .yarnrc.yml ./
COPY .yarn ./.yarn
COPY ./packages/db ./packages/db
COPY ./packages/schemas ./packages/schemas
COPY ./packages/shared ./packages/shared
COPY ./packages/queryLanguage ./packages/queryLanguage

RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/db install
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/schemas install
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/shared install
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/query-language install
# ------------------------------------

# ------ Build Web ------
FROM node-alpine AS web-builder
ENV SKIP_ENV_VALIDATION=1
# -----------
ARG NEXT_PUBLIC_SENTRY_ENVIRONMENT
ENV NEXT_PUBLIC_SENTRY_ENVIRONMENT=$NEXT_PUBLIC_SENTRY_ENVIRONMENT
ARG NEXT_PUBLIC_SENTRY_WEBAPP_DSN
ENV NEXT_PUBLIC_SENTRY_WEBAPP_DSN=$NEXT_PUBLIC_SENTRY_WEBAPP_DSN
ARG NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY
ENV NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY=$NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY
ARG NEXT_PUBLIC_LANGFUSE_BASE_URL
ENV NEXT_PUBLIC_LANGFUSE_BASE_URL=$NEXT_PUBLIC_LANGFUSE_BASE_URL
ARG NEXT_PUBLIC_BUILD_COMMIT_SHA
ENV NEXT_PUBLIC_BUILD_COMMIT_SHA=$NEXT_PUBLIC_BUILD_COMMIT_SHA

# To upload source maps to Sentry, we need to set the following build-time args.
# It's important that we don't set these for oss builds, otherwise the Sentry
# auth token will be exposed.
# @see : next.config.mjs
ARG SENTRY_ORG
ENV SENTRY_ORG=$SENTRY_ORG
ARG SENTRY_WEBAPP_PROJECT
ENV SENTRY_WEBAPP_PROJECT=$SENTRY_WEBAPP_PROJECT
ARG SENTRY_RELEASE
ENV SENTRY_RELEASE=$SENTRY_RELEASE
# SMUAT = Source Map Upload Auth Token
ARG SENTRY_SMUAT
ENV SENTRY_SMUAT=$SENTRY_SMUAT
# -----------

RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true --mount=type=bind,from=public.ecr.aws/g5f9s8a4/nora-apk:1.0.0@sha256:55df38687c301e6fefa230dc1c71a8841618214cc549ade71be740b25822a00e,target=/nora-apk \
    /nora-apk/nora-apk add --no-cache libc6-compat
WORKDIR /app

COPY package.json yarn.lock* .yarnrc.yml ./
COPY .yarn ./.yarn
COPY ./packages/web ./packages/web
COPY --from=shared-libs-builder /app/node_modules ./node_modules
COPY --from=shared-libs-builder /app/packages/db ./packages/db
COPY --from=shared-libs-builder /app/packages/schemas ./packages/schemas
COPY --from=shared-libs-builder /app/packages/shared ./packages/shared
COPY --from=shared-libs-builder /app/packages/queryLanguage ./packages/queryLanguage

# Fixes arm64 timeouts
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/web install

ENV NEXT_TELEMETRY_DISABLED=1
RUN yarn workspace @sourcebot/web build
ENV SKIP_ENV_VALIDATION=0
# ------------------------------

# ------ Build Backend ------
FROM node-alpine AS backend-builder
ENV SKIP_ENV_VALIDATION=1
# -----------

# To upload source maps to Sentry, we need to set the following build-time args.
# It's important that we don't set these for oss builds, otherwise the Sentry
# auth token will be exposed.
ARG SENTRY_ORG
ENV SENTRY_ORG=$SENTRY_ORG
ARG SENTRY_BACKEND_PROJECT
ENV SENTRY_BACKEND_PROJECT=$SENTRY_BACKEND_PROJECT
# SMUAT = Source Map Upload Auth Token
ARG SENTRY_SMUAT
ENV SENTRY_SMUAT=$SENTRY_SMUAT
ARG SENTRY_RELEASE
ENV SENTRY_RELEASE=$SENTRY_RELEASE
# -----------

WORKDIR /app

COPY package.json yarn.lock* .yarnrc.yml ./
COPY .yarn ./.yarn
COPY ./schemas ./schemas
COPY ./packages/backend ./packages/backend
COPY --from=shared-libs-builder /app/node_modules ./node_modules
COPY --from=shared-libs-builder /app/packages/db ./packages/db
COPY --from=shared-libs-builder /app/packages/schemas ./packages/schemas
COPY --from=shared-libs-builder /app/packages/shared ./packages/shared
COPY --from=shared-libs-builder /app/packages/queryLanguage ./packages/queryLanguage
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,env=YARN_NPM_AUTH_TOKEN,required=true \
    YARN_NPM_REGISTRY_SERVER=https://packages.maestra.io/npm YARN_NPM_ALWAYS_AUTH=true yarn workspace @sourcebot/backend install
RUN yarn workspace @sourcebot/backend build

# Upload source maps to Sentry if we have the necessary build-time args.
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true --mount=type=bind,from=public.ecr.aws/g5f9s8a4/nora-apk:1.0.0@sha256:55df38687c301e6fefa230dc1c71a8841618214cc549ade71be740b25822a00e,target=/nora-apk \
    if [ -n "$SENTRY_SMUAT" ] && [ -n "$SENTRY_ORG" ] && [ -n "$SENTRY_BACKEND_PROJECT" ] && [ -n "$SENTRY_RELEASE" ]; then \
    /nora-apk/nora-apk add --no-cache curl; \
    curl -sL https://sentry.io/get-cli/ | sh; \
    sentry-cli login --auth-token $SENTRY_SMUAT; \
    sentry-cli sourcemaps inject --org $SENTRY_ORG --project $SENTRY_BACKEND_PROJECT --release $SENTRY_RELEASE ./packages/backend/dist; \
    sentry-cli sourcemaps upload --org $SENTRY_ORG --project $SENTRY_BACKEND_PROJECT --release $SENTRY_RELEASE ./packages/backend/dist; \
fi

ENV SKIP_ENV_VALIDATION=0
# ------------------------------

# ------ Runner ------
FROM node-alpine AS runner
# -----------
ARG NEXT_PUBLIC_SENTRY_ENVIRONMENT
ENV NEXT_PUBLIC_SENTRY_ENVIRONMENT=$NEXT_PUBLIC_SENTRY_ENVIRONMENT
ARG NEXT_PUBLIC_SENTRY_WEBAPP_DSN
ENV NEXT_PUBLIC_SENTRY_WEBAPP_DSN=$NEXT_PUBLIC_SENTRY_WEBAPP_DSN
ARG NEXT_PUBLIC_SENTRY_BACKEND_DSN
ENV NEXT_PUBLIC_SENTRY_BACKEND_DSN=$NEXT_PUBLIC_SENTRY_BACKEND_DSN
ARG NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY
ENV NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY=$NEXT_PUBLIC_LANGFUSE_PUBLIC_KEY
ARG NEXT_PUBLIC_LANGFUSE_BASE_URL
ENV NEXT_PUBLIC_LANGFUSE_BASE_URL=$NEXT_PUBLIC_LANGFUSE_BASE_URL
ARG NEXT_PUBLIC_BUILD_COMMIT_SHA
ENV NEXT_PUBLIC_BUILD_COMMIT_SHA=$NEXT_PUBLIC_BUILD_COMMIT_SHA
# -----------

WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATA_DIR=/data
ENV DATA_CACHE_DIR=$DATA_DIR/.sourcebot
ENV DATABASE_DATA_DIR=$DATA_CACHE_DIR/db
ENV REDIS_DATA_DIR=$DATA_CACHE_DIR/redis
ENV SOURCEBOT_PUBLIC_KEY_PATH=/app/public.pem
# PAPIK = Project API Key
# Note that this key does not need to be kept secret, so it's not
# necessary to use Docker build secrets here.
# @see: https://posthog.com/tutorials/api-capture-events#authenticating-with-the-project-api-key
# @note: this is also declared in the shared env.server.ts file.
ENV POSTHOG_PAPIK=phc_lLPuFFi5LH6c94eFJcqvYVFwiJffVcV6HD8U4a1OnRW

# Valid values are: debug, info, warn, error
ENV SOURCEBOT_LOG_LEVEL=info

# Sourcebot collects anonymous usage data using [PostHog](https://posthog.com/). Uncomment this line to disable.
# ENV SOURCEBOT_TELEMETRY_DISABLED=1

# Configure dependencies. `apk upgrade` is what picks up Alpine security fixes: the release
# build has no layer cache, so a push here rebuilds against the current packages.
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true --mount=type=bind,from=public.ecr.aws/g5f9s8a4/nora-apk:1.0.0@sha256:55df38687c301e6fefa230dc1c71a8841618214cc549ade71be740b25822a00e,target=/nora-apk \
    /nora-apk/nora-apk add --no-cache git ca-certificates bind-tools tini jansson wget supervisor uuidgen curl perl jq redis postgresql16 postgresql16-contrib openssl util-linux unzip && \
    /nora-apk/nora-apk upgrade --no-cache

# Remove npm (unused — we use Yarn). The Node.js base image bundles npm
# with its own transitive dependencies (minimatch, tar, picomatch, etc.)
# that Trivy flags as vulnerable. Since npm is never invoked at runtime,
# removing it eliminates these false positives and reduces image size.
RUN rm -rf /usr/local/lib/node_modules/npm && \
    rm -rf /usr/local/bin/npm && \
    rm -rf /usr/local/bin/npx && \
    rm -rf /root/.npm && \
    rm -rf /root/.node-gyp

ARG UID=1500
ARG GID=1500

# Always create the non-root user to support runtime user switching
# The container can be run as root (default) or as sourcebot user using docker run --user
RUN addgroup -g $GID sourcebot && \
    adduser -D -u $UID -h /app -S sourcebot && \
    adduser sourcebot postgres && \
    adduser sourcebot redis && \
    chown -R sourcebot /app && \
    adduser sourcebot node && \
    mkdir /var/log/sourcebot && \
    chown sourcebot /var/log/sourcebot

COPY package.json yarn.lock* .yarnrc.yml public.pem ./
COPY .yarn ./.yarn

# Configure zoekt
COPY vendor/zoekt/install-ctags-alpine.sh .
# The vendored zoekt script calls apk itself: an `apk` shim first in PATH sends it to
# nora-apk, whose own inner `apk` call goes to the real /sbin/apk (NORA_APK_INNER).
RUN --mount=type=secret,id=PRIVATE_PACKAGES_TOKEN,required=true --mount=type=bind,from=public.ecr.aws/g5f9s8a4/nora-apk:1.0.0@sha256:55df38687c301e6fefa230dc1c71a8841618214cc549ade71be740b25822a00e,target=/nora-apk \
    mkdir /tmp/nora-shim && \
    printf '#!/bin/sh\n[ -n "${NORA_APK_INNER:-}" ] && exec /sbin/apk "$@"\nNORA_APK_INNER=1 exec /nora-apk/nora-apk "$@"\n' > /tmp/nora-shim/apk && \
    chmod 755 /tmp/nora-shim/apk && \
    PATH="/tmp/nora-shim:$PATH" ./install-ctags-alpine.sh && rm -rf install-ctags-alpine.sh /tmp/nora-shim && \
    # Clean up ctags build artifacts
    rm -rf /tmp/*
RUN mkdir -p ${DATA_CACHE_DIR}
COPY --from=zoekt-builder \
/cmd/zoekt-git-index \
/cmd/zoekt-indexserver \
/cmd/zoekt-mirror-github \
/cmd/zoekt-mirror-gitiles \
/cmd/zoekt-mirror-bitbucket-server \
/cmd/zoekt-mirror-gitlab \
/cmd/zoekt-mirror-gerrit \
/cmd/zoekt-webserver \
/cmd/zoekt-index \
/usr/local/bin/

RUN chown -R sourcebot:sourcebot /app

# Copy zoekt proto files (needed for gRPC client at runtime)
COPY --chown=sourcebot:sourcebot vendor/zoekt/grpc/protos /app/vendor/zoekt/grpc/protos

# Copy OpenAPI docs
COPY --chown=sourcebot:sourcebot docs/api-reference/sourcebot-public.openapi.json /app/docs/api-reference/sourcebot-public.openapi.json

# Copy all of the things
COPY --chown=sourcebot:sourcebot --from=web-builder /app/packages/web/public ./packages/web/public
COPY --chown=sourcebot:sourcebot --from=web-builder /app/packages/web/.next/standalone ./
COPY --chown=sourcebot:sourcebot --from=web-builder /app/packages/web/.next/static ./packages/web/.next/static

COPY --chown=sourcebot:sourcebot --from=backend-builder /app/node_modules ./node_modules
COPY --chown=sourcebot:sourcebot --from=backend-builder /app/packages/backend ./packages/backend

COPY --chown=sourcebot:sourcebot --from=shared-libs-builder /app/packages/db ./packages/db
COPY --chown=sourcebot:sourcebot --from=shared-libs-builder /app/packages/schemas ./packages/schemas
COPY --chown=sourcebot:sourcebot --from=shared-libs-builder /app/packages/shared ./packages/shared
COPY --chown=sourcebot:sourcebot --from=shared-libs-builder /app/packages/queryLanguage ./packages/queryLanguage

# Fixes git "dubious ownership" issues when the volume is mounted with different permissions to the container.
RUN git config --global safe.directory "*"

# Configure the database
RUN mkdir -p /run/postgresql && \
    chown -R postgres:postgres /run/postgresql && \
    chmod 775 /run/postgresql

# Make app directory accessible to both root and sourcebot user
RUN chown -R sourcebot /app \
	&& chgrp -R 0  /app \
	&& chmod -R g=u /app
# Make data directory accessible to both root and sourcebot user
RUN chown -R sourcebot /data

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY prefix-output.sh ./prefix-output.sh
RUN chmod +x ./prefix-output.sh
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Note: for back-compat cases, we do _not_ set the USER directive here.
# Instead, the user can be overridden at runtime with --user flag.
# USER sourcebot

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
ENTRYPOINT ["/sbin/tini", "--", "./entrypoint.sh"]
# ------------------------------