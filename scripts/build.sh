#!/bin/bash
set -e

# ============================================================
# scripts/build.sh
# Produces a release .rbxm for a module — src/ only, no tests
# or dev packages. Processes src/ through darklua then builds
# with rojo against default.project.json.
#
# Usage:
#   scripts/build.sh                  (interactive)
#   scripts/build.sh gamemode-core    (direct)
#   scripts/build.sh gamemode-core --output path/to/out.rbxm
# ============================================================

DIRECT_MODULE=""
OUTPUT_PATH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        *)
            DIRECT_MODULE="$1"
            shift
            ;;
    esac
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
    echo "Select a module to build:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

if [ -z "$OUTPUT_PATH" ]; then
    OUTPUT_PATH="build/output/$MODULE_NAME.rbxm"
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Build: $MODULE_NAME → $OUTPUT_PATH"
echo "══════════════════════════════════════════════"

REPO_ROOT="$(pwd)"
cd "$MODULE_DIR"

# ── 2. Ensure packages are installed ─────────────────────────
# Only runtime Packages/ is needed for a release build, but
# install-packages.sh installs both — that's fine, wally.toml
# controls what gets included in the output.
if [ ! -d "Packages" ]; then
    echo "--- Packages not found, installing ---"
    cd "$REPO_ROOT"
    sh scripts/install-packages.sh "$MODULE_NAME"
    cd "$MODULE_DIR"
fi

# ── 3. Sourcemap ─────────────────────────────────────────────
# dev.project.json maps src/ and Packages/ at the correct
# runtime paths, which is all darklua needs to resolve @pkg/@src.
echo "--- [Rojo] Generating sourcemap ---"
rojo sourcemap dev.project.json -o sourcemap.json

# ── 4. Darklua ───────────────────────────────────────────────
# Process src/ → dist/src/ only. tests/ and DevPackages/ are
# excluded — this is a release build.
echo "--- [Darklua] Processing src/ → dist/src/ ---"
mkdir -p dist/src
export __DEV__=false
darklua process --config .darklua.json src/ dist/src/
export -n __DEV__

# ── 5. Non-Lua sync ──────────────────────────────────────────
# darklua only processes .lua/.luau — copy everything else from
# src/ into dist/src/ so rojo sees a complete tree.
echo "--- Syncing non-Lua files src/ → dist/src/ ---"
find src/ -type f ! -name "*.lua" ! -name "*.luau" | while read -r file; do
    dest="dist/${file}"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"
    echo "    copied: $file → $dest"
done

# ── 6. Generate dist.project.json ────────────────────────────
# Remap default.project.json's "$path": "src" to "dist/src" so
# rojo builds from the darklua-processed output.
echo "--- Generating dist.project.json ---"
python3 - << 'PYEOF'
import json

WALLY_DIRS = {"Packages", "DevPackages"}

def remap(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k == '$path' and isinstance(v, str) and v not in WALLY_DIRS:
                out[k] = f"dist/{v}"
            else:
                out[k] = remap(v)
        return out
    if isinstance(node, list):
        return [remap(i) for i in node]
    return node

with open('default.project.json', 'r') as f:
    data = json.load(f)

with open('dist.project.json', 'w') as f:
    json.dump(remap(data), f, indent=2)

print("    wrote dist.project.json")
PYEOF

# ── 7. Rojo build ────────────────────────────────────────────
mkdir -p "$(dirname "$REPO_ROOT/$OUTPUT_PATH")"

echo "--- [Rojo] Building $MODULE_NAME.rbxm ---"
rojo build dist.project.json -o "$REPO_ROOT/$OUTPUT_PATH"

echo "✓ Built: $OUTPUT_PATH"