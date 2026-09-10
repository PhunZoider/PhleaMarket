if isClient() then
    return
end

-- What a player can ask the market to do.
--
-- Every handler here is the same shape: validate, then act in an order where
-- anything that can fail happens before anything that cannot be undone. The
-- store decides the arithmetic; these decide the sequence.

require "PhleaMarket/core"
require "PhleaMarket/commands"

local Core = PhunMart
local Market = PhleaMarket
local Listings = require "PhleaMarket/listings"
local Snapshot = require "PhleaMarket/item_snapshot"
-- Required rather than read off Market: server lua loads alphabetically, so
-- this file loads before store.lua and Market.store is not set yet.
local Store = require "PhleaMarket_Server/store"

local Commands = {}
Market.serverCommands = Commands

local C = Market.commands

local function fail(playerObj, why, extra)
    local payload = extra or {}
    payload.failed = true
    payload.message = why
    Store.respond(playerObj, C.result, payload)
    return nil
end

local function nameOf(playerObj)
    return playerObj:getUsername()
end

local function charNameOf(playerObj)
    local d = playerObj:getDescriptor()
    return d and (d:getForename() .. " " .. d:getSurname()) or nil
end

---------------------------------------------------------------------------
-- Listing something
---------------------------------------------------------------------------

Commands[C.list] = function(playerObj, args)
    if not Market.isEnabled() then
        return fail(playerObj, "Disabled")
    end
    args = args or {}
    local store = Store.get()

    local fullType = args.fullType
    if type(fullType) ~= "string" or fullType == "" then
        return fail(playerObj, "NoItem")
    end
    if not Market.isListable(fullType) then
        return fail(playerObj, "NotListable")
    end

    local qty = math.floor(tonumber(args.qty) or 1)
    local price = math.floor(tonumber(args.unitPrice) or 0)
    local hours = Store.duration(args.duration)
    local limits = Store.limits()

    -- Snapped to the step here, before the fee is worked out on it. Listings
    -- snaps again when it creates the record, but the fee is charged from this
    -- side beforehand, and charging a percentage of a figure the listing does
    -- not go on to carry is how the dialog's total and the receipt disagree.
    price = Market.snapPrice(price, limits.step)

    -- Bounded here as well as in the dialog. The client clamps what it sends,
    -- but the client is not the authority on anything: a number arriving from
    -- it is a request, and the only figures that matter are the ones this side
    -- checks and the count escrow actually removes.
    if qty < 1 then
        return fail(playerObj, "BadQuantity")
    end
    if limits.maxQty and qty > limits.maxQty then
        qty = limits.maxQty
    end

    -- Check the limit before taking anything out of the seller's bag. Refusing
    -- afterwards would mean handing it straight back, and a failure that
    -- touches the inventory at all is a failure with a way to go wrong.
    if Listings.countActiveFor(store, nameOf(playerObj)) >= limits.maxListings then
        return fail(playerObj, "TooManyListings")
    end
    if price < limits.minPrice then
        return fail(playerObj, "PriceTooLow")
    end
    if price > limits.maxPrice then
        return fail(playerObj, "PriceTooHigh")
    end

    -- The fee is worked out on what is being asked, so the seller has already
    -- been shown this number and agreed to it.
    local askingTotal = price * qty
    local fee = Market.listingFeeFor(askingTotal, args.duration)
    local pool = Store.feePool()
    if fee > 0 and not Store.canPay(playerObj, pool, fee) then
        return fail(playerObj, "CannotAffordFee", {
            fee = fee
        })
    end

    -- Held at all? Whether enough of them are alike enough to travel as one
    -- listing is escrow's question, since it is the one picking which items to
    -- take and by the same rule.
    local held = playerObj:getInventory():getFirstTypeRecurse(fullType)
    if not held then
        return fail(playerObj, "NotHeld")
    end

    local snapshot, taken = Store.escrow(playerObj, fullType, qty)
    if not snapshot then
        return fail(playerObj, taken or "NotHeld")
    end

    -- From here on the listing is about what left the bag, never about what was
    -- asked for. The fee is worked out again on that basis, since it is a share
    -- of the asking total and the asking total just changed.
    qty = taken
    askingTotal = price * qty
    fee = Market.listingFeeFor(askingTotal, args.duration)

    local listing, createFailed = Listings.create(store, {
        seller = nameOf(playerObj),
        sellerChar = charNameOf(playerObj),
        snapshot = snapshot,
        fullType = fullType,
        itemName = held:getName(),
        qty = qty,
        unitPrice = {
            -- Decided here and not taken from the client. What the server calls
            -- money is not a thing a listing gets to name for itself, and a
            -- pool arriving over the wire is a pool somebody chose.
            pool = Market.currencyPool(),
            amount = price
        },
        duration = args.duration,
        durationHours = hours,
        listingFee = fee,
        commission = Store.commissionRule(),
        nowHours = Store.now(),
        limits = limits
    })

    if not listing then
        -- The goods are already out of the bag, so they go back rather than
        -- nowhere. This should be unreachable -- everything create checks was
        -- checked above -- but "should be unreachable" is not a thing to bet
        -- somebody's axe on.
        Store.deliver(playerObj, snapshot, qty)
        return fail(playerObj, createFailed or "CouldNotList")
    end

    -- Charged only now that the listing exists. A fee taken for a listing that
    -- did not happen is the one outcome with no way to explain itself.
    if fee > 0 then
        Store.charge(playerObj, pool, fee)
        Store.syncWallet(playerObj)
    end

    -- Remembered so the next one of these opens at this price rather than at
    -- the floor. Recorded on success only: a price that was refused is not a
    -- price this account decided on.
    Listings.rememberAsk(store, listing.seller, fullType, price)

    Store.log({
        event = Listings.EVENT.LIST,
        actor = listing.seller,
        listing = listing.id,
        item = fullType,
        qty = qty,
        unit = price,
        fee = fee
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "list",
        listingId = listing.id,
        fee = fee,
        expiresAt = listing.expiresAt
    })
