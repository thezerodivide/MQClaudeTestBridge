-- Spike 9 (writer, runs in MacroQuest): replace a test heartbeat file thousands of times with MoveFileExA
-- (the call proven safe in spike 8 step (c)) while spike9_reader.py reads it in a loop.
-- Each generation g writes: {"generation":g,"length":L,"check":C,"payload":"<L copies of one letter>"} where L, C and the
-- letter are all derived from g, so a reader can tell a complete published generation from any torn or mixed content.
-- The writer only counts attempted, successful and failed replacements (failures by Windows error code); whether any
-- READ was torn is decided by the reader, not here.
-- Safety: log() fails closed (as in spike 8 step (c)); a breadcrumb is written before every batch of calls.
local mq = require('mq')
local dir = rawget(_G, 'SPIKE9_DIR') or 'C:/Users/Public/MacroQuest/Logs/'
local N = rawget(_G, 'SPIKE9_N') or 6000        -- generations to publish
local PER_PULSE = 20                            -- replacements per game pulse, so the client is never blocked for long
local hb, tmp = dir .. 'spike9_hb.json', dir .. 'spike9_hb.tmp'
local logpath = dir .. 'spike9_writer_log.txt'

local function log(m)
    local f, err = io.open(logpath, 'a')
    if not f then error('log open failed: ' .. tostring(err), 0) end
    local wok, werr = f:write(os.date('%H:%M:%S'), ' | ', m, '\n')
    if not wok then f:close(); error('log write failed: ' .. tostring(werr), 0) end
    local cok, cerr = f:close()
    if not cok then error('log close failed: ' .. tostring(cerr), 0) end
end
local function write(p, s) local f = assert(io.open(p, 'wb')); assert(f:write(s)); assert(f:close()) end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end
local BS = string.char(92)
local function native(p) return (p:gsub('/', BS)) end

-- Everything about a generation is derived from g (the reader recomputes the same formulas).
local function content(g)
    local L = 100 + (g * 37) % 400
    local ch = string.char(97 + g % 26)
    local check = (g * 7919 + L) % 1000003
    local final = (g == N) and ',"final":true' or ''
    return '{"generation":' .. g .. ',"length":' .. L .. ',"check":' .. check .. final ..
        ',"payload":"' .. ch:rep(L) .. '"}'
end

local f0, e0 = io.open(logpath, 'w')
if not f0 then error('cannot open the log for writing: ' .. tostring(e0), 0) end
assert(f0:write('spike9 writer start, N=' .. N .. '\n')); assert(f0:close())

local function main()
    local ok_ffi, ffi = pcall(require, 'ffi')
    if not ok_ffi then log('ABORT: require ffi failed: ' .. tostring(ffi)); return end
    log('ffi.arch = ' .. tostring(ffi.arch) .. ', ffi.os = ' .. tostring(ffi.os))
    if ffi.os ~= 'Windows' then log('ABORT: ffi.os is not Windows'); return end

    ffi.cdef[[
int __stdcall MoveFileExA(const char* lpExistingFileName, const char* lpNewFileName, unsigned long dwFlags);
unsigned long __stdcall GetLastError(void);
]]
    local MOVEFILE_REPLACE_EXISTING = 0x1
    local MoveFileExA = ffi.C.MoveFileExA
    local GetLastError = ffi.C.GetLastError
    log('symbols bound: MoveFileExA and GetLastError')

    for _, p in ipairs({ hb, tmp }) do os.remove(p) end
    if exists(hb) or exists(tmp) then
        log('ABORT: a stale test file could not be removed; no Windows call was made'); return
    end

    local attempts, succeeded, last_published = 0, 0, 0
    local failures_by_code = {}

    -- One publication attempt for generation g: write the temp file completely, then replace the target.
    local function publish(g)
        write(tmp, content(g))
        attempts = attempts + 1
        local ok = MoveFileExA(native(tmp), native(hb), MOVEFILE_REPLACE_EXISTING)
        if ok ~= 0 then
            succeeded = succeeded + 1
            last_published = g
            return true
        end
        local code = tonumber(GetLastError())
        failures_by_code[code] = (failures_by_code[code] or 0) + 1
        return false
    end

    local g = 1
    while g <= N do
        local last_in_batch = math.min(g + PER_PULSE - 1, N)
        log('about to run generations ' .. g .. '..' .. last_in_batch .. ' (attempts so far ' .. attempts ..
            ', succeeded ' .. succeeded .. ')')                     -- fails closed: an error here stops the script first
        for gen = g, last_in_batch do publish(gen) end
        g = last_in_batch + 1
        mq.delay(1)                                                  -- yield to the game between batches
    end

    -- The reader stops when it sees the final generation, so make sure the final one is published.
    local tries = 0
    while last_published ~= N and tries < 300 do
        tries = tries + 1
        log('final generation ' .. N .. ' not yet published; retry ' .. tries)
        publish(N)
        mq.delay(1)
    end

    local parts = {}
    for code, n in pairs(failures_by_code) do parts[#parts + 1] = 'GetLastError ' .. code .. ' x' .. n end
    table.sort(parts)
    log('SUMMARY attempts=' .. attempts .. ' succeeded=' .. succeeded .. ' failed=' .. (attempts - succeeded) ..
        ' last_published=' .. last_published .. ' final_published=' .. tostring(last_published == N) ..
        ' | failures: ' .. (#parts > 0 and table.concat(parts, ', ') or 'none'))
end

local ran_ok, run_err = pcall(main)
if not ran_ok then pcall(log, 'ERROR: ' .. tostring(run_err)) end
os.remove(tmp)
pcall(log, 'spike9 writer end')
