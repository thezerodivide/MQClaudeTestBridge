-- Parse-checks every .lua file under lua/ and test/ without executing anything (adapted from PTAutoRoute's harness; this repo: DL-021 design item 1).
-- luajit test/harness/syntax_check.lua      Exit codes: 0 clean, 30 syntax error(s), 31 guard failure.
local script = arg[0]:gsub('\\', '/')
local root = (script:match('^(.*)/[^/]*$') or '.') .. '/../..'
package.path = root .. '/test/?.lua;' .. package.path
local fs = require 'harness.fs'

local files = {}
for _, sub in ipairs({ 'lua', 'test' }) do
  for _, p in ipairs(fs.list(root .. '/' .. sub, '*.lua', true)) do files[#files + 1] = p end
end
table.sort(files)

-- Guard: the listing cannot signal failure, so require the known entry point to be present.
local saw_version = false
for _, p in ipairs(files) do
  if p:find('claudebridge[/\\]version%.lua$') then saw_version = true end
end
if not saw_version then
  print('SYNTAX CHECK GUARD FAILURE: found ' .. #files .. ' files and claudebridge/version.lua was not among them (listing failed?)')
  os.exit(31)
end

local bad = 0
for _, p in ipairs(files) do
  local chunk, err = loadfile(p)
  if not chunk then
    bad = bad + 1
    print('SYNTAX ERROR: ' .. tostring(err))
  end
end
print(string.format('syntax check: %d file(s), %d error(s)', #files, bad))
os.exit(bad > 0 and 30 or 0)
