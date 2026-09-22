# syntax=docker/dockerfile:1

###############################################################################
# Single-container image: mushpi-server (NestJS) + the built mushpi-client SPA.
#
# Build context = this repository root (mushroom-pi/), which contains the
# sibling sub-repos mushpi-server/ and mushpi-client/. CI checks both out here;
# self-hosters never build at all — they pull the published image.
###############################################################################

###############################################################################
# Stage 1 — Build the React client
#
# The generated API client (src/api/generated/*) is gitignored upstream, so we
# regenerate it from the server's committed spec/openapi.json before
# type-checking/bundling.
###############################################################################
FROM node:24-bookworm-slim AS client-build
WORKDIR /app

# Activate Corepack so `yarn` resolves to the project's pinned Yarn 4 (via the
# `packageManager` field), not the image's default Yarn 1 shim.
RUN corepack enable

# openapi-generator-cli (used by `yarn gen:client`) needs a JRE to run.
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install client dependencies (layer-cached on package.json/yarn.lock).
COPY mushpi-client/package.json mushpi-client/yarn.lock mushpi-client/.yarnrc.yml ./
RUN yarn install --immutable

COPY mushpi-client/ .

# Canonical OpenAPI spec (committed in mushpi-server/spec/openapi.json) →
# regenerate the gitignored API client before building.
COPY mushpi-server/spec/openapi.json ./openapi.json
# Release-bundle manifest (repo root) → baked into the SPA as __APP_RELEASE_VERSION__.
COPY release.json /app/release.json
RUN yarn gen:client && yarn gen:schemas

# Same-origin API base: the SPA calls the server on the same origin.
ARG VITE_API_BASE_URL=/
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN yarn build

###############################################################################
# Stage 2 — Build the server
###############################################################################
FROM node:24-bookworm-slim AS server-build
WORKDIR /app

# Activate Corepack (see client-build stage note).
RUN corepack enable

COPY mushpi-server/package.json mushpi-server/yarn.lock mushpi-server/.yarnrc.yml ./
RUN yarn install --immutable

# Explicitly copy source + build config. NOT `COPY mushpi-server/ .` — that
# would keep the sibling mushpi-client/ out of the compile set and shift tsc's
# rootDir (breaking the package.json import and the dist/src/main.js entrypoint).
COPY mushpi-server/nest-cli.json mushpi-server/tsconfig.json mushpi-server/tsconfig.build.json ./
COPY mushpi-server/src ./src
COPY mushpi-server/docs ./docs
COPY mushpi-server/spec ./spec
# Branding assets (Swagger UI favicon) — served by ServeStaticModule at
# /public. Added to the explicit list above (not via `COPY mushpi-server/ .`).
COPY mushpi-server/public ./public
RUN yarn build

###############################################################################
# Stage 3 — Runtime
###############################################################################
FROM node:24-bookworm-slim AS runtime
WORKDIR /usr/src/app

ENV NODE_ENV=prod

# Activate Corepack (see client-build stage note).
RUN corepack enable

# Native-compile toolchain for better-sqlite3. Its install script tries a
# prebuilt binary first but falls back to `node-gyp rebuild` (needs Python +
# a C++ compiler). Install g++ which pulls the rest, then remove apt lists to
# keep the layer lean.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# Production dependencies only (builds the better-sqlite3 native binding).
COPY mushpi-server/package.json mushpi-server/yarn.lock mushpi-server/.yarnrc.yml ./
RUN yarn workspaces focus --all --production \
    && yarn cache clean

# Compiled server output + built client SPA.
COPY --from=server-build /app/dist ./dist
COPY --from=client-build /app/dist ./client

# Branding assets — build-time COPY, NOT a volume (contrast with the /data
# uploads dir below): ServeStaticModule resolves `public` against WORKDIR,
# so it must ship in the runtime image or the assets 404.
COPY --from=server-build /app/public ./public

# ServeStaticModule requires this absolute path in prod (Joi-enforced).
ENV CLIENT_DIST_DIR=/usr/src/app/client

# Single persisted volume: SQLite DB + uploaded images + logs.
RUN mkdir -p /data/logs /data/images \
    && chown -R node:node /data

USER node
EXPOSE 3000

# Liveness probe (Node built-in fetch — no curl/wget in -slim). APP_SECRET is
# optional and unset by default, so /ping needs no Authorization header.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/ping').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/src/main.js"]
