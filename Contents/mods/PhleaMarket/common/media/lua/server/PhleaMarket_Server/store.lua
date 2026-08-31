if isClient() then
    return
end

-- The half of the market that actually acts.
--
-- listings.lua decides: it says what a sale comes to and who is owed what, over
-- plain tables, and can be tested without the game. This is the other half --
-- the part that reads ModData, moves money, creates items and puts them in
-- somebody's bag. It is deliberately thin, because everything it does is a
-- thing that cannot be tested offline, and the less of that there is the
-- better.
--
-- The ordering rule that matters, and the reason buy() reads the way it does:
-- build the goods, take the money, hand them over, and only then write the
-- sale down. Every step before the last can fail and leave nothing changed.

require "PhleaMarket/core"
require "PhleaMarket/commands"

local Core = PhunMart
local Market = PhleaMarket
local Listings = require "PhleaMarket/listings"
local Snapshot = require "PhleaMarket/item_snapshot"

local Store = {}
Market.store = Store

-- ModData and nothing else.
--
-- No file mirror, deliberately. PhunMart used to write player data to files
-- beside the mod and moved it into ModData precisely because a file has the
-- install's lifetime and the data has the save's: a wiped world inherited the
-- previous one's balances, and two saves on one machine shared a history.
-- Listings are player data in every sense that matters -- somebody's axe is in
-- here -- so they belong to the save that produced them.
Store.KEY = "PhleaMarket_Listings"

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

local data

--- The store, loaded on first use.
---
--- Indices are rebuilt here rather than persisted, so what a save carries is
--- only ever the listings themselves and an index can never come back
--- disagreeing with them.
function Store.get()
    if data then
        return data
    end
    data = ModData.getOrCreate(Store.KEY)

    -- A fresh save hands back an empty table rather than a store, so fill in
    -- whatever a store is expected to have. Field by field rather than
    -- replacing it wholesale: this table is held by reference by ModData, and
    -- handing back a different one would leave the save writing to the old.
    local blank = Listings.newStore()
    for key, value in pairs(blank) do
        if data[key] == nil then
            data[key] = value
        end
    end
    Listings.rebuildIndices(data)

    Market.debugLn("store loaded: " .. Store.countActive() .. " active listings")
    return data
end

--- ModData is written when the save is, so there is nothing to flush. This
--- exists so the call sites read as though there were, and so there is one
--- place to add a write if that ever stops being true.
function Store.save()
    return true
end

function Store.countActive()
    local n = 0
    for _ in pairs(Listings.rebuildIndices(Store.get()).active) do
        n = n + 1
    end
    return n
end

---------------------------------------------------------------------------
-- Settings, resolved once per call
---------------------------------------------------------------------------

local DURATIONS = {
    short = {
        hours = "DurationShortHours",
        default = 24,
        mult = nil
    },
    medium = {
        hours = "DurationMediumHours",
        default = 72,
        mult = "DurationMediumMult",
        multDefault = 2
    },
    long = {
        hours = "DurationLongHours",
        default = 168,
        mult = "DurationLongMult",
        multDefault = 4
    }
}

--- Hours and fee multiplier for a duration tier. Falls back to medium for
--- anything unrecognised, which is what an out-of-date client would send.
function Store.duration(tier)
    local spec = DURATIONS[tier] or DURATIONS.medium
    local hours = Market.getOption(spec.hours, spec.default)
    local mult = spec.mult and Market.getOption(spec.mult, spec.multDefault) or 1
    return hours, mult
end

--- The commission rules as they stand right now, frozen onto a listing when it
--- goes up so a later change cannot reach back and tax it.
function Store.commissionRule()
    return {
        mode = Market.getOption("CommissionMode", Listings.FEE_PERCENT),
        percent = Market.getOption("CommissionPercent", 5),
        fixed = Market.getOption("CommissionFixed", 25)
    }
end

function Store.listingFeeRule()
    return {
        mode = Market.getOption("ListingFeeMode", Listings.FEE_PERCENT),
        percent = Market.getOption("ListingFeePercent", 2),
        fixed = Market.getOption("ListingFeeFixed", 0)
    }
end

function Store.limits()
    return {
        maxListings = Market.getOption("MaxListings", 10),
        maxQty = Market.getOption("MaxStackQty", 100),
        minPrice = Market.getOption("MinPrice", 5),
        maxPrice = Market.getOption("MaxPrice", 9999)
    }
end

function Store.feePool()
    return Market.getOption("FeePool", "change")
end

function Store.now()
    return GameTime:getInstance():getWorldAgeHours()
end

