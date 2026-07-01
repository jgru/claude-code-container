#!/bin/bash
set -e

# ── Determine user ──
# The image ships a `node` user (uid 1000) that owns /home/node and all the
# baked config.  The wrapper runs us as the host uid (CLAUDE_USER) so files
# created in the bind-mounted workspace are owned by the caller.  Rather than
# invent a second `claude` username for that uid — the old node/claude split,
# which also broke sudo via a passwd-only account with no shadow entry — we
# REMAP the existing `node` user to the host uid.  One identity, owns its home.
RUN_UID="${CLAUDE_USER:-1000}"
if ! [[ "$RUN_UID" =~ ^[0-9]+$ ]]; then
    echo "[entrypoint] Error: CLAUDE_USER must be numeric, got '${RUN_UID}'" >&2
    exit 1
fi

NODE_UID="$(id -u node 2>/dev/null || echo 1000)"
if [ "$RUN_UID" != "0" ] && [ "$RUN_UID" != "$NODE_UID" ] \
   && ! getent passwd "$RUN_UID" &>/dev/null; then
    # Remap node -> host uid (prefer usermod; fall back to editing passwd/group).
    if command -v usermod &>/dev/null && usermod -u "$RUN_UID" node 2>/dev/null; then
        groupmod -g "$RUN_UID" node 2>/dev/null || true
    else
        sed -i -E "s/^node:x:[0-9]+:[0-9]+:/node:x:${RUN_UID}:${RUN_UID}:/" /etc/passwd
        sed -i -E "s/^node:x:[0-9]+:/node:x:${RUN_UID}:/"                    /etc/group 2>/dev/null || true
    fi
    # Re-own the baked home so the remapped node owns it — but NEVER the
    # bind-mounted .claude* (that maps the host's real dir).  -xdev keeps find
    # on the container fs; the -prune guards belt-and-suspenders the mounts.
    find /home/node -xdev \
         -path /home/node/.claude      -prune -o \
         -path /home/node/.claude.json -prune -o \
         -path /home/node/.claude-seed -prune -o \
         -print0 2>/dev/null \
      | xargs -0r chown -h "$RUN_UID:$RUN_UID" 2>/dev/null || true
fi

# Safety net: if the uid still isn't resolvable (remap tooling absent and it's
# not a pre-existing account), synthesize a `claude` user so gosu can run as
# it — with a shadow entry so sudo's PAM account phase doesn't fail
# ("account validation failure, is your account locked?").
if ! getent passwd "$RUN_UID" &>/dev/null; then
    echo "claude:x:${RUN_UID}:${RUN_UID}::/home/node:/bin/bash" >> /etc/passwd
    echo "claude:*:19000:0:99999:7:::"                          >> /etc/shadow
fi

echo "[entrypoint] Running as uid ${RUN_UID} ($(getent passwd "$RUN_UID" | cut -d: -f1 2>/dev/null || echo '?'))" >&2

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

# ── Container settings ──
# Deploy the container-specific settings.json if none exists yet.
# For bind-mounted ~/.claude (unnamed instances) this respects existing
# host settings; for named instances it provides a sensible default.
_SETTINGS_FRESH=false
if [ -f /etc/claude/settings.json ] && [ ! -f /home/node/.claude/settings.json ]; then
    cp /etc/claude/settings.json /home/node/.claude/settings.json
    chown "$RUN_UID" /home/node/.claude/settings.json
    _SETTINGS_FRESH=true
    echo "[claude] Installed container settings.json"
fi

# ── MCP servers ──
# Conditionally enable MCP servers based on available credentials and
# merge any custom MCP config mounted at /etc/claude/mcp.json.
_MCP_NEEDED=false
_HAS_NOTEBOOKLM=false
[ "$_SETTINGS_FRESH" = true ] && _MCP_NEEDED=true
[ -f /etc/claude/mcp.json ] && _MCP_NEEDED=true
if command -v notebooklm-mcp &>/dev/null; then
    _HAS_NOTEBOOKLM=true
    [ "$_SETTINGS_FRESH" = true ] && _MCP_NEEDED=true
fi

if [ "$_MCP_NEEDED" = true ] && [ -f /home/node/.claude/settings.json ]; then
    _FRESH="$_SETTINGS_FRESH" _HAS_NOTEBOOKLM="$_HAS_NOTEBOOKLM" node -e "
