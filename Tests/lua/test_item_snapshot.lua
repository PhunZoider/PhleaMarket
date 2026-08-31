-- Covers item_snapshot: turning an InventoryItem into a table and back again.
--
-- This is the module the whole market rests on, and its failures are quiet
-- ones. A dropped property does not throw, it hands the seller back a better
-- item than they listed, which is indistinguishable from generosity until
-- somebody notices the machine will repair anything for the price of a listing
-- fee. So the tests here are mostly about what must NOT be lost.
--
-- The item is a plain table with the methods a real one has. That works because
-- the module probes for methods rather than asking what class it is holding,
-- which is the same property that makes it survive an engine that moves a
-- method from one class to another.
--
-- Run: luajit test_item_snapshot.lua   (or run.cmd, which runs all of them)

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = arg[1] or (here .. "/../..")
package.path = here .. "/?.lua;" .. package.path

local harness = require "harness"

local shared = root .. "/Contents/mods/PhleaMarket/common/media/lua/shared"
package.path = shared .. "/?.lua;" .. package.path

harness.installGlobals()

---------------------------------------------------------------------------
-- A stand-in for the engine
---------------------------------------------------------------------------

-- Item types the script manager knows about. Restoring anything else is how a
-- server that has dropped a mod behaves, and is tested for.
local KNOWN = {
    ["Base.Axe"] = true,
    ["Base.Nails"] = true,
    ["Base.WaterBottle"] = true,
    ["Base.Steak"] = true,
    ["Base.Hat"] = true
}

_G.getScriptManager = function()
    return {
        FindItem = function(_, fullType)
            return KNOWN[fullType] and {
                type = fullType
            } or nil
        end
    }
end

-- A table that answers like an InventoryItem. Only the getters an item of this
-- shape would actually have are defined: leaving the others off is the point,
-- since that is how the module tells a nail from an axe.
local function makeItem(spec)
    local item = {}
    local state = {
        fullType = spec.fullType or "Base.Axe",
        condition = spec.condition,
        conditionMax = spec.conditionMax,
        usedDelta = spec.usedDelta,
        age = spec.age,
        hungChange = spec.hungChange,
        name = spec.name,
        customName = spec.customName,
        favorite = spec.favorite,
        color = spec.color,
        weight = spec.weight,
        customWeight = spec.customWeight,
        modData = spec.modData or {}
    }
    item._state = state

    function item:getFullType()
        return state.fullType
    end
    function item:getModData()
        return state.modData
    end
    function item:copyModData(t)
        for k, v in pairs(t) do
            state.modData[k] = v
        end
    end

    if spec.conditionMax ~= nil then
        function item:getCondition()
            return state.condition
        end
        function item:getConditionMax()
            return state.conditionMax
        end
        function item:setCondition(v)
            state.condition = v
        end
    end
    if spec.usedDelta ~= nil then
        function item:getUsedDelta()
            return state.usedDelta
        end
        function item:setUsedDelta(v)
            state.usedDelta = v
        end
    end
    if spec.age ~= nil or spec.hungChange ~= nil then
        function item:getAge()
            return state.age
        end
        function item:setAge(v)
            state.age = v
        end
        function item:getHungChange()
            return state.hungChange
        end
        function item:setHungChange(v)
            state.hungChange = v
        end
    end

    function item:isCustomName()
        return state.customName == true
    end
    function item:getName()
        return state.name
    end
    function item:setName(v)
        state.name = v
    end
    function item:setCustomName(v)
        state.customName = v
    end

    function item:isFavorite()
        return state.favorite == true
    end
    function item:setFavorite(v)
        state.favorite = v
    end

    function item:isCustomColor()
        return state.color ~= nil
    end
    function item:getColorRed()
        return state.color and state.color.r
    end
    function item:getColorGreen()
        return state.color and state.color.g
    end
    function item:getColorBlue()
        return state.color and state.color.b
    end
    function item:setColorRed(v)
        state.color = state.color or {}
        state.color.r = v
    end
    function item:setColorGreen(v)
        state.color = state.color or {}
        state.color.g = v
    end
    function item:setColorBlue(v)
        state.color = state.color or {}
        state.color.b = v
    end
    function item:setCustomColor()
    end

    function item:isCustomWeight()
        return state.customWeight == true
    end
    function item:getActualWeight()
        return state.weight
    end
    function item:setActualWeight(v)
        state.weight = v
    end
    function item:setCustomWeight(v)
        state.customWeight = v
    end

    return item
