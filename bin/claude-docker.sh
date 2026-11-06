#!/bin/bash
# claude — run Claude Code in a Docker container.
# Isolation is filesystem-only (no network firewall): the container sees the
# current project directory.  Git tokens + settings come from the project's .env.
#
# Install:
#   cp claude-docker.sh ~/.local/bin/claude-docker && chmod +x ~/.local/bin/claude-docker
#   ln -s claude-docker ~/.local/bin/codex-docker      # same wrapper, runs Codex

set -eo pipefail

IMAGE="claude-devcontainer"
BUILD_DIR="${CLAUDE_DEVCONTAINER_DIR:-${HOME}/.config/claude-devcontainer}"

case "$(basename "$0")" in
    codex-docker*) CLI=codex;  CNAME_PREFIX="codex-" ;;
    *)             CLI=claude; CNAME_PREFIX="claude-code-" ;;
esac

# ── Parse wrapper flags (consumed here, not passed to claude) ──
INSTANCE=""
LIST_INSTANCES=false
PRUNE_INSTANCE=false
SETTINGS_FILE=""
MCP_FILE=""
PRIVILEGED=false
ROOT=false
GW_ENV_FLAG=""         # --env FILE
CLAUDE_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--instance)
            INSTANCE="$2"; shift 2 ;;
        --instance=*)
            INSTANCE="${1#--instance=}"; shift ;;
        --list)
            LIST_INSTANCES=true; shift ;;
        --prune)
            PRUNE_INSTANCE=true; shift ;;
        --privileged)
            PRIVILEGED=true; shift ;;
        --root)
            ROOT=true; shift ;;
        --env)
            GW_ENV_FLAG="$2"; shift 2 ;;
        --env=*)
            GW_ENV_FLAG="${1#--env=}"; shift ;;
        -s|--settings)
            SETTINGS_FILE="$2"; shift 2 ;;
        --settings=*)
            SETTINGS_FILE="${1#--settings=}"; shift ;;
        --mcp)
            MCP_FILE="$2"; shift 2 ;;
        --mcp=*)
            MCP_FILE="${1#--mcp=}"; shift ;;
        --version|-V)
            echo "$(basename "$0") (claude-code-container wrapper)"; exit 0 ;;
        *)
            CLAUDE_ARGS+=("$1"); shift ;;
    esac
done
set -- "${CLAUDE_ARGS[@]}"

