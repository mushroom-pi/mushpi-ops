# mushpi-ops — Reference (On-Demand)

Long-tail gotchas for the release/packaging layer. **Load only when the task touches these areas** — do not read on every spawn. The always-loaded [`AGENTS.md`](./AGENTS.md) holds the file map, the sibling-materialization model, verification commands, and core conventions.

Topics covered here: build-context layout · Yarn Berry 4 / Corepack · `better-sqlite3` native build · client API regeneration + `tsc` gate · entrypoint & runtime details · `release.json` in the build context · tag & CI semantics · local verify/build prerequisites · `docker-compose.override.yml` & local `.env`.

---

## Build-context layout

- The Docker build context is **this repository's root** (the `mushpi-ops` checkout). The `Dockerfile`, `docker-compose.yml`, `.dockerignore`, `.env.example`, and `.github/workflows/publish.yml` all live here; `COPY mushpi-server/...` and `COPY mushpi-client/...` reach the siblings because they are materialized **inside** this root.
- Never move the `Dockerfile`/compose back into `mushpi-server/` — the cross-repo `COPY` would no longer reach `mushpi-client/`.
- Never build with the workspace (orchestration root) as the context root. No `.dockerignore` governs that path, so the context balloons and `.env`/sibling checkouts can be swept into the upload.

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

## `release.json` in the build context

- The client-build stage bakes `__APP_RELEASE_VERSION__` into the SPA from `release.json` (the sidebar footer). Keep **both** halves: `COPY release.json /app/release.json` in the Dockerfile **and** `release.json` absent from `.dockerignore`.
- Breaking either half fails **silently** — the image still builds, but the footer shows its `dev` fallback with no build error. The two halves are coupled.

## Tag & CI semantics

- The image name derives from `${{ github.repository }}`, so renaming this repo renames the published image.
- A `vX.Y.Z` tag pins only **this repo's** files (Dockerfile, compose, CI, `release.json`). Sub-repos build at their **default-branch HEAD**, not at any ref the tag records — so sub-repo release commits (including `mushpi-mock`) must be pushed **before** the tag.
- On tag builds CI checks out all four sub-repos and runs `scripts/verify-release.sh` (the parity check), which cross-checks the manifest against each sub-repo's committed version. Grow and mock are checked out solely so that check can run; they never enter the image.

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
