#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT=/data

for subdir in "$DATA_ROOT" "$DATA_ROOT/images" "$DATA_ROOT/logs"; do
  if ! mkdir -p "$subdir"; then
    echo "ERROR: cannot create $subdir (is $DATA_ROOT writable by UID $(id -u)?)" >&2
    exit 1
  fi
done

if [ ! -w "$DATA_ROOT" ]; then
  echo "ERROR: $DATA_ROOT is not writable by UID $(id -u)." >&2
  echo "       Create the host data directory as the same user the container runs as (UID 1000)," >&2
  echo "       or fix ownership:  sudo chown -R 1000:1000 <MUSHPI_DATA_DIR>" >&2
  exit 1
fi

exec "$@"
