-- claudebridge: the entry script (DL-021 design item 2; DL-022 step 5, decisions 13 to 17). Run with `/lua run claudebridge` (a test build runs as claudebridge-<version>.lua).
-- It holds only the MacroQuest adapter construction and the outer run loop; every rule lives in the modules under claudebridge/ and is tested there. It is
-- tested as a whole, under a fake mq, ffi and lfs, by test/entry_test.lua (decision 13, option C).
--
-- Startup order (decisions 8 and 13; nothing that can write comes before step 7):
--   1. protected require('ffi')                          2. ffi.os == 'Windows' and ffi.arch == 'x86'     3. protected require('claudebridge.winreplace')
--   4. protected require('lfs')                          5. the source and version identity check          6. the bridge folder from ${MacroQuest.Path[root]}
--   7. fsadapter.new, then adapter.prepare(root), the first operation that can write                       8. store, loop, the listener (decision 14), loop:start
-- Console output (decision 16): every refusal prints once and the script returns; a fatal state at run time prints once when the loop stops.
local mq = require('mq')

local POLL_DELAY_MS = 100        -- decision 15: a delay after each completed iteration, not a start-to-start period
local REFUSED = 'claudebridge refused to start: '
local STOPPED = 'claudebridge stopped: '

-- Renders external text for one console line: printable ASCII is kept, every other byte becomes \xNN (the rule of version.lua and design item 20, applied
-- here to operator diagnostics; a local copy, decision 16).
local function sanitize(s)
    return (tostring(s):gsub('[^\32-\126]', function(c) return string.format('\\x%02x', c:byte()) end))
end

local function suffix(detail)
    if detail == nil then return '' end
    return ' (' .. sanitize(detail) .. ')'
end

local function refuse(reason, detail)
    print(REFUSED .. reason .. suffix(detail))
end

local function load_module(name)
    local ok, module = pcall(require, name)
    if not ok then return nil, module end
    return module
end

-- Decision 17: character() and zone() evaluate the root Me() first (the proxy mq.TLO.Me is not an availability test); both are nil when it is nil.
-- A nil member is nil, a string is returned unchanged, any other type is a real failure (no pcall: the heartbeat skips it and a ping fails loudly).
local function game_string(read, name)
    if mq.TLO.Me() == nil then return nil end
    local value = read()
    if value == nil or type(value) == 'string' then return value end
    error('claudebridge internal error: ' .. name .. ' returned a ' .. type(value) .. ' value', 0)
end

local env = {
    parse = function(expression) return mq.parse(expression) end,
    character = function() return game_string(function() return mq.TLO.Me.CleanName() end, 'character') end,
    zone = function() return game_string(function() return mq.TLO.Zone.ShortName() end, 'zone') end,
}

local function run()
    local ok_ffi, ffi = pcall(require, 'ffi')
    if not ok_ffi then return refuse('ffi is not available', ffi) end
    if ffi.os ~= 'Windows' then
        return refuse('ffi.os is [' .. sanitize(ffi.os) .. ']; the bridge supports only Windows x86')
    end
    if ffi.arch ~= 'x86' then
        return refuse('ffi.arch is [' .. sanitize(ffi.arch) .. ']; the bridge supports only Windows x86')
    end

    local ok_wr, winreplace = pcall(require, 'claudebridge.winreplace')
    if not ok_wr then return refuse('the replace module could not be loaded', winreplace) end
    if type(winreplace) ~= 'table' or type(winreplace.replace) ~= 'function' then
        return refuse('the replace module does not provide replace')
    end

    local ok_lfs, lfs = pcall(require, 'lfs')
    if not ok_lfs then return refuse('the lfs library could not be loaded', lfs) end

    local modules = {}
    for _, name in ipairs({ 'version', 'fsadapter', 'store', 'loop' }) do
        local module, err = load_module('claudebridge.' .. name)
        if not module then return refuse('a bridge module could not be loaded', name .. ': ' .. tostring(err)) end
        modules[name] = module
    end

    local identity_ok, identity_message = modules.version.check_identity(debug.getinfo(1, 'S').source, modules.version.VERSION)
    if not identity_ok then return print(identity_message) end      -- the message already starts with the refusal prefix

    -- An absolute path only: a root that is NULL, empty or relative would put the folders relative to an unknown directory.
    local root = mq.parse('${MacroQuest.Path[root]}')
    if type(root) ~= 'string' or not root:match('^%a:[\\/]') then
        return refuse('the MacroQuest root folder could not be determined', root)
    end
    local dir = root .. '\\claude'

    local adapter = modules.fsadapter.new({ lfs = lfs, io = io, os = os, replace = winreplace.replace })
    local prepared, reason, detail = adapter.prepare(dir)
    if not prepared then return refuse(reason, detail) end

    local store = modules.store.new(adapter, dir)
    local loop = modules.loop.new(store, env)

    -- Decision 14: registered immediately before start, so the first heartbeat cannot precede the listener; nothing is dispatched until doevents.
    mq.event('claudebridge_all', '#*#', function(line) loop:on_event(line, os.time()) end)

    local started, start_reason, start_detail = loop:start(os.time(), mq.gettime())
    if not started then return refuse(start_reason, start_detail) end
    print('claudebridge ' .. modules.version.VERSION .. ' started')

    -- Decision 15: the sticky failure is checked at the loop boundary and after each stage; the delay is never called once the loop has stopped.
    while not loop:failure() do
        mq.doevents()
        if loop:failure() then break end
        loop:step(os.time(), mq.gettime())
        if loop:failure() then break end
        mq.delay(POLL_DELAY_MS)
    end
    local failure = loop:failure()
    print(STOPPED .. failure.reason .. suffix(failure.detail))
end

run()
