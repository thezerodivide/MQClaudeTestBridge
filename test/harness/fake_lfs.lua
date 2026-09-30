-- Fakes of lfs, io and os over one in-memory file tree, for testing claudebridge/fsadapter.lua (Step 5, DL-022 decision 11). Not shipped.
-- They model the behavior OBSERVED LIVE in MacroQuest (DL-022 evidence notes on spikes 11 and 12, LuaFileSystem 1.9.0), NOT the assumption used in
-- spike 12's dry-run fake:
--   * lfs.dir(path) returns an iterator and a directory object; the iterator must be called with that object as its state (else it raises);
--     for an existing directory it yields '.' and '..' and the entries (files and directories together); for a MISSING path or a path that is a
--     FILE it does not raise and yields nothing.
--   * lfs.attributes(path, name) returns the value (or the table); for an absent path it returns nil, a message containing the path, and the
--     number 2.
--   * lfs.mkdir(path) is not recursive: it returns true, or nil plus a message plus 17 for an existing path and 2 for a missing parent.
--   * os.rename onto an existing file fails (spike 8 b2): nil plus a message.
-- Every call is recorded in fake.calls as { fn = 'lfs.mkdir', path = ... } so a test can check order and that nothing forbidden was called.
-- Hooks for failures: fake.attr_fail[path] = { message, code } makes lfs.attributes return nil, message, code for that path;
-- fake.open_fail[path] = 'message' makes io.open return nil, message; fake.write_fail[path] / fake.close_fail[path] make that file's write or close fail;
-- fake.dir_raises[path] = true makes lfs.dir raise; fake.mkdir_result[path] = { ... } overrides lfs.mkdir's return values (without creating anything).
local M = {}

local BS = '\\'

local unpack = unpack or table.unpack

local function parent_of(path) return (path:match('^(.*)\\[^\\]*$')) end
local function leaf_of(path) return (path:match('([^\\]*)$')) end

function M.new(initial)
  local fake = { tree = {}, calls = {}, attr_fail = {}, open_fail = {}, write_fail = {}, close_fail = {}, dir_raises = {}, mkdir_result = {}, closed_handles = 0 }
  -- initial: path -> string (a file with that content) or true (a directory)
  for path, v in pairs(initial or {}) do
    if v == true then fake.tree[path] = { kind = 'directory' } else fake.tree[path] = { kind = 'file', data = v } end
  end

  local function note(fn, path, extra) fake.calls[#fake.calls + 1] = { fn = fn, path = path, extra = extra } end

  local function missing_message(path) return "cannot obtain information from file '" .. path .. "': No such file or directory" end

  local function children(dir)
    local out = {}
    for path in pairs(fake.tree) do
      if parent_of(path) == dir then out[#out + 1] = leaf_of(path) end
    end
    table.sort(out)
    return out
  end

  local lfs = {}

  function lfs.attributes(path, name)
    note('lfs.attributes', path, name)
    local hook = fake.attr_fail[path]
    if hook then return nil, hook[1], hook[2] end
    local e = fake.tree[path]
    if not e then return nil, missing_message(path), 2 end
    local full = { mode = e.kind, size = e.kind == 'file' and #e.data or 65536 }
    if name then return full[name] end
    return full
  end

  function lfs.dir(path)
    note('lfs.dir', path)
    if fake.dir_raises[path] then error('cannot open ' .. path .. ': Access is denied', 2) end
    local list = {}
    local e = fake.tree[path]
    if e and e.kind == 'directory' then
      list = { '.', '..' }
      for _, n in ipairs(children(path)) do list[#list + 1] = n end
    end                                      -- a missing path or a file path: no raise, an empty iteration (observed)
    local i = 0
    local handle = { close = function() fake.closed_handles = fake.closed_handles + 1 end }
    return function(state)
      if state ~= handle then error("bad argument #1 to 'for iterator' (directory expected, got " .. type(state) .. ')', 2) end
      i = i + 1
      return list[i]
    end, handle
  end

  function lfs.mkdir(path)
    note('lfs.mkdir', path)
    local override = fake.mkdir_result[path]
    if override then return unpack(override) end
    if fake.tree[path] then return nil, 'File exists', 17 end
    local par = parent_of(path)
    if not (par and fake.tree[par] and fake.tree[par].kind == 'directory') then return nil, 'No such file or directory', 2 end
    fake.tree[path] = { kind = 'directory' }
    return true
  end

  function lfs.rmdir(path) note('lfs.rmdir', path); error('lfs.rmdir must never be called by the adapter', 2) end

  local fio = {}

  function fio.open(path, mode)
    note('io.open', path, mode)
    if fake.open_fail[path] then return nil, fake.open_fail[path] end
    local e = fake.tree[path]
    if mode == 'rb' then
      if not e or e.kind ~= 'file' then return nil, path .. ': No such file or directory' end
    elseif mode == 'wb' or mode == 'ab' then
      local par = parent_of(path)
      if e and e.kind == 'directory' then return nil, path .. ': Permission denied' end
      if not (par and fake.tree[par] and fake.tree[par].kind == 'directory') then return nil, path .. ': No such file or directory' end
      if not e then e = { kind = 'file', data = '' }; fake.tree[path] = e end
      if mode == 'wb' then e.data = '' end
    else
      error('fake io.open: unexpected mode ' .. tostring(mode), 2)    -- the adapter must use binary modes only
    end
    local pos = 0
    local f = {}
    function f:read(what)
      if what == '*a' then
        local s = e.data:sub(pos + 1)
        pos = #e.data
        return s
      end
      if type(what) == 'number' then
        if pos >= #e.data then return nil end     -- read(n) at the end of the file returns nil (standard Lua)
        local s = e.data:sub(pos + 1, pos + what)
        pos = pos + #s
        return s
      end
      error('fake io: unexpected read format', 2)
    end
    function f:seek(whence, offset)
      if whence == 'set' then pos = offset elseif whence == 'end' then pos = #e.data + (offset or 0) else error('fake io: unexpected seek', 2) end
      return pos
    end
    function f:write(data)
      if fake.write_fail[path] then return nil, fake.write_fail[path] end
      if mode == 'ab' then e.data = e.data .. data else e.data = e.data:sub(1, pos) .. data; pos = #e.data end
      return self
    end
    function f:close()
      if fake.close_fail[path] then return nil, fake.close_fail[path] end
      return true
    end
    return f
  end

  local fos = {}

  function fos.rename(src, dst)
    note('os.rename', src, dst)
    if not fake.tree[src] then return nil, src .. ': No such file or directory', 2 end
    if fake.tree[dst] then return nil, dst .. ': File exists', 17 end
    fake.tree[dst], fake.tree[src] = fake.tree[src], nil
    return true
  end

  function fos.remove(path) note('os.remove', path); error('os.remove must never be called by the adapter', 2) end

  fake.lfs, fake.io, fake.os = lfs, fio, fos
  return fake
end

return M
