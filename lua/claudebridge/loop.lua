-- The bridge's control logic (DL-021 design item 2; DL-022 step 5): startup, one poll per step, and one heard line per on_event.
-- Decisions 6, 7 (amended) and 9 of DL-022, design items 2, 5, 6, 9, 19 and 26, criteria 2, 6, 7, 10 and 13.
-- Pure: it is given a store (over a file-system adapter), a game env (parse, character, zone) and, on every call, clock READINGS: now_s,
-- whole-second wall time, used only for the heartbeat's written_at and an event's t; and now_ms, monotonic milliseconds, used only for scheduling.
-- It never reads a clock, never sleeps and never prints: the entry script polls (about every 100 ms), reads the clocks and prints the one
-- fatal message, taken from failure().
--
--   L = loop.new(store, env)
--   L:start(now_s, now_ms) -> true, or nil, reason, detail          (reason: a fixed ASCII string; detail: the raw error, which may hold external text;
--                                                                     called once: a second call returns nil, 'start was already called' and does nothing)
--   L:step(now_s, now_ms)                                            (one poll: list, select, handle at most one request, heartbeat if due)
--   L:on_event(line, now_s)                                          (one heard line; never raises)
--   L:failure() -> nil, or { reason = ..., detail = ... }            (the first fatal failure, kept: reported once)
--
-- Failure policy (decisions 6 and 9): at startup a failure to list inbox or outbox, to open the events file (including exhaustion) or to record an
-- event refuses to start. The first heartbeat attempt is part of startup but is NOT one of those failures: any failure to publish a heartbeat,
-- returned or raised, only skips that beat, at startup as at any other time, and startup still succeeds. At runtime an events failure (including
-- exhaustion), a failure to list inbox or outbox, or a failure to write or rename a reply sets one sticky fatal state. After it every step and
-- every event is ignored, so no request is processed and no heartbeat is published and the stale heartbeat reports it.
local queue = require 'claudebridge.queue'
local core = require 'claudebridge.core'
local version = require 'claudebridge.version'
local store_module = require 'claudebridge.store'

local M = {}
local L = {}
L.__index = L

-- Decision 7: a heartbeat is due this many monotonic milliseconds after the last ATTEMPT (success or not); from the spec ("about once per second").
local HEARTBEAT_INTERVAL_MS = 1000

-- Fixed ASCII reasons (design item 20's rule applied to the bridge's own messages); the raw error travels separately as `detail`.
local REASON = {
    list_inbox = 'could not list the inbox folder',
    list_outbox = 'could not list the outbox folder',
    open_events = 'the events file could not be opened',
    exhausted = 'the events file is exhausted: its last event has the largest event number; deal with the file by hand before restarting',
    bridge_start = 'could not record the bridge_start event',
    record = 'could not record an event',
    write_reply = 'could not write a reply',
    started_twice = 'start was already called',
}

function M.new(store, env)
    return setmetatable({
        store = store,
        env = env,
        floor = nil,                -- the startup floor: an unpadded decimal string, or nil
        started = false,
        failed = nil,               -- the first fatal failure: { reason, detail }; sticky
        last_beat_ms = nil,         -- the monotonic reading of the last heartbeat attempt
        unreadable_logged = {},     -- request file names already logged as unreadable (one event per file, design item 19)
    }, L)
end

function L:failure() return self.failed end

-- Sets the sticky fatal state; the first failure is kept. Returns nothing, so `return fail(...)` ends a step.
local function fail(self, reason, detail)
    if not self.failed then self.failed = { reason = reason, detail = detail } end
end

local function start_failed(self, reason, detail)
    fail(self, reason, detail)
    return nil, reason, detail
end

-- Appends one event. Any failure, including a raised error, sets the fatal state; returns true on success.
local function record(self, now_s, kind, fields, reason)
    local ok, n, err = pcall(self.store.append_event, self.store, now_s, kind, fields)
    if not ok then
        fail(self, reason or REASON.record, n)
        return false
    end
    if not n then
        fail(self, reason or REASON.record, err)
        return false
    end
    return true
end

