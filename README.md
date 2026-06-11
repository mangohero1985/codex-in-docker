# codex-in-docker

Run Codex inside Docker instead of directly on the host.

## What It Does

- runs Codex in a dedicated container
- mounts only the current project directory as the workspace
- stores Codex state in a project-scoped Docker volume at `/home/dev/.codex`
- blocks obvious host secret paths and does not forward common secret env vars
- defaults to an offline, read-only container

## Default Start

This is the launcher default:

- `CODEX_NETWORK_MODE=none`
- `CODEX_ROOTFS_MODE=readonly`

Use it like this:

```bash
cd /path/to/your/project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
bash /path/to/codex-in-docker/run.sh
```

This mode is safe by default, but it cannot call the Codex model.

## Online Start

Use this when you want real Codex model access:

```bash
cd /path/to/your/project
mkdir -p /path/to/codex-in-docker/.tmp/buildx
BUILDX_CONFIG=/path/to/codex-in-docker/.tmp/buildx \
CODEX_NETWORK_MODE=direct \
CODEX_ROOTFS_MODE=writable \
bash /path/to/codex-in-docker/run.sh
```

Inside the container:

```bash
codex
```

or:

```bash
codex exec "your task here"
```

By default, the container-side `codex` wrapper disables the inner Codex `bwrap`
sandbox and runs with `--sandbox danger-full-access`. This keeps Docker as the
main isolation boundary and avoids nested sandbox failures such as
`bwrap: No permissions to create a new namespace...`.

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
>> codex home volume: ...
```

That volume stores:

- Codex login state
- Codex sessions
- Docker-side config

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

For project-local secrets, you can create `./.codex.env`. The launcher reads
this file on startup and forwards only the explicitly allowed keys below:

- `OPENAI_API_KEY`

Example:

```bash
cat > .codex.env <<'EOF'
OPENAI_API_KEY=your-litellm-key
EOF
```

`/.codex.env` is intended to stay local to your machine and should be ignored by Git.

## Guardrails

The launcher refuses to start if the current directory is inside a known host secret path such as:

- `~/.ssh`
- `~/.aws`
- `~/.kube`
- `~/.docker`
- `~/Library/Keychains`
- `/run`
- `/var/run`

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
- do not mount host secret directories
- do not rely on general host secret env vars inside the container
