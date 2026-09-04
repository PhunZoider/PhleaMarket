-- The listing store: what is for sale, who owes whom, and what is owed back.
--
-- Pure table work, deliberately. Nothing here reads ModData, touches a wallet,
-- removes an item from an inventory or sends a command. It decides; the server
-- layer above it does. A buy returns a description of what must happen -- take
-- this much from the buyer, credit the seller that much, hand over this item --
-- and the caller carries it out and says whether it worked.
--
-- That split is worth the indirection twice over. It makes the whole of the
-- market's arithmetic testable without launching the game, which is where the
-- mistakes that matter live: a commission taken twice, a partial sale crediting
-- the full amount, an expiry that returns an item already sold. And it keeps
-- the ordering rules honest, because a function that cannot move money cannot
-- move it before checking whether it should.
--
-- The one rule the callers must keep: the store is only ever changed through
-- these functions, and a call that returns an error has changed nothing.

local Listings = {}

Listings.STATUS = {
    ACTIVE = "ACTIVE",
    SOLD = "SOLD",
    EXPIRED = "EXPIRED",
    CANCELLED = "CANCELLED"
}

Listings.REASON = {
    EXPIRED = "expired",
    CANCELLED = "cancelled",
    SALE = "sale",
    WALLET_FULL = "wallet_full",
    ADMIN = "admin"
}

Listings.EVENT = {
    LIST = "LIST",
    BUY = "BUY",
    CANCEL = "CANCEL",
    EXPIRE = "EXPIRE",
    COLLECT = "COLLECT",
    ADMIN_CANCEL = "ADMIN_CANCEL",
    ADMIN_EDIT = "ADMIN_EDIT"
}

--- Bumped when the stored shape changes in a way an older save would not
--- survive. Written onto the store so a migration can tell what it is holding.
Listings.VERSION = 1

---------------------------------------------------------------------------
-- The store
---------------------------------------------------------------------------

--- An empty store.
---
--- `listings` is keyed by id rather than being an array, because every lookup
--- in the market is by id and the ones that are not go through an index. The
--- indices are not stored: they are rebuilt on load, so a save can never carry
--- an index that disagrees with the listings it points at.
function Listings.newStore()
    return {
        v = Listings.VERSION,
        nextId = 1,
        listings = {},
        returns = {},
        log = {},
        -- What each account last asked for each item type. Small, and it
        -- outlives the listing it came from, which is the point: the useful
        -- default when selling a second axe is what you asked for the first.
        asks = {}
    }
end

local function pad(n)
    local s = tostring(n)
    while #s < 5 do
        s = "0" .. s
    end
    return s
end

--- Take the next id. Never reused, including across a listing being deleted,
--- because ids appear in the ledger and a reused one would make two unrelated
--- transactions look like the same listing.
local function takeId(store)
    local n = store.nextId or 1
    store.nextId = n + 1
    return "pm_" .. pad(n)
end

--- Rebuild the lookups that are not persisted.
---
--- Called on load and after anything that changes a listing's status. Cheap
--- enough to do wholesale: a busy server holds hundreds of listings, not
--- millions, and a rebuilt index cannot drift from the data the way an
--- incrementally maintained one can.
function Listings.rebuildIndices(store)
    local active, bySeller, byItem = {}, {}, {}
    for id, listing in pairs(store.listings or {}) do
        listing.id = listing.id or id
        if listing.status == Listings.STATUS.ACTIVE then
            active[id] = listing
            local seller = listing.seller
            if seller then
                bySeller[seller] = bySeller[seller] or {}
                bySeller[seller][id] = listing
            end
            local fullType = listing.fullType
            if fullType then
                byItem[fullType] = byItem[fullType] or {}
                byItem[fullType][id] = listing
            end
        end
    end
    store.index = {
        active = active,
        bySeller = bySeller,
        byItem = byItem
    }
    return store.index
end

local function indices(store)
    if not store.index then
        Listings.rebuildIndices(store)
    end
    return store.index
end

function Listings.get(store, id)
    return store.listings and store.listings[id] or nil
end

--- How many listings this account has up. Counted per account rather than per
--- character, so a new survivor does not arrive with a fresh allowance.
function Listings.countActiveFor(store, seller)
    local bySeller = indices(store).bySeller[seller]
    if not bySeller then
        return 0
    end
    local n = 0
    for _ in pairs(bySeller) do
        n = n + 1
    end
    return n
