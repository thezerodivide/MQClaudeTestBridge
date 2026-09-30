-- Tests for claudebridge/store.lua (Step 4 of DL-022: the heartbeat, events and reply files, and the ASCII folder check).
-- Requirement sources (DL-018 / DL-021 in docs/decision_log.md), named per test below:
--   * Criterion 6 with design items 9 and 26: heartbeat.json holds bridge_version, character, zone, state and written_at
--     (whole seconds); waiting_for_sequence only during a real gap (criterion 2); unreadable_sequence only while the next
--     request cannot be read (item 19); character and zone are null when no character is in the game; a reader never sees
--     a partial heartbeat (temp file in the same folder, then a replace; a refused replace skips the beat and does not
--     retry inside the call; the temp name is never the destination).
--   * Criterion 7 with design items 9 and 10: every event is one JSON object on its own line, appended in observation order,
--     with an increasing event number n and the time t; text keeps the item 16 rule; on start the file is appended to,
--     numbering continues from the last complete line, and a leftover fragment gets a newline so nothing is glued to it.
--   * Design item 5: a reply is published by writing a temporary name and renaming, so a half-written reply is never
--     mistaken for a completed request; a reply is never overwritten.
--   * Criterion 13 with design item 14: a request file over the limit is never read (its size is checked first); item 19:
--     a request file that cannot be read now is reported as unreadable, with the operating system's error, and tried
--     again on the next call.
--   * The 2026-09-29 decision on non-ASCII paths: the bridge folder path is rejected if any byte is above 0x7F.
-- store.new(fs, dir) works over an injected file-system adapter, so no file is touched here; the fake below models what
-- the spikes observed of Windows (rename onto an existing file fails: spike 8 b2; a replace onto a file a reader holds open
-- fails safely and leaves the old content: spike 8 c3 and spike 9). The real adapter and the real MoveFileExA are live-only.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local json = require 'claudebridge.json'
local version = require 'claudebridge.version'
local queue = require 'claudebridge.queue'
local store = require 'claudebridge.store'

local DIR = 'C:\\Users\\Public\\MacroQuest\\claude'
local BS = '\\'

-- ---- The fake file-system adapter ---------------------------------------------------------------------------------

