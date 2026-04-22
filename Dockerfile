# =============================================================================
# windows-ai-sandbox — shared dev image for the per-profile pattern
# =============================================================================
#   Base: NVIDIA CUDA 12.6.3 on Ubuntu 24.04.
#   Runs as root. Rootless Docker's userns=host maps container UID 0 to host
#   UID 1000, so workspace bind mounts stay writable. See
#   .devcontainer/ROOTLESS-DOCKER-NOTES.md for the why.
#
#   Everything a profile needs is baked here; per-profile auth/config lives in
#   bind mounts under ~/.ai-sandbox/profiles/<profile>/ at runtime.
# =============================================================================

FROM nvidia/cuda:12.6.3-base-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------- system packages --------------------------------------------------
# bubblewrap + socat: Claude Code's in-process sandbox.
# tini: PID 1 signal handling.
# build-essential + python3-venv: native builds for ML wheels.
# ripgrep/jq/less/vim-tiny: agent + interactive ergonomics.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git \
      bubblewrap socat tini \
      build-essential \
      python3 python3-pip python3-venv \
      ripgrep jq less vim-tiny \
      openssh-client \
      zsh lsd fontconfig locales lsof \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Node.js 20 + Claude Code (baked, auth at runtime) ----------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- uv (Python package manager) --------------------------------------
# Install system-wide so PATH ordering is irrelevant.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv  /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Baseline venv used by VS Code's Python default interpreter setting.
# Users typically create per-repo venvs under /workspace/<repo>/.venv.
RUN uv venv --python 3.12 /root/.venv

# ---------- GitHub CLI (gh) --------------------------------------------------
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- GitLab CLI (glab) — official release tarball, arch-aware ---------
ARG GLAB_VERSION=1.92.1
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      amd64) GARCH=x86_64 ;; \
      arm64) GARCH=arm64 ;; \
      *)     echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${GARCH}.tar.gz" \
      | tar -xz -C /tmp bin/glab \
 && mv /tmp/bin/glab /usr/local/bin/glab \
 && rm -rf /tmp/bin \
 && chmod 0755 /usr/local/bin/glab

# ---------- zsh + oh-my-zsh + powerlevel10k + plugins -----------------------
# Dotfiles come in via `config/`. Fonts are a host-terminal concern, not baked.
COPY config/.zshrc    /root/.zshrc
COPY config/.p10k.zsh /root/.p10k.zsh

ENV RUNZSH=no CHSH=no
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc \
 && ZSH_CUSTOM="/root/.oh-my-zsh/custom" \
 && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git                    "$ZSH_CUSTOM/themes/powerlevel10k" \
 && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git            "$ZSH_CUSTOM/plugins/zsh-autosuggestions" \
 && git clone --depth=1 https://github.com/marlonrichert/zsh-autocomplete.git           "$ZSH_CUSTOM/plugins/zsh-autocomplete" \
 && git clone --depth=1 https://github.com/zsh-users/zsh-history-substring-search.git   "$ZSH_CUSTOM/plugins/zsh-history-substring-search" \
 && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git        "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" \
 && usermod -s /usr/bin/zsh root

# ---------- runtime layout ---------------------------------------------------
# Expected bind mounts (see docker-compose.yml):
#   /workspace                <- ~/repo/<profile>/
#   /root/.claude             <- ~/.ai-sandbox/profiles/<profile>/claude-home
#   /root/.claude.json        <- ~/.ai-sandbox/profiles/<profile>/claude.json
#   /root/.cache              <- ~/.ai-sandbox/profiles/<profile>/cache
#   /root/.config             <- ~/.ai-sandbox/profiles/<profile>/config
ENV HOME=/root \
    SHELL=/usr/bin/zsh \
    PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

USER root
WORKDIR /workspace

ENTRYPOINT ["tini", "--"]
CMD ["sleep", "infinity"]
