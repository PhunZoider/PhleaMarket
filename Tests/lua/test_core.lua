-- Covers core: what a typed figure means, and what the price limits allow.
--
-- The unit a number is in is the thing this file exists to pin down. A price is
-- stored in the pool's own units -- cents, on the change pool -- while every
-- figure a player types or reads is dollars. That conversion has exactly one
-- place to live, and getting it wrong by a factor of a hundred does not throw:
-- it lists a hundred dollar rifle for a dollar, and nobody finds out until the
-- market has been emptied by whoever noticed first.
--
-- Run: luajit test_core.lua   (or run.cmd, which runs all of them)

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = arg[1] or (here .. "/../..")
package.path = here .. "/?.lua;" .. package.path

local harness = require "harness"

local shared = root .. "/Contents/mods/PhleaMarket/common/media/lua/shared"
package.path = shared .. "/?.lua;" .. package.path

harness.installGlobals()

-- core.lua refuses to load without PhunMart, and registers itself with two of
-- its lists on the way past. Stood up as the least that lets it load: a wallet
-- holding the two pools PhunMart ships, so the cents question has both of its
-- answers available, plus the two lists it appends to.
_G.PhunMart = {
    defaultPaths = {
        shops = {}
    },
    shopDefPassthrough = {},
    wallet = {
        pools = {
            change = {
                label = "Change",
                format = "cents"
            },
            tokens = {
                label = "Tokens",
                format = "count"
            }
        }
    }
}

local Market = require "PhleaMarket/core"

harness.strip()

---------------------------------------------------------------------------

local passed, failed = 0, 0
local function ok(label, cond, detail)
    if cond then
        passed = passed + 1
        print("  ok    " .. label)
    else
        failed = failed + 1
        print("  FAIL  " .. label .. (detail and ("  <- " .. detail) or ""))
    end
end

--- Set the sandbox to exactly these options and nothing else, so each test
--- states the whole of what it depends on.
local function options(tbl)
    harness.sandbox = {}
    for name, value in pairs(tbl or {}) do
        harness.sandbox["PhleaMarket." .. name] = value
    end
end

---------------------------------------------------------------------------

print("-- a typed figure is dollars, a stored one is cents --")
do
    ok("a whole number is dollars, not cents", Market.parseAmount("change", "105") == 10500,
        tostring(Market.parseAmount("change", "105")))
    ok("which is the whole point: 105 does not mean a dollar five", Market.parseAmount("change", "105") ~= 105)
    ok("a dollar", Market.parseAmount("change", "1") == 100)
    ok("dollars and cents", Market.parseAmount("change", "12.50") == 1250)

    -- 12.37 times a hundred comes out of the float unit as 1236.9999999999998,
    -- and truncating there takes a cent off every price carrying an odd one.
    ok("a figure the float unit cannot hold exactly", Market.parseAmount("change", "12.37") == 1237,
        tostring(Market.parseAmount("change", "12.37")))
    ok("and another", Market.parseAmount("change", "0.29") == 29, tostring(Market.parseAmount("change", "0.29")))

    ok("a fraction of a cent rounds to the nearest", Market.parseAmount("change", "0.014") == 1)
    ok("nothing is nothing", Market.parseAmount("change", "0") == 0)

    -- A pool counted in whole units takes whole units. Nothing is scaled, or a
    -- server pricing in tokens would find every figure multiplied by a hundred.
    ok("a counted pool is untouched", Market.parseAmount("tokens", "105") == 105)
    ok("and a pool nobody has defined is treated as counted", Market.parseAmount("nosuchpool", "105") == 105)

    ok("letters are not a price", Market.parseAmount("change", "abc") == nil)
    ok("nor is an empty box", Market.parseAmount("change", "") == nil)
    ok("nor a negative one", Market.parseAmount("change", "-5") == nil)
end

