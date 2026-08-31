-- Covers listings: the store, the arithmetic, and the ordering rules.
--
-- This module decides and does not act, which is exactly why it can be tested
-- like this. Everything below is the market's money and its fairness rules
-- worked out against plain tables: partial sales, commission on a part of a
-- listing, expiry returning only what is left, and the two sort orders that
-- decide whose listing sells first.
--
-- The failures worth catching here are arithmetic ones. They do not throw --
-- they quietly pay somebody the wrong amount, which nobody notices until a
-- player adds it up.
--
-- Run: luajit test_listings.lua   (or run.cmd, which runs all of them)

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = arg[1] or (here .. "/../..")
package.path = here .. "/?.lua;" .. package.path

local harness = require "harness"

local shared = root .. "/Contents/mods/PhleaMarket/common/media/lua/shared"
package.path = shared .. "/?.lua;" .. package.path

harness.installGlobals()

local L = require "PhleaMarket/listings"

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

local PERCENT_5 = {
    mode = L.FEE_PERCENT,
    percent = 5
}

--- A listing with everything defaulted, so a test states only what it is about.
local function list(store, over)
    over = over or {}
    return L.create(store, {
        seller = over.seller or "steve",
        sellerChar = over.sellerChar or "Steve Miller",
        snapshot = over.snapshot or {
            fullType = over.fullType or "Base.Nails"
        },
        fullType = over.fullType or "Base.Nails",
        itemName = over.itemName or "Nails",
        qty = over.qty or 1,
        unitPrice = over.unitPrice or {
            pool = "change",
            amount = over.amount or 100
        },
        duration = over.duration or "medium",
        durationHours = over.durationHours or 72,
        listingFee = over.listingFee or 0,
        commission = over.commission or PERCENT_5,
        nowHours = over.nowHours or 1000,
        limits = over.limits
    })
end

local function countActive(store)
    local n = 0
    for _ in pairs(L.rebuildIndices(store).active) do
        n = n + 1
    end
    return n
end

---------------------------------------------------------------------------

print("-- creating --")
do
    local store = L.newStore()
    local listing = list(store, {
        amount = 250
    })
    ok("returns the listing", listing ~= nil)
    ok("is active", listing.status == L.STATUS.ACTIVE)
    ok("expires at listedAt plus the duration", listing.expiresAt == 1072)
    ok("records what was listed as well as what is left", listing.qtyListed == 1 and listing.qty == 1)
    ok("is findable by id", L.get(store, listing.id) == listing)
    ok("counts against the seller", L.countActiveFor(store, "steve") == 1)
    ok("and not against anyone else", L.countActiveFor(store, "dave") == 0)
end

print("-- ids are never reused --")
do
    local store = L.newStore()
    local a = list(store)
    store.listings[a.id] = nil
    local b = list(store)
    ok("a deleted listing's id does not come round again", a.id ~= b.id, a.id .. " / " .. b.id)
end

print("-- what create refuses --")
do
    local store = L.newStore()
    local _, why = L.create(store, {})
    ok("no seller", why == "NoSeller")

    _, why = L.create(store, {
        seller = "steve"
    })
    ok("no item", why == "NoItem")

    _, why = list(store, {
        amount = 1,
        limits = {
            minPrice = 5
        }
    })
    ok("under the price floor", why == "PriceTooLow")

    _, why = list(store, {
        amount = 100000,
        limits = {
            maxPrice = 9999
        }
    })
    ok("over the price ceiling", why == "PriceTooHigh")

    _, why = list(store, {
        qty = 500,
        limits = {
            maxQty = 100
        }
    })
    ok("over the stack cap", why == "TooMany")

    _, why = list(store, {
        qty = 0
    })
    ok("a quantity of nothing", why == "BadQuantity")

    _, why = list(store, {
        durationHours = 0
    })
    ok("no duration", why == "BadDuration")

    ok("and none of it created anything", countActive(store) == 0)
end

print("-- the listing limit is per account --")
do
    local store = L.newStore()
    local limits = {
        maxListings = 2
    }
    list(store, {
        limits = limits
    })
    list(store, {
        limits = limits
    })
    local _, why = list(store, {
        limits = limits
    })
    ok("a third is refused", why == "TooManyListings")

    -- A different character on the same account is the same account.
    _, why = list(store, {
        sellerChar = "A New Survivor",
        limits = limits
    })
    ok("and a new character does not get a fresh allowance", why == "TooManyListings")

    ok("but another player is unaffected", list(store, {
        seller = "dave",
        limits = limits
    }) ~= nil)
