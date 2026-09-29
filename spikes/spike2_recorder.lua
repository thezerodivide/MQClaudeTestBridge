local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike2_status.txt'
local names = { 'spike2_target', 'spike2_crash' }
local last, seenPids = {}, {}

local function log(msg)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', msg, '\n'); f:close() end
end
local function val(fn)
    local v = fn()
    if v == nil then return '<nil>' end
    return tostring(v)
end
local function describe(s)
    return val(s.Status) .. ' returns=' .. val(s.ReturnCount) .. ' return=' .. val(s.Return)
end

local f = io.open(path, 'w')
if f then f:write('recorder started\n'); f:close() end

while true do
    local pids = tostring(mq.TLO.Lua.PIDs() or '')
    for pid in pids:gmatch('%d+') do seenPids[pid] = true end
    local q = { ['PIDs'] = pids }
    for _, n in ipairs(names) do q['name:' .. n] = describe(mq.TLO.Lua.Script(n)) end
    for pid in pairs(seenPids) do q['pid:' .. pid] = describe(mq.TLO.Lua.Script(pid)) end
    for k, v in pairs(q) do
        if last[k] ~= v then last[k] = v; log(k .. ' = ' .. v) end
    end
    mq.delay(250)
end
