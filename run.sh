#!/usr/bin/env bash

set -euo pipefail

IMAGE="codex-in-docker:local"
HOME_IN_CONTAINER="/home/dev"
WORKSPACE_ROOT_IN_CONTAINER="${HOME_IN_CONTAINER}/workspace"
WORKSPACE_IN_CONTAINER="${WORKSPACE_ROOT_IN_CONTAINER}/current"
EXTRA_WORKSPACES_IN_CONTAINER="${WORKSPACE_ROOT_IN_CONTAINER}/_mounts"
CODEX_HOME_IN_CONTAINER="${HOME_IN_CONTAINER}/.codex"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd -P)"
NETWORK_MODE="${CODEX_NETWORK_MODE:-none}"
ROOTFS_MODE="${CODEX_ROOTFS_MODE:-readonly}"
MCP_OAUTH_CALLBACK_PORT="${CODEX_MCP_OAUTH_CALLBACK_PORT:-}"
RUNTIME_STATE_DIR="${SCRIPT_DIR}/.tmp/runtime"
PASSWD_FILE="${RUNTIME_STATE_DIR}/passwd"
GROUP_FILE="${RUNTIME_STATE_DIR}/group"
PROJECT_HASH_INPUT="${PROJECT_DIR}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
PRINT_CODEX_HOME_VOLUME=false
DOCKER_COMMAND_ARGS=()
EXTRA_MOUNT_MODES=()
EXTRA_MOUNT_NAMES=()
EXTRA_MOUNT_DIRS=()
EXTRA_MOUNT_TARGETS=()
ALLOWED_PASSTHROUGH_ENVS=(
  CODEX_ACCESS_TOKEN
  CODEX_API_KEY
  CODEX_CA_CERTIFICATE
)
PROJECT_ENV_FILE_NAME=".codex.env"
GLOBAL_ENV_FILE="${SCRIPT_DIR}/.codex.env"
PROJECT_ALLOWED_ENV_KEYS=(
  OPENAI_API_KEY
)
HOST_CODEX_DIR="${HOME}/.codex"
HOST_CODEX_IMPORT_ITEMS=(
  config.toml
  prompts
  rules
  skills
)
SENSITIVE_HOST_PATHS=(
  "${HOME}/.ssh"
  "${HOME}/.aws"
  "${HOME}/.azure"
  "${HOME}/.config/gcloud"
  "${HOME}/.config/gh"
  "${HOME}/.docker"
  "${HOME}/.gnupg"
  "${HOME}/.kube"
  "${HOME}/Library/Keychains"
  "/run"
  "/var/run"
)
SENSITIVE_HOST_ENVS=(
  SSH_AUTH_SOCK
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  AWS_PROFILE
  GITHUB_TOKEN
  GH_TOKEN
  GOOGLE_APPLICATION_CREDENTIALS
  AZURE_CLIENT_SECRET
  AZURE_TENANT_ID
  AZURE_CLIENT_ID
  KUBECONFIG
  DOCKER_HOST
  DOCKER_CERT_PATH
  GNUPGHOME
)

canonicalize_dir() {
  local path="$1"
  [[ -d "${path}" ]] || return 1
  (cd "${path}" && pwd -P)
}

