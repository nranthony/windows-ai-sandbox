# =============================================================================
# windows-ai-sandbox — shared dev image for the per-profile pattern
# =============================================================================
#   Base: NVIDIA CUDA 12.6.3 on Ubuntu 24.04.
#   Runs as root. Rootless Docker's userns=host maps container UID 0 to host
#   UID 1000, so workspace bind mounts stay writable. See
#   CLAUDE.md § "Security Posture" for the why.
#
#   Everything a profile needs is baked here; per-profile auth/config lives in
#   bind mounts under ~/.ai-sandbox/profiles/<profile>/ at runtime.
#
#   Base digest pinned — captured at first successful build so the image is
#   reproducible across rebuilds. To re-pin after bumping CUDA:
#     docker pull nvidia/cuda:<new-tag>
#     docker inspect --format='{{index .RepoDigests 0}}' nvidia/cuda:<new-tag>
#   and paste the @sha256:... portion below.
# =============================================================================

FROM nvidia/cuda:12.6.3-base-ubuntu24.04@sha256:c87e78933f4c16e3272123bf2f75537306596d0fbaa395a29696a22786e5ee0e

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------- system packages --------------------------------------------------
# tini: PID 1 signal handling.
# build-essential + python3-venv: native builds for ML wheels.
# ripgrep/jq/less/vim-tiny: agent + interactive ergonomics.
# just (command runner) is NOT here — noble ships only 1.21.0, too old for
# recipe attributes like [doc(...)]; baked from upstream below instead.
# NOT installed (deliberate, see sandbox-hardening-package.md §7):
#   - bubblewrap:     Claude Code's in-process sandbox needs unprivileged user
#                     namespaces, which our seccomp profile correctly blocks.
#                     The container is the security boundary; bwrap-inside
#                     would be redundant nesting that breaks Bash.
#   - socat:          raw-TCP exfil channel bypassing the HTTP-only Squid proxy.
#   - openssh-client: ssh/scp/sftp/ssh-agent are the tool surface that would
#                     weaponize VS Code's SSH_AUTH_SOCK forwarding if the host
#                     setting (remote.SSH.enableAgentForwarding) ever reverts.
#                     Purging physically closes the exfil path. gh/glab auth
#                     with HTTPS tokens; git uses HTTPS remotes; Claude's
#                     permission profile already denies `git push/clone/fetch`.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git \
      tini \
      build-essential \
      python3 python3-pip python3-venv \
      ripgrep jq less vim-tiny \
      postgresql-client \
      tesseract-ocr poppler-utils \
      zsh lsd fontconfig locales lsof \
 && apt-get purge -y openssh-client \
 && if dpkg -l openssh-client 2>/dev/null | awk '/^ii/{found=1} END{exit !found}'; then \
      echo "FATAL: openssh-client still installed after purge — invariant violated" >&2; \
      exit 1; \
    fi \
 && apt-get autoremove -y \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Playwright / Chromium runtime libraries --------------------------
# Headless Chromium needs ~20 shared libraries that the base image doesn't
# ship. Without these the binary won't start even after `playwright install
# chromium`. Baked in because the agent runs as root with cap_drop: ALL +
# no_new_privs — apt-get can't acquire locks at runtime with these restrictions.
# Adds ~150 MB. Justifiable: any profile doing JS-heavy crawling reuses them.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libglib2.0-0t64 libnspr4 libnss3 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 \
      libdbus-1-3 libcups2t64 \
      libxcb1 libxkbcommon0 libx11-6 libxcomposite1 libxdamage1 \
      libxext6 libxfixes3 libxrandr2 \
      libgbm1 libcairo2 libpango-1.0-0 libasound2t64 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Node.js 24 + global npm tooling ---------------------------------
# The AI CLIs (Claude Code + Antigravity `agy`) are installed LAST, in the
# refresh layer near the end of this file — so bumping them rebuilds only that
# tail, not this heavy Node/CUDA/uv/font stack. See "AI CLI refresh layer".
# Upgrade bundled npm first — NodeSource ships an older npm whose vendored
# deps (tar, cross-spawn, glob, minimatch) accumulate CVEs between publishes.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g npm@latest \
 && npm install -g mongosh@latest pnpm@10 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- uv (Python package manager) --------------------------------------
