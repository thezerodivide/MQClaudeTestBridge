-- Test-file API (adapted from PTAutoRoute's harness; this repo: DL-021 design item 1). A test file does:
--   local T = require 'harness.t'
--   local test, expect = T.test, T.expect
-- Tests run immediately when declared (Lester runs `it` at call time).
local lester = require 'lester'
local fs = require 'harness.fs'

lester.color = false
lester.quiet = false
lester.show_traceback = false
lester.show_error = true

local T = { expect = lester.expect }

local stats = { ran = 0, passed = 0, failed = 0, skipped = 0, cleanup_failed = 0 }
local cleanups = {}

local function describe_error(e)
  if type(e) == 'string' then return e end
  return '(non-string error, ' .. type(e) .. ') ' .. tostring(e)
end

local function traceback_handler(e)
  return debug.traceback(describe_error(e), 2)
end

function T.summary()
  return stats
end

-- Registers fn to run after the current test, LIFO, whether the test passed or failed.
function T.on_cleanup(fn)
  cleanups[#cleanups + 1] = fn
end

-- One top-level `after`: Lester runs it after every test, pass or fail.
lester.after(function(name)
  for i = #cleanups, 1, -1 do
    local ok, e = xpcall(cleanups[i], traceback_handler)
    if not ok then
      stats.cleanup_failed = stats.cleanup_failed + 1
      print('[CLEANUP FAILED] after "' .. name .. '": ' .. describe_error(e))
    end
    cleanups[i] = nil
  end
end)

-- Tail call so Lester's [FAIL] header points at the test file's line, not this one.
function T.test(name, fn)
  stats.ran = stats.ran + 1
  return lester.it(name, function()
    local ok, e = xpcall(fn, traceback_handler)
    if ok then
      stats.passed = stats.passed + 1
    else
      stats.failed = stats.failed + 1
      error(e, 0)
    end
  end)
end

-- A skip must say why; it is printed every run and never counted as "ran".
function T.skip(name, reason)
  if type(reason) ~= 'string' or not reason:find('%S') then
    error('skip() requires a reason: ' .. tostring(name), 2)
  end
  stats.skipped = stats.skipped + 1
  return lester.it(name .. '  -- SKIPPED: ' .. reason, function() end, false)
end

-- Plain-substring containment (needles like "100%" are safe).
function T.assert_contains(haystack, needle, msg)
  if type(haystack) ~= 'string' or not haystack:find(needle, 1, true) then
    error((msg and (msg .. ': ') or '') .. 'expected ' .. tostring(haystack) .. ' to contain "' .. needle .. '"', 2)
  end
end

function T.near(a, b, eps, msg)
  eps = eps or 1e-9
  if type(a) ~= 'number' or type(b) ~= 'number' or math.abs(a - b) > eps then
    error((msg and (msg .. ': ') or '') .. string.format('expected %.17g to be within %g of %.17g', tonumber(a) or 0, eps, tonumber(b) or 0), 2)
  end
end

-- Sets tbl[key] = value for the duration of the current test.
function T.patch(tbl, key, value)
  local old = tbl[key]
  tbl[key] = value
  T.on_cleanup(function() tbl[key] = old end)
end

-- Clears every claudebridge.* entry so the module tree is loaded fresh and consistently
-- (clearing a single entry would leave already-loaded dependents on the old table).
function T.fresh_require(name)
  for k in pairs(package.loaded) do
    if type(k) == 'string' and (k == 'claudebridge' or k:find('^claudebridge%.')) then package.loaded[k] = nil end
  end
  return require(name)
end

local function norm(p)
  return (fs.native(p):lower():gsub(fs.native('\\') .. '+$', ''))
end

-- Creates a fresh temp directory under %TEMP%, removed after the test. Refuses anything else.
function T.with_temp_dir()
  local temp = os.getenv('TEMP')
  assert(temp and temp ~= '', 'with_temp_dir: %TEMP% is not set')
  local dir = os.tmpname()
  local prefix = norm(temp) .. fs.native('\\')
  assert(norm(dir):sub(1, #prefix) == prefix, 'with_temp_dir: refusing path outside %TEMP%: ' .. dir)
  assert(not fs.exists(dir), 'with_temp_dir: refusing existing path: ' .. dir)
  assert(fs.execute('mkdir ' .. fs.q(dir) .. ' >NUL 2>&1') == 0, 'with_temp_dir: mkdir failed: ' .. dir)
  T.on_cleanup(function()
    assert(norm(dir):sub(1, #prefix) == prefix, 'refusing to delete outside %TEMP%: ' .. dir)
    fs.execute('rmdir /s /q ' .. fs.q(dir) .. ' >NUL 2>&1')
    assert(not fs.exists(dir), 'temp dir was not removed: ' .. dir)
  end)
  return dir
end

return T
