--!strict
-- (©) Copyright 2025 Meta Games, LLC. All rights reserved.

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

export type ClientNetworking = {
	Events: { [string]: EventInfo },
	Middleware: { Middleware },
	Disconnect: (self: ClientNetworking, RemoteName: string, ConnectionId: string) -> (),
	Connect: (self: ClientNetworking, RemoteName: string, Callback: (...any) -> any) -> Connection,
	Fire: (self: ClientNetworking, RemoteName: string, ...any) -> ...any,
	UseMiddleware: (self: ClientNetworking, middleware: Middleware) -> (),
	_sendPacket: (self: ClientNetworking, id: string, reliable: boolean, packetType: number, ...any) -> (),
	_dispatch: (self: ClientNetworking, id: string, args: { any }, argCount: number) -> (),
	_handleEvent: (self: ClientNetworking, buffer: buffer, instance: { Instance }) -> (),
	_flush: (self: ClientNetworking) -> (),
}

local ClientNetworking = Class("ClientNetworking"):Extend(SharedNetworkingModule)

-- Internal --
--[[
	Internal method to write a packet to the buffer for sending to server.
	Handles serialization of event ID, packet type, and arguments.
	
	@private
	@param id - The remote event identifier
	@param reliable - Whether to use reliable transmission
	@param packetType - Type of packet (EVENT, REQUEST, or RESPONSE)
	@param ... - Arguments to serialize into the packet
]]
function ClientNetworking:_sendPacket(id: string, reliable: boolean, packetType: number, ...: any)
	local writer = self:_Writer(reliable)

	self.Buffers.WriteString(writer, id)

	local n = select("#", ...)
	self.Buffers.WritePacketHeader(writer, packetType, n)

	for i = 1, n do
		self.Buffers.WriteAny(writer, select(i, ...))
	end
end

--[[
	Internal method to dispatch received packets from server to registered callbacks.
	Runs middleware, validates events, and handles EVENT/REQUEST/RESPONSE packet types.
	
	@private
	@param id - The remote event identifier
	@param args - Array of deserialized arguments (first element is packet type)
	@param argCount - Number of arguments in the array
]]
function ClientNetworking:_dispatch(id: string, args: { any }, argCount: number)
	if self.Events[id] == nil then
		warn("[KnightRemotes]: ", "Server is attempting to call an unregistered event '" .. id .. "'. Dropping packet.")
		return
	end

	-- Run middleware (client doesn't have player context, so pass nil)
	for _, middleware in ipairs(self.Middleware) do
		local shouldContinue, modifiedArgs = middleware(nil, id, { table.unpack(args, 2, argCount) })
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
			task.spawn(callback, table.unpack(args, 2, argCount))
		end
	elseif packetType == self.PacketTypes.PACKET_RESPONSE then
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
				`Received response for unknown request '{id}' with request ID '{reqId}'. Dropping packet.`
			)
			return
		end

		self.Requests[id][reqId] = nil
		task.cancel(channel.timer)
		task.spawn(channel.thread, ok, table.unpack(args, 4, argCount))
	elseif packetType == self.PacketTypes.PACKET_REQUEST then
		-- Handle request from server for server->client two-way requests
		local reqId = args[2]
		local callback = Sift.Dictionary.values(self.Events[id].Callbacks)[1]
		if not callback then
			warn(
				"[KnightRemotes]: ",
				`Server is attempting to invoke '{id}' which has no callback connected. Dropping packet.`
			)
			return
		end

		task.spawn(function()
			local results = {
				pcall(callback, table.unpack(args, 3, argCount)),
			}

			local ok = results[1]
			table.remove(results, 1)

			local writer = self:_Writer(true)
			self.Buffers.WriteString(writer, id)

			local n = #results + 2
			self.Buffers.WritePacketHeader(writer, self.PacketTypes.PACKET_RESPONSE, n)

			self.Buffers.WriteAny(writer, reqId)
			self.Buffers.WriteAny(writer, ok)

			for i, v in pairs(results) do
				self.Buffers.WriteAny(writer, v)
			end

			self:_flushImmediate(true, nil)
		end)
	end
end

--[[
	Internal method to handle incoming network packets from server.
	Deserializes the buffer and dispatches each event to _dispatch.
	
	@private
	@param buffer - The raw buffer data
	@param instance - Array of instance references for deserialization
]]
function ClientNetworking:_handleEvent(buffer, instance: { Instance })
	local reader = self.Buffers.CreateReader(buffer, instance)

	while reader.cursor < reader.len do
		local id = self.Buffers.ReadString(reader)
		local type, argCount = self.Buffers.ReadPacketHeader(reader)

		local args = table.create(argCount + 1)
		args[1] = type
		for key = 1, argCount do
			args[key + 1] = self.Buffers.ReadAny(reader)
		end

		self:_dispatch(id, args, argCount + 1)
	end

	self.Buffers.FreeReader(reader)
end

--[[
	Internal method to immediately flush buffered packets to server.
	Used for time-sensitive operations like TwoWay requests.
	
	@private
	@param reliable - Whether to flush reliable or unreliable buffer
	@param player - Unused on client (kept for API compatibility)
]]
function ClientNetworking:_flushImmediate(reliable: boolean, player: Player?)
	local map = if reliable then self.ReliableMap else self.UnreliableMap
	local writer = map["_server"]

	if writer then
		map["_server"] = nil
		local remote = if reliable then self._Reliable else self._Unreliable
		remote:FireServer(self.Buffers.Finalize(writer))
		self.Buffers.FreeWriter(writer)
	end
end

--[[
	Internal method to flush all buffered packets to server on the next frame.
	Called automatically by the Heartbeat loop to batch network operations.
	
	@private
]]
function ClientNetworking:_flush()
	local reliableWriter = self.ReliableMap["_server"]
	if reliableWriter then
		self.ReliableMap["_server"] = nil
		self._Reliable:FireServer(self.Buffers.Finalize(reliableWriter))
		self.Buffers.FreeWriter(reliableWriter)
	end

	local unreliableWriter = self.UnreliableMap["_server"]
	if unreliableWriter then
		self.UnreliableMap["_server"] = nil
		self._Unreliable:FireServer(self.Buffers.Finalize(unreliableWriter))
		self.Buffers.FreeWriter(unreliableWriter)
	end
end

return ClientNetworking :: ClientNetworking & typeof(ClientNetworking)
