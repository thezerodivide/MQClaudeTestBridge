local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3b_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

log('SCRIPT | crash_main start')
mq.delay(500)
log('SCRIPT | crash_main about to error')
error('SPIKE3B main chunk error')