print("-- and back again --")
do
    -- Round trips, because the box is filled from a stored amount and then read
    -- back off the keyboard. A pair that disagrees loses money on an edit that
    -- nobody made.
    for _, cents in ipairs({0, 1, 5, 29, 100, 1237, 10500, 999999}) do
        local text = Market.amountToText("change", cents)
        ok("a stored " .. cents .. " writes as " .. text .. " and reads back the same",
            Market.parseAmount("change", text) == cents, tostring(Market.parseAmount("change", text)))
    end

    ok("text for the box carries no currency symbol", Market.amountToText("change", 10500) == "105.00")
    ok("a counted pool writes as a bare number", Market.amountToText("tokens", 105) == "105")

    -- The written-out form is a different job: it is read, never edited.
    ok("the written form does carry one", Market.formatAmount("change", 10500) == "$105.00")
    ok("and a counted pool has none to carry", Market.formatAmount("tokens", 105) == "105")
end

print("-- the price step --")
do
    options({
        PriceStep = 100
    })
    ok("a figure between steps comes down", Market.snapPrice(1237) == 1200)
    ok("one already on a step is untouched", Market.snapPrice(1200) == 1200)
    ok("and one under the first step comes down to nothing", Market.snapPrice(99) == 0)

    options({
        PriceStep = 5
    })
    ok("a nickel step aligns to five", Market.snapPrice(37) == 35)

    options({
        PriceStep = 1
    })
    ok("a step of one leaves everything alone", Market.snapPrice(1237) == 1237)

    options({})
    ok("the shipped default is the nickel the change economy already uses", Market.priceStep() == 5)

    -- A sandbox minimum of 1 should put these out of reach. It is a number from
    -- a config file all the same, and a step of zero divides by zero.
    options({
        PriceStep = 0
    })
    ok("a step of zero is read as a step of one", Market.priceStep() == 1)
    options({
        PriceStep = -100
    })
    ok("and so is a negative one", Market.priceStep() == 1)
end

print("-- the range is aligned to the step --")
do
    -- The shipped defaults: a nickel step, a nickel floor, and a ceiling one
    -- cent under a round hundred dollars.
    options({})
    local limits = Market.limits()
    ok("the default floor is already aligned", limits.minPrice == 5)
    ok("the default ceiling comes down onto the step", limits.maxPrice == 9995, tostring(limits.maxPrice))

    -- The whole dollar case: what a server that has scaled PhunMart's own
    -- prices wants, and the reason any of this exists.
    options({
        PriceStep = 100,
        MinPrice = 5,
        MaxPrice = 9999
    })
    limits = Market.limits()
    ok("the floor goes up to the first whole dollar", limits.minPrice == 100, tostring(limits.minPrice))
    ok("the ceiling comes down to the last one", limits.maxPrice == 9900, tostring(limits.maxPrice))
    ok("so both ends of the range are prices a listing may actually hold",
        Market.snapPrice(limits.minPrice) == limits.minPrice and Market.snapPrice(limits.maxPrice) == limits.maxPrice)
    ok("and the step travels with them", limits.step == 100)

    -- A floor below the first step must not round down to zero, or a listing
    -- could be put up for nothing.
    options({
        PriceStep = 100,
        MinPrice = 1,
        MaxPrice = 10000
    })
    ok("a floor under the first step is raised to it", Market.limits().minPrice == 100)

    -- Two settings that cannot both hold. One listable price beats a range with
    -- nothing in it and a sell button that never lights up.
    options({
        PriceStep = 100,
        MinPrice = 5,
        MaxPrice = 50
    })
    limits = Market.limits()
    ok("a ceiling under the step does not end up below the floor", limits.maxPrice >= limits.minPrice,
        limits.minPrice .. " / " .. limits.maxPrice)
end


print("-- what the market calls money --")
do
    local ITEM = "item:Base.Money"

    -- Change, which is what a server that has never touched currency_base runs.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "currency",
            pool = "change"
        }
    end
    ok("an untouched server prices in change", Market.currencyPool() == "change")
    ok("and change is not an item pool", Market.poolItem("change") == nil)

    -- An item currency, which is one edit to currency_base and nothing here.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money"
        }
    end
    ok("an item currency prices in that item", Market.currencyPool() == ITEM)
    ok("and the item comes back out of the pool", Market.poolItem(ITEM) == "Base.Money")

    -- A PhunMart too old to answer is a PhunMart with no item currency to have.
    _G.PhunMart.currencyDef = nil
    ok("no currencyDef at all means change", Market.currencyPool() == "change")

    -- Typed in whole items, stored in hundredths of one, so that commission has
    -- somewhere to put a fraction.
    ok("a price is typed in whole items", Market.parseAmount(ITEM, "5") == 500)
    ok("half an item is not a price anybody may name", Market.parseAmount(ITEM, "3.5") == 300)
    ok("and it reads back as what was typed", Market.amountToText(ITEM, 500) == "5")

    -- The decimal point belongs to the money that has one.
    ok("an item pool takes no decimal point", Market.isSubunitPool(ITEM) == false)
    ok("change still does", Market.isSubunitPool("change") == true)

    ok("five items reads as five", Market.formatAmount(ITEM, 500) == "5 Money")
    -- The 75 hundredths are commission's, held until there is a whole one.
    ok("a held fraction is not collectable yet", Market.formatAmount(ITEM, 575) == "5 Money")
    ok("change is left exactly as it was", Market.formatAmount("change", 250) == "$2.50")
