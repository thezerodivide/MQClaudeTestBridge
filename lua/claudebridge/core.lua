-- Request text to reply for the bridge (DL-021 design item 2; DL-022 step 3): decodes a request, validates its shape and
-- command, enforces the size limits and executes ping, eval and eval_many. Criteria 1, 4, 5, 10, 12 and 13; design items
-- 8, 9, 14, 15, 16, 18, 20 and 21.
-- Pure: every call into the game goes through the injected `env` (env.parse(expression) -> string, env.character() and
-- env.zone() -> string or nil), so nothing here calls MacroQuest or touches a file. Every path that fails a request goes
-- through one function (error_reply), so each bad-request case has one home.
local json = require 'claudebridge.json'
local version = require 'claudebridge.version'

local M = {
    MAX_EXPRESSION_BYTES = 2047,   -- criterion 12: the evidenced safe mq.parse input limit, no margin
    MAX_REQUEST_BYTES = 32768,     -- design item 14: a first guess under Protocol section 15
}

-- Every error message is a fixed ASCII string chosen here, one per specific failure; nothing from a request is quoted,
-- and the decoder's own messages are discarded because they embed the offending input (design item 20).
local MSG = {
    decode = 'request could not be decoded as JSON',
    shape = 'request has the wrong shape: it must be a JSON object with a string `command`',
    expression = 'request has the wrong shape: `expression` must be a string',
    expressions = 'request has the wrong shape: `expressions` must be a list of strings',
    unsupported = 'unsupported command',
    too_long = 'an expression is longer than ' .. M.MAX_EXPRESSION_BYTES .. ' bytes; nothing was evaluated',
    too_large = 'request is larger than ' .. M.MAX_REQUEST_BYTES .. ' bytes; it was not decoded',
}

-- Base64 (RFC 4648, with padding), by arithmetic so it does not depend on a bit library.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64_char(n) return B64:sub(n + 1, n + 1) end

