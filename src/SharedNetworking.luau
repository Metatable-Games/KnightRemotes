--!strict
-- (©) Copyright 2025 Meta Games, LLC. All rights reserved.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Packages = ReplicatedStorage:WaitForChild("Packages")

local Class = require(Packages:WaitForChild("class"))
local Sift = require(Packages:WaitForChild("sift"))

local FRAME_TIME_RATE = 1 / 60
local REQUEST_TIMEOUT = 60
local REPLICATION_TIMEOUT = 10 -- Max time to wait for event replication from server

export type EventInfo = {
	Reliable: boolean,
	TwoWay: boolean,
	Callbacks: { [string]: (...any) -> any },
}

export type Connection = {
	Disconnect: () -> (),
}

export type Middleware = (player: Player?, eventName: string, args: { any }) -> (boolean, { any }?)

export type SharedNetworking = {
	Events: { [string]: EventInfo },
	Middleware: { Middleware },
	Disconnect: (self: SharedNetworking, RemoteName: string, ConnectionId: string) -> (),
	Connect: (self: SharedNetworking, RemoteName: string, Callback: (...any) -> any) -> Connection,
	Fire: (self: SharedNetworking, RemoteName: string, ...any) -> ...any,
	FireAll: (self: SharedNetworking, RemoteName: string, ...any) -> (),
	UseMiddleware: (self: SharedNetworking, middleware: Middleware) -> (),
}

local SharedNetworking = Class("SharedNetworking")
SharedNetworking.wasInited = false
SharedNetworking.Events = {}
SharedNetworking.Middleware = {}
SharedNetworking.Buffers = require("./Buffers")
SharedNetworking.Standalone = true
SharedNetworking.silenceDeprecationWarnings = false

-- Helper function to wait for event replication on client (with timeout)
local function waitForEventReplication(self: any, RemoteName: string): EventInfo?
	if not RunService:IsClient() then
		return self.Events[RemoteName]
	end

	local startTime = os.clock()
	while not self.Events[RemoteName] and (os.clock() - startTime) < REPLICATION_TIMEOUT do
		task.wait(0.05) -- Check every 50ms
	end

	return self.Events[RemoteName]
end

--[[
	Sanitizes a remote name by replacing invalid characters.
	Converts ':' to '_' to ensure compatibility with Roblox naming conventions.
	
	@param name - The remote name to sanitize
	@return The sanitized remote name
]]
function SharedNetworking:SanitizeRemoteName(name: string): string
	return name:gsub(":", "_")
end
SharedNetworking.sanitizeRemoteName = SharedNetworking.SanitizeRemoteName

--[[
	Adds middleware to the networking layer.
	Middleware can intercept and modify packets before they're processed.
	
	@param middleware - Function that receives (player, eventName, args) and returns (shouldContinue, modifiedArgs?)
]]
function SharedNetworking:UseMiddleware(middleware: (Player?, string, { any }) -> (boolean, { any }?)): Connection
	assert(type(middleware) == "function", "Middleware must be a function")

	table.insert(self.Middleware, middleware)

	return {
		Disconnect = function()
			for i, m in ipairs(self.Middleware) do
				if m == middleware then
					table.remove(self.Middleware, i)
					return
				end
			end
		end,
	}
end
SharedNetworking.useMiddleware = SharedNetworking.UseMiddleware

--[[
	Disconnects a specific callback from a remote event.
	Removes the callback with the given ConnectionId from the event's callback list.
	Note: For BindableEvents/Functions, the connection is managed by Roblox directly.
	
	@param RemoteName - The name of the remote event
	@param ConnectionId - The unique identifier for the callback connection
]]
function SharedNetworking:Disconnect(RemoteName: string, ConnectionId: string)
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	assert(type(ConnectionId) == "string", "id must be a string.")
	RemoteName = self:SanitizeRemoteName(RemoteName)

	-- Bindables are managed by Roblox Connection objects directly
	if self.Bindables and self.Bindables[RemoteName] then
		warn("[KnightRemotes]: ", "Bindable connections are managed by Roblox. Call :Disconnect() on the Connection object returned from :Connect().")
		return
	end

	assert(self.Events[RemoteName] ~= nil, "RemoteName '" .. RemoteName .. "' is not registered.")

	if self.Events[RemoteName].Callbacks[ConnectionId] == nil then
		warn("[KnightRemotes]: ", "Callback for RemoteName '" .. RemoteName .. "' is already disconnected.")
		return
	end

	self.Events[RemoteName].Callbacks[ConnectionId] = nil