end

---------------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------------

Commands[C.buy] = function(playerObj, args)
    if not Market.isEnabled() then
        return fail(playerObj, "Disabled")
    end
    args = args or {}
    local store = Store.get()
    local listing = Listings.get(store, args.listingId)
    if not listing then
        return fail(playerObj, "NotFound")
    end

    local quote, why = Listings.quote(listing, args.qty)
    if not quote then
        return fail(playerObj, why)
    end

    -- Build the goods first. A snapshot of an item type the game no longer has
    -- must fail before anybody's money moves.
    local buildOk = Snapshot.restore(listing.snapshot) ~= nil
    if not buildOk then
        return fail(playerObj, "ItemUnavailable")
    end

    -- Then take the money. Checked and taken in one call, so nothing can spend
    -- it in between.
    if not Store.charge(playerObj, quote.pool, quote.gross) then
        return fail(playerObj, "InsufficientFunds")
    end
    -- Told the moment it is taken, rather than at the end. Everything after
    -- this can still refuse, and each of those paths would otherwise have to
    -- remember to say so; sending here means the client is never left holding a
    -- balance the server has already spent, whichever way the rest goes.
    Store.syncWallet(playerObj)

    -- Then hand it over. If this fails the buyer is refunded: they have paid
    -- for something they did not get, and the listing has not been touched.
    if not Store.deliver(playerObj, listing.snapshot, quote.qty) then
        -- The buyer is standing here, so an item refund goes straight back into
        -- their hands rather than queueing for a collection they did not earn.
        Store.creditCapped(playerObj, quote.pool, quote.gross)
        -- Charged and refunded is usually a round trip to nothing, but not when
        -- the refund meets the ceiling, so the client is told either way.
        Store.syncWallet(playerObj)
        return fail(playerObj, "CouldNotDeliver")
    end

    -- Only now is the sale written down.
    local sale = Listings.buy(store, args.listingId, nameOf(playerObj), quote.qty, Store.now())
    if not sale then
        return fail(playerObj, "NotActive")
    end

    -- And only now is the seller paid. Through the capped path, so the market
    -- cannot be used to lift a balance past the ceiling every earn rate in
    -- PhunMart is set against.
    --
    -- Unless there is nobody to pay. A simulated listing has a name but no
    -- wallet behind it, and crediting one would put money into a record that no
    -- player can ever spend -- harmless, but it would also leave a returns queue
    -- filling up under a survivor who does not exist. The buyer still pays: the
    -- money leaves the economy, which is what a purchase from a stranger who
    -- wandered off should do.
    local paid, held = 0, 0
    if not sale.simulated then
        -- Found once and used for both the money and the message.
        --
        -- The money needs it as much as the notice does. An item currency can
        -- only be counted into the hands of somebody standing here, and this is
        -- how creditCapped is told that somebody is: a name is a seller who is
        -- not. Passing the name unconditionally meant every sale on an item
        -- currency paid out nothing and queued the whole amount, including to a
        -- seller watching it happen. Collect would still have paid it -- that
        -- path hands over a player -- but a market where being present and
        -- being away are the same thing is not what any of this describes.
        local seller = Core.utils.getPlayerByUsername(sale.seller, true)

        paid, held = Store.creditCapped(seller or sale.seller, sale.pool, sale.net)
        if held > 0 then
            Listings.addCredit(store, sale.seller, sale.pool, held, Listings.REASON.WALLET_FULL, sale.listingId,
                Store.now())
        end
        -- Only when they are here to be told. An offline seller's client reads
        -- the server's record at their next login anyway.
        if paid > 0 then
            Store.syncWallet(seller)
        end

        -- Told now if they are here, left for them if they are not.
        --
        -- Something selling is good news and good news is better immediately:
        -- a seller standing at a machine watching their axe go should see it
        -- happen rather than find out at their next login. The queue is for
        -- everyone else.
        --
        -- Not for buying your own listing. They know.
        if not sale.selfPurchase then
            local notice = {
                itemName = sale.itemName or sale.fullType,
                qty = sale.qty,
                net = sale.net,
                held = held,
                at = Store.now()
            }
            if seller then
                Store.respond(seller, C.noticesData, {
                    notices = {notice},
                    missed = 0
                })
            else
                Listings.addNotice(store, sale.seller, notice)
            end
        end
    end

    Store.log({
        event = Listings.EVENT.BUY,
        actor = sale.buyer,
        listing = sale.listingId,
        item = sale.fullType,
        qty = sale.qty,
        unit = quote.unit,
        gross = sale.gross,
        commission = sale.commission,
        net = sale.net,
        paid = paid,
        held = held,
        -- Left out of any price history: counting it would let a player
        -- manufacture the market rate shown to everyone else.
        selfPurchase = sale.selfPurchase
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "buy",
        listingId = sale.listingId,
        qty = sale.qty,
        paid = sale.gross,
        soldOut = sale.soldOut
    })
