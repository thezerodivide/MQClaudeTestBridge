-- Spike 12: does lfs (LuaFileSystem) behave inside MacroQuest the way the bridge's file adapter needs? (DL-022 step 5)
-- Follows spike 11, which showed require('lfs') works here and lfs.dir takes about 1 ms. Three modes, each meant to be
-- authorized and run separately, in this order:
--   /lua run spike12_lfs one         READ-ONLY checks, once each (see below). Nothing is created, changed or removed.
--   /lua run spike12_lfs run [secs]  READ-ONLY. The adapter's real workload, repeated: list a folder, and for every entry call
--                                    lfs.attributes(path) (mode and size in one call), with a 100 ms delay between completed
--                                    calls, for secs seconds (default 10, at most 60). Records per-call durations.
--   /lua run spike12_lfs mkdir       BOUNDED WRITE TEST, the only mode that writes anything but its own log (see below).
-- Always written: this spike's own log, Logs\spike12_<mode>_log.txt. No ffi, no game action, and no other file changed. The
-- only other file access is read-only: mode 'one' opens up to three existing files in the Logs folder with io.open(path, 'rb')
-- to seek to their end, only to compare that size with lfs.attributes; nothing is written to them.
-- The only os.* calls are os.time() and os.date(), read-only, used to make the scratch folder name unique and stamp the log.
--
-- 'one' checks: lfs's version and how MacroQuest found it (package.cpath and package.searchpath); lfs.dir on an existing
--   folder (does it return '.' and '..'? does the iterator end?), on a missing folder and on a path that is a file (does it
--   raise, and with what text?); lfs.attributes on a directory, a file and a missing path (the values it returns, the exact
--   failure results); telling files from directories by lfs.attributes(path, 'mode'); file sizes from lfs.attributes(path,
--   'size') compared with the size found by opening the file and seeking to its end; and the same listing and filtering on a
--   folder whose path has a space in it. The missing-path tests use a name confirmed absent by a successful listing of its
--   parent, and are skipped, with the reason logged, if that cannot be shown.
-- 'run' workload: the bridge's poll would list inbox and outbox and stat the request it is about to handle. This lists a
--   folder of about a hundred entries and stats every entry, which is a heavier per-call load than the real folders will
--   usually have (they stay small until requests accumulate), so it is a conservative stand-in, not the real workload.
--   Every lfs.attributes call is protected (a raised error is caught), and every lfs.dir and lfs.attributes failure, raised or
--   returned, is counted and the first is recorded (the small cost of the protective wrapper is inside the timings); the log ends with one RESULT line that says
--   CLEAN (every call succeeded for the full duration) or PARTIAL / NOT CLEAN, so timings from a partly failed run cannot be
--   mistaken for a clean result.
--   Like spike 11, the check for a slow call runs only AFTER a call returns: it stops later calls, and cannot interrupt a
--   call that never returns. A step followed by a 100 ms delay is a PLANNED shape for the bridge's loop, which does not exist
--   yet; nothing here proves what the implementation will do.
-- 'mkdir' write test (the production operation for design decision A, "the bridge creates its own folders"):
--   * the scratch name is unique, beneath the Logs folder: spike12_scratch_<date>_<time>_<ms>. Before EACH creation (the root
--     under Logs, and inbox and outbox under the root) it lists the parent with lfs.dir and requires that the listing succeeds
--     and does not contain the exact name (ignoring case); if the parent cannot be listed, or the name is there, it REFUSES that
--     creation (lfs.attributes(path, 'mode') == nil is not accepted as proof of absence: it can also be an access error);
--   * it creates the scratch root, then <root>\inbox, then <root>\outbox, in that order (the bridge's order). After EVERY
--     lfs.mkdir it inspects the path: a directory that appeared is recorded for cleanup whatever mkdir reported (an unexpected
--     return then makes the test fail, but the directory is still removed); a non-directory that appeared is reported as a
--     failure and is NEVER removed. It also checks that the root is empty;
--   * it also checks, changing nothing: that lfs.mkdir on the existing scratch root fails and how, that lfs.mkdir with a missing
--     parent (<root>\no_parent\child) fails and creates nothing (whether mkdir is non-recursive), and that lfs.mkdir on a path
--     that is an existing FILE (this run's own log) fails and how;
--   * it removes ONLY the directories it created in this run, children first, with lfs.rmdir, and confirms each removal while
--     the parent still exists: the parent's listing must succeed and must not contain the exact name. A parent is removed only
--     after every directory recorded under it is confirmed gone; a removal that cannot be confirmed stays tracked and makes the
--     result NOT CLEAN (lfs.attributes returning nil is never accepted as proof of removal). Each created directory is recorded
--     with its own path, parent and name. If anything fails partway, it makes a best-effort cleanup of what it created and
--     reports, in the log and on the console, exactly which scratch objects (if any) are or may still be there, and ends with one
--     RESULT line: everything as expected and confirmed removed, or NOT CLEAN.
--   * the three failure probes (an existing directory, a missing parent, an existing file) are meant to FAIL; a reported success
--     from any of them is an unexpected result and makes the result NOT CLEAN, whatever state is found afterwards.
--   Ownership, stated accurately: the name was absent in a successful listing of its parent immediately before this run's own
--     lfs.mkdir, which strongly supports that this run created what it removes; it cannot rule out something else creating the
--     same name at the same instant.
--   It never deletes or replaces any file, or any directory it did not itself create in this run.
-- Time source: mq.gettime() = std::chrono::steady_clock in whole milliseconds (as in spikes 10 and 11).
local mq = require('mq')
local args = { ... }
local mode = args[1] or 'one'
if mode ~= 'one' and mode ~= 'run' and mode ~= 'mkdir' then
    error("spike12: unknown mode '" .. tostring(mode) .. "' (use 'one', 'run [seconds]' or 'mkdir')", 0)
end

local logdir = rawget(_G, 'SPIKE12_LOGDIR') or 'C:\\Users\\Public\\MacroQuest\\Logs'
local spacedir = rawget(_G, 'SPIKE12_SPACEDIR') or 'C:\\Program Files'
local logpath = logdir .. '\\spike12_' .. mode .. '_log.txt'
local RUN_SECONDS = math.min(60, math.max(1, tonumber(args[2]) or 10))
local DELAY_MS = 100
local STALL_STOP_MS = 1000

local function log(m)
    local f, err = io.open(logpath, 'a')
    if not f then error('spike12: cannot open the log: ' .. tostring(err), 0) end
    assert(f:write(m, '\n')); assert(f:close())
end
do
    local f, err = io.open(logpath, 'w')
    if not f then error('spike12: cannot open the log for writing: ' .. tostring(err), 0) end
    assert(f:write('spike12 start, mode ', mode, '\n')); assert(f:close())
end

local function s(v) return tostring(v):sub(1, 300) end
local function join(...)
    local out = {}
    for i = 1, select('#', ...) do out[i] = s((select(i, ...))) end
    return table.concat(out, ' / ')
end

local ok_lfs, lfs = pcall(require, 'lfs')
if not ok_lfs or type(lfs) ~= 'table' then
    log('lfs: require("lfs") FAILED: ' .. s(lfs))
    log('spike12 end (nothing else can be tested)')
    print('spike12: lfs did not load; see ' .. logpath)
    return
end

-- All lfs calls go through pcall so a raised error is recorded, not fatal. Results come back as { n = count, ... } with the
-- pcall status first (LuaJIT's own unpack and select, since table.pack and table.unpack need the 5.2-compat build).
local unpack = unpack or table.unpack
local function pack2(...) return { n = select('#', ...), ... } end
local function try(fn, ...) return pack2(pcall(fn, ...)) end

-- Lists a folder with lfs.dir. Returns names (including '.' and '..' if lfs returns them), or nil and the raised error.
local function list(dir)
    local names = {}
    local ok, err = pcall(function()
        local iter, handle = lfs.dir(dir)
        -- lfs.dir returns an iterator and a directory object, and the iterator is called with that object as its state:
        -- `for name in iter, handle do` (a bare `for name in iter do` drops it and lfs raises a bad-argument error)
        for name in iter, handle do names[#names + 1] = name end
        if type(handle) == 'userdata' or type(handle) == 'table' then pcall(function() handle:close() end) end
    end)
    if not ok then return nil, err end
    return names
end

-- lfs.attributes(path, 'mode') with a raised error caught. Returns the mode string, or nil plus the reason. NIL IS NOT PROOF THAT
-- THE PATH IS ABSENT: it can also be an access or filesystem error. Absence is only ever judged by confirmed_absent below.
local function mode_of(path)
    local r = try(lfs.attributes, path, 'mode')
    if not r[1] then return nil, 'raised: ' .. s(r[2]) end
    return r[2], r[3], r[4]
end

local function join_path(dir, name) return dir .. '\\' .. name end

-- The ONLY way this spike decides that something is absent (before a creation, after a removal, and for the missing-path tests):
-- a successful listing of the parent that does not contain the exact name, compared ignoring case as Windows does.
-- Returns true (absent), false (present) or nil (the parent could not be listed) plus a reason.
local function confirmed_absent(parent, name)
    local names, err = list(parent)
    if not names then return nil, 'the parent could not be listed: ' .. s(err) end
    local lname = name:lower()
    for _, n in ipairs(names) do
        if n:lower() == lname then return false, 'an entry with that name exists' end
    end
    return true
end

local function first(names, n)
    local out = {}
    for i = 1, math.min(n, #names) do out[i] = names[i] end
    return table.concat(out, ' | ')
end

local function size_by_seek(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local n = f:seek('end')
    f:close()
    return n
end

local function count_by_mode(dir, names)
    local counts, files = {}, {}
    for _, name in ipairs(names) do
        if name ~= '.' and name ~= '..' then
            local m = mode_of(join_path(dir, name))
            m = m or 'nil'
            counts[m] = (counts[m] or 0) + 1
            if m == 'file' then files[#files + 1] = name end
        end
    end
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. counts[k] end
    return table.concat(parts, ' '), files
end

local function stats(list_of_ms)
    if #list_of_ms == 0 then return 'no samples' end
    local sorted, total = {}, 0
    for i, v in ipairs(list_of_ms) do sorted[i] = v; total = total + v end
    table.sort(sorted)
    local p95 = sorted[math.max(1, math.ceil(#sorted * 0.95))]
    return string.format('n=%d total=%d ms mean=%.1f median=%d p95=%d worst=%d', #list_of_ms, total, total / #list_of_ms,
        sorted[math.ceil(#sorted / 2)], p95, sorted[#sorted])
end

local function mode_one()
    log('lfs: loaded; _VERSION = ' .. s(lfs._VERSION))
    log('package.cpath = ' .. s(package.cpath))
    local sp = try(function() return package.searchpath('lfs', package.cpath) end)
    log('package.searchpath("lfs", package.cpath) -> ' .. (sp[1] and join(sp[2], sp[3]) or ('raised: ' .. s(sp[2]))))

    -- lfs.dir on an existing folder
    local names, err = list(logdir)
    if names then
        local has_dot, has_dotdot = false, false
        for _, n in ipairs(names) do
            if n == '.' then has_dot = true elseif n == '..' then has_dotdot = true end
        end
        log(string.format('lfs.dir(existing) [%s]: %d names including dots; returns "." = %s, ".." = %s; first: %s',
            logdir, #names, tostring(has_dot), tostring(has_dotdot), first(names, 4)))
    else
        log('lfs.dir(existing) RAISED: ' .. s(err))
    end

    -- lfs.dir on a missing folder. The name is made unique and must be CONFIRMED absent by a successful listing of its parent; if
    -- that cannot be established, the missing-path tests are skipped, because their results would say nothing about a missing path.
    local missing_name = 'spike12_no_such_folder_' .. os.time()
    local missing = join_path(logdir, missing_name)
    local missing_absent, missing_why = confirmed_absent(logdir, missing_name)
    if missing_absent ~= true then
        log('missing-path tests SKIPPED (lfs.dir and lfs.attributes on a missing path): ' .. s(missing_why or 'the chosen name exists') .. '; a result would not be evidence about a missing path')
    else
        local mnames, merr = list(missing)
        if mnames then
            log('lfs.dir(missing): DID NOT RAISE; returned ' .. #mnames .. ' names (' .. first(mnames, 4) .. ')')
        else
            log('lfs.dir(missing): RAISED: ' .. s(merr))
        end
    end

    -- lfs.attributes on a directory, a file and a missing path
    local all_files
    do
        local counts
        counts, all_files = count_by_mode(logdir, names or {})
        log('entries of the logs folder by lfs.attributes(path, "mode"): ' .. counts)
    end
    local dattrs = try(lfs.attributes, logdir)
    if dattrs[1] and type(dattrs[2]) == 'table' then
        local keys = {}
        for k in pairs(dattrs[2]) do keys[#keys + 1] = k end
        table.sort(keys)
        log('lfs.attributes(directory) -> table; mode = ' .. s(dattrs[2].mode) .. ', size = ' .. s(dattrs[2].size) .. '; keys: ' .. table.concat(keys, ','))
    else
        log('lfs.attributes(directory) -> ' .. join(unpack(dattrs, 1, dattrs.n)))
    end
    local file1 = all_files and all_files[1]
    if file1 then
        local fa = try(lfs.attributes, join_path(logdir, file1))
        if fa[1] and type(fa[2]) == 'table' then
            log('lfs.attributes(file) [' .. file1 .. '] -> mode = ' .. s(fa[2].mode) .. ', size = ' .. s(fa[2].size))
        else
            log('lfs.attributes(file) -> ' .. join(unpack(fa, 1, fa.n)))
        end
        -- lfs.dir on a path that is a file
        local fnames, ferr = list(join_path(logdir, file1))
        if fnames then
            log('lfs.dir(a file): DID NOT RAISE; returned ' .. #fnames .. ' names')
        else
            log('lfs.dir(a file): RAISED: ' .. s(ferr))
        end
    else
        log('lfs.attributes(file): no file found in the logs folder to test')
    end
    if missing_absent == true then
        local ma = try(lfs.attributes, missing)
        log('lfs.attributes(missing path) -> returned: ' .. join(unpack(ma, 1, ma.n)))
        local mm = try(lfs.attributes, missing, 'mode')
        log('lfs.attributes(missing path, "mode") -> returned: ' .. join(unpack(mm, 1, mm.n)))
    end

    -- sizes: lfs.attributes(path, 'size') against opening the file and seeking to its end (the file may still be growing)
    for i = 1, math.min(3, #(all_files or {})) do
        local path = join_path(logdir, all_files[i])
        local sr = try(lfs.attributes, path, 'size')
        local by_lfs = sr[1] and sr[2] or nil
        local by_seek = size_by_seek(path)
        log(string.format('size [%s]: lfs.attributes = %s%s, open+seek = %s, equal = %s', all_files[i], s(by_lfs), sr[1] and '' or (' (raised: ' .. s(sr[2]) .. ')'), s(by_seek), tostring(by_lfs ~= nil and by_lfs == by_seek)))
    end

    -- the folder whose path has a space in it
    local snames, serr = list(spacedir)
    if snames then
        local counts = count_by_mode(spacedir, snames)
        log(string.format('lfs.dir + mode filter [%s]: %d names including dots; by mode: %s', spacedir, #snames, counts))
    else
        log('lfs.dir(folder with a space) RAISED: ' .. s(serr))
    end
    log('one-call mode done (read-only)')
    print('spike12 one: done. Log: ' .. logpath)
end

local function mode_run()
    log(string.format('run: workload = lfs.dir + lfs.attributes(path) for every entry of [%s], a %d ms delay between completed calls, for %d s; stops after any call of %d ms or more has returned (a call that blocks cannot be interrupted)',
        logdir, DELAY_MS, RUN_SECONDS, STALL_STOP_MS))
    local t_start = mq.gettime()
    local durations, periods = {}, {}
    local prev_start, entries, files, stopped = nil, 0, 0, false
    local attr_calls, attr_failures, first_attr_failure = 0, 0, nil
    local list_failures, first_list_failure = 0, nil
    while mq.gettime() - t_start < RUN_SECONDS * 1000 do
        local t0 = mq.gettime()
        if prev_start then periods[#periods + 1] = t0 - prev_start end
        prev_start = t0
        local names, err = list(logdir)
        if not names then
            list_failures = list_failures + 1
            first_list_failure = first_list_failure or s(err)
            log('run: lfs.dir RAISED at call ' .. (#durations + 1) .. ': ' .. s(err))
            stopped = true
            break
        end
        entries, files = 0, 0
        for _, name in ipairs(names) do
            if name ~= '.' and name ~= '..' then
                entries = entries + 1
                local r = try(lfs.attributes, join_path(logdir, name))
                local a = r[2]
                attr_calls = attr_calls + 1
                if not r[1] then
                    attr_failures = attr_failures + 1
                    first_attr_failure = first_attr_failure or (name .. ' -> raised: ' .. s(r[2]))
                elseif type(a) ~= 'table' then
                    attr_failures = attr_failures + 1
                    first_attr_failure = first_attr_failure or (name .. ' -> ' .. join(r[2], r[3], r[4]))
                elseif a.mode == 'file' then
                    if a.size == nil then
                        attr_failures = attr_failures + 1
                        first_attr_failure = first_attr_failure or (name .. ' -> a file without a size')
                    else
                        files = files + 1
                    end
                end
            end
        end
        local ms = mq.gettime() - t0
        durations[#durations + 1] = ms
        if ms >= STALL_STOP_MS then
            log(string.format('run: STALL: call %d took %d ms and has returned; stopping the run', #durations, ms))
            stopped = true
            break
        end
        mq.delay(DELAY_MS)
    end
    log(string.format('run: entries per call (last) = %d, of which files with a size = %d', entries, files))
    log(string.format('run: lfs.attributes calls = %d, failures = %d%s', attr_calls, attr_failures,
        first_attr_failure and ('; first failure: ' .. s(first_attr_failure)) or ''))
    log(string.format('run: lfs.dir failures = %d%s', list_failures, first_list_failure and ('; first failure: ' .. s(first_list_failure)) or ''))
    log('run: per-call duration (ms): ' .. stats(durations))
    log('run: period between call starts (ms; about the call plus ' .. DELAY_MS .. ' ms plus scheduling): ' .. stats(periods))
    local reasons = {}
    if attr_failures > 0 then reasons[#reasons + 1] = attr_failures .. ' lfs.attributes failure(s)' end
    if list_failures > 0 then reasons[#reasons + 1] = list_failures .. ' lfs.dir failure(s)' end
    if stopped then reasons[#reasons + 1] = 'stopped early' end
    local verdict
    if #reasons == 0 then
        verdict = 'CLEAN: every call succeeded, for the full duration; the timings above describe a fully successful workload'
    else
        verdict = 'PARTIAL / NOT CLEAN: ' .. table.concat(reasons, '; ') .. '; the timings above describe a partly failed workload and must not be read as a clean result'
    end
    log('run: RESULT: ' .. verdict)
    print('spike12 run: ' .. (#reasons == 0 and 'CLEAN' or 'PARTIAL / NOT CLEAN') .. '. Log: ' .. logpath)
end

local function mode_mkdir()
    local stamp = os.date('%Y%m%d%H%M%S') .. '_' .. mq.gettime()
    local rootname = 'spike12_scratch_' .. stamp
    local root = join_path(logdir, rootname)
    local inbox, outbox = join_path(root, 'inbox'), join_path(root, 'outbox')
    local created = {}      -- records { path, parent, name } of directories this run made and has NOT yet confirmed removed, in creation order
    local confirmed = {}    -- paths this run removed and confirmed absent from a successful listing of their parent, in order
    local foreign = {}      -- non-directory objects that appeared where a directory was requested: reported, never removed
    local unexpected = {}   -- anything that did not go as expected, for the final verdict

    -- After a creation attempt, look at what is there and take cleanup responsibility for a directory that appeared, whatever the
    -- attempt reported. The name was absent in a successful listing immediately before this run's own attempt, which strongly
    -- supports that this run created it; it cannot rule out a simultaneous creation by something else.
    -- Returns 'directory', 'foreign' (something that is not a directory appeared: reported, never removed), 'unknown'
    -- (cannot tell) or 'nothing'.
    local function inspect_after(path, parent, name)
        local m = mode_of(path)
        if m == 'directory' then
            created[#created + 1] = { path = path, parent = parent, name = name }
            return 'directory'
        end
        local absent = confirmed_absent(parent, name)
        if m ~= nil or absent == false then
            foreign[#foreign + 1] = path
            log(string.format('mkdir: an object that is not a directory (mode %s) now exists at [%s]; it is NOT removed', s(m), path))
            return 'foreign'
        end
        if absent == nil then
            log('mkdir: cannot tell whether anything exists at [' .. path .. '] (mode ' .. s(m) .. ', parent not listable); nothing will be removed there')
            return 'unknown'
        end
        return 'nothing'
    end

    -- Returns true only when the path was confirmed absent beforehand, lfs.mkdir reported true, and a directory is there afterwards.
    local function make(path, parent, name)
        local absent, why = confirmed_absent(parent, name)
        if absent ~= true then
            log('mkdir: REFUSED to create [' .. path .. ']: ' .. s(why))
            unexpected[#unexpected + 1] = 'refused to create ' .. name
            return false
        end
        local r = try(lfs.mkdir, path)
        local after = inspect_after(path, parent, name)
        log(string.format('mkdir: lfs.mkdir [%s] -> %s; afterwards: %s', path, join(unpack(r, 1, r.n)), after))
        local reported_ok = r[1] and r[2] == true
        if after == 'directory' and reported_ok then return true end
        if after == 'directory' then
            unexpected[#unexpected + 1] = 'lfs.mkdir reported a failure for ' .. name .. ' but the directory exists (cleanup responsibility taken)'
        else
            unexpected[#unexpected + 1] = 'creating ' .. name .. ' did not produce a directory (' .. after .. ')'
        end
        return false
    end

    local absent, why = confirmed_absent(logdir, rootname)
    if absent ~= true then
        log('mkdir: REFUSED: ' .. s(why) .. '; nothing was created')
        print('spike12 mkdir: refused (' .. s(why) .. '). Nothing created. Log: ' .. logpath)
        return
    end
    log('mkdir: scratch root will be ' .. root .. ' (absent in a successful listing of its parent)')

    -- Cleanup: children before parents, and a parent is removed only when no directory recorded under it is still unconfirmed.
    -- Each removal is confirmed while its parent still exists (the parent's listing does not contain the exact name); a removal
    -- that cannot be confirmed leaves the directory tracked and the result NOT CLEAN. Nothing is re-checked after its parent is gone.
    local function has_tracked_children(path)
        for _, rec in ipairs(created) do
            if rec.parent == path then return true end
        end
        return false
    end
    local function cleanup(reason)
        log('mkdir: cleanup (' .. reason .. '): removing only directories this run created, children first')
        for i = #created, 1, -1 do
            local rec = created[i]
            if has_tracked_children(rec.path) then
                log('mkdir: NOT removing [' .. rec.path .. ']: something recorded under it is not yet confirmed absent')
            else
                local r = try(lfs.rmdir, rec.path)
                local gone, gwhy = confirmed_absent(rec.parent, rec.name)
                log(string.format('mkdir: rmdir [%s] -> %s; confirmed absent from a listing of its parent = %s%s', rec.path, join(unpack(r, 1, r.n)),
                    tostring(gone), gone == nil and (' (' .. s(gwhy) .. ')') or ''))
                if gone == true then
                    confirmed[#confirmed + 1] = rec.path
                    table.remove(created, i)
                end
            end
        end
    end

    local main_ok, main_err = pcall(function()
        -- the bridge's order: root, then inbox, then outbox
        assert(make(root, logdir, rootname), 'creating the scratch root failed')
        local rn, rerr = list(root)
        local only_dots = rn ~= nil
        if rn then
            for _, n in ipairs(rn) do
                if n ~= '.' and n ~= '..' then only_dots = false end
            end
        end
        log('mkdir: new root is empty (only "." and ".." or nothing) = ' .. tostring(only_dots) .. (rn and '' or (' (lfs.dir raised: ' .. s(rerr) .. ')')))
        assert(make(inbox, root, 'inbox'), 'creating inbox failed')
        assert(make(outbox, root, 'outbox'), 'creating outbox failed')

        -- How mkdir fails on an existing directory, with a missing parent, and on an existing file. Each is meant to FAIL: a
        -- reported success is an unexpected result whatever state is found afterwards, and each is inspected afterwards.
        local again = try(lfs.mkdir, root)
        log('mkdir: lfs.mkdir on the EXISTING root -> ' .. join(unpack(again, 1, again.n)) .. '; still a directory = ' .. tostring(mode_of(root) == 'directory'))
        if again[1] and again[2] == true then unexpected[#unexpected + 1] = 'lfs.mkdir reported success on an existing directory' end

        local parent = join_path(root, 'no_parent')
        local child = join_path(parent, 'child')
        local parent_absent = confirmed_absent(root, 'no_parent')
        if parent_absent ~= true then
            log('mkdir: missing-parent probe SKIPPED: could not show "no_parent" absent in a listing of the root')
        else
            local orphan = try(lfs.mkdir, child)
            log('mkdir: lfs.mkdir with a MISSING PARENT [' .. child .. '] -> ' .. join(unpack(orphan, 1, orphan.n)))
            if orphan[1] and orphan[2] == true then unexpected[#unexpected + 1] = 'lfs.mkdir reported success with a missing parent' end
            local pafter = inspect_after(parent, root, 'no_parent')
            local cafter = (pafter == 'directory') and inspect_after(child, parent, 'child') or 'nothing'
            log('mkdir: after the missing-parent probe: parent = ' .. pafter .. ', child = ' .. cafter)
            if pafter ~= 'nothing' or cafter ~= 'nothing' then
                log('mkdir: NOTE: mkdir produced something for a missing parent (it may be recursive); any directories it made are in the cleanup list')
                unexpected[#unexpected + 1] = 'lfs.mkdir with a missing parent produced ' .. pafter .. ' / ' .. cafter
            end
        end

        local onfile = try(lfs.mkdir, logpath)
        log('mkdir: lfs.mkdir on an existing FILE (this run\'s own log) -> ' .. join(unpack(onfile, 1, onfile.n)) .. '; still a file = ' .. tostring(mode_of(logpath) == 'file'))
        if onfile[1] and onfile[2] == true then unexpected[#unexpected + 1] = 'lfs.mkdir reported success on an existing file' end
        if mode_of(logpath) ~= 'file' then unexpected[#unexpected + 1] = 'the log file is not confirmed to still be a file after lfs.mkdir on it' end
    end)
    if not main_ok then log('mkdir: ERROR during the test: ' .. s(main_err)) end

    cleanup(main_ok and 'normal end' or 'after an error')
    local left = {}
    for _, rec in ipairs(created) do left[#left + 1] = rec.path .. ' (removal not confirmed)' end
    for _, p in ipairs(foreign) do left[#left + 1] = p .. ' (not a directory; not removed)' end
    if #left == 0 then
        log('mkdir: VERIFIED: ' .. #confirmed .. ' scratch directory(ies) this run created were removed, each confirmed absent from a successful listing of its parent, in this order: ' .. table.concat(confirmed, ' ; '))
    else
        log('mkdir: WARNING: scratch objects that are, or may still be, present: ' .. table.concat(left, ' ; ') .. ' (check and remove by hand)')
    end
    local verdict
    if main_ok and #unexpected == 0 and #left == 0 then
        verdict = 'ALL STEPS WENT AS EXPECTED and every directory created was removed and confirmed absent'
    else
        verdict = 'NOT CLEAN: ' .. (main_ok and '' or 'an error ended the test early; ') .. #unexpected .. ' unexpected result(s)' ..
            (#unexpected > 0 and (': ' .. table.concat(unexpected, ' | ')) or '') .. '; ' .. #left .. ' scratch object(s) left or not confirmed removed'
    end
    log('mkdir: RESULT: ' .. verdict)
    print('spike12 mkdir: ' .. verdict .. '. Log: ' .. logpath)
end

local runner = { one = mode_one, run = mode_run, mkdir = mode_mkdir }
log('wall clock at start: ' .. os.date('%Y-%m-%d %H:%M:%S'))
local ok, err = pcall(runner[mode])
if not ok then
    pcall(log, 'ERROR: ' .. s(err))
    error(err, 0)
end
log('spike12 end')
