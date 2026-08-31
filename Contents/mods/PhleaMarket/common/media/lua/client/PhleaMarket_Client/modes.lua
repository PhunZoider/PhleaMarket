if isServer() then
    return
end

-- The four things a Phlea Market can be asked to do, registered onto the shop
-- window's mode strip.
--
-- PhunMart owns the window. This owns what the window shows when it is standing
-- in front of one of these machines: the modes are registered, not patched in,
-- and every one of them is scoped by the `consignment` flag so nothing here
-- turns up on a machine that sells nails.
--
-- Each mode projects whatever it is showing into the offer shape the item grid
-- already renders -- an id, an item type, a price and a stock count. That grid
-- does icons, categories, tooltips and scrolling, and none of it needed
-- changing to show listings instead of stock.

require "PhleaMarket/core"
require "PhleaMarket/commands"
require "PhleaMarket_Client/commands"

local Core = PhunMart
local Market = PhleaMarket
local Snapshot = require "PhleaMarket/item_snapshot"
local Client = Market.client
local C = Market.commands

local Modes = {}
Market.modes = Modes

---------------------------------------------------------------------------
-- Projecting into the grid
---------------------------------------------------------------------------

--- Turn a row into something the item grid will draw.
---
--- `stockQty` carries the quantity, which is what puts a count on the tile, and
--- -1 means unlimited to the grid so it must never be used here: everything in
--- a market is finite.
local function asOffer(id, fullType, unit, pool, qty, meta)
    return {
        id = id,
        item = fullType,
        price = {
            kind = "currency",
            pool = pool or "change",
            amount = unit or 0
        },
        offer = {
            qty = 1,
            stockQty = math.max(0, math.floor(qty or 0))
        },
        meta = meta
    }
end

local function emptyGrid(ui)
    return {
        key = ui.data and ui.data.key,
        offers = {},
        conditionsDefs = ui.data and ui.data.conditionsDefs
    }
end

local function gridOf(ui, offers)
    return {
        key = ui.data and ui.data.key,
        offers = offers,
        conditionsDefs = ui.data and ui.data.conditionsDefs
    }
end

--- Ask again, and remember which window asked.
---
--- Every mode refreshes on entry rather than caching: a market is a shared
--- thing, and what it held when the window opened is not what it holds now.
---
--- The window is stashed because a reply arrives long after the call and has to
--- find something to redraw. PhunMart keeps its shop windows in a local table
--- with no accessor, but every mode hook is handed the window itself, so there
--- is nothing to reach for: it is already here.
local function refresh(ui, command, args)
    Modes.window = ui
    Client.send(command, args)
end

---------------------------------------------------------------------------
-- Buy
---------------------------------------------------------------------------

Core.registerShopMode({
    key = "market",
    label = "IGUI_PhleaMarket_Mode_Buy",
    order = 5,
    flag = "consignment",

    onEnter = function(ui)
        refresh(ui, C.browse)
    end,

    getGridData = function(ui)
        local browse = Client.data.browse
        if not (browse and browse.listings) then
            return emptyGrid(ui)
        end
        local offers = {}
        for _, row in ipairs(browse.listings) do
            offers[row.id] = asOffer(row.id, row.fullType, row.unit, row.pool, row.qty)
        end
        return gridOf(ui, offers)
    end,

    actionLabel = function(ui, offer)
        -- Buying your own listing is allowed -- it is a strictly worse Cancel,
        -- since you pay commission to get your own item back -- but it should
        -- not look like a mistake, so it says what it is.
        local row = Modes.rowFor(ui, offer)
        if row and row.seller == Modes.username() then
            return getText("IGUI_PhleaMarket_BuyBack")
        end
        return getText("IGUI_PhunMart_Buy")
    end,

    canAction = function(ui, offer, id)
        if not id then
            return false
        end
        local price = offer and offer.price
        if not price then
            return false
        end
        return (Core.wallet:getBalance(ui.player, price.pool) or 0) >= (price.amount or 0)
    end,

    onAction = function(ui)
        if not ui.selectedId then
            return
        end
        Client.send(C.buy, {
            listingId = ui.selectedId,
            qty = 1
        })
    end
})

---------------------------------------------------------------------------
-- Sell
---------------------------------------------------------------------------

--- What the player is carrying that may be listed, one row per item type.
---
--- Collapsed by type rather than listed instance by instance, because an
--- inventory holding forty nails should offer one thing to sell and not forty.
--- The count is what the seller then chooses a quantity from.
--- Recursive, because escrow is. Store.escrow takes what it needs with
--- getFirstTypeRecurse, so it reaches into bags; a Sell grid built from the
--- top-level inventory alone would refuse to offer something the server would
--- happily have taken, and the player would be told they are not carrying an
--- item that is plainly in their backpack.
local function listableInventory(player)
    local rows, order = {}, {}
    local items = player:getInventory():getAllEvalRecurse(function()
        return true
    end, ArrayList.new())
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = item.getFullType and item:getFullType()
        if fullType and Market.isListable(fullType) then
            local row = rows[fullType]
            if not row then
                row = {
                    fullType = fullType,
                    itemName = item:getName(),
                    count = 0,
                    stackable = Snapshot.isStackable(item)
                }
                rows[fullType] = row
                table.insert(order, fullType)
            end
            row.count = row.count + 1
        end
    end
    return rows, order