if [ -n "$INSTANCE" ] && ! [[ "$INSTANCE" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[claude] Invalid instance name '${INSTANCE}': only [a-zA-Z0-9._-] allowed." >&2
    exit 1
fi

# ── Prune a specific instance ──
if [ "$PRUNE_INSTANCE" = true ]; then
    if [ -z "$INSTANCE" ]; then
        echo "[claude] --prune requires -i <instance>." >&2
        exit 1
    fi
    _PRUNE_DIR="${BUILD_DIR}/instances/${INSTANCE}"
    if [ ! -d "$_PRUNE_DIR" ]; then
        echo "[claude] Instance '${INSTANCE}' not found." >&2
        exit 1
    fi
    _cname="${CNAME_PREFIX}${INSTANCE}"
    if docker ps -q --filter "name=^${_cname}$" 2>/dev/null | grep -q .; then
        echo "[claude] Instance '${INSTANCE}' is currently running." >&2
        echo "[claude] Stop it first with: docker stop ${_cname}" >&2
        exit 1
    fi
    rm -rf "$_PRUNE_DIR"
    docker volume rm "claude-devcontainer-codex-${INSTANCE}" >/dev/null 2>&1 || true
    echo "[claude] Pruned instance '${INSTANCE}'." >&2
    exit 0
fi

# ── List instances ──
if [ "$LIST_INSTANCES" = true ]; then
    _INSTANCE_BASE="${BUILD_DIR}/instances"
    if [ ! -d "$_INSTANCE_BASE" ] || [ -z "$(ls -A "$_INSTANCE_BASE" 2>/dev/null)" ]; then
        echo "No instances found." >&2
        exit 0
    fi
    printf "%-20s %-10s %-20s %s\n" "INSTANCE" "STATUS" "LAST USED" "PROJECT"
    printf "%-20s %-10s %-20s %s\n" "--------" "------" "---------" "-------"
    for _d in "$_INSTANCE_BASE"/*/; do
        [ -d "$_d" ] || continue
        _name="$(basename "$_d")"
        # Running status
        _cname="${CNAME_PREFIX}${_name}"
        if docker ps -q --filter "name=^${_cname}$" 2>/dev/null | grep -q .; then
            _status="running"
        else
            _status="stopped"
        fi
        # Last used
        if [ -f "$_d.last-used" ]; then
            _mtime="$(stat -c %Y "$_d.last-used" 2>/dev/null || stat -f %m "$_d.last-used")"
            _last_used="$(date -d "@${_mtime}" '+%Y-%m-%d %H:%M' 2>/dev/null \
                       || date -r "$_mtime" '+%Y-%m-%d %H:%M')"
        else
            _last_used="-"
        fi
        # Project (workspace)
        if [ -f "$_d.workspace" ]; then
            _project="$(cat "$_d.workspace")"
        else
            _project="-"
        fi
        printf "%-20s %-10s %-20s %s\n" "$_name" "$_status" "$_last_used" "$_project"
    done
    exit 0
fi

# ── Paths & helpers ──
WORKSPACE="${PWD}"
ENV_FILE="${WORKSPACE}/.env"
GLOBAL_ENV="${HOME}/.config/claude-devcontainer/env"

# read_env_var KEY — KEY's value from the project .env, unquoted, never evaluated.
read_env_var() {
    local key="$1"
    if [ -f "$ENV_FILE" ]; then
        grep -E "^${key}=" "$ENV_FILE" 2>/dev/null \
            | tail -1 \
            | sed "s/^${key}=//" \
            | sed "s/^[\"']//" \
            | sed "s/[\"']*$//" \
            | tr -d '[:space:]' || true
    fi
}

ensure_global_env_mode() {
    local perms
    perms=$(stat -c %a "$GLOBAL_ENV" 2>/dev/null || stat -f %OLp "$GLOBAL_ENV")
    if [ "$perms" != "600" ]; then
        echo "[claude] Error: ${GLOBAL_ENV} has mode ${perms}, expected 600." >&2
        echo "[claude] Fix with: chmod 600 ${GLOBAL_ENV}" >&2
        exit 1
    fi
}

# ── LLM gateway: --env FILE ──
# Not read on the host: its directory is mounted at /etc/gateway-bundle and
# the entrypoint sources it right before the CLI starts.
GATEWAY_MODE=false
if [ -n "$GW_ENV_FLAG" ]; then
    GW_SOURCE="${GW_ENV_FLAG/#\~/$HOME}"
    [[ "$GW_SOURCE" != /* ]] && GW_SOURCE="${PWD}/${GW_SOURCE}"
    if [ ! -f "$GW_SOURCE" ]; then
        echo "[${CLI}] Error: --env file not found: ${GW_SOURCE}" >&2
        exit 1
    fi
    GATEWAY_MODE=true
    GW_BUNDLE="$(cd "$(dirname "$GW_SOURCE")" && pwd)"
    echo "[${CLI}] Gateway: ${GW_SOURCE}" >&2
fi

# ── Build if missing ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[claude] Building image..." >&2
    docker build -t "$IMAGE" "$BUILD_DIR"
fi

# ── OAuth token ──
if [ "$GATEWAY_MODE" = true ] || [ "$CLI" = codex ]; then
    # No Keychain; the global env file only for its git tokens.
    if [ -f "$GLOBAL_ENV" ]; then
        ensure_global_env_mode
        set -a
        # shellcheck source=/dev/null
        source "$GLOBAL_ENV"
        set +a
    fi
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
else
    # First hit wins:
    #   1. CLAUDE_CODE_OAUTH_TOKEN already set in the environment
    #   2. Keychain item "$KEYCHAIN_TOKEN_SERVICE": long-lived token from
    #      `claude setup-token` (valid ~1 year, nothing to refresh)
    #   3. Global env file (CLAUDE_CODE_OAUTH_TOKEN=...)
    #   4. Claude Code's own login ('Claude Code-credentials'): only the
    #      ~8h access token; the container cannot refresh it, so the
    #      container loses auth when it expires.
    KEYCHAIN_TOKEN_SERVICE="claude-devcontainer-oauth"
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && command -v security &>/dev/null; then
        CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s "$KEYCHAIN_TOKEN_SERVICE" -w 2>/dev/null || true)"
    fi

    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$GLOBAL_ENV" ]; then
        ensure_global_env_mode
        set -a
        # shellcheck source=/dev/null
        source "$GLOBAL_ENV"
        set +a
    fi

    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && command -v security &>/dev/null; then
        KEYCHAIN_CREDS="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
        if [ -n "$KEYCHAIN_CREDS" ]; then
            CLAUDE_CODE_OAUTH_TOKEN="$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$KEYCHAIN_CREDS")"
            _exp_s="$(jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' <<<"$KEYCHAIN_CREDS")"
            if [ "$_exp_s" -le "$(date +%s)" ]; then
                echo "[claude] Warning: the host login token has expired; start 'claude' on the host once to refresh it." >&2
            else
                echo "[claude] Warning: using the short-lived host login token (expires $(date -r "$_exp_s" +%H:%M))." >&2
            fi
            echo "[claude]   For a 1-year token: claude setup-token, then" >&2
            echo "[claude]   security add-generic-password -U -a \"\$USER\" -s ${KEYCHAIN_TOKEN_SERVICE} -w" >&2
        fi
    fi
fi

# ── Project .env fills in what is still unset ──
GITHUB_TOKEN="${GITHUB_TOKEN:-$(read_env_var GITHUB_TOKEN)}"
GITLAB_TOKEN="${GITLAB_TOKEN:-$(read_env_var GITLAB_TOKEN)}"
GIT_TOKEN="${GIT_TOKEN:-$(read_env_var GIT_TOKEN)}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(read_env_var GIT_AUTHOR_NAME)}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(read_env_var GIT_AUTHOR_EMAIL)}"
if [ "$GATEWAY_MODE" = false ] && [ "$CLI" = claude ]; then
    CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$(read_env_var CLAUDE_CODE_OAUTH_TOKEN)}"
fi

# Suppress remote URL rewriting when no git token is configured in .env
# (tokens from keychain/global env are for auth only — rewrite only when
# the project explicitly provides a token, or when CLAUDE_NO_GIT_REWRITE=0).
if [ -z "${CLAUDE_NO_GIT_REWRITE:-}" ]; then
    _has_env_token="$(read_env_var GITHUB_TOKEN)$(read_env_var GITLAB_TOKEN)$(read_env_var GIT_TOKEN)"
    if [ -z "$_has_env_token" ]; then
        CLAUDE_NO_GIT_REWRITE=1
    fi
fi

# ── Secrets file (mounted, not visible in docker inspect / ps) ──
# NAME=value per line, value verbatim; the entrypoint parses it, never sources it.
SECRETS_FILE="$(mktemp)"
chmod 600 "$SECRETS_FILE"
HERDR_WATCH_PID=""
HERDR_RELAY_HOST_DIR=""
cleanup() {
    rm -f "$SECRETS_FILE"
    [ -z "$HERDR_WATCH_PID" ] || kill "$HERDR_WATCH_PID" 2>/dev/null || true
    [ -z "$HERDR_RELAY_HOST_DIR" ] || rm -rf "$HERDR_RELAY_HOST_DIR"
}
trap cleanup EXIT

write_secret() {
    local name="$1" value="$2"
    [ -n "$value" ] || return 0
    if [[ "$value" == *$'\n'* ]]; then
        echo "[claude] Error: ${name} contains a newline; refusing to write it to the secrets file." >&2
        exit 1
    fi
    printf '%s=%s\n' "$name" "$value" >> "$SECRETS_FILE"
}

write_secret GITHUB_TOKEN "${GITHUB_TOKEN:-}"
write_secret GITLAB_TOKEN "${GITLAB_TOKEN:-}"
write_secret GIT_TOKEN    "${GIT_TOKEN:-}"
# Model credential from the host unless the --env file provides it.
if [ "$GATEWAY_MODE" = false ]; then
    if [ "$CLI" = codex ]; then
        write_secret OPENAI_API_KEY "${OPENAI_API_KEY:-}"
    else
        write_secret ANTHROPIC_API_KEY       "${ANTHROPIC_API_KEY:-}"
        write_secret CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}"
    fi
fi

# Non-secret config — safe to pass via -e
ENV_ARGS=()
[ -n "${GIT_AUTHOR_NAME:-}" ]           && ENV_ARGS+=(-e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}")
[ -n "${GIT_AUTHOR_EMAIL:-}" ]          && ENV_ARGS+=(-e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}")
[ -n "${CLAUDE_NO_GIT_REWRITE:-}" ]     && ENV_ARGS+=(-e "CLAUDE_NO_GIT_REWRITE=${CLAUDE_NO_GIT_REWRITE}")

# Shell knobs (model pins, flags) via -e; never credentials or URLs.
for _v in $(compgen -A variable | grep -E '^(ANTHROPIC_|CLAUDE_CODE_|OPENAI_|LITELLM_)'); do
    case "$_v" in
        ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|\
        CLAUDE_CODE_SSE_PORT|OPENAI_BASE_URL|OPENAI_API_KEY|LITELLM_API_KEY) continue ;;
    esac
    if [ -n "${!_v:-}" ]; then
        ENV_ARGS+=(-e "${_v}=${!_v}")
    fi
done

# ── Auto-prune stale instances ──
_INSTANCE_MAX_AGE="${CLAUDE_INSTANCE_MAX_AGE:-7}"   # days
_INSTANCE_BASE="${BUILD_DIR}/instances"
if [ -d "$_INSTANCE_BASE" ]; then
    for _d in "$_INSTANCE_BASE"/*/; do
        [ -d "$_d" ] || continue
        _marker="$_d.last-used"
        [ -f "$_marker" ] || _marker="$_d.seeded"
        [ -f "$_marker" ] || continue
        if [ -n "$(find "$_marker" -mtime +"$_INSTANCE_MAX_AGE" 2>/dev/null)" ]; then
            _iname="$(basename "$_d")"
            [ "$_iname" = "$INSTANCE" ] && continue
            rm -rf "$_d"
            docker volume rm "claude-devcontainer-codex-${_iname}" >/dev/null 2>&1 || true
            echo "[claude] Pruned stale instance '${_iname}'" >&2
        fi
    done
fi

# ── Concurrent-instance guard ──
# Named instances have isolated state, so only warn for unnamed instances.
if [ -z "$INSTANCE" ]; then
    _CONFLICT=$(docker ps --filter "name=${CNAME_PREFIX}" --format "{{.ID}} {{.Names}}" 2>/dev/null \
        | while read -r _id _name; do
            docker inspect "$_id" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null \
                | grep -qF "${WORKSPACE}" && echo "$_name"
        done) || true
    if [ -n "$_CONFLICT" ]; then
        echo "[claude] Warning: another claude-docker is already running in this directory ($_CONFLICT)." >&2
        echo "[claude] Two instances sharing the same workspace can cause git remote conflicts." >&2
    fi
fi

# ── Run ──
# Use -t (TTY) when in a terminal, skip it when called from Emacs (pipes)
DOCKER_ARGS=(--rm -i)
if [ -t 0 ]; then
    DOCKER_ARGS+=(-t)
fi

# ── Privileged mode (opt-in) ──
# Off by default — this container is a filesystem-isolated sandbox.  Enable with the
# --privileged flag or CLAUDE_PRIVILEGED=1 when you need host-level kernel
# access (nested Docker, mounts, iptables/NET_ADMIN, ptrace debugging, ...).
if [ "$PRIVILEGED" = true ] || [ "${CLAUDE_PRIVILEGED:-}" = 1 ]; then
    DOCKER_ARGS+=(--privileged)
    echo "[claude] Running in privileged mode" >&2
fi

# ── Extra docker run args, e.g. --add-host=host.docker.internal:host-gateway ──
if [ -n "${CLAUDE_DOCKER_RUN_ARGS:-}" ]; then
    read -r -a _extra_args <<< "${CLAUDE_DOCKER_RUN_ARGS}"
    DOCKER_ARGS+=("${_extra_args[@]}")
fi

# ── Run-as user (opt-in root) ──
# By default the container runs as your host uid so workspace files stay owned
# by you.  --root / CLAUDE_ROOT=1 runs Claude as root inside the container
# (uid 0) — handy for root-native tooling (mount -o loop, losetup, debugfs)
# under --privileged, at the cost of root-owned files in the workspace.  Claude
# refuses bypassPermissions as root, so these runs ask for permission.
RUN_AS_UID="$(id -u)"
if [ "$ROOT" = true ] || [ "${CLAUDE_ROOT:-}" = 1 ]; then
    RUN_AS_UID=0
    echo "[claude] Running as root inside the container" >&2
    # Claude writes to the mounted ~/.claude as root.  On a Linux host those files
    # would stay root-owned, so the entrypoint hands them back on exit.  Docker
    # Desktop's bind mounts already map ownership to you.
    [ "$(uname -s)" != Linux ] || ENV_ARGS+=(-e "CLAUDE_HOST_OWNER=$(id -u):$(id -g)")
fi

# ── IDE integration (Emacs claude-code-ide) ──
# The IDE starts an MCP server on the host; the container must reach it.
if [ -n "${CLAUDE_CODE_SSE_PORT:-}" ]; then
    ENV_ARGS+=(-e "CLAUDE_CODE_SSE_PORT=${CLAUDE_CODE_SSE_PORT}")
    ENV_ARGS+=(-e "ENABLE_IDE_INTEGRATION=true")
    [ -n "${TERM_PROGRAM:-}" ]         && ENV_ARGS+=(-e "TERM_PROGRAM=${TERM_PROGRAM}")
    [ -n "${FORCE_CODE_TERMINAL:-}" ]  && ENV_ARGS+=(-e "FORCE_CODE_TERMINAL=${FORCE_CODE_TERMINAL}")
    DOCKER_ARGS+=(--network host)
fi

# Volume mounts
if [ -n "$INSTANCE" ]; then
    # Named instance: isolated state directory
    INSTANCE_DIR="${BUILD_DIR}/instances/${INSTANCE}"
    mkdir -p "${INSTANCE_DIR}/claude" "${INSTANCE_DIR}/state"
    # Seed new instance with host credentials/config on first creation
    _SEED_LOCK="${INSTANCE_DIR}/.seed-lock"
    if [ ! -f "${INSTANCE_DIR}/.seeded" ]; then
        # Break stale lock from a previous crashed run
        if [ -d "$_SEED_LOCK" ]; then
            # Stale if the holder is gone (no .seeded means it never finished)
            rmdir "$_SEED_LOCK" 2>/dev/null || true
        fi
        if mkdir "$_SEED_LOCK" 2>/dev/null; then
            # Re-check after acquiring lock
            if [ ! -f "${INSTANCE_DIR}/.seeded" ]; then
                # Copy top-level files (settings, credentials, etc.)
                for f in "${HOME}/.claude"/*; do
                    [ -f "$f" ] && cp "$f" "${INSTANCE_DIR}/claude/"
                done
                # Copy config subdirs (skills, agents, rules, output-styles)
                # Exclude ephemeral/history dirs: ide, projects, todos, debug, file-history
                for d in skills agents rules output-styles; do
                    [ -d "${HOME}/.claude/${d}" ] && cp -r "${HOME}/.claude/${d}" "${INSTANCE_DIR}/claude/"
                done
                if [ -f "${HOME}/.claude.json" ]; then
                    cp "${HOME}/.claude.json" "${INSTANCE_DIR}/claude.json"
                else
                    echo '{}' > "${INSTANCE_DIR}/claude.json"
                fi
                touch "${INSTANCE_DIR}/.seeded"
            fi
            rmdir "$_SEED_LOCK" 2>/dev/null || true
        else
            # Another process holds the lock — wait for it
            echo "[claude] Another process is seeding instance '${INSTANCE}', waiting..." >&2
            while [ -d "$_SEED_LOCK" ]; do sleep 0.2; done
        fi
    fi
    touch "${INSTANCE_DIR}/.last-used"
    printf '%s' "${WORKSPACE}" > "${INSTANCE_DIR}/.workspace"
    VOL_ARGS=(
        -v "${INSTANCE_DIR}/claude:/home/node/.claude-seed:ro"
        -v "${INSTANCE_DIR}/state:/home/node/.claude"
        -v "${INSTANCE_DIR}/claude.json:/home/node/.claude.json"
        -v "${WORKSPACE}:${WORKSPACE}"
    )
else
    # Default: shared state
    VOL_ARGS=(
        -v "${HOME}/.claude:/home/node/.claude"
        -v "${WORKSPACE}:${WORKSPACE}"
    )
    # Only mount .claude.json if it exists — Docker creates an empty directory otherwise
    [ -f "${HOME}/.claude.json" ] && VOL_ARGS+=(-v "${HOME}/.claude.json:/home/node/.claude.json")
fi

# ── Codex state (codex-docker only) ──
# ~/.codex (SQLite, app-server socket) hangs on a macOS bind mount, so it is a
# named volume, one per instance.  The host's ~/.codex is never touched.
if [ "$CLI" = codex ]; then
    CODEX_VOLUME="claude-devcontainer-codex${INSTANCE:+-$INSTANCE}"
    VOL_ARGS+=(-v "${CODEX_VOLUME}:/home/node/.codex")
    ENV_ARGS+=(-e "CLAUDE_DOCKER_CLI=codex")
fi

# ── Gateway bundle: the --env file's directory ──
if [ "$GATEWAY_MODE" = true ]; then
    VOL_ARGS+=(-v "${GW_BUNDLE}:/etc/gateway-bundle:ro")
    ENV_ARGS+=(-e "CLAUDE_DOCKER_ENV=/etc/gateway-bundle/$(basename "$GW_SOURCE")")
fi

# Custom settings override: mount user-provided settings.json into the container
if [ -n "$SETTINGS_FILE" ]; then
    SETTINGS_FILE="$(cd "$(dirname "$SETTINGS_FILE")" && pwd)/$(basename "$SETTINGS_FILE")"
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo "[claude] Error: settings file '${SETTINGS_FILE}' not found." >&2
        exit 1
    fi
    VOL_ARGS+=(-v "${SETTINGS_FILE}:/etc/claude/settings.json:ro")
fi

# Custom MCP config: merged into settings.json by the entrypoint
if [ -n "$MCP_FILE" ]; then
    MCP_FILE="$(cd "$(dirname "$MCP_FILE")" && pwd)/$(basename "$MCP_FILE")"
    if [ ! -f "$MCP_FILE" ]; then
        echo "[claude] Error: MCP config file '${MCP_FILE}' not found." >&2
        exit 1
    fi
    VOL_ARGS+=(-v "${MCP_FILE}:/etc/claude/mcp.json:ro")
fi

# IDE integration: mount lockfiles so Claude Code discovers the MCP
# server. Emacs claude code package writes lockfiles to
# ~/.claude/ide/<port>.lock on the host. For named instances the
# container's ~/.claude is a separate volume, so without this
# sub-mount Claude Code can't find the lockfile and never connects to
# the WebSocket server.
if [ -n "${CLAUDE_CODE_SSE_PORT:-}" ] && [ -d "${HOME}/.claude/ide" ]; then
    VOL_ARGS+=(-v "${HOME}/.claude/ide:/home/node/.claude/ide:ro")
fi

# Worktree support: mount the main repo's .git dir if workspace is a worktree
# In a worktree, .git is a file pointing outside the workspace — git breaks without it
if [ -f "${WORKSPACE}/.git" ]; then
    MAIN_GIT="$(git -C "${WORKSPACE}" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "${MAIN_GIT}" ]; then
        # git-common-dir may be relative on older git versions — make it absolute
        [[ "${MAIN_GIT}" != /* ]] && MAIN_GIT="$(cd "${WORKSPACE}" && cd "${MAIN_GIT}" && pwd)"
        VOL_ARGS+=(-v "${MAIN_GIT}:${MAIN_GIT}")
    fi
fi

# ── Herdr (https://herdr.dev) ──
# Inside a Herdr pane, mark the docker process as the agent so Herdr tracks its
# state (Herdr does not recognise the name `claude-docker`).  For Claude, also
# relay the session id out of the container so Herdr can reopen it after a
# server restart: a SessionStart hook in the container writes the id into a
# host directory, and a watcher here reports `claude-docker ... --resume <id>`
# as the pane's resume command.  The Herdr socket never enters the container.
RUN_PREFIX=()
if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    RUN_PREFIX=(env "HERDR_AGENT=${CLI}")
    # Herdr types the command into a fresh shell, so it must resolve on PATH.
    if [ "$CLI" = claude ] && command -v herdr >/dev/null 2>&1 \
            && command -v "$(basename "$0")" >/dev/null 2>&1; then
        HERDR_RESUME_ARGV=("$(basename "$0")")
        [ -n "$INSTANCE" ]       && HERDR_RESUME_ARGV+=(-i "$INSTANCE")
        { [ "$PRIVILEGED" = true ] || [ "${CLAUDE_PRIVILEGED:-}" = 1 ]; } && HERDR_RESUME_ARGV+=(--privileged)
        { [ "$ROOT" = true ] || [ "${CLAUDE_ROOT:-}" = 1 ]; } && HERDR_RESUME_ARGV+=(--root)
        [ "$GATEWAY_MODE" = true ] && HERDR_RESUME_ARGV+=(--env "$GW_SOURCE")
        [ -n "$SETTINGS_FILE" ]  && HERDR_RESUME_ARGV+=(--settings "$SETTINGS_FILE")
        [ -n "$MCP_FILE" ]       && HERDR_RESUME_ARGV+=(--mcp "$MCP_FILE")

        HERDR_RELAY_HOST_DIR="$(mktemp -d)"
        VOL_ARGS+=(-v "${HERDR_RELAY_HOST_DIR}:/run/herdr-relay")
        ENV_ARGS+=(-e "HERDR_RELAY_DIR=/run/herdr-relay")

        herdr_relay_watch() {
            local file="${HERDR_RELAY_HOST_DIR}/session" last="" id="" tries=0 next
            # kill -0: don't outlive a wrapper that died without running cleanup.
            while sleep 1 && kill -0 "$$" 2>/dev/null; do
                # The container writes this file, so nothing in it is trusted.
                # A symlink would read a host file, and an id like --privileged
                # would become a wrapper flag when Herdr replays the command.
                [ -f "$file" ] && [ ! -L "$file" ] || continue
                next="$(head -c 256 "$file" 2>/dev/null)" || continue
                [[ "$next" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]] || continue
                [ "$next" != "$last" ] || continue
                [ "$next" = "$id" ] || { id="$next"; tries=0; }
                # Herdr accepts the command only once it has detected the agent
                # in this pane; retry for a while, then give up on this id.
                [ "$tries" -lt 30 ] || continue
                tries=$((tries + 1))
                if herdr pane report-agent-session "$HERDR_PANE_ID" \
                        --source custom:claude-docker --agent claude \
                        -- "${HERDR_RESUME_ARGV[@]}" --resume "$id" >/dev/null 2>&1; then
                    last="$id"
                fi
            done
        }
        herdr_relay_watch &
        HERDR_WATCH_PID=$!
        disown "$HERDR_WATCH_PID"   # no "Terminated" job notice when cleanup kills it
    fi
fi

# Host hooks can name host paths; the entrypoint stubs Herdr's (see there).
ENV_ARGS+=(-e "CLAUDE_HOST_HOME=${HOME}")

CONTAINER_NAME="${CNAME_PREFIX}${INSTANCE:-$$}"

# Named instances use a deterministic container name — check for conflicts
if [ -n "$INSTANCE" ] && docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
    echo "[claude] Instance '${INSTANCE}' is already running." >&2
    echo "[claude] Stop it with: docker stop ${CONTAINER_NAME}" >&2
    exit 1
fi

"${RUN_PREFIX[@]}" docker run \
    "${DOCKER_ARGS[@]}" \
    --name "${CONTAINER_NAME}" \
    -e "CLAUDE_USER=${RUN_AS_UID}" \
    -v "${SECRETS_FILE}:/run/secrets/env:ro" \
    "${VOL_ARGS[@]}" \
    -w "${WORKSPACE}" \
    "${ENV_ARGS[@]}" \
    "$IMAGE" "$@"
