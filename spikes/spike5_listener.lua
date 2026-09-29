local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike5_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

-- Same patterns and callback shape as lua/autoinv.lua (registerEvents, onTell, onGroupLeave).
mq.event('S5_Tell', "#1# tells you, '#2#'", function(line, sender, body)
    log('TELL EVENT | line=[' .. tostring(line) .. '] sender=[' .. tostring(sender) .. '] body=[' .. tostring(body) .. ']')
end)
mq.event('S5_GroupLeave', "#1# has left the group.", function(line, player)
    log('LEAVE EVENT | line=[' .. tostring(line) .. '] player=[' .. tostring(player) .. ']')
end)

-- Raw lines that reached the listener at all, so a missed pattern can be told apart from a missed line.
-- No print() in any callback: the listener would hear its own output.
mq.event('S5_Raw', '#*#', function(line)
    if line:lower():find('spikefive', 1, true) then log('RAW CHAT | ' .. line) end
end)

local f = io.open(path, 'w')
if f then f:write('listener started\n'); f:close() end

while true do
    mq.doevents()
    mq.delay(100)
end
