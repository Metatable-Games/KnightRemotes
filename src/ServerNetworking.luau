--!strict
-- (©) Copyright 2025 Meta Games, LLC. All rights reserved.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Class = require(Packages:WaitForChild("class"))
local Sift = require(Packages:WaitForChild("sift"))
local SharedNetworkingModule = require("./SharedNetworking")

export type EventInfo = {
	Reliable: boolean,
	TwoWay: boolean,
	Callbacks: { [string]: (...any) -> any },
}

export type Connection = {
	Disconnect: () -> (),
}

export type Middleware = (player: Player?, eventName: string, args: { any }) -> (boolean, { any }?)

export type ServerEventConfig = {
	Reliable: boolean?,
	TwoWay: boolean?,
}

export type ServerNetworking = {
	Events: { [string]: EventInfo },
	Middleware: { Middleware },
	new: (
		self: ServerNetworking,
		RemoteName: string,
		Reliable: boolean | ServerEventConfig | nil,
		TwoWay: boolean?,
		callback: ((...any) -> ())?
	) -> (),
	Destroy: (self: ServerNetworking, RemoteName: string) -> (),
	Register: (self: ServerNetworking, Name: string, Type: string, Callback: ((...any) -> ())?) -> any,
	Disconnect: (self: ServerNetworking, RemoteName: string, ConnectionId: string) -> (),
	Connect: (self: ServerNetworking, RemoteName: string, Callback: (...any) -> any) -> Connection,
	Fire: (self: ServerNetworking, RemoteName: string, ...any) -> ...any,
	FireAll: (self: ServerNetworking, RemoteName: string, ...any) -> (),
	UseMiddleware: (self: ServerNetworking, middleware: Middleware) -> (),
	_sendPacket: (
		self: ServerNetworking,
		id: string,
		Reliable: boolean,
		Player: Player?,
		packetType: number,
		...any
	) -> (),
	_dispatch: (self: ServerNetworking, player: Player, id: string, args: { any }, argCount: number) -> (),
	_handleEvent: (self: ServerNetworking, player: Player, buffer: buffer, instance: { Instance }) -> (),
	_flush: (self: ServerNetworking) -> (),
}

local ServerNetworking = Class("ServerNetworking"):Extend(SharedNetworkingModule)

--[[
	Registers a new remote event on the server.
	Automatically replicates event creation to all connected clients.
	
	@param RemoteName - Unique name for the remote event
	@param Reliable - Whether to use reliable transmission (default: true). Can also pass a ServerEventConfig table
	@param TwoWay - Whether this is a request/response event (default: false). TwoWay events must be reliable
	@param callback - Optional callback function to connect immediately
	@return Connection object if callback provided, otherwise nil
]]
function ServerNetworking:New(
	RemoteName: string,
	Reliable: boolean | ServerEventConfig | nil,
	TwoWay: boolean?,
	callback: ((...any) -> ())?
)
	RemoteName = self:SanitizeRemoteName(RemoteName)
	if typeof(Reliable) == "table" then
		-- > Support passing in a table of options
		local Config = Reliable :: any
		TwoWay = Config.TwoWay or nil
		Reliable = Config.Reliable or nil
	end

	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	assert(type(Reliable) == "boolean" or Reliable == nil, "Reliable must be a boolean or nil.")
	assert(type(TwoWay) == "boolean" or TwoWay == nil, "TwoWay must be a boolean or nil.")

	assert(self.Events[RemoteName] == nil, "RemoteName '" .. RemoteName .. "' is already registered.")

	-- Default to reliable remotes
	if Reliable == nil then
		Reliable = true
	end

	-- Default to one-way remotes
	if TwoWay == nil then
		TwoWay = false
	end

	-- Two-way remotes must be reliable
	if TwoWay then
		assert(Reliable, "Two-way remotes must be reliable!")
	end

	self.Events[RemoteName] = {
		Reliable = Reliable,
		TwoWay = TwoWay,
		Callbacks = {},
	}

	-- Initialize request tracking for two-way remotes
	if TwoWay then
		self.Requests[RemoteName] = self.Requests[RemoteName] or {}
		self.RequestIdCounters[RemoteName] = 0
	end

	-- Replicate event creation to all clients
	if self._Replication then
		self._Replication:FireAllClients(1, RemoteName, {
			Reliable = Reliable,
			TwoWay = TwoWay,
		})
	end

	-- Auto-connect callback if provided
	if callback then
		return self:Connect(RemoteName, callback)
	end
end

ServerNetworking.new = ServerNetworking.New

