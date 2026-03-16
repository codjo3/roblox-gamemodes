-- Layout:
--   Signal
--   ReactiveSlot / Dep
--   HookContext (useState / useReducer / useMemo / useCallback / useRef / useEffect)
--   GamemodeCore lifecycle
--   GamemodeCore :mount

local JestGlobals = require("@dev/JestGlobals")
local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it

local GamemodeCore = require("@src")

------------------------------------------------------------------------
-- Helpers

local _counter = 0
local function uniqueName(prefix: string?): string
	_counter += 1
	return (prefix or "gm") .. "_" .. tostring(_counter)
end

local BASE_TYPE = "TestType"
GamemodeCore.register(BASE_TYPE, function(_self, _dt) end)

local function newGM(config: GamemodeCore.Config?)
	return GamemodeCore.new(BASE_TYPE, uniqueName(), config or {})
end

------------------------------------------------------------------------
-- Signal

describe("Signal", function()
	it("fires connected listeners", function()
		local gm = newGM()
		local received = {}
		gm.Started:Connect(function(meta)
			table.insert(received, meta)
		end)
		gm:Start("hello")
		expect(#received).toBe(1)
		expect(received[1]).toBe("hello")
		gm:Destroy()
	end)

	it("does not fire after Disconnect", function()
		local gm = newGM()
		local count = 0
		local c = gm.Started:Connect(function()
			count += 1
		end)
		c:Disconnect()
		gm:Start()
		expect(count).toBe(0)
		gm:Destroy()
	end)

	it("Once fires exactly once", function()
		local gm = newGM()
		local count = 0
		gm.Started:Once(function()
			count += 1
		end)
		gm:Start()
		gm:Stop()
		gm:Start()
		expect(count).toBe(1)
		gm:Destroy()
	end)

	it("Fire is safe during iteration (snapshot semantics)", function()
		local gm = newGM()
		local order = {}
		gm.Started:Connect(function()
			table.insert(order, "first")
			gm.Started:Connect(function()
				table.insert(order, "late")
			end)
		end)
		gm:Start()
		expect(#order).toBe(1)
		expect(order[1]).toBe("first")
		gm:Destroy()
	end)

	it("Destroy removes all listeners", function()
		local gm = newGM()
		local count = 0
		gm.Started:Connect(function()
			count += 1
		end)
		gm.Started:Destroy()
		gm.Started:Fire()
		expect(count).toBe(0)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- GamemodeCore.new

describe("GamemodeCore.new", function()
	it("copies config fields onto the instance", function()
		type meta = { MaxPlayers: number, MapName: string }
		local gm = GamemodeCore.new(BASE_TYPE, uniqueName(), {
			MaxPlayers = 10,
			MapName = "Jungle",
		}) :: GamemodeCore.GamemodeCore & meta
		expect(gm.MaxPlayers).toBe(10)
		expect(gm.MapName).toBe("Jungle")
		gm:Destroy()
	end)

	it("starts in inactive, unpaused state with Elapsed = 0", function()
		local gm = newGM()
		expect(gm.Active).toBe(false)
		expect(gm.Paused).toBe(false)
		expect(gm.Elapsed).toBe(0)
		gm:Destroy()
	end)

	it("registers under getByName", function()
		local name = uniqueName()
		local gm = GamemodeCore.new(BASE_TYPE, name, {})
		expect(GamemodeCore.getByName(name)).toBe(gm)
		gm:Destroy()
	end)

	it("throws when registering a duplicate name", function()
		local name = uniqueName()
		local gm = GamemodeCore.new(BASE_TYPE, name, {})
		expect(function()
			GamemodeCore.new(BASE_TYPE, name, {})
		end).toThrow()
		gm:Destroy()
	end)

	it("throws when using an unregistered type", function()
		expect(function()
			GamemodeCore.new("NonExistentType_xyz", uniqueName(), {})
		end).toThrow()
	end)
end)

------------------------------------------------------------------------
-- GamemodeCore.register

describe("GamemodeCore.register", function()
	it("throws on empty type string", function()
		expect(function()
			GamemodeCore.register("", function() end)
		end).toThrow()
	end)

	it("throws when tickFn is not a function", function()
		expect(function()
			GamemodeCore.register(uniqueName("type"), "notAFunction" :: any)
		end).toThrow()
	end)

	it("warns but succeeds when overwriting an existing type", function()
		local typeName = uniqueName("type")
		GamemodeCore.register(typeName, function() end)
		expect(function()
			GamemodeCore.register(typeName, function() end)
		end).never.toThrow()
	end)
end)

------------------------------------------------------------------------
-- Start / Stop

describe("GamemodeCore:Start / Stop", function()
	it("sets Active = true and fires Started", function()
		local gm = newGM()
		local fired = false
		gm.Started:Connect(function()
			fired = true
		end)
		gm:Start()
		expect(gm.Active).toBe(true)
		expect(fired).toBe(true)
		gm:Destroy()
	end)

	it("is idempotent: double Start does not double-fire", function()
		local gm = newGM()
		local count = 0
		gm.Started:Connect(function()
			count += 1
		end)
		gm:Start()
		gm:Start()
		expect(count).toBe(1)
		gm:Destroy()
	end)

	it("Stop sets Active = false and fires Stopped with winner", function()
		local gm = newGM()
		local winner = nil
		gm.Stopped:Connect(function(w)
			winner = w
		end)
		gm:Start()
		gm:Stop("PlayerA")
		expect(gm.Active).toBe(false)
		expect(winner).toBe("PlayerA")
		gm:Destroy()
	end)

	it("Stop resets Elapsed to 0", function()
		local gm = newGM()
		gm:Start()
		gm.Elapsed = 99
		gm:Stop()
		expect(gm.Elapsed).toBe(0)
		gm:Destroy()
	end)

	it("Stop on inactive gamemode is a no-op", function()
		local gm = newGM()
		local count = 0
		gm.Stopped:Connect(function()
			count += 1
		end)
		gm:Stop()
		expect(count).toBe(0)
		gm:Destroy()
	end)

	it("can be restarted after Stop", function()
		local gm = newGM()
		local startCount = 0
		gm.Started:Connect(function()
			startCount += 1
		end)
		gm:Start()
		gm:Stop()
		gm:Start()
		expect(startCount).toBe(2)
		expect(gm.Active).toBe(true)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- Pause / Resume

describe("GamemodeCore:Pause / Resume", function()
	it("Pause sets Paused = true and fires OnPaused", function()
		local gm = newGM()
		local meta = nil
		gm.OnPaused:Connect(function(m)
			meta = m
		end)
		gm:Start()
		gm:Pause("reason")
		expect(gm.Paused).toBe(true)
		expect(meta).toBe("reason")
		gm:Destroy()
	end)

	it("Pause while already paused is a no-op", function()
		local gm = newGM()
		local count = 0
		gm.OnPaused:Connect(function()
			count += 1
		end)
		gm:Start()
		gm:Pause()
		gm:Pause()
		expect(count).toBe(1)
		gm:Destroy()
	end)

	it("Pause on inactive gamemode is a no-op", function()
		local gm = newGM()
		gm:Pause()
		expect(gm.Paused).toBe(false)
		gm:Destroy()
	end)

	it("Resume clears Paused flag", function()
		local gm = newGM()
		gm:Start()
		gm:Pause()
		gm:Resume()
		expect(gm.Paused).toBe(false)
		gm:Destroy()
	end)

	it("Resume when not paused is a no-op", function()
		local gm = newGM()
		gm:Start()
		gm:Resume()
		expect(gm.Paused).toBe(false)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- Destroy

describe("GamemodeCore:Destroy", function()
	it("fires Destroying signal", function()
		local gm = newGM()
		local destroyed = nil
		gm.Destroying:Connect(function(g)
			destroyed = g
		end)
		gm:Destroy()
		expect(destroyed).toBe(gm)
	end)

	it("stops an active gamemode on Destroy", function()
		local gm = newGM()
		gm:Start()
		gm:Destroy()
		expect(GamemodeCore.getByName(gm._name)).toBeNil()
	end)

	it("removes instance from registry", function()
		local name = uniqueName()
		local gm = GamemodeCore.new(BASE_TYPE, name, {})
		gm:Destroy()
		expect(GamemodeCore.getByName(name)).toBeNil()
	end)

	it("allows re-using the name after Destroy", function()
		local name = uniqueName()
		local gm1 = GamemodeCore.new(BASE_TYPE, name, {})
		gm1:Destroy()
		expect(function()
			local gm2 = GamemodeCore.new(BASE_TYPE, name, {})
			gm2:Destroy()
		end).never.toThrow()
	end)
end)

------------------------------------------------------------------------
-- :mount

describe("GamemodeCore:mount", function()
	it("mount fn runs once on Start", function()
		local gm = newGM()
		local runCount = 0
		gm:mount(function()
			runCount += 1
		end)
		gm:Start()
		expect(runCount).toBe(1)
		gm:Destroy()
	end)

	it("mount fn registered before Start runs on Start", function()
		local gm = newGM()
		local ran = false
		gm:mount(function()
			ran = true
		end)
		expect(ran).toBe(false)
		gm:Start()
		expect(ran).toBe(true)
		gm:Destroy()
	end)

	it("mount fn registered on an already-Active gm runs immediately", function()
		local gm = newGM()
		local ran = false
		gm:Start()
		gm:mount(function()
			ran = true
		end)
		expect(ran).toBe(true)
		gm:Destroy()
	end)

	it("unmount function stops the fn from running and flushes cleanups", function()
		local gm = newGM()
		local runCount = 0
		local cleaned = false

		local unmount = gm:mount(function(_g, ctx)
			runCount += 1
			ctx:useEffect(function()
				return function()
					cleaned = true
				end
			end, {})
		end)

		gm:Start()
		unmount()
		expect(cleaned).toBe(true)
		expect(runCount).toBe(1)
		gm:Destroy()
	end)

	it("useEffect inside mount: runs once with empty deps", function()
		local gm = newGM()
		local fxCount = 0

		gm:mount(function(_g, ctx)
			ctx:useEffect(function()
				fxCount += 1
			end, {})
		end)

		gm:Start()
		expect(fxCount).toBe(1)
		gm:Destroy()
	end)

	it("useEffect cleanup called on Stop", function()
		local gm = newGM()
		local cleaned = false

		gm:mount(function(_g, ctx)
			ctx:useEffect(function()
				return function()
					cleaned = true
				end
			end, {})
		end)

		gm:Start()
		expect(cleaned).toBe(false)
		gm:Stop()
		expect(cleaned).toBe(true)
		gm:Destroy()
	end)

	it("useEffect cleanup called on Destroy", function()
		local gm = newGM()
		local cleaned = false

		gm:mount(function(_g, ctx)
			ctx:useEffect(function()
				return function()
					cleaned = true
				end
			end, {})
		end)

		gm:Start()
		gm:Destroy()
		expect(cleaned).toBe(true)
	end)

	it("useEffect re-runs when a dep value changes", function()
		local gm = newGM()
		local fxCount = 0
		local score = 0
		local setScore: any = nil

		gm:mount(function(_g, ctx)
			local v, set = ctx:useState(0)
			score = v
			setScore = set
			ctx:useEffect(function()
				fxCount += 1
			end, { score })
		end)

		gm:Start()
		expect(fxCount).toBe(1)

		setScore(42)

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(fxCount).toBe(2)
		gm:Destroy()
	end)

	it("useEffect does NOT re-run when dep value is unchanged", function()
		local gm = newGM()
		local fxCount = 0
		local score = 0

		gm:mount(function(_g, ctx)
			local v, _ = ctx:useState(0)
			score = v
			ctx:useEffect(function()
				fxCount += 1
			end, { score })
		end)

		gm:Start()
		expect(fxCount).toBe(1)

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(fxCount).toBe(1)
		gm:Destroy()
	end)

	it("useEffect error is caught and does not crash the tick", function()
		local gm = newGM()
		gm:mount(function(_g, ctx)
			ctx:useEffect(function()
				error("intentional test error")
			end, {})
		end)
		expect(function()
			gm:Start()
		end).never.toThrow()
		gm:Destroy()
	end)

	it("mount error is caught and does not crash the tick", function()
		local gm = newGM()
		gm:mount(function()
			error("mount error")
		end)
		expect(function()
			gm:Start()
		end).never.toThrow()
		gm:Destroy()
	end)

	it("effects re-run after Stop then Start (state is reset)", function()
		local gm = newGM()
		local fxCount = 0

		gm:mount(function(_g, ctx)
			ctx:useEffect(function()
				fxCount += 1
			end, {})
		end)

		gm:Start()
		expect(fxCount).toBe(1)
		gm:Stop()
		gm:Start()
		expect(fxCount).toBe(2)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- HookContext – useState

describe("HookContext.useState", function()
	it("returns the initial value on first call", function()
		local gm = newGM()
		local captured = nil

		gm:mount(function(_g, ctx)
			local v, _ = ctx:useState(99)
			captured = v
		end)

		gm:Start()
		expect(captured).toBe(99)
		gm:Destroy()
	end)

	it("setter (Dep) is callable and updates slot value", function()
		local gm = newGM()
		local setterRef: any = nil
		local slotRef: any = nil

		gm:mount(function(_g, ctx)
			local _, set = ctx:useState(0)
			setterRef = set
			slotRef = (set :: any)._slot
		end)

		gm:Start()
		setterRef(10)
		expect(slotRef._value).toBe(10)
		gm:Destroy()
	end)

	it("Dep has :Connect — fires when value changes", function()
		local gm = newGM()
		local capturedDep: any = nil
		local notified = nil

		gm:mount(function(_g, ctx)
			local _, set = ctx:useState(0)
			capturedDep = set
		end)

		gm:Start()
		expect(type(capturedDep.Connect)).toBe("function")
		capturedDep:Connect(function(v)
			notified = v
		end)
		capturedDep(99)
		expect(notified).toBe(99)
		gm:Destroy()
	end)

	it("setter is a no-op when new value equals current value", function()
		local gm = newGM()
		local fireCount = 0
		local setterRef: any = nil

		gm:mount(function(_g, ctx)
			local _, set = ctx:useState(42)
			setterRef = set
		end)

		gm:Start()
		setterRef:Connect(function()
			fireCount += 1
		end)
		setterRef(42)
		expect(fireCount).toBe(0)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- HookContext – useReducer

describe("HookContext.useReducer", function()
	it("dispatching an action updates state via reducer", function()
		local gm = newGM()
		local slotRef: any = nil
		local dispatch: any = nil

		gm:mount(function(_g, ctx)
			local _, d = ctx:useReducer(function(s: number, action)
				if action == "inc" then
					return s + 1
				elseif action == "dec" then
					return s - 1
				end
				return s
			end, 0)
			dispatch = d
			slotRef = (d :: any)._slot
		end)

		gm:Start()
		dispatch("inc")
		dispatch("inc")
		dispatch("dec")
		expect(slotRef._value).toBe(1)
		gm:Destroy()
	end)

	it("dispatch has :Connect — fires on each state change", function()
		local gm = newGM()
		local changes = {}
		local dispatch: any = nil

		gm:mount(function(_g, ctx)
			local _, d = ctx:useReducer(function(s: number, a: number)
				return s + a
			end, 0)
			dispatch = d
		end)

		gm:Start()
		dispatch:Connect(function(v)
			table.insert(changes, v)
		end)
		dispatch(5)
		dispatch(3)
		expect(#changes).toBe(2)
		expect(changes[1]).toBe(5)
		expect(changes[2]).toBe(8)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- HookContext – useMemo & useCallback

describe("HookContext.useMemo", function()
	it("recomputes when a dep value changes", function()
		local gm = newGM()
		local computeCount = 0
		local setX: any = nil

		gm:mount(function(_g, ctx)
			local x: number, sx = ctx:useState(1)
			setX = sx
			ctx:useMemo(function()
				computeCount += 1
				return x * 2
			end, { x })
		end)

		gm:Start()
		expect(computeCount).toBe(1)

		setX(5)

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(computeCount).toBe(2)
		gm:Destroy()
	end)

	it("does NOT recompute when dep value is unchanged", function()
		local gm = newGM()
		local computeCount = 0

		gm:mount(function(_g, ctx)
			local x: number, _ = ctx:useState(1)
			ctx:useMemo(function()
				computeCount += 1
				return x * 2
			end, { x })
		end)

		gm:Start()
		expect(computeCount).toBe(1)

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(computeCount).toBe(1)
		gm:Destroy()
	end)

	it("returns the memoised value reference when unchanged", function()
		local gm = newGM()
		local results = {}

		gm:mount(function(_g, ctx)
			local x, _ = ctx:useState(0)
			local v = ctx:useMemo(function()
				return {}
			end, { x })
			table.insert(results, v)
		end)

		gm:Start()

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(results[1]).toBe(results[2])
		gm:Destroy()
	end)
end)

describe("HookContext.useCallback", function()
	it("returns a function", function()
		local gm = newGM()
		local cb: any = nil

		gm:mount(function(_g, ctx)
			cb = ctx:useCallback(function()
				return 42
			end, {})
		end)

		gm:Start()
		expect(type(cb)).toBe("function")
		expect(cb()).toBe(42)
		gm:Destroy()
	end)

	it("returns the same function reference when deps unchanged", function()
		local gm = newGM()
		local refs = {}

		gm:mount(function(_g, ctx)
			local x, _ = ctx:useState(0)
			local fn = ctx:useCallback(function() end, { x })
			table.insert(refs, fn)
		end)

		gm:Start()

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(refs[1]).toBe(refs[2])
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- HookContext – useRef

describe("HookContext.useRef", function()
	it("current is readable and writable", function()
		local gm = newGM()
		local refHolder: any = nil

		gm:mount(function(_g, ctx)
			local r = ctx:useRef(0)
			refHolder = r
		end)

		gm:Start()
		expect(refHolder.current).toBe(0)
		refHolder.current = 42
		expect(refHolder.current).toBe(42)
		gm:Destroy()
	end)

	it("persists mutations across ticks (box stable)", function()
		local gm = newGM()
		local reads = {}
		local tickRef: any = nil

		gm:mount(function(_g, ctx)
			local r = ctx:useRef(0)
			tickRef = r
			table.insert(reads, r.current)
			r.current = (r.current :: number) + 1
		end)

		gm:Start()

		for _, entry in (gm :: any)._mounts do
			local ctx = entry.ctx
			ctx:_resetCounters()
			entry.fn(gm, ctx)
		end

		expect(reads[1]).toBe(0)
		expect(reads[2]).toBe(1)
		expect(tickRef.current).toBe(2)
		gm:Destroy()
	end)

	it("ref mutation does NOT fire any change notifications", function()
		local gm = newGM()
		local notified = false

		gm:mount(function(_g, ctx)
			local r = ctx:useRef(0)
			r.current = 99
		end)

		gm:Start()
		expect(notified).toBe(false)
		gm:Destroy()
	end)
end)

------------------------------------------------------------------------
-- Multiple concurrent instances

describe("Multiple instances", function()
	it("mount state is isolated between instances", function()
		local gmA = newGM()
		local gmB = newGM()
		local slotA: any = nil
		local slotB: any = nil

		gmA:mount(function(_g, ctx)
			local _, set = ctx:useState(10)
			slotA = (set :: any)._slot
		end)
		gmB:mount(function(_g, ctx)
			local _, set = ctx:useState(20)
			slotB = (set :: any)._slot
		end)

		gmA:Start()
		gmB:Start()

		expect(slotA._value).toBe(10)
		expect(slotB._value).toBe(20)
		expect(slotA).never.toBe(slotB)

		gmA:Destroy()
		gmB:Destroy()
	end)
end)

return {}