# Install system-wide so PATH ordering is irrelevant. INSTALLER_NO_MODIFY_PATH=1
# stops the installer appending `. "$HOME/.local/bin/env"` to /root/.profile and
# /root/.bashrc — that shim lives under /root/.local, which is a noexec tmpfs
# masked empty at runtime (see docker-compose.yml), so the source would always
# fail with a "No such file" on every login shell. uv is moved onto PATH below,
# so the profile edit is pointless anyway.
RUN curl -LsSf https://astral.sh/uv/install.sh | env INSTALLER_NO_MODIFY_PATH=1 sh \
 && mv /root/.local/bin/uv  /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# Baseline venv used by VS Code's Python default interpreter setting.
# Users typically create per-repo venvs under /workspace/<repo>/.venv.
RUN uv venv --python 3.12 /root/.venv

# ---------- PDF generation tooling (WeasyPrint + pandoc) ---------------------
# Markdown/HTML -> PDF with no LaTeX: pandoc drives WeasyPrint directly via
# `--pdf-engine=weasyprint`, a complete document path without TeX Live's multi-
# GB footprint.
#
# Native libs: WeasyPrint renders through Pango (since v53 — no GTK/Cairo system
# dep). libpango-1.0-0 + libcairo2 already come from the Playwright block above;
# only libpangoft2-1.0-0 (Pango FreeType backend) is missing. pandoc is
# apt-installed with --no-install-recommends so it does NOT drag texlive in as a
# Recommends.
#
# Fonts: the CUDA base ships almost no families, so without these PDFs render in
# fallback/tofu glyphs. Curated set chosen for metric compatibility — the open
# clones match the proprietary originals' character widths, so line breaks and
# page counts hold (matters for legal/court page limits) without licensing them.
# NOT using ttf-mscorefonts-installer: it downloads from SourceForge behind an
# interactive EULA — breaks the noninteractive build and the egress allowlist.
#   liberation        Times New Roman / Arial / Courier New      (already above)
#   crosextra-carlito Calibri (modern Word default)
#   crosextra-caladea Cambria
#   texgyre           Century Schoolbook / Palatino / Bookman / Times / Helvetica
#   noto-core         pan-Unicode Latin/Greek/Cyrillic + symbols (anti-tofu)
#   inter             modern document/UI sans
#   jetbrains-mono    modern coding mono for code blocks
#
# WeasyPrint goes in via `uv tool install`, NOT /root/.venv or /root/.local —
# the latter is a 256m noexec + ephemeral tmpfs at runtime (docker-compose.yml),
# the same constraint that put `agy` in /usr/local/bin. So UV_TOOL_DIR pins the
# isolated tool venv to /opt (persistent, exec-allowed) and UV_TOOL_BIN_DIR puts
# the `weasyprint` entrypoint on PATH at /usr/local/bin — which is also where
# pandoc looks for the engine.
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libpangoft2-1.0-0 \
      pandoc \
      fonts-dejavu-core fonts-liberation \
      fonts-crosextra-carlito fonts-crosextra-caladea fonts-texgyre \
      fonts-noto-core \
      fonts-inter fonts-jetbrains-mono \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
 && uv tool install weasyprint \
 && weasyprint --version \
 && pandoc --version

# (The legal.css reference stylesheet is COPYed in the late-bound assets
# section near the end of this file — nothing here consumes it, and keeping
# it out of this layer chain lets stylesheet edits rebuild only the tail.)

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

# ---------- GitLab CLI (glab) — official .deb, arch-aware -------------------
# Upstream stopped publishing linux amd64/arm64 .tar.gz around v1.93.0; only
# .deb / .rpm / .apk now. dpkg -i is enough since glab is a static Go binary
# with no runtime deps.
ARG GLAB_VERSION=1.93.0
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in amd64|arm64) DARCH="$ARCH" ;; *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; esac \
 && curl -fsSL -o /tmp/glab.deb "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${DARCH}.deb" \
 && dpkg -i /tmp/glab.deb \
 && rm -f /tmp/glab.deb \
 && glab --version

# ---------- zsh + oh-my-zsh + powerlevel10k + plugins -----------------------
# Dotfiles come in via `sandbox_templates/common/`. Fonts are a host-terminal concern, not baked.
# .zshrc must be COPYed BEFORE the oh-my-zsh install below (--keep-zshrc reads
# it); .p10k.zsh and the deny-destructive hook feed nothing in the clone layers,
# so they live in the late-bound assets section near the end of the file.
COPY sandbox_templates/common/.zshrc    /root/.zshrc

