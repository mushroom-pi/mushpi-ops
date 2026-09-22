# Mushroom Pi — Maintaining It (Packaging & Release)

This is the maintainer-facing half: packaging internals and the release process. Operators should read `DEPLOYMENT.md` instead. This document describes what happens; the agent-facing rules for editing the machinery here live in `REFERENCE.md`.

## How the image is built

The image is built by `Dockerfile` from this repository's root as its Docker context. CI checks out the two build inputs — `mushpi-server` and `mushpi-client` — into that root and builds there; on a `v*` tag it also checks out `mushpi-grow` and `mushpi-mock` so the bundle-parity check can run. Firmware never enters the image; the manifest records what the bundle was tested against. The result is pushed to `ghcr.io/mushroom-pi/mushpi-ops`, a name derived from `github.repository`. Locally, the siblings are materialized as transient clones inside this repo; the recipe and the packaging guardrails are in `REFERENCE.md`.

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

`main` is shipped; `dev` is where you work. The release is now multi-repo: each component's version bump lands as a release commit in that component repo's `main` (`mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` for the parity record), while the manifest commit — `release.json` in this repo — plus the `vX.Y.Z` tag land on **this repo's** `main`. Component versions bump only on those release commits, never on `dev`.

### 1. What a release is

A release is a **git tag `vX.Y.Z`** on this repo (`mushpi-ops`) plus a **committed `release.json` manifest at this repo's root**, kept in lockstep. The statement it makes — "these specific component versions are tested to work together" — and the 5-field manifest schema live in `versioning.md` §3 / §3.1; tag ⇔ manifest equality is enforced twice (subsection 4's consistency rule, via the local pre-tag check and the CI manifest guard below).

> **CI status note:** `publish.yml` lives in this repo and triggers on pushes to `main` and on `v*` tags. The first published image comes from this repo's first `v*` tag cut after the release-repo split lands; before that there are no published image tags to watch.

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

Enforced by the local pre-tag check (subsection 9) — and, once publishing is live, by the CI manifest guard step in `publish.yml` (subsection 8), which fails the run before anything reaches GHCR if the tagged tree's manifest doesn't match the tag.

### 5. How the bundle maps onto the publish pipeline

*Cross-reference only — the pipeline itself is defined in `publish.yml`; don't duplicate it here.*

- On a `v*` tag push, `publish.yml` builds from **this repo@tag** (the tag pins the Dockerfile, compose, CI workflow, and `release.json`) plus `mushpi-server` and `mushpi-client` checked out at their **default-branch HEAD** — the tag pins no sub-repo code (`REFERENCE.md` → Tag & CI semantics). On tag builds the workflow also checks out `mushpi-grow` and `mushpi-mock` and runs the bundle-parity check.
- Image tags derive from the git tag: `type=ref,event=tag` keeps the `v` (image tag `v0.8.0`), plus a `sha-<short>` tag; metadata-action's default `latest=auto` flavor also retags `latest` on tag pushes (the workflow's explicit `latest` line is branch-only — `enable={{is_default_branch}}` evaluates false on tag events).
- **The release version is the image-version axis.** The server's own version rides *inside* the image (`package.json` + the OpenAPI `info.version`) — it is not the image tag.
- **Firmware never enters the image** — Pico units are flashed over USB; the manifest is the only place a release records the firmware it was tested against.

### 6. Procedure

The operational form of `versioning.md` §7. All paths are relative to this repo's root unless a directory is given.

1. **Decide the bump types** per component using `versioning.md` §2's rules — and whether the Pico↔Server contract broke (§4), which determines `api_version`.
2. **Bump the three component version fields:** firmware `_SOFTWARE_VERSION` (`mushpi-grow/app/state.py`), server `package.json` `version`, client `package.json` `version`.
3. **Regenerate the client** if the server's OpenAPI contract changed: `yarn gen:all:remote` in `mushpi-client/` (build-time lockstep, §5).
4. **Sync the mock** if the firmware bumped: `src/mushpi_mock/VERSION` and the mock's `state.py::_SOFTWARE_VERSION` to the new firmware version (§6).
5. **Verify the bundle:** in `mushpi-server/` `yarn build && yarn lint && yarn test && yarn test:e2e`; in `mushpi-client/` `yarn build && yarn lint`; optionally a mock integration run (the mock stands in for hardware — see subsection 7).
6. **Write `release.json`** in this repo (schema: `versioning.md` §3.1), reading every value **live from its source of truth** — never from memory:
   - server: `jq -r .version mushpi-server/package.json`
   - client: `jq -r .version mushpi-client/package.json`
   - firmware: `grep -oP '_SOFTWARE_VERSION\s*=\s*"\K[^"]+' mushpi-grow/app/state.py`

   `release` is the version chosen in step 1. `api_version` is currently the literal `1`; when it becomes versioned it is sourced from the grow firmware/spec — **never** from the server's URI `API_VERSION`.
