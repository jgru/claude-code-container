#!/bin/bash
set -e

# ── Determine user ──
RUN_UID="${CLAUDE_USER:-1000}"
if ! [[ "$RUN_UID" =~ ^[0-9]+$ ]]; then
    echo "[entrypoint] Error: CLAUDE_USER must be numeric, got '${RUN_UID}'" >&2
    exit 1
fi

if ! getent passwd "$RUN_UID" &>/dev/null; then
    echo "claude:x:${RUN_UID}:${RUN_UID}::/home/node:/bin/bash" >> /etc/passwd
fi

export HOME="/home/node"

# ── Load secrets from mounted file (not passed via env flags) ──
if [ -f /run/secrets/env ]; then
    set -a
    . /run/secrets/env
    set +a
fi

# ── Seed new named instance state (first use only) ──
# The seed is mounted read-only; on first use copy it into the writable state
# directory so the instance starts authenticated.  Subsequent runs skip this
# and use the already-accumulated state directly.
if [ -d /home/node/.claude-seed ] && [ -z "$(ls -A /home/node/.claude 2>/dev/null)" ]; then
    cp -a /home/node/.claude-seed/. /home/node/.claude/
    chown -R "$RUN_UID" /home/node/.claude
fi

# ── Git config ──
# Write to a temp file — macOS bind mounts may not let us write to $HOME
GIT_HOME=$(mktemp -d)
chown "$RUN_UID" "$GIT_HOME"
export GIT_CONFIG_GLOBAL="$GIT_HOME/.gitconfig"

run_as() { gosu "$RUN_UID" "$@"; }

run_as git config --global credential.helper token
run_as git config --global user.name  "${GIT_AUTHOR_NAME:-Claude Code}"
run_as git config --global user.email "${GIT_AUTHOR_EMAIL:-claude@devcontainer}"
run_as git config --global --add safe.directory "${PWD:-/workspace}"

# insteadOf rewrites — safety net for submodules and hardcoded URLs
if [ -n "${GITHUB_TOKEN:-}" ]; then
    run_as git config --global url."https://github.com/".insteadOf  "git@github.com:"
    run_as git config --global url."https://github.com/".insteadOf  "ssh://git@github.com/"
    echo "[git] GitHub token configured"
fi
if [ -n "${GITLAB_TOKEN:-}" ]; then
    for host in "gitlab.com"; do
        run_as git config --global url."https://${host}/".insteadOf "git@${host}:"
        run_as git config --global url."https://${host}/".insteadOf "ssh://git@${host}/"
    done
    echo "[git] GitLab token configured"
fi

# ── Rewrite SSH remotes to HTTPS ──────────────────────────────────────
# Claude Code inspects `git remote -v`; if the URL looks like SSH it
# refuses to push (ssh client is not in the container).  The insteadOf
# rules above only affect git's transport layer — `git remote -v` still
# shows the original SSH URL.  So we rewrite the configured remote URLs
# directly and restore them when the last container exits.
#
# A flock-guarded refcount tracks how many containers are using the
# rewritten URLs.  The first container saves the original URLs and
# rewrites; subsequent containers just bump the count.  On exit each
# container decrements; the last one (count reaches 0) restores the
# original URLs.
#
# Set CLAUDE_NO_GIT_REWRITE=1 to skip this (e.g. when no token is configured).

_REWRITE_DIR=""