end
SharedNetworking.disconnect = SharedNetworking.Disconnect

--[[
	Checks if a remote event is registered.
	On the client, can optionally yield until the event is replicated from the server.
	Also checks for registered BindableEvents and BindableFunctions.
	
	@param RemoteName - The name of the remote event to check
	@param yield - (Optional) If true and on client, waits for event replication before checking
	@return True if the event is registered, false otherwise
]]
function SharedNetworking:IsRegistered(RemoteName: string, yield: boolean?): boolean
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	if yield == nil then
		yield = false
	end
	RemoteName = self:SanitizeRemoteName(RemoteName)
	
	-- Check if it's a bindable
	if self.Bindables and self.Bindables[RemoteName] then
		return true
	end
	
	if yield and RunService:IsClient() then
		waitForEventReplication(self, RemoteName)
	end
	return self.Events[RemoteName] ~= nil
end
SharedNetworking.isRegistered = SharedNetworking.IsRegistered

--[[
	Connects a callback function to a remote event.
	For BindableEvents/Functions, connects directly to the Roblox instance.
	For network events, registers the callback to receive incoming packets.
	On client, automatically waits for event replication if needed.
	
	@param RemoteName - The name of the remote event to connect to
	@param Callback - The function to call when the event fires
	@return A Connection object with a Disconnect method
]]
function SharedNetworking:Connect(RemoteName: string, Callback: (...any) -> ()?)
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	assert(type(Callback) == "function", "Callback must be a function.")
	RemoteName = self:SanitizeRemoteName(RemoteName)

	-- > Handle bindables
	if self.Bindables and self.Bindables[RemoteName] then
		local instance = self.Bindables[RemoteName]

		if instance:IsA("BindableEvent") then
			return instance.Event:Connect(Callback)
		elseif instance:IsA("BindableFunction") then
			instance.OnInvoke = Callback
		else
			error("Instance bound to " .. RemoteName .. " is not a BindableEvent or BindableFunction.")
		end
	end

	local Event = self.Events[RemoteName]

	-- On the client, wait for event replication if it doesn't exist yet
	if Event == nil and RunService:IsClient() then
		Event = waitForEventReplication(self, RemoteName)

		-- If still nil after timeout, auto-register with defaults
		if Event == nil then
			self.Events[RemoteName] = {
				Reliable = true,
				TwoWay = false,
				Callbacks = {},
			}
			Event = self.Events[RemoteName]
		end
	end

	assert(Event ~= nil, "RemoteName '" .. RemoteName .. "' is not registered.")

	if Event.TwoWay and Sift.Dictionary.count(Event.Callbacks) > 0 then
		warn(
			"[KnightRemotes]: ",
			"RemoteName '" .. RemoteName .. "' already has a callback connected. Overwriting existing callback."
		)
		for key in pairs(Event.Callbacks) do
			Event.Callbacks[key] = nil
		end
	end

	local id = HttpService:GenerateGUID(false)
	Event.Callbacks[id] = Callback

	if RunService:IsClient() then
		self.Requests[RemoteName] = self.Requests[RemoteName] or {}
		self.RequestIdCounters[RemoteName] = 0
	end

	return {
		Disconnect = function()
			return self:Disconnect(RemoteName, id)
		end,
	}
end
SharedNetworking.connect = SharedNetworking.Connect

