--!strict
-- (©) Copyright 2025 Meta Games, LLC. All rights reserved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("knightremotes"))

local value = workspace:FindFirstChildWhichIsA("BasePart") :: BasePart

Remotes:init()
Remotes:Connect("Test", function(...)
	local d = {}
	for i, v in ipairs({...}) do
		table.insert(d, tostring(v) .. " (" .. typeof(v) .. ")")
	end
	warn("[CLIENT RECEIVED]: ", table.concat(d, ", "))
end)

-- Connect to server->client two-way remote
Remotes:Connect("ServerToClient", function(): string
	print("[CLIENT] Server is requesting a response via two-way remote")
	return "Hello from client!"
end)

task.wait(3) -- Wait longer for replication
Remotes:Fire("Test", value)

task.wait(1)
print("[CLIENT] Server (client->server) responded with:", Remotes:Fire("ClientToServer") or "<no response>")
