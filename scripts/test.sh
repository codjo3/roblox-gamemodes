#!/bin/bash
set -e

# ============================================================
# scripts/test.sh
# Builds and runs JestLua tests for a module.
#
# Usage:
#   scripts/test.sh                   (interactive selection)
#   scripts/test.sh gamemode-core     (direct)
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
    echo "Select a module to test:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

BUILD_PATH="build/tests/$MODULE_NAME"
echo ""
echo "══════════════════════════════════════════════"
echo "  Testing: $MODULE_NAME"
echo "══════════════════════════════════════════════"
echo "--- Building in $BUILD_PATH ---"

# ── 2. Setup Build Environment ───────────────────────────────
rm -rf "$BUILD_PATH"
mkdir -p "$BUILD_PATH"
cp -r "$MODULE_DIR/." "$BUILD_PATH/"
cd "$BUILD_PATH"

# ── 3. Inject Jest if tests exist ────────────────────────────
if [ -d "tests" ] && [ -f "wally.toml" ]; then
    echo "--- [Wally] Injecting Jest into dev-dependencies ---"
    if grep -q "\[dev-dependencies\]" wally.toml; then
        sed -i '/\[dev-dependencies\]/a Jest = "jsdotlua/jest@3.10.0"' wally.toml
    else
        echo -e "\n[dev-dependencies]\nJest = \"jsdotlua/jest@3.10.0\"" >> wally.toml
    fi
fi

# ── 4. Wally Install ─────────────────────────────────────────
if [ -f "wally.toml" ]; then
    echo "--- [Wally] Installing (including Jest) ---"
    wally install
fi

# ── 5. Initial Rojo Sourcemap (required for Darklua) ─────────
if [ -f "dev.project.json" ]; then
    echo "--- [Rojo] Generating initial sourcemap ---"
    rojo sourcemap dev.project.json --output sourcemap.json
fi

# ── 6. Darklua Processing ────────────────────────────────────
if [ -f ".darklua.json" ]; then
    echo "--- [Darklua] Processing to dist/ ---"
    mkdir -p dist
    [ -d "src" ]   && darklua process src dist/src
    [ -d "tests" ] && darklua process tests dist/tests

    if [ -f "dev.project.json" ]; then
        echo "--- [Rojo] Updating paths and generating dist/ sourcemap ---"
        sed -i 's/"\$path": "src"/"\$path": "dist\/src"/g' dev.project.json
        sed -i 's/"\$path": "tests"/"\$path": "dist\/tests"/g' dev.project.json
        rojo sourcemap dev.project.json --output dist/sourcemap.json
    fi
fi

# ── 7. CI Testing ────────────────────────────────────────────
TEST_FILE="dist/tests/run-tests.luau"
[ ! -f "$TEST_FILE" ] && TEST_FILE="tests/run-tests.luau"

if [ -f "$TEST_FILE" ]; then
    echo "--- [CI] Running $TEST_FILE ---"
    rojo build dev.project.json --output dist/ci_place.rbxl
    run-in-roblox --place dist/ci_place.rbxl --script "$TEST_FILE"
    rm dist/ci_place.rbxl
else
    echo "--- [CI] No tests found ---"
fi

echo "--- Done ---"