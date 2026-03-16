--!native
--!optimize 2

local GamemodeCore = require("@pkg/GamemodeCore")
local QuickZone = require("@pkg/QuickZone")

local Zone = QuickZone.Zone
local Group = QuickZone.Group
local Observer = QuickZone.Observer

------------------------------------------------------------------------
-- Types

export type TeamInfo = {
	Points: number,
	Capturing: number,
	inZoneCount: number,
	isHolder: boolean,
}

export type Settings = {
	Teams: { Team },
	Parts: { BasePart },

	Increase: number?,
	Rollback: number?,
	PointsNeeded: number?,
	RequireDominanceToIncrease: boolean?,
	ProgressWhileContested: boolean?,
	CaptureWhileDead: boolean?,
	CaptureStacking: boolean?,
	CaptureTime: number?,
	OvertimeThreshold: number?,
	OvertimeIncrease: number?,
	OvertimeRollback: number?,
	OvertimePointsNeeded: number?,
	OvertimeDefenderWinFullDominance: boolean?,
	DefendingTeam: Team?,
}

------------------------------------------------------------------------
-- Tick function — registered once at module load with GamemodeCore

local function terminalTick(self, dt: number)
	local playingTeams = self.PlayingTeams :: { [Team]: TeamInfo }
	local captureTime = self.CaptureTime :: number

	-- ── Overtime threshold ────────────────────────────────────────
	local inOvertime = self.Overtime :: boolean
	if not inOvertime then
		local threshold = self.OvertimeThreshold :: number
		if threshold > 0 and (self.Elapsed :: number) >= threshold then
			for team, info in playingTeams do
				if info.Capturing == captureTime then
					self:Stop(team, nil)
					return
				end
			end
			self.Overtime = true
			inOvertime = true
			self.OvertimeEntered:Fire()
		end
	end

	local increase = (if inOvertime then self.OvertimeIncrease else self.Increase) :: number
	local rollback = (if inOvertime then self.OvertimeRollback else self.Rollback) :: number
	local pointsNeeded = (if inOvertime then self.OvertimePointsNeeded else self.PointsNeeded) :: number

	-- ── Contested ─────────────────────────────────────────────────
	local occupiedCount = 0
	local contested = false
	for _, info in playingTeams do
		if info.inZoneCount > 0 then
			occupiedCount += 1
			if occupiedCount == 2 then
				contested = true
				break
			end
		end
	end

	local oldContested = self.Contested :: boolean
	if contested ~= oldContested then
		self.Contested = contested
		self.ContestedChanged:Fire(contested)
	end

	-- ── Capture progress ──────────────────────────────────────────
	local totalInZone = 0
	for _, info in playingTeams do
		totalInZone += info.inZoneCount
	end

	local nTeams = #self.Teams
	local captureStacking = self.CaptureStacking :: boolean
	local capturingChanged = self.CapturingChanged

	local othersDivisor = if nTeams > 1 then nTeams - 1 else 1

	for team, info in playingTeams do
		local myCount = info.inZoneCount
		local others = (totalInZone - myCount) / othersDivisor

		local delta
		if myCount == 0 then
			delta = -1
		elseif captureStacking then
			delta = myCount - others
		else
			delta = math.sign(myCount - others)
		end

		local old = info.Capturing
		local new = math.clamp(old + dt * delta, 0, captureTime)
		if old ~= new then
			info.Capturing = new
			capturingChanged:Fire(team, new)
		end
	end

	-- ── Holders ────────────────────────────────────────────────────
	local progressWhileContested = self.ProgressWhileContested :: boolean
	if not contested or progressWhileContested then
		local holderAdded = self.HolderAdded
		local holderRemoved = self.HolderRemoved

		for team, info in playingTeams do
			local cap = info.Capturing
			if cap == captureTime then
				if not info.isHolder then
					info.isHolder = true
					table.insert(self.Holders, team)
					holderAdded:Fire(team)
				end
			elseif not progressWhileContested or cap == 0 then
				if info.isHolder then
					info.isHolder = false
					local holders = self.Holders :: { Team }
					for i = #holders, 1, -1 do
						if holders[i] == team then
							table.remove(holders, i)
							break
						end
					end
					holderRemoved:Fire(team)
				end
			end
		end
	end

	-- ── Points ────────────────────────────────────────────────────
	local requireDominance = self.RequireDominanceToIncrease :: boolean
	local pointsChanged = self.PointsChanged

	for team, info in playingTeams do
		local old = info.Points

		if not info.isHolder then
			local new = math.max(old - dt * rollback, 0)
			if old ~= new then
				info.Points = new
				pointsChanged:Fire(team, new)
			end
			continue
		end

		if not requireDominance then
			local new = math.min(old + dt * increase, pointsNeeded)
			if old ~= new then
				info.Points = new
				pointsChanged:Fire(team, new)
			end
			continue
		end

		local dominated = true
		for ot, oi in playingTeams do
			if ot ~= team and oi.Points > 0 then
				dominated = false
				break
			end
		end
		if dominated then
			local new = math.min(old + dt * increase, pointsNeeded)
			if old ~= new then
				info.Points = new
				pointsChanged:Fire(team, new)
			end
		end
	end

	-- ── Win checks ────────────────────────────────────────────────
	if not inOvertime then
		for team, info in playingTeams do
			if info.Points >= pointsNeeded then
				self:Stop(team, nil)
				break
			end
		end
		return
	end

	local overtimeWinner: Team? = nil
	local overtimeTied = false
	for team, info in playingTeams do
		if info.Points >= pointsNeeded then
			if not overtimeWinner then
				overtimeWinner = team
			else
				overtimeTied = true
				break
			end
		end
	end

	if overtimeWinner and not overtimeTied then
		self:Stop(overtimeWinner, nil)
		return
	end

	local defenderWinCond = self.OvertimeDefenderWinFullDominance :: boolean
	if defenderWinCond then
		local defendingTeam = self.DefendingTeam :: Team?
		if defendingTeam then
			local di = playingTeams[defendingTeam]
			if di and di.Capturing == captureTime then
				local allZero = true
				for t, i in playingTeams do
					if t ~= defendingTeam and i.Points > 0 then
						allZero = false
						break
					end
				end
				if allZero then
					self:Stop(defendingTeam, nil)
					return
				end
			end
		end
	end

	if not contested and overtimeTied then
		for team, info in playingTeams do
			if info.Capturing == captureTime then
				self:Stop(team, nil)
				return
			end
		end
	end
