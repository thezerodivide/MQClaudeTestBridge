--[[ ==========================================================================
  AutoInviteSolo.lua  -  "Auto Invite + DZ Manager" (STANDALONE, single file)
  Run in-game with:  /lua run AutoInviteSolo

  Refactor of Kylaeris' `autoinv.mac` into a layered Lua tool, with one addition:
  auto-invite / auto-dzadd are GATED to your GUILD ROSTER. The roster is obtained
  the cheap, reliable way — EverQuest's own `/outputfile guild <file>` writes the
  full guild list to the EQ folder; we parse that tab-delimited dump into a name
  set (there is NO TLO that exposes the whole roster; Spawn.Guild only covers who
  is in your zone, §8). A per-character "extras" whitelist lets you also allow
  trusted non-guildies.

  ORIGINAL MACRO BEHAVIOUR (preserved)
    - tell "inv"   -> /invite <sender>
    - tell "dzadd" -> /dzadd  <sender>
    - "<name> has left the group." -> /dzremoveplayer <name>

  DESIGN DECISIONS
    - Invite gating ....... GUILD-ONLY by default. Sender must be on the cached
                            roster (or the extras whitelist) or the request is
                            denied (and optionally whispered back). Toggle off to
                            invite anyone (original macro behaviour).
    - Roster source ....... `/outputfile guild <file>` -> parse the dump. Refreshed
                            on load, on demand (/autoinv refresh or the button),
                            and optionally on an interval.
    - Trigger words ....... configurable (default "inv" / "dzadd"); we match every
                            tell and compare the body, so changing a trigger never
                            needs an event re-register.
    - Interface ........... ImGui window (roster table + activity log + settings)
                            AND a full slash-command surface.
    - Config identity ..... one config per character keyed Name_Server.

  COMMANDS
    /autoinv                 toggle the window
    /autoinv compact         switch the UI to compact status mode
    /autoinv full            switch the UI back to the full interface
    /autoinv refresh         re-dump + reparse the guild roster now
    /autoinv roster          write the roster summary to the log
    /autoinv invite on|off   toggle auto-invite
    /autoinv dz on|off       toggle auto-dzadd + auto-dzremove
    /autoinv guildonly on|off toggle guild-only gating
    /autoinv add <name>      add a name to the extras whitelist (allow a non-guildie)
    /autoinv remove <name>   remove a name from the extras whitelist
    /autoinv save            save config
    /autoinv status          write diagnostics to the log
    /autoinv log             print the log path
============================================================================ ]]

local mq    = require('mq')
local ImGui = require('ImGui')
local lfs   = nil; pcall(function() lfs = require('lfs') end)

-- ==========================================================================
-- Inlined helpers  -  the only bits of the shared utils library this tool uses,
-- copied in so this file stands alone (no dependency but MacroQuest itself).
-- ==========================================================================