function M.base64_encode(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = b64_char(math.floor(n / 262144) % 64)
        out[#out + 1] = b64_char(math.floor(n / 4096) % 64)
        out[#out + 1] = b and b64_char(math.floor(n / 64) % 64) or '='
        out[#out + 1] = c and b64_char(n % 64) or '='
    end
    return table.concat(out)
end

-- Design item 16: one helper writes every string field that comes from MacroQuest or from a request. It writes
-- `"name":"..."`, or `"name_base64":"..."` when the value has a byte 0x80 or above (exactly one of the two), or
-- `"name":null` for nil (design item 9). Bytes 0x00 to 0x7f are safe in a JSON string: the encoder escapes control
-- bytes, quote and backslash.
function M.string_field(name, value)
    if value == nil then return '"' .. name .. '":null' end
    if value:find('[\128-\255]') then
        return '"' .. name .. '_base64":' .. json.encode(M.base64_encode(value))
    end
    return '"' .. name .. '":' .. json.encode(value)
end

-- `seq` is an unpadded decimal string (from queue.lua), written as a JSON number with its digits exactly.
local function object(seq, fields)
    return '{"seq":' .. seq .. ',' .. table.concat(fields, ',') .. '}'
end

-- `command` is the recognized command name, or nil when the request failed before its command could be trusted. The
-- summary repeats the reply's fixed message (safe to log: it is ASCII chosen here) so a log can say why (Protocol section 8).
local function error_reply(seq, kind, message, command)
    local reply = object(seq, {
        '"ok":false',
        '"error":{"kind":' .. json.encode(kind) .. ',"message":' .. json.encode(message) .. '}',
    })
    return reply, { command = command, kind = kind, message = message }
end

-- A list of strings as the decoder returned it: no holes and no non-string elements. On its own this is NOT enough: the
-- approved vendored decoder turns JSON null into nil and returns {} for both [] and {}, so it would accept [null],
-- ["a",null] and {} as lists. expressions_count (below) checks the request text as well.
local function string_list(t)
    if type(t) ~= 'table' then return false end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    for i = 1, count do
        if type(t[i]) ~= 'string' then return false end
    end
    return true
end

-- A bounded structural check of the request TEXT, run only after the decoder has decoded it (design item 18). It extracts
-- no request values: it only answers whether the effective top-level `expressions` member is a JSON array whose elements
-- are all string literals, and if so how many. It is iterative (no recursion), skips string contents (including escaped
-- quotes) so nothing inside a string is mistaken for structure, resolves each top-level key with the decoder so escaped
-- key names read the same, and lets the last duplicate key win, as the decoder does. Any surprise returns nil (refuse).
local function skip_ws(text, i)
    return text:find('[^ \t\r\n]', i) or #text + 1
end

-- text[i] is an opening quote; returns the index after the closing quote, or nil if the string never ends. A backslash
-- always consumes the next character, so an odd run of backslashes escapes a quote and an even run does not.
local function skip_string(text, i)
    i = i + 1
    while true do
        local c = text:find('["\\]', i)
        if not c then return nil end
        if text:sub(c, c) == '"' then return c + 1 end
        i = c + 2
    end
end

-- Returns the index after the value that starts at text[i] (a string, an array or object with nesting, or a bare word).
local function skip_value(text, i)
    local c = text:sub(i, i)
    if c == '"' then return skip_string(text, i) end
    if c == '[' or c == '{' then
        local depth = 0
        repeat
            local ch = text:sub(i, i)
            if ch == '"' then
                i = skip_string(text, i)
                if not i then return nil end
            else
                if ch == '[' or ch == '{' then
                    depth = depth + 1
                elseif ch == ']' or ch == '}' then
                    depth = depth - 1
                end
                i = i + 1
            end
        until depth == 0 or i > #text
        return depth == 0 and i or nil
    end
    return text:find('[,}%]%s]', i) or #text + 1
end

local function expressions_count(text)
    local i = skip_ws(text, 1)
    if text:sub(i, i) ~= '{' then return nil end
    i = i + 1
    local first
    while true do
        i = skip_ws(text, i)
        local c = text:sub(i, i)
        if c == '}' then break end
        if c ~= '"' then return nil end
        local key_end = skip_string(text, i)
        if not key_end then return nil end
        local key = json.decode(text:sub(i, key_end - 1))
        i = skip_ws(text, key_end)
        if text:sub(i, i) ~= ':' then return nil end
        i = skip_ws(text, i + 1)
        local value_end = skip_value(text, i)
        if not value_end then return nil end
        if key == 'expressions' then first = i end
        i = skip_ws(text, value_end)
        c = text:sub(i, i)
        if c == '}' then break end
        if c ~= ',' then return nil end
        i = i + 1
    end
    if not first or text:sub(first, first) ~= '[' then return nil end

    i = skip_ws(text, first + 1)
    if text:sub(i, i) == ']' then return 0 end
    local count = 0
    while true do
        if text:sub(i, i) ~= '"' then return nil end     -- null, a number, true or false, an object, an array, a stray comma
        i = skip_string(text, i)
        if not i then return nil end
        count = count + 1
        i = skip_ws(text, i)
        local c = text:sub(i, i)
        if c == ']' then return count end
        if c ~= ',' then return nil end
        i = skip_ws(text, i + 1)
    end
end

local function too_long(expression)
    return #expression > M.MAX_EXPRESSION_BYTES
end

local commands = {}

function commands.ping(env, seq)
    local reply = object(seq, {
        '"ok":true',
        '"command":"ping"',
        '"bridge_version":' .. json.encode(version.VERSION),
        M.string_field('character', env.character()),
        M.string_field('zone', env.zone()),
        '"state":"running"',
    })
    return reply, { command = 'ping', kind = 'ok' }
end

function commands.eval(env, seq, request)
    local expression = request.expression
    if type(expression) ~= 'string' then return error_reply(seq, 'invalid_request', MSG.expression, 'eval') end
    if too_long(expression) then return error_reply(seq, 'expression_too_long', MSG.too_long, 'eval') end
    local value = env.parse(expression)
    local reply = object(seq, {
        '"ok":true',
        '"command":"eval"',
        M.string_field('expression', expression),
        M.string_field('value', value),
    })
    return reply, { command = 'eval', kind = 'ok' }
end

function commands.eval_many(env, seq, request, text)
    local expressions = request.expressions
    -- Three-way agreement: the decoder's list is a dense list of strings, the text check says the effective member is an
    -- array of only string literals, and both count the same. A failure of the text check counts as disagreement.
    local scanned_ok, count = pcall(expressions_count, text)
    if not (string_list(expressions) and scanned_ok and count == #expressions) then
        return error_reply(seq, 'invalid_request', MSG.expressions, 'eval_many')
    end
    -- Every expression is checked before any is evaluated (criterion 12).
    for i = 1, #expressions do
        if too_long(expressions[i]) then return error_reply(seq, 'expression_too_long', MSG.too_long, 'eval_many') end
    end
    local results = {}
    for i = 1, #expressions do
        local value = env.parse(expressions[i])
        results[i] = '{' .. M.string_field('expression', expressions[i]) .. ',' .. M.string_field('value', value) .. '}'
    end
    local reply = object(seq, {
        '"ok":true',
        '"command":"eval_many"',
        '"results":[' .. table.concat(results, ',') .. ']',
    })
    return reply, { command = 'eval_many', kind = 'ok' }
end

-- handle(env, seq, text) -> reply_text, summary
-- summary = { command = 'ping' | 'eval' | 'eval_many' | nil, kind = 'ok' | an error kind, message = the fixed error
-- message or nil } for the loop's log. The command is nil whenever it was not recognized (undecodable, no command,
-- unsupported): a command name from a request is external text and is never passed on.
function M.handle(env, seq, text)
    -- Criterion 13: a request over the limit is never decoded.
    if #text > M.MAX_REQUEST_BYTES then return error_reply(seq, 'request_too_large', MSG.too_large) end

    local ok, request = pcall(json.decode, text)
    if not ok then return error_reply(seq, 'invalid_request', MSG.decode) end
    if type(request) ~= 'table' or type(request.command) ~= 'string' then
        return error_reply(seq, 'invalid_request', MSG.shape)
    end

    local command = commands[request.command]
    if not command then return error_reply(seq, 'unsupported_command', MSG.unsupported) end
    return command(env, seq, request, text)
end

return M
