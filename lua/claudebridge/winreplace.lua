-- The Windows file replacement primitive (DL-022 decisions 8 and 12; design item 26): MoveFileExA with MOVEFILE_REPLACE_EXISTING through ffi. This is the
-- ONLY module that binds it, and the only crash-capable code in the bridge, so it is kept tiny: no general file-system adapter, no logging, no retries, no
-- deletion and no heartbeat scheduling.
--
--   winreplace.replace(src, dst) -> true, or nil, <the number from GetLastError>
--
-- The entry script loads it only after checking that ffi exists and that ffi.os is Windows and ffi.arch is x86 (the one environment with live evidence); it
-- refuses to start if this module cannot be loaded. The adapter (fsadapter.lua) turns a failure into 'MoveFileExA failed: GetLastError <n>'.
-- GetLastError is the only error authority and is read only after a failed call, immediately: ffi.errno() is never used (spike 8(c): it was stale).
-- Precondition, documented and not rechecked here: the paths are ASCII (store.new refuses a non-ASCII folder) and use backslashes, and the two files are
-- in the same folder (a same-folder rename, which is what the heartbeat replace is).
--
-- The declaration and the flag below are copied byte for byte from spikes/spike8_c.lua, the reviewed file that ran live in the 32-bit client
-- (`__stdcall` declared explicitly because the client is 32-bit; ignored on x64). A test compares the two files, so the copy cannot drift.
local ffi = require 'ffi'

ffi.cdef[[
int __stdcall MoveFileExA(const char* lpExistingFileName, const char* lpNewFileName, unsigned long dwFlags);
unsigned long __stdcall GetLastError(void);
]]

local MOVEFILE_REPLACE_EXISTING = 0x1

-- Both symbols are bound when the module loads, before any replacement call (design item 26.1). If either cannot be bound, indexing ffi.C raises and the
-- module fails to load: there is no fallback to a weaker mechanism (design item 26.4).
local MoveFileExA = ffi.C.MoveFileExA
local GetLastError = ffi.C.GetLastError

local M = {}

function M.replace(src, dst)
    local result = MoveFileExA(src, dst, MOVEFILE_REPLACE_EXISTING)
    if result ~= 0 then return true end
    return nil, tonumber(GetLastError())
end

return M
