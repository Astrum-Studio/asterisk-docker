#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/ensure-remote-access.sh &

exec docker-entrypoint.sh "$@"
