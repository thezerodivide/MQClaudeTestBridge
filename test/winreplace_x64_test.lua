-- Tests for claudebridge/winreplace.lua with the REAL ffi (Step 5 of DL-022, decisions 8 and 12).
-- EVIDENCE LABEL: these run in the standalone LuaJIT that runs the local suite (x64). They are x64-only logic and Windows-semantics evidence: they show that the
-- wrapper really binds the Windows symbols and does what it says on real files. They do NOT validate the 32-bit calling convention (`__stdcall` is ignored on
-- x64); that is proven only by the live x86 check (spike 8(c) for the declaration, and the Step 8 integrated check for the final module).
-- Bounded: every test works in its own scratch folder (harness T.with_temp_dir: unique, under %TEMP%, refuses any other path, removed afterwards); the
-- MacroQuest and bridge folders are never touched. The module is loaded once per process, so the real ffi.cdef runs once.
-- Requirement sources: decision 8 (replace returns true, or nil plus GetLastError's number); design item 26 and spikes 8(c) and 9 (a replacement onto a
-- file a reader holds open is refused, GetLastError 5, and changes nothing); the Win32 system error codes (2 is ERROR_FILE_NOT_FOUND, 5 is ERROR_ACCESS_DENIED).
local T = require 'harness.t'
local test, expect = T.test, T.expect
local fs = require 'harness.fs'

-- The real module is loaded ONLY on Windows x64. On any other architecture, above all x86, these tests skip BEFORE the safety-sensitive module is loaded,
-- so the real 32-bit __stdcall call can never run from the local suite: real x86 use is reserved for the Step 8 live check, after the exact-file review
-- and the developer's separate crash-risk decision (DL-022 decision 12; the second reviewer's finding on this file).
local function real_tests_allowed(ffi_lib)
  return ffi_lib ~= nil and ffi_lib.os == 'Windows' and ffi_lib.arch == 'x64'
end

-- The one place the real module is loaded. `load` is injected so a test can show that an x86 ffi never reaches it.
local function load_real(ffi_lib, load)
  if real_tests_allowed(ffi_lib) then return load('claudebridge.winreplace') end
  return nil
end

local ok_ffi, ffi = pcall(require, 'ffi')
local winreplace = ok_ffi and load_real(ffi, require) or nil

local function skip_reason()
  return 'the real-ffi tests need x64 LuaJIT on Windows; the real call on x86 is reserved for the Step 8 live check'
end

test('the gate that decides whether the real module may be loaded allows Windows x64 and nothing else, above all not x86 (decision 12)', function()
  expect.equal(real_tests_allowed({ os = 'Windows', arch = 'x64' }), true)
  expect.equal(real_tests_allowed({ os = 'Windows', arch = 'x86' }), false)
  expect.equal(real_tests_allowed({ os = 'Windows', arch = 'arm64' }), false)
  expect.equal(real_tests_allowed({ os = 'Windows', arch = nil }), false)
  expect.equal(real_tests_allowed({ os = 'Linux', arch = 'x64' }), false)
  expect.equal(real_tests_allowed({ os = nil, arch = 'x64' }), false)
  expect.equal(real_tests_allowed(nil), false)
end)

test('the real module is never loaded for an ffi that is not Windows x64: the loader is not even called (decision 12: x86 is reserved for Step 8)', function()
  local loads = {}
  local function recording_loader(name) loads[#loads + 1] = name; return { replace = function() end } end
  for _, not_allowed in ipairs({
    { os = 'Windows', arch = 'x86' }, { os = 'Windows', arch = 'arm64' }, { os = 'Linux', arch = 'x64' }, { os = 'Windows' }, {},
  }) do
    expect.equal(load_real(not_allowed, recording_loader), nil)
  end
  expect.equal(load_real(nil, recording_loader), nil)
  expect.equal(#loads, 0)
  local module = load_real({ os = 'Windows', arch = 'x64' }, recording_loader)   -- the allowed case loads it, once
  expect.equal(type(module), 'table')
  expect.equal(loads, { 'claudebridge.winreplace' })
end)

local function write_file(path, data)
  local f = assert(io.open(path, 'wb'))
  assert(f:write(data))
  assert(f:close())
end

local function content(path) return fs.read_all(path) end

local function case(title, fn)
  if not winreplace then T.skip(title, skip_reason()); return end
  test(title, fn)
end

case('x64 evidence: a replacement onto a MISSING destination succeeds: the destination holds the new content and the source is gone (decision 8)', function()
  local dir = T.with_temp_dir()
  local src, dst = dir .. '\\heartbeat.json.tmp', dir .. '\\heartbeat.json'
  write_file(src, 'new')
  expect.equal(winreplace.replace(src, dst), true)
  expect.equal(content(dst), 'new')
  expect.equal(fs.exists(src), false)
end)

case('x64 evidence: a replacement onto an EXISTING destination succeeds and replaces its content, the source is gone (decision 8, spike 8 c2)', function()
  local dir = T.with_temp_dir()
  local src, dst = dir .. '\\heartbeat.json.tmp', dir .. '\\heartbeat.json'
  write_file(dst, 'old content that is longer')
  write_file(src, 'newer')
  expect.equal(winreplace.replace(src, dst), true)
  expect.equal(content(dst), 'newer')
  expect.equal(fs.exists(src), false)
end)

case('x64 evidence: a replacement onto a destination a reader holds open is REFUSED with GetLastError 5 and changes nothing; it succeeds once the reader lets go (spikes 8 c3 and 9)', function()
  local dir = T.with_temp_dir()
  local src, dst = dir .. '\\heartbeat.json.tmp', dir .. '\\heartbeat.json'
  write_file(dst, 'old')
  write_file(src, 'new')
  local held = assert(io.open(dst, 'rb'))
  local closed = false
  local function release() if not closed then closed = true; pcall(held.close, held) end end
  T.on_cleanup(release)                       -- runs even if an assertion below fails, so the scratch folder can be removed
  local ok, code = winreplace.replace(src, dst)
  expect.equal(ok, nil)
  expect.equal(code, 5)
  expect.equal(type(code), 'number')
  expect.equal(content(dst), 'old')
  expect.equal(content(src), 'new')
  release()
  expect.equal(winreplace.replace(src, dst), true)
  expect.equal(content(dst), 'new')
end)

case('x64 evidence: a MISSING source fails with GetLastError 2 (file not found) and leaves the destination alone (decision 8)', function()
  local dir = T.with_temp_dir()
  local src, dst = dir .. '\\no_such_source.tmp', dir .. '\\heartbeat.json'
  write_file(dst, 'keep me')
  local ok, code = winreplace.replace(src, dst)
  expect.equal(ok, nil)
  expect.equal(code, 2)
  expect.equal(content(dst), 'keep me')
end)

case('x64 evidence: the real module exposes only replace, and the code it returns is a Lua number (decision 8)', function()
  local keys = {}
  for k in pairs(winreplace) do keys[#keys + 1] = k end
  expect.equal(keys, { 'replace' })
  local dir = T.with_temp_dir()
  local _, code = winreplace.replace(dir .. '\\nothing.tmp', dir .. '\\x')
  expect.equal(type(code), 'number')
end)
