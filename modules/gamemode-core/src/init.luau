--!native
--!optimize 2

local RunService = game:GetService("RunService")

------------------------------------------------------------------------
-- Signal

--[=[
	A simple typed signal implementation used throughout gamemode-core.

	@class Signal
]=]

--[=[
	A live connection returned by `Signal:Connect`.

	@interface Connection
	.Connected boolean -- Whether the connection is still active.
	.Disconnect (self: Connection) -> () -- Disconnects and deactivates this connection.
	@within Signal
]=]
export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	_id: number,
	_cns: { [number]: (T...) -> () },
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Destroy: (self: Signal<T...>) -> (),
}

local Signal = {}
Signal.__index = Signal

--[=[
	Creates a new Signal.

	```lua
	local signal = Signal.new()
	```

	@within Signal
	@return Signal<T...>
]=]
function Signal.new<T...>(): Signal<T...>
	return setmetatable({ _id = 0, _cns = {} }, Signal) :: any
end

--[=[
	Connects a callback to this signal. Returns a `Connection` that can be
	used to disconnect later.

	```lua
	local c = signal:Connect(function(value)
	    print(value)
	end)
	-- later:
	c:Disconnect()
	```

	@within Signal
	@param fn (T...) -> () -- Callback to invoke when the signal fires.
	@return Connection
]=]
function Signal:Connect(fn: (...any) -> ()): Connection
	local id: number = (self._id :: number) + 1
	self._id = id
	self._cns[id] = fn
	local c: Connection = { Connected = true, Disconnect = nil :: any }
	c.Disconnect = function()
		c.Connected = false
		self._cns[id] = nil
	end
	return c
end

--[=[
	Fires the signal, calling all connected callbacks with the provided arguments.

	@within Signal
	@param ... T... -- Arguments forwarded to all connected callbacks.
]=]
function Signal:Fire(...: any)
	local snap = table.clone(self._cns)
	for _, fn: any in snap do
		fn(...)
	end
end

--[=[
	Connects a callback that automatically disconnects after firing once.

	@within Signal
	@param fn (T...) -> () -- Callback to invoke once.
	@return Connection
]=]
function Signal:Once(fn: (...any) -> ()): Connection
	local c: Connection
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

--[=[
	Yields the current thread until the signal fires, then returns the fired arguments.

	```lua
	local winner = gm.Stopped:Wait()
	```

	@within Signal
	@yields
	@return T...
]=]
function Signal:Wait(): ...any
	local t = coroutine.running()
	local c: Connection
	c = self:Connect(function(...)
		c:Disconnect()
		task.spawn(t, ...)
	end)
	return coroutine.yield()
end

--[=[
	Disconnects all connections and makes the signal inert.

	@within Signal
]=]
function Signal:Destroy()
	self._cns = {}
end

------------------------------------------------------------------------
-- ReactiveSlot

export type Dep<T> = {
	Connect: (self: Dep<T>, fn: (T) -> ()) -> Connection,
} & typeof(setmetatable({} :: {}, {} :: { __call: (self: any, v: any) -> () }))

export type Ref<T> = { current: T }

local ReactiveSlot = {}
ReactiveSlot.__index = ReactiveSlot

local depMeta = {}
depMeta.__call = function(dep: any, v: any)
	dep._slot:set(v)
end
depMeta.__index = function(dep: any, k: string): any
	if k == "Connect" then
		return function(_self: any, fn: (any) -> ()): Connection
			return dep._slot._changed:Connect(fn)
		end
	end
	return nil
end

local reducerDepMeta = {}
reducerDepMeta.__call = function(dep: any, action: any)
	local slot = dep._slot
	slot:set(dep._reducer(slot._value, action))
end
reducerDepMeta.__index = depMeta.__index

local function newSlot(initial: any): any
	local s = setmetatable({}, ReactiveSlot)
	s._value = initial
	s._changed = Signal.new()
	return s
end

function ReactiveSlot:get(): any
	return self._value
