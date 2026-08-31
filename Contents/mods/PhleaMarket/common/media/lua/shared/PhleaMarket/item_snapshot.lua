-- Turning an InventoryItem into a table and back again.
--
-- Everything the market does rests on this. An item listed for sale leaves the
-- world entirely: it is removed from the seller's inventory, lives in a ModData
-- table across restarts, and is built again from nothing when somebody buys it
-- or the listing expires. Nothing else in PhunMart has ever had to do that --
-- every reward path there is inv:AddItem(fullType), a fresh instance from a
-- script name -- and the engine offers Lua no serialiser to lean on.
--
-- The cost of getting it wrong is not a rough edge, it is an exploit. Store
-- only the item type and the machine becomes a repair bench: list a ruined
-- machete, let it expire, collect a new one. It also makes every listing of a
-- type identical, which takes away the only judgement a buyer would exercise.
--
-- So: a whitelist of properties, captured by capability rather than by asking
-- what class the item is, because the answer to "does this item have a
-- condition" is better obtained by looking than by keeping a list of the
-- classes that do.
--
-- This module deliberately depends on nothing. Not on PhunMart, not on the rest
-- of this mod, and on no engine global at load time -- only at call time, which
-- is what lets the whole of it be tested against a table pretending to be an
-- item. It is the first thing built and the only part testable without
-- launching the game, so it is the part worth being sure of.

local Snapshot = {}

--- Bumped when the shape below changes in a way an older stored snapshot would
--- not survive. Stored on every snapshot so restore can tell, rather than
--- guessing from which keys happen to be present.
Snapshot.VERSION = 1

---------------------------------------------------------------------------
-- Mod data
---------------------------------------------------------------------------

-- What may travel in a snapshot's modData.
--
-- Anything else is dropped rather than carried: a function or a piece of Java
-- userdata cannot be written to ModData and cannot survive a restart, so
-- keeping it would produce a snapshot that works until the server is bounced
-- and then quietly does not.
local COPYABLE = {
    string = true,
    number = true,
    boolean = true
}

--- Deep copy the parts of a mod data table worth keeping.
---
--- `seen` guards against a table that contains itself. Mod data is normally
--- flat, but it belongs to whichever mod put it there and nothing stops one
--- from building a cycle; without this, one such item would hang the server on
--- the first attempt to list it.
local function copyValue(value, seen)
    local kind = type(value)
    if COPYABLE[kind] then
        return value
    end
    if kind ~= "table" then
        return nil
    end
    seen = seen or {}
    if seen[value] then
        return nil
    end
    seen[value] = true

    local out = {}
    for k, v in pairs(value) do
        -- Keys go the same way as values, and for a sharper reason: this table
        -- is bound for ModData, which a JSON mirror has to be able to write,
        -- and JSON object keys are strings. A number key survives in memory and
        -- vanishes through the file, which is a bug that only appears after a
        -- restart. Numbers are kept -- a sequence is worth having -- but
        -- anything else as a key is not worth the trouble it causes later.
        local keyKind = type(k)
        if keyKind == "string" or keyKind == "number" then
            local copied = copyValue(v, seen)
            if copied ~= nil then
                out[k] = copied
            end
        end
    end

    seen[value] = nil
    return out
end

--- Whether a table holds anything at all. Mod data is usually an empty table
--- rather than nil, and an empty one is not worth storing on every listing.
local function isEmpty(tbl)
    if type(tbl) ~= "table" then
        return true
    end
    for _ in pairs(tbl) do
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Capability probes
--
-- `item.getCondition` rather than instanceof: presence of the method is the
-- question actually being asked, it costs nothing, and it does not go stale
-- when the engine moves a method between classes.
---------------------------------------------------------------------------

--- Call a getter if the item has one, and hand back nil if it does not or if
--- the call goes wrong. An item type from a mod that has been half-uninstalled
--- can have a method that throws, and one bad item should cost its own listing
--- rather than the whole market.
local function get(item, method)
    if not item or type(item[method]) ~= "function" then
        return nil
    end
    local ok, value = pcall(item[method], item)
    if ok then
        return value
    end
    return nil
end