-- Every operation is recorded in fs.ops as { op, path, ... }. fs.fail[op] = function(path, ...) -> error string or nil
-- makes that operation fail (nothing changes on failure). fs.held[path] = true models a reader holding a file open: a
-- replace onto it is refused. fs.observe, if set, is called before every operation, so a test can look at the world at
-- every point where a reader could look.
local function fake_fs(files)
  local fs = { files = files or {}, ops = {}, fail = {}, held = {} }

  local function begin(op, path, ...)
    fs.ops[#fs.ops + 1] = { op = op, path = path, ... }
    if fs.observe then fs.observe(op, path) end
    local f = fs.fail[op]
    if f then
      local e = f(path, ...)
      if e then return e end
    end
  end

  function fs.list(dir)
    local e = begin('list', dir)
    if e then return nil, e end
    local names, prefix = {}, dir .. BS
    for path in pairs(fs.files) do
      if path:sub(1, #prefix) == prefix and not path:find(BS, #prefix + 1, true) then names[#names + 1] = path:sub(#prefix + 1) end
    end
    table.sort(names)
    return names
  end

  function fs.size(path)
    local e = begin('size', path)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path, 'not_found' end
    return #fs.files[path]
  end

  function fs.read(path)
    local e = begin('read', path)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path end
    return fs.files[path]
  end

  function fs.read_range(path, offset, length)
    local e = begin('read_range', path, offset, length)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path end
    return fs.files[path]:sub(offset + 1, offset + length)
  end

  function fs.write(path, data)
    local e = begin('write', path, data)
    if e then return nil, e end
    fs.files[path] = data
    return true
  end

  function fs.append(path, data)
    local e = begin('append', path, data)
    if e then return nil, e end
    fs.files[path] = (fs.files[path] or '') .. data
    return true
  end

  -- os.rename semantics on Windows (spike 8 b2): fails if the destination exists.
  function fs.rename(src, dst)
    local e = begin('rename', src, dst)
    if e then return nil, e end
    if not fs.files[src] then return nil, 'No such file: ' .. src end
    if fs.files[dst] then return nil, 'File exists: ' .. dst end
    fs.files[dst], fs.files[src] = fs.files[src], nil
    return true
  end

  -- MoveFileExA with MOVEFILE_REPLACE_EXISTING semantics (spike 8 c1 to c3): replaces, or is refused if a reader holds the
  -- destination, leaving both files as they were.
  function fs.replace(src, dst)
    local e = begin('replace', src, dst)
    if e then return nil, e end
    if not fs.files[src] then return nil, 'No such file: ' .. src end
    if fs.held[dst] then return nil, 'MoveFileExA failed: GetLastError 5' end
    fs.files[dst], fs.files[src] = fs.files[src], nil
    return true
  end

  function fs.remove(path)
    begin('remove', path)
    fs.files[path] = nil
    return true
  end

  return fs
end

local function count_ops(fs, op)
  local n = 0
  for _, o in ipairs(fs.ops) do
    if o.op == op then n = n + 1 end
  end
  return n
end

local function clear_ops(fs) fs.ops = {} end

local INBOX = DIR .. BS .. 'inbox' .. BS
local OUTBOX = DIR .. BS .. 'outbox' .. BS
local HEARTBEAT = DIR .. BS .. 'heartbeat.json'
local EVENTS = DIR .. BS .. 'events.jsonl'

-- ---- The ASCII folder check (2026-09-29 decision: refuse a non-ASCII folder path) --------------------------------------

test('an ASCII folder path is accepted, including the default folder (non-ASCII-path decision)', function()
  expect.truthy(store.check_bridge_dir('C:\\Users\\Public\\MacroQuest\\claude'))
  expect.truthy(store.check_bridge_dir('D:\\Games\\mq\\claude'))
end)

test('the boundary is exact: byte 0x7F is accepted, every byte 0x80 to 0xFF is rejected (non-ASCII-path decision)', function()
  expect.truthy(store.check_bridge_dir('C:\\x' .. string.char(0x7F) .. 'y'))
  for b = 0x80, 0xFF do
    local ok = store.check_bridge_dir('C:\\Users\\a' .. string.char(b) .. 'b\\claude')
    expect.equal(ok, false, 'byte ' .. b .. ' should be rejected')
  end
end)

test('a rejected path gives one fixed ASCII reason that does not repeat the path (decision: one clear console line)', function()
  local ok, reason = store.check_bridge_dir('C:\\Users\\J\195\184rg\\claude')
  expect.equal(ok, false)
  expect.equal(type(reason), 'string')
  expect.falsy(reason:find('[^\32-\126]'))
  expect.falsy(reason:find('Zq', 1, true))
  expect.falsy(reason:find('Users', 1, true))
end)

test('a path that is not a string is refused, never accepted (fail closed; the check judges the derived folder string)', function()
  expect.equal((store.check_bridge_dir(nil)), false)
  expect.equal((store.check_bridge_dir(42)), false)
  expect.equal((store.check_bridge_dir({})), false)
end)

test('a store cannot be made over a non-ASCII folder even if the caller skipped the check (non-ASCII-path decision)', function()
  expect.falsy((pcall(store.new, fake_fs(), 'C:\\Users\\Zq\195\184Zq\\claude')))
end)

-- ---- Reading a request (criterion 13, design item 19) --------------------------------------------------------------------

test('a readable request comes back as its exact bytes, read from inbox\\<name> (criterion 1 path)', function()
  local fs = fake_fs({ [INBOX .. '000123.json'] = '{"command":"ping"}\0\128\255' })
  local s = store.new(fs, DIR)
  local r = s:read_request('000123.json')
  expect.equal(r.status, 'ok')
  expect.equal(r.text, '{"command":"ping"}\0\128\255')
end)

test('a request over the 32,768-byte limit is reported as too large and its contents are never read (criterion 13, item 14)', function()
  local fs = fake_fs({ [INBOX .. '000005.json'] = string.rep('x', 32769) })
  local s = store.new(fs, DIR)
  local r = s:read_request('000005.json')
  expect.equal(r.status, 'too_large')
  expect.equal(r.size, 32769)
  expect.equal(count_ops(fs, 'read'), 0)
  expect.equal(count_ops(fs, 'read_range'), 0)
end)

test('a request of exactly 32,768 bytes is read (criterion 13: a file at the limit is accepted)', function()
  local fs = fake_fs({ [INBOX .. '000005.json'] = string.rep('x', 32768) })
  local r = store.new(fs, DIR):read_request('000005.json')
  expect.equal(r.status, 'ok')
  expect.equal(#r.text, 32768)
end)

test('a request that cannot be read now is unreadable with the OS error, and reading it again later can succeed (item 19)', function()
  local fs = fake_fs({ [INBOX .. '000007.json'] = '{"command":"ping"}' })
  local s = store.new(fs, DIR)
  fs.fail.read = function() return 'Permission denied (sharing violation)' end
  local r = s:read_request('000007.json')
  expect.equal(r.status, 'unreadable')
  expect.equal(r.error, 'Permission denied (sharing violation)')
  fs.fail.read = nil
  expect.equal(s:read_request('000007.json').status, 'ok')
end)

test('a request whose size cannot be read is also unreadable, not too large and not an empty request (item 19)', function()
  local fs = fake_fs({ [INBOX .. '000007.json'] = '{"command":"ping"}' })
  fs.fail.size = function() return 'Access is denied' end
  local r = store.new(fs, DIR):read_request('000007.json')
  expect.equal(r.status, 'unreadable')
  expect.equal(r.error, 'Access is denied')
  expect.equal(r.text, nil)
end)

test('a request file that does not exist is unreadable, never an empty request (item 19: unreadable is not invalid)', function()
  local r = store.new(fake_fs(), DIR):read_request('000009.json')
  expect.equal(r.status, 'unreadable')
end)

-- ---- Listing (input to queue.select) ------------------------------------------------------------------------------------

test('the request and reply listings give bare file names of their own folder only (input to queue.select)', function()
  local fs = fake_fs({
    [INBOX .. '000001.json'] = 'a', [INBOX .. '000002.json'] = 'b',
    [OUTBOX .. '000001.json'] = 'r', [DIR .. BS .. 'heartbeat.json'] = 'h',
  })
  local s = store.new(fs, DIR)
  expect.equal(s:list_requests(), { '000001.json', '000002.json' })
  expect.equal(s:list_replies(), { '000001.json' })
end)

test('a listing that fails returns nil and the error, so the loop can tell it from an empty folder', function()
  local fs = fake_fs()
  fs.fail.list = function() return 'The system cannot find the path specified' end
  local names, err = store.new(fs, DIR):list_requests()
  expect.equal(names, nil)
  expect.equal(err, 'The system cannot find the path specified')
end)

-- ---- Writing a reply (design item 5) ------------------------------------------------------------------------------------

test('a reply ends up in outbox under the canonical name with its exact bytes and no temporary file left (item 5)', function()
  local fs = fake_fs()
  local ok = store.new(fs, DIR):write_reply('123', '{"seq":123,"ok":true}\128')
  expect.equal(ok, true)
  expect.equal(fs.files[OUTBOX .. '000123.json'], '{"seq":123,"ok":true}\128')
  local n = 0
  for _ in pairs(fs.files) do n = n + 1 end
  expect.equal(n, 1)
end)

test('the reply name follows the request rule across the six-to-seven digit boundary (item 8 via queue.filename)', function()
  local fs = fake_fs()
  store.new(fs, DIR):write_reply('1000000', 'r')
  expect.truthy(fs.files[OUTBOX .. '1000000.json'])
end)

test('a half-written reply is never mistaken for a completed request: the temporary name is not a reply name (item 5)', function()
  local fs = fake_fs()
  local seen
  fs.observe = function(op)
    if op == 'rename' then
      -- the world just before the reply becomes visible: only a temporary name may exist in outbox
      local names = {}
      for path in pairs(fs.files) do
        if path:sub(1, #OUTBOX) == OUTBOX then names[#names + 1] = path:sub(#OUTBOX + 1) end
      end
      seen = names
    end
  end
  store.new(fs, DIR):write_reply('4', '{"seq":4}')
  expect.equal(#seen, 1)
  -- queue.select is the oracle: with that name in outbox and requests 4 and 5 waiting, nothing counts as completed, so 4 is next
  local sel = queue.select({ '000004.json', '000005.json' }, seen, nil)
  expect.equal(sel.next.seq, '4')
end)

test('the reply is written to the temporary name and only then renamed, in that order (item 5)', function()
  local fs = fake_fs()
  store.new(fs, DIR):write_reply('4', 'R')
  expect.equal(#fs.ops, 2)
  expect.equal(fs.ops[1].op, 'write')
  expect.equal(fs.ops[2].op, 'rename')
  expect.equal(fs.ops[2].path, fs.ops[1].path)
  expect.equal(fs.ops[2][1], OUTBOX .. '000004.json')
end)

test('a failed write leaves no reply, and the failure is returned (item 5: a reply never appears half-written)', function()
  local fs = fake_fs()
  fs.fail.write = function() return 'No space left on device' end
  local ok, err = store.new(fs, DIR):write_reply('4', 'R')
  expect.equal(ok, nil)
  expect.equal(err, 'No space left on device')
  expect.equal(fs.files[OUTBOX .. '000004.json'], nil)
  expect.equal(count_ops(fs, 'rename'), 0)
end)

test('a failed rename leaves no reply, and the failure is returned (item 5)', function()
  local fs = fake_fs()
  fs.fail.rename = function() return 'Permission denied' end
  local ok, err = store.new(fs, DIR):write_reply('4', 'R')
  expect.equal(ok, nil)
  expect.equal(err, 'Permission denied')
  expect.equal(fs.files[OUTBOX .. '000004.json'], nil)
end)

test('an existing reply is never overwritten (item 5: reply names are new names; rename onto an existing file fails)', function()
  local fs = fake_fs({ [OUTBOX .. '000004.json'] = 'FIRST' })
  local ok, err = store.new(fs, DIR):write_reply('4', 'SECOND')
  expect.equal(ok, nil)
  expect.truthy(err)
  expect.equal(fs.files[OUTBOX .. '000004.json'], 'FIRST')
end)

test('a sequence number that is not an unpadded decimal string is refused, so no odd file name can be built (item 8)', function()
  local s = store.new(fake_fs(), DIR)
  expect.falsy((pcall(s.write_reply, s, '0123', 'r')))
  expect.falsy((pcall(s.write_reply, s, '..\\x', 'r')))
  expect.falsy((pcall(s.write_reply, s, 12, 'r')))
end)

-- ---- The heartbeat (criterion 6, design items 9 and 26) ------------------------------------------------------------------

local function heartbeat_text(fs) return fs.files[HEARTBEAT] end

test('the heartbeat holds bridge_version, character, zone, state running and written_at in whole seconds (criterion 6, item 9)', function()
  local fs = fake_fs()
  local ok = store.new(fs, DIR):publish_heartbeat({ character = 'Testchar', zone = 'bazaar', now = 1727612345 })
  expect.equal(ok, true)
  local hb = json.decode(heartbeat_text(fs))
  expect.equal(hb.bridge_version, version.VERSION)
  expect.equal(hb.character, 'Testchar')
  expect.equal(hb.zone, 'bazaar')
  expect.equal(hb.state, 'running')
  expect.equal(hb.written_at, 1727612345)
end)

test('the heartbeat is one line of JSON whose written_at is exactly the given time, for a time in the seven-digit range too', function()
  local fs = fake_fs()
  store.new(fs, DIR):publish_heartbeat({ character = 'A', zone = 'b', now = 1727612345 })
  expect.truthy(heartbeat_text(fs):find('"written_at":1727612345', 1, true))
  expect.falsy(heartbeat_text(fs):find('[\r\n]'))
end)

test('character and zone are null when no character is in the game (item 9: null, not missing, not empty)', function()
  local fs = fake_fs()
  store.new(fs, DIR):publish_heartbeat({ character = nil, zone = nil, now = 5 })
  local text = heartbeat_text(fs)
  expect.truthy(text:find('"character":null', 1, true))
  expect.truthy(text:find('"zone":null', 1, true))
  local hb = json.decode(text)
  expect.equal(hb.character, nil)
  expect.equal(hb.zone, nil)
end)

test('a character or zone with a byte 0x80 or above is written as _base64, exactly one of the two (item 16)', function()
  local fs = fake_fs()
  store.new(fs, DIR):publish_heartbeat({ character = 'J\195\184rg', zone = 'plain', now = 5 })
  local hb = json.decode(heartbeat_text(fs))
  expect.equal(hb.character, nil)
  expect.equal(hb.character_base64, 'SsO4cmc=')   -- base64 of the five bytes 4A C3 B8 72 67, worked out by hand
  expect.equal(hb.zone, 'plain')
  expect.equal(hb.zone_base64, nil)
end)

test('a zone with a byte 0x80 or above is written as zone_base64, and character stays plain (item 16)', function()
  local fs = fake_fs()
  store.new(fs, DIR):publish_heartbeat({ character = 'plain', zone = 'caf\195\169', now = 5 })
  local hb = json.decode(heartbeat_text(fs))
  expect.equal(hb.zone, nil)
  expect.equal(hb.zone_base64, 'Y2Fmw6k=')
  expect.equal(hb.character, 'plain')
  expect.equal(hb.character_base64, nil)
end)

test('waiting_for_sequence and unreadable_sequence are present only when given, with their exact digits (criterion 2, item 19)', function()
  local fs = fake_fs()
  local s = store.new(fs, DIR)
  s:publish_heartbeat({ character = 'A', zone = 'b', now = 5 })
  local hb = json.decode(heartbeat_text(fs))
  expect.equal(hb.waiting_for_sequence, nil)
  expect.equal(hb.unreadable_sequence, nil)

  s:publish_heartbeat({ character = 'A', zone = 'b', now = 6, waiting_for_sequence = '1000000' })
  expect.truthy(heartbeat_text(fs):find('"waiting_for_sequence":1000000', 1, true))
  expect.equal(json.decode(heartbeat_text(fs)).unreadable_sequence, nil)

  s:publish_heartbeat({ character = 'A', zone = 'b', now = 7, unreadable_sequence = '123' })
  expect.truthy(heartbeat_text(fs):find('"unreadable_sequence":123', 1, true))
  expect.equal(json.decode(heartbeat_text(fs)).waiting_for_sequence, nil)
end)

test('the two gap fields are independent: both may be present at once (item 19.3)', function()
  local fs = fake_fs()
  store.new(fs, DIR):publish_heartbeat({ character = 'A', zone = 'b', now = 5, waiting_for_sequence = '4', unreadable_sequence = '9' })
  local hb = json.decode(heartbeat_text(fs))
  expect.equal(hb.waiting_for_sequence, 4)
  expect.equal(hb.unreadable_sequence, 9)
end)

test('a sequence field that is not an unpadded decimal string, or a time that is not a whole number, is refused (fail closed)', function()
  local s = store.new(fake_fs(), DIR)
  local function bad(info) return not pcall(s.publish_heartbeat, s, info) end
  expect.truthy(bad({ character = 'A', zone = 'b', now = 5, waiting_for_sequence = '4,"x":1' }))
  expect.truthy(bad({ character = 'A', zone = 'b', now = 5, waiting_for_sequence = 4 }))
  expect.truthy(bad({ character = 'A', zone = 'b', now = 5, unreadable_sequence = '007' }))
  expect.truthy(bad({ character = 'A', zone = 'b', now = 5.5 }))
  expect.truthy(bad({ character = 'A', zone = 'b', now = nil }))
  expect.truthy(bad({ character = 'A', zone = 'b', now = '5' }))
end)

test('the heartbeat is written to a temporary file in the same folder, then replaced onto heartbeat.json, never removed first (item 26.1)', function()
  local fs = fake_fs({ [HEARTBEAT] = '{"old":true}' })
  store.new(fs, DIR):publish_heartbeat({ character = 'A', zone = 'b', now = 5 })
  expect.equal(#fs.ops, 2)
  expect.equal(fs.ops[1].op, 'write')
  expect.equal(fs.ops[2].op, 'replace')
  expect.equal(fs.ops[2].path, fs.ops[1].path)
  expect.equal(fs.ops[2][1], HEARTBEAT)
  expect.truthy(fs.ops[1].path ~= HEARTBEAT)
  expect.equal(fs.ops[1].path:sub(1, #DIR + 1), DIR .. BS)
  expect.falsy(fs.ops[1].path:sub(#DIR + 2):find(BS, 1, true))   -- same folder
  expect.equal(count_ops(fs, 'remove'), 0)
  expect.equal(json.decode(heartbeat_text(fs)).written_at, 5)
  expect.equal(fs.files[fs.ops[1].path], nil)   -- the temporary file is gone
end)

test('a refused replace skips the beat: old heartbeat intact, the failure returned, one attempt only, no retry inside the call (item 26.2)', function()
  local fs = fake_fs({ [HEARTBEAT] = '{"old":true}' })
  fs.held[HEARTBEAT] = true
  local ok, err = store.new(fs, DIR):publish_heartbeat({ character = 'A', zone = 'b', now = 5 })
  expect.equal(ok, nil)
  expect.equal(err, 'MoveFileExA failed: GetLastError 5')
  expect.equal(heartbeat_text(fs), '{"old":true}')
  expect.equal(count_ops(fs, 'replace'), 1)
end)

test('after a skipped beat the next normal update succeeds once the reader lets go, with fresh content (item 26.2)', function()
  local fs = fake_fs({ [HEARTBEAT] = '{"old":true}' })
  local s = store.new(fs, DIR)
  fs.held[HEARTBEAT] = true
  s:publish_heartbeat({ character = 'A', zone = 'b', now = 5 })
  fs.held[HEARTBEAT] = nil
  expect.equal(s:publish_heartbeat({ character = 'A', zone = 'b', now = 6 }), true)
  expect.equal(json.decode(heartbeat_text(fs)).written_at, 6)
end)

test('a failed temporary write leaves the heartbeat untouched and never attempts the replace (criterion 6)', function()
  local fs = fake_fs({ [HEARTBEAT] = '{"old":true}' })
  fs.fail.write = function() return 'No space left on device' end
  local ok, err = store.new(fs, DIR):publish_heartbeat({ character = 'A', zone = 'b', now = 5 })
  expect.equal(ok, nil)
  expect.equal(err, 'No space left on device')
  expect.equal(heartbeat_text(fs), '{"old":true}')
  expect.equal(count_ops(fs, 'replace'), 0)
end)

test('a reader never observes a partial heartbeat: at every operation heartbeat.json is absent or a complete published one (criterion 6)', function()
  local fs = fake_fs()
  local s = store.new(fs, DIR)
  local observed = {}
  fs.observe = function() observed[#observed + 1] = fs.files[HEARTBEAT] end
  for i = 1, 5 do
    s:publish_heartbeat({ character = 'A', zone = 'b', now = 100 + i })
    fs.observe(nil)
  end
  expect.truthy(#observed >= 10)
  for _, text in ipairs(observed) do
    if text ~= nil then
      local hb = json.decode(text)   -- an error here is a partial heartbeat
      expect.equal(hb.state, 'running')
      expect.truthy(hb.written_at >= 101 and hb.written_at <= 105)
    end
  end
end)

-- ---- Events (criterion 7, design items 9 and 10) -------------------------------------------------------------------------

local function lines_of(text)
  local out = {}
  for line in (text or ''):gmatch('([^\n]*)\n') do out[#out + 1] = line end
  return out
end

local function open_store(files)
  local fs = fake_fs(files)
  local s = store.new(fs, DIR)
  expect.equal(s:open_events(), true)
  return s, fs
end

test('on a new file the first event is number 1, and the line has the item 9 envelope exactly (item 9, criterion 7)', function()
  local s, fs = open_store()
  local n = s:append_event(1727612345, 'chat', { { name = 'text', string = 'You have entered The Bazaar.' } })
  expect.equal(n, 1)
  expect.equal(fs.files[EVENTS], '{"n":1,"t":1727612345,"kind":"chat","text":"You have entered The Bazaar."}\n')
end)

test('events are appended in the order given, each on its own line, with increasing numbers (criterion 7)', function()
  local s, fs = open_store()
  s:append_event(10, 'chat', { { name = 'text', string = 'first' } })
  s:append_event(10, 'chat', { { name = 'text', string = 'second' } })
  s:append_event(11, 'chat', { { name = 'text', string = 'third' } })
  local lines = lines_of(fs.files[EVENTS])
  expect.equal(#lines, 3)
  for i, line in ipairs(lines) do
    local e = json.decode(line)
    expect.equal(e.n, i)
    expect.equal(e.text, ({ 'first', 'second', 'third' })[i])
  end
  expect.equal(json.decode(lines[3]).t, 11)
end)

test('text with control bytes stays on one line and decodes back exactly (criterion 7 with criterion 4 rules)', function()
  local s, fs = open_store()
  local text = 'a\nb\r\tc\0d\18e"f\\g'
  s:append_event(1, 'chat', { { name = 'text', string = text } })
  local lines = lines_of(fs.files[EVENTS])
  expect.equal(#lines, 1)
  expect.equal(json.decode(lines[1]).text, text)
end)

test('text with a byte 0x80 or above is written as text_base64 and there is no text field (item 16)', function()
  local s, fs = open_store()
  s:append_event(1, 'chat', { { name = 'text', string = 'caf\195\169' } })
  local e = json.decode(lines_of(fs.files[EVENTS])[1])
  expect.equal(e.text, nil)
  expect.equal(e.text_base64, 'Y2Fmw6k=')
end)

test('a number field is written as its exact digits (bridge-generated events such as request carry a seq) (item 9)', function()
  local s, fs = open_store()
  s:append_event(1, 'request', { { name = 'seq', number = '1000000' }, { name = 'command', string = 'ping' } })
  local line = lines_of(fs.files[EVENTS])[1]
  expect.truthy(line:find('"seq":1000000', 1, true))
  local e = json.decode(line)
  expect.equal(e.kind, 'request')
  expect.equal(e.command, 'ping')
end)

test('a field name or number that could break the line is refused (fail closed)', function()
  local s = open_store()
  expect.falsy((pcall(s.append_event, s, 1, 'chat', { { name = 'te"xt', string = 'x' } })))
  -- a name that would render as a valid first key followed by a second one, `"a":1,"b":"x"`, if it were not checked
  expect.falsy((pcall(s.append_event, s, 1, 'chat', { { name = 'a":1,"b', string = 'x' } })))
  expect.falsy((pcall(s.append_event, s, 1, 'chat', { { name = 'seq', number = '1,"x":2' } })))
  expect.falsy((pcall(s.append_event, s, 1, 'chat', { { name = 'seq', number = 12 } })))
  expect.falsy((pcall(s.append_event, s, 1.5, 'chat', {})))
  expect.falsy((pcall(s.append_event, s, 1, 'ch"at', {})))
  expect.falsy((pcall(s.append_event, s, 1, 5, {})))
end)

-- Second reviewer's findings on the first Step 4 candidate (2026-09-30), from design item 9's envelope
-- `{"n":42,"t":1727612345,"kind":"chat","text":"..."}` and criterion 7 (one event object per line, an event number that can serve
-- as a cursor): the envelope members are the bridge's, and a line must be one unambiguous object. The decoder keeps the last
-- duplicate key (DL-021 evidence note on rxi/json.lua), so a duplicate key would let a caller's field replace an envelope member.

test('a caller field named n, t or kind is refused and nothing is written: the envelope cannot be overridden (item 9)', function()
  for _, name in ipairs({ 'n', 't', 'kind' }) do
    local s, fs = open_store()
    clear_ops(fs)
    expect.falsy((pcall(s.append_event, s, 5, 'chat', { { name = name, string = 'evil' } })), name .. ' as a string field')
    expect.falsy((pcall(s.append_event, s, 5, 'chat', { { name = name, number = '999' } })), name .. ' as a number field')
    expect.equal(count_ops(fs, 'append'), 0)
    expect.equal(s:append_event(6, 'chat', { { name = 'text', string = 'ok' } }), 1)   -- the number was not used up
    local lines = lines_of(fs.files[EVENTS])
    expect.equal(#lines, 1)
    expect.equal(json.decode(lines[1]).n, 1)
    expect.equal(json.decode(lines[1]).kind, 'chat')
  end
end)

test('two fields that end up with the same output name are refused, including after the _base64 rewrite (item 16, criterion 7)', function()
  local s, fs = open_store()
  clear_ops(fs)
  -- the same name twice
  expect.falsy((pcall(s.append_event, s, 5, 'chat', { { name = 'text', string = 'a' }, { name = 'text', string = 'b' } })))
  -- text holding a byte 0x80 or above is written as text_base64, which collides with a supplied text_base64 (either order)
  expect.falsy((pcall(s.append_event, s, 5, 'chat', { { name = 'text', string = 'caf\195\169' }, { name = 'text_base64', string = 'AAAA' } })))
  expect.falsy((pcall(s.append_event, s, 5, 'chat', { { name = 'text_base64', string = 'AAAA' }, { name = 'text', string = 'caf\195\169' } })))
  expect.equal(count_ops(fs, 'append'), 0)
  expect.equal(s:append_event(6, 'chat', { { name = 'text', string = 'ok' } }), 1)
end)

test('fields whose output names differ are accepted, even when they share a stem (no false refusals)', function()
  local s, fs = open_store()
  -- text stays text (plain ASCII), text_base64 is its own name, and a number field has its own name
  expect.equal(s:append_event(5, 'chat', { { name = 'text', string = 'a' }, { name = 'text_base64', string = 'AAAA' }, { name = 'seq', number = '7' } }), 1)
  local e = json.decode(lines_of(fs.files[EVENTS])[1])
  expect.equal(e.text, 'a')
  expect.equal(e.text_base64, 'AAAA')
  expect.equal(e.seq, 7)
end)

test('a last line that lacks the required envelope is not an event: numbering continues from the last complete event (criterion 7, item 9)', function()
  local good = '{"n":5,"t":1,"kind":"chat","text":"a"}\n'
  local bad = {
    '{"n":999}',                                      -- no t, no kind
    '{"n":999,"t":1}',                                -- no kind
    '{"n":999,"kind":"chat"}',                        -- no t
    '{"n":999,"t":1,"kind":5}',                       -- kind not a string
    '{"n":999,"t":1,"kind":"Chat"}',                  -- kind not lower case
    '{"n":999,"t":1,"kind":""}',                      -- kind empty
    '{"n":999,"t":1,"kind":"ch at"}',                 -- kind with a character outside a-z and _
    '{"n":999,"t":"1","kind":"chat"}',                -- t a string
    '{"n":999,"t":1.5,"kind":"chat"}',                -- t not a whole number
    '{"n":"999","t":1,"kind":"chat"}',                -- n a string
    '{"n":999.5,"t":1,"kind":"chat"}',                -- n not a whole number
    '{"n":0,"t":1,"kind":"chat"}',                    -- n not positive
    '{"n":-3,"t":1,"kind":"chat"}',                   -- n not positive
    '{"n":1e20,"t":1,"kind":"chat"}',                 -- n too large to be an exact whole number
    '{"n":999,"t":1e20,"kind":"chat"}',               -- t too large to be a time in seconds
    '123', '"text"', '[1,2]', 'true',                 -- valid JSON, but not an object at all
  }
  for _, line in ipairs(bad) do
    local s = open_store({ [EVENTS] = good .. line .. '\n' })
    expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'b' } }), 6, 'accepted as an event: ' .. line)
  end
end)

test('a complete envelope counts whatever its kind and extra members (bridge-generated kinds too) (item 9)', function()
  local s = open_store({ [EVENTS] = '{"n":5,"t":1,"kind":"chat"}\n{"n":9,"t":2,"kind":"startup_skipped","seq":4,"extra":[1,2]}\n' })
  expect.equal(s:append_event(3, 'bridge_start', {}), 10)
end)

-- Second reviewer's second finding (2026-09-30), criterion 7 and design item 10: event numbers must keep increasing and stay
-- usable as cursors across restarts. The bridge has one finite largest event number (an implementation choice: the largest
-- whole number below 1e15, 999999999999999, which the store writes exactly with %d and the decoder reads back exactly; the
-- store never passes n through json.encode, whose %.14g would round this 15-digit value to 1e+15). It may be written once;
-- after it the bridge fails closed; recovery never falls back to an earlier event to hand a number out again.
local MAX_N = 999999999999999

test('the largest event number may be written once, then appending fails closed: nothing is written and no number is reused (criterion 7)', function()
  local s, fs = open_store({ [EVENTS] = '{"n":999999999999998,"t":1,"kind":"chat"}\n' })
  expect.equal(s:append_event(2, 'chat', {}), MAX_N)
  expect.truthy(fs.files[EVENTS]:find('{"n":999999999999999,"t":2,"kind":"chat"}\n', 1, true))
  local before = fs.files[EVENTS]
  clear_ops(fs)
  local n, err = s:append_event(3, 'chat', {})
  expect.equal(n, nil)
  expect.equal(type(err), 'string')
  expect.truthy(err:find('exhausted', 1, true))
  expect.falsy(err:find('[^\32-\126]'))
  expect.equal(count_ops(fs, 'append'), 0)
  expect.equal(fs.files[EVENTS], before)
  expect.equal((s:append_event(4, 'chat', {})), nil)   -- and it stays refused
  expect.equal(fs.files[EVENTS], before)
end)

test('after the largest number was written, a restart reports exhaustion and is not opened, instead of falling back to an earlier event (criterion 7)', function()
  local s, fs = open_store({ [EVENTS] = '{"n":999999999999998,"t":1,"kind":"chat"}\n' })
  s:append_event(2, 'chat', {})
  local restarted = store.new(fs, DIR)
  local ok, err = restarted:open_events()
  expect.equal(ok, nil)
  expect.equal(type(err), 'string')
  expect.truthy(err:find('exhausted', 1, true))
  expect.falsy(err:find('[^\32-\126]'))
  expect.falsy((pcall(restarted.append_event, restarted, 5, 'chat', {})))   -- not opened, so no append is possible
  expect.equal(#lines_of(fs.files[EVENTS]), 2)
end)

test('a file whose last event already has the largest number is reported as exhausted when opened (criterion 7)', function()
  local text = '{"n":5,"t":1,"kind":"chat"}\n{"n":999999999999999,"t":1,"kind":"chat"}\n'
  local fs = fake_fs({ [EVENTS] = text })
  local s = store.new(fs, DIR)
  local ok, err = s:open_events()
  expect.equal(ok, nil)
  expect.truthy(err:find('exhausted', 1, true))
  expect.equal(fs.files[EVENTS], text)
end)

test('a last line numbered above the largest is not an event and is skipped, as the reader rule says (criterion 7)', function()
  local s = open_store({ [EVENTS] = '{"n":5,"t":1,"kind":"chat"}\n{"n":1000000000000000,"t":1,"kind":"chat"}\n' })
  expect.equal(s:append_event(2, 'chat', {}), 6)
end)

test('the number before the largest still opens and appends normally (no off-by-one at the boundary)', function()
  local s = open_store({ [EVENTS] = '{"n":999999999999997,"t":1,"kind":"chat"}\n' })
  expect.equal(s:append_event(2, 'chat', {}), 999999999999998)
  expect.equal(s:append_event(2, 'chat', {}), MAX_N)
end)

test('an existing file is appended to, not truncated, and numbering continues from its last complete line (design item 10.1)', function()
  local existing = '{"n":41,"t":1,"kind":"chat","text":"a"}\n{"n":42,"t":2,"kind":"chat","text":"b"}\n'
  local s, fs = open_store({ [EVENTS] = existing })
  local n = s:append_event(3, 'chat', { { name = 'text', string = 'c' } })
  expect.equal(n, 43)
  expect.equal(fs.files[EVENTS]:sub(1, #existing), existing)
  expect.equal(json.decode(lines_of(fs.files[EVENTS])[3]).n, 43)
end)

test('a leftover fragment is not a completed event: numbering continues from the last complete line before it (item 10.2, criterion 7)', function()
  local complete = '{"n":7,"t":1,"kind":"chat","text":"a"}\n'
  local s, fs = open_store({ [EVENTS] = complete .. '{"n":8,"t":2,"kind":"ch' })
  local n = s:append_event(3, 'chat', { { name = 'text', string = 'c' } })
  expect.equal(n, 8)
end)

test('a fragment gets a newline first, so the first new event starts on a fresh line and nothing is glued to it (item 10.2)', function()
  local complete = '{"n":7,"t":1,"kind":"chat","text":"a"}\n'
  local fragment = '{"n":8,"t":2,"kind":"ch'
  local s, fs = open_store({ [EVENTS] = complete .. fragment })
  s:append_event(3, 'chat', { { name = 'text', string = 'c' } })
  local lines = lines_of(fs.files[EVENTS] .. '')
  expect.equal(#lines, 3)
  expect.equal(lines[2], fragment)                       -- the fragment stays behind as one malformed line
  expect.equal(json.decode(lines[3]).n, 8)               -- the new event is a whole line of its own
  expect.equal(json.decode(lines[3]).text, 'c')
end)

test('a file holding only a fragment also gets the newline first, and numbering starts at 1 (item 10.2)', function()
  local s, fs = open_store({ [EVENTS] = '{"n":1,"t":1,"ki' })
  expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'a' } }), 1)
  local lines = lines_of(fs.files[EVENTS])
  expect.equal(#lines, 2)
  expect.equal(lines[1], '{"n":1,"t":1,"ki')
  expect.equal(json.decode(lines[2]).text, 'a')
end)

test('a file that ends with a newline gets no extra blank line (item 10.2 applies only to a fragment)', function()
  local s, fs = open_store({ [EVENTS] = '{"n":1,"t":1,"kind":"chat","text":"a"}\n' })
  s:append_event(2, 'chat', { { name = 'text', string = 'b' } })
  expect.equal(#lines_of(fs.files[EVENTS]), 2)
  expect.falsy(fs.files[EVENTS]:find('\n\n', 1, true))
end)

test('a malformed complete line at the end is skipped: numbering continues from the last valid event (criterion 7 reader rule)', function()
  local text = '{"n":5,"t":1,"kind":"chat","text":"a"}\nnot json at all\n{"kind":"chat"}\n'
  local s = open_store({ [EVENTS] = text })
  expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'b' } }), 6)
end)

test('a last line whose n is not a whole number is not an event: numbering continues from the last valid one (criterion 7 reader rule)', function()
  local text = '{"n":5,"t":1,"kind":"chat","text":"a"}\n{"n":5.5,"t":1,"kind":"chat"}\n{"n":0,"t":1,"kind":"chat"}\n{"n":"9","t":1}\n'
  local s = open_store({ [EVENTS] = text })
  expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'b' } }), 6)
end)

test('an empty existing file starts at 1 (item 10.1)', function()
  local s = open_store({ [EVENTS] = '' })
  expect.equal(s:append_event(1, 'chat', { { name = 'text', string = 'a' } }), 1)
end)

test('the last event of a large file is found by reading from the end, not the whole file (item 10 risk note: growth)', function()
  local parts = {}
  for i = 1, 2000 do parts[#parts + 1] = '{"n":' .. i .. ',"t":1,"kind":"chat","text":"' .. string.rep('x', 60) .. '"}\n' end
  local file = table.concat(parts)
  local fs = fake_fs({ [EVENTS] = file })
  local s = store.new(fs, DIR)
  expect.equal(s:open_events(), true)
  expect.equal(s:append_event(1, 'chat', { { name = 'text', string = 'z' } }), 2001)
  local most = 0
  for _, o in ipairs(fs.ops) do
    if o.op == 'read_range' and o[2] > most then most = o[2] end
    expect.falsy(o.op == 'read' and o.path == EVENTS)
  end
  expect.truthy(most > 0 and most < #file / 4)
end)

test('a last event longer than the first read window is still found (item 10.1: reading from the end must not miss a long line)', function()
  local long = '{"n":99,"t":1,"kind":"chat","text":"' .. string.rep('y', 40000) .. '"}\n'
  local s = open_store({ [EVENTS] = '{"n":98,"t":1,"kind":"chat","text":"a"}\n' .. long })
  expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'b' } }), 100)
end)

test('when the events file cannot be inspected, opening fails with the error and nothing is appended (Protocol section 8)', function()
  local fs = fake_fs({ [EVENTS] = '{"n":1,"t":1,"kind":"chat","text":"a"}\n' })
  fs.fail.size = function() return 'Access is denied' end
  local s = store.new(fs, DIR)
  local ok, err = s:open_events()
  expect.equal(ok, nil)
  expect.equal(err, 'Access is denied')
  expect.equal(count_ops(fs, 'append'), 0)
  expect.falsy((pcall(s.append_event, s, 1, 'chat', {})))   -- appending before a successful open is a programming error
end)

test('a failed append returns the error and does not use up the event number (criterion 7: numbers increase without gaps)', function()
  local s, fs = open_store()
  fs.fail.append = function() return 'No space left on device' end
  local n, err = s:append_event(1, 'chat', { { name = 'text', string = 'lost' } })
  expect.equal(n, nil)
  expect.equal(err, 'No space left on device')
  fs.fail.append = nil
  expect.equal(s:append_event(2, 'chat', { { name = 'text', string = 'kept' } }), 1)
end)

test('after a failed append the next append starts with a newline, since the failed one may have left a fragment (item 10.2 applied to a running bridge)', function()
  local s, fs = open_store()
  fs.fail.append = function() return 'disk error' end
  s:append_event(1, 'chat', { { name = 'text', string = 'lost' } })
  fs.fail.append = nil
  fs.files[EVENTS] = '{"n":1,"t":1,"kind":"ch'    -- what an interrupted write might have left
  s:append_event(2, 'chat', { { name = 'text', string = 'kept' } })
  local lines = lines_of(fs.files[EVENTS])
  expect.equal(#lines, 2)
  expect.equal(json.decode(lines[2]).text, 'kept')
end)

-- DL-022 decisions 6 and 9: the loop must tell event-number exhaustion apart from any other events failure, so the store exports the
-- fixed message that both open_events and append_event return at exhaustion.
test('store.EXHAUSTED is the fixed message returned by open_events and by append_event at exhaustion (decisions 6, 9)', function()
  expect.equal(type(store.EXHAUSTED), 'string')
  expect.falsy(store.EXHAUSTED:find('[^\32-\126]'))
  local at_max = store.new(fake_fs({ [EVENTS] = '{"n":999999999999999,"t":1,"kind":"chat"}\n' }), DIR)
  local ok, err = at_max:open_events()
  expect.equal(ok, nil)
  expect.equal(err, store.EXHAUSTED)
  local s = open_store({ [EVENTS] = '{"n":999999999999998,"t":1,"kind":"chat"}\n' })
  expect.equal(s:append_event(2, 'chat', {}), 999999999999999)
  local n, err2 = s:append_event(3, 'chat', {})
  expect.equal(n, nil)
  expect.equal(err2, store.EXHAUSTED)
  -- an ordinary failure is not the exhaustion message
  local s2, fs2 = open_store()
  fs2.fail.append = function() return 'No space left on device' end
  local _, err3 = s2:append_event(1, 'chat', {})
  expect.truthy(err3 ~= store.EXHAUSTED)
end)