end

function ReactiveSlot:set(v: any)
	if v == self._value then
		return
	end
	self._value = v
	self._changed:Fire(v)
end

------------------------------------------------------------------------
-- HookContext

--[=[
	Provides React-style hooks to functions mounted onto a `GamemodeCore`
	instance via `GamemodeCore:mount`. A new `HookContext` is created per
	mounted function and persists for the lifetime of that mount.

	Hooks must always be called in the same order on every invocation —
	the same rules as React hooks apply.

	@class HookContext
]=]
export type HookContext = {
	_resetCounters: (self: HookContext) -> (),

	useState: <T>(self: HookContext, initial: T) -> (T, Dep<T>),
	useReducer: <T, A>(self: HookContext, reducer: (state: T, action: A) -> T, initial: T) -> (T, Dep<A>),
	useMemo: <T>(self: HookContext, fn: () -> T, deps: { any }) -> T,
	useCallback: <T>(self: HookContext, fn: T, deps: { any }) -> T,
	useRef: <T>(self: HookContext, initial: T) -> Ref<T>,
	useEffect: (self: HookContext, fn: () -> () | (() -> ())?, deps: { any }) -> (),
}

local HookContext = {}
HookContext.__index = HookContext

local function snapDeps(deps: { any }, out: { any })
	for i = 1, #deps do
		out[i] = deps[i]
	end
end

local function makeContext(gamemode: any): HookContext
	local ctx: any = setmetatable({}, HookContext)
	ctx._gamemode = gamemode
	ctx._slots = {}
	ctx._si = 0
	ctx._memos = {}
	ctx._mi = 0
	ctx._effects = {}
	ctx._ei = 0
	return ctx :: HookContext
end

function HookContext:_resetCounters()
	self._si = 0
	self._mi = 0
	self._ei = 0
end

--[=[
	Returns the current value of a persistent state slot and a `Dep` that
	can be called to update it. On subsequent calls the initial value is
	ignored and the stored value is returned.

	```lua
	gm:mount(function(self, ctx)
	    local score, setScore = ctx:useState(0)
	    -- call setScore(n) to update
	end)
	```

	@within HookContext
	@param initial T -- Value used only on the first call.
	@return T -- Current value.
	@return Dep<T> -- Callable setter. Also has a `:Connect` method to observe changes.
]=]
function HookContext:useState(initial: any): (any, any)
	local idx: number = self._si + 1
	self._si = idx
	local slots: { any } = self._slots
	local slot: any = slots[idx]
	if not slot then
		slot = newSlot(initial)
		slots[idx] = slot
	end
	local dep = setmetatable({ _slot = slot }, depMeta)
	return slot._value, dep
end

--[=[
	Like `useState` but the setter accepts an action that is passed through
	a reducer function to produce the next state.

	```lua
	local function reducer(state, action)
	    if action == "increment" then return state + 1 end
	    return state
	end

	gm:mount(function(self, ctx)
	    local count, dispatch = ctx:useReducer(reducer, 0)
	    dispatch("increment")
	end)
	```

	@within HookContext
	@param reducer (state: T, action: A) -> T -- Pure function that computes the next state.
	@param initial T -- Initial state value.
	@return T -- Current state.
	@return Dep<A> -- Callable dispatcher.
]=]
function HookContext:useReducer(reducer: any, initial: any): (any, any)
	local idx: number = self._si + 1
	self._si = idx
	local slots: { any } = self._slots
	local slot: any = slots[idx]
	if not slot then
		slot = newSlot(initial)
		slots[idx] = slot
	end
	local dep = setmetatable({ _slot = slot, _reducer = reducer }, reducerDepMeta)
	return slot._value, dep
end

