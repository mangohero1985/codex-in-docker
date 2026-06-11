#!/usr/bin/env bash

set -euo pipefail

REAL_CODEX_BIN="${CODEX_REAL_BIN:-/usr/local/bin/codex-real}"

if [[ "${CODEX_DISABLE_INNER_SANDBOX:-1}" == "1" ]]; then
  exec "${REAL_CODEX_BIN}" --sandbox danger-full-access "$@"
fi

exec "${REAL_CODEX_BIN}" "$@"