end

-- What CreateItem hands back: a blank item of that type, with every method a
-- real one has, so restore can set whatever it wants. Blank on purpose --
-- a test that starts from a populated item proves nothing about restore.
local CREATE_SHAPE = {
    ["Base.Axe"] = {
        conditionMax = 10
    },
    ["Base.Nails"] = {},
    ["Base.WaterBottle"] = {
        usedDelta = 0
    },
    ["Base.Steak"] = {
        age = 0,
        hungChange = 0
    },
    ["Base.Hat"] = {
        conditionMax = 10
    }
}

_G.InventoryItemFactory = {
    CreateItem = function(fullType)
        if not KNOWN[fullType] then
            return nil
        end
        local shape = {}
        for k, v in pairs(CREATE_SHAPE[fullType] or {}) do
            shape[k] = v
        end
        shape.fullType = fullType
        if shape.conditionMax then
            shape.condition = shape.conditionMax
        end
        return makeItem(shape)
    end
}

local Snapshot = require "PhleaMarket/item_snapshot"

harness.strip()

---------------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(label, condition, detail)
    if condition then
        passed = passed + 1
        print("  ok    " .. label)
    else
        failed = failed + 1
        print("  FAIL  " .. label .. (detail and ("  <- " .. detail) or ""))
    end
end

--- Capture, then restore, then capture again. Two snapshots of the same item
--- either side of a round trip should be identical; anything that differs is
--- something the round trip lost or invented.
local function roundTrip(item)
    local before = Snapshot.capture(item)
    local rebuilt = Snapshot.restore(before)
    local after = rebuilt and Snapshot.capture(rebuilt)
    return before, rebuilt, after
end

