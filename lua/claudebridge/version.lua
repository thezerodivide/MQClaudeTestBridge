-- The single authoritative version value for the bridge, and the startup identity check (DL-021 design items 21 and 20).
-- The entry script passes its own source string (debug.getinfo(1, "S").source, which is "@" plus the full path) and this
-- module's VERSION to check_identity. Pure: no MacroQuest calls, no file access.
local M = { VERSION = '0.1.0-test.1' }

-- A SemVer numeric identifier: ASCII digits only, and no leading zero unless the value is 0. ([0-9], not %d, so the
-- guarantee does not depend on the C library's idea of a digit or on the locale.)
local function numeric_id(s)
    return s:match('^[0-9]+$') ~= nil and (s == '0' or s:sub(1, 1) ~= '0')
end

-- The only two accepted forms (Protocol section 9): 'release' for X.Y.Z and 'test' for X.Y.Z-test.N, with SemVer numeric
-- identifiers. Anything else (a malformed lookalike such as 0.1.0-test.foo, another pre-release, a leading zero) is nil.
function M.classify(v)
    if type(v) ~= 'string' then return nil end
    local core, n = v:match('^([^-]+)%-test%.(.+)$')
    local a, b, c = (core or v):match('^([0-9]+)%.([0-9]+)%.([0-9]+)$')
    if not (a and numeric_id(a) and numeric_id(b) and numeric_id(c)) then return nil end
    if core then
        if numeric_id(n) then return 'test' end
        return nil
    end
    return 'release'
end

-- True only for a well-formed X.Y.Z-test.N version.
function M.is_test(v)
    return M.classify(v or M.VERSION) == 'test'
end

-- Renders external text (a file name) for a message: printable ASCII is kept, every other byte becomes \xNN, so the
-- message is printable ASCII by construction (DL-021 design item 20).
local function sanitize(s)
    return (tostring(s):gsub('[^\32-\126]', function(c) return string.format('\\x%02x', c:byte()) end))
end

local PREFIX = 'claudebridge refused to start: '

-- Returns true, or false and a one-line message. The module version must be a well-formed release or test version. A
-- file named claudebridge-<version>.lua must match `version`; a plain claudebridge.lua is a release entry and requires
-- that `version` is not a test build.
function M.check_identity(source, version)
    local kind = M.classify(version)
    if not kind then
        return false, PREFIX .. 'the module version [' .. sanitize(version) ..
            '] is neither a release version (X.Y.Z) nor a test version (X.Y.Z-test.N).'
    end

    local path = type(source) == 'string' and source:match('^@(.+)$')
    if not path then
        return false, PREFIX .. 'the entry script could not learn its own file name (source ' .. sanitize(source) .. ').'
    end
    local name = path:match('([^/\\]*)$')

    if name == 'claudebridge.lua' then
        if kind == 'test' then
            return false, PREFIX .. 'the entry file is claudebridge.lua (a release entry) but the modules are test build ' ..
                sanitize(version) .. '; run claudebridge-' .. sanitize(version) .. '.lua.'
        end
        return true
    end

    local file_version = name:match('^claudebridge%-(.+)%.lua$')
    if file_version then
        if file_version == version then return true end
        return false, PREFIX .. 'the entry file is for version ' .. sanitize(file_version) .. ' but the modules are version ' ..
            sanitize(version) .. '; copy a complete, matching build.'
    end

    return false, PREFIX .. 'the entry file name [' .. sanitize(name) ..
        '] is neither claudebridge.lua nor claudebridge-<version>.lua.'
end

return M
