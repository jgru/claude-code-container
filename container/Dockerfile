FROM node:22-slim

ARG USERNAME=node

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    iproute2 \
    dnsutils \
    git \
    ca-certificates \
    curl \
    gosu \
    socat \
    sudo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Passwordless sudo for the unprivileged runtime user, so the agent can
# install packages mid-session without running as root (keeps workspace
# files owned by the host uid).  The entrypoint runs claude as the host
# uid, which is user `node` (uid 1000) or `claude` (any other uid — see
# entrypoint.sh), so grant both.  NOTE: runtime installs are ephemeral
# (the container is --rm) — bake durable tools into this image instead.
RUN printf '%s\n' 'node ALL=(ALL) NOPASSWD:ALL' 'claude ALL=(ALL) NOPASSWD:ALL' \
        > /etc/sudoers.d/claude-agent \
    && chmod 0440 /etc/sudoers.d/claude-agent

RUN npm install -g @modelcontextprotocol/server-github

USER node
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/node/.local/bin:${PATH}"
USER root

RUN mkdir -p /home/${USERNAME}/.claude \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.claude

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY git-credential-token /usr/local/bin/git-credential-token
COPY settings.json /etc/claude/settings.json
COPY statusline.js /etc/claude/statusline.js
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/git-credential-token \
    && chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/git-credential-token

ENV DEVCONTAINER=true
ENV NODE_OPTIONS="--max-old-space-size=4096"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
