#!/bin/bash
set -e

# ── Determine user ──
RUN_UID="${CLAUDE_USER:-1000}"

if ! getent passwd "$RUN_UID" &>/dev/null; then
    echo "claude:x:${RUN_UID}:${RUN_UID}::/home/node:/bin/bash" >> /etc/passwd
fi

# ── Git config ──
# Use a temp dir for .gitconfig (macOS Docker bind mounts are not writable)
GIT_HOME=$(mktemp -d)
chown "$RUN_UID" "$GIT_HOME"
export GIT_CONFIG_GLOBAL="$GIT_HOME/.gitconfig"

gosu "$RUN_UID" git config --global credential.helper token

if [ -n "${GITHUB_TOKEN:-}" ]; then
    gosu "$RUN_UID" git config --global url."https://github.com/".insteadOf "git@github.com:"
    gosu "$RUN_UID" git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
    echo "[git] GitHub token configured"
fi

if [ -n "${GITLAB_TOKEN:-}" ]; then
    for host in \
        "gitlab.com" \
    ; do
        gosu "$RUN_UID" git config --global url."https://${host}/".insteadOf "git@${host}:"
        gosu "$RUN_UID" git config --global url."https://${host}/".insteadOf "ssh://git@${host}/"
    done
    echo "[git] GitLab token configured"
fi

gosu "$RUN_UID" git config --global user.name "${GIT_AUTHOR_NAME:-Claude Code}"
gosu "$RUN_UID" git config --global user.email "${GIT_AUTHOR_EMAIL:-claude@devcontainer}"
gosu "$RUN_UID" git config --global --add safe.directory "${PWD:-/workspace}"

# ── Drop privileges and exec claude ──
export HOME=/home/node
exec gosu "$RUN_UID" claude "$@"