end

GamemodeCore.register("Terminal", terminalTick :: any)

------------------------------------------------------------------------
-- QuickZone helpers

local function playerEligible(self, player: Player): boolean
	local team = player.Team
	if not team or not self._teamSet[team] then
		return false
	end
	if self.CaptureWhileDead then
		return true
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function setupZone(self)
	self._qzZones = Zone.fromParts(self.Parts)
	self._qzGroup = Group.players()
	self._qzObs = Observer.new({ priority = 0, groups = { self._qzGroup } })

	for _, zone in self._qzZones :: { QuickZone.Zone } do
		zone:attach(self._qzObs)
	end

	self._qzObs:observePlayer(function(player: Player, _zone)
		local team = player.Team
		local info = team and self.PlayingTeams[team] :: TeamInfo?
		if not info then
			return
		end

		local counted = playerEligible(self, player)
		if counted then
			info.inZoneCount += 1
		end

		local teamConn = player:GetPropertyChangedSignal("Team"):Connect(function()
			if counted then
				counted = false
				info.inZoneCount = math.max(0, info.inZoneCount - 1)
			end
		end)

		local diedConn: RBXScriptConnection? = nil
		if not self.CaptureWhileDead then
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
	end)
end

local function teardownZone(self)
	if self._qzObs then
		self._qzObs:destroy()
		self._qzObs = nil :: any
	end
	if self._qzGroup then
		self._qzGroup:destroy()
		self._qzGroup = nil :: any
	end
	for _, z in self._qzZones or {} :: { any } do
		z:destroy()
	end
	self._qzZones = {}
end

------------------------------------------------------------------------
-- Terminal

local Terminal = {}
Terminal.__index = Terminal

