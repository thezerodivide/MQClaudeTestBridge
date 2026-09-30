-- Tests for claudebridge/fsadapter.lua (Step 5 of DL-022, decision 11): the lfs-based file-system adapter for store.lua and the startup folder
-- preparation. It is exercised against test/harness/fake_lfs.lua, which models the lfs, io and os behavior OBSERVED LIVE (DL-022 evidence notes
-- on spikes 11 and 12), not the assumption used in spike 12's dry-run fake.
-- Requirement sources, named per test below:
--   * The store.lua adapter contract (see the header of lua/claudebridge/store.lua): list, size (nil, err, 'not_found' for a missing file), read,
--     read_range, write, append, rename, replace; binary modes; every failure is nil plus an error string and never a raise.
--   * Decision 2 (DL-022): protected use of lfs; lfs.attributes(folder, 'mode') == 'directory' before listing; the iterator state preserved and
--     '.' and '..' skipped; numeric errno 2 translated into the string 'not_found' and never passed through; the startup folders: the ASCII check
--     first, then the bridge root, inbox and outbox, parents first (lfs.mkdir is not recursive), an existing directory accepted, lfs.mkdir only
--     after errno 2 has shown the path absent, an existing non-directory or any other attribute error refused, a directory verified after mkdir,
--     nothing deleted; a failure returns a fixed ASCII reason and stops.
--   * Decision 8: the replace primitive returns true or nil plus GetLastError's number; the adapter formats 'MoveFileExA failed: GetLastError <n>'.
--   * Decision 11 (Claude's flagged implementation choice): list returns only regular files; an entry that vanishes between listing and stat
--     (errno 2) is skipped (the MCP server publishes by renaming a temporary file); any other stat failure is a listing failure.
-- fsadapter.new{ lfs = , io = , os = , replace = } returns a table of functions (no self): list, size, read, read_range, write, append, rename,
-- replace, and prepare(root) -> true, or nil, reason, detail.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local fake_lfs = require 'harness.fake_lfs'
local fsadapter = require 'claudebridge.fsadapter'
local store = require 'claudebridge.store'

local MQ = 'C:\\Users\\Public\\MacroQuest'
local DIR = MQ .. '\\claude'
local INBOX, OUTBOX = DIR .. '\\inbox', DIR .. '\\outbox'

-- An adapter over a fake tree. `replace_result` is what the injected replace primitive returns: { true } or { nil, <number> }.
local function make(initial, replace_result)
  local fake = fake_lfs.new(initial)
  fake.replace_calls = {}
  local function replace(src, dst)
    fake.replace_calls[#fake.replace_calls + 1] = { src, dst }
    if replace_result == 'raise' then error('the primitive raised') end
    local r = replace_result or { true }
    return r[1], r[2]
  end
  local adapter = fsadapter.new({ lfs = fake.lfs, io = fake.io, os = fake.os, replace = replace })
  return adapter, fake
end

local function folders(extra)
  local t = { [MQ] = true, [DIR] = true, [INBOX] = true, [OUTBOX] = true }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function calls_of(fake, fn)
  local out = {}
  for _, c in ipairs(fake.calls) do
    if c.fn == fn then out[#out + 1] = c end
  end
  return out
end

local function printable_ascii(s) return type(s) == 'string' and not s:find('[^\32-\126]') end

-- ---- list (decision 2, decision 11) ----------------------------------------------------------------------------------------------

test('list returns the names of the regular files only: not ".", not "..", not subdirectories (store contract; decision 11)', function()
  local a = make(folders({ [INBOX .. '\\000001.json'] = 'a', [INBOX .. '\\000002.json'] = 'b', [INBOX .. '\\sub'] = true, [INBOX .. '\\notes.txt'] = 'n' }))
  local names = a.list(INBOX)
  table.sort(names)
  expect.equal(names, { '000001.json', '000002.json', 'notes.txt' })
end)

test('list of an empty folder is an empty list, not an error (store contract)', function()
  local a = make(folders())
  expect.equal(a.list(INBOX), {})
end)

test('list refuses a missing folder with an error, although lfs.dir yields nothing for it: zero names is not trusted (decision 2, spike 12 evidence)', function()
  local a, fake = make(folders())
  local names, err = a.list(MQ .. '\\no_such_folder')
  expect.equal(names, nil)
  expect.equal(type(err), 'string')
  expect.equal(#calls_of(fake, 'lfs.dir'), 0)        -- the mode check comes first, so lfs.dir is never called
end)

test('list refuses a path that is a file, although lfs.dir yields nothing for it (decision 2, spike 12 evidence)', function()
  local a, fake = make(folders({ [DIR .. '\\events.jsonl'] = 'x' }))
  local names, err = a.list(DIR .. '\\events.jsonl')
  expect.equal(names, nil)
  expect.truthy(err)
  expect.equal(#calls_of(fake, 'lfs.dir'), 0)
end)

test('list keeps the iterator state that lfs.dir returns: the fake raises if the iterator is called without it (spike 12 evidence)', function()
  local a = make(folders({ [INBOX .. '\\000001.json'] = 'a' }))
  local names, err = a.list(INBOX)
  expect.equal(err, nil)
  expect.equal(names, { '000001.json' })
end)

test('list closes the directory handle it opened (no handle leak at ten polls a second)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'a' }))
  a.list(INBOX)
  a.list(INBOX)
  expect.equal(fake.closed_handles, 2)
end)

test('an entry that vanishes between the listing and the stat (errno 2) is skipped: the MCP server publishes by renaming (decision 11)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'a', [INBOX .. '\\request-abc.tmp'] = 't' }))
  -- the temporary name is renamed away after lfs.dir listed it: its stat then fails with errno 2
  fake.attr_fail[INBOX .. '\\request-abc.tmp'] = { "cannot obtain information from file: No such file or directory", 2 }
  local names, err = a.list(INBOX)
  expect.equal(err, nil)
  expect.equal(names, { '000001.json' })
end)

test('any other stat failure for an entry is a listing failure, not a silently shorter list (decision 11; decision 9: a listing failure is fatal)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'a' }))
  fake.attr_fail[INBOX .. '\\000001.json'] = { 'Permission denied', 13 }
  local names, err = a.list(INBOX)
  expect.equal(names, nil)
  expect.equal(type(err), 'string')
  expect.truthy(err:find('Permission denied', 1, true))
end)

test('a raised lfs error while listing is caught and returned as nil plus an error (store contract: never a raise)', function()
  local a, fake = make(folders())
  fake.dir_raises[INBOX] = true
  local names, err = a.list(INBOX)
  expect.equal(names, nil)
  expect.equal(type(err), 'string')
  expect.truthy(err:find('Access is denied', 1, true))
end)

-- ---- size (store contract; decision 2: errno 2 becomes the string 'not_found') -------------------------------------------------------

test('size of an existing file is its byte count (store contract)', function()
  local a = make(folders({ [INBOX .. '\\000001.json'] = 'twelve bytes' }))
  expect.equal(a.size(INBOX .. '\\000001.json'), 12)
  expect.equal(a.size(INBOX .. '\\000001.json'), 12)
end)

test('size of a missing file returns nil, an error and the STRING not_found: errno 2 is translated, never passed through (decision 2)', function()
  local a = make(folders())
  local size, err, code = a.size(DIR .. '\\events.jsonl')
  expect.equal(size, nil)
  expect.equal(type(err), 'string')
  expect.equal(code, 'not_found')
  expect.equal(type(code), 'string')
end)

test('any other size failure returns nil and the error with no not_found marker, so a file the bridge cannot stat is not taken as a new file (decision 2)', function()
  local a, fake = make(folders({ [DIR .. '\\events.jsonl'] = 'x' }))
  fake.attr_fail[DIR .. '\\events.jsonl'] = { 'Permission denied', 13 }
  local size, err, code = a.size(DIR .. '\\events.jsonl')
  expect.equal(size, nil)
  expect.truthy(err:find('Permission denied', 1, true))
  expect.equal(code, nil)                                     -- neither 'not_found' nor the raw number 13
end)

-- ---- read and read_range (store contract; binary) ---------------------------------------------------------------------------------

test('read returns the exact bytes, including zero and high bytes, and the empty string for an empty file (store contract)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'a\0b\128\255c', [INBOX .. '\\000002.json'] = '' }))
  expect.equal(a.read(INBOX .. '\\000001.json'), 'a\0b\128\255c')
  expect.equal(a.read(INBOX .. '\\000002.json'), '')
  for _, c in ipairs(calls_of(fake, 'io.open')) do expect.equal(c.extra, 'rb') end   -- binary mode only
end)

test('read of a missing file returns nil and an error (store contract)', function()
  local a = make(folders())
  local data, err = a.read(INBOX .. '\\000009.json')
  expect.equal(data, nil)
  expect.equal(type(err), 'string')
end)

test('read_range returns the bytes at the offset, a short result at the end of the file, and the empty string beyond it (store contract: reading from the end)', function()
  local a = make(folders({ [DIR .. '\\events.jsonl'] = '0123456789' }))
  expect.equal(a.read_range(DIR .. '\\events.jsonl', 0, 4), '0123')
  expect.equal(a.read_range(DIR .. '\\events.jsonl', 6, 100), '6789')
  expect.equal(a.read_range(DIR .. '\\events.jsonl', 10, 4), '')
  expect.equal(a.read_range(DIR .. '\\events.jsonl', 50, 4), '')
  expect.equal(a.read_range(DIR .. '\\events.jsonl', 3, 0), '')
end)

test('read_range of a missing file returns nil and an error (store contract)', function()
  local a = make(folders())
  local data, err = a.read_range(DIR .. '\\events.jsonl', 0, 4)
  expect.equal(data, nil)
  expect.equal(type(err), 'string')
end)

-- ---- write, append, rename, replace (store contract; decision 8) ----------------------------------------------------------------

test('write creates or truncates the file with the exact bytes, in binary mode (store contract)', function()
  local a, fake = make(folders({ [OUTBOX .. '\\000001.json.tmp'] = 'old and longer content' }))
  expect.equal(a.write(OUTBOX .. '\\000001.json.tmp', 'new\0\255'), true)
  expect.equal(fake.tree[OUTBOX .. '\\000001.json.tmp'].data, 'new\0\255')
  for _, c in ipairs(calls_of(fake, 'io.open')) do expect.equal(c.extra, 'wb') end
end)

test('write reports a failure to open, to write and to close as nil plus an error, never a raise (store contract)', function()
  local a, fake = make(folders())
  fake.open_fail[OUTBOX .. '\\a.tmp'] = 'Permission denied'
  local ok, err = a.write(OUTBOX .. '\\a.tmp', 'x')
  expect.equal(ok, nil)
  expect.equal(err, 'Permission denied')
  fake.write_fail[OUTBOX .. '\\b.tmp'] = 'No space left on device'
  local ok2, err2 = a.write(OUTBOX .. '\\b.tmp', 'x')
  expect.equal(ok2, nil)
  expect.equal(err2, 'No space left on device')
  fake.close_fail[OUTBOX .. '\\c.tmp'] = 'Disk error on close'
  local ok3, err3 = a.write(OUTBOX .. '\\c.tmp', 'x')
  expect.equal(ok3, nil)
  expect.equal(err3, 'Disk error on close')
end)

test('append adds to the end, creates a missing file, and uses the binary append mode (store contract)', function()
  local a, fake = make(folders({ [DIR .. '\\events.jsonl'] = 'one\n' }))
  expect.equal(a.append(DIR .. '\\events.jsonl', 'two\n'), true)
  expect.equal(fake.tree[DIR .. '\\events.jsonl'].data, 'one\ntwo\n')
  expect.equal(a.append(DIR .. '\\new.jsonl', 'x'), true)
  expect.equal(fake.tree[DIR .. '\\new.jsonl'].data, 'x')
  for _, c in ipairs(calls_of(fake, 'io.open')) do expect.equal(c.extra, 'ab') end
end)

test('append reports a failure as nil plus an error (store contract; decision 6: the loop stops on it)', function()
  local a, fake = make(folders())
  fake.write_fail[DIR .. '\\events.jsonl'] = 'No space left on device'
  local ok, err = a.append(DIR .. '\\events.jsonl', 'x')
  expect.equal(ok, nil)
  expect.equal(err, 'No space left on device')
end)

test('rename moves a file to a new name, and fails without changing anything when the destination exists (store contract; spike 8 b2)', function()
  local a, fake = make(folders({ [OUTBOX .. '\\000001.json.tmp'] = 'reply' }))
  expect.equal(a.rename(OUTBOX .. '\\000001.json.tmp', OUTBOX .. '\\000001.json'), true)
  expect.equal(fake.tree[OUTBOX .. '\\000001.json'].data, 'reply')
  expect.equal(fake.tree[OUTBOX .. '\\000001.json.tmp'], nil)
  fake.tree[OUTBOX .. '\\000002.json.tmp'] = { kind = 'file', data = 'second' }
  fake.tree[OUTBOX .. '\\000002.json'] = { kind = 'file', data = 'first' }
  local ok, err = a.rename(OUTBOX .. '\\000002.json.tmp', OUTBOX .. '\\000002.json')
  expect.equal(ok, nil)
  expect.equal(type(err), 'string')
  expect.equal(fake.tree[OUTBOX .. '\\000002.json'].data, 'first')
end)

test('replace calls the injected primitive with the two paths and returns true on success (decision 8)', function()
  local a, fake = make(folders(), { true })
  expect.equal(a.replace(DIR .. '\\heartbeat.json.tmp', DIR .. '\\heartbeat.json'), true)
  expect.equal(fake.replace_calls, { { DIR .. '\\heartbeat.json.tmp', DIR .. '\\heartbeat.json' } })
end)

test('a failed replace becomes nil plus the fixed string MoveFileExA failed: GetLastError <n>, with the number formatted as an integer (decision 8)', function()
  local a = make(folders(), { nil, 5 })
  local ok, err = a.replace('a', 'b')
  expect.equal(ok, nil)
  expect.equal(err, 'MoveFileExA failed: GetLastError 5')
  local a2 = make(folders(), { nil, 32 })
  expect.equal(select(2, a2.replace('a', 'b')), 'MoveFileExA failed: GetLastError 32')
end)

test('a raised or malformed replace result is still nil plus a fixed ASCII error, never a raise and never a mistaken success (decision 8, store contract)', function()
  local a = make(folders(), 'raise')
  local ok, err = a.replace('a', 'b')
  expect.equal(ok, nil)
  expect.equal(err, 'MoveFileExA failed: the replace primitive raised an error')
  local a2 = make(folders(), { nil, nil })                       -- a failure without a number
  local ok2, err2 = a2.replace('a', 'b')
  expect.equal(ok2, nil)
  expect.equal(err2, 'MoveFileExA failed: GetLastError unknown')
  expect.truthy(printable_ascii(err) and printable_ascii(err2))
end)

-- ---- prepare: the startup folders (decision 2) -----------------------------------------------------------------------------------

test('prepare creates the bridge root, then inbox, then outbox, each verified afterwards, when all are absent (decision 2: parents first)', function()
  local a, fake = make({ [MQ] = true })
  expect.equal(a.prepare(DIR), true)
  local made = {}
  for _, c in ipairs(calls_of(fake, 'lfs.mkdir')) do made[#made + 1] = c.path end
  expect.equal(made, { DIR, INBOX, OUTBOX })
  expect.equal(fake.tree[DIR].kind, 'directory')
  expect.equal(fake.tree[INBOX].kind, 'directory')
  expect.equal(fake.tree[OUTBOX].kind, 'directory')
  -- every creation is followed by a check of the path
  local last
  for i, c in ipairs(fake.calls) do
    if c.fn == 'lfs.mkdir' then
      local next_call = fake.calls[i + 1]
      expect.truthy(next_call and next_call.fn == 'lfs.attributes' and next_call.path == c.path)
    end
  end
end)

test('prepare accepts folders that already exist and calls mkdir for none of them (decision 2)', function()
  local a, fake = make(folders())
  expect.equal(a.prepare(DIR), true)
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 0)
end)

test('prepare creates only what is missing, and still in order: an existing root with no inbox or outbox (decision 2)', function()
  local a, fake = make({ [MQ] = true, [DIR] = true })
  expect.equal(a.prepare(DIR), true)
  local made = {}
  for _, c in ipairs(calls_of(fake, 'lfs.mkdir')) do made[#made + 1] = c.path end
  expect.equal(made, { INBOX, OUTBOX })
end)

test('prepare refuses a path that exists as a file, with a fixed reason, and goes no further (decision 2)', function()
  local a, fake = make({ [MQ] = true, [DIR] = true, [INBOX] = 'a file where a folder should be' })
  local ok, reason, detail = a.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'the inbox folder path exists but is not a directory')
  expect.truthy(printable_ascii(reason))
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 0)
  expect.equal(fake.tree[OUTBOX], nil)                        -- stopped: outbox was never considered
end)

test('prepare refuses on any attribute error other than errno 2 and never calls mkdir after one (decision 2: mkdir only after errno 2)', function()
  local a, fake = make({ [MQ] = true })
  fake.attr_fail[DIR] = { 'Access is denied', 5 }
  local ok, reason, detail = a.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not examine the bridge folder')
  expect.truthy(detail:find('Access is denied', 1, true))
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 0)
end)

test('prepare refuses when mkdir fails, carrying the error, and does not try the later folders (decision 2)', function()
  local a, fake = make({ [MQ] = true })
  fake.mkdir_result[DIR] = { nil, 'Permission denied', 13 }
  local ok, reason, detail = a.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not create the bridge folder')
  expect.truthy(detail:find('Permission denied', 1, true))
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 1)
end)

test('prepare refuses when mkdir reports success but no directory is there afterwards (decision 2: verify after a successful mkdir)', function()
  local a, fake = make({ [MQ] = true, [DIR] = true })
  fake.mkdir_result[INBOX] = { true }                          -- reports success and creates nothing
  local ok, reason = a.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'the inbox folder was not created')
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 1)
end)

