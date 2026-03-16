#!/bin/bash
set -e

# ============================================================
# scripts/publish.sh
# Processes src/ through darklua (resolving @pkg aliases to
# script.Parent chains) then publishes to Wally.
#
# Usage:
#   scripts/publish.sh                  (interactive selection)
#   scripts/publish.sh gamemode-core    (direct)
#   scripts/publish.sh --dry-run        (build only, no publish)
# ============================================================

DRY_RUN=false
DIRECT_MODULE=""

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) DIRECT_MODULE="$arg" ;;
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
    echo "Select a module to publish:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

VERSION=$(grep '^version' "$MODULE_DIR/wally.toml" | head -1 | sed 's/version = "\(.*\)"/\1/')
PACKAGE_NAME=$(grep '^name' "$MODULE_DIR/wally.toml" | head -1 | sed 's/name = "\(.*\)"/\1/')

echo ""
echo "══════════════════════════════════════════════"
echo "  $PACKAGE_NAME@$VERSION"
[ "$DRY_RUN" = true ] && echo "  (dry run)"
echo "══════════════════════════════════════════════"

# ── 2. Set up a clean build directory ───────────────────────
BUILD_PATH="build/publish/$MODULE_NAME"
rm -rf "$BUILD_PATH"
mkdir -p "$BUILD_PATH"
cp -r "$MODULE_DIR/." "$BUILD_PATH/"
cd "$BUILD_PATH"

# ── 3. Wally install ─────────────────────────────────────────
echo "--- [Wally] Installing dependencies ---"
wally install
mkdir -p Packages

# ── 4. Generate a temporary publish project ──────────────────
cat > darklua.project.json << EOF
{
  "name": "${MODULE_NAME}-darklua",
  "tree": {
    "\$className": "DataModel",
    "ReplicatedStorage": {
      "\$className": "ReplicatedStorage",
      "Packages": {
        "\$path": "Packages",
        "${MODULE_NAME}": {
          "\$path": "src"
        }
      }
    }
  }
}
EOF

echo "--- [Rojo] Generating darklua sourcemap ---"
rojo sourcemap darklua.project.json --output darklua-sourcemap.json

# ── 5. Generate a publish darklua config ─────────────────────
cat > .darklua-publish.json << EOF
{
  "generator": "retain_lines",
  "rules": [
    {
      "rule": "inject_global_value",
      "identifier": "__DEV__",
      "value": false
    },
    {
      "rule": "convert_require",
      "current": {
        "name": "path",
        "sources": {
          "@pkg": "Packages",
          "@src": "src"
        }
      },
      "target": {
        "name": "roblox",
        "rojo_sourcemap": "./darklua-sourcemap.json",
        "indexing_style": "wait_for_child"
      }
    }
  ]
}
EOF

# ── 6. Darklua: process src/ → dist/src/ ─────────────────────
echo "--- [Darklua] Processing src/ → dist/src/ ---"
mkdir -p dist/src
darklua process --config .darklua-publish.json src dist/src

# ── 7. Verify all aliases were resolved ──────────────────────
echo "--- Verifying no path aliases remain in dist/src/ ---"
ALIAS_HITS=$(grep -rl '@pkg\|@dev\|@src' dist/src/ --include="*.luau" --include="*.lua" 2>/dev/null || true)
if [ -n "$ALIAS_HITS" ]; then
    echo "❌ Unresolved path aliases found after darklua processing:"
    echo "$ALIAS_HITS"
    exit 1
fi
echo "    ✓ All aliases resolved"

# ── 8. Replace src/ with dist/src/ ───────────────────────────
# dist/src is the processed output — make it the canonical src
# so wally.toml and default.project.json need no changes.
rm -rf src
mv dist/src src
rm -rf dist
echo "--- Replaced src/ with processed output ---"

# ── 9. Publish ────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "Dry run complete. Processed output: $BUILD_PATH/src/"
    echo ""
    echo "Resolved requires in src/init.luau:"
    INIT_FILE=""
    [ -f "src/init.luau" ] && INIT_FILE="src/init.luau"
    [ -f "src/init.lua" ]  && INIT_FILE="src/init.lua"
    [ -n "$INIT_FILE" ] && grep 'require(' "$INIT_FILE" | head -20
else
    echo "--- [Wally] Publishing $PACKAGE_NAME@$VERSION ---"
    wally publish
    echo "✓ Published $PACKAGE_NAME@$VERSION"
fi

cd - > /dev/null