--[=[
	Returns a cached value that is only recomputed when one of the `deps`
	changes between calls.

	```lua
	gm:mount(function(self, ctx)
	    local expensive = ctx:useMemo(function()
	        return computeSomething(self.Score)
	    end, { self.Score })
	end)
	```

	@within HookContext
	@param fn () -> T -- Function that computes the value.
	@param deps { any } -- List of values to watch for changes.
	@return T -- Cached computed value.
]=]
function HookContext:useMemo(fn: () -> any, deps: { any }): any
	local idx: number = self._mi + 1
	self._mi = idx
	local memos: { any } = self._memos
	local m: any = memos[idx]
	local dlen = #deps
	if not m then
		local snap = table.create(dlen)
		snapDeps(deps, snap)
		m = { v = fn(), snap = snap }
		memos[idx] = m
	else
		local snap: { any } = m.snap
		if #snap ~= dlen then
			snap = table.create(dlen)
			m.snap = snap
		end
		local changed = false
		for i = 1, dlen do
			local nv = deps[i]
			if snap[i] ~= nv then
				snap[i] = nv
				changed = true
			end
		end
		if changed then
			m.v = fn()
		end
	end
	return m.v
end

--[=[
	Returns a memoized function reference that only changes when one of
	the `deps` changes. Equivalent to `useMemo(function() return fn end, deps)`.

	@within HookContext
	@param fn T -- Function to memoize.
	@param deps { any } -- List of values to watch for changes.
	@return T -- Stable function reference.
]=]
function HookContext:useCallback(fn: any, deps: { any }): any
	return self:useMemo(function()
		return fn
	end, deps)
end

local refMeta = {}
refMeta.__index = function(proxy: any, k: string): any
	if k == "current" then
		return proxy._box.current
	end
	return nil
end
refMeta.__newindex = function(proxy: any, k: string, v: any)
	if k == "current" then
		proxy._box.current = v
	end
end

--[=[
	Returns a persistent mutable ref object with a `.current` field.
	Unlike `useState`, mutating `.current` does not trigger a re-run.

	```lua
	gm:mount(function(self, ctx)
	    local timerRef = ctx:useRef(0)
	    timerRef.current += dt
	end)
	```

	@within HookContext
	@param initial T -- Initial value of `.current`.
	@return Ref<T>
]=]
function HookContext:useRef(initial: any): Ref<any>
	local idx: number = self._si + 1
	self._si = idx
	local slots: { any } = self._slots
	local box: any = slots[idx]
	if not box then
		box = { current = initial }
		slots[idx] = box
	end
	return setmetatable({ _box = box }, refMeta) :: any
end

--[=[
	Runs a side effect when `deps` change. The effect function may return a
	cleanup function that is called before the next run or when the mount
	is destroyed.

	```lua
	gm:mount(function(self, ctx)
	    ctx:useEffect(function()
	        local c = self.Stopped:Connect(function()
	            print("stopped")
	        end)
	        return function() c:Disconnect() end
	    end, {})
	end)
	```

	@within HookContext
	@param fn () -> (() -> ())? -- Effect function. Return a cleanup function or nothing.
	@param deps { any } -- Re-runs the effect when any dep changes.
]=]
function HookContext:useEffect(fn: () -> (() -> ())?, deps: { any })
	local idx: number = self._ei + 1
	self._ei = idx
	local effects: { any } = self._effects
	local e: any = effects[idx]
	local dlen = #deps
	if not e then
		local snap = table.create(dlen)
		snapDeps(deps, snap)
		local cleanup: any = nil
		local ok, result = pcall(fn)
		if ok and type(result) == "function" then
			cleanup = result
		elseif not ok then
			warn("gamemode-core [useEffect]: " .. tostring(result))
		end
		effects[idx] = { cleanup = cleanup, snap = snap }
	else
		local snap: { any } = e.snap
		if #snap ~= dlen then
			snap = table.create(dlen)
			e.snap = snap
		end
		local changed = false
		for i = 1, dlen do
			local nv = deps[i]
			if snap[i] ~= nv then
				snap[i] = nv
				changed = true
			end
		end
		if changed then
			if e.cleanup then
				pcall(e.cleanup)
			end
			e.cleanup = nil
			local ok, result = pcall(fn)
			if ok and type(result) == "function" then
				e.cleanup = result
			elseif not ok then
				warn("gamemode-core [useEffect]: " .. tostring(result))
			end
		end
	end
