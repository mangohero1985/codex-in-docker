# codex-in-docker

Run Codex inside Docker instead of directly on the host.

## Quick Start

Default safe mode:

```bash
cd /path/to/your/project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
bash /path/to/codex-in-docker/run.sh
```

Online writable mode:

```bash
cd /path/to/your/project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
CODEX_NETWORK_MODE=direct \
CODEX_ROOTFS_MODE=writable \
bash /path/to/codex-in-docker/run.sh
```

Online mode with extra mounts:

```bash
cd /path/to/primary-project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
CODEX_NETWORK_MODE=direct \
CODEX_ROOTFS_MODE=writable \
bash /path/to/codex-in-docker/run.sh \
  --mount /path/to/service-a \
  --mount /path/to/service-b:backend \
  --mount-ro /path/to/shared-specs:specs
```

Volume management:

```bash
bash /path/to/codex-in-docker/run.sh --list-volumes
bash /path/to/codex-in-docker/run.sh --prune-project-volumes
bash /path/to/codex-in-docker/run.sh --prune-all-volumes
```

After the container starts:

```bash
codex
```

or:

```bash
codex exec "your task here"
```

## Parameter List

Launcher flags:

- `--mount /path/to/repo`
- `--mount /path/to/repo:alias`
- `--mount-ro /path/to/repo`
- `--mount-ro /path/to/repo:alias`
- `--print-codex-home-volume`
- `--list-volumes`
- `--prune-project-volumes`
- `--prune-all-volumes`
- `--`

Important environment variables:

- `CODEX_NETWORK_MODE=none|firewall|direct`
- `CODEX_ROOTFS_MODE=readonly|writable`
- `CODEX_DEPENDENCY_ISOLATION=enabled|disabled`
- `CODEX_VERSION=<exact-version>`
- `CODEX_CONTAINER_NAME=<name>`
- `CODEX_MCP_OAUTH_CALLBACK_PORT=<port>`
- `CODEX_HOME_VOLUME=<docker-volume-name>`

Semantics:

- `--mount` adds an extra read-write bind mount under `/home/dev/workspace/_mounts/<name>`
- `--mount-ro` adds an extra read-only bind mount
- `--` stops launcher flag parsing and passes the remaining args to the container command
- `--prune-project-volumes` removes the current project's `codex-home-*` volume and, when enabled, its dependency isolation volumes
- `--prune-all-volumes` removes every `codex-home-*` and `codex-deps-*` volume on the Docker host

## Quick Setup

Before starting an online session, you can create a global `.codex.env` next to
`run.sh`:

```bash
cat > /path/to/codex-in-docker/.codex.env <<'EOF'
OPENAI_API_KEY=your-openai-key
EOF
```

You can also create `./.codex.env` in an individual project. The launcher loads
the global file first and then the project file, so project-local values
override the global defaults.

## What It Does

- runs Codex in a dedicated container
- mounts the current project directory at `/home/dev/workspace/current`
- optionally mounts additional host folders under `/home/dev/workspace/_mounts/<name>`
- keeps common Node/Python dependency directories in container-only Docker volumes by default
- stores Codex state in a project-scoped Docker volume at `/home/dev/.codex`
- uses explicit Docker names for the Codex container and its volumes
- blocks obvious host secret paths and does not forward common secret env vars
- checks the latest published `@openai/codex` version before launch and rebuilds the image when the installed version is behind
- defaults to an offline, read-only container

## Extra Project Mounts

If you need to work across multiple repositories in one container session, you
can add extra folder mounts when launching:

```bash
cd /path/to/primary-project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
CODEX_NETWORK_MODE=direct \
CODEX_ROOTFS_MODE=writable \
bash /path/to/codex-in-docker/run.sh \
  --mount /path/to/service-a \
  --mount /path/to/service-b:backend \
  --mount-ro /path/to/shared-specs:specs
```

Inside the container:

- the current directory is `/home/dev/workspace/current`
- extra read-write mounts appear under `/home/dev/workspace/_mounts/<name>`
- `--mount-ro` exposes a folder read-only, which is useful for reference repos

Notes:

- `--mount /path/to/repo` uses the folder basename as `<name>`
- `--mount /path/to/repo:alias` mounts it at `/home/dev/workspace/_mounts/alias`
- if you need to pass `--mount` to the command inside the container, separate
  launcher args from command args with `--`

## Dependency Isolation

By default, the launcher keeps common dependency install directories in
container-only Docker volumes instead of writing them back into the host
checkout.

Current isolated directories:

- `node_modules`
- `.pnpm-store`
- `.yarn`
- `.venv`
- `venv`
- `env`
- `.tox`
- `.nox`

This applies to both the primary project and extra mounts.

The launcher also isolates the same dependency directories for direct child
projects under these common monorepo roots when they exist:

- `apps/*`
- `packages/*`
- `services/*`
- `libs/*`
- `tools/*`
- `examples/*`

Example:

- `npm install` writes package contents into the container volume mounted at
  `/home/dev/workspace/current/node_modules`
- `cd packages/web && npm install` writes package contents into the container
  volume mounted at `/home/dev/workspace/current/packages/web/node_modules`
- `python -m venv .venv` writes the environment into the container volume
  mounted at `/home/dev/workspace/current/.venv`

