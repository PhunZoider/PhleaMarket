if isServer() then
    return
end

-- Naming a price, and saying what happened.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "PhleaMarket/core"
require "PhleaMarket/commands"
require "PhleaMarket_Client/commands"

local Core = PhunMart
local Market = PhleaMarket
local tools = require "PhunMart_Client/ui/ui_utils"
local Client = Market.client
local C = Market.commands

local UI = {}
Market.ui = UI

local FS = tools.FONT_SCALE
local FONT_SM = tools.FONT_HGT_SMALL

---------------------------------------------------------------------------
-- Words
---------------------------------------------------------------------------

-- Every reason a command can refuse, in the words a player would use.
--
-- Mapped rather than shown raw: "NotStackable" is the server explaining itself
-- to another programmer, and a message that says what went wrong without saying
-- what to do about it is only half an error.
local FAILURES = {
    Disabled = "IGUI_PhleaMarket_Err_Disabled",
    NoItem = "IGUI_PhleaMarket_Err_NoItem",
    NotListable = "IGUI_PhleaMarket_Err_NotListable",
    NotStackable = "IGUI_PhleaMarket_Err_NotStackable",
    NotHeld = "IGUI_PhleaMarket_Err_NotHeld",
    NotEnough = "IGUI_PhleaMarket_Err_NotEnough",
    TooManyListings = "IGUI_PhleaMarket_Err_TooManyListings",
    PriceTooLow = "IGUI_PhleaMarket_Err_PriceTooLow",
    PriceTooHigh = "IGUI_PhleaMarket_Err_PriceTooHigh",
    BadPrice = "IGUI_PhleaMarket_Err_BadPrice",
    CannotAffordFee = "IGUI_PhleaMarket_Err_CannotAffordFee",
    InsufficientFunds = "IGUI_PhleaMarket_Err_InsufficientFunds",
    NotFound = "IGUI_PhleaMarket_Err_NotFound",
    NotActive = "IGUI_PhleaMarket_Err_NotActive",
    NotYours = "IGUI_PhleaMarket_Err_NotYours",
    ItemUnavailable = "IGUI_PhleaMarket_Err_ItemUnavailable",
    CouldNotDeliver = "IGUI_PhleaMarket_Err_CouldNotDeliver",
    CouldNotList = "IGUI_PhleaMarket_Err_CouldNotList"
}

function UI.failureText(message)
    local key = FAILURES[message]
    if key then
        return getText(key)
    end
    return getText("IGUI_PhleaMarket_Err_Unknown", tostring(message))
end

function UI.successText(payload)
    payload = payload or {}
    if payload.action == "list" or payload.action == "relist" then
        if (payload.fee or 0) > 0 then
            return getText("IGUI_PhleaMarket_Msg_ListedWithFee", Market.formatAmount("change", payload.fee))
        end
        return getText("IGUI_PhleaMarket_Msg_Listed")
    elseif payload.action == "buy" then
        return getText("IGUI_PhleaMarket_Msg_Bought", tostring(payload.qty or 1))
    elseif payload.action == "cancel" then
        return getText("IGUI_PhleaMarket_Msg_Cancelled")
    elseif payload.action == "adminCancel" then
        return getText("IGUI_PhleaMarket_Msg_Cancelled")
    elseif payload.action == "collect" then
        -- Says what is still waiting rather than only what arrived. A collect
        -- that leaves money behind because the wallet is full otherwise looks
        -- like a collect that did nothing.
        if (payload.stillHeld or 0) > 0 then
            return getText("IGUI_PhleaMarket_Msg_CollectedPartial", Market.formatAmount("change", payload.stillHeld))
        end
        if (payload.keptBack or 0) > 0 then
            return getText("IGUI_PhleaMarket_Msg_CollectedNoRoom")
        end
        return getText("IGUI_PhleaMarket_Msg_Collected")
    end
    return getText("IGUI_PhleaMarket_Msg_Done")
end

---------------------------------------------------------------------------
-- Naming a price
---------------------------------------------------------------------------

local Dialog = ISPanel:derive("PhleaMarketPriceDialog")

-- Taller than the figures alone need, for the three lines of guidance under
-- them. Naming a price with nothing to go on is the hardest thing this mod
-- asks of a player, and it is the one place where a few numbers turn a guess
-- into a decision.
local W, H = 320, 330

