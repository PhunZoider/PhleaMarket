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

require "ISUI/ISComboBox"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "PhleaMarket/core"
require "PhleaMarket/commands"
require "PhleaMarket_Client/commands"

local Core = PhunMart
local Market = PhleaMarket
local tools = require "PhunMart_Client/ui/ui_utils"
local Snapshot = require "PhleaMarket/item_snapshot"
local Client = Market.client
local C = Market.commands
local FS = tools.FONT_SCALE

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

--- The display category of an item type, as the grid would group it.
---
--- Read from the script rather than sent with the listing, because it is the
--- same answer for every listing of a type and the client already has it.
--- What to call an item type on screen.
---
--- Asked of the script rather than taken from the listing. A listing carries
--- the name the item had when it was listed, which can be absent on anything
--- made before that field existed, and the heading then read "Base.ShotgunShells"
--- while the tile beside it said "12g Round". The script is the same answer the
--- grid uses, so the two cannot disagree.
local function displayNameOf(fullType)
    local manager = getScriptManager()
    local script = manager and manager:getItem(fullType)
    local name = script and script:getDisplayName()
    if name and name ~= "" then
        return name
    end
    return fullType
end

local function categoryOf(fullType)
    local manager = getScriptManager()
    local script = manager and manager:getItem(fullType)
    local category = script and script:getDisplayCategory()
    if not category or category == "" then
        return "Other"
    end
    return category
end

--- Whether a listing survives the filter strip.
---
--- Case-insensitive substring on the item name, and a leading @ switches to the
--- seller instead: @steve finds everything Steve has up, which is the question
--- players actually ask each other.
local function matches(ui, row)
    local state = ui._phleaFilter
    if not state then
        return true
    end
    if state.category and state.category ~= "" and categoryOf(row.fullType) ~= state.category then
        return false
    end
    local search = state.search
    if not search or search == "" then
        return true
    end
    search = search:lower()
    if search:sub(1, 1) == "@" then
        local who = search:sub(2)
        if who == "" then
            return true
        end
        return ((row.sellerChar or "") .. " " .. (row.seller or "")):lower():find(who, 1, true) ~= nil
    end
    return ((row.itemName or "") .. " " .. (row.fullType or "")):lower():find(search, 1, true) ~= nil
end

--- Which item type the player has opened, or nil while looking at all of them.
---
--- Browsing a market is two questions, and answering them on one screen is what
--- made a busy market unreadable: what is for sale at all, and then who is
--- selling this particular thing and for how much. So the grid shows one tile
--- per item type, and opening one shows the listings underneath it.
local function groupOf(ui)
    return ui._phleaGroup
end

local function openGroup(ui, fullType)
    ui._phleaGroup = fullType
    Client.data.group = nil
    Modes.window = ui
    Client.send(C.group, {
        fullType = fullType
    })
    ui:buildModeFilter()
    ui:refreshGrid()
end

local function closeGroup(ui)
    ui._phleaGroup = nil
    ui:buildModeFilter()
    ui:refreshGrid()
end

--- Searching by seller answers a question about listings, not about item types,
--- so it drops out of the grouped view and shows the listings directly. A
--- summary carries no seller to match against, and inventing one would be
--- pretending the grouping knows something it does not.
local function isSellerSearch(ui)
    local state = ui._phleaFilter
    local search = state and state.search
    return type(search) == "string" and search:sub(1, 1) == "@" and #search > 1
end

