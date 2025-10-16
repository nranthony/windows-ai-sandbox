FROM nvidia/cuda:12.6.3-base-ubuntu24.04

# -------------------------------------------------
# Essential packages
# -------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git zsh vim curl wget fontconfig locales lsd ca-certificates lsof && \
    rm -rf /var/lib/apt/lists/*

# -------------------------------------------------
# Copy dotfiles for root user
# -------------------------------------------------
COPY .p10k.zsh /root/.p10k.zsh
COPY .zshrc /root/.zshrc

# -------------------------------------------------
# Set PATH for root's miniforge installation
# -------------------------------------------------
ENV PATH="/root/miniforge3/bin:/root/miniforge3/condabin:${PATH}"

# -------------------------------------------------
# Run as root (safe with rootless Docker)
# Container root (UID 0) = Host user (UID 1000)
# -------------------------------------------------
USER root
WORKDIR /root