-- Guarded TLO read: the value, or `default` if the call errored/returned nil (§8).
local function tlo(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

-- Directory create, memoized (mkdir belongs at init, not per call, §7).
local _made = {}
local function ensureDir(dir)
    if not _made[dir] then
        if lfs then pcall(function() lfs.mkdir(dir) end) end
        _made[dir] = true
    end
    return dir
end

-- Serialize a plain Lua table to source ("return { ... }"). No JSON ships with
-- MQ (§6); this loads back safely with loadfile().
local function _ser(v, indent)
    local t = type(v)
    if t == 'string' then return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then return tostring(v)
    elseif t == 'table' then
        local ni, parts = indent .. '  ', {}
        for k, val in pairs(v) do
            local key
            if type(k) == 'number' then key = '[' .. k .. ']'
            else key = '[' .. string.format('%q', tostring(k)) .. ']' end
            parts[#parts + 1] = ni .. key .. ' = ' .. _ser(val, ni)
        end
        if not parts[1] then return '{}' end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end
local function serialize(tbl) return 'return ' .. _ser(tbl, '') .. '\n' end

-- Minimal file logger (§41): timestamped lines to <dir><name>.log, plus printf()
-- that echoes to the EQ console. Same shape as utils.log.new().
local function newLogger(name, dir)
    if lfs then pcall(function() lfs.mkdir(dir) end) end
    local path = dir .. name:lower() .. '.log'
    local L = {}
    function L.path() return path end
    function L.line(s)
        local f = io.open(path, 'a')
        if f then f:write(os.date('%H:%M:%S ') .. tostring(s) .. '\n'); f:close() end
    end
    function L.reset()
        local f = io.open(path, 'w')
        if f then f:write(os.date('== ' .. name .. ' log %Y-%m-%d %H:%M:%S ==') .. '\n'); f:close() end
    end
    function L.logf(fmt, ...) L.line(string.format(fmt, ...)) end
    function L.printf(fmt, ...) mq.cmdf('/echo ' .. fmt, ...) end
    return L
end

local logf, printf   -- assigned once the log root is known (below)

-- ==========================================================================
-- Constants
-- ==========================================================================

local Const = {}
Const.GUILD_FILE      = 'autoinvite_guild.txt'   -- /outputfile target (in EQ root)
Const.REFRESH_TIMEOUT = 6.0        -- seconds to wait for the dump to appear
Const.REFRESH_STABLE  = 2          -- consecutive stable polls before we parse
Const.ACT_MAX         = 60         -- activity-log ring size
Const.AUTO_INTERVALS  = { 0, 5, 10, 15, 30, 60 }   -- minutes; 0 = off
-- Best-guess column positions in the guild dump (1-based). Overridden per-row by
-- the defensive scan below; kept as documentation + fallback (see IN-GAME VERIFY).
Const.GUILD_COLS = { name = 1, level = 2, class = 3, rank = 4 }

local COL_GREY  = { 0.70, 0.70, 0.70, 1.0 }
local COL_WARN  = { 0.90, 0.80, 0.40, 1.0 }
local COL_GREEN = { 0.50, 0.90, 0.50, 1.0 }
local COL_RED   = { 0.95, 0.55, 0.55, 1.0 }
local COL_BLUE  = { 0.55, 0.75, 1.00, 1.0 }
local COL_TXT   = { 0.80, 0.80, 0.80, 1.0 }
local function textColored(c, s) ImGui.TextColored(c[1], c[2], c[3], c[4], s) end

-- ==========================================================================
-- Reader  -  pcall-guarded MQ TLO access only (§8)
-- ==========================================================================

local Reader = {}

function Reader.name()      return tostring(tlo(function() return mq.TLO.Me.Name() end, 'char')) end
function Reader.server()    return tostring(tlo(function() return mq.TLO.EverQuest.Server() end, 'server')) end
function Reader.guildName() return tostring(tlo(function() return mq.TLO.Me.Guild() end, '') or '') end
function Reader.groupMembers() return tonumber(tlo(function() return mq.TLO.Group.Members() end, 0)) or 0 end
function Reader.inGroup()      return Reader.groupMembers() > 0 end
function Reader.groupFull()    return Reader.groupMembers() >= 5 end  -- MQ Group.Members excludes yourself; 5 others = full 6-person group
function Reader.eqPath()    return tlo(function() return mq.TLO.EverQuest.Path() end) end
function Reader.mqConfig()  return tlo(function() return mq.TLO.MacroQuest.Path('config')() end) end
function Reader.mqPath()    return tlo(function() return mq.TLO.MacroQuest.Path()() end) end

-- Is `name` a guild member currently in our zone? (Spawn.Guild is zone-scoped, so
-- this is only a bonus signal — never a substitute for the dumped roster, §8.)
function Reader.spawnGuild(name)
    if not name or name == '' then return nil end
    local g = tlo(function() return mq.TLO.Spawn('pc =' .. name).Guild() end)
    if g == nil then return nil end
    return tostring(g)
end

-- ==========================================================================
-- Utility  -  string helpers
-- ==========================================================================

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- Split a line on TAB (the guild dump is tab-delimited). Falls back to runs of
-- 2+ spaces if the line has no tabs (some clients space-pad instead).
local function splitFields(line)
    local out = {}
    if line:find('\t') then
        for f in (line .. '\t'):gmatch('([^\t]*)\t') do out[#out + 1] = trim(f) end
    else
        for f in (line .. '  '):gmatch('(.-)%s%s+') do
            local t = trim(f); if t ~= '' then out[#out + 1] = t end
        end
        if #out == 0 then out[1] = trim(line) end
    end
    return out
end

-- Does a field look like a last-online date/time? (M/D/YYYY, YYYY-MM-DD, etc.)
local function looksLikeDate(s)
    if not s or s == '' then return false end
    return s:find('%d+[/%-]%d+[/%-]%d+') ~= nil
end

-- ==========================================================================
-- Roster  -  the guild name-set, obtained via /outputfile guild + parse
-- ==========================================================================

local Roster = {}
Roster.members = {}      -- array of { name, nameLower, level, class, rank, lastOn, raw }
Roster.set     = {}      -- [nameLower] = true  (fast membership test)
Roster.count   = 0
Roster.updated = 0       -- os.time() of the last successful parse
Roster.status  = 'no roster yet'

-- Build the fast lookup set from the members array.
local function reindexRoster()
    local set = {}
    for _, m in ipairs(Roster.members) do set[m.nameLower] = true end
    Roster.set   = set
    Roster.count = #Roster.members
end

-- Absolute path to the dump file in the EQ folder.
function Roster.filePath()
    local base = Reader.eqPath()
    if not base or base == '' then base = '.' end
    -- EverQuest.Path() has no trailing slash; /outputfile writes to the EQ root.
    return base .. '/' .. Const.GUILD_FILE
end

-- Parse one already-read dump body into the members array. Defensive about column
-- order: name = field 1; level = first purely-numeric field; a date-looking field
-- = last online; class/rank taken from the configured columns when present.
function Roster.parse(body)
    local members, cols = {}, Const.GUILD_COLS
    local firstData, header
    for line in body:gmatch('[^\r\n]+') do
        local f = splitFields(line)
        local name = f[1]
        if name and name ~= '' then
            -- skip a header row (col 1 == "Name", or no numeric level anywhere)
            local isHeader = name:lower() == 'name'
            if isHeader then
                header = line
            else
                if not firstData then firstData = line end
                -- level: configured column if numeric, else first numeric field
                local level = tonumber(f[cols.level or 2])
                if not level then
                    for i = 2, #f do local n = tonumber(f[i]); if n and n < 200 then level = n; break end end
                end
                -- last online: first date-looking field
                local lastOn = ''
                for i = 2, #f do if looksLikeDate(f[i]) then lastOn = f[i]; break end end
                members[#members + 1] = {
                    name      = name,
                    nameLower = name:lower(),
                    level     = level or 0,
                    class     = tostring(f[cols.class or 3] or ''),
                    rank      = tostring(f[cols.rank or 4] or ''),
                    lastOn    = lastOn,
                    raw       = line,
                }
            end
        end
    end
    table.sort(members, function(a, b) return a.nameLower < b.nameLower end)
    Roster.members = members
    reindexRoster()
    Roster.updated = os.time()
    Roster.status  = string.format('%d members', #members)
    -- Log the shape once so column drift on a given server is easy to spot (§41).
    logf('roster parsed: %d members; header=[%s] first=[%s]',
        #members, tostring(header or 'none'), tostring(firstData or 'none'))
    return #members
end

-- Read the dump file from disk and parse it. Returns (count, err).
function Roster.loadFromFile()
    local path = Roster.filePath()
    local fh = io.open(path, 'r')
    if not fh then return nil, 'file not found: ' .. path end
    local body = fh:read('*a'); fh:close()
    if not body or trim(body) == '' then return nil, 'file empty' end
    return Roster.parse(body)
end

-- File size on disk (0 if missing), used to detect the fresh write.
local function fileSize(path)
    if lfs then
        local a = lfs.attributes(path)
        if a and a.size then return a.size end
        return 0
    end
    local fh = io.open(path, 'r')
    if not fh then return 0 end
    local body = fh:read('*a') or ''; fh:close()
    return #body
end

-- Truncate the dump file so we can reliably detect the new write (size 0 -> >0).
local function truncateFile(path)
    local fh = io.open(path, 'w'); if fh then fh:close() end
end

-- ==========================================================================
-- Storage  -  one Lua-table config per character (Name_Server) (§6/§7)
-- ==========================================================================

local Storage = {}
local _rootDir
function Storage.root()
    if _rootDir then return _rootDir end
    local base = Reader.mqConfig() or Reader.mqPath() or '.'
    _rootDir = ensureDir(base .. '/AutoInvite')
    return _rootDir
end
function Storage.configDir() return ensureDir(Storage.root() .. '/config') end
function Storage.key()
    local raw = string.format('%s_%s', Reader.name(), Reader.server())
    return (raw:gsub('[^%w_]', ''))
end
function Storage.path(key) return Storage.configDir() .. '/' .. (key or Storage.key()) .. '.lua' end

-- ==========================================================================
-- State
-- ==========================================================================

local State = {}
State.open = true
State.key  = nil
State.settings = {
    autoInvite   = true,             -- react to the invite trigger
    autoDz       = true,             -- react to the dzadd trigger + group-leave removal
    guildOnly    = true,             -- gate invites/dzadds to the roster + extras
    whisperDeny  = true,             -- tell the requester when denied
    triggerInv   = 'inv',            -- tell body that requests an invite
    triggerDz    = 'dzadd',          -- tell body that requests a DZ add
    announceGroup= true,             -- /g echoes like the original macro
    autoRefreshM = 0,                -- minutes between roster auto-refreshes (0=off)
    compactMode  = false,            -- remember compact/full UI mode per character
    extras       = {},               -- [nameLower] = displayName  (allow non-guildies)
}
State.status   = 'Starting...'
State.activity = {}                  -- ring buffer of recent { t, kind, who, note }

function Storage.save()
    local path = Storage.path(State.key or Storage.key())
    local f = io.open(path, 'w')
    if not f then return false end
    f:write(serialize(State.settings))
    f:close()
    return true
end

local function mergeSettings(t)
    local s = State.settings
    local function str(k) if type(t[k]) == 'string' then s[k] = t[k] end end
    local function bool(k) if type(t[k]) == 'boolean' then s[k] = t[k] end end
    local function num(k) if tonumber(t[k]) then s[k] = tonumber(t[k]) end end
    bool('autoInvite'); bool('autoDz'); bool('guildOnly'); bool('whisperDeny'); bool('announceGroup'); bool('compactMode')
    str('triggerInv'); str('triggerDz')
    num('autoRefreshM')
    if type(t.extras) == 'table' then
        local e = {}
        for k, v in pairs(t.extras) do
            if type(k) == 'string' and type(v) == 'string' then e[k] = v end
        end
        s.extras = e
    end
end

function Storage.load()
    local chunk = loadfile(Storage.path(Storage.key()))
    if not chunk then return false end
    local ok, t = pcall(chunk)
    if not (ok and type(t) == 'table') then return false end
    mergeSettings(t)
    return true
end

-- ==========================================================================
-- Log
-- ==========================================================================

local Log = newLogger('AutoInvite', Storage.root() .. '/')
logf   = Log.logf
printf = Log.printf

-- ==========================================================================
-- Extras whitelist  -  allow specific non-guildies
-- ==========================================================================

local Extras = {}
function Extras.has(nameLower) return State.settings.extras[nameLower] ~= nil end
function Extras.add(name)
    name = trim(name); if name == '' then return false end
    if Extras.has(name:lower()) then return false end
    State.settings.extras[name:lower()] = name
    return true
end
function Extras.remove(nameLower)
    if not Extras.has(nameLower) then return false end
    State.settings.extras[nameLower] = nil
    return true
end
function Extras.list()
    local out = {}
    for k, v in pairs(State.settings.extras) do out[#out + 1] = { key = k, name = v } end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- ==========================================================================
-- Gate  -  may we act on a request from `sender`?
-- ==========================================================================

local Gate = {}
-- Returns true if allowed; false + reason otherwise.
function Gate.allowed(sender)
    if not State.settings.guildOnly then return true end
    local low = trim(sender):lower()
    if Roster.set[low] then return true, 'guild' end
    if Extras.has(low) then return true, 'extras' end
    -- last-ditch: if the roster hasn't loaded yet, fall back to the zone TLO so we
    -- aren't dead in the water on a fresh reload (only trusts an exact guild match).
    if Roster.count == 0 then
        local g = Reader.spawnGuild(sender)
        if g and g ~= '' and g == Reader.guildName() then return true, 'zone-tlo' end
    end
    return false, 'not in guild'
end

-- ==========================================================================
-- Activity log (UI ring buffer)
-- ==========================================================================

local function pushActivity(kind, who, note)
    table.insert(State.activity, 1, { t = os.time(), kind = kind, who = who, note = note })
    while #State.activity > Const.ACT_MAX do table.remove(State.activity) end
end

-- ==========================================================================
-- Engine  -  the actual server-facing actions (runs during doevents in the
-- MAIN LOOP, so issuing /commands here is safe, §44/§21).
-- ==========================================================================

local Engine = {}

local function announce(fmt, ...)
    if State.settings.announceGroup and Reader.inGroup() then mq.cmdf('/g ' .. fmt, ...) end
end

function Engine.invite(sender)
    sender = trim(sender)
    if sender == '' or sender:lower() == Reader.name():lower() then return end
    local ok, why = Gate.allowed(sender)
    if not ok then
        pushActivity('deny', sender, 'invite: ' .. why)
        logf('DENY invite: %s (%s)', sender, why)
        if State.settings.whisperDeny then mq.cmdf('/tell %s Sorry, auto-invite is guild-only.', sender) end
        return
    end
    if Reader.groupFull() then
        pushActivity('deny', sender, 'invite: group full')
        logf('DENY invite: %s (group full)', sender)
        mq.cmdf('/tell %s Sorry, the group is full.', sender)
        return
    end
    announce('Invite request from %s.', sender)
    mq.cmdf('/invite %s', sender)
    pushActivity('invite', sender, why or 'ok')
    logf('INVITE %s (%s)', sender, tostring(why))
end

function Engine.dzadd(sender)
    sender = trim(sender)
    if sender == '' then return end
    local ok, why = Gate.allowed(sender)
    if not ok then
        pushActivity('deny', sender, 'dzadd: ' .. why)
        logf('DENY dzadd: %s (%s)', sender, why)
        if State.settings.whisperDeny then mq.cmdf('/tell %s Sorry, DZ add is guild-only.', sender) end
        return
    end
    announce('DZ add request from %s.', sender)
    mq.cmdf('/dzadd %s', sender)
    pushActivity('dzadd', sender, why or 'ok')
    logf('DZADD %s (%s)', sender, tostring(why))
end

function Engine.dzremove(player)
    player = trim(player)
    if player == '' then return end
    announce('%s left the group. Removing from DZ...', player)
    mq.cmdf('/dzremoveplayer %s', player)
    pushActivity('dzremove', player, 'left group')
    logf('DZREMOVE %s', player)
end

-- ==========================================================================
-- App  -  orchestration; roster refresh + file I/O run in the MAIN LOOP (§21)
-- ==========================================================================

local App = { needsSave = false, needsRefresh = false, busy = false }
App.refresh = nil        -- active refresh state machine, or nil

-- Kick off a roster refresh (called from the main loop only).
function App.startRefresh(reason)
    if App.refresh then return end
    local path = Roster.filePath()
    truncateFile(path)
    mq.cmdf('/outputfile guild %s', Const.GUILD_FILE)
    App.refresh = { path = path, deadline = os.clock() + Const.REFRESH_TIMEOUT,
                    lastSize = 0, stable = 0, reason = reason }
    Roster.status = 'refreshing...'
    logf('roster refresh start (%s): /outputfile guild %s -> %s',
        tostring(reason), Const.GUILD_FILE, path)
end

-- One step of the refresh machine: wait for the file to grow, then hold steady
-- for a couple of polls (so we don't read a half-written file), then parse.
local function stepRefresh()
    local r = App.refresh
    local size = fileSize(r.path)
    if size > 0 and size == r.lastSize then
        r.stable = r.stable + 1
    else
        r.stable = 0
    end
    r.lastSize = size

    if size > 0 and r.stable >= Const.REFRESH_STABLE then
        local n, err = Roster.loadFromFile()
        App.refresh = nil
        if n then
            State.status = string.format('Roster refreshed: %d members.', n)
        else
            Roster.status = 'parse failed'
            State.status  = 'Roster refresh failed: ' .. tostring(err)
            logf('roster refresh FAILED: %s', tostring(err))
        end
        return
    end

    if os.clock() > r.deadline then
        App.refresh = nil
        -- Timed out waiting for the dump. Try a last read in case it did write.
        local n = Roster.loadFromFile()
        if n then
            State.status = string.format('Roster refreshed (late): %d members.', n)
        else
            Roster.status = 'timeout'
            State.status  = 'Roster refresh timed out (no dump file). Check /autoinv log.'
            logf('roster refresh TIMEOUT: no usable file at %s', r.path)
        end
    end
end

App._lastAutoRefresh = 0
function App.tick()
    if App.needsSave then App.needsSave = false; Storage.save() end
    if App.needsRefresh then App.needsRefresh = false; App.startRefresh('manual') end

    if App.refresh then
        App.busy = true
        stepRefresh()
        return
    end
    App.busy = false

    -- optional periodic auto-refresh
    local mins = tonumber(State.settings.autoRefreshM) or 0
    if mins > 0 then
        if os.time() - App._lastAutoRefresh >= mins * 60 then
            App._lastAutoRefresh = os.time()
            App.startRefresh('auto')
        end
    end
end

-- ==========================================================================
-- Events  -  macro-syntax matchers, pumped via doevents in the main loop (§44)
-- ==========================================================================

-- We match EVERY tell and compare the body, so changing a trigger word never
-- needs an event re-register.
local function onTell(_, sender, body)
    body = trim(body):lower()
    local s = State.settings
    if s.autoInvite and body == trim(s.triggerInv):lower() then
        Engine.invite(sender)
    elseif s.autoDz and body == trim(s.triggerDz):lower() then
        Engine.dzadd(sender)
    end
end

local function onGroupLeave(_, player)
    if State.settings.autoDz then Engine.dzremove(player) end
end

local function registerEvents()
    mq.event('AI_Tell',       "#1# tells you, '#2#'", onTell)
    mq.event('AI_GroupLeave', "#1# has left the group.", onGroupLeave)
end

-- ==========================================================================
-- UI  -  rendering only (§12/§13/§20). Safe manual column sort (§16).
-- ==========================================================================

local UI = {}
local TABLE_FLAGS = 0x200075D
UI.filter = { text = '', lower = '' }
UI.addName = ''
UI.sort = { col = 'name', asc = true }        -- roster sort state (§16)
UI.resizeRequested = false

local function agoStr(t)
    if not t or t == 0 then return 'never' end
    local d = os.time() - t
    if d < 60 then return d .. 's ago' end
    if d < 3600 then return math.floor(d / 60) .. 'm ago' end
    if d < 86400 then return math.floor(d / 3600) .. 'h ago' end
    return math.floor(d / 86400) .. 'd ago'
end

-- Clickable header cell; flips/sets UI.sort (safe pattern §16).
local function sortHeader(label, key, defaultAsc)
    local arrow = ''
    if UI.sort.col == key then arrow = UI.sort.asc and ' ^' or ' v' end
    ImGui.TableHeader(label .. arrow)
    if ImGui.IsItemClicked() then
        if UI.sort.col == key then UI.sort.asc = not UI.sort.asc
        else UI.sort.col = key; UI.sort.asc = (defaultAsc ~= false) end
    end
end

-- Return a sorted copy of the roster for display (built each draw; roster is small).
local function sortedRoster()
    local out = {}
    for i = 1, #Roster.members do out[i] = Roster.members[i] end
    local key, asc = UI.sort.col, UI.sort.asc
    table.sort(out, function(a, b)          -- if/else, never and/or shorthand (§17)
        local av, bv
        if key == 'level' then av, bv = a.level or 0, b.level or 0
        elseif key == 'class' then av, bv = (a.class or ''):lower(), (b.class or ''):lower()
        elseif key == 'rank'  then av, bv = (a.rank or ''):lower(),  (b.rank or ''):lower()
        else av, bv = a.nameLower, b.nameLower end
        if av == bv then av, bv = a.nameLower, b.nameLower; if asc then return av < bv else return av > bv end end
        if asc then return av < bv else return av > bv end
    end)
    return out
end

function UI.drawTopBar()
    local guild = Reader.guildName()
    ImGui.Text(string.format('%s   |   %s', Reader.name(), guild ~= '' and ('<' .. guild .. '>') or 'No guild'))
    ImGui.SameLine()
    textColored(COL_GREY, string.format('   Roster: %s  (%s)', Roster.status, agoStr(Roster.updated)))
end

function UI.drawControls()
    local isBusy = App.busy       -- snapshot before any BeginDisabled (§20)
    local s = State.settings

    local iv, ic = ImGui.Checkbox('Auto-invite', s.autoInvite)
    if ic then s.autoInvite = iv; App.needsSave = true end
    ImGui.SameLine()
    local dv, dc = ImGui.Checkbox('Auto-DZ', s.autoDz)
    if dc then s.autoDz = dv; App.needsSave = true end
    ImGui.SameLine()
    local gv, gc = ImGui.Checkbox('Guild-only', s.guildOnly)
    if gc then s.guildOnly = gv; App.needsSave = true end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('%s', 'When on, only guild members (plus the extras whitelist) are auto-invited / auto-dzadded.') end

    if isBusy then ImGui.BeginDisabled() end
    if ImGui.Button('Refresh roster', 120, 0) then App.needsRefresh = true end
    if isBusy then ImGui.EndDisabled() end
    ImGui.SameLine()
    if ImGui.Button('Save', 60, 0) then App.needsSave = true; State.status = 'Saved.' end
end

function UI.drawRoster()
    ImGui.AlignTextToFramePadding(); ImGui.Text('Filter')
    ImGui.SameLine(); ImGui.SetNextItemWidth(-1)
    local ft, fc = ImGui.InputText('##rosterfilter', UI.filter.text)
    if fc then UI.filter.text = ft; UI.filter.lower = ft:lower() end

    if Roster.count == 0 then
        textColored(COL_WARN, 'No roster loaded — click "Refresh roster" (runs /outputfile guild and parses it).')
    end

    local rows = sortedRoster()
    ImGui.BeginChild('rosterBox##ai', 0, 0, true)
    if ImGui.BeginTable('rosterTbl##ai', 5, TABLE_FLAGS) then
        ImGui.TableSetupScrollFreeze(0, 1)
        ImGui.TableSetupColumn('Name',  ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Lvl',   ImGuiTableColumnFlags.WidthFixed, 40)
        ImGui.TableSetupColumn('Class', ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableSetupColumn('Rank',  ImGuiTableColumnFlags.WidthFixed, 90)
        ImGui.TableSetupColumn('Last on', ImGuiTableColumnFlags.WidthFixed, 110)
        -- manual sortable header row (§16)
        ImGui.TableNextRow(ImGuiTableRowFlags.Headers)
        ImGui.TableSetColumnIndex(0); sortHeader('Name', 'name', true)
        ImGui.TableSetColumnIndex(1); sortHeader('Lvl', 'level', false)
        ImGui.TableSetColumnIndex(2); sortHeader('Class', 'class', true)
        ImGui.TableSetColumnIndex(3); sortHeader('Rank', 'rank', true)
        ImGui.TableSetColumnIndex(4); ImGui.TableHeader('Last on')
        for i, m in ipairs(rows) do
            if UI.filter.lower == '' or string.find(m.nameLower, UI.filter.lower, 1, true) then
                ImGui.PushID('r' .. i)
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0); ImGui.Text(m.name)
                ImGui.TableSetColumnIndex(1); ImGui.Text(tostring(m.level or 0))
                ImGui.TableSetColumnIndex(2); ImGui.Text(m.class or '')
                ImGui.TableSetColumnIndex(3); ImGui.Text(m.rank or '')
                ImGui.TableSetColumnIndex(4); textColored(COL_GREY, m.lastOn ~= '' and m.lastOn or '?')
                ImGui.PopID()
            end
        end
        ImGui.EndTable()
    end
    ImGui.EndChild()
end

function UI.drawActivity()
    textColored(COL_GREY, 'Recent auto-invite / DZ actions (newest first).')
    ImGui.BeginChild('actBox##ai', 0, 0, true)
    if ImGui.BeginTable('actTbl##ai', 4, TABLE_FLAGS) then
        ImGui.TableSetupScrollFreeze(0, 1)
        ImGui.TableSetupColumn('When', ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 80)
        ImGui.TableSetupColumn('Who', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Note', ImGuiTableColumnFlags.WidthFixed, 120)
        ImGui.TableHeadersRow()
        for i, a in ipairs(State.activity) do
            ImGui.PushID('act' .. i)
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); textColored(COL_GREY, agoStr(a.t))
            ImGui.TableSetColumnIndex(1)
            local c = (a.kind == 'deny') and COL_RED or COL_GREEN
            textColored(c, a.kind)
            ImGui.TableSetColumnIndex(2); ImGui.Text(a.who or '')
            ImGui.TableSetColumnIndex(3); textColored(COL_GREY, a.note or '')
            ImGui.PopID()
        end
        ImGui.EndTable()
    end
    ImGui.EndChild()
end

function UI.drawSettings()
    local s = State.settings

    textColored(COL_WARN, 'Triggers (tell body that fires each action)')
    ImGui.SetNextItemWidth(140)
    local tv, tc = ImGui.InputText('Invite trigger', s.triggerInv)
    if tc then s.triggerInv = tv; App.needsSave = true end
    ImGui.SetNextItemWidth(140)
    local zv, zc = ImGui.InputText('DZ add trigger', s.triggerDz)
    if zc then s.triggerDz = zv; App.needsSave = true end

    ImGui.Separator()
    textColored(COL_WARN, 'Behaviour')
    local wv, wc = ImGui.Checkbox('Whisper the requester when denied', s.whisperDeny)
    if wc then s.whisperDeny = wv; App.needsSave = true end
    local av, ac = ImGui.Checkbox('Announce actions in /g', s.announceGroup)
    if ac then s.announceGroup = av; App.needsSave = true end

    ImGui.SetNextItemWidth(120)
    local cur = (s.autoRefreshM == 0) and 'off' or (s.autoRefreshM .. 'm')
    if ImGui.BeginCombo('Auto-refresh roster', cur) then
        for _, m in ipairs(Const.AUTO_INTERVALS) do
            local label = (m == 0) and 'off' or (m .. 'm')
            if ImGui.Selectable(label .. '##ar' .. m, m == s.autoRefreshM) then
                s.autoRefreshM = m; App.needsSave = true
            end
        end
        ImGui.EndCombo()
    end

    ImGui.Separator()
    textColored(COL_WARN, 'Extras whitelist (allow these non-guildies)')
    ImGui.SetNextItemWidth(-150)
    local submitted = false
    local nv, nc = ImGui.InputTextWithHint('##extra', 'exact character name',
        UI.addName, ImGuiInputTextFlags.EnterReturnsTrue)
    if nc then submitted = true end
    UI.addName = nv
    ImGui.SameLine()
    if ImGui.Button('Add##extra', 80, 0) then submitted = true end
    if submitted then
        if Extras.add(UI.addName) then
            App.needsSave = true; State.status = 'Added to extras: ' .. trim(UI.addName); UI.addName = ''
        else
            State.status = 'Nothing added (blank or duplicate).'
        end
    end

    local extras = Extras.list()
    textColored(COL_GREY, string.format('%d extra name(s) allowed', #extras))
    ImGui.BeginChild('extraBox##ai', 0, 120, true)
    if ImGui.BeginTable('extraTbl##ai', 2, TABLE_FLAGS) then
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('',     ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableHeadersRow()
        local removeKey = nil
        for i, e in ipairs(extras) do
            ImGui.PushID('x' .. i)
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.Text(e.name)
            ImGui.TableSetColumnIndex(1)
            if ImGui.SmallButton('Remove') then removeKey = e.key end
            ImGui.PopID()
        end
        ImGui.EndTable()
        if removeKey then Extras.remove(removeKey); App.needsSave = true end
    end
    ImGui.EndChild()
end

local function setCompactMode(enabled)
    enabled = enabled == true
    if State.settings.compactMode ~= enabled then
        State.settings.compactMode = enabled
        UI.resizeRequested = true
        App.needsSave = true
    end
end

local function enabledText(v)
    return v and 'ON' or 'OFF'
end

function UI.drawCompact()
    if ImGui.SetNextWindowSize then
        if UI.resizeRequested then
            ImGui.SetNextWindowSize(350, 205, ImGuiCond.Always)
            UI.resizeRequested = false
        else
            ImGui.SetNextWindowSize(350, 205, ImGuiCond.FirstUseEver)
        end
    end
    if ImGui.SetNextWindowSizeConstraints then
        ImGui.SetNextWindowSizeConstraints(320, 180, 500, 320)
    end

    local open, shouldDraw = ImGui.Begin('Auto Invite - Compact##autoinvite', State.open)
    State.open = open
    if not shouldDraw then ImGui.End(); return end

    local s = State.settings

    ImGui.Text(string.format('%s  |  <%s>', Reader.name(),
        Reader.guildName() ~= '' and Reader.guildName() or 'No guild'))
    ImGui.Separator()

    ImGui.Text('Auto Invite:')
    ImGui.SameLine(105)
    textColored(s.autoInvite and COL_GREEN or COL_RED, enabledText(s.autoInvite))

    ImGui.Text('Auto DZ:')
    ImGui.SameLine(105)
    textColored(s.autoDz and COL_GREEN or COL_RED, enabledText(s.autoDz))

    ImGui.Text('Guild Only:')
    ImGui.SameLine(105)
    textColored(s.guildOnly and COL_GREEN or COL_WARN, enabledText(s.guildOnly))

    ImGui.Separator()
    ImGui.Text(string.format('Roster: %s (%s)', Roster.status, agoStr(Roster.updated)))

    if #State.activity > 0 then
        local a = State.activity[1]
        local who = (a.who and a.who ~= '') and (' ' .. a.who) or ''
        textColored(COL_GREY,
            string.format('Last: %s%s - %s', tostring(a.kind or 'action'), who, agoStr(a.t)))
    else
        textColored(COL_GREY, 'Last: no activity yet')
    end

    ImGui.Separator()

    local isBusy = App.busy
    if isBusy then ImGui.BeginDisabled() end
    if ImGui.Button('Refresh', 85, 0) then App.needsRefresh = true end
    if isBusy then ImGui.EndDisabled() end

    ImGui.SameLine()
    if ImGui.Button('Full Mode', 95, 0) then setCompactMode(false) end

    ImGui.End()
end

function UI.draw()
    if State.settings.compactMode then
        UI.drawCompact()
        return
    end

    if ImGui.SetNextWindowSize then
        if UI.resizeRequested then
            ImGui.SetNextWindowSize(560, 560, ImGuiCond.Always)
            UI.resizeRequested = false
        else
            ImGui.SetNextWindowSize(560, 560, ImGuiCond.FirstUseEver)
        end
    end
    if ImGui.SetNextWindowSizeConstraints then ImGui.SetNextWindowSizeConstraints(440, 360, 1400, 1800) end
    local open, shouldDraw = ImGui.Begin('Auto Invite##autoinvite', State.open)
    State.open = open
    if not shouldDraw then ImGui.End(); return end

    UI.drawTopBar()
    ImGui.Separator()
    UI.drawControls()
    ImGui.SameLine()
    if ImGui.Button('Compact Mode', 110, 0) then setCompactMode(true) end
    ImGui.Separator()
    textColored(COL_GREY, State.status)

    if ImGui.BeginTabBar('aiTabs##ai') then
        local rl = string.format('Roster (%d)###tab_roster', Roster.count)
        if ImGui.BeginTabItem(rl) then UI.drawRoster(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('Activity') then UI.drawActivity(); ImGui.EndTabItem() end
        if ImGui.BeginTabItem('Settings') then UI.drawSettings(); ImGui.EndTabItem() end
        ImGui.EndTabBar()
    end
    ImGui.End()
end

-- ==========================================================================
-- Slash command  -  register a flag / do light work only (§26/§40)
-- ==========================================================================

local function onOff(v) return v == 'on' or v == 'true' or v == '1' or v == 'yes' end

local function cmd(...)
    local args = { ... }
    local sub = (args[1] or ''):lower()
    local a2  = (args[2] or ''):lower()
    if sub == '' then State.open = not State.open
    elseif sub == 'compact' then
        State.open = true
        setCompactMode(true)
        printf('\ag[AutoInvite]\ax compact mode.')
    elseif sub == 'full' then
        State.open = true
        setCompactMode(false)
        printf('\ag[AutoInvite]\ax full mode.')
    elseif sub == 'refresh' then App.needsRefresh = true; printf('\ag[AutoInvite]\ax refreshing roster...')
    elseif sub == 'roster' then
        logf('ROSTER (%d members, %s):', Roster.count, agoStr(Roster.updated))
        for _, m in ipairs(Roster.members) do logf('  %-24s L%-3d %-12s %s', m.name, m.level or 0, m.class or '', m.rank or '') end
        printf('\ag[AutoInvite]\ax roster (%d) written to %s', Roster.count, Log.path())
    elseif sub == 'invite' then
        State.settings.autoInvite = onOff(a2); App.needsSave = true
        printf('\ag[AutoInvite]\ax auto-invite %s', State.settings.autoInvite and 'ON' or 'OFF')
    elseif sub == 'dz' then
        State.settings.autoDz = onOff(a2); App.needsSave = true
        printf('\ag[AutoInvite]\ax auto-DZ %s', State.settings.autoDz and 'ON' or 'OFF')
    elseif sub == 'guildonly' then
        State.settings.guildOnly = onOff(a2); App.needsSave = true
        printf('\ag[AutoInvite]\ax guild-only %s', State.settings.guildOnly and 'ON' or 'OFF')
    elseif sub == 'add' then
        local name = trim(table.concat(args, ' ', 2))
        if name == '' then printf('\ay[AutoInvite] usage: /autoinv add <name>\ax')
        elseif Extras.add(name) then App.needsSave = true; printf('\ag[AutoInvite]\ax allowed %s (extras).', name)
        else printf('\ay[AutoInvite]\ax "%s" already allowed.', name) end
    elseif sub == 'remove' then
        local name = trim(table.concat(args, ' ', 2))
        if Extras.remove(name:lower()) then App.needsSave = true; printf('\ag[AutoInvite]\ax removed %s from extras.', name)
        else printf('\ay[AutoInvite]\ax "%s" not in extras.', name) end
    elseif sub == 'save' then App.needsSave = true; printf('\ag[AutoInvite]\ax saved.')
    elseif sub == 'status' then
        logf('STATUS -------------------------------')
        logf('  key=%s guild=%s server=%s', tostring(State.key), Reader.guildName(), Reader.server())
        logf('  autoInvite=%s autoDz=%s guildOnly=%s', tostring(State.settings.autoInvite),
            tostring(State.settings.autoDz), tostring(State.settings.guildOnly))
        logf('  triggers: inv=%q dz=%q  whisperDeny=%s announceGroup=%s',
            State.settings.triggerInv, State.settings.triggerDz,
            tostring(State.settings.whisperDeny), tostring(State.settings.announceGroup))
        logf('  roster=%d updated=%s autoRefreshM=%d extras=%d', Roster.count,
            agoStr(Roster.updated), State.settings.autoRefreshM, #Extras.list())
        logf('  guildFile=%s', Roster.filePath())
        printf('\ag[AutoInvite]\ax status written to %s', Log.path())
    elseif sub == 'log' then printf('\ag[AutoInvite]\ax log: %s', Log.path())
    else
        printf('\ay[AutoInvite] usage: /autoinv [compact|full|refresh|roster|invite on/off|dz on/off|guildonly on/off|add <name>|remove <name>|save|status|log]\ax')
    end
end

-- ==========================================================================
-- Bootstrap
-- ==========================================================================

State.key = Storage.key()
Storage.load()

Log.reset()
logf('boot: key=%s guild=%s server=%s lfs=%s', tostring(State.key),
    Reader.guildName(), Reader.server(), tostring(lfs ~= nil))

registerEvents()

mq.imgui.init('AutoInviteUI', function()
    if not State.open then return end
    local ok, err = pcall(UI.draw)
    if not ok and err ~= State._lastDrawErr then
        State._lastDrawErr = err
        logf('DRAW ERROR: %s', tostring(err))
        printf('\ar[AutoInvite] draw error (see log):\ax %s', Log.path())
    end
end)
mq.bind('/autoinv', cmd)

-- Pull the roster once on load so gating works immediately.
App.needsRefresh = true

printf('\ag[AutoInvite]\ax loaded. Open with \ay/autoinv\ax. Log: %s', Log.path())

-- Main loop. Pump events every tick (§44) and guard each step (§3).
while State.open do
    mq.doevents()
    local ok, err = pcall(App.tick)
    if not ok and err ~= State._lastTickErr then
        State._lastTickErr = err
        logf('TICK ERROR: %s', tostring(err))
        printf('\ar[AutoInvite] tick error (see log):\ax %s', Log.path())
    end
    mq.delay(App.busy and 20 or 100)
end

pcall(function() mq.imgui.destroy('AutoInviteUI') end)
pcall(function() mq.unbind('/autoinv') end)
pcall(function() mq.unevent('AI_Tell') end)
pcall(function() mq.unevent('AI_GroupLeave') end)
printf('\ag[AutoInvite]\ax closed.')