end

print("-- what a player can pay with --")
do
    local ITEM = "item:Base.Money"

    -- A bag holding `count` of Base.Money and nothing else worth counting.
    local function bagOf(count)
        return {
            getInventory = function()
                return {
                    getItemCountRecurse = function(_, fullType)
                        return fullType == "Base.Money" and count or 0
                    end
                }
            end
        }
    end

    _G.PhunMart.wallet.getBalance = function(_, _, pool)
        return pool == "change" and 250 or 0
    end

    ok("an item pool is counted out of the bag, in hundredths",
        Market.balanceOf(bagOf(7), ITEM) == 700)
    ok("an empty bag can pay nothing", Market.balanceOf(bagOf(0), ITEM) == 0)
    ok("and a wallet pool still comes from the wallet",
        Market.balanceOf(bagOf(7), "change") == 250)
    -- Nobody to ask is not a crash, it is a balance of nothing.
    ok("no player is no money", Market.balanceOf(nil, ITEM) == 0)

    -- Fees follow the currency, because a server paying in items has usually
    -- turned the change pool off and a fee nobody can pay refuses every listing.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money"
        }
    end
    options({})
    ok("an unset fee pool follows the currency", Market.feePool() == ITEM)

    options({
        FeePool = "tokens"
    })
    ok("a fee pool an admin named wins", Market.feePool() == "tokens")

    _G.PhunMart.currencyDef = nil
    options({})
    ok("and on a change server it is still change", Market.feePool() == "change")
end

print("-- price limits on an item currency --")
do
    local ITEM = "item:Base.Money"
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money"
        }
    end

    -- The shipped numbers, read as whole items rather than as hundredths.
    options({
        MinPrice = 5,
        MaxPrice = 9999,
        PriceStep = 5
    })
    local lim = Market.limits()
    ok("the floor is five items", lim.minPrice == 500, tostring(lim.minPrice))
    -- Brought down to the last step a listing could actually hold, the same way
    -- it is on the change pool, where a ceiling of 9999 lands on 9995.
    ok("the ceiling comes down to the last listable step", lim.maxPrice == 999500,
        tostring(lim.maxPrice))
    ok("and the step is five", lim.step == 500, tostring(lim.step))

    -- Which is what the seller is told, and the reason this exists: unscaled
    -- it read as a floor of nothing in steps of nothing.
    ok("the range reads in items", Market.formatAmount(ITEM, lim.minPrice) == "5 Money")
    ok("and so does the step", Market.formatAmount(ITEM, lim.step) == "5 Money")

    -- Never finer than one whole item, whatever an admin sets, because a price
    -- the seller cannot type is a price the buy path would round up on.
    options({
        MinPrice = 1,
        MaxPrice = 100,
        PriceStep = 1
    })
    lim = Market.limits()
    ok("a step of one is one whole item", lim.step == 100, tostring(lim.step))
    ok("and the floor cannot go under one either", lim.minPrice == 100, tostring(lim.minPrice))

    -- Change is left exactly as it was: these are already its own units.
    _G.PhunMart.currencyDef = nil
    options({
        MinPrice = 5,
        MaxPrice = 9999,
        PriceStep = 5
    })
    lim = Market.limits()
    ok("a change server keeps its cents", lim.minPrice == 5 and lim.maxPrice == 9995 and lim.step == 5,
        lim.minPrice .. "/" .. lim.maxPrice .. "/" .. lim.step)
end

