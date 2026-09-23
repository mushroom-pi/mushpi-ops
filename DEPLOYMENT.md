# Mushroom Pi — Running It (Operator Guide)

How to run the Mushroom Pi system on your own hardware: what gets deployed, and the operator procedures for SD-card provisioning, first boot, Pico setup, updates, backups, and Tailscale remote access.

> **Status: still being written.** What exists today: the "What you are deploying" summary below (complete and accurate), **Prerequisites**, the stack configuration in "First boot" and the backup note in "Backup", plus the remaining procedure headings. The step-by-step procedures beyond that are placeholders — each section says so — and will be filled in as the deployment workstream lands.

This document is the operator-facing half — how to run the system. The maintainer-facing half (packaging internals and the release process) lives in `MAINTAINING.md`.

## What you are deploying

A single container that serves the React dashboard and the NestJS API on one port:

- **One image, one port, one volume.** The server serves the built client (static SPA) on port 3000; production is same-origin (CORS is dev-only, via `CLIENT_URL`).
- **Published image.** You pull `ghcr.io/mushroom-pi/mushpi` from GitHub Container Registry — you never build it, and the package is public, so the pull needs **no credentials**. You clone **this repository** (`mushpi-ops`) and run `docker compose up -d`; `docker-compose.yml` is the entry point. The local build toggle (`docker-compose.override.yml`) is untracked, so it never ships in a clone — a plain `docker compose up -d` always pulls the published image.
- **Remote access via Tailscale.** A private WireGuard-based mesh VPN. No port forwarding, no TLS certificates, no public exposure. MagicDNS gives the phone a hostname; Headscale is the documented self-host escape hatch.
- **Target hardware.** Raspberry Pi 3 (1GB) on Raspberry Pi OS Lite 64-bit, with Docker and `restart: unless-stopped` for boot persistence.
- **SD-card provisioning.** Raspberry Pi Imager "advanced options" — pre-bake the WiFi SSID/password, enable SSH, and set the hostname before first boot. No GUI desktop.

## Procedures

> To be written as part of the deployment workstream. The sections below are operator-facing and still in progress.

### Prerequisites

**Hardware and OS**

- **Raspberry Pi 3 (1GB)** or newer, running **Raspberry Pi OS Lite 64-bit**.
- **The 64-bit OS is a hard requirement, not a preference.** The published image targets `linux/arm64` (plus `linux/amd64`), so a 32-bit install cannot run it at all: `docker pull` fails with `no matching manifest for linux/arm/v7 in the manifest list entries`. The Pi 3's CPU *is* 64-bit capable, but the familiar 32-bit Raspberry Pi OS image is not — select **64-bit** in Raspberry Pi Imager (Lite; no desktop needed).
- **Memory is tight.** 1GB is enough for this stack but leaves little headroom; avoid running other services alongside it.

**Software**

- **Docker Engine with the Compose v2 plugin.** You need the `docker compose` subcommand (space), not the legacy `docker-compose` script (hyphen). `curl -fsSL https://get.docker.com | sh` installs both; then add your user to the `docker` group so you can run compose without `sudo`.
- **`git`**, to clone this repository on the Pi.
- That is all. **No registry login is needed** — the image is public, so `docker compose pull` runs anonymously. Do not put a GitHub token on the Pi.

**Network**

- Outbound HTTPS to `ghcr.io`, to pull the image.
- LAN access between the Pi and the Pico unit(s): the server polls each unit over the local network, and each unit announces itself to the server when it boots.
- Browsers on your LAN reach the dashboard on the Pi's port 3000. For access from outside your LAN, use Tailscale (below) rather than exposing that port.

> **If a pull fails with `unauthorized` or `denied`**, the package's visibility has been set back to private. A public package never asks for credentials, so this is the first thing to check — see the package's settings on GitHub.

### SD-card provisioning

> TODO — Raspberry Pi Imager advanced options (pre-bake WiFi SSID/password, enable SSH, set hostname).

### First boot

> Partially written — the stack configuration below is current; the rest of the first boot is still TODO.

Create `.env` from `.env.example`; two optional variables shape the run:

- **Choosing the data directory.** All persistent state — the SQLite database, uploaded images and logs — lives in one host directory. Point the deployment at it by setting `MUSHPI_DATA_DIR` in `.env` (e.g. `MUSHPI_DATA_DIR=/home/pi/mushpi-data`). It may be any absolute or relative path; it defaults to `./mushpi-data` beside the compose file. Put it somewhere you back up.
- **Ownership requirement.** The directory must be writable by UID 1000, because the container runs as the image's unprivileged `node` user. On Raspberry Pi OS the default `pi` user is already UID 1000, so creating the directory as yourself is normally enough.
- **First run.** You do not need to pre-create the directory — the container creates its subdirectories itself and checks writability on start. If the directory is missing, root-owned or otherwise unwritable, the container exits immediately with a message naming the directory and the fix; run `sudo chown -R 1000:1000 <MUSHPI_DATA_DIR>` and start it again.
- **Selecting a dev or pre-release image.** Set `MUSHPI_IMAGE_TAG` in `.env` to the tag you want (default `latest`), then `docker compose pull && docker compose up -d`. This is how you run a test image before a release is cut.

> **Migrating from `./data`.** If you already have a populated `./data` directory from an earlier run, the new default (`./mushpi-data`) points somewhere else, so the stack would start with an empty data directory. Either stop the stack with `docker compose down` (**do not** use `-v`), rename the folder (`mv data mushpi-data`), and start it again — or keep the old folder where it is by setting `MUSHPI_DATA_DIR=./data` in `.env`. Nothing has been released yet, so this only affects local development checkouts.

### Pico unit setup

> TODO — being written.

### Update workflow

> TODO — `docker compose pull && docker compose up -d`.

### Backup

All persistent state lives in one directory — whatever `MUSHPI_DATA_DIR` points at (default `./mushpi-data`): the database, uploaded images and logs. Backing up is copying that one directory (`cp -a` / `rsync -a`) — do it with the stack stopped so the SQLite database is not mid-write.

### Tailscale remote access

> TODO — phone + Pi setup, including MagicDNS.
