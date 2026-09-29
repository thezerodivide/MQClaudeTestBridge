-- Spike 10: how long does a MacroQuest Lua script stop getting execution during zone changes?
-- Observation only: no heartbeat logic, no retries, no file replacement, no ffi, no game action.
-- Time source: mq.gettime() = std::chrono::steady_clock in whole milliseconds (monotonic; 1 ms resolution).
-- Cadence: mq.delay(100), the same shape as the planned bridge poll loop. Every sample is logged with the wall-clock
-- time, the zone and the game state, so each gap can be checked against the zone change that caused it. One run can
-- cover several zone changes: the summary lists every gap over 250 ms in time order and the overall largest.
-- Usage: /lua run spike10_zone_gap [seconds]     (default 600 seconds; the script ends by itself)
local mq = require('mq')
local args = { ... }
local dir = rawget(_G, 'SPIKE10_DIR') or 'C:/Users/Public/MacroQuest/Logs/'
local DURATION_MS = (tonumber(args[1]) or rawget(_G, 'SPIKE10_SECONDS') or 600) * 1000
local GAP_REPORT_MS = 250
local logpath = dir .. 'spike10_log.txt'

local function log(m)
    local f, err = io.open(logpath, 'a')
    if not f then error('log open failed: ' .. tostring(err), 0) end
    assert(f:write(m, '\n')); assert(f:close())
end
local function safe(fn)
    local ok, v = pcall(fn)
    if not ok then return 'ERR' end
    if v == nil then return 'nil' end
    return tostring(v)
end
local function zone() return safe(function() return mq.TLO.Zone.ShortName() end) end
local function state() return safe(function() return mq.TLO.EverQuest.GameState() end) end

local f0, e0 = io.open(logpath, 'w')
if not f0 then error('cannot open the log for writing: ' .. tostring(e0), 0) end
assert(f0:write('spike10 start\n')); assert(f0:close())

local function main()
    log('time source: mq.gettime(), steady_clock, whole milliseconds, monotonic | cadence: mq.delay(100) | duration ' ..
        (DURATION_MS / 1000) .. ' s')
    log('wall clock at start: ' .. os.date('%Y-%m-%d %H:%M:%S'))
    local t0 = mq.gettime()
    local prev = t0
    local samples = {}
    log('columns: t = ms since start, dt = ms since the previous sample, wall = clock time, zone, EverQuest.GameState')
    while true do
        mq.delay(100)
        local now = mq.gettime()
        local dt = now - prev
        prev = now
        local z, s = zone(), state()
        samples[#samples + 1] = { t = now - t0, dt = dt, wall = os.date('%H:%M:%S'), zone = z, state = s }
        log(string.format('t=%d dt=%d wall=%s zone=%s state=%s', now - t0, dt, samples[#samples].wall, z, s))
        if now - t0 >= DURATION_MS then break end
    end

    -- Summary: every gap over the report threshold in time order, each with the zone and state on both sides.
    local largest, over1000 = 0, 0
    for _, smp in ipairs(samples) do
        if smp.dt > largest then largest = smp.dt end
        if smp.dt > 1000 then over1000 = over1000 + 1 end
    end
    log(string.format('SUMMARY samples=%d largest_dt_ms=%d samples_over_1000ms=%d', #samples, largest, over1000))
    log('gaps over ' .. GAP_REPORT_MS .. ' ms, in time order:')
    local listed = 0
    for i, smp in ipairs(samples) do
        if smp.dt > GAP_REPORT_MS then
            listed = listed + 1
            local before = samples[i - 1]
            log(string.format('  dt=%d ms, ending at t=%d (wall %s) | before: zone=%s state=%s | after: zone=%s state=%s',
                smp.dt, smp.t, smp.wall, before and before.zone or 'start', before and before.state or 'start',
                smp.zone, smp.state))
        end
    end
    if listed == 0 then log('  none') end
end

local ran_ok, run_err = pcall(main)
if not ran_ok then pcall(log, 'ERROR: ' .. tostring(run_err)) end
pcall(log, 'spike10 end')