end

local function flushEffectCleanups(effects: { any })
	for _, e in effects do
		if e and e.cleanup then
			pcall(e.cleanup)
			e.cleanup = nil
		end
	end
end

------------------------------------------------------------------------
-- MountEntry

type MountEntry = {
	ctx: HookContext,
	fn: (gamemode: any, ctx: HookContext) -> (),
	alive: boolean,
}

local function makeMountEntry(gamemode: any, mountFn: (any, HookContext) -> ()): MountEntry
	return {
		ctx = makeContext(gamemode),
		fn = mountFn,
		alive = true,
	}
end

local function tickMountEntry(entry: MountEntry, gamemode: any)
	if not entry.alive then
		return
	end
	local ctx: any = entry.ctx
	ctx:_resetCounters()
	local ok, err = pcall(entry.fn :: any, gamemode, ctx)
	if not ok then
		warn("gamemode-core [mount]: " .. tostring(err))
	end
end

local function destroyMountEntry(entry: MountEntry)
	entry.alive = false
	flushEffectCleanups((entry :: any).ctx._effects)
end

------------------------------------------------------------------------
-- GamemodeCore

--[=[
	Reactive hook-based gamemode lifecycle core.

	Register a gamemode type with `GamemodeCore.register`, then create
	instances with `GamemodeCore.new`. Each instance manages an Active/Paused
	state machine, a per-frame tick loop, and a React-style hook system via
	`mount`.

	```lua
	local GamemodeCore = require(Packages.GamemodeCore)

	GamemodeCore.register("MyMode", function(self, dt)
	    -- custom per-frame logic
	end)

	local gm = GamemodeCore.new("MyMode", "RoundOne", {
	    ScoreLimit = 100,
	})

	gm.Stopped:Connect(function(winner, metadata)
	    print("Winner:", winner)
	end)

	gm:Start()
	```

	@class GamemodeCore
]=]

--[=[
	A free-form config table passed to `GamemodeCore.new`. Every key is
	copied directly onto the instance.

	@type Config { [string]: any }
	@within GamemodeCore
]=]
export type Config = { [string]: any }

export type GamemodeCore = {
	_type: string,
	_name: string,
	_tickFn: (self: GamemodeCore, dt: number) -> (),
	_mounts: { MountEntry },
	_heartbeat: RBXScriptConnection?,

	Active: boolean,
	Paused: boolean,
	Elapsed: number,

	Started: Signal<any?>,
	Stopped: Signal<any?, any?>,
	OnPaused: Signal<any?>,
	ElapsedChanged: Signal<number>,
	Destroying: Signal<GamemodeCore>,

	mount: (self: GamemodeCore, fn: (gm: GamemodeCore, ctx: HookContext) -> ()) -> () -> (),

	Start: (self: GamemodeCore, metadata: any?) -> (),
	Stop: (self: GamemodeCore, winner: any?, metadata: any?) -> (),
	Pause: (self: GamemodeCore, metadata: any?) -> (),
	Resume: (self: GamemodeCore) -> (),
	Destroy: (self: GamemodeCore) -> (),
}

local _registry: { [string]: { tickFn: (any, number) -> () } } = {}
local _instances: { [string]: GamemodeCore } = {}

local GamemodeCore = {}
GamemodeCore.__index = GamemodeCore

