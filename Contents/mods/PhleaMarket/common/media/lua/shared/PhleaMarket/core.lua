-- =========================================================
-- Phlea Market
--
-- A vending machine that stocks itself from other players' pockets. A seller
-- hands it an item and names a price, the item goes into escrow on the server,
-- and it sits in every Phlea Market in the world until somebody buys it or the
-- listing expires.
--
-- Everything below the surface is PhunMart's: the wallet, the compiler, the
-- shop window, the admin shell. This mod owns the listings and nothing else,
-- which is why it declares require=phunmart2 and does almost nothing on its
-- own.
-- =========================================================
if not PhunMart then
    -- require=phunmart2 in mod.info should make this impossible. It is checked
    -- anyway because the failure is otherwise a nil index somewhere further
    -- down, at a point that says nothing about the cause.
    print("[PhleaMarket] PhunMart 2 is not loaded. Phlea Market does nothing without it.")
    return
end

PhleaMarket = PhleaMarket or {}
local Market = PhleaMarket
local Core = PhunMart

Market.name = "PhleaMarket"

-- Bumped when a change alters what is stored rather than how it is displayed.
-- Persistence reads it to know whether what it loaded needs migrating.
Market.dataVersion = 1

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

--- Read a sandbox option under this mod's own name.
---
--- PhunMart's Core.getOption builds `PhunMart.<name>`, so borrowing it would
--- mean declaring options in PhunMart's namespace from a mod PhunMart knows
--- nothing about. Twenty of them, on a page an admin would then find under
--- somebody else's heading. Own prefix, own page, same one-line shape.
function Market.getOption(name, default)
    local options = getSandboxOptions()
    local option = options and options:getOptionByName(Market.name .. "." .. name)
    local value = option and option:getValue()
    if value == nil then
        return default
    end
    return value
end

function Market.isEnabled()
    return Market.getOption("Enabled", true) == true
end

--- What an enum fee-mode option means.
---
--- A sandbox enum hands back the ordinal, not the label, so every read of one
--- is a bare 1 or 2 with nothing on it to say which is which. Named here once,
--- because "if mode == 1" scattered through the fee arithmetic is a thing that
--- reads fine and is wrong half the time.
Market.FEE_PERCENT = 1
Market.FEE_FIXED = 2

--- Resolve one of the two fees against an asking total.
---
--- `which` is "ListingFee" or "Commission", naming the pair of options to read.
--- Both take the same shape deliberately: a flat charge asks the same to list a
--- nail as a gold bar, which is the wrong shape for a market where a nail is a
--- reasonable thing to sell, so each fee can be told to take a share instead.
---
--- Rounded down, so the rounding always favours the player.
function Market.feeFor(which, askingTotal)
    local mode = Market.getOption(which .. "Mode", Market.FEE_PERCENT)
    if mode == Market.FEE_FIXED then
        return Market.getOption(which .. "Fixed", 0)
    end
    local percent = Market.getOption(which .. "Percent", 0)
    if percent <= 0 then
        return 0
    end
    return math.floor((askingTotal or 0) * percent / 100)
end

--- The three listing lengths and what each multiplies the listing fee by.
---
--- Shared rather than server-only so the window can show the seller the exact
--- fee the server is about to charge. Two copies of this arithmetic, one for
--- display and one for the charge, is how a player ends up shown one number and
--- billed another.
Market.DURATIONS = {
    short = {
        hours = "DurationShortHours",
        hoursDefault = 24,
        multDefault = 1
    },
    medium = {
        hours = "DurationMediumHours",
        hoursDefault = 72,
        mult = "DurationMediumMult",
        multDefault = 2
    },
    long = {
        hours = "DurationLongHours",
        hoursDefault = 168,
        mult = "DurationLongMult",
        multDefault = 4
    }
}

--- Hours and fee multiplier for a tier. Anything unrecognised is treated as
--- medium, which is what an out-of-date client would send.
function Market.duration(tier)
    local spec = Market.DURATIONS[tier] or Market.DURATIONS.medium
    local hours = Market.getOption(spec.hours, spec.hoursDefault)
    local mult = spec.mult and Market.getOption(spec.mult, spec.multDefault) or spec.multDefault or 1
    return hours, mult
