if isClient() then
    return
end

-- Sellers who do not exist.
--
-- A market with nobody in it is worse than no market: the machine works, the
-- screens are all correct, and there is nothing to buy. That is singleplayer
-- every time, and a quiet server most evenings. So the shelves get stocked by
-- survivors who are not there.
--
-- Nothing about browsing or buying one of these is special. They are ordinary
-- listings with a flag, so the grid, the filter, the price guide and the buy
-- path all treat them exactly as they treat everyone else's -- which is the
-- point, because the moment they need their own code path they start behaving
-- differently in ways players notice.
--
-- Two things do differ, and both are absences rather than behaviours: there is
-- no wallet behind the name to pay when one sells, and nothing to hand back
-- when one expires.

require "PhleaMarket/core"

local Core = PhunMart
local Market = PhleaMarket
local Listings = require "PhleaMarket/listings"
local Snapshot = require "PhleaMarket/item_snapshot"
local Store = require "PhleaMarket_Server/store"

local Simulated = {}
Market.simulated = Simulated

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

-- Carried here rather than taken from the game's survivor lists.
--
-- SurvivorFactory.randomName wants a descriptor to write into, which means
-- building a survivor to throw away, on a server, to get a string. A list is
-- forty lines, has no engine dependency, works headless, and can be read by
-- anyone wondering where a name came from.
local FORENAMES = {"Alan", "Bernice", "Carl", "Dolores", "Earl", "Faye", "Gus", "Hazel", "Ivan", "Jolene", "Karl",
                   "Lorna", "Marv", "Nadine", "Otis", "Peggy", "Quentin", "Rosa", "Stan", "Tammy", "Ulysses", "Vera",
                   "Wendell", "Yvonne", "Zeke", "Bobbie", "Clyde", "Darlene", "Emmett", "Francine"}

local SURNAMES = {"Ackley", "Boone", "Crutcher", "Dabney", "Eubanks", "Fentress", "Gatliff", "Hollon", "Ingram",
                  "Jessup", "Kilburn", "Lyttle", "Maggard", "Napier", "Osborne", "Prather", "Quillen", "Ratliff",
                  "Slone", "Tackett", "Vance", "Whitaker", "Yeary", "Zachary", "Combs", "Deaton", "Hignite",
                  "Muncy", "Sizemore", "Wagers"}