--[=[
	Registers a gamemode type with a tick function. Must be called before
	`GamemodeCore.new` for that type. Registering the same type twice
	overwrites the previous registration with a warning.

	```lua
	GamemodeCore.register("MyMode", function(self, dt)
	    if self.Elapsed > 300 then
	        self:Stop(nil)
	    end
	end)
	```

	@within GamemodeCore
	@param gmType string -- Unique identifier for this gamemode type.
	@param tickFn (self: GamemodeCore, dt: number) -> () -- Called every Heartbeat while active and unpaused.
]=]
function GamemodeCore.register(gmType: string, tickFn: (self: GamemodeCore, dt: number) -> ())
	assert(type(gmType) == "string" and gmType ~= "", "gamemode-core: type must be a non-empty string")
	assert(type(tickFn) == "function", "gamemode-core: tickFn must be a function")
	if _registry[gmType] then
		warn(`gamemode-core: '{gmType}' already registered, overwriting`)
	end
	_registry[gmType] = { tickFn = tickFn }
end

--[=[
	Creates a new `GamemodeCore` instance of the given registered type.
	Every key in `config` is shallow-copied onto the instance.

	```lua
	local gm = GamemodeCore.new("MyMode", "RoundOne", {
	    ScoreLimit = 100,
	})
	```

	@within GamemodeCore
	@param gmType string -- A type previously registered with `GamemodeCore.register`.
	@param name string -- Unique name for this instance. Used by `GamemodeCore.getByName`.
	@param config Config -- Key-value pairs copied onto the instance.
	@return GamemodeCore
]=]
function GamemodeCore.new(gmType: string, name: string, config: Config): GamemodeCore
	assert(_registry[gmType], `gamemode-core: type '{gmType}' not registered`)
	assert(not _instances[name], `gamemode-core: '{name}' already exists`)

	local self: any = setmetatable({}, GamemodeCore)

	self._type = gmType
	self._name = name
	self._tickFn = _registry[gmType].tickFn
	self._mounts = {}
	self._heartbeat = nil

	for k, v in config do
		self[k] = v
	end

	self.Active = false
	self.Paused = false
	self.Elapsed = 0

	--[=[
		Fires when the gamemode starts. Receives the optional metadata passed to `Start`.
		@prop Started Signal<any?>
		@within GamemodeCore
	]=]
	self.Started = Signal.new()

	--[=[
		Fires when the gamemode stops. Receives the winner and optional metadata passed to `Stop`.
		@prop Stopped Signal<any?, any?>
		@within GamemodeCore
	]=]
	self.Stopped = Signal.new()

	--[=[
		Fires when the gamemode is paused. Receives the optional metadata passed to `Pause`.
		@prop OnPaused Signal<any?>
		@within GamemodeCore
	]=]
	self.OnPaused = Signal.new()

	--[=[
		Fires every Heartbeat while the gamemode is active and unpaused, with the current elapsed time.
		@prop ElapsedChanged Signal<number>
		@within GamemodeCore
	]=]
	self.ElapsedChanged = Signal.new()

	--[=[
		Fires just before the gamemode is destroyed.
		@prop Destroying Signal<GamemodeCore>
		@within GamemodeCore
	]=]
	self.Destroying = Signal.new()

	_instances[name] = self
	return self
end

--[=[
	Returns the `GamemodeCore` instance registered under `name`, or `nil`
	if no such instance exists.

	@within GamemodeCore
	@param name string
	@return GamemodeCore?
]=]
function GamemodeCore.getByName(name: string): GamemodeCore?
	return _instances[name]
end

--[=[
	Attaches a reactive function to the gamemode. The function receives the
	instance and a `HookContext` and is called every Heartbeat while the
	gamemode is active and unpaused.

	Returns an unmount function. Call it to detach the mount and run any
	pending `useEffect` cleanups.

	```lua
	local unmount = gm:mount(function(self, ctx)
	    local score, setScore = ctx:useState(0)

	    ctx:useEffect(function()
	        local c = self.Stopped:Connect(function() setScore(0) end)
	        return function() c:Disconnect() end
	    end, {})
	end)

	-- later:
	unmount()
	```

	@within GamemodeCore
	@param fn (gm: GamemodeCore, ctx: HookContext) -> () -- Reactive function to mount.
	@return () -> () -- Call to unmount and clean up.
]=]
function GamemodeCore:mount(fn: (gm: GamemodeCore, ctx: HookContext) -> ()): () -> ()
	local gm: any = self
	local entry = makeMountEntry(gm, fn)
	local mounts: { any } = gm._mounts
	local idx = #mounts + 1
	mounts[idx] = entry

	if gm.Active and not gm.Paused then
		tickMountEntry(entry, gm)
	end

	return function()
		destroyMountEntry(entry)
		for i = 1, #mounts do
			if mounts[i] == entry then
				table.remove(mounts, i)
				break
			end
		end
	end
