-- Cutting a reply up for the wire, and putting it back together.
--
-- There is a limit to how much one command may carry before the transport
-- gives up on it, and three of this mod's replies can grow past any fixed
-- guess: the whole market, the whole admin listing table, and the ledger, whose
-- ceiling is a sandbox setting an admin may put into the thousands.
--
-- Each of those is one big list wrapped in a small header. That shape is what
-- makes this possible: the list is cut into parts, the header rides on the
-- first, and the receiver stitches them back before anything downstream is
-- told. Neither the command handlers nor the UI know it happened.
--
-- Both halves live here rather than one on each side, because they are one
-- rule. A sender that changes what it puts in the envelope and a receiver that
-- still opens it the old way is the kind of bug that only shows up on a real
-- server, under load, in front of players. Kept together, they are also plain
-- enough to test offline, which is the only place they get tested at all.

local Chunk = {}

--- Rows per part.
---
--- The same hundred PhunMart chunks its item definitions at. A projected
--- listing row is a dozen short fields, so a hundred of them is comfortably
--- small, and the part count stays low enough that the per-command overhead
--- does not start to matter.
Chunk.SIZE = 100

--- Does this payload need cutting up at all?
function Chunk.needed(payload, field, size)
    local rows = payload and payload[field]
    if type(rows) ~= "table" then
        return false
    end
    return #rows > (size or Chunk.SIZE)
end

--- Cut `payload` into parts on `field`, handing each to `send`.
---
--- The header is everything except the list, and it goes out on the first part
--- only, so it is neither repeated nor split across parts. Every part carries a
--- `chunk` marker saying which field it belongs to, whether it is the first and
--- whether it is the last; `Chunk.join` needs nothing else.
---
--- Returns the number of parts sent.
function Chunk.split(payload, field, size, send)
    size = size or Chunk.SIZE
    local rows = payload[field]
    local total = #rows
    local sent, parts = 0, 0
    local first = true

    -- A list that is empty or exactly at the limit still goes out as one part,
    -- rather than as nothing at all. The caller is entitled to assume that
    -- calling this always sends something.
    repeat
        local slice = {}
        local last = math.min(sent + size, total)
        for i = sent + 1, last do
            slice[#slice + 1] = rows[i]
        end
        sent = last

        local part = {}
        if first then
            for key, value in pairs(payload) do
                if key ~= field then
                    part[key] = value
                end
            end
        end
        part[field] = slice
        part.chunk = {
            field = field,
            first = first,
            completed = sent >= total,
            total = total
        }

        send(part)
        parts = parts + 1
        first = false
    until sent >= total

    return parts
end

--- Collect a part. Returns the whole payload once the last one lands, else nil.
---
--- `state` is a table the caller owns and keys by whatever distinguishes one
--- transfer from another, normally the command name. A payload with no `chunk`
--- marker was never cut up and comes straight back, so a caller can put every
--- reply through this without asking which kind it is.
---
--- A part with no head to attach to is dropped rather than guessed at. The
--- field is checked as well as the presence, because one command may answer
--- with either of two lists: switching screens mid-transfer would otherwise
--- thread the tail of one onto the head of the other, and the two need not even
--- hold the same shape of row. A dropped transfer costs a stale screen and a
--- refresh, which is a great deal better than half a market presented as all
--- of it.
function Chunk.join(state, key, payload)
    local meta = payload and payload.chunk
    if not meta then
        return payload
    end

    local field = meta.field
    if meta.first then
        payload.chunk = nil
        state[key] = payload
    else
        local acc = state[key]
        if not (acc and acc[field]) then
            return nil, "orphan"
        end
        local into = acc[field]
        for _, row in ipairs(payload[field] or {}) do
            into[#into + 1] = row
        end
    end

    if not meta.completed then
        return nil
    end
    local whole = state[key]
    state[key] = nil
    return whole
end

return Chunk