end

---------------------------------------------------------------------------
-- The ledger
---------------------------------------------------------------------------

--- Record something that happened. A ring buffer: the oldest entry goes when
--- the cap is reached, because this is the one structure here that would
--- otherwise grow for the life of the save.
---
--- A cap of zero turns it off entirely, which is a legitimate thing for a
--- server that does not want the overhead and will never adjudicate a dispute.
function Listings.record(store, cap, entry)
    cap = tonumber(cap) or 0
    if cap <= 0 then
        store.log = {}
        return
    end
    store.log = store.log or {}
    table.insert(store.log, entry)
    while #store.log > cap do
        table.remove(store.log, 1)
    end
end

---------------------------------------------------------------------------
-- Fees
--
-- Both fees are frozen onto the listing when it goes up, rather than read from
-- the settings at the moment they are charged. A seller sees their exact
-- take-home before confirming, and an admin who changes the commission cannot
-- retroactively tax something already on the shelf.
---------------------------------------------------------------------------

Listings.FEE_PERCENT = 1
Listings.FEE_FIXED = 2

--- The same, unrounded.
---
--- Only worth having because the listing fee multiplies by a duration tier
--- after the rule has been applied. Rounding first throws the fraction away and
--- the multiplier then has nothing left to scale: two percent of a forty five
--- cent listing floors to zero, and zero times four is still zero, so short,
--- medium and long all cost the same nothing. Holding the fraction until the
--- single rounding at the end is what makes the tiers mean anything on a cheap
--- listing, and it is what keeps a percentage worth having at all once an
--- amount is counted in something coarser than cents.
function Listings.feeValue(fee, amount)
    if type(fee) ~= "table" then
        return 0
    end
    if fee.mode == Listings.FEE_FIXED then
        local fixed = tonumber(fee.fixed) or 0
        if fixed < 0 then
            return 0
        end
        return math.min(fixed, amount)
    end
    local percent = tonumber(fee.percent) or 0
    if percent <= 0 then
        return 0
    end
    local value = amount * percent / 100
    if value > amount then
        return amount
    end
    return value
end

--- What a fee frozen at list time comes to on a given amount.
---
--- Percent scales with the sale, so a partial sale pays a partial commission.
--- Fixed is per transaction, not per unit: charging a flat fee fifty times for
--- fifty nails bought at once would cost more than the nails.
---
--- Rounded down, so the rounding always favours the player. Commission is taken
--- straight from this and has nothing applied after it, so this is the one
--- place it rounds.
function Listings.applyFee(fee, amount)
    return math.floor(Listings.feeValue(fee, amount))
end

---------------------------------------------------------------------------
-- Creating a listing
---------------------------------------------------------------------------

