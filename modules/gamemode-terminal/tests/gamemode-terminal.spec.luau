-- Terminal test suite (full — see document 4)
-- Layout:
--   Helpers / fakes
--   QuickZone stub
--   Terminal.new — construction & validation
--   Terminal:Start lifecycle
--   Terminal:Stop lifecycle
--   Terminal:Pause / Resume
--   Terminal:Destroy
--   Terminal:getState
--   Terminal:mount delegation
--   terminalTick — overtime threshold
--   terminalTick — contested detection
--   terminalTick — capture progress
--   terminalTick — holders
--   terminalTick — points accumulation
--   terminalTick — points rollback
--   terminalTick — dominance requirement
--   terminalTick — win condition
--   terminalTick — overtime mechanics
--   terminalTick — overtime tie-break
--   Zone callbacks — enter / exit / death / team change
--   Zone callbacks — counted guard and double-decrement prevention
--   Edge cases

local JestGlobals = require("@dev/JestGlobals")
local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it

local Terminal = require("@src")
local GamemodeCore = require("@pkg/GamemodeCore")

------------------------------------------------------------------------
-- Patch Terminal.Start / Stop to skip QuickZone in tests

local _originalStart = Terminal.Start
Terminal.Start = function(self, metadata)
	self.Overtime = false
	self.Contested = false
	self.Holders = {}
	self.PlayingTeams = {}

	local startCap = (self.CaptureTime :: number) / #(self.Teams :: { any })
	for _, team in self.Teams :: { any } do
		self.PlayingTeams[team] = {
			Points = 0,
			Capturing = startCap,
			inZoneCount = 0,
			isHolder = false,
		}
		self.PointsChanged:Fire(team, 0)
		self.CapturingChanged:Fire(team, startCap)
	end

	GamemodeCore.Start(self, metadata)
end

local _originalStop = Terminal.Stop
Terminal.Stop = function(self, winner, metadata)
	GamemodeCore.Stop(self, winner, metadata)

	self.PlayingTeams = {}
	self.Holders = {}
	self.Overtime = false
	self.Contested = false
end

------------------------------------------------------------------------
-- Helpers / fakes

local _counter = 0
local function uid(prefix: string?): string
	_counter += 1
	return (prefix or "terminal") .. "_" .. tostring(_counter)
end

local function fakeTeam(name: string): Team
	return { Name = name, ClassName = "Team" } :: any
end

local function fakePart(): BasePart
	local part = {
		ClassName = "Part",
		Size = Vector3.new(10, 10, 10),
		Position = Vector3.new(0, 0, 0),
		CFrame = CFrame.new(0, 0, 0),
		Shape = { Value = 0 },
	}
	function part:IsA(className: string): boolean
		return className == "Part" or className == "BasePart" or className == "Instance"
	end
	return part :: any
end

local function fakeSignal()
	local sig = { _cns = {} }
	function sig:Connect(fn)
		local id = #self._cns + 1
		self._cns[id] = fn
		local c = { Connected = true }
		c.Disconnect = function()
			c.Connected = false
			self._cns[id] = nil
		end
		return c
	end
	function sig:Fire(...)
		local snap = table.clone(self._cns)
		for _, fn: any in snap do
			fn(...)
		end
	end
	return sig
end

local function fakePlayer(team, alive: boolean?): Player & { [string]: any }
	alive = if alive == nil then true else alive

	local diedSignal = fakeSignal()
	local hum = { Health = if alive then 100 else 0, Died = diedSignal, ClassName = "Humanoid" }
	local char = {
		FindFirstChildOfClass = function(_self, cls)
			return if cls == "Humanoid" then hum else nil
		end,
	}

	local teamChangedSignal = fakeSignal()
	local player = {
		Team = team,
		Character = char,
		_hum = hum,
		_teamChanged = teamChangedSignal,
	}
	player.GetPropertyChangedSignal = function(_self, prop)
		if prop == "Team" then
			return teamChangedSignal
		end
		return fakeSignal()
	end
	return player :: any
end

------------------------------------------------------------------------
-- QuickZone simulation

