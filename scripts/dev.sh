#!/bin/bash
set -e

# ============================================================
# scripts/dev.sh
# Starts a live dev environment for a module: rojo serve,
# sourcemap watch, darklua watch, and a non-Lua file sync —
# all in parallel. Rojo serves the darklua-processed dist/
# so scripts run correctly in Roblox Studio.
#
# Requires: Git Bash on Windows, Python 3, PowerShell
#
# Usage:
#   scripts/dev.sh                  (interactive)
#   scripts/dev.sh gamemode-core    (direct)
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
    echo "Select a module to develop:"
    select MODULE_DIR in modules/*; do
        if [ -n "$MODULE_DIR" ]; then
            MODULE_NAME=$(basename "$MODULE_DIR")
            break
        fi
    done
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Dev: $MODULE_NAME"
echo "══════════════════════════════════════════════"

cd "$MODULE_DIR"

# ── 2. Ensure packages are installed ─────────────────────────
if [[ ! -d "Packages" && ! -d "DevPackages" ]]; then
    echo "--- Packages not found, installing ---"
    cd ../..
    sh scripts/install-packages.sh "$MODULE_NAME"
    cd "$MODULE_DIR"
fi

# ── 3. Ensure dist/ mirrors exist ────────────────────────────
# Create a dist/ mirror for every local source directory that
# appears as a $path in dev.project.json, skipping Wally dirs.
mkdir -p dist/src dist/tests

# ── 4. Generate dist.project.json ────────────────────────────
# Rewrites dev.project.json so that every "$path" value that
# refers to a local source directory (anything except Packages/
# and DevPackages/) is prefixed with "dist/", e.g.:
#   "src"   → "dist/src"
#   "tests" → "dist/tests"
# Wally output dirs are left untouched so rojo still resolves
# installed packages from their original locations.
echo "--- Generating dist.project.json ---"
python3 - << 'PYEOF'
import json

# Wally-managed dirs — pre-built, darklua never touches these
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

with open('dev.project.json', 'r') as f:
    data = json.load(f)

with open('dist.project.json', 'w') as f:
    json.dump(remap(data), f, indent=2)

print("    wrote dist.project.json")
PYEOF

# ── 5. Initial non-Lua sync ──────────────────────────────────
# darklua only processes .lua/.luau — copy everything else from
# all local source dirs into their dist/ mirrors so the tree is
# complete before rojo starts serving.
echo "--- Initial sync of non-Lua files → dist/ ---"
for dir in src tests; do
    [ -d "$dir" ] || continue
    find "$dir/" -type f ! -name "*.lua" ! -name "*.luau" | while read -r file; do
        dest="dist/${file}"
        mkdir -p "$(dirname "$dest")"
        cp "$file" "$dest"
        echo "    copied: $file → $dest"
    done
done

# ── 6. PID tracking for clean shutdown ───────────────────────
# Git Bash on Windows does not support kill 0 for process groups,
# so we track each background PID and kill them individually.
PIDS=()

cleanup() {
    echo ""
    echo "Stopping all processes..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    exit 0
}

trap cleanup INT TERM

# ── 7. Start parallel processes ──────────────────────────────
echo "--- Starting rojo serve, sourcemap watch, darklua watch, and non-Lua sync ---"
echo "--- Press Ctrl+C to stop all processes ---"
echo ""

# Rojo serves dist.project.json so Studio sees darklua-processed output
rojo serve dist.project.json &
PIDS+=($!)

# Sourcemap watch uses dev.project.json (src/) so darklua's
# roblox require target resolves correctly against original paths
rojo sourcemap dev.project.json -o sourcemap.json --watch &
PIDS+=($!)

# darklua processes .lua/.luau files from all local source dirs.
# src/ and tests/ are both passed so requires resolve correctly
# across the whole module tree.
# Inline env assignment (VAR=val cmd) is not reliable in Git Bash,
# so export first then unset afterward.
export __DEV__=true
darklua process --config .darklua.json --watch src/ dist/src/ &
PIDS+=($!)
[ -d "tests" ] && {
    darklua process --config .darklua.json --watch tests/ dist/tests/ &
    PIDS+=($!)
}
export -n __DEV__

# PowerShell FileSystemWatcher mirrors non-Lua files into dist/.
# Watches both src/ and tests/ (and any other local source dirs),
# skipping .lua/.luau which darklua handles.
# This is the Windows equivalent of fswatch / inotifywait.
powershell -NoProfile -Command "
\$watchDirs = @('src', 'tests') | Where-Object { Test-Path \$_ -PathType Container }
\$watchers  = @()

foreach (\$dir in \$watchDirs) {
    \$absDir = (Get-Location).Path + '\' + \$dir
    \$w = New-Object System.IO.FileSystemWatcher
    \$w.Path = \$absDir
    \$w.IncludeSubdirectories = \$true
    \$w.EnableRaisingEvents = \$true
    \$w.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
                      [System.IO.NotifyFilters]::LastWrite -bor
                      [System.IO.NotifyFilters]::DirectoryName

    \$action = {
        \$fullPath   = \$Event.SourceEventArgs.FullPath
        \$changeType = \$Event.SourceEventArgs.ChangeType

        # darklua handles .lua/.luau — skip them here
        if (\$fullPath -match '\.(lua|luau)$') { return }

        # Determine which watched dir this event came from
        \$base = \$Event.MessageData
        \$rel  = [System.IO.Path]::GetRelativePath(\$base, \$fullPath)
        \$dirName = [System.IO.Path]::GetFileName(\$base)
        \$dest = (Get-Location).Path + '\dist\' + \$dirName + '\' + \$rel

        if (\$changeType -eq 'Deleted') {
            Remove-Item \$dest -Force -ErrorAction SilentlyContinue
            Write-Host \"    removed: dist\\\$dirName\\\\$rel\"
        } else {
            \$destDir = [System.IO.Path]::GetDirectoryName(\$dest)
            New-Item -ItemType Directory -Force -Path \$destDir | Out-Null
            Copy-Item \$fullPath \$dest -Force
            Write-Host \"    synced:  \$dirName\\\\$rel -> dist\\\$dirName\\\\$rel\"
        }
    }

    Register-ObjectEvent \$w 'Created' -Action \$action -MessageData \$absDir | Out-Null
    Register-ObjectEvent \$w 'Changed' -Action \$action -MessageData \$absDir | Out-Null
    Register-ObjectEvent \$w 'Deleted' -Action \$action -MessageData \$absDir | Out-Null
    Register-ObjectEvent \$w 'Renamed' -Action \$action -MessageData \$absDir | Out-Null
    \$watchers += \$w
}

Write-Host '--- [watch] Non-Lua files -> dist/ ---'
while (\$true) { Start-Sleep -Seconds 1 }
" &
PIDS+=($!)

wait