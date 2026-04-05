#!/bin/bash
set -e

# ============================================================
# scripts/publish.sh
# Builds a module via build.sh (darklua pipeline), checks
# whether the version in wally.toml has been bumped since the
# last git tag, and publishes to Wally if so.
#
# Usage:
#   scripts/publish.sh                  (interactive)
#   scripts/publish.sh gamemode-core    (direct)
#   scripts/publish.sh --dry-run        (build + verify, no publish)
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

REPO_ROOT="$(pwd)"
TOML="$MODULE_DIR/wally.toml"

VERSION=$(grep '^version' "$TOML" | head -1 | sed 's/version = "\(.*\)"/\1/')
PACKAGE_NAME=$(grep '^name' "$TOML" | head -1 | sed 's/name = "\(.*\)"/\1/')

echo ""
echo "══════════════════════════════════════════════"
echo "  $PACKAGE_NAME@$VERSION"
[ "$DRY_RUN" = true ] && echo "  (dry run)"
echo "══════════════════════════════════════════════"

# ── 2. Version check ─────────────────────────────────────────
# Compare the current version in wally.toml against the most
# recent git tag for this module. If unchanged, skip publishing.
PREV_TAG=$(git tag --list "$MODULE_NAME@*" --sort=-version:refname | head -1)

if [ -n "$PREV_TAG" ]; then
    PREVIOUS=$(git show "$PREV_TAG":"$TOML" 2>/dev/null \
        | grep '^version' | head -1 \
        | sed 's/version = "\(.*\)"/\1/' || echo "none")
else
    PREVIOUS="none"
fi

echo "Current version:  $VERSION"
echo "Previous version: $PREVIOUS"

if [ "$VERSION" = "$PREVIOUS" ]; then
    echo "Version unchanged — nothing to publish."
    exit 0
fi

echo "Version bumped — proceeding."

# ── 3. Build via build.sh ─────────────────────────────────────
# Delegates sourcemap generation, darklua processing, non-Lua
# file sync, and alias verification to build.sh. The .rbxm
# output is discarded — we only need dist/src/ to be populated
# before staging for Wally.
echo "--- Running build.sh to process dist/src/ ---"
DUMMY_RBXM="build/output/.publish-tmp-$MODULE_NAME.rbxm"
sh scripts/build.sh "$MODULE_NAME" --output "$DUMMY_RBXM"
rm -f "$DUMMY_RBXM"

# ── 4. Stage publish directory ───────────────────────────────
# wally.toml declares include = ["src", ...], so wally expects
# the processed source to be at src/. We stage a clean copy with
# dist/src/ presented as src/ so the working module dir stays clean.
STAGE="$REPO_ROOT/build/publish/$MODULE_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$MODULE_DIR/wally.toml" "$STAGE/wally.toml"
cp "$MODULE_DIR/default.project.json" "$STAGE/default.project.json"
cp -r "$MODULE_DIR/dist/src/." "$STAGE/src/"

echo "--- Staged publish directory: $STAGE ---"

# ── 5. Publish ───────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "Dry run complete. Staged output: $STAGE"
    echo ""
    echo "Resolved requires in src/init.luau:"
    INIT_FILE=""
    [ -f "$STAGE/src/init.luau" ] && INIT_FILE="$STAGE/src/init.luau"
    [ -f "$STAGE/src/init.lua"  ] && INIT_FILE="$STAGE/src/init.lua"
    [ -n "$INIT_FILE" ] && grep 'require(' "$INIT_FILE" | head -20
    exit 0
fi

cd "$STAGE"

if [ -n "$WALLY_AUTH_TOKEN" ]; then
    echo "--- [Wally] Logging in ---"
    wally login --token "$WALLY_AUTH_TOKEN"
fi

echo "--- [Wally] Publishing $PACKAGE_NAME@$VERSION ---"
wally publish
echo "✓ Published $PACKAGE_NAME@$VERSION"

cd "$REPO_ROOT"

# ── 6. Changelog ─────────────────────────────────────────────
TAG="$MODULE_NAME@$VERSION"

if [ -z "$PREV_TAG" ]; then
    CHANGELOG=$(git log --pretty=format:"- %s (%h)" -- "$MODULE_DIR/")
else
    CHANGELOG=$(git log "$PREV_TAG"..HEAD --pretty=format:"- %s (%h)" -- "$MODULE_DIR/")
fi

[ -z "$CHANGELOG" ] && CHANGELOG="- No changes recorded."

echo "$CHANGELOG" > /tmp/changelog.txt
echo "tag=$TAG" > /tmp/publish-meta.txt

echo ""
echo "Changelog:"
cat /tmp/changelog.txt