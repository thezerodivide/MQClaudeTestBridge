-- Test runner (adapted from PTAutoRoute's harness; this repo: DL-021 design item 1): luajit test/harness/run.lua [test dir]
-- Runs every test/*_test.lua in its own luajit subprocess and reports per-file results.
-- Exit codes: 0 all pass, 20 at least one file failed/crashed, 21 discovery/guard failure.
local script = arg[0]:gsub('\\', '/')
local script_dir = script:match('^(.*)/[^/]*$') or '.'
local root = script_dir .. '/../..'
package.path = root .. '/test/?.lua;' .. package.path

local fs = require 'harness.fs'
local interp = arg[-1]
local test_dir = arg[1] or (root .. '/test')

local function guard_fail(msg)
  print('RUNNER GUARD FAILURE: ' .. msg)
  os.exit(21)
end

-- Layout contract: every .lua directly in the test dir is a test file, so a misnamed file
-- can never be silently skipped.
local all = fs.list(test_dir, '*.lua')
if #all == 0 then guard_fail('no .lua files found in ' .. test_dir .. ' (or the directory listing failed)') end
local files = {}
for _, name in ipairs(all) do
  if not name:find('_test%.lua$') then
    guard_fail('"' .. name .. '" in ' .. test_dir .. ' does not match *_test.lua; support code belongs in test/harness/ or test/vendor/')
  end
  files[#files + 1] = name
end

print('MQ bridge test run: ' .. #files .. ' file(s) in ' .. test_dir .. ' using ' .. tostring(interp))
for _, name in ipairs(files) do print('  ' .. name) end

local labels = { [0] = 'PASS', [10] = 'FAIL (tests failed)', [11] = 'FAIL (load error)', [12] = 'FAIL (no tests ran)' }
local totals = { ran = 0, passed = 0, failed = 0, skipped = 0 }
local bad = 0

for _, name in ipairs(files) do
  local outfile = os.tmpname()
  local cmd = fs.q(interp) .. ' ' .. fs.q(root .. '/test/harness/bootstrap.lua') .. ' ' ..
    fs.q(test_dir .. '/' .. name) .. ' ' .. fs.q(root) .. ' > ' .. fs.q(outfile) .. ' 2>&1'
  local code = fs.execute(cmd)
  local out = fs.read_all(outfile) or '(no output captured)'
  os.remove(outfile)

  print('\n===== ' .. name .. ' =====')
  io.write(out, out:sub(-1) == '\n' and '' or '\n')

  local ran, passed, failed, skipped = out:match('MQBRIDGE_TEST_SUMMARY ran=(%d+) passed=(%d+) failed=(%d+) skipped=(%d+)')
  local label = labels[code] or ('CRASH/LAUNCH FAILURE (exit ' .. tostring(code) .. ')')
  if code == 0 and not ran then
    label = 'FAIL (exit 0 but no summary line)'
    code = -1
  end
  if ran then
    totals.ran, totals.passed = totals.ran + ran, totals.passed + passed
    totals.failed, totals.skipped = totals.failed + failed, totals.skipped + skipped
  end
  print('----- ' .. name .. ': ' .. label)
  if code ~= 0 then bad = bad + 1 end
end

print(string.format('\nSUMMARY: %d file(s), %d bad; tests ran=%d passed=%d failed=%d skipped=%d',
  #files, bad, totals.ran, totals.passed, totals.failed, totals.skipped))
-- A failing file is the more specific cause, so it is reported before the zero-tests guard.
if bad > 0 then
  print('RESULT: FAIL')
  os.exit(20)
end
if totals.ran == 0 then guard_fail('zero tests ran across all files') end
print('RESULT: PASS')
os.exit(0)