--- Call a setter if the item has one. Silent when it does not: an item whose
--- script no longer supports a property is better restored without it than not
--- restored at all.
local function set(item, method, ...)
    if not item or type(item[method]) ~= "function" then
        return false
    end
    return pcall(item[method], item, ...)
end

--- instanceof, if the engine is there to answer. Off the engine -- in a test --
--- there is no class to ask about, so this says no and the capability probes
--- carry the weight instead.
local function isA(item, className)
    if type(instanceof) ~= "function" then
        return false
    end
    local ok, result = pcall(instanceof, item, className)
    return ok and result == true
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

--- Describe an item completely enough to build it again.
---
--- Returns nil for anything that is not an item with a type, which is the only
--- failure worth reporting: everything else is a property that either applies
--- or does not, and a missing one is absence rather than error.
function Snapshot.capture(item)
    if not item then
        return nil
    end
    local fullType = get(item, "getFullType")
    if type(fullType) ~= "string" or fullType == "" then
        return nil
    end

    local snap = {
        v = Snapshot.VERSION,
        fullType = fullType
    }

    -- Condition, with the maximum it was measured against.
    --
    -- Both, because condition is meaningless alone: an axe at 4 is nearly
    -- broken and a wall at 4 is nearly new. Keeping the scale lets restore
    -- rebuild the item proportionally if a mod update moves the maximum, rather
    -- than handing back something arbitrarily sturdier or more fragile.
    local conditionMax = get(item, "getConditionMax")
    if type(conditionMax) == "number" and conditionMax > 0 then
        local condition = get(item, "getCondition")
        if type(condition) == "number" then
            snap.condition = condition
            snap.conditionMax = conditionMax
        end
    end

    -- How much of a drainable is left. A fraction from 0 (full) to 1 (empty),
    -- which is the engine's own convention and not one worth reinventing.
    local usedDelta = get(item, "getUsedDelta")
    if type(usedDelta) == "number" then
        snap.usedDelta = usedDelta
    end

    -- Food: how old it is and what is left of its nutrition. Without age, a
    -- listed steak comes back fresh, which is the same laundering problem
    -- condition has.
    if isA(item, "Food") or get(item, "getAge") ~= nil then
        local age = get(item, "getAge")
        if type(age) == "number" then
            snap.age = age
        end
        local hunger = get(item, "getHungChange")
        if type(hunger) == "number" then
            snap.hungChange = hunger
        end
    end

    -- A name the player typed. Only when it is actually theirs: every item has
    -- a name, and storing the default one would mean restoring a "custom" name
    -- onto an item that never had one.
    if get(item, "isCustomName") == true then
        local name = get(item, "getName")
        if type(name) == "string" and name ~= "" then
            snap.name = name
        end
    end

    if get(item, "isFavorite") == true then
        snap.favorite = true
    end

    if get(item, "isCustomColor") == true then
        local r, g, b = get(item, "getColorRed"), get(item, "getColorGreen"), get(item, "getColorBlue")
        if type(r) == "number" and type(g) == "number" and type(b) == "number" then
            snap.color = {
                r = r,
                g = g,
                b = b
            }
        end
    end

    if get(item, "isCustomWeight") == true then
        local weight = get(item, "getActualWeight")
        if type(weight) == "number" then
            snap.weight = weight
        end
    end

    local modData = copyValue(get(item, "getModData"))
    if not isEmpty(modData) then
        snap.modData = modData
    end

    return snap
end

---------------------------------------------------------------------------
-- Restore
---------------------------------------------------------------------------

