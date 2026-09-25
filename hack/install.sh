#!/usr/bin/env bash

set -euo pipefail

CURDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Infra LB: Keepalived + HAProxy (image build + manifests)
make -C "$CURDIR/.." infra-lb

# harbor in HA mode (requires `make ha-deps`)
$CURDIR/install-harbor-ha.sh
