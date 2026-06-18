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
DEPENDENCY_ISOLATION_MODE="${CODEX_DEPENDENCY_ISOLATION:-enabled}"
MCP_OAUTH_CALLBACK_PORT="${CODEX_MCP_OAUTH_CALLBACK_PORT:-}"
CONTAINER_NAME_OVERRIDE="${CODEX_CONTAINER_NAME:-}"
CODEX_VERSION_OVERRIDE="${CODEX_VERSION:-}"
RUNTIME_STATE_DIR="${SCRIPT_DIR}/.tmp/runtime"
PASSWD_FILE="${RUNTIME_STATE_DIR}/passwd"
GROUP_FILE="${RUNTIME_STATE_DIR}/group"
PROJECT_HASH_INPUT="${PROJECT_DIR}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
PRINT_CODEX_HOME_VOLUME=false
MANAGEMENT_ACTION=""
DOCKER_COMMAND_ARGS=()
EXTRA_MOUNT_MODES=()
EXTRA_MOUNT_NAMES=()
EXTRA_MOUNT_DIRS=()
EXTRA_MOUNT_TARGETS=()
UNIQUE_VALUES=()
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
DEPENDENCY_ISOLATED_DIRS=(
  node_modules
  .pnpm-store
  .yarn
  .venv
  venv
  env
  .tox
  .nox
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

array_length() {
  local array_name="$1"
  local count=0
  local had_nounset=0

  case "$-" in
    *u*)
      had_nounset=1
      set +u
      ;;
  esac

  eval "count=\${#${array_name}[@]}"

  if [[ "${had_nounset}" -eq 1 ]]; then
    set -u
  fi

  printf '%s\n' "${count}"
}

print_array_lines() {
  local array_name="$1"
  local count
  local had_nounset=0

  count="$(array_length "${array_name}")"
  if [[ "${count}" -eq 0 ]]; then
    return 0
  fi

  case "$-" in
    *u*)
      had_nounset=1
      set +u
      ;;
  esac

  eval "printf '%s\n' \"\${${array_name}[@]}\""

  if [[ "${had_nounset}" -eq 1 ]]; then
    set -u
  fi
}

path_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-10
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-10
  fi
}

init_project_identity() {
  PROJECT_HASH_SHORT="$(path_hash "${PROJECT_HASH_INPUT}")"
  SAFE_NAME="$(printf '%s' "$(basename "${PROJECT_DIR}")" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  SAFE_NAME="$(printf '%s' "${SAFE_NAME}" | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  CODEX_HOME_VOLUME="${CODEX_HOME_VOLUME:-codex-home-${SAFE_NAME:-repo}-${PROJECT_HASH_SHORT}}"
  CONTAINER_NAME="${CONTAINER_NAME_OVERRIDE:-codex-${SAFE_NAME:-repo}-${PROJECT_HASH_SHORT}-$$}"
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
  local extra_mount_name_count

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

  extra_mount_name_count="$(array_length EXTRA_MOUNT_NAMES)"
  for ((i=0; i<extra_mount_name_count; i++)); do
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

dependency_volume_name() {
  local identity="$1"
  local rel_dir="$2"
  local safe_rel

  safe_rel="$(printf '%s' "${rel_dir}" | tr '/.' '--' | tr -c 'a-zA-Z0-9_-' '-')"
  safe_rel="$(printf '%s' "${safe_rel}" | tr '[:upper:]' '[:lower:]' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')"
  printf 'codex-deps-%s-%s' "$(path_hash "${identity}")" "${safe_rel:-dir}"
}

register_dependency_mounts() {
  local identity="$1"
  local container_base="$2"
  local rel_dir
  local volume_name

  for rel_dir in "${DEPENDENCY_ISOLATED_DIRS[@]}"; do
    volume_name="$(dependency_volume_name "${identity}:${rel_dir}" "${rel_dir}")"
    DOCKER_MOUNT_ARGS+=(--volume "${volume_name}:${container_base}/${rel_dir}")
  done
}

append_unique_value() {
  local value="$1"
  local existing

  for existing in "${UNIQUE_VALUES[@]:-}"; do
    if [[ "${existing}" == "${value}" ]]; then
      return 0
    fi
  done

  UNIQUE_VALUES+=("${value}")
}

collect_project_volume_names() {
  local roots=("${PROJECT_DIR}")
  local root
  local rel_dir

  while IFS= read -r root; do
    roots+=("${root}")
  done < <(print_array_lines EXTRA_MOUNT_DIRS)

  UNIQUE_VALUES=()
  append_unique_value "${CODEX_HOME_VOLUME}"

  if [[ "${DEPENDENCY_ISOLATION_MODE}" == "enabled" ]]; then
    for root in "${roots[@]}"; do
      for rel_dir in "${DEPENDENCY_ISOLATED_DIRS[@]}"; do
        append_unique_value "$(dependency_volume_name "${root}:${rel_dir}" "${rel_dir}")"
      done
    done
  fi

  print_array_lines UNIQUE_VALUES
}

list_codex_volumes() {
  docker volume ls --format '{{.Name}}' | grep -E '^codex-(home|deps)-' || true
}

remove_named_volumes() {
  local volume
  local removed_any=false

  while IFS= read -r volume; do
    [[ -n "${volume}" ]] || continue
    if docker volume inspect "${volume}" >/dev/null 2>&1; then
      echo "removing volume: ${volume}"
      docker volume rm "${volume}"
      removed_any=true
    fi
  done

  if [[ "${removed_any}" != true ]]; then
    echo "no matching codex volumes found"
  fi
}

run_management_action() {
  case "${MANAGEMENT_ACTION}" in
    list-volumes)
      list_codex_volumes
      ;;
    prune-project-volumes)
      collect_project_volume_names | remove_named_volumes
      ;;
    prune-all-volumes)
      list_codex_volumes | remove_named_volumes
      ;;
    "")
      return 0
      ;;
    *)
      echo "unsupported management action: ${MANAGEMENT_ACTION}" >&2
      exit 1
      ;;
  esac

  exit 0
}

