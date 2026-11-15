# Agent sandbox image. Adapted from anthropics/claude-code/.devcontainer/Dockerfile (blob 8b48f6a, 2026-11-10).
# Deviations: node:22-bookworm-slim (the full image adds 1.3 GB of compilers and ImageMagick), agents behind
# AGENTS (default: Claude Code only), just (checksummed), JetBrains backend libs, gawk, git config for bind
# mounts, root-owned policy files, npm prefix written root-owned in one layer, argument-pinned sudoers +
# visudo check, baked api.github.com/meta snapshot for the firewall fallback, /etc/profile.d PATH entry for
# login shells, bash history for node only in a 0700 directory, python3 for the plugin scripts, the
# datenkollektiv toolbox tree baked root-owned to /opt/agents-toolbox when the build context carries toolbox/
# (install-plugins.sh registers it as a folder marketplace from postStartCommand, after init-firewall.sh);
# no zsh-in-docker, no git-delta.
FROM node:22-bookworm-slim

ARG TZ
ENV TZ="$TZ"

# Agents to install, space-separated from: claude codex gemini opencode. Each name also keeps its firewall
# allowlist fragment (allowlist.d/2x-<agent>.txt). Sizes on arm64 (2026-11-10): claude 330 MB, opencode 490 MB,
# codex 390 MB, gemini 100 MB, so the default stays Claude only; /onboard Phase 5e offers the others.
ARG AGENTS="claude"
# Pins verified 2026-11-10 against `npm view <pkg> version`.
ARG CLAUDE_CODE_VERSION=2.1.321
ARG CODEX_VERSION=0.167.0
ARG GEMINI_CLI_VERSION=0.67.0
ARG OPENCODE_VERSION=2.2.6
# Pin verified 2026-11-10: tag and tarball URL pattern exist at https://github.com/casey/just/releases.
# Hashes come from that release's SHA256SUMS asset; bump them together with JUST_VERSION.
ARG JUST_VERSION=1.59.0
ARG JUST_SHA256_X86_64=409044617b6f06517c1035e55ca38c8c856ff8b650e41bc2aa1ef82d5903a23e
ARG JUST_SHA256_AARCH64=23871b1702bfd550fb5f901778fd4290ecf2ee034a45a889fbe96d89b188086d

# Reference apt list plus curl/ca-certificates/gawk (Debian defaults to mawk; the hooks are written for
# gawk/BSD awk semantics), python3 (the datenkollektiv-security skills run ${CLAUDE_PLUGIN_ROOT}/scripts/*.py
# and would fail inside without an interpreter) and the JetBrains backend runtime libs.
RUN apt-get update && apt-get install -y --no-install-recommends \
  less git procps sudo man-db unzip gnupg2 gh curl ca-certificates \
  iptables ipset iproute2 dnsutils aggregate jq gawk nano vim python3 \
  libxext6 libxrender1 libxtst6 libxi6 libfreetype6 \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# just: pinned GitHub release tarball, SHA-256 checked before extraction (release assets are mutable);
# never piped from a URL into a shell.
RUN set -eu; arch="$(uname -m)"; \
  case "$arch" in \
    x86_64)  sum="$JUST_SHA256_X86_64" ;; \
    aarch64) sum="$JUST_SHA256_AARCH64" ;; \
    *) echo "no just checksum recorded for $arch" >&2; exit 1 ;; esac; \
  curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/just.tar.gz \
    "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${arch}-unknown-linux-musl.tar.gz"; \
  echo "$sum  /tmp/just.tar.gz" | sha256sum -c -; \
  tar -xzf /tmp/just.tar.gz -C /usr/local/bin just; rm /tmp/just.tar.gz; just --version

# The npm prefix stays root-owned from the start and the agents install as root below. A chown pass after a
# node-owned install would re-copy the whole tree into a new layer (1.96 GB observed); the reference instead
# chowns all of /usr/local/share, which hands node /usr/local/share/ca-certificates, the directory a later
# root update-ca-certificates imports into the trust store.
RUN mkdir -p /usr/local/share/npm-global

