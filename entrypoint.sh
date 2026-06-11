#!/usr/bin/env bash

set -euo pipefail

HOME_DIR="${HOME:-/home/dev}"
NETWORK_MODE="${CODEX_NETWORK_MODE:-firewall}"
ROOTFS_MODE="${CODEX_ROOTFS_MODE:-writable}"

if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  echo "[identity] no passwd entry for uid $(id -u)" >&2
  exit 1
fi

if ! getent group "$(id -g)" >/dev/null 2>&1; then
  echo "[identity] no group entry for gid $(id -g)" >&2
  exit 1
fi

if [[ "${NETWORK_MODE}" == "firewall" ]]; then
  sudo /usr/local/bin/init-firewall.sh
elif [[ "${NETWORK_MODE}" == "direct" ]]; then
  echo "[network] mode=direct; using Docker default network without container firewall" >&2
elif [[ "${NETWORK_MODE}" == "none" ]]; then
  echo "[network] mode=none; skipping firewall init because Docker network is disabled" >&2
else
  echo "[network] unsupported CODEX_NETWORK_MODE: ${NETWORK_MODE}" >&2
  exit 1
fi

echo "[filesystem] mode=${ROOTFS_MODE}" >&2

exec "$@"
