-- Tests for claudebridge/core.lua (Step 3 of DL-022: request text to reply).
-- Requirement sources (DL-018 / DL-021 in docs/decision_log.md), named per test below:
--   * Criterion 1: ping's reply has the same sequence number and holds the bridge version, character, zone and state.
--   * Criterion 4: eval's reply has the original expression and the exact string mq.parse returned; NULL stays NULL,
--     an empty string stays empty; bytes are preserved.
--   * Criterion 5: eval_many gives one reply, an entry per expression in the order given; design item 18: an empty
--     list is a successful reply with an empty results list.
--   * Criterion 10: only ping, eval and eval_many run; an unsupported command or an undecodable or wrongly shaped
--     request gets an error reply with the same sequence number and executes nothing.
--   * Criterion 12: an expression over 2047 BYTES is never evaluated; for eval_many every expression is checked
--     before any is evaluated.
--   * Criterion 13 with design items 14 and 15: a request over 32,768 bytes is never decoded and gets the distinct
--     kind request_too_large; a request at exactly the limit is accepted.
--   * Design item 8: reply and error shapes and the four error kinds. Item 16: a string field from MacroQuest or from a
--     request is written as `name`, or as `name_base64` if it has a byte 0x80 or above, exactly one of the two.
--     Item 20: every error message is a fixed ASCII string chosen by our code; nothing from the request is quoted.
--     Item 9: character and zone are null when no character is in the game. Item 21: ping reports the build's version.
-- core.handle(env, seq, text) returns the reply text and a small summary {command=, kind=} for the loop's log
-- (Protocol section 8); env is the injected game adapter (parse, character, zone), so no MacroQuest call is made here.
local T = require 'harness.t'
local test, expect = T.test, T.expect

local json = require 'claudebridge.json'
local version = require 'claudebridge.version'
local core = require 'claudebridge.core'

