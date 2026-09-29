local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike3_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | runner | ', m, '\n'); f:close() end
end

local args = { ... }
local name = args[1]
SPIKE3_MODE = 'runner'
log('runner start, target = ' .. tostring(name))

local chunk, err = loadfile('C:/Users/Public/MacroQuest/lua/' .. tostring(name) .. '.lua')
if not chunk then
    log('loadfile failed: ' .. tostring(err))
    return
end

local ok, res = xpcall(chunk, debug.traceback)
if ok then
    log('target returned normally: ' .. tostring(res))
else
    log('target error caught: ' .. tostring(res))
end
log('runner end')
