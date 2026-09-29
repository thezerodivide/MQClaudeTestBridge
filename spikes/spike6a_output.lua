-- Spike 6a: what does mq.parse return when the evaluated OUTPUT reaches its 2048-byte buffer?
-- The input stays short. Ascending sizes; stops at the first abnormal result.
local mq = require('mq')
local path = 'C:/Users/Public/MacroQuest/Logs/spike6a_log.txt'
local function log(m)
    local f = io.open(path, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end

local f = io.open(path, 'w')
if f then f:write('spike6a start\n'); f:close() end

local small = mq.parse('hello')
log('baseline parse("hello") -> [' .. tostring(small) .. ']')

local zone = mq.parse('${Zone.Name}')
local L = #zone
log('Zone.Name = [' .. zone .. '] length ' .. L)
if L < 14 or zone == 'NULL' then
    log('cannot build: zone name too short (or NULL) to expand past 2048 bytes from an input under 2048')
    return
end

local unit = '${Zone.Name}'
for _, T in ipairs({ 1000, 2000, 2046, 2047, 2048, 2049, 2100, 2500 }) do
    local n = math.floor(T / L)
    local pad = T - n * L
    local expr = unit:rep(n) .. ('x'):rep(pad)
    local expected = zone:rep(n) .. ('x'):rep(pad)
    if #expr >= 2048 then
        log('CASE out T=' .. T .. ' skipped: input length ' .. #expr .. ' would reach the input limit')
        break
    end
    log('CASE out T=' .. T .. ' about to parse, input length ' .. #expr .. ', expected output length ' .. #expected)
    local ok, res = pcall(mq.parse, expr)
    if not ok then
        log('CASE out T=' .. T .. ' ABNORMAL: Lua error: ' .. tostring(res))
        break
    end
    res = tostring(res)
    if res ~= expected then
        local diff = 0
        for i = 1, math.max(#res, #expected) do
            if res:sub(i, i) ~= expected:sub(i, i) then diff = i; break end
        end
        log('CASE out T=' .. T .. ' ABNORMAL: returned length ' .. #res .. ', first difference at byte ' .. diff .. ', tail=[' .. res:sub(-20) .. ']')
        break
    end
    log('CASE out T=' .. T .. ' normal: returned length ' .. #res .. ', identical to expected')
end
log('spike6a end')
