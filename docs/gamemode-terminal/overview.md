---
sidebar_position: 1
---

# Overview

`gamemode-terminal` is a terminal (control-point capture) gamemode built on top of `gamemode-core`. Teams compete to hold a control point long enough to accumulate points. It handles zone detection via [QuickZone](https://github.com/ldgerrits/quickzone), capture progress, holder tracking, point accumulation, overtime, and win conditions out of the box.

## Installation

```toml
[dependencies]
GamemodeCore = "codjo3/gamemode-core@VERSION"
GamemodeTerminal = "codjo3/gamemode-terminal@VERSION"
```

```bash
wally install
```

Check [wally.run](https://wally.run) or the module's [`wally.toml`](https://github.com/codjo3/roblox-gamemodes/blob/main/modules/gamemode-terminal/wally.toml) for the latest version.

## Basic Usage

```lua
local Terminal = require(Packages.GamemodeTerminal)

local gm = Terminal.new("RoundOne", {
    Teams = { game.Teams.Red, game.Teams.Blue },
    Parts = { workspace.ControlPoint },
})

gm.Stopped:Connect(function(winner)
    print(winner.Name .. " wins!")
end)

gm:Start()
```

## Concepts

### Settings

All settings are optional except `Teams` and `Parts`.

| Setting | Type | Default | Description |
|---|---|---|---|
| `Teams` | `{ Team }` | required | Teams competing in the round |
| `Parts` | `{ BasePart }` | required | Parts that define the capture zone(s) |
| `Increase` | `number` | `1` | Points per second earned while holding |
| `Rollback` | `number` | `1` | Points per second lost while not holding |
| `PointsNeeded` | `number` | `1200` | Points required to win |
| `CaptureTime` | `number` | `1` | Seconds to fully capture a point |
| `RequireDominanceToIncrease` | `boolean` | `true` | Only earn points if the opponent has zero points |
| `ProgressWhileContested` | `boolean` | `true` | Allow capture progress when both teams are in zone |
| `CaptureWhileDead` | `boolean` | `false` | Count dead players toward zone occupation |
| `CaptureStacking` | `boolean` | `false` | Scale capture speed by player count difference |
| `OvertimeThreshold` | `number` | `-1` | Seconds before overtime starts (`-1` = disabled) |
| `OvertimeIncrease` | `number` | `1` | Points per second during overtime |
| `OvertimeRollback` | `number` | `1` | Rollback rate during overtime |
| `OvertimePointsNeeded` | `number` | `120` | Points to win during overtime |
| `OvertimeDefenderWinFullDominance` | `boolean` | `true` | Defenders win if they fully capture while opponent has zero points |
| `DefendingTeam` | `Team?` | `Teams[1]` | The defending team for overtime win condition |

### Capture & Holders

Each team has a **Capturing** value (from `0` to `CaptureTime`). When `Capturing` reaches `CaptureTime` the team becomes a **Holder** and begins earning points. If they lose the zone their progress rolls back.

### Points

Holders earn `Increase` points per second. Non-holders lose `Rollback` points per second. The first team to reach `PointsNeeded` wins the round, calling `gm:Stop(winnerTeam)`.

### Overtime

If `OvertimeThreshold` is set and the elapsed time reaches it without a winner, overtime begins. `OvertimeEntered` fires, and the win condition switches to `OvertimePointsNeeded`. A tied overtime can be broken by one team capturing the point while the other has zero points.

### Signals

```lua
gm.ContestedChanged:Connect(function(contested: boolean) end)
gm.OvertimeEntered:Connect(function() end)
gm.PointsChanged:Connect(function(team: Team, points: number) end)
gm.CapturingChanged:Connect(function(team: Team, capturing: number) end)
gm.HolderAdded:Connect(function(team: Team) end)
gm.HolderRemoved:Connect(function(team: Team) end)

-- Inherited from GamemodeCore:
gm.Started:Connect(function(metadata) end)
gm.Stopped:Connect(function(winner: Team?, metadata) end)
gm.ElapsedChanged:Connect(function(elapsed: number) end)
```

### Reading State

`getState()` returns a frozen snapshot of the current round state, useful for replication:

```lua
local state = gm:getState()
-- state.Active, state.Overtime, state.Contested,
-- state.PlayingTeams, state.Holders, state.Elapsed, ...
```

### Hooks

Terminal inherits `mount` from `GamemodeCore`:

```lua
gm:mount(function(self, ctx)
    local holders, setHolders = ctx:useState({})

    ctx:useEffect(function()
        local a = self.HolderAdded:Connect(function(team)
            setHolders(table.clone(self.Holders))
        end)
        local r = self.HolderRemoved:Connect(function(team)
            setHolders(table.clone(self.Holders))
        end)
        return function()
            a:Disconnect()
            r:Disconnect()
        end
    end, {})
end)
```