function Terminal.new(name: string, settings: Settings)
	assert(settings.Teams and settings.Teams[1], "Terminal: Teams must have at least 1 entry")
	assert(settings.Parts and settings.Parts[1], "Terminal: Parts must have at least 1 entry")

	local cfg = {
		Teams = settings.Teams,
		Parts = settings.Parts,

		Increase = math.max(0, settings.Increase or 1),
		Rollback = math.max(0, settings.Rollback or 1),
		PointsNeeded = math.max(0, settings.PointsNeeded or 1200),

		RequireDominanceToIncrease = if settings.RequireDominanceToIncrease == nil
			then true
			else settings.RequireDominanceToIncrease,
		ProgressWhileContested = if settings.ProgressWhileContested == nil
			then true
			else settings.ProgressWhileContested,
		CaptureWhileDead = if settings.CaptureWhileDead == nil then false else settings.CaptureWhileDead,
		CaptureStacking = if settings.CaptureStacking == nil then false else settings.CaptureStacking,

		CaptureTime = math.max(0, settings.CaptureTime or 1),
		OvertimeThreshold = settings.OvertimeThreshold or -1,
		OvertimeIncrease = math.max(0, settings.OvertimeIncrease or 1),
		OvertimeRollback = math.max(0, settings.OvertimeRollback or 1),
		OvertimePointsNeeded = math.max(0, settings.OvertimePointsNeeded or 120),

		OvertimeDefenderWinFullDominance = if settings.OvertimeDefenderWinFullDominance == nil
			then true
			else settings.OvertimeDefenderWinFullDominance,
		DefendingTeam = settings.DefendingTeam or settings.Teams[1],
	}

	local gm = GamemodeCore.new("Terminal", name, cfg) :: any

	gm._teamSet = {}
	for _, t in cfg.Teams do
		gm._teamSet[t] = true
	end

	gm.Overtime = false
	gm.Contested = false
	gm.Holders = {} :: { Team }
	gm.PlayingTeams = {} :: { [Team]: TeamInfo }

	gm._qzZones = {}
	gm._qzGroup = nil
	gm._qzObs = nil

	-- Terminal signals (private Signal implementation to avoid a second module dep)
	local Signal = {}
	Signal.__index = Signal
	function Signal.new()
		return setmetatable({ _id = 0, _cns = {} }, Signal)
	end
	function Signal:Connect(fn)
		self._id = (self._id :: number) + 1
		local id = self._id
		self._cns[id] = fn
		local c = { Connected = true }
		c.Disconnect = function()
			c.Connected = false
			self._cns[id] = nil
		end
		return c
	end
	function Signal:Fire(...)
		local snap = table.clone(self._cns)
		for _, fn: any in snap do
			fn(...)
		end
	end
	function Signal:Destroy()
		self._cns = {}
	end

	gm.ContestedChanged = Signal.new()
	gm.OvertimeEntered = Signal.new()
	gm.PointsChanged = Signal.new()
	gm.CapturingChanged = Signal.new()
	gm.HolderAdded = Signal.new()
	gm.HolderRemoved = Signal.new()

	return setmetatable(gm, Terminal)
end

------------------------------------------------------------------------
-- Lifecycle

function Terminal:Start(metadata: any?)
	self.Overtime = false
	self.Contested = false
	self.Holders = {}
	self.PlayingTeams = {}

	local startCap = (self.CaptureTime :: number) / #(self.Teams :: { Team })
	for _, team in self.Teams :: { Team } do
		self.PlayingTeams[team] = {
			Points = 0,
			Capturing = startCap,
			inZoneCount = 0,
			isHolder = false,
		}
		self.PointsChanged:Fire(team, 0)
		self.CapturingChanged:Fire(team, startCap)
	end

	setupZone(self :: any)
	GamemodeCore.Start(self, metadata)
end

function Terminal:Stop(winner: Team?, metadata: any?)
	teardownZone(self)
	GamemodeCore.Stop(self, winner, metadata)

	self.PlayingTeams = {}
	self.Holders = {}
	self.Overtime = false
	self.Contested = false
end

function Terminal:Destroy()
	self.ContestedChanged:Destroy()
	self.OvertimeEntered:Destroy()
	self.PointsChanged:Destroy()
	self.CapturingChanged:Destroy()
	self.HolderAdded:Destroy()
	self.HolderRemoved:Destroy()

	GamemodeCore.Destroy(self)
end

Terminal.Pause = GamemodeCore.Pause
Terminal.Resume = GamemodeCore.Resume

function Terminal:mount(fn)
	return GamemodeCore.mount(self, fn)
end

function Terminal:getState()
	return table.freeze({
		Active = self.Active,
		Paused = self.Paused,
		Overtime = self.Overtime,
		Contested = self.Contested,
		Elapsed = self.Elapsed,
		PlayingTeams = self.PlayingTeams,
		Holders = self.Holders,
		PointsNeeded = self.PointsNeeded,
		CaptureTime = self.CaptureTime,
		Increase = self.Increase,
		Rollback = self.Rollback,
	})
end

return Terminal
