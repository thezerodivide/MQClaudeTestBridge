-- The Lua and Python sides carry one shared project version.
-- Requirement source: DL-021 design item 24 ("One project version: version.lua and version.py hold the same
-- 0.1.0-test.N value; a local test fails if they differ"), and design item 22 (the MCP server's identity).
local T = require 'harness.t'
local test, expect = T.test, T.expect
local fs = require 'harness.fs'

test('the Lua and Python version modules hold the same version', function()
  local py = fs.read_all(T.root .. '/python/mq_mcp/version.py')
  expect.truthy(py, 'python/mq_mcp/version.py could not be read')
  local py_version = py:match("\nVERSION%s*=%s*'([^']+)'")
  expect.truthy(py_version, 'no VERSION = \'...\' line found in version.py')
  local lua_version = require('claudebridge.version').VERSION
  expect.equal(py_version, lua_version)
end)
