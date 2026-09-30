-- The bridge's files (DL-021 design item 2; DL-022 step 4): reading a request, writing a reply, publishing the heartbeat,
-- appending events, and the ASCII check on the bridge folder. Criteria 6, 7, 13; design items 5, 9, 10, 14, 19 and 26; the
-- 2026-09-29 non-ASCII-path decision.
-- It works over an injected file-system adapter `fs`, so nothing here touches a file or calls MacroQuest. The adapter is
-- built in the entry script (step 5) and is live-only. Its contract (every function returns nil plus an error string on
-- failure and changes nothing on failure; a string is what the operating system said, and it may hold external text, so the
-- caller writes it with core.string_field):
--   fs.list(dir) -> array of bare file names
--   fs.size(path) -> size in bytes | nil, err, 'not_found' (the third value only when the file does not exist)
--   fs.read(path) -> the whole file as a string (binary: no newline translation)
--   fs.read_range(path, offset, length) -> up to `length` bytes from byte `offset` (0-based)
--   fs.write(path, data) -> true   (create or truncate)
--   fs.append(path, data) -> true  (binary append, creating the file if needed)
--   fs.rename(src, dst) -> true    (plain rename: fails if dst exists, as os.rename does on Windows)
--   fs.replace(src, dst) -> true   (MoveFileExA with MOVEFILE_REPLACE_EXISTING, design item 26; refused while a reader holds dst)
local json = require 'claudebridge.json'
local version = require 'claudebridge.version'
local queue = require 'claudebridge.queue'
local core = require 'claudebridge.core'

local M = {}
local S = {}
S.__index = S

local BS = '\\'

-- How much of the end of events.jsonl is read at a time when looking for the last complete line at startup (design item
-- 10.1). An implementation choice with no requirement behind the number: a window that is too small is doubled until the
-- line is found, so it affects only how much is read, never the result.
local EVENTS_WINDOW = 8192

-- The 2026-09-29 decision: the bridge refuses to start unless its folder path is ASCII (every byte 0x7F or below). Returns
-- true, or false plus a fixed ASCII reason that does not repeat the path.
function M.check_bridge_dir(path)
    if type(path) ~= 'string' then return false, 'bridge folder path is not a string' end
    if path:find('[\128-\255]') then
        return false, 'bridge folder path has a byte above 0x7F (non-ASCII); the bridge needs an ASCII folder path'
    end
    return true
end

-- A whole number of seconds (design item 9: written_at and t come from os.time()).
local function whole_seconds(n)
    return type(n) == 'number' and n == math.floor(n) and math.abs(n) < 1e15
end

-- The largest event number, one constant for writing and for recovery so the two can never disagree. An implementation
-- choice (the record sets no limit): the largest whole number below 1e15. It is exact where it is used: append_event writes
-- n with string.format('%d'), which prints a whole number below 2^53 in full, and the decoder represents such a number
-- exactly (binary64). json.encode is NOT used for n: its %.14g allows 14 significant digits and would round this 15-digit
-- maximum to 1e+15. It may be written once; after it appending fails closed and a restart reports exhaustion, so no number
-- is ever handed out twice (criterion 7). A line numbered above it is not an event.
local MAX_EVENT_N = 999999999999999
local EXHAUSTED = 'event numbers are exhausted; no event was written'
M.EXHAUSTED = EXHAUSTED   -- exported so the loop can tell exhaustion from any other events failure (DL-022 decisions 6 and 9)

-- Design item 9: an event's `kind` is one of our own names, lower-case letters and underscores.
local function valid_kind(kind)
    return type(kind) == 'string' and kind:match('^[a-z_]+$') ~= nil
end

-- A decoded line is a complete event only if it has the whole item 9 envelope: `n` a positive whole number, `t` whole
-- seconds, `kind` a valid kind. A line with only some of it (for example {"n":999}) must not move the numbering.
local function is_complete_event(event)
    return type(event) == 'table'
        and type(event.n) == 'number' and event.n == math.floor(event.n) and event.n >= 1 and event.n <= MAX_EVENT_N
        and whole_seconds(event.t)
        and valid_kind(event.kind)
end

