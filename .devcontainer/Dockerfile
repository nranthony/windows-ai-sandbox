FROM ubuntu:24.04

# Base packages you still want
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git zsh vim curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir "/data"

COPY .p10k.zsh /root/.p10k.zsh
COPY .zshrc /root/.zshrc

# COPY entrypoint.sh /root/entrypoint.sh
# RUN chmod +x /root/entrypoint.sh

# COPY ohmyzsh-setup.sh /root/ohmyzsh-setup.sh
# RUN chmod +x /root/ohmyzsh-setup.sh

# COPY set-git-global.sh /root/set-git-global.sh
# RUN chmod +x /root/set-git-global.sh

# CMD ["/bin/bash", "-c", "/root/entrypoint.sh && exec /bin/zsh"]


# # Make zsh the default shell for the existing ubuntu user
# RUN chsh -s /usr/bin/zsh ubuntu

# USER ubuntu                 # <-- no new user created
# ENV HOME=/home/ubuntu
# WORKDIR /workspace          # will be created / chowned at runtime

# # Post-create: install Oh-My-Zsh and initialize Conda (runs as dave)
# RUN git clone https://github.com/ohmyzsh/ohmyzsh.git $HOME/.oh-my-zsh \
#     && cp $HOME/.oh-my-zsh/templates/zshrc.zsh-template $HOME/.zshrc \
#     && conda init zsh
