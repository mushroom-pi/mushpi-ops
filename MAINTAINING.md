# Mushroom Pi — Maintaining It (Packaging & Release)

This is the maintainer-facing half: packaging internals and the release process. Operators should read `DEPLOYMENT.md` instead.

## Tooling & Packaging Facts

Ground truths from building the real image. Violating any of these breaks the build:

1. **Build context = the `mushpi-ops/` parent repo, NOT `mushpi-server/`.** The `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, and `.github/workflows/publish.yml` all live at the parent. This lets the Dockerfile `COPY` from both `mushpi-server/` and `mushpi-client/` directly — no staging/copying the client into `mushpi-server/`. Do not move these files back into `mushpi-server/`.

2. **The repos are Yarn Berry 4, not Yarn 1** (despite the client AGENTS.md once saying "Yarn 1"). They rely on Corepack to run the right Yarn, but the official `node:*` images ship Yarn 1 AND remove/disable Corepack. The Dockerfile MUST `RUN corepack enable` in every stage, AND both `package.json` files carry `"packageManager": "yarn@4.14.1"`. Without this, `yarn` resolves to Yarn 1 and `yarn workspaces focus`/`install --immutable` fail. Do NOT `npm install -g yarn@4` — Yarn 4 is not published under the `yarn` npm package (that name is Yarn 1); Yarn 2+ is Corepack-only.

3. **`better-sqlite3` needs a native toolchain in the runtime stage** (`python3 make g++`). Its install script tries `prebuild-install` then falls back to `node-gyp rebuild`, which requires a C++ compiler. Add `apt-get install -y python3 make g++` before `yarn workspaces focus`. (`server-build`/`client-build` stages don't need it — they install full dev deps where prebuilds suffice.)

4. **The client's generated API (`src/api/generated/*`) is gitignored.** The Docker client-build stage MUST regenerate it from `mushpi-server/spec/openapi.json` (`yarn gen:client && yarn gen:schemas`) and needs a JRE (`default-jre-headless`) for `openapi-generator-cli`.

5. **The client `tsc` build is a hard gate.** If the server's committed `spec/openapi.json` is missing fields (because entities lack `@ApiProperty` decorators), the regenerated client types are incomplete and `yarn build` fails. This is a SERVER contract bug, not a packaging bug — flag it, don't hack around it.

6. **Server entrypoint is `dist/src/main.js`**, not `dist/main.js` (tsc `rootDir` = project root because `docs/`/`spec/` are in the compile set). `CMD ["node", "dist/src/main.js"]`.

7. **`APP_SECRET` is optional** (LAN/Tailscale is the auth boundary) — the HEALTHCHECK does NOT send a token. `PICO_ANNOUNCE_SECRET` is still required in prod and belongs in `.env`.

8. **The published image is `ghcr.io/mushroom-pi/mushpi-ops`** — published by `publish.yml`, which derives the name from `${{ github.repository }}` and so resolves to that image. `docker-compose.yml` pulls `:latest` from it. The packaging and release machinery is planned to move into a dedicated `mushroom-pi/mushpi-ops` release repository.

9. **The orchestration repo does not vendor the sub-repos.** `mushpi-server/` and friends are independent nested git repos, ignored by the parent `.gitignore`. A `vX.Y.Z` tag pins only the orchestration files (Dockerfile, compose, CI, `release.json`); `publish.yml` checks out `mushpi-server`/`mushpi-client` at their **default-branch HEAD**, not at any ref the tag records. This is why the Release Workflow's push-order rule and manifest guard exist.

10. **The root `release.json` must stay in the Docker build context.** The `client-build` stage bakes `__APP_RELEASE_VERSION__` into the SPA from it (sidebar footer version) — keep `COPY release.json /app/release.json` AND keep `release.json` out of `.dockerignore`. Breaking either half is **silent** (deviation from this section's header): the image still builds fine, but the footer permanently shows its `dev` fallback with no build error. The two halves are coupled.

11. **Local tooling prerequisites:** `scripts/verify-release.sh` and a local `docker build` need **bash, git, and jq** (the script parses JSON with `jq`). Windows contributors should run these under **WSL**. Plain self-hosting needs none of that — just `docker compose pull` the published image (Fact 8).

## Container Networking Notes (mDNS / `.local`)

How the server reaches Pico units from inside the container. This is factual behavior of the current default-bridge setup, not a locked decision.

- **mDNS (`.local`) does not resolve inside the container.** The server polls each unit at `http://{handle}.local:{port}` first, then falls back to the announced LAN IP. In the default-bridge container (a `-slim` image with no avahi/mDNS resolver), `.local` names never resolve — Docker's embedded DNS at `127.0.0.11` does not perform mDNS lookups. The primary mDNS poll address is therefore dead in Docker.
- **Polling relies on the announced LAN IP fallback.** For the fallback to work, a unit must announce a real, routable LAN IP — which the Pico firmware does via `wlan.ifconfig()[0]`.
- **Implications:**
  - Every poll incurs a failed mDNS lookup before falling back to the IP (minor latency per unit, per 60s cycle).
  - If a unit's DHCP lease changes its IP, the stored fallback IP goes stale until the unit re-announces (on boot or WiFi reconnect). The `.local` name was meant to be the stable identity, but it is non-functional in the container — so the IP is the only live path.
- **Options if mDNS is ever desired:** `network_mode: host`, or an avahi/mDNS passthrough into the container. Neither is currently configured.

## Release Workflow — Cutting a vX.Y.Z Bundle

*How* a release is cut, tagged, and shipped. What a release version *means* and the manifest schema are normative in `mushpi-docs/versioning.md` §3 — this section documents mechanics only and never restates the semantics.

### 0. Branch & release model

`main` is shipped; `dev` is where you work. Component versions bump **only on the release commit into `main`** — never on `dev`. A release is one commit on `main` that bumps the component versions, writes `release.json`, and is tagged `vX.Y.Z`.

### 1. What a release is

A release is a **git tag `vX.Y.Z`** on the orchestration repo plus a **committed `release.json` manifest at the monorepo root**, kept in lockstep. The statement it makes — "these specific component versions are tested to work together" — and the 5-field manifest schema live in `versioning.md` §3 / §3.1; tag ⇔ manifest equality is enforced twice (subsection 4's consistency rule, via the local pre-tag check and the CI guard below).

> **CI status note:** `publish.yml` exists with a `v*` tag trigger, but the image is not published yet. Publication is gated on the release-repo split, which moves the Dockerfile, this workflow, `release.json`, `verify-release.sh`, and this document into a dedicated release repository. Until that lands, tags may be cut locally only, and the push/watch steps below are manual no-ops.

### 2. When to cut a release

Cut a release when either of these holds:

- a feature that changed the **server** and/or **client** has landed with green verification — client regenerated if the OpenAPI contract changed; or
- a **firmware** release has been tested against the current server+client pair.

Never cut with dirty trees, red verification, an un-regenerated client after a contract change, or mid-feature.

### 3. Choosing the release version

The `release` field is an **independent monotonic counter** — never derived from, and never required to exceed, any component version. Per `versioning.md` §3.2–§3.3, the components snap to the project release line at milestone cuts and drift between cuts (the current bundle: release `0.8.0` with firmware `0.8.4`). Milestone progression: `0.8.0` baseline → `0.8.x` development cuts as the remaining MVP work lands → `0.9.0` = the complete MVP set shipped to the friend (prose: the "1.0 field prototype") → `0.9.x` fixes from feedback → `0.10.x` / `0.11.x` … larger pre-1.0 changes → `1.0.0` stability graduation.

### 4. The consistency rule

The git tag and the manifest state the same version:

```
git tag  vX.Y.Z   ⇔   release.json  "release": "X.Y.Z"     (no `v` inside the JSON)
```

Enforced by the local pre-tag check (subsection 9) — and, once publishing is live, by the CI guard step in `publish.yml` (subsection 8), which fails the run before anything reaches GHCR if the tagged tree's manifest doesn't match the tag.

### 5. How the bundle maps onto the publish pipeline

*Cross-reference only — the pipeline itself is defined in `publish.yml`; don't duplicate it here.*

- On a `v*` tag push, `publish.yml` builds from **orchestration@tag** (the tag pins the Dockerfile, compose, CI workflow, and `release.json`) plus `mushpi-server` and `mushpi-client` checked out at their **default-branch HEAD** — the orchestration tag pins no sub-repo code (Tooling & Packaging Fact 9).
- Image tags derive from the git tag: `type=ref,event=tag` keeps the `v` (image tag `v0.8.0`), plus a `sha-<short>` tag; metadata-action's default `latest=auto` flavor also retags `latest` on tag pushes (the workflow's explicit `latest` line is branch-only — `enable={{is_default_branch}}` evaluates false on tag events).
- **The release version is the image-version axis.** The server's own version rides *inside* the image (`package.json` + the OpenAPI `info.version`) — it is not the image tag.
- **Firmware never enters the image** — Pico units are flashed over USB; the manifest is the only place a release records the firmware it was tested against.

### 6. Procedure

The operational form of `versioning.md` §7. All paths are relative to the monorepo root unless a directory is given.

1. **Decide the bump types** per component using `versioning.md` §2's rules — and whether the Pico↔Server contract broke (§4), which determines `api_version`.
2. **Bump the three component version fields:** firmware `_SOFTWARE_VERSION` (`mushpi-grow/app/state.py`), server `package.json` `version`, client `package.json` `version`.
3. **Regenerate the client** if the server's OpenAPI contract changed: `yarn gen:all:remote` in `mushpi-client/` (build-time lockstep, §5).
4. **Sync the mock** if the firmware bumped: `src/mushpi_mock/VERSION` and the mock's `state.py::_SOFTWARE_VERSION` to the new firmware version (§6).
5. **Verify the bundle:** in `mushpi-server/` `yarn build && yarn lint && yarn test && yarn test:e2e`; in `mushpi-client/` `yarn build && yarn lint`; optionally a mock integration run (the mock stands in for hardware — see subsection 7).
6. **Write `release.json`** at the monorepo root (schema: `versioning.md` §3.1), reading every value **live from its source of truth** — never from memory:
   - server: `jq -r .version mushpi-server/package.json`
   - client: `jq -r .version mushpi-client/package.json`
   - firmware: `grep -oP '_SOFTWARE_VERSION\s*=\s*"\K[^"]+' mushpi-grow/app/state.py`

   `release` is the version chosen in step 1. `api_version` is currently the literal `1`; when it becomes versioned it is sourced from the grow firmware/spec — **never** from the server's URI `API_VERSION`.
7. **Run the local pre-tag check** (subsection 9) — it must print `OK — cut tag vX.Y.Z`.
8. **Commit + push each remoted sub-repo** — `mushpi-server`, `mushpi-client`, `mushpi-grow` (version bumps, spec, regenerated client). `mushpi-mock` and `mushpi-docs` are local-only: commit if you like, nothing to push.
9. **Commit the orchestration repo** — `release.json` plus any orchestration changes — as *the release commit*, and tag it `vX.Y.Z` on that commit.
10. **Push the orchestration repo, then push the tag — the tag goes last.** Rationale: CI builds from the sub-repos' default-branch HEAD, not from refs the tag pins (Fact 9) — the sub-repo release commits must already be on their remotes when the tag triggers the workflow, or the CI guard (subsection 8) fails the run on a manifest-vs-code mismatch.
11. **Watch the `publish.yml` run** on the tag (once publishing is live — subsection 1's status note).
12. **Log the release** in the post-release session log: bundle version, component versions, what shipped.

### 7. Mock & bundle tests

Whenever bundle tests run, the mock's **represented** firmware version (`src/mushpi_mock/VERSION`) must equal the manifest's `firmware` entry — otherwise the mock lies about what it emulates and the test proves nothing about the bundle. The mock is **not** a manifest field and never ships (`versioning.md` §6). The mock's existing alignment check (grow `_SOFTWARE_VERSION` vs `src/mushpi_mock/VERSION`, see `mushpi-mock/AGENTS.md`) remains the guard; the pre-tag check below bakes that comparison into the release flow itself.

### 8. The CI manifest guard

`publish.yml` carries a guard step, placed after the sub-repo checkouts and before any build tooling, that fires only on `v*` tag pushes (`if: startsWith(github.ref, 'refs/tags/v')`). At CI time it enforces:

- **tag ⇔ manifest** — the pushed tag `vX.Y.Z` must equal the tagged commit's `release.json` `release` field (and the manifest must exist at that commit);
- **manifest shape** — the four SemVer strings plus an integer `api_version ≥ 1` (`versioning.md` §3.1);
- **manifest ⇔ code being built** — the manifest's `server`/`client` must equal the checked-out sub-repos' `package.json` versions; this is what catches an orchestration tag cut before the sub-repo release commits were pushed.

**What stays local:** the firmware and mock checks — `mushpi-grow` (and `mushpi-mock`) are not checked out in the CI context, so only the pre-tag check (subsection 9) can cover them.

### 9. Pre-tag check

At the monorepo root, just before tagging:

```bash
./scripts/verify-release.sh vX.Y.Z
```

It must print `OK — release X.Y.Z is consistent`. It checks the manifest shape, the tag⇔`release` equality, that no version moved backward, that `release.json` matches the committed component versions (server/client `package.json`, firmware `_SOFTWARE_VERSION`, mock `VERSION`), and that each component's spec `info.version` matches. Requires `jq`.

**Rollback** is just pinning the compose `image:` tag to the older `vX.Y.Z` image tag and `docker compose up -d`.
