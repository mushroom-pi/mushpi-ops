# Mushroom Pi — Running It (Operator Guide)

How to run the Mushroom Pi system on your own hardware: what gets deployed, and the operator procedures for SD-card provisioning, first boot, Pico setup, updates, backups, and Tailscale remote access.

> **Status: still being written.** What exists today: the "What you are deploying" summary below (complete and accurate) and the procedure section headings with their known commands. The step-by-step procedures themselves are placeholders — each section says so — and will be filled in as the deployment workstream lands.

This document is the operator-facing half — how to run the system. The maintainer-facing half (packaging internals and the release process) lives in `MAINTAINING.md`.

## What you are deploying

A single container that serves the React dashboard and the NestJS API on one port:

- **One image, one port, one volume.** The server serves the built client (static SPA) on port 3000; production is same-origin (CORS is dev-only, via `CLIENT_URL`).
- **Published image.** You pull `ghcr.io/mushroom-pi/mushpi` from GitHub Container Registry — you never build it. You clone **this repository** (`mushpi-ops`) and run `docker compose up -d`; `docker-compose.yml` is the entry point. The local build toggle (`docker-compose.override.yml`) is untracked, so it never ships in a clone — a plain `docker compose up -d` always pulls the published image.
- **Remote access via Tailscale.** A private WireGuard-based mesh VPN. No port forwarding, no TLS certificates, no public exposure. MagicDNS gives the phone a hostname; Headscale is the documented self-host escape hatch.
- **Target hardware.** Raspberry Pi 3 (1GB) on Raspberry Pi OS Lite 64-bit, with Docker and `restart: unless-stopped` for boot persistence.
- **SD-card provisioning.** Raspberry Pi Imager "advanced options" — pre-bake the WiFi SSID/password, enable SSH, and set the hostname before first boot. No GUI desktop.

## Procedures

> To be written as part of the deployment workstream. The sections below are operator-facing and still in progress.

### Prerequisites

> TODO — being written.

### SD-card provisioning

> TODO — Raspberry Pi Imager advanced options (pre-bake WiFi SSID/password, enable SSH, set hostname).

### First boot

> TODO — being written.

### Pico unit setup

> TODO — being written.

### Update workflow

> TODO — `docker compose pull && docker compose up -d`.

### Backup

> TODO — rolling SQLite copies.

### Tailscale remote access

> TODO — phone + Pi setup, including MagicDNS.
