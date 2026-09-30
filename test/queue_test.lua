-- Tests for claudebridge/queue.lua (Step 2 of DL-022: sequence order, gaps, duplicates, the canonical file-name rule,
-- ignored names and waiting_for_sequence).
-- Requirement sources (DL-018 / DL-021 in docs/decision_log.md), named per test below:
--   * Criterion 2: complete requests only, strictly in sequence-number order, one at a time; a missing number with a
--     later one present blocks later requests and shows waiting_for_sequence; the Assumption that a request at or below
--     the highest completed number is not handled.
--   * Criterion 10: an invalid request must not block the queue (here: only names that are not requests are ignored).
--   * Design item 5: a request is completed when its reply file exists in outbox (no separate completion state).
--   * Design item 6: startup floor (never handle at or below it, and report what was skipped) and base (the first
--     request above the floor sets where strict ordering begins, with no gap check on it).
--   * Design item 8: file name = decimal, zero-padded to at least six digits, no upper bound, no other leading zeros;
--     ordering compares numbers, never name text (a test crosses six to seven digits); a name that is not the canonical
--     form of its number is not a request: ignored (and reported so it can be logged).
-- queue.select(inbox_names, outbox_names, floor) is pure: it is given directory listings, returns a decision and touches
-- no files. Sequence numbers are decimal strings without padding ('123'), so "no upper bound" holds exactly.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local queue = require 'claudebridge.queue'

-- The names in a list of {name=...} entries, sorted, for comparisons that must not depend on listing order.
local function names_of(entries)
  local out = {}
  for _, e in ipairs(entries) do out[#out + 1] = e.name end
  table.sort(out)
  return out
end

local function reasons_by_name(entries)
  local out = {}
  for _, e in ipairs(entries) do out[e.name] = e.reason end
  return out
end

-- The selected request's file name and sequence number, or nil when nothing is selected (so a wrong "nothing selected"
-- fails as a value mismatch, not as an index error).
local function nxt(r) return r.next and r.next.name end
local function nseq(r) return r.next and r.next.seq end
local function nbase(r) return r.next and r.next.base end

local function sel(inbox, outbox, floor)
  return queue.select(inbox, outbox or {}, floor)
end

-- ---- Design item 8: the canonical file name -----------------------------------------------------------------------