end

---------------------------------------------------------------------------
-- Cancelling
---------------------------------------------------------------------------

Commands[C.cancel] = function(playerObj, args)
    args = args or {}
    local store = Store.get()
    local returned, why = Listings.cancel(store, args.listingId, nameOf(playerObj))
    if not returned then
        return fail(playerObj, why)
    end
    returned.at = Store.now()

    Store.log({
        event = Listings.EVENT.CANCEL,
        actor = nameOf(playerObj),
        listing = args.listingId,
        item = returned.fullType,
        qty = returned.qty
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "cancel",
        listingId = args.listingId,
        qty = returned.qty
    })
end

---------------------------------------------------------------------------
-- Collecting
---------------------------------------------------------------------------

Commands[C.collect] = function(playerObj, args)
    local store = Store.get()
    local username = nameOf(playerObj)
    local items, credits = Listings.takeReturns(store, username)

    -- Taken from the queue before anything is granted, and put back if the
    -- grant fails. The other order loses somebody an axe to a full bag.
    local deliveredItems, keptBack = 0, 0
    for _, entry in ipairs(items) do
        if Store.deliver(playerObj, entry.snapshot, entry.qty) then
            deliveredItems = deliveredItems + entry.qty
        else
            Listings.addReturn(store, username, entry)
            keptBack = keptBack + 1
        end
    end

    local creditedTotal, stillHeld = 0, 0
    for _, entry in ipairs(credits) do
        local paid, held = Store.creditCapped(playerObj, entry.pool, entry.amount)
        creditedTotal = creditedTotal + paid
        if held > 0 then
            stillHeld = stillHeld + held
            Listings.addCredit(store, username, entry.pool, held, entry.reason, entry.listingId, Store.now())
        end
    end
    -- Once, after the whole queue, rather than once per credit: a seller who
    -- has been at the ceiling all week has a row for every sale, and the client
    -- only ever wants the figure they add up to.
    if creditedTotal > 0 then
        Store.syncWallet(playerObj)
    end

    Store.log({
        event = Listings.EVENT.COLLECT,
        actor = username,
        qty = deliveredItems,
        net = creditedTotal,
        held = stillHeld
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "collect",
        items = deliveredItems,
        credited = creditedTotal,
        -- Named separately so the window can say why something is still there
        -- rather than looking as though collect did nothing.
        keptBack = keptBack,
        stillHeld = stillHeld
    })
