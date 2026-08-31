-- Covers chunking: cutting a reply up for the wire and putting it back.
--
-- This is worth testing offline precisely because it is the code least likely
-- to be caught in play. It does nothing at all in singleplayer, and on a server
-- it only engages once a list grows past a hundred rows, which is a busy market
-- some weeks in rather than anything a first session produces. A sender and a
-- receiver that disagree would sit quietly until exactly the moment there is
-- enough data to matter.
--
-- The failures to catch here are silent ones: a part dropped, a header lost, a
-- row duplicated at a boundary, or a transfer that reassembles into something
-- plausible but incomplete. None of those throw. They produce a market that is
-- simply missing things.
--
-- Run: luajit test_chunking.lua   (or run.cmd, which runs all of them)

local here = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
local root = arg[1] or (here .. "/../..")
package.path = here .. "/?.lua;" .. package.path

local harness = require "harness"

local shared = root .. "/Contents/mods/PhleaMarket/common/media/lua/shared"
package.path = shared .. "/?.lua;" .. package.path

harness.installGlobals()

local Chunk = require "PhleaMarket/chunking"

harness.strip()

---------------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(label, condition, detail)
    if condition then
        passed = passed + 1
        print("  ok    " .. label)
    else
        failed = failed + 1
        print("  FAIL  " .. label .. (detail and ("  <- " .. detail) or ""))
    end
end

local function section(name)
    print("")
    print(name)
end

--- A list of `n` rows, each knowing its own position, so a reassembled list can
--- be checked for order and for gaps rather than only for length.
local function rows(n)
    local out = {}
    for i = 1, n do
        out[i] = {
            id = i,
            name = "row" .. i
        }
    end
    return out
end

