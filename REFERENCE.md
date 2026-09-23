# mushpi-ops — Reference (On-Demand)

Long-tail gotchas for the release/packaging layer. **Load only when the task touches these areas** — do not read on every spawn. The always-loaded [`AGENTS.md`](./AGENTS.md) holds the file map, the sibling-materialization model, verification commands, and core conventions.

Topics covered here: build-context layout · Yarn Berry 4 / Corepack · `better-sqlite3` native build · client API regeneration + `tsc` gate · entrypoint & runtime details · `release.json` in the build context · tag & CI semantics · dev / pre-release image builds · shared build action · local verify/build prerequisites · `docker-compose.override.yml` & local `.env`.

---

## Build-context layout

- The Docker build context is **this repository's root** (the `mushpi-ops` checkout). The `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, and `.github/workflows/publish.yml` all live here; `COPY mushpi-server/...` and `COPY mushpi-client/...` reach the siblings because they are materialized **inside** this root.
- Never move the `Dockerfile`/compose back into `mushpi-server/` — the cross-repo `COPY` would no longer reach `mushpi-client/`.
- Never build with the workspace (orchestration root) as the context root. No `.dockerignore` governs that path, so the context balloons and `.env`/sibling checkouts can be swept into the upload.
- **`.dockerignore` has load-bearing entries — never "clean it up" by pattern.** `mushpi-server/` and `mushpi-client/` are the build inputs (`COPY`ed by the Dockerfile) and must **never** be listed there; `release.json` must stay un-ignored. Only the never-built repos (`mushpi-grow`, `mushpi-mock`, `mushpi-docs`) and live state (`data`, `data-test`, `mushpi-data`) belong in that file. To check a change, extract every `COPY`/`ADD` source from the `Dockerfile` and confirm it is not matched — note `git check-ignore` reads `.gitignore`, **not** `.dockerignore`, so it is the wrong tool for this and gives misleading hits (the sibling clones are gitignored by design).

## Yarn Berry 4 / Corepack

- The sub-repos are Yarn Berry 4, not Yarn 1. They pin Yarn via `"packageManager": "yarn@4.14.1"` in each `package.json` and rely on Corepack to run the pinned release. The official `node:*` images ship Yarn 1 **and** remove/disable Corepack, so the Dockerfile must `RUN corepack enable` in **every** stage.
- Never `npm install -g yarn@4`. The `yarn` npm package is Yarn 1; Yarn 2+ is Corepack-only. Without Corepack, `yarn workspaces focus` and `yarn install --immutable` fail.

## `better-sqlite3` native build

- Needs `python3 make g++` in the **runtime** stage only, installed before `yarn workspaces focus --all --production`. Its install script tries a prebuilt binary, then falls back to `node-gyp rebuild`, which needs Python and a C++ compiler.
- The `client-build`/`server-build` stages do **not** need the toolchain — they install full dev dependencies, where prebuilds suffice.

## Client API regeneration + the `tsc` gate

- `mushpi-client/src/api/generated/*` is gitignored, so the client-build stage regenerates it from the committed `mushpi-server/spec/openapi.json` (`yarn gen:client && yarn gen:schemas`). `openapi-generator-cli` needs a JRE (`default-jre-headless`).
- The client's `yarn build` (`tsc`) is a hard gate. If the server's committed spec is missing fields (entities lacking `@ApiProperty`), the regenerated types are incomplete and the build fails. That is a **server contract bug — flag it, don't hack around it**.

## Entrypoint & runtime details

- The server entrypoint is `dist/src/main.js`, not `dist/main.js` — tsc's `rootDir` is the project root because `docs/` and `spec/` are in the compile set. `CMD ["node", "dist/src/main.js"]`.
- `APP_SECRET` is optional (LAN/Tailscale is the auth boundary), which is why the HEALTHCHECK sends no Authorization header.
- `PICO_ANNOUNCE_SECRET` is required in production and belongs in `.env`.

### Entrypoint & data directory

