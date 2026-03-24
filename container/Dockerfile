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
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER node
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/node/.local/bin:${PATH}"
USER root

RUN mkdir -p /home/${USERNAME}/.claude \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.claude

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY git-credential-token /usr/local/bin/git-credential-token
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/git-credential-token \
    && chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/git-credential-token

ENV DEVCONTAINER=true
ENV NODE_OPTIONS="--max-old-space-size=4096"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