test('a canonical name is a request; its sequence number is the number without padding (item 8: 000123.json)', function()
  local r = sel({ '000123.json' })
  expect.equal(nxt(r), '000123.json')
  expect.equal(nseq(r), '123')
  expect.equal(#r.ignored, 0)
end)

test('ordering compares numbers, never name text: 999999 comes before 1000000 (item 8, six-to-seven digit boundary)', function()
  -- As text, '1000000.json' sorts before '999999.json'; as numbers 999999 is first.
  local r = sel({ '1000000.json', '999999.json' })
  expect.equal(nxt(r), '999999.json')
end)

test('the sequence continues across the six-to-seven digit boundary: after reply 999999 the next is 1000000 (item 8)', function()
  local r = sel({ '999999.json', '1000000.json' }, { '999999.json' })
  expect.equal(nxt(r), '1000000.json')
  expect.equal(nseq(r), '1000000')
  expect.equal(r.waiting_for_sequence, nil)
end)

test('there is no upper bound: numbers beyond exact floating-point range are compared and continued exactly (item 8)', function()
  local a = '123456789012345678901234567890'
  local b = '123456789012345678901234567891'
  local r = sel({ a .. '.json', b .. '.json' }, { a .. '.json' })
  expect.equal(nseq(r), b)
  expect.equal(r.waiting_for_sequence, nil)
  -- and a real gap is still seen at that size
  local c = '123456789012345678901234567892'
  local g = sel({ c .. '.json' }, { a .. '.json' })
  expect.equal(g.next, nil)
  expect.equal(g.waiting_for_sequence, b)
end)

test('names that are not the canonical form of a number are ignored and reported (item 8: for example 1.json)', function()
  local bad = {
    '1.json',                 -- item 8's own example: fewer than six digits
    '12345.json',             -- five digits
    '0000123.json',           -- seven digits with a leading zero: "no other leading zeros"
    '000123.json.tmp',        -- still under a temporary name (criterion 2)
    'request-3f9a.tmp',       -- a temporary request name (criterion 2)
    '000123.txt',
    'readme',
    '.json',
    'abc123.json',
  }
  local r = sel(bad)
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, nil)
  local expected = {}
  for _, n in ipairs(bad) do expected[#expected + 1] = n end
  table.sort(expected)
  expect.equal(names_of(r.ignored), expected)
  expect.equal(#r.stale, 0)
end)

test('the extension must be exactly lowercase .json: other cases are not canonical and are ignored and reported (item 8: <seq>.json)', function()
  local variants = { '000123.JSON', '000123.Json', '000123.jSON' }
  local r = sel(variants)
  expect.equal(r.next, nil)
  expect.equal(names_of(r.ignored), { '000123.JSON', '000123.Json', '000123.jSON' })
  expect.equal(#r.stale, 0)
  -- a real request beside them is still selected
  local beside = sel({ '000123.JSON', '000124.json' })
  expect.equal(nxt(beside), '000124.json')
end)

test('an ignored name never blocks or reorders real requests (criterion 10: an invalid file must not block the queue)', function()
  local r = sel({ '1.json', '000005.json', 'request-x.tmp', '000006.json' }, { '000004.json' })
  expect.equal(nxt(r), '000005.json')
  expect.equal(r.waiting_for_sequence, nil)
  expect.equal(names_of(r.ignored), { '1.json', 'request-x.tmp' })
end)

test('a reply that is not a canonical name does not count as a completed request (item 5 with item 8)', function()
  -- outbox holds only non-canonical reply names for number 4: nothing is completed, so the lowest request is the base
  -- (request 7 is selected with no gap check). If those names counted as reply 4, request 7 would be a gap waiting for 5.
  local r = sel({ '000007.json' }, { '000004.json.tmp', '4.json' })
  expect.equal(nxt(r), '000007.json')
  expect.equal(r.waiting_for_sequence, nil)
end)

-- ---- Design item 8: building the canonical name (the same rule, in one place) ---------------------------------------------

test('a sequence number is written as its canonical file name: at least six digits, zero-padded (item 8 examples)', function()
  expect.equal(queue.filename('123'), '000123.json')
  expect.equal(queue.filename('999999'), '999999.json')
  expect.equal(queue.filename('1000000'), '1000000.json')
  expect.equal(queue.filename('1'), '000001.json')
  expect.equal(queue.filename('0'), '000000.json')
  expect.equal(queue.filename('123456789012345678901234567890'), '123456789012345678901234567890.json')
end)

test('every name the builder produces is read back as a request with the same sequence number (item 8)', function()
  for _, n in ipairs({ '0', '1', '123', '999999', '1000000', '123456789012345678901234567890' }) do
    local r = sel({ queue.filename(n) })
    expect.equal(nseq(r), n)
    expect.equal(#r.ignored, 0)
  end
end)

test('the builder refuses anything that is not an unpadded decimal number, so it can never produce a non-canonical name (item 8)', function()
  for _, bad in ipairs({ '', 'abc', '0123', '12.5', '-1', '1 ', 123 }) do
    expect.falsy(pcall(queue.filename, bad), 'accepted ' .. tostring(bad))
  end
  expect.falsy(pcall(queue.filename, nil))
end)

-- ---- Criterion 2: order, one at a time, gaps ------------------------------------------------------------------------

test('requests are handled strictly in sequence-number order, one at a time (criterion 2)', function()
  local r = sel({ '000007.json', '000005.json', '000006.json' }, { '000004.json' })
  expect.equal(nxt(r), '000005.json')
  expect.equal(r.waiting_for_sequence, nil)
end)

test('a completed request (its reply exists) is not selected again: the next one is (item 5, criterion 2)', function()
  local r = sel({ '000005.json', '000006.json', '000007.json' }, { '000004.json', '000005.json' })
  expect.equal(nxt(r), '000006.json')
end)

test('a missing number with a later request present blocks later requests and is reported as waiting (criterion 2)', function()
  local r = sel({ '000006.json', '000007.json' }, { '000004.json' })
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, '5')
end)

test('waiting names the first missing number when several are missing (criterion 2)', function()
  local r = sel({ '000008.json' }, { '000004.json' })
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, '5')
end)

test('no later request present means no gap: the next request simply has not been written yet (criterion 2)', function()
  local none = sel({}, { '000004.json' })
  expect.equal(none.next, nil)
  expect.equal(none.waiting_for_sequence, nil)
  local only_old = sel({ '000003.json', '000004.json' }, { '000003.json', '000004.json' })
  expect.equal(only_old.next, nil)
  expect.equal(only_old.waiting_for_sequence, nil)
end)

test('the gap closes when the missing request arrives, and it is handled before the later ones (criterion 2)', function()
  local blocked = sel({ '000006.json' }, { '000004.json' })
  expect.equal(blocked.waiting_for_sequence, '5')
  local closed = sel({ '000005.json', '000006.json' }, { '000004.json' })
  expect.equal(nxt(closed), '000005.json')
  expect.equal(closed.waiting_for_sequence, nil)
end)

-- ---- Criterion 2's Assumption: nothing at or below the highest completed number is handled -------------------------

test('a request at or below the highest completed number is not handled and is reported as stale (criterion 2 Assumption)', function()
  local r = sel({ '000003.json', '000004.json', '000005.json' }, { '000004.json' })
  expect.equal(nxt(r), '000005.json')
  expect.equal(names_of(r.stale), { '000003.json', '000004.json' })
  local why = reasons_by_name(r.stale)
  expect.equal(why['000003.json'], 'completed')
  expect.equal(why['000004.json'], 'completed')
end)

test('even a request with no reply of its own is not handled if a higher one is completed (criterion 2 Assumption)', function()
  local r = sel({ '000006.json' }, { '000007.json' })
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, nil)
  expect.equal(names_of(r.stale), { '000006.json' })
end)

-- ---- Design item 6: the startup floor and base ------------------------------------------------------------------------

test('a request at or below the floor is never handled, and is reported with the reason floor (item 6.1, 6.3)', function()
  local r = sel({ '000009.json', '000010.json', '000011.json' }, {}, '10')
  expect.equal(nxt(r), '000011.json')
  expect.equal(names_of(r.stale), { '000009.json', '000010.json' })
  local why = reasons_by_name(r.stale)
  expect.equal(why['000009.json'], 'floor')
  expect.equal(why['000010.json'], 'floor')
end)

test('the first request above the floor sets the base with no gap check on it (item 6.2)', function()
  -- The MCP counter is far ahead of an emptied folder: the floor is 10, the first new request is 500.
  local r = sel({ '000500.json' }, { '000010.json' }, '10')
  expect.equal(nxt(r), '000500.json')
  expect.equal(r.waiting_for_sequence, nil)
end)

test('with several requests above the floor and nothing completed since startup, the lowest is the base (item 6.2)', function()
  local r = sel({ '000502.json', '000500.json' }, { '000010.json' }, '10')
  expect.equal(nxt(r), '000500.json')
  expect.equal(r.waiting_for_sequence, nil)
end)

test('once a request above the floor has been completed, criterion 2 applies exactly: a gap after it blocks (item 6.2)', function()
  local r = sel({ '000500.json', '000502.json' }, { '000010.json', '000500.json' }, '10')
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, '501')
end)

