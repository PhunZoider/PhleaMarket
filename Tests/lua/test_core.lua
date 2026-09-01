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

print("")
print("passed: " .. passed .. "  failed: " .. failed)
os.exit(failed == 0 and 0 or 1)
