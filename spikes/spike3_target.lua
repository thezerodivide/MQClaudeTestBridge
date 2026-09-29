local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3_log.txt'
local mode = tostring(rawget(_G, 'SPIKE3_MODE') or 'direct')
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', mode, ' | ', m, '\n'); f:close() end
end

mq.event('spike3_ping', '#*#SPIKE3-PING#*#', function() log('event fired') end)
log('target start')
for i = 1, 6 do
    mq.delay(500)
    mq.doevents()
    log('tick ' .. i)
end
log('target end')
return 'spike3-return'
