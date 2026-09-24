# Mushroom Pi — Running It (Operator Guide)

How to run the Mushroom Pi system on your own hardware: what gets deployed, and the operator procedures for SD-card provisioning, first boot, Pico setup, updates, backups, and Tailscale remote access.

> **Status: still being written.** What exists today: the "What you are deploying" summary below (complete and accurate), **Prerequisites**, **SD-card provisioning**, the stack configuration in "First boot" and the backup note in "Backup", plus the remaining procedure headings. The step-by-step procedures beyond that are placeholders — each section says so — and will be filled in as the deployment workstream lands.

This document is the operator-facing half — how to run the system. The maintainer-facing half (packaging internals and the release process) lives in `MAINTAINING.md`.

## What you are deploying

A single container that serves the React dashboard and the NestJS API on one port:

- **One image, one port, one volume.** The server serves the built client (static SPA) on port 3000; production is same-origin (CORS is dev-only, via `CLIENT_URL`).
- **Published image.** You pull `ghcr.io/mushroom-pi/mushpi` from GitHub Container Registry — you never build it, and the package is public, so the pull needs **no credentials**. You clone **this repository** (`mushpi-ops`) and run `docker compose up -d`; `docker-compose.yml` is the entry point. The local build toggle (`docker-compose.override.yml`) is untracked, so it never ships in a clone — a plain `docker compose up -d` always pulls the published image.
- **Remote access via Tailscale.** A private WireGuard-based mesh VPN. No port forwarding, no TLS certificates, no public exposure. MagicDNS gives the phone a hostname; Headscale is the documented self-host escape hatch.
- **Target hardware.** Raspberry Pi 3 (1GB) on Raspberry Pi OS Lite 64-bit, with Docker and `restart: unless-stopped` for boot persistence.
- **SD-card provisioning.** Raspberry Pi Imager (≥ 2.0.6) "OS customisation" — pre-bake the WiFi SSID/password, enable SSH, and set the hostname before first boot. No GUI desktop.

## Procedures

> To be written as part of the deployment workstream. The sections below are operator-facing and still in progress.

### Prerequisites

**Hardware and OS**

- **Raspberry Pi 3 (1GB)** or newer, running **Raspberry Pi OS Lite 64-bit**.
- **The 64-bit OS is a hard requirement, not a preference.** The published image targets `linux/arm64` (plus `linux/amd64`), so a 32-bit install cannot run it at all: `docker pull` fails with `no matching manifest for linux/arm/v7 in the manifest list entries`. The Pi 3's CPU *is* 64-bit capable, but the familiar 32-bit Raspberry Pi OS image is not — select **64-bit** in Raspberry Pi Imager (Lite; no desktop needed).
- **Memory is tight.** 1GB is enough for this stack but leaves little headroom; avoid running other services alongside it.

**Software**

- **Docker Engine with the Compose v2 plugin.** You need the `docker compose` subcommand (space), not the legacy `docker-compose` script (hyphen): `curl -fsSL https://get.docker.com | sh`.
- **Access to the Docker daemon — do not skip this.** By default only `root` can talk to the daemon, so a normal user gets `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`. Fix it with `sudo usermod -aG docker $USER`, then **log out and back in** — group membership is read at login, so an existing SSH session is not enough (`newgrp docker` covers only the current shell). Confirm with `id -nG | tr ' ' '\n' | grep -x docker`.
- **Do not work around that with `sudo docker compose …`.** This is no longer about data-directory ownership — the container entrypoint corrects the data directory's ownership on every start regardless of who created it — but running the whole stack as root remains unnecessary; fix the group membership above instead.
- **`git`**, to clone this repository on the Pi.
- That is all. **No registry login is needed** — the image is public, so `docker compose pull` runs anonymously. Do not put a GitHub token on the Pi.

**Network**

- Outbound HTTPS to `ghcr.io`, to pull the image.
- LAN access between the Pi and the Pico unit(s): the server polls each unit over the local network, and each unit announces itself to the server when it boots.
- Browsers on your LAN reach the dashboard on the Pi's port 3000. For access from outside your LAN, use Tailscale (below) rather than exposing that port.

