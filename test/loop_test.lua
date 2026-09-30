-- Tests for claudebridge/loop.lua (Step 5 of DL-022: the control logic). The loop is exercised together with the REAL store, queue and core,
-- over the in-memory file-system fake in test/harness/fake_fs.lua, so it is tested against the same modules it runs with; the game is a fake env.
-- Requirement sources (DL-018 / DL-021 / DL-022 in docs/decision_log.md), named per test below:
--   * Criterion 2 and design items 5, 6, 8: requests are handled one at a time in sequence order; a gap blocks later requests and shows
--     waiting_for_sequence; a request is completed when its reply exists; at startup the floor is the highest number present and nothing
--     at or below it is handled (base rule for the first request above it); one request per step (DL-022 decision 9, implementation choice).
--   * Criterion 6 and design items 9, 19, 26; decision 7 (amended): the first heartbeat is attempted at startup; then a heartbeat is due 1,000 ms
--     after the last ATTEMPT, measured on the monotonic reading now_ms; wall seconds now_s are used only for written_at and event t; one beat,
--     not a burst, after a stall; decision 9: ANY heartbeat publish failure skips that beat, silently and without state.
--   * Criterion 7 and decision 6: every heard line is recorded as a chat event; any events failure, including exhaustion, at startup refuses to
--     start and at runtime sets one sticky fatal state (reported once, later events ignored, no later step, heartbeat or request).
--   * Decision 9: a runtime failure to list inbox or outbox, or to write or rename a reply, takes the same fatal path; startup includes the first
--     heartbeat attempt after the events file is open and before any request is processed. A startup failure before events begin to be appended
--     (a listing failure, the events file failing to open or being exhausted) writes nothing; a later failure (bridge_start or a startup_skipped
--     event) stops startup and publishes no heartbeat, but may leave the events already written and, as Step 4 records, a failed-append fragment:
--     no rollback is claimed. start is called once (a second call returns nil and does nothing).
--   * Criterion 10 and design item 19: an invalid request gets an error reply and is completed; an unreadable request file is deferred, logged once
--     as an unreadable event and shown as unreadable_sequence, and retried on every step.
--   * Criterion 13, design item 14, decisions 4 and 9: a request file over the limit is answered with core.oversize_reply(seq) and never read.
-- loop.new(store, env) builds the loop; L:start(now_s, now_ms), L:step(now_s, now_ms), L:on_event(line, now_s), L:failure().
local T = require 'harness.t'
local test, expect = T.test, T.expect

local json = require 'claudebridge.json'
local version = require 'claudebridge.version'
local core = require 'claudebridge.core'
local store = require 'claudebridge.store'
local loop = require 'claudebridge.loop'
local fake_fs = require 'harness.fake_fs'

local DIR = 'C:\\Users\\Public\\MacroQuest\\claude'
local BS = '\\'
local INBOX, OUTBOX = DIR .. BS .. 'inbox' .. BS, DIR .. BS .. 'outbox' .. BS
local HEARTBEAT, EVENTS = DIR .. BS .. 'heartbeat.json', DIR .. BS .. 'events.jsonl'
local T0, M0 = 1727612345, 100000   -- a wall reading in seconds, a monotonic reading in milliseconds