end

---------------------------------------------------------------------------
-- Relisting
---------------------------------------------------------------------------

--- Collect one return and put it straight back up, at the price it carried.
Commands[C.relist] = function(playerObj, args)
    args = args or {}
    local store = Store.get()
    local username = nameOf(playerObj)
    local queue = Listings.peekReturns(store, username)
    local index = math.floor(tonumber(args.index) or 0)
    local entry = queue.items and queue.items[index]
    if not entry then
        return fail(playerObj, "NotFound")
    end

    local hours = Store.duration(args.duration)
    local price = math.floor(tonumber(args.unitPrice) or (entry.unitPrice and entry.unitPrice.amount) or 0)
    local limits = Store.limits()
    -- Snapped as a new listing is, since the price carried over from the return
    -- was set under whatever the step was then, and the step may have moved.
    price = Market.snapPrice(price, limits.step)
    if price < limits.minPrice or price > limits.maxPrice then
        return fail(playerObj, "BadPrice")
    end

    local fee = Market.listingFeeFor(price * entry.qty, args.duration)
    local pool = Store.feePool()
    if fee > 0 and not Store.canPay(playerObj, pool, fee) then
        return fail(playerObj, "CannotAffordFee", {
            fee = fee
        })
    end

    local listing, why = Listings.create(store, {
        seller = username,
        sellerChar = charNameOf(playerObj),
        snapshot = entry.snapshot,
        fullType = entry.fullType,
        itemName = entry.itemName,
        qty = entry.qty,
        unitPrice = {
            pool = (entry.unitPrice and entry.unitPrice.pool) or Market.currencyPool(),
            amount = price
        },
        duration = args.duration,
        durationHours = hours,
        listingFee = fee,
        commission = Store.commissionRule(),
        nowHours = Store.now(),
        limits = limits
    })
    if not listing then
        return fail(playerObj, why)
    end

    -- Removed from the queue only once the listing exists, so a refusal leaves
    -- the goods exactly where they were.
    table.remove(queue.items, index)
    if fee > 0 then
        Store.charge(playerObj, pool, fee)
        Store.syncWallet(playerObj)
    end

    Store.log({
        event = Listings.EVENT.LIST,
        actor = username,
        listing = listing.id,
        item = listing.fullType,
        qty = listing.qty,
        unit = price,
        fee = fee,
        relist = true
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "relist",
        listingId = listing.id,
        fee = fee
    })
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

Commands[C.browse] = function(playerObj, args)
    local store = Store.get()

    -- Both shapes, because the window wants both and neither is expensive.
    -- `rows` is one line per item type, which is what a grouped grid and an
    -- instant client-side search need. `listings` is every active listing,
    -- projected, which is what a flat grid renders directly. Active listings
    -- are bounded by the per-account limit times the player count, so this is
    -- hundreds of small rows at worst.
    local listings = {}
    for id, listing in pairs(Listings.rebuildIndices(store).active) do
        table.insert(listings, {
            id = id,
            seller = listing.seller,
            sellerChar = listing.sellerChar,
            fullType = listing.fullType,
            itemName = listing.itemName,
            qty = listing.qty,
            unit = listing.unitPrice.amount,
            pool = listing.unitPrice.pool,
            expiresAt = listing.expiresAt,
            condition = listing.snapshot and listing.snapshot.condition,
            conditionMax = listing.snapshot and listing.snapshot.conditionMax
        })
    end

    -- Chunked on the listings, which is the half that grows with the market.
    -- `rows` is one line per item type, so it can never be the longer of the
    -- two, and it rides along as a header.
    Store.respondChunked(playerObj, C.browseData, {
        rows = Listings.summarise(store),
        listings = listings
    }, "listings")
end

Commands[C.group] = function(playerObj, args)
    args = args or {}
    local store = Store.get()
    local rows = {}
    for _, listing in ipairs(Listings.forItem(store, args.fullType)) do
        table.insert(rows, {
            id = listing.id,
            sellerChar = listing.sellerChar,
            seller = listing.seller,
            itemName = listing.itemName,
            qty = listing.qty,
            unit = listing.unitPrice.amount,
            pool = listing.unitPrice.pool,
            expiresAt = listing.expiresAt,
            -- The buyer needs to see this: with condition preserved, it is the
            -- only thing distinguishing two listings of the same item.
            condition = listing.snapshot and listing.snapshot.condition,
            conditionMax = listing.snapshot and listing.snapshot.conditionMax
        })
    end
    -- The name travels with it: the heading needs one before any tile has been
    -- drawn, and the client would otherwise have only the type.
    local itemName = rows[1] and rows[1].itemName or args.fullType
    Store.respond(playerObj, C.groupData, {
        fullType = args.fullType,
        itemName = itemName,
        rows = rows,
        guide = Listings.priceGuide(store, args.fullType)
    })