ENV RUNZSH=no CHSH=no
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc \
 && ZSH_CUSTOM="/root/.oh-my-zsh/custom" \
 && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git                    "$ZSH_CUSTOM/themes/powerlevel10k" \
 && git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git            "$ZSH_CUSTOM/plugins/zsh-autosuggestions" \
&& git clone --depth=1 https://github.com/zsh-users/zsh-history-substring-search.git   "$ZSH_CUSTOM/plugins/zsh-history-substring-search" \
 && git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git        "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" \
 && usermod -s /usr/bin/zsh root

# ---------- gitstatusd (p10k dependency) ------------------------------------
# Pre-install so powerlevel10k doesn't try to fetch from github.com on first
# shell start — which the proxy allowlist correctly blocks when the [git]
# planning-mode section is commented out. Version + sha256 parsed from p10k's
# own install.info so re-cloning p10k automatically picks up upstream's pin.
RUN set -eux; \
    GS_DIR="/root/.oh-my-zsh/custom/themes/powerlevel10k/gitstatus"; \
    uname_s="$(uname -s | tr '[:upper:]' '[:lower:]')"; \
    uname_m="$(uname -m)"; \
    LINE="$(awk -v m="$uname_m" '/^uname_s_glob="linux"/ && $0 ~ "uname_m_glob=\""m"\""' "$GS_DIR/install.info" | head -1)"; \
    [ -n "$LINE" ] || { echo "no install.info entry for linux/$uname_m" >&2; exit 1; }; \
    eval "$LINE"; \
    URL="https://github.com/romkatv/gitstatus/releases/download/${version}/${file}.tar.gz"; \
    curl -fsSL "$URL" -o /tmp/gsd.tar.gz; \
    echo "${sha256}  /tmp/gsd.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gsd.tar.gz -C "$GS_DIR/usrbin/"; \
    rm /tmp/gsd.tar.gz; \
    chmod +x "$GS_DIR/usrbin/$file"; \
    test -x "$GS_DIR/usrbin/$file"

# ---------- late-bound assets (cache-friendly tail) --------------------------
# Dependency-free files deliberately placed BELOW the oh-my-zsh/gitstatusd
# layers: editing the prompt config, a stylesheet, or the hook re-runs only
# this cheap tail (+ AI CLI layer), not the git clones and downloads above.
COPY sandbox_templates/common/.p10k.zsh /root/.p10k.zsh

# Reference stylesheet for legal/formal documents. Baked at a stable path so
# any profile/project can use it without copying into each workspace:
#   weasyprint --stylesheet /usr/local/share/pdf-styles/legal.css in.html out.pdf
#   pandoc doc.md -o out.pdf --pdf-engine=weasyprint \
#     --css /usr/local/share/pdf-styles/legal.css
COPY sandbox_templates/common/pdf-styles/legal.css /usr/local/share/pdf-styles/legal.css

# deny-destructive PreToolUse hook — closes the deny-list bypass class where
# permissions.deny's prefix matcher cannot see destructive flags (find
# -delete, dd of=) or path targets (Edit to /usr/local/lib/claude-hooks/).
# See docs/deny-destructive-hook-plan.md. Baked into the image so it survives
# container recreates; rebuild restores the canonical script on every up.
# Not using COPY --chmod= to stay portable across non-BuildKit builders.
COPY sandbox_templates/claude/hooks/deny-destructive.sh /usr/local/lib/claude-hooks/deny-destructive.sh
RUN chmod 0755 /usr/local/lib/claude-hooks/deny-destructive.sh

# webfetch — web-read broker for the restricted agent. curl/wget are denied and
# the real WebFetch tool is not allow-listed, so the agent reads the web ONLY
# through a hosted reader API (default Tavily, already in allowed_domains.txt).
# The remote service performs the arbitrary-URL egress from its own infra; the
# sandbox's egress surface never grows. stdlib-only, so it needs no pip layer;
# urllib routes through the Squid proxy via HTTPS_PROXY. Keys come from the
# per-profile secrets.env env_file (never argv). See docs/web-read-broker.md.
# Baked into the image so it survives recreates and lives on exec'able fs
# (the /root tmpfs mounts are noexec). Same no-COPY --chmod portability note.
COPY sandbox_templates/bin/webfetch /usr/local/bin/webfetch
RUN chmod 0755 /usr/local/bin/webfetch

