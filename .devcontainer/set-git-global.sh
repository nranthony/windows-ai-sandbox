#!/bin/bash

# Optional: Load .env if you're not using --env-file runArgs
# run from repo root dir
# set -a && [ -f ./.env ] && . ./.env && set +a

# Configure Git
if [ -n "$GIT_NAME" ]; then
    git config --global user.name "$GIT_NAME"
fi
if [ -n "$GIT_EMAIL" ]; then
    git config --global user.email "$GIT_EMAIL"
fi