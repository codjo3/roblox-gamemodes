#!/bin/bash
set -e

# ============================================================
# scripts/docs.sh
# Wraps moonwave so the --code flags are never forgotten.
#
# Usage:
#   scripts/docs.sh        (local dev server)
#   scripts/docs.sh build  (production build)
# ============================================================

CODE_FLAGS="--code modules/gamemode-core/src --code modules/gamemode-terminal/src"

if [ "${1}" = "build" ]; then
    moonwave build $CODE_FLAGS --publish
else
    moonwave dev $CODE_FLAGS
fi