end

--- The fee rules as they stand. Frozen onto a listing when it goes up, so a
--- later change cannot reach back and tax something already on the shelf.
function Market.commissionRule()
    return {
        mode = Market.getOption("CommissionMode", Market.FEE_PERCENT),
        percent = Market.getOption("CommissionPercent", 5),
        fixed = Market.getOption("CommissionFixed", 25)
    }
end

function Market.listingFeeRule()
    return {
        mode = Market.getOption("ListingFeeMode", Market.FEE_PERCENT),
        percent = Market.getOption("ListingFeePercent", 2),
        fixed = Market.getOption("ListingFeeFixed", 0)
    }
end

--- The coarseness a price may be named at, in pool units.
---
--- A market counted in cents lets somebody ask $12.37, which on a server whose
--- machines all charge round figures reads as a mistake rather than as a keen
--- price. One allows every amount; five keeps the change economy nickel-aligned
--- the way the rest of it already is; a hundred means whole dollars and nothing
--- finer, which is what a server that has scaled PhunMart's prices up wants.
function Market.priceStep()
    local step = math.floor(tonumber(Market.getOption("PriceStep", 5)) or 1)
    if step < 1 then
        return 1
    end
    return step
end

--- An amount brought down onto the step below it.
---
--- Down rather than to the nearest, so snapping never quietly asks a buyer for
--- more than the figure the seller typed. Nothing here puts the floor back:
--- callers check the range afterwards, and a price that snaps under the
--- minimum is a price that was under it, which is worth being told about
--- rather than silently corrected upwards.
function Market.snapPrice(amount, step)
    amount = math.floor(tonumber(amount) or 0)
    step = step or Market.priceStep()
    if step <= 1 then
        return amount
    end
    return math.floor(amount / step) * step
end

function Market.limits()
    local step = Market.priceStep()
    local minPrice = Market.getOption("MinPrice", 5)
    local maxPrice = Market.getOption("MaxPrice", 9999)

    -- On an item currency these three are read as whole items rather than as
    -- ledger units. One rule, and the one an admin means: a MinPrice of 5 is
    -- five of the thing, the same way it is five cents on the change pool.
    -- Left unscaled they are hundredths, and a floor of five hundredths, a
    -- ceiling of ninety nine and a step of nothing is what the range line was
    -- reporting.
    --
    -- The step is held at one whole item at the least. Half an item is not a
    -- price a seller can name -- parseAmount truncates before it gets here --
    -- so a finer step only lets the simulated sellers quote a figure the buy
    -- path would then round up on, which shows a player one number and charges
    -- them another.
    if Market.poolItem(Market.currencyPool()) then
        local scale = Market.ITEM_SCALE
        minPrice = math.max(scale, math.floor(minPrice) * scale)
        maxPrice = math.max(minPrice, math.floor(maxPrice) * scale)
        step = math.max(scale, math.floor(step) * scale)
    end

    -- The bounds are aligned to the step as well, because a range whose ends
    -- are not themselves listable is a range that lies: a floor of 5 under a
    -- step of 100 names a price no listing may ever hold. The floor goes up and
    -- the ceiling comes down, so everything the range describes is a price that
    -- can actually be asked.
    --
    -- Moving them can collide -- a ceiling of 50 under a step of 100 rounds
    -- down to nothing, and the aligned floor is already above it. The ceiling
    -- is opened back up to the floor rather than left underneath it, which is
    -- above the figure that was set. An admin who has asked for a step coarser
    -- than their own ceiling has asked for two things that cannot both hold,
    -- and one listable price is a better answer than a market where the sell
    -- button never lights up and the range line explains why.
    if step > 1 then
        minPrice = math.ceil(minPrice / step) * step
        maxPrice = math.floor(maxPrice / step) * step
        if minPrice < step then
            minPrice = step
        end
        if maxPrice < minPrice then
            maxPrice = minPrice
        end
    end

    return {
        maxListings = Market.getOption("MaxListings", 10),
        maxQty = Market.getOption("MaxStackQty", 100),
        minPrice = minPrice,
        maxPrice = maxPrice,
        step = step
    }