- The runtime `ENTRYPOINT` is `scripts/docker-entrypoint.sh`: it `mkdir -p`s `/data` plus its `images`/`logs` subdirs, then requires `/data` to be writable by the running UID (1000 — the `node` user, matching Raspberry Pi OS's default `pi` user), and finally `exec "$@"`. It runs as `node` — never root, never chowns.
- An unwritable or root-owned host directory (the bind-mounted `MUSHPI_DATA_DIR`, default `./mushpi-data`) makes the container exit 1 with an operator-readable hint: `sudo chown -R 1000:1000 <MUSHPI_DATA_DIR>`.
- No-volume fallback: run the image with no `/data` mount and the tree baked into the image (created and owned in the runtime stage) still passes the check — `docker run ghcr.io/mushroom-pi/mushpi` boots fine for smoke tests; data just doesn't persist.
- An override command passed to `docker run` (e.g. `docker run … bash`) is still guarded: the entrypoint checks first, then `exec`s it.

## `release.json` in the build context

- The client-build stage bakes `__APP_RELEASE_VERSION__` into the SPA from `release.json` (the sidebar footer). Keep **both** halves: `COPY release.json /app/release.json` in the Dockerfile **and** `release.json` absent from `.dockerignore`.
- Breaking either half fails **silently** — the image still builds, but the footer shows its `dev` fallback with no build error. The two halves are coupled.

## Tag & CI semantics

- **Neither publish workflow has ever actually executed.** No `v*` tag has been cut and `release.json` is still pre-1.0, so `publish.yml` has never run and `publish-dev.yml` is brand new. CI edits are therefore **unverified until a real run**: a wrong action owner (`actions/setup-qemu-action` instead of `docker/setup-qemu-action`) sat undetected in `publish.yml` from the day it was written. Verify every `uses:` owner against the registry (`git ls-remote --tags https://github.com/<owner>/<repo> refs/tags/<tag>`) rather than trusting the file's own history, and remember `actionlint` cannot lint composite actions.

- The image name is `ghcr.io/${{ github.repository_owner }}/mushpi`, deliberately decoupled from this repo's name. Renaming this repo does **not** rename the published image; changing the image name is a deliberate product decision, not a side effect of a repo rename.
- A `vX.Y.Z` tag pins only **this repo's** files (Dockerfile, compose, CI, `release.json`). Sub-repos build at their **default-branch HEAD**, not at any ref the tag records — so sub-repo release commits (including `mushpi-mock`) must be pushed **before** the tag.
- On tag builds CI checks out all four sub-repos and runs `scripts/verify-release.sh` (the parity check), which cross-checks the manifest against each sub-repo's committed version. Grow and mock are checked out solely so that check can run; they never enter the image.
- **`latest` is emitted by two independent mechanisms — changing one and not the other surprises you.** `publish.yml` passes metadata-action `flavor: latest=auto` (the action's default; it now travels through the shared composite action), which generates `latest` for tag-type rules — so a `v*` tag push moves `latest` on its own. The workflow's explicit `type=raw,value=latest` rule covers pushes to `main`, and its condition is bound **by ref** (`github.ref == 'refs/heads/main'`) rather than to the repository's default-branch setting — so which branch is the default cannot enable or disable it.

## Dev / pre-release image builds

- `publish-dev.yml` is `workflow_dispatch`-only. Inputs: `ops_ref` (default `main`), `server_ref`/`client_ref` (blank = that repo's default branch), a required free-form `image_tag`, and `push` (default true; false = build without pushing — multi-platform cannot `load`, so nothing is exported).
- Tag rules: `latest` and a strict `vX.Y.Z` (or `X.Y.Z`) are rejected so a dev run can never be mistaken for a release; pre-release forms (`0.9.0-rc1`) pass. Every build also gets `dev-sha-<short>` (metadata-action concatenates `prefix=dev-sha-` with the 7-char SHA verbatim). `flavor: latest=false` guarantees `latest` is never emitted.
- The release-manifest guard and `scripts/verify-release.sh` are deliberately skipped — a dev build is not a bundle release.
- Run a dev image on the Pi: set `MUSHPI_IMAGE_TAG=<tag>` in `.env`, then `docker compose pull && docker compose up -d`.
- Pre-release convention: an `0.9.0-rc1` image is a test candidate only; the actual release is cut by the `v0.9.0` git tag plus the `release.json` bump through `publish.yml`. Never retag an rc image as the release — rebuild on the tag.
- Cleanup of dev tags is **manual only** (no scheduled workflow, no retention policy): delete stale versions in the GHCR package UI or API.

## Shared build action (`.github/actions/build-image`)

- The composite action is **deliberately dumb**: toolchain setup, login, metadata, build/push only. **Callers own triggers, guards and tag policy** — each workflow passes its own `registry`/`image_name` (from its `env`), `token`, `push`, `flavor` and `tags`. That explicit local policy is what guarantees a dev build cannot move `latest`. **Never add a `mode: release|dev` input, or any ref/branch logic, to the action.**
- `flavor` and `tags` are **required** inputs. `publish.yml` passes `latest=auto` (metadata-action's default; a `v*` tag push moves `latest`), `publish-dev.yml` passes `latest=false`.
- Composite actions cannot reliably read the `secrets` context — the token arrives as the `token` input (`token: ${{ secrets.GITHUB_TOKEN }}` from each caller; both keep `packages: write`). `push` is a string: the action compares `inputs.push == 'true'`.
- `.gitignore` allowlists `.github/actions/**` explicitly (mirroring `!.github/workflows/**`). A new file under `.github/actions/` that falls outside that pattern is silently uncommittable, which breaks both workflows in CI.
- actionlint lints the two workflows but **not** the action file — it parses explicit file arguments as workflows (rhysd/actionlint#401).

## Local verify/build prerequisites

- `scripts/verify-release.sh` and a local `docker build` need **bash, git, and jq** (the script parses JSON with `jq`), plus GNU `grep`/`sort`. Windows contributors run under **WSL**.
- Materialize the four siblings as transient clones **inside this repo** (they are gitignored — never vendored):
  ```bash
  for r in mushpi-server mushpi-client mushpi-grow mushpi-mock; do
    git clone https://github.com/mushroom-pi/$r.git
  done
  ```
  A local verify can instead clone from working trees. Plain self-hosting needs none of this.

## `docker-compose.override.yml` & local `.env`

- `docker-compose.override.yml` is untracked by design: it switches compose from pulling the published image to building locally. Self-hosters' clones never contain it.
- Copy `.env.example` → `.env` before a local `docker compose up`. `.env` is gitignored and never committed.