-- A fake game: answers parse from a table (default 'NULL'), and reports a character and a zone.
local function fake_env()
  local env = { char = 'Testchar', zone_name = 'bazaar', calls = {} }
  env.parse = function(expr) env.calls[#env.calls + 1] = expr; return 'NULL' end
  env.character = function() return env.char end
  env.zone = function() return env.zone_name end
  return env
end

local function setup(files)
  local fs = fake_fs.new(files)
  local st = store.new(fs, DIR)
  local env = fake_env()
  local L = loop.new(st, env)
  return L, fs, env
end

local function name(n) return string.format('%06d.json', n) end
local function put_request(fs, n, text) fs.files[INBOX .. name(n)] = text or '{"command":"ping"}' end

local function events_of(fs)
  local out = {}
  for line in (fs.files[EVENTS] or ''):gmatch('([^\n]*)\n') do
    local ok, e = pcall(json.decode, line)
    if ok and type(e) == 'table' then out[#out + 1] = e end
  end
  return out
end

local function kinds_of(fs)
  local out = {}
  for _, e in ipairs(events_of(fs)) do out[#out + 1] = e.kind end
  return out
end

local function events_of_kind(fs, kind)
  local out = {}
  for _, e in ipairs(events_of(fs)) do
    if e.kind == kind then out[#out + 1] = e end
  end
  return out
end

local function heartbeat_of(fs)
  local text = fs.files[HEARTBEAT]
  return text and json.decode(text) or nil
end

local function count_ops(fs, op, pattern)
  local n = 0
  for _, o in ipairs(fs.ops) do
    if o.op == op and (pattern == nil or o.path:find(pattern, 1, true)) then n = n + 1 end
  end
  return n
end

local function printable_ascii(s) return type(s) == 'string' and not s:find('[^\32-\126]') end

-- A started loop over an empty bridge folder (floor nil).
local function started(files)
  local L, fs, env = setup(files)
  expect.equal(L:start(T0, M0), true)
  return L, fs, env
end

local PING = '{"command":"ping"}'

-- ---- Startup (decisions 2, 6, 9; design items 6 and 9) ----------------------------------------------------------------------------

test('start on empty folders records bridge_start as event 1 and publishes the first heartbeat (design items 6, 9; decisions 7, 9)', function()
  local L, fs = started()
  local events = events_of(fs)
  expect.equal(#events, 1)
  expect.equal(events[1].n, 1)
  expect.equal(events[1].t, T0)
  expect.equal(events[1].kind, 'bridge_start')
  expect.equal(events[1].version, version.VERSION)
  expect.equal(events[1].floor, nil)
  local hb = heartbeat_of(fs)
  expect.equal(hb.written_at, T0)
  expect.equal(hb.character, 'Testchar')
  expect.equal(hb.zone, 'bazaar')
  expect.equal(hb.state, 'running')
  expect.equal(hb.waiting_for_sequence, nil)
  expect.equal(hb.unreadable_sequence, nil)
  expect.equal(L:failure(), nil)
end)

test('the floor is the highest number present in inbox and outbox; every request present at startup is logged as startup_skipped (design item 6.1, 6.3)', function()
  local files = {}
  for n = 1, 3 do files[INBOX .. name(n)] = PING end
  files[OUTBOX .. name(2)] = '{"seq":2}'
  local L, fs = started(files)
  local events = events_of(fs)
  expect.equal(events[1].kind, 'bridge_start')
  expect.equal(events[1].floor, 3)
  local skipped = events_of_kind(fs, 'startup_skipped')
  expect.equal(#skipped, 3)
  for i = 1, 3 do expect.equal(skipped[i].seq, i) end
  expect.equal(#events, 4)
end)

test('the floor counts the outbox too: a request above the inbox numbers but at or below a reply already in the outbox is never handled (design item 6.1)', function()
  -- inbox has 3, outbox has 10: the floor is 10, so a request numbered 5 (above the inbox's highest) is at or below the floor.
  local files = { [INBOX .. name(3)] = PING, [OUTBOX .. name(10)] = '{"seq":10}' }
  local L, fs = started(files)
  expect.equal(events_of(fs)[1].floor, 10)
  put_request(fs, 5)
  L:step(T0, M0 + 100)
  expect.equal(fs.files[OUTBOX .. name(5)], nil)
  put_request(fs, 11)
  L:step(T0, M0 + 200)
  expect.truthy(fs.files[OUTBOX .. name(11)])
  expect.equal(events_of_kind(fs, 'request')[1].ordering, 'base')     -- reply 10 is AT the floor, not above it, so 11 is the first request above it (item 6.2)
end)

test('nothing at or below the floor is ever handled, and the first request above it is chosen under the base rule (design item 6.1, 6.2)', function()
  local files = {}
  for n = 1, 3 do files[INBOX .. name(n)] = PING end
  local L, fs = started(files)
  L:step(T0, M0 + 100)
  L:step(T0, M0 + 200)
  expect.equal(fs.files[OUTBOX .. name(1)], nil)
  expect.equal(fs.files[OUTBOX .. name(3)], nil)
  put_request(fs, 500)
  L:step(T0, M0 + 300)
  expect.truthy(fs.files[OUTBOX .. name(500)])
  local r = events_of_kind(fs, 'request')
  expect.equal(#r, 1)
  expect.equal(r[1].seq, 500)
  expect.equal(r[1].ordering, 'base')
end)

test('startup_skipped events are written only at startup, not on every poll (DL-022 step 2 note, design item 6.3)', function()
  local files = {}
  for n = 1, 3 do files[INBOX .. name(n)] = PING end
  local L, fs = started(files)
  local before = #events_of(fs)
  for i = 1, 5 do L:step(T0, M0 + i * 100) end
  expect.equal(#events_of(fs), before)
end)

test('a failure to list inbox or outbox at startup refuses to start, before any event is appended, and writes nothing (decisions 2, 9)', function()
  for _, which in ipairs({ 'inbox', 'outbox' }) do
    local L, fs = setup()
    fs.fail.list = function(path) if path:find(which, 1, true) then return 'Access is denied' end end
    local ok, reason, detail = L:start(T0, M0)
    expect.equal(ok, nil)
    expect.equal(reason, 'could not list the ' .. which .. ' folder')
    expect.equal(detail, 'Access is denied')
    expect.equal(fs.files[EVENTS], nil)
    expect.equal(fs.files[HEARTBEAT], nil)
    expect.equal(L:failure().reason, reason)     -- the failed start is also the loop's sticky failure
    expect.equal(L:failure().detail, detail)
  end
end)

test('an events file that cannot be opened refuses to start, with a fixed reason, before any event is appended (decision 6)', function()
  local L, fs = setup({ [EVENTS] = '{"n":1,"t":1,"kind":"chat"}\n' })
  fs.fail.size = function(path) if path == EVENTS then return 'Access is denied' end end
  local ok, reason, detail = L:start(T0, M0)
  expect.equal(ok, nil)
  expect.equal(reason, 'the events file could not be opened')
  expect.equal(detail, 'Access is denied')
  expect.equal(fs.files[HEARTBEAT], nil)
  expect.equal(count_ops(fs, 'append'), 0)
end)

test('an exhausted events file refuses to start, before any event is appended, and says it must be dealt with by hand (decision 6)', function()
  expect.truthy(store.EXHAUSTED)
  local L, fs = setup({ [EVENTS] = '{"n":999999999999999,"t":1,"kind":"chat"}\n' })
  local ok, reason, detail = L:start(T0, M0)
  expect.equal(ok, nil)
  expect.equal(reason, 'the events file is exhausted: its last event has the largest event number; deal with the file by hand before restarting')
  expect.equal(detail, store.EXHAUSTED)
  expect.equal(fs.files[HEARTBEAT], nil)
  expect.equal(count_ops(fs, 'append'), 0)
end)

test('if bridge_start cannot be recorded, startup refuses and no heartbeat is published; no claim is made about what a failed append left behind (decision 6)', function()
  local L, fs = setup()
  fs.fail.append = function() return 'No space left on device' end
  local ok, reason, detail = L:start(T0, M0)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not record the bridge_start event')
  expect.equal(detail, 'No space left on device')
  expect.equal(fs.files[HEARTBEAT], nil)
end)

test('a refused first heartbeat does not stop startup: any heartbeat failure skips the beat (decision 9)', function()
  local L, fs = setup({ [HEARTBEAT] = '{"old":true}' })
  fs.held[HEARTBEAT] = true
  expect.equal(L:start(T0, M0), true)
  expect.equal(L:failure(), nil)
  expect.equal(fs.files[HEARTBEAT], '{"old":true}')
end)

test('startup opens the events file before the first heartbeat attempt, and both come before any step (decision 9: what startup includes)', function()
  local files = { [INBOX .. name(7)] = PING }
  local L, fs = started(files)
  local first_append, first_replace
  for i, o in ipairs(fs.ops) do
    if o.op == 'append' and not first_append then first_append = i end
    if o.op == 'replace' and not first_replace then first_replace = i end
  end
  expect.truthy(first_append and first_replace and first_append < first_replace)
  expect.equal(count_ops(fs, 'rename', OUTBOX), 0)   -- no request processed yet
end)

test('after a failed start, step and on_event do nothing (decision 9)', function()
  local L, fs = setup()
  fs.fail.list = function(path) if path:find('inbox', 1, true) then return 'denied' end end
  L:start(T0, M0)
  local ops = #fs.ops
  L:step(T0, M0 + 5000)
  L:on_event('a line', T0)
  expect.equal(#fs.ops, ops)
end)

-- ---- The heartbeat schedule on clock readings (decision 7, amended; design items 9, 26) ------------------------------------------------

test('a heartbeat is due 1,000 ms after the last attempt on the monotonic reading, not before (decision 7)', function()
  local L, fs = started()
  expect.equal(count_ops(fs, 'replace'), 1)
  L:step(T0, M0 + 999)
  expect.equal(count_ops(fs, 'replace'), 1)
  L:step(T0, M0 + 1000)
  expect.equal(count_ops(fs, 'replace'), 2)
  L:step(T0, M0 + 1999)
  expect.equal(count_ops(fs, 'replace'), 2)
  L:step(T0, M0 + 2000)
  expect.equal(count_ops(fs, 'replace'), 3)
end)

test('the next beat is measured from the last ATTEMPT, so a refused replace is retried at the next due time, not in a loop (decision 7, item 26.2)', function()
  local L, fs = started()
  fs.held[HEARTBEAT] = true
  L:step(T0, M0 + 1000)                      -- attempted and refused
  expect.equal(count_ops(fs, 'replace'), 2)
  expect.equal(heartbeat_of(fs).written_at, T0)
  L:step(T0 + 1, M0 + 1100)
  L:step(T0 + 1, M0 + 1999)
  expect.equal(count_ops(fs, 'replace'), 2)  -- no retry inside the second
  fs.held[HEARTBEAT] = nil
  L:step(T0 + 2, M0 + 2000)
  expect.equal(count_ops(fs, 'replace'), 3)
  expect.equal(heartbeat_of(fs).written_at, T0 + 2)
end)

test('after a long stall exactly one beat is written, and the next is due 1,000 ms after it: no catch-up burst (decision 7)', function()
  local L, fs = started()
  L:step(T0 + 9, M0 + 9000)
  expect.equal(count_ops(fs, 'replace'), 2)
  L:step(T0 + 9, M0 + 9500)
  expect.equal(count_ops(fs, 'replace'), 2)
  L:step(T0 + 10, M0 + 10000)
  expect.equal(count_ops(fs, 'replace'), 3)
end)

test('written_at comes from the wall reading and scheduling from the monotonic one: moving one without the other changes only its own job (decision 7)', function()
  local L, fs = started()
  L:step(T0 + 5000, M0 + 100)                -- the wall clock jumps forward; no beat is due on the monotonic reading
  expect.equal(count_ops(fs, 'replace'), 1)
  L:step(T0 - 999, M0 + 1000)                -- the wall clock is behind; a beat is due on the monotonic reading
  expect.equal(count_ops(fs, 'replace'), 2)
  expect.equal(heartbeat_of(fs).written_at, T0 - 999)
end)

test('any heartbeat publish failure, the temporary write or a replace for any reason, skips the beat without stopping anything (decision 9)', function()
  local L, fs = started()
  fs.fail.write = function(path) if path:find('heartbeat.json.tmp', 1, true) then return 'No space left on device' end end
  L:step(T0, M0 + 1000)
  expect.equal(L:failure(), nil)
  fs.fail.write = nil
  fs.fail.replace = function() return 'MoveFileExA failed: GetLastError 87' end
  L:step(T0, M0 + 2000)
  expect.equal(L:failure(), nil)
  fs.fail.replace = nil
  put_request(fs, 1)
  L:step(T0, M0 + 2100)                      -- requests are still served
  expect.truthy(fs.files[OUTBOX .. name(1)])
  expect.equal(#events_of_kind(fs, 'request'), 1)
  expect.equal(#events_of(fs), 2)            -- bridge_start and the request: a heartbeat failure is not logged
end)

test('character and zone are null in the heartbeat when no character is in the game (design item 9)', function()
  local L, fs, env = setup()
  env.char, env.zone_name = nil, nil
  L:start(T0, M0)
  local text = fs.files[HEARTBEAT]
  expect.truthy(text:find('"character":null', 1, true))
  expect.truthy(text:find('"zone":null', 1, true))
end)

-- ---- Requests (criteria 2, 10, 13; design items 5, 6, 8, 19) ----------------------------------------------------------------------

test('a ping is answered with exactly what core.handle returns, and logged as a request event with the base ordering first (criteria 1, 2; item 6.2)', function()
  local L, fs, env = started()
  put_request(fs, 1)
  L:step(T0 + 1, M0 + 100)
  local expected = core.handle(env, '1', PING)
  expect.equal(fs.files[OUTBOX .. name(1)], expected)
  local r = events_of_kind(fs, 'request')
  expect.equal(#r, 1)
  expect.equal(r[1].seq, 1)
  expect.equal(r[1].command, 'ping')
  expect.equal(r[1].result, 'ok')
  expect.equal(r[1].ordering, 'base')
  expect.equal(r[1].message, nil)
  expect.equal(r[1].t, T0 + 1)
  put_request(fs, 2)
  L:step(T0 + 1, M0 + 200)
  expect.equal(events_of_kind(fs, 'request')[2].ordering, 'strict')
end)

test('one request is handled per step, in sequence order (criterion 2; decision 9 implementation choice)', function()
  local L, fs = started()
  for n = 1, 3 do put_request(fs, n) end
  L:step(T0, M0 + 100)
  expect.truthy(fs.files[OUTBOX .. name(1)])
  expect.equal(fs.files[OUTBOX .. name(2)], nil)
  L:step(T0, M0 + 200)
  expect.truthy(fs.files[OUTBOX .. name(2)])
  expect.equal(fs.files[OUTBOX .. name(3)], nil)
  L:step(T0, M0 + 300)
  expect.truthy(fs.files[OUTBOX .. name(3)])
end)

test('a gap blocks later requests and shows waiting_for_sequence in the heartbeat; filling it lets them through in order (criterion 2)', function()
  local L, fs = started()
  put_request(fs, 1)
  put_request(fs, 3)
  L:step(T0, M0 + 100)                       -- handles 1 (base)
  L:step(T0, M0 + 1000)                      -- request 3 waits for 2; a beat is due
  expect.equal(fs.files[OUTBOX .. name(3)], nil)
  expect.equal(heartbeat_of(fs).waiting_for_sequence, 2)
  put_request(fs, 2)
  L:step(T0, M0 + 1100)
  expect.truthy(fs.files[OUTBOX .. name(2)])
  L:step(T0, M0 + 2000)
  expect.truthy(fs.files[OUTBOX .. name(3)])
  expect.equal(heartbeat_of(fs).waiting_for_sequence, nil)
end)

test('an invalid request gets an error reply, counts as completed, and does not block the next one (criterion 10)', function()
  local L, fs = started()
  put_request(fs, 1, '{not json')
  put_request(fs, 2)
  L:step(T0, M0 + 100)
  local d = json.decode(fs.files[OUTBOX .. name(1)])
  expect.equal(d.ok, false)
  expect.equal(d.error.kind, 'invalid_request')
  local r = events_of_kind(fs, 'request')
  expect.equal(r[1].result, 'invalid_request')
  expect.equal(r[1].message, d.error.message)
  expect.equal(r[1].command, nil)
  L:step(T0, M0 + 200)
  expect.equal(json.decode(fs.files[OUTBOX .. name(2)]).ok, true)
end)

test('an unreadable request is deferred: no reply, one unreadable event with the error, unreadable_sequence in the heartbeat, retried every step (item 19)', function()
  local L, fs = started()
  put_request(fs, 1)
  fs.fail.read = function(path) if path:find(name(1), 1, true) then return 'Permission denied (sharing violation)' end end
  L:step(T0, M0 + 100)
  L:step(T0, M0 + 200)
  L:step(T0, M0 + 1000)
  expect.equal(fs.files[OUTBOX .. name(1)], nil)
  local u = events_of_kind(fs, 'unreadable')
  expect.equal(#u, 1)                        -- one event per file, not one per poll
  expect.equal(u[1].seq, 1)
  expect.equal(u[1].error, 'Permission denied (sharing violation)')
  expect.equal(heartbeat_of(fs).unreadable_sequence, 1)
  fs.fail.read = nil
  L:step(T0, M0 + 1100)                      -- readable now: handled, never given up on
  expect.truthy(fs.files[OUTBOX .. name(1)])
  L:step(T0, M0 + 2000)
  expect.equal(heartbeat_of(fs).unreadable_sequence, nil)
  expect.equal(#events_of_kind(fs, 'unreadable'), 1)
end)

test('an oversized request file is answered with core.oversize_reply and its contents are never read (criterion 13; decisions 4, 9)', function()
  local L, fs = started()
  fs.files[INBOX .. name(1)] = string.rep('x', core.MAX_REQUEST_BYTES + 1)
  L:step(T0, M0 + 100)
  local expected = core.oversize_reply('1')
  expect.equal(fs.files[OUTBOX .. name(1)], expected)
  expect.equal(count_ops(fs, 'read', name(1)), 0)
  expect.equal(count_ops(fs, 'read_range', name(1)), 0)
  local r = events_of_kind(fs, 'request')
  expect.equal(r[1].result, 'request_too_large')
  expect.equal(r[1].command, nil)
  put_request(fs, 2)
  L:step(T0, M0 + 200)                       -- completed under the existing outbox rule: the next request is handled
  expect.truthy(fs.files[OUTBOX .. name(2)])
end)

test('the reply is published before the request counts as handled: the reply rename comes before the request event (item 5)', function()
  local L, fs = started()
  put_request(fs, 1)
  local before = #fs.ops
  L:step(T0, M0 + 100)
  local rename_at, append_at
  for i = before + 1, #fs.ops do
    local o = fs.ops[i]
    if o.op == 'rename' and o.path:find('outbox', 1, true) and not rename_at then rename_at = i end
    if o.op == 'append' and o.path == EVENTS and not append_at then append_at = i end
  end
  expect.truthy(rename_at and append_at and rename_at < append_at)
end)

test('the request event for a request is written once, not again on later polls (Protocol section 8, item 9)', function()
  local L, fs = started()
  put_request(fs, 1)
  for i = 1, 4 do L:step(T0, M0 + i * 100) end
  expect.equal(#events_of_kind(fs, 'request'), 1)
end)

-- ---- Events (criterion 7; decision 6) -------------------------------------------------------------------------------------------------

test('every heard line is recorded as a chat event with the wall time and the text unchanged, numbers increasing with the bridge events (criterion 7)', function()
  local L, fs = started()
  L:on_event('You have entered The Bazaar.', T0 + 5)
  put_request(fs, 1)
  L:step(T0 + 6, M0 + 100)
  L:on_event('caf\195\169 \18 item', T0 + 7)
  local events = events_of(fs)
  expect.equal(kinds_of(fs), { 'bridge_start', 'chat', 'request', 'chat' })
  for i, e in ipairs(events) do expect.equal(e.n, i) end
  expect.equal(events[2].text, 'You have entered The Bazaar.')
  expect.equal(events[2].t, T0 + 5)
  expect.equal(events[4].text, nil)
  expect.equal(events[4].text_base64 ~= nil, true)
end)

test('on_event never raises, whatever it is given (decision 6: the callback does not raise)', function()
  local L = started()
  expect.equal((pcall(L.on_event, L, nil, T0)), true)
  expect.equal((pcall(L.on_event, L, 42, T0)), true)
  expect.equal((pcall(L.on_event, L, string.rep('\0\255', 50), T0)), true)
  expect.equal(L:failure(), nil)
end)

test('an events append failure sets one sticky fatal state; later events are ignored and no later step does anything (decisions 6, 9)', function()
  local L, fs = started()
  fs.fail.append = function(path) if path == EVENTS then return 'No space left on device' end end
  L:on_event('a line', T0 + 1)
  local f = L:failure()
  expect.equal(f.reason, 'could not record an event')
  expect.equal(f.detail, 'No space left on device')
  fs.fail.append = nil
  local ops = #fs.ops
  put_request(fs, 1)
  L:on_event('another line', T0 + 2)
  L:step(T0 + 3, M0 + 5000)
  L:step(T0 + 4, M0 + 9000)
  expect.equal(#fs.ops, ops + 0)             -- put_request touches only the table, not the adapter
  expect.equal(fs.files[OUTBOX .. name(1)], nil)
  expect.equal(#events_of(fs), 1)
  expect.truthy(rawequal(L:failure(), f))    -- reported once: the same object, the first failure preserved
end)

test('the failure of a bridge-generated event takes the same fatal path, and the reply already written stands (decision 6, item 5)', function()
  local L, fs = started()
  put_request(fs, 1)
  fs.fail.append = function(path) if path == EVENTS then return 'Permission denied' end end
  L:step(T0, M0 + 100)
  expect.truthy(fs.files[OUTBOX .. name(1)])  -- the request is completed: its reply exists
  local f = L:failure()
  expect.equal(f.reason, 'could not record an event')
  expect.equal(f.detail, 'Permission denied')
end)

test('after a failed request event the same step publishes no heartbeat even though one is due (decisions 6, 9)', function()
  local L, fs = started()
  put_request(fs, 1)
  fs.fail.append = function(path) if path == EVENTS then return 'Permission denied' end end
  L:step(T0, M0 + 1000)                      -- a beat is due in this very step
  expect.truthy(L:failure())
  expect.equal(count_ops(fs, 'replace'), 1)  -- only the startup heartbeat
end)

test('after a failed unreadable event the same step publishes no heartbeat even though one is due (decisions 6, 9)', function()
  local L, fs = started()
  put_request(fs, 1)
  fs.fail.read = function(path) if path:find(name(1), 1, true) then return 'sharing violation' end end
  fs.fail.append = function(path) if path == EVENTS then return 'Permission denied' end end
  L:step(T0, M0 + 1000)
  expect.truthy(L:failure())
  expect.equal(L:failure().detail, 'Permission denied')
  expect.equal(count_ops(fs, 'replace'), 1)
end)

test('before start, step and on_event do nothing and do not raise (decision 9: nothing runs before startup has finished)', function()
  local L, fs = setup()
  expect.equal((pcall(L.step, L, T0, M0 + 5000)), true)
  expect.equal((pcall(L.on_event, L, 'a line', T0)), true)
  expect.equal(#fs.ops, 0)
  expect.equal(L:failure(), nil)
end)

test('event-number exhaustion at runtime takes the same fatal path as a write failure (decision 6)', function()
  local L, fs = setup({ [EVENTS] = '{"n":999999999999997,"t":1,"kind":"chat"}\n' })
  expect.equal(L:start(T0, M0), true)         -- bridge_start takes ...998
  L:on_event('takes the largest number', T0 + 1)
  expect.equal(L:failure(), nil)
  L:on_event('no number left', T0 + 2)
  local f = L:failure()
  expect.equal(f.reason, 'could not record an event')
  expect.equal(f.detail, store.EXHAUSTED)
  local ops = #fs.ops
  L:step(T0 + 3, M0 + 5000)
  L:on_event('ignored', T0 + 4)
  expect.equal(#fs.ops, ops)
end)

-- ---- Runtime failures of the loop's own file operations (decision 9) -----------------------------------------------------------------

test('a runtime failure to list inbox or outbox stops the bridge: one fatal state, no further work (decision 9)', function()
  for _, which in ipairs({ 'inbox', 'outbox' }) do
    local L, fs = started()
    fs.fail.list = function(path) if path:find(which, 1, true) then return 'The network path was not found' end end
    L:step(T0, M0 + 100)
    local f = L:failure()
    expect.equal(f.reason, 'could not list the ' .. which .. ' folder')
    expect.equal(f.detail, 'The network path was not found')
    fs.fail.list = nil
    local ops = #fs.ops
    L:step(T0, M0 + 5000)
    expect.equal(#fs.ops, ops)
    expect.equal(count_ops(fs, 'replace'), 1)   -- no heartbeat after the failure
  end
end)

test('a failure to write or rename a reply stops the bridge: no request event, no later step, heartbeat or event (decision 9, item 5)', function()
  for _, op in ipairs({ 'write', 'rename' }) do
    local L, fs = started()
    put_request(fs, 1)
    fs.fail[op] = function(path) if path:find(OUTBOX, 1, true) then return 'Disk error' end end
    L:step(T0, M0 + 100)
    local f = L:failure()
    expect.equal(f.reason, 'could not write a reply')
    expect.equal(f.detail, 'Disk error')
    expect.equal(fs.files[OUTBOX .. name(1)], nil)
    expect.equal(#events_of_kind(fs, 'request'), 0)
    fs.fail[op] = nil
    local ops = #fs.ops
    L:step(T0, M0 + 5000)
    L:on_event('ignored', T0 + 1)
    expect.equal(#fs.ops, ops)
  end
end)

test('every failure reason is a fixed printable ASCII string, and the raw error is carried separately (decision 6, design item 20)', function()
  local L, fs = started()
  fs.fail.append = function() return 'Caf\195\169 error \0 with odd bytes' end
  L:on_event('x', T0 + 1)
  local f = L:failure()
  expect.truthy(printable_ascii(f.reason))
  expect.equal(f.detail, 'Caf\195\169 error \0 with odd bytes')
end)

test('an error raised inside the store while recording an event is caught: on_event still does not raise and the fatal state is set (decision 6)', function()
  local L, fs = setup()
  L:start(T0, M0)
  -- a store whose append_event raises (a programming error or an unexpected runtime error inside it)
  local st = L.store
  st.append_event = function() error('boom inside the store') end
  expect.equal((pcall(L.on_event, L, 'a line', T0 + 1)), true)
  local f = L:failure()
  expect.equal(f.reason, 'could not record an event')
  expect.truthy(tostring(f.detail):find('boom inside the store', 1, true))
end)

-- ---- Reviewer findings on subset 2 (DL-022 addendum, 2026-09-30) ---------------------------------------------------------------------

test('a later startup event that fails stops startup with no heartbeat, leaving the events already written: no rollback is claimed (decision 6)', function()
  -- bridge_start (1st append) and the skipped event for request 1 (2nd) succeed; the skipped event for request 2 (3rd append) fails.
  local files = { [INBOX .. name(1)] = PING, [INBOX .. name(2)] = PING, [INBOX .. name(3)] = PING }
  local L, fs = setup(files)
  local appends = 0
  fs.fail.append = function(path)
    if path == EVENTS then
      appends = appends + 1
      if appends == 3 then return 'No space left on device' end
    end
  end
  local ok, reason, detail = L:start(T0, M0)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not record an event')
  expect.equal(detail, 'No space left on device')
  expect.equal(L:failure().reason, reason)
  expect.equal(fs.files[HEARTBEAT], nil)                       -- startup did not finish: no heartbeat
  expect.equal(kinds_of(fs), { 'bridge_start', 'startup_skipped' })   -- what was already written stays
  L:step(T0, M0 + 5000)
  expect.equal(fs.files[HEARTBEAT], nil)
end)

test('a heartbeat publish that RAISES, in the store, the adapter or a game read, only skips the beat, at startup and in a step (decision 9)', function()
  local L, fs, env = setup()
  local st = L.store
  local calls = 0
  st.publish_heartbeat = function() calls = calls + 1; error('the adapter raised') end
  expect.equal((pcall(L.start, L, T0, M0)), true)
  expect.equal(L:failure(), nil)
  expect.equal(calls, 1)                                       -- the startup attempt happened and was skipped
  put_request(fs, 1)
  expect.equal((pcall(L.step, L, T0, M0 + 999)), true)
  expect.equal(calls, 1)                                       -- not due yet
  expect.truthy(fs.files[OUTBOX .. name(1)])                   -- requests are still served
  expect.equal((pcall(L.step, L, T0, M0 + 1000)), true)
  expect.equal(calls, 2)                                       -- due: attempted once, skipped
  expect.equal((pcall(L.step, L, T0, M0 + 1500)), true)
  expect.equal(calls, 2)                                       -- measured from the attempt, not retried in a loop
  expect.equal(L:failure(), nil)
  -- and a raise from the game read for the character
  local L2, fs2, env2 = setup()
  env2.character = function() error('the TLO read raised') end
  expect.equal((pcall(L2.start, L2, T0, M0)), true)
  expect.equal(fs2.files[HEARTBEAT], nil)                      -- the beat was skipped
  expect.equal(L2:failure(), nil)
end)

test('start is called once: a second call after a successful startup returns nil and does nothing (single-call contract)', function()
  local L, fs = started({ [INBOX .. name(1)] = PING })
  local events_before, ops_before = #events_of(fs), #fs.ops
  local ok, reason = L:start(T0 + 1, M0 + 100)
  expect.equal(ok, nil)
  expect.equal(reason, 'start was already called')
  expect.equal(#fs.ops, ops_before)                            -- no file operation at all
  expect.equal(#events_of(fs), events_before)                  -- no second bridge_start, no repeated startup_skipped
  expect.equal(L:failure(), nil)                               -- a caller error, not a fatal failure
  put_request(fs, 2)
  L:step(T0 + 2, M0 + 200)                                     -- the loop still works
  expect.truthy(fs.files[OUTBOX .. name(2)])
end)

test('start after a failed startup returns nil and does nothing: the sticky failure stands (single-call contract)', function()
  local L, fs = setup()
  fs.fail.list = function(path) if path:find('inbox', 1, true) then return 'Access is denied' end end
  local _, first_reason = L:start(T0, M0)
  local failure = L:failure()
  fs.fail.list = nil
  local ops = #fs.ops
  local ok, reason = L:start(T0 + 1, M0 + 100)
  expect.equal(ok, nil)
  expect.equal(reason, 'start was already called')
  expect.equal(#fs.ops, ops)
  expect.equal(fs.files[EVENTS], nil)
  expect.equal(fs.files[HEARTBEAT], nil)
  expect.truthy(rawequal(L:failure(), failure))
  expect.equal(failure.reason, first_reason)
  L:step(T0 + 2, M0 + 200)
  expect.equal(#fs.ops, ops)
end)