local function pick(list)
    return list[ZombRand(#list) + 1]
end

--- A survivor who is not there.
---
--- The account name is prefixed and carries the same random digits, so anything
--- that files by account -- the per-account listing cap, a returns queue that
--- should never be written -- keeps them apart from each other and from a real
--- player, whose username could otherwise collide with a generated one.
local function makeSeller()
    local forename, surname = pick(FORENAMES), pick(SURNAMES)
    local tag = tostring(ZombRand(100000))
    return "npc:" .. tag, forename .. " " .. surname
end

--- Whether a seller name belongs to nobody.
function Simulated.isSimulatedSeller(seller)
    return type(seller) == "string" and seller:sub(1, 4) == "npc:"
end

---------------------------------------------------------------------------
-- What they sell, and for how much
---------------------------------------------------------------------------

local candidates

--- Things the machines themselves sell, at the prices they sell them for.
---
--- Drawn from PhunMart's compiled pools rather than from a list written here,
--- which is what keeps the fake market anchored to the real economy: whatever
--- an admin has priced a hammer at, that is roughly what a hammer goes for
--- here, including on a server that has rewritten every price in the game.
---
--- Only currency offers in the fee pool, and only real items. An offer priced
--- in items, or one that hands over a trait or a vehicle, is not something a
--- survivor can be pictured carrying to a market stall.
function Simulated.candidates()
    if candidates then
        return candidates
    end
    candidates = {}
    local pool = Market.feePool()

    for _, poolDef in pairs((Core.runtime and Core.runtime.pools) or {}) do
        for _, offer in pairs(poolDef.offers or {}) do
            local item = offer.item
            local price = offer.price
            -- A dot means a real item type. Traits, skills and boosts use bare
            -- keys, and none of them is a thing to find on a market stall.
            if type(item) == "string" and item:find("%.") and type(price) == "table" and price.kind == "currency" and
                (price.pool or "change") == pool and Market.isListable(item) then
                local amount = price.amount
                if type(amount) == "table" then
                    -- A price range compiles to one at restock; here the middle
                    -- of it is the honest reading of "what this costs".
                    amount = math.floor(((amount.min or 0) + (amount.max or amount.min or 0)) / 2)
                end
                if type(amount) == "number" and amount > 0 then
                    table.insert(candidates, {
                        fullType = item,
                        base = math.floor(amount)
                    })
                end
            end
        end
    end

    Market.debugLn("simulated: " .. #candidates .. " candidate items drawn from the pools")
    return candidates
end

--- Forget the cached candidates, so the next tick reads the pools again.
--- Called when definitions recompile, since prices may have moved.
function Simulated.invalidate()
    candidates = nil
end

---------------------------------------------------------------------------
-- Stocking the shelves
---------------------------------------------------------------------------

--- How many simulated listings are up.
local function countSimulated(store)
    local n = 0
    for _, listing in pairs(Listings.rebuildIndices(store).active) do
        if listing.simulated then
            n = n + 1
        end
    end
    return n
end

--- Put one fake listing up.
---
--- Priced between roughly two thirds and one and a half times what a machine
--- charges, so the market reads as a spread of good and bad deals rather than a
--- second price list. A player who knows what a hammer costs can tell which is
--- which, which is the whole game of a market.
function Simulated.addOne(store, now)
    local list = Simulated.candidates()
    if #list == 0 then
        return nil
    end
    local choice = list[ZombRand(#list) + 1]
    local limits = Market.limits()

    local spread = 65 + ZombRand(86) -- 65% to 150%
    local unit = math.floor(choice.base * spread / 100)
    -- Nickel-aligned, because the rest of the change economy is and a price of
    -- 37 cents in among prices ending in 0 and 5 reads as a bug.
    unit = math.floor(unit / 5) * 5
    if unit < limits.minPrice then
        unit = limits.minPrice
    end
    if unit > limits.maxPrice then
        unit = limits.maxPrice
    end

    -- Only where every one really is interchangeable. Asking the item itself is
    -- the same question a player's listing has to answer, and answering it the
    -- same way is what stops simulated stock behaving unlike real stock.
    local qty = 1
    local probe = type(instanceItem) == "function" and instanceItem(choice.fullType)
    if probe and Snapshot.isStackable(probe) then
        qty = 1 + ZombRand(8)
    end

    local seller, sellerChar = makeSeller()
    local hours = Market.duration(ZombRand(3) == 0 and "short" or "medium")

    return Listings.create(store, {
        seller = seller,
        sellerChar = sellerChar,
        -- The snapshot is the item type and nothing else, which is all a fresh
        -- one needs: restore builds from the type, so a simulated axe arrives in
        -- the condition the game makes a new axe in. Nothing about the buy path
        -- has to know.
        snapshot = {
            v = Snapshot.VERSION,
            fullType = choice.fullType
        },
        fullType = choice.fullType,
        itemName = probe and probe:getName() or choice.fullType,
        qty = qty,
        unitPrice = {
            pool = Market.feePool(),
            amount = unit
        },
        durationHours = hours,
        listingFee = 0,
        commission = Market.commissionRule(),
        nowHours = now,
        simulated = true,
        -- No limits: the per-account cap is about stopping one player filling
        -- the market, and each of these is its own account anyway.
        limits = nil
    })
end

--- Keep the shelves roughly as full as the setting asks.
---
--- One at a time rather than topping straight up to the target, so a market
--- that has just been emptied refills over a while instead of blinking back to
--- full between two visits. Churn comes free with it: listings expire on their
--- own, and this notices the gap on the next tick.
function Simulated.tick(store, now)
    if not Market.getOption("SimulatedSellers", false) then
        return 0
    end
    local target = Market.getOption("SimulatedCount", 20)
    if target <= 0 then
        return 0
    end

    local have = countSimulated(store)
    if have >= target then
        return 0
    end

    -- A few per tick. Ten minutes between ticks means an empty market fills in
    -- a couple of in-game hours, which is a market filling up rather than a
    -- market being switched on.
    local added = 0
    local room = math.min(target - have, 3)
    for _ = 1, room do
        if Simulated.addOne(store, now) then
            added = added + 1
        end
    end
    if added > 0 then
        Market.debugLn("simulated: added " .. added .. ", now " .. (have + added) .. "/" .. target)
    end
    return added
end

return Simulated
