-- Spike 6b: what does mq.parse do with an INPUT expression at and past its 2048-byte buffer?
-- Plain text 'A' repeated. Ascending sizes; stops at the first abnormal result.
local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike6b_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

local f = io.open(path, 'w')
if f then f:write('spike6b start\n'); f:close() end

for _, N in ipairs({ 2000, 2046, 2047, 2048, 2049, 3000 }) do
    local expr = ('A'):rep(N)
    log('CASE in N=' .. N .. ' about to parse, input length ' .. #expr)
    local ok, res = pcall(mq.parse, expr)
    if not ok then
        log('CASE in N=' .. N .. ' ABNORMAL: Lua error: ' .. tostring(res))
        break
    end
    res = tostring(res)
    if res ~= expr then
        local diff = 0
        for i = 1, math.max(#res, #expr) do
            if res:sub(i, i) ~= expr:sub(i, i) then diff = i; break end
        end
        log('CASE in N=' .. N .. ' ABNORMAL: returned length ' .. #res .. ', first difference at byte ' .. diff)
        break
    end
    log('CASE in N=' .. N .. ' normal: returned length ' .. #res .. ', identical to input')
end
log('spike6b end')
