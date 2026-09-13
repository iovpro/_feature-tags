#!/usr/bin/env sh
# Demo runner for the clean fixture.

set -eu

# #f:fx.ops.up.main

# up_main builds and starts the demo stack.
up_main() {
  docker compose up -d
}

# #f:fx.ops.up

case "${1:-up}" in
  up) # #f:fx.ops.up.start
    up_main ;;
  *)
    echo "usage: run.sh up" >&2
    exit 2 ;;
esac
