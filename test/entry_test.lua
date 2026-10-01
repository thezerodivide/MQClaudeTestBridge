-- Tests for lua/claudebridge.lua, the entry script (Step 5 of DL-022; decisions 13 to 17, with decisions 6, 7 (Revision 4), 8 and 9, design items 9 and 21).
-- EVIDENCE LABEL: local tests with fakes. The REAL entry-script text is loaded with a synthetic '@claudebridge-<version>.lua' chunk name (decision 13,
-- option C) and run with its globals replaced: a fake `mq`, `ffi`, `lfs`, `io` and `os`, and a TRIPWIRE fake of claudebridge.winreplace. The real
-- winreplace.lua is never loaded or executed here (tested separately, decision 12); the pure modules (version, store, queue, core, loop, fsadapter, json)
-- are the real ones. These tests show the script's wiring and ordering against the defined interfaces. They do NOT show what real MacroQuest does:
-- whether it feeds the bridge's own print back to its listener, whether it queues lines before the first doevents, what `Me()` returns at character
-- select, and what `${MacroQuest.Path[root]}` looks like are Step 8 live evidence. The stop sentinel lives in this file only; the script has no test branch.
-- Requirement sources: decision 13 (startup order: ffi, the Windows x86 gate, winreplace, lfs, identity check, root, adapter, prepare as the first write,
-- then store, loop and start); decision 14 (the catch-all listener is registered once, immediately before loop:start); decision 15 (the loop and its
-- 100 ms delay, and the failure checks); decision 16 (the console contract); decision 17 (the env adapter); decision 7 Revision 4 (two clock readings per poll).
local T = require 'harness.t'
local test, expect = T.test, T.expect
local fs = require 'harness.fs'
local fake_lfs = require 'harness.fake_lfs'
local version = require 'claudebridge.version'

local ENTRY_TEXT = assert(fs.read_all(T.root .. '/lua/claudebridge.lua'), 'lua/claudebridge.lua is missing')

local ROOT = 'C:\\MQ'
local DIR = ROOT .. '\\claude'
local INBOX, OUTBOX = DIR .. '\\inbox', DIR .. '\\outbox'
local EVENTS, HEARTBEAT = DIR .. '\\events.jsonl', DIR .. '\\heartbeat.json'
local PREFIX = 'claudebridge refused to start: '
local STOPPED = 'claudebridge stopped: '
local START_LINE = 'claudebridge ' .. version.VERSION .. ' started'
local STOP = {}                      -- raised by the fake mq.delay to end the run; never part of the script

local function pick(opts, key, nilkey, default)
  if opts[nilkey] then return nil end
  if opts[key] ~= nil then return opts[key] end
  return default
end

