---
sidebar_position: 1
---

# Overview

`gamemode-core` is a reactive, hook-based lifecycle library that acts as the foundation for all gamemode packages in this collection. It manages a gamemode's state machine, drives a per-frame tick loop, and exposes a React-style hook system so any system can subscribe to gamemode state without tight coupling.

## Installation

```toml
[dependencies]
GamemodeCore = "codjo3/gamemode-core@VERSION"
```

```bash
wally install
```

Check [wally.run](https://wally.run) or the module's [`wally.toml`](https://github.com/codjo3/roblox-gamemodes/blob/main/modules/gamemode-core/wally.toml) for the latest version.

## Concepts

### Registering a Type

Before creating a gamemode instance you must register a **type** with a tick function. The tick function is called every `Heartbeat` while the gamemode is active and not paused.

```lua
local GamemodeCore = require(Packages.GamemodeCore)

GamemodeCore.register("MyMode", function(self, dt)
    -- self is the GamemodeCore instance
    -- dt is delta time in seconds
end)
```

### Creating an Instance

```lua
local gm = GamemodeCore.new("MyMode", "RoundOne", {
    ScoreLimit = 100,
})
```

The third argument is a config table — every key is copied directly onto the instance, so `gm.ScoreLimit == 100`.

### Lifecycle

```lua
gm:Start()           -- transitions to Active, begins Heartbeat loop
gm:Pause()           -- suspends the tick loop, fires OnPaused
gm:Resume()          -- resumes the tick loop
gm:Stop(winner)      -- ends the round, fires Stopped with winner
gm:Destroy()         -- tears down everything, removes from registry
```

### Signals

Every instance exposes typed signals you can connect to:

```lua
gm.Started:Connect(function(metadata) end)
gm.Stopped:Connect(function(winner, metadata) end)
gm.OnPaused:Connect(function(metadata) end)
gm.ElapsedChanged:Connect(function(elapsed: number) end)
gm.Destroying:Connect(function(gm) end)
```

### Hooks

`mount` lets you attach reactive logic to a gamemode instance. It takes a function that receives the instance and a `HookContext`, and re-runs that function every heartbeat while the gamemode is active.

```lua
gm:mount(function(self, ctx)
    local score, setScore = ctx:useState(0)

    ctx:useEffect(function()
        -- runs once on mount, cleanup runs on unmount or when deps change
        local c = self.Stopped:Connect(function()
            setScore(0)
        end)
        return function() c:Disconnect() end
    end, {})
end)
```

`mount` returns an **unmount function** — call it to remove that mounted function and run its cleanup:

```lua
local unmount = gm:mount(function(self, ctx) ... end)

-- later:
unmount()
```

### Available Hooks

| Hook | Description |
|---|---|
| `useState` | Persistent value slot with a setter dep |
| `useReducer` | Like useState but driven by a reducer function |
| `useMemo` | Cached computed value, recomputed when deps change |
| `useCallback` | Memoized function reference |
| `useRef` | Persistent mutable ref that does not trigger re-renders |
| `useEffect` | Side effect with optional cleanup, re-runs when deps change |

See the [API reference](../api/GamemodeCore) for full signatures.