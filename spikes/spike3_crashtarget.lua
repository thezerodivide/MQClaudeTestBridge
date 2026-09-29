local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3_log.txt'
local mode = tostring(rawget(_G, 'SPIKE3_MODE') or 'direct')
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', mode, ' | ', m, '\n'); f:close() end
end

log('crashtarget start')
mq.delay(500)
log('about to error')
error('SPIKE3 deliberate error after a delay')
