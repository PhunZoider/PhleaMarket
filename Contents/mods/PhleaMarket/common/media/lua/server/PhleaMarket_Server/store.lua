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
local Chunk = require "PhleaMarket/chunking"

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

-- Settings live in core, shared with the client so the seller is shown the
-- exact fee the server is about to charge rather than a second calculation of
-- it. Aliased here because the call sites below read better for it.
Store.duration = Market.duration
Store.commissionRule = Market.commissionRule
Store.listingFeeRule = Market.listingFeeRule
Store.limits = Market.limits
Store.feePool = Market.feePool

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
--- Item currency, at the two points it has to be physical.
---
--- An item pool is counted in hundredths of an item so commission has somewhere
--- to keep a fraction. Everything above these three functions works in those
--- hundredths and never has to know; these are where the ledger meets a bag.

--- Every whole one of `item` the player is carrying.
local function countItems(playerObj, item)
    local inv = playerObj and playerObj.getInventory and playerObj:getInventory()
    if not inv then
        return 0
    end
    return inv:getItemCountRecurse(item) or 0
end

--- Take `count` whole items out of a bag. All or nothing.
---
--- Gathered before any is removed, the same rule escrow follows: taking them
--- one at a time and finding the fifth missing leaves four gone with nothing
--- bought. Recursive, because money in a bag inside a bag still spends.
local function takeItems(playerObj, item, count)
    if count <= 0 then
        return true
    end
    local inv = playerObj:getInventory()
    local held = inv:getAllEvalRecurse(function(it)
        return it ~= nil and it.getFullType and it:getFullType() == item
    end, ArrayList.new())

    local picked = {}
    for i = 0, held:size() - 1 do
        table.insert(picked, held:get(i))
        if #picked >= count then
            break
        end
    end
    if #picked < count then
        return false
    end

    for _, it in ipairs(picked) do
        local container = it:getContainer() or inv
        container:Remove(it)
        sendRemoveItemFromContainer(container, it)
    end
    return true
end

--- Put `count` whole items into a bag. Returns how many actually went in.
local function giveItems(playerObj, item, count)
    local inv = playerObj:getInventory()
    local given = 0
    for _ = 1, count do
        local added = inv:AddItem(item)
        if not added then
            break
        end
        sendAddItemToContainer(inv, added)
        given = given + 1
    end
    return given
end

