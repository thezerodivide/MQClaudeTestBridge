-- Spike 11: can the bridge list a folder from MacroQuest's Lua, and what does it cost?
-- Read-only observation. No ffi, no writes except this spike's own log in the MacroQuest Logs folder, no game action,
-- no other script or file touched (the only os.* call is os.date(), read-only, for the log's wall-clock line). It answers
-- three questions and commits the project to nothing:
--   (1) does require('lfs') work inside MacroQuest on this machine (lfs is not bundled; it is a luarock)?
--   (2) does the exact command the bridge would use, `dir /b /a-d "<folder>\*"` through io.popen, return the file names,
--       including for a folder whose path contains a space (quoting), and what does the popen handle report on close?
--   (3) how long does one such call take on the wall clock, as a total and a worst call (not only an average), when
--       calls are made with a 100 ms delay between completed calls, and does it stretch the loop? That loop shape (a
--       step, then mq.delay(100)) is a PLANNED implementation choice for the bridge's poll loop, which does not exist
--       yet; spike 10 measured a loop of this shape, but nothing here proves what the future implementation will do.
-- Two modes, so the first look is one call that a person can watch for a console window flashing or a stall:
--   /lua run spike11_listing one           each target once (popen, and lfs if it loaded); prints what to watch for
--   /lua run spike11_listing run [secs]    popen listing, a 100 ms delay between completed calls, for secs seconds
--                                          (default 60, at most 300); so it makes fewer calls than a 100 ms start-to-start poll
-- Suggested live order: 'one' first, read its log and what was seen on screen; then 'run 5'; only then anything longer.
-- After any call that takes 3000 ms or more RETURNS, the run stops and says so in the log. This does NOT interrupt a call
-- that blocks: the check happens only after io.popen, the read loop and p:close() have returned, so a call that never
-- returns would freeze the client with nothing here to stop it. That is what the single-call 'one' mode, watched by a
-- person, is for.
-- Observation of a console window flashing cannot be measured by the script: the person running it reports it.
-- Time source: mq.gettime() = std::chrono::steady_clock in whole milliseconds (as in spike 10).
local mq = require('mq')
local args = { ... }
local mode = args[1] or 'one'
if mode ~= 'one' and mode ~= 'run' then
    error("spike11: unknown mode '" .. tostring(mode) .. "' (use 'one' or 'run [seconds]')", 0)
end

local logdir = rawget(_G, 'SPIKE11_LOGDIR') or 'C:\\Users\\Public\\MacroQuest\\Logs'
local logpath = logdir .. '\\spike11_' .. mode .. '_log.txt'
-- Read-only listing targets (each is only listed, never written):
--   the Logs folder (files from earlier spikes, so a realistic non-empty listing), and a folder whose path has a space in
--   it, to test the quoting.
local targets = rawget(_G, 'SPIKE11_TARGETS') or {
    { label = 'logs folder', dir = logdir },
    { label = 'folder with a space in its path', dir = 'C:\\Program Files' },
}
local RUN_SECONDS = math.min(300, tonumber(args[2]) or 60)
local DELAY_MS = 100   -- the delay between completed calls (not a start-to-start period)
local STALL_ABORT_MS = 3000

local function log(m)
    local f, err = io.open(logpath, 'a')
    if not f then error('spike11: cannot open the log: ' .. tostring(err), 0) end
    assert(f:write(m, '\n')); assert(f:close())
end
do
    local f, err = io.open(logpath, 'w')
    if not f then error('spike11: cannot open the log for writing: ' .. tostring(err), 0) end
    assert(f:write('spike11 start, mode ', mode, '\n')); assert(f:close())
end

-- The command the bridge would use: files only, bare names, the folder quoted, errors silenced.
local function listing_command(dir)
    return 'dir /b /a-d "' .. dir .. '\\*" 2>NUL'
end

-- Lists a folder with io.popen. Returns names, info, elapsed_ms; names is nil if popen itself failed.
local function popen_list(dir)
    local t0 = mq.gettime()
    local p, perr = io.popen(listing_command(dir), 'r')
    if not p then return nil, 'popen failed: ' .. tostring(perr), mq.gettime() - t0 end
    local names = {}
    for line in p:lines() do
        line = line:gsub('\r$', '')
        if line ~= '' then names[#names + 1] = line end
    end
    local c1, c2, c3 = p:close()
    return names, 'close returned ' .. tostring(c1) .. ' / ' .. tostring(c2) .. ' / ' .. tostring(c3), mq.gettime() - t0
end

local function lfs_list(lfs, dir)
    local t0 = mq.gettime()
    local names = {}
    local ok, err = pcall(function()
        for name in lfs.dir(dir) do
            if name ~= '.' and name ~= '..' then names[#names + 1] = name end
        end
    end)
    if not ok then return nil, 'lfs.dir failed: ' .. tostring(err), mq.gettime() - t0 end
    return names, 'lfs.dir listed folders and files together', mq.gettime() - t0
end

local function first_names(names)
    local out = {}
    for i = 1, math.min(3, #names) do out[i] = names[i] end
    return table.concat(out, ' | ')
end

local function main()
    log('wall clock at start: ' .. os.date('%Y-%m-%d %H:%M:%S'))
    log('time source: mq.gettime(), steady_clock, whole milliseconds; command form: ' .. listing_command('<folder>'))

    -- (1) lfs
    local lfs_ok, lfs = pcall(require, 'lfs')
    if lfs_ok and type(lfs) == 'table' then
        log('lfs: require("lfs") WORKED; type(lfs.dir) = ' .. type(lfs.dir))
    else
        log('lfs: require("lfs") FAILED: ' .. tostring(lfs):sub(1, 300))
        lfs = nil
    end

    if mode == 'one' then
        print('spike11 one: about to run one popen listing per target. WATCH FOR a console window flashing or the client freezing, and report what you saw.')
        for _, t in ipairs(targets) do
            local names, info, ms = popen_list(t.dir)
            if names then
                log(string.format('popen one call [%s]: %d ms, %d names, first: %s | %s', t.label, ms, #names, first_names(names), info))
            else
                log(string.format('popen one call [%s]: %d ms, FAILED: %s', t.label, ms, info))
            end
            if lfs then
                local lnames, linfo, lms = lfs_list(lfs, t.dir)
                if lnames then
                    log(string.format('lfs one call [%s]: %d ms, %d names (folders included), %s', t.label, lms, #lnames, linfo))
                else
                    log(string.format('lfs one call [%s]: %d ms, FAILED: %s', t.label, lms, linfo))
                end
            end
        end
        log('one-call mode done; the person running it reports whether a console window flashed or the client stalled')
        print('spike11 one: done. Did a console window flash? Did the client stall? Check the log: ' .. logpath)
        return
    end

    -- (3) timing run against the first target (the Logs folder)
    local dir = targets[1].dir
    log(string.format('run: popen listing of [%s], a %d ms delay between completed calls, for %d s (stops after any call that takes %d ms or more has returned; a call that blocks cannot be interrupted)',
        targets[1].label, DELAY_MS, RUN_SECONDS, STALL_ABORT_MS))
    local t_start = mq.gettime()
    local prev_iter_start = nil
    local durations, periods, names_count = {}, {}, nil
    local aborted = false
    while mq.gettime() - t_start < RUN_SECONDS * 1000 do
        local iter_start = mq.gettime()
        if prev_iter_start then periods[#periods + 1] = iter_start - prev_iter_start end
        prev_iter_start = iter_start
        local names, info, ms = popen_list(dir)
        durations[#durations + 1] = ms
        if not names then
            log('run: popen FAILED at call ' .. #durations .. ': ' .. info)
            aborted = true
            break
        end
        names_count = #names
        if ms >= STALL_ABORT_MS then
            log(string.format('run: STALL: call %d took %d ms and has returned; stopping the run', #durations, ms))
            aborted = true
            break
        end
        mq.delay(DELAY_MS)
    end

    local function stats(list)
        if #list == 0 then return 'no samples' end
        local sorted = {}
        local total = 0
        for i, v in ipairs(list) do sorted[i] = v; total = total + v end
        table.sort(sorted)
        local p95 = sorted[math.max(1, math.ceil(#sorted * 0.95))]
        return string.format('n=%d total=%d ms mean=%.1f median=%d p95=%d worst=%d', #list, total, total / #list, sorted[math.ceil(#sorted / 2)], p95, sorted[#sorted])
    end
    log('run: names per listing (last): ' .. tostring(names_count))
    log('run: per-call duration (ms): ' .. stats(durations))
    log('run: period between call starts (ms; about the call plus ' .. DELAY_MS .. ' ms plus scheduling): ' .. stats(periods))
    log('run: ' .. (aborted and 'STOPPED early (see above)' or 'completed the full duration'))
    log('spike11 run end')
    print('spike11 run: done. Log: ' .. logpath)
end

local ok, err = pcall(main)
if not ok then
    pcall(log, 'ERROR: ' .. tostring(err))
    error(err, 0)
end
