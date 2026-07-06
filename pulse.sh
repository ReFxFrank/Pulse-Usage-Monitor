#!/bin/sh
# Pulse — launcher (POSIX). Forwards all args to server.js.
# Usage: ./pulse.sh [--port N] [--inspect-schema]
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$DIR/server.js" "$@"