test('a reply at the floor is not a completion since startup: the base rule still applies (item 6.2, item 5)', function()
  local r = sel({ '000012.json' }, { '000010.json' }, '10')
  expect.equal(nxt(r), '000012.json')
  expect.equal(r.waiting_for_sequence, nil)
end)

test('with no floor and nothing completed, the lowest request present is the base, then criterion 2 applies (item 6.2)', function()
  local first = sel({ '000007.json', '000005.json' })
  expect.equal(nxt(first), '000005.json')
  expect.equal(first.waiting_for_sequence, nil)
  local after = sel({ '000005.json', '000007.json' }, { '000005.json' })
  expect.equal(after.next, nil)
  expect.equal(after.waiting_for_sequence, '6')
end)

-- ---- Protocol section 8: the base decision must be visible ----------------------------------------------------------------

test('a request chosen under the base rule is marked base, so a decision made without a gap check can be logged (item 6.2, Protocol 8)', function()
  -- The base rule is the accepted limitation that a lost first request cannot be detected; a log must show when it applied.
  expect.equal(nbase(sel({ '000500.json' }, { '000010.json' }, '10')), true)
  expect.equal(nbase(sel({ '000005.json', '000007.json' })), true)
end)

test('a request chosen under criterion 2 (a reply above the floor exists) is not marked base (item 6.2, Protocol 8)', function()
  local r = sel({ '000501.json' }, { '000010.json', '000500.json' }, '10')
  expect.equal(nxt(r), '000501.json')
  expect.equal(nbase(r), nil)
  expect.equal(nbase(sel({ '000005.json', '000006.json' }, { '000005.json' })), nil)
end)