-- A fake game: records every expression it is asked to parse and answers from a table (default 'NULL').
local function fake_env(answers)
  local env = { calls = {}, char = 'Testchar', zone_name = 'bazaar' }
  env.parse = function(expr)
    env.calls[#env.calls + 1] = expr
    local v = answers and answers[expr]
    if v == nil then return 'NULL' end
    return v
  end
  env.character = function() return env.char end
  env.zone = function() return env.zone_name end
  return env
end

local function run(text, env, seq)
  env = env or fake_env()
  local reply, summary = core.handle(env, seq or '7', text)
  return reply, summary, env
end

local function decoded(reply)
  return json.decode(reply)
end

local function printable_ascii(s) return not s:find('[^\32-\126]') end

-- A base64 decoder written here, independent of the code under test, so the tests do not check the encoder against itself.
local function b64_decode(s)
  local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local index = {}
  for i = 1, #alphabet do index[alphabet:sub(i, i)] = i - 1 end
  local out, bits, nbits = {}, 0, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c ~= '=' then
      bits = bits * 64 + assert(index[c], 'not a base64 character')
      nbits = nbits + 6
      if nbits >= 8 then
        nbits = nbits - 8
        local byte = math.floor(bits / 2 ^ nbits)
        out[#out + 1] = string.char(byte)
        bits = bits - byte * 2 ^ nbits
      end
    end
  end
  return table.concat(out)
end

local function ping(text) return run(text or '{"command":"ping"}') end

-- ---- Criterion 1: ping ------------------------------------------------------------------------------------------------

test('ping replies with the same sequence number and the version, character, zone and state (criterion 1, item 21)', function()
  local reply = run('{"command":"ping"}', fake_env(), '123')
  local r = decoded(reply)
  expect.equal(r.seq, 123)
  expect.equal(r.ok, true)
  expect.equal(r.command, 'ping')
  expect.equal(r.bridge_version, version.VERSION)
  expect.equal(r.character, 'Testchar')
  expect.equal(r.zone, 'bazaar')
  expect.equal(r.state, 'running')
end)

test('ping ignores extra fields in the request and still answers (criterion 1)', function()
  local r = decoded((run('{"command":"ping","extra":[1,2],"more":{"a":true}}')))
  expect.equal(r.ok, true)
  expect.equal(r.command, 'ping')
end)

test('ping with no character in the game gives null for character and zone (design item 9)', function()
  local env = fake_env()
  env.char, env.zone_name = nil, nil
  local reply = run('{"command":"ping"}', env)
  expect.truthy(reply:find('"character":null', 1, true), reply)
  expect.truthy(reply:find('"zone":null', 1, true), reply)
  local r = decoded(reply)
  expect.equal(r.ok, true)
  expect.equal(r.character, nil)
end)

test('a character or zone name with a byte 0x80 or above is written as character_base64 / zone_base64 only (item 16)', function()
  local env = fake_env()
  env.char, env.zone_name = 'Ren\233e', 'Caf\195\169 Zone'
  local r = decoded((run('{"command":"ping"}', env)))
  expect.equal(r.character, nil)
  expect.equal(r.zone, nil)
  expect.equal(b64_decode(r.character_base64), 'Ren\233e')
  expect.equal(b64_decode(r.zone_base64), 'Caf\195\169 Zone')
end)

-- ---- Criterion 4: eval ------------------------------------------------------------------------------------------------

test('eval replies with the expression and the exact string parse returned, and parses once (criterion 4, item 8)', function()
  local env = fake_env({ ['${Me.PctHPs}'] = '87' })
  local reply, summary = run('{"command":"eval","expression":"${Me.PctHPs}"}', env, '42')
  local r = decoded(reply)
  expect.equal(r.seq, 42)
  expect.equal(r.ok, true)
  expect.equal(r.command, 'eval')
  expect.equal(r.expression, '${Me.PctHPs}')
  expect.equal(r.value, '87')
  expect.equal(env.calls, { '${Me.PctHPs}' })
  expect.equal(summary.command, 'eval')
  expect.equal(summary.kind, 'ok')
end)

test('NULL stays NULL and an empty string stays empty; nothing is trimmed or changed (criterion 4)', function()
  local env = fake_env({ a = 'NULL', b = '', c = '  padded \t ', d = 'null' })
  for expr, want in pairs({ a = 'NULL', b = '', c = '  padded \t ', d = 'null' }) do
    local r = decoded((run('{"command":"eval","expression":"' .. expr .. '"}', env)))
    expect.equal(r.value, want, 'value for ' .. expr)
    expect.equal(r.value_base64, nil)
  end
end)

test('every byte 0x00 to 0x7f in a value comes back exactly, as a plain value (criterion 4, item 16)', function()
  local all = {}
  for b = 0, 127 do all[#all + 1] = string.char(b) end
  local value = table.concat(all)
  local env = fake_env({ x = value })
  local r = decoded((run('{"command":"eval","expression":"x"}', env)))
  expect.equal(r.value, value)
  expect.equal(r.value_base64, nil)
end)

test('a value with any byte 0x80 or above is written as value_base64 only, with the exact bytes (item 16)', function()
  for b = 128, 255 do
    local value = 'a' .. string.char(b) .. 'z'
    local r = decoded((run('{"command":"eval","expression":"x"}', fake_env({ x = value }))))
    expect.equal(r.value, nil, 'plain value present for byte ' .. b)
    expect.equal(b64_decode(r.value_base64), value, 'byte ' .. b)
  end
  local every = {}
  for b = 0, 255 do every[#every + 1] = string.char(b) end
  local value = table.concat(every)
  local r = decoded((run('{"command":"eval","expression":"x"}', fake_env({ x = value }))))
  expect.equal(r.value, nil)
  expect.equal(b64_decode(r.value_base64), value)
end)

test('an expression with a byte 0x80 or above is echoed as expression_base64 and parsed with its exact bytes (item 16)', function()
  local expr = '${Spawn[Caf\195\169]}'
  local env = fake_env()
  local reply = run(json.encode({ command = 'eval', expression = expr }), env)
  local r = decoded(reply)
  expect.equal(r.expression, nil)
  expect.equal(b64_decode(r.expression_base64), expr)
  expect.equal(env.calls, { expr })
end)

-- ---- Criterion 5: eval_many ---------------------------------------------------------------------------------------------

test('eval_many gives one reply with an entry per expression, in the order given, with the same rules (criterion 5)', function()
  local env = fake_env({ a = 'one', b = '', c = 'x\200y', d = 'four' })
  local reply, summary = run('{"command":"eval_many","expressions":["c","a","b","d","a"]}', env, '9')
  local r = decoded(reply)
  expect.equal(r.seq, 9)
  expect.equal(r.ok, true)
  expect.equal(r.command, 'eval_many')
  expect.equal(#r.results, 5)
  expect.equal(r.results[1].expression, 'c')
  expect.equal(b64_decode(r.results[1].value_base64), 'x\200y')
  expect.equal(r.results[1].value, nil)
  expect.equal(r.results[2], { expression = 'a', value = 'one' })
  expect.equal(r.results[3], { expression = 'b', value = '' })
  expect.equal(r.results[4], { expression = 'd', value = 'four' })
  expect.equal(r.results[5], { expression = 'a', value = 'one' })
  expect.equal(env.calls, { 'c', 'a', 'b', 'd', 'a' })
  expect.equal(summary.command, 'eval_many')
  expect.equal(summary.kind, 'ok')
end)

test('an empty eval_many list is a successful reply with an empty results list (design item 18)', function()
  local env = fake_env()
  local reply = run('{"command":"eval_many","expressions":[]}', env, '5')
  expect.equal(reply, '{"seq":5,"ok":true,"command":"eval_many","results":[]}')
  expect.equal(env.calls, {})
end)

-- ---- Criterion 12: the 2047-byte expression limit --------------------------------------------------------------------

test('an expression of exactly 2047 bytes is accepted and parsed; 2048 is refused and never parsed (criterion 12)', function()
  local ok_expr = string.rep('A', core.MAX_EXPRESSION_BYTES)
  local env = fake_env()
  local r = decoded((run(json.encode({ command = 'eval', expression = ok_expr }), env)))
  expect.equal(r.ok, true)
  expect.equal(env.calls, { ok_expr })

  local env2 = fake_env()
  local reply, summary = run(json.encode({ command = 'eval', expression = ok_expr .. 'A' }), env2, '31')
  local e = decoded(reply)
  expect.equal(e.seq, 31)
  expect.equal(e.ok, false)
  expect.equal(e.error.kind, 'expression_too_long')
  expect.equal(env2.calls, {})
  expect.equal(summary.kind, 'expression_too_long')
end)

test('the limit counts BYTES: 1024 two-byte characters (2048 bytes) is refused, 2047 bytes is accepted (criterion 12)', function()
  local two_byte = string.rep('\195\169', 1024)          -- 1024 characters, 2048 bytes
  local env = fake_env()
  local e = decoded((run(json.encode({ command = 'eval', expression = two_byte }), env)))
  expect.equal(e.error.kind, 'expression_too_long')
  expect.equal(env.calls, {})
  local fits = string.rep('\195\169', 1023) .. 'A'       -- 1024 characters, 2047 bytes
  local env2 = fake_env()
  local r = decoded((run(json.encode({ command = 'eval', expression = fits }), env2)))
  expect.equal(r.ok, true)
  expect.equal(env2.calls, { fits })
end)

test('eval_many checks every expression before evaluating any: one oversized expression means none is evaluated (criterion 12)', function()
  local big = string.rep('B', core.MAX_EXPRESSION_BYTES + 1)
  local env = fake_env()
  local e = decoded((run(json.encode({ command = 'eval_many', expressions = { 'a', 'b', big } }), env)))
  expect.equal(e.ok, false)
  expect.equal(e.error.kind, 'expression_too_long')
  expect.equal(env.calls, {})
end)

test('eval_many accepts expressions of exactly 2047 bytes (criterion 12)', function()
  local edge = string.rep('C', core.MAX_EXPRESSION_BYTES)
  local env = fake_env()
  local r = decoded((run(json.encode({ command = 'eval_many', expressions = { edge, 'a' } }), env)))
  expect.equal(r.ok, true)
  expect.equal(env.calls, { edge, 'a' })
end)

-- ---- Criterion 13 with design items 14 and 15: request size --------------------------------------------------------------

local function padded_ping(total)
  local base = '{"command":"ping"}'
  return base .. string.rep(' ', total - #base)
end

test('the request size limit is 32,768 bytes (design item 14)', function()
  expect.equal(core.MAX_REQUEST_BYTES, 32768)
end)

test('a request of exactly 32,768 bytes is accepted (criterion 13)', function()
  local r = decoded((run(padded_ping(32768))))
  expect.equal(r.ok, true)
  expect.equal(r.command, 'ping')
end)

test('a request over 32,768 bytes is refused as request_too_large and is not processed, even though it is valid (criterion 13, item 15)', function()
  -- A valid ping padded past the limit: if it were decoded it would succeed. The error proves it was not.
  local reply, summary, env = run(padded_ping(32769), fake_env(), '77')
  local e = decoded(reply)
  expect.equal(e.seq, 77)
  expect.equal(e.ok, false)
  expect.equal(e.error.kind, 'request_too_large')
  expect.equal(summary.kind, 'request_too_large')
  expect.equal(#env.calls, 0)
end)

test('an oversized request that is also not valid JSON is still request_too_large, not invalid_request (criterion 13)', function()
  local e = decoded((run(string.rep('x', 40000))))
  expect.equal(e.error.kind, 'request_too_large')
end)

-- ---- Criterion 10: bad requests, with fixed messages (design items 8 and 20) ----------------------------------------------

local MSG_DECODE = 'request could not be decoded as JSON'
local MSG_LIST = 'request has the wrong shape: `expressions` must be a list of strings'
local MSG_UNSUPPORTED = 'unsupported command'

local function error_of(text, seq)
  local reply, summary, env = run(text, fake_env(), seq or '11')
  local r = decoded(reply)
  expect.equal(r.ok, false)
  return r.error, r, summary, env
end

test('text that is not valid JSON is invalid_request with the fixed decode message, and nothing runs (criteria 10; item 20)', function()
  -- Inputs the approved vendored decoder rejects (DL-021 design item 13's evidence note: empty text, truncated text,
  -- trailing garbage, a raw control character in a string). Its known leniencies (a trailing comma, hex numbers, last
  -- duplicate key wins) are not requirements either way and are not asserted.
  local bad = {
    '', '{', '{"command":', 'not json', '{"command":"ping"} trailing', '[1,2',
    '{"command":"ev\nal"}',   -- a raw newline inside a string is not valid JSON
  }
  for _, text in ipairs(bad) do
    local err, r, _, env = error_of(text, '12')
    expect.equal(r.seq, 12)
    expect.equal(err.kind, 'invalid_request', text)
    expect.equal(err.message, MSG_DECODE, text)
    expect.equal(#env.calls, 0)
  end
end)

test('deeply nested JSON under the size limit is invalid_request, not a crash (criterion 13 evidence: catchable stack overflow)', function()
  local err = error_of(string.rep('[', 20000))
  expect.equal(err.kind, 'invalid_request')
  expect.equal(err.message, MSG_DECODE)
end)

test('valid JSON of the wrong shape is invalid_request (criterion 10, design item 8)', function()
  local shapes = {
    '[]', '5', '"ping"', 'null', 'true', '{}', '{"command":5}', '{"command":null}', '{"command":["ping"]}',
    '{"command":"eval"}', '{"command":"eval","expression":5}', '{"command":"eval","expression":null}',
    '{"command":"eval","expression":["a"]}',
  }
  for _, text in ipairs(shapes) do
    local err, _, _, env = error_of(text)
    expect.equal(err.kind, 'invalid_request', text)
    expect.equal(#env.calls, 0, text)
  end
end)

test('eval_many with expressions that are not a list of strings is invalid_request with the fixed message (item 18, 20)', function()
  local shapes = {
    '{"command":"eval_many"}',
    '{"command":"eval_many","expressions":"a"}',
    '{"command":"eval_many","expressions":5}',
    '{"command":"eval_many","expressions":{"a":"b"}}',
    '{"command":"eval_many","expressions":[1]}',
    '{"command":"eval_many","expressions":["a",2]}',
    '{"command":"eval_many","expressions":[{"a":1}]}',
    '{"command":"eval_many","expressions":[true]}',
    '{"command":"eval_many","expressions":[null,"a"]}',
  }
  for _, text in ipairs(shapes) do
    local err, _, _, env = error_of(text)
    expect.equal(err.kind, 'invalid_request', text)
    expect.equal(err.message, MSG_LIST, text)
    expect.equal(#env.calls, 0, text)
  end
end)

test('a command that is not ping, eval or eval_many is unsupported_command, nothing runs, and nothing is quoted (criterion 10, item 20)', function()
  local commands = { 'cmd', 'Ping', 'EVAL', 'eval ', '', 'evalmany', 'run_test', 'ping\226' }
  for _, c in ipairs(commands) do
    local err, _, summary, env = error_of(json.encode({ command = c, expression = 'x' }))
    expect.equal(err.kind, 'unsupported_command', c)
    expect.equal(err.message, MSG_UNSUPPORTED, c)
    expect.equal(#env.calls, 0)
    expect.equal(summary.command, nil, 'the command name is external text and must not reach the summary')
  end
end)

test('an error reply holds the same sequence number and exactly the fields seq, ok, error.kind, error.message (design item 8)', function()
  local reply = run('{"command":"cmd"}', fake_env(), '5000000')
  expect.equal(reply, '{"seq":5000000,"ok":false,"error":{"kind":"unsupported_command","message":"unsupported command"}}')
end)

test('no text from the request appears in any error reply, and every error reply is printable ASCII (design item 20)', function()
  local marker = 'ZZQUOTEMARKERZZ'
  local high = '\233\195\169'
  local requests = {
    json.encode({ command = marker .. high }),                       -- unsupported command with external text
    '{"command":"' .. marker .. '"',                                   -- malformed JSON containing the marker
    '{"command":"eval","expression":5,"note":"' .. marker .. high .. '"}',
    json.encode({ command = 'eval', expression = marker .. string.rep('A', 3000) .. high }),  -- too long
    json.encode({ command = 'eval_many', expressions = { marker .. high, 5 } }),
    marker .. string.rep('x', 40000) .. high,                          -- too large
  }
  for _, text in ipairs(requests) do
    local reply = run(text)
    expect.falsy(reply:find(marker, 1, true), 'request text leaked: ' .. reply:sub(1, 80))
    expect.truthy(printable_ascii(reply), 'reply is not printable ASCII')
    expect.equal(decoded(reply).ok, false)
  end
end)

test('each kind of failure has its own fixed message, the same every time, and the four kinds are the approved ones (items 8, 15, 20)', function()
  local function message_and_kind(text)
    local err = error_of(text)
    return err.kind, err.message
  end
  local long_kind, long_msg = message_and_kind(json.encode({ command = 'eval', expression = string.rep('A', 2048) }))
  local large_kind, large_msg = message_and_kind(string.rep(' ', 40000))
  local dec_kind, dec_msg = message_and_kind('{')
  local shape_kind, shape_msg = message_and_kind('{"command":"eval"}')
  local uns_kind, uns_msg = message_and_kind('{"command":"cmd"}')
  expect.equal(long_kind, 'expression_too_long')
  expect.equal(large_kind, 'request_too_large')
  expect.equal(dec_kind, 'invalid_request')
  expect.equal(shape_kind, 'invalid_request')
  expect.equal(uns_kind, 'unsupported_command')
  -- one message per specific failure: all five differ
  local seen = {}
  for _, m in ipairs({ long_msg, large_msg, dec_msg, shape_msg, uns_msg }) do
    expect.falsy(seen[m], 'two failures share the message: ' .. m)
    seen[m] = true
  end
  -- fixed: a different bad input of the same kind gives the same message
  local _, other = message_and_kind('[1,')
  expect.equal(other, dec_msg)
  local _, other_long = message_and_kind(json.encode({ command = 'eval', expression = string.rep('Q', 5000) }))
  expect.equal(other_long, long_msg)
end)

-- ---- Design item 18 with the decoder's ambiguities closed: an eval_many list is a list of strings, exactly ----------------------
-- The approved vendored decoder turns JSON null into nil and returns {} for both [] and {}, so on its own it accepts
-- [null], ["a",null] and {} as if they were lists. The request text is therefore also checked directly: the effective
-- `expressions` member must be a JSON array whose elements are all string literals, and the decoder and that check must
-- agree on the count, or the request is invalid_request (fail closed).

local EM = '{"command":"eval_many","expressions":'

local function eval_many_result(text)
  local env = fake_env()
  local reply, summary = core.handle(env, '3', text)
  return decoded(reply), summary, env
end

local function expect_invalid_list(text)
  local r, summary, env = eval_many_result(text)
  expect.equal(r.ok, false, text)
  expect.equal(r.error.kind, 'invalid_request', text)
  expect.equal(r.error.message, MSG_LIST, text)
  expect.equal(summary.kind, 'invalid_request', text)
  expect.equal(#env.calls, 0, 'nothing may be evaluated: ' .. text)
end

test('null, an empty object and other decoder-ambiguous shapes are refused, and nothing is evaluated (design item 18)', function()
  local refused = {
    EM .. '[null]}',            -- decodes to an empty list
    EM .. '["a",null]}',        -- decodes to ["a"]
    EM .. '["a",null,null]}',   -- multiple trailing nulls
    EM .. '[null,null]}',
    EM .. '["a",null,"b"]}',    -- a hole
    EM .. '[null,"a"]}',
    EM .. '{}}',                -- an empty object is not an empty list
    EM .. '{"0":"a"}}',
    EM .. '["a",]}',            -- a trailing comma: the decoder accepts it, the text is not a list of strings
    EM .. '[["a"]]}',
    EM .. '[{"a":"b"}]}',
    EM .. '[1]}', EM .. '[true]}', EM .. '[false]}', EM .. '[-1.5e3]}', EM .. '[0x10]}',
    EM .. '"a"}', EM .. '5}', EM .. 'null}', EM .. 'true}',
  }
  for _, text in ipairs(refused) do expect_invalid_list(text) end
  -- The decoder itself rejects a leading comma, so this one is an undecodable request (design item 20's decode message).
  local r, _, env = eval_many_result(EM .. '[,"a"]}')
  expect.equal(r.error.kind, 'invalid_request')
  expect.equal(r.error.message, MSG_DECODE)
  expect.equal(#env.calls, 0)
end)

test('an empty array is still an empty list and succeeds with no results (design item 18)', function()
  local r, _, env = eval_many_result(EM .. '[]}')
  expect.equal(r.ok, true)
  expect.equal(#r.results, 0)
  expect.equal(#env.calls, 0)
  local spaced = eval_many_result('{ "command" : "eval_many" ,\n "expressions" :\n [ \t ] \n}')
  expect.equal(spaced.ok, true)
end)

test('lists of strings are accepted with whitespace anywhere between tokens, and each string is evaluated (design item 18)', function()
  local r, _, env = eval_many_result('{ "command" : "eval_many" ,\n "expressions" : [ "a" ,\n\t"b" , "c" ] \n}')
  expect.equal(r.ok, true)
  expect.equal(env.calls, { 'a', 'b', 'c' })
end)

test('quotes, backslashes, brackets, braces, commas, colons and the word null INSIDE strings are just text (design item 18)', function()
  -- Built with the encoder so the escapes are right; the expressions include odd and even runs of backslashes before a
  -- quote, which is what a string-boundary bug gets wrong.
  local expressions = {
    'a\\', 'b"', '\\"', '\\\\"', '"\\', '\\\\\\', 'x\\\\"y', '"', '""',
    'a]b', '[', ']', '{', '}', ',', ':', 'a,b', '"expressions":{}', '["a",null]', 'null', 'x null y', '${If[${Me.ID},1,null]}',
    '}{][', '\1\2', 'caf\195\169',
  }
  local r, _, env = eval_many_result(json.encode({ command = 'eval_many', expressions = expressions }))
  expect.equal(r.ok, true)
  expect.equal(env.calls, expressions)
  expect.equal(#r.results, #expressions)
end)

test('the `expressions` key may be written with escapes; the effective member is the one the decoder reads (design item 18)', function()
  local r, _, env = eval_many_result('{"command":"eval_many","expr\\u0065ssions":["a","b"]}')
  expect.equal(r.ok, true)
  expect.equal(env.calls, { 'a', 'b' })
  local r2, _, env2 = eval_many_result('{"command":"eval_many","\\u0065xpressions":["c"]}')
  expect.equal(r2.ok, true)
  expect.equal(env2.calls, { 'c' })
  expect_invalid_list('{"command":"eval_many","expr\\u0065ssions":{}}')
  expect_invalid_list('{"command":"eval_many","expr\\u0065ssions":["a",null]}')
end)

test('with duplicate top-level keys the LAST one is the effective one, as the decoder reads it (item 13 evidence: last wins)', function()
  local r, _, env = eval_many_result(EM .. '["a","b"],"expressions":["c"]}')
  expect.equal(r.ok, true)
  expect.equal(env.calls, { 'c' })
  expect_invalid_list(EM .. '["a"],"expressions":{}}')
  expect_invalid_list(EM .. '["a"],"expressions":["b",null]}')
  local r2, _, env2 = eval_many_result(EM .. '{},"expressions":["a","b"]}')
  expect.equal(r2.ok, true)
  expect.equal(env2.calls, { 'a', 'b' })
end)

test('a key named expressions deeper in the request, or inside a string value, is not the request\'s expressions (design item 18)', function()
  local r, _, env = eval_many_result('{"command":"eval_many","meta":{"expressions":{}},"expressions":["a"]}')
  expect.equal(r.ok, true)
  expect.equal(env.calls, { 'a' })
  local r2, _, env2 = eval_many_result('{"command":"eval_many","note":"\\"expressions\\":{}","expressions":["a"]}')
  expect.equal(r2.ok, true)
  expect.equal(env2.calls, { 'a' })
  local r3, _, env3 = eval_many_result('{"command":"eval_many","list":[{"expressions":["x"]}],"expressions":["a","b"]}')
  expect.equal(r3.ok, true)
  expect.equal(env3.calls, { 'a', 'b' })
  -- and a decoy alone does not stand in for the real member
  expect_invalid_list('{"command":"eval_many","meta":{"expressions":["a"]}}')
  expect_invalid_list('{"command":"eval_many","note":"\\"expressions\\":[\\"a\\"]"}')
end)

test('other members of any shape do not disturb the check, including ones the decoder is lenient about (design item 18)', function()
  local shapes = {
    '{"command":"eval_many","a":null,"b":[1,{"c":[]}],"expressions":["x"],"d":0x10,"e":-1.5e2}',
    '{"command":"eval_many","expressions":["x"],"trailing":"comma",}',
    '{"command":"eval_many","n":"a\\\\","expressions":["x"]}',
  }
  for _, text in ipairs(shapes) do
    local r, _, env = eval_many_result(text)
    expect.equal(r.ok, true, text)
    expect.equal(env.calls, { 'x' }, text)
  end
end)

test('a request at the 32 KiB limit made of escape-heavy strings is decoded and checked correctly (criterion 13, design item 18)', function()
  local one = string.rep('\\"', 30) .. string.rep('\\\\', 5) .. '"x'          -- escape-heavy, ends with a quote
  local expressions = {}
  local size = #json.encode({ command = 'eval_many', expressions = {} })
  while true do
    local piece = #json.encode(one) + 1
    if size + piece > core.MAX_REQUEST_BYTES then break end
    expressions[#expressions + 1] = one
    size = size + piece
  end
  local text = json.encode({ command = 'eval_many', expressions = expressions })
  -- pad with spaces inside the object so the request is exactly the limit
  text = text:sub(1, -2) .. string.rep(' ', core.MAX_REQUEST_BYTES - #text) .. '}'
  expect.equal(#text, core.MAX_REQUEST_BYTES)
  local r, _, env = eval_many_result(text)
  expect.equal(r.ok, true)
  expect.equal(#env.calls, #expressions)
  expect.equal(env.calls[1], one)
  expect.truthy(#expressions > 50, 'the test must actually be large')
end)

test('if the text check itself fails, the request is invalid_request with the fixed message and nothing escapes (fail closed)', function()
  local original = json.decode
  local calls = 0
  T.patch(json, 'decode', function(text)
    calls = calls + 1
    if calls == 1 then return original(text) end       -- the whole request decodes normally
    error('simulated failure inside the text check')  -- the check decodes a key token: make it blow up
  end)
  local env = fake_env()
  local reply = core.handle(env, '3', EM .. '["a"]}')
  local r = original(reply)                             -- read the reply with the real decoder, not the patched one
  expect.equal(r.ok, false)
  expect.equal(r.error.kind, 'invalid_request')
  expect.equal(r.error.message, MSG_LIST)
  expect.equal(#env.calls, 0)
end)

test('if the decoder and the text check disagree on the count, the request is refused (fail closed)', function()
  -- The text says one string; the (patched) decoder reports two. Neither is trusted over the other.
  local original = json.decode
  local calls = 0
  T.patch(json, 'decode', function(text)
    calls = calls + 1
    if calls == 1 then return { command = 'eval_many', expressions = { 'a', 'b' } } end
    return original(text)
  end)
  local env = fake_env()
  local reply = core.handle(env, '3', EM .. '["a"]}')
  local r = original(reply)
  expect.equal(r.ok, false)
  expect.equal(r.error.kind, 'invalid_request')
  expect.equal(#env.calls, 0)
end)

test('each of the three checks refuses on its own: the text check alone, the decoder-list check alone (design item 18)', function()
  -- The decoder is patched so that two of the three agree and only one objects; the request must still be refused.
  local original = json.decode
  local function refused_when_decoder_returns(list, text)
    local calls = 0
    local restore = json.decode
    json.decode = function(t)
      calls = calls + 1
      if calls == 1 then return { command = 'eval_many', expressions = list } end
      return original(t)
    end
    local env = fake_env()
    local reply = core.handle(env, '3', text)
    json.decode = restore
    local r = original(reply)
    expect.equal(r.ok, false, text)
    expect.equal(r.error.kind, 'invalid_request', text)
    expect.equal(#env.calls, 0, text)
  end
  -- Text check alone: the decoder says a clean list of one string and the counts agree, but the TEXT holds a non-string.
  refused_when_decoder_returns({ 'x' }, EM .. '[null]}')
  refused_when_decoder_returns({ 'x' }, EM .. '[1]}')
  refused_when_decoder_returns({ 'a', 'b' }, EM .. '["a",true]}')
  refused_when_decoder_returns({ 'x' }, EM .. '{}}')
  -- Decoder-list check alone: the text is a clean array of two strings and the counts agree, but the decoded list is not.
  refused_when_decoder_returns({ 'a', 5 }, EM .. '["a","b"]}')
  refused_when_decoder_returns({ 'a', nil, 'c' }, EM .. '["a","b","c"]}')
end)

-- ---- Protocol section 8: what the loop can log ------------------------------------------------------------------------------

test('the summary of a failed request carries the same fixed message as its reply, so a log can say why; a success has none (Protocol 8)', function()
  local cases = {
    '{', '{}', '{"command":"eval"}', '{"command":"eval_many","expressions":5}', '{"command":"cmd"}',
    json.encode({ command = 'eval', expression = string.rep('A', 2048) }), string.rep(' ', 40000),
  }
  local seen = {}
  for _, text in ipairs(cases) do
    local reply, summary = run(text)
    local err = decoded(reply).error
    expect.equal(summary.kind, err.kind)
    expect.equal(summary.message, err.message)
    seen[summary.message] = true
  end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  expect.equal(distinct, #cases, 'the loop must be able to tell these failures apart')
  local _, ok_summary = run('{"command":"ping"}')
  expect.equal(ok_summary.message, nil)
end)

test('the summary names the command once it was recognized, even if the request then failed, and never otherwise (Protocol 8, item 20)', function()
  local _, s1 = run('{"command":"eval"}')
  expect.equal(s1.command, 'eval')
  local _, s2 = run('{"command":"eval_many","expressions":"a"}')
  expect.equal(s2.command, 'eval_many')
  local _, s3 = run(json.encode({ command = 'eval_many', expressions = { string.rep('A', 2048) } }))
  expect.equal(s3.command, 'eval_many')
  for _, text in ipairs({ '{', '{}', '{"command":"cmd"}', string.rep(' ', 40000) }) do
    local _, s = run(text)
    expect.equal(s.command, nil, 'command must be nil when it was not recognized: ' .. text:sub(1, 20))
  end
end)

-- ---- Sequence numbers in replies (design item 8: the number is the file name; exact at any size) -------------------------

test('the reply carries the sequence number exactly, however long (design item 8: no upper bound)', function()
  local reply = run('{"command":"ping"}', fake_env(), '123456789012345678901234567890')
  expect.truthy(reply:find('"seq":123456789012345678901234567890,', 1, true), reply)
  local bad = run('{', fake_env(), '123456789012345678901234567890')
  expect.truthy(bad:find('"seq":123456789012345678901234567890,', 1, true), bad)
end)

-- ---- The shared field helper (design item 16: one helper writes name / name_base64 fields) ---------------------------------

test('base64_encode matches the RFC 4648 test vectors', function()
  -- RFC 4648 section 10.
  local vectors = { [''] = '', f = 'Zg==', fo = 'Zm8=', foo = 'Zm9v', foob = 'Zm9vYg==', fooba = 'Zm9vYmE=', foobar = 'Zm9vYmFy' }
  for plain, want in pairs(vectors) do
    expect.equal(core.base64_encode(plain), want, 'vector for [' .. plain .. ']')
  end
  expect.equal(core.base64_encode('\255\254'), '//4=')
end)

test('string_field writes exactly one of name and name_base64, and null for nil (design items 9 and 16)', function()
  expect.equal(core.string_field('value', 'abc'), '"value":"abc"')
  expect.equal(core.string_field('value', ''), '"value":""')
  expect.equal(core.string_field('value', 'a"b\\c\n'), '"value":"a\\"b\\\\c\\n"')
  expect.equal(core.string_field('value', '\255'), '"value_base64":"/w=="')
  expect.equal(core.string_field('character', nil), '"character":null')
end)