--[[
	Fires a remote event to send data across the network.
	
	Server usage: Fire(RemoteName, Player, ...args)
	  - First argument must be the target Player
	  - Remaining arguments are sent to the client
	
	Client usage: Fire(RemoteName, ...args)
	  - All arguments are sent to the server
	
	For TwoWay events, this method yields until a response is received.
	For BindableEvents, fires the event. For BindableFunctions, invokes and returns the result.
	Automatically handles reliable/unreliable transmission and request/response flow.
	
	@param RemoteName - The name of the remote event to fire
	@param ... - Arguments to send (on server, first arg must be Player for network events)
	@return For TwoWay events, returns the response values from the remote callback
]]
function SharedNetworking:Fire(RemoteName: string, ...)
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	RemoteName = self:SanitizeRemoteName(RemoteName)

	-- Handle bindables
	if self.Bindables and self.Bindables[RemoteName] then
		local instance = self.Bindables[RemoteName]
		
		if instance:IsA("BindableEvent") then
			instance:Fire(...)
			return
		elseif instance:IsA("BindableFunction") then
			return instance:Invoke(...)
		else
			error("Instance bound to " .. RemoteName .. " is not a BindableEvent or BindableFunction.")
		end
	end

	local args = { ... }
	local Event = self.Events[RemoteName]

	-- On the client, wait for event replication if it doesn't exist yet
	if Event == nil and RunService:IsClient() then
		Event = waitForEventReplication(self, RemoteName)

		-- If still nil after timeout, auto-register with defaults
		if Event == nil then
			self.Events[RemoteName] = {
				Reliable = true,
				TwoWay = false,
				Callbacks = {},
			}
			Event = self.Events[RemoteName]
		end
	end

	assert(
		Event ~= nil,
		"RemoteName '" .. RemoteName .. "' is not registered. On the server, you must call :new() first."
	)

	-- TwoWay works for both client->server and server->client requests
	local packetType = Event.TwoWay and self.PacketTypes.PACKET_REQUEST or self.PacketTypes.PACKET_EVENT

	-- Initialize request tracking for two-way remotes if not already done
	if Event.TwoWay then
		self.Requests[RemoteName] = self.Requests[RemoteName] or {}
		self.RequestIdCounters[RemoteName] = self.RequestIdCounters[RemoteName] or 0
	end

	if RunService:IsServer() then
		local targetPlayer = args[1] :: Player?
		assert(
			targetPlayer ~= nil and typeof(targetPlayer) == "Instance" and targetPlayer:IsA("Player"),
			"First argument must be a Player instance when firing from the server."
		)
		table.remove(args, 1)

		if packetType == self.PacketTypes.PACKET_REQUEST then
			-- Server->Client two-way request
			local reqId = self.RequestIdCounters[RemoteName]
			self.RequestIdCounters[RemoteName] += 1

			self:_sendPacket(RemoteName, Event.Reliable, targetPlayer, packetType, reqId, table.unpack(args))
			self:_flushImmediate(Event.Reliable, targetPlayer)

			local thread = coroutine.running()
			local timer = task.delay(REQUEST_TIMEOUT, function()
				if self.Requests[RemoteName] and self.Requests[RemoteName][reqId] then
					self.Requests[RemoteName][reqId] = nil
					task.spawn(thread, false, "Request timed out after " .. REQUEST_TIMEOUT .. " seconds.")
				end
			end)

			self.Requests[RemoteName][reqId] = {
				thread = thread,
				timer = timer,
				player = targetPlayer,
			}

			local results = { coroutine.yield() }
			local success = results[1]

			if not success then
				error(results[2], 0)
			end

			return table.unpack(results, 2)
		else
			self:_sendPacket(RemoteName, Event.Reliable, targetPlayer, packetType, table.unpack(args))
			self:_flushImmediate(Event.Reliable, targetPlayer)
		end
	else
		if packetType == self.PacketTypes.PACKET_REQUEST then
			local reqId = self.RequestIdCounters[RemoteName]
			self.RequestIdCounters[RemoteName] += 1

			self:_sendPacket(RemoteName, Event.Reliable, packetType, reqId, table.unpack(args))

			local thread = coroutine.running()
			local timer = task.delay(REQUEST_TIMEOUT, function()
				if self.Requests[RemoteName] and self.Requests[RemoteName][reqId] then
					self.Requests[RemoteName][reqId] = nil
					task.spawn(thread, false, "Request timed out after " .. REQUEST_TIMEOUT .. " seconds.")
				end
			end)

			self.Requests[RemoteName][reqId] = {
				thread = thread,
				timer = timer,
			}

			local results = { coroutine.yield() }
			local success = results[1]

			if not success then
				error(results[2], 0)
			end

			return table.unpack(results, 2)
		else
			self:_sendPacket(RemoteName, Event.Reliable, packetType, table.unpack(args))
			self:_flushImmediate(Event.Reliable, nil)
		end
	end