end

--- The pool a listing fee and a commission are taken in.
---
--- Follows the market's currency unless an admin has named something else. A
--- server that has moved to an item currency has usually turned the change pool
--- off, and a fee charged in a pool nobody is filling is a fee that refuses
--- every listing on the server.
---
--- Naming a pool explicitly still wins. Charging fees in tokens while the goods
--- trade in items is a deliberate arrangement, and the option is here to let an
--- admin set it up.
function Market.feePool()
    local configured = Market.getOption("FeePool", "change")
    if configured == nil or configured == "" or configured == "change" then
        return Market.currencyPool()
    end
    return configured
end

--- The ledger units in one whole item of an item currency.
---
--- Prices are named in whole items, but commission is a share of one, and a
--- fifth of an item is a real amount that has to survive until there is enough
--- of it to pay. So an item pool is counted in hundredths the way change is
--- counted in cents, and only becomes items again at the two points it has to
--- be physical: taken out of a bag, or put into one.
Market.ITEM_SCALE = 100

--- An item pool is written "item:Base.Money" rather than carried beside the
--- pool as a second field. The pool string is already stamped on every listing
--- and already threaded through quote, sale and return, so putting the item
--- inside it means none of that plumbing has to learn a new shape. Only the few
--- places that actually touch money have to ask what kind of pool they have.
Market.ITEM_POOL_PREFIX = "item:"

--- The item an item-backed pool pays in, or nil for an ordinary wallet pool.
function Market.poolItem(pool)
    if type(pool) ~= "string" then
        return nil
    end
    return pool:match("^item:(.+)$")
end

--- The pool the market prices in as things stand.
---
--- PhunMart owns what money is; this only asks it. `currency_base` is the one
--- place a server's currency is configured, so there is nothing here to keep in
--- step with it and nothing for an admin to set twice.
---
--- Guarded, because a PhunMart older than currencyDef is a PhunMart whose
--- currency cannot be anything but change.
function Market.currencyPool()
    local def = Core.currencyDef and Core.currencyDef()
    if not def then
        return "change"
    end
    if def.kind == "items" and def.item then
        return Market.ITEM_POOL_PREFIX .. def.item
    end
    return def.pool or "change"
end

--- What to call one of them on screen.
---
--- Through the script manager rather than the raw id, so a listing reads
--- "5 Money" and not "5 Base.Money". Falls back to the half after the dot,
--- which is what is left if the type has no script loaded.
function Market.poolItemLabel(item)
    if not item then
        return ""
    end

    -- What the server has chosen to call its money wins over what the game
    -- calls the item. "3 Money" is what Base.Money gives you and it reads
    -- oddly; a server trading in bottle caps wants to say so.
    local def = Core.currencyDef and Core.currencyDef()
    if def and def.item == item and def.label and def.label ~= "" then
        return def.label
    end

    local ok, name = pcall(function()
        local si = getScriptManager():getItem(item)
        return si and si:getDisplayName() or nil
    end)
    if ok and name then
        return name
    end
    return item:match("%.(.+)$") or item
end

--- Whether a pool is counted in something finer than the unit it is spoken in.
---
--- The change pool is: it is counted in cents and spoken in dollars, so a
--- balance of 500 is five dollars. Tokens are counted and spoken in tokens.
--- Everything that puts money on screen or takes it off a keyboard turns on
--- this one question.
---
--- An item pool is stored finer than it is spoken too, and still answers no,
--- because what this actually decides is whether a figure is written and typed
--- with a decimal point. Half an item is not a price anybody may name: the
--- fractions an item pool carries are made by commission, never by a seller.
function Market.isSubunitPool(pool)
    if Market.poolItem(pool) then
        return false
    end
    local def = Core.wallet and Core.wallet.pools and Core.wallet.pools[pool or "change"]
    return def ~= nil and def.format == "cents"
