--!native
--!optimize 2

local RunService = game:GetService("RunService")

------------------------------------------------------------------------
-- Signal

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

function Signal.new<T...>(): Signal<T...>
	return setmetatable({ _id = 0, _cns = {} }, Signal) :: any
end

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

function Signal:Fire(...: any)
	local snap = table.clone(self._cns)
	for _, fn: any in snap do
		fn(...)
	end
end

function Signal:Once(fn: (...any) -> ()): Connection
	local c: Connection
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function Signal:Wait(): ...any
	local t = coroutine.running()
	local c: Connection
	c = self:Connect(function(...)
		c:Disconnect()
		task.spawn(t, ...)
	end)
	return coroutine.yield()
end

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

function GamemodeCore.register(gmType: string, tickFn: (self: GamemodeCore, dt: number) -> ())
	assert(type(gmType) == "string" and gmType ~= "", "gamemode-core: type must be a non-empty string")
	assert(type(tickFn) == "function", "gamemode-core: tickFn must be a function")
	if _registry[gmType] then
		warn(`gamemode-core: '{gmType}' already registered, overwriting`)
	end
	_registry[gmType] = { tickFn = tickFn }
end

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

	self.Started = Signal.new()
	self.Stopped = Signal.new()
	self.OnPaused = Signal.new()
	self.ElapsedChanged = Signal.new()
	self.Destroying = Signal.new()

	_instances[name] = self
	return self
end

function GamemodeCore.getByName(name: string): GamemodeCore?
	return _instances[name]
end

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

function GamemodeCore:Pause(metadata: any?)
	local gm: any = self
	if gm.Active and not gm.Paused then
		gm.Paused = true
		gm.OnPaused:Fire(metadata)
	end
end

function GamemodeCore:Resume()
	local gm: any = self
	if gm.Active and gm.Paused then
		gm.Paused = false
	end
end

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