--- Put something up for sale.
---
--- `params` carries what the seller chose and what the caller resolved from
--- settings, which is everything this needs: it reads no configuration itself,
--- so a test states the rules rather than arranging for them.
---
---   seller, sellerChar   who
---   snapshot, fullType, itemName   what, already captured
---   qty                  how many, 1 unless the item is interchangeable
---   unitPrice            {kind="currency", pool=..., amount=N}
---   duration             "short" | "medium" | "long"
---   durationHours        resolved from the tier
---   listingFee           already charged by the caller, recorded here
---   commission           {mode=, percent=, fixed=} frozen for this listing
---   nowHours             world age
---   limits               {maxListings=, minPrice=, maxPrice=, maxQty=, step=}
---
--- Returns the listing, or nil plus a reason. Nothing is changed on failure.
function Listings.create(store, params)
    params = params or {}
    local limits = params.limits or {}

    if type(params.seller) ~= "string" or params.seller == "" then
        return nil, "NoSeller"
    end
    if type(params.snapshot) ~= "table" then
        return nil, "NoItem"
    end
    local fullType = params.fullType or params.snapshot.fullType
    if type(fullType) ~= "string" or fullType == "" then
        return nil, "NoItem"
    end

    local price = params.unitPrice
    if type(price) ~= "table" or type(price.amount) ~= "number" then
        return nil, "NoPrice"
    end
    -- Snapped before the range is checked rather than after, so the figure the
    -- bounds are judged against is the figure the listing will actually carry.
    -- Snapping afterwards would let a price pass the floor and then be rounded
    -- under it. limits carries the step already aligned to those bounds, so an
    -- amount that survives this is listable as it stands.
    local amount = math.floor(price.amount)
    local step = math.floor(tonumber(limits.step) or 1)
    if step > 1 then
        amount = math.floor(amount / step) * step
    end
    if limits.minPrice and amount < limits.minPrice then
        return nil, "PriceTooLow"
    end
    if limits.maxPrice and amount > limits.maxPrice then
        return nil, "PriceTooHigh"
    end

    local qty = math.floor(tonumber(params.qty) or 1)
    if qty < 1 then
        return nil, "BadQuantity"
    end
    if qty > 1 and limits.maxQty and qty > limits.maxQty then
        return nil, "TooMany"
    end

    if limits.maxListings and Listings.countActiveFor(store, params.seller) >= limits.maxListings then
        return nil, "TooManyListings"
    end

    local now = tonumber(params.nowHours) or 0
    local hours = tonumber(params.durationHours) or 0
    if hours <= 0 then
        return nil, "BadDuration"
    end

    local id = takeId(store)
    local listing = {
        id = id,
        seller = params.seller,
        sellerChar = params.sellerChar,
        snapshot = params.snapshot,
        fullType = fullType,
        itemName = params.itemName or fullType,
        qty = qty,
        qtyListed = qty,
        unitPrice = {
            kind = "currency",
            pool = price.pool or "change",
            amount = amount
        },
        duration = params.duration,
        listingFee = tonumber(params.listingFee) or 0,
        commission = params.commission,
        listedAt = now,
        expiresAt = now + hours,
        status = Listings.STATUS.ACTIVE,
        -- A listing nobody really made. Everything about browsing and buying
        -- one is identical; what differs is that there is no seller behind it
        -- to pay, and nothing to hand back when it expires.
        simulated = params.simulated == true or nil
    }

    store.listings[id] = listing
    Listings.rebuildIndices(store)
    return listing
end

---------------------------------------------------------------------------
-- Buying
---------------------------------------------------------------------------

--- What a purchase would come to, without doing it.
---
--- Separate from buy so the window can show a total before the player commits,
--- and so buy has one place to get the arithmetic from rather than two that can
--- disagree.
function Listings.quote(listing, qty)
    if type(listing) ~= "table" then
        return nil, "NotFound"
    end
    if listing.status ~= Listings.STATUS.ACTIVE then
        return nil, "NotActive"
    end
    qty = math.floor(tonumber(qty) or 1)
    if qty < 1 then
        return nil, "BadQuantity"
    end
    -- Clamped rather than refused. Asking for twelve when eight remain buys
    -- eight and says so, which is what a person means by it and avoids a race
    -- between two buyers failing outright.
    if qty > listing.qty then
        qty = listing.qty
    end
    if qty < 1 then
        return nil, "SoldOut"
    end

    local gross = listing.unitPrice.amount * qty
    local commission = Listings.applyFee(listing.commission, gross)
    return {
        qty = qty,
        unit = listing.unitPrice.amount,
        pool = listing.unitPrice.pool,
        gross = gross,
        commission = commission,
        net = gross - commission
    }
end

