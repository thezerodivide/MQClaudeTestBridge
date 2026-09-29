-- Runs ONE test file in this process (adapted from PTAutoRoute's harness; this repo: DL-021 design item 1). Launched by run.lua: bootstrap.lua <test file> <repo root>
-- Exit codes: 0 pass, 10 a test failed, 11 the file failed to load/run its body, 12 the file ran zero tests.
-- Any other code (notably 1) means this script itself crashed.
local file, root = arg[1], arg[2]
assert(file and root, 'usage: bootstrap.lua <test file> <repo root>')
package.path = root .. '/lua/?.lua;' .. root .. '/test/?.lua;' .. root .. '/test/vendor/?.lua;' .. package.path

local T = require 'harness.t'
local lester = require 'lester'
T.root = root

local chunk, err = loadfile(file)
if not chunk then
  print('LOAD ERROR (syntax): ' .. tostring(err))
  os.exit(11)
end
local ok, e = xpcall(chunk, function(m) return debug.traceback(type(m) == 'string' and m or tostring(m), 2) end)
if not ok then
  print('LOAD ERROR (file body raised outside a test): ' .. e)
  os.exit(11)
end

local s = T.summary()
lester.report()
print(string.format('MQBRIDGE_TEST_SUMMARY ran=%d passed=%d failed=%d skipped=%d cleanup_failed=%d',
  s.ran, s.passed, s.failed, s.skipped, s.cleanup_failed))
if s.ran == 0 then os.exit(12) end
if s.failed > 0 or s.cleanup_failed > 0 then os.exit(10) end
os.exit(0)