assert_safe_mount_dir() {
  local mount_dir="$1"
  local sensitive
  local resolved_sensitive

  for sensitive in "${SENSITIVE_HOST_PATHS[@]}"; do
    if ! resolved_sensitive="$(canonicalize_dir "${sensitive}")"; then
      continue
    fi

    case "${mount_dir}" in
      "${resolved_sensitive}"|"${resolved_sensitive}"/*)
        cat >&2 <<EOF
[security] refusing to mount sensitive host path: ${mount_dir}
[security] blocked because it is inside: ${resolved_sensitive}
[security] clone the repository into a dedicated workspace directory and run codex-in-docker from there.
EOF
        exit 1
        ;;
    esac
  done
}

sanitize_mount_name() {
  local raw_name="$1"
  local safe_name

  safe_name="$(printf '%s' "${raw_name}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')"
  safe_name="$(printf '%s' "${safe_name}" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  printf '%s' "${safe_name}"
}

path_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-10
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-10
  fi
}

register_extra_mount() {
  local mode="$1"
  local spec="$2"
  local mount_dir=""
  local requested_name=""
  local safe_name
  local target_path
  local existing_name
  local i

  if mount_dir="$(canonicalize_dir "${spec}")"; then
    requested_name="$(basename "${mount_dir}")"
  elif [[ "${spec}" =~ ^(.+):([A-Za-z0-9._-]+)$ ]] && mount_dir="$(canonicalize_dir "${BASH_REMATCH[1]}")"; then
    requested_name="${BASH_REMATCH[2]}"
  else
    echo "unsupported mount path: ${spec}" >&2
    echo "expected an existing directory, optionally with :name suffix" >&2
    exit 1
  fi

  safe_name="$(sanitize_mount_name "${requested_name}")"
  if [[ -z "${safe_name}" ]]; then
    echo "unsupported mount name in spec: ${spec}" >&2
    exit 1
  fi

  if [[ "${safe_name}" == "$(basename "${WORKSPACE_IN_CONTAINER}")" ]]; then
    safe_name="${safe_name}-$(path_hash "${mount_dir}")"
  fi

  for ((i=0; i<${#EXTRA_MOUNT_NAMES[@]}; i++)); do
    existing_name="${EXTRA_MOUNT_NAMES[i]}"
    if [[ "${mount_dir}" == "${EXTRA_MOUNT_DIRS[i]}" ]]; then
      echo "duplicate mount path requested: ${mount_dir}" >&2
      exit 1
    fi
    if [[ "${safe_name}" == "${existing_name}" ]]; then
      safe_name="${safe_name}-$(path_hash "${mount_dir}")"
      break
    fi
  done

  target_path="${EXTRA_WORKSPACES_IN_CONTAINER}/${safe_name}"
  EXTRA_MOUNT_MODES+=("${mode}")
  EXTRA_MOUNT_NAMES+=("${safe_name}")
  EXTRA_MOUNT_DIRS+=("${mount_dir}")
  EXTRA_MOUNT_TARGETS+=("${target_path}")
}

parse_launcher_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --print-codex-home-volume)
        PRINT_CODEX_HOME_VOLUME=true
        shift
        ;;
      --mount)
        [[ "$#" -ge 2 ]] || {
          echo "--mount requires a path argument" >&2
          exit 1
        }
        register_extra_mount "rw" "$2"
        shift 2
        ;;
      --mount=*)
        register_extra_mount "rw" "${1#--mount=}"
        shift
        ;;
      --mount-ro)
        [[ "$#" -ge 2 ]] || {
          echo "--mount-ro requires a path argument" >&2
          exit 1
        }
        register_extra_mount "ro" "$2"
        shift 2
        ;;
      --mount-ro=*)
        register_extra_mount "ro" "${1#--mount-ro=}"
        shift
        ;;
      --)
        shift
        DOCKER_COMMAND_ARGS+=("$@")
        break
        ;;
      *)
        DOCKER_COMMAND_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

parse_launcher_args "$@"
if [[ "${#DOCKER_COMMAND_ARGS[@]}" -gt 0 ]]; then
  set -- "${DOCKER_COMMAND_ARGS[@]}"
else
  set --
fi

warn_ignored_sensitive_host_envs() {
  local env_name
  local warned=()

  for env_name in "${SENSITIVE_HOST_ENVS[@]}"; do
    if [[ -n "${!env_name:-}" ]]; then
      warned+=("${env_name}")
    fi
  done

  if [[ "${#warned[@]}" -gt 0 ]]; then
    printf '[security] host secret env vars detected but not forwarded: %s\n' "${warned[*]}" >&2
    echo "[security] only explicit Codex auth env vars are passed through to the container." >&2
  fi
}

load_env_file() {
  local env_file="$1"
  local line
  local key
  local value
  local allowed=false

  [[ -f "${env_file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"

    if [[ -z "${line//[[:space:]]/}" ]]; then
      continue
    fi

    if [[ "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if [[ ! "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "[env] unsupported line in ${env_file}: ${line}" >&2
      exit 1
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    allowed=false

    for allowed_key in "${PROJECT_ALLOWED_ENV_KEYS[@]}"; do
      if [[ "${key}" == "${allowed_key}" ]]; then
        allowed=true
        break
      fi
    done

    if [[ "${allowed}" != true ]]; then
      echo "[env] unsupported key in ${env_file}: ${key}" >&2
      exit 1
    fi

    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    DOCKER_ENV_ARGS+=(--env "${key}=${value}")
  done < "${env_file}"
}

load_project_env_file() {
  load_env_file "${PROJECT_DIR}/${PROJECT_ENV_FILE_NAME}"
}

load_global_env_file() {
  load_env_file "${GLOBAL_ENV_FILE}"
}

prepare_host_codex_seed_dir() {
  local seed_dir="${RUNTIME_STATE_DIR}/host-codex-seed"
  local item

  rm -rf "${seed_dir}"
  mkdir -p "${seed_dir}"

  [[ -d "${HOST_CODEX_DIR}" ]] || return 0

  for item in "${HOST_CODEX_IMPORT_ITEMS[@]}"; do
    if [[ -e "${HOST_CODEX_DIR}/${item}" ]]; then
      cp -R "${HOST_CODEX_DIR}/${item}" "${seed_dir}/${item}"
    fi
  done
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

compute_seed_dir_hash() {
  local seed_dir="$1"

  (
    cd "${seed_dir}"
    while IFS= read -r path; do
      if [[ -d "${path}" ]]; then
        printf 'dir\t%s\n' "${path}"
      elif [[ -f "${path}" ]]; then
        printf 'file\t%s\t%s\n' "${path}" "$(sha256_file "${path}")"
      elif [[ -L "${path}" ]]; then
        printf 'symlink\t%s\t%s\n' "${path}" "$(readlink "${path}")"
      fi
    done < <(find . -mindepth 1 -print | LC_ALL=C sort)
  ) | sha256_stdin
}

seed_codex_home_volume_if_needed() {
  local seed_dir="${RUNTIME_STATE_DIR}/host-codex-seed"
  local first_seed_entry
  local seed_hash

  [[ -d "${seed_dir}" ]] || return 0
  first_seed_entry="$(find "${seed_dir}" -mindepth 1 -print -quit)"
  [[ -n "${first_seed_entry}" ]] || return 0
  seed_hash="$(compute_seed_dir_hash "${seed_dir}")"

  docker run --rm \
    --entrypoint bash \
    --env "HOST_UID=${HOST_UID}" \
    --env "HOST_GID=${HOST_GID}" \
    --env "HOST_CODEX_SEED_HASH=${seed_hash}" \
    --volume "${CODEX_HOME_VOLUME}:${CODEX_HOME_IN_CONTAINER}" \
    --volume "${seed_dir}:/seed:ro" \
    "${IMAGE}" \
    -lc '
      set -euo pipefail
      marker="'"${CODEX_HOME_IN_CONTAINER}"'/.host-config-imported.sha256"
      current_hash=""

      if [[ -e "$marker" ]]; then
        current_hash="$(cat "$marker")"
      fi

      if [[ "$current_hash" == "$HOST_CODEX_SEED_HASH" ]]; then
        exit 0
      fi

      mkdir -p "'"${CODEX_HOME_IN_CONTAINER}"'"
      for base in config.toml prompts rules skills; do
        rm -rf "'"${CODEX_HOME_IN_CONTAINER}"'/$base"
      done
      shopt -s dotglob nullglob
      for item in /seed/*; do
        base="$(basename "$item")"
        cp -R "$item" "'"${CODEX_HOME_IN_CONTAINER}"'/$base"
      done
      printf "%s\n" "$HOST_CODEX_SEED_HASH" > "$marker"
      chown -R "${HOST_UID}:${HOST_GID}" "'"${CODEX_HOME_IN_CONTAINER}"'"
      chmod 700 "'"${CODEX_HOME_IN_CONTAINER}"'"
      find "'"${CODEX_HOME_IN_CONTAINER}"'" -type d -exec chmod 755 {} \;
      find "'"${CODEX_HOME_IN_CONTAINER}"'" -type f -exec chmod 644 {} \;
      chmod 600 "'"${CODEX_HOME_IN_CONTAINER}"'/auth.json 2>/dev/null || true
      chmod 600 "'"${CODEX_HOME_IN_CONTAINER}"'/config.toml 2>/dev/null || true
    '

  echo ">> synchronized host Codex config into volume: ${CODEX_HOME_VOLUME}"
}

context_hash() {
  local files=(
    "${SCRIPT_DIR}/Dockerfile"
    "${SCRIPT_DIR}/codex-wrapper.sh"
    "${SCRIPT_DIR}/entrypoint.sh"
    "${SCRIPT_DIR}/init-firewall.sh"
    "${SCRIPT_DIR}/allowed-domains.txt"
    "${SCRIPT_DIR}/run.sh"
  )
  local existing=()
  local file

  for file in "${files[@]}"; do
    [[ -f "${file}" ]] && existing+=("${file}")
  done

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${existing[@]}"
  else
    shasum -a 256 "${existing[@]}"
  fi | sha256sum | cut -c1-16
}

CURRENT_HASH="$(context_hash)"
IMAGE_HASH="$(docker image inspect "${IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"

if [[ "${PRINT_CODEX_HOME_VOLUME}" != true ]]; then
  assert_safe_mount_dir "${PROJECT_DIR}"
  for mount_dir in "${EXTRA_MOUNT_DIRS[@]}"; do
    assert_safe_mount_dir "${mount_dir}"
  done
  warn_ignored_sensitive_host_envs
fi

if [[ "${IMAGE_HASH}" != "${CURRENT_HASH}" ]]; then
  if [[ "${PRINT_CODEX_HOME_VOLUME}" == true ]]; then
    echo "codex-in-docker image is outdated; run the launcher normally once to rebuild it." >&2
    exit 1
  fi
  if [[ -n "${IMAGE_HASH}" ]]; then
    echo ">> build context changed; rebuilding ${IMAGE}"
  else
    echo ">> building ${IMAGE}"
  fi
  docker build --tag "${IMAGE}" --label "build.context-hash=${CURRENT_HASH}" "${SCRIPT_DIR}"
fi

mkdir -p "${RUNTIME_STATE_DIR}"
cat > "${PASSWD_FILE}" <<EOF
root:x:0:0:root:/root:/bin/bash
dev:x:$(id -u):$(id -g):dev:${HOME_IN_CONTAINER}:/bin/bash
EOF
cat > "${GROUP_FILE}" <<EOF
root:x:0:
dev:x:$(id -g):
EOF

DOCKER_NETWORK_ARGS=()
DOCKER_PUBLISH_ARGS=()
DOCKER_ENV_ARGS=(
  --env "HOME=${HOME_IN_CONTAINER}"
  --env "COLORTERM=truecolor"
  --env "CODEX_NETWORK_MODE=${NETWORK_MODE}"
  --env "CODEX_ROOTFS_MODE=${ROOTFS_MODE}"
  --env "CODEX_HOME=${CODEX_HOME_IN_CONTAINER}"
)
DOCKER_MOUNT_ARGS=(
  --volume "${PROJECT_DIR}:${WORKSPACE_IN_CONTAINER}"
  --volume "${PASSWD_FILE}:/etc/passwd:ro"
  --volume "${GROUP_FILE}:/etc/group:ro"
)
DOCKER_ROOTFS_ARGS=()

if [[ -n "${MCP_OAUTH_CALLBACK_PORT}" ]]; then
  if [[ ! "${MCP_OAUTH_CALLBACK_PORT}" =~ ^[0-9]+$ ]]; then
    echo "unsupported CODEX_MCP_OAUTH_CALLBACK_PORT: ${MCP_OAUTH_CALLBACK_PORT}" >&2
    echo "expected an integer TCP port" >&2
    exit 1
  fi
  if [[ "${NETWORK_MODE}" == "none" ]]; then
    echo "CODEX_MCP_OAUTH_CALLBACK_PORT requires network access; use CODEX_NETWORK_MODE=direct or firewall" >&2
    exit 1
  fi
  DOCKER_PUBLISH_ARGS+=(--publish "127.0.0.1:${MCP_OAUTH_CALLBACK_PORT}:${MCP_OAUTH_CALLBACK_PORT}")
fi

SAFE_NAME="$(printf '%s' "$(basename "${PROJECT_DIR}")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
SAFE_NAME="$(printf '%s' "${SAFE_NAME}" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
CODEX_HOME_VOLUME="${CODEX_HOME_VOLUME:-codex-home-${SAFE_NAME:-repo}-$(path_hash "${PROJECT_HASH_INPUT}")}"
DOCKER_MOUNT_ARGS+=(--volume "${CODEX_HOME_VOLUME}:${CODEX_HOME_IN_CONTAINER}")

for ((i=0; i<${#EXTRA_MOUNT_DIRS[@]}; i++)); do
  mount_dir="${EXTRA_MOUNT_DIRS[i]}"
  target_path="${EXTRA_MOUNT_TARGETS[i]}"
  mount_mode="${EXTRA_MOUNT_MODES[i]}"
  DOCKER_MOUNT_ARGS+=(--volume "${mount_dir}:${target_path}:${mount_mode}")
done

if [[ "${PRINT_CODEX_HOME_VOLUME}" == true ]]; then
  printf '%s\n' "${CODEX_HOME_VOLUME}"
  exit 0
fi

load_global_env_file
load_project_env_file
prepare_host_codex_seed_dir
seed_codex_home_volume_if_needed

echo ">> project: ${PROJECT_DIR}"
echo ">> workspace root: ${WORKSPACE_ROOT_IN_CONTAINER}"
echo ">> primary mount: ${PROJECT_DIR} -> ${WORKSPACE_IN_CONTAINER}"
echo ">> codex home volume: ${CODEX_HOME_VOLUME}"
for ((i=0; i<${#EXTRA_MOUNT_DIRS[@]}; i++)); do
  mount_dir="${EXTRA_MOUNT_DIRS[i]}"
  target_path="${EXTRA_MOUNT_TARGETS[i]}"
  mount_mode="${EXTRA_MOUNT_MODES[i]}"
  echo ">> extra mount [${mount_mode}]: ${mount_dir} -> ${target_path}"
done
if [[ -n "${MCP_OAUTH_CALLBACK_PORT}" ]]; then
  echo ">> mcp oauth callback port: ${MCP_OAUTH_CALLBACK_PORT}"
fi

for maybe_env in "${ALLOWED_PASSTHROUGH_ENVS[@]}"; do
  if [[ -n "${!maybe_env:-}" ]]; then
    DOCKER_ENV_ARGS+=(--env "${maybe_env}")
  fi
done

case "${NETWORK_MODE}" in
  firewall)
    DOCKER_NETWORK_ARGS+=(--cap-drop=ALL --cap-add=NET_ADMIN --cap-add=SETUID --cap-add=SETGID)
    ;;
  direct)
    DOCKER_NETWORK_ARGS+=(--cap-drop=ALL)
    ;;
  none)
    DOCKER_NETWORK_ARGS+=(--cap-drop=ALL --network none)
    ;;
  *)
    echo "unsupported CODEX_NETWORK_MODE: ${NETWORK_MODE}" >&2
    echo "supported values: firewall, direct, none" >&2
    exit 1
    ;;
esac

case "${ROOTFS_MODE}" in
  writable)
    ;;
  readonly)
    DOCKER_ROOTFS_ARGS+=(
      --read-only
      --tmpfs /tmp:rw,noexec,nosuid,nodev
      --tmpfs /var/tmp:rw,noexec,nosuid,nodev
      --tmpfs /run:rw,nosuid,nodev
      --tmpfs /home/dev/.cache:rw,nosuid,nodev
    )
    ;;
  *)
    echo "unsupported CODEX_ROOTFS_MODE: ${ROOTFS_MODE}" >&2
    echo "supported values: writable, readonly" >&2
    exit 1
    ;;
esac

exec docker run \
  --interactive --tty --rm \
  --user "$(id -u):$(id -g)" \
  --security-opt no-new-privileges:true \
  ${DOCKER_PUBLISH_ARGS[@]+"${DOCKER_PUBLISH_ARGS[@]}"} \
  ${DOCKER_NETWORK_ARGS[@]+"${DOCKER_NETWORK_ARGS[@]}"} \
  ${DOCKER_ROOTFS_ARGS[@]+"${DOCKER_ROOTFS_ARGS[@]}"} \
  ${DOCKER_ENV_ARGS[@]+"${DOCKER_ENV_ARGS[@]}"} \
  ${DOCKER_MOUNT_ARGS[@]+"${DOCKER_MOUNT_ARGS[@]}"} \
  --workdir "${WORKSPACE_IN_CONTAINER}" \
  "${IMAGE}" \
  "$@"