test('an empty inbox yields nothing to do and no gap (criterion 2)', function()
  local r = sel({}, {}, '10')
  expect.equal(r.next, nil)
  expect.equal(r.waiting_for_sequence, nil)
  expect.equal(#r.ignored, 0)
  expect.equal(#r.stale, 0)
end)


-- ---- Decision 5 (DL-022 addendum, 2026-09-30): queue.highest, the startup floor ----------------------------------------------
-- queue.highest(inbox_names, outbox_names) returns the highest canonical sequence number found in either listing, as an
-- unpadded decimal string, or nil if there is none. Source: design item 6 (at startup the bridge notes the highest sequence
-- number present in inbox and outbox) and design item 8 (canonical names only; ordering by number, never by name text; no upper
-- bound on a sequence number). It is pure, shares queue.lua's parser and comparison, and never uses tonumber.

test('the highest number may come from the inbox or from the outbox (decision 5, design item 6)', function()
  expect.equal(queue.highest({ '000007.json', '000003.json' }, { '000005.json' }), '7')
  expect.equal(queue.highest({ '000003.json' }, { '000005.json', '000009.json' }), '9')
end)

test('the result does not depend on the order of the names or of the two listings (decision 5)', function()
  local a, b = { '000010.json', '000002.json', '000033.json' }, { '000004.json', '000031.json' }
  expect.equal(queue.highest(a, b), '33')
  expect.equal(queue.highest(b, a), '33')
  expect.equal(queue.highest({ '000033.json', '000010.json', '000002.json' }, { '000031.json', '000004.json' }), '33')
end)

test('names that are not canonical are ignored by the existing parser rules, even when their digits are larger (design item 8)', function()
  -- 1.json (too short), 0000012.json (padded past six digits), 000123.JSON (wrong case), 000123.json.tmp (a temporary name),
  -- notes.txt: none is a request or reply name, so none can raise the floor.
  local names = { '1.json', '0000012.json', '000123.JSON', '000123.json.tmp', 'notes.txt', '000050.json' }
  expect.equal(queue.highest(names, {}), '50')
  expect.equal(queue.highest({}, names), '50')
end)

test('the result is the unpadded decimal string: six-digit padding is removed (design item 8)', function()
  expect.equal(queue.highest({ '000123.json' }, {}), '123')
  expect.equal(queue.highest({ '000000.json' }, {}), '0')
end)

test('ordering is by number, never by name text: 999999 is below 1000000 (design item 8, six-to-seven digit boundary)', function()
  -- As text, '1000000.json' sorts before '999999.json'.
  expect.equal(queue.highest({ '999999.json' }, { '1000000.json' }), '1000000')
  expect.equal(queue.highest({ '1000000.json' }, { '999999.json' }), '1000000')
end)

test('numbers too long for a Lua number compare exactly: two different same-length 30-digit values (design item 8, no upper bound)', function()
  -- 123456789012345678901234567890 and ...891 differ only in the last digit; as Lua numbers (doubles) they are equal, so an
  -- implementation that used tonumber could not tell them apart. The larger exact decimal string must win, from either listing.
  local low, high = '123456789012345678901234567890', '123456789012345678901234567891'
  expect.equal(queue.highest({ low .. '.json' }, { high .. '.json' }), high)
  expect.equal(queue.highest({ high .. '.json' }, { low .. '.json' }), high)
  expect.equal(queue.highest({ low .. '.json', high .. '.json' }, {}), high)
  -- and a longer number beats a shorter one whose leading digits are larger
  expect.equal(queue.highest({ '99999999999999999999999999999.json' }, { '100000000000000000000000000000.json' }), '100000000000000000000000000000')
end)

test('empty listings, and listings with only non-canonical names, give nil (decision 5: no floor)', function()
  expect.equal(queue.highest({}, {}), nil)
  expect.equal(queue.highest({ '1.json', 'notes.txt', '000123.json.tmp' }, { '0000012.json' }), nil)
end)

test('select agrees with highest about what counts as the highest completed reply (one scanner inside queue.lua, decision 5)', function()
  -- select's completed-number rule must use the same parser and comparison as highest: with replies 999999 and 1000000 the
  -- next request is 1000001, and a 30-digit reply is recognized as completed, blocking a request at or below it.
  expect.equal(nxt(sel({ '1000001.json' }, { '999999.json', '1000000.json' }, '999998')), '1000001.json')
  local big = '123456789012345678901234567890'
  local r = sel({ '123456789012345678901234567890.json', '123456789012345678901234567891.json' }, { big .. '.json' }, '5')
  expect.equal(nxt(r), '123456789012345678901234567891.json')
  expect.equal(reasons_by_name(r.stale)['123456789012345678901234567890.json'], 'completed')
end)

test('select recognizes the highest of two 30-digit replies exactly, whichever order they are listed in (decision 5: no tonumber in select either)', function()
  -- The two numbers differ only in the last digit, so as Lua numbers they are equal; if select scanned the outbox with tonumber it
  -- would take the first one listed as the highest completed reply and treat the other as the next request. With the exact
  -- comparison both are completed: nothing is left to handle and both are reported stale.
  local low, high = '123456789012345678901234567890', '123456789012345678901234567891'
  for _, outbox in ipairs({ { low .. '.json', high .. '.json' }, { high .. '.json', low .. '.json' } }) do
    local r = sel({ low .. '.json', high .. '.json' }, outbox, '5')
    expect.equal(r.next, nil)
    expect.equal(#r.stale, 2)
    expect.equal(r.waiting_for_sequence, nil)
  end
end)