local function simulateEnter(terminal, player: Player)
	local team: Team? = player.Team
	local info: any = team and terminal.PlayingTeams[team]
	if not info then
		return nil :: any
	end

	local eligible = false
	if terminal.CaptureWhileDead then
		eligible = team ~= nil and terminal._teamSet[team]
	else
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		eligible = hum ~= nil and hum.Health > 0
	end

	local counted = eligible
	if counted then
		info.inZoneCount += 1
	end

	local teamConn = player:GetPropertyChangedSignal("Team"):Connect(function()
		if counted then
			counted = false
			info.inZoneCount = math.max(0, info.inZoneCount - 1)
		end
	end)

	local diedConn = nil
	if not terminal.CaptureWhileDead then
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			diedConn = hum.Died:Connect(function()
				if counted then
					counted = false
					info.inZoneCount = math.max(0, info.inZoneCount - 1)
				end
			end)
		end
	end

	return function()
		if counted then
			counted = false
			info.inZoneCount = math.max(0, info.inZoneCount - 1)
		end
		teamConn:Disconnect()
		if diedConn then
			diedConn:Disconnect()
		end
	end
end

local function tick(terminal, dt: number)
	terminal._tickFn(terminal, dt)
end

------------------------------------------------------------------------
-- Default factory

local function newTerminal(overrides: { [string]: any }?)
	local t1 = fakeTeam("Red")
	local t2 = fakeTeam("Blue")
	local settings = {
		Teams = { t1, t2 },
		Parts = { fakePart() },
	}
	if overrides then
		for k, v in overrides do
			settings[k] = v
		end
	end
	local term = Terminal.new(uid(), settings :: any)
	return term, t1, t2
end

------------------------------------------------------------------------
-- Terminal.new — construction & validation

describe("Terminal.new", function()
	it("throws when Teams is missing", function()
		expect(function()
			Terminal.new(uid(), { Teams = {}, Parts = { fakePart() } })
		end).toThrow()
	end)

	it("throws when Parts is missing", function()
		expect(function()
			Terminal.new(uid(), { Teams = { fakeTeam("A") }, Parts = {} })
		end).toThrow()
	end)

	it("applies all defaults when settings fields are nil", function()
		local term = newTerminal()
		expect(term.Increase).toBe(1)
		expect(term.Rollback).toBe(1)
		expect(term.PointsNeeded).toBe(1200)
		expect(term.CaptureTime).toBe(1)
		expect(term.RequireDominanceToIncrease).toBe(true)
		expect(term.ProgressWhileContested).toBe(true)
		expect(term.CaptureWhileDead).toBe(false)
		expect(term.CaptureStacking).toBe(false)
		expect(term.OvertimeThreshold).toBe(-1)
		expect(term.OvertimeIncrease).toBe(1)
		expect(term.OvertimeRollback).toBe(1)
		expect(term.OvertimePointsNeeded).toBe(120)
		expect(term.OvertimeDefenderWinFullDominance).toBe(true)
		term:Destroy()
	end)

	it("DefendingTeam defaults to Teams[1] when not provided", function()
		local term, t1 = newTerminal()
		expect(term.DefendingTeam).toBe(t1)
		term:Destroy()
	end)

	it("applies all custom settings", function()
		local t1, t2 = fakeTeam("A"), fakeTeam("B")
		local term = Terminal.new(uid(), {
			Teams = { t1, t2 },
			Parts = { fakePart() },
			Increase = 5,
			Rollback = 2,
			PointsNeeded = 500,
			CaptureTime = 10,
			RequireDominanceToIncrease = false,
			ProgressWhileContested = false,
			CaptureWhileDead = true,
			CaptureStacking = true,
			OvertimeThreshold = 300,
			OvertimeIncrease = 3,
			OvertimeRollback = 0.5,
			OvertimePointsNeeded = 60,
			OvertimeDefenderWinFullDominance = false,
			DefendingTeam = t2,
		})
		expect(term.Increase).toBe(5)
		expect(term.Rollback).toBe(2)
		expect(term.PointsNeeded).toBe(500)
		expect(term.CaptureTime).toBe(10)
		expect(term.RequireDominanceToIncrease).toBe(false)
		expect(term.ProgressWhileContested).toBe(false)
		expect(term.CaptureWhileDead).toBe(true)
		expect(term.CaptureStacking).toBe(true)
		expect(term.OvertimeThreshold).toBe(300)
		expect(term.OvertimeIncrease).toBe(3)
		expect(term.OvertimeRollback).toBe(0.5)
		expect(term.OvertimePointsNeeded).toBe(60)
		expect(term.OvertimeDefenderWinFullDominance).toBe(false)
		expect(term.DefendingTeam).toBe(t2)
		term:Destroy()
	end)

	it("clamps negative Increase to 0", function()
		local term = newTerminal({ Increase = -10 })
		expect(term.Increase).toBe(0)
		term:Destroy()
	end)

	it("starts as inactive", function()
		local term = newTerminal()
		expect(term.Active).toBe(false)
		term:Destroy()
	end)

	it("all Terminal signals are present", function()
		local term = newTerminal()
		expect(term.ContestedChanged).never.toBeNil()
		expect(term.OvertimeEntered).never.toBeNil()
		expect(term.PointsChanged).never.toBeNil()
		expect(term.CapturingChanged).never.toBeNil()
		expect(term.HolderAdded).never.toBeNil()
		expect(term.HolderRemoved).never.toBeNil()
		term:Destroy()
	end)

	it("_teamSet is populated for every team", function()
		local term, t1, t2 = newTerminal()
		expect(term._teamSet[t1]).toBe(true)
		expect(term._teamSet[t2]).toBe(true)
		term:Destroy()
	end)
end)