--- Just the parts, as they would go on the wire.
---
--- Kept apart from the round trip below because join strips the marker off the
--- first part as it takes it in. That is fine in the client, where the payload
--- belongs to the receiver, but it means a test cannot inspect parts it has
--- already fed through.
local function splitOnly(payload, field, size)
    local parts = {}
    Chunk.split(payload, field, size, function(part)
        parts[#parts + 1] = part
    end)
    return parts
end

--- Send and receive, returning what the far end made of it.
---
--- The parts are collected first and only then fed in, so nothing here depends
--- on the two halves being interleaved.
local function roundTrip(payload, field, size, key)
    local parts = splitOnly(payload, field, size)
    local state = {}
    local whole
    for _, part in ipairs(parts) do
        whole = Chunk.join(state, key or "cmd", part) or whole
    end
    return whole, parts, state
end

local function idsInOrder(list)
    for i, row in ipairs(list) do
        if row.id ~= i then
            return false, "position " .. i .. " holds id " .. tostring(row.id)
        end
    end
    return true
end

---------------------------------------------------------------------------
section("Deciding whether to cut at all")

ok("a short list is left alone", Chunk.needed({
    listings = rows(50)
}, "listings", 100) == false)

ok("a list exactly at the limit is left alone", Chunk.needed({
    listings = rows(100)
}, "listings", 100) == false)

ok("one row over the limit is cut", Chunk.needed({
    listings = rows(101)
}, "listings", 100) == true)

ok("an empty list is left alone", Chunk.needed({
    listings = {}
}, "listings", 100) == false)

ok("a missing field is left alone", Chunk.needed({}, "listings", 100) == false)

ok("a field that is not a list is left alone", Chunk.needed({
    listings = "nonsense"
}, "listings", 100) == false)

ok("nil payload is left alone", Chunk.needed(nil, "listings", 100) == false)

---------------------------------------------------------------------------
section("The round trip")

local whole, parts = roundTrip({
    listings = rows(250)
}, "listings", 100)

ok("250 rows go out as three parts", #parts == 3, "got " .. #parts)
ok("and arrive as one payload", whole ~= nil)
ok("with every row present", whole and #whole.listings == 250, whole and #whole.listings)
ok("in the order they were sent", whole and idsInOrder(whole.listings))
ok("and the marker stripped off", whole and whole.chunk == nil)

local exact = roundTrip({
    listings = rows(300)
}, "listings", 100)
ok("a list that divides exactly loses nothing", exact and #exact.listings == 300, exact and #exact.listings)
ok("and is still in order", exact and idsInOrder(exact.listings))

local one = splitOnly({
    listings = rows(1)
}, "listings", 100)
ok("a single row is one part", #one == 1)

local none = splitOnly({
    listings = {}
}, "listings", 100)
ok("an empty list still sends one part", #none == 1, "otherwise the caller is never answered")

---------------------------------------------------------------------------
section("The header")

local headed = roundTrip({
    rows = {"summary"},
    guide = {
        low = 5
    },
    fullType = "Base.Axe",
    listings = rows(250)
}, "listings", 100)

ok("header fields survive", headed and headed.fullType == "Base.Axe")
ok("including tables", headed and headed.guide and headed.guide.low == 5)
ok("and other lists", headed and headed.rows and headed.rows[1] == "summary")

local headedParts = splitOnly({
    fullType = "Base.Axe",
    listings = rows(250)
}, "listings", 100)

ok("the header rides on the first part", headedParts[1].fullType == "Base.Axe")
ok("and is not repeated on the second", headedParts[2].fullType == nil)
ok("nor on the last", headedParts[3].fullType == nil)

ok("only the last part says it is done", headedParts[1].chunk.completed == false and
    headedParts[2].chunk.completed == false and headedParts[3].chunk.completed == true)
ok("only the first says it is first", headedParts[1].chunk.first == true and headedParts[2].chunk.first == false)
ok("every part names its field", headedParts[1].chunk.field == "listings" and headedParts[3].chunk.field ==
    "listings")
ok("and carries the total", headedParts[2].chunk.total == 250)

---------------------------------------------------------------------------
section("Nothing is handed over early")

local state = {}
local parts3 = splitOnly({
    listings = rows(250)
}, "listings", 100)

ok("the first part alone yields nothing", Chunk.join(state, "cmd", parts3[1]) == nil)
ok("nor does the second", Chunk.join(state, "cmd", parts3[2]) == nil)
local final = Chunk.join(state, "cmd", parts3[3])
ok("the third completes it", final ~= nil and #final.listings == 250)
ok("and the collector is emptied afterwards", state.cmd == nil,
    "a transfer left behind would be appended to by the next one")

---------------------------------------------------------------------------
section("Payloads that were never cut up")

local plain = {
    listings = rows(3),
    fullType = "Base.Axe"
}
local passedThrough = Chunk.join({}, "cmd", plain)
ok("a payload with no marker comes straight back", passedThrough == plain,
    "so a caller can put every reply through join without asking which kind it is")

---------------------------------------------------------------------------
section("Parts that arrive with no head")

local orphanState = {}
local partsO = splitOnly({
    listings = rows(250)
}, "listings", 100)

local got, why = Chunk.join(orphanState, "cmd", partsO[2])
ok("a middle part with nothing to attach to is refused", got == nil)
ok("and says why", why == "orphan")

local lastGot = Chunk.join(orphanState, "cmd", partsO[3])
ok("so is the last one", lastGot == nil, "half a market must never be presented as all of it")

---------------------------------------------------------------------------
section("Two lists on one command")

-- adminData answers with `listings` for the Listings tab and `log` for the
-- Ledger tab. An admin switching tabs mid-transfer must not thread the tail of
-- one onto the head of the other: the two do not hold the same shape of row.
local mixed = {}
local listParts = splitOnly({
    listings = rows(250)
}, "listings", 100)
local logParts = splitOnly({
    log = rows(250)
}, "log", 100)

Chunk.join(mixed, "adminData", listParts[1])
local crossed, crossedWhy = Chunk.join(mixed, "adminData", logParts[2])
ok("a log part will not attach to a listings head", crossed == nil)
ok("and is called an orphan", crossedWhy == "orphan")

ok("the listings transfer is still intact", mixed.adminData and #mixed.adminData.listings == 100,
    mixed.adminData and #mixed.adminData.listings)

-- And starting the other transfer properly replaces it rather than merging.
Chunk.join(mixed, "adminData", logParts[1])
ok("a new head replaces the abandoned one", mixed.adminData and mixed.adminData.log ~= nil and
    mixed.adminData.listings == nil)

---------------------------------------------------------------------------
section("Two commands at once")

-- Keyed per command, so a browse arriving while an admin listing is still
-- coming in cannot walk into the middle of it.
local shared_ = {}
local browseParts = splitOnly({
    listings = rows(250)
}, "listings", 100)
local adminParts = splitOnly({
    listings = rows(150)
}, "listings", 100)

Chunk.join(shared_, "browse", browseParts[1])
Chunk.join(shared_, "admin", adminParts[1])
Chunk.join(shared_, "browse", browseParts[2])
local adminWhole = Chunk.join(shared_, "admin", adminParts[2])
local browseWhole = Chunk.join(shared_, "browse", browseParts[3])

ok("interleaved transfers both complete", adminWhole ~= nil and browseWhole ~= nil)
ok("the admin one has its own 150", adminWhole and #adminWhole.listings == 150,
    adminWhole and #adminWhole.listings)
ok("the browse one has its own 250", browseWhole and #browseWhole.listings == 250,
    browseWhole and #browseWhole.listings)
ok("and neither borrowed a row from the other", adminWhole and idsInOrder(adminWhole.listings) and browseWhole and
    idsInOrder(browseWhole.listings))

---------------------------------------------------------------------------
section("Sizes other than the default")

ok("the shipped size is the hundred PhunMart uses", Chunk.SIZE == 100)

local small = roundTrip({
    listings = rows(7)
}, "listings", 2)
ok("a size of two still reassembles cleanly", small and #small.listings == 7 and idsInOrder(small.listings))

local smallParts = splitOnly({
    listings = rows(7)
}, "listings", 2)
ok("into the expected number of parts", #smallParts == 4, "got " .. #smallParts)

---------------------------------------------------------------------------
print("")
print("passed: " .. passed .. "  failed: " .. failed)
os.exit(failed == 0 and 0 or 1)
