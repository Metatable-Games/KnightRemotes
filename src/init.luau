--[[
 (©) Copyright 2025 Meta Games, LLC. All rights reserved.

 This software is licensed by Meta Games, LLC under the terms of the MIT License.
 You may not use this file except in compliance with the License.
 You may obtain a copy of the License at https://opensource.org/license/mit/

 Main Repository (V2): https://github.com/Metatable-Games/KnightRemotes
 Legacy (v1): https://github.com/RAMPAGELLC/KnightRemotes
]]

local RunService = game:GetService("RunService")
return RunService:IsServer() and require("@self/ServerNetworking") or require("@self/ClientNetworking")
