local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike5_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

log('INJECT | script mq.cmd /echo tell')
mq.cmd("/echo Spikefive tells you, 'inv'")
mq.delay(1000)
log('INJECT | script print() tell')
print("Spikefive tells you, 'inv'")
mq.delay(1000)
log('INJECT | script mq.cmd /echo group leave')
mq.cmd('/echo Spikefive has left the group.')
mq.delay(500)
log('INJECT | done')