7. **Materialize the four sub-repos** as transient clones inside this repo — `mushpi-server`, `mushpi-client`, `mushpi-grow`, `mushpi-mock` (they are gitignored; recipe in `REFERENCE.md`).
8. **Run the local pre-tag check** (subsection 9) — it must print `OK — release X.Y.Z is consistent`.
9. **Commit + push each remoted sub-repo** — `mushpi-server`, `mushpi-client`, `mushpi-grow`, and `mushpi-mock` (version bumps, spec, regenerated client). The mock is now checked out by CI for the parity check, so its release commit must be pushed too. Only `mushpi-docs` remains local-only: commit if you like, nothing to push.
10. **Commit this repo** — `release.json` plus any changes here — as *the release commit*, and tag it `vX.Y.Z` on that commit.
11. **Push this repo, then push the tag — the tag goes last.** Rationale: CI builds from the sub-repos' default-branch HEAD, not from refs the tag pins (`REFERENCE.md` → Tag & CI semantics) — the sub-repo release commits must already be on their remotes when the tag triggers the workflow, or the CI guard (subsection 8) fails the run on a manifest-vs-code mismatch.
12. **Watch the `publish.yml` run** on the tag (once publishing is live — subsection 1's status note).
13. **Log the release** in the post-release session log: bundle version, component versions, what shipped.

### 7. Mock & bundle tests

Whenever bundle tests run, the mock's **represented** firmware version (`src/mushpi_mock/VERSION`) must equal the manifest's `firmware` entry — otherwise the mock lies about what it emulates and the test proves nothing about the bundle. The mock is **not** a manifest field and never ships (`versioning.md` §6). The mock's existing alignment check (grow `_SOFTWARE_VERSION` vs `src/mushpi_mock/VERSION`, see `mushpi-mock/AGENTS.md`) remains the guard; the pre-tag check below bakes that comparison into the release flow itself.

### 8. The CI guards

`publish.yml` carries two steps, both placed after the sub-repo checkouts and before any build tooling, that fire only on `v*` tag pushes (`if: startsWith(github.ref, 'refs/tags/v')`):

The **manifest guard** enforces:

- **tag ⇔ manifest** — the pushed tag `vX.Y.Z` must equal the tagged commit's `release.json` `release` field (and the manifest must exist at that commit);
- **manifest shape** — the four SemVer strings plus an integer `api_version ≥ 1` (`versioning.md` §3.1);
- **manifest ⇔ code being built** — the manifest's `server`/`client` must equal the checked-out sub-repos' `package.json` versions; this is what catches a tag cut before the sub-repo release commits were pushed.

The **bundle-parity step** then runs `scripts/verify-release.sh "${GITHUB_REF_NAME}"`, cross-checking the manifest against every committed component version — server/client `package.json`, firmware `_SOFTWARE_VERSION` and the grow spec's `info.version`, and the mock's `VERSION`. This is why the grow and mock checkouts exist.

**What stays local:** the monotonicity check — that no version moved backward relative to `main:release.json`. CI checks out a single ref, so `main` is not available there and the script skips that comparison; the pre-tag check (subsection 9) covers it.

### 9. Pre-tag check

At this repo's root, with the four siblings materialized, just before tagging:

```bash
./scripts/verify-release.sh vX.Y.Z
```

It must print `OK — release X.Y.Z is consistent`. It checks the manifest shape, the tag⇔`release` equality, that no version moved backward, that `release.json` matches the committed component versions (server/client `package.json`, firmware `_SOFTWARE_VERSION`, mock `VERSION`), and that each component's spec `info.version` matches. Requires `jq`.

**Rollback** is just pinning the compose `image:` tag to the older `vX.Y.Z` image tag and `docker compose up -d`.