> **If a pull fails with `unauthorized` or `denied`**, the package's visibility has been set back to private. A public package never asks for credentials, so this is the first thing to check — see the package's settings on GitHub.

### SD-card provisioning

Prepare the SD card before the Pi's first boot — bake the hostname, user, Wi-Fi, locale and SSH key in so the machine comes up headless and reachable. This is done with **Raspberry Pi Imager**, whose OS-customisation step writes the cloud-init files for you.

**The version trap — check it before you flash.**

> **Note:** Raspberry Pi OS **Trixie** (the current image, released 24 Nov 2025) moved first-boot customisation from the legacy `firstrun.sh` script to **cloud-init**. **Raspberry Pi Imager 1.9.x and earlier cannot customise a Trixie image, and fail silently** — no error, the settings are simply not applied: username, Wi-Fi, keyboard and SSH are all silently absent. Use **Imager ≥ 2.0.6** (2.0.0 has a separate write-speed defect). Check your version first via **Help → About**.

**The OS-list trap.**

> **Note:** Imager's customisation UI only appears when Raspberry Pi OS is chosen **from Imager's own OS list**. Flashing a pre-downloaded image via **"Custom image"** disables the customisation UI entirely — if you must flash a downloaded image, use the manual alternative below.

**What to set in Imager's OS Customisation:**

- **General:** hostname; username + password; Wi-Fi SSID + password **and the Wi-Fi country code** (easy to miss); locale, timezone and keyboard.
- **Services:** enable SSH with **public-key authentication only**, and paste the **contents of a `.pub` file** (one line). This becomes the `authorized_keys` entry for the created user. The private key never leaves your machine.
- Imager writes three files to the boot partition: `meta-data`, `network-config`, `user-data`.

> **Note:** A **Raspberry Pi 3 Model B is 2.4 GHz-only** — a 5 GHz-only or band-steered SSID will not be visible to it. Pick a 2.4 GHz network (or enable the 2.4 GHz band on the router) before flashing.

**Verify before first boot — the discipline that turns this from guesswork into verification.**

After writing, mount the card's FAT32 boot partition (the volume Windows and macOS show automatically; the rest is ext4) and read `user-data`. Confirm the `users:` block has the intended `name:` and an `ssh_authorized_keys:` entry beginning `ssh-ed25519` or `ssh-rsa` — **never** `-----BEGIN` (a private key pasted there is both useless and a leak). If the file is absent, nothing was customised — see the version trap above.

**Manual alternative — write the three files yourself.**

Any flasher, or a pre-downloaded image: create three files at the root of the boot partition.

`meta-data`:

```yaml
instance-id: <unique-name>
local-hostname: <hostname>
```

`user-data` — the `#cloud-config` first line is **mandatory**:

```yaml
#cloud-config
hostname: <hostname>
manage_etc_hosts: true
timezone: Europe/Madrid
locale: en_GB.UTF-8
keyboard:
  layout: gb
users:
  - name: <username>
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "<strong-password>"
    ssh_authorized_keys:
      - <public-key-line>
    sudo: ALL=(ALL) NOPASSWD:ALL
enable_ssh: true
ssh_pwauth: false
```

`network-config` (netplan v2, rendered by NetworkManager):

```yaml
network:
  version: 2
  wifis:
    renderer: NetworkManager
    wlan0:
      dhcp4: true
      regulatory-domain: "ES"
      access-points:
        "<SSID>":
          password: "<wifi-password>"
      optional: true
```

- The `rpi:` block (SPI/I2C/serial/USB-gadget) is **not needed** for this host — the Pico owns the GPIO.
- Keep the account password even with key-only SSH, or `sudo` will fail unless NOPASSWD is granted.
- Save as UTF-8 **without BOM** and with LF line endings — a BOM breaks `#cloud-config` detection.

**Secrets — these files are plaintext.**

> **Note:** These files sit on a plain FAT partition readable by any OS with no authentication, and the Wi-Fi and account passwords are **plaintext** in them. Unlike `firstrun.sh` they are not documented as self-deleting — decide deliberately whether to remove them after a successful first boot. Real values must never be committed to the repository: the examples here use placeholders only.

**Connecting afterwards — the trap that costs an hour.**