--- Sell part or all of a listing.
---
--- Returns a settlement describing what the caller must now do, and does not
--- assume any of it succeeded: the caller charges the buyer first and only
--- calls this once the money is actually taken. Ordering matters and belongs to
--- the caller, because only the caller can fail.
---
--- `qty` is clamped to what remains. The settlement says how many were actually
--- bought, which is not always what was asked for.
function Listings.buy(store, id, buyer, qty, nowHours)
    local listing = Listings.get(store, id)
    local quote, why = Listings.quote(listing, qty)
    if not quote then
        return nil, why
    end
    if type(buyer) ~= "string" or buyer == "" then
        return nil, "NoBuyer"
    end

    listing.qty = listing.qty - quote.qty
    if listing.qty <= 0 then
        listing.status = Listings.STATUS.SOLD
        listing.soldAt = tonumber(nowHours) or 0
    end
    Listings.rebuildIndices(store)

    return {
        listingId = id,
        seller = listing.seller,
        buyer = buyer,
        fullType = listing.fullType,
        itemName = listing.itemName,
        snapshot = listing.snapshot,
        qty = quote.qty,
        pool = quote.pool,
        gross = quote.gross,
        commission = quote.commission,
        net = quote.net,
        -- True when this emptied the listing, so the caller knows whether the
        -- seller has anything left on the shelf without re-reading it.
        soldOut = listing.status == Listings.STATUS.SOLD,
        -- Carried so the caller knows not to look for a wallet to pay into.
        simulated = listing.simulated == true,
        -- A seller buying their own listing is allowed: with proceeds credited
        -- through a capped path it cannot inflate anything, and it is a strictly
        -- worse Cancel, since they pay commission to get their own item back.
        -- Flagged so price history can leave it out -- counting it would let a
        -- player manufacture the market rate everyone else is shown.
        selfPurchase = buyer == listing.seller
    }
end

---------------------------------------------------------------------------
-- Cancelling and expiring
---------------------------------------------------------------------------

--- Take a listing down. `by` must be the seller unless `force`, which is the
--- admin path and is recorded as such.
function Listings.cancel(store, id, by, force)
    local listing = Listings.get(store, id)
    if not listing then
        return nil, "NotFound"
    end
    if listing.status ~= Listings.STATUS.ACTIVE then
        return nil, "NotActive"
    end
    if not force and listing.seller ~= by then
        return nil, "NotYours"
    end

    listing.status = Listings.STATUS.CANCELLED
    local remaining = listing.qty
    listing.qty = 0
    Listings.rebuildIndices(store)

    -- The remainder goes back to the seller, never to whoever cancelled it. An
    -- admin pulling a listing is removing it from sale, not confiscating it.
    return Listings.addReturn(store, listing.seller, {
        snapshot = listing.snapshot,
        fullType = listing.fullType,
        itemName = listing.itemName,
        qty = remaining,
        unitPrice = listing.unitPrice,
        listingId = id,
        reason = force and Listings.REASON.ADMIN or Listings.REASON.CANCELLED
    })
end

--- Every listing whose time is up. Marks them expired and moves what is left
--- to the seller's returns, handing back the list so the caller can notify.
function Listings.expireDue(store, nowHours)
    local now = tonumber(nowHours) or 0
    local expired = {}
    for id, listing in pairs(store.listings or {}) do
        if listing.status == Listings.STATUS.ACTIVE and (listing.expiresAt or 0) <= now then
            listing.status = Listings.STATUS.EXPIRED
            local remaining = listing.qty
            listing.qty = 0
            -- Kept because qty is about to be zero and the caller wants to
            -- record how much actually went back: a listing that sold most of
            -- its stack returns the remainder, not what it started with.
            listing.returned = remaining

            -- A listing nobody made has nobody to hand anything back to. It
            -- simply goes, rather than filling a returns queue under a name
            -- that will never walk up to a machine to empty it.
            if listing.simulated then
                listing.returned = 0
            else
                Listings.addReturn(store, listing.seller, {
                    snapshot = listing.snapshot,
                    fullType = listing.fullType,
                    itemName = listing.itemName,
                    qty = remaining,
                    unitPrice = listing.unitPrice,
                    listingId = id,
                    reason = Listings.REASON.EXPIRED
                })
            end
            table.insert(expired, listing)
        end
    end
    if #expired > 0 then
        Listings.rebuildIndices(store)
    end
    return expired
end

--- Drop simulated listings priced in something the market no longer trades in.
---
--- A currency change leaves everything already on the shelf quoting the old
--- money. For a listing a player made that is correct and deliberate: they
--- asked for two dollars fifty and are owed two dollars fifty, and the pool
--- stamped on the listing is exactly what makes honouring that possible. Those
--- stay, and are paid in what they were listed in until they sell or expire.
---
--- A simulated one owes nobody anything. Leaving it means a market half priced
--- in a currency the server no longer uses, for as long as three days, which
--- reads as the currency change having silently failed. So they go, and the
--- next tick stocks the shelf again at the new prices.
---
--- Only active ones. A sold or expired simulated listing is a finished record
--- that purge clears on its own schedule, and reaching back into history to
--- delete rows is not this function's business.
---
--- Returns how many went.
function Listings.dropSimulatedNotIn(store, pool)
    local dropped = 0
    for id, listing in pairs(store.listings or {}) do
        if listing.simulated and listing.status == Listings.STATUS.ACTIVE and
            (listing.unitPrice and listing.unitPrice.pool) ~= pool then
            store.listings[id] = nil
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        Listings.rebuildIndices(store)
    end
    return dropped