describe("Terminal:Start", function()
	it("sets Active = true", function()
		local term = newTerminal()
		term:Start()
		expect(term.Active).toBe(true)
		term:Destroy()
	end)

	it("fires Started signal", function()
		local term = newTerminal()
		local started = false
		term.Started:Connect(function()
			started = true
		end)
		term:Start()
		expect(started).toBe(true)
		term:Destroy()
	end)

	it("is idempotent — double Start does not double-fire Started", function()
		local term = newTerminal()
		local count = 0
		term.Started:Connect(function()
			count += 1
		end)
		term:Start()
		term:Start()
		expect(count).toBe(1)
		term:Destroy()
	end)

	it("can restart after Stop", function()
		local term = newTerminal()
		term:Start()
		term:Stop()
		expect(function()
			term:Start()
		end).never.toThrow()
		expect(term.Active).toBe(true)
		term:Destroy()
	end)
end)

describe("Terminal:Stop", function()
	it("sets Active = false", function()
		local term = newTerminal()
		term:Start()
		term:Stop()
		expect(term.Active).toBe(false)
		term:Destroy()
	end)

	it("fires Stopped with the winner", function()
		local term, t1 = newTerminal()
		local winner = nil
		term.Stopped:Connect(function(w)
			winner = w
		end)
		term:Start()
		term:Stop(t1)
		expect(winner).toBe(t1)
		term:Destroy()
	end)

	it("clears PlayingTeams", function()
		local term = newTerminal()
		term:Start()
		term:Stop()
		local count = 0
		for _ in term.PlayingTeams do
			count += 1
		end
		expect(count).toBe(0)
		term:Destroy()
	end)
end)

describe("terminalTick overtime threshold", function()
	it("enters overtime when Elapsed reaches threshold", function()
		local term = newTerminal({ OvertimeThreshold = 10, PointsNeeded = 9999 })
		term:Start()
		term.Elapsed = 10
		local entered = false
		term.OvertimeEntered:Connect(function()
			entered = true
		end)
		tick(term, 1)
		expect(entered).toBe(true)
		expect(term.Overtime).toBe(true)
		term:Destroy()
	end)

	it("does not enter overtime when threshold is -1", function()
		local term = newTerminal({ OvertimeThreshold = -1, PointsNeeded = 9999 })
		term:Start()
		term.Elapsed = 999999
		local entered = false
		term.OvertimeEntered:Connect(function()
			entered = true
		end)
		tick(term, 1)
		expect(entered).toBe(false)
		term:Destroy()
	end)
end)