if [ -d "${PWD}/.git" ] && [ "${CLAUDE_NO_GIT_REWRITE:-}" != "1" ]; then
    _REWRITE_DIR="${PWD}/.git/claude-docker-rewrite"
    mkdir -p "$_REWRITE_DIR"
    _LOCK="${_REWRITE_DIR}/lock"
    _COUNT_FILE="${_REWRITE_DIR}/count"
    _SAVED_DIR="${_REWRITE_DIR}/saved"

    exec 9>"$_LOCK"
    flock 9

    _COUNT=$(cat "$_COUNT_FILE" 2>/dev/null || echo 0)

    if [ "$_COUNT" -eq 0 ]; then
        # First container: save original URLs and rewrite
        mkdir -p "$_SAVED_DIR"
        for name in $(run_as git remote 2>/dev/null); do
            url=$(run_as git remote get-url "$name" 2>/dev/null) || continue
            new=""
            case "$url" in
                git@github.com:*)       [ -n "${GITHUB_TOKEN:-}" ] && new="https://github.com/${url#git@github.com:}" ;;
                ssh://git@github.com/*) [ -n "${GITHUB_TOKEN:-}" ] && new="https://github.com/${url#ssh://git@github.com/}" ;;
                git@gitlab.com:*)       [ -n "${GITLAB_TOKEN:-}" ] && new="https://gitlab.com/${url#git@gitlab.com:}" ;;
                ssh://git@gitlab.com/*) [ -n "${GITLAB_TOKEN:-}" ] && new="https://gitlab.com/${url#ssh://git@gitlab.com/}" ;;
            esac
            if [ -n "$new" ]; then
                echo "$url" > "$_SAVED_DIR/$name"
                run_as git remote set-url "$name" "$new"
                echo "[git] Rewrote remote '$name' → HTTPS"
            fi
        done
    fi

    echo $(( _COUNT + 1 )) > "$_COUNT_FILE"
    flock -u 9
fi

cleanup() {
    [ -z "$_REWRITE_DIR" ] && return
    _LOCK="${_REWRITE_DIR}/lock"
    _COUNT_FILE="${_REWRITE_DIR}/count"
    _SAVED_DIR="${_REWRITE_DIR}/saved"

    exec 9>"$_LOCK"
    flock 9

    _COUNT=$(cat "$_COUNT_FILE" 2>/dev/null || echo 1)
    _COUNT=$(( _COUNT - 1 ))

    if [ "$_COUNT" -le 0 ]; then
        # Last container: restore original URLs
        if [ -d "$_SAVED_DIR" ]; then
            for f in "$_SAVED_DIR"/*; do
                [ -f "$f" ] || continue
                name="$(basename "$f")"
                url="$(cat "$f")"
                run_as git remote set-url "$name" "$url" 2>/dev/null || true
            done
            rm -rf "$_SAVED_DIR"
        fi
        rm -f "$_COUNT_FILE"
    else
        echo "$_COUNT" > "$_COUNT_FILE"
    fi

    flock -u 9
}

# ── IDE integration: bridge loopback → host ──────────────────────────
# Emacs runs a WebSocket MCP server on host 127.0.0.1:$CLAUDE_CODE_SSE_PORT.
# With --network host on native Linux the loopback is shared and Claude Code
# connects directly.  On Docker Desktop (macOS/Windows) --network host may
# be a no-op; we forward the port via host.docker.internal so the connection
# still succeeds.  If the port is already reachable (true --network host)
# the bind fails harmlessly.
if [ -n "${CLAUDE_CODE_SSE_PORT:-}" ] && [ -n "${ENABLE_IDE_INTEGRATION:-}" ]; then
    _HOST_IP=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1}')
    if [ -n "$_HOST_IP" ]; then
        gosu "$RUN_UID" \
          socat TCP-LISTEN:"${CLAUDE_CODE_SSE_PORT}",bind=127.0.0.1,reuseaddr,fork \
                TCP:"${_HOST_IP}":"${CLAUDE_CODE_SSE_PORT}" 2>/dev/null &
    fi
fi

# ── Run claude, then clean up ─────────────────────────────────────────
# Cannot use exec — the EXIT trap must fire to restore remotes.
trap cleanup EXIT
trap 'kill -TERM $PID 2>/dev/null' TERM INT

gosu "$RUN_UID" claude "$@" &
PID=$!
wait "$PID" 2>/dev/null
exit $?
