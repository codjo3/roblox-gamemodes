#!/bin/bash
set -e

# ============================================================
# scripts/install-packages.sh
# Installs Wally packages and patches type definitions for a
# module. Mirrors roblox-project-template's install-packages.sh
# but scoped to a single module in the monorepo.
#
# Usage:
#   scripts/install-packages.sh                  (interactive)
#   scripts/install-packages.sh gamemode-core    (direct)
# ============================================================

DIRECT_MODULE=""

for arg in "$@"; do
    DIRECT_MODULE="$arg"
done

# ── 1. Module Selection ──────────────────────────────────────
if [ -n "$DIRECT_MODULE" ]; then
    MODULE_DIR="modules/$DIRECT_MODULE"
    if [ ! -d "$MODULE_DIR" ]; then
        echo "❌ Module '$DIRECT_MODULE' not found in modules/"
        exit 1
    fi
    MODULE_NAME="$DIRECT_MODULE"
else
    echo "Select a module to install packages for:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Installing packages: $MODULE_NAME"
echo "══════════════════════════════════════════════"

cd "$MODULE_DIR"

# ── 2. Wally Install ─────────────────────────────────────────
echo "--- [Wally] Installing packages ---"
wally install

# ── 3. Sourcemap + type patches ──────────────────────────────
echo "--- [Rojo] Generating sourcemap ---"
rojo sourcemap dev.project.json -o sourcemap.json

echo "--- [wally-package-types] Patching type definitions ---"
if [ -d "Packages" ]; then 
    wally-package-types --sourcemap sourcemap.json Packages/
fi
if [ -d "DevPackages" ]; then 
    wally-package-types --sourcemap sourcemap.json DevPackages/
fi

echo "✓ Packages installed for $MODULE_NAME"