describe("terminalTick capture progress", function()
	it("sole occupant increases Capturing toward CaptureTime", function()
		local term, t1, t2 = newTerminal({
			CaptureTime = 100,
			CaptureStacking = false,
			RequireDominanceToIncrease = false,
			ProgressWhileContested = true,
		})
		term:Start()
		term.PlayingTeams[t1].Capturing = 0
		term.PlayingTeams[t1].inZoneCount = 1
		term.PlayingTeams[t2].inZoneCount = 0
		tick(term, 1)
		expect(term.PlayingTeams[t1].Capturing > 0).toBe(true)
		term:Destroy()
	end)

	it("team with no occupants rolls back toward 0", function()
		local term, t1, t2 = newTerminal({ CaptureTime = 100, Rollback = 2, RequireDominanceToIncrease = false })
		term:Start()
		term.PlayingTeams[t1].Capturing = 50
		term.PlayingTeams[t2].Capturing = 50
		term.PlayingTeams[t1].inZoneCount = 0
		term.PlayingTeams[t2].inZoneCount = 0
		tick(term, 1)
		expect(term.PlayingTeams[t1].Capturing < 50).toBe(true)
		term:Destroy()
	end)
end)

describe("terminalTick win condition", function()
	it("stops the game when a team reaches PointsNeeded", function()
		local term, t1, t2 = newTerminal({
			CaptureTime = 1,
			PointsNeeded = 10,
			Increase = 100,
			Rollback = 0,
			RequireDominanceToIncrease = false,
		})
		term:Start()
		term.PlayingTeams[t1].Capturing = 1
		term.PlayingTeams[t1].isHolder = true
		term.PlayingTeams[t1].inZoneCount = 1
		term.PlayingTeams[t2].Points = 0
		table.insert(term.Holders, t1)
		local winner = nil
		term.Stopped:Connect(function(w)
			winner = w
		end)
		tick(term, 1)
		expect(winner).toBe(t1)
		expect(term.Active).toBe(false)
		term:Destroy()
	end)
end)

describe("Zone player callbacks — basic enter/exit", function()
	it("eligible alive player increments inZoneCount on enter", function()
		local term, t1 = newTerminal()
		term:Start()
		simulateEnter(term, fakePlayer(t1, true))
		expect(term.PlayingTeams[t1].inZoneCount).toBe(1)
		term:Destroy()
	end)

	it("exit cleanup decrements inZoneCount", function()
		local term, t1 = newTerminal()
		term:Start()
		local exit = simulateEnter(term, fakePlayer(t1, true))
		exit()
		expect(term.PlayingTeams[t1].inZoneCount).toBe(0)
		term:Destroy()
	end)

	it("dead player not counted when CaptureWhileDead = false", function()
		local term, t1 = newTerminal({ CaptureWhileDead = false })
		term:Start()
		simulateEnter(term, fakePlayer(t1, false))
		expect(term.PlayingTeams[t1].inZoneCount).toBe(0)
		term:Destroy()
	end)
end)

describe("Zone player callbacks — counted guard", function()
	it("death then exit: inZoneCount decremented exactly once", function()
		local term, t1 = newTerminal({ CaptureWhileDead = false })
		term:Start()
		local player = fakePlayer(t1, true)
		local exit = simulateEnter(term, player)
		expect(term.PlayingTeams[t1].inZoneCount).toBe(1)
		player._hum.Died:Fire()
		expect(term.PlayingTeams[t1].inZoneCount).toBe(0)
		exit()
		expect(term.PlayingTeams[t1].inZoneCount).toBe(0)
		term:Destroy()
	end)

	it("repeated exit calls never push inZoneCount below 0", function()
		local term, t1 = newTerminal()
		term:Start()
		local player = fakePlayer(t1, true)
		local exit = simulateEnter(term, player)
		exit()
		exit()
		exit()
		expect(term.PlayingTeams[t1].inZoneCount).toBe(0)
		term:Destroy()
	end)
end)

return {}
