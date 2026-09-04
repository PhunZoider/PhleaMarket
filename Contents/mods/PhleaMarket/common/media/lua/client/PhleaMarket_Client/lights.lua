if isServer() then
    return
end

-- The glow on a machine's face.
--
-- A vending machine that goes dark in a blackout is right for a machine that
-- runs off the mains. This one does not: it declares powered = false, it still
-- trades with the grid down, and so it is still lit with the grid down. A shop
-- that declares powered = true is lit only while its square has power, decided
-- by the same test that chooses between its two faces, so the light and the
-- sprite never disagree about whether the thing is running.
--
-- The light is a lamppost on the cell rather than a property on the sprite. The
-- engine will build a light out of LightRadius and lightR/G/B, which is how a
-- vanilla vending machine glows, but it decides that when the world loads the
-- object and it gates the result on mains power. PhunMart builds these with
-- IsoObject.new long after the world has loaded, and half of what is wanted
-- here is a light that outlives the grid. So the sprites carry no light
-- properties at all and this file owns the whole of it.
--
-- Every client does this for itself. A lamppost is a fact about rendering, it
-- is never sent anywhere, and there is nothing here to keep in step between
-- players.

require "PhleaMarket/core"

local Core = PhunMart
local Market = PhleaMarket

-- A warm white, against a night PZ paints blue. Written as the 0..255 anybody
-- reading this would reach for and divided down, because a light source wants
-- 0..1. Two tiles is the reach vanilla gives a vending machine.
local LIGHT_R, LIGHT_G, LIGHT_B = 255 / 255, 214 / 255, 170 / 255
local LIGHT_RADIUS = 2

--- Which way a tile faces, in squares.
---
--- A lamppost is a point and the engine has no cone to aim, so the closest
--- thing to a directional machine is to hang its light on the square in front
--- of it rather than on the machine. The glow then lands on the ground the
--- glass is facing, and the machine, being solid, shades its own back.
local AHEAD = {
    N = {x = 0, y = -1},
    S = {x = 0, y = 1},
    E = {x = 1, y = 0},
    W = {x = -1, y = 0}
}

-- How far in front to hang it. Zero puts the light back on the machine, and a
-- negative number puts it behind, which is the one-character fix if the sprite
-- property turns out to name the side the machine's back is against.
local AHEAD_TILES = 1

--- Every machine this client has seen, keyed by its own square. The light is
--- remembered separately as {x, y, z}, because it does not hang on that square.
local known = {}

--- The lamppost burning at a square, for those that have one.
local lit = {}

local function keyFor(x, y, z)
    return x .. "," .. y .. "," .. z
end

---------------------------------------------------------------------------
-- Recognising a machine
---------------------------------------------------------------------------

--- Whether an object is one of this mod's machines.
---
--- Asked of the sprite rather than of the object's name. PhunMart names a
--- machine PhunMartVendingMachine, but only once its own client-side handler
--- has been past, and that can be after this one has. CustomName is on all
--- eight sprites, powered and unplugged alike, so it answers the same for a
--- machine in either state.
local function propsOf(isoObject)
    local sprite = isoObject and isoObject:getSprite()
    return sprite and sprite:getProperties() or nil
end

local function isMachine(isoObject)
    local props = propsOf(isoObject)
    return props ~= nil and props:get("CustomName") == Market.name
end

--- The square a machine's light should hang over.
---
--- The direction comes off the sprite rather than off the object, because the
--- sprite is what is actually being looked at: all eight of them carry Facing,
--- and a machine that swaps to its unplugged face keeps the same one. A sprite
--- with no Facing, which would mean somebody has pointed the shop at art of
--- their own, leaves the light on the machine.
local function lightSquare(isoObject, square)
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local props = propsOf(isoObject)
    local ahead = props and AHEAD[props:get("Facing")]
    if not ahead then
        return x, y, z
    end
    return x + ahead.x * AHEAD_TILES, y + ahead.y * AHEAD_TILES, z
end

