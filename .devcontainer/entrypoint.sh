#!/bin/bash

# Run setup only if not already done
if [[ ! -f /.setup-complete ]]; then
    /ohmyzsh-setup.sh
    touch /.setup-complete
fi

exec "$@"