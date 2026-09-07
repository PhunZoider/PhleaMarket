-- The Phlea Market machine.
--
-- Contributed to PhunMart's compile through Core.defaultPaths in core.lua, so
-- it is compiled and placed by exactly the machinery that handles the sixteen
-- shops PhunMart ships. Returned as a table keyed by shop name, matching the
-- shape of PhunMart/defaults/shops.
--
return {
    PhleaMarket = {
        probability = 5,
        minDistance = 500,
        category = "PhleaMarket",

        -- Read by the shop window's mode registry to decide whether the Sell,
        -- Mine and Returns modes belong on this machine. Survives compilation
        -- only because core.lua names it in Core.shopDefPassthrough.
        consignment = true,

        -- Exempt from the eligible-pool test. A shop with no poolSets is
        -- normally unplaceable, since "no pool passes the zone filter here" is
        -- the correct answer for an empty list and that test survives an admin
        -- forcing placement. This machine's stock comes from players.
        stocksNothing = true,

        background = "machine-phleamarket.png",

        -- This mod's own pack, not PhunMart's (media/phleamarket.tiles, declared
        -- by the tiledef line in mod.info). Borrowing phunmart_03_16..23
        -- would work at runtime -- sprite names are global once a pack loads --
        -- but it would mean the machine's art shipping from a repository this
        -- mod does not own, and the two having to be versioned together to
        -- change a sprite.
        sprites = {"phleamarket_01_0", "phleamarket_01_1", "phleamarket_01_2", "phleamarket_01_3"},
        unpoweredSprites = {"phleamarket_01_4", "phleamarket_01_5", "phleamarket_01_6", "phleamarket_01_7"},

        -- Deliberately empty. See stocksNothing above.
        poolSets = {}
    }
}