end
SharedNetworking.fire = SharedNetworking.Fire

--[[
	Fires a remote event to all connected players.
	Can only be called from the server. Does not support TwoWay events or Bindables.
	
	@param RemoteName - The name of the remote event to fire
	@param ... - Arguments to send to all clients
]]
function SharedNetworking:FireAll(RemoteName: string, ...)
	assert(RunService:IsServer(), "FireAll can only be called from the server.")
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	RemoteName = self:SanitizeRemoteName(RemoteName)

	-- Bindables don't support FireAll (they're local only)
	if self.Bindables and self.Bindables[RemoteName] then
		warn("[KnightRemotes]: ", "FireAll is not supported for BindableEvents/Functions. Use :Fire() instead.")
		return
	end

	if not self.Events[RemoteName] then
		warn("[KnightRemotes]: ", "RemoteName '" .. RemoteName .. "' is not registered.")
		return
	end

	if self.Events[RemoteName].TwoWay then
		warn(
			"[KnightRemotes]: ",
			"RemoteName '" .. RemoteName .. "' is registered as TwoWay. FireAll does not support TwoWay remotes."
		)
		return
	end

	for _, player in pairs(Players:GetPlayers()) do
		self:Fire(RemoteName, player, ...)
	end
end
SharedNetworking.fireAll = SharedNetworking.FireAll

-- Aliases --
SharedNetworking.FireAllClients = SharedNetworking.FireAll
SharedNetworking.FireClient = SharedNetworking.Fire
SharedNetworking.FireServer = SharedNetworking.Fire

SharedNetworking.fireAllClients = SharedNetworking.FireAll
SharedNetworking.fireClient = SharedNetworking.Fire
SharedNetworking.fireServer = SharedNetworking.Fire

SharedNetworking.InvokeClient = SharedNetworking.Fire
SharedNetworking.InvokeServer = SharedNetworking.Fire
SharedNetworking.Invoke = SharedNetworking.Fire

SharedNetworking.invokeClient = SharedNetworking.Fire
SharedNetworking.invokeServer = SharedNetworking.Fire
SharedNetworking.invoke = SharedNetworking.Fire

-- Internal --
SharedNetworking.PacketTypes = {
	PACKET_EVENT = 1,
	PACKET_REQUEST = 2,
	PACKET_RESPONSE = 3,
}

function SharedNetworking:_Writer(reliable: boolean, player: Player?)
	if RunService:IsServer() then
		if player then
			local map = if reliable then self.ReliableMap else self.UnreliableMap
			local writer = map[player]

			if not writer then
				writer = self.Buffers.CreateWriter()
				map[player] = writer
			end

			return writer
		else
			if reliable then
				if not self.BroadcastReliable then
					self.BroadcastReliable = self.Buffers.CreateWriter()
				end

				return self.BroadcastReliable
			else
				if not self.BroadcastUnreliable then
					self.BroadcastUnreliable = self.Buffers.CreateWriter()
				end

				return self.BroadcastUnreliable
			end
		end
	else
		local map = if reliable then self.ReliableMap else self.UnreliableMap
		local writer = map["_server"]

		if not writer then
			writer = self.Buffers.CreateWriter()
			map["_server"] = writer
		end

		return writer
	end
end

