-- Command names, shared so both ends spell them the same way.
--
-- Their own module string rather than PhunMart's: OnClientCommand is dispatched
-- on the module, and two mods answering to one module name would each have to
-- ignore the other's traffic.

-- Not a local: this file loads before core.lua (shared lua loads alphabetically
-- and "commands" sorts before "core"), so assigning to a local here would put
-- the module name and the command list on a table nothing else ever sees.
PhleaMarket = PhleaMarket or {}

PhleaMarket.module = "PhleaMarket"

PhleaMarket.commands = {
    -- Player to server
    list = "PhleaList",
    buy = "PhleaBuy",
    cancel = "PhleaCancel",
    collect = "PhleaCollect",
    relist = "PhleaRelist",
    browse = "PhleaBrowse",
    group = "PhleaGroup",
    priceInfo = "PhleaPriceInfo",
    catchUp = "PhleaCatchUp",
    mine = "PhleaMine",

    -- Admin
    adminList = "PhleaAdminList",
    adminCancel = "PhleaAdminCancel",
    adminLog = "PhleaAdminLog",

    -- Server to player
    result = "PhleaResult",
    browseData = "PhleaBrowseData",
    groupData = "PhleaGroupData",
    priceInfoData = "PhleaPriceInfoData",
    noticesData = "PhleaNoticesData",
    mineData = "PhleaMineData",
    returnsData = "PhleaReturnsData",
    adminData = "PhleaAdminData"
}

--- Events the client raises to itself in singleplayer, where a server command
--- has nowhere to go.
PhleaMarket.events = {
    OnResult = "OnPhleaMarketResult",
    OnData = "OnPhleaMarketData"
}

if type(LuaEventManager) == "table" and LuaEventManager.AddEvent then
    for _, name in pairs(PhleaMarket.events) do
        LuaEventManager.AddEvent(name)
    end
end

return PhleaMarket.commands