const fs = require('fs');
const p = '/home/node/.claude/settings.json';
const s = JSON.parse(fs.readFileSync(p, 'utf8'));
s.mcpServers = s.mcpServers || {};
let changed = false;

// GitHub MCP server — auto-enable on fresh settings when token is available
if (process.env._FRESH === 'true' && process.env.GITHUB_TOKEN && !s.mcpServers.github) {
    s.mcpServers.github = {
        command: 'mcp-server-github',
        env: { GITHUB_PERSONAL_ACCESS_TOKEN: '${GITHUB_TOKEN}' }
    };
    process.stderr.write('[mcp] Enabled GitHub server\n');
    changed = true;
}

// NotebookLM MCP server — auto-enable when package is installed (Dockerfile.full)
if (process.env._HAS_NOTEBOOKLM === 'true' && !s.mcpServers.notebooklm) {
    s.mcpServers.notebooklm = {
        command: 'notebooklm-mcp',
        env: { HEADLESS: 'true' }
    };
    process.stderr.write('[mcp] Enabled NotebookLM server\n');
    changed = true;
}

// Merge custom MCP config if mounted via --mcp flag
try {
    const ext = JSON.parse(fs.readFileSync('/etc/claude/mcp.json', 'utf8'));
    const servers = ext.mcpServers || ext;
    for (const [k, v] of Object.entries(servers)) {
        if (typeof v === 'object' && v !== null) {
            s.mcpServers[k] = v;
            changed = true;
        }
    }
    if (changed) process.stderr.write('[mcp] Merged custom MCP config\n');
} catch {}

if (changed) fs.writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
" 2>&1
    chown "$RUN_UID" /home/node/.claude/settings.json
fi

# ── GSD framework (Dockerfile.full only) ──────────────────────────────
# GSD (Git. Ship. Done.) is baked into the image at /opt/gsd.  Its hooks,
# statusline and ~180 skill references hard-code absolute paths under
# /home/node/.claude, but that directory is bind-mounted over at runtime,
# so the baked copy is shadowed.  Inject it into the live state directory
# on first use.
#
# Restricted to NAMED INSTANCES: a named instance's ~/.claude is a
# container-private state directory (the read-only seed at .claude-seed is
# its tell), so writing GSD's files and container-only hook paths there is
# safe.  The default/shared mount maps the user's real host ~/.claude — we
# must never write GSD's host-invalid hook paths into that.
#
# Idempotent: keyed on the presence of gsd-core/, so it runs once per
# instance and never duplicates merged hooks.
if [ -d /opt/gsd ] && [ -d /home/node/.claude-seed ] \
   && [ ! -d /home/node/.claude/gsd-core ]; then
    echo "[gsd] Injecting GSD framework into instance state"

    # Copy the framework payload, merging into any seeded skills/agents.
    # settings.json is handled separately so we don't clobber the
    # instance's own settings.
    for item in /opt/gsd/* /opt/gsd/.[!.]*; do
        [ -e "$item" ] || continue
        base="$(basename "$item")"
        [ "$base" = "settings.json" ] && continue
        if [ -d "$item" ]; then
            mkdir -p "/home/node/.claude/$base"
            cp -a "$item/." "/home/node/.claude/$base/"
        else
            cp -a "$item" "/home/node/.claude/$base"
        fi
    done

    # Merge GSD's hooks / statusLine / permissions into the instance
    # settings.json (preserving the instance's existing statusLine etc.).
    if [ ! -f /home/node/.claude/settings.json ]; then
        cp /opt/gsd/settings.json /home/node/.claude/settings.json
    else
        node -e '
const fs = require("fs");
const dst = "/home/node/.claude/settings.json";
const s = JSON.parse(fs.readFileSync(dst, "utf8"));
const g = JSON.parse(fs.readFileSync("/opt/gsd/settings.json", "utf8"));
s.hooks = s.hooks || {};
for (const [evt, arr] of Object.entries(g.hooks || {})) {
    s.hooks[evt] = (s.hooks[evt] || []).concat(arr);
}
if (g.statusLine && !s.statusLine) s.statusLine = g.statusLine;
if (g.permissions) {
    s.permissions = s.permissions || {};
    for (const k of ["allow", "deny", "ask"]) {
        if (!g.permissions[k]) continue;
        s.permissions[k] = Array.from(new Set((s.permissions[k] || []).concat(g.permissions[k])));
    }
}
fs.writeFileSync(dst, JSON.stringify(s, null, 2) + "\n");
'
    fi

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
