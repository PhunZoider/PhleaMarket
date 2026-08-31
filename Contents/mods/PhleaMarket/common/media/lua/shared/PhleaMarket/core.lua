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
table.insert(Core.defaultPaths.shops, "PhleaMarket/defaults/shops")

--- Keep the `consignment` flag through compilation.
---
--- The compiler builds each runtime.shops entry from an explicit list of field
--- names and drops anything not on it, which is what stops an admin override
--- smuggling arbitrary keys into the runtime. A flag this mod invents is not on
--- that list, so without this it would be gone before the shop window ever saw
--- it, and the Sell mode keyed on it would simply never appear.
table.insert(Core.shopDefPassthrough, "consignment")

return Market
