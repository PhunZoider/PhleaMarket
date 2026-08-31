if isClient() then
    return
end

-- Where the market is wired to the world: incoming commands, and the clock.

require "PhleaMarket/core"
require "PhleaMarket/commands"
require "PhleaMarket_Server/store"

local Core = PhunMart
local Market = PhleaMarket
local Listings = require "PhleaMarket/listings"
local Store = require "PhleaMarket_Server/store"
local Commands = require "PhleaMarket_Server/commands"
local Simulated = require "PhleaMarket_Server/simulated"

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------

-- Answers only to its own module string. PhunMart's dispatcher ignores anything
-- that is not addressed to it and this does the same, so two mods can listen on
-- the one event without reading each other's post.
--
-- This fires in singleplayer too. sendClientCommand is delivered locally there;
-- it is sendServerCommand, the reply, that goes nowhere, which is why Store
-- .respond exists.
Events.OnClientCommand.Add(function(module, command, playerObj, args)
    if module ~= Market.module then
        return
    end
    local handler = Commands[command]
    if not handler then
        Market.debugLn("unknown command " .. tostring(command))
        return
    end
    if not playerObj then
        return
    end
    -- One bad command should not take the server's command dispatch with it.
    local ok, err = pcall(handler, playerObj, args)
    if not ok then
        print("[PhleaMarket] command " .. tostring(command) .. " failed: " .. tostring(err))
    end
end)

---------------------------------------------------------------------------
-- The clock
---------------------------------------------------------------------------

--- Expire what is due, then drop what nobody is coming back for.
---
--- Ten minutes is the same cadence PhunMart's playtime rewards run on, and it
--- is fine for something measured in in-game hours: the cost of a listing
--- outliving its expiry by a few minutes is nothing, and the cost of sweeping
--- every listing every tick is not.
local function tick()
    if not Market.isEnabled() then
        return
    end
    local store = Store.get()
    local now = Store.now()

    local expired = Listings.expireDue(store, now)
    for _, listing in ipairs(expired) do
        Store.log({
            event = Listings.EVENT.EXPIRE,
            actor = "system",
            listing = listing.id,
            item = listing.fullType,
            -- What actually went back, which is what was left rather than what
            -- was listed: a listing that sold most of its stack returns the
            -- remainder. listing.qty is zero by now, hence the separate field.
            qty = listing.returned or 0,
            at = now
        })
    end

    -- Both halves matter. Without the first the save carries every completed
    -- sale for its whole life; without the second it carries the gear of every
    -- player who stopped playing.
    local dropped, abandoned = Listings.purge(store, now, {
        completedAfterHours = 168,
        returnsAfterHours = Market.getOption("ReturnsExpiryHours", 336)
    })

    -- After the sweep, so a listing that just expired is a gap this can fill on
    -- the same tick rather than the next one.
    local added = Simulated.tick(store, now)

    if #expired > 0 or dropped > 0 or abandoned > 0 or added > 0 then
        Store.save()
        Market.debugLn(("tick: %d expired, %d purged, %d abandoned, %d simulated"):format(#expired, dropped,
            abandoned, added))
    end
end

Events.EveryTenMinutes.Add(tick)

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

-- Pulled in once the save's ModData exists, so the first player to open a
-- machine is not the one paying for the load and the index rebuild.
Events.OnInitGlobalModData.Add(function()
    Store.get()
end)