# ---------- just (command runner) -------------------------------------------
# Agents run per-repo justfile recipes in /workspace (settings already allow
# `Bash(just:*)`). Ubuntu noble ships only just 1.21.0 — too old for recipe
# attributes like [doc(...)] (added upstream in 1.27.0) — so we bake a pinned
# upstream prebuilt binary, checksum-verified against the release SHA256SUMS
# (the just.systems installer does NOT verify). Static musl binary, arch-aware
# amd64/arm64. No runtime egress — a local task runner fetches nothing; the
# download runs at build time on the host network, bypassing Squid. Bump = edit
# JUST_VERSION (re-pull + re-verify). Same sha256-pin + arch-aware idiom as the
# gitstatusd/glab blocks.
#
# The binary lands in /usr/local/libexec and a thin wrapper takes its place on
# PATH: just runs a shebang recipe (`#!/usr/bin/env bash` ...) by writing the
# script to $TMPDIR and EXEC'ing it, but this sandbox mounts /tmp noexec (audit
# Finding G), so a default shebang recipe dies with EACCES ("Permission denied
# (os error 13)"). The wrapper points TMPDIR at a dedicated exec-allowed rootfs
# dir (/var/lib/just-tmp, 0700 root-owned) for just ONLY — global /tmp stays
# noexec + tmpfs-fast for npm/uv/builds; a global TMPDIR override would weaken
# Finding G and slow every build. A private 0700 dir (vs world-writable
# /var/tmp) removes any shared-tmp race and reads intentionally in an audit.
# Override with $JUST_TMPDIR. just removes its per-run tempdir, so nothing
# accumulates. verify-sandbox.sh asserts a shebang recipe runs.
ARG JUST_VERSION=1.56.0
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
      amd64) TARGET="x86_64-unknown-linux-musl" ;; \
      arm64) TARGET="aarch64-unknown-linux-musl" ;; \
      *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac \
 && ARCHIVE="just-${JUST_VERSION}-${TARGET}.tar.gz" \
 && BASE="https://github.com/casey/just/releases/download/${JUST_VERSION}" \
 && curl -fsSL -o /tmp/just.tar.gz "${BASE}/${ARCHIVE}" \
 && curl -fsSL -o /tmp/SHA256SUMS  "${BASE}/SHA256SUMS" \
 && EXPECTED="$(awk -v f="$ARCHIVE" '$2==f{print $1}' /tmp/SHA256SUMS)" \
 && [ -n "$EXPECTED" ] || { echo "no SHA256SUMS entry for $ARCHIVE" >&2; exit 1; } \
 && echo "${EXPECTED}  /tmp/just.tar.gz" | sha256sum -c - \
 && mkdir -p /usr/local/libexec /var/lib/just-tmp \
 && chmod 0700 /var/lib/just-tmp \
 && tar -xzf /tmp/just.tar.gz -C /usr/local/libexec just \
 && printf '%s\n' \
      '#!/bin/sh' \
      '# /tmp is noexec here; just execs shebang recipes from $TMPDIR. Point' \
      '# just (only) at a private exec-allowed dir so shebang recipes run. See Dockerfile.' \
      'TMPDIR="${JUST_TMPDIR:-/var/lib/just-tmp}"; export TMPDIR' \
      'exec /usr/local/libexec/just "$@"' \
      > /usr/local/bin/just \
 && chmod 0755 /usr/local/bin/just \
 && rm -f /tmp/just.tar.gz /tmp/SHA256SUMS \
 && just --version

