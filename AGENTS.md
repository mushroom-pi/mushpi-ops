# mushpi-ops — Release & Packaging

This repo is the **release/packaging layer** for the Mushroom Pi system. It owns the container build, the compose service definition, the release manifest, and the publish workflow. It publishes the single image `ghcr.io/mushroom-pi/mushpi-ops` — the server API and the built React dashboard on one port.

It is **not a runtime tier** and contains no application code. The orchestration root (its sibling directory) owns the agent definitions, the full-stack architecture context, and the cross-repo contracts. The sub-repos — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock`, `mushpi-docs` — are sibling git repos, never vendored here.

On-demand gotchas for editing this layer live in [`REFERENCE.md`](./REFERENCE.md); human procedures live in [`DEPLOYMENT.md`](./DEPLOYMENT.md) (operators) and [`MAINTAINING.md`](./MAINTAINING.md) (maintainers).

## Map

| Path | What exists there |
|---|---|
| `.github/workflows/publish.yml` | CI: on push to `main` or a `v*` tag, checks out the sub-repos, runs the tag⇔manifest guard and the parity check, builds and pushes the image to GHCR |
| `Dockerfile` | Three-stage build (client → server → runtime); build context = this repo's root |
| `docker-compose.yml` | Compose service that pulls `ghcr.io/mushroom-pi/mushpi-ops:latest` |
| `docker-compose.override.yml` | Local build toggle — **untracked by design**, absent from clones |
| `.dockerignore` | Build-context exclusions |
| `.gitignore` | Ignore-all-then-allowlist; the tracked set is exactly the packaging layer |
| `.env.example` | Env template (`PICO_ANNOUNCE_SECRET` required; optional overrides) |
| `release.json` | Release manifest: `release`/`server`/`client`/`firmware` SemVer plus integer `api_version` |
| `scripts/verify-release.sh` | Release-consistency check: tag⇔manifest, manifest⇔committed component versions, spec versions |
| `DEPLOYMENT.md` | Operator guide — running the system (human register) |
| `MAINTAINING.md` | Maintainer guide — packaging and the release process (human register) |
| `README.md` | Repo entry point for self-hosters |
| `AGENTS.md` | This file — always-loaded agent core |
| `REFERENCE.md` | On-demand agent gotchas for this packaging layer |

## How a build gets its siblings

Sub-repos are **never vendored** into this repo. CI materializes them from GitHub at **default-branch HEAD**: always `mushpi-server` and `mushpi-client` (the build inputs), plus `mushpi-grow` and `mushpi-mock` on tag builds (for the parity check only — firmware never enters the image). Locally, they are transient, gitignored clones inside this repo; the clone recipe is in `REFERENCE.md`. The Dockerfile `COPY`s from `mushpi-server/` and `mushpi-client/`, so both must be present for a local build.

## Verification

Run from this repo's root:

- `docker compose -f docker-compose.yml config` — render the base compose file (client-side; no daemon).
- `docker compose config` — render with the local override (build mode).
- `docker build .` — requires the materialized siblings `mushpi-server/` and `mushpi-client/`.
- `bash scripts/verify-release.sh [vX.Y.Z]` — release-consistency check; requires the four siblings present and `jq`.
- `actionlint .github/workflows/publish.yml` — if actionlint is installed.

## Conventions

- **Never commit `.env` or `data/`.** Both are gitignored; `.env` holds local secrets and `data/` holds live runtime state (SQLite DB, uploaded images, logs).
- **The `vX.Y.Z` tag and `release.json` change in one commit.** They are an intra-repo pair; keeping them atomic is what makes the tag⇔manifest guard meaningful.
- **The image name is derived from this repo's name** (`${{ github.repository }}`). Renaming the repo renames the published image.
- **A push to `main` or a `v*` tag triggers a publish.** A tag also pins only this repo's files while sub-repos build at default-branch HEAD — push sub-repo release commits first.
- **Register split:** agent rules live here and in `REFERENCE.md`; human procedures live in `DEPLOYMENT.md` and `MAINTAINING.md`. Do not put agent-directed instructions in the human-named docs, and do not restate them here.

## ⛔ Data Deletion Prohibition

Inherited from the root `AGENTS.md`. **Never delete, modify, or destroy database data, server state, or live records without the user's explicit consent.** When the stack runs from this directory, `./data` is live state: the SQLite database, uploaded images, and logs. Investigation is read-only — never exercise destructive endpoints or queries against a running instance. This applies to every agent working in this repo.
