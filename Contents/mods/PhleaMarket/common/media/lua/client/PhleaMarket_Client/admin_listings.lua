if isServer() then
    return
end

-- The Listings tab in PhunMart's admin shell.
--
-- Two jobs, and the second is the one that matters. The first is seeing what is
-- on the market and being able to pull something off it. The second is the
-- ledger: the first time two players disagree about who was paid what, this is
-- the only thing that can settle it, and the answer has to already be recorded
-- by the time anybody thinks to ask.
--
-- Built on PhunMart's ListPanel, the same base its nine admin screens use, so
-- sorting, filtering, the button bar and the row drawing all come as they are.
-- Registered through Core.registerAdminTab, which is what lets a screen for a
-- machine PhunMart does not know about sit beside the ones it does.

require "ISUI/ISModalDialog"
require "PhleaMarket/core"
require "PhleaMarket/commands"
require "PhleaMarket_Client/commands"

local Core = PhunMart
local Market = PhleaMarket
local ListPanel = require "PhunMart_Client/ui/base/list_panel"
local Listings = require "PhleaMarket/listings"
local Client = Market.client
local C = Market.commands

Core.ui.phlea_listings = ListPanel:derive("PhleaMarketAdminListings")
Core.ui.phlea_listings.instances = {}
local UI = Core.ui.phlea_listings

--- Hours as something a person reads. World age is a running total, so the
--- useful thing is always the distance from now, not the number itself.
local function relativeHours(hours)
    if type(hours) ~= "number" then
        return "-"
    end
    local now = GameTime:getInstance():getWorldAgeHours()
    local delta = hours - now
    local past = delta < 0
    delta = math.abs(delta)
    local text
    if delta < 1 then
        text = getText("IGUI_PhleaMarket_Adm_Soon")
    elseif delta < 48 then
        text = getText("IGUI_PhleaMarket_Adm_Hours", tostring(math.floor(delta)))
    else
        text = getText("IGUI_PhleaMarket_Adm_Days", tostring(math.floor(delta / 24)))
    end
    if past then
        return getText("IGUI_PhleaMarket_Adm_Ago", text)
    end
    return text
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function UI.createTab(player)
    local playerIndex = player:getPlayerNum()
    local instance = UI.instances[playerIndex]
    if not instance then
        instance = UI:new(0, 0, 100, 100, player)
        instance.description = getText("IGUI_PhleaMarket_Adm_Desc")
        instance:initialise()
        UI.instances[playerIndex] = instance
    end
    return instance
end

function UI:createChildren()
    ListPanel.createChildren(self)

    self.list.doDrawItem = ListPanel.defaultDrawRow

    -- Active first, because that is what an admin has come to look at. The
    -- ledger is last and is a different kind of thing entirely: not listings,
    -- but what has happened to them.
    self:addFilterTabs({{
        key = "active",
        label = getText("IGUI_PhleaMarket_Adm_Active")
    }, {
        key = "all",
        label = getText("IGUI_PhleaMarket_Adm_All")
    }, {
        key = "log",
        label = getText("IGUI_PhleaMarket_Adm_Ledger")
    }})

    -- Every column sorts. `sort` is opt-in per column rather than a property of
    -- the panel, so a column that has no meaningful order can simply not offer
    -- one; here they all do.
    --
    -- The three on the right sort on a number rather than on what they display,
    -- because what they display is text: sorted as written, 9 comes after 10,
    -- $1.00 after $0.05, and "3d" after "20h". A column that sorts visibly
    -- wrongly is worse than one that does not sort at all.
    self:addListColumn(getText("IGUI_PhleaMarket_Adm_Item"), 0, {
        field = "name",
        sort = true
    })
    self:addListColumn(getText("IGUI_PhleaMarket_Adm_Seller"), 0.34, {
        field = "who",
        color = {0.75, 0.75, 0.75},
        sort = true
    })
    self:addListColumn(getText("IGUI_PhleaMarket_Adm_Qty"), 0.55, {
        field = "qtyText",
        align = "right",
        sort = function(data)
            return data.qtyValue or 0
        end
    })
    self:addListColumn(getText("IGUI_PhleaMarket_Adm_Price"), 0.66, {
        field = "priceText",
        align = "right",
        sort = function(data)
            return data.priceValue or 0
        end
    })
    self:addListColumn(getText("IGUI_PhleaMarket_Adm_When"), 0.80, {
        field = "whenText",
        color = {0.7, 0.7, 0.7},
        sort = function(data)
            return data.whenValue or 0
        end
    })

    self:addBottomButton(getText("IGUI_PhleaMarket_Adm_Refresh"), self.onRefresh)
    self:addBottomButton(getText("IGUI_PhleaMarket_Adm_Pull"), self.onPull, true)
end

--- Ask the server for what this panel is showing.
---
--- The ledger is only fetched while the Ledger tab is the one on screen. It is
--- the largest thing this mod ever sends, capped by a setting an admin may put
--- into the thousands, and it used to be fetched again on every result, so
--- pulling one listing dragged the entire history down the wire behind it. The
--- other two tabs never render a ledger row, so they never need one.
---
--- Switching to the Ledger asks for it, which is the tab change below.
function UI:requestData()
    Client.send(C.adminList)
    if self._activeFilterTab == "log" then
        Client.send(C.adminLog)
    end
end

UI.refresh = UI.requestData

function UI:onRefresh()
    self:requestData()
end

--- Fetch the ledger the first time it is asked to be shown.
---
--- The base switches tab and refilters, which is all the other two need since
--- their rows are already here. The ledger is not fetched up front, so opening
--- that tab is the moment to go and get it. Once only: it is asked for again on
--- any result while the tab is up, and Refresh is there for anything else.
function UI:onFilterTabClick(btn)
    ListPanel.onFilterTabClick(self, btn)
    if self._activeFilterTab == "log" and not self.log then
        Client.send(C.adminLog)
    end
