local mq = require('mq')
local path = 'C:\\Users\\Public\\MacroQuest\\Logs\\spike1_events.txt'

-- No print() in the callback: the listener would hear its own output.
mq.event('spike1_all', '#*#', function(line)
    if line:find('SPIKE1', 1, true) then
        local f = io.open(path, 'a')
        if f then f:write(os.date('%H:%M:%S'), ' | ', line, '\n'); f:close() end
    end
end)

local f = io.open(path, 'w')   -- start each run with an empty file
if f then f:write('listener started\n'); f:close() end

while true do
    mq.doevents()
    mq.delay(100)
end