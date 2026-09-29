-- Windows shell/filesystem helpers for the test tooling (adapted from PTAutoRoute's harness; this repo: DL-021 design item 1). Not shipped: lives outside lua/.
-- Windows-only by design; all shell interaction is confined to this file.
local M = {}

local BS = string.char(92)

function M.native(path)
  return (path:gsub('/', BS))
end

-- cmd /c strips the first and last quote when a command line has more than two quotes, which
-- breaks `"exe with space" "script with space"`. Wrapping the whole command in one more pair of
-- quotes avoids that. Verified 2026-09-28 in PTAutoRoute (its DL-012): without the wrapper the launch fails, with it it works.
function M.shell(cmd)
  return '"' .. cmd .. '"'
end

function M.q(path)
  return '"' .. M.native(path) .. '"'
end

-- Returns the process exit code as a number.
function M.execute(cmd)
  local r = os.execute(M.shell(cmd))
  if r == true then return 0 end
  if r == false or r == nil then return 1 end
  return r
end

-- Lists files matching `pattern` in `dir`. Non-recursive returns bare names; recursive returns full paths.
-- io.popen():close() reports success even when the command fails, so an unusable listing is
-- indistinguishable from an empty one here; callers must treat zero results as a failure where that matters.
function M.list(dir, pattern, recursive)
  local cmd = 'dir /b /a-d ' .. (recursive and '/s ' or '') .. M.q(dir .. BS .. pattern) .. ' 2>NUL'
  local p = assert(io.popen(M.shell(cmd)))
  local names = {}
  for line in p:lines() do
    line = line:gsub('\r$', '')
    if line ~= '' then names[#names + 1] = line end
  end
  p:close()
  table.sort(names)
  return names
end

function M.read_all(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

function M.exists(path)
  return os.rename(path, path) and true or false
end

return M