Important limits:

- dependency manifests such as `package.json`, lockfiles, `requirements.txt`,
  `pyproject.toml`, or `.pnp.cjs` still live in the host checkout and can still
  be modified
- custom install targets outside the isolated directory list are not captured
- if you disable this feature, dependency directories go back to the host bind
  mount behavior

For project-specific paths outside the defaults, set `CODEX_ISOLATED_PATHS` to a
comma-separated list of relative paths. Each listed path is overlaid with a
Docker volume inside the container instead of writing back to the host checkout.

Example:

```bash
CODEX_ISOLATED_PATHS="packages/web/node_modules,apps/api/.venv,.cache/pip" \
  bash /path/to/codex-in-docker/run.sh
```

To turn dependency isolation off for a session:

```bash
CODEX_DEPENDENCY_ISOLATION=disabled bash /path/to/codex-in-docker/run.sh
```

By default, the container-side `codex` wrapper disables the inner Codex `bwrap`
sandbox and runs with `--sandbox danger-full-access`. This keeps Docker as the
main isolation boundary and avoids nested sandbox failures such as
`bwrap: No permissions to create a new namespace...`.

The launcher chooses the Codex version before starting the container by using
`CODEX_VERSION` when it is set. If `CODEX_VERSION` is unset, `run.sh` reuses the
version recorded in the image label.

When no version is recorded yet, set `CODEX_VERSION=<exact-version>` explicitly
to force a rebuild.

To restore the original Codex sandbox behavior for a single container session:

```bash
CODEX_DISABLE_INNER_SANDBOX=0 bash
codex
```

## Login

In an online session:

```bash
codex login --device-auth
```

Login state is stored under `/home/dev/.codex` and survives container exit.

## State

The launcher prints the current project and Codex state volume:

```text
>> project: ...
>> workspace root: /home/dev/workspace
>> primary mount: ... -> /home/dev/workspace/current
>> container name: codex-...
>> codex home volume: ...
>> dependency isolation: enabled
```

That volume stores:

- Codex login state
- Codex sessions
- Docker-side config

Naming notes:

- the Codex home volume uses a stable name like `codex-home-<project>-<hash>`
- dependency isolation volumes use stable names like `codex-deps-<hash>-node_modules`
- the running container gets an explicit name like
  `codex-<project>-<hash>-<pid>`
- you can override the container name for one launch with
  `CODEX_CONTAINER_NAME=my-codex-session`

## Host Config Import

On startup, the launcher syncs these host-side Codex assets from `~/.codex` into the project volume whenever their content changes:

- `config.toml`
- `prompts/`
- `rules/`
- `skills/`

It does not import host-side auth, logs, sqlite databases, or session history.

## Environment Rules

The launcher only forwards these auth-related env vars:

- `CODEX_ACCESS_TOKEN`
- `CODEX_API_KEY`
- `CODEX_CA_CERTIFICATE`

Common host secret env vars are not forwarded.

For local secrets, the launcher reads these files on startup in this order:

- `/path/to/codex-in-docker/.codex.env`
- `./.codex.env`

If the same key appears in both files, the project-local `./.codex.env`
overrides the global value. Only the explicitly allowed keys below are
forwarded:

- `OPENAI_API_KEY`

Both `.codex.env` files are intended to stay local to your machine and should be
ignored by Git.

## Guardrails

The launcher refuses to start if the current directory is inside a known host secret path such as:

- `~/.ssh`
- `~/.aws`
- `~/.kube`
- `~/.docker`
- `~/Library/Keychains`
- `/run`
- `/var/run`

The same guardrails also apply to extra folders passed with `--mount` or
`--mount-ro`.

The container always runs with Docker `no-new-privileges`.

## MCP

Docker-side MCP OAuth credentials are configured to stay in the Docker `CODEX_HOME` volume:

```toml
mcp_oauth_credentials_store = "file"
```

Known limitation:

- localhost OAuth callback flows for some MCP servers are not fully reliable in Docker today
- normal Codex usage (`codex`, `codex exec`, `codex login --device-auth`) works

## Recommended Use

- daily safe default: offline mode
- real Codex development: `direct + writable`
- mount extra repos only when they are needed for the task
- prefer `--mount-ro` for reference code or docs you do not need to edit
- leave dependency isolation enabled unless you explicitly need host-side installs
- do not mount host secret directories
- do not rely on general host secret env vars inside the container

## Isolation Impact

Adding extra mounts does not change the container boundary itself:

- network isolation still depends on `CODEX_NETWORK_MODE`
- root filesystem isolation still depends on `CODEX_ROOTFS_MODE`
- `no-new-privileges` still stays enabled

What does change is host filesystem exposure:

- every extra mount gives the container direct access to another host directory
- read-write mounts allow edits to those host files from inside the container
- Docker `--read-only` does not make bind mounts read-only; use `--mount-ro` if
  you want that behavior
- dependency isolation reduces write-back for common install directories, but it
  does not stop changes to manifest or source files in the mounted checkout

## Acknowledgements

This project was put together with reference to these two projects. Thanks to
their authors for the ideas and groundwork:

- `openai/codex-universal`: `https://github.com/openai/codex-universal`
- `MrOggy85/claude-in-docker`: `https://github.com/MrOggy85/claude-in-docker`
