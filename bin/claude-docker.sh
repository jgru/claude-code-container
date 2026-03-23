#!/bin/bash
# claude — run Claude Code in a firewalled Docker container.
# Reads git tokens + settings from the project's .env file.
#
# Install:
#   cp claude-docker ~/.local/bin/claude && chmod +x ~/.local/bin/claude

set -eo pipefail

IMAGE="claude-devcontainer"
BUILD_DIR="${CLAUDE_DEVCONTAINER_DIR:-${HOME}/.config/claude-devcontainer}"

# ── Parse wrapper flags (consumed here, not passed to claude) ──
INSTANCE=""
CLAUDE_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--instance)
            INSTANCE="$2"; shift 2 ;;
        --instance=*)
            INSTANCE="${1#--instance=}"; shift ;;
        *)
            CLAUDE_ARGS+=("$1"); shift ;;
    esac
done
set -- "${CLAUDE_ARGS[@]}"

# ── Build if missing ──
if ! docker image inspect "$IMAGE" &>/dev/null; then
    echo "[claude] Building image..." >&2
    docker build -t "$IMAGE" "$BUILD_DIR"
fi

# ── OAuth token ──
# Read from macOS Keychain (where Claude Code stores it)
# Falls back to env file or existing env var
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    if command -v security &>/dev/null; then
        KEYCHAIN_CREDS="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
        if [ -n "$KEYCHAIN_CREDS" ]; then
            # Extract accessToken from the JSON blob
            CLAUDE_CODE_OAUTH_TOKEN="$(echo "$KEYCHAIN_CREDS" | jq -r .claudeAiOauth.accessToken )"
            # if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            #     echo "[claude] Token loaded from Keychain" >&2
            # fi
        fi
    fi
fi

# Fallback: global env file
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    GLOBAL_ENV="${HOME}/.config/claude-devcontainer/env"
    if [ -f "$GLOBAL_ENV" ]; then
        set -a
        source "$GLOBAL_ENV"
        set +a
    fi
fi

# ── Read project .env (overrides global) ──
WORKSPACE="${PWD}"
ENV_FILE="${WORKSPACE}/.env"

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

GITHUB_TOKEN="${GITHUB_TOKEN:-$(read_env_var GITHUB_TOKEN)}"
GITLAB_TOKEN="${GITLAB_TOKEN:-$(read_env_var GITLAB_TOKEN)}"
GIT_TOKEN="${GIT_TOKEN:-$(read_env_var GIT_TOKEN)}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$(read_env_var GIT_AUTHOR_NAME)}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$(read_env_var GIT_AUTHOR_EMAIL)}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$(read_env_var CLAUDE_CODE_OAUTH_TOKEN)}"

# Suppress remote URL rewriting when no git token is configured in .env
# (tokens from keychain/global env are for auth only — rewrite only when
# the project explicitly provides a token, or when CLAUDE_NO_GIT_REWRITE=0).
if [ -z "${CLAUDE_NO_GIT_REWRITE:-}" ]; then
    _has_env_token="$(read_env_var GITHUB_TOKEN)$(read_env_var GITLAB_TOKEN)$(read_env_var GIT_TOKEN)"
    if [ -z "$_has_env_token" ]; then
        CLAUDE_NO_GIT_REWRITE=1
    fi
fi

ENV_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ]              && ENV_ARGS+=(-e "GITHUB_TOKEN=${GITHUB_TOKEN}")
[ -n "${GITLAB_TOKEN:-}" ]              && ENV_ARGS+=(-e "GITLAB_TOKEN=${GITLAB_TOKEN}")
[ -n "${GIT_TOKEN:-}" ]                 && ENV_ARGS+=(-e "GIT_TOKEN=${GIT_TOKEN}")
[ -n "${GIT_AUTHOR_NAME:-}" ]           && ENV_ARGS+=(-e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}")
[ -n "${GIT_AUTHOR_EMAIL:-}" ]          && ENV_ARGS+=(-e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}")
[ -n "${ANTHROPIC_API_KEY:-}" ]         && ENV_ARGS+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]   && ENV_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
[ -n "${CLAUDE_NO_GIT_REWRITE:-}" ]     && ENV_ARGS+=(-e "CLAUDE_NO_GIT_REWRITE=${CLAUDE_NO_GIT_REWRITE}")

# ── Concurrent-instance guard ──
# Named instances have isolated state, so only warn for unnamed instances.
if [ -z "$INSTANCE" ]; then
    _CONFLICT=$(docker ps --filter "name=claude-code-" --format "{{.ID}} {{.Names}}" 2>/dev/null \
        | while read -r _id _name; do
            docker inspect "$_id" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null \
                | grep -qF "${WORKSPACE}" && echo "$_name"
        done)
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

# Volume mounts
if [ -n "$INSTANCE" ]; then
    # Named instance: isolated state directory
    INSTANCE_DIR="${BUILD_DIR}/instances/${INSTANCE}"
    mkdir -p "${INSTANCE_DIR}/claude"
    # Seed new instance with host credentials/config on first creation
    if [ ! -f "${INSTANCE_DIR}/.seeded" ]; then
        for f in "${HOME}/.claude"/*; do
            [ -f "$f" ] && cp "$f" "${INSTANCE_DIR}/claude/"
        done
        if [ -f "${HOME}/.claude.json" ]; then
            cp "${HOME}/.claude.json" "${INSTANCE_DIR}/claude.json"
        else
            echo '{}' > "${INSTANCE_DIR}/claude.json"
        fi
        touch "${INSTANCE_DIR}/.seeded"
    fi
    VOL_ARGS=(
        -v "${INSTANCE_DIR}/claude:/home/node/.claude"
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

CONTAINER_NAME="claude-code-${INSTANCE:-$$}"

# Named instances use a deterministic container name — check for conflicts
if [ -n "$INSTANCE" ] && docker ps -q --filter "name=^${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
    echo "[claude] Instance '${INSTANCE}' is already running." >&2
    echo "[claude] Stop it with: docker stop ${CONTAINER_NAME}" >&2
    exit 1
fi

exec docker run \
    "${DOCKER_ARGS[@]}" \
    --name "${CONTAINER_NAME}" \
    -e CLAUDE_USER="$(id -u)" \
    "${VOL_ARGS[@]}" \
    -w "${WORKSPACE}" \
    "${ENV_ARGS[@]}" \
    "$IMAGE" "$@"
