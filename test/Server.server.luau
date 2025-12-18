--!strict
-- (©) Copyright 2025 Meta Games, LLC. All rights reserved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("knightremotes"))

local value = BrickColor.Yellow()

Remotes:init()
Remotes:new("Test", {
	Reliable = true,
	TwoWay = false,
})

Remotes:Connect("Test", function(sender, ...)
	local d = {}
	for i, v in ipairs({...}) do
		table.insert(d, tostring(v) .. " (" .. typeof(v) .. ")")
	end
	warn("[SERVER RECEIVED]: ", table.concat(d, ", "))
end)

-- Two-way remote: Client -> Server
Remotes:new("ClientToServer", {
	Reliable = true,
	TwoWay = true,
})

Remotes:Connect("ClientToServer", function(sender): string
	print("[SERVER] Received two-way request from", sender.Name)
	return "Hello from server!"
end)

-- Two-way remote: Server -> Client
Remotes:new("ServerToClient", {
	Reliable = true,
	TwoWay = true,
})

repeat
	task.wait(1)
until #game.Players:GetPlayers() > 0
local player = game.Players:GetPlayers()[1]

task.wait(2) -- Give time for client to connect
for i = 1, 3 do
	print("[SERVER] Firing packet", i)
	Remotes:FireAll("Test", value, i)
end

-- Test server->client two-way
print("[SERVER] Client (server->client) responded with:", Remotes:Fire("ServerToClient", player) or "<no response>")
