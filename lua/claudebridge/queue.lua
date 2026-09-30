-- Request selection for the bridge (DL-021 design item 2; DL-022 step 2): which request file to handle next, whether a
-- gap is blocking, and which names are not requests. Criteria 2 and 10, design items 5, 6 and 8.
-- Pure: it is given directory listings (file names) and returns a decision. It reads no files, calls nothing in
-- MacroQuest and keeps no state; the loop passes the listings again on every poll.
--
-- Internally a sequence number is a decimal string without padding ('123'), so "no upper bound" (design item 8) holds
-- exactly, with no floating-point limit. The floor (design item 6) is given the same way, or nil. File names are never
-- unpadded: they are always zero-padded to at least six digits ('000123.json'; see M.filename).
local M = {}

-- Design item 8: a request file is named <seq>.json with the number in decimal, zero-padded to at least six digits, no
-- upper bound and no other leading zeros. Returns the number without padding, or nil for any other name (which is not a
-- request). ([0-9], not %d, so the rule does not depend on the C library's idea of a digit.)
local function parse(name)
    local digits = name:match('^([0-9]+)%.json$')
    if not digits then return nil end
    if #digits < 6 then return nil end
    if #digits > 6 and digits:sub(1, 1) == '0' then return nil end
    local key = digits:gsub('^0+', '')
    if key == '' then key = '0' end
    return key
end

-- The canonical file name for an unpadded decimal sequence number ('123' -> '000123.json'), the inverse of parse, so
-- reply names are built by the same rule that reads request names. It refuses anything that is not an unpadded decimal
-- string, so it can never build a name that select would ignore.
function M.filename(seq)
    if not seq:match('^[0-9]+$') or (#seq > 1 and seq:sub(1, 1) == '0') then
        error('queue.filename: not an unpadded decimal sequence number', 2)
    end
    return string.rep('0', 6 - #seq) .. seq .. '.json'
end

-- Compares two unpadded decimal strings by value: -1, 0 or 1. Never compares them as text (as text '1000000' sorts
-- before '999999'): a longer number is larger, and equal lengths compare digit by digit.
local function compare(a, b)
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end

-- The number after `key`, as an unpadded decimal string ('999999' -> '1000000').
local function successor(key)
    local digits = {}
    for i = 1, #key do digits[i] = key:byte(i) - 48 end
    local i = #digits
    while i >= 1 and digits[i] == 9 do
        digits[i] = 0
        i = i - 1
    end
    if i == 0 then return '1' .. table.concat(digits) end
    digits[i] = digits[i] + 1
    return table.concat(digits)
end

-- The highest canonical number among `names` and `best` (an unpadded decimal string or nil), or nil if there is none. The one
-- scanner in this file (decision 5, DL-022): select and highest both use it, so they cannot disagree about what a canonical
-- name is or how two numbers compare. Never uses tonumber: numbers have no upper bound (design item 8).
local function highest_key(names, best)
    for _, name in ipairs(names) do
        local key = parse(name)
        if key and (best == nil or compare(key, best) > 0) then best = key end
    end
    return best
end

-- highest(inbox_names, outbox_names) -> the highest canonical sequence number found in either listing, as an unpadded decimal
-- string ('123'), or nil if there is none. The startup floor (design item 6, decision 5): the loop calls it once at startup
-- with both listings and passes the result to select as `floor`. Pure.
function M.highest(inbox_names, outbox_names)
    return highest_key(outbox_names, highest_key(inbox_names))
end

-- select(inbox_names, outbox_names, floor) -> {
--     next = { name = '000123.json', seq = '123', base = true } or nil   -- the one request to handle now, if any;
--                                                                         -- base is true only under the base rule
--     waiting_for_sequence = '5' or nil                     -- the first missing number, only during a real gap
--     ignored = { { name = ..., reason = 'not_canonical' }, ... }   -- names that are not requests (sorted by name)
--     stale = { { name = ..., seq = ..., reason = 'floor' | 'completed' }, ... }   -- requests never handled (by number)
-- }
-- `outbox_names` are the reply files: a request is completed when its reply exists (design item 5), and the highest
-- canonical reply number is the last completed request. `floor` is the highest number seen at startup (design item 6),
-- or nil. Nothing at or below the floor, or at or below the highest completed number, is ever handled (design item 6.1,
-- criterion 2's Assumption). Until a reply above the floor exists, the lowest request above it is the base and is not
-- gap-checked (design item 6.2); after that criterion 2 applies exactly.
function M.select(inbox_names, outbox_names, floor)
    local result = { next = nil, waiting_for_sequence = nil, ignored = {}, stale = {} }

    local highest = highest_key(outbox_names)
    local completed_since_startup = highest ~= nil and (floor == nil or compare(highest, floor) > 0)

    local candidates = {}
    for _, name in ipairs(inbox_names) do
        local key = parse(name)
        if not key then
            result.ignored[#result.ignored + 1] = { name = name, reason = 'not_canonical' }
        elseif floor ~= nil and compare(key, floor) <= 0 then
            result.stale[#result.stale + 1] = { name = name, seq = key, reason = 'floor' }
        elseif completed_since_startup and compare(key, highest) <= 0 then
            result.stale[#result.stale + 1] = { name = name, seq = key, reason = 'completed' }
        else
            candidates[#candidates + 1] = { name = name, seq = key }
        end
    end

    table.sort(result.ignored, function(a, b) return a.name < b.name end)
    local function by_number(a, b) return compare(a.seq, b.seq) < 0 end
    table.sort(result.stale, by_number)
    table.sort(candidates, by_number)

    if #candidates > 0 then
        if not completed_since_startup then
            -- Marked so a request chosen without a gap check can be logged (Protocol section 8); the caller must be
            -- able to see that a lost first request would not have been noticed.
            result.next = candidates[1]
            result.next.base = true
        else
            local expected = successor(highest)
            if candidates[1].seq == expected then
                result.next = candidates[1]
            else
                result.waiting_for_sequence = expected
            end
        end
    end
    return result
end

return M
