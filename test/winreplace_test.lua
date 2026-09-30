-- Tests for claudebridge/winreplace.lua with a FAKE ffi (Step 5 of DL-022, decisions 8 and 12). The module is loaded with a fake `ffi` through
-- the harness's fresh_require, so these check the wrapper's contract and its ordering, not the real Windows call (that is test/winreplace_x64_test.lua,
-- x64-only logic evidence, and the live x86 check at Step 8).
-- Requirement sources, named per test below:
--   * Design item 26 and decision 8: both Windows symbols (MoveFileExA, GetLastError) are bound when the module loads, before any replacement call; if
--     ffi or a symbol is unavailable the module fails to load (the entry script then refuses to start); GetLastError is read only after a failed
--     MoveFileExA, immediately, and is the only error authority; ffi.errno() is never used (spike 8(c): it was stale); replace returns true, or nil plus
--     GetLastError's number; the module holds only the replacement primitive.
--   * Decision 12: the declaration and the flag are copied byte for byte from spikes/spike8_c.lua (the reviewed file that ran live in the 32-bit
--     client); a test compares the two files so the copy cannot drift.
local T = require 'harness.t'
local test, expect = T.test, T.expect
local fs = require 'harness.fs'

-- A fake ffi. opts.result is MoveFileExA's return (default 1 = success), opts.code is GetLastError's return, opts.missing names a symbol whose
-- lookup raises (as an undefined symbol does). Every cdef text, every symbol lookup and every call is recorded in `log`.
local function make_ffi(opts)
  opts = opts or {}
  local log = { cdefs = {}, looked_up = {}, calls = {} }
  local C = setmetatable({}, { __index = function(_, symbol)
    log.looked_up[#log.looked_up + 1] = symbol
    if opts.missing == symbol then error('undefined symbol: ' .. symbol, 2) end
    if symbol == 'MoveFileExA' then
      return function(src, dst, flags)
        log.calls[#log.calls + 1] = { 'MoveFileExA', src, dst, flags }
        return opts.result == nil and 1 or opts.result
      end
    end
    if symbol == 'GetLastError' then
      return function()
        log.calls[#log.calls + 1] = { 'GetLastError' }
        return opts.code or 0
      end
    end
    error('the module looked up an unexpected symbol: ' .. tostring(symbol), 2)
  end })
  local ffi = {
    os = 'Windows', arch = 'x86', C = C,
    cdef = function(text) log.cdefs[#log.cdefs + 1] = text end,
    errno = function() error('ffi.errno must never be consulted (decision 8: GetLastError is the only error authority)') end,
  }
  return ffi, log
end

local function load_with(ffi)
  T.patch(package.loaded, 'ffi', ffi)
  return T.fresh_require('claudebridge.winreplace')
end

local function decl_block(text) return text:match('ffi%.cdef%[%[(.-)%]%]') end

-- ---- Copied, not re-derived (decision 12) -------------------------------------------------------------------------------------------

test('the declaration is identical to spike 8(c)\'s, byte for byte, and is what is passed to ffi.cdef (decision 12)', function()
  local spike = fs.read_all(T.root .. '/spikes/spike8_c.lua')
  local module = fs.read_all(T.root .. '/lua/claudebridge/winreplace.lua')
  expect.truthy(spike and module)
  local from_spike, from_module = decl_block(spike), decl_block(module)
  expect.truthy(from_spike and #from_spike > 40)
  expect.equal(from_module, from_spike)
  local ffi, log = make_ffi()
  load_with(ffi)
  expect.equal(#log.cdefs, 1)
  -- Lua skips a newline that immediately follows the opening [[ of a long string, so ffi.cdef receives the block without that first newline.
  expect.equal(log.cdefs[1], (from_spike:gsub('^\r?\n', '')))
end)

test('the flag is MOVEFILE_REPLACE_EXISTING = 0x1, as in spike 8(c), and is what MoveFileExA receives (decision 12)', function()
  local spike = fs.read_all(T.root .. '/spikes/spike8_c.lua')
  local module = fs.read_all(T.root .. '/lua/claudebridge/winreplace.lua')
  expect.truthy(spike:find('local MOVEFILE_REPLACE_EXISTING = 0x1', 1, true))
  expect.truthy(module:find('local MOVEFILE_REPLACE_EXISTING = 0x1', 1, true))
  local ffi, log = make_ffi()
  local wr = load_with(ffi)
  wr.replace('a', 'b')
  expect.equal(log.calls[1][4], 1)
end)

-- ---- Binding at load and failing closed (decision 8, design item 26.1 and 26.4) ---------------------------------------------------------

test('both symbols are bound when the module loads, before any replacement call (design item 26.1)', function()
  local ffi, log = make_ffi()
  load_with(ffi)
  local seen = {}
  for _, symbol in ipairs(log.looked_up) do seen[symbol] = true end
  expect.truthy(seen.MoveFileExA)
  expect.truthy(seen.GetLastError)
  expect.equal(#log.calls, 0)
end)

test('the symbols are not looked up again on each call: binding happened once, at load (design item 26.1)', function()
  local ffi, log = make_ffi({ result = 0, code = 5 })
  local wr = load_with(ffi)
  local lookups = #log.looked_up
  wr.replace('a', 'b')
  wr.replace('c', 'd')
  expect.equal(#log.looked_up, lookups)
end)

test('a symbol that cannot be bound makes the module fail to load, so nothing can be called (decision 8, design item 26.4)', function()
  for _, missing in ipairs({ 'MoveFileExA', 'GetLastError' }) do
    local ffi = make_ffi({ missing = missing })
    T.patch(package.loaded, 'ffi', ffi)
    local ok, err = pcall(T.fresh_require, 'claudebridge.winreplace')
    expect.equal(ok, false, missing .. ' missing should stop loading')
    expect.truthy(tostring(err):find(missing, 1, true))
  end
end)

test('an unavailable ffi makes the module fail to load (design item 26.4: no fallback to a weaker mechanism)', function()
  T.patch(package.loaded, 'ffi', nil)
  T.patch(package.preload, 'ffi', function() error('module ffi not found') end)
  local ok = pcall(T.fresh_require, 'claudebridge.winreplace')
  expect.equal(ok, false)
end)

-- ---- The contract and the ordering (decision 8) -------------------------------------------------------------------------------------------

test('a successful replacement returns true, passes both paths through unchanged, and never reads GetLastError (decision 8)', function()
  local ffi, log = make_ffi({ result = 1 })
  local wr = load_with(ffi)
  local ok, extra = wr.replace('C:\\x\\heartbeat.json.tmp', 'C:\\x\\heartbeat.json')
  expect.equal(ok, true)
  expect.equal(extra, nil)
  expect.equal(#log.calls, 1)
  expect.equal(log.calls[1][1], 'MoveFileExA')
  expect.equal(log.calls[1][2], 'C:\\x\\heartbeat.json.tmp')
  expect.equal(log.calls[1][3], 'C:\\x\\heartbeat.json')
end)

test('any non-zero result is success, whatever its value (the Win32 BOOL contract)', function()
  for _, result in ipairs({ 1, 2, 255, -1 }) do
    local ffi = make_ffi({ result = result })
    local wr = load_with(ffi)
    expect.equal((wr.replace('a', 'b')), true)
  end
end)

test('a failed replacement returns nil and GetLastError\'s number, read exactly once, immediately after MoveFileExA (decision 8)', function()
  local ffi, log = make_ffi({ result = 0, code = 5 })
  local wr = load_with(ffi)
  local ok, code = wr.replace('a', 'b')
  expect.equal(ok, nil)
  expect.equal(code, 5)
  expect.equal(type(code), 'number')
  expect.equal(#log.calls, 2)
  expect.equal(log.calls[1][1], 'MoveFileExA')
  expect.equal(log.calls[2][1], 'GetLastError')
end)

test('the error code is whatever GetLastError returns, including other codes (decision 8)', function()
  for _, code in ipairs({ 2, 3, 5, 32, 87 }) do
    local ffi = make_ffi({ result = 0, code = code })
    local wr = load_with(ffi)
    expect.equal(select(2, wr.replace('a', 'b')), code)
  end
end)

test('ffi.errno is never consulted on success or on failure: the fake raises if it is (decision 8, spike 8(c): errno was stale)', function()
  local ffi = make_ffi({ result = 0, code = 5 })
  local wr = load_with(ffi)
  expect.equal((pcall(wr.replace, 'a', 'b')), true)
  local ffi2 = make_ffi({ result = 1 })
  local wr2 = load_with(ffi2)
  expect.equal((pcall(wr2.replace, 'a', 'b')), true)
end)

test('the module exposes only replace: no general filesystem adapter, logging, retries or deletion (decision 8 scope)', function()
  local ffi = make_ffi()
  local wr = load_with(ffi)
  local keys = {}
  for k in pairs(wr) do keys[#keys + 1] = k end
  expect.equal(keys, { 'replace' })
end)