end

Core.registerShopMode({
    key = "sell",
    label = "IGUI_PhleaMarket_Mode_Sell",
    order = 20,
    flag = "consignment",

    onEnter = function(ui)
        -- Nothing to fetch: what can be sold is in the player's own bag. The
        -- window is still noted, so a reply to somebody else's command can
        -- redraw this one.
        Modes.window = ui
        ui._phleaSell = nil
    end,

    getGridData = function(ui)
        local rows = listableInventory(ui.player)
        ui._phleaSell = rows
        local offers = {}
        for fullType, row in pairs(rows) do
            -- Priced at nothing: the seller has not said what they want for it
            -- yet, and showing a made-up figure would be showing them a number
            -- they did not choose.
            offers[fullType] = asOffer(fullType, fullType, 0, "change", row.count)
        end
        return gridOf(ui, offers)
    end,

    actionLabel = function()
        return getText("IGUI_PhleaMarket_List")
    end,

    canAction = function(ui, offer, id)
        return id ~= nil
    end,

    onAction = function(ui)
        local row = ui._phleaSell and ui._phleaSell[ui.selectedId]
        if row then
            Market.ui.askPrice(ui, row)
        end
    end
})

---------------------------------------------------------------------------
-- Mine
---------------------------------------------------------------------------

Core.registerShopMode({
    key = "mine",
    label = "IGUI_PhleaMarket_Mode_Mine",
    order = 30,
    flag = "consignment",

    onEnter = function(ui)
        refresh(ui, C.mine)
    end,

    getGridData = function(ui)
        local mine = Client.data.mine
        if not (mine and mine.listings) then
            return emptyGrid(ui)
        end
        local offers = {}
        for _, listing in ipairs(mine.listings) do
            offers[listing.id] = asOffer(listing.id, listing.fullType, listing.unitPrice and
                listing.unitPrice.amount, listing.unitPrice and listing.unitPrice.pool, listing.qty)
        end
        return gridOf(ui, offers)
    end,

    actionLabel = function()
        return getText("IGUI_PhleaMarket_Cancel")
    end,

    canAction = function(ui, offer, id)
        return id ~= nil
    end,

    onAction = function(ui)
        if not ui.selectedId then
            return
        end
        Client.send(C.cancel, {
            listingId = ui.selectedId
        })
    end
})

---------------------------------------------------------------------------
-- Returns
---------------------------------------------------------------------------

Core.registerShopMode({
    key = "returns",
    label = "IGUI_PhleaMarket_Mode_Returns",
    order = 40,
    flag = "consignment",

    onEnter = function(ui)
        refresh(ui, C.mine)
    end,

    getGridData = function(ui)
        local mine = Client.data.mine
        local queue = mine and mine.returns
        if not queue then
            return emptyGrid(ui)
        end
        local offers = {}
        for index, entry in ipairs(queue.items or {}) do
            -- Keyed by position rather than by anything on the entry, because
            -- relist names the entry by its place in the queue and the two have
            -- to agree.
            offers["return:" .. index] = asOffer("return:" .. index, entry.fullType,
                entry.unitPrice and entry.unitPrice.amount, entry.unitPrice and entry.unitPrice.pool, entry.qty)
        end
        return gridOf(ui, offers)
    end,

    actionLabel = function()
        return getText("IGUI_PhleaMarket_Collect")
    end,

    canAction = function(ui, offer, id)
        local queue = Client.data.mine and Client.data.mine.returns
        if not queue then
            return false
        end
        -- Live whenever there is anything at all to collect, including money
        -- with no item beside it, which the grid has no way to show.
        return (#(queue.items or {}) + #(queue.credits or {})) > 0
    end,

    onAction = function(ui)
        Client.send(C.collect)
    end
})

---------------------------------------------------------------------------
-- Helpers the modes share
---------------------------------------------------------------------------

function Modes.username()
    local player = getPlayer()
    return player and player:getUsername()
end

--- The browse row behind a selected tile, for the things an offer cannot say.
function Modes.rowFor(ui, offer)
    if not (offer and ui and ui.selectedId) then
        return nil
    end
    local browse = Client.data.browse
    for _, row in ipairs(browse and browse.listings or {}) do
        if row.id == ui.selectedId then
            return row
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Redrawing when an answer arrives
---------------------------------------------------------------------------

-- The window asks and carries on. When the reply lands the grid is rebuilt from
-- whatever mode is showing, so a mode never has to know which reply it was
-- waiting for.
Events[Market.events.OnData].Add(function(kind, payload)
    local window = Modes.window
    -- Closed since it asked, or never opened. onEnter sets this and nothing
    -- clears it, so the visibility check is what makes a stale reference safe.
    if not (window and window.isVisible and window:isVisible()) then
        return
    end
    if kind == "result" and payload and payload.failed then
        window:showFeedback(Market.ui.failureText(payload.message), 0.9, 0.3, 0.3)
    elseif kind == "result" then
        window:showFeedback(Market.ui.successText(payload), 0.4, 0.9, 0.4)
        -- A sale, a cancel or a collect all change what every mode is showing,
        -- so ask again rather than working out which.
        Client.send(C.browse)
        Client.send(C.mine)
    end
    if window.refreshGrid then
        window:refreshGrid()
    end
end)

return Modes