# Login shells (bash -l, JetBrains backend, ssh-style attach) lose the ENV PATH below: Debian /etc/profile
# resets PATH for non-root users. profile.d re-adds the npm prefix; root-owned 0644 so node cannot edit it.
# The snippet also runs for root login shells; that is safe only because npm-global ends up root-owned (below).
RUN printf '%s\n' 'case ":$PATH:" in *":/usr/local/share/npm-global/bin:"*) ;; *) PATH="$PATH:/usr/local/share/npm-global/bin" ;; esac' \
      'export PATH' > /etc/profile.d/npm-global.sh \
  && chmod 0644 /etc/profile.d/npm-global.sh

ARG USERNAME=node

# Persist bash history (reference snippet, applied to bash instead of zsh). /etc/bash.bashrc is system-wide,
# so the export is guarded to non-root shells: without the guard a root shell (docker exec -u root) would append
# its typed commands to a node-owned file, and `history -a` would follow a symlink node plants there.
# 0700: only node reads or writes the directory. Existing volumes keep their old mode until deleted.
RUN mkdir /commandhistory && touch /commandhistory/.bash_history \
  && chown -R $USERNAME:$USERNAME /commandhistory && chmod 0700 /commandhistory \
  && printf '%s\n' 'if [ "$(id -u)" -ne 0 ]; then export PROMPT_COMMAND="history -a" HISTFILE=/commandhistory/.bash_history; fi' >> /etc/bash.bashrc

# Set `DEVCONTAINER` environment variable to help with orientation; yolo.just refuses bypass mode without it.
ENV DEVCONTAINER=true

# Bind-mounted repos report inode/ctime drift, so git shows every file modified
# (trailofbits/claude-code-devcontainer PR #59). System-wide, so no post-create script is needed.
# safe.directory is set for node only (below, after USER node): a system-wide '*' would also let a
# root-run git in the node-writable workspace execute repo-controlled hooks (CVE-2022-24765 class).
RUN git config --system core.checkStat minimal \
  && git config --system core.trustctime false \
  && git config --system credential.https://github.com.helper '!gh auth git-credential'

# Agent homes exist in the image so the ${devcontainerId} volumes inherit node ownership and the seed
# files on first mount. Later template changes do not reach existing volumes (delete the volume to re-seed).
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex /home/node/.gemini /home/node/.local/share/opencode \
  && chown -R node:node /workspace /home/node
COPY --chown=node:node codex-config.toml /home/node/.codex/config.toml
COPY --chown=node:node gemini-settings.json /home/node/.gemini/settings.json

# Policy: Claude Code managed settings and OpenCode system config, root-owned, not writable by node.
COPY managed-settings.json /etc/claude-code/managed-settings.json
COPY opencode.json /etc/opencode/opencode.json
RUN chmod 0755 /etc/claude-code /etc/opencode \
  && chmod 0644 /etc/claude-code/managed-settings.json /etc/opencode/opencode.json