-- One heartbeat attempt. The time is taken as attempted whatever the outcome, and a failure of any kind, returned or RAISED (the store, the
-- adapter or a game read for the character and zone), only skips the beat (decision 9): the stale heartbeat is what reports it.
local function beat(self, now_s, now_ms, waiting, unreadable)
    self.last_beat_ms = now_ms
    pcall(function()
        self.store:publish_heartbeat({
            character = self.env.character(),
            zone = self.env.zone(),
            now = now_s,
            waiting_for_sequence = waiting,
            unreadable_sequence = unreadable,
        })
    end)
end

-- Single-call contract: start is called once. A second call, after a successful or a failed startup, returns nil and a fixed reason, performs
-- no file operation and changes no state (it is a caller error, not a fatal failure of the bridge).
function L:start(now_s, now_ms)
    if self.started or self.failed then return nil, REASON.started_twice end
    local inbox, err = self.store:list_requests()
    if not inbox then return start_failed(self, REASON.list_inbox, err) end
    local outbox
    outbox, err = self.store:list_replies()
    if not outbox then return start_failed(self, REASON.list_outbox, err) end

    local floor = queue.highest(inbox, outbox)

    local opened, open_err = self.store:open_events()
    if not opened then
        if open_err == store_module.EXHAUSTED then return start_failed(self, REASON.exhausted, open_err) end
        return start_failed(self, REASON.open_events, open_err)
    end

    local start_fields = {
        { name = 'version', string = version.VERSION },
        floor and { name = 'floor', number = floor } or { name = 'floor', string = nil },
    }
    if not record(self, now_s, 'bridge_start', start_fields, REASON.bridge_start) then return nil, self.failed.reason, self.failed.detail end
    self.floor = floor

    -- Design item 6.3: every request at or below the floor is logged once, here. (By definition every request present at startup is.)
    for _, entry in ipairs(queue.select(inbox, outbox, floor).stale) do
        if entry.reason == 'floor' then
            if not record(self, now_s, 'startup_skipped', { { name = 'seq', number = entry.seq } }) then
                return nil, self.failed.reason, self.failed.detail
            end
        end
    end

    beat(self, now_s, now_ms, nil, nil)     -- startup includes the first heartbeat attempt, before any step (decision 9)
    self.started = true
    return true
end

function L:step(now_s, now_ms)
    if self.failed or not self.started then return end

    local inbox, err = self.store:list_requests()
    if not inbox then return fail(self, REASON.list_inbox, err) end
    local outbox
    outbox, err = self.store:list_replies()
    if not outbox then return fail(self, REASON.list_outbox, err) end

    local selection = queue.select(inbox, outbox, self.floor)
    local unreadable
    local chosen = selection.next
    if chosen then
        local read = self.store:read_request(chosen.name)
        if read.status == 'unreadable' then
            -- Design item 19: deferred, never given up on, logged once per file, visible in the heartbeat.
            unreadable = chosen.seq
            if not self.unreadable_logged[chosen.name] then
                self.unreadable_logged[chosen.name] = true
                if not record(self, now_s, 'unreadable', { { name = 'seq', number = chosen.seq }, { name = 'error', string = read.error } }) then return end
            end
        else
            local reply, summary
            if read.status == 'too_large' then
                reply, summary = core.oversize_reply(chosen.seq)     -- the file is never read (criterion 13, decision 4)
            else
                reply, summary = core.handle(self.env, chosen.seq, read.text)
            end
            local ok, write_err = self.store:write_reply(chosen.seq, reply)     -- a request counts as completed when its reply exists (design item 5)
            if not ok then return fail(self, REASON.write_reply, write_err) end
            local fields = {
                { name = 'seq', number = chosen.seq },
                { name = 'command', string = summary.command },
                { name = 'result', string = summary.kind },
            }
            if summary.message then fields[#fields + 1] = { name = 'message', string = summary.message } end
            fields[#fields + 1] = { name = 'ordering', string = chosen.base and 'base' or 'strict' }
            if not record(self, now_s, 'request', fields) then return end
        end
    end

    if now_ms - self.last_beat_ms >= HEARTBEAT_INTERVAL_MS then
        beat(self, now_s, now_ms, selection.waiting_for_sequence, unreadable)
    end
end

function L:on_event(line, now_s)
    if self.failed or not self.started then return end
    if type(line) ~= 'string' then line = tostring(line) end
    record(self, now_s, 'chat', { { name = 'text', string = line } })
end

return M