print("-- figures are read, not counted --")
do
    local ITEM = "item:Base.Money"
    _G.PhunMart.currencyDef = nil

    ok("hundreds are left alone", Market.formatAmount("change", 12345) == "$123.45")
    ok("thousands are grouped", Market.formatAmount("change", 1234567) == "$12,345.67")
    ok("and millions too", Market.formatAmount("change", 123456789) == "$1,234,567.89")
    -- Always two decimals here, unlike PhunMart's formatCents which drops them
    -- on a round figure. A column of prices lines up on the point.
    ok("a round figure keeps its decimals", Market.formatAmount("change", 10500) == "$105.00")
    ok("a counted pool groups as well", Market.formatAmount("tokens", 4200) == "4,200")
    ok("and so does an item one", Market.formatAmount(ITEM, 1234500) == "12,345 Money")
    ok("negatives keep their sign", Market.formatAmount("change", -1234567) == "-$12,345.67")

    -- What the server calls its money beats what the game calls the item.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money",
            label = "Caps"
        }
    end
    ok("a configured name is used", Market.formatAmount(ITEM, 300) == "3 Caps")

    -- Blank or absent falls back, which is the shipped behaviour.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money",
            label = ""
        }
    end
    ok("an empty name falls back to the item", Market.formatAmount(ITEM, 300) == "3 Money")

    -- And it only speaks for the currency it was set on.
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money",
            label = "Caps"
        }
    end
    ok("another item is not renamed", Market.formatAmount("item:Base.Nails", 300) == "3 Nails")
end

print("-- a listing fee has to be a whole item --")
do
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money"
        }
    end

    -- Two percent of three items is six hundredths. It used to read as "costs 0
    -- to list" and then take a whole one, because charge rounds up and the
    -- display floored.
    options({
        ListingFeeMode = 1,
        ListingFeePercent = 2,
        ListingFeeMin = 0
    })
    local fee = Market.listingFeeFor(300, "short")
    ok("a fee too small to take rounds up to one", fee == 100, tostring(fee))
    ok("and says so", Market.formatAmount(Market.feePool(), fee) == "1 Money")

    -- Never past what is being asked, even when rounding up would carry it.
    ok("a fee never exceeds a one item ask", Market.listingFeeFor(100, "long") <= 100)

    -- The duration tiers still separate once the fee is big enough to have
    -- whole items in it to separate.
    options({
        ListingFeeMode = 1,
        ListingFeePercent = 10,
        ListingFeeMin = 0
    })
    local short = Market.listingFeeFor(5000, "short")
    local long = Market.listingFeeFor(5000, "long")
    ok("a long listing still costs more than a short one", long > short,
        short .. " / " .. long)
    ok("and both are whole items", short % 100 == 0 and long % 100 == 0,
        short .. " / " .. long)

    -- Free stays free: rounding up must not invent a fee where none was set.
    options({
        ListingFeeMode = 1,
        ListingFeePercent = 0,
        ListingFeeFixed = 0
    })
    ok("no fee configured is still no fee", Market.listingFeeFor(5000, "long") == 0)

    _G.PhunMart.currencyDef = nil
    options({})
end

print("-- a figure without the word for it --")
do
    local ITEM = "item:Base.Money"
    _G.PhunMart.currencyDef = function()
        return {
            kind = "items",
            item = "Base.Money"
        }
    end

    -- What goes before an icon: the number and nothing else, because the icon
    -- is the word.
    ok("an item figure drops the name", Market.amountFigure(ITEM, 17500) == "175")
    ok("and still groups", Market.amountFigure(ITEM, 1234500) == "12,345")
    ok("negatives keep their sign", Market.amountFigure(ITEM, -17500) == "-175")

    -- The change pool keeps its dollar sign, which is the same idea: a symbol
    -- standing where the word would be.
    ok("change keeps its symbol", Market.amountFigure("change", 250) == "$2.50")
    ok("a counted pool is bare either way", Market.amountFigure("tokens", 4200) == "4,200")

    -- And the named form still names it, for every line that has no icon.
    ok("the named form is unchanged", Market.formatAmount(ITEM, 17500) == "175 Money")

    _G.PhunMart.currencyDef = nil
end
print("")
print("passed: " .. passed .. "  failed: " .. failed)
os.exit(failed == 0 and 0 or 1)
