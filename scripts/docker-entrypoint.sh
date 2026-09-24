#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT=/data
UID_NOW=$(id -u)
GID_NOW=$(id -g)
APP_USER=node
APP_GROUP=node
APP_UID=1000
APP_GID=1000
SETPRIV=/usr/bin/setpriv

fail() {
  echo "ERROR: $1" >&2
  shift
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

remedy_nonroot() {
  echo "Fix it on the HOST, then restart the container:" >&2
  echo "    sudo chown -R ${UID_NOW}:${GID_NOW} <MUSHPI_DATA_DIR>" >&2
  echo "(The host directory is whatever MUSHPI_DATA_DIR points at, default ./mushpi-data" >&2
  echo "beside the compose file. The Docker daemon creates a missing bind-mount source" >&2
  echo "directory as root, which this container cannot write into.)" >&2
}

ensure_dirs_writable_nonroot() {
  for subdir in "$DATA_ROOT" "$DATA_ROOT/images" "$DATA_ROOT/logs"; do
    if ! mkdir -p "$subdir" 2>/dev/null; then
      echo "ERROR: cannot create $subdir — $DATA_ROOT is not writable by UID $UID_NOW." >&2
      remedy_nonroot
      exit 1
    fi
  done

  if [ ! -w "$DATA_ROOT" ]; then
    echo "ERROR: $DATA_ROOT is not writable by UID $UID_NOW." >&2
    remedy_nonroot
    exit 1
  fi
}

if [ "$UID_NOW" -eq 0 ]; then
  for subdir in "$DATA_ROOT" "$DATA_ROOT/images" "$DATA_ROOT/logs"; do
    if ! mkdir -p "$subdir"; then
      fail "cannot create $subdir as root." \
           "The bind-mounted filesystem may be read-only or the path may be invalid."
    fi

    if [ "$(stat -c '%u:%g' "$subdir")" != "${APP_UID}:${APP_GID}" ]; then
      if ! chown -R "${APP_USER}:${APP_GROUP}" "$subdir"; then
        fail "cannot chown $subdir to ${APP_USER}:${APP_GROUP}." \
             "This usually means the filesystem maps root to an unprivileged user" \
             "(NFS root_squash) or does not allow chown. Pre-create the directory" \
             "on the host as UID ${APP_UID} / GID ${APP_GID} and restart:" \
             "    sudo mkdir -p <MUSHPI_DATA_DIR>" \
             "    sudo chown -R ${APP_UID}:${APP_GID} <MUSHPI_DATA_DIR>"
      fi
    fi
  done

  if ! "$SETPRIV" --reuid="$APP_USER" --regid="$APP_GROUP" --clear-groups -- test -w "$DATA_ROOT"; then
    fail "$DATA_ROOT is not writable by ${APP_USER} (UID ${APP_UID})." \
         "The directory could not be made writable for the application user." \
         "Pre-create it on the host as UID ${APP_UID} / GID ${APP_GID} and restart:" \
         "    sudo mkdir -p <MUSHPI_DATA_DIR>" \
         "    sudo chown -R ${APP_UID}:${APP_GID} <MUSHPI_DATA_DIR>"
  fi

  exec "$SETPRIV" --reuid="$APP_USER" --regid="$APP_GROUP" --clear-groups -- "$@"
else
  ensure_dirs_writable_nonroot
  exec "$@"
fi
