---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- SpellSpree -- automated vendor spell buyer & scriber
-- ----------------------------------------------------------------------------
-- Run with: /lua run spellspree
--
-- Open a spell vendor's merchant window, hit Start in the SpellSpree window.
-- It will:
--   1. Try to turn on the merchant's "usable items only" filter (best-effort --
--      the exact checkbox name varies by UI skin, see USABLE_FILTER_CANDIDATES).
--   2. Before each purchase, find the first genuinely open inventory slot
--      (lowest bag, lowest slot) -- same order the client fills new items
--      into -- and use that as the expected landing spot. No moving things
--      around, no forcing anything into a pre-cleared slot. Warns and stops
--      cleanly if there's no free space anywhere.
--   3. Walk the merchant's item list top to bottom. For each item that's a
--      spell scroll: buy it, confirm the quantity window if one pops up,
--      right-click it where it landed to scribe it into your spellbook,
--      confirm a scribe dialog if one pops up, then move to the next item.
--   4. Stop (and close the vendor) once the list runs out. Stops (vendor left
--      open) if it can't afford the next spell, if inventory fills up
--      mid-run, or if a purchase just plain fails -- in that case it skips
--      that one spell and keeps going rather than getting stuck.
--
-- NOTE: written without an in-game test pass. The four /notify commands for
-- buy/quantity/select/scribe are taken directly from a known-working macro,
-- so those should be solid. The "usable items only" checkbox name and the
-- scribe-confirmation dialog name are best-effort guesses (commented below)
-- since those vary by UI skin/client era -- if either doesn't fire, it's
-- non-fatal, but paste back the exact child-window name if you know it and
-- I'll wire it in directly.
-- ============================================================================

local mq    = require('mq')
local ImGui = require('ImGui')

local VERSION = '1.3-test-merchant-enum2-reorder'
local open    = true

-- ============================================================================
-- Theme
-- ============================================================================
local COLOR_INFO = { 0.75, 0.80, 0.92, 1.0 }
local COLOR_GOOD = { 0.40, 0.90, 0.55, 1.0 }
local COLOR_WARN = { 1.00, 0.76, 0.30, 1.0 }
local COLOR_ERR  = { 0.95, 0.35, 0.35, 1.0 }
local COLOR_GOLD = { 1.00, 0.84, 0.35, 1.0 }
local COLOR_MUTE = { 0.55, 0.58, 0.65, 1.0 }
local COLOR_WHITE = { 1.00, 1.00, 1.00, 1.0 }

-- ============================================================================
-- Diagnostics
-- ============================================================================
-- Flip to true to get the development diagnostics back in the log: the raw
-- text of every vendor tell, every parsed price quote, and the predicted
-- landing slot at the start of a vendor. They're off by default because they
-- fired two lines per item and buried the lines that actually say what
-- happened. They stay in the code rather than getting deleted -- each one
-- answered a real question during testing (does mq.event fire here at all;
-- is the price pattern matching; is the slot prediction pointing somewhere
-- real), and those are the same questions worth asking first if something
-- ever goes sideways again.
local DEBUG = false

-- ============================================================================
-- PoK spell vendors -- hand-verified in-game by the user, not scraped from
-- old wiki pages. Edit this table directly if a name ever changes.
-- ============================================================================
local TIERS = { '1-25', '26-50', '51-60', '61-70' }

local CLASS_ORDER = {
    'Cleric', 'Bard', 'Enchanter', 'Wizard', 'Shadowknight', 'Necromancer',
    'Shaman', 'Druid', 'Magician', 'Ranger', 'Paladin', 'Beastlord',
}

local VENDOR_DATA = {
    Cleric        = { ['1-25'] = 'Vicar Ceraen',        ['26-50'] = 'Vicar Thiran',         ['51-60'] = 'Vicar Delin',        ['61-70'] = 'Vicar Diarin' },
    Bard          = { ['1-25'] = 'Minstrel Eoweril',    ['26-50'] = 'Minstrel Joet',         ['51-60'] = 'Minstrel Gwiar',     ['61-70'] = 'Minstrel Silnon' },
    Enchanter     = { ['1-25'] = 'Illusionist Jerup',   ['26-50'] = 'Illusionist Sevat',     ['51-60'] = 'Illusionist Lobaen', ['61-70'] = 'Illusionist Acored' },
    Wizard        = { ['1-25'] = 'Channeler Olaemos',   ['26-50'] = 'Channeler Lariland',    ['51-60'] = 'Channeler Cerakoth', ['61-70'] = 'Channeler Alyrianne' },
    Shadowknight  = { ['1-25'] = 'Reaver Nydlil',       ['26-50'] = 'Reaver Uledrith',       ['51-60'] = 'Reaver Thirlan',     ['61-70'] = 'Reaver Muron' },
    Necromancer   = { ['1-25'] = 'Heretic Drahur',      ['26-50'] = 'Heretic Elirev',        ['51-60'] = 'Heretic Edalith',    ['61-70'] = 'Heretic Ceikon' },
    Shaman        = { ['1-25'] = 'Mystic Abomin',       ['26-50'] = 'Mystic Goharkor',       ['51-60'] = 'Mystic Ryrin',       ['61-70'] = 'Mystic Pikor' },
    Druid         = { ['1-25'] = 'Wanderer Astobin',    ['26-50'] = 'Wanderer Qenda',        ['51-60'] = 'Wanderer Frardok',   ['61-70'] = 'Wanderer Kedrisan' },
    Magician      = { ['1-25'] = 'Elementalist Somat',  ['26-50'] = 'Elementalist Kaeob',    ['51-60'] = 'Elementalist Padan', ['61-70'] = 'Elementalist Siewth' },
    Ranger        = { ['1-25'] = 'Pathfinder Viliken',  ['26-50'] = 'Pathfinder Vaered',     ['51-60'] = 'Pathfinder Thoajin', ['61-70'] = 'Pathfinder Naend' },
    Paladin       = { ['1-25'] = 'Cavalier Waut',       ['26-50'] = 'Cavalier Aodus',        ['51-60'] = 'Cavalier Preradus',  ['61-70'] = 'Cavalier Cerakor' },
    Beastlord     = { ['1-25'] = 'Primalist Saosith',   ['26-50'] = 'Primalist Worenon',     ['51-60'] = 'Primalist Nydalith', ['61-70'] = 'Primalist Loerith' },
}

-- ============================================================================
-- Class detection -- ported from triune.lua's own detectClasses(), since
-- that's proven working code for this "trio" multi-class character setup,
-- not a guess. Reads the InventoryWindow's class display (a character can
-- be up to 3 classes at once on this server), falls back to Me.Class for a
-- normal single-class character. Maps onto our full class names so it can
-- filter the Shopping List.
-- ============================================================================
local MQSHORT = {
    WARRIOR = 'War', WAR = 'War', WARRIORS = 'War',
    CLERIC = 'Clr', CLR = 'Clr', CLERICS = 'Clr',
    PALADIN = 'Pal', PAL = 'Pal', PALADINS = 'Pal',
    RANGER = 'Rng', RNG = 'Rng', RANGERS = 'Rng',
    SHADOWKNIGHT = 'SK', SHD = 'SK', SK = 'SK', SHADOWKNIGHTS = 'SK',
    DRUID = 'Dru', DRU = 'Dru', DRUIDS = 'Dru',
    MONK = 'Mnk', MNK = 'Mnk', MONKS = 'Mnk',
    BARD = 'Brd', BRD = 'Brd', BARDS = 'Brd',
    ROGUE = 'Rog', ROG = 'Rog', ROGUES = 'Rog',
    SHAMAN = 'Shm', SHM = 'Shm', SHAMANS = 'Shm',
    NECROMANCER = 'Nec', NEC = 'Nec', NECROMANCERS = 'Nec',
    WIZARD = 'Wiz', WIZ = 'Wiz', WIZARDS = 'Wiz',
    MAGICIAN = 'Mag', MAG = 'Mag', MAGICIANS = 'Mag',
    ENCHANTER = 'Enc', ENC = 'Enc', ENCHANTERS = 'Enc',
    BEASTLORD = 'Bst', BST = 'Bst', BEASTLORDS = 'Bst',
    BERSERKER = 'Ber', BER = 'Ber', BERSERKERS = 'Ber',
}