-- Runs the real entry-script text once under the fakes. Returns a context with the recorded calls, prints and counts.
local function run_entry(opts)
  opts = opts or {}
  local fake = fake_lfs.new(opts.tree or { [ROOT] = true })
  local ctx = { fake = fake, prints = {}, requires = {}, delays = {}, ms = 0, now = opts.now or 5000,
                counts = { doevents = 0, delay = 0, gettime = 0, os_time = 0, winreplace_loads = 0, winreplace_calls = 0, event_regs = 0 } }
  local function note(fn, path, extra) fake.calls[#fake.calls + 1] = { fn = fn, path = path, extra = extra } end

  local character = pick(opts, 'character', 'character_nil', 'Bob')
  local zone = pick(opts, 'zone', 'zone_nil', 'bazaar')
  local function value(v) if type(v) == 'function' then return v() end return v end

  local me_proxy = setmetatable({}, {
    __call = function() note('mq.TLO.Me()'); if opts.me_unavailable then return nil end return 'Me' end,
    __index = function(_, k)
      if k == 'CleanName' then return function() note('Me.CleanName'); return value(character) end end
    end,
  })
  local mq = {
    TLO = { Me = me_proxy, Zone = { ShortName = function() note('Zone.ShortName'); return value(zone) end } },
    parse = function(expr)
      note('mq.parse', expr)
      if expr == '${MacroQuest.Path[root]}' then return opts.root ~= nil and opts.root or ROOT end
      if opts.parse then return opts.parse(expr) end
      return 'parsed<' .. expr .. '>'
    end,
    event = function(name, pattern, cb)
      ctx.counts.event_regs = ctx.counts.event_regs + 1
      ctx.listener, ctx.event_name, ctx.event_pattern = cb, name, pattern
      note('mq.event', name, pattern)
    end,
    doevents = function()
      ctx.counts.doevents = ctx.counts.doevents + 1
      note('mq.doevents')
      if opts.on_doevents then opts.on_doevents(ctx, ctx.counts.doevents) end
    end,
    delay = function(ms)
      ctx.counts.delay = ctx.counts.delay + 1
      ctx.delays[#ctx.delays + 1] = ms
      note('mq.delay', nil, ms)
      ctx.ms = ctx.ms + ms
      if opts.on_delay then opts.on_delay(ctx, ctx.counts.delay) end
      if ctx.counts.delay >= (opts.max_delays or 3) then error(STOP, 0) end
    end,
    gettime = function() ctx.counts.gettime = ctx.counts.gettime + 1; return ctx.ms end,
  }
  local winreplace = { replace = function(src, dst)
    ctx.counts.winreplace_calls = ctx.counts.winreplace_calls + 1
    note('winreplace.replace', src, dst)
    if not fake.tree[src] then return nil, 2 end
    fake.tree[dst], fake.tree[src] = fake.tree[src], nil
    return true
  end }

  local function fake_require(name)
    ctx.requires[#ctx.requires + 1] = name
    note('require', name)
    if name == 'mq' then return mq end
    if name == 'ffi' then
      if opts.ffi_missing then error("module 'ffi' not found", 0) end
      return opts.ffi or { os = 'Windows', arch = 'x86' }
    end
    if name == 'lfs' then
      if opts.lfs_missing then error("module 'lfs' not found", 0) end
      return fake.lfs
    end
    if name == 'claudebridge.winreplace' then
      ctx.counts.winreplace_loads = ctx.counts.winreplace_loads + 1
      if opts.winreplace_raises then error('the replace module failed to load', 0) end
      if opts.winreplace_value ~= nil then return opts.winreplace_value end
      return winreplace
    end
    if name == opts.module_fails then error('simulated failure to load ' .. name, 0) end
    return require(name)
  end

  local fake_os = { time = function() ctx.counts.os_time = ctx.counts.os_time + 1; return ctx.now end, rename = fake.os.rename, remove = fake.os.remove }
  local env = setmetatable({
    require = fake_require,
    print = function(...)
      local parts = {}
      for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
      ctx.prints[#ctx.prints + 1] = table.concat(parts, '\t')
      note('print')
    end,
    io = fake.io,
    os = fake_os,
  }, { __index = _G })

  local chunk = assert(loadstring(ENTRY_TEXT, opts.chunkname or ('@claudebridge-' .. version.VERSION .. '.lua')))
  setfenv(chunk, env)
  function ctx.hear(line) return ctx.listener(line) end
  local ok, err = pcall(chunk)
  ctx.ok, ctx.err = ok, err
  ctx.stopped = (not ok) and err == STOP
  ctx.crashed = (not ok) and err ~= STOP and tostring(err) or nil
  return ctx
end

local function index_of(ctx, pred)
  for i, c in ipairs(ctx.fake.calls) do if pred(c, i) then return i end end
  return nil
end
local function last_index_of(ctx, pred)
  local found
  for i, c in ipairs(ctx.fake.calls) do if pred(c, i) then found = i end end
  return found
end
local function is_write(c) return (c.fn == 'io.open' and (c.extra == 'wb' or c.extra == 'ab')) or c.fn == 'winreplace.replace' or c.fn == 'os.rename' end
local function no_writes(ctx)
  expect.equal(index_of(ctx, function(c) return c.fn == 'lfs.mkdir' or is_write(c) end), nil)
end
local function printable_line(s) return type(s) == 'string' and not s:find('[^\32-\126]') end

-- Decision 16: exactly one refusal line, the fixed prefix, printable ASCII on one line, and nothing else printed.
local function single_refusal(ctx)
  expect.equal(#ctx.prints, 1)
  local line = ctx.prints[1]
  expect.equal(line:sub(1, #PREFIX), PREFIX)
  expect.truthy(printable_line(line), 'not printable ASCII: ' .. line)
  expect.equal(ctx.ok, true)                    -- the script returned; it did not crash and did not reach the loop
  expect.equal(ctx.counts.doevents, 0)
  expect.equal(ctx.counts.delay, 0)
  return line
end

local function starts_with(s, prefix) return type(s) == 'string' and s:sub(1, #prefix) == prefix end

local function file_data(ctx, path) local e = ctx.fake.tree[path]; return e and e.data end

-- ---- The normal path (decisions 13 to 16) --------------------------------------------------------------------------

test('startup on simulated Windows x86 requests the fake winreplace exactly once, creates the three folders, writes bridge_start and the first heartbeat, and prints only the start line (decisions 8, 13, 16)', function()
  local ctx = run_entry()
  expect.equal(ctx.stopped, true)
  expect.equal(ctx.counts.winreplace_loads, 1)
  for _, d in ipairs({ DIR, INBOX, OUTBOX }) do expect.equal(ctx.fake.tree[d] and ctx.fake.tree[d].kind, 'directory') end
  T.assert_contains(file_data(ctx, EVENTS), '"kind":"bridge_start"')
  local hb = file_data(ctx, HEARTBEAT)
  T.assert_contains(hb, '"state":"running"')
  T.assert_contains(hb, '"character":"Bob"')
  T.assert_contains(hb, '"zone":"bazaar"')
  expect.equal(ctx.prints, { START_LINE })
end)

test('the gates and the module loads come first and in order, before any folder is created: ffi, then winreplace, then lfs, then the folder preparation (decisions 8 and 13)', function()
  local ctx = run_entry()
  local function req(name) return index_of(ctx, function(c) return c.fn == 'require' and c.path == name end) end
  local first_mkdir = index_of(ctx, function(c) return c.fn == 'lfs.mkdir' end)
  expect.truthy(req('ffi') < req('claudebridge.winreplace'))
  expect.truthy(req('claudebridge.winreplace') < req('lfs'))
  expect.truthy(req('lfs') < first_mkdir)
  expect.truthy(index_of(ctx, function(c) return c.fn == 'mq.parse' and c.path == '${MacroQuest.Path[root]}' end) < first_mkdir)
end)

test('the start line is printed once, after startup succeeded (after the first heartbeat) and before the loop begins (decision 16)', function()
  local ctx = run_entry()
  local printed = index_of(ctx, function(c) return c.fn == 'print' end)
  expect.truthy(printed > index_of(ctx, function(c) return c.fn == 'winreplace.replace' end))
  expect.truthy(printed < index_of(ctx, function(c) return c.fn == 'mq.doevents' end))
  expect.equal(ctx.prints, { START_LINE })
end)

-- ---- Refusals before any write (decisions 8 and 13) ------------------------------------------------------------------

test('a missing ffi library refuses once, saying ffi is not available, and nothing else happens (decision 8)', function()
  local ctx = run_entry({ ffi_missing = true })
  local line = single_refusal(ctx)
  T.assert_contains(line, 'ffi is not available')
  T.assert_contains(line, "module 'ffi' not found")           -- the cause travels with the refusal (decision 16)
  expect.equal(ctx.counts.winreplace_loads, 0)
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

for _, case in ipairs({
  { 'Windows x64', { os = 'Windows', arch = 'x64' }, '[x64]' },
  { 'Windows arm64', { os = 'Windows', arch = 'arm64' }, '[arm64]' },
  { 'Windows with no arch', { os = 'Windows' }, '[nil]' },
  { 'Linux x86', { os = 'Linux', arch = 'x86' }, '[Linux]' },
  { 'no os', { arch = 'x86' }, '[nil]' },
  { 'OSX x64', { os = 'OSX', arch = 'x64' }, '[OSX]' },
}) do
  test('an unsupported environment (' .. case[1] .. ') refuses once, naming the wrong value and the supported environment, and never requests winreplace or lfs (decisions 8 and 13)', function()
    local ctx = run_entry({ ffi = case[2] })
    local line = single_refusal(ctx)
    T.assert_contains(line, case[3])
    T.assert_contains(line, 'Windows x86')
    expect.equal(ctx.counts.winreplace_loads, 0)
    expect.equal(index_of(ctx, function(c) return c.fn == 'require' and c.path == 'lfs' end), nil)
    expect.equal(ctx.counts.event_regs, 0)
    no_writes(ctx)
  end)
end

test('an observed environment value is escaped in the refusal: control bytes and high bytes become \\xNN, backslash and percent stay as they are (decision 16)', function()
  local ctx = run_entry({ ffi = { os = 'a\\b%c\n\255', arch = 'x86' } })
  local line = single_refusal(ctx)
  T.assert_contains(line, '[a\\b%c\\x0a\\xff]')
  local ctx2 = run_entry({ ffi = { os = 'Windows', arch = 'a\\b%c\n\255' } })
  T.assert_contains(single_refusal(ctx2), '[a\\b%c\\x0a\\xff]')
end)

test('a winreplace module that cannot load refuses once with the cause and writes nothing (decisions 8 and 13; design item 26.4)', function()
  local ctx = run_entry({ winreplace_raises = true })
  local line = single_refusal(ctx)
  T.assert_contains(line, 'replace module could not be loaded')
  T.assert_contains(line, 'the replace module failed to load')
  expect.equal(ctx.counts.winreplace_loads, 1)
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

test('a winreplace module that loads but provides no replace function refuses once and writes nothing (decisions 8 and 13)', function()
  local ctx = run_entry({ winreplace_value = {} })
  local line = single_refusal(ctx)
  T.assert_contains(line, 'does not provide replace')
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

for _, name in ipairs({ 'claudebridge.version', 'claudebridge.fsadapter', 'claudebridge.store', 'claudebridge.loop' }) do
  test('a bridge module that cannot be loaded (' .. name .. ') refuses once with the cause and writes nothing (decision 16)', function()
    local ctx = run_entry({ module_fails = name })
    local line = single_refusal(ctx)
    T.assert_contains(line, 'a bridge module could not be loaded')
    T.assert_contains(line, 'simulated failure to load ' .. name)
    expect.equal(ctx.counts.event_regs, 0)
    no_writes(ctx)
  end)
end

test('a missing lfs library refuses once and writes nothing (decision 13)', function()
  local ctx = run_entry({ lfs_missing = true })
  local line = single_refusal(ctx)
  T.assert_contains(line, 'lfs library could not be loaded')
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

test('an identity mismatch (a versioned file name for another version) prints the identity message once, as it is, and writes nothing (decisions 13 and 16; design item 21)', function()
  local ctx = run_entry({ chunkname = '@claudebridge-9.9.9.lua' })
  local line = single_refusal(ctx)
  local ok, expected = version.check_identity('@claudebridge-9.9.9.lua', version.VERSION)
  expect.equal(ok, false)
  expect.equal(line, expected)
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

test('the plain claudebridge.lua name with test-build modules refuses once and writes nothing (design item 21)', function()
  local ctx = run_entry({ chunkname = '@claudebridge.lua' })
  single_refusal(ctx)
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

for _, case in ipairs({
  { 'NULL', 'NULL' }, { 'an empty string', '' }, { 'a relative path', '.' }, { 'a path with no separator', 'C:' },
}) do
  test('a MacroQuest root that is not an absolute path (' .. case[1] .. ') refuses once and creates nothing, so no folder can land relative to an unknown directory (decision 13, step 6)', function()
    local ctx = run_entry({ root = case[2] })
    local line = single_refusal(ctx)
    T.assert_contains(line, 'MacroQuest root folder could not be determined')
    T.assert_contains(line, '(' .. case[2] .. ')')            -- the observed value is shown, escaped (decision 16)
    expect.equal(ctx.counts.event_regs, 0)
    no_writes(ctx)
  end)
end

test('a root that is not ASCII is refused by the folder preparation with its fixed reason and no detail, and creates nothing (design items 7 and 20)', function()
  local ctx = run_entry({ root = 'C:\\M\255Q' })
  local line = single_refusal(ctx)
  expect.equal(line, PREFIX .. 'bridge folder path has a byte above 0x7F (non-ASCII); the bridge needs an ASCII folder path')
  expect.equal(ctx.counts.event_regs, 0)
  no_writes(ctx)
end)

-- ---- Folder preparation failure, with the hostile detail (decision 16) ------------------------------------------------

local function run_with_mkdir_failure()
  -- fake_lfs hook: lfs.mkdir of the bridge folder returns nil, a message with a newline and a high byte, and a code.
  local original_new = fake_lfs.new
  local made
  fake_lfs.new = function(initial)
    made = original_new(initial)
    made.mkdir_result[DIR] = { nil, 'bad\n\255 path', 5 }
    return made
  end
  local ok, ctx = pcall(run_entry)
  fake_lfs.new = original_new
  assert(ok, ctx)
  return ctx
end

test('a folder that cannot be created refuses once; the detail is escaped; no listener is registered and nothing starts (decisions 13, 14 and 16)', function()
  local ctx = run_with_mkdir_failure()
  local line = single_refusal(ctx)
  expect.equal(line, PREFIX .. 'could not create the bridge folder (bad\\x0a\\xff path)')
  expect.equal(ctx.counts.event_regs, 0)
  expect.equal(file_data(ctx, EVENTS), nil)
end)

-- ---- Listener registration (decision 14) ------------------------------------------------------------------------------

test('the catch-all listener is registered exactly once, after the folder preparation and before the first file the bridge writes (decision 14)', function()
  local ctx = run_entry()
  expect.equal(ctx.counts.event_regs, 1)
  expect.equal(ctx.event_pattern, '#*#')
  local reg = index_of(ctx, function(c) return c.fn == 'mq.event' end)
  expect.truthy(reg > last_index_of(ctx, function(c) return c.fn == 'lfs.mkdir' end))
  expect.truthy(reg < index_of(ctx, is_write))
  expect.truthy(reg < index_of(ctx, function(c) return c.fn == 'winreplace.replace' end))
end)

test('a failed loop start refuses once with the fixed reason and the detail, leaves the listener registered but dispatches nothing, and never polls (decisions 6, 14 and 16)', function()
  local tree = { [ROOT] = true }
  local ctx
  local original_new = fake_lfs.new
  fake_lfs.new = function(initial)
    local f = original_new(initial)
    f.attr_fail[EVENTS] = { 'Access is denied', 13 }
    return f
  end
  local ok, result = pcall(run_entry, { tree = tree })
  fake_lfs.new = original_new
  assert(ok, result)
  ctx = result
  local line = single_refusal(ctx)
  expect.truthy(starts_with(line, PREFIX .. 'the events file could not be opened'), line)
  T.assert_contains(line, 'Access is denied')                 -- the detail travels with the refusal (decision 16)
  expect.equal(ctx.counts.event_regs, 1)
  expect.equal(file_data(ctx, HEARTBEAT), nil)
end)

test('a delivered line reaches the loop with the current os.time(), and is recorded as a chat event (decisions 6 and 14)', function()
  local ctx = run_entry({ max_delays = 1, now = 7777, on_doevents = function(c, n) if n == 1 then c.hear('hello world') end end })
  expect.equal(ctx.stopped, true)
  local events = file_data(ctx, EVENTS)
  T.assert_contains(events, '"t":7777,"kind":"chat","text":"hello world"')
end)

-- ---- The loop (decisions 7 Revision 4 and 15) ------------------------------------------------------------------------------

test('each poll calls doevents, then the step (which lists the inbox), then delay(100), in that order (decision 15)', function()
  local ctx = run_entry({ max_delays = 3 })
  local seq = {}
  local started = false
  for _, c in ipairs(ctx.fake.calls) do
    if c.fn == 'mq.doevents' then started = true end
    if started then
      if c.fn == 'mq.doevents' or c.fn == 'mq.delay' or (c.fn == 'lfs.dir' and c.path == INBOX) then seq[#seq + 1] = c.fn .. (c.fn == 'mq.delay' and (':' .. tostring(c.extra)) or '') end
    end
  end
  expect.equal(seq, {
    'mq.doevents', 'lfs.dir', 'mq.delay:100',
    'mq.doevents', 'lfs.dir', 'mq.delay:100',
    'mq.doevents', 'lfs.dir', 'mq.delay:100',
  })
end)

test('the clocks are read once per poll for the step, and once at startup (decision 7 Revision 4)', function()
  local ctx = run_entry({ max_delays = 3 })
  expect.equal(ctx.counts.gettime, 1 + 3)
  expect.equal(ctx.counts.os_time, 1 + 3)
end)

test('a request that arrives is answered in the poll that sees it: the real core and store run behind the entry script (decisions 15 and 17; criterion 1)', function()
  local ctx = run_entry({ max_delays = 1, on_doevents = function(c, n)
    if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"ping"}' } end
  end })
  local reply = file_data(ctx, OUTBOX .. '\\000001.json')
  T.assert_contains(reply, '"ok":true')
  T.assert_contains(reply, '"command":"ping"')
  T.assert_contains(reply, '"character":"Bob"')
  T.assert_contains(reply, '"zone":"bazaar"')
end)

test('a failure set while events are processed stops the loop before the step and before the delay; the stopped line is printed once (decisions 6, 7 and 15)', function()
  local ctx = run_entry({ max_delays = 5, on_doevents = function(c, n)
    if n == 1 then c.fake.write_fail[EVENTS] = 'disk full'; c.hear('x') end
  end })
  expect.equal(ctx.ok, true)                               -- the loop ended by itself, not by the test's stop
  expect.equal(ctx.counts.doevents, 1)
  expect.equal(ctx.counts.delay, 0)
  expect.equal(ctx.counts.gettime, 1)                      -- only the startup reading: the step was never called (decision 15)
  local doevents_at = index_of(ctx, function(c) return c.fn == 'mq.doevents' end)
  expect.equal(index_of(ctx, function(c, i) return i > doevents_at and c.fn == 'lfs.dir' end), nil)   -- no step ran
  expect.equal(#ctx.prints, 2)
  expect.equal(ctx.prints[1], START_LINE)
  expect.truthy(starts_with(ctx.prints[2], STOPPED .. 'could not record an event'), ctx.prints[2])
  T.assert_contains(ctx.prints[2], 'disk full')
  expect.truthy(printable_line(ctx.prints[2]))
end)

test('a failure set during the step stops the loop before the delay (decisions 6 and 15)', function()
  local ctx = run_entry({ max_delays = 5, on_doevents = function(c, n)
    if n == 1 then c.fake.dir_raises[OUTBOX] = true end
  end })
  expect.equal(ctx.ok, true)
  expect.equal(ctx.counts.doevents, 1)
  expect.equal(ctx.counts.delay, 0)
  expect.equal(#ctx.prints, 2)
  expect.truthy(starts_with(ctx.prints[2], STOPPED .. 'could not list the outbox folder'), ctx.prints[2])
end)

test('a failure set during the delay itself (a callback dispatched there) is noticed at the loop boundary: no further doevents, no further step (decision 15)', function()
  local ctx = run_entry({ max_delays = 5, on_delay = function(c, n)
    if n == 1 then c.fake.write_fail[EVENTS] = 'disk full'; c.hear('x') end
  end })
  expect.equal(ctx.ok, true)
  expect.equal(ctx.counts.doevents, 1)
  expect.equal(ctx.counts.delay, 1)
  local dir_calls = 0
  for _, c in ipairs(ctx.fake.calls) do if c.fn == 'lfs.dir' and c.path == INBOX then dir_calls = dir_calls + 1 end end
  expect.equal(dir_calls, 2)                                -- the startup listing and exactly one step
  expect.equal(#ctx.prints, 2)
  expect.truthy(starts_with(ctx.prints[2], STOPPED .. 'could not record an event'), ctx.prints[2])
end)

test('mq.delay is never called after the loop has stopped (decision 15)', function()
  local ctx = run_entry({ max_delays = 9, on_doevents = function(c, n)
    if n == 2 then c.fake.write_fail[EVENTS] = 'disk full'; c.hear('x') end
  end })
  expect.equal(ctx.counts.doevents, 2)
  expect.equal(ctx.counts.delay, 1)
  expect.equal(#ctx.prints, 2)
end)

-- ---- The env adapter (decision 17) ------------------------------------------------------------------------------------

local function ping_run(opts)
  opts = opts or {}
  opts.max_delays = opts.max_delays or 1
  opts.on_doevents = function(c, n)
    if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"ping"}' } end
  end
  return run_entry(opts)
end

test('when Me() is nil both character and zone are null, even though the Me proxy exists and a zone name would be available (decision 17; design item 9)', function()
  local ctx = ping_run({ me_unavailable = true })
  local reply = file_data(ctx, OUTBOX .. '\\000001.json')
  T.assert_contains(reply, '"character":null,"zone":null')
  local hb = file_data(ctx, HEARTBEAT)
  T.assert_contains(hb, '"character":null')
  T.assert_contains(hb, '"zone":null')
end)

test('a nil member result is null (decision 17)', function()
  local ctx = ping_run({ character_nil = true, zone_nil = true })
  T.assert_contains(file_data(ctx, OUTBOX .. '\\000001.json'), '"character":null,"zone":null')
end)

test('an empty string and the text NULL pass through unchanged and are not reinterpreted (decision 17)', function()
  local ctx = ping_run({ character = '', zone = 'NULL' })
  T.assert_contains(file_data(ctx, OUTBOX .. '\\000001.json'), '"character":"","zone":"NULL"')
end)

test('the evaluated root is checked with Me(), and the member is read only after it (decision 17)', function()
  local ctx = ping_run()
  local root_eval = index_of(ctx, function(c) return c.fn == 'mq.TLO.Me()' end)
  local member = index_of(ctx, function(c) return c.fn == 'Me.CleanName' end)
  expect.truthy(root_eval and member and root_eval < member)
  local ctx2 = ping_run({ me_unavailable = true })
  expect.equal(index_of(ctx2, function(c) return c.fn == 'Me.CleanName' or c.fn == 'Zone.ShortName' end), nil)
end)

test('parse is a direct pass-through to mq.parse: the exact string comes back, including NULL (decision 17; criterion 4)', function()
  local ctx = run_entry({ max_delays = 1, on_doevents = function(c, n)
    if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"eval","expression":"${Me.Level}"}' } end
  end })
  T.assert_contains(file_data(ctx, OUTBOX .. '\\000001.json'), '"value":"parsed<${Me.Level}>"')
  local ctx2 = run_entry({ max_delays = 1, parse = function() return 'NULL' end, on_doevents = function(c, n)
    if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"eval","expression":"${Me.Level}"}' } end
  end })
  T.assert_contains(file_data(ctx2, OUTBOX .. '\\000001.json'), '"value":"NULL"')
end)

for _, case in ipairs({
  { 'a number character', { character = 5 }, 'claudebridge internal error: character returned a number value' },
  { 'a table zone', { zone = {} }, 'claudebridge internal error: zone returned a table value' },
  { 'a boolean character', { character = true }, 'claudebridge internal error: character returned a boolean value' },
}) do
  test('an unexpected member type (' .. case[1] .. ') is a real failure, not absence: the first heartbeat is skipped and a ping ends the script with the fixed error (decisions 9 and 17)', function()
    local opts = case[2]
    opts.max_delays = 5
    opts.on_doevents = function(c, n)
      if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"ping"}' } end
    end
    local ctx = run_entry(opts)
    expect.equal(ctx.ok, false)
    expect.equal(ctx.crashed, case[3])
    expect.equal(file_data(ctx, HEARTBEAT), nil)                  -- skipped, so the stale heartbeat reports it
    expect.equal(file_data(ctx, OUTBOX .. '\\000001.json'), nil)  -- no healthy-looking reply
  end)
end

test('a raise from the game read is not caught by the adapter: the heartbeat skips it and a ping propagates it (decisions 9 and 17)', function()
  local ctx = run_entry({ max_delays = 5, character = function() error('boom', 0) end, on_doevents = function(c, n)
    if n == 1 then c.fake.tree[INBOX .. '\\000001.json'] = { kind = 'file', data = '{"command":"ping"}' } end
  end })
  expect.equal(ctx.ok, false)
  expect.equal(ctx.crashed, 'boom')
  expect.equal(file_data(ctx, HEARTBEAT), nil)
end)

-- ---- Safety property of this suite (decision 12) -----------------------------------------------------------------------

test('this suite never loaded or executed the real winreplace.lua (decision 12): only the tripwire fake was requested', function()
  expect.equal(package.loaded['claudebridge.winreplace'], nil)
end)