end
local isSubunit = Market.isSubunitPool

--- How many ledger units make up one of whatever the pool is spoken in.
function Market.poolScale(pool)
    if Market.poolItem(pool) then
        return Market.ITEM_SCALE
    end
    return isSubunit(pool) and 100 or 1
end

--- What a player could pay out of a pool right now, in that pool's units.
---
--- Shared, because the window greys a Buy button with it and the server
--- refuses the purchase with it, and those two disagreeing is a button that
--- does nothing when pressed. An item pool has no wallet balance to read:
--- what a player has is what is in their bags.
function Market.balanceOf(playerObj, pool)
    local item = Market.poolItem(pool)
    if item then
        local inv = playerObj and playerObj.getInventory and playerObj:getInventory()
        if not inv then
            return 0
        end
        return (inv:getItemCountRecurse(item) or 0) * Market.ITEM_SCALE
    end
    return (Core.wallet and Core.wallet:getBalance(playerObj, pool)) or 0
end

--- An amount in the words of the pool it belongs to.
---
--- A price is a number of pool units, and what a unit is depends on the pool:
--- change is counted in cents and reads as $0.05, tokens are counted in tokens
--- and read as 5. Showing the raw number leaves a seller typing 5 and having no
--- idea whether they have asked for a nickel or five dollars.
--- Digits in threes, so a four figure price is read rather than counted.
---
--- Its own copy for the same reason the cents arithmetic below is: the shared
--- one lives in a client-only module of another mod, and this runs on the
--- server too.
local function grouped(n)
    local s = tostring(math.floor(math.abs(tonumber(n) or 0)))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return out
end
Market.groupDigits = grouped

function Market.formatAmount(pool, amount)
    amount = tonumber(amount) or 0
    local sign = amount < 0 and "-" or ""
    local item = Market.poolItem(pool)
    if item then
        -- Floored, so a balance never reads as more than it could pay out. What
        -- the floor drops is not lost, it is only not collectable yet.
        local n = math.floor(math.abs(amount) / Market.ITEM_SCALE)
        return sign .. grouped(n) .. " " .. Market.poolItemLabel(item)
    end
    if isSubunit(pool) then
        -- The shared formatter lives in a client-only module, so this does the
        -- same arithmetic rather than reaching across for it.
        -- Always two decimals, unlike PhunMart's own formatCents which drops
        -- them on a round figure. That is deliberate here: this form is read and
        -- never edited, and a column of prices lines up on the point.
        local n = math.abs(math.floor(amount))
        return sign .. "$" .. grouped(math.floor(n / 100)) .. string.format(".%02d", n % 100)
    end
    return sign .. grouped(amount)
end

--- The figure alone, without the word for what it is.
---
--- For a line that will have the currency's icon drawn after it. The icon is
--- the word: "175 Money" with a picture of money beside it says the same thing
--- twice, and on a server paying in nails it says it twice badly, because
--- "Nails" is both the money and half the things for sale.
---
--- The change pool keeps its dollar sign, which is the same idea already: a
--- symbol standing where the word would be.
function Market.amountFigure(pool, amount)
    amount = tonumber(amount) or 0
    if Market.poolItem(pool) then
        local sign = amount < 0 and "-" or ""
        return sign .. grouped(math.floor(math.abs(amount) / Market.ITEM_SCALE))
    end
    return Market.formatAmount(pool, amount)
end

--- The icon for a currency, or nil where there is nothing to draw.
---
--- nil for the change pool, which has no item behind it, and nil on a server
--- whose currency item has no script loaded. Both mean the caller falls back to
--- naming the currency in words.
function Market.currencyTexture(pool)
    local item = Market.poolItem(pool)
    if not item then
        return nil
    end
    local ok, tex = pcall(function()
        local si = getScriptManager():getItem(item)
        return si and si:getNormalTexture() or nil
    end)
    if ok then
        return tex
    end
    return nil
end

