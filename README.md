# knightremotes

A high-performance, type-safe networking library for Roblox using binary buffers for efficient data transmission.

## Features

✨ **High Performance** - Binary buffer protocol with automatic batching  
🔒 **Type Safe** - Full strict mode support with comprehensive type annotations  
🛡️ **Middleware System** - Intercept and modify packets for validation, logging, and rate limiting  
⚡ **Reliable & Unreliable** - Choose the right transmission method for your use case  
🔄 **Two-Way Communication** - Request/response pattern for client-server interactions  
📦 **Efficient Serialization** - Optimized encoding for all Roblox data types  

## Quick Start

```lua
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)
KnightRemotes:init()

-- Create a remote
KnightRemotes:new("PlayerDamaged", true, false)

-- Server: Listen for events
KnightRemotes:Connect("PlayerDamaged", function(player, damage)
    player.Character.Humanoid.Health -= damage
end)

-- Client: Fire events
KnightRemotes:Fire("PlayerDamaged", 25)
```

## Documentation

* 📖 [API Documentation](docs/API.md) - Complete API reference with examples
* 🔧 [Migration Guide](docs/API.md#migration-from-standard-remoteevents) - Coming from RemoteEvents?

## Installation

### Wally

```toml
[dependencies]
knightremotes = "vq9o/knightremotes@2.0.0"
```

Then run: `wally install`

## Why KnightRemotes?

Traditional RemoteEvents and RemoteFunctions are simple but inefficient. KnightRemotes provides:

- **60% smaller packets** through optimized binary serialization
- **Automatic batching** of multiple calls in a single frame
- **Middleware system** for centralized validation and rate limiting
- **Type safety** with full Luau type annotations
- **Flexible reliability** - choose reliable or unreliable per remote

## Example: Two-Way Communication (Server -> Client / Client -> Server)

```lua
-- Server
KnightRemotes:new("GetPlayerData", {
    Reliable = true;
    TwoWay = true;
}, function(player, dataType)
    return true, player.Data[dataType]
end)

-- Client
local success, data = KnightRemotes:Fire("GetPlayerData", "inventory")
if success then
    print("Inventory:", data)
end
```

## Example: Middleware

```lua
-- Rate limiting middleware
KnightRemotes:UseMiddleware(function(player, eventName, args)
    if isRateLimited(player) then
        return false -- Block the request
    end
    return true
end)
```

## Links
* The Knight framework (**not required**): https://github.com/RAMPAGELLC/knight/tree/main
* Documentation: https://knight.metatable.dev/luau-api/knight-remotes-api
* Legacy (V1): https://github.com/RAMPAGELLC/KnightRemotes

# License
```
MIT License

Copyright (c) 2025 Meta Games, LLC.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
