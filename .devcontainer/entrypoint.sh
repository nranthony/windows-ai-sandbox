#!/bin/bash

# Change to the script's directory first
SCRIPT_DIR=$(dirname "$0")
cd "$SCRIPT_DIR"

# Run setup only if not already done
if [[ ! -f ~/.setup-complete ]]; then
    ./ohmyzsh-container-setup.sh
    ./set-git-global.sh
    touch ~/.setup-complete
fi

exec "$@"