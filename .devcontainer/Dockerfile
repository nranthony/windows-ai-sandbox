FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git zsh vim curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir "/data"

COPY .p10k.zsh /root/.p10k.zsh
COPY .zshrc /root/.zshrc