--- A figure somebody typed, as a number of pool units.
---
--- The price box is the only place in the market where anybody types money, and
--- it used to take raw pool units. On the change pool that means cents, so a
--- seller who meant a hundred dollars typed 100 and listed at one. Nothing else
--- in PhunMart asks that of a player -- every balance, price and fee they are
--- shown is written out in dollars -- which made this the single screen wanting
--- a unit the rest of the game never puts in front of them, and there is no
--- reading of "105" that warns you it meant a dollar five.
---
--- So it takes dollars, and converts here. This is deliberately the same
--- arithmetic as PhunMart's own wallet editor, which has always taken dollars
--- for a cents pool: the two ought not to disagree about what a typed number
--- means.
---
--- Returns nil for anything that is not a number, which the caller shows as a
--- price of nothing rather than guessing at.
function Market.parseAmount(pool, text)
    local num = tonumber(text)
    if not num or num < 0 then
        return nil
    end
    if Market.poolItem(pool) then
        -- Whole items only. Somebody naming three and a half of something has
        -- named a price the market cannot take out of a bag, and truncating is
        -- the reading that never charges a buyer more than was asked.
        return math.floor(num) * Market.ITEM_SCALE
    end
    if isSubunit(pool) then
        -- Rounded rather than truncated: 12.37 arrives as 1236.9999... and a
        -- floor would quietly take a cent off every price with an odd one.
        return math.floor(num * 100 + 0.5)
    end
    return math.floor(num)
end

--- The inverse: an amount as the text an entry box should open holding.
---
--- Bare digits rather than formatAmount's "$1.05", because this goes straight
--- back into a box the player edits, and a currency symbol is something they
--- would have to type around.
function Market.amountToText(pool, amount)
    amount = math.floor(tonumber(amount) or 0)
    if Market.poolItem(pool) then
        return tostring(math.floor(amount / Market.ITEM_SCALE))
    end
    if isSubunit(pool) then
        return string.format("%.2f", amount / 100)
    end
    return tostring(amount)
end

--- What listing something actually costs, all in.
---
--- One function rather than the percentage, the multiplier and the floor spelt
--- out at each of the three call sites -- the dialog that shows the figure, the
--- command that charges it, and the relist that does both.
---
--- The floor exists because a percentage of a small asking price rounds to
--- nothing: two percent of a nickel is zero, so cheap listings were free and
--- the fee stopped being a brake on spam exactly where spam is cheapest. It
--- only applies when the rule would charge something at all, so setting the
--- percentage to zero still means free listings.
function Market.listingFeeFor(askingTotal, duration)
    local Listings = require "PhleaMarket/listings"
    local rule = Market.listingFeeRule()
    local _, mult = Market.duration(duration)

    local charges = (tonumber(rule.percent) or 0) > 0 or (tonumber(rule.fixed) or 0) > 0
    if not charges then
        return 0
    end

    -- Unrounded, so the duration multiplier scales the real fraction rather
    -- than what is left of it after a floor. Rounded once at the end.
    local fee = Listings.feeValue(rule, askingTotal) * mult
    local floor = Market.getOption("ListingFeeMin", 0)
    if floor > 0 and fee < floor then
        fee = floor
    end
    -- Never more than the seller is asking, or listing would cost more than
    -- selling could return.
    if fee > askingTotal then
        fee = askingTotal
    end

    -- On an item currency the fee has to be a whole number of items, because it
    -- is taken out of a bag before there is any balance to hold a fraction in.
    -- Rounded up rather than down: charge is what decides the real figure and
    -- it rounds up too, so anything else here shows a seller one number and
    -- takes another. Six hundredths of an item read as "costs 0 to list" and
    -- then cost them a whole one.
    --
    -- The cap above still holds, so a fee can never exceed the ask even when
    -- rounding up would carry it past.
    local item = Market.poolItem(Market.feePool())
    if item and fee > 0 then
        local scale = Market.ITEM_SCALE
        fee = math.min(math.ceil(fee / scale) * scale, math.floor(askingTotal / scale) * scale)
    end

    return math.floor(fee)
end

function Market.debugLn(str)
    if Core.settings and Core.settings.Debug then
        print("[PhleaMarket] " .. tostring(str))
    end
end

---------------------------------------------------------------------------
-- What may be listed
---------------------------------------------------------------------------

-- Never listable, whatever an admin says.
--
-- Currency would let a player launder a capped pool through the market. The
-- dropped wallet is somebody's balance in item form. The vehicle key spawner
-- rolls a car when it is used, so a listing of one is a listing of a car nobody
-- has seen. None of these are things a server owner should have to think to
-- block.
local NEVER = {
    ["PhunMart.DroppedWallet"] = true,
    ["PhunMart.VehicleKeySpawner"] = true
}

--- Rules an admin adds, in three kinds.
---
--- Exact types alone would mean enumerating every food item in Build 42 to say
--- "no food", which is not a reasonable thing to ask. Category is the script
--- item's display category; tag is for the cross-cutting cases a category
--- misses.
---
--- Deliberately its own list rather than PhunMart's global blacklist: that one
--- answers a different question -- what a machine may not stock -- and adding
--- to it would change what the other sixteen machines sell.
Market.blocked = {
    types = {},
    categories = {},
    tags = {}
}

--- Whether a table holds anything.
---
--- `next` is not handed to mod code in B42.20.4, so the usual `next(t) ~= nil`
--- is a call to a nil value. pairs still works, because it reaches next below
--- the C boundary rather than through the global.
local function hasAny(tbl)
    for _ in pairs(tbl) do
        return true
    end
    return false
end

--- Whether a player may put this item type up for sale.
function Market.isListable(fullType)
    if type(fullType) ~= "string" or fullType == "" then
        return false
    end
    if NEVER[fullType] or Market.blocked.types[fullType] then
        return false
    end
    -- Currency is asked of PhunMart rather than listed here, so a server that
    -- adds a coin of its own does not have to remember to block it too.
    if Core.wallet and Core.wallet:isCurrency(fullType) then
        return false
    end

    local manager = type(getScriptManager) == "function" and getScriptManager()
    local script = manager and manager:FindItem(fullType)
    if not script then
        -- Unknown to the game: refuse rather than escrow something that cannot
        -- be built again.
        return false
    end

    if hasAny(Market.blocked.categories) and script.getDisplayCategory then
        local category = script:getDisplayCategory()
        if category and Market.blocked.categories[category] then
            return false
        end
    end

    if hasAny(Market.blocked.tags) and script.getTags then
        local ok, tags = pcall(script.getTags, script)
        if ok and tags and tags.size then
            for i = 0, tags:size() - 1 do
                if Market.blocked.tags[tags:get(i)] then
                    return false
                end
            end
        end
    end

    return true
end

---------------------------------------------------------------------------
-- Hooks into PhunMart
--
-- All four run at load time, which is the window they have to run in: the
-- first two are read when definitions compile, and the last two when a window
-- first opens. A mod's shared file loads well before either.
---------------------------------------------------------------------------

--- Contribute the shop definition to the compile.
---
--- Core.defaultPaths is a category -> module path table that compileWith builds
--- its base context from, long after every mod's shared Lua has loaded, so
--- appending here is enough to have PhleaMarket compiled alongside the sixteen
--- machines PhunMart ships.
--- Append once, however many times this file is executed.
---
--- The game loads a mod's shared files itself, and other files here also
--- `require` this one. Those are two different caches, so this can run twice in
--- one session -- harmless for a function definition, not harmless for a list
--- that something appends to on every pass.
local function registerOnce(list, value)
    for _, existing in ipairs(list) do
        if existing == value then
            return
        end
    end
    table.insert(list, value)
end

registerOnce(Core.defaultPaths.shops, "PhleaMarket/defaults/shops")

--- Keep the `consignment` flag through compilation.
---
--- The compiler builds each runtime.shops entry from an explicit list of field
--- names and drops anything not on it, which is what stops an admin override
--- smuggling arbitrary keys into the runtime. A flag this mod invents is not on
--- that list, so without this it would be gone before the shop window ever saw
--- it, and the Sell mode keyed on it would simply never appear.
registerOnce(Core.shopDefPassthrough, "consignment")

return Market
