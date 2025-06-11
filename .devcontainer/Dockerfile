# Use Ubuntu latest as the base
FROM ubuntu:latest

# Install dependencies for Miniforge and tooling
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       wget bzip2 ca-certificates \
       git zsh vim curl sudo \
    && rm -rf /var/lib/apt/lists/*

# Create non-root 'vscode' user with zsh default shell
RUN useradd -ms /usr/bin/zsh vscode \
    && echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode

# Switch to the non-root user
USER vscode
ENV HOME=/home/vscode
WORKDIR /workspace

# Install Miniforge3 (Conda)
RUN wget --quiet https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -O Miniforge3.sh \
    && bash Miniforge3.sh -b -p $HOME/miniforge3 \
    && rm Miniforge3.sh
ENV PATH="$HOME/miniforge3/bin:$PATH"

# Install Oh-My-Zsh for 'vscode'
RUN git clone https://github.com/ohmyzsh/ohmyzsh.git $HOME/.oh-my-zsh \
    && cp $HOME/.oh-my-zsh/templates/zshrc.zsh-template $HOME/.zshrc