parse_launcher_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --print-codex-home-volume)
        PRINT_CODEX_HOME_VOLUME=true
        shift
        ;;
      --list-volumes)
        MANAGEMENT_ACTION="list-volumes"
        shift
        ;;
      --prune-project-volumes)
        MANAGEMENT_ACTION="prune-project-volumes"
        shift
        ;;
      --prune-all-volumes)
        MANAGEMENT_ACTION="prune-all-volumes"
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
if [[ "$(array_length DOCKER_COMMAND_ARGS)" -gt 0 ]]; then
  set +u
  set -- "${DOCKER_COMMAND_ARGS[@]}"
  set -u
else
  set --
fi

init_project_identity

warn_ignored_sensitive_host_envs() {
  local env_name
  local warned=()

  for env_name in "${SENSITIVE_HOST_ENVS[@]}"; do
    if [[ -n "${!env_name:-}" ]]; then
      warned+=("${env_name}")
    fi
  done

  if [[ "$(array_length warned)" -gt 0 ]]; then
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

image_codex_version() {
  docker image inspect "${IMAGE}" --format '{{index .Config.Labels "codex.version"}}' 2>/dev/null || true
}

resolve_target_codex_version() {
  local image_version="$1"

  if [[ -n "${CODEX_VERSION_OVERRIDE}" ]]; then
    printf '%s\n' "${CODEX_VERSION_OVERRIDE}"
    return 0
  fi

  if [[ -n "${image_version}" ]]; then
    echo ">> reusing image version ${image_version}; set CODEX_VERSION to override it" >&2
    printf '%s\n' "${image_version}"
    return 0
  fi

  cat >&2 <<EOF
unable to determine which Codex version to build.
Set CODEX_VERSION=<version> explicitly to force a rebuild.
EOF
  return 1
}

case "${DEPENDENCY_ISOLATION_MODE}" in
  enabled|disabled)
    ;;
  *)
    echo "unsupported CODEX_DEPENDENCY_ISOLATION: ${DEPENDENCY_ISOLATION_MODE}" >&2
    echo "supported values: enabled, disabled" >&2
    exit 1
    ;;
esac

if [[ -n "${MANAGEMENT_ACTION}" ]]; then
  run_management_action
fi

CURRENT_HASH="$(context_hash)"
IMAGE_HASH="$(docker image inspect "${IMAGE}" --format '{{index .Config.Labels "build.context-hash"}}' 2>/dev/null || true)"
IMAGE_CODEX_VERSION="$(image_codex_version)"
TARGET_CODEX_VERSION=""

if [[ "${PRINT_CODEX_HOME_VOLUME}" != true ]]; then
  assert_safe_mount_dir "${PROJECT_DIR}"
  while IFS= read -r mount_dir; do
    assert_safe_mount_dir "${mount_dir}"
  done < <(print_array_lines EXTRA_MOUNT_DIRS)
  warn_ignored_sensitive_host_envs
  TARGET_CODEX_VERSION="$(resolve_target_codex_version "${IMAGE_CODEX_VERSION}")"
fi

REBUILD_REQUIRED=false
if [[ "${IMAGE_HASH}" != "${CURRENT_HASH}" ]]; then
  REBUILD_REQUIRED=true
fi
if [[ "${PRINT_CODEX_HOME_VOLUME}" != true && "${IMAGE_CODEX_VERSION}" != "${TARGET_CODEX_VERSION}" ]]; then
  REBUILD_REQUIRED=true
fi

if [[ "${REBUILD_REQUIRED}" == true ]]; then
  if [[ "${PRINT_CODEX_HOME_VOLUME}" == true ]]; then
    echo "codex-in-docker image is outdated; run the launcher normally once to rebuild it." >&2
    exit 1
  fi
  if [[ -n "${IMAGE_HASH}" ]]; then
    if [[ "${IMAGE_HASH}" != "${CURRENT_HASH}" && "${IMAGE_CODEX_VERSION}" != "${TARGET_CODEX_VERSION}" ]]; then
      echo ">> build context changed and Codex ${TARGET_CODEX_VERSION} is required; rebuilding ${IMAGE}"
    elif [[ "${IMAGE_HASH}" != "${CURRENT_HASH}" ]]; then
      echo ">> build context changed; rebuilding ${IMAGE}"
    else
      echo ">> Codex ${TARGET_CODEX_VERSION} is newer than image version ${IMAGE_CODEX_VERSION:-unknown}; rebuilding ${IMAGE}"
    fi
  else
    echo ">> building ${IMAGE} with Codex ${TARGET_CODEX_VERSION}"
  fi
  docker build \
    --tag "${IMAGE}" \
    --build-arg "CODEX_VERSION=${TARGET_CODEX_VERSION}" \
    --label "build.context-hash=${CURRENT_HASH}" \
    --label "codex.version=${TARGET_CODEX_VERSION}" \
    "${SCRIPT_DIR}"
  IMAGE_CODEX_VERSION="${TARGET_CODEX_VERSION}"
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
DOCKER_CONTAINER_ARGS=()
extra_mount_count="$(array_length EXTRA_MOUNT_DIRS)"

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

DOCKER_MOUNT_ARGS+=(--volume "${CODEX_HOME_VOLUME}:${CODEX_HOME_IN_CONTAINER}")
DOCKER_CONTAINER_ARGS+=(
  --name "${CONTAINER_NAME}"
  --label "codex.project_dir=${PROJECT_DIR}"
  --label "codex.project_hash=${PROJECT_HASH_SHORT}"
)

if [[ "${DEPENDENCY_ISOLATION_MODE}" == "enabled" ]]; then
  register_dependency_mounts "${PROJECT_DIR}" "${WORKSPACE_IN_CONTAINER}"
fi

for ((i=0; i<extra_mount_count; i++)); do
  mount_dir="${EXTRA_MOUNT_DIRS[i]}"
  target_path="${EXTRA_MOUNT_TARGETS[i]}"
  mount_mode="${EXTRA_MOUNT_MODES[i]}"
  DOCKER_MOUNT_ARGS+=(--volume "${mount_dir}:${target_path}:${mount_mode}")
  if [[ "${DEPENDENCY_ISOLATION_MODE}" == "enabled" ]]; then
    register_dependency_mounts "${mount_dir}" "${target_path}"
  fi
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
echo ">> container name: ${CONTAINER_NAME}"
echo ">> codex home volume: ${CODEX_HOME_VOLUME}"
echo ">> codex version: ${IMAGE_CODEX_VERSION:-unknown}"
echo ">> dependency isolation: ${DEPENDENCY_ISOLATION_MODE}"
if [[ "${DEPENDENCY_ISOLATION_MODE}" == "enabled" ]]; then
  echo ">> isolated dependency dirs: ${DEPENDENCY_ISOLATED_DIRS[*]}"
fi
for ((i=0; i<extra_mount_count; i++)); do
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
  ${DOCKER_CONTAINER_ARGS[@]+"${DOCKER_CONTAINER_ARGS[@]}"} \
  ${DOCKER_PUBLISH_ARGS[@]+"${DOCKER_PUBLISH_ARGS[@]}"} \
  ${DOCKER_NETWORK_ARGS[@]+"${DOCKER_NETWORK_ARGS[@]}"} \
  ${DOCKER_ROOTFS_ARGS[@]+"${DOCKER_ROOTFS_ARGS[@]}"} \
  ${DOCKER_ENV_ARGS[@]+"${DOCKER_ENV_ARGS[@]}"} \
  ${DOCKER_MOUNT_ARGS[@]+"${DOCKER_MOUNT_ARGS[@]}"} \
  --workdir "${WORKSPACE_IN_CONTAINER}" \
  "${IMAGE}" \
  "$@"
