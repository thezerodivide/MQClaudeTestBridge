-- An in-memory file-system adapter for tests (Step 5, DL-022): the same contract as store.lua's adapter (see the header of
-- lua/claudebridge/store.lua), modelled on what the spikes observed of Windows: a plain rename onto an existing file fails (spike 8 b2),
-- and a replace onto a file a reader holds open is refused and changes nothing (spike 8 c3, spike 9). Not shipped: lives in test/harness/.
--
-- Every operation is recorded in fs.ops as { op = ..., path = ..., <arguments> }. fs.fail[op] = function(path, ...) -> an error string
-- or nil makes that operation fail (nothing changes on failure). fs.held[path] = true makes a replace onto that path refuse.
local M = {}

local BS = '\\'

function M.new(files)
  local fs = { files = files or {}, ops = {}, fail = {}, held = {} }

  local function begin(op, path, ...)
    fs.ops[#fs.ops + 1] = { op = op, path = path, ... }
    local f = fs.fail[op]
    if f then
      local e = f(path, ...)
      if e then return e end
    end
  end

  function fs.list(dir)
    local e = begin('list', dir)
    if e then return nil, e end
    local names, prefix = {}, dir .. BS
    for path in pairs(fs.files) do
      if path:sub(1, #prefix) == prefix and not path:find(BS, #prefix + 1, true) then names[#names + 1] = path:sub(#prefix + 1) end
    end
    table.sort(names)
    return names
  end

  function fs.size(path)
    local e = begin('size', path)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path, 'not_found' end
    return #fs.files[path]
  end

  function fs.read(path)
    local e = begin('read', path)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path end
    return fs.files[path]
  end

  function fs.read_range(path, offset, length)
    local e = begin('read_range', path, offset, length)
    if e then return nil, e end
    if not fs.files[path] then return nil, 'No such file: ' .. path end
    return fs.files[path]:sub(offset + 1, offset + length)
  end

  function fs.write(path, data)
    local e = begin('write', path, data)
    if e then return nil, e end
    fs.files[path] = data
    return true
  end

  function fs.append(path, data)
    local e = begin('append', path, data)
    if e then return nil, e end
    fs.files[path] = (fs.files[path] or '') .. data
    return true
  end

  function fs.rename(src, dst)
    local e = begin('rename', src, dst)
    if e then return nil, e end
    if not fs.files[src] then return nil, 'No such file: ' .. src end
    if fs.files[dst] then return nil, 'File exists: ' .. dst end
    fs.files[dst], fs.files[src] = fs.files[src], nil
    return true
  end

  function fs.replace(src, dst)
    local e = begin('replace', src, dst)
    if e then return nil, e end
    if not fs.files[src] then return nil, 'No such file: ' .. src end
    if fs.held[dst] then return nil, 'MoveFileExA failed: GetLastError 5' end
    fs.files[dst], fs.files[src] = fs.files[src], nil
    return true
  end

  return fs
end

return M