end

--- What the filter box searches.
---
--- The base falls back to the row's display text when a panel does not answer
--- this, which is effectively the first column alone. Everything worth looking
--- something up by goes in: the item name and its type, the seller by character
--- and by account, the status, and the ledger event -- so "BUY", "steve",
--- "Base.Axe" and "EXPIRED" all find what a person means by them.
function UI:getFilterText(itemData)
    return table.concat({itemData.name or "", itemData.fullType or "", itemData.who or "", itemData.status or "",
                         itemData.event or ""}, " ")
end

function UI:rowInFilterTab(itemData, tabKey)
    if tabKey == "log" then
        return itemData.kind == "log"
    end
    if itemData.kind == "log" then
        return false
    end
    if tabKey == "active" then
        return itemData.status == Listings.STATUS.ACTIVE
    end
    return true
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

function UI:refreshList()
    self:clearList()

    for _, listing in ipairs(self.listings or {}) do
        local unit = listing.unitPrice and listing.unitPrice.amount or 0
        local pool = listing.unitPrice and listing.unitPrice.pool or Market.currencyPool()
        self:addListItem(listing.itemName or listing.fullType, {
            kind = "listing",
            key = listing.id,
            id = listing.id,
            name = listing.itemName or listing.fullType,
            -- The character who listed it, with the account behind it, because
            -- a ban is applied to an account and a complaint names a survivor.
            who = (listing.sellerChar or listing.seller or "?") .. " (" .. (listing.seller or "?") .. ")",
            status = listing.status,
            fullType = listing.fullType,
            qtyText = tostring(listing.qty or 0) .. "/" .. tostring(listing.qtyListed or 0),
            priceText = Market.formatAmount(pool, unit),
            whenText = listing.status == Listings.STATUS.ACTIVE and relativeHours(listing.expiresAt) or
                (listing.status or ""):lower(),
            -- What the three right-hand columns sort on. Kept beside the text
            -- rather than parsed back out of it, which is the other way this
            -- gets done and the way that breaks the moment the wording changes.
            qtyValue = listing.qty or 0,
            priceValue = unit,
            whenValue = listing.expiresAt or listing.listedAt or 0
        })
    end

    -- Newest first. A ledger is read from the end: what just happened is what
    -- somebody is asking about.
    local log = self.log or {}
    for i = #log, 1, -1 do
        local entry = log[i]
        local amount = entry.net or entry.gross or entry.fee
        self:addListItem(entry.item or entry.event, {
            kind = "log",
            key = "log:" .. i,
            name = (entry.event or "?") .. "  " .. (entry.item or ""),
            who = entry.actor or "?",
            event = entry.event,
            fullType = entry.item,
            qtyText = entry.qty and tostring(entry.qty) or "",
            priceText = amount and Market.formatAmount(Market.currencyPool(), amount) or "",
            whenText = relativeHours(entry.at),
            qtyValue = entry.qty or 0,
            priceValue = amount or 0,
            whenValue = entry.at or 0
        })
    end
end

---------------------------------------------------------------------------
-- Pulling a listing
---------------------------------------------------------------------------

function UI:onPull()
    local row = self:selectedRow()
    if not row or row.kind ~= "listing" then
        return
    end
    if row.status ~= Listings.STATUS.ACTIVE then
        return
    end

    -- Says where the goods go, because that is the part an admin is entitled to
    -- be nervous about. Pulling a listing takes it off the market; it does not
    -- take somebody's axe away from them.
    local w = math.floor(380 * ListPanel.FONT_SCALE)
    local h = math.floor(150 * ListPanel.FONT_SCALE)
    local modal = ISModalDialog:new((getCore():getScreenWidth() - w) / 2, (getCore():getScreenHeight() - h) / 2, w, h,
        getText("IGUI_PhleaMarket_Adm_PullConfirm", row.name, row.who), true, self, UI.onPullConfirm,
        self.player:getPlayerNum(), row.id)
    modal:initialise()
    modal:addToUIManager()
end

function UI:onPullConfirm(button, listingId)
    if button.internal ~= "YES" then
        return
    end
    Client.send(C.adminCancel, {
        listingId = listingId
    })
end

---------------------------------------------------------------------------
-- Data in
---------------------------------------------------------------------------

function UI:setData(payload)
    payload = payload or {}
    -- Two commands answer into one panel, and either may arrive first, so each
    -- only replaces the half it carries.
    if payload.listings then
        self.listings = payload.listings
    end
    if payload.log then
        self.log = payload.log
    end
    self:refreshList()
end

Events[Market.events.OnData].Add(function(kind, payload)
    if kind == "admin" then
        for _, instance in pairs(UI.instances or {}) do
            instance:setData(payload)
        end
        return
    end

    -- Anything that changed the market changed this list, and a pull made from
    -- this very panel is the obvious case: without this the row an admin just
    -- took off sale sits there until they press Refresh, looking as though the
    -- button did nothing. Asked for again rather than patched locally, because
    -- the server is the one that knows whether it worked.
    if kind == "result" then
        for _, instance in pairs(UI.instances or {}) do
            if instance:isLive() then
                instance:requestData()
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

-- Between Rewards and Wallets on PhunMart's strip. The shipped tabs are spaced
-- ten apart precisely so a mod can sit between two of them without renumbering
-- anything, and this belongs beside the screens about what players hold rather
-- than among the ones that define what machines sell.
Core.registerAdminTab({
    key = "phlea_listings",
    module = "phlea_listings",
    label = "IGUI_PhleaMarket_Adm_Tab",
    order = 95
})

return UI
