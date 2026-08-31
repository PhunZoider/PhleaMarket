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

local W, H = 320, 250

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
    -- Prefilled with what they asked for one of these last time, which is very
    -- often what they want again, and is the whole reason the server remembers.
    self.priceBox:setText(tostring(Market.lastAsk and Market.lastAsk[self.row.fullType] or
                                       Market.limits().minPrice))
    self:addChild(self.priceBox)
    y = y + lineH + math.floor(6 * FS)

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
end

function Dialog:onOK()
    local price, qty = self:values()
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
