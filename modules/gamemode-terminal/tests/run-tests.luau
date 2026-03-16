local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tests = ReplicatedStorage:QueryDescendants(">#Packages>#GamemodeTerminal>#tests")[1]

local runCLI = require("@dev/Jest").runCLI

local processServiceExists, ProcessService: any = pcall(game.GetService, game, "ProcessService")

local status, result = runCLI(Tests, {
	verbose = true,
	ci = true,
}, { Tests }):awaitStatus()

if status == "Rejected" then
	print(result)
end

if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
	if processServiceExists then
		ProcessService:ExitAsync(0)
	end
end

if processServiceExists then
	ProcessService:ExitAsync(1)
end

return nil
