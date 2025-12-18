# KnightRemotes API Documentation

A high-performance, type-safe networking library for Roblox using binary buffers for efficient data transmission.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Reference](#api-reference)
- [Middleware System](#middleware-system)
- [Examples](#examples)
- [Best Practices](#best-practices)

## Installation

### Wally

Add to your `wally.toml`:

```toml
[dependencies]
knightremotes = "vq9o/knightremotes@2.0.0"
```

Then run:

```bash
wally install
```

## Quick Start

### Basic Event (One-Way Communication)

**Server:**
```lua
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)
KnightRemotes:init()

-- Create a reliable, one-way event
KnightRemotes:new("PlayerDamaged", true, false)

-- Connect callback
KnightRemotes:Connect("PlayerDamaged", function(player, damage)
    print(player.Name .. " took " .. damage .. " damage")
end)

-- Fire to specific player
local player = game.Players:GetPlayerByUserId(12345)
KnightRemotes:Fire("PlayerDamaged", player, 25)

-- Fire to all players
KnightRemotes:FireAll("PlayerDamaged", 50)
```

**Client:**
```lua
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)
KnightRemotes:init()

-- Register the same event
KnightRemotes:new("PlayerDamaged", true, false)

-- Fire to server
KnightRemotes:Fire("PlayerDamaged", 10)
```

### Two-Way Communication (Request/Response)

**Server:**
```lua
KnightRemotes:init()

-- Create a reliable, two-way remote
KnightRemotes:new("GetPlayerData", true, true)

-- Connect callback that returns data
KnightRemotes:Connect("GetPlayerData", function(player, dataType)
    if dataType == "coins" then
        return true, player.leaderstats.Coins.Value
    else
        return false, "Invalid data type"
    end
end)
```

**Client:**
```lua
KnightRemotes:init()

KnightRemotes:new("GetPlayerData", true, true)

-- Invoke and wait for response
local success, coins = KnightRemotes:Fire("GetPlayerData", "coins")
if success then
    print("You have " .. coins .. " coins")
else
    warn("Error: " .. coins)
end
```

## API Reference

### KnightRemotes:init()

Initializes the networking system. **Must be called before using any other methods.**

```lua
KnightRemotes:init()
```

### KnightRemotes:new()

Creates a new remote event or function.

```lua
KnightRemotes:new(
    RemoteName: string,
    Reliable: boolean?,  -- Default: true
    TwoWay: boolean?     -- Default: false
)
```

**Parameters:**
- `RemoteName` - Unique identifier for this remote
- `Reliable` - Whether to use reliable transmission (guaranteed delivery)
- `TwoWay` - Whether this is a request/response pattern (must be reliable)

**Example:**
```lua
-- Reliable one-way event
KnightRemotes:new("ChatMessage", true, false)

-- Unreliable one-way event (good for high-frequency updates)
KnightRemotes:new("PlayerPosition", false, false)

-- Two-way remote function
KnightRemotes:new("PurchaseItem", true, true)
```

### KnightRemotes:Connect()

Connects a callback to handle incoming events.

```lua
local connection = KnightRemotes:Connect(
    RemoteName: string,
    Callback: function
) -> Connection
```

**Returns:** Connection object with `Disconnect()` method

**Server Callback Signature:**
```lua
function(player: Player, ...args) -> ...returns
```

**Client Callback Signature:**
```lua
function(...args) -> ...returns
```

**Example:**
```lua
local conn = KnightRemotes:Connect("OnDamage", function(player, amount)
    -- Handle damage
end)

-- Later, disconnect
conn:Disconnect()
```

### KnightRemotes:Fire()

Fires an event or invokes a two-way remote.

**Server Usage:**
```lua
KnightRemotes:Fire(RemoteName: string, player: Player, ...args)
```

**Client Usage:**
```lua
KnightRemotes:Fire(RemoteName: string, ...args) -> ...results
```

**For two-way remotes, this yields and returns the response.**

### KnightRemotes:FireAll()

*(Server Only)* Fires an event to all players.

```lua
KnightRemotes:FireAll(RemoteName: string, ...args)
```

**Example:**
```lua
-- Notify all players of a global event
KnightRemotes:FireAll("ServerShutdown", "Server restarting in 5 minutes")
```

### Aliases

For familiarity with standard Roblox RemoteEvents/RemoteFunctions:

- `FireClient()` - Alias for `Fire()` (server)
- `FireServer()` - Alias for `Fire()` (client)
- `FireAllClients()` - Alias for `FireAll()`
- `InvokeClient()` - Alias for `Fire()` for two-way remotes
- `InvokeServer()` - Alias for `Fire()` for two-way remotes

## Middleware System

Middleware allows you to intercept and modify network packets before they're processed. Perfect for validation, logging, rate limiting, and more.

### KnightRemotes:UseMiddleware()

```lua
KnightRemotes:UseMiddleware(function(
    player: Player?,    -- nil on client
    eventName: string,
    args: {any}
) -> (shouldContinue: boolean, modifiedArgs: {any}?)
end)
```

**Parameters:**
- `player` - The player who sent the packet (nil on client)
- `eventName` - Name of the remote being called
- `args` - Arguments passed to the remote

**Returns:**
- `shouldContinue` - Whether to continue processing (false = drop packet)
- `modifiedArgs` - Optional modified arguments to use instead

### Middleware Examples

#### Rate Limiting

```lua
local rateLimits = {}
local MAX_REQUESTS_PER_SECOND = 10

KnightRemotes:UseMiddleware(function(player, eventName, args)
    if not player then return true end -- Skip on client
    
    local key = player.UserId .. "_" .. eventName
    local now = os.clock()
    
    if not rateLimits[key] then
        rateLimits[key] = { count = 0, resetTime = now + 1 }
    end
    
    local limit = rateLimits[key]
    
    if now > limit.resetTime then
        limit.count = 1
        limit.resetTime = now + 1
        return true
    end
    
    limit.count += 1
    
    if limit.count > MAX_REQUESTS_PER_SECOND then
        warn(player.Name .. " is being rate limited on " .. eventName)
        return false -- Drop the packet
    end
    
    return true
end)
```

#### Logging

```lua
KnightRemotes:UseMiddleware(function(player, eventName, args)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local playerName = player and player.Name or "CLIENT"
    
    print(string.format(
        "[%s] %s called '%s' with %d args",
        timestamp,
        playerName,
        eventName,
        #args
    ))
    
    return true -- Continue processing
end)
```

#### Argument Validation

```lua
KnightRemotes:UseMiddleware(function(player, eventName, args)
    if eventName == "ChatMessage" then
        local message = args[1]
        
        -- Check message length
        if type(message) ~= "string" or #message > 200 then
            warn("Invalid chat message from " .. player.Name)
            return false
        end
        
        -- Filter profanity
        local filtered = game:GetService("TextService"):FilterStringAsync(
            message,
            player.UserId
        )
        
        -- Modify the arguments
        return true, { filtered:GetNonChatStringForBroadcastAsync() }
    end
    
    return true
end)
```

#### Anti-Exploit Protection

```lua
KnightRemotes:UseMiddleware(function(player, eventName, args)
    if eventName == "PurchaseItem" then
        local itemId = args[1]
        local price = args[2]
        
        -- Validate item exists
        local itemData = ReplicatedStorage.Items:FindFirstChild(itemId)
        if not itemData then
            warn(player.Name .. " tried to purchase non-existent item")
            return false
        end
        
        -- Validate price (never trust client)
        local actualPrice = itemData.Price.Value
        if price ~= actualPrice then
            warn(player.Name .. " sent incorrect price for " .. itemId)
            -- Force the correct price
            return true, { itemId, actualPrice }
        end
    end
    
    return true
end)
```

## Examples

### Complete Game System Example

#### Server Setup

```lua
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)

KnightRemotes:init()

-- Setup remotes
KnightRemotes:new("PlayerJoined", true, false)
KnightRemotes:new("GetInventory", true, true)
KnightRemotes:new("EquipItem", true, true)
KnightRemotes:new("UpdatePosition", false, false) -- Unreliable for performance

-- Rate limiting middleware
local requestCounts = {}
KnightRemotes:UseMiddleware(function(player, eventName, args)
    if not player then return true end
    
    local key = player.UserId
    requestCounts[key] = (requestCounts[key] or 0) + 1
    
    if requestCounts[key] > 100 then
        player:Kick("Too many requests")
        return false
    end
    
    return true
end)

-- Reset rate limits every second
task.spawn(function()
    while true do
        task.wait(1)
        requestCounts = {}
    end
end)

-- Handle inventory requests
KnightRemotes:Connect("GetInventory", function(player)
    local inventory = player:FindFirstChild("Inventory")
    if inventory then
        return true, inventory:GetChildren()
    else
        return false, "Inventory not found"
    end
end)

-- Handle item equipping
KnightRemotes:Connect("EquipItem", function(player, itemId)
    local inventory = player:FindFirstChild("Inventory")
    local item = inventory and inventory:FindFirstChild(itemId)
    
    if item then
        -- Equip logic here
        return true, "Item equipped"
    else
        return false, "Item not in inventory"
    end
end)

-- Broadcast player positions to nearby players
KnightRemotes:Connect("UpdatePosition", function(player, position)
    -- Get nearby players
    local nearbyPlayers = {}
    for _, otherPlayer in pairs(game.Players:GetPlayers()) do
        if otherPlayer ~= player then
            local char = otherPlayer.Character
            local otherPos = char and char:GetPrimaryPartCFrame().Position
            if otherPos and (otherPos - position).Magnitude < 100 then
                table.insert(nearbyPlayers, otherPlayer)
            end
        end
    end
    
    -- Send position update to nearby players only
    for _, nearbyPlayer in pairs(nearbyPlayers) do
        KnightRemotes:Fire("PlayerMoved", nearbyPlayer, player.Name, position)
    end
end)
```

#### Client Setup

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)

local player = Players.LocalPlayer

KnightRemotes:init()

-- Setup remotes
KnightRemotes:new("PlayerJoined", true, false)
KnightRemotes:new("GetInventory", true, true)
KnightRemotes:new("EquipItem", true, true)
KnightRemotes:new("UpdatePosition", false, false)
KnightRemotes:new("PlayerMoved", false, false)

-- Handle other players moving
local otherPlayerPositions = {}
KnightRemotes:Connect("PlayerMoved", function(playerName, position)
    otherPlayerPositions[playerName] = position
    -- Update visual representation
end)

-- Send position updates (unreliable for performance)
RunService.Heartbeat:Connect(function()
    local character = player.Character
    if character then
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if hrp then
            KnightRemotes:Fire("UpdatePosition", hrp.Position)
        end
    end
end)

-- Request inventory
local function refreshInventory()
    local success, inventory = KnightRemotes:Fire("GetInventory")
    if success then
        print("Inventory:", inventory)
        -- Update UI
    else
        warn("Failed to get inventory:", inventory)
    end
end

-- Equip item
local function equipItem(itemId)
    local success, message = KnightRemotes:Fire("EquipItem", itemId)
    if success then
        print(message)
    else
        warn("Failed to equip:", message)
    end
end
```

## Best Practices

### 1. Always Initialize

Call `:init()` before using any networking features:

```lua
local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)
KnightRemotes:init()
```

### 2. Choose Reliable vs Unreliable Wisely

**Use Reliable (true) for:**
- Critical game logic
- Transactions (purchases, trades)
- Chat messages
- Important state changes

**Use Unreliable (false) for:**
- High-frequency updates (position, rotation)
- Cosmetic effects
- Non-critical audio/visual updates

### 3. Use Two-Way Remotes for Validation

When you need confirmation or data back:

```lua
-- Two-way remote for purchases
KnightRemotes:new("BuyItem", true, true)

local success, result = KnightRemotes:Fire("BuyItem", "Sword123")
if success then
    print("Purchased successfully!")
else
    warn("Purchase failed:", result)
end
```

### 4. Implement Rate Limiting

Protect against spam and exploits:

```lua
-- Use middleware for rate limiting
KnightRemotes:UseMiddleware(rateLimitingMiddleware)
```

### 5. Never Trust the Client

Always validate on the server:

```lua
KnightRemotes:Connect("PurchaseItem", function(player, itemId, clientPrice)
    -- NEVER trust client price
    local actualPrice = getItemPrice(itemId)
    
    if player.Coins.Value >= actualPrice then
        player.Coins.Value -= actualPrice
        giveItem(player, itemId)
        return true
    else
        return false, "Insufficient funds"
    end
end)
```

### 6. Use Middleware for Common Logic

Centralize validation, logging, and anti-exploit measures:

```lua
-- Single middleware for all validation
KnightRemotes:UseMiddleware(function(player, eventName, args)
    -- Log all requests
    logRequest(player, eventName, args)
    
    -- Rate limit
    if isRateLimited(player) then
        return false
    end
    
    -- Anti-exploit checks
    if isSuspiciousActivity(player, eventName, args) then
        flagPlayer(player)
        return false
    end
    
    return true
end)
```

### 7. Disconnect When Done

Clean up connections you no longer need:

```lua
local connection = KnightRemotes:Connect("TempEvent", callback)

-- Later...
connection:Disconnect()
```

### 8. Handle Errors Gracefully

Two-way remotes can error - handle them:

```lua
local success, result = pcall(function()
    return KnightRemotes:Fire("GetData")
end)

if success then
    -- Process result
else
    warn("Request failed:", result)
end
```

## Performance Tips

1. **Batch Updates**: Instead of sending multiple individual updates, batch them together
2. **Use Unreliable for High-Frequency**: Position/rotation updates don't need guaranteed delivery
3. **Limit Arguments**: Fewer arguments = smaller packets
4. **Optimize Data Types**: Use integers when possible (more compact than floats)
5. **Middleware Performance**: Keep middleware functions lightweight

## Type Safety

KnightRemotes is built with `--!strict` mode and full type annotations. You get IntelliSense and type checking:

```lua
--!strict

local KnightRemotes = require(ReplicatedStorage.Packages.knightremotes)

-- Type-safe callbacks
KnightRemotes:Connect("Damage", function(player: Player, amount: number)
    -- TypeScript-like autocomplete and checking
    player.Character.Humanoid.Health -= amount
end)
```

## Migration from Standard RemoteEvents

If you're coming from standard RemoteEvents/RemoteFunctions:

| Old | New |
|-----|-----|
| `remoteEvent = Instance.new("RemoteEvent")` | `KnightRemotes:new("EventName")` |
| `remoteEvent:FireClient(player, ...)` | `KnightRemotes:Fire("EventName", player, ...)` |
| `remoteEvent:FireAllClients(...)` | `KnightRemotes:FireAll("EventName", ...)` |
| `remoteEvent.OnServerEvent:Connect(...)` | `KnightRemotes:Connect("EventName", ...)` |
| `remoteFunction:InvokeServer(...)` | `KnightRemotes:Fire("EventName", ...)` (with TwoWay=true) |

## Troubleshooting

### Requests Timing Out

Default timeout is 60 seconds. Check:
- Server callback is connected
- No errors in server callback
- Network connectivity

### "Two-way remotes must be reliable"

You can't create unreliable two-way remotes. Change to `reliable = true`.

### Middleware Blocking Everything

Check your middleware return values - make sure to `return true` to allow packets through.

---

**Need help?** Open an issue on [GitHub](https://github.com/Metatable-Games/KnightRemotes)
