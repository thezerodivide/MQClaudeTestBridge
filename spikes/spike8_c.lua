-- Spike 8, step (c): can MoveFileExA with MOVEFILE_REPLACE_EXISTING replace a file from inside MacroQuest's Lua?
-- The EQ client is 32-bit (ffi.arch = x86 was observed), so the calling convention is declared explicitly (__stdcall).
-- Safety procedure: every risky call is preceded by a log line, and log() FAILS CLOSED: if the log cannot be opened,
-- written or closed, log() raises an error, so no ffi call can follow a breadcrumb that was not recorded.
-- Each later case runs only if the previous case left the state its label describes; otherwise the spike ends.
local dir = rawget(_G, 'SPIKE8_DIR') or 'C:/Users/Public/MacroQuest/Logs/'
local logpath = dir .. 'spike8c_log.txt'

local function log(m)
    local f, err = io.open(logpath, 'a')
    if not f then error('log open failed: ' .. tostring(err), 0) end
    local wok, werr = f:write(os.date('%H:%M:%S'), ' | ', m, '\n')
    if not wok then f:close(); error('log write failed: ' .. tostring(werr), 0) end
    local cok, cerr = f:close()
    if not cok then error('log close failed: ' .. tostring(cerr), 0) end
end
local function write(p, s) local f = assert(io.open(p, 'wb')); assert(f:write(s)); assert(f:close()) end
local function read(p)
    local f = io.open(p, 'rb'); if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end
local BS = string.char(92)
local function native(p) return (p:gsub('/', BS)) end

local f0, e0 = io.open(logpath, 'w')
if not f0 then error('cannot open the log for writing: ' .. tostring(e0), 0) end
assert(f0:write('spike8 (c) start\n')); assert(f0:close())

local tmp, dst = dir .. 'spike8_n.tmp', dir .. 'spike8_n.dat'

local function main()
    local ok_ffi, ffi = pcall(require, 'ffi')
    if not ok_ffi then log('ABORT: require ffi failed: ' .. tostring(ffi)); return end
    log('ffi.arch = ' .. tostring(ffi.arch) .. ', ffi.os = ' .. tostring(ffi.os))
    if ffi.os ~= 'Windows' then log('ABORT: ffi.os is not Windows'); return end

    -- Both functions are in kernel32 and use the __stdcall convention. ffi.C resolves them on Windows.
    ffi.cdef[[
int __stdcall MoveFileExA(const char* lpExistingFileName, const char* lpNewFileName, unsigned long dwFlags);
unsigned long __stdcall GetLastError(void);
]]
    local MOVEFILE_REPLACE_EXISTING = 0x1

    -- Bind both symbols BEFORE the first Windows call, so no symbol lookup can happen between a failing call and the
    -- GetLastError read (Windows says to read the last error immediately after the failing function).
    local MoveFileExA = ffi.C.MoveFileExA
    local GetLastError = ffi.C.GetLastError
    log('symbols bound: MoveFileExA and GetLastError')

    local function replace(label, src, dstp)
        log(label .. ': about to call MoveFileExA')          -- fails closed: an error here stops the script first
        local ok = MoveFileExA(native(src), native(dstp), MOVEFILE_REPLACE_EXISTING)
        -- GetLastError is authoritative for this Win32 call and is read only on failure. A dry run showed ffi.errno()
        -- alone gave 2 (file not found) for a sharing conflict, so it is logged only as a secondary value.
        local win_err
        if ok == 0 then win_err = tonumber(GetLastError()) end
        local ffi_err = ffi.errno()
        log(label .. ': returned ' .. tostring(ok) .. (ok ~= 0 and ' (success)' or
            (' (failure, GetLastError ' .. tostring(win_err) .. ', ffi.errno ' .. tostring(ffi_err) .. ')')))
        return ok ~= 0
    end

    -- Precondition for (c1): both test files must be verifiably absent.
    for _, p in ipairs({ tmp, dst }) do os.remove(p) end
    if exists(tmp) or exists(dst) then
        log('ABORT before (c1): a stale test file could not be removed; no Windows call was made'); return
    end

    -- (c1) destination does not exist
    write(tmp, 'new')
    local ok1 = replace('(c1) replace, destination does not exist', tmp, dst)
    local d1, t1 = read(dst), exists(tmp)
    log('     destination now holds: ' .. tostring(d1) .. ' | temp exists: ' .. tostring(t1))
    if not (ok1 and d1 == 'new' and not t1) then
        log('ABORT after (c1): result was not the expected one; (c2) and (c3) were not run'); return
    end

    -- (c2) destination exists, nothing holds it open: the heartbeat case
    write(tmp, 'newer')
    local ok2 = replace('(c2) replace, destination exists and is not held open', tmp, dst)
    local d2, t2 = read(dst), exists(tmp)
    log('     destination now holds: ' .. tostring(d2) .. ' | temp exists: ' .. tostring(t2))
    if not (ok2 and d2 == 'newer' and not t2) then
        log('ABORT after (c2): result was not the expected one; (c3) was not run'); return
    end

    -- (c3) destination exists and this script holds it open (an ordinary read handle, as a reader would)
    write(tmp, 'newest')
    local held = io.open(dst, 'rb')
    if not held then log('ABORT before (c3): the destination could not be opened, so it would not be held open; no call made'); return end
    replace('(c3) replace, destination held open by this script', tmp, dst)
    held:close()
    log('     destination now holds: ' .. tostring(read(dst)) .. ' | temp exists: ' .. tostring(exists(tmp)))
end

local ran_ok, run_err = pcall(main)
if not ran_ok then pcall(log, 'ERROR: ' .. tostring(run_err)) end
for _, p in ipairs({ tmp, dst }) do os.remove(p) end
pcall(log, 'spike8 (c) end')