end

--[=[
	Starts the gamemode. Transitions `Active` to `true`, resets `Elapsed`
	to `0`, begins the Heartbeat loop, ticks all mounted functions once,
	then fires `Started`.

	Does nothing if already active.

	@within GamemodeCore
	@param metadata any? -- Optional value forwarded to `Started` listeners.
]=]
function GamemodeCore:Start(metadata: any?)
	local gm: any = self
	if gm.Active then
		return
	end
	gm.Active = true
	gm.Paused = false
	gm.Elapsed = 0

	for _, entry: any in gm._mounts do
		tickMountEntry(entry, gm)
	end

	local mounts: { any } = gm._mounts

	gm._heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		if gm.Paused then
			return
		end

		gm.Elapsed += dt
		gm.ElapsedChanged:Fire(gm.Elapsed)

		gm._tickFn(gm, dt)

		for i = 1, #mounts do
			tickMountEntry(mounts[i], gm)
		end
	end)

	gm.Started:Fire(metadata)
end

--[=[
	Stops the gamemode. Disconnects the Heartbeat loop, flushes all
	`useEffect` cleanups, fires `Stopped`, then resets `Elapsed` to `0`.

	Does nothing if not active.

	@within GamemodeCore
	@param winner any? -- Passed as the first argument to `Stopped` listeners.
	@param metadata any? -- Passed as the second argument to `Stopped` listeners.
]=]
function GamemodeCore:Stop(winner: any?, metadata: any?)
	local gm: any = self
	if not gm.Active then
		return
	end
	gm.Active = false
	gm.Paused = false

	if gm._heartbeat then
		gm._heartbeat:Disconnect()
		gm._heartbeat = nil
	end

	for _, entry: any in gm._mounts do
		flushEffectCleanups(entry.ctx._effects)
		table.clear(entry.ctx._effects)
	end

	gm.Stopped:Fire(winner, metadata)
	gm.Elapsed = 0
end

--[=[
	Pauses the gamemode, suspending the tick loop and mount calls.
	Fires `OnPaused`. Does nothing if not active or already paused.

	@within GamemodeCore
	@param metadata any? -- Optional value forwarded to `OnPaused` listeners.
]=]
function GamemodeCore:Pause(metadata: any?)
	local gm: any = self
	if gm.Active and not gm.Paused then
		gm.Paused = true
		gm.OnPaused:Fire(metadata)
	end
end

--[=[
	Resumes a paused gamemode. Does nothing if not active or not paused.

	@within GamemodeCore
]=]
function GamemodeCore:Resume()
	local gm: any = self
	if gm.Active and gm.Paused then
		gm.Paused = false
	end
end

--[=[
	Destroys the gamemode. Fires `Destroying`, stops the round if active,
	destroys all mounts and signals, and removes the instance from the
	global registry.

	After calling this, the instance must not be used again.

	@within GamemodeCore
]=]
function GamemodeCore:Destroy()
	local gm: any = self
	gm.Destroying:Fire(gm)
	if gm.Active then
		gm:Stop(nil, nil)
	end

	for _, entry: any in gm._mounts do
		destroyMountEntry(entry)
	end
	table.clear(gm._mounts)

	gm.Started:Destroy()
	gm.Stopped:Destroy()
	gm.OnPaused:Destroy()
	gm.ElapsedChanged:Destroy()
	gm.Destroying:Destroy()

	_instances[gm._name] = nil
	setmetatable(gm, nil)
end

return GamemodeCore