# Firewall script, allowlist fragments and template version. Fragments of agents not in AGENTS are
# removed, so the allowlist is composed per enabled agent at build time and cannot be widened from inside.
# The trailing "" in the sudoers entry pins the command to no arguments: `sudo init-firewall.sh --check <dir>`
# would otherwise read any *.txt in a node-chosen directory as root and echo its first offending line.
# github-meta.json is the build-time snapshot init-firewall.sh falls back to when the live api.github.com/meta
# fetch fails; the build fails without it, because an image without a snapshot carries dead recovery code.
COPY init-firewall.sh /usr/local/bin/
COPY allowlist.d/ /etc/devcontainer-firewall/allowlist.d/
COPY VERSION /etc/devcontainer-firewall/VERSION
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
  && for a in claude codex gemini opencode; do \
       case " $AGENTS " in *" $a "*) ;; *) rm -f /etc/devcontainer-firewall/allowlist.d/*-"$a".txt ;; esac; done \
  && curl -fsS --proto '=https' --max-time 20 -o /etc/devcontainer-firewall/github-meta.json https://api.github.com/meta \
  && jq -e '.web and .api and .git' /etc/devcontainer-firewall/github-meta.json >/dev/null \
  && chmod -R a+rX,go-w /etc/devcontainer-firewall \
  && echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh ""' > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall \
  && visudo -cf /etc/sudoers.d/node-firewall

# datenkollektiv plugins. /onboard Phase 5e copies the plugin-relevant toolbox tree (.claude-plugin, skills,
# shared, hooks, scripts, prompts) into .devcontainer/toolbox/; the toolbox's own devcontainer/ template never
# carries it (it would be a copy of the repo inside itself), so the build must work both ways. COPY cannot
# be conditional, and `COPY . <tmp>` + a later rm would still ship the whole .devcontainer/ context (compose
# env files, certificates, whatever a project drops there) as a layer of every image. The context is instead
# bind-mounted into this one RUN step (BuildKit, default since Docker 23 and always on in the devcontainer
# CLI); the mount is gone when the step ends, and only toolbox/ is copied out, when present. Root-owned, not
# writable by node: install-plugins.sh registers it as a folder marketplace from postStartCommand, after
# init-firewall.sh, and folder marketplaces load in place, so the skills node runs are the ones baked here.
COPY install-plugins.sh /usr/local/bin/
RUN --mount=type=bind,source=.,target=/tmp/sandbox-ctx set -eu; \
  if [ -d /tmp/sandbox-ctx/toolbox ]; then \
    cp -a /tmp/sandbox-ctx/toolbox /opt/agents-toolbox \
    && chown -R root:root /opt/agents-toolbox \
    && chmod -R a+rX,go-w /opt/agents-toolbox \
    && echo "baked toolbox/ to /opt/agents-toolbox ($(find /opt/agents-toolbox -type f | wc -l) files)"; \
  else \
    echo 'no toolbox/ in build context: datenkollektiv plugins are not baked in'; \
  fi; \
  chmod 0755 /usr/local/bin/install-plugins.sh

WORKDIR /workspace

# Global npm prefix; the agents install here as root, so the CLI that evaluates managed-settings.json, hooks
# and auto mode is never writable by the user it constrains. Auto-update is disabled for every agent, so node
# needs no write access at runtime; a runtime `npm install -g` as node fails with EACCES by design.
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Pinned agents; auto-updates are disabled by containerEnv / seeded config, so the pin holds.
# Exact versions only: npm takes dist.integrity from the registry at build time, and global installs have
# no lockfile, so there is no build-side integrity pin (unlike the just tarball above).
# Install scripts run on purpose: the postinstall of @anthropic-ai/claude-code and @opencode/cli places the
# platform binary, and both CLIs refuse to start without it (observed 2026-11-10 with --ignore-scripts:
# "claude native binary not installed", "postinstall script was not run"). The pins are exact versions, so
# the scripts that run are the ones reviewed with the pin. NPM_CONFIG_IGNORE_SCRIPTS=true in devcontainer.json
# only reaches runtime npm calls, not this build.
# Those postinstalls hard-link the platform binary into bin/; a later chown -R layer would split every hard
# link into two full copies on overlayfs (observed: +1.96 GB), which is why nothing touches this tree afterwards.
# Every enabled agent must answer --version before the layer is accepted.
RUN set -eu; pkgs=""; for a in $AGENTS; do case "$a" in \
      claude)   pkgs="$pkgs @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" ;; \
      codex)    pkgs="$pkgs @openai/codex@${CODEX_VERSION}" ;; \
      gemini)   pkgs="$pkgs @google/gemini-cli@${GEMINI_CLI_VERSION}" ;; \
      opencode) pkgs="$pkgs @opencode/cli@${OPENCODE_VERSION}" ;; \
      *) echo "unknown agent in AGENTS: $a" >&2; exit 1 ;; esac; done; \
    npm install -g $pkgs && npm cache clean --force; \
    for a in $AGENTS; do "$a" --version; done

# Set the default editor and visual
ENV EDITOR=nano
ENV VISUAL=nano

# Set up non-root user
USER node

# Bind mounts show the workspace as foreign-owned; opt node (and only node) out of git's ownership check.
RUN git config --global safe.directory '*'
