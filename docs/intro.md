---
sidebar_position: 1
---

# roblox-gamemodes

[![CI](https://github.com/codjo3/roblox-gamemodes/actions/workflows/ci.yml/badge.svg)](https://github.com/codjo3/roblox-gamemodes/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/codjo3/roblox-gamemodes/blob/main/LICENSE)

A collection of reactive, hook-based gamemode packages for Roblox, distributed via [Wally](https://wally.run).

---

## Packages

| Package | Description |
|---|---|
| [gamemode-core](gamemode-core/overview) | Reactive hook-based gamemode lifecycle core |
| [gamemode-terminal](gamemode-terminal/overview) | Terminal (control-point) gamemode built on gamemode-core |

For the latest versions of each package, see their respective `wally.toml` files or search on [wally.run](https://wally.run).

---

## Installation

Add whichever packages you need to your `wally.toml` and run `wally install`:

```toml
[dependencies]
GamemodeCore = "codjo3/gamemode-core@VERSION"
GamemodeTerminal = "codjo3/gamemode-terminal@VERSION"
```

---

## Quick Example

```lua
local Terminal = require(Packages.GamemodeTerminal)

local gm = Terminal.new("RoundOne", {
    Teams = { game.Teams.Red, game.Teams.Blue },
    Parts = { workspace.ControlPoint },
    PointsNeeded = 1200,
    CaptureTime = 10,
})

gm.Stopped:Connect(function(winner)
    print(winner.Name .. " wins!")
end)

gm:Start()
```