--- The machine standing on a square, if one is.
local function machineOn(square)
    local objects = square and square:getObjects()
    if not objects then
        return nil
    end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if isMachine(object) then
            return object
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Deciding, lighting, putting out
---------------------------------------------------------------------------

--- Whether the machine on this square should be burning.
---
--- The powered branch is worded to match ServerObject:hasElectricity in
--- PhunMart, which is what picks the sprite. A machine wearing its unplugged
--- face and glowing anyway would be worse than no light at all.
local function shouldBurn(square)
    local def = Core.shops and Core.shops[Market.name]
    if not def or def.powered ~= true then
        -- Wants no mains, so it burns whatever the grid is doing. This is also
        -- the answer before the shop definitions have reached this client,
        -- which is the right way round: this mod's own machine is one of these.
        return true
    end
    if square:haveElectricity() then
        return true
    end
    local grace = SandboxVars.ElecShutModifier
    return grace ~= nil and grace > -1 and GameTime:getInstance():getNightsSurvived() < grace
end

local function extinguish(key)
    local light = lit[key]
    if not light then
        return
    end
    local cell = getCell()
    if cell then
        cell:removeLamppost(light)
    end
    lit[key] = nil
    Market.debugLn("light out for the machine at " .. key)
end

local function ignite(key, where)
    if lit[key] then
        return
    end
    local cell = getCell()
    if not cell then
        return
    end
    local light = IsoLightSource.new(where.x, where.y, where.z, LIGHT_R, LIGHT_G, LIGHT_B, LIGHT_RADIUS)
    cell:addLamppost(light)
    lit[key] = light
    Market.debugLn("light on at " .. keyFor(where.x, where.y, where.z) .. " for the machine at " .. key)
end

--- Put one machine's light where it should be, lit or out.
local function settle(key, at, square)
    if shouldBurn(square) then
        ignite(key, at.light)
    else
        extinguish(key)
    end
end

--- Take note of a machine, and light it if it has earned it.
local function remember(isoObject)
    local square = isoObject:getSquare()
    if not square then
        return
    end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local key = keyFor(x, y, z)
    local at = known[key]
    if not at then
        local lx, ly, lz = lightSquare(isoObject, square)
        at = {x = x, y = y, z = z, light = {x = lx, y = ly, z = lz}}
        known[key] = at
    end
    settle(key, at, square)
end

local function forget(key)
    known[key] = nil
    extinguish(key)
end

---------------------------------------------------------------------------
-- When to look
---------------------------------------------------------------------------

--- Read a square that has just come in.
---
--- OnObjectAdded covers a machine that appears while somebody is watching it.
--- Squares are read as they load as well, because the ordinary way to meet a
--- machine is to walk back to one that arrives with its chunk, and remembering
--- the same machine twice costs nothing.
local function readSquare(square)
    local machine = machineOn(square)
    if machine then
        remember(machine)
    end
end

--- Walk everything known, once a minute.
---
--- Two jobs. Nothing announces the grid going down, so every light is decided
--- again. And the cell holds a lamppost until it is told otherwise, so a
--- machine whose chunk has unloaded, or that somebody has carried off, would
--- otherwise leave one burning over nothing.
local function sweep()
    local cell = getCell()
    if not cell then
        return
    end
    for key, at in pairs(known) do
        local square = cell:getGridSquare(at.x, at.y, at.z)
        if not square or not machineOn(square) then
            forget(key)
        else
            settle(key, at, square)
        end
    end
end

Events.LoadGridsquare.Add(readSquare)

Events.OnObjectAdded.Add(function(isoObject)
    if isMachine(isoObject) then
        remember(isoObject)
    end
end)

Events.OnObjectAboutToBeRemoved.Add(function(isoObject)
    if not isMachine(isoObject) then
        return
    end
    local square = isoObject:getSquare()
    if square then
        forget(keyFor(square:getX(), square:getY(), square:getZ()))
    end
end)

Events.EveryOneMinute.Add(sweep)
