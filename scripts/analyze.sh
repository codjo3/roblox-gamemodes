#!/bin/bash
set -e

# ============================================================
# scripts/analyze.sh
# Runs luau-lsp static analysis over a module's src/.
# Mirrors roblox-project-template's analyze.sh.
#
# Usage:
#   scripts/analyze.sh                  (interactive)
#   scripts/analyze.sh gamemode-core    (direct)
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
    echo "Select a module to analyze:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Analyze: $MODULE_NAME"
echo "══════════════════════════════════════════════"

cd "$MODULE_DIR"

# ── 2. Ensure packages are installed ─────────────────────────
if [[ ! -d "Packages" && ! -d "DevPackages" ]]; then
    echo "--- Packages not found, installing ---"
    cd ../..
    sh scripts/install-packages.sh "$MODULE_NAME"
    cd "$MODULE_DIR"
fi

# ── 3. Sourcemap ─────────────────────────────────────────────
echo "--- [Rojo] Generating sourcemap ---"
rojo sourcemap default.project.json -o sourcemap.json

# ── 4. Fetch Roblox global types ─────────────────────────────
echo "--- Fetching Roblox global type definitions ---"
curl -sSf -O https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.lua

# ── 5. luau-lsp analyze ──────────────────────────────────────
# .luaurc lives at the src/ level (as set up in .luaurc at the module root,
# which aliases @pkg, @dev, @src). Pass it as --base-luaurc so lsp resolves
# the same aliases darklua does at build time.
echo "--- [luau-lsp] Analyzing src/ ---"
luau-lsp analyze \
    --definitions=globalTypes.d.lua \
    --base-luaurc=.luaurc \
    --sourcemap=sourcemap.json \
    --no-strict-dm-types \
    --ignore="Packages/**/*.lua" \
    --ignore="Packages/**/*.luau" \
    --ignore="DevPackages/**/*.lua" \
    --ignore="DevPackages/**/*.luau" \
    src/

echo "✓ Analysis complete for $MODULE_NAME"