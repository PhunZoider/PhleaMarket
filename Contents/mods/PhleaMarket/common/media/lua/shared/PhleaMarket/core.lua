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