test('prepare refuses a missing parent: lfs.mkdir is not recursive, and the bridge folder sits directly under the MacroQuest root (decision 2, spike 12 evidence)', function()
  local a, fake = make({})                                     -- not even the MacroQuest root exists
  local ok, reason, detail = a.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not create the bridge folder')
  expect.truthy(detail:find('No such file or directory', 1, true))
  expect.equal(#calls_of(fake, 'lfs.mkdir'), 1)
end)

test('the ASCII check comes first: a non-ASCII bridge path is refused before any lfs call (decision 2)', function()
  local a, fake = make({ [MQ] = true })
  local ok, reason = a.prepare('C:\\Users\\Zq\195\184Zq\\MacroQuest\\claude')
  expect.equal(ok, nil)
  expect.equal(reason, select(2, store.check_bridge_dir('C:\\Users\\Zq\195\184Zq\\x')))
  expect.truthy(printable_ascii(reason))
  expect.equal(#fake.calls, 0)
end)

test('prepare never deletes anything: no rmdir and no os.remove, on success and on every refusal (decision 2)', function()
  -- the fake raises if rmdir or os.remove is called, so any call would fail these runs
  local scenarios = {
    function() return make({ [MQ] = true }) end,
    function() return make(folders()) end,
    function() local a, f = make({ [MQ] = true, [DIR] = true, [INBOX] = 'file' }); return a, f end,
    function() local a, f = make({ [MQ] = true }); f.mkdir_result[DIR] = { nil, 'x', 13 }; return a, f end,
  }
  for _, build in ipairs(scenarios) do
    local a, fake = build()
    expect.equal((pcall(a.prepare, DIR)), true)
    expect.equal(#calls_of(fake, 'lfs.rmdir'), 0)
    expect.equal(#calls_of(fake, 'os.remove'), 0)
  end
end)

-- ---- The adapter satisfies the store contract (integration over the fakes) ----------------------------------------------------------

test('store.lua runs over the adapter: a request is read, a reply published, events appended and recovered, the heartbeat replaced (decision 11)', function()
  local a, fake = make({ [MQ] = true }, { true })
  expect.equal(a.prepare(DIR), true)
  fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"ping"}' }
  local st = store.new(a, DIR)
  expect.equal(st:list_requests(), { '000001.json' })
  expect.equal(st:read_request('000001.json'), { status = 'ok', text = '{"command":"ping"}' })
  expect.equal(st:write_reply('1', '{"seq":1,"ok":true}'), true)
  expect.equal(fake.tree[OUTBOX .. '\\000001.json'].data, '{"seq":1,"ok":true}')
  expect.equal(st:list_replies(), { '000001.json' })
  expect.equal(st:open_events(), true)                                   -- a missing events file is a new file: size's not_found
  expect.equal(st:append_event(100, 'chat', { { name = 'text', string = 'hello' } }), 1)
  local st2 = store.new(a, DIR)
  expect.equal(st2:open_events(), true)                                  -- numbering recovered by reading from the end
  expect.equal(st2:append_event(101, 'chat', {}), 2)
  expect.equal(st:publish_heartbeat({ character = 'A', zone = 'b', now = 100 }), true)
  expect.equal(#fake.replace_calls, 1)
  expect.equal(st:read_request('000009.json').status, 'unreadable')      -- a missing request file is unreadable, not empty
end)

-- ---- Every call into lfs, io and os is protected (store contract: nil plus an error, never a raise) -------------------------------

test('a raised error from any lfs, io or os call comes back as nil plus an error string, never as a raise (store contract)', function()
  local function boom() error('boom from the library') end
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'x' }), { true })
  fake.lfs.attributes, fake.lfs.dir, fake.lfs.mkdir = boom, boom, boom
  fake.io.open = boom
  fake.os.rename = boom
  local function no_raise(fn, ...)
    local ok, r1, r2 = pcall(fn, ...)
    expect.equal(ok, true)
    return r1, r2
  end
  local function check(fn, ...)
    local r, err = no_raise(fn, ...)
    expect.equal(r, nil)
    expect.truthy(tostring(err):find('boom from the library', 1, true))
  end
  check(a.list, INBOX)
  check(a.size, INBOX .. '\\000001.json')
  check(a.read, INBOX .. '\\000001.json')
  check(a.read_range, INBOX .. '\\000001.json', 0, 4)
  check(a.write, OUTBOX .. '\\x.tmp', 'x')
  check(a.append, DIR .. '\\events.jsonl', 'x')
  check(a.rename, 'a', 'b')
  expect.equal((no_raise(a.prepare, DIR)), nil)
  -- when only mkdir raises (attributes work), prepare reports it with the detail
  local a2, fake2 = make({ [MQ] = true })
  fake2.lfs.mkdir = boom
  local ok, reason, detail = a2.prepare(DIR)
  expect.equal(ok, nil)
  expect.equal(reason, 'could not create the bridge folder')
  expect.truthy(detail:find('boom from the library', 1, true))
  -- file-object methods that raise: read, seek, write, close
  local a3, fake3 = make(folders({ [INBOX .. '\\000002.json'] = 'abc' }))
  local real_open = fake3.io.open
  fake3.io.open = function(path, mode)
    local f = real_open(path, mode)
    if f then f.read, f.seek, f.write, f.close = boom, boom, boom, boom end
    return f
  end
  check(a3.read, INBOX .. '\\000002.json')
  check(a3.read_range, INBOX .. '\\000002.json', 0, 2)
  check(a3.write, OUTBOX .. '\\y.tmp', 'y')
  check(a3.append, DIR .. '\\events.jsonl', 'y')
end)

-- ---- Gaps found by the mutation check (DL-022 addendum, 2026-09-30) ----------------------------------------------------------------

test('list does not stat the "." and ".." entries: they are skipped by name, not by the stat result (decision 2)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'a' }))
  a.list(INBOX)
  for _, c in ipairs(calls_of(fake, 'lfs.attributes')) do
    expect.falsy(c.path:find('\\.$'))
    expect.falsy(c.path:find('\\..$'))
  end
end)

test('a read error is an error, not an empty file: read and read_range return nil plus the error when the library reports one (store contract)', function()
  local a, fake = make(folders({ [INBOX .. '\\000001.json'] = 'abc' }))
  local real_open = fake.io.open
  fake.io.open = function(path, mode)
    local f = real_open(path, mode)
    if f then f.read = function() return nil, 'Input/output error' end end
    return f
  end
  local data, err = a.read(INBOX .. '\\000001.json')
  expect.equal(data, nil)
  expect.equal(err, 'Input/output error')
  local data2, err2 = a.read_range(INBOX .. '\\000001.json', 0, 2)
  expect.equal(data2, nil)
  expect.equal(err2, 'Input/output error')
end)

test('a replace code that is not a whole number, or is not a number at all, is reported as unknown, never formatted as a code (decision 8)', function()
  local a = make(folders(), { nil, 5.5 })
  expect.equal(select(2, a.replace('a', 'b')), 'MoveFileExA failed: GetLastError unknown')
  local a2 = make(folders(), { nil, '5' })
  expect.equal(select(2, a2.replace('a', 'b')), 'MoveFileExA failed: GetLastError unknown')
  local a3 = make(folders(), { false, 5 })                      -- a false result with a code is still a failure with that code
  expect.equal(select(2, a3.replace('a', 'b')), 'MoveFileExA failed: GetLastError 5')
end)