Core.registerShopMode({
    key = "market",
    label = "IGUI_PhleaMarket_Mode_Buy",
    order = 5,
    flag = "consignment",

    onEnter = function(ui)
        ui._phleaGroup = nil
        refresh(ui, C.browse)
    end,

    onExit = function(ui)
        ui._phleaGroup = nil
    end,

    --- The strip changes with the view. Browsing types, it narrows them: a
    --- category dropdown and a search box, both filtering what is already here
    --- rather than asking again, because a search that round-trips on every
    --- keystroke is unusable at any latency. Inside a type, it says which one
    --- and offers the way back.
    createFilter = function(ui, x, y, w, h)
        ui._phleaFilter = ui._phleaFilter or {}
        local state = ui._phleaFilter

        local fullType = groupOf(ui)
        if fullType then
            local backW = math.floor(70 * FS)
            local back = ISButton:new(x, y, backW, h, getText("IGUI_PhleaMarket_Back"), ui, function(target)
                closeGroup(target)
            end)
            back:initialise()
            back:instantiate()
            back.font = UIFont.Small

            -- The spread, said here because the grid draws one price per tile
            -- and a range is two. This is the first place it can be told.
            --
            -- "from" only when there is a spread to speak of. Two listings at
            -- the same price are not a range, and saying "$1.00 to $1.00" makes
            -- a reader look twice at nothing.
            local guide = Client.data.group and Client.data.group.guide
            local rows = Client.data.group and Client.data.group.rows
            local text = displayNameOf(fullType)
            if guide then
                local key = guide.low == guide.high and "IGUI_PhleaMarket_GroupHeadingFlat" or
                                "IGUI_PhleaMarket_GroupHeading"
                text = getText(key, text, Market.formatAmount("change", guide.low), tostring(#(rows or {})))
            end

            -- Cut to what is left of the strip. A label draws its whole string
            -- whatever it is given, so a long item name ran off the end and over
            -- the machine beside it.
            local labelX = x + backW + math.floor(8 * FS)
            text = tools.truncate(text, (x + w) - labelX, UIFont.Small)

            local label = ISLabel:new(labelX, y, h, text, 0.85, 0.85, 0.85, 1, UIFont.Small, true)
            label:initialise()

            return {back, label}
        end

        local comboW = math.floor(w * 0.42)
        local combo = ISComboBox:new(x, y, comboW, h, ui, function(target, box)
            -- The option data, not its text: the labels carry a count, so the
            -- text no longer is the category name.
            state.category = box:getOptionData(box.selected)
            target:refreshGrid()
        end)
        combo:initialise()
        combo.font = UIFont.Small
        Modes.fillCategories(combo, state.category)

        local box = ISTextEntryBox:new(state.search or "", x + comboW + math.floor(4 * FS), y, w - comboW -
            math.floor(4 * FS), h)
        box:initialise()
        box:instantiate()
        box.onTextChange = function()
            state.search = box:getInternalText()
            ui:refreshGrid()
        end
        box:setTooltip(getText("IGUI_PhleaMarket_SearchHint"))

        ui._phleaCombo = combo
        return {combo, box}
    end,

    getGridData = function(ui)
        local browse = Client.data.browse
        if not browse then
            return emptyGrid(ui)
        end

        local fullType = groupOf(ui)
        local offers = {}

        if fullType then
            -- The listings under one type, as the server ordered them: cheapest
            -- first, then oldest first.
            for _, row in ipairs((Client.data.group and Client.data.group.rows) or {}) do
                offers[row.id] = asOffer(row.id, fullType, row.unit, row.pool, row.qty)
            end
            return gridOf(ui, offers)
        end

        Modes.fillCategories(ui._phleaCombo, ui._phleaFilter and ui._phleaFilter.category, browse.listings)

        -- Looking for a seller is a question about listings, so it answers with
        -- listings rather than with the types they happen to be.
        if isSellerSearch(ui) then
            for _, row in ipairs(browse.listings or {}) do
                if matches(ui, row) then
                    offers[row.id] = asOffer(row.id, row.fullType, row.unit, row.pool, row.qty)
                end
            end
            return gridOf(ui, offers)
        end

        -- One tile per item type: the lowest anybody is asking, and how many
        -- are to be had across every listing of it.
        for _, row in ipairs(browse.rows or {}) do
            if matches(ui, row) then
                offers["type:" .. row.fullType] = asOffer("type:" .. row.fullType, row.fullType, row.low, "change",
                    row.available)
            end
        end
        return gridOf(ui, offers)
    end,

    actionLabel = function(ui, offer)
        if not groupOf(ui) and not isSellerSearch(ui) then
            return getText("IGUI_PhleaMarket_View")
        end
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
        -- Opening a type asks nothing of the wallet. Even a market of listings
        -- nobody can afford is worth being able to look at.
        if not groupOf(ui) and not isSellerSearch(ui) then
            return true
        end
        local price = offer and offer.price
        if not price then
            return false
        end
        return (Core.wallet:getBalance(ui.player, price.pool) or 0) >= (price.amount or 0)
    end,

    --- What the tile above is standing for.
    ---
    --- The price and stock lines are true and incomplete on a grouped tile: the
    --- figure is the lowest anybody is asking and the count is spread across
    --- several sellers. Saying so is the difference between a figure and a
    --- misleading one, and it is what makes a type worth opening -- or not.
    detailLines = function(ui, offer)
        if groupOf(ui) or isSellerSearch(ui) then
            -- A single listing. Who is selling it is the useful fact here, and
            -- the price above is simply the price.
            local row = Modes.rowFor(ui, offer)
            if not row then
                return nil
            end
            return {{
                text = getText("IGUI_PhleaMarket_SoldBy", row.sellerChar or row.seller or "?")
            }}
        end

        local fullType = tostring(ui.selectedId or ""):match("^type:(.+)$")
        if not fullType then
            return nil
        end
        for _, row in ipairs((Client.data.browse and Client.data.browse.rows) or {}) do
            if row.fullType == fullType then
                -- One listing is worth saying outright. It is the case that
                -- looks oddest after opening -- a page holding a single row --
                -- and knowing beforehand turns that from a surprise into what
                -- was expected.
                if row.listings == 1 then
                    return {{
                        text = getText("IGUI_PhleaMarket_OneListing")
                    }}
                end
                return {{
                    text = getText("IGUI_PhleaMarket_FromPrice", Market.formatAmount("change", row.low))
                }, {
                    text = getText("IGUI_PhleaMarket_AcrossListings", tostring(row.listings))
                }}
            end
        end
        return nil
    end,

    --- Double-click opens a type, or buys a listing.
    ---
    --- The same thing the action button does, on the motion people already make
    --- for it. Buying on a double-click is safe here in a way it would not be on
    --- a shop machine, because a listing is opened before it can be bought: the
    --- second click lands on a page the first one had to reach.
    onActivate = function(ui, id, offer)
        Market.modes.activate(ui)
    end,

    onAction = function(ui)
        Market.modes.activate(ui)
    end
})

--- Open the selected type, or buy the selected listing.
---
--- Shared by the action button and the double-click so the two cannot drift.
function Modes.activate(ui)
    if not ui.selectedId then
        return
    end
    if not groupOf(ui) and not isSellerSearch(ui) then
        -- Opened even when there is only one listing under it. That page is
        -- then a confirmation: who is selling, what condition it is in and what
        -- they want, before any money moves.
        local fullType = tostring(ui.selectedId):match("^type:(.+)$")
        if fullType then
            openGroup(ui, fullType)
        end
        return
    end
    -- How many, when there is more than one to be had. Buying fifty nails was
    -- fifty presses of the same button, and the server had taken a quantity
    -- since the day it was written -- the client simply never asked for one.
    local row = Modes.rowFor(ui, ui.selectedOffer)
    if row then
        Market.ui.askQuantity(row)
        return
    end
    Client.send(C.buy, {
        listingId = ui.selectedId,
        qty = 1
    })
end

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
    local byType = {}
    local items = player:getInventory():getAllEvalRecurse(function()
        return true
    end, ArrayList.new())
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local fullType = item.getFullType and item:getFullType()
        if fullType and Market.isListable(fullType) then
            if not byType[fullType] then
                byType[fullType] = {}
                table.insert(order, fullType)
                rows[fullType] = {
                    fullType = fullType,
                    itemName = item:getName()
                }
            end
            table.insert(byType[fullType], item)
        end
    end

    -- The count offered is how many are alike, not how many are held.
    --
    -- A listing carries one snapshot, so a stack is only honest while every
    -- item in it would have produced that same snapshot. Ninety-eight fresh
    -- shells and two that differ is a stack of ninety-eight, and the server
    -- picks the same ones by the same rule when it takes them.
    for fullType, list in pairs(byType) do
        local alike = Snapshot.countAlike(list)
        rows[fullType].count = alike
        rows[fullType].held = #list
        rows[fullType].stackable = alike > 1
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

--- The label on the first entry in the dropdown, which carries no category
--- data and therefore means no filter. Resolved on first use rather than at
--- load, since getText wants the translations loaded.
Modes.ALL_CATEGORIES = nil

--- Fill the dropdown from the categories actually on the market.
---
--- Built from what is listed rather than from every category in the game, so a
--- player is never offered a filter that empties the grid, and the counts say
--- how much is behind each one. Rebuilt whenever the listings change, keeping
--- the current choice if it still exists.
function Modes.fillCategories(combo, current, listings)
    if not combo then
        return
    end
    Modes.ALL_CATEGORIES = getText("IGUI_PhleaMarket_AllCategories")

    listings = listings or (Client.data.browse and Client.data.browse.listings) or {}
    local counts, names = {}, {}
    for _, row in ipairs(listings) do
        local category = categoryOf(row.fullType)
        if not counts[category] then
            counts[category] = 0
            table.insert(names, category)
        end
        counts[category] = counts[category] + 1
    end
    table.sort(names)

    -- Nothing changed, so leave it alone: rebuilding a dropdown a player has
    -- open closes it under them.
    local signature = table.concat(names, "|")
    if combo._phleaSignature == signature then
        return
    end
    combo._phleaSignature = signature

    combo:clear()
    -- nil data on the first entry is what "no filter" means downstream.
    combo:addOptionWithData(Modes.ALL_CATEGORIES, nil)
    local selected = 1
    for i, name in ipairs(names) do
        combo:addOptionWithData(name .. "  (" .. counts[name] .. ")", name)
        if name == current then
            selected = i + 1
        end
    end
    combo.selected = selected
end

function Modes.username()
    local player = getPlayer()
    return player and player:getUsername()
end

--- The browse row behind a selected tile, for the things an offer cannot say.
function Modes.rowFor(ui, offer)
    if not (offer and ui and ui.selectedId) then
        return nil
    end
    -- The open group first: inside one, that is where the selected listing is,
    -- and the browse reply does not necessarily still hold it.
    local group = Client.data.group
    for _, row in ipairs(group and group.rows or {}) do
        if row.id == ui.selectedId then
            return row
        end
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
        -- Including the open group. Without this the listing just bought stayed
        -- on screen, and buying it again asked the server for something that had
        -- already gone -- which answered, correctly and uselessly, that somebody
        -- got there first. That somebody was you, a moment ago.
        local openType = window._phleaGroup
        if openType then
            Client.send(C.group, {
                fullType = openType
            })
        end
    end
    -- A group reply changes the heading as well as the grid: the spread and
    -- the count are only known once the listings arrive.
    if kind == "group" and window.buildModeFilter then
        window:buildModeFilter()
    end
    if window.refreshGrid then
        window:refreshGrid()
    end
end)

return Modes