end

print("-- a cancelled listing frees a slot --")
do
    local store = L.newStore()
    local limits = {
        maxListings = 1
    }
    local first = list(store, {
        limits = limits
    })
    ok("the second is refused", select(2, list(store, {
        limits = limits
    })) == "TooManyListings")
    L.cancel(store, first.id, "steve")
    ok("and allowed once the first is cancelled", list(store, {
        limits = limits
    }) ~= nil)
end

print("-- fees --")
do
    ok("five percent of 1000", L.applyFee(PERCENT_5, 1000) == 50)
    ok("rounds down, in the player's favour", L.applyFee(PERCENT_5, 99) == 4)
    ok("zero percent is free", L.applyFee({
        mode = L.FEE_PERCENT,
        percent = 0
    }, 1000) == 0)
    ok("a fixed fee is flat", L.applyFee({
        mode = L.FEE_FIXED,
        fixed = 25
    }, 1000) == 25)
    -- A flat fee larger than the sale would owe the seller money.
    ok("a fixed fee never exceeds the sale", L.applyFee({
        mode = L.FEE_FIXED,
        fixed = 500
    }, 100) == 100)
    ok("a percentage never exceeds the sale", L.applyFee({
        mode = L.FEE_PERCENT,
        percent = 200
    }, 100) == 100)
    ok("no fee at all", L.applyFee(nil, 1000) == 0)
end

print("-- buying the whole thing --")
do
    local store = L.newStore()
    local listing = list(store, {
        amount = 200
    })
    local sale = L.buy(store, listing.id, "dave", 1, 1010)
    ok("returns a settlement", sale ~= nil)
    ok("gross", sale.gross == 200)
    ok("commission is five percent", sale.commission == 10)
    ok("the seller nets the rest", sale.net == 190)
    ok("names the seller to pay", sale.seller == "steve")
    ok("carries the item to hand over", sale.snapshot ~= nil)
    ok("sold out", sale.soldOut == true)
    ok("the listing is marked sold", listing.status == L.STATUS.SOLD)
    ok("and is no longer active", countActive(store) == 0)
end

print("-- buying part of a stack --")
do
    local store = L.newStore()
    local listing = list(store, {
        qty = 50,
        amount = 10,
        limits = {
            maxQty = 100
        }
    })
    local sale = L.buy(store, listing.id, "dave", 12, 1010)
    ok("charges for twelve", sale.gross == 120)
    ok("commission is on the part sold, not the whole listing", sale.commission == 6)
    ok("seller nets 114", sale.net == 114)
    ok("thirty-eight are left", listing.qty == 38)
    ok("the listing is still active", listing.status == L.STATUS.ACTIVE)
    ok("and not marked sold out", sale.soldOut == false)

    local rest = L.buy(store, listing.id, "dave", 38, 1011)
    ok("the rest empties it", rest.qty == 38 and listing.status == L.STATUS.SOLD)
end

print("-- asking for more than is left --")
do
    -- Two buyers, one stack. The loser should not simply fail: they should get
    -- what remains, which is what a person means by "I'll take twelve".
    local store = L.newStore()
    local listing = list(store, {
        qty = 8,
        amount = 10,
        limits = {
            maxQty = 100
        }
    })
    local sale = L.buy(store, listing.id, "dave", 12, 1010)
    ok("buys what is there", sale.qty == 8)
    ok("and charges only for that", sale.gross == 80)
    ok("leaving it sold out", listing.status == L.STATUS.SOLD)

    local nothing, why = L.buy(store, listing.id, "erin", 1, 1011)
    ok("the next buyer is told it is gone", nothing == nil and why == "NotActive", tostring(why))
end

print("-- buying your own --")
do
    local store = L.newStore()
    local listing = list(store)
    local sale = L.buy(store, listing.id, "steve", 1, 1010)
    ok("is allowed", sale ~= nil)
    -- Allowed because with proceeds credited through a capped path it cannot
    -- inflate anything: it is a strictly worse Cancel, paying commission to get
    -- your own item back. But it must never count as a market price.
    ok("and flagged, so price history can leave it out", sale.selfPurchase == true)

    local store2 = L.newStore()
    local other = list(store2)
    ok("an ordinary sale is not flagged", L.buy(store2, other.id, "dave", 1, 1010).selfPurchase == false)
end