-- :new() Wrappers --
--[[
	Convenience method to register a reliable, one-way remote event.
	
	@param RemoteName - Unique name for the remote event
	@param callback - Optional callback function to connect immediately
	@return Connection object if callback provided, otherwise nil
]]
function ServerNetworking:Reliable(RemoteName: string, callback: ((...any) -> ())?)
	return self:new(RemoteName, true, false, callback)
end
ServerNetworking.reliable = ServerNetworking.Reliable

--[[
	Convenience method to register a reliable, two-way (request/response) remote event.
	
	@param RemoteName - Unique name for the remote event
	@param callback - Optional callback function to connect immediately
	@return Connection object if callback provided, otherwise nil
]]
function ServerNetworking:TwoWay(RemoteName: string, callback: ((...any) -> ())?)
	return self:new(RemoteName, true, true, callback)
end
ServerNetworking.twoWay = ServerNetworking.TwoWay

--[[
	Convenience method to register an unreliable, one-way remote event.
	Unreliable events have lower latency but may be dropped under poor network conditions.
	
	@param RemoteName - Unique name for the remote event
	@param callback - Optional callback function to connect immediately
	@return Connection object if callback provided, otherwise nil
]]
function ServerNetworking:Unreliable(RemoteName: string, callback: ((...any) -> ())?)
	return self:new(RemoteName, false, false, callback)
end
ServerNetworking.unreliable = ServerNetworking.Unreliable

--[[
	Destroys a remote event and replicates to clients.
	Clears all callbacks and removes the event from the Events table.
	For BindableEvents/Functions, destroys the Roblox instance.
	
	@param RemoteName - The name of the remote to destroy
]]
function ServerNetworking:Destroy(RemoteName: string)
	assert(type(RemoteName) == "string", "RemoteName must be a string.")
	RemoteName = self:SanitizeRemoteName(RemoteName)

	-- Handle bindables
	if self.Bindables and self.Bindables[RemoteName] then
		local instance = self.Bindables[RemoteName]
		self.Bindables[RemoteName] = nil
		instance:Destroy()
		return
	end

	if self.Events[RemoteName] == nil then
		warn("[KnightRemotes]: ", "RemoteName '" .. RemoteName .. "' does not exist.")
		return
	end

	-- Clear all callbacks
	for key in pairs(self.Events[RemoteName].Callbacks) do
		self.Events[RemoteName].Callbacks[key] = nil
	end

	-- Remove event
	self.Events[RemoteName] = nil

	-- Replicate destruction to all clients
	if self._Replication then
		self._Replication:FireAllClients(2, RemoteName)
	end
end
ServerNetworking.destroy = ServerNetworking.Destroy

--[[
	Deprecated backward compatibility method for registering events.
	Supports legacy event types including BindableEvent and BindableFunction.
	
	@deprecated Use :new(), :Reliable(), :TwoWay(), or :Unreliable() instead
	@param RemoteName - Unique name for the event
	@param Type - Event type: "RemoteEvent", "UnreliableRemoteEvent", "RemoteFunction", "BindableEvent", "BindableFunction"
	@param Callback - Optional callback function to connect immediately
	@return Connection object if callback provided, otherwise nil
]]
function ServerNetworking:Register(RemoteName: string, Type: string, Callback: (...any) -> ()?)
	RemoteName = self:SanitizeRemoteName(RemoteName)

	if not self.silenceDeprecationWarnings then
		warn("[KnightRemotes]: ", "ServerNetworking:Register(Name, Type, Callback) is deprecated.", debug.traceback())
	end

	-- Handle BindableEvent and BindableFunction
	if table.find({ "BindableEvent", "BindableFunction" }, Type) then
		-- Initialize Bindables table if it doesn't exist
		if not self.Bindables then
			self.Bindables = {}
		end

		-- Create the Roblox instance
		local instance = Instance.new(Type)
		instance.Name = RemoteName
		self.Bindables[RemoteName] = instance

		-- Connect callback if provided
		if Callback then
			return self:Connect(RemoteName, Callback)
		end

		return
	end

	local isUnreliable = Type == "UnreliableRemoteEvent"
	local isTwoWay = Type == "RemoteFunction"

	self:new(RemoteName, not isUnreliable, isTwoWay)

	if Callback then
		return self:Connect(RemoteName, Callback)
	end
end
ServerNetworking.register = ServerNetworking.Register

