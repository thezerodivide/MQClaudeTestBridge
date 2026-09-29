local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3b_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

log('SCRIPT | crash_bind start')
mq.bind('/spike3bbind', function()
    log('SCRIPT | crash_bind handler running')
    error('SPIKE3B bind handler error')
end)
for i = 1, 8 do
    mq.delay(500)
    log('SCRIPT | crash_bind tick ' .. i)
end
log('SCRIPT | crash_bind end')