# ---------- beads (bd) — per-repo execution ledger --------------------------
# Git-backed, dependency-graph issue tracker (gastownhall/beads; Go + embedded
# Dolt). Adopted per docs/adr ADR-0005 + BEADS_ADOPTION_PLAN — this sandbox is
# the runtime for the project_zenbu pilot. Baked because container-global
# installs live on the ephemeral rootfs: a hand-run `bd` install vanishes on
# recreate (only /workspace + ~/.ai-sandbox mounts persist), so this is the
# only durable path — same reasoning that puts claude/agy/glab in the image.
# Embedded Dolt is in-process: no separate `dolt` binary, no sql-server host
# for the pilot.
#
# Canonical upstream install.sh: auto-targets /usr/local/bin (writable as root
# — the exec-allowed, persistent path; NOT ~/.local, a noexec+ephemeral tmpfs
# at runtime), and REFUSES to install unless the release archive's SHA256
# matches the signed checksums.txt. Runs at BUILD time with full caps (host
# network, bypassing Squid) — so no build-time allowlist entry is needed and
# the tar-extract chown succeeds. RUNTIME `bd` is local; the only network op is
# `bd dolt push/pull` -> github.com (already always-on).
#
# UPGRADE = rebuild this layer. In-container `bd upgrade` / install.sh CANNOT
# run under the runtime hardening: cap_drop ALL strips CAP_CHOWN, so tar-
# extracting the release archive dies on "Cannot change ownership ... Operation
# not permitted", and a /usr/local/bin write wouldn't survive recreate anyway.
# (Verified: the BAKED bd + embedded Dolt run cleanly under seccomp + cap_drop
# ALL + no-new-privileges — init/create/ready --json all pass.) The
# [beads-install] allowlist block only widens egress; it does not lift that cap
# limit — see proxy/allowed_domains.txt.
#
# Deliberately ABOVE the AI-CLI refresh tail: `--refresh-ai` must NOT silently
# bump bd (young storage engine — upgrades are a backup+doctor step per the
# plan). Editing this line re-pulls latest; that + the conventions-repo
# VERSION.md is the pin of record.
RUN curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash \
 && bd version

# ---------- AI CLI refresh layer (Claude Code + Antigravity agy) -------------
# Deliberately the LAST build step so bumping either CLI rebuilds only this tail
# layer, not the Node/CUDA/uv/font/oh-my-zsh layers above. Routine version bumps
# go from a multi-minute rebuild to a seconds-long tail rebuild:
#   scripts/profile.sh build --refresh-ai                 # latest of BOTH CLIs
#   scripts/profile.sh build --claude-version=1.2.3       # pin claude (implies refresh)
# AI_CLI_REFRESH is a cache-buster token — the build flags above pass a fresh
# value so this RUN re-executes and pulls upstream. Untouched, it stays cached.
#
# claude: npm global. mongosh/pnpm stay in the Node layer above (rarely bumped).
# agy: native binary to /usr/local/bin via --dir, NOT the installer default
# ~/.local/bin (that's a noexec + ephemeral tmpfs at runtime — see
# docker-compose.yml — so a binary there can't run or survive a recreate). The
# installer sha512-verifies the payload against its signed manifest. This step
# runs on the host network, bypassing Squid; RUNTIME auth/API hosts are gated in
# proxy/allowed_domains.txt under [antigravity]. agy auth is NOT persisted across
# rebuilds — sign in at the container console (`scripts/profile.sh <p>
# auth-antigravity`, or just `agy`); config lives under /root/.gemini/antigravity-cli/.
ARG AI_CLI_REFRESH=0
ARG CLAUDE_VERSION=latest
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 && curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin \
 && claude --version \
 && /usr/local/bin/agy --version

# ---------- runtime layout ---------------------------------------------------
# Expected bind mounts (see docker-compose.yml):
#   /workspace                <- ~/repo/<profile>/
#   /root/.claude             <- ~/.ai-sandbox/profiles/<profile>/claude-home
#   /root/.claude.json        <- ~/.ai-sandbox/profiles/<profile>/claude.json
#   /root/.cache              <- ~/.ai-sandbox/profiles/<profile>/cache
#   /root/.config             <- ~/.ai-sandbox/profiles/<profile>/config
#   /root/.gemini             <- ~/.ai-sandbox/profiles/<profile>/gemini-home
#                                (Antigravity CLI `agy` home — config under
#                                 /root/.gemini/antigravity-cli/; dir name kept)
# DISABLE_AUTOUPDATER/DISABLE_UPDATES: Claude Code's runtime self-updater runs a
# plain `npm install -g @anthropic-ai/claude-code` (no --allow-scripts), which
# this image's npm allow-scripts allowlist blocks — the postinstall (install.cjs,
# fetches the platform-native binary) is skipped, so `claude --version` becomes
# "native binary not installed" for every process in the shared global install.
# Update claude ONLY at build time (the RUN above passes --allow-scripts) via
# `scripts/profile.sh build --refresh-ai`. Mirrored in the seeded Claude settings
# (sandbox_templates/claude/claude-settings.json "env").
ENV HOME=/root \
    SHELL=/usr/bin/zsh \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1 \
    PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

USER root
WORKDIR /workspace

ENTRYPOINT ["tini", "--"]
CMD ["sleep", "infinity"]