function Store.log(entry)
    entry.at = entry.at or Store.now()
    Listings.record(Store.get(), Market.getOption("LogEntries", 2000), entry)
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

--- Credit a pool without going past its ceiling, and say what would not fit.
---
--- This is what stops the market being a way around ChangeCapCents. The coin
--- pickup path (wallet:adjust) already clamps and refuses a coin that will not
--- fit; adjustByPool, which is what the reward actions call, adds the raw
--- number with no cap check at all. Pay sale proceeds in through that and two
--- players passing one item back and forth can lift a balance as high as they
--- like, which makes every earn rate in PhunMart meaningless, since all of them
--- are set against that ceiling actually holding.
---
--- So: pay what fits, hand back the rest for the caller to park in the seller's
--- returns. They spend down and collect the remainder.
function Store.creditCapped(username, pool, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return 0, 0
    end
    -- Wallet calls take a username as readily as a player object, which is what
    -- lets an offline seller be paid. Singleplayer files every wallet under one
    -- fixed key regardless, so the name only has to be right in multiplayer.
    local key = username
    local cap = Core.wallet:getCap(pool)
    local paid = amount
    if cap then
        local balance = Core.wallet:getBalance(key, pool) or 0
        local room = cap - balance
        if room <= 0 then
            return 0, amount
        end
        if paid > room then
            paid = room
        end
    end
    if paid > 0 then
        Core.wallet:adjustByPool(key, "current", pool, paid)
    end
    return paid, amount - paid
end

--- Take money from a player, or say it could not be taken.
function Store.charge(playerObj, pool, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return true
    end
    if (Core.wallet:getBalance(playerObj, pool) or 0) < amount then
        return false
    end
    Core.wallet:adjustByPool(playerObj, "current", pool, -amount)
    return true
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

--- Build `qty` copies of a snapshot and put them in a player's bag.
---
--- All or nothing: every item is created before any is handed over, so a type
--- the game no longer has fails the whole delivery rather than giving somebody
--- three of the five nails they paid for.
function Store.deliver(playerObj, snapshot, qty)
    qty = math.floor(tonumber(qty) or 1)
    if qty < 1 then
        return false
    end
    local built = {}
    for _ = 1, qty do
        local item = Snapshot.restore(snapshot)
        if not item then
            return false
        end
        table.insert(built, item)
    end
    local inv = playerObj:getInventory()
    for _, item in ipairs(built) do
        inv:AddItem(item)
        sendAddItemToContainer(inv, item)
    end
    return true
end

--- Take the item being listed out of the seller's hands.
---
--- Returns the snapshot taken, so the caller has the record of exactly what
--- left. Nothing is removed unless enough of it was found, so a seller cannot
--- lose four nails to a listing of five that was refused.
function Store.escrow(playerObj, fullType, qty)
    qty = math.floor(tonumber(qty) or 1)
    local inv = playerObj:getInventory()

    local found = {}
    local item = inv:getFirstTypeRecurse(fullType)
    if not item then
        return nil, "NotHeld"
    end
    local snapshot = Snapshot.capture(item)
    if not snapshot then
        return nil, "NotListable"
    end

    -- Gather before removing. getItemCountRecurse counts what is there; taking
    -- them one at a time and finding the fifth missing would leave four already
    -- gone with no listing to show for it.
    if qty > 1 then
        if (inv:getItemCountRecurse(fullType) or 0) < qty then
            return nil, "NotEnough"
        end
    end

    for _ = 1, qty do
        -- Not named `next`: mod code does not get the global of that name in
        -- B42.20.4, and shadowing it invites reaching for it by habit.
        local nextItem = inv:getFirstTypeRecurse(fullType)
        if not nextItem then
            -- Put back whatever was taken. Should be unreachable given the
            -- count above, but an inventory is not ours alone and being wrong
            -- here costs somebody their gear.
            for _, taken in ipairs(found) do
                inv:AddItem(taken)
                sendAddItemToContainer(inv, taken)
            end
            return nil, "NotEnough"
        end
        local container = nextItem:getContainer() or inv
        container:Remove(nextItem)
        sendRemoveItemFromContainer(container, nextItem)
        table.insert(found, nextItem)
    end

    return snapshot
end

---------------------------------------------------------------------------
-- Talking back
---------------------------------------------------------------------------

--- Answer a player.
---
--- sendServerCommand is a no-op in singleplayer, so a reply sent that way there
--- is simply lost. The client listens on an event instead, and this decides
--- which of the two it is.
function Store.respond(playerObj, command, payload)
    if Core.isLocal then
        triggerEvent(Market.events.OnResult, command, payload)
    else
        sendServerCommand(playerObj, Market.module, command, payload or {})
    end
end

return Store