print("-- what buy refuses --")
do
    local store = L.newStore()
    local listing = list(store)
    ok("an id that does not exist", select(2, L.buy(store, "pm_99999", "dave", 1, 1000)) == "NotFound")
    ok("no buyer", select(2, L.buy(store, listing.id, nil, 1, 1000)) == "NoBuyer")
    ok("a quantity of nothing", select(2, L.buy(store, listing.id, "dave", 0, 1000)) == "BadQuantity")
    ok("and the listing is untouched", listing.qty == 1 and listing.status == L.STATUS.ACTIVE)
end

print("-- cancelling --")
do
    local store = L.newStore()
    local listing = list(store, {
        qty = 10,
        limits = {
            maxQty = 100
        }
    })
    L.buy(store, listing.id, "dave", 4, 1010)
    local returned = L.cancel(store, listing.id, "steve")
    ok("returns what was left, not what was listed", returned.qty == 6)
    ok("the listing is cancelled", listing.status == L.STATUS.CANCELLED)
    ok("it waits in the seller's returns", #L.peekReturns(store, "steve").items == 1)

    ok("somebody else cannot cancel it", select(2, L.cancel(store, listing.id, "dave")) == "NotActive")
end

print("-- an admin pulling a listing --")
do
    local store = L.newStore()
    local listing = list(store)
    ok("is refused without force", select(2, L.cancel(store, listing.id, "admin")) == "NotYours")

    local returned = L.cancel(store, listing.id, "admin", true)
    ok("and allowed with it", returned ~= nil)
    -- Removing something from sale, not confiscating it.
    ok("the goods go back to the seller, not the admin", #L.peekReturns(store, "steve").items == 1)
    ok("and nothing to the admin", #L.peekReturns(store, "admin").items == 0)
    ok("recorded as an admin action", returned.reason == L.REASON.ADMIN)
end

print("-- expiry --")
do
    local store = L.newStore()
    local soon = list(store, {
        nowHours = 1000,
        durationHours = 10
    })
    local later = list(store, {
        nowHours = 1000,
        durationHours = 100
    })

    local expired = L.expireDue(store, 1005)
    ok("nothing expires early", #expired == 0)

    expired = L.expireDue(store, 1010)
    ok("expires on the hour it is due, not after it", #expired == 1)
    ok("the right one", expired[1].id == soon.id)
    ok("marked expired", soon.status == L.STATUS.EXPIRED)
    ok("the other is untouched", later.status == L.STATUS.ACTIVE)
    ok("the goods are waiting for the seller", #L.peekReturns(store, "steve").items == 1)

    -- Sweeping again finds nothing: the expired one is no longer active, and
    -- the other is not due until 1100. An expiry that fired twice would queue
    -- the seller's goods to them twice, which is how a market prints items.
    ok("and it does not expire twice", #L.expireDue(store, 1020) == 0)
    ok("nor duplicate the return", #L.peekReturns(store, "steve").items == 1)
end

print("-- expiry returns only what is left --")
do
    local store = L.newStore()
    local listing = list(store, {
        qty = 10,
        nowHours = 1000,
        durationHours = 10,
        limits = {
            maxQty = 100
        }
    })
    L.buy(store, listing.id, "dave", 7, 1005)
    L.expireDue(store, 1010)
    local items = L.peekReturns(store, "steve").items
    ok("three come back, not ten", items[1] and items[1].qty == 3, items[1] and tostring(items[1].qty))
    -- qty is zero by the time expireDue returns, so the amount that actually
    -- went back is kept separately. The ledger records this, and a ledger that
    -- says every expiry returned nothing is a ledger nobody can settle an
    -- argument with.
    ok("and the listing says how much went back", listing.returned == 3, tostring(listing.returned))
end

print("-- a listing that sold out has nothing to return --")
do
    local store = L.newStore()
    local listing = list(store, {
        nowHours = 1000,
        durationHours = 10
    })
    L.buy(store, listing.id, "dave", 1, 1005)
    L.expireDue(store, 1010)
    ok("no phantom return is queued", #L.peekReturns(store, "steve").items == 0)
end

print("-- listings nobody made --")
do
    -- A simulated listing browses and sells exactly like any other. The two
    -- differences are absences: no wallet behind the name to pay, and nothing
    -- to hand back when it expires.
    local store = L.newStore()
    local fake = L.create(store, {
        seller = "npc:4821",
        sellerChar = "Hazel Sizemore",
        snapshot = {
            fullType = "Base.Axe"
        },
        fullType = "Base.Axe",
        itemName = "Axe",
        qty = 1,
        unitPrice = {
            pool = "change",
            amount = 300
        },
        durationHours = 24,
        commission = PERCENT_5,
        nowHours = 1000,
        simulated = true
    })
    ok("is created like any other", fake ~= nil and fake.status == L.STATUS.ACTIVE)
    ok("and is marked", fake.simulated == true)

    -- Browsing must not tell them apart, or the filter and the price guide
    -- would quietly disagree with the grid.
    ok("appears in the summary", #L.summarise(store) == 1)
    ok("and counts towards the price guide", L.priceGuide(store, "Base.Axe").count == 1)

    local sale = L.buy(store, fake.id, "dave", 1, 1005)
    ok("sells normally", sale ~= nil and sale.gross == 300)
    ok("commission still applies", sale.commission == 15)
    -- The caller needs to know there is nobody to pay. The buyer still pays:
    -- the money leaves the economy, which is what buying from a stranger who
    -- wandered off ought to do.
    ok("the settlement says nobody is owed", sale.simulated == true)

    local real = L.newStore()
    local mine = list(real)
    ok("an ordinary sale is not flagged", L.buy(real, mine.id, "dave", 1, 1005).simulated == false)
end

print("-- a simulated listing expiring --")
do
    local store = L.newStore()
    L.create(store, {
        seller = "npc:99",
        snapshot = {
            fullType = "Base.Axe"
        },
        fullType = "Base.Axe",
        qty = 3,
        unitPrice = {
            pool = "change",
            amount = 100
        },
        durationHours = 10,
        commission = PERCENT_5,
        nowHours = 1000,
        simulated = true
    })

    local expired = L.expireDue(store, 1010)
    ok("expires", #expired == 1)
    -- The whole point: no returns queue accumulating under a survivor who will
    -- never walk up to a machine to empty it.
    ok("queues nothing for a seller who does not exist", #L.peekReturns(store, "npc:99").items == 0)
    ok("and says nothing went back", expired[1].returned == 0)

    -- A real listing beside it still returns, so the skip is about the flag
    -- rather than about expiry.
    local both = L.newStore()
    list(both, {
        nowHours = 1000,
        durationHours = 10
    })
    L.expireDue(both, 1010)
    ok("a real one still returns its goods", #L.peekReturns(both, "steve").items == 1)
end

print("-- credits, and the wallet cap --")
do
    -- The market must not become a way around ChangeCapCents. Proceeds that do
    -- not fit wait here rather than being pushed into a full balance.
    local store = L.newStore()
    L.addCredit(store, "steve", "change", 400, L.REASON.WALLET_FULL, "pm_00001", 1000)
    local credits = L.peekReturns(store, "steve").credits
    ok("waits to be collected", #credits == 1 and credits[1].amount == 400)
    ok("with its reason", credits[1].reason == L.REASON.WALLET_FULL)
    ok("nothing is credited for zero", select(2, L.addCredit(store, "steve", "change", 0)) == "NothingToCredit")
    ok("nor for a negative amount", select(2, L.addCredit(store, "steve", "change", -50)) == "NothingToCredit")
end

print("-- collecting --")
do
    local store = L.newStore()
    L.addReturn(store, "steve", {
        snapshot = {
            fullType = "Base.Axe"
        },
        qty = 1
    })
    L.addCredit(store, "steve", "change", 400, L.REASON.SALE, nil, 1000)

    local items, credits = L.takeReturns(store, "steve")
    ok("hands back the items", #items == 1)
    ok("and the credits", #credits == 1)
    ok("the queue is empty afterwards", #L.peekReturns(store, "steve").items == 0)

    -- The caller puts back what it could not deliver -- an inventory too full
    -- for an axe -- which is why take hands over the entries themselves.
    L.addReturn(store, "steve", items[1])
    ok("and something undeliverable can go back", #L.peekReturns(store, "steve").items == 1)
end

print("-- purging --")
do
    local store = L.newStore()
    local sold = list(store, {
        nowHours = 1000,
        durationHours = 10
    })
    L.buy(store, sold.id, "dave", 1, 1001)
    local live = list(store, {
        nowHours = 1000,
        durationHours = 1000
    })

    local dropped = L.purge(store, 1100, {
        completedAfterHours = 168
    })
    ok("a recently completed listing stays", dropped == 0)

    dropped = L.purge(store, 1200, {
        completedAfterHours = 168
    })
    ok("an old one goes", dropped == 1)
    ok("the active one is left alone", L.get(store, live.id) ~= nil)
end

print("-- returns nobody came back for --")
do
    local store = L.newStore()
    L.addReturn(store, "steve", {
        snapshot = {},
        qty = 1,
        at = 1000
    })
    L.addCredit(store, "steve", "change", 100, L.REASON.SALE, nil, 1000)

    local _, abandoned = L.purge(store, 1100, {
        returnsAfterHours = 336
    })
    ok("waits while it is fresh", abandoned == 0)

    _, abandoned = L.purge(store, 1400, {
        returnsAfterHours = 336
    })
    ok("both go once abandoned", abandoned == 2)
    ok("and the empty queue goes with them", store.returns["steve"] == nil)
end

print("-- the ledger is a ring --")
do
    local store = L.newStore()
    for i = 1, 10 do
        L.record(store, 5, {
            event = L.EVENT.LIST,
            n = i
        })
    end
    ok("never grows past the cap", #store.log == 5)
    ok("keeps the newest", store.log[5].n == 10)
    ok("and drops the oldest", store.log[1].n == 6)

    L.record(store, 0, {
        event = L.EVENT.LIST
    })
    ok("a cap of zero turns it off", #store.log == 0)
end

print("-- browsing: one row per item type --")
do
    local store = L.newStore()
    list(store, {
        fullType = "Base.Nails",
        itemName = "Nails",
        amount = 10,
        qty = 50,
        limits = {
            maxQty = 100
        }
    })
    list(store, {
        seller = "dave",
        fullType = "Base.Nails",
        itemName = "Nails",
        amount = 4,
        qty = 20,
        limits = {
            maxQty = 100
        }
    })
    list(store, {
        fullType = "Base.Axe",
        itemName = "Axe",
        amount = 500
    })

    local rows = L.summarise(store)
    ok("two types from three listings", #rows == 2)
    ok("alphabetical, so a tile keeps its place between visits", rows[1].fullType == "Base.Axe")

    local nails = rows[2]
    ok("shows the cheapest asking price", nails.low == 4)
    ok("how many listings", nails.listings == 2)
    ok("and how many are available across them", nails.available == 70)
end

print("-- cheapest first, then oldest first --")
do
    local store = L.newStore()
    local dear = list(store, {
        amount = 50,
        nowHours = 1000
    })
    local newCheap = list(store, {
        seller = "dave",
        amount = 10,
        nowHours = 2000
    })
    local oldCheap = list(store, {
        seller = "erin",
        amount = 10,
        nowHours = 1500
    })

    local order = L.forItem(store, "Base.Nails")
    -- The tiebreak is the fair one: two sellers asking the same price are
    -- served in the order they listed, so nobody loses a sale to somebody who
    -- turned up later and undercut by nothing.
    ok("cheapest first", order[1].id == oldCheap.id, order[1].id)
    ok("then the later listing at the same price", order[2].id == newCheap.id)
    ok("then the dearer one", order[3].id == dear.id)
end

print("-- what the market is asking --")
do
    local store = L.newStore()
    for _, amount in ipairs({10, 30, 20}) do
        list(store, {
            seller = "s" .. amount,
            amount = amount
        })
    end
    local guide = L.priceGuide(store, "Base.Nails")
    ok("low", guide.low == 10)
    ok("high", guide.high == 30)
    ok("median of three", guide.median == 20)
    ok("and says how many it speaks for", guide.count == 3)

    list(store, {
        seller = "s40",
        amount = 40
    })
    ok("median of four averages the middle pair", L.priceGuide(store, "Base.Nails").median == 25)

    ok("nothing listed, nothing to say", L.priceGuide(store, "Base.Saw") == nil)
end

print("-- indices are rebuilt, never carried --")
do
    -- A save holds listings, not indices. One rebuilt on load cannot disagree
    -- with the data; one persisted alongside it eventually does.
    local store = L.newStore()
    local listing = list(store)
    store.index = nil
    ok("a store with no index still answers", L.countActiveFor(store, "steve") == 1)
    ok("and finds the listing", #L.forItem(store, "Base.Nails") == 1)

    -- A deliberately wrong index is discarded rather than trusted.
    store.index = {
        active = {},
        bySeller = {},
        byItem = {}
    }
    L.rebuildIndices(store)
    ok("a stale index is corrected by a rebuild", L.countActiveFor(store, "steve") == 1)
    ok("the listing survived all that", L.get(store, listing.id).status == L.STATUS.ACTIVE)
end

---------------------------------------------------------------------------

print("")
print("passed: " .. passed .. "  failed: " .. failed)
if failed > 0 then
    os.exit(1)
end
