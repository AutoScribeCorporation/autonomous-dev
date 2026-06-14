# autonomous-dev dispatcher image (AutoScribeCorporation deploy).
# Runs the zxkane issue->PR->review->merge loop against QuantFlowsCorporation/backend,
# with Claude Code as the worker. Sandboxed: NO docker.sock, no host mounts beyond the
# App key + a work volume. Claude reaches Anthropic via the France ts-exit proxy
# (HK geo-block); GitHub is reached directly (NO_PROXY).
FROM node:20-bookworm-slim

# Tooling the dispatcher + wrappers need: git, jq, curl, openssl (App JWT), gh CLI.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl jq ca-certificates openssl procps gnupg python3 \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update && apt-get install -y --no-install-recommends gh \
  && rm -rf /var/lib/apt/lists/*

# Claude Code worker — pinned to the version verified working in code-server.
# Renovate-bumpable; re-verify headless auth after a bump.
ARG CLAUDE_VERSION=2.1.173
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION} && npm cache clean --force

# The pipeline (fork scripts) live here, read-only at runtime.
COPY skills/ /opt/autonomous-dev/skills/
# autonomous.conf MUST live in the scripts dir: dispatch-local.sh (and the dev/review
# wrappers) load it via ${SCRIPT_DIR}/autonomous.conf, NOT via $AUTONOMOUS_CONF.
COPY deploy/autonomous.conf /opt/autonomous-dev/skills/autonomous-dispatcher/scripts/autonomous.conf
COPY deploy/entrypoint.sh /opt/autonomous-dev/entrypoint.sh
RUN chmod +x /opt/autonomous-dev/entrypoint.sh \
  && find /opt/autonomous-dev/skills -name '*.sh' -exec chmod +x {} +

# Run as non-root (the base image's `node` user, uid 1000). REQUIRED: Claude Code
# refuses --dangerously-skip-permissions / bypassPermissions when running as root.
# uid 1000 also matches the IDE's `coder` user, so the seeded subscription creds
# (owned by 1000) are already readable/writable here. Pre-create + own the runtime
# dirs so fresh named volumes inherit node ownership on first mount.
RUN mkdir -p /work /home/node/.claude /home/node/.config \
    && chown -R node:node /work /home/node
ENV AUTONOMOUS_CONF=/opt/autonomous-dev/skills/autonomous-dispatcher/scripts/autonomous.conf \
    HOME=/home/node
USER node
WORKDIR /work
ENTRYPOINT ["/opt/autonomous-dev/entrypoint.sh"]