--- Build the item a snapshot describes.
---
--- Returns nil when the item type is no longer in the game, which happens when
--- a server drops a mod while something of its is sitting in escrow. The caller
--- decides what that means -- the listing is void and the seller is owed
--- something, or it is quietly dropped -- because this module has no idea which
--- is fair and no business deciding.
function Snapshot.restore(snap)
    if type(snap) ~= "table" or type(snap.fullType) ~= "string" or snap.fullType == "" then
        return nil
    end

    -- Ask before building. CreateItem on a type the script manager has never
    -- heard of is not a question worth putting to the engine.
    local manager = type(getScriptManager) == "function" and getScriptManager()
    if manager and type(manager.FindItem) == "function" then
        local ok, script = pcall(manager.FindItem, manager, snap.fullType)
        if not ok or not script then
            return nil
        end
    end

    if type(InventoryItemFactory) ~= "table" or type(InventoryItemFactory.CreateItem) ~= "function" then
        return nil
    end
    local created, item = pcall(InventoryItemFactory.CreateItem, snap.fullType)
    if not created or not item then
        return nil
    end

    -- Condition, rescaled if the maximum has moved since capture. An axe listed
    -- at half worn comes back half worn, whatever the numbers happen to be now.
    if type(snap.condition) == "number" then
        local value = snap.condition
        local nowMax = get(item, "getConditionMax")
        local thenMax = snap.conditionMax
        if type(nowMax) == "number" and nowMax > 0 and type(thenMax) == "number" and thenMax > 0 and nowMax ~= thenMax then
            value = math.floor(value * nowMax / thenMax + 0.5)
        end
        if type(nowMax) == "number" and nowMax > 0 then
            if value > nowMax then
                value = nowMax
            end
        end
        if value < 0 then
            value = 0
        end
        set(item, "setCondition", value)
    end

    if type(snap.usedDelta) == "number" then
        set(item, "setUsedDelta", snap.usedDelta)
    end

    if type(snap.age) == "number" then
        set(item, "setAge", snap.age)
    end
    if type(snap.hungChange) == "number" then
        set(item, "setHungChange", snap.hungChange)
    end

    if type(snap.name) == "string" and snap.name ~= "" then
        -- Order matters: the flag is what makes the name stick as the player's
        -- own rather than something the next refresh is free to overwrite.
        set(item, "setName", snap.name)
        set(item, "setCustomName", true)
    end

    if snap.favorite == true then
        set(item, "setFavorite", true)
    end

    if type(snap.color) == "table" then
        set(item, "setColorRed", snap.color.r)
        set(item, "setColorGreen", snap.color.g)
        set(item, "setColorBlue", snap.color.b)
        set(item, "setCustomColor", true)
    end

    if type(snap.weight) == "number" then
        set(item, "setActualWeight", snap.weight)
        set(item, "setCustomWeight", true)
    end

    if type(snap.modData) == "table" then
        -- copyModData is the engine's own way of moving mod data between two
        -- items, so it is what vanilla reaches for and what this should use.
        -- The fallback writes the keys directly, which is the behaviour wanted
        -- either way: a freshly created item may carry mod data its own scripts
        -- put there, and the stored keys should land on top of that rather than
        -- replace it wholesale.
        if not set(item, "copyModData", snap.modData) then
            local target = get(item, "getModData")
            if type(target) == "table" then
                for k, v in pairs(snap.modData) do
                    target[k] = v
                end
            end
        end
    end

    return item
end

---------------------------------------------------------------------------
-- Stacking
---------------------------------------------------------------------------

--- Whether every one of these is interchangeable with every other.
---
--- Fifty nails should be one listing with a price per nail, not fifty listings.
--- Fifty axes should not, because a snapshot holds one exemplar and the other
--- forty-nine would come back wearing its condition. So the question is not
--- "does this item stack in the inventory" but "would a buyer be able to tell
--- two of them apart".
---
--- Anything carrying state says no: condition, drainable charge, food age, a
--- name someone typed, a colour, a weight, or mod data, which is where another
--- mod keeps whatever makes its items individual.
function Snapshot.isStackable(item)
    local snap = Snapshot.capture(item)
    return Snapshot.isStackableSnapshot(snap)
end

--- The same question asked of a snapshot rather than an item, so a listing can
--- be checked after the item itself is gone.
function Snapshot.isStackableSnapshot(snap)
    if type(snap) ~= "table" then
        return false
    end
    if snap.condition ~= nil or snap.usedDelta ~= nil then
        return false
    end
    if snap.age ~= nil or snap.hungChange ~= nil then
        return false
    end
    if snap.name ~= nil or snap.favorite ~= nil or snap.color ~= nil or snap.weight ~= nil then
        return false
    end
    if snap.modData ~= nil then
        return false
    end
    return true
end

return Snapshot