function Dialog:new(x, y, window, row)
    local o = ISPanel:new(x, y, math.floor(W * FS), math.floor(H * FS))
    setmetatable(o, self)
    self.__index = self
    o.window = window
    o.row = row
    o.moveWithMouse = true
    o.backgroundColor = {
        r = 0.05,
        g = 0.05,
        b = 0.06,
        a = 0.95
    }
    o.borderColor = {
        r = 0.25,
        g = 0.45,
        b = 0.28,
        a = 1
    }
    o.duration = "medium"
    return o
end

function Dialog:createChildren()
    ISPanel.createChildren(self)
    local pad = math.floor(12 * FS)
    local lineH = FONT_SM + math.floor(8 * FS)
    local y = pad + FONT_SM * 2

    local boxW = math.floor(90 * FS)
    self.priceBox = ISTextEntryBox:new("", self.width - pad - boxW, y, boxW, lineH)
    self.priceBox:initialise()
    self.priceBox:instantiate()
    self.priceBox:setOnlyNumbers(true)
    -- Opens at the floor, and moves to what this account asked for one of these
    -- last time once the server says. That answer cannot be here yet -- it is
    -- still in flight when the dialog is built -- so render applies it, and only
    -- while the box still holds this untouched starting value.
    self._initialText = tostring(Market.lastAsk and Market.lastAsk[self.row.fullType] or Market.limits().minPrice)
    self.priceBox:setText(self._initialText)
    self:addChild(self.priceBox)

    -- A line's worth of room under the box for the allowed range. A limit a
    -- seller only discovers by being refused is a limit that should have been
    -- on screen before they typed.
    self.rangeY = y + lineH + math.floor(2 * FS)
    y = y + lineH + FONT_SM + math.floor(8 * FS)

    -- Only offered for something where every one is interchangeable. A stack of
    -- axes cannot be listed as a stack, because the listing holds one snapshot
    -- and the rest would come back wearing its condition.
    if self.row.stackable and self.row.count > 1 then
        self.qtyBox = ISTextEntryBox:new("1", self.width - pad - boxW, y, boxW, lineH)
        self.qtyBox:initialise()
        self.qtyBox:instantiate()
        self.qtyBox:setOnlyNumbers(true)
        self:addChild(self.qtyBox)
        y = y + lineH + math.floor(6 * FS)
    end
    self.qtyY = y

    local btnW = math.floor((self.width - pad * 2 - math.floor(8 * FS)) / 3)
    self.durationBtns = {}
    local tiers = {"short", "medium", "long"}
    for i, tier in ipairs(tiers) do
        local btn = ISButton:new(pad + (i - 1) * (btnW + math.floor(4 * FS)), y + FONT_SM + math.floor(4 * FS), btnW,
            lineH, getText("IGUI_PhleaMarket_Dur_" .. tier), self, Dialog.onDuration)
        btn.internal = tier
        btn:initialise()
        btn:instantiate()
        btn.font = UIFont.Small
        self:addChild(btn)
        self.durationBtns[tier] = btn
    end
    y = y + FONT_SM + lineH + math.floor(12 * FS)
    self.feeY = y

    local okW = math.floor((self.width - pad * 2 - math.floor(8 * FS)) / 2)
    self.okBtn = ISButton:new(pad, self.height - pad - lineH, okW, lineH, getText("IGUI_PhleaMarket_List"), self,
        Dialog.onOK)
    self.okBtn:initialise()
    self.okBtn:instantiate()
    self.okBtn.backgroundColor = {
        r = 0.06,
        g = 0.26,
        b = 0.08,
        a = 0.95
    }
    self:addChild(self.okBtn)

    self.cancelBtn = ISButton:new(self.width - pad - okW, self.height - pad - lineH, okW, lineH,
        getText("IGUI_PhleaMarket_Close"), self, Dialog.onCancel)
    self.cancelBtn:initialise()
    self.cancelBtn:instantiate()
    self:addChild(self.cancelBtn)

    self:paintDuration()
end

function Dialog:onDuration(btn)
    self.duration = btn.internal
    self:paintDuration()
end

function Dialog:paintDuration()
    for tier, btn in pairs(self.durationBtns) do
        local on = tier == self.duration
        btn.backgroundColor = on and {
            r = 0.09,
            g = 0.28,
            b = 0.10,
            a = 0.95
        } or {
            r = 0.08,
            g = 0.08,
            b = 0.09,
            a = 0.9
        }
        btn.borderColor = on and {
            r = 0.22,
            g = 0.72,
            b = 0.24,
            a = 1
        } or {
            r = 0.25,
            g = 0.25,
            b = 0.28,
            a = 1
        }
    end
