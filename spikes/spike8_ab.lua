-- Spike 8, steps (a) and (b): what file-replace tools exist inside MacroQuest's embedded Lua?
-- (a) does require('ffi') work?  (b) how does os.rename / os.remove behave on Windows here?
-- Harmless: no game action, no ffi call is made (only the library is loaded and inspected).
local dir = rawget(_G, 'SPIKE8_DIR') or 'C:/Users/Public/MacroQuest/Logs/'
local logpath = dir .. 'spike8_log.txt'

local function log(m)
    local f = io.open(logpath, 'a')
    if f then f:write(os.date('%H:%M:%S'), ' | ', m, '\n'); f:close() end
end
local function write(p, s)
    local f = assert(io.open(p, 'wb')); f:write(s); f:close()
end
local function read(p)
    local f = io.open(p, 'rb'); if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end
local function show(ok, err, code)
    if ok then return 'ok' end
    return 'FAILED: ' .. tostring(err) .. ' (code ' .. tostring(code) .. ')'
end

local f0 = io.open(logpath, 'w')
if f0 then f0:write('spike8 (a)(b) start\n'); f0:close() end

local a_tmp, b_dat = dir .. 'spike8_a.tmp', dir .. 'spike8_b.dat'
local c_tmp, d_dat = dir .. 'spike8_c.tmp', dir .. 'spike8_d.dat'
for _, p in ipairs({ a_tmp, b_dat, c_tmp, d_dat }) do os.remove(p) end

-- (b1) baseline: rename onto a name that does not exist
write(a_tmp, 'new')
log('(b1) os.rename onto a NEW name: ' .. show(os.rename(a_tmp, b_dat)))
log('     new name now holds: ' .. tostring(read(b_dat)))

-- (b2) rename onto an EXISTING file (the heartbeat case)
write(c_tmp, 'new'); write(d_dat, 'old')
log('(b2) os.rename onto an EXISTING file: ' .. show(os.rename(c_tmp, d_dat)))
log('     destination now holds: ' .. tostring(read(d_dat)) .. ' | temp file still exists: ' .. tostring(read(c_tmp) ~= nil))

-- (b3) remove a file while this script itself holds it open
local held = io.open(d_dat, 'rb')
log('(b3) os.remove of a file held open by this script: ' .. show(os.remove(d_dat)))
if held then held:close() end
log('(b3) os.remove after closing it: ' .. show(os.remove(d_dat)))

-- (a) is the ffi library available? Only loaded and inspected: no C function is declared or called.
local ok, ffi = pcall(require, 'ffi')
log('(a) pcall(require, "ffi"): ' .. (ok and 'ok' or ('FAILED: ' .. tostring(ffi))))
if ok and type(ffi) == 'table' then
    log('    ffi.os = ' .. tostring(ffi.os) .. ', ffi.arch = ' .. tostring(ffi.arch))
end
log('    jit global present: ' .. tostring(rawget(_G, 'jit') ~= nil) ..
    (rawget(_G, 'jit') and (', jit.version = ' .. tostring(jit.version)) or ''))

for _, p in ipairs({ a_tmp, b_dat, c_tmp, d_dat }) do os.remove(p) end
log('spike8 (a)(b) end')