local function sameSnapshot(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false, "not both tables"
    end
    local function compare(x, y, path)
        for k, v in pairs(x) do
            local w = y[k]
            if type(v) == "table" then
                if type(w) ~= "table" then
                    return false, path .. k .. " lost"
                end
                local sub, why = compare(v, w, path .. k .. ".")
                if not sub then
                    return false, why
                end
            elseif v ~= w then
                return false, path .. k .. ": " .. tostring(v) .. " -> " .. tostring(w)
            end
        end
        return true
    end
    local okA, whyA = compare(a, b, "")
    if not okA then
        return false, whyA
    end
    return compare(b, a, "")
end

---------------------------------------------------------------------------

print("-- the exploit this module exists to prevent --")
do
    -- The reverted AuctionHouse stored only the item type. A ruined axe listed
    -- and collected came back new, which turns the machine into a repair bench.
    local ruined = makeItem({
        fullType = "Base.Axe",
        condition = 1,
        conditionMax = 10
    })
    local _, rebuilt = roundTrip(ruined)
    ok("a ruined axe comes back ruined", rebuilt and rebuilt._state.condition == 1,
        rebuilt and tostring(rebuilt._state.condition) or "no item")
    ok("and not at full condition", rebuilt and rebuilt._state.condition ~= 10)
end

print("-- round trip keeps everything --")
do
    local item = makeItem({
        fullType = "Base.Axe",
        condition = 7,
        conditionMax = 10,
        name = "Chopper",
        customName = true,
        favorite = true,
        color = {
            r = 0.5,
            g = 0.25,
            b = 1
        },
        weight = 3.5,
        customWeight = true,
        modData = {
            kills = 12,
            owner = "steve",
            flag = true
        }
    })
    local before, rebuilt, after = roundTrip(item)
    ok("restores to an item", rebuilt ~= nil)
    local same, why = sameSnapshot(before, after)
    ok("snapshot survives the round trip unchanged", same, why)
    ok("condition", rebuilt and rebuilt._state.condition == 7)
    ok("custom name", rebuilt and rebuilt._state.name == "Chopper")
    ok("name is flagged as the player's own", rebuilt and rebuilt._state.customName == true)
    ok("favourite", rebuilt and rebuilt._state.favorite == true)
    ok("colour", rebuilt and rebuilt._state.color and rebuilt._state.color.r == 0.5)
    ok("weight", rebuilt and rebuilt._state.weight == 3.5)
    ok("mod data", rebuilt and rebuilt._state.modData.kills == 12 and rebuilt._state.modData.owner == "steve")
end

print("-- drainables and food --")
do
    local bottle = makeItem({
        fullType = "Base.WaterBottle",
        usedDelta = 0.75
    })
    local _, rebuilt = roundTrip(bottle)
    ok("a part-empty bottle comes back part-empty", rebuilt and rebuilt._state.usedDelta == 0.75)

    local steak = makeItem({
        fullType = "Base.Steak",
        age = 40,
        hungChange = -12
    })
    local _, rebuiltSteak = roundTrip(steak)
    ok("an old steak comes back old", rebuiltSteak and rebuiltSteak._state.age == 40,
        rebuiltSteak and tostring(rebuiltSteak._state.age) or "no item")
    ok("with its nutrition", rebuiltSteak and rebuiltSteak._state.hungChange == -12)
end

print("-- properties an item does not have --")
do
    local nails = makeItem({
        fullType = "Base.Nails"
    })
    local snap = Snapshot.capture(nails)
    ok("no condition is recorded for something that has none", snap.condition == nil)
    ok("no drainable charge", snap.usedDelta == nil)
    ok("no food age", snap.age == nil)
    ok("empty mod data is not stored", snap.modData == nil)
    ok("but the type always is", snap.fullType == "Base.Nails")
    ok("and the version", snap.v == Snapshot.VERSION)
end

print("-- a name nobody typed --")
do
    -- Every item has a name. Storing the default one would restore a "custom"
    -- name onto an item that never had one.
    local plain = makeItem({
        fullType = "Base.Axe",
        conditionMax = 10,
        condition = 10,
        name = "Axe",
        customName = false
    })
    ok("the default name is not captured", Snapshot.capture(plain).name == nil)
end

print("-- condition when the maximum has moved --")
do
    -- A mod update changes an axe's maximum condition between listing and
    -- collection. Half-worn should come back half-worn.
    local snap = {
        v = 1,
        fullType = "Base.Axe",
        condition = 5,
        conditionMax = 10
    }
    CREATE_SHAPE["Base.Axe"].conditionMax = 20
    local rebuilt = Snapshot.restore(snap)
    ok("condition is rescaled, not carried across literally", rebuilt and rebuilt._state.condition == 10,
        rebuilt and tostring(rebuilt._state.condition) or "no item")

    -- And the other way: a maximum that shrank must not leave an item above it.
    CREATE_SHAPE["Base.Axe"].conditionMax = 4
    local shrunk = Snapshot.restore({
        v = 1,
        fullType = "Base.Axe",
        condition = 10,
        conditionMax = 10
    })
    ok("and never exceeds the new maximum", shrunk and shrunk._state.condition <= 4,
        shrunk and tostring(shrunk._state.condition) or "no item")

    CREATE_SHAPE["Base.Axe"].conditionMax = 10
end

print("-- an item type the game no longer has --")
do
    -- A server drops a mod while something of its is sitting in escrow.
    local snap = {
        v = 1,
        fullType = "SomeMod.Thing",
        condition = 5,
        conditionMax = 10
    }
    ok("restore returns nothing rather than erroring", Snapshot.restore(snap) == nil)
    ok("and does not throw", pcall(Snapshot.restore, snap))
end

print("-- rubbish in --")
do
    ok("capture of nil", Snapshot.capture(nil) == nil)
    ok("capture of a table that is not an item", Snapshot.capture({}) == nil)
    ok("restore of nil", Snapshot.restore(nil) == nil)
    ok("restore of a table with no type", Snapshot.restore({
        v = 1
    }) == nil)
    ok("restore of an empty type", Snapshot.restore({
        fullType = ""
    }) == nil)
    ok("restore of a string", Snapshot.restore("Base.Axe") == nil)
end

print("-- mod data that cannot be stored --")
do
    local item = makeItem({
        fullType = "Base.Axe",
        conditionMax = 10,
        condition = 10,
        modData = {
            keep = "yes",
            count = 3,
            flag = false,
            dropMe = function()
            end,
            nested = {
                deep = "also kept"
            }
        }
    })
    local snap = Snapshot.capture(item)
    ok("strings survive", snap.modData.keep == "yes")
    ok("numbers survive", snap.modData.count == 3)
    ok("false survives, rather than being read as absent", snap.modData.flag == false)
    ok("nested tables survive", snap.modData.nested and snap.modData.nested.deep == "also kept")
    -- A function cannot be written to ModData and cannot survive a restart, so
    -- carrying it would make a snapshot that works until the server bounces.
    ok("functions are dropped", snap.modData.dropMe == nil)
end

print("-- mod data that would break the JSON mirror --")
do
    local weird = {}
    weird[true] = "boolean key"
    weird["fine"] = "string key"
    weird[3] = "number key"
    local item = makeItem({
        fullType = "Base.Nails",
        modData = weird
    })
    local snap = Snapshot.capture(item)
    ok("string keys survive", snap.modData.fine == "string key")
    ok("number keys survive", snap.modData[3] == "number key")
    ok("keys JSON cannot hold are dropped", snap.modData[true] == nil)
end

print("-- mod data that contains itself --")
do
    -- Nothing stops another mod building a cycle. Without a guard this hangs
    -- the server on the first attempt to list such an item.
    local cyclic = {
        name = "loop"
    }
    cyclic.self = cyclic
    local item = makeItem({
        fullType = "Base.Nails",
        modData = cyclic
    })
    local done = false
    local okCall = pcall(function()
        local snap = Snapshot.capture(item)
        done = snap ~= nil and snap.modData.name == "loop"
    end)
    ok("capture completes rather than recursing forever", okCall and done)
end

print("-- an item whose methods throw --")
do
    -- A half-uninstalled mod can leave an item type whose methods error. One
    -- bad item should cost its own listing, not the whole market.
    local hostile = makeItem({
        fullType = "Base.Axe",
        conditionMax = 10,
        condition = 5
    })
    hostile.getCondition = function()
        error("boom")
    end
    local okCall, snap = pcall(Snapshot.capture, hostile)
    ok("capture survives a throwing getter", okCall)
    ok("and still records the type", okCall and snap and snap.fullType == "Base.Axe")
end

print("-- stackable: would a buyer tell two apart --")
do
    ok("plain nails stack", Snapshot.isStackable(makeItem({
        fullType = "Base.Nails"
    })) == true)

    ok("an axe does not, it has condition", Snapshot.isStackable(makeItem({
        fullType = "Base.Axe",
        condition = 10,
        conditionMax = 10
    })) == false)

    ok("a bottle does not, it has a charge", Snapshot.isStackable(makeItem({
        fullType = "Base.WaterBottle",
        usedDelta = 0
    })) == false)

    ok("a steak does not, it has an age", Snapshot.isStackable(makeItem({
        fullType = "Base.Steak",
        age = 0,
        hungChange = -10
    })) == false)

    ok("nails someone named do not", Snapshot.isStackable(makeItem({
        fullType = "Base.Nails",
        name = "Lucky",
        customName = true
    })) == false)

    ok("nails carrying mod data do not", Snapshot.isStackable(makeItem({
        fullType = "Base.Nails",
        modData = {
            enchanted = true
        }
    })) == false)

    ok("a favourite does not", Snapshot.isStackable(makeItem({
        fullType = "Base.Nails",
        favorite = true
    })) == false)

    ok("nil is not stackable", Snapshot.isStackable(nil) == false)
    ok("and neither is a snapshot of nothing", Snapshot.isStackableSnapshot(nil) == false)
end

print("-- a full-condition item is still not stackable --")
do
    -- Tempting to treat "condition equals maximum" as interchangeable. It is
    -- not: the buyer sees a condition bar, and two items that both happen to be
    -- pristine today are still two items whose condition can diverge.
    ok("a pristine hat does not stack", Snapshot.isStackable(makeItem({
        fullType = "Base.Hat",
        condition = 10,
        conditionMax = 10
    })) == false)
end

---------------------------------------------------------------------------

print("")
print("passed: " .. passed .. "  failed: " .. failed)
if failed > 0 then
    os.exit(1)
end