-- An unpadded decimal string, the form queue.lua uses for sequence numbers ('0', '123', '1000000').
local function sequence_digits(s)
    return type(s) == 'string' and (s == '0' or s:match('^[1-9][0-9]*$') ~= nil)
end

function M.new(fs, dir)
    -- The check is repeated here so no store can exist over a non-ASCII folder, whatever the caller did first.
    assert(M.check_bridge_dir(dir))
    return setmetatable({
        fs = fs,
        inbox = dir .. BS .. 'inbox',
        outbox = dir .. BS .. 'outbox',
        heartbeat = dir .. BS .. 'heartbeat.json',
        events = dir .. BS .. 'events.jsonl',
        next_n = nil,             -- the number the next event gets; nil until open_events has succeeded
        newline_first = false,    -- the events file may end in a fragment, so the next append starts with a newline
    }, S)
end

function S:list_requests() return self.fs.list(self.inbox) end
function S:list_replies() return self.fs.list(self.outbox) end

-- read_request(name) -> one of
--   { status = 'ok', text = <the file's exact bytes> }
--   { status = 'too_large', size = <bytes> }        (criterion 13: over the limit, so the file is never read)
--   { status = 'unreadable', error = <the OS error> }   (design item 19: not now; the caller asks again on the next poll)
-- Keeps no state, so a file that could not be read is simply tried again.
function S:read_request(name)
    local path = self.inbox .. BS .. name
    local size, err = self.fs.size(path)
    if not size then return { status = 'unreadable', error = err } end
    if size > core.MAX_REQUEST_BYTES then return { status = 'too_large', size = size } end
    local text
    text, err = self.fs.read(path)
    if not text then return { status = 'unreadable', error = err } end
    return { status = 'ok', text = text }
end

-- Design item 5: the reply is written under a temporary name and renamed, so a half-written reply is never a completed
-- request (the temporary name is not a canonical reply name, so queue.select ignores it). A reply name is a new name; a
-- rename onto an existing reply fails and the existing reply stays. `seq` is an unpadded decimal string.
function S:write_reply(seq, text)
    local final = self.outbox .. BS .. queue.filename(seq)
    local temp = final .. '.tmp'
    local ok, err = self.fs.write(temp, text)
    if not ok then return nil, err end
    ok, err = self.fs.rename(temp, final)
    if not ok then return nil, err end
    return true
end

-- Criterion 6, design items 9, 19 and 26. info = { character = string|nil, zone = string|nil, now = whole seconds,
-- waiting_for_sequence = digits|nil, unreadable_sequence = digits|nil }. Writes the content to a temporary file in the same
-- folder and replaces heartbeat.json with it in one call. One attempt: a refused replace (a reader holds the file open)
-- returns nil and the error and leaves the old heartbeat, and the caller tries again on a later normal update (item 26.2).
function S:publish_heartbeat(info)
    if not whole_seconds(info.now) then error('publish_heartbeat: now must be a whole number of seconds', 2) end
    local fields = {
        '"bridge_version":' .. json.encode(version.VERSION),
        core.string_field('character', info.character),
        core.string_field('zone', info.zone),
        '"state":"running"',
        '"written_at":' .. string.format('%d', info.now),
    }
    for _, name in ipairs({ 'waiting_for_sequence', 'unreadable_sequence' }) do
        local value = info[name]
        if value ~= nil then
            if not sequence_digits(value) then error('publish_heartbeat: ' .. name .. ' must be an unpadded decimal string', 2) end
            fields[#fields + 1] = '"' .. name .. '":' .. value
        end
    end
    local temp = self.heartbeat .. '.tmp'
    local ok, err = self.fs.write(temp, '{' .. table.concat(fields, ',') .. '}')
    if not ok then return nil, err end
    ok, err = self.fs.replace(temp, self.heartbeat)
    if not ok then return nil, err end
    return true
end

-- Design item 10.1 and 10.2, called once at start. Appends to the existing file (never truncates), finds the last complete
-- line that is a complete event (the whole envelope: n, t and kind) and continues from n + 1, and remembers whether the file ends in a fragment (an
-- interrupted append), in which case the first new event is preceded by a newline. Reads from the end of the file in
-- growing windows, so a long file is not read whole. Returns true, or nil and the error (the exhaustion message if the last
-- event already has the largest number; the store is then not opened).
function S:open_events()
    local fs = self.fs
    local size, err, code = fs.size(self.events)
    if not size then
        if code ~= 'not_found' then return nil, err end
        self.next_n, self.newline_first = 1, false
        return true
    end
    if size == 0 then
        self.next_n, self.newline_first = 1, false
        return true
    end

    local window = EVENTS_WINDOW
    local ends_with_newline
    while true do
        local start = math.max(0, size - window)
        local chunk
        chunk, err = fs.read_range(self.events, start, size - start)
        if not chunk then return nil, err end
        if ends_with_newline == nil then ends_with_newline = chunk:sub(-1) == '\n' end

        -- Only complete lines count: a line is complete only if a newline follows it (so a trailing fragment is never one)
        -- and, if the window starts inside the file, the first line is dropped because it may be cut short.
        local text = chunk
        if start > 0 then text = text:match('^[^\n]*\n(.*)$') or '' end
        local lines = {}
        for line in text:gmatch('([^\n]*)\n') do lines[#lines + 1] = line end
        for i = #lines, 1, -1 do
            local ok, event = pcall(json.decode, lines[i])
            if ok and is_complete_event(event) then
                if event.n >= MAX_EVENT_N then return nil, EXHAUSTED end   -- never fall back to an earlier event
                self.next_n, self.newline_first = event.n + 1, not ends_with_newline
                return true
            end
        end
        if start == 0 then
            self.next_n, self.newline_first = 1, not ends_with_newline
            return true
        end
        window = window * 2
    end
end

-- Members the bridge writes itself; a caller's field may not take their place (the decoder keeps the last duplicate key,
-- so a repeated name would override the envelope).
local ENVELOPE = { n = true, t = true, kind = true }

-- Returns the field rendered as `"name":value` and the name that is actually written: core.string_field writes `name_base64`
-- instead of `name` when the value has a byte 0x80 or above, and that written name is what must be unique.
local function event_field(field)
    if type(field.name) ~= 'string' or not field.name:match('^[a-z_][a-z0-9_]*$') then
        error('append_event: a field name must be lower-case letters, digits and underscores', 3)
    end
    if field.number ~= nil then
        if not sequence_digits(field.number) then error('append_event: a number field must be an unpadded decimal string', 3) end
        return '"' .. field.name .. '":' .. field.number, field.name
    end
    local rendered = core.string_field(field.name, field.string)
    return rendered, rendered:match('^"([a-z0-9_]+)":')
end

-- Criterion 7, design item 9. Appends one event as one line, `{"n":42,"t":1727612345,"kind":"chat","text":"..."}`, and
-- returns its number, or nil and the error (the number is then not used up; after MAX_EVENT_N the error is EXHAUSTED and
-- nothing is written). `t` is whole seconds; `kind` is one of our own
-- lower-case names; `fields` is an array of { name = ..., string = ... } (written by core.string_field, so item 16 applies)
-- or { name = ..., number = 'digits' }. After a failed append the next one starts with a newline, since the failed one may
-- have left a fragment (design item 10.2's rule applied to a running bridge).
function S:append_event(t, kind, fields)
    if not self.next_n then error('append_event: open_events must succeed first', 2) end
    if self.next_n > MAX_EVENT_N then return nil, EXHAUSTED end
    if not whole_seconds(t) then error('append_event: t must be a whole number of seconds', 2) end
    if not valid_kind(kind) then error('append_event: kind must be lower-case letters and underscores', 2) end
    local parts = { '"n":' .. string.format('%d', self.next_n), '"t":' .. string.format('%d', t), '"kind":' .. json.encode(kind) }
    local written = {}
    for _, field in ipairs(fields) do
        local rendered, name = event_field(field)
        if ENVELOPE[name] then error('append_event: a field may not be named n, t or kind', 2) end
        if written[name] then error('append_event: two fields would be written under the same name', 2) end
        written[name] = true
        parts[#parts + 1] = rendered
    end
    local line = '{' .. table.concat(parts, ',') .. '}\n'
    if self.newline_first then line = '\n' .. line end
    local ok, err = self.fs.append(self.events, line)
    if not ok then
        self.newline_first = true
        return nil, err
    end
    local n = self.next_n
    self.next_n, self.newline_first = n + 1, false
    return n
end

return M