--[[
	Fires a remote event to all connected players that pass the filter function.
	
	@param RemoteName - The name of the remote event
	@param Filter - A function that takes a Player and returns true to send the event, false to skip
	@param ... - Additional arguments to send with the event
]]
function ServerNetworking:FireAllFilter(RemoteName: string, Filter: (player: Player) -> boolean, ...)
	for _, player: Player in pairs(Players:GetPlayers()) do
		if Filter(player) then
			self:Fire(RemoteName, player, ...)
		end
	end
end
ServerNetworking.fireAllFilter = ServerNetworking.FireAllFilter

--[[
	Fires a remote event to all connected players within a certain distance from a position.
	
	@param RemoteName - The name of the remote event
	@param Position - The center position to measure distance from
	@param MaxDistance - The maximum distance from the position to send the event
	@param ... - Additional arguments to send with the event
]]
function ServerNetworking:FireAllNearby(RemoteName: string, Position: Vector3, MaxDistance: number, ...)
	return self:FireAllFilter(RemoteName, function(player: Player)
		return player:DistanceFromCharacter(Position) <= MaxDistance
	end, ...)
end
ServerNetworking.fireAllNearby = ServerNetworking.FireAllNearby

--[[
	Fires a remote event to all connected players except those specified.
	
	@param RemoteName - The name of the remote event
	@param Except - A Player or array of Players to exclude from receiving the event
	@param ... - Additional arguments to send with the event
]]
function ServerNetworking:FireAllExcept(RemoteName: string, Except: Player | { Player }, ...)
	return self:FireAllFilter(RemoteName, function(player: Player)
		if typeof(Except) == "table" then
			return not table.find(Except :: { Player }, player)
		end

		return player ~= (Except :: Player)
	end, ...)
end
ServerNetworking.fireAllExcept = ServerNetworking.FireAllExcept

-- Internal --
--[[
	Internal method to write a packet to the buffer for a specific player.
	Handles serialization of event ID, packet type, and arguments.
	
	@private
	@param id - The remote event identifier
	@param Reliable - Whether to use reliable transmission
	@param Player - Target player (nil for broadcast)
	@param packetType - Type of packet (EVENT, REQUEST, or RESPONSE)
	@param ... - Arguments to serialize into the packet
]]
function ServerNetworking:_sendPacket(id: string, Reliable: boolean, Player: Player?, packetType: number, ...: any)
	local write = self:_Writer(Reliable, Player)
	self.Buffers.WriteString(write, id)

	local n = select("#", ...)
	self.Buffers.WritePacketHeader(write, packetType, n)

	for i = 1, n do
		self.Buffers.WriteAny(write, select(i, ...))
	end
end

--[[
	Internal method to dispatch received packets to registered callbacks.
	Runs middleware, validates events, and handles EVENT/REQUEST/RESPONSE packet types.
	
	@private
	@param player - The player who sent the packet
	@param id - The remote event identifier
	@param args - Array of deserialized arguments (first element is packet type)
	@param argCount - Number of arguments in the array
]]
function ServerNetworking:_dispatch(player: Player, id: string, args: { any }, argCount: number)
	if self.Events[id] == nil then
		warn("[KnightRemotes]: ", `{player.Name} is attempting to call an unregistered event '{id}'. Dropping packet.`)
		return
	end

	-- Run middleware
	for _, middleware in ipairs(self.Middleware) do
		local shouldContinue, modifiedArgs = middleware(player, id, { table.unpack(args, 2, argCount) })
		if not shouldContinue then
			return -- Middleware blocked the request
		end
		if modifiedArgs then
			-- Replace args with modified version
			for i, v in ipairs(modifiedArgs) do
				args[i + 1] = v
			end
			argCount = #modifiedArgs + 1
		end
	end

	local packetType = args[1]

	if packetType == self.PacketTypes.PACKET_EVENT then
		for _, callback in pairs(self.Events[id].Callbacks) do
			task.spawn(callback, player, table.unpack(args, 2, argCount))
		end
	elseif packetType == self.PacketTypes.PACKET_REQUEST then
		local reqId = args[2]
		local callback = Sift.Dictionary.values(self.Events[id].Callbacks)[1]
		if not callback then
			warn(
				"[KnightRemotes]: ",
				`{player.Name} is attempting to invoke '{id}' which has no callback connected. Dropping packet.`
			)
			return
		end

		task.spawn(function()
			local results = {
				pcall(callback, player, table.unpack(args, 3, argCount)),
			}

			local ok = results[1]
			table.remove(results, 1)

			local writer = self:_Writer(true, player)
			self.Buffers.WriteString(writer, id)

			local n = #results + 2
			self.Buffers.WritePacketHeader(writer, self.PacketTypes.PACKET_RESPONSE, n)

			self.Buffers.WriteAny(writer, reqId)
			self.Buffers.WriteAny(writer, ok)

			for i, v in pairs(results) do
				self.Buffers.WriteAny(writer, v)
			end
		end)
	elseif packetType == self.PacketTypes.PACKET_RESPONSE then
		-- Handle response from client for server->client two-way requests
		local reqId = args[2]
		local ok = args[3]

		if type(ok) == "boolean" and ok == true or type(ok) == "number" and ok == 1 then
			ok = true
		else
			ok = false
		end

		local channel = self.Requests[id] and self.Requests[id][reqId]
		if not channel then
			warn(
				"[KnightRemotes]: ",
				`Received response for unknown request '{id}' with request ID '{reqId}' from {player.Name}. Dropping packet.`
			)
			return
		end

		self.Requests[id][reqId] = nil
		task.cancel(channel.timer)
		task.spawn(channel.thread, ok, table.unpack(args, 4, argCount))
	end