end

--- Take everything off the market at once.
---
--- The bulk form of cancel, for an admin clearing the board: after a currency
--- change, before a wipe, or when a market has filled with something that
--- should not be on it. Doing it a row at a time through the ledger is the same
--- work spread over as many confirmations as there are listings.
---
--- Goods go back to their sellers exactly as a single pull does. An admin
--- pulling a listing is removing it from sale, not confiscating it, and that
--- does not stop being true because they pulled a hundred at once.
---
--- Simulated listings are deleted rather than returned. There is no wallet
--- behind the name and nobody who will ever walk up to a machine to empty the
--- queue, so returning them would pile goods under a survivor who does not
--- exist. Same rule expiry already follows.
---
--- Indices are rebuilt once at the end rather than per listing, which is the
--- only reason this is not simply a loop over cancel().
---
--- Returns a summary: how many went back to sellers, how many fake ones were
--- dropped, and the per-seller counts so the caller can say who was affected.
function Listings.cancelAll(store, by, nowHours)
    local now = tonumber(nowHours) or 0
    local cancelled, dropped = 0, 0
    local bySeller = {}

    for id, listing in pairs(store.listings or {}) do
        if listing.status == Listings.STATUS.ACTIVE then
            if listing.simulated then
                store.listings[id] = nil
                dropped = dropped + 1
            else
                listing.status = Listings.STATUS.CANCELLED
                local remaining = listing.qty
                listing.qty = 0

                local ret = Listings.addReturn(store, listing.seller, {
                    snapshot = listing.snapshot,
                    fullType = listing.fullType,
                    itemName = listing.itemName,
                    qty = remaining,
                    unitPrice = listing.unitPrice,
                    listingId = id,
                    reason = Listings.REASON.ADMIN
                })
                if ret then
                    ret.at = now
                end

                cancelled = cancelled + 1
                bySeller[listing.seller] = (bySeller[listing.seller] or 0) + 1
            end
        end
    end

    if cancelled + dropped > 0 then
        Listings.rebuildIndices(store)
    end

    return {
        cancelled = cancelled,
        dropped = dropped,
        sellers = bySeller,
        by = by
    }
end

