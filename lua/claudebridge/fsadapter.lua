-- The file-system adapter over LuaFileSystem (DL-021 design item 2, amended by DL-022 decision 11; decisions 2 and 8): the file operations that
-- store.lua expects, and the startup folder preparation. It holds the translations that are not MacroQuest wiring: errno 2 from lfs.attributes
-- becomes the string 'not_found' (the number is never passed on); a path is checked to be a directory before it is listed; the iterator state
-- that lfs.dir returns is kept and '.' and '..' are skipped; reads and writes are binary; the replace primitive's numeric Windows error becomes a
-- fixed ASCII string. It contains no ffi (winreplace.lua is the only module that binds MoveFileExA), no polling, no heartbeat scheduling, no event
-- policy, no console reporting and no MacroQuest call: the entry script decides the startup order and how a returned error is shown.
--
-- fsadapter.new{ lfs = , io = , os = , replace = } returns a table of plain functions (no self), as store.lua calls them:
--   list(dir) -> array of file names (regular files only) | nil, err
--   size(path) -> bytes | nil, err, 'not_found' (errno 2 only) | nil, err
--   read(path) -> string | nil, err            read_range(path, offset, length) -> string ('' at or past the end) | nil, err
--   write(path, data) / append(path, data) -> true | nil, err
--   rename(src, dst) -> true | nil, err        replace(src, dst) -> true | nil, 'MoveFileExA failed: GetLastError <n>'
--   prepare(root) -> true | nil, reason, detail   (reason: a fixed ASCII string; detail: the raw error, which may hold external text)
-- Every lfs, io and os call is protected: a raised error comes back as nil plus an error string, never as a raise.
-- Precondition (documented, not rechecked beyond prepare's own check): paths are ASCII (decision 8; store.new refuses a non-ASCII folder).
--
-- Observed live (DL-022 evidence notes, spikes 11 and 12) and relied on here: lfs.dir lists files and directories together, yields nothing (and does
-- not raise) for a missing path or a file path, and needs its iterator called with the directory object; lfs.attributes returns nil, a message and 2
-- for an absent path; lfs.mkdir is not recursive and returns nil, a message and 17 for an existing path and 2 for a missing parent.
local store_module = require 'claudebridge.store'    -- only for its pure check_bridge_dir

local M = {}

local function pack2(...) return { n = select('#', ...), ... } end

function M.new(deps)
    local lfs, fio, fos, replace_primitive = deps.lfs, deps.io, deps.os, deps.replace
    local A = {}

    -- lfs.attributes with a raised error caught. Returns the value, or nil plus a message plus a code. The code is lfs's errno (2 for an absent
    -- path) or 'raised'. NIL IS NOT ABSENCE: only the code 2 is.
    local function attributes(path, name)
        local r = pack2(pcall(lfs.attributes, path, name))
        if not r[1] then return nil, 'raised: ' .. tostring(r[2]), 'raised' end
        return r[2], r[3], r[4]
    end

    local function open_file(path, mode)
        local r = pack2(pcall(fio.open, path, mode))
        if not r[1] then return nil, 'raised: ' .. tostring(r[2]) end
        if not r[2] then return nil, r[3] or ('could not open ' .. path) end
        return r[2]
    end

    local function close_quietly(f) pcall(f.close, f) end

    function A.list(dir)
        -- Decision 2 and the spike 12 evidence: lfs.dir yields nothing for a missing path or a file, so zero names is not trusted; the mode is.
        local mode, err = attributes(dir, 'mode')
        if mode ~= 'directory' then
            if mode == nil then return nil, err or ('could not examine ' .. dir) end
            return nil, 'not a directory: ' .. dir
        end
        local entries = {}
        local ok, derr = pcall(function()
            local iter, handle = lfs.dir(dir)
            for name in iter, handle do entries[#entries + 1] = name end     -- the iterator is called with the directory object as its state
            if type(handle) == 'table' or type(handle) == 'userdata' then pcall(function() handle:close() end) end
        end)
        if not ok then return nil, 'raised: ' .. tostring(derr) end
        local names = {}
        for _, name in ipairs(entries) do
            if name ~= '.' and name ~= '..' then
                local m, merr, mcode = attributes(dir .. '\\' .. name, 'mode')
                if m == 'file' then
                    names[#names + 1] = name
                elseif m == nil then
                    -- errno 2: the entry vanished between the listing and the stat (the MCP server publishes by renaming a temporary file): skip it.
                    -- Any other failure is a listing failure, not a silently shorter list.
                    if mcode ~= 2 then return nil, merr end
                end                                                          -- a directory or anything else that is not a regular file: not a request name
            end
        end
        return names
    end

    function A.size(path)
        local size, err, code = attributes(path, 'size')
        if size ~= nil then return size end
        if code == 2 then return nil, err, 'not_found' end                   -- the number is translated, never passed through
        return nil, err
    end

    function A.read(path)
        local f, err = open_file(path, 'rb')
        if not f then return nil, err end
        local r = pack2(pcall(f.read, f, '*a'))
        close_quietly(f)
        if not r[1] then return nil, 'raised: ' .. tostring(r[2]) end
        if r[2] == nil then return nil, r[3] or ('could not read ' .. path) end
        return r[2]
    end

    function A.read_range(path, offset, length)
        local f, err = open_file(path, 'rb')
        if not f then return nil, err end
        local s = pack2(pcall(f.seek, f, 'set', offset))
        if not s[1] or s[2] == nil then
            close_quietly(f)
            return nil, s[1] and (s[3] or ('could not seek in ' .. path)) or ('raised: ' .. tostring(s[2]))
        end
        local r = pack2(pcall(f.read, f, length))
        close_quietly(f)
        if not r[1] then return nil, 'raised: ' .. tostring(r[2]) end
        if r[2] == nil then
            if r[3] ~= nil then return nil, r[3] end                         -- a real read error
            return ''                                                        -- read(n) returns nil at the end of the file: nothing more to read
        end
        return r[2]
    end

    local function put(path, data, mode)
        local f, err = open_file(path, mode)
        if not f then return nil, err end
        local w = pack2(pcall(f.write, f, data))
        if not w[1] then
            close_quietly(f)
            return nil, 'raised: ' .. tostring(w[2])
        end
        if w[2] == nil then
            close_quietly(f)
            return nil, w[3] or ('could not write ' .. path)
        end
        local c = pack2(pcall(f.close, f))
        if not c[1] then return nil, 'raised: ' .. tostring(c[2]) end
        if c[2] == nil then return nil, c[3] or ('could not close ' .. path) end
        return true
    end

    function A.write(path, data) return put(path, data, 'wb') end
    function A.append(path, data) return put(path, data, 'ab') end

    function A.rename(src, dst)
        local r = pack2(pcall(fos.rename, src, dst))
        if not r[1] then return nil, 'raised: ' .. tostring(r[2]) end
        if r[2] then return true end
        return nil, r[3] or ('could not rename ' .. src)
    end

    -- Decision 8: the primitive returns true, or nil plus GetLastError's number; ffi.errno() is never involved. The string is fixed ASCII.
    function A.replace(src, dst)
        local r = pack2(pcall(replace_primitive, src, dst))
        if not r[1] then return nil, 'MoveFileExA failed: the replace primitive raised an error' end
        if r[2] == true then return true end
        local code = r[3]
        if type(code) == 'number' and code == math.floor(code) then
            return nil, 'MoveFileExA failed: GetLastError ' .. string.format('%d', code)
        end
        return nil, 'MoveFileExA failed: GetLastError unknown'
    end

    -- Decision 2: the ASCII check first; then the bridge root, inbox and outbox in that order (lfs.mkdir is not recursive, so parents first). An
    -- existing directory is accepted; a path that exists as anything else is refused; any attribute failure other than errno 2 is refused; lfs.mkdir is
    -- called only after errno 2 has shown the path absent, and a directory must be there afterwards. Nothing is ever deleted.
    function A.prepare(root)
        local ok, reason = store_module.check_bridge_dir(root)
        if not ok then return nil, reason end
        local steps = { { 'bridge', root }, { 'inbox', root .. '\\inbox' }, { 'outbox', root .. '\\outbox' } }
        for _, step in ipairs(steps) do
            local label, path = step[1], step[2]
            local mode, err, code = attributes(path, 'mode')
            if mode == 'directory' then
                -- already there: accepted
            elseif mode ~= nil then
                return nil, 'the ' .. label .. ' folder path exists but is not a directory'
            elseif code ~= 2 then
                return nil, 'could not examine the ' .. label .. ' folder', err
            else
                local r = pack2(pcall(lfs.mkdir, path))
                if not r[1] then return nil, 'could not create the ' .. label .. ' folder', 'raised: ' .. tostring(r[2]) end
                if r[2] ~= true then return nil, 'could not create the ' .. label .. ' folder', r[3] end
                if attributes(path, 'mode') ~= 'directory' then return nil, 'the ' .. label .. ' folder was not created' end
            end
        end
        return true
    end

    return A
end

return M
