local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3b_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

log('SCRIPT | crash_event start')
mq.event('spike3b_evt', '#*#SPIKE3B-TRIGGER#*#', function()
    log('SCRIPT | crash_event handler running')
    error('SPIKE3B event handler error')
end)
for i = 1, 8 do
    mq.delay(500)
    mq.doevents()
    log('SCRIPT | crash_event tick ' .. i)
end
log('SCRIPT | crash_event end')
