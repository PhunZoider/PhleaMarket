if isServer() then
    return
end

-- Talking to the server, and being answered.
--
-- Both directions have a singleplayer case and they are not the same one.
-- Asking works everywhere: sendClientCommand is delivered locally in
-- singleplayer, so the server handlers run there as they do on a server. The
-- answer does not: sendServerCommand is a no-op locally, so the server side
-- raises an event instead and this listens for both.

require "PhleaMarket/core"
require "PhleaMarket/commands"

local Core = PhunMart
local Market = PhleaMarket
local C = Market.commands

local Client = {}
Market.client = Client

--- The last thing the server told us, per kind. The window reads these rather
--- than holding its own copies, so a window opened after a reply still sees it.
Client.data = {
    browse = nil,
    group = nil,
    mine = nil,
    admin = nil
}

--- Ask the server for something.
---
--- One helper rather than sendClientCommand at every call site, so there is a
--- single place that knows the module name and a single place to look when a
--- command goes missing.
function Client.send(command, args)
    sendClientCommand(Market.module, command, args or {})
end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------

local handlers = {}

handlers[C.result] = function(payload)
    Client.lastResult = payload
    triggerEvent(Market.events.OnData, "result", payload)
end

handlers[C.browseData] = function(payload)
    Client.data.browse = payload
    triggerEvent(Market.events.OnData, "browse", payload)
end

handlers[C.groupData] = function(payload)
    Client.data.group = payload
    triggerEvent(Market.events.OnData, "group", payload)
end

handlers[C.mineData] = function(payload)
    Client.data.mine = payload
    triggerEvent(Market.events.OnData, "mine", payload)
end

handlers[C.adminData] = function(payload)
    Client.data.admin = payload
    triggerEvent(Market.events.OnData, "admin", payload)
end

local function dispatch(command, payload)
    local handler = handlers[command]
    if handler then
        handler(payload or {})
    else
        Market.debugLn("unhandled reply " .. tostring(command))
    end
end

Client.dispatch = dispatch

-- Multiplayer: the server sends, this receives.
Events.OnServerCommand.Add(function(module, command, payload)
    if module ~= Market.module then
        return
    end
    dispatch(command, payload)
end)

-- Singleplayer: the server side raises this instead, because sendServerCommand
-- has nowhere to send to when there is no server.
Events[Market.events.OnResult].Add(function(command, payload)
    dispatch(command, payload)
end)

return Client