end

--- Everything worth knowing before naming a price: what the market is asking,
--- what it has been paying, and what this account asked last time.
--- Anything that happened while this account was away.
---
--- Asked for by the client once it has finished loading, rather than pushed
--- when a player connects: the client is the only side that knows when it is
--- ready to be told, and this way singleplayer and multiplayer take the same
--- path.
Commands[C.catchUp] = function(playerObj, args)
    local store = Store.get()
    local items, missed = Listings.takeNotices(store, nameOf(playerObj))
    if #items == 0 then
        return
    end
    Store.save()
    Store.respond(playerObj, C.noticesData, {
        notices = items,
        missed = missed
    })
end

Commands[C.priceInfo] = function(playerObj, args)
    args = args or {}
    Store.respond(playerObj, C.priceInfoData,
        Listings.priceInfo(Store.get(), nameOf(playerObj), args.fullType))
end

Commands[C.mine] = function(playerObj, args)
    local store = Store.get()
    local username = nameOf(playerObj)
    Store.respond(playerObj, C.mineData, {
        listings = Listings.forSeller(store, username),
        returns = Listings.peekReturns(store, username)
    })
end

---------------------------------------------------------------------------
-- Admin
---------------------------------------------------------------------------

Commands[C.adminList] = function(playerObj, args)
    if not Core.utils.isAdmin(playerObj) then
        return
    end
    local store = Store.get()

    -- Projected rather than sent whole. A listing carries the snapshot of the
    -- item in escrow, mod data and all, and an admin screen showing a name, a
    -- seller and a price has no use for any of it.
    local all = {}
    for _, listing in pairs(store.listings or {}) do
        table.insert(all, {
            id = listing.id,
            seller = listing.seller,
            sellerChar = listing.sellerChar,
            fullType = listing.fullType,
            itemName = listing.itemName,
            qty = listing.qty,
            qtyListed = listing.qtyListed,
            unitPrice = listing.unitPrice,
            status = listing.status,
            listedAt = listing.listedAt,
            expiresAt = listing.expiresAt
        })
    end
    table.sort(all, function(a, b)
        return (a.listedAt or 0) > (b.listedAt or 0)
    end)
    Store.respondChunked(playerObj, C.adminData, {
        listings = all
    }, "listings")
end

Commands[C.adminCancel] = function(playerObj, args)
    if not Core.utils.isAdmin(playerObj) then
        return
    end
    args = args or {}
    local store = Store.get()
    local returned, why = Listings.cancel(store, args.listingId, nameOf(playerObj), true)
    if not returned then
        return fail(playerObj, why)
    end
    returned.at = Store.now()

    Store.log({
        event = Listings.EVENT.ADMIN_CANCEL,
        actor = nameOf(playerObj),
        listing = args.listingId,
        item = returned.fullType,
        qty = returned.qty
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "adminCancel",
        listingId = args.listingId
    })
end

Commands[C.adminCancelAll] = function(playerObj, args)
    if not Core.utils.isAdmin(playerObj) then
        return
    end
    local store = Store.get()
    local result = Listings.cancelAll(store, nameOf(playerObj), Store.now())

    -- One ledger entry rather than one per listing. A hundred rows saying the
    -- same thing at the same second buries whatever else is in the log, and the
    -- thing worth being able to look up later is that somebody cleared the
    -- board and how much was on it.
    Store.log({
        event = Listings.EVENT.ADMIN_CANCEL,
        actor = nameOf(playerObj),
        qty = result.cancelled,
        held = result.dropped
    })
    Store.save()

    Store.respond(playerObj, C.result, {
        ok = true,
        action = "adminCancelAll",
        cancelled = result.cancelled,
        dropped = result.dropped
    })
end

Commands[C.adminLog] = function(playerObj, args)
    if not Core.utils.isAdmin(playerObj) then
        return
    end
    -- The one reply with a configured ceiling rather than a natural one, and an
    -- admin may set that ceiling into the thousands.
    Store.respondChunked(playerObj, C.adminData, {
        log = Store.get().log or {}
    }, "log")
end

return Commands