--- Whether a player could pay `amount` from `pool` right now.
---
--- Here rather than at the call sites because an item pool has no wallet
--- balance to read, and a caller asking the wallet directly gets zero and
--- refuses every listing on a server paying in items.
function Store.canPay(playerObj, pool, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return true
    end
    -- Through the shared reader, so the window and the server cannot disagree
    -- about whether somebody can afford this.
    return Market.balanceOf(playerObj, pool) >= amount
end

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
---
--- An item currency uses that same remainder for a different reason. Items can
--- only go into the hands of somebody standing here, and only in whole numbers,
--- so a sale to an offline seller pays nothing and queues all of it, and a
--- collection pays out the whole ones and queues the fraction. Both come back
--- through here at the next collect. That is how a five percent commission on a
--- five item sale is actually taken: a quarter of an item at a time, held until
--- four sales have made a whole one.
function Store.creditCapped(target, pool, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return 0, 0
    end

    local item = Market.poolItem(pool)
    if item then
        -- A username and not a player is a seller who is not here to be handed
        -- anything. Not a failure: the goods already wait in the same queue.
        if type(target) ~= "table" or not target.getInventory then
            return 0, amount
        end
        local whole = math.floor(amount / Market.ITEM_SCALE)
        if whole < 1 then
            return 0, amount
        end
        local paid = giveItems(target, item, whole) * Market.ITEM_SCALE
        return paid, amount - paid
    end

    -- Wallet calls take a username as readily as a player object, which is what
    -- lets an offline seller be paid. Singleplayer files every wallet under one
    -- fixed key regardless, so the name only has to be right in multiplayer.
    local key = target
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

    local item = Market.poolItem(pool)
    if item then
        -- Rounded up, because a fraction of an item cannot be taken out of a
        -- bag and letting it pass free is the exploitable direction. A price is
        -- always whole items so it never lands here; a percentage listing fee
        -- on an item currency can, which is why that fee is meant to be set
        -- fixed. See Docs/GUIDE_ITEM_CURRENCY.md.
        local want = math.ceil(amount / Market.ITEM_SCALE)
        if countItems(playerObj, item) < want then
            return false
        end
        return takeItems(playerObj, item, want)
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

    -- Every item of this type the player is carrying, so the alike ones can be
    -- picked out of them. Recursive, because a listing may be assembled from
    -- what is in a bag as readily as from what is in hand.
    local held = inv:getAllEvalRecurse(function(item)
        return item ~= nil and item.getFullType and item:getFullType() == fullType
    end, ArrayList.new())

    local candidates = {}
    for i = 0, held:size() - 1 do
        table.insert(candidates, held:get(i))
    end
    if #candidates == 0 then
        return nil, "NotHeld"
    end

    local snapshot = Snapshot.capture(candidates[1])
    if not snapshot then
        return nil, "NotListable"
    end

    -- Only the ones that match the snapshot the listing will hold. A stack is
    -- faithful exactly when every item in it would have produced that same
    -- snapshot, so a half-used lighter cannot ride along with four full ones.
    local alike = {}
    for _, item in ipairs(candidates) do
        if Snapshot.equal(snapshot, Snapshot.capture(item)) then
            table.insert(alike, item)
            if #alike >= qty then
                break
            end
        end
    end
    -- Counted before anything is removed. Taking them one at a time and finding
    -- the fifth missing would leave four already gone with no listing to show
    -- for it.
    if #alike < qty then
        return nil, "NotEnough"
    end

    local taken = 0
    for _, item in ipairs(alike) do
        local container = item:getContainer() or inv
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
        taken = taken + 1
    end

    -- How many were actually removed, not how many were asked for.
    --
    -- The listing is built from this. They should always agree -- the count is
    -- checked above before anything moves -- but "should always agree" is how
    -- you get a listing for ten of something when six were taken, and a
    -- cancelled listing hands back what it says it holds. The number that can
    -- be trusted is the one counted while removing them.
    return snapshot, taken
end

---------------------------------------------------------------------------
-- Talking back
---------------------------------------------------------------------------

--- Tell a player's client what their wallet now holds.
---
--- The balance a player reads is drawn from their own client's copy of the
--- wallet, not from the server's. Every PhunMart path that moves a balance
--- server-side pushes the record back afterwards -- a coin pickup, a purchase,
--- an admin edit -- and nothing here ever did. So the money moved and the
--- number on screen did not: a buyer watched their balance sit still through a
--- purchase and reported not being charged, and a seller was only convinced
--- otherwise by the toast. It corrected itself at the next login, which is what
--- kept it looking like a market that does not take money rather than a window
--- that does not update.
---
--- Sent as PhunMart's own getWallet, so its client handler files it the way
--- every other sync is filed and there is nothing to keep in step here.
---
--- Singleplayer shares one table between the two halves, so there is nothing to
--- send and nothing that can be stale.
function Store.syncWallet(playerObj)
    if Core.isLocal then
        return
    end
    if not (playerObj and playerObj.getUsername) then
        return
    end
    sendServerCommand(playerObj, Core.name, Core.commands.getWallet, {
        username = playerObj:getUsername(),
        wallet = Core.wallet:get(playerObj)
    })
end

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

--- Answer a player with a reply whose bulk is one list, cutting it up if it has
--- grown large enough to be worth cutting up.
---
--- `field` names the list. See PhleaMarket/chunking for what goes in a part and
--- how the client puts them back; the point of it being there rather than here
--- is that both ends read the one description.
---
--- Singleplayer never chunks, and neither does anything under the threshold.
--- There is no wire to be too big for locally: the event path hands the same
--- table straight over, so cutting it up would be work with nothing to show.
function Store.respondChunked(playerObj, command, payload, field)
    payload = payload or {}

    if Core.isLocal or not Chunk.needed(payload, field) then
        return Store.respond(playerObj, command, payload)
    end

    Chunk.split(payload, field, Chunk.SIZE, function(part)
        sendServerCommand(playerObj, Market.module, command, part)
    end)
end

return Store