--- Drop finished listings, and returns nobody came back for.
---
--- Both are needed. Without the first the store carries every completed sale
--- for the life of the save; without the second it carries the gear of every
--- player who stopped playing.
function Listings.purge(store, nowHours, opts)
    opts = opts or {}
    local now = tonumber(nowHours) or 0
    local completedAfter = tonumber(opts.completedAfterHours) or 168
    local returnsAfter = tonumber(opts.returnsAfterHours)

    local dropped = 0
    for id, listing in pairs(store.listings or {}) do
        if listing.status ~= Listings.STATUS.ACTIVE then
            local finished = listing.soldAt or listing.expiresAt or listing.listedAt or 0
            if now - finished >= completedAfter then
                store.listings[id] = nil
                dropped = dropped + 1
            end
        end
    end

    local abandoned = 0
    if returnsAfter and returnsAfter > 0 then
        for username, queue in pairs(store.returns or {}) do
            for _, key in ipairs({"items", "credits"}) do
                local list = queue[key]
                if list then
                    for i = #list, 1, -1 do
                        local at = list[i].at or 0
                        if now - at >= returnsAfter then
                            table.remove(list, i)
                            abandoned = abandoned + 1
                        end
                    end
                end
            end
            if (not queue.items or #queue.items == 0) and (not queue.credits or #queue.credits == 0) then
                store.returns[username] = nil
            end
        end
    end

    if dropped > 0 then
        Listings.rebuildIndices(store)
    end
    return dropped, abandoned
end

---------------------------------------------------------------------------
-- Returns
---------------------------------------------------------------------------

local function queueFor(store, username)
    store.returns = store.returns or {}
    if not store.returns[username] then
        store.returns[username] = {
            items = {},
            credits = {}
        }
    end
    return store.returns[username]
end

--- Put an item aside for someone to collect.
function Listings.addReturn(store, username, entry)
    if type(username) ~= "string" or username == "" then
        return nil, "NoOwner"
    end
    if type(entry) ~= "table" or (tonumber(entry.qty) or 0) < 1 then
        -- A listing that sold out entirely has nothing to return, which is not
        -- an error: it is the ordinary end of a successful listing.
        return nil, "NothingToReturn"
    end
    entry.at = entry.at or 0
    table.insert(queueFor(store, username).items, entry)
    return entry
end

--- Put money aside for someone to collect.
---
--- This is what stops the market being a way around the wallet cap. Proceeds
--- are credited through a capped path, and whatever will not fit waits here
--- rather than being pushed into a balance that is already at its ceiling. Two
--- players passing one item back and forth could otherwise inflate a balance
--- indefinitely, and every earn rate in PhunMart is calibrated against that
--- ceiling meaning something.
function Listings.addCredit(store, username, pool, amount, reason, listingId, nowHours)
    if type(username) ~= "string" or username == "" then
        return nil, "NoOwner"
    end
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return nil, "NothingToCredit"
    end
    local entry = {
        pool = pool or "change",
        amount = amount,
        reason = reason,
        listingId = listingId,
        at = tonumber(nowHours) or 0
    }
    table.insert(queueFor(store, username).credits, entry)
    return entry
end

--- What is waiting for someone, without taking it.
function Listings.peekReturns(store, username)
    local queue = store.returns and store.returns[username]
    if not queue then
        return {
            items = {},
            credits = {}
        }
    end
    return queue
end

--- Hand everything back.
---
--- Empties the queue and returns what was in it, so the caller can grant the
--- items and credit the money. The caller is expected to put back anything it
--- could not deliver -- an inventory too full for an axe -- through addReturn,
--- which is why this returns the entries rather than a summary.
function Listings.takeReturns(store, username)
    local queue = store.returns and store.returns[username]
    if not queue then
        return {}, {}
    end
    local items, credits = queue.items or {}, queue.credits or {}
    store.returns[username] = nil
    return items, credits
end

---------------------------------------------------------------------------
-- Browsing
---------------------------------------------------------------------------

--- One row per item type, which is what the Buy grid shows.
---
--- Grouping is what makes the browse affordable and the search instant: a
--- thousand listings might be sixty distinct types, and sixty rows is nothing
--- to send or to filter on the client.
function Listings.summarise(store)
    local rows = {}
    for fullType, listings in pairs(indices(store).byItem) do
        local low, count, total, name
        for _, listing in pairs(listings) do
            local unit = listing.unitPrice.amount
            if not low or unit < low then
                low = unit
            end
            count = (count or 0) + 1
            total = (total or 0) + listing.qty
            name = name or listing.itemName
        end
        if count then
            table.insert(rows, {
                fullType = fullType,
                itemName = name,
                low = low,
                listings = count,
                available = total
            })
        end
    end
    table.sort(rows, function(a, b)
        return (a.itemName or a.fullType) < (b.itemName or b.fullType)
    end)
    return rows
end

--- The listings under one item type, cheapest first and then oldest first.
---
--- That tiebreak is the fair one and the one sellers expect: two people asking
--- the same price are served in the order they listed, so nobody loses a sale
--- to somebody who arrived later and undercut by nothing.
function Listings.forItem(store, fullType)
    local out = {}
    for _, listing in pairs(indices(store).byItem[fullType] or {}) do
        table.insert(out, listing)
    end
    table.sort(out, function(a, b)
        if a.unitPrice.amount ~= b.unitPrice.amount then
            return a.unitPrice.amount < b.unitPrice.amount
        end
        if a.listedAt ~= b.listedAt then
            return a.listedAt < b.listedAt
        end
        return a.id < b.id
    end)
    return out
end

--- What the market is asking for this item: low, median, high and a count.
---
--- Derived rather than stored, so it cannot go stale, and honest about a thin
--- market because it says how many listings it is speaking for.
function Listings.priceGuide(store, fullType)
    local prices = {}
    for _, listing in pairs(indices(store).byItem[fullType] or {}) do
        table.insert(prices, listing.unitPrice.amount)
    end
    if #prices == 0 then
        return nil
    end
    table.sort(prices)
    local mid = math.floor((#prices + 1) / 2)
    local median = prices[mid]
    if #prices % 2 == 0 then
        median = math.floor((prices[mid] + prices[mid + 1]) / 2)
    end
    return {
        low = prices[1],
        high = prices[#prices],
        median = median,
        count = #prices
    }
end

---------------------------------------------------------------------------
-- Telling a seller what happened while they were out
---------------------------------------------------------------------------

--- The most recent sales a seller has not been told about yet.
---
--- Capped, and the cap drops the oldest rather than refusing the newest: a
--- player away for a month wants to hear about this week, not about the first
--- thing that sold and then nothing. `missed` counts what fell off, so the
--- summary can say there were more than it is naming.
Listings.MAX_NOTICES = 20

function Listings.addNotice(store, username, entry)
    if type(username) ~= "string" or username == "" or type(entry) ~= "table" then
        return
    end
    store.notices = store.notices or {}
    local mine = store.notices[username]
    if not mine then
        mine = {
            items = {},
            missed = 0
        }
        store.notices[username] = mine
    end
    table.insert(mine.items, entry)
    while #mine.items > Listings.MAX_NOTICES do
        table.remove(mine.items, 1)
        mine.missed = (mine.missed or 0) + 1
    end
end

--- Hand over what a seller has not heard, and forget it.
---
--- Taken rather than read, because the next thing the caller does is show it,
--- and a notice shown twice is worse than one shown late.
function Listings.takeNotices(store, username)
    local mine = store.notices and store.notices[username]
    if not mine then
        return {}, 0
    end
    store.notices[username] = nil
    return mine.items or {}, mine.missed or 0
end

---------------------------------------------------------------------------
-- What to ask for it
---------------------------------------------------------------------------

--- Remember what somebody asked, so the next one of these starts there.
---
--- Kept per account rather than per character, like everything else here: it is
--- the person who learns what a hammer goes for, not the survivor.
function Listings.rememberAsk(store, seller, fullType, amount)
    if type(seller) ~= "string" or type(fullType) ~= "string" then
        return
    end
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return
    end
    store.asks = store.asks or {}
    store.asks[seller] = store.asks[seller] or {}
    store.asks[seller][fullType] = amount
end

function Listings.lastAsk(store, seller, fullType)
    local mine = store.asks and store.asks[seller]
    return mine and mine[fullType] or nil
end

--- What this item type has actually changed hands for, most recent first.
---
--- Read back out of the ledger rather than kept as its own list. The ledger is
--- already the record of every sale, already capped, and already persisted; a
--- second store of the same numbers is a second thing to keep in step.
---
--- Self-purchases are left out. Buying your own listing is allowed and is a
--- strictly worse Cancel, but counting it here would let a player set the
--- reference price everyone else is shown by trading with themselves.
function Listings.soldPrices(store, fullType, limit)
    limit = tonumber(limit) or 5
    local out = {}
    local log = store.log or {}
    for i = #log, 1, -1 do
        local entry = log[i]
        if entry.event == Listings.EVENT.BUY and entry.item == fullType and not entry.selfPurchase and entry.unit then
            table.insert(out, {
                unit = entry.unit,
                qty = entry.qty,
                at = entry.at
            })
            if #out >= limit then
                break
            end
        end
    end
    return out
end

--- Everything worth showing somebody about to name a price: what the market is
--- asking, what it has been paying, and what they asked last time.
function Listings.priceInfo(store, seller, fullType)
    return {
        fullType = fullType,
        guide = Listings.priceGuide(store, fullType),
        sold = Listings.soldPrices(store, fullType, 5),
        lastAsk = Listings.lastAsk(store, seller, fullType)
    }
end

--- Everything one seller has up, newest first.
function Listings.forSeller(store, seller)
    local out = {}
    for _, listing in pairs(indices(store).bySeller[seller] or {}) do
        table.insert(out, listing)
    end
    table.sort(out, function(a, b)
        if a.listedAt ~= b.listedAt then
            return a.listedAt > b.listedAt
        end
        return a.id < b.id
    end)
    return out
end

return Listings