OpenSSH's client only offers keys with default names (`id_rsa`, `id_ecdsa`, `id_ed25519`, `id_dsa`) or keys already loaded in `ssh-agent`. If the authorized key has any other filename, `ssh` never offers it and the server answers `Permission denied (publickey)`. Pass the key explicitly with `-i` **plus** `-o IdentitiesOnly=yes` — best made permanent in `~/.ssh/config`:

```
Host mushpi
    HostName <hostname>.local
    User <username>
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes
```

Then:

- `sshd` returns the **same** `Permission denied (publickey)` for a nonexistent username as for a wrong key — a wrong username is indistinguishable from a wrong key.
- The first connection prints an unknown-host-key prompt — accepting it is normal; a later **changed** host key means a re-flash, cleared with `ssh-keygen -R <hostname>.local`.
- `ssh -v` shows which keys are offered (`Offering public key: …`).

**First boot — confirm the bake.**

cloud-init runs on first boot and takes about a minute — don't conclude failure early. Then confirm the settings landed:

```bash
hostname
uname -m                    # expect aarch64
cat /proc/device-tree/model
ip -brief addr
```

Changing the Wi-Fi network after the unit is running is a different procedure, covered in the user guide (`mushpi-docs/user-guide/host-wifi.md`).

### First boot

> Partially written — the stack configuration below is current; the rest of the first boot is still TODO.

Create `.env` from `.env.example`; a few optional variables shape the run:

- **Choosing the data directory.** All persistent state — the SQLite database, uploaded images and logs — lives in one host directory. Point the deployment at it by setting `MUSHPI_DATA_DIR` in `.env` (e.g. `MUSHPI_DATA_DIR=/home/pi/mushpi-data`). It may be any absolute or relative path; it defaults to `./mushpi-data` beside the compose file. Put it somewhere you back up.
- **Ownership — handled by the container.** The host directory (`MUSHPI_DATA_DIR`, default `./mushpi-data`) is created if missing and its ownership corrected automatically by the container entrypoint on every start — no manual preparation is needed for a first run. You never create the directory or its `images`/`logs` subdirectories yourself — the container does that.
- **If the container exits reporting a `chown` failure.** The automatic ownership fix needs to run `chown` inside the container, which some filesystems refuse (NFS with `root_squash` is the classic case). Only in that case — the container's own error message names it — prepare the directory on the host yourself: `sudo mkdir -p <MUSHPI_DATA_DIR> && sudo chown -R 1000:1000 <MUSHPI_DATA_DIR>`, then start the stack again. No other situation requires manual directory preparation.
- **A note on `docker exec`.** To fix ownership the image starts as root and then drops privileges, so `docker exec <container> …` now lands as root rather than the `node` user; PID 1 still runs as `node`. Use `docker exec --user node <container> …` to restore the old behaviour.
- **HTTPS vs plain HTTP.** `APP_HTTPS_ENABLED` defaults to `false`. Keep it `false` for a plain-HTTP LAN deployment (the normal Pi setup); set it to `true` only when the browser-facing deployment is actually served over HTTPS (TLS terminated in front, e.g. Tailscale or a reverse proxy). Reason: when `true` the server sends HSTS and keeps the CSP `upgrade-insecure-requests` directive — on a plain-HTTP deployment those make the browser rewrite the dashboard's own asset URLs to `https://`, which renders a blank page.
- **Rate limiting (opt-in).** By default the server applies no request throttling. To enable it, set **both** `MAX_REQUESTS` (requests per window) and `MAX_REQUESTS_TIME` (window length in milliseconds) in `.env` — uncomment the pair in `.env.example`; the recommended starting point for a LAN/Tailscale deployment is `MAX_REQUESTS=300` / `MAX_REQUESTS_TIME=60000` (≈5 requests per second per client IP). Setting only one is a configuration error and the container fails to start. When enabled, a client that exceeds the limit receives `429` responses carrying `X-RateLimit-*` headers; `/health` is always exempt, so the container health check is unaffected. Two caveats: the counters are in-memory per container (a restart resets them), and the server does not trust reverse-proxy headers — behind a proxy such as Tailscale Serve all clients share one bucket, so leave the pair unset there unless a shared budget is intended.
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
