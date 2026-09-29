-- Tests for claudebridge/version.lua (Lua side of the build identity).
-- Requirement source for every test: DL-021 design item 21 (build identity for the bridge, Protocol §9):
--   * a test build's entry file is named claudebridge-<version>.lua and its version must equal the version in the
--     version module; on a mismatch the bridge refuses to start and prints one console line naming both versions;
--   * a plain claudebridge.lua is a release entry and requires that the module's version is not a test build;
--   * the entry learns its own name from debug.getinfo(1, "S").source, which is "@" plus the full path;
--   * DL-021 design item 20's rule that our own messages are ASCII by construction (a file name is external text).
-- Versions follow SemVer with -test.N pre-release identifiers (Protocol §9).
local T = require 'harness.t'
local test, expect = T.test, T.expect

local BS = string.char(92)
local version = require 'claudebridge.version'

-- How the source string looks for a file run from the MacroQuest lua folder.
local function entry(name)
  return '@C:' .. BS .. 'Users' .. BS .. 'Public' .. BS .. 'MacroQuest' .. BS .. 'lua' .. BS .. name
end
local function printable_ascii(s) return not s:find('[^\32-\126]') end

test('a test build entry whose filename version matches the module version is allowed to start', function()
  local ok, msg = version.check_identity(entry('claudebridge-0.1.0-test.1.lua'), '0.1.0-test.1')
  expect.truthy(ok)
  expect.equal(msg, nil)
end)

test('the same check works for a forward-slash path', function()
  local ok = version.check_identity('@C:/Users/Public/MacroQuest/lua/claudebridge-0.1.0-test.1.lua', '0.1.0-test.1')
  expect.truthy(ok)
end)

test('a filename version that differs from the module version refuses and names both versions', function()
  local ok, msg = version.check_identity(entry('claudebridge-0.1.0-test.2.lua'), '0.1.0-test.1')
  expect.falsy(ok)
  T.assert_contains(msg, 'claudebridge refused to start')
  T.assert_contains(msg, '0.1.0-test.2')
  T.assert_contains(msg, '0.1.0-test.1')
end)

test('a plain claudebridge.lua is allowed only for a release (non-test) module version', function()
  local ok = version.check_identity(entry('claudebridge.lua'), '0.1.0')
  expect.truthy(ok)
end)

test('a plain claudebridge.lua with a test-build module version refuses and names the version', function()
  local ok, msg = version.check_identity(entry('claudebridge.lua'), '0.1.0-test.1')
  expect.falsy(ok)
  T.assert_contains(msg, 'claudebridge refused to start')
  T.assert_contains(msg, '0.1.0-test.1')
end)

test('an entry file name that is neither claudebridge.lua nor claudebridge-<version>.lua refuses', function()
  for _, name in ipairs({ 'other.lua', 'claudebridge-.lua', 'claudebridge.lua.bak', 'claudebridge_0.1.0-test.1.lua' }) do
    local ok, msg = version.check_identity(entry(name), '0.1.0-test.1')
    expect.falsy(ok, name)
    T.assert_contains(msg, 'claudebridge refused to start')
    T.assert_contains(msg, name)
  end
end)

test('a source that is not a file path (a chunk loaded from a string) refuses', function()
  local ok, msg = version.check_identity('=(load)', '0.1.0-test.1')
  expect.falsy(ok)
  T.assert_contains(msg, 'claudebridge refused to start')
end)

test('the refusal message is printable ASCII even when the file name holds non-ASCII or control bytes', function()
  local odd_version = entry('claudebridge-0.1.0-' .. string.char(0xC3, 0xA9) .. '.lua')
  local odd_name = entry('cl' .. string.char(1, 0xFF) .. '.lua')
  for _, source in ipairs({ odd_version, odd_name }) do
    local ok, msg = version.check_identity(source, '0.1.0-test.1')
    expect.falsy(ok)
    expect.truthy(printable_ascii(msg), 'message is not printable ASCII: ' .. msg)
    expect.falsy(msg:find(string.char(0xC3), 1, true))
    expect.falsy(msg:find(string.char(0xFF), 1, true))
  end
end)

test('is_test is true only for a well-formed X.Y.Z-test.N version', function()
  expect.truthy(version.is_test('0.1.0-test.4'))
  expect.truthy(version.is_test('12.0.3-test.0'))
  expect.falsy(version.is_test('0.1.0'))
  expect.falsy(version.is_test('1.0.0-rc.1'))
end)

test('malformed -test. lookalikes are not test versions and are not release versions either', function()
  -- Protocol section 9 (SemVer, -test.N for test builds); found in the second reviewer's read of step 1.
  for _, v in ipairs({ '0.1.0-test.foo', '0.1.0-test.1-extra', 'x-test.y', '0.1.0-test.', '0.1.0-test', '0.1.0-test.01',
                       '01.1.0-test.1', '0.1.0-TEST.1', '0.1.0-test.1.2', '-test.1', '0.1-test.1', '', '0.1.0-rc.1' }) do
    expect.falsy(version.is_test(v), 'is_test accepted ' .. v)
    expect.equal(version.classify(v), nil, 'classify accepted ' .. v)
  end
end)

test('a version containing non-ASCII digit bytes is rejected (ASCII 0-9 only)', function()
  -- Parallel to the Python test. Bytes: 0xB2 (superscript two in code page 1252), 0xD9 0xA1 (an Arabic-Indic one in UTF-8).
  -- On this machine Lua's %d matches only ASCII 0-9 in every locale tried, so this documents the contract; the
  -- locale-independence itself comes from the source using [0-9].
  for _, v in ipairs({ '0.1.0-test.' .. string.char(0xB2), '0.1.0-test.1' .. string.char(0xB9),
                       string.char(0xD9, 0xA1) .. '.1.0', '0.' .. string.char(0xD9, 0xA1) .. '.0-test.1',
                       '0.1.0-test.' .. string.char(0xD9, 0xA1) }) do
    expect.equal(version.classify(v), nil, 'classify accepted a version with non-ASCII digit bytes')
    expect.falsy(version.is_test(v))
  end
end)

test('classify returns release for X.Y.Z and test for X.Y.Z-test.N, with SemVer numeric identifiers', function()
  expect.equal(version.classify('0.1.0'), 'release')
  expect.equal(version.classify('10.20.30'), 'release')
  expect.equal(version.classify('0.1.0-test.7'), 'test')
  expect.equal(version.classify('01.2.3'), nil)      -- a leading zero is not a SemVer numeric identifier
  expect.equal(version.classify(nil), nil)
  expect.equal(version.classify(5), nil)
end)

test('a malformed module version is refused, so it cannot slip through the plain-entry rule as a release', function()
  -- Without this, tightening is_test alone would classify 0.1.0-test.potato as a release and accept claudebridge.lua.
  for _, v in ipairs({ '0.1.0-test.potato', '0.1.0-test.1-extra', 'v1' }) do
    for _, name in ipairs({ 'claudebridge.lua', 'claudebridge-' .. v .. '.lua' }) do
      local ok, msg = version.check_identity(entry(name), v)
      expect.falsy(ok, name .. ' with module version ' .. v)
      T.assert_contains(msg, 'claudebridge refused to start')
      T.assert_contains(msg, v)
    end
  end
end)

test('the version module holds a well-formed value: SemVer, with -test.N for test builds', function()
  expect.truthy(version.classify(version.VERSION), 'VERSION is not X.Y.Z or X.Y.Z-test.N: ' .. tostring(version.VERSION))
end)