function SharedNetworking:init()
	if self.wasInited then
		return
	end

	self.wasInited = true

	self._Reliable = RunService:IsServer() and Instance.new("RemoteEvent") or script.Parent:WaitForChild("RemoteEvent")
	self._Unreliable = RunService:IsServer() and Instance.new("UnreliableRemoteEvent")
		or script.Parent:WaitForChild("UnreliableRemoteEvent")
	self._Replication = RunService:IsServer() and Instance.new("RemoteEvent")
		or script.Parent:WaitForChild("Replication")

	self._Reliable.Parent = script.Parent
	self._Unreliable.Parent = script.Parent
	self._Replication.Parent = script.Parent
	self._Replication.Name = "Replication"

	self.ReliableMap = {}
	self.UnreliableMap = {}

	self.BroadcastReliable = nil
	self.BroadcastUnreliable = nil

	local accumulator = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulator += deltaTime

		if accumulator < FRAME_TIME_RATE then
			return
		end

		local flushed = false
		while accumulator >= FRAME_TIME_RATE do
			accumulator -= FRAME_TIME_RATE
			flushed = true
		end

		if flushed then
			self:_flush()
		end
	end)

	if RunService:IsServer() then
		-- Function to replicate all events to a specific player
		local function replicateEventsToPlayer(player: Player)
			for eventName, eventInfo in pairs(self.Events) do
				self._Replication:FireClient(player, 1, eventName, {
					Reliable = eventInfo.Reliable,
					TwoWay = eventInfo.TwoWay,
				})
			end
		end

		-- When a player joins, send them all existing events
		Players.PlayerAdded:Connect(function(player: Player)
			replicateEventsToPlayer(player)
		end)

		-- Replicate to any players already in the game
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(replicateEventsToPlayer, player)
		end

		Players.PlayerRemoving:Connect(function(player: Player)
			local reliable = self.ReliableMap[player]
			local unreliable = self.UnreliableMap[player]

			if reliable then
				self.Buffers.FreeWriter(reliable)
				self.ReliableMap[player] = nil
			end

			if unreliable then
				self.Buffers.FreeWriter(unreliable)
				self.UnreliableMap[player] = nil
			end

			-- Clean up any pending requests for this player
			for eventName, requests in pairs(self.Requests or {}) do
				for reqId, channel in pairs(requests) do
					if channel.player == player then
						task.cancel(channel.timer)
						requests[reqId] = nil
					end
				end
			end
		end)

		-- Initialize request tracking for server->client two-way requests
		self.Requests = {} :: { [string]: { [number]: { thread: thread, timer: thread, player: Player? } } }
		self.RequestIdCounters = {} :: { [string]: number }

		self._Reliable.OnServerEvent:Connect(function(...)
			return self:_handleEvent(...)
		end)

		self._Unreliable.OnServerEvent:Connect(function(...)
			return self:_handleEvent(...)
		end)
	else
		self.Requests = {} :: { [string]: { [number]: { thread: thread, timer: thread } } }
		self.RequestIdCounters = {} :: { [string]: number }

		-- Handle event replication from server
		self._Replication.OnClientEvent:Connect(
			function(action: number, eventName: string, eventInfo: { Reliable: boolean, TwoWay: boolean }?)
				if action == 1 and eventInfo then
					-- Only create if it doesn't exist or update if it does
					if not self.Events[eventName] then
						self.Events[eventName] = {
							Reliable = eventInfo.Reliable,
							TwoWay = eventInfo.TwoWay,
							Callbacks = {},
						}
					else
						-- Update existing event properties from server
						self.Events[eventName].Reliable = eventInfo.Reliable
						self.Events[eventName].TwoWay = eventInfo.TwoWay
					end
				elseif action == 2 then
					-- Remove event (clear callbacks first)
					if self.Events[eventName] then
						for key in pairs(self.Events[eventName].Callbacks) do
							self.Events[eventName].Callbacks[key] = nil
						end
						self.Events[eventName] = nil
					end
				end
			end
		)

		self._Reliable.OnClientEvent:Connect(function(...)
			return self:_handleEvent(...)
		end)

		self._Unreliable.OnClientEvent:Connect(function(...)
			return self:_handleEvent(...)
		end)
	end
end

return SharedNetworking :: SharedNetworking & typeof(SharedNetworking)