end

--[[
	Internal method to handle incoming network packets from a player.
	Deserializes the buffer and dispatches each event to _dispatch.
	
	@private
	@param player - The player who sent the packet
	@param buffer - The raw buffer data
	@param instance - Array of instance references for deserialization
]]
function ServerNetworking:_handleEvent(player: Player, buffer, instance: { Instance })
	local reader = self.Buffers.CreateReader(buffer, instance)

	while reader.cursor < reader.len do
		local id = self.Buffers.ReadString(reader)
		local type, argCount = self.Buffers.ReadPacketHeader(reader)

		local args = table.create(argCount + 1)
		args[1] = type
		for key = 1, argCount do
			args[key + 1] = self.Buffers.ReadAny(reader)
		end

		self:_dispatch(player, id, args, argCount + 1)
	end

	self.Buffers.FreeReader(reader)
end

--[[
	Internal method to immediately flush buffered packets to player(s).
	Used for time-sensitive operations like TwoWay requests.
	
	@private
	@param reliable - Whether to flush reliable or unreliable buffer
	@param player - Target player to flush (nil for broadcast flush)
]]
function ServerNetworking:_flushImmediate(reliable: boolean, player: Player?)
	if player then
		-- Flush for specific player
		local map = if reliable then self.ReliableMap else self.UnreliableMap
		local writer = map[player]

		if writer then
			map[player] = nil
			local remote = if reliable then self._Reliable else self._Unreliable
			remote:FireClient(player, self.Buffers.Finalize(writer))
			self.Buffers.FreeWriter(writer)
		end
	else
		-- Flush broadcast (used by FireAll)
		if reliable then
			if self.BroadcastReliable then
				local writer = self.BroadcastReliable
				self.BroadcastReliable = nil
				self._Reliable:FireAllClients(self.Buffers.Finalize(writer))
				self.Buffers.FreeWriter(writer)
			end
		else
			if self.BroadcastUnreliable then
				local writer = self.BroadcastUnreliable
				self.BroadcastUnreliable = nil
				self._Unreliable:FireAllClients(self.Buffers.Finalize(writer))
				self.Buffers.FreeWriter(writer)
			end
		end
	end
end

--[[
	Internal method to flush all buffered packets on the next frame.
	Called automatically by the Heartbeat loop to batch network operations.
	
	@private
]]
function ServerNetworking:_flush()
	if self.BroadcastReliable then
		local writer = self.BroadcastReliable
		self.BroadcastReliable = nil

		self._Reliable:FireAllClients(self.Buffers.Finalize(writer))
		self.Buffers.FreeWriter(writer)
	end

	if self.BroadcastUnreliable then
		local writer = self.BroadcastUnreliable
		self.BroadcastUnreliable = nil

		self._Unreliable:FireAllClients(self.Buffers.Finalize(writer))
		self.Buffers.FreeWriter(writer)
	end

	for player, writer in pairs(self.ReliableMap) do
		self.ReliableMap[player] = nil
		self._Reliable:FireClient(player, self.Buffers.Finalize(writer))
		self.Buffers.FreeWriter(writer)
	end

	for player, writer in pairs(self.UnreliableMap) do
		self.UnreliableMap[player] = nil
		self._Unreliable:FireClient(player, self.Buffers.Finalize(writer))
		self.Buffers.FreeWriter(writer)
	end
end

return ServerNetworking :: ServerNetworking & typeof(ServerNetworking)
