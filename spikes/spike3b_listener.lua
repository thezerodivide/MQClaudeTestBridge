local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3b_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

-- Only lines that could belong to a Lua error are kept, so game chatter stays out of the log.
local function wanted(line)
    local l = line:lower()
    return l:find('spike3b', 1, true) or l:find('stack traceback', 1, true)
        or l:find('in function', 1, true) or l:find('in main chunk', 1, true)
end

-- No print() in the callback: the listener would hear its own output.
mq.event('spike3b_all', '#*#', function(line)
    if wanted(line) then log('CHAT | ' .. line) end
end)

local f = io.open(path, 'w')
if f then f:write('listener started\n'); f:close() end

local names = { 'spike3b_crash_main', 'spike3b_crash_event', 'spike3b_crash_bind' }
local last = {}
while true do
    mq.doevents()
    for _, n in ipairs(names) do
        local v = mq.TLO.Lua.Script(n).Status()
        v = (v == nil) and '<nil>' or tostring(v)
        if last[n] ~= v then last[n] = v; log('STATUS | ' .. n .. ' = ' .. v) end
    end
    mq.delay(100)
end
