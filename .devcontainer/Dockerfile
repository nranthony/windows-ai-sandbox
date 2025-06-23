# FROM ubuntu:24.04
FROM nvidia/cuda:12.8.0-base-ubuntu24.04

# -------------------------------------------------
# Essential packages (unchanged)
# -------------------------------------------------
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git zsh vim curl wget fontconfig locales lsd ca-certificates && \
    rm -rf /var/lib/apt/lists/*


HEALTHCHECK --interval=60s --timeout=3s \
  CMD curl -f http://localhost/health || exit 1

# -------------------------------------------------
# Create an unprivileged user that matches host UID=1000
#    (rootless Docker volumes will be owned by this UID already)
# -------------------------------------------------
# RUN useradd -m -u 1000 -s /bin/bash ubuntu && \
#     echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu && \
#     chmod 0440 /etc/sudoers.d/ubuntu

# -------------------------------------------------
# Copy dotfiles for root AND the ubuntu user
# -------------------------------------------------
COPY .p10k.zsh /root/.p10k.zsh
COPY .zshrc     /root/.zshrc
COPY .p10k.zsh /home/ubuntu/.p10k.zsh
COPY .zshrc     /home/ubuntu/.zshrc
RUN chown ubuntu:ubuntu /home/ubuntu/.p10k.zsh /home/ubuntu/.zshrc

ENV PATH="/root/miniforge3/bin:/root/miniforge3/condabin:${PATH}"


# -------------------------------------------------
# Don’t pre-create /home/ubuntu/repo/workspace
#    → the named volume will be mounted there automatically
# -------------------------------------------------

# USER ubuntu
# WORKDIR /home/ubuntu



# FROM ubuntu:24.04

# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         git zsh vim curl wget fontconfig locales lsd ca-certificates && \
#     rm -rf /var/lib/apt/lists/*

# RUN mkdir "/data"

# COPY .p10k.zsh /root/.p10k.zsh
# COPY .zshrc /root/.zshrc
# COPY .p10k.zsh /home/ubuntu/.p10k.zsh
# COPY .zshrc /home/ubuntu/.zshrc

# RUN mkdir -p /home/ubuntu/repo/workspace
# RUN chown -R 1000:1000 /home/ubuntu/repo/workspace