-- Abbreviation -> our full class name (only the 12 that have PoK spell
-- vendors; War/Mnk/Rog/Ber just won't match anything, which is correct).
local ABBR_TO_FULLNAME = {
    Clr = 'Cleric', Brd = 'Bard', Enc = 'Enchanter', Wiz = 'Wizard',
    SK = 'Shadowknight', Nec = 'Necromancer', Shm = 'Shaman', Dru = 'Druid',
    Mag = 'Magician', Rng = 'Ranger', Pal = 'Paladin', Bst = 'Beastlord',
}

local function parseClassLine(text)
    if not text or type(text) ~= 'string' or text == '' or text == 'NULL' then return nil end
    local cleaned = text:gsub('^%s*%d+[%s%.:]*', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if cleaned == '' then return nil end
    local up = cleaned:upper()
    if up:find('^LEVEL') or up:find('^LVL') then return nil end
    local noSpaces = up:gsub('[%s_%-]+', '')
    if MQSHORT[noSpaces] then return MQSHORT[noSpaces] end
    for word in cleaned:gmatch('%a+') do
        local wup = word:upper()
        if MQSHORT[wup] then return MQSHORT[wup] end
    end
    return nil
end

local function addFound(found, norm)
    if not norm then return end
    for _, existing in ipairs(found) do
        if existing == norm then return end
    end
    found[#found + 1] = norm
end

local function scanOneNode(node, found)
    if not node or not node() then return end
    pcall(function()
        local items = node.Items()
        if items and items > 0 then
            for i = 1, items do
                local ok, text = pcall(function() return node.List(i)() end)
                if ok and text and text ~= '' and text ~= 'NULL' then
                    addFound(found, parseClassLine(text))
                end
            end
        end
    end)
    pcall(function()
        local text = node.Text()
        if text and text ~= '' and text ~= 'NULL' then
            for line in text:gmatch('[^\r\n]+') do
                addFound(found, parseClassLine(line))
            end
        end
    end)
end

local function walkChildTree(parentNode, found, depth)
    if not parentNode or not parentNode() then return end
    depth = depth or 0
    if depth > 15 then return end
    local okChild, child = pcall(function() return parentNode.FirstChild end)
    if not okChild or not child or not child() then return end
    local visited = 0
    while child and child() and visited < 200 do
        visited = visited + 1
        scanOneNode(child, found)
        walkChildTree(child, found, depth + 1)
        local okNext, nxt = pcall(function() return child.Next end)
        if not okNext or not nxt or not nxt() then break end
        child = nxt
    end
end

-- Contains mq.delay() (forces the Inventory window open briefly) -- must be
-- called from the main loop (a yieldable thread), never from inside the
-- ImGui draw() callback. Same crash triune's own comment warns about:
-- "Cannot delay from non-yieldable thread."
local function classesFromInventoryWindow()
    local wasOpen = false
    pcall(function() wasOpen = mq.TLO.Window('InventoryWindow').Open() end)
    if not wasOpen then
        mq.cmd('/windowstate InventoryWindow open')
        mq.delay(250)
    end

    local found = {}

    pcall(function()
        local invWin = mq.TLO.Window('InventoryWindow')
        if not invWin or not invWin() then return end
        local abbrChild = invWin.Child('IW_ClassAbbr')
        if abbrChild and abbrChild() then
            local text = abbrChild.Text()
            if text and text ~= '' and text ~= 'NULL' then
                for line in text:gmatch('[^\r\n]+') do
                    addFound(found, parseClassLine(line))
                end
            end
        end
    end)

    if #found == 0 then
        pcall(function()
            local invWin = mq.TLO.Window('InventoryWindow')
            if not invWin or not invWin() then return end
            local clsChild = invWin.Child('IW_Class')
            if clsChild and clsChild() then
                local text = clsChild.Text()
                if text and text ~= '' and text ~= 'NULL' then
                    for line in text:gmatch('[^\r\n]+') do
                        addFound(found, parseClassLine(line))
                    end
                end
            end
        end)
    end

    if #found == 0 then
        pcall(function()
            local invWin = mq.TLO.Window('InventoryWindow')
            if invWin and invWin() then
                walkChildTree(invWin, found, 0)
            end
        end)
    end

    if not wasOpen then
        mq.cmd('/windowstate InventoryWindow close')
    end

    return #found > 0 and found or nil
end

-- Safe to call from the main loop only (see classesFromInventoryWindow).
-- Returns a list of our full class names, or nil if nothing was detected.
local function detectClasses()
    local abbrs = classesFromInventoryWindow()
    if not abbrs then
        local ok, mainClass = pcall(function() return mq.TLO.Me.Class.ShortName() end)
        if ok and mainClass and mainClass ~= '' and mainClass ~= 'NULL' then
            local norm = MQSHORT[mainClass:upper()]
            if norm then abbrs = { norm } end
        end
    end
    if not abbrs then return nil end

    local names = {}
    for _, abbr in ipairs(abbrs) do
        local fullName = ABBR_TO_FULLNAME[abbr]
        if fullName then table.insert(names, fullName) end
    end
    return #names > 0 and names or nil
end

-- ============================================================================
-- State
-- ============================================================================
local STATE = { IDLE = 'Idle', RUNNING = 'Running', STOPPED = 'Stopped', DONE = 'Done' }

-- S.selected[className][tier] = true/false, all unchecked by default -- an
-- explicit opt-in list of who to visit this run, not an opt-out.
local function freshSelection()
    local sel = {}
    for _, className in ipairs(CLASS_ORDER) do
        sel[className] = {}
        for _, tier in ipairs(TIERS) do
            sel[className][tier] = false
        end
    end
    return sel
end

local S = {
    state             = STATE.IDLE,
    stopRequested     = false,
    shoppingSpreeRequested = false,
    reDetectRequested = true, -- start true so it auto-detects once on load
    detectedClasses   = nil, -- nil until first detection runs; then a set { [className] = true }
    selected          = freshSelection(),
    log               = {},
    bought            = 0,
    skipped           = 0,
    purchasedNames    = {},
    skippedNames      = {},
    spentCopper       = 0,
    currentName       = nil,
    currentIndex      = 0,
    lastStopReason    = nil,
    lastScanSelName   = nil, -- item name seen selected on the previous scan iteration
    mouseOverOverlay  = false, -- true while the mouse is hovering this window (see draw())
    openedBags        = {}, -- [bagIdx] = true once we've clicked it open this run
    consecutiveNoMoneyMovement = 0, -- see the "not paid" branch in runSpellSpree
    stopOnOutOfMoney = true, -- false = skip unaffordable spells and keep going
}

local MAX_LOG_LINES = 400

local function logLine(text, color)
    table.insert(S.log, { text = text, color = color or COLOR_INFO, t = os.date('%H:%M:%S') })
    if #S.log > MAX_LOG_LINES then table.remove(S.log, 1) end
    print(string.format('\ay[SpellSpree]\ax %s', text))
end

-- Diagnostic log line -- a no-op unless DEBUG is on. See the DEBUG flag.
local function dbgLine(text)
    if not DEBUG then return end
    logLine(text, COLOR_MUTE)
end

-- NOTE: earlier versions of this script tried to verify purchases/scribes by
-- watching for specific chat lines via mq.event ("You give X to Y.", "You
-- have finished scribing X."). In testing, NEITHER ever fired even once,
-- while both actions genuinely succeeded in-game -- meaning the event
-- pattern-matching itself isn't working reliably in this setup, not that
-- timing was off. Switched to verifying against TLO reads instead (money on
-- hand, bag contents) -- the same kind of check already used everywhere else
-- in this script and never once unreliable across all this testing.

-- ============================================================================
-- Small helpers
-- ============================================================================
local function merchantOpen()
    local ok, isOpen = pcall(function() return mq.TLO.Window('MerchantWnd').Open() end)
    return ok and isOpen and true or false
end

-- Plane of Knowledge's zone short name is "poknowledge" -- standard,
-- long-established EQ zone naming, not something specific to this server.
local function inPoK()
    local ok, shortName = pcall(function() return mq.TLO.Zone.ShortName() end)
    return ok and shortName ~= nil and shortName:lower() == 'poknowledge'
end

local function myTotalCopper()
    local pp, gp, sp, cp = 0, 0, 0, 0
    pcall(function() pp = mq.TLO.Me.Platinum() or 0 end)
    pcall(function() gp = mq.TLO.Me.Gold() or 0 end)
    pcall(function() sp = mq.TLO.Me.Silver() or 0 end)
    pcall(function() cp = mq.TLO.Me.Copper() or 0 end)
    return pp * 1000 + gp * 100 + sp * 10 + cp
end

-- ============================================================================
-- Vendor price quotes -- UNVERIFIED, best-effort, not the primary defense.
-- ----------------------------------------------------------------------------
-- Item.Price() is confirmed unreliable (always reads 0, see isSpellItem's own
-- comment). This script's own earlier comment also mentions the vendor's tell
-- price quotes as something already seen in this environment ("That'll be
-- ... per Spell: Chaos Flux.") -- but the exact wording was never pinned
-- down, and this codebase has already hit chat events that silently never
-- fired even once during testing (see the note above logLine). So this is
-- built to fail SAFELY: if the quote never arrives, or the wording doesn't
-- match, nothing breaks -- the purchase just proceeds exactly as it did
-- before, falling back to the existing attempt-and-check-money-movement
-- logic, still backed by the "two in a row" stop. This can only ever make
-- things MORE informed, never less safe.
--
-- Confirmed against real chat log output: EVERY item selected in the
-- merchant window gets an automatic price tell, not just spells -- and,
-- importantly, the vendor uses BOTH wordings ("That'll be X per Y." AND
-- "That'll be X for Y.") depending on the item, not consistently one or the
-- other. Keyed by item name rather than one single slot for the most
-- recently seen quote -- with every item triggering a tell as it's merely
-- selected while scanning the list, a single slot got overwritten by
-- whatever was selected most recently by the time a purchase was actually
-- attempted several items later, which is why a quote that WAS captured
-- correctly still weren't being used for the right item at decision time.
-- ============================================================================
local priceQuotes = {} -- [itemName] = { copper = N, at = os.clock() }

-- Sums every "<number> <denomination>" pair found in a chunk of text,
-- whatever combination is actually present ("5 platinum", "3 gold and 2
-- silver", "1pp 4gp", etc.) -- tolerant of the exact phrasing on purpose,
-- since that's the one thing here with no confirmed source at all.
local function parseCopperFromText(text)
    if not text then return nil end
    local total, foundAny = 0, false
    local DENOMS = {
        { pat = '(%d+)%s*[Pp][Ll][Aa][Tt]', mult = 1000 }, { pat = '(%d+)%s*pp', mult = 1000 },
        { pat = '(%d+)%s*[Gg][Oo][Ll][Dd]', mult = 100 },  { pat = '(%d+)%s*gp', mult = 100 },
        { pat = '(%d+)%s*[Ss][Ii][Ll][Vv]', mult = 10 },   { pat = '(%d+)%s*sp', mult = 10 },
        { pat = '(%d+)%s*[Cc][Oo][Pp][Pp]', mult = 1 },    { pat = '(%d+)%s*cp', mult = 1 },
    }
    for _, d in ipairs(DENOMS) do
        local n = text:match(d.pat)
        if n then total = total + tonumber(n) * d.mult; foundAny = true end
    end
    return foundAny and total or nil
end

-- 1000000 -> "1,000,000". Only really matters for platinum, which is the
-- only denomination that gets big enough to need it.
local function withCommas(n)
    n = math.floor(tonumber(n) or 0)
    local sign = ''
    if n < 0 then sign = '-'; n = -n end
    local digits = tostring(n)
    local formatted = digits:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    formatted = formatted:gsub('^,', '')
    return sign .. formatted
end

local function formatCoin(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    local pp = math.floor(copper / 1000); copper = copper % 1000
    local gp = math.floor(copper / 100); copper = copper % 100
    local sp = math.floor(copper / 10); copper = copper % 10
    local cp = copper
    local parts = {}
    if pp > 0 then table.insert(parts, withCommas(pp) .. 'pp') end
    if gp > 0 then table.insert(parts, gp .. 'gp') end
    if sp > 0 then table.insert(parts, sp .. 'sp') end
    if cp > 0 or #parts == 0 then table.insert(parts, cp .. 'cp') end
    return table.concat(parts, ' ')
end

-- Plat-only, rounded UP so any leftover gold/silver/copper still shows as at
-- least 1pp instead of disappearing/rounding to 0.
local function formatCoinPPOnly(copper)
    copper = tonumber(copper) or 0
    return withCommas(math.ceil(copper / 1000)) .. 'pp'
end

local function bagItemCount(n)
    local ok, cnt = pcall(function() return mq.TLO.Me.Inventory('pack' .. n)() and mq.TLO.Me.Inventory('pack' .. n).Container() or 0 end)
    if ok and cnt then return cnt end
    return 0
end

local function bagSlotItem(bagIdx, slotIdx)
    local ok, it = pcall(function() return mq.TLO.Me.Inventory('pack' .. bagIdx).Item(slotIdx) end)
    if not ok or not it or not it() then return nil end
    return it
end

-- Reads a general inventory slot's own item, when nothing is nested inside a
-- bag there -- i.e. whatever a purchase landed as a loose item directly in
-- that slot, not inside a container. Distinct from bagSlotItem above, which
-- only ever looks INSIDE a bag.
local function topLevelSlotItem(bagIdx)
    local ok, it = pcall(function() return mq.TLO.Me.Inventory('pack' .. bagIdx) end)
    if not ok or not it or not it() then return nil end
    return it
end

-- Reads whatever landed at a firstFreeInventorySlot() result, whichever kind
-- of slot it turned out to be -- see the slotIdx == 0 sentinel note there.
local function readTargetSlot(bagIdx, slotIdx)
    if slotIdx == 0 then return topLevelSlotItem(bagIdx) end
    return bagSlotItem(bagIdx, slotIdx)
end

-- Builds the right /itemnotify for interacting with a firstFreeInventorySlot()
-- result -- a sub-slot inside a bag needs "in packN M", a loose top-level
-- item needs a plain click on the slot itself, same as ensureBagOpen's own
-- click on the bag icon.
local function targetSlotNotifyCmd(bagIdx, slotIdx)
    if slotIdx == 0 then
        return string.format('/itemnotify pack%d rightmouseup', bagIdx)
    end
    return string.format('/itemnotify in pack%d %d rightmouseup', bagIdx, slotIdx)
end

-- Human-readable form of a firstFreeInventorySlot() result, for log lines.
-- slotIdx 0 means the general inventory slot itself, with nothing equipped
-- there -- not a bag, so it isn't called one.
local function slotLabel(bagIdx, slotIdx)
    if slotIdx == 0 then
        return string.format('main inventory slot %d', bagIdx)
    end
    return string.format('bag %d/slot %d', bagIdx, slotIdx)
end

-- Name of whatever's on the cursor right now, or nil if the cursor is empty.
-- Nothing this script does should ever leave an item on the cursor -- every
-- action here is a click on something already sitting in a bag slot or the
-- merchant window, never a pick-up. If something IS there, that means some
-- action didn't complete the way it was supposed to, and continuing on
-- autopilot risks dropping, destroying, or misplacing it.
local function cursorItemName()
    local ok, has = pcall(function() return mq.TLO.Cursor() ~= nil end)
    if not ok or not has then return nil end
    local name = 'something'
    pcall(function() name = mq.TLO.Cursor.Name() or name end)
    return name
end

-- Interacting with an item INSIDE a bag (via "/itemnotify in packN M ...")
-- apparently requires that bag's own container window to actually be open on
-- screen -- confirmed in testing, it silently doesn't work otherwise.
-- Right-clicking the bag icon itself ("/itemnotify packN rightmouseup") is
-- what actually opens it -- confirmed via live testing (left-click didn't do
-- it). That click TOGGLES, so it is only ever safe to send when the bag is
-- known to be closed -- sending it at a bag that's already open closes it,
-- which is the one thing everything downstream can't survive.
--
-- Whether a bag's window is open right now, as opposed to "did this script
-- click it open at some point." S.openedBags only ever tracked the latter,
-- and the gap between the two is what caused the stall: a bag the user (or
-- the client) had open already got toggled SHUT by the first ensureBagOpen
-- that reached it, and the blind re-open in the recovery paths could just as
-- easily close a bag as open one. Returns true, false, or nil when the
-- client won't say either way -- nil keeps the old once-per-session
-- bookkeeping as the fallback, since a guess is all that's left at that
-- point.
local function bagOpenState(bagIdx)
    local state = nil
    pcall(function()
        local it = mq.TLO.Me.Inventory('pack' .. bagIdx)
        if it and it() then
            local v = it.Open()
            if type(v) == 'boolean' then
                state = v
            elseif type(v) == 'number' then
                state = (v ~= 0)
            end
        end
    end)
    return state
end

-- Sends the toggle only when the bag is actually closed. Returns true if a
-- click was sent. Safe to call as often as needed -- unlike the old
-- once-per-session guard, this can re-open a bag that got closed later in
-- the run without ever risking closing one that's already open.
local function openBagIfClosed(bagIdx)
    if bagOpenState(bagIdx) == true then return false end
    mq.cmdf('/itemnotify pack%d rightmouseup', bagIdx)
    -- Widened from 200ms -- on a slower connection, the window opening and
    -- its contents actually becoming readable through the TLO can take
    -- longer than 200ms to round-trip; better to spend an extra moment than
    -- read a bag before it's actually settled.
    mq.delay(400)
    return true
end

local function ensureBagOpen(bagIdx)
    local open = bagOpenState(bagIdx)
    if open == true then
        -- Already open, by whatever means. Record it so the nil-state
        -- fallback below doesn't go clicking at it later.
        S.openedBags[bagIdx] = true
        return
    end
    -- State unreadable: nothing to do but fall back to the old "click each
    -- bag at most once per session" rule.
    if open == nil and S.openedBags[bagIdx] then return end
    mq.cmdf('/itemnotify pack%d rightmouseup', bagIdx)
    mq.delay(400)
    S.openedBags[bagIdx] = true
end

-- How many general inventory slots this character actually HAS. Not always
-- 12 -- it depends on the client/expansion, and 8 and 10 are both common.
-- That distinction mattered far more than it looks: the TLO returns nil for
-- a slot that is merely EMPTY and also nil for a slot that DOESN'T EXIST, so
-- the hardcoded 1..12 scan below used to treat the non-existent packs past
-- the real end of inventory as "a free top-level slot" and hand one back as
-- the landing target for the next purchase. Every purchase then went through
-- for real, landed somewhere real, and failed to read back from a slot that
-- can never hold anything -- which is exactly what produced "didn't buy for
-- some reason" on items the vendor's own tells confirm were bought and paid
-- for. Me.NumBagSlots is the authoritative count; the fallback only applies
-- if it can't be read at all, and the landing-check sweep further down is
-- what covers a wrong guess either way.
local function generalSlotCount()
    local n = nil
    pcall(function() n = tonumber(mq.TLO.Me.NumBagSlots()) end)
    if not n or n < 1 then n = 10 end
    if n > 12 then n = 12 end
    return n
end

-- Finds the first genuinely open slot anywhere in general inventory -- lowest
-- bag, lowest slot within that bag, checked in the same pack1-slot1,
-- pack1-slot2, ..., pack2-slot1, ... order the client fills new items into.
-- No moving things around, no forcing anything into a specific pre-cleared
-- slot -- just find wherever the next purchase will actually land, and use
-- that. Returns bagIdx, slotIdx, or nil, nil if there's nowhere free at all.
--
-- Opens each bag before trusting a read from it, same as the comment above
-- ensureBagOpen already established for interacting with an item inside one
-- -- that finding was never actually applied here, which is the real bug
-- behind two separate symptoms that looked unrelated: a bag that has never
-- been opened can read as having free space when it does not (letting a
-- purchase go through with nowhere for it to actually land, however that
-- then manifests), and the post-purchase landing check re-reads that exact
-- same unreliable data, which is how a purchase that genuinely succeeded
-- still got reported as "didn't buy."
--
-- Priority confirmed directly by in-game testing: an empty TOP-LEVEL general
-- inventory slot is filled before the client ever puts a new item inside a
-- bag, full stop -- not "whichever comes first while scanning slot by
-- slot." An earlier version of this got that order wrong: it checked each
-- general inventory slot in turn and, the moment one held a bag with room,
-- used a slot inside THAT bag right away -- so an empty top-level slot
-- sitting a couple of positions further along never even got considered if
-- an earlier slot happened to hold a bag with space. That is backwards from
-- how the client actually behaves: any bare open slot wins over any amount
-- of room inside any bag, regardless of which one comes first in slot order.
-- Two full passes fixes that -- every top-level slot is checked for being
-- completely empty before bag contents are looked at at all, and bags are
-- only ever considered once every single top-level slot is confirmed
-- occupied by something. slotIdx 0 is the sentinel for "the top-level slot
-- itself, not a sub-slot inside a bag there" -- real in-bag indices always
-- start at 1, so 0 can never collide with one.
local function firstFreeInventorySlot()
    -- Pass 1: any completely empty top-level slot at all, lowest index wins.
    -- This alone decides the answer whenever one exists -- pass 2 below is
    -- never reached in that case.
    for bagIdx = 1, generalSlotCount() do
        local slotItem = nil
        pcall(function() slotItem = mq.TLO.Me.Inventory('pack' .. bagIdx) end)
        if not (slotItem and slotItem() ~= nil) then
            return bagIdx, 0
        end
    end

    -- Pass 2: only reached once every top-level slot is confirmed occupied
    -- by something (a bag or a loose item) -- now, and only now, look inside
    -- bags for room, in the same pack1-slot1, pack1-slot2, ..., order.
    for bagIdx = 1, generalSlotCount() do
        local slotItem = nil
        pcall(function() slotItem = mq.TLO.Me.Inventory('pack' .. bagIdx) end)
        if slotItem and slotItem() ~= nil then
            local containerSize = 0
            pcall(function() containerSize = tonumber(slotItem.Container()) or 0 end)
            if containerSize > 0 then
                ensureBagOpen(bagIdx)
                local size = bagItemCount(bagIdx)
                if size <= 0 then size = containerSize end
                for slot = 1, size do
                    if not bagSlotItem(bagIdx, slot) then
                        return bagIdx, slot
                    end
                end
            end
            -- else: a loose, non-container item occupies this slot outright
            -- -- nothing to look inside.
        end
    end
    return nil, nil
end

-- ============================================================================
-- "Usable items only" filter. Confirmed straight from this UI's own
-- EQUI_MerchantWnd.xml: it's a <Button item="MW_UsableButton"> with
-- Style_Checkbox=true (paired with a <Label item="MW_UsableLabel"> reading
-- "Show only items I can use") -- NOT a separate Checkbox-type element,
-- which is why the earlier name guesses never matched anything at all.
-- MW_UsableButton is tried first; the rest stay as fallbacks in case a
-- different UI skin names it something else.
-- ============================================================================
local USABLE_FILTER_CANDIDATES = {
    'MW_UsableButton',
    'MW_UsableOnlyCheckbox', 'MW_UseableOnlyCheckbox', 'MW_ItemFilterCheckbox',
    'MW_CanUseCheckbox', 'MW_CanUseCheckBox', 'MW_UsableCheckBox',
    'MW_FilterCheckbox', 'MW_Filter_Checkbox',
}

local function verifyUsableFilterOn()
    for _, name in ipairs(USABLE_FILTER_CANDIDATES) do
        local ok, exists = pcall(function() return mq.TLO.Window('MerchantWnd').Child(name)() ~= nil end)
        if ok and exists then
            local function isChecked()
                local checked = false
                pcall(function() checked = mq.TLO.Window('MerchantWnd').Child(name).Checked() end)
                return checked
            end

            if isChecked() then
                logLine('"Usable items only" filter is on.', COLOR_MUTE)
                return true
            end

            -- Still worth trying to click it automatically, then verify
            -- instead of assuming -- but this is now a hard requirement, not
            -- a warning: if it's not confirmed on, the run does not start.
            for attempt = 1, 2 do
                mq.cmdf('/notify MerchantWnd %s leftmouseup', name)
                mq.delay(300)
                if isChecked() then
                    logLine(string.format('Enabled "usable items only" filter (%s).', name), COLOR_GOOD)
                    return true
                end
            end

            logLine(string.format('"Usable items only" (%s) is NOT checked, and clicking it isn\'t taking. Check that box yourself, then hit Start again -- this run will not start without it.', name), COLOR_ERR)
            return false
        end
    end
    logLine('Could not find a "usable items only" checkbox on this UI at all -- can\'t confirm it\'s on, so this run will not start. If this vendor has that option, check it yourself and hit Start again.', COLOR_ERR)
    return false
end

-- ============================================================================
-- Merchant list helpers
-- ============================================================================
-- Visible merchant rows are authoritative for enumeration. Merchant.Item(N) is
-- intentionally NOT used here: with the merchant's usable-only filter enabled,
-- its indexing can diverge from MerchantWnd -> ItemList, which is the list the
-- user is actually looking at and the one /notify listselect operates on.
local function merchantVisibleRowCount()
    local count = nil
    pcall(function()
        local itemList = mq.TLO.Window('MerchantWnd').Child('ItemList')
        if itemList and itemList() then
            count = tonumber(itemList.Items())
        end
    end)
    return count
end

-- Whatever the merchant window is ACTUALLY showing as selected right now
-- (after a listselect). This is ground truth -- Merchant.Item(N) and the
-- UI's Nth visible row can disagree (seen in testing: selecting index N
-- bought a totally unrelated item, most likely because the "usable items
-- only" filter changes what's visually listed). Every buy decision below is
-- driven off THIS, never off a pre-fetched Item(N) guess.
local function merchantSelectedItem()
    local ok, it = pcall(function() return mq.TLO.Merchant.SelectedItem end)
    if not ok or not it then return nil end
    local existsOk, exists = pcall(function() return it() ~= nil end)
    if not existsOk or not exists then return nil end
    return it
end

local function itemDisplayName(it)
    local name = 'Unknown'
    pcall(function() name = it.Name() or name end)
    return name
end

-- Stable identity for reorder-safe merchant enumeration. The visible UI row
-- number is only an address into the list AT THIS MOMENT; it is not the item's
-- identity, because the merchant can reorder itself after purchases/scribes.
-- Prefer the selected item's real ID when MQ exposes it, with the displayed
-- name included for readable diagnostics. Fall back to name only if ID cannot
-- be read.
local function merchantSelectedItemKey(it, knownName)
    local name = knownName or itemDisplayName(it)
    local id = nil
    pcall(function() id = tonumber(it.ID()) end)
    if id and id > 0 then
        return string.format('id:%d|name:%s', id, name), tostring(id)
    end
    return 'name:' .. tostring(name), 'name-fallback'
end

-- Searches every general inventory slot and bag for an existing item with
-- this exact name, returning its location and current stack count. Used only
-- to recognize a purchase that stacked onto an existing copy instead of
-- landing in a new slot -- confirmed happening in testing (spell scrolls
-- stack on this server). Doesn't open any bags itself; a stale read from a
-- bag that's never been opened just means this search misses a copy sitting
-- in there, which only costs this best-effort detection, not anything that
-- gates a purchase.
local function findExistingCopy(name)
    for bagIdx = 1, generalSlotCount() do
        local slotItem = nil
        pcall(function() slotItem = mq.TLO.Me.Inventory('pack' .. bagIdx) end)
        if slotItem and slotItem() then
            local containerSize = 0
            pcall(function() containerSize = tonumber(slotItem.Container()) or 0 end)
            if containerSize > 0 then
                local size = bagItemCount(bagIdx)
                if size <= 0 then size = containerSize end
                for slot = 1, size do
                    local it = bagSlotItem(bagIdx, slot)
                    if it and itemDisplayName(it) == name then
                        local stack = 1
                        pcall(function() stack = tonumber(it.Stack()) or 1 end)
                        return bagIdx, slot, stack
                    end
                end
            elseif itemDisplayName(slotItem) == name then
                local stack = 1
                pcall(function() stack = tonumber(slotItem.Stack()) or 1 end)
                return bagIdx, 0, stack
            end
        end
    end
    return nil, nil, nil
end

-- Finds a copy of this item ANYWHERE in general inventory, skipping one known
-- location (typically the copy that was already sitting there before a
-- purchase, so a pre-existing scroll isn't mistaken for the new one). Opens
-- bags as it goes, since an unopened bag reads as empty.
--
-- This is the safety net for the landing check. Money leaving your pocket
-- already proves the purchase posted, so once that's confirmed the right
-- question is "where did it actually land," not "did it buy." Predicting the
-- destination slot can go wrong for reasons invisible from here, and
-- declaring a confirmed, paid-for purchase a failure is much the worse of
-- the two errors -- it loses the scribe step too, leaving a scroll sitting
-- unscribed in a bag with the log claiming it was never bought.
local function findCopyAnywhere(name, skipBag, skipSlot)
    for bagIdx = 1, generalSlotCount() do
        local slotItem = nil
        pcall(function() slotItem = mq.TLO.Me.Inventory('pack' .. bagIdx) end)
        if slotItem and slotItem() then
            local containerSize = 0
            pcall(function() containerSize = tonumber(slotItem.Container()) or 0 end)
            if containerSize > 0 then
                ensureBagOpen(bagIdx)
                local size = bagItemCount(bagIdx)
                if size <= 0 then size = containerSize end
                for slot = 1, size do
                    if not (skipBag == bagIdx and skipSlot == slot) then
                        local it = bagSlotItem(bagIdx, slot)
                        if it and itemDisplayName(it) == name then
                            return bagIdx, slot
                        end
                    end
                end
            elseif not (skipBag == bagIdx and skipSlot == 0) then
                if itemDisplayName(slotItem) == name then
                    return bagIdx, 0
                end
            end
        end
    end
    return nil, nil
end

-- Vendor-sold spells are always named "Spell: <SpellName>" -- visible right in
-- the merchant window and in the vendor's own /tell price quotes ("That'll be
-- ... per Spell: Chaos Flux."). This is the ONLY signal used now. There used
-- to be a fallback checking Item.Spell.Name(), but that turned out to be
-- flawed by design, not just unreliable: Item.Spell reflects ANY spell
-- effect associated with the item (a worn effect, a proc, a clicky) --
-- NOT specifically "this is a spell scroll." That's exactly why an enchanted
-- earring (its enchantment IS a spell effect) and a food item both
-- false-positived through it and got bought (and in the food's case, then
-- got eaten instead of scribed, since the script blindly right-clicked
-- whatever it thought was a scroll).
local function isSpellItem(it, knownName)
    local name = knownName or itemDisplayName(it)
    return name ~= nil and name:match('^Spell:%s') ~= nil
end

-- Confirm the quantity window if one pops up after Buy.
--
-- A short retry loop, not one fixed wait then a single check -- the original
-- single-shot version assumed the window would be fully open within exactly
-- 150ms. On a connection with any real latency, the buy click's round trip
-- and the window actually opening can easily take longer than that on their
-- own, meaning the single check could run in the gap before the window ever
-- appears, silently missing a quantity prompt that was still on its way.
local function handleQuantityWindowIfOpen()
    for _ = 1, 5 do -- up to ~750ms
        local ok, isOpen = pcall(function() return mq.TLO.Window('QuantityWnd').Open() end)
        if ok and isOpen then
            mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
            mq.delay(150)
            return
        end
        mq.delay(150)
    end
end

-- Confirm a scribe-confirmation dialog if one pops up (varies by client/UI --
-- best-effort, harmless if it doesn't match anything). Same retry reasoning
-- as handleQuantityWindowIfOpen above, for the same latency-tolerance reason.
local SCRIBE_CONFIRM_CANDIDATES = { 'ConfirmationDialogBox', 'ScribeConfirmWnd' }
local function handleScribeConfirmIfOpen()
    for _ = 1, 5 do -- up to ~750ms
        for _, wname in ipairs(SCRIBE_CONFIRM_CANDIDATES) do
            local ok, isOpen = pcall(function() return mq.TLO.Window(wname).Open() end)
            if ok and isOpen then
                pcall(function() mq.cmdf('/notify %s CD_Yes_Button leftmouseup', wname) end)
                mq.delay(150)
                return
            end
        end
        mq.delay(150)
    end
end

-- The very first scribe click can silently fail to register if the mouse is
-- still hovering this window when it fires -- the MQ2 overlay appears to
-- swallow it before it reaches the game. Rather than let that happen quietly,
-- pause here and tell the user to move their mouse into the game world, then
-- wait until it's actually clear before proceeding. Loops (not a fixed
-- delay) since this depends entirely on the user, not on timing. Always
-- prints immediately on entry (no shared/module-level throttle that could
-- carry over from an earlier call and suppress this one), then reminds every
-- few seconds if it's still waiting.
-- Capped rather than truly unbounded. The previous version only ever exited
-- on the flag clearing or Stop being pressed -- fine if the user is actually
-- watching, but if this fires during an unattended multi-vendor run and the
-- mouse just happens to be sitting over the window (parked there, AFK,
-- whatever), there was nothing to ever break out of this on its own. That
-- silent, indefinite wait is the most likely explanation for "locks up the
-- lua, have to kill it with /lua stop" -- the script wasn't actually stuck,
-- it was correctly waiting for an input that was never going to come.
local MOUSE_OVERLAY_WAIT_TIMEOUT = 60
local function waitForMouseOffOverlay()
    if not S.mouseOverOverlay then return end
    logLine('Mouse is over the SpellSpree window -- move it into the game world so the click actually registers.', COLOR_WARN)
    local startedAt = os.clock()
    local lastReminderAt = startedAt
    while S.mouseOverOverlay do
        if S.stopRequested then return end
        if (os.clock() - startedAt) > MOUSE_OVERLAY_WAIT_TIMEOUT then
            logLine(string.format('Waited %ds for the mouse to move -- giving up on that and trying the click anyway.',
                MOUSE_OVERLAY_WAIT_TIMEOUT), COLOR_WARN)
            return
        end
        if (os.clock() - lastReminderAt) > 5.0 then
            lastReminderAt = os.clock()
            logLine('Still waiting -- move your mouse off the SpellSpree window.', COLOR_WARN)
        end
        mq.delay(100)
    end
end


-- ============================================================================
-- Main run loop -- called from the plain main loop below (NOT from the ImGui
-- callback), so mq.delay() here is safe. Stop button just flips
-- S.stopRequested, checked between every step.
-- ============================================================================
local function closeVendor()
    if merchantOpen() then
        pcall(function() mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup') end)
    end
end

-- Close and reopen the currently targeted merchant between scan passes. This
-- intentionally forces the client to rebuild the usable-only merchant list so
-- successfully scribed spells disappear before the next pass. Returns true
-- only after the merchant is open again and the usable-only filter is verified.
local function reopenCurrentMerchantForNextPass(passNumber)
    -- Preserve the exact merchant target BEFORE closing the window. On this
    -- client, closing MerchantWnd can clear or disturb the current target, so
    -- a blind `/click right target` afterward is not a reliable reopen action.
    local merchantTargetId = nil
    local merchantTargetName = nil
    pcall(function() merchantTargetId = tonumber(mq.TLO.Target.ID()) end)
    pcall(function() merchantTargetName = mq.TLO.Target.CleanName() or mq.TLO.Target.Name() end)

    if not merchantTargetId or merchantTargetId <= 0 then
        logLine('[merchant scan] Cannot preserve the merchant target before close/reopen -- stopping rather than clicking an unknown target.', COLOR_ERR)
        return false, 'Could not preserve merchant target before reopen'
    end

    logLine(string.format('[merchant scan] Pass %d bought at least one spell; closing merchant to force a fresh filtered list before the next pass. Preserved merchant target: %s (#%d).',
        passNumber, tostring(merchantTargetName or 'unknown'), merchantTargetId), COLOR_WARN)
    closeVendor()

    local closed = false
    for _ = 1, 20 do -- up to ~2s
        if not merchantOpen() then
            closed = true
            break
        end
        mq.delay(100)
    end
    if not closed then
        logLine('[merchant scan] Merchant window did not close cleanly between passes -- stopping rather than scanning a stale list.', COLOR_ERR)
        return false, 'Merchant did not close between passes'
    end

    if S.stopRequested then return false, 'Stopped by user' end

    waitForMouseOffOverlay()
    if S.stopRequested then return false, 'Stopped by user' end

    -- Re-acquire the exact NPC we were shopping from. Do not assume the target
    -- survived closing MerchantWnd. Verify the ID before attempting to reopen.
    local targetRestored = false
    for attempt = 1, 10 do -- up to ~3s
        mq.cmdf('/target id %d', merchantTargetId)
        mq.delay(300)
        local currentTargetId = nil
        pcall(function() currentTargetId = tonumber(mq.TLO.Target.ID()) end)
        if currentTargetId == merchantTargetId then
            targetRestored = true
            break
        end
    end
    if not targetRestored then
        logLine(string.format('[merchant scan] Merchant closed, but could not re-target %s (#%d) for the next pass -- stopping.',
            tostring(merchantTargetName or 'merchant'), merchantTargetId), COLOR_ERR)
        return false, 'Could not re-target merchant between passes'
    end

    logLine(string.format('[merchant scan] Re-targeted %s (#%d); right-clicking to reopen merchant.',
        tostring(merchantTargetName or 'merchant'), merchantTargetId), COLOR_MUTE)
    mq.cmd('/click right target')
    local reopened = false
    for _ = 1, 25 do -- up to ~5s
        if merchantOpen() then
            reopened = true
            break
        end
        mq.delay(200)
    end
    if not reopened then
        logLine('[merchant scan] Merchant window did not reopen between passes -- stopping.', COLOR_ERR)
        return false, 'Merchant did not reopen between passes'
    end

    if not verifyUsableFilterOn() then
        return false, '"Usable items only" not confirmed after merchant reopen'
    end

    local rows = merchantVisibleRowCount()
    if rows == nil then
        logLine('[merchant scan] Merchant reopened, but visible row count is unavailable -- stopping rather than guessing.', COLOR_ERR)
        return false, 'Merchant visible row count unavailable after reopen'
    end

    logLine(string.format('[merchant scan] Merchant reopened for pass %d with %d visible row(s).', passNumber + 1, rows), COLOR_GOLD)
    return true, nil, rows
end

local function runSpellSpree()
    S.state = STATE.RUNNING
    -- NOT resetting bought/skipped/spentCopper here -- same bug class as
    -- the bag-tracking fix above. These need to accumulate across the
    -- WHOLE shopping spree (all vendors), not wipe out every time a new
    -- vendor's run starts -- otherwise the final total only reflects
    -- whatever the LAST vendor did, which is exactly why "Spent" showed 0pp
    -- after a run that bought plenty, just not at the final vendor. These
    -- get reset once, at the start of runShoppingSpree, instead.
    S.currentName, S.currentIndex = nil, 0
    S.lastStopReason = nil
    S.lastScanSelName = nil
    -- Reset per vendor, unlike bought/skipped/spentCopper -- this is about
    -- catching a streak within THIS vendor's list, not something that should
    -- carry a near-miss over from a completely different vendor and trip a
    -- stop on the very first purchase attempt there.
    S.consecutiveNoMoneyMovement = 0
    -- Also per-vendor -- a quote from a different vendor's identically-named
    -- item (unlikely, but not impossible) shouldn't linger and misinform a
    -- decision here.
    priceQuotes = {}
    -- NOT resetting S.openedBags here -- it needs to persist across the
    -- whole session (all vendors in a shopping spree), not just this one
    -- run. The bag's actual open/closed state in the game doesn't reset
    -- between vendor visits, so if this got wiped every run, the very next
    -- vendor would forget the bag was already open, blindly right-click it
    -- "to open" it, and since that click TOGGLES the bag, slam it shut
    -- instead -- exactly the "bag randomly closes between vendors" bug.
    logLine('Starting up...', COLOR_GOLD)
    logLine('This will open bags as needed to buy and scribe into -- please leave them open once they pop up (closing one mid-run can briefly misread a purchase as failed).', COLOR_WARN)

    if not merchantOpen() then
        logLine('No merchant window open -- open a vendor first.', COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = 'No merchant open'
        return
    end

    do
        local stray = cursorItemName()
        if stray then
            logLine(string.format('There\'s already something on your cursor ("%s") -- clear that before starting.', stray), COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Item already on cursor'
            return
        end
    end

    if not verifyUsableFilterOn() then
        S.state = STATE.STOPPED
        S.lastStopReason = '"Usable items only" not confirmed on'
        return
    end

    do
        local checkBag, checkSlot = firstFreeInventorySlot()
        if not checkBag then
            logLine('No free inventory space anywhere -- make room before running this.', COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Inventory full'
            return
        end
        dbgLine(string.format('First free slot right now: %s.', slotLabel(checkBag, checkSlot)))
    end

    -- Walk the ENTIRE VISIBLE merchant list. MerchantWnd -> ItemList is the
    -- authority because /notify listselect addresses those visible rows directly,
    -- while Merchant.Item(N) can use a different index space when filtering is on.
    local idx = 1
    local nonSpellSkipped = 0

    -- Row numbers are NOT stable identities. Project Triune's merchant can
    -- reorder the visible list during purchasing without the user touching the
    -- sort controls. We therefore treat each open-window traversal as ONE pass.
    -- Within that pass, remember identities already inspected so a reorder cannot
    -- make us buy the same scroll twice. If the pass buys anything, close and
    -- reopen the merchant before the next pass; the usable-only filter then
    -- rebuilds the list without successfully scribed spells. Completion requires
    -- a complete pass that buys zero spells.
    local seenMerchantItems = {}
    local scanPass = 1
    local totalUniqueInspected = 0
    local passBoughtStart = S.bought
    local MAX_SCAN_PASSES = 100 -- defensive ceiling against a merchant that never converges

    local lastVisibleRowCount = merchantVisibleRowCount()
    if not lastVisibleRowCount then
        logLine('Could not read MerchantWnd ItemList row count -- stopping rather than guessing at merchant indices.', COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = 'Merchant visible row count unavailable'
        return
    end
    logLine(string.format('[merchant scan] Visible row count at start: %d.', lastVisibleRowCount), COLOR_GOLD)
    logLine(string.format('[merchant scan] Starting pass %d at visible row #1.', scanPass), COLOR_MUTE)

    while true do
        -- Explicit and frequent, not left to whatever mq.delay() may or may
        -- not do internally -- the outer main loop's own mq.doevents() call
        -- only runs once, before this whole function is even entered, and
        -- doesn't run again until this returns, which can be many items and
        -- many seconds later.
        mq.doevents()

        if S.stopRequested then
            logLine('Stopped by user.', COLOR_WARN)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Stopped by user'
            return
        end
        if not merchantOpen() then
            logLine('Merchant window closed unexpectedly -- stopping.', COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Merchant closed'
            return
        end

        do
            local stray = cursorItemName()
            if stray then
                logLine(string.format('Something ended up on your cursor ("%s") -- that means an action didn\'t complete cleanly. Stopping before anything gets lost or misplaced.', stray), COLOR_ERR)
                S.state = STATE.STOPPED
                S.lastStopReason = string.format('Unexpected item on cursor: "%s"', stray)
                return
            end
        end

        local rowCount = merchantVisibleRowCount()
        if not rowCount then
            logLine(string.format('[merchant scan] Could not read visible row count before row #%d -- stopping rather than guessing at the end of the list.', idx), COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Merchant visible row count unavailable during scan'
            return
        end
        if rowCount ~= lastVisibleRowCount then
            logLine(string.format('[merchant scan] Visible row count changed: %d -> %d before row #%d.', lastVisibleRowCount, rowCount, idx), COLOR_WARN)
            -- If rows disappeared after the previous item (for example because a
            -- newly scribed spell no longer survives the usable-only filter), the
            -- next unvisited row shifts upward. Revisit the current visible
            -- position instead of skipping whatever moved into it.
            if rowCount < lastVisibleRowCount then
                local removed = lastVisibleRowCount - rowCount
                local oldIdx = idx
                idx = math.max(1, idx - removed)
                if idx ~= oldIdx then
                    logLine(string.format('[merchant scan] Row removal shifted the list; adjusting next row %d -> %d so shifted rows are not skipped.', oldIdx, idx), COLOR_WARN)
                end
            end
            lastVisibleRowCount = rowCount
        end

        if idx > rowCount then
            local boughtThisPass = S.bought - passBoughtStart
            if boughtThisPass == 0 then
                if nonSpellSkipped > 0 then
                    logLine(string.format('[merchant scan] Scan complete: pass %d reached the end of %d visible row(s) and bought zero spells. No purchase-triggered reorder remains to reconcile. Inspected %d item encounter(s) total; skipped %d non-spell item(s).',
                        scanPass, rowCount, totalUniqueInspected, nonSpellSkipped), COLOR_GOLD)
                else
                    logLine(string.format('[merchant scan] Scan complete: pass %d reached the end of %d visible row(s) and bought zero spells. No purchase-triggered reorder remains to reconcile. Inspected %d item encounter(s) total.',
                        scanPass, rowCount, totalUniqueInspected), COLOR_GOLD)
                end
                S.state = STATE.DONE
                S.lastStopReason = 'Full refreshed merchant pass bought zero spells'
                closeVendor()
                return
            end

            logLine(string.format('[merchant scan] Pass %d reached the current end (%d row(s)) after buying %d spell(s). A mid-pass reorder may have moved unvisited spells behind the cursor.',
                scanPass, rowCount, boughtThisPass), COLOR_WARN)

            if scanPass >= MAX_SCAN_PASSES then
                logLine(string.format('[merchant scan] Aborting after %d close/reopen passes -- the merchant never reached a pass with zero purchases.', MAX_SCAN_PASSES), COLOR_ERR)
                S.state = STATE.STOPPED
                S.lastStopReason = 'Merchant list did not converge after reopen passes'
                return
            end

            local reopened, reopenReason, reopenedRows = reopenCurrentMerchantForNextPass(scanPass)
            if not reopened then
                if reopenReason == 'Stopped by user' then
                    logLine('Stopped by user.', COLOR_WARN)
                end
                S.state = STATE.STOPPED
                S.lastStopReason = reopenReason or 'Merchant reopen failed'
                return
            end

            scanPass = scanPass + 1
            idx = 1
            seenMerchantItems = {} -- fresh window/list; completed spells should now be absent
            S.lastScanSelName = nil
            passBoughtStart = S.bought
            lastVisibleRowCount = reopenedRows
            logLine(string.format('[merchant scan] Starting pass %d at visible row #1 on the freshly reopened merchant.', scanPass), COLOR_MUTE)
            rowCount = reopenedRows
        end

        local rowCountBeforeRow = rowCount
        local previousSelectedName = S.lastScanSelName
        logLine(string.format('[merchant scan] Requesting visible UI row #%d of %d.', idx, rowCountBeforeRow), COLOR_MUTE)

        -- Select this visible UI row, then poll for Merchant.SelectedItem to
        -- settle. A repeated name is NOT an EOF signal: adjacent legitimate rows
        -- can share names, and the visible row count already tells us whether this
        -- index exists. If the name never changes from the prior row, retry the
        -- listselect once, log it, then accept the returned selection.
        mq.cmdf('/notify MerchantWnd ItemList listselect %d', idx)
        local sel, selName = nil, nil
        local selectionAdvanced = false
        for _ = 1, 12 do
            mq.delay(30)
            sel = merchantSelectedItem()
            if sel then
                selName = itemDisplayName(sel)
                if previousSelectedName == nil or selName ~= previousSelectedName then
                    selectionAdvanced = true
                    break
                end
            end
        end

        if sel and not selectionAdvanced and previousSelectedName ~= nil and selName == previousSelectedName then
            logLine(string.format('[merchant scan] Row #%d selection still reads "%s"; retrying listselect once because selection did not visibly advance.', idx, selName), COLOR_WARN)
            mq.cmdf('/notify MerchantWnd ItemList listselect %d', idx)
            for _ = 1, 12 do
                mq.delay(30)
                sel = merchantSelectedItem()
                if sel then
                    selName = itemDisplayName(sel)
                    if selName ~= previousSelectedName then
                        selectionAdvanced = true
                        break
                    end
                end
            end
            if sel and not selectionAdvanced then
                logLine(string.format('[merchant scan] Row #%d still reads "%s" after retry; accepting it because row #%d is within the authoritative visible row count (%d).', idx, selName, idx, rowCountBeforeRow), COLOR_MUTE)
            end
        end

        S.lastScanSelName = selName

        if not sel then
            logLine(string.format('[merchant scan] Could not read Merchant.SelectedItem for visible row #%d -- skipping that row.', idx), COLOR_WARN)
            idx = idx + 1
        else
            local itemKey, itemIdText = merchantSelectedItemKey(sel, selName)
            local alreadySeen = seenMerchantItems[itemKey] == true
            logLine(string.format('[merchant scan] Pass %d row #%d/%d selected: "%s" [item %s] -> %s.',
                scanPass, idx, rowCountBeforeRow, selName, itemIdText, alreadySeen and 'already inspected THIS PASS' or 'NEW THIS PASS'), COLOR_MUTE)

            if alreadySeen then
                idx = idx + 1
            else
                -- Mark it before processing. This set is deliberately pass-local:
                -- it prevents a mid-pass reorder from buying the same merchant item
                -- twice before we close/reopen the vendor. After reopen the set is
                -- reset because successfully scribed spells should be absent from
                -- the freshly filtered list.
                seenMerchantItems[itemKey] = true
                totalUniqueInspected = totalUniqueInspected + 1

                local name = selName
                if not isSpellItem(sel, name) then
                nonSpellSkipped = nonSpellSkipped + 1
                -- Keep the GUI's "current position" moving even while
                -- skipping non-spells -- otherwise it looks frozen for the
                -- whole time it's working through a big inventory, when
                -- really it's just not found a spell to report yet.
                S.currentName, S.currentIndex = name, idx
                idx = idx + 1
            else
                S.currentName, S.currentIndex = name, idx

                -- Proactive: selecting an item triggers the vendor's own
                -- price tell automatically (confirmed directly against real
                -- chat log output -- every item does this, not just spells).
                -- A short settle wait plus an explicit doevents right here,
                -- not just the one at the top of this loop (which only
                -- catches whatever arrived before THIS item was even
                -- selected) -- the tell is a separate, asynchronous response
                -- to the selection just above, so it needs its own moment to
                -- actually arrive and then be processed before checking for
                -- it makes any sense.
                mq.delay(250)
                mq.doevents()
                local q = priceQuotes[name]
                if q and q.copper > myTotalCopper() then
                    if S.stopOnOutOfMoney then
                        logLine(string.format('Vendor quoted "%s" at %s -- you have %s. Not enough. Stopping.',
                            name, formatCoin(q.copper), formatCoin(myTotalCopper())), COLOR_ERR)
                        S.state = STATE.STOPPED
                        S.lastStopReason = string.format('Not enough money for "%s" (quoted %s)', name, formatCoin(q.copper))
                        return
                    end
                    logLine(string.format('Vendor quoted "%s" at %s -- you have %s. Not enough, skipping just this one.',
                        name, formatCoin(q.copper), formatCoin(myTotalCopper())), COLOR_WARN)
                    S.skipped = S.skipped + 1
                    table.insert(S.skippedNames, name)
                    idx = idx + 1
                    goto nextItem
                end

                -- Item.Price() has proven completely unreliable in this
                -- environment (always reads 0 here, tried multiple sources)
                -- -- same category of issue as the checkbox and chat events.
                -- Rather than display a fake "(0cp)" price or gate purchases
                -- on a number we know is wrong, this only checks the one
                -- thing we CAN trust: whether you have any money at all. The
                -- real cost gets shown after the fact, measured from the
                -- actual drop in money on hand.
                if myTotalCopper() <= 0 then
                    if S.stopOnOutOfMoney then
                        logLine(string.format('Out of money -- can\'t afford "%s". Stopping.', name), COLOR_ERR)
                        S.state = STATE.STOPPED
                        S.lastStopReason = 'Out of money'
                        return
                    end
                    logLine(string.format('Out of money -- can\'t afford "%s". Skipping it and checking the rest.', name), COLOR_WARN)
                    S.skipped = S.skipped + 1
                    table.insert(S.skippedNames, name)
                    idx = idx + 1
                    goto nextItem
                end

                local targetBag, targetSlot = firstFreeInventorySlot()
                if not targetBag then
                    logLine('No free inventory space left -- stopping.', COLOR_ERR)
                    S.state = STATE.STOPPED
                    S.lastStopReason = 'Inventory full'
                    return
                end
                waitForMouseOffOverlay()
                -- Nothing to open when the target is an empty top-level slot
                -- itself (no bag equipped there at all) -- see slotIdx == 0
                -- in firstFreeInventorySlot's own comment.
                if targetSlot ~= 0 then ensureBagOpen(targetBag) end

                -- Baseline for stack-detection below -- see findExistingCopy.
                local existingBag, existingSlot, existingStackBefore = findExistingCopy(name)

                logLine(string.format('Buying "%s"...', name), COLOR_INFO)
                local copperBeforeBuy = myTotalCopper()
                mq.cmd('/notify MerchantWnd MW_Buy_Button leftmouseup')
                handleQuantityWindowIfOpen()

                -- Wait for money on hand to actually drop -- the real,
                -- TLO-based confirmation that the transaction posted, instead
                -- of a blind delay or a chat line that isn't firing reliably.
                local paid = false
                for _ = 1, 15 do -- up to ~3s
                    if myTotalCopper() < copperBeforeBuy then
                        paid = true
                        break
                    end
                    mq.delay(200)
                    mq.doevents()
                end
                if not paid then
                    -- Race-condition safety net: the proactive check right
                    -- after selecting this item should have already caught
                    -- an unaffordable spell before we ever got here, but if
                    -- the quote arrived a beat late, it'll be sitting in
                    -- priceQuotes by now -- check again rather than falling
                    -- through to the ambiguous "money didn't move" reasoning
                    -- below when a definitive answer is actually available.
                    local q = priceQuotes[name]
                    if q and q.copper > myTotalCopper() then
                        logLine(string.format('Vendor quoted "%s" at %s -- you have %s. Not enough, skipping just this one.',
                            name, formatCoin(q.copper), formatCoin(myTotalCopper())), COLOR_WARN)
                        S.skipped = S.skipped + 1
                        table.insert(S.skippedNames, name)
                        idx = idx + 1
                        goto nextItem
                    end

                    -- Two of these in a row is a much stronger signal, though:
                    -- a one-off explains a single miss, but the same thing
                    -- happening on back-to-back purchases is far more likely
                    -- genuine -- actually out of money for this vendor's
                    -- price range. That's when stopping outright is
                    -- justified, since Item.Price() is confirmed unreliable
                    -- (always reads 0) and there's no way to check
                    -- affordability ahead of time the way the earlier
                    -- "myTotalCopper() <= 0" check already does for being
                    -- flat broke.
                    S.consecutiveNoMoneyMovement = S.consecutiveNoMoneyMovement + 1
                    if S.consecutiveNoMoneyMovement >= 2 then
                        if S.stopOnOutOfMoney then
                            logLine(string.format('Money on hand hasn\'t moved for two purchases in a row (now "%s") -- most likely out of money for this vendor. Stopping here rather than guessing at every remaining item.', name), COLOR_ERR)
                            S.state = STATE.STOPPED
                            S.lastStopReason = string.format('Probably not enough money (stopped at "%s")', name)
                            return
                        end
                        logLine(string.format('Money on hand hasn\'t moved for two purchases in a row (now "%s") -- most likely out of money for this vendor. "Stop when out of money" is off, so skipping and checking the rest anyway.', name), COLOR_WARN)
                        S.skipped = S.skipped + 1
                        table.insert(S.skippedNames, name)
                        idx = idx + 1
                        goto nextItem
                    end

                    -- No quote to confirm it outright, and not (yet) two in a
                    -- row -- but money simply not moving at all already IS
                    -- conclusive that nothing was bought; there's nothing left
                    -- to learn from spending another 3s on the landing check
                    -- too, and letting it fall through to that was producing
                    -- a vague, uninformative "didn't buy for some reason"
                    -- that buried what actually happened. Confirmed directly
                    -- against real testing: this exact single-miss pattern
                    -- has turned out to mean insufficient funds far more
                    -- often than not, even without a price quote to prove it
                    -- outright, so the message says so plainly now instead of
                    -- staying generic.
                    logLine(string.format('Money on hand didn\'t move for "%s" -- most likely not enough coin for it (no vendor quote to confirm it outright, so not stopping the whole vendor over one miss). Skipping it.', name), COLOR_WARN)
                    S.skipped = S.skipped + 1
                    table.insert(S.skippedNames, name)
                    idx = idx + 1
                    goto nextItem
                else
                    S.consecutiveNoMoneyMovement = 0
                end

                -- Verify it actually landed where we expected before trusting the
                -- purchase. Retried for up to ~3s (matching the "paid" wait just
                -- above, since both are waiting on the same round trip) rather
                -- than a single immediate read -- the bag is open by now
                -- (firstFreeInventorySlot takes care of that), but on a slower
                -- connection there can still be a real gap between the purchase
                -- actually landing server-side and the slot's contents showing
                -- up through the TLO, and a read landing inside that gap is how
                -- a purchase that genuinely went through got reported as failed.
                --
                -- readTargetSlot (not bagSlotItem directly) so this reads
                -- correctly whichever kind of slot this turned out to be -- a
                -- purchase landing as a loose item directly in an empty
                -- top-level slot needs a different read than one landing
                -- inside a bag, and using the wrong one here is exactly what
                -- was causing "didn't buy" reports for purchases that landed
                -- in an open top-level slot: bagSlotItem only ever looks
                -- INSIDE a bag, so it always came up empty for those.
                local landed, landedOk = nil, false
                for _ = 1, 15 do -- up to ~3s
                    landed = readTargetSlot(targetBag, targetSlot)
                    if landed then landedOk = true; break end
                    mq.delay(200)
                end
                if landed then
                    local landedName = itemDisplayName(landed)
                    if landedName ~= name then
                        logLine(string.format('Something landed in %s ("%s") but the name doesn\'t match "%s" -- proceeding anyway.', slotLabel(targetBag, targetSlot), landedName, name), COLOR_WARN)
                    end
                end

                if not landedOk and targetSlot ~= 0 then
                    -- S.openedBags only tracks "did we open this bag once this
                    -- session" -- not "is it still open right now." If the user
                    -- (or anything else) closed it since, every read of it goes
                    -- right back to being unreliable, which reads exactly like
                    -- "the purchase failed" even when it didn't. One recovery
                    -- attempt here, same reasoning as the scribe loop's own
                    -- recovery step further down: re-toggling a bag that was
                    -- never actually the problem risks closing it, but a
                    -- purchase that already had a full 3s to show up and still
                    -- isn't reading is far more likely explained by a closed
                    -- bag than by anything a toggle could break. Only applies
                    -- when there's actually a bag involved -- an empty
                    -- top-level slot has no bag to have gotten closed.
                    if openBagIfClosed(targetBag) then
                        logLine(string.format('"%s" isn\'t reading back from bag %d/slot %d and that bag reads as closed -- re-opening it before giving up.', name, targetBag, targetSlot), COLOR_WARN)
                    else
                        logLine(string.format('"%s" isn\'t reading back from bag %d/slot %d, but that bag is already open -- giving it one more read rather than toggling it shut.', name, targetBag, targetSlot), COLOR_WARN)
                        mq.delay(400)
                    end
                    landed = readTargetSlot(targetBag, targetSlot)
                    if landed then
                        landedOk = true
                        logLine(string.format('"%s" showed up after re-opening the bag -- it did buy, just wasn\'t readable at the time.', name), COLOR_GOOD)
                    end
                end

                -- Still nothing in the predicted slot, and the bag-reopen
                -- recovery above didn't turn it up either. The money already
                -- came out of pocket, so this purchase DID post -- sweep the
                -- whole inventory for the scroll and retarget onto wherever
                -- it really is, rather than calling a paid-for purchase a
                -- failure. Retargeting matters as much as the reporting
                -- does: everything downstream (the spell-scroll name gate,
                -- the right-click to scribe, the "did it leave the slot"
                -- check) works off targetBag/targetSlot, so pointing those
                -- at the real location is what lets the scribe step run at
                -- all.
                if not landedOk then
                    local foundBag, foundSlot = findCopyAnywhere(name, existingBag, existingSlot)
                    if foundBag then
                        landed = readTargetSlot(foundBag, foundSlot)
                        if landed then
                            targetBag, targetSlot = foundBag, foundSlot
                            landedOk = true
                            logLine(string.format('"%s" didn\'t land in the slot it was expected in -- found it in %s instead. It did buy.', name, slotLabel(targetBag, targetSlot)), COLOR_GOOD)
                        end
                    end
                end

                -- Didn't land in the predicted NEW slot -- but a purchase
                -- that stacks onto an EXISTING copy instead of landing
                -- anywhere new looks exactly like this too, and that's
                -- confirmed to happen on this server. If there was an
                -- existing copy before this purchase, check whether its
                -- stack just grew rather than concluding failure outright.
                local stackedInstead = false
                if not landedOk and existingBag then
                    local nowBag, nowSlot, nowStack = findExistingCopy(name)
                    if nowBag and nowStack and existingStackBefore and nowStack > existingStackBefore then
                        landedOk = true
                        stackedInstead = true
                        S.bought = S.bought + 1
                        table.insert(S.purchasedNames, name)
                        local actualSpent = math.max(0, copperBeforeBuy - myTotalCopper())
                        S.spentCopper = S.spentCopper + actualSpent
                        logLine(string.format('"%s" stacked onto an existing copy (now %d) instead of landing in a new slot -- it did buy. Not auto-scribing this one, since it isn\'t clear whether the existing copy was already scribed -- check it yourself if it wasn\'t.', name, nowStack), COLOR_GOOD)
                    end
                end

                if not landedOk then
                    logLine(string.format('"%s" didn\'t buy for some reason -- skipping it.', name), COLOR_WARN)
                    S.skipped = S.skipped + 1
                    table.insert(S.skippedNames, name)
                    idx = idx + 1
                elseif stackedInstead then
                    -- Already counted as bought and logged above; nothing
                    -- left to do but move on to the next item.
                    idx = idx + 1
                else
                    -- Hard safety gate: never right-click ANYTHING that isn't
                    -- name-confirmed as a spell scroll, no matter how
                    -- confident the earlier detection was. This is what
                    -- would have stopped the food item from getting eaten --
                    -- "landed" is read fresh from the actual slot, so this
                    -- catches a wrong purchase even if isSpellItem was fooled
                    -- earlier or something unexpected landed there.
                    local landedName = itemDisplayName(landed)
                    if not landedName:match('^Spell:%s') then
                        logLine(string.format('"%s" landed in %s but isn\'t named like a spell scroll -- NOT right-clicking it. Stopping so you can check what happened.', landedName, slotLabel(targetBag, targetSlot)), COLOR_ERR)
                        S.state = STATE.STOPPED
                        S.lastStopReason = string.format('Refused to scribe non-spell item: "%s"', landedName)
                        return
                    end

                    S.bought = S.bought + 1
                    table.insert(S.purchasedNames, name)
                    -- The ACTUAL measured drop in money on hand -- Price()
                    -- doesn't work here at all (confirmed always 0), so this
                    -- real measurement is the only trustworthy cost figure.
                    local actualSpent = math.max(0, copperBeforeBuy - myTotalCopper())
                    S.spentCopper = S.spentCopper + actualSpent
                    logLine(string.format('Scribing "%s"...', name), COLOR_INFO)

                    -- The client can reject the right-click for a while after
                    -- a purchase ("You can't use that command right now") --
                    -- confirmed happening 3x in a row before it finally took.
                    -- So: click, wait ~1s while watching for the scroll to
                    -- actually leave the slot (right-clicking a scroll
                    -- consumes it on a successful scribe), and if it's still
                    -- sitting there just click again -- up to 20 tries
                    -- (~20+s total). Respects Stop between attempts so it's
                    -- not a dead 20s wait if you want out.
                    local scribed = false
                    local maxAttempts = 20
                    local recoveryAttempted = false
                    for attempt = 1, maxAttempts do
                        mq.delay(attempt == 1 and 150 or 1000)
                        if S.stopRequested then break end

                        waitForMouseOffOverlay()
                        if S.stopRequested then break end

                        -- A few attempts in with zero progress -- the bag is
                        -- very likely not actually open. Try toggling it
                        -- open exactly ONCE as a recovery step. Right-
                        -- clicking the bag icon toggles it open/closed, so
                        -- blindly retrying risks closing an already-open bag
                        -- -- but if it WAS open, something should have
                        -- worked well before attempt 4, so by this point a
                        -- toggle is far more likely to open a closed bag
                        -- than close an open one. (With openedBags now
                        -- persisting across the whole session instead of
                        -- resetting every vendor, this recovery step should
                        -- rarely even need to fire anymore -- it's a safety
                        -- net, not the primary fix.) Only applies when
                        -- there's actually a bag involved -- an empty
                        -- top-level slot has nothing to toggle.
                        if targetSlot ~= 0 and attempt == 4 and not scribed and not recoveryAttempted then
                            recoveryAttempted = true
                            waitForMouseOffOverlay()
                            if openBagIfClosed(targetBag) then
                                logLine(string.format('Still no progress on "%s" -- bag %d reads as closed, re-opening it.', name, targetBag), COLOR_WARN)
                            end
                        end

                        mq.cmd(targetSlotNotifyCmd(targetBag, targetSlot))
                        handleScribeConfirmIfOpen()

                        for _ = 1, 5 do
                            local stillThere = readTargetSlot(targetBag, targetSlot)
                            if not stillThere or itemDisplayName(stillThere) ~= name then
                                scribed = true
                                break
                            end
                            mq.delay(200)
                        end
                        if scribed then break end
                        if S.stopRequested then break end

                        if attempt % 5 == 0 then
                            logLine(string.format('Still trying to scribe "%s" (attempt %d/%d)...', name, attempt, maxAttempts), COLOR_WARN)
                        end
                    end

                    if scribed then
                        -- The scroll can transit through the cursor briefly
                        -- as part of the normal scribe animation even after
                        -- it's left the bag slot -- wait for the cursor to
                        -- actually clear too before calling this done,
                        -- otherwise the cursor-safety check on the very next
                        -- loop iteration can catch it mid-transition and
                        -- think something went wrong (it didn't -- this is
                        -- what caused the false "unexpected item on cursor"
                        -- stop right after a successful scribe).
                        for _ = 1, 15 do -- up to ~3s
                            if not cursorItemName() then break end
                            mq.delay(200)
                        end
                        local stuck = cursorItemName()
                        if stuck then
                            logLine(string.format('"%s" scribed, but something is still on the cursor afterward ("%s") -- stopping to be safe.', name, stuck), COLOR_ERR)
                            S.state = STATE.STOPPED
                            S.lastStopReason = string.format('Cursor not clear after scribing "%s"', name)
                            return
                        end
                        logLine(string.format('Confirmed scribed: "%s" (cost %s, scroll left %s).', name, formatCoin(actualSpent), slotLabel(targetBag, targetSlot)), COLOR_GOOD)

                        -- Scribing can change the usable-only filtered list. Give
                        -- the UI a short chance to refresh before choosing the next
                        -- row. If the row count shrank, keep this same visible index
                        -- because the next unvisited item has shifted into it.
                        local afterScribeRowCount = merchantVisibleRowCount()
                        for _ = 1, 10 do
                            if afterScribeRowCount and afterScribeRowCount ~= rowCountBeforeRow then break end
                            mq.delay(50)
                            afterScribeRowCount = merchantVisibleRowCount()
                        end
                        if afterScribeRowCount and afterScribeRowCount ~= rowCountBeforeRow then
                            logLine(string.format('[merchant scan] Visible row count changed after row #%d: %d -> %d.', idx, rowCountBeforeRow, afterScribeRowCount), COLOR_WARN)
                            lastVisibleRowCount = afterScribeRowCount
                            if afterScribeRowCount < rowCountBeforeRow then
                                logLine(string.format('[merchant scan] Keeping next scan at row #%d because the filtered list shrank; the next unvisited item may have shifted into this row.', idx), COLOR_WARN)
                            else
                                idx = idx + 1
                            end
                        else
                            idx = idx + 1
                        end
                    else
                        if S.stopRequested then
                            logLine('Stopped by user.', COLOR_WARN)
                            S.state = STATE.STOPPED
                            S.lastStopReason = 'Stopped by user'
                            return
                        end
                        logLine(string.format('"%s" was bought, but the scroll never left %s after %d tries -- a common cause is a full spellbook. Stopping so you can check.', name, slotLabel(targetBag, targetSlot), maxAttempts), COLOR_ERR)
                        S.state = STATE.STOPPED
                        S.lastStopReason = string.format('Scribe failed on "%s"', name)
                        return
                    end
                end
            end
        end
        end

        ::nextItem::
        mq.delay(100)
    end
end

-- ============================================================================
-- Nav & Shop: path to a named NPC, open their merchant window, run the exact
-- same buy-everything logic as a normal Start, then close the merchant when
-- done -- a full "walk up, buy it all, walk away" cycle. Built to test with
-- one NPC first; the plan is to expand to a list of stops later.
--
-- UNVERIFIED, same as everything else in this script has been at first:
-- /nav id <ID> for pathing, and /click right target for opening the merchant
-- window, are both standard MQ2 commands I'm reasonably confident about, but
-- neither has been tested live yet in this script.
-- ============================================================================
-- The "=" prefix forces an EXACT name match instead of a substring match --
-- without it, "Illusionist Sevat" also matches "Illusionist Sevata", which
-- is exactly the wrong-NPC problem this fixes. Used for both the spawn
-- lookup (so /nav id targets the right one) and the actual /target command.
local function findNpcSpawn(npcName)
    local ok, spawn = pcall(function() return mq.TLO.Spawn(string.format('npc "=%s"', npcName)) end)
    if not ok or not spawn or not spawn() then return nil end
    return spawn
end

local function runNavAndShop(npcName)
    S.state = STATE.RUNNING
    S.lastStopReason = nil
    logLine(string.format('Nav & Shop: looking for "%s"...', npcName), COLOR_GOLD)

    -- Don't kick off anything -- not even the nav -- until the mouse is
    -- confirmed off the overlay.
    waitForMouseOffOverlay()
    if S.stopRequested then
        logLine('Stopped by user.', COLOR_WARN)
        S.state = STATE.STOPPED
        S.lastStopReason = 'Stopped by user'
        return
    end

    local meshLoaded = false
    pcall(function() meshLoaded = mq.TLO.Navigation.MeshLoaded() end)
    if not meshLoaded then
        logLine('No navmesh loaded for this zone -- can\'t auto-path. Load MQ2Nav\'s mesh for this zone first.', COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = 'No navmesh loaded'
        return
    end

    local spawn = findNpcSpawn(npcName)
    if not spawn then
        logLine(string.format('Could not find an exact match for "%s" in this zone.', npcName), COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = string.format('NPC not found: "%s"', npcName)
        return
    end
    local npcId = spawn.ID()

    logLine(string.format('Found "%s" (#%d) -- navigating...', npcName, npcId), COLOR_INFO)
    mq.cmdf('/nav id %d', npcId)
    mq.delay(300)

    local navStartAt = os.clock()
    local lastNavMsgAt = 0
    while true do
        if S.stopRequested then
            logLine('Stopped by user.', COLOR_WARN)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Stopped by user'
            mq.cmd('/nav stop')
            return
        end
        local navActive = false
        pcall(function() navActive = mq.TLO.Navigation.Active() end)
        if not navActive then break end
        if (os.clock() - navStartAt) > 60 then
            logLine(string.format('Navigation to "%s" timed out after 60s -- stopping.', npcName), COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Navigation timed out'
            mq.cmd('/nav stop')
            return
        end
        if (os.clock() - lastNavMsgAt) > 5.0 then
            lastNavMsgAt = os.clock()
            logLine(string.format('Still navigating to "%s"...', npcName), COLOR_MUTE)
        end
        mq.delay(200)
    end

    logLine(string.format('Arrived near "%s".', npcName), COLOR_GOOD)

    -- Retry for a few seconds rather than one shot -- right after nav
    -- finishes, the client doesn't always have the NPC targetable
    -- immediately (still settling into position, LoS, etc.), and one
    -- 300ms attempt was giving up before it had a real chance to land.
    local targetOk = false
    for attempt = 1, 10 do -- up to ~3s
        if S.stopRequested then break end
        mq.cmdf('/target npc "=%s"', npcName)
        mq.delay(300)
        pcall(function() targetOk = mq.TLO.Target.ID() == npcId end)
        if targetOk then break end
    end
    if not targetOk then
        logLine(string.format('Could not target "%s" after arriving.', npcName), COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = 'Could not target NPC'
        return
    end

    waitForMouseOffOverlay()
    mq.cmd('/click right target')

    local merchOpen = false
    for _ = 1, 25 do -- up to ~5s
        if merchantOpen() then
            merchOpen = true
            break
        end
        mq.delay(200)
    end
    if not merchOpen then
        logLine(string.format('Right-clicked "%s" but the merchant window never opened.', npcName), COLOR_ERR)
        S.state = STATE.STOPPED
        S.lastStopReason = 'Merchant window never opened'
        return
    end

    logLine('Merchant window open -- starting the buy run.', COLOR_GOOD)
    runSpellSpree()

    -- Always close, no matter how the buy run ended -- this is meant to be a
    -- full, self-contained cycle, not something that leaves a vendor window
    -- hanging open for you to deal with afterward.
    closeVendor()
    logLine('Nav & Shop: done, merchant closed.', COLOR_GOLD)
end

-- ============================================================================
-- Shopping Spree: run Nav & Shop back-to-back for every checked class/tier
-- vendor. A failure on one vendor (not found, merchant never opened, etc.)
-- just moves on to the next one -- but running out of money stops the whole
-- spree early, since every vendor after that would fail the same way.
-- ============================================================================
local function collectSelectedVendors()
    local list = {}
    for _, className in ipairs(CLASS_ORDER) do
        for _, tier in ipairs(TIERS) do
            if S.selected[className][tier] then
                local npcName = VENDOR_DATA[className] and VENDOR_DATA[className][tier]
                if npcName then
                    table.insert(list, { class = className, tier = tier, name = npcName })
                end
            end
        end
    end
    return list
end

-- Some stop reasons mean the whole spree needs to stop, not just this one
-- vendor -- something stuck on the cursor needs your attention right now
-- (don't go wandering off to another vendor with it), and a full inventory
-- or spellbook will just fail the exact same way at every vendor after
-- this one too, so there's no point continuing.
local function isSpreeAbortingReason(reason)
    if not reason then return false end
    local r = reason:lower()
    return r:find('cursor') ~= nil
        or r:find('out of money') ~= nil
        or r:find('inventory full') ~= nil
        or r:find('scribe failed') ~= nil
end

local function printSpreeSummary()
    if #S.purchasedNames > 0 then
        logLine(string.format('Purchased (%d): %s', #S.purchasedNames, table.concat(S.purchasedNames, ', ')), COLOR_GOOD)
    else
        logLine('Purchased (0): none', COLOR_GOOD)
    end
    if #S.skippedNames > 0 then
        logLine(string.format('Skipped (%d): %s', #S.skippedNames, table.concat(S.skippedNames, ', ')), COLOR_WARN)
    else
        logLine('Skipped (0): none', COLOR_MUTE)
    end
end

local function runShoppingSpree()
    local list = collectSelectedVendors()
    if #list == 0 then
        logLine('No vendors selected -- check at least one class/tier box first.', COLOR_WARN)
        return
    end

    S.bought, S.skipped, S.spentCopper = 0, 0, 0
    S.purchasedNames, S.skippedNames = {}, {}
    logLine(string.format('Shopping spree: %d vendor(s) selected.', #list), COLOR_GOLD)
    for i, entry in ipairs(list) do
        if S.stopRequested then
            logLine('Stopped by user.', COLOR_WARN)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Stopped by user'
            printSpreeSummary()
            return
        end

        logLine(string.format('--- Vendor %d/%d: %s (%s %s) ---', i, #list, entry.name, entry.class, entry.tier), COLOR_GOLD)
        runNavAndShop(entry.name)

        if S.stopRequested then
            logLine('Stopped by user.', COLOR_WARN)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Stopped by user'
            printSpreeSummary()
            return
        end
        if isSpreeAbortingReason(S.lastStopReason) then
            logLine(string.format('"%s" -- ending the shopping spree early, no point visiting the rest.', S.lastStopReason), COLOR_ERR)
            S.state = STATE.STOPPED
            printSpreeSummary()
            return
        end
    end

    logLine(string.format('Shopping spree: all %d vendor(s) done.', #list), COLOR_GOLD)
    S.state = STATE.DONE
    S.lastStopReason = 'Shopping spree complete'
    printSpreeSummary()
end

-- ============================================================================
-- ImGui
-- ============================================================================
local function stateColor()
    if S.state == STATE.RUNNING then return COLOR_GOOD end
    if S.state == STATE.DONE then return COLOR_GOLD end
    if S.state == STATE.STOPPED then return COLOR_WARN end
    return COLOR_MUTE
end

local function draw()
    ImGui.SetNextWindowSize(600, 780, ImGuiCond.FirstUseEver)
    local shown
    open, shown = ImGui.Begin('SpellSpree v' .. VERSION .. '###spellSpree', open)
    if not shown then
        ImGui.End()
        return
    end

    -- Two independent ways to detect "is the mouse over this window" --
    -- kept both since IsWindowHovered() alone wasn't reliably catching it.
    local hoverOk1, hover1 = pcall(function() return ImGui.IsWindowHovered() end)
    local wx, wy, ww, wh, mx, my = 0, 0, 0, 0, 0, 0
    local rectOk = pcall(function()
        wx, wy = ImGui.GetWindowPos()
        ww, wh = ImGui.GetWindowSize()
        mx, my = ImGui.GetMousePos()
    end)
    local hover2 = rectOk and mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh
    S.mouseOverOverlay = (hoverOk1 and hover1 == true) or (hover2 == true)

    ImGui.TextColored(COLOR_GOLD[1], COLOR_GOLD[2], COLOR_GOLD[3], COLOR_GOLD[4], 'SpellSpree')
    ImGui.SameLine()
    ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4], 'buy & scribe every spell, vendor after vendor')
    ImGui.Separator()
    ImGui.Dummy(0, 2)

    local mOpen = merchantOpen()
    ImGui.Text('Merchant:')
    ImGui.SameLine()
    if mOpen then
        ImGui.TextColored(COLOR_GOOD[1], COLOR_GOOD[2], COLOR_GOOD[3], COLOR_GOOD[4], 'Open')
    else
        ImGui.TextColored(COLOR_ERR[1], COLOR_ERR[2], COLOR_ERR[3], COLOR_ERR[4], 'Not open')
    end
    ImGui.SameLine()
    ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4], '    Status:')
    ImGui.SameLine()
    local sc = stateColor()
    ImGui.TextColored(sc[1], sc[2], sc[3], sc[4], S.state)
    local isInPoK = inPoK()
    ImGui.SameLine()
    ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4], '    In PoK:')
    ImGui.SameLine()
    if isInPoK then
        ImGui.TextColored(COLOR_GOOD[1], COLOR_GOOD[2], COLOR_GOOD[3], COLOR_GOOD[4], 'Yes')
    else
        ImGui.TextColored(COLOR_ERR[1], COLOR_ERR[2], COLOR_ERR[3], COLOR_ERR[4], 'No')
    end
    if S.state == STATE.RUNNING and S.currentName then
        ImGui.SameLine()
        ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4],
            string.format('(#%d: %s)', S.currentIndex, S.currentName))
    end
    if S.lastStopReason and S.state ~= STATE.RUNNING then
        ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4],
            'Last stop reason: ' .. S.lastStopReason)
    end
    if S.mouseOverOverlay then
        ImGui.TextColored(COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3], COLOR_WARN[4],
            '!! Mouse is over this window -- move it into the game world')
    end
    if S.state == STATE.RUNNING then
        ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4],
            'Leave any bag windows this opens alone until it\'s done.')
    end

    ImGui.Dummy(0, 6)
    ImGui.Separator()
    ImGui.Dummy(0, 2)
    ImGui.Text(string.format('Bought: %d', S.bought))
    ImGui.SameLine()
    ImGui.Text(string.format('    Skipped: %d', S.skipped))
    ImGui.SameLine()
    ImGui.TextColored(COLOR_WHITE[1], COLOR_WHITE[2], COLOR_WHITE[3], COLOR_WHITE[4],
        '    Spent: ' .. formatCoinPPOnly(S.spentCopper))
    ImGui.Text('On hand: ' .. formatCoin(myTotalCopper()))

    ImGui.Dummy(0, 6)
    ImGui.Separator()
    ImGui.Dummy(0, 2)
    ImGui.TextColored(COLOR_GOLD[1], COLOR_GOLD[2], COLOR_GOLD[3], COLOR_GOLD[4], 'Shopping List')
    ImGui.SameLine()
    ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4], '-- pick vendors, then run')

    if S.detectedClasses then
        local names = {}
        for _, className in ipairs(CLASS_ORDER) do
            if S.detectedClasses[className] then table.insert(names, className) end
        end
        ImGui.TextColored(COLOR_MUTE[1], COLOR_MUTE[2], COLOR_MUTE[3], COLOR_MUTE[4],
            'Detected: ' .. (#names > 0 and table.concat(names, ', ') or 'none of your classes have PoK vendors'))
    else
        ImGui.TextColored(COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3], COLOR_WARN[4],
            'No classes detected -- showing the full list.')
    end
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 90)
    if ImGui.Button('Re-detect', 80, 0) then
        S.reDetectRequested = true
    end

    ImGui.Dummy(0, 2)
    for _, className in ipairs(CLASS_ORDER) do
        if (not S.detectedClasses) or S.detectedClasses[className] then
            local allChecked = true
            for _, tier in ipairs(TIERS) do
                if not S.selected[className][tier] then
                    allChecked = false
                    break
                end
            end
            local newClassChecked, classChanged = ImGui.Checkbox('##class_' .. className, allChecked)
            if classChanged then
                for _, tier in ipairs(TIERS) do
                    S.selected[className][tier] = newClassChecked
                end
            end
            ImGui.SameLine()
            if ImGui.TreeNode(className) then
                ImGui.Indent()
                for _, tier in ipairs(TIERS) do
                    local checked, changed = ImGui.Checkbox(tier .. '##' .. className, S.selected[className][tier])
                    if changed then
                        S.selected[className][tier] = checked
                    end
                end
                ImGui.Unindent()
                ImGui.TreePop()
            end
        end
    end

    local selectedCount = 0
    for _, className in ipairs(CLASS_ORDER) do
        for _, tier in ipairs(TIERS) do
            if S.selected[className][tier] then
                selectedCount = selectedCount + 1
            end
        end
    end

    ImGui.Dummy(0, 4)
    local newStop, stopChanged = ImGui.Checkbox('Stop when out of money (uncheck to skip and keep shopping)', S.stopOnOutOfMoney)
    if stopChanged then S.stopOnOutOfMoney = newStop end

    ImGui.Dummy(0, 4)
    local canSpree = (S.state ~= STATE.RUNNING) and selectedCount > 0 and isInPoK
    if not canSpree then ImGui.BeginDisabled() end
    if ImGui.Button(string.format('Run Shopping Spree (%d selected)', selectedCount), 260, 0) then
        S.stopRequested = false
        S.shoppingSpreeRequested = true
    end
    if not canSpree then ImGui.EndDisabled() end

    ImGui.SameLine()
    local canStop = (S.state == STATE.RUNNING)
    if not canStop then ImGui.BeginDisabled() end
    if ImGui.Button('Stop', 100, 0) then
        S.stopRequested = true
    end
    if not canStop then ImGui.EndDisabled() end

    if not isInPoK and S.state ~= STATE.RUNNING then
        ImGui.TextColored(COLOR_WARN[1], COLOR_WARN[2], COLOR_WARN[3], COLOR_WARN[4],
            'Get to Plane of Knowledge before running -- vendors are only there.')
    end

    ImGui.Dummy(0, 6)
    ImGui.Separator()
    ImGui.Dummy(0, 2)
    ImGui.Text('Log')
    ImGui.SameLine()
    ImGui.SetCursorPosX(ImGui.GetWindowWidth() - 90)
    if ImGui.Button('Clear Log', 80, 0) then
        S.log = {}
    end
    ImGui.BeginChild('SpellSpreeLog', 0, 140, true)
    local wasNearBottom = true
    pcall(function()
        wasNearBottom = (ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 15)
    end)
    ImGui.PushTextWrapPos(0.0)
    for _, entry in ipairs(S.log) do
        ImGui.TextColored(entry.color[1], entry.color[2], entry.color[3], entry.color[4],
            entry.t .. '  ' .. entry.text)
    end
    ImGui.PopTextWrapPos()
    if wasNearBottom then ImGui.SetScrollHereY(1.0) end
    ImGui.EndChild()

    ImGui.End()
end

mq.imgui.init('SpellSpreeWindow', draw)

-- Best-effort price-quote listener -- see the block comment above
-- parseCopperFromText for why this is not trusted as the primary defense.
--
-- Now matched against the EXACT confirmed wording, copied straight from
-- chat: "Cavalier Waut tells you, 'That'll be 159 platinum 2 gold 1 silver
-- 9 copper per Spell: Crusaders Touch.'" -- so the earlier guesses (a "for"
-- variant that was never right, and a trailing #*# on the "per" one that may
-- well have been the actual problem) are gone. Simplified to the minimum
-- needed: one clean anchor, no trailing wildcard after the capture that
-- closes the pattern.
--
-- A silent pattern mismatch and mq.event genuinely not firing in this
-- environment look identical from here -- no error, just nothing happening
-- -- and this codebase has already hit that exact thing before (see the note
-- above logLine: two other chat events never fired even once in testing).
-- The debug listener right below answers that directly instead of leaving it
-- another guess: it matches on nothing but "tells you," and logs the raw
-- text straight to the SpellSpree log for ANY tell during a run. If that
-- never shows anything either, the answer is definitive -- mq.event isn't
-- catching vendor tells in this environment at all, and no amount of further
-- pattern tweaking will fix it. If it DOES show the tell but the price still
-- isn't being used, the raw text it logs is exactly what's needed to fix the
-- structured pattern for real.
local function onPriceQuote(_, amountText, itemText)
    local copper = parseCopperFromText(amountText)
    if copper then
        local itemName = tostring(itemText or ''):gsub('%s+$', '')
        priceQuotes[itemName] = { copper = copper, at = os.clock() }
        dbgLine(string.format('[price quote] "%s" = %s', itemName, formatCoin(copper)))
    end
end
-- Both wordings, confirmed both actually occur on the same vendor for
-- different items -- "for" was dropped in an earlier version on the
-- (wrong) assumption only "per" was real.
mq.event('spellspree_price_per', "#*#tells you, 'That'll be #1# per #2#.'", onPriceQuote)
mq.event('spellspree_price_for', "#*#tells you, 'That'll be #1# for #2#.'", onPriceQuote)

-- Raw-tell firehose. Only registered under DEBUG -- it matches every tell
-- during a run, so with the structured patterns above now confirmed working
-- it's pure duplication of the [price quote] line next to it.
if DEBUG then
    mq.event('spellspree_price_debug', "#*#tells you, #1#", function(_, rest)
        logLine(string.format('[tell debug] %s', tostring(rest)), COLOR_MUTE)
    end)
end

-- ============================================================================
-- Main loop -- all blocking work (mq.delay calls inside runSpellSpree and its
-- helpers) happens here, never inside the ImGui draw callback.
-- ============================================================================
logLine(string.format('SpellSpree v%s loaded. Check some vendors below and hit Run Shopping Spree.', VERSION), COLOR_GOLD)

while open do
    mq.doevents()
    if S.reDetectRequested then
        S.reDetectRequested = false
        local ok, detected = pcall(detectClasses)
        if ok and detected then
            local set = {}
            for _, className in ipairs(detected) do
                set[className] = true
            end
            S.detectedClasses = set
            logLine('Detected class(es): ' .. table.concat(detected, ', '), COLOR_GOLD)
        else
            logLine('Could not detect any classes -- showing the full list instead.', COLOR_WARN)
            S.detectedClasses = nil
        end
    end
    if S.shoppingSpreeRequested and S.state ~= STATE.RUNNING then
        S.shoppingSpreeRequested = false
        local ok, err = pcall(runShoppingSpree)
        if not ok then
            logLine('Unexpected error: ' .. tostring(err), COLOR_ERR)
            S.state = STATE.STOPPED
            S.lastStopReason = 'Script error'
        end
    end
    mq.delay(50)
end