end

function Dialog:values()
    local price = tonumber(self.priceBox:getInternalText()) or 0
    local qty = self.qtyBox and (tonumber(self.qtyBox:getInternalText()) or 1) or 1
    if qty < 1 then
        qty = 1
    end
    if qty > self.row.count then
        qty = self.row.count
    end
    return math.floor(price), math.floor(qty)
end

function Dialog:render()
    ISPanel.render(self)
    local pad = math.floor(12 * FS)
    local Listings = require "PhleaMarket/listings"

    self:drawText(getText("IGUI_PhleaMarket_ListTitle", self.row.itemName), pad, pad, 1, 1, 1, 1, UIFont.Medium)

    local priceY = pad + FONT_SM * 2
    self:drawText(getText("IGUI_PhleaMarket_UnitPrice"), pad, priceY + math.floor(4 * FS), 0.8, 0.8, 0.8, 1,
        UIFont.Small)
    if self.qtyBox then
        self:drawText(getText("IGUI_PhleaMarket_Quantity", tostring(self.row.count)), pad,
            self.qtyBox:getY() + math.floor(4 * FS), 0.8, 0.8, 0.8, 1, UIFont.Small)
    end
    self:drawText(getText("IGUI_PhleaMarket_Duration"), pad, self.qtyY, 0.8, 0.8, 0.8, 1, UIFont.Small)

    -- The exact figures the server will use, worked out from the same shared
    -- functions it will use, so what is shown here and what is charged cannot
    -- drift apart.
    local price, qty = self:values()
    local total = price * qty
    local fee = Market.listingFeeFor(total, self.duration)
    local commission = Listings.applyFee(Market.commissionRule(), total)
    local pool = "change"

    -- The allowed range, said before it is enforced rather than after. Shown
    -- only where there is a floor to speak of, since a minimum of zero is not
    -- a rule worth taking up a line.
    local limits = Market.limits()
    local tooLow = price < (limits.minPrice or 0)
    local tooHigh = price > (limits.maxPrice or math.huge)
    if (limits.minPrice or 0) > 0 or tooHigh then
        local text, r, g, b
        if tooLow then
            text = getText("IGUI_PhleaMarket_RangeTooLow", Market.formatAmount(pool, limits.minPrice))
            r, g, b = 0.95, 0.45, 0.4
        elseif tooHigh then
            text = getText("IGUI_PhleaMarket_RangeTooHigh", Market.formatAmount(pool, limits.maxPrice))
            r, g, b = 0.95, 0.45, 0.4
        else
            text = getText("IGUI_PhleaMarket_Range", Market.formatAmount(pool, limits.minPrice),
                Market.formatAmount(pool, limits.maxPrice))
            r, g, b = 0.55, 0.55, 0.55
        end
        self:drawText(text, pad, self.rangeY, r, g, b, 1, UIFont.Small)
    end

    -- Out of range cannot be listed, so the button says so by being dead. The
    -- alternative is what shipped: let them press it, send it, and explain
    -- afterwards.
    self.okBtn:setEnable(not tooLow and not tooHigh and price > 0)

    -- Beside the box, because a seller typing 5 has no way to know whether they
    -- have asked for a nickel or five dollars until they see it written out.
    self:drawText(Market.formatAmount(pool, price), self.priceBox:getX() - math.floor(64 * FS),
        priceY + math.floor(4 * FS), 0.6, 0.85, 0.6, 1, UIFont.Small)

    local y = self.feeY
    self:drawText(getText("IGUI_PhleaMarket_AskingTotal", Market.formatAmount(pool, total)), pad, y, 0.85, 0.85,
        0.85, 1, UIFont.Small)
    y = y + FONT_SM + math.floor(2 * FS)
    -- Named as non-refundable, because it is: cancelling a listing returns the
    -- goods and not the fee, and that is better learned before paying it.
    local feeKey = fee > 0 and "IGUI_PhleaMarket_FeeNow" or "IGUI_PhleaMarket_FeeFree"
    self:drawText(getText(feeKey, Market.formatAmount(pool, fee)), pad, y, 0.9, 0.75, 0.4, 1, UIFont.Small)
    y = y + FONT_SM + math.floor(2 * FS)
    -- Take-home, not the asking price. The number a seller actually cares about
    -- is what lands in their wallet if it all sells.
    self:drawText(getText("IGUI_PhleaMarket_YouGet", Market.formatAmount(pool, total - commission)), pad, y, 0.5,
        0.9, 0.5, 1, UIFont.Small)

    -- What anybody would want to know before naming a figure: what the market
    -- is asking for one of these, what it has actually been paying, and what
    -- this account asked the last time. Only shown for the item in hand, since
    -- a reply for a different one is worse than none.
    y = y + FONT_SM + math.floor(8 * FS)
    local info = Client.data.priceInfo
    if info and info.fullType == self.row.fullType then
        -- Fill in the remembered price, once, and never over something typed:
        -- an answer arriving a moment after the player started typing must not
        -- take the keyboard off them.
        if info.lastAsk and not self._prefilled then
            self._prefilled = true
            if self.priceBox:getInternalText() == self._initialText then
                self.priceBox:setText(tostring(info.lastAsk))
            end
        end

        local guide = info.guide
        if guide then
            self:drawText(getText("IGUI_PhleaMarket_Listed", Market.formatAmount(pool, guide.low),
                Market.formatAmount(pool, guide.high), tostring(guide.count)), pad, y, 0.7, 0.75, 0.85, 1,
                UIFont.Small)
        else
            self:drawText(getText("IGUI_PhleaMarket_NoneListed"), pad, y, 0.55, 0.55, 0.55, 1, UIFont.Small)
        end
        y = y + FONT_SM + math.floor(2 * FS)

        local sold = info.sold or {}
        if #sold > 0 then
            -- The most recent few rather than an average. An average of three
            -- sales says less than the three sales do, and hides that there
            -- were only three.
            local parts = {}
            for i = 1, math.min(#sold, 3) do
                table.insert(parts, Market.formatAmount(pool, sold[i].unit))
            end
            self:drawText(getText("IGUI_PhleaMarket_SoldFor", table.concat(parts, ", ")), pad, y, 0.7, 0.75, 0.85, 1,
                UIFont.Small)
        else
            self:drawText(getText("IGUI_PhleaMarket_NeverSold"), pad, y, 0.55, 0.55, 0.55, 1, UIFont.Small)
        end
        y = y + FONT_SM + math.floor(2 * FS)

        if info.lastAsk then
            self:drawText(getText("IGUI_PhleaMarket_YouAsked", Market.formatAmount(pool, info.lastAsk)), pad, y, 0.6,
                0.6, 0.6, 1, UIFont.Small)
        end
    end
end

function Dialog:onOK()
    local price, qty = self:values()

    -- The button is dead when the price is out of range, so this should not be
    -- reachable. Checked anyway: the enable state is set in render, and a
    -- dialog that has not drawn yet has never set it.
    local limits = Market.limits()
    if price <= 0 or price < (limits.minPrice or 0) or price > (limits.maxPrice or math.huge) then
        return
    end

    Client.send(C.list, {
        fullType = self.row.fullType,
        qty = qty,
        unitPrice = price,
        duration = self.duration,
        pool = "change"
    })
    -- Remembered locally as well as on the server, so the next listing in this
    -- session is prefilled even before the server answers.
    Market.lastAsk = Market.lastAsk or {}
    Market.lastAsk[self.row.fullType] = price
    self:onCancel()
end

function Dialog:onCancel()
    self:removeFromUIManager()
    self:setVisible(false)
end

--- Ask what they want for it.
function UI.askPrice(window, row)
    if UI.dialog then
        UI.dialog:onCancel()
    end

    -- Cleared before asking, so a stale answer for the last item cannot be read
    -- as this one's while the reply is in flight. render checks the type too;
    -- this stops the wrong figures appearing for even a frame.
    Client.data.priceInfo = nil
    Client.send(C.priceInfo, {
        fullType = row.fullType
    })
    local core = getCore()
    local x = math.floor((core:getScreenWidth() - W * FS) / 2)
    local y = math.floor((core:getScreenHeight() - H * FS) / 2)
    local dialog = Dialog:new(x, y, window, row)
    dialog:initialise()
    dialog:addToUIManager()
    UI.dialog = dialog
    return dialog
end

return UI
