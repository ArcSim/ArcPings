-- ═══════════════════════════════════════════════════════════════════════════
-- ArcPings (Arc Pings) — ping keys + feed window + ping alerts  (12.1 ONLY)
--
-- Standalone twin of ArcUI's Pings module (ArcUI's copy goes dormant when this
-- addon is loaded). Same engine, same secrecy model:
--   * CHAT_MSG_PING is the one readable receive channel. In combat/restricted
--     content the payload is SECRET -- SetText still renders it (secret sink),
--     timestamps/lifetime/ordering are ours (arrival time is never secret).
--   * NEVER concatenate the payload (string ops on secrets throw): timestamp,
--     text and sender live on SEPARATE FontStrings; rows own their entry for
--     life (secret text can only be SetText once).
--   * Class colors resolve only when the sender is readable (outside
--     combat); honest fallbacks otherwise. No TTS (combat-first: kept simple).
-- Options: Blizzard Settings panel (no libraries). Zero idle CPU. No pcall.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON = ...

local HAS_ACTION_PINGS = (C_Ping ~= nil)
    and (Enum and Enum.PingSubjectType and Enum.PingSubjectType.ActionReady ~= nil)

-- ── DB ───────────────────────────────────────────────────────────────────────
local DEFAULTS = {
    enabled       = true,    -- ships ON (Arc's call): visible feature, one toggle off
    locked        = true,
    -- window draggable while the options panel is open, regardless of the
    -- lock (Edit-Mode feel; ships ON by Arc's call -- the panel being open IS
    -- the opt-in, and the toggle below turns it off)
    panelDrag     = true,
    -- FIXED window width (no dynamic widening) -- default sized so the
    -- longest callout ("[Spell Name] will be ready in 0:12!" + sender) fits
    width         = 340,
    -- base height: 0 = automatic (hugs the entries); a value keeps the window
    -- at least this tall (it still grows when more entries need the room)
    height        = 0,
    -- static box: always sized for maxEntries and always on screen -- a fixed
    -- frame pings flow through (chat-frame style), never growing/shrinking
    staticSize    = false,
    showMinimap   = true,   -- minimap button (click = options, drag = reposition)
    minimapAngle  = 220,    -- degrees around the minimap rim
    windowScale   = 1,    -- scales the WHOLE window (everything in it)
    showTitle     = true, -- the "Arc Pings" watermark while unlocked/options open
    -- per-edge padding around the pieces' bounding box (the box shrink-wraps
    -- the layout; these add breathing room, 0 = flush against the pieces)
    rowPadTop     = 2,
    rowPadBottom  = 2,
    maxEntries    = 8,
    entrySeconds  = 12,
    fontSize      = 12,
    fontOutline   = "OUTLINE",  -- "NONE" | "OUTLINE" | "THICKOUTLINE"
    -- chromeless by default: the window is INVISIBLE except its entries;
    -- background/border are opt-in (the border still shows while unlocked)
    showBackground = false,
    showBorder    = false,
    bgAlpha       = 0.35,
    newestOnTop   = true,
    showTimestamp = false,   -- default look: no timestamp (Arc's call)
    showSender    = true,
    -- COMBAT-FIRST RULE (Arc's hard rule): features that only work OUT of
    -- combat do not ship at all. Removed for that reason: pinged-spell icon,
    -- ping-type filter, class-icon sender style (all need the payload, which
    -- is SECRET in combat).
    -- FREE ROW LAYOUT (Plater-style): each piece anchors LEFT or RIGHT of the
    -- row with fine x/y offsets, arranged by dragging in the options preview.
    -- The ping text always fills the space between the innermost pieces.
    -- default layout = Blizzard's chat baseline: "10:59 [Sender]: [Spell] is
    -- ready!" -- timestamp at the left, sender right of it, text flowing after
    iconPos = "left",  iconX = 0,  iconY = 0,
    timePos = "left",  timeX = 0, timeY = 0,
    senderPos = "right", senderX = 0, senderY = 0,
    -- optional piece-to-piece anchoring: "row" (free placement, default) or
    -- the name of another piece ("icon"/"time"/"sender"/"text"). When
    -- anchored, Pos means which SIDE of the target ("left"/"right" of it),
    -- X is the gap from it and Y rides relative to the target's line.
    iconAnchorTo = "row", timeAnchorTo = "row", senderAnchorTo = "time",
    -- per-piece sizes: 0 = automatic (icon follows the row, texts follow the
    -- global Font Size); any positive number overrides just that piece
    iconSize = 0, timeSize = 0, senderSize = 0, textSize = 0,
    -- the ping text still spans (so long lines truncate), but the side it
    -- reads from is draggable like any other piece: textPos anchors the
    -- glyphs LEFT or RIGHT, textX pushes them in from that edge (same-line
    -- pieces still push further; the far side keeps auto-truncating)
    textPos = "left", textX = 0, textY = 0,
    -- colors ({r,g,b})
    colText   = { 0.949, 0.941, 0.925 },  -- #F2F0EC (Arc's palette)
    colTime   = { 0.75, 0.83, 0.92 },
    colSender = { 0.7, 0.9, 0.7 },
    colBg     = { 0.043, 0.059, 0.102 },
    colBorder = { 0.114, 0.165, 0.247 },
    strata        = "MEDIUM",
    animStyle     = "pulse",  -- entrance: none | fade | pulse | flash | zoom
    animInSecs    = 0.3,      -- entrance duration (scales the sequence)
    animOutStyle  = "fade",   -- expiry: none (snap off) | fade
    animOutSecs   = 0.4,      -- expiry fade duration
    -- WHERE the feed window is allowed to appear. All ON by default: this
    -- narrows an existing feature, so switching one off is the opt-in.
    showInWorld        = true,
    showInDungeon      = true,   -- normal / heroic / mythic 0
    showInMythicPlus   = true,
    showInRaid         = true,
    showInBattleground = true,
    showInArena        = true,
    showInScenario     = true,   -- scenarios, delves, follower dungeons

    alertsEnabled = false,
    alertSound    = "None",
    alertThrottle = 2,
    -- PING KEYS (opt-in, house rule: new features default OFF). Hold pkKey and
    -- press a tracked spell's own keybind to ping it instead of casting it.
    -- pkSpells = array of { id = spellID, key = "manual key override or nil" }.
    -- Each selected entry carries its own mode: "key" (ping key + its key) or
    -- pkOnlySelected narrows the ping key to the picked list (default: any spell)
    -- "always" (pings on every press).

    pkEnabled     = true,   -- ships ON (Arc's call): the headline feature
    -- INVERTED on purpose: the ping key works on EVERY bound spell out of the
    -- box (a ping key that does nothing on most spells is just confusing), and
    -- this narrows it to the picked list. The option itself still defaults off.
    pkOnlySelected = false,
    -- "Every time I cast it" spells as a group: on by default. There is NO
    -- checkbox for this -- pkToggleKey is the only control, and the holder owns
    -- the live value (the key can flip it in combat). Saved back on regen.
    pkAutoOn      = true,
    pkToggleKey   = "",
    pkKey         = "",
    pkSpells      = nil,
    pos           = nil,
}

local SOUNDS = { None = 0, Alarm = 567458, Bell = 566558, Warning = 567397 }

-- ArcUI's sound pack (36 sounds) -- usable here whenever ArcUI is installed
-- (files load from ArcUI's folder; no dependency otherwise)
local ARC_SOUND_FILES = {
    ["ArcUI: Bleat"] = "Bleat.ogg", ["ArcUI: Cat Meow"] = "CatMeow2.ogg",
    ["ArcUI: Chicken Alarm"] = "ChickenAlarm.ogg", ["ArcUI: Cow Mooing"] = "CowMooing.ogg",
    ["ArcUI: Goat Bleating"] = "GoatBleating.ogg", ["ArcUI: Kitten Meow"] = "KittenMeow.ogg",
    ["ArcUI: Roaring Lion"] = "RoaringLion.ogg", ["ArcUI: Rooster Chicken"] = "RoosterChickenCalls.ogg",
    ["ArcUI: Sheep Bleat"] = "SheepBleat.ogg", ["ArcUI: Air Horn"] = "AirHorn.ogg",
    ["ArcUI: Bike Horn"] = "BikeHorn.ogg", ["ArcUI: Error Beep"] = "ErrorBeep.ogg",
    ["ArcUI: Ringing Phone"] = "RingingPhone.ogg", ["ArcUI: Robot Blip"] = "RobotBlip.ogg",
    ["ArcUI: Warning Siren"] = "WarningSiren.ogg", ["ArcUI: Acoustic Guitar"] = "AcousticGuitar.ogg",
    ["ArcUI: Brass"] = "Brass.mp3", ["ArcUI: Drums"] = "Drums.ogg",
    ["ArcUI: Glass"] = "Glass.mp3", ["ArcUI: Synth Chord"] = "SynthChord.ogg",
    ["ArcUI: Tada Fanfare"] = "TadaFanfare.ogg", ["ArcUI: Temple Bell"] = "TempleBellHuge.ogg",
    ["ArcUI: Xylophone"] = "Xylophone.ogg", ["ArcUI: Applause"] = "Applause.ogg",
    ["ArcUI: Banana Peel Slip"] = "BananaPeelSlip.ogg", ["ArcUI: Batman Punch"] = "BatmanPunch.ogg",
    ["ArcUI: Blast"] = "Blast.ogg", ["ArcUI: Boxing Arena"] = "BoxingArenaSound.ogg",
    ["ArcUI: Double Whoosh"] = "DoubleWhoosh.ogg", ["ArcUI: Heartbeat"] = "HeartbeatSingle.ogg",
    ["ArcUI: Sharp Punch"] = "SharpPunch.ogg", ["ArcUI: Shotgun"] = "Shotgun.ogg",
    ["ArcUI: Squeaky Toy"] = "SqueakyToyShort.ogg", ["ArcUI: Squish"] = "SquishFart.ogg",
    ["ArcUI: Torch"] = "Torch.ogg", ["ArcUI: Water Drop"] = "WaterDrop.ogg",
    ["ArcUI: Cartoon Voice"] = "CartoonVoiceBaritone.ogg", ["ArcUI: Cartoon Walking"] = "CartoonWalking.ogg",
    ["ArcUI: Oh No"] = "OhNo.ogg",
}

-- resolve a sound NAME to something PlaySoundFile accepts: builtin file IDs,
-- then any LibSharedMedia-registered sound (SharedMedia packs, other addons),
-- then ArcUI's pack by path
local function ResolveSound(name)
    if not name or name == "None" then return nil end
    local builtin = SOUNDS[name]
    if builtin and builtin ~= 0 then return builtin end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local f = lsm and lsm:Fetch("sound", name, true)
    if f then return f end
    local arc = ARC_SOUND_FILES[name]
    if arc then return "Interface\\AddOns\\ArcUI\\Sounds\\" .. arc end
    return nil
end

-- the full pickable list: builtins + ArcUI pack (if installed) + every
-- LSM-registered sound
local function BuildSoundList()
    local seen, list = {}, {}
    local function add(n) if n and not seen[n] then seen[n] = true; list[#list + 1] = n end end
    add("Alarm"); add("Bell"); add("Warning")
    if C_AddOns and C_AddOns.DoesAddOnExist and C_AddOns.DoesAddOnExist("ArcUI") then
        for n in pairs(ARC_SOUND_FILES) do add(n) end
    end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm and lsm.List then
        for _i, n in ipairs(lsm:List("sound") or {}) do
            if n ~= "None" then add(n) end
        end
    end
    table.sort(list)
    table.insert(list, 1, "None")
    return list
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SETTING SCOPE
--
-- ArcPingsDB is ACCOUNT-WIDE, and stays the base every character reads. On
-- top of it sit sparse per-character and per-spec patches:
--
--   ArcPingsDB           the shared base
--   ArcPingsDB._ov[key]  { onlyTheSettingsYouChangedThere }
--   ArcPingsDB._char[c]  the handful that are per character no matter what
--
-- The patches are SPARSE, which is the whole point. An override is not a copy
-- of the config, it is the two or three settings you wanted different here, so
-- twelve specs cost twelve tiny tables instead of twelve configs. Anything you
-- never touch keeps following the account value, including later changes to it.
--
-- Reads resolve most-specific-first: this char + this spec, then this char,
-- then the account base, then the shipped default.
local SCOPE_ACCOUNT, SCOPE_CHAR, SCOPE_SPEC = "account", "char", "spec"

-- Per character NO MATTER WHAT, each for its own reason:
--   pkSpells    a tracked list is one character's bars. Sharing it across the
--               account was a real bug here: the standalone had no per-char
--               store at all, so a Shaman's list showed up on a Mage.
--   pkAutoOn    runtime state, not a setting. It gets flipped mid-pull by a
--               snippet, and routing that through the scope layer would capture
--               an override into whatever scope the panel was left on.
--   pkEditScope which scope you are editing. Storing it in a scope is circular.
local PK_CHAR_ONLY = { pkSpells = true, pkAutoOn = true, pkEditScope = true }

local function DB()
    -- adopt the pre-rename SavedVariables once (the addon shipped to nobody
    -- under the old name, but a tester's config should not evaporate)
    if ArcPingsDB == nil and type(ArcPingFeedDB) == "table" then
        ArcPingsDB = ArcPingFeedDB
    end
    ArcPingsDB = ArcPingsDB or {}
    return ArcPingsDB
end

local function CharKey()
    local n = UnitName("player") or "?"
    local r = GetRealmName and GetRealmName() or "?"
    return n .. "-" .. r
end

local function SpecKey()
    if not (GetSpecialization and GetSpecializationInfo) then return nil end
    local i = GetSpecialization()
    local id = i and GetSpecializationInfo(i)
    if not id then return nil end
    return CharKey() .. "|" .. id
end

-- the per-character store, for the keys that never belong to the account
local function CharDB()
    local db = DB()
    db._char = db._char or {}
    local k = CharKey()
    db._char[k] = db._char[k] or {}
    return db._char[k]
end

local function ActiveScope()
    local s = CharDB().pkEditScope
    if s == SCOPE_CHAR or s == SCOPE_SPEC then return s end
    return SCOPE_ACCOUNT
end

local function ScopeKey(scope)
    if scope == SCOPE_CHAR then return CharKey() end
    if scope == SCOPE_SPEC then return SpecKey() end
    return nil
end

-- create=false is the read path: never spawn empty patch tables just by looking
local function OvTable(scope, create)
    local db = DB()
    local k = ScopeKey(scope)
    if not k then return nil end
    if not db._ov then
        if not create then return nil end
        db._ov = {}
    end
    local t = db._ov[k]
    if not t and create then t = {}; db._ov[k] = t end
    return t
end

-- true while the options panel is open; the scope picker PREVIEWS while it is
local panelOpen = false

-- ONE resolver for reads, so the value shown, the value saved and the value the
-- window uses can never disagree.
--
-- While the panel is OPEN the picker also PREVIEWS: you see the layer you are
-- EDITING, not the most specific one. Without that, selecting the account scope
-- would leave a character override still winning, so the window would keep the
-- character's look and it would appear as though the account had "moved with
-- it" -- and any edit made then would write that value into the account for
-- real. Panel closed = normal runtime resolution, most specific wins.
local function ResolveStore(key)
    local editing = panelOpen and ActiveScope() or nil
    if editing ~= SCOPE_CHAR and editing ~= SCOPE_ACCOUNT then
        local spec = OvTable(SCOPE_SPEC, false)
        if spec and spec[key] ~= nil then return spec end
    end
    if editing ~= SCOPE_ACCOUNT then
        local char = OvTable(SCOPE_CHAR, false)
        if char and char[key] ~= nil then return char end
    end
    local db = DB()
    if db[key] ~= nil then return db end
    return nil
end

-- Where Cfg("pos") resolved from, so Render's edge backfill lands in the very
-- same table the window is reading rather than the account base.
local function PosStore()
    return ResolveStore("pos") or DB()
end

-- Forward: the X/Y sliders need it, and it needs ScopedStore/ApplyAll below.
local SetWindowPos

-- Where a scoped setting is WRITTEN right now. Shared by SetCfg and by the
-- window's own drag-stop, so dragging the feed while editing a character or
-- spec captures the position there instead of moving it for the whole account.
local function ScopedStore()
    local scope = ActiveScope()
    if scope ~= SCOPE_ACCOUNT then
        local t = OvTable(scope, true)
        if t then return t end
    end
    return DB()
end

-- Lua 5.1 caps a function at 60 UPVALUES and BuildOptionsPanel reads a lot of
-- file-level state. Bundling the scope layer costs it ONE upvalue instead of
-- eight. (luac -p cannot catch this: our checker is 5.4, which allows 255.)
local SCOPE = {
    ACCOUNT = SCOPE_ACCOUNT, CHAR = SCOPE_CHAR, SPEC = SCOPE_SPEC,
    Active = ActiveScope, Key = ScopeKey, Ov = OvTable,
    Char = CharDB, SpecKey = SpecKey,
}

local function Cfg(key)
    if PK_CHAR_ONLY[key] then
        local c = CharDB()
        if c[key] ~= nil then return c[key] end
        return DEFAULTS[key]
    end
    local t = ResolveStore(key)
    if t then return t[key] end
    return DEFAULTS[key]
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WINDOW + ROWS (engine identical to ArcUI's module)
-- ═══════════════════════════════════════════════════════════════════════════

local win
local rows = {}
local entries = {}
local entryToken = 0
-- (panelOpen lives up with the scope layer: the resolver reads it, and a second
-- declaration here would shadow it and silently disable the scope preview)

-- the window is movable when unlocked, OR while the options panel is open
-- (unless the user turned panel-drag off)
local function CanDrag()
    return not Cfg("locked") or (panelOpen and Cfg("panelDrag") ~= false)
end

-- REQUIREMENT (Arc-verified in-game): CHAT_MSG_PING stops firing when the
-- Blizzard "Show Pings in Chat" or "Enable Pings" settings are off -- the
-- feed silently receives NOTHING. Both are plain CVars; warn + one-click fix.
-- (Only called on 12.1 clients, where the CVars exist.)
local function BlizzPingSettingsOK()
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    return get("enablePings") == "1" and get("showPingsInChat") == "1"
end
local function FixBlizzPingSettings()
    local set = C_CVar and C_CVar.SetCVar or SetCVar
    set("enablePings", "1")
    set("showPingsInChat", "1")
end
local warnedOnce = false
local function WarnIfBlizzSettingsOff()
    if warnedOnce or BlizzPingSettingsOK() then return end
    warnedOnce = true
    print("|cff33ff99Arc Pings|r: |cffff5555the Blizzard setting \"Show Pings in Chat\" (or \"Enable Pings\") is OFF -- the game sends addons nothing, so the feed stays empty.|r Use \"Fix Blizzard Ping Settings\" in /arcpings, or Blizzard Options > Gameplay > Ping System.")
end
local ROW_PAD = 2
local ApplyAll  -- fwd
local PKPanelRefresh  -- fwd: repaint every options control
local SenderDisplay  -- fwd: sender text renderer (defined below)

-- Typed window coordinates, ported from ArcUI. Offsets from the SCREEN CENTRE,
-- which is what the window is anchored by, so 0,0 is dead centre.
--
-- Always a FRESH table: sharing one between scopes is how an in-place edge
-- backfill leaks from a character override into the account base. Y is written
-- to whichever EDGE the feed grows away from, the same edge dragging preserves,
-- so the window stays put as entries come and go.
--
-- Deliberately no panel rebuild afterwards: a slider fires this for every pixel
-- of travel, and rebuilding the options tree each time is what made dragging
-- feel sticky.
SetWindowPos = function(x, y)
    local cur = Cfg("pos")
    local top = Cfg("newestOnTop") ~= false
    local pos = { (cur and cur[1]) or 0, (cur and cur[2]) or 0,
                  top = cur and cur.top, bottom = cur and cur.bottom }
    if x then pos[1] = x end
    if y then
        pos[2] = y
        if top then pos.top = y else pos.bottom = y end
    end
    ScopedStore().pos = pos
    ApplyAll()
end

local function RowHeight() return Cfg("fontSize") + 6 end

-- The row FOOTPRINT: when pieces are dragged above/below the line (their Y
-- offsets), each row must grow so stacked rows don't overlap and the window
-- matches what the layout canvas shows. Symmetric around the row center.
-- Anchored pieces ride relative to their target, so their ABSOLUTE y is the
-- anchor chain's sum (depth-capped in case of a cycle).
-- One table, four sub-tables: this chunk runs within a couple of locals of Lua's
-- 200-per-chunk ceiling, and going over is a LOAD failure, not a compile error.
local PIECE_KEYS = {
    Y      = { icon = "iconY", time = "timeY", sender = "senderY", text = "textY" },
    ANCHOR = { icon = "iconAnchorTo", time = "timeAnchorTo", sender = "senderAnchorTo" },
    POS    = { icon = "iconPos",  time = "timePos",  sender = "senderPos",  text = "textPos" },
    SIZE   = { icon = "iconSize", time = "timeSize", sender = "senderSize", text = "textSize" },
}

local function PieceHeight(which)
    local v = Cfg(PIECE_KEYS.SIZE[which])
    return ((v and v > 0) and v or Cfg("fontSize")) + 2
end

-- Where a piece ACTUALLY sits, as (center, height) measured from the layout
-- centerline. This has to mirror ApplyRowLayout's placement exactly, because
-- RowExtents shrink-wraps the entry box around it and the window clips its
-- children: any piece the box does not account for gets cut off.
--
-- The old PieceAbsY only summed Y OFFSETS down the anchor chain, which is right
-- for left/right placements but wrong for "Top"/"Bottom": those also lift the
-- piece clear of its anchor target (SetPoint BOTTOM->TOP + a 2px gap), and that
-- lift was invisible to the box math. Result: sender anchored to Ping Text at
-- Top landed correctly in the Layout Designer -- whose sample row pins the
-- centerline to its own middle and never consults RowExtents -- but in the real
-- window the centerline sat too high and the sender was clipped away.
--
-- Heights here run ~1px generous (font size + 2 vs the raw glyph height the
-- placement uses). That errs toward a slightly taller box, never a clipped one.
local function PieceBand(which, depth)
    depth = (depth or 0) + 1
    local h = PieceHeight(which)
    local y = Cfg(PIECE_KEYS.Y[which]) or 0
    if which == "text" or depth > 4 then return y, h end
    local a = Cfg(PIECE_KEYS.ANCHOR[which]) or "row"
    -- row-anchored top/bottom pin to the row's own edges, so they are contained
    -- by construction and need no extra allowance
    if a == "row" or not PIECE_KEYS.Y[a] then return y, h end
    local tc, th = PieceBand(a, depth)
    local pos = Cfg(PIECE_KEYS.POS[which]) or "left"
    if pos == "top" then
        return tc + th / 2 + 2 + y + h / 2, h
    elseif pos == "bottom" then
        return tc - th / 2 - 2 + y - h / 2, h
    end
    return tc + y, h
end


-- ASYMMETRIC shrink-wrap: the entry box hugs the pieces' actual bounding box.
-- RowExtents returns how far the layout reaches ABOVE and BELOW the layout
-- centerline (the line pieces' Y offsets are measured from); the box is
-- extents + the user's per-edge padding. No empty space unless the user adds
-- padding, and a piece can never be outside the box by construction.
local function RowExtents()
    local up, down = 0, 0
    -- (spell icon removed -- combat-first rule)
    local function ext(shown, which)
        if not shown then return end
        local c, h = PieceBand(which)
        if (c + h / 2) > up then up = c + h / 2 end
        if (h / 2 - c) > down then down = h / 2 - c end
    end
    ext(Cfg("showTimestamp"), "time")
    ext(Cfg("showSender"), "sender")
    ext(true, "text")
    return up, down
end

local function RowPads()
    local pt = tonumber(Cfg("rowPadTop")) or 2
    local pb = tonumber(Cfg("rowPadBottom")) or 2
    if pt < 0 then pt = 0 end
    if pb < 0 then pb = 0 end
    return pt, pb
end

local function LayoutRowHeight()
    local up, down = RowExtents()
    local pt, pb = RowPads()
    return math.ceil(up + pt + down + pb)
end

-- UIParent's center expressed in the WINDOW's coordinate space -- with a
-- window scale != 1 the two spaces differ, and mixing them (GetCenter vs
-- SetPoint offsets) makes the window drift on every re-anchor
local function UICenterForWin(w)
    local ux, uy = UIParent:GetCenter()
    local s = (w:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    if not s or s == 0 then s = 1 end
    return ux / s, uy / s
end

local function EnsureWindow()
    if win then return win end
    win = CreateFrame("Frame", "ArcPingsWindow", UIParent, "BackdropTemplate")
    win:SetClampedToScreen(true)
    win:SetMovable(true)
    win:EnableMouse(false)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self)
        if CanDrag() then self:StartMoving() end
    end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cx, cy = self:GetCenter()
        local ux, uy = UICenterForWin(self)
        if cx and ux then
            -- store the EDGES too: the window is re-anchored by its stable
            -- edge (top or bottom per grow direction), never by a center
            -- captured at some other height -- that center drifts every time
            -- the entry count differs from the moment it was saved
            ScopedStore().pos = { cx - ux, cy - uy,
                top    = (self:GetTop() or cy) - uy,
                bottom = (self:GetBottom() or cy) - uy }
            -- keep the typed X/Y in the options panel in step with the drag
            if PKPanelRefresh then PKPanelRefresh() end
        end
    end)
    -- Arc 2.0 skin: flat navy + 1px hairline (no ornate tooltip border)
    win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    -- NOTHING renders outside the background box: rows (and any dragged/
    -- offset piece) clip at the window rect
    win:SetClipsChildren(true)
    -- and the border can never be covered by row content: a border-only
    -- overlay ABOVE the rows carries the visible edge (the window's own
    -- edge stays transparent)
    win.edge = CreateFrame("Frame", nil, win, "BackdropTemplate")
    win.edge:SetAllPoints(win)
    win.edge:SetFrameLevel(win:GetFrameLevel() + 40)
    win.edge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    win.edge:EnableMouse(false)
    -- the title floats OUTSIDE the window, centered above its top edge. It
    -- needs its own UIParent-parented frame: the window clips its children,
    -- so anything inside can neither render above the rect nor avoid sitting
    -- on the entries. Out here it takes no layout space and overlaps nothing.
    win.titleHolder = CreateFrame("Frame", nil, UIParent)
    win.titleHolder:SetSize(140, 16)
    win.titleHolder:SetPoint("BOTTOM", win, "TOP", 0, 2)
    win.titleHolder:Hide()
    win.title = win.titleHolder:CreateFontString(nil, "OVERLAY")
    win.title:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    win.title:SetPoint("CENTER", 0, 0)
    win.title:SetAlpha(0.85)
    win.title:SetText("|cff3fc9f2Arc|r|cff8298b4 Pings|r")
    -- the holder mirrors the window's visibility (gated by the wanted flag)
    win:HookScript("OnShow", function(self) self.titleHolder:SetShown(self._titleWanted and true or false) end)
    win:HookScript("OnHide", function(self) self.titleHolder:Hide() end)
    return win
end

local function EnsureRow(i)
    local r = rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, EnsureWindow())
    -- the LAYOUT CENTERLINE: pieces anchor to this invisible line (their Y
    -- offsets are measured from it). ApplyRowLayout positions it inside the
    -- row so the box can hug the pieces ASYMMETRICALLY (top and bottom
    -- padding are independent).
    r.line = CreateFrame("Frame", nil, r)
    r.line:SetHeight(1)
    r.time = r:CreateFontString(nil, "OVERLAY")
    r.time:SetJustifyH("LEFT")
    r.time:SetTextColor(0.6, 0.7, 0.8)
    r.text = r:CreateFontString(nil, "OVERLAY")
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r.sender = r:CreateFontString(nil, "OVERLAY")
    r.sender:SetJustifyH("RIGHT")
    -- fonts MUST be set before the first SetText ("Font not set" error --
    -- AddEntry writes text before Render runs ApplyRowLayout)
    local size = Cfg("fontSize")
    r.time:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    r.text:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    r.sender:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    -- pinged spell/item icon (populated when the payload is readable)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.icon:Hide()
    rows[i] = r
    return r
end

-- (PingIconFromText removed with the spell-icon feature -- combat-first rule)

-- width read that tolerates a fontstring holding SECRET text (its measured
-- width may itself be secret -- fall back to a sane estimate).
-- UNBOUNDED width: GetStringWidth returns the CURRENT (possibly truncated)
-- width, so once a line was squeezed the fit check believed the lie forever.
local function SafeWidth(fs, fallback)
    local w
    if fs.GetUnboundedStringWidth then w = fs:GetUnboundedStringWidth()
    elseif fs.GetStringWidth then w = fs:GetStringWidth() end
    if w == nil or (issecretvalue and issecretvalue(w)) then return fallback end
    return w
end

-- FREE ROW LAYOUT: every piece (icon / timestamp / sender) anchors to the
-- row's LEFT or RIGHT edge with its own fine x/y offsets (arranged by drag in
-- the options preview); the ping text fills whatever remains between the
-- widest extents of each side.
local function ApplyRowLayout(r)
    local size = Cfg("fontSize")
    local outline = Cfg("fontOutline")
    if outline == "NONE" then outline = "" end
    local font = STANDARD_TEXT_FONT
    -- per-piece font sizes (0/nil = the global Font Size)
    local tsz = Cfg("timeSize");   tsz = (tsz and tsz > 0) and tsz or size
    local ssz = Cfg("senderSize"); ssz = (ssz and ssz > 0) and ssz or size
    local xsz = Cfg("textSize");   xsz = (xsz and xsz > 0) and xsz or size
    r.time:SetFont(font, tsz, outline)
    r.text:SetFont(font, xsz, outline)
    r.sender:SetFont(font, ssz, outline)
    -- text color: per-row state color (readable pings) beats the base color
    local ct = Cfg("colText")
    r.text:SetTextColor(ct[1], ct[2], ct[3])
    local cti = Cfg("colTime")
    r.time:SetTextColor(cti[1], cti[2], cti[3])
    -- sender renders LIVE from the stored readable identity, so option changes
    -- hit rows already on screen. Secret senders keep their raw SetText render.
    if r._senderClean then
        r.sender:SetText(SenderDisplay(r._senderClean))
    end
    -- sender colour is the user's custom colour, full stop. Class colour was
    -- REMOVED (combat-first rule): the sender identity is secret in combat and
    -- CHAT_MSG_PING never carries a usable GUID, so it could only ever have
    -- worked out of combat. See the pings memory before reconsidering.
    local cs = Cfg("colSender")
    r.sender:SetTextColor(cs[1], cs[2], cs[3])

    local showTime, showSender = Cfg("showTimestamp"), Cfg("showSender")
    r.time:SetShown(showTime)
    r.sender:SetShown(showSender)
    -- spell icon removed (combat-first rule: the payload is secret in combat,
    -- so the icon could never show there)
    if r.icon then r.icon:Hide() end

    r.time:ClearAllPoints()
    r.sender:ClearAllPoints()
    r.text:ClearAllPoints()

    -- pieces only PUSH the text while they share its line: a piece dragged
    -- above/below the text's band stops affecting the text's span (the
    -- "callout moves when I lift the sender on top" fix)
    local textBandY = Cfg("textY") or 0
    local band = xsz + 4
    local leftExtent, rightExtent = 0, 0

    -- position the LAYOUT CENTERLINE inside the row: the box shrink-wraps the
    -- pieces, so the line sits (top extent + top padding) below the row's top
    -- edge. The canvas sample pins it to its center instead (stable drag
    -- space; the band overlay shows the real box there). Containment is BY
    -- CONSTRUCTION: the box is derived from the pieces, nothing can be
    -- outside it.
    if r.line then
        local upExt, _downExt = RowExtents()
        local padT = RowPads()
        r.line:ClearAllPoints()
        if r._isSample then
            r.line:SetPoint("LEFT", r, "LEFT", 0, 0)
            r.line:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        else
            r.line:SetPoint("LEFT", r, "TOPLEFT", 0, -(upExt + padT))
            r.line:SetPoint("RIGHT", r, "TOPRIGHT", 0, -(upExt + padT))
        end
    end
    local L = r.line or r

    local P = {
        -- icon entry kept ONLY as an anchor-fallback target (never shown)
        icon   = { el = r.icon,   shown = false,      pos = "left", x = 0, y = 0, w = 0, anchor = "row" },
        time   = { el = r.time,   shown = showTime,   pos = Cfg("timePos"),   x = Cfg("timeX") or 0,   y = Cfg("timeY") or 0,   w = SafeWidth(r.time, 44),  anchor = Cfg("timeAnchorTo") or "row" },
        sender = { el = r.sender, shown = showSender, pos = Cfg("senderPos"), x = Cfg("senderX") or 0, y = Cfg("senderY") or 0, w = SafeWidth(r.sender, 60), anchor = Cfg("senderAnchorTo") or "row" },
    }

    -- resolve each piece's EFFECTIVE row side / extent / absolute Y, following
    -- anchor chains (cycles and hidden targets fall back to free row placement)
    local eff = {}
    local function Resolve(key, visited)
        if eff[key] then return eff[key] end
        local pc = P[key]
        visited = visited or {}
        local a = pc.anchor
        if visited[key] then a = "row" end
        visited[key] = true
        -- only left/right placements push the text span; center/top/bottom
        -- pieces float without squeezing the callout
        local sideExtent = (pc.pos == "left" or pc.pos == "right") and (pc.x + pc.w) or nil
        if a == "row" then
            eff[key] = { mode = "row", side = pc.pos, extent = sideExtent, y = pc.y }
        elseif a == "text" then
            eff[key] = { mode = "text", side = Cfg("textPos") or "left", extent = nil, y = (Cfg("textY") or 0) + pc.y }
        elseif P[a] and P[a].shown then
            local te = Resolve(a, visited)
            local grows = (pc.pos == "left" or pc.pos == "right")
                and ((te.side == "right") and (pc.pos == "left") or (te.side ~= "right") and (pc.pos == "right"))
            local extent = te.extent and (grows and (te.extent + 4 + pc.x + pc.w) or te.extent) or nil
            eff[key] = { mode = "piece", target = P[a].el, side = te.side, extent = extent, y = te.y + pc.y }
        elseif P[a] then
            -- anchor target exists but is HIDDEN: the piece's pos means
            -- "left/right OF the target", NOT a row side -- so the orphan
            -- takes over the TARGET'S spot (its side of the row), it does
            -- not fly to the opposite window edge
            local te = Resolve(a, visited)
            local side = te.side or pc.pos
            local ext = (side == "left" or side == "right") and (pc.x + pc.w) or nil
            eff[key] = { mode = "row", side = side, extent = ext, y = pc.y }
        else
            eff[key] = { mode = "row", side = pc.pos, extent = sideExtent, y = pc.y }
        end
        return eff[key]
    end

    local deferred = {}  -- text-anchored pieces place AFTER the text lays out
    for key, pc in pairs(P) do
        if pc.shown then
            local e = Resolve(key)
            local el = pc.el
            if e.mode == "text" then
                deferred[#deferred + 1] = { pc = pc, e = e }
            elseif e.mode == "row" then
                -- e.side may differ from pc.pos (orphaned-anchor fallback
                -- inherits the hidden target's side) -- place by e.side
                local sidePos = e.side or pc.pos
                if sidePos == "right" then
                    el:SetPoint("RIGHT", L, "RIGHT", -pc.x, pc.y)
                elseif sidePos == "center" then
                    el:SetPoint("CENTER", L, "CENTER", pc.x, pc.y)
                elseif sidePos == "top" then
                    el:SetPoint("TOP", r, "TOP", pc.x, math.min(0, pc.y))
                elseif sidePos == "bottom" then
                    el:SetPoint("BOTTOM", r, "BOTTOM", pc.x, math.max(0, pc.y))
                else
                    el:SetPoint("LEFT", L, "LEFT", pc.x, pc.y)
                end
            else
                -- anchored: sit on the chosen SIDE of the target with a small
                -- base gap; X widens the gap, Y rides relative to the target
                local tel = e.target
                if pc.pos == "right" then
                    el:SetPoint("LEFT", tel, "RIGHT", 4 + pc.x, pc.y)
                elseif pc.pos == "center" then
                    el:SetPoint("CENTER", tel, "CENTER", pc.x, pc.y)
                elseif pc.pos == "top" then
                    el:SetPoint("BOTTOM", tel, "TOP", pc.x, 2 + pc.y)
                elseif pc.pos == "bottom" then
                    el:SetPoint("TOP", tel, "BOTTOM", pc.x, -2 + pc.y)
                else
                    el:SetPoint("RIGHT", tel, "LEFT", -(4 + pc.x), pc.y)
                end
            end
            if el.SetJustifyH and el ~= r.icon then
                local j = (e.mode == "row") and (e.side or pc.pos) or pc.pos
                el:SetJustifyH((j == "right") and "RIGHT" or (j == "left") and "LEFT" or "CENTER")
            end
            -- extent push (same-line band check on the piece's ABSOLUTE y)
            if e.extent and math.abs((e.y or 0) - textBandY) < band then
                if e.side == "right" then
                    if e.extent > rightExtent then rightExtent = e.extent end
                else
                    if e.extent > leftExtent then leftExtent = e.extent end
                end
            end
        end
    end

    -- the text's anchored side (textPos) is user-positioned: its own offset
    -- (textX) wins over the piece extents when it is larger; the far side
    -- keeps the auto inset while the line FITS
    local ty = Cfg("textY") or 0
    local li = leftExtent + ((leftExtent > 0) and 5 or 0)
    local ri = rightExtent + ((rightExtent > 0) and 5 or 0)
    local tx = Cfg("textX") or 0
    local tpos = Cfg("textPos")
    local rightSide = tpos == "right"
    local centerText = tpos == "center"
    if rightSide then
        if tx > ri then ri = tx end
        r.text:SetJustifyH("RIGHT")
    elseif centerText then
        r.text:SetJustifyH("CENTER")
    else
        if tx > li then li = tx end
        r.text:SetJustifyH("LEFT")
    end
    -- TOO-LONG LINES stay INSIDE the box: a line wider than the span is
    -- constrained to the span so the fontstring ellipsizes cleanly ("...")
    -- instead of overflowing into the window edge and getting clipped
    -- mid-letter (the "mkeeper] will be ready" bug). The worst-case preview
    -- exists so users size the width to never hit this.
    local needed = SafeWidth(r.text, nil)
    local avail = (r:GetWidth() or 0) - li - ri
    r._neededW = needed and (li + needed + ri) or nil
    if centerText and not (needed and needed > avail) then
        r.text:SetPoint("CENTER", L, "CENTER", tx, ty)
    else
        r.text:SetPoint("LEFT", L, "LEFT", li, ty)
        r.text:SetPoint("RIGHT", L, "RIGHT", -ri, ty)
    end

    -- pieces anchored TO THE TEXT: the fontstring SPANS the row, so its rect
    -- edge is the window edge -- anchoring there dumped pieces at the far
    -- corner (the "X0 isn't the text's right edge" bug). Place against the
    -- measured GLYPH box instead: "Right of it" + X0 = flush against the
    -- last letter. Secret text is unmeasurable: fall back to the span edge.
    if #deferred > 0 then
        local rowW = r:GetWidth() or 0
        local tw = SafeWidth(r.text, nil)
        local gL, gR
        if tw then
            if rightSide then
                gR = rowW - ri; gL = gR - tw
            elseif centerText then
                local mid = rowW / 2 + tx
                gL, gR = mid - tw / 2, mid + tw / 2
            else
                gL = li; gR = gL + tw
            end
        end
        for _di, d in ipairs(deferred) do
            local pc, e = d.pc, d.e
            local el = pc.el
            local ey = e.y or 0
            if not gL then
                -- SECRET PAYLOAD PATH (in combat / restricted content): the ping
                -- text is unmeasurable, so there is no glyph box to anchor to and
                -- we fall back to the fontstring's own rect. That rect SPANS the
                -- row, so every case has to be handled here -- letting top/bottom/
                -- center drop into the left branch anchored them off the row's
                -- left edge, where SetClipsChildren deleted them. That was the
                -- "sender vanishes the moment I enter combat" bug: the layout was
                -- right out of combat and silently different in it.
                if pc.pos == "right" then
                    el:SetPoint("LEFT", r.text, "RIGHT", 4 + pc.x, pc.y)
                elseif pc.pos == "top" then
                    el:SetPoint("BOTTOM", r.text, "TOP", pc.x, 2 + pc.y)
                elseif pc.pos == "bottom" then
                    el:SetPoint("TOP", r.text, "BOTTOM", pc.x, -2 + pc.y)
                elseif pc.pos == "center" then
                    el:SetPoint("CENTER", r.text, "CENTER", pc.x, pc.y)
                else
                    el:SetPoint("RIGHT", r.text, "LEFT", -(4 + pc.x), pc.y)
                end
            elseif pc.pos == "right" then
                el:SetPoint("LEFT", L, "LEFT", gR + 4 + pc.x, ey)
            elseif pc.pos == "center" then
                el:SetPoint("CENTER", L, "LEFT", (gL + gR) / 2 + pc.x, ey)
            elseif pc.pos == "top" then
                el:SetPoint("BOTTOM", L, "LEFT", (gL + gR) / 2 + pc.x, ty + xsz / 2 + 2 + pc.y)
            elseif pc.pos == "bottom" then
                el:SetPoint("TOP", L, "LEFT", (gL + gR) / 2 + pc.x, ty - xsz / 2 - 2 + pc.y)
            else
                el:SetPoint("RIGHT", L, "LEFT", gL - 4 - pc.x, ey)
            end
        end
    end
end

local function Render()
    if not win then return end
    local width = Cfg("width")
    local rowH  = LayoutRowHeight()
    local top   = Cfg("newestOnTop")
    local n     = #entries
    -- size BEFORE layout: ApplyRowLayout measures the row's width for the
    -- never-truncate check, so it must see the current size
    local function LayoutRows(w)
        local maxNeed = w
        for _i, e in ipairs(entries) do
            local r = e.row
            if r then
                r:SetSize(w - 12, rowH)
                ApplyRowLayout(r)
                if r._neededW and r._neededW + 12 > maxNeed then maxNeed = r._neededW + 12 end
            end
        end
        return maxNeed
    end
    -- FULL TEXT ALWAYS (Arc's guarantee): the configured width is the BASE --
    -- the window is never narrower than it -- but if a line on screen needs
    -- more room, the window widens to fit that line and returns to the base
    -- when it expires. A readable callout is never truncated. (Secret lines
    -- are unmeasurable and render at the base width.)
    local need = LayoutRows(width)
    if need > width then
        width = math.ceil(need)
        LayoutRows(width)
    end
    -- GROW-DIRECTION pinning: the window is anchored by CENTER, so height
    -- changes used to stretch it both ways and shift every row. Preserve the
    -- STABLE edge across the resize instead: newest-on-top keeps the TOP edge
    -- fixed (grows downward), newest-on-bottom keeps the BOTTOM edge fixed
    -- (grows upward) -- same fix in both directions.
    local ux, uy = UICenterForWin(win)
    local wcx = win:GetCenter()
    local edgeY = top and win:GetTop() or win:GetBottom()
    -- CONSTANT padding: the title floats outside the window, so
    -- unlocking/locking can never shift the entries
    local padTop = 6
    -- static box: sized for the MAX entry count, so expiring pings never
    -- shrink the window
    local staticBox = Cfg("staticSize")
    local rowsFor = staticBox and (Cfg("maxEntries") or 8) or math.max(1, n)
    local autoH = rowsFor * (rowH + ROW_PAD) + padTop + 6
    local hBase = tonumber(Cfg("height")) or 0
    win:SetSize(width, (hBase > autoH) and hBase or autoH)
    if wcx and edgeY and ux then
        win:ClearAllPoints()
        if top then
            win:SetPoint("TOP", UIParent, "CENTER", wcx - ux, edgeY - uy)
        else
            win:SetPoint("BOTTOM", UIParent, "CENTER", wcx - ux, edgeY - uy)
        end
        -- keep the saved edges current (migrates old center-only positions)
        local pos = PosStore().pos
        if pos then
            local t, b = win:GetTop(), win:GetBottom()
            if t then pos.top = t - uy end
            if b then pos.bottom = b - uy end
        end
    end
    -- a static box is a permanent HUD element: it stays on screen when empty
    win:SetShown(Cfg("enabled") and (n > 0 or not Cfg("locked") or panelOpen or staticBox))
    -- rows hug the window's stable edge so existing entries never move:
    -- newest-on-top stacks down from the top, newest-on-bottom stacks up
    -- from the bottom (entries[1] is always the newest)
    for i, e in ipairs(entries) do
        local r = e.row
        if r then
            r:ClearAllPoints()
            if top then
                r:SetPoint("TOPLEFT", win, "TOPLEFT", 6, -padTop - (i - 1) * (rowH + ROW_PAD))
            else
                r:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 6, 6 + (i - 1) * (rowH + ROW_PAD))
            end
            r:Show()
        end
    end
end

local EnsureRowAnims  -- fwd (animations section below)

local function FinalizeRemove(token)
    for i, e in ipairs(entries) do
        if e.token == token then
            if e.row then
                e.row:Hide()
                e.row:SetAlpha(1)   -- reset for the next claim
                e.row.free = true
            end
            table.remove(entries, i)
            Render()
            return
        end
    end
end

local function RemoveEntry(token)
    for _i, e in ipairs(entries) do
        if e.token == token then
            local r = e.row
            -- CR-style expiry: fade the row out, then actually remove it
            if r and r:IsShown() and Cfg("animOutStyle") == "fade" then
                EnsureRowAnims(r)
                if not r.fadeOutAG:IsPlaying() then
                    r.fadeOutA:SetDuration(math.max(0.05, tonumber(Cfg("animOutSecs")) or 0.4))
                    r._onFadeOutDone = function() FinalizeRemove(token) end
                    r.fadeOutAG:Play()
                end
            else
                FinalizeRemove(token)
            end
            return
        end
    end
end

local function ClaimRow()
    for i = 1, Cfg("maxEntries") do
        local r = EnsureRow(i)
        if r.free or not r.claimed then
            r.free, r.claimed = false, true
            return r
        end
    end
    local oldest = entries[#entries]
    if oldest then
        local r = oldest.row
        table.remove(entries, #entries)
        return r
    end
    return EnsureRow(1)
end

-- ── animations (Cooldown-Reminder-style kit, on OUR row frames = combat-safe) ─
function EnsureRowAnims(r)
    if r.pulseAG then return end
    -- "pulse": quick scale bounce
    r.pulseAG = r:CreateAnimationGroup()
    local up = r.pulseAG:CreateAnimation("Scale")
    up:SetOrder(1); up:SetScale(1.12, 1.12); up:SetDuration(0.12)
    local down = r.pulseAG:CreateAnimation("Scale")
    down:SetOrder(2); down:SetScale(1 / 1.12, 1 / 1.12); down:SetDuration(0.18)
    r.pulseUp, r.pulseDown = up, down
    -- "flash": alpha bounces (urgent)
    r.flashAG = r:CreateAnimationGroup()
    r.flashSteps = {}
    for i = 1, 2 do
        local dim = r.flashAG:CreateAnimation("Alpha")
        dim:SetOrder(i * 2 - 1); dim:SetFromAlpha(1); dim:SetToAlpha(0.25); dim:SetDuration(0.1)
        local bright = r.flashAG:CreateAnimation("Alpha")
        bright:SetOrder(i * 2); bright:SetFromAlpha(0.25); bright:SetToAlpha(1); bright:SetDuration(0.1)
        r.flashSteps[#r.flashSteps + 1] = dim
        r.flashSteps[#r.flashSteps + 1] = bright
    end
    -- "fade": entrance fade-in (alpha 0 -> 1)
    r.fadeInAG = r:CreateAnimationGroup()
    r.fadeInA = r.fadeInAG:CreateAnimation("Alpha")
    r.fadeInA:SetFromAlpha(0); r.fadeInA:SetToAlpha(1)
    r.fadeInA:SetDuration(0.3); r.fadeInA:SetSmoothing("OUT")
    -- "zoom": CR-style pop-in (0.7 -> 1.15 -> 1.0, fading in over the pop)
    r.zoomAG = r:CreateAnimationGroup()
    local z1 = r.zoomAG:CreateAnimation("Scale")
    z1:SetOrder(1); z1:SetScaleFrom(0.7, 0.7); z1:SetScaleTo(1.15, 1.15)
    z1:SetDuration(0.12); z1:SetSmoothing("OUT")
    local z2 = r.zoomAG:CreateAnimation("Scale")
    z2:SetOrder(2); z2:SetScaleFrom(1.15, 1.15); z2:SetScaleTo(1.0, 1.0)
    z2:SetDuration(0.08); z2:SetSmoothing("IN")
    local zi = r.zoomAG:CreateAnimation("Alpha")
    zi:SetOrder(1); zi:SetFromAlpha(0); zi:SetToAlpha(1); zi:SetDuration(0.12)
    r.zoom1, r.zoom2, r.zoomIn = z1, z2, zi
    -- expiry fade-out -> finalize removal via per-row callback
    r.fadeOutAG = r:CreateAnimationGroup()
    r.fadeOutA = r.fadeOutAG:CreateAnimation("Alpha")
    r.fadeOutA:SetFromAlpha(1); r.fadeOutA:SetToAlpha(0)
    r.fadeOutA:SetDuration(0.4); r.fadeOutA:SetSmoothing("OUT")
    r.fadeOutAG:SetScript("OnFinished", function()
        local cb = r._onFadeOutDone
        r._onFadeOutDone = nil
        if cb then cb() end
    end)
end

local function PlayNewPingAnim(r)
    EnsureRowAnims(r)
    -- a new ping on a row that was mid-expiry must snap back to full life
    r.fadeOutAG:Stop(); r._onFadeOutDone = nil; r:SetAlpha(1)
    local style = Cfg("animStyle")
    if style == "none" then return end
    r.pulseAG:Stop(); r.flashAG:Stop(); r.fadeInAG:Stop(); r.zoomAG:Stop()
    -- entrance duration scales the whole sequence (CR pattern)
    local D = math.max(0.05, tonumber(Cfg("animInSecs")) or 0.3)
    if style == "flash" then
        for _i, a in ipairs(r.flashSteps) do a:SetDuration(D / #r.flashSteps) end
        r.flashAG:Play()
    elseif style == "fade" then
        r.fadeInA:SetDuration(D)
        r.fadeInAG:Play()
    elseif style == "zoom" then
        r.zoom1:SetDuration(D * 0.6)
        r.zoomIn:SetDuration(D * 0.6)
        r.zoom2:SetDuration(D * 0.4)
        r.zoomAG:Play()
    else -- pulse
        r.pulseUp:SetDuration(D * 0.4)
        r.pulseDown:SetDuration(D * 0.6)
        r.pulseAG:Play()
    end
end

-- ── alerts ───────────────────────────────────────────────────────────────────
local lastAlertAt = 0
-- (TTS removed entirely -- Arc's call: keep v1 simple; the alert sound is the
-- audio cue)

local function FireAlerts(text)
    if not Cfg("alertsEnabled") then return end
    local now = GetTime()
    if (now - lastAlertAt) < (Cfg("alertThrottle") or 0) then return end
    lastAlertAt = now
    local f = ResolveSound(Cfg("alertSound"))
    if f then PlaySoundFile(f, "Master") end
end

-- ── sender name ──────────────────────────────────────────────────────────────
-- The sender arrives as a PLAYER HYPERLINK ("|Hplayer:Name-Realm|h[Name]|h"),
-- not a plain name -- extract the name before roster compares.
local function CleanSenderName(sender)
    if sender == nil then return nil end
    if issecretvalue and issecretvalue(sender) then return nil end
    if type(sender) ~= "string" then return nil end
    local n = sender:match("|Hplayer:([^:|%]]+)")
    return n or sender
end

-- the sender piece's display string. Name only -- the class-icon style was
-- REMOVED (combat-first rule: the sender is secret in combat, the icon could
-- never show there).
function SenderDisplay(cleanName)
    return cleanName and (Ambiguate and Ambiguate(cleanName, "short") or cleanName) or ""
end

-- ── entries ──────────────────────────────────────────────────────────────────
-- preview entry: shown in the REAL window while the options panel is open and
-- no actual ping is on screen -- so every option is judged against the real
-- thing, not just the canvas
local function RemovePreviewEntries()
    local removed = false
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.preview then
            if e.row then e.row:Hide(); e.row:SetAlpha(1); e.row.free = true end
            table.remove(entries, i)
            removed = true
        end
    end
    return removed
end

-- NOTE: no ping-type filter. In combat the payload is SECRET, so pings cannot
-- be classified -- a filter would either break there or silently eat cooldown
-- pings. Combat-first rule: the option doesn't ship at all.
local function AddEntry(text, sender, guid, isPreview)
    if not Cfg("enabled") then return end
    -- a real ping replaces the preview immediately
    if not isPreview then RemovePreviewEntries() end
    EnsureWindow()
    entryToken = entryToken + 1
    local token = entryToken
    local r = ClaimRow()

    r.time:SetText(date("%H:%M:%S"))
    -- readable payloads: optional custom template + state color; secret -> raw.
    -- The GUID path can recover the clean name even when the sender string is
    -- secret (in-combat identity secrecy) -- full sender rendering in combat.
    -- (PingLab: guid arg is NIL on current builds -- kept for when it lands.)
    local cleanName = CleanSenderName(sender)
    -- the payload renders exactly as the game sent it: Custom Format was
    -- REMOVED (combat-first) -- rewriting the line needs to READ it, and it is
    -- secret in combat. SetText is a one-way sink, which is why the line still
    -- displays there at all.
    if text ~= nil then r.text:SetText(text) else r.text:SetText("") end
    -- (pinged-spell icon removed -- combat-first rule: the spellID lives
    -- inside the payload, which is secret in combat; no link extractor exists)
    r.icon:Hide()
    -- store the readable identity; ApplyRowLayout renders sender text + color
    -- from it LIVE (style/color changes hit rows already on screen). Secret
    -- senders render raw via SetText here and keep it.
    r._senderClean = cleanName
    if not cleanName then
        if sender ~= nil then r.sender:SetText(sender) else r.sender:SetText("") end
    end

    table.insert(entries, 1, { token = token, row = r, preview = isPreview or nil })
    while #entries > Cfg("maxEntries") do
        local e = table.remove(entries, #entries)
        if e.row then e.row:Hide(); e.row:SetAlpha(1); e.row.free = true end
    end
    Render()
    PlayNewPingAnim(r)
    if isPreview then return end  -- no alerts, no expiry: lives while the panel is open
    FireAlerts(text)

    local life = Cfg("entrySeconds")
    if life and life > 0 then
        C_Timer.After(life, function() RemoveEntry(token) end)
    end
end

-- ── preview callout ─────────────────────────────────────────────────────────
-- The sample line used by the layout canvas and the "Show Test Ping" button.
-- It used to be a hardcoded Lightning Bolt, which is nonsense on twelve of the
-- thirteen classes, so it is built from a spell the player ACTUALLY has.
--
-- Source is the ACTIVE SPEC's own skill line (SpellBookSkillLineInfo.specID is
-- set, isOffSpec is false), which is where a spec's signature abilities live --
-- the general class line is mostly baseline filler. The LAST non-passive entry
-- is preferred because the spellbook is ordered by level learned, so it is
-- usually a real cooldown rather than a filler button, which suits the
-- "will be ready in 0:12" wording.
--
-- Cached per spec: the scan walks the whole book, and the answer only changes
-- when the spec does.
local previewSpellID, previewSpec

local function PreviewSpellID()
    -- GetSpecialization is only a deprecated alias now (Blizzard_Deprecated-
    -- Specialization aliases it to this); call the real one, keep the old as a
    -- fallback in case that shim ever loads first.
    local csi = C_SpecializationInfo
    local spec = (csi and csi.GetSpecialization and csi.GetSpecialization())
              or (GetSpecialization and GetSpecialization()) or 0
    if previewSpellID and previewSpec == spec then return previewSpellID end
    previewSpec = spec

    local sb = C_SpellBook
    if not (sb and sb.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank) then
        previewSpellID = nil
        return nil
    end
    local BANK = Enum.SpellBookSpellBank.Player
    local specPick, anyPick

    for line = 1, (sb.GetNumSpellBookSkillLines() or 0) do
        local info = sb.GetSpellBookSkillLineInfo(line)
        -- offSpecID set = this whole line belongs to a spec the player is not in
        if info and not info.isGuild and not info.offSpecID then
            local first = (info.itemIndexOffset or 0) + 1
            local last  = (info.itemIndexOffset or 0) + (info.numSpellBookItems or 0)
            for slot = first, last do
                local item = sb.GetSpellBookItemInfo(slot, BANK)
                if item and item.spellID and not item.isPassive and not item.isOffSpec then
                    anyPick = item.spellID
                    -- a line carrying a specID IS the active spec's line
                    if info.specID then specPick = item.spellID end
                end
            end
        end
    end

    previewSpellID = specPick or anyPick
    return previewSpellID
end

-- The worst-case (longest) callout form, so the layout is sized against the
-- widest line it will ever have to show.
local function PreviewText(withLink)
    local id = PreviewSpellID()
    if id then
        local link = withLink and C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(id)
        if link then return link .. " will be ready in 0:12!" end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        local name = info and info.name
        if name then
            return ("|cff71d5ff[%s]|r will be ready in 0:12!"):format(name)
        end
    end
    -- no spellbook yet (very early login): a linkless line still previews the
    -- layout correctly, and the next refresh picks up the real spell
    return "|cff71d5ff[Your Cooldown]|r will be ready in 0:12!"
end
local function ShowPreviewEntry()
    RemovePreviewEntries()
    if #entries > 0 then Render(); return end  -- real pings on screen win
    AddEntry(PreviewText(true), UnitName("player"), UnitGUID and UnitGUID("player") or nil, true)
end

-- ── receive + init ───────────────────────────────────────────────────────────
-- Which of the Show In switches covers where the player is standing.
local function CurrentContent()
    local _, instanceType = GetInstanceInfo()
    if instanceType == "party" then
        local cm = C_ChallengeMode
        if cm and cm.IsChallengeModeActive and cm.IsChallengeModeActive() then
            return "showInMythicPlus"
        end
        return "showInDungeon"
    elseif instanceType == "raid" then       return "showInRaid"
    elseif instanceType == "pvp" then        return "showInBattleground"
    elseif instanceType == "arena" then      return "showInArena"
    elseif instanceType == "scenario" then   return "showInScenario"
    end
    return "showInWorld"
end

local function FeedAllowedHere()
    return Cfg(CurrentContent()) ~= false
end

local evFrame = CreateFrame("Frame")
evFrame:SetScript("OnEvent", function(_, _, text, sender, _a3, _a4, _a5, _a6, _a7, _a8, _a9, _a10, _lineID, guid)
    -- arg11 = LINE COUNTER (not a ping type -- it fooled us once; leave it).
    -- arg12 = sender GUID: nil on current builds; kept as the future
    -- combat path to class/name when the sender string is secret.
    AddEntry(text, sender, guid)
end)

-- ── minimap button (no libraries: classic rim-riding button) ────────────────
local mmBtn
local function MMUpdatePos()
    if not mmBtn then return end
    local angle = math.rad(tonumber(Cfg("minimapAngle")) or 220)
    local r = (Minimap:GetWidth() / 2) + 5
    mmBtn:ClearAllPoints()
    mmBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function BuildMinimapButton()
    if mmBtn then return mmBtn end
    mmBtn = CreateFrame("Button", "ArcPingsMinimapButton", Minimap)
    mmBtn:SetSize(31, 31)
    mmBtn:SetFrameStrata("MEDIUM")
    mmBtn:SetFrameLevel(8)
    mmBtn:RegisterForClicks("LeftButtonUp")
    mmBtn:RegisterForDrag("LeftButton")
    mmBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local overlay = mmBtn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")
    -- the TrackingBorder ring is OFFSET inside its 53px texture -- background
    -- and icon must use the LibDBIcon geometry to sit inside its circle
    local bg = mmBtn:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = mmBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(19, 19)
    -- the addon's own mark, pre-masked to a circle: the minimap button is round,
    -- so the square logo's corners would only get clipped. No SetTexCoord for
    -- the same reason -- the art is already framed for this size.
    icon:SetTexture("Interface\\AddOns\\ArcPings\\Media\\Minimap")
    icon:SetPoint("TOPLEFT", 6, -5)
    mmBtn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            ScopedStore().minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            MMUpdatePos()
        end)
    end)
    mmBtn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    mmBtn:SetScript("OnClick", function() _G.ArcPings_ToggleOptions() end)
    mmBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff3fc9f2Arc|r|cffd5e2f2 Pings|r")
        GameTooltip:AddLine("Click: options.  Drag: move this button.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    mmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    MMUpdatePos()
    return mmBtn
end

ApplyAll = function()
    if mmBtn then
        mmBtn:SetShown(Cfg("showMinimap") ~= false)
        MMUpdatePos()
    end
    -- the feed is OFF here if this content type is switched off: stop
    -- listening as well as hiding, so nothing queues up behind the scenes
    local live = Cfg("enabled") and HAS_ACTION_PINGS and FeedAllowedHere()
    if live then
        evFrame:RegisterEvent("CHAT_MSG_PING")
        WarnIfBlizzSettingsOff()
    else
        evFrame:UnregisterAllEvents()
    end
    if live then
        local w = EnsureWindow()
        local pos = PosStore().pos
        -- SCALE WITHOUT DRIFT: the saved offsets are in WINDOW units, so a
        -- scale change multiplies the window's distance from screen center
        -- (it slid toward a corner). Re-express the stored offsets in the new
        -- scale first -- the window then stays exactly where it is on screen.
        local newScale = tonumber(Cfg("windowScale")) or 1
        if newScale <= 0 then newScale = 1 end
        local oldScale = w._appliedScale or newScale
        if pos and oldScale ~= newScale then
            local f = oldScale / newScale
            pos[1] = (pos[1] or 0) * f
            pos[2] = (pos[2] or 0) * f
            if pos.top then pos.top = pos.top * f end
            if pos.bottom then pos.bottom = pos.bottom * f end
        end
        w._appliedScale = newScale
        w:SetScale(newScale)
        w:ClearAllPoints()
        -- anchor by the STABLE edge for the grow direction; the center form
        -- is only a legacy/first-run fallback (Render converts it to an edge)
        if pos and Cfg("newestOnTop") and pos.top then
            w:SetPoint("TOP", UIParent, "CENTER", pos[1], pos.top)
        elseif pos and not Cfg("newestOnTop") and pos.bottom then
            w:SetPoint("BOTTOM", UIParent, "CENTER", pos[1], pos.bottom)
        elseif pos then
            w:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
        else
            -- first-run default: center-top of the screen
            w:SetPoint("TOP", UIParent, "TOP", 0, -100)
        end
        w:EnableMouse(CanDrag())
        w:SetFrameStrata(Cfg("strata"))
        -- chromeless by default: bg/border only when opted in; the cyan
        -- hairline always shows while unlocked (placement aid)
        local cbg = Cfg("colBg")
        w:SetBackdropColor(cbg[1], cbg[2], cbg[3], Cfg("showBackground") and Cfg("bgAlpha") or 0)
        -- border lives on the overlay (above rows -- content can't cover it)
        w:SetBackdropBorderColor(0, 0, 0, 0)
        -- border: the cyan hairline only while unlocked (drag aid). Locked =
        -- purely the user's choice -- panel-open never forces a border on,
        -- and the user's Border Color always wins when Show Border is on.
        if not Cfg("locked") then
            w.edge:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
        elseif Cfg("showBorder") then
            local cbo = Cfg("colBorder")
            w.edge:SetBackdropBorderColor(cbo[1], cbo[2], cbo[3], 1)
        else
            w.edge:SetBackdropBorderColor(0, 0, 0, 0)
        end
        -- title: floats above the window while unlocked or the panel is open
        w._titleWanted = (not Cfg("locked") or panelOpen) and Cfg("showTitle") ~= false
        w.titleHolder:SetFrameStrata(Cfg("strata"))
        w.titleHolder:SetScale(newScale)
        w.titleHolder:SetShown(w._titleWanted and w:IsShown())
        Render()
    elseif win then
        win:Hide()
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SETTINGS PANEL (Blizzard Settings API — no libraries)
-- ═══════════════════════════════════════════════════════════════════════════

local settingsCategory

local PKApply  -- fwd: Ping Keys re-arm (defined below; nil until then)

local function SetCfg(key, val)
    if PK_CHAR_ONLY[key] then
        CharDB()[key] = val
    else
        -- Editing in a narrower scope CAPTURES the setting: from here on this
        -- char/spec keeps its own value and stops following the account one.
        -- Clearing the patch puts it back on the leash.
        ScopedStore()[key] = val
    end
    ApplyAll()
    if PKApply then PKApply() end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PING KEYS — hold your ping key, press a tracked spell's OWN keybind, and
-- that key pings the spell instead of casting it.
--
-- /pingspell is a SECURE slash command (Blizzard registers it through
-- CheckAddSecureSlashCommand), so it only fires from a SecureActionButton's
-- macrotext. RunMacroText from ordinary addon Lua does nothing at all.
--
-- COMBAT-FIRST (the hard rule): the binding swap has to happen the instant the
-- ping key goes down, which is mid-fight. SetOverrideBindingClick and
-- SetAttribute are both blocked there, so the swap runs INSIDE a secure
-- snippet, where HANDLE:SetBindingClick / HANDLE:ClearBindings are legal. Every
-- Lua-side write (relay macrotext, the attribute list the snippet reads, the
-- ping key's own override binding) happens OUT of combat only, and any edit
-- made mid-fight is deferred to PLAYER_REGEN_ENABLED.
--
-- Binding ownership is split on purpose: pkBindOwner owns the ping key's
-- override binding (written from Lua), the handler owns the swapped spell
-- bindings (written from the snippet). One frame owning both would have the
-- Lua-side ClearOverrideBindings and the snippet-side ClearBindings fighting
-- over the same list.
-- ═══════════════════════════════════════════════════════════════════════════

local PK_MAX = 12   -- tracked spells (also the relay-button pool size)

-- the ceilings share one table to stay clear of Lua's 200-local cap
local PK_LIMIT = {
    ALL   = 60,    -- relays for "any spell" mode (5 bars of 12)
    MACRO = 120,   -- Constants.MacroConsts.MAX_ACCOUNT_MACROS
    CAT   = 60,    -- catalog grid cap; the count line says when it truncates
}

local pkBindOwner, pkAlwaysOwner
local pkRelays = {}
local pkDirty  = false

-- fwd: defined in the SELECT MODE block below, needed by PKApply above it
local PKCollectButtons, PKButtonSubject, PKSubjectInfo, PKPingLine
-- forward: PKEntryMatchesBar (above the definition) resolves it at call time
local PKLiveSpellID

local function PKList()
    local db = DB()
    if type(db.pkSpells) ~= "table" then db.pkSpells = {} end
    return db.pkSpells
end

-- Blizzard's action buttons carry `bindingAction` (set in ActionButton.lua), so
-- read the LIVE frames rather than hardcoding a slot->command table: paging and
-- bar layout stay Blizzard's problem. Third-party bars (ElvUI, Bartender) name
-- their buttons differently and simply won't resolve -- that is what the manual
-- per-spell key override is for.
local PK_BARS = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button",
    "MultiBar6Button", "MultiBar7Button",
}

local function PKAutoKey(spellID)
    for _b = 1, #PK_BARS do
        for i = 1, 12 do
            local btn = _G[PK_BARS[_b] .. i]
            local slot = btn and btn.action
            if slot and HasAction(slot) then
                local aType, id = GetActionInfo(slot)
                local sid
                if aType == "spell" then
                    sid = id
                elseif aType == "macro" then
                    sid = GetMacroSpell(id)
                end
                if sid == spellID then
                    local cmd = btn.bindingAction or btn.commandName
                    local k = cmd and GetBindingKey(cmd)
                    if k then return k end
                end
            end
        end
    end
    return nil
end

-- the key a tracked entry actually answers to, best source first:
--   1. a manual override the user typed
--   2. the BINDING COMMAND captured when they picked the spell off a bar --
--      resolved live, so rebinding the key updates us for free, and it works
--      for ElvUI/Bartender buttons that PKAutoKey's name scan cannot see
--   3. a fresh scan of Blizzard's bars (entries added by spell ID)
-- The BAR key this entry lives on. Note there is deliberately no override here
-- any more: the per-spell override is a PING key (which modifier key activates
-- this spell), not a spell key. Overriding the spell key silently disconnected
-- the real bar key, which is the bug Arc hit.
-- Set by the options panel once it is built. The auto holder calls it when the
-- toggle key flips Auto-Ping, so the checkbox tracks the key press.

-- A flip of Auto-Ping is a deliberate act mid-fight, so it needs to be visible
-- without opening the options. UIErrorsFrame is the standard spot for a status
-- flash and it works in combat.
local function PKAutoNotify(on)
    local msg = on and "Auto-Ping ON" or "Auto-Ping OFF"
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        if on then UIErrorsFrame:AddMessage("|cff33ff99Arc Pings:|r " .. msg, 0.2, 1.0, 0.6, 1, 3)
        else        UIErrorsFrame:AddMessage("|cffff5555Arc Pings:|r " .. msg, 1.0, 0.35, 0.35, 1, 3) end
    end
    if PlaySound and SOUNDKIT then
        PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
    end
end

-- ── SPEC / BAR-CONTENT GUARD ────────────────────────────────────────────────
-- A binding command SURVIVES a spec change; the spell in its slot does not.
-- Pick Doom Winds on Enhancement (some bar button = G), switch to Resto, and
-- GetBindingKey still hands back G, but that slot now holds something else.
-- Arming anyway overrides G with a relay that casts DOOM WINDS, so the player
-- cannot cast what is actually on their bar and gets a ping for a spell they do
-- not have. Always-mode is the damaging one: it binds unconditionally.
--
-- Compared through PKLiveSpellID so an override pair (base captured, override
-- live or vice versa) is not a false negative. Entries with no source button
-- (Add-By-ID) have nothing to verify and are allowed through.
local function PKEntryMatchesBar(entry)
    if not entry then return false end
    local btn = entry.btn and _G[entry.btn]
    if not btn then return true end
    local sid = PKButtonSubject(btn)
    if not sid then return false end            -- slot emptied in this spec
    if sid == entry.id then return true end
    if entry.kind == "item" then return false end
    return PKLiveSpellID(sid) == PKLiveSpellID(entry.id)
end

local function PKKeyFor(entry)
    if entry.cmd then
        local k = GetBindingKey(entry.cmd)
        if k then return k end
    end
    return PKAutoKey(entry.id)
end

-- Which ping key activates this entry: its own override, else the global one.
local function PKPingKeyFor(entry)
    local k = entry and entry.pingKey
    if k and k ~= "" then return k end
    local g = Cfg("pkKey")
    return (g and g ~= "") and g or nil
end

-- "Ping every Nth press". A TIME-based throttle is impossible: the restricted
-- environment has no clock, and Lua cannot write a secure button's attributes in
-- combat. Counting, though, is just arithmetic, which is legal anywhere.
--
-- This pre-click snippet runs BEFORE the button's own OnClick, so it picks which
-- of two pre-baked macrotexts that same click will run:
--   pkFull     = cast + ping
--   pkCastOnly = cast, no ping
-- The cast line is in BOTH, so a suppressed ping can never eat a keypress.
--
-- Honest limit, by construction: this counts PRESSES, not seconds. The counter
-- does not decay, so with N=2 it is always the even-numbered press that pings,
-- however far apart they are. No timeout is possible -- see the long note in
-- ArcUI's Pings module for the four dead ends, all tested in-game.
--
-- HANDS OFF unless this relay is a gated always-relay. Relays are POOLED, so a
-- hold-mode relay (macrotext = ping line only, no pkFull) shares the pool, and
-- overwriting its macrotext here would silently kill the ping.
local PK_PRESS_GATE = [=[
    local full = self:GetAttribute("pkFull")
    if not full then return end
    local castOnly = self:GetAttribute("pkCastOnly") or full

    local every = self:GetAttribute("pkEvery") or 1
    if every <= 1 then
        self:SetAttribute("macrotext", full)
        return
    end
    local n = (self:GetAttribute("pkPress") or 0) + 1
    if n >= every then n = 0 end
    self:SetAttribute("pkPress", n)
    -- n wrapped back to 0 on THIS press => this is the Nth => ping
    if n == 0 then
        self:SetAttribute("macrotext", full)
    else
        self:SetAttribute("macrotext", castOnly)
    end
]=]

local pkGateHeader

-- relays live 1px offscreen and SHOWN on purpose: a binding click is delivered
-- to the button regardless, but a shown button is the pattern every secure
-- relay addon uses and costs nothing
local function PKRelay(i)
    local r = pkRelays[i]
    if not r then
        r = CreateFrame("Button", "ArcPingsPingRelay" .. i, UIParent, "SecureActionButtonTemplate")
        r:SetSize(1, 1)
        r:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
        r:RegisterForClicks("AnyDown")
        r:SetAttribute("type", "macro")
        r:SetAttribute("macrotext", "")
        -- the wrap needs an explicitly-protected header frame to run against
        if not pkGateHeader then
            pkGateHeader = CreateFrame("Frame", "ArcPingsGateHeader", UIParent,
                "SecureHandlerBaseTemplate")
        end
        SecureHandlerWrapScript(r, "OnClick", pkGateHeader, PK_PRESS_GATE)
        pkRelays[i] = r
    end
    -- Pooled: wipe the previous owner's gate data on every claim. Without this a
    -- hold-mode entry reusing an always-mode slot would inherit its pkFull and
    -- ping the wrong spell.
    r:SetAttribute("pkFull", nil)
    r:SetAttribute("pkCastOnly", nil)
    r:SetAttribute("pkEvery", 1)
    r:SetAttribute("pkPress", 0)
    return r
end

-- runs in the RESTRICTED environment, so it is legal in combat. It reads the
-- key/relay pairs off its own attributes because a snippet cannot see addon
-- Lua tables.
--
-- The PAGE GUARD is what keeps "Any Spell" mode honest. Relay macrotext is
-- baked from what each button held at bake time, and baking needs Lua, which is
-- locked in combat. If your bar pages mid-fight (druid forms, warrior stances,
-- vehicles) the baked text is stale, so rather than ping the WRONG spell the
-- snippet refuses to bind anything until the bar returns to the baked state or
-- combat ends. Correct or silent, never wrong.
local PK_SNIPPET = [=[
    if down then
        if self:GetAttribute("pkGuard") then
            local baked = self:GetAttribute("pkBakedState")
            local live  = self:GetAttribute("pkLiveState")
            if baked and live and baked ~= live then return end
        end
        local n = self:GetAttribute("pkCount") or 0
        for i = 1, n do
            local k = self:GetAttribute("pkKey" .. i)
            local r = self:GetAttribute("pkRelay" .. i)
            if k and r then
                self:SetBindingClick(true, k, r)
            end
        end
    else
        self:ClearBindings()
    end
]=]

-- the bar state the relays were baked against; any change invalidates them
local PK_STATE_DRIVER =
    "[overridebar]o;[vehicleui]v;[possessbar]p;[shapeshift]s;"
    .. "[bar:2]2;[bar:3]3;[bar:4]4;[bar:5]5;[bar:6]6;1"
local PK_STATE_SNIPPET = [=[ self:SetAttribute("pkLiveState", newstate) ]=]

-- HOLDER POOL, one per distinct ping key. Spells can each nominate their own
-- ping key, so several may be live at once; each holder owns only the spells
-- assigned to its key, and its snippet binds only those.
local pkHolders, pkHolderN = {}, 0

local function PKHolder(pingKey)
    local h = pkHolders[pingKey]
    if h then return h end
    pkHolderN = pkHolderN + 1
    -- _onclick needs ClickTemplate and _onstate-* needs StateTemplate. With
    -- Click alone the page-guard snippet never ran, so pkLiveState never
    -- updated and the guard was dead weight.
    h = CreateFrame("Button", "ArcPingsPingKeyHolder" .. pkHolderN, UIParent,
        "SecureHandlerClickTemplate,SecureHandlerStateTemplate")
    h:SetSize(1, 1)
    h:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
    h:RegisterForClicks("AnyDown", "AnyUp")
    h:SetAttribute("_onclick", PK_SNIPPET)
    h:SetAttribute("_onstate-pkpage", PK_STATE_SNIPPET)
    RegisterStateDriver(h, "pkpage", PK_STATE_DRIVER)
    pkHolders[pingKey] = h
    return h
end

-- Referenced by PKApply but never defined here: the standalone was ported from
-- ArcUI's module, where it also has to stand down for the standalone addon.
-- There is no such rival here, so it is purely "does this client have pings".
local function PKUsable() return HAS_ACTION_PINGS end

local function PKEnsureOwners()
    pkBindOwner   = pkBindOwner   or CreateFrame("Frame")
    pkAlwaysOwner = pkAlwaysOwner or CreateFrame("Frame")
end

-- the current bar state, read the same way the state driver reports it
local function PKBarState()
    if HasOverrideActionBar and HasOverrideActionBar() then return "o" end
    if UnitHasVehicleUI and UnitHasVehicleUI("player") then return "v" end
    if IsPossessBarVisible and IsPossessBarVisible() then return "p" end
    local form = GetShapeshiftForm and GetShapeshiftForm()
    if form and form > 0 then return "s" end
    local page = GetActionBarPage and GetActionBarPage() or 1
    return tostring(page)
end

-- how many tracked spells currently resolve to a key (options panel status)
-- entries that would actually arm right now. Always mode needs the source
-- BUTTON too (its relay /clicks it to reproduce the cast), so an entry added by
-- spell ID counts in hold mode but not in always mode -- the status line has to
-- reflect that or it promises something that never fires.
-- An entry stays in the list while DISABLED so its key override and mode
-- survive being toggled off -- that is what separates "Enable Ping" (temporary)
-- from "Remove" (permanent). enabled == nil means enabled: entries created
-- before the flag existed keep working.
local function PKEntryOn(e) return e and e.enabled ~= false end

-- Each mode needs a different key to exist, so the check is mode-aware.
-- (PKEntryMode is defined further down, so the modes are read directly here.)
local function PKEntryArms(e)
    if not (e and e.id and PKEntryOn(e)) then return false end
    if e.mode == "own" then
        -- own key mode needs only its dedicated key; no bar key, no ping key
        return e.ownKey ~= nil and e.ownKey ~= ""
    end
    -- the other two ride the spell's action bar key
    if not PKKeyFor(e) then return false end
    if e.mode == "always" then return true end
    -- hold mode also needs a ping key to hold (its own, or the global one)
    return PKPingKeyFor(e) ~= nil
end

local function PKResolvedCount()
    local list, n = PKList(), 0
    for i = 1, #list do
        if PKEntryArms(list[i]) then n = n + 1 end
    end
    return n
end

-- how many entries are armed right now, and why not (options status line)
local pkArmed, pkSkipped = 0, 0

-- an entry's own mode: "key" (ping key + its key) or "always" (pings on every
-- press, no modifier). Per-entry, so one spell can always announce itself while
-- the rest stay behind the ping key.
local function PKEntryMode(e)
    if e.mode == "always" then return "always" end
    if e.mode == "own" then return "own" end
    return "key"
end

-- What an Always relay has to run to reproduce the user's own cast.
--
-- /click <button> is right for a button holding a SPELL or an ITEM: it keeps
-- paging, override spells and range/target handling as Blizzard's own button
-- does them. It is WRONG for a button holding a MACRO, because WoW refuses to
-- run a macro from inside another macro -- the /click silently did nothing and
-- only the ping fired, which is exactly the "it pings but never casts" report.
-- For those we inline the macro's OWN body instead, read fresh at bake time so
-- edits to the macro are picked up without re-selecting it.
-- Find a macro's INDEX from its name.
--
-- 12.1 gotcha, confirmed from a live dump: for a macro action slot
-- GetActionInfo returns ("macro", <RESOLVED SPELL ID>, "spell") -- the second
-- return is NOT the macro index the way it reads for other action types. So the
-- index has to be recovered from the macro's NAME, which GetActionText gives us.
-- GetMacroIndexByName has no references left in Blizzard's 12.1 code, so it is
-- tried first but never depended on: the fallback scans the two index ranges
-- (account macros 1..120, character macros 121..150) by name.
-- NAME IS NOT UNIQUE. An account macro and a character macro can share a name
-- (a live dump had "Pve" as both a Demon Hunter Sigil macro at index 59 and the
-- Shaman's own Wind Shear macro), and neither GetMacroIndexByName nor a plain
-- name scan can tell them apart -- both just return whichever comes first, so
-- the relay ran a different class's macro.
--
-- So disambiguate against the SLOT: among every macro sharing the name, prefer
-- the one whose resolved spell matches the slot's, then the one whose icon
-- matches, and only then fall back to first-by-name.
local function PKMacroIndexForSlot(slot)
    if type(slot) ~= "number" then return nil end
    local name = GetActionText and GetActionText(slot)
    if not name or name == "" then return nil end
    if not (GetNumMacros and GetMacroInfo) then return nil end
    local _t, wantSpell = GetActionInfo(slot)
    local wantTex = GetActionTexture and GetActionTexture(slot)
    local acct, char = GetNumMacros()
    local byName, bySpell, byTex
    local function scan(from, to)
        for i = from, to do
            local n, tex = GetMacroInfo(i)
            if n == name then
                byName = byName or i
                if wantSpell and GetMacroSpell and GetMacroSpell(i) == wantSpell then
                    bySpell = bySpell or i
                end
                if wantTex and tex == wantTex then byTex = byTex or i end
            end
        end
    end
    scan(1, acct or 0)
    scan(PK_LIMIT.MACRO + 1, PK_LIMIT.MACRO + (char or 0))
    return bySpell or byTex or byName
end

-- Talent overrides swap what a bar key really casts (Doom Winds <-> Ascendance),
-- and the swap happens long after we baked the macrotext. An entry captured
-- while the override was up stores the OVERRIDE spell, so "/cast Ascendance"
-- casts nothing once the talent is dropped -- the key pings but refuses to fire.
--
-- Casting the BASE spell fixes it in both directions: WoW routes /cast <base>
-- to whichever spell currently overrides it, so one line stays correct through
-- the swap and never needs rewriting. That matters because rewriting a secure
-- macrotext in combat is impossible -- this way there is nothing to rewrite.
--
-- Returns nil when the entry already IS the base, so the caller keeps its own
-- name and nothing changes for the overwhelmingly common case.
local function PKBaseSpellName(id)
    if type(id) ~= "number" then return nil end
    if not (C_Spell and C_Spell.GetBaseSpell) then return nil end
    local base = C_Spell.GetBaseSpell(id)
    if type(base) ~= "number" or base <= 0 or base == id then return nil end
    local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(base)
    return info and info.name or nil
end

local function PKCastLines(e)
    -- MACRO buttons: inline the macro's own body. A macro cannot /click another
    -- macro (WoW blocks nested macro execution), and the body preserves every
    -- conditional the user wrote.
    local btn = e.btn and _G[e.btn]
    if btn then
        local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
        if type(slot) == "number" and HasAction(slot) then
            local aType = GetActionInfo(slot)
            if aType == "macro" then
                local idx = PKMacroIndexForSlot(slot)
                if idx and GetMacroInfo then
                    local _n, _t, body = GetMacroInfo(idx)
                    if type(body) == "string" and body ~= "" then
                        return (body:gsub("%s+$", ""))
                    end
                end
            end
        end
    end
    -- Everything else casts BY NAME rather than /click-ing the source button.
    --
    -- /click looked right (it inherits paging, overrides and targeting) but is
    -- broken under modifiers: ActionButton's OnClick early-returns when
    -- IsModifiedClick("PICKUPACTION") -- SHIFT by default -- so with bars locked
    -- a shift-bound spell did nothing, and with bars unlocked it picked the
    -- spell up off the bar instead. That is why SHIFT-bound spells pinged but
    -- never cast.
    --
    -- Casting by name sidesteps the button entirely, and it means an entry no
    -- longer needs a source button at all: an Add-By-ID spell with a Key
    -- Override can now use Every Cast too.
    local nm = PKSubjectInfo(e)
    if not nm or nm == "" then return nil end
    if e.kind == "item" then return "/use " .. nm end
    -- base name, not the stored one -- see PKBaseSpellName above
    return "/cast " .. (PKBaseSpellName(e.id) or nm)
end

-- ── AUTO-PING TOGGLE ───────────────────────────────────────────────────────
-- "Every time I cast it" spells are handy in M+ and noise in a raid, so the
-- whole always-mode layer can be switched off with one key, mid-fight.
--
-- That forces a design point: the always bindings must be owned by a SNIPPET,
-- not by Lua. Lua cannot ClearOverrideBindings in combat, and a snippet's
-- ClearBindings only clears what the HANDLE owns -- mixing the two would leave
-- half the bindings live. So every always binding is applied inside
-- pkAutoApply, and both entry points run that same snippet:
--   * out of combat, Lua sets the attributes then Hide()/Show() -> _onshow
--   * in combat, the toggle key's _onclick flips the flag -> RunAttribute
local PK_AUTO_APPLY = [=[
    self:ClearBindings()
    if not self:GetAttribute("pkAutoOn") then return end
    local n = self:GetAttribute("pkAutoCount") or 0
    for i = 1, n do
        local k = self:GetAttribute("pkAutoKey" .. i)
        local r = self:GetAttribute("pkAutoRelay" .. i)
        if k and r then
            self:SetBindingClick(true, k, r)
        end
    end
]=]

local PK_AUTO_TOGGLE = [=[
    if down then
        self:SetAttribute("pkAutoOn", not self:GetAttribute("pkAutoOn"))
        self:RunAttribute("pkAutoApply")
    end
]=]

local pkAutoHolder

local function PKAutoHolder()
    if pkAutoHolder then return pkAutoHolder end
    pkAutoHolder = CreateFrame("Button", "ArcPingsAutoHolder", UIParent,
        -- BOTH templates: ClickTemplate wires _onclick (the toggle key), but
        -- _onshow is ONLY honoured by ShowHideTemplate. With Click alone the
        -- apply snippet never ran and no always-mode spell ever bound.
        "SecureHandlerClickTemplate,SecureHandlerShowHideTemplate")
    pkAutoHolder:SetSize(1, 1)
    pkAutoHolder:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -1000, 1000)
    pkAutoHolder:RegisterForClicks("AnyDown")
    pkAutoHolder:SetAttribute("pkAutoApply", PK_AUTO_APPLY)
    pkAutoHolder:SetAttribute("_onclick", PK_AUTO_TOGGLE)
    pkAutoHolder:SetAttribute("_onshow", "self:RunAttribute('pkAutoApply')")

    -- THE SNIPPET FLIPS THIS ATTRIBUTE AND LUA HAS TO HEAR ABOUT IT.
    -- Syncing only on PLAYER_REGEN_ENABLED meant an out-of-combat press was
    -- never stored, and the next PKApply (spec change, rebind, bar edit) pushed
    -- the stale value straight back over it: "auto-ping turns itself off", and
    -- it silences every always-mode spell when it happens.
    --
    -- OnAttributeChanged fires for snippet writes too, in and out of combat.
    -- Writing a Lua table is not a protected action, so this is combat-safe.
    pkAutoHolder:SetScript("OnAttributeChanged", function(_self, name, value)
        if name ~= "pkautoon" then return end   -- names arrive lowercased
        local on = value and true or false
        if (Cfg("pkAutoOn") ~= false) == on then return end
        CharDB().pkAutoOn = on
        PKAutoNotify(on)
        if PKPanelRefresh then PKPanelRefresh() end
    end)
    return pkAutoHolder
end

-- Is auto-ping currently live? Read from the holder when it exists, because the
-- toggle key can have flipped it in combat without Lua ever hearing about it.
local function PKAutoOn()
    if pkAutoHolder then
        return pkAutoHolder:GetAttribute("pkAutoOn") and true or false
    end
    return Cfg("pkAutoOn") ~= false
end

-- Always entries: the entry's own key is rebound to a relay that reproduces the
-- cast and then pings. Fully static -- written once out of combat. No source
-- button needed since the cast goes by name, so an Add-By-ID entry with a Key
-- Override works here too.
local function PKArmAlways(e, slotIndex, autoN)
    local k = PKKeyFor(e)
    local cast = PKCastLines(e)
    if not (k and cast) then return false end
    -- Never override a bar key that no longer holds this spell. This is the
    -- mode that would otherwise BLOCK the cast entirely.
    if not PKEntryMatchesBar(e) then return false end
    -- ping LAST so a macro's own /stopmacro still suppresses the callout
    local r = PKRelay(slotIndex)
    local full = cast .. "\n" .. PKPingLine(e)
    r:SetAttribute("macrotext", full)

    -- both forms baked here, out of combat; the press gate picks between them
    -- per click. pkEvery = 1 leaves the snippet a no-op.
    r:SetAttribute("pkFull", full)
    r:SetAttribute("pkCastOnly", cast)
    r:SetAttribute("pkEvery", tonumber(e.every) or 1)
    r:SetAttribute("pkPress", 0)

    -- recorded on the auto holder rather than bound here: the toggle key has to
    -- be able to drop and restore these in combat, which only a snippet can do
    local h = PKAutoHolder()
    h:SetAttribute("pkAutoKey" .. autoN, k)
    h:SetAttribute("pkAutoRelay" .. autoN, r:GetName())
    return true
end

-- Key entries: the ping key arms the swap and the snippet binds in combat.
local function PKArmKey(h, e, slotIndex, n)
    local k = PKKeyFor(e)
    if not k then return false end
    -- hold mode does not block the cast, but on the wrong spec it would
    -- announce a spell the player does not have. Same guard.
    if not PKEntryMatchesBar(e) then return false end
    local r = PKRelay(slotIndex)
    r:SetAttribute("macrotext", PKPingLine(e))
    h:SetAttribute("pkKey" .. n, k)
    h:SetAttribute("pkRelay" .. n, r:GetName())
    return true
end

-- "Any spell": every key on your bars pings whatever it holds. Baked from live
-- bar contents, so this is the one path that needs the stale-page guard.
local function PKArmAnySpell(h)
    local btns = PKCollectButtons()
    local seen, n = {}, 0
    for i = 1, #btns do
        if n >= PK_LIMIT.ALL then break end
        local sid, cmd, kind = PKButtonSubject(btns[i])
        local k = cmd and GetBindingKey(cmd)
        -- one relay per KEY, not per button: two buttons sharing a key would
        -- otherwise fight over the same binding
        if sid and k and not seen[k] then
            seen[k] = true
            n = n + 1
            -- offset past the picked-list relays: both pools were using 1..12
            local r = PKRelay(PK_MAX + n)
            r:SetAttribute("macrotext", PKPingLine({ id = sid, kind = kind }))
            h:SetAttribute("pkKey" .. n, k)
            h:SetAttribute("pkRelay" .. n, r:GetName())
        end
    end
    return n
end

-- Own-key entries: one dedicated key that PINGS ONLY. No ping key to hold, no
-- bar key involved, and nothing is cast -- this is the "tell the group it is on
-- cooldown, after the fact" case that neither other mode can express.
local function PKArmOwn(e, slotIndex)
    local k = e.ownKey
    if not k or k == "" then return false end
    local r = PKRelay(slotIndex)
    r:SetAttribute("macrotext", PKPingLine(e))
    SetOverrideBindingClick(pkAlwaysOwner, true, k, r:GetName())
    return true
end

PKApply = function()
    -- never write bindings or attributes in combat; re-arm on regen instead
    if InCombatLockdown() then pkDirty = true; return end
    pkDirty = false
    PKEnsureOwners()
    ClearOverrideBindings(pkBindOwner)
    ClearOverrideBindings(pkAlwaysOwner)
    -- every holder resets: a ping key can stop being used entirely when the last
    -- spell on it changes mode, and a stale holder would keep answering
    for _k, h in pairs(pkHolders) do
        h:SetAttribute("pkCount", 0)
        h:SetAttribute("pkGuard", false)
    end
    pkArmed, pkSkipped = 0, 0
    if not (Cfg("pkEnabled") and PKUsable()) then return end

    local barState = PKBarState()
    local globalKey = Cfg("pkKey")
    -- DEFAULT IS "EVERY SPELL". Holding the ping key over any bound spell pings
    -- it; the picked list is for spells that want something DIFFERENT (their own
    -- ping key, auto-ping on cast, or a ping-only key). "Only Selected Spells"
    -- narrows the ping key to the list instead.
    --
    -- These two layers COEXIST -- the old early-return meant turning on any-spell
    -- silently killed every always-mode and own-key entry.
    local onlySel = Cfg("pkOnlySelected") == true
    local perKeyN = {}    -- pingKey -> how many spells are on that holder

    if not onlySel and globalKey and globalKey ~= "" then
        local h = PKHolder(globalKey)
        -- only this layer bakes from live bar contents, so only it needs the
        -- stale-page guard. It covers the whole holder, so a paged bar pauses
        -- that key's per-spell entries too -- conservative, never wrong.
        h:SetAttribute("pkGuard", true)
        local n = PKArmAnySpell(h)
        perKeyN[globalKey] = n
        pkArmed = n
    end

    -- The picked list, each entry by its OWN mode. Runs regardless of the layer
    -- above, and its hold entries are appended AFTER the any-spell ones on the
    -- same holder so the later SetBindingClick wins for that key.
    local list = PKList()
    local slot, autoN = 0, 0
    for i = 1, #list do
        local e = list[i]
        if e and e.id and PKEntryOn(e) and slot < PK_MAX then
            slot = slot + 1
            local mode, ok = PKEntryMode(e), nil
            if mode == "always" then
                autoN = autoN + 1
                ok = PKArmAlways(e, slot, autoN)
                if not ok then autoN = autoN - 1 end
            elseif mode == "own" then
                ok = PKArmOwn(e, slot)
            else
                local pk = PKPingKeyFor(e)
                if pk then
                    local h = PKHolder(pk)
                    local n = (perKeyN[pk] or 0) + 1
                    ok = PKArmKey(h, e, slot, n)
                    if ok then perKeyN[pk] = n end
                end
            end
            if ok then pkArmed = pkArmed + 1 else pkSkipped = pkSkipped + 1 end
        end
    end

    for pk, n in pairs(perKeyN) do
        local h = PKHolder(pk)
        h:SetAttribute("pkCount", n)
        h:SetAttribute("pkBakedState", barState)
        h:SetAttribute("pkLiveState", barState)
        if n > 0 then SetOverrideBindingClick(pkBindOwner, true, pk, h:GetName()) end
    end

    -- hand the always list to the auto holder and let its snippet bind it. The
    -- Hide/Show is the apply trigger (_onshow runs pkAutoApply) -- Lua never
    -- binds these itself, so the toggle key can drop and restore them in combat.
    local ah = PKAutoHolder()
    ah:SetAttribute("pkAutoCount", autoN)
    ah:SetAttribute("pkAutoOn", Cfg("pkAutoOn") ~= false)
    ah:Hide()
    ah:Show()
    local tk = Cfg("pkToggleKey")
    if tk and tk ~= "" and autoN > 0 then
        SetOverrideBindingClick(pkBindOwner, true, tk, ah:GetName())
    end
end

-- ── SELECT MODE ─────────────────────────────────────────────────────────────
-- Click "Select Spells" and every action-bar button grows a clickable overlay:
-- click one to add that spell to the ping list, click again to remove. The
-- overlay is an ordinary frame sitting ON TOP of the (protected) action button,
-- so it eats the mouse click and the spell never fires -- no secure code, and
-- nothing about the real button is touched.
--
-- Picking a spell this way also captures the button's BINDING COMMAND, which is
-- how ElvUI/Bartender users get a working key without typing one: we resolve
-- GetBindingKey(cmd) live instead of guessing from a slot scan.

local pkSel = { on = false, overlays = {}, buttons = {}, banner = nil }
local PKSelRefresh   -- fwd

-- bar button name prefixes, richest first. LibActionButton bars (ElvUI,
-- Bartender4) replace Blizzard's entirely, so if one is present we use it and
-- skip the Blizzard names.
local PK_BTN_SETS = {
    { probe = "ElvUI_Bar1Button1", names = function(list)
        for bar = 1, 15 do
            for i = 1, 12 do list[#list + 1] = ("ElvUI_Bar%dButton%d"):format(bar, i) end
        end
    end },
    { probe = "BT4Button1", names = function(list)
        for i = 1, 120 do list[#list + 1] = "BT4Button" .. i end
    end },
    { probe = "ActionButton1", names = function(list)
        for _b = 1, #PK_BARS do
            for i = 1, 12 do list[#list + 1] = PK_BARS[_b] .. i end
        end
    end },
}

PKCollectButtons = function()
    local out = {}
    for _s = 1, #PK_BTN_SETS do
        local set = PK_BTN_SETS[_s]
        if _G[set.probe] then
            local names = {}
            set.names(names)
            for i = 1, #names do
                local f = _G[names[i]]
                if f and f.GetObjectType then out[#out + 1] = f end
            end
            return out
        end
    end
    return out
end

-- What a bar button is holding, as a PING SUBJECT. Blizzard ships /pingspell
-- AND /pingitem, so trinkets, potions and item macros are pingable too -- a
-- macro resolves to whichever it actually casts (GetMacroSpell first, then
-- GetMacroItem), which is why a "/use Healthstone" macro now shows up in the
-- picker where the old spell-only lookup skipped it.
-- Returns: id, bindingCommand, kind ("spell"|"item"), buttonName
PKButtonSubject = function(btn)
    local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
    if type(slot) ~= "number" or not HasAction(slot) then return nil end
    local aType, id = GetActionInfo(slot)
    local kind, sid
    -- Plain item and spell slots are unambiguous.
    if aType == "spell" then
        kind, sid = "spell", id
    elseif aType == "item" then
        kind, sid = "item", id
    elseif aType == "macro" then
        -- Macros need a resolver. C_ActionBar.GetSpell is the DOCUMENTED one
        -- and sees straight through a macro to the spell the slot will cast --
        -- which matters in 12.1, where GetMacroSpell is undocumented and
        -- GetMacroItem has no references left in Blizzard's code at all. The
        -- legacy globals stay as a fallback for item macros only, guarded by an
        -- existence check so a removed global degrades to "skip" not an error.
        if C_ActionBar and C_ActionBar.GetSpell then
            local s = C_ActionBar.GetSpell(slot)
            if type(s) == "number" and s > 0 then kind, sid = "spell", s end
        end
        if not sid and GetMacroSpell then
            local ms = GetMacroSpell(id)
            if ms then kind, sid = "spell", ms end
        end
        if not sid and GetMacroItem and GetItemInfoInstant then
            local _mn, mlink = GetMacroItem(id)
            local iid = mlink and GetItemInfoInstant(mlink)
            if iid then kind, sid = "item", iid end
        end
    end
    -- last resort: the slot knows whether it is an item even when the type did
    -- not tell us (item macros)
    if not sid and C_ActionBar and C_ActionBar.GetSpell then
        local s = C_ActionBar.GetSpell(slot)
        if type(s) == "number" and s > 0 then kind, sid = "spell", s end
    end
    if not sid then return nil end
    -- keyBoundTarget is LibActionButton's binding command (ElvUI/Bartender)
    local cmd = btn.bindingAction or btn.commandName or btn.keyBoundTarget
    return sid, cmd, kind, btn.GetName and btn:GetName() or nil
end

-- display name/icon for a tracked entry, spell or item
-- Which half of an override pair is live RIGHT NOW, from either half.
-- Normalise to the base (stable identity), then resolve forward (current
-- reality). A stored id is whatever the bar happened to show when it was
-- captured, so it can be either one.
PKLiveSpellID = function(id)
    if type(id) ~= "number" then return id end
    local sid = id
    if C_Spell and C_Spell.GetBaseSpell then
        local b = C_Spell.GetBaseSpell(sid)
        if type(b) == "number" and b > 0 then sid = b end
    end
    if C_Spell and C_Spell.GetOverrideSpell then
        local o = C_Spell.GetOverrideSpell(sid)
        if type(o) == "number" and o > 0 then sid = o end
    end
    return sid
end

PKSubjectInfo = function(entry)
    if entry.kind == "item" then
        local nm = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(entry.id)
        local ic = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(entry.id)
        return nm or ("Item " .. tostring(entry.id)), ic or 134400
    end
    -- show the spell the key ACTUALLY casts today, not the one it cast when
    -- this entry was added
    local live = PKLiveSpellID(entry.id)
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(live)
    return (info and info.name) or ("Spell " .. tostring(entry.id)), (info and info.iconID) or 134400
end

-- The slash line that pings this entry. Unlike /cast, /pingspell takes a
-- literal spell ID -- the game will not resolve an override for us -- so
-- resolving forward from the STORED id was not enough: an entry captured while
-- the override was up kept pinging Ascendance after the talent was dropped.
PKPingLine = function(entry)
    if entry.kind == "item" then return "/pingitem " .. entry.id end
    return "/pingspell " .. PKLiveSpellID(entry.id)
end

-- ── CATALOG ────────────────────────────────────────────────────────────────
-- Everything currently sitting on your action bars, as a browsable list. This is
-- the alternative to the on-bars overlay picker: same subjects, same capture
-- (id/kind/cmd/btn), but readable at a glance in the options panel and without
-- leaving it. Deliberately scanned from the BARS, not the spellbook -- a ping key
-- needs a keybind, and only bar buttons have one.
--
-- Rebuilt on demand (options panel open / Rescan), never on a timer: bar contents
-- change rarely and a scan walks up to 120 frames.
local pkCatalog, pkCatalogBuilt = {}, false

local function PKBuildCatalog()
    wipe(pkCatalog)
    local btns = PKCollectButtons()
    local seen = {}
    for i = 1, #btns do
        local btn = btns[i]
        local id, cmd, kind, bname = PKButtonSubject(btn)
        if id and not seen[id] then
            seen[id] = true
            local e = { id = id, kind = kind or "spell", cmd = cmd, btn = bname }
            local nm, icon = PKSubjectInfo(e)
            e.name, e.icon = nm, icon
            e.key = cmd and GetBindingKey(cmd) or nil
            pkCatalog[#pkCatalog + 1] = e
        elseif id and seen[id] then
            -- same subject on two bars: keep whichever copy actually has a key
            for j = 1, #pkCatalog do
                local c = pkCatalog[j]
                if c.id == id and not c.key and cmd then
                    local k = GetBindingKey(cmd)
                    if k then c.key, c.cmd, c.btn = k, cmd, bname end
                    break
                end
            end
        end
    end
    -- Anything TRACKED that is not on a bar (added by spell ID, or dragged off
    -- the bars since) is appended so the grid is the complete picture. Without
    -- this such an entry would be tracked but invisible and uneditable, because
    -- the grid is the only way into the editor.
    local list = PKList()
    for i = 1, #list do
        local t = list[i]
        if t and t.id and not seen[t.id] then
            seen[t.id] = true
            local e = { id = t.id, kind = t.kind or "spell", cmd = t.cmd, btn = t.btn, offBar = true }
            local nm, icon = PKSubjectInfo(e)
            e.name, e.icon = nm, icon
            e.key = (t.cmd and GetBindingKey(t.cmd)) or t.ownKey or nil
            pkCatalog[#pkCatalog + 1] = e
        end
    end
    -- keybound first (those are the ones a ping key can actually reach), then A-Z
    table.sort(pkCatalog, function(a, b)
        local ak, bk = a.key ~= nil, b.key ~= nil
        if ak ~= bk then return ak end
        return (a.name or "") < (b.name or "")
    end)
    pkCatalogBuilt = true
    return #pkCatalog
end

local function PKCatalog()
    if not pkCatalogBuilt then PKBuildCatalog() end
    return pkCatalog
end

local function PKCatalogDirty() pkCatalogBuilt = false end

-- ── catalog selection ───────────────────────────────────────────────────────
-- Which catalog icon the editor is currently showing. Selection is by SUBJECT
-- ID, not list index: the tracked list reorders on removal, and an index would
-- silently point at a different spell afterwards.
local pkSelID

local function PKTracked(id)
    if not id then return nil end
    local list = PKList()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
    return nil
end

local function PKSelect(id) pkSelID = id end
local function PKSelectedID() return pkSelID end

local function PKSelected()
    if not pkSelID then return nil end
    local cat = PKCatalog()
    for i = 1, #cat do
        if cat[i].id == pkSelID then return cat[i] end
    end
    -- selected something that has since left the bars: fall back to the tracked
    -- entry so the editor can still remove it
    local t = PKTracked(pkSelID)
    if t then
        local nm, icon = PKSubjectInfo(t)
        return { id = t.id, kind = t.kind, cmd = t.cmd, btn = t.btn, name = nm, icon = icon }
    end
    return nil
end

-- Enable creates the entry the first time, and thereafter only flips the flag --
-- so a spell toggled off and back on keeps its mode and key override.
local function PKSetSelectedEnabled(on)
    local sel = PKSelected()
    if not sel then return end
    local t = PKTracked(sel.id)
    if on then
        if not t then
            local list = PKList()
            if #list >= PK_MAX then
                print("|cff33ff99Arc Pings|r: ping-key list is full (" .. PK_MAX .. " entries).")
                return
            end
            list[#list + 1] = { id = sel.id, kind = sel.kind, cmd = sel.cmd, btn = sel.btn }
        else
            t.enabled = nil
        end
    elseif t then
        t.enabled = false
    end
    CharDB().pkSpells = PKList()
    PKApply()
end

local function PKRemoveSelected()
    local sel = PKSelected()
    if not sel then return end
    local list = PKList()
    for i = #list, 1, -1 do
        if list[i].id == sel.id then table.remove(list, i) end
    end
    CharDB().pkSpells = PKList()
    -- an off-bar entry only exists in the catalog BECAUSE it was tracked, so
    -- removing it has to drop it from the grid too
    if sel.offBar then
        PKCatalogDirty()
        pkSelID = nil
    end
    PKApply()
end

-- search filter shared by the options grid
local pkCatSearch = ""
local function PKSetCatSearch(s) pkCatSearch = s or "" end

local pkCatView = "all"   -- "all" | "on" (pinging) | "off" (not pinging)
local function PKSetCatView(v) pkCatView = v or "all" end
local function PKGetCatView() return pkCatView end

local function PKCatalogFiltered()
    local all = PKCatalog()
    local q = (pkCatSearch ~= "") and pkCatSearch:lower() or nil
    if not q and pkCatView == "all" then return all end
    local out = {}
    for i = 1, #all do
        local e = all[i]
        local ok = true
        if q then
            local n = e.name
            ok = n and n:lower():find(q, 1, true) ~= nil
        end
        if ok and pkCatView ~= "all" then
            local t = PKTracked(e.id)
            local pinging = (t ~= nil) and PKEntryOn(t)
            ok = (pkCatView == "on") == pinging
        end
        if ok then out[#out + 1] = e end
    end
    return out
end

local function PKIndexOf(spellID)
    local list = PKList()
    for i = 1, #list do
        if list[i].id == spellID then return i end
    end
    return nil
end

local function PKToggleSpell(spellID, cmd, kind, bname)
    local i = PKIndexOf(spellID)
    local list = PKList()
    if i then
        table.remove(list, i)
    else
        if #list >= PK_MAX then
            print("|cff33ff99Arc Pings|r: ping-key list is full (" .. PK_MAX .. " entries).")
            return
        end
        -- btn is kept for Always mode: its relay has to /click the REAL button
        -- so the cast still respects paging, overrides and macro conditionals
        list[#list + 1] = { id = spellID, cmd = cmd, kind = kind or "spell", btn = bname }
    end
    if PKApply then PKApply() end
    if PKSelRefresh then PKSelRefresh() end
end

local function PKOverlayFor(btn)
    local o = pkSel.overlays[btn]
    if o then return o end
    o = CreateFrame("Button", nil, btn)
    o:SetAllPoints(btn)
    o:SetFrameStrata("FULLSCREEN")
    o:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    o.tint = o:CreateTexture(nil, "OVERLAY")
    o.tint:SetAllPoints()
    o.tint:SetColorTexture(0.247, 0.788, 0.949, 0.30)
    o.tint:Hide()
    o.ring = o:CreateTexture(nil, "OVERLAY", nil, 1)
    o.ring:SetPoint("TOPLEFT", -2, 2)
    o.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    o.ring:SetColorTexture(0.247, 0.788, 0.949, 0.55)
    o.ring:Hide()
    o.check = o:CreateTexture(nil, "OVERLAY", nil, 2)
    o.check:SetSize(16, 16)
    o.check:SetPoint("TOPRIGHT", -1, -1)
    o.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    o.check:Hide()
    -- dim buttons holding nothing pingable so the eye goes to the real choices
    o.dim = o:CreateTexture(nil, "BACKGROUND")
    o.dim:SetAllPoints()
    o.dim:SetColorTexture(0, 0, 0, 0.55)
    o.dim:Hide()
    o:SetScript("OnClick", function()
        local sid, cmd, kind, bname = PKButtonSubject(btn)
        if sid then PKToggleSpell(sid, cmd, kind, bname) end
    end)
    o:SetScript("OnEnter", function(self)
        local sid, _cmd, kind = PKButtonSubject(btn)
        if not sid then return end
        self.ring:SetColorTexture(1, 1, 1, 0.75)
        self.ring:Show()
        local nm = PKSubjectInfo({ id = sid, kind = kind })
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(nm, 1, 1, 1)
        GameTooltip:AddLine(PKIndexOf(sid) and "Click to stop pinging this"
            or "Click to ping this", 0.6, 0.85, 1)
        GameTooltip:Show()
    end)
    o:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if PKSelRefresh then PKSelRefresh() end
    end)
    o:Hide()
    pkSel.overlays[btn] = o
    return o
end

PKSelRefresh = function()
    if not pkSel.on then return end
    for i = 1, #pkSel.buttons do
        local btn = pkSel.buttons[i]
        local o = pkSel.overlays[btn]
        if o then
            local sid = PKButtonSubject(btn)
            local picked = sid and PKIndexOf(sid)
            o.dim:SetShown(not sid)
            o.tint:SetShown(picked and true or false)
            o.check:SetShown(picked and true or false)
            o.ring:SetColorTexture(0.247, 0.788, 0.949, 0.55)
            o.ring:SetShown(sid and true or false)
        end
    end
    if pkSel.banner and pkSel.banner.count then
        local n = #PKList()
        pkSel.banner.count:SetText(("|cff33ff99%d|r of %d selected"):format(n, PK_MAX))
    end
    -- the options panel keeps its list in sync while picking (set by the panel)
    if pkSel.notify then pkSel.notify() end
end

local PKExitSelect  -- fwd

local function PKBanner()
    if pkSel.banner then return pkSel.banner end
    local b = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    b:SetSize(420, 66)
    b:SetPoint("TOP", UIParent, "TOP", 0, -120)
    b:SetFrameStrata("FULLSCREEN_DIALOG")
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    b:SetBackdropColor(0.043, 0.059, 0.102, 0.96)
    b:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
    local t = b:CreateFontString(nil, "OVERLAY")
    t:SetFont(STANDARD_TEXT_FONT, 13, "")
    t:SetPoint("TOP", 0, -10)
    t:SetText("|cff3fc9f2Pick the spells you want to ping|r")
    local sub = b:CreateFontString(nil, "OVERLAY")
    sub:SetFont(STANDARD_TEXT_FONT, 11, "")
    sub:SetPoint("TOP", t, "BOTTOM", 0, -4)
    sub:SetTextColor(0.51, 0.60, 0.71)
    sub:SetText("click a spell on your bars to add it, click again to remove")
    b.count = b:CreateFontString(nil, "OVERLAY")
    b.count:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.count:SetPoint("BOTTOMLEFT", 12, 8)
    local done = CreateFrame("Button", nil, b, "BackdropTemplate")
    done:SetSize(80, 20)
    done:SetPoint("BOTTOMRIGHT", -10, 8)
    done:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    done:SetBackdropColor(0.110, 0.161, 0.243, 1)       -- raised navy fill (matches MakeSmallButton)
    done:SetBackdropBorderColor(0.298, 0.400, 0.549, 1) -- steel border
    local dfs = done:CreateFontString(nil, "OVERLAY")
    dfs:SetFont(STANDARD_TEXT_FONT, 11, "")
    dfs:SetPoint("CENTER")
    dfs:SetText("Done")
    done:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.150, 0.205, 0.295, 1)
        self:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)  -- cyan on hover
    end)
    done:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.110, 0.161, 0.243, 1)
        self:SetBackdropBorderColor(0.298, 0.400, 0.549, 1)
    end)
    done:SetScript("OnClick", function() PKExitSelect() end)
    b:Hide()
    pkSel.banner = b
    return b
end

local function PKEnterSelect()
    if pkSel.on then PKExitSelect() return end
    pkSel.on = true
    pkSel.buttons = PKCollectButtons()
    if #pkSel.buttons == 0 then
        pkSel.on = false
        print("|cff33ff99Arc Pings|r: no action bar buttons found to pick from.")
        return
    end
    for i = 1, #pkSel.buttons do
        local o = PKOverlayFor(pkSel.buttons[i])
        o:EnableMouse(true)
        o:Show()
    end
    PKBanner():Show()
    PKSelRefresh()
end

PKExitSelect = function()
    pkSel.on = false
    for _btn, o in pairs(pkSel.overlays) do
        o:EnableMouse(false)
        o:Hide()
    end
    if pkSel.banner then pkSel.banner:Hide() end
    GameTooltip:Hide()
    -- hand the user back to where they came from (set by the options panel)
    if pkSel.onExit then pkSel.onExit() end
end

-- ── PING KEYS DEBUG ─────────────────────────────────────────────────────────
-- Dumps what each relay ACTUALLY holds. The cast half of an Always entry has
-- several places it can silently fall through (slot lookup, action type, macro
-- body read), and all of them look identical in game: the ping fires, nothing
-- casts. This shows which step produced the macrotext that is really loaded.
local pkDbgWin
local function PKDebugWindow(text)
    if not pkDbgWin then
        local f = CreateFrame("Frame", "ArcPingsPKDebug", UIParent, "BackdropTemplate")
        f:SetSize(620, 460)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        f:SetBackdropColor(0.043, 0.059, 0.102, 1)
        f:SetBackdropBorderColor(0.247, 0.788, 0.949, 1)
        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFont(STANDARD_TEXT_FONT, 13, "")
        t:SetPoint("TOPLEFT", 12, -10)
        t:SetText("|cff3fc9f2Ping Keys|r  relay dump (Ctrl+A, Ctrl+C)")
        local close = CreateFrame("Button", nil, f)
        close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -6, -6)
        local cx = close:CreateFontString(nil, "OVERLAY")
        cx:SetFont(STANDARD_TEXT_FONT, 14, ""); cx:SetPoint("CENTER"); cx:SetText("x")
        close:SetScript("OnClick", function() f:Hide() end)
        local sf = CreateFrame("ScrollFrame", "ArcPingsPKDebugScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -34)
        sf:SetPoint("BOTTOMRIGHT", -30, 12)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject("GameFontHighlightSmall")
        eb:SetWidth(560)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        sf:SetScrollChild(eb)
        f.eb = eb
        pkDbgWin = f
    end
    pkDbgWin.eb:SetText(text)
    pkDbgWin.eb:HighlightText()
    pkDbgWin:Show()
end

local function PKDebugDump()
    local out = {}
    local function add(s) out[#out + 1] = s end
    add("enabled=" .. tostring(Cfg("pkEnabled"))
        .. "  onlySelected=" .. tostring(Cfg("pkOnlySelected"))
        .. "  pingKey=" .. tostring(Cfg("pkKey"))
        .. "  combat=" .. tostring(InCombatLockdown())
        .. "  autoPing=" .. tostring(PKAutoOn()) .. " toggleKey=" .. tostring(Cfg("pkToggleKey")))
    add("GetMacroInfo=" .. tostring(GetMacroInfo ~= nil)
        .. "  C_ActionBar.GetSpell=" .. tostring(C_ActionBar and C_ActionBar.GetSpell ~= nil))
    -- HOLD-MODE PROOF: which ping keys have a holder, how many spells are on
    -- each, and what the key currently resolves to. NOTE boundTo shows the
    -- NORMAL binding -- it is how we caught key 7 already belonging to
    -- EXTRAACTIONBUTTON1 while our override was set non-priority and losing.
    add("-- hold-mode holders --")
    local anyHolder = false
    for pk, h in pairs(pkHolders) do
        anyHolder = true
        add(("  pingKey=%s holder=%s pkCount=%s guard=%s boundTo=%s")
            :format(tostring(pk), tostring(h:GetName()),
                tostring(h:GetAttribute("pkCount")), tostring(h:GetAttribute("pkGuard")),
                tostring(GetBindingAction and GetBindingAction(pk) or "?")))
        local n = h:GetAttribute("pkCount") or 0
        for i = 1, n do
            add(("    [%d] key=%s relay=%s macrotext=[%s]"):format(i,
                tostring(h:GetAttribute("pkKey" .. i)),
                tostring(h:GetAttribute("pkRelay" .. i)),
                tostring(_G[h:GetAttribute("pkRelay" .. i) or ""] and
                    _G[h:GetAttribute("pkRelay" .. i)]:GetAttribute("macrotext"))))
        end
    end
    if not anyHolder then add("  (no hold-mode holders created)") end
    add("")
    local list = PKList()
    if #list == 0 then add("(no spells selected)") end
    for i = 1, #list do
        local e = list[i]
        local nm = PKSubjectInfo(e)
        add(("[%d] %s  id=%s kind=%s mode=%s"):format(i, tostring(nm), tostring(e.id),
            tostring(e.kind), PKEntryMode(e)))
        add("     btn=" .. tostring(e.btn) .. "  exists=" .. tostring(e.btn and _G[e.btn] ~= nil))
        add("     cmd=" .. tostring(e.cmd) .. "  pingKey=" .. tostring(e.pingKey) .. " ownKey=" .. tostring(e.ownKey)
            .. "  resolvedKey=" .. tostring(PKKeyFor(e)))
        local btn = e.btn and _G[e.btn]
        if btn then
            local slot = btn.action or (btn.GetAttribute and btn:GetAttribute("action"))
            add("     slot=" .. tostring(slot) .. "  hasAction=" ..
                tostring(type(slot) == "number" and HasAction(slot) or false))
            if type(slot) == "number" and HasAction(slot) then
                local aType, aid, sub = GetActionInfo(slot)
                add("     GetActionInfo -> type=" .. tostring(aType)
                    .. " id=" .. tostring(aid) .. " sub=" .. tostring(sub))
                if aType == "macro" then
                    local mname = GetActionText and GetActionText(slot)
                    local idx = PKMacroIndexForSlot(slot)
                    add("     macroName=" .. tostring(mname) .. "  macroIndex=" .. tostring(idx))
                    -- list every macro sharing that name: a collision between an
                    -- account and a character macro is what made this pick wrong
                    if mname and GetNumMacros and GetMacroInfo then
                        local acct, char = GetNumMacros()
                        local cands = {}
                        local function scan(from, to)
                            for mi = from, to do
                                if GetMacroInfo(mi) == mname then
                                    cands[#cands + 1] = mi .. "(spell=" ..
                                        tostring(GetMacroSpell and GetMacroSpell(mi)) .. ")"
                                end
                            end
                        end
                        scan(1, acct or 0)
                        scan(PK_LIMIT.MACRO + 1, PK_LIMIT.MACRO + (char or 0))
                        add("     sameName=[" .. table.concat(cands, " ") .. "]  wantSpell=" .. tostring(aid))
                    end
                    if idx and GetMacroInfo then
                        local mn, _mt, body = GetMacroInfo(idx)
                        add("     GetMacroInfo(" .. tostring(idx) .. ") -> name=" .. tostring(mn)
                            .. " bodyLen=" .. tostring(type(body) == "string" and #body or "n/a"))
                        if type(body) == "string" then add("     body: [" .. body .. "]") end
                    end
                end
            end
        end
        local r = pkRelays[i]
        add("     relay=" .. tostring(r and r:GetName())
            .. "  type=" .. tostring(r and r:GetAttribute("type")))
        add("     macrotext: [" .. tostring(r and r:GetAttribute("macrotext")) .. "]")
        add("")
    end
    PKDebugWindow(table.concat(out, "\n"))
end
_G.ArcPings_PKDebug = PKDebugDump

StaticPopupDialogs["ARCPINGFEED_RESET_LAYOUT"] = {
    text = "Reset the entry layout back to the Blizzard chat shape?|n|n"
        .. "Sender at the line start, callout flowing after, automatic height. "
        .. "Every piece position, offset, size and padding is dropped.",
    button1 = YES, button2 = NO,
    OnAccept = function() if ArcPings_ResetLayout then ArcPings_ResetLayout() end end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local pkEv = CreateFrame("Frame")
pkEv:RegisterEvent("PLAYER_REGEN_ENABLED")
pkEv:RegisterEvent("UPDATE_BINDINGS")
pkEv:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
pkEv:RegisterEvent("PLAYER_ENTERING_WORLD")
pkEv:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
pkEv:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
-- "any spell" mode bakes from live bar contents, so a page/form change makes
-- the relays stale: re-bake here when we can, and the snippet's page guard
-- covers the case where we cannot (mid-combat)
-- Talent-driven spell overrides. The CAST line survives these on its own (it
-- casts the base spell), but the PING line is resolved forward at bake time, so
-- without these it would keep naming the spell you used to have. Deliberately
-- NOT SPELLS_CHANGED, which fires constantly during loading for no gain.
pkEv:RegisterEvent("TRAIT_CONFIG_UPDATED")
pkEv:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
-- combat is a STATE the Ping Keys status line reports (every write is deferred
-- while it lasts), so the panel has to hear the edge in both directions
pkEv:RegisterEvent("PLAYER_REGEN_DISABLED")
pkEv:SetScript("OnEvent", function(_, ev)
    if (ev == "PLAYER_REGEN_DISABLED" or ev == "PLAYER_REGEN_ENABLED")
        and PKPanelRefresh then
        PKPanelRefresh()
    end
    if ev == "PLAYER_REGEN_DISABLED" then return end
    -- The toggle key can flip Auto-Ping mid-fight, which only the holder knows
    -- about. Write that back to the DB BEFORE any re-apply, or the next PKApply
    -- would push the stale saved value over the user's in-combat choice.
    if ev == "PLAYER_REGEN_ENABLED" and pkAutoHolder then
        local live = pkAutoHolder:GetAttribute("pkAutoOn") and true or false
        if live ~= (Cfg("pkAutoOn") ~= false) then CharDB().pkAutoOn = live end
    end
    -- the catalog mirrors the bars, so anything that moves a spell or a binding
    -- stales it; mark rather than rescan (a scan walks up to 120 frames and the
    -- panel may not even be open)
    if ev == "UPDATE_BINDINGS" or ev == "ACTIONBAR_SLOT_CHANGED"
        or ev == "ACTIONBAR_PAGE_CHANGED" or ev == "PLAYER_ENTERING_WORLD"
        or ev == "TRAIT_CONFIG_UPDATED" or ev == "PLAYER_SPECIALIZATION_CHANGED" then
        PKCatalogDirty()
    end
    -- auto-resolved keys move when the user rebinds or drags a spell to another
    -- slot; re-arm on those, and flush anything deferred out of combat
    if ev == "PLAYER_REGEN_ENABLED" and not pkDirty then return end
    if Cfg("pkEnabled") or pkDirty then PKApply() end
end)

local function RegisterSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
    local category = Settings.RegisterVerticalLayoutCategory("Arc Pings")
    settingsCategory = category

    local function bool(key, label, tooltip)
        local setting = Settings.RegisterProxySetting(category, "ARCPINGS_" .. key:upper(),
            Settings.VarType.Boolean, label, DEFAULTS[key],
            function() return Cfg(key) end, function(v) SetCfg(key, v) end)
        Settings.CreateCheckbox(category, setting, tooltip)
    end
    local function slider(key, label, minV, maxV, step, tooltip)
        local setting = Settings.RegisterProxySetting(category, "ARCPINGS_" .. key:upper(),
            Settings.VarType.Number, label, DEFAULTS[key],
            function() return Cfg(key) end, function(v) SetCfg(key, v) end)
        local options = Settings.CreateSliderOptions(minV, maxV, step)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options, tooltip)
    end
    local function dropdown(key, label, values, tooltip)
        local setting = Settings.RegisterProxySetting(category, "ARCPINGS_" .. key:upper(),
            Settings.VarType.String, label, DEFAULTS[key],
            function() return Cfg(key) end, function(v) SetCfg(key, v) end)
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            for _, pair in ipairs(values) do
                container:Add(pair[1], pair[2])
            end
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, tooltip)
    end

    bool("enabled", "Enable Feed Window", "Shows your group's pings as a scrolling feed window.")
    bool("locked", "Lock Window Position", "Unlock to drag the window; the border shows while unlocked.")
    bool("panelDrag", "Drag While Options Open", "While the options panel is open, the window can be dragged into place even when its position is locked. Turn off if you want the lock respected at all times.")
    slider("width", "Window Width", 160, 600, 10)
    slider("height", "Window Height", 0, 800, 10, "0 = automatic: the window hugs its entries. Set a value to keep the window at least this tall.")
    bool("staticSize", "Static Window Size", "The window is always sized for Max Entries Shown and stays on screen even when empty — a fixed box that pings flow through, instead of a window that grows and shrinks with each ping.")
    bool("showMinimap", "Show Minimap Button", "The Arc Pings button on the minimap. Click it for options; drag it around the rim to move it.")
    slider("fontSize", "Font Size", 8, 24, 1)
    slider("maxEntries", "Max Entries Shown", 1, 20, 1)
    slider("entrySeconds", "Entry Duration (seconds)", 0, 60, 1, "How long each ping stays. 0 = stay until pushed out.")
    bool("showBackground", "Show Background")
    slider("bgAlpha", "Background Opacity", 0, 1, 0.05)
    bool("showBorder", "Show Border", "The border always shows while the window is unlocked.")
    bool("newestOnTop", "Newest Entries On Top")
    bool("showTimestamp", "Show Timestamps")
    bool("showSender", "Show Sender Name")
    dropdown("strata", "Window Layer (Frame Strata)", { { "BACKGROUND", "Background (lowest)" }, { "LOW", "Low" }, { "MEDIUM", "Medium" }, { "HIGH", "High" }, { "DIALOG", "Dialog (highest)" } })
    dropdown("animStyle", "New Ping Animation", { { "none", "None" }, { "fade", "Fade In" }, { "pulse", "Pulse" }, { "flash", "Flash" }, { "zoom", "Zoom (pop in)" } })
    slider("animInSecs", "Entrance Animation Seconds", 0.1, 2, 0.1)
    dropdown("animOutStyle", "Expire Animation", { { "none", "None (snap off)" }, { "fade", "Fade Out" } })
    slider("animOutSecs", "Fade Out Seconds", 0.1, 3, 0.1)
    slider("windowScale", "Window Scale", 0.5, 2, 0.05)
    bool("showTitle", "Show Title While Unlocked", "The \"Arc Pings\" label floating above the window while it is unlocked or the options panel is open. It sits outside the window and never touches the entries.")
    slider("rowPadTop", "Entry Top Padding", 0, 40, 1)
    slider("rowPadBottom", "Entry Bottom Padding", 0, 40, 1)
    bool("alertsEnabled", "Enable Ping Alerts", "Sound and/or text-to-speech when your group pings.")
    -- NO dropdowns here. This page writes the same keys as the real panel but
    -- could only ever offer a subset of the choices (2 of 5 positions, 4 of the
    -- full sound library), so touching one silently overwrote a valid setting
    -- with a truncated one. Positions and sounds live in the Arc panel only.
    slider("alertThrottle", "Minimum Seconds Between Alerts", 0, 10, 0.5)

    Settings.RegisterAddOnCategory(category)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- STANDALONE OPTIONS PANEL v7 — Arc 2.0 look, ROW-BUILDER engine.
-- Structure: title bar → LIVE PREVIEW strip (every tab, re-renders on every
-- change) → tabs (Window / Entries / Alerts / Layout) → striped option rows
-- built by a small row factory (the reusable Arc 2.0 kit).
-- Layout tab: drag canvas (ALL four pieces free-drag — the Ping Text carries
-- its own side/X/Y and its grab box hugs the glyphs, not the full span) +
-- piece list (visibility switch + Edit per piece) + INLINE editor with a
-- per-piece reset. All controls write through Commit -> SetCfg -> ApplyAll
-- + preview refresh.
-- ═══════════════════════════════════════════════════════════════════════════

local COL = {
    bg      = { 0.043, 0.059, 0.102 },
    panel   = { 0.063, 0.094, 0.153 },
    well    = { 0.039, 0.067, 0.125 },
    line    = { 0.114, 0.165, 0.247 },
    line2   = { 0.165, 0.231, 0.341 },
    box     = { 0.055, 0.078, 0.130 },  -- section container fill (raised from bg)
    ink     = { 0.950, 0.970, 1.000 },  -- near-white: primary labels pop
    dim     = { 0.700, 0.780, 0.880 },  -- cool bright blue-grey: readable secondary
    faint   = { 0.550, 0.650, 0.780 },  -- tags/outlines clearly visible on navy
    arc     = { 0.247, 0.788, 0.949 },
    arcDeep = { 0.078, 0.353, 0.451 },
    btn      = { 0.110, 0.161, 0.243 },  -- raised navy-blue button fill
    btnHover = { 0.150, 0.205, 0.295 },  -- button fill lightens on hover
    steel    = { 0.298, 0.400, 0.549 },  -- steel button border (cyan only on hover)
}
local WHITE = "Interface\\Buttons\\WHITE8X8"

local optPanel
local optRefreshers = {}
-- forward: the Window tab's own Reset button is built before the layout page
local ResetWholeLayout
-- hand the engine a way to re-read every control (the Auto-Ping key can flip
-- state from a secure snippet, with no Lua call of ours involved)
PKPanelRefresh = function()
    -- callers include an event handler that fires whether or not the panel was
    -- ever built, so the guard lives here where optPanel is actually in scope
    if not (optPanel and optPanel:IsShown()) then return end
    for i = 1, #optRefreshers do optRefreshers[i]() end
end
local openDropdown
local RefreshPreview  -- fwd: re-renders both sample rows + inline editor

local function Skin(f, bg, borderCol)
    f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local b = borderCol or COL.line
    f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end

local function CloseDropdown()
    if openDropdown then openDropdown:Hide(); openDropdown = nil end
end

-- single write path for every panel control
local function Commit(key, val)
    SetCfg(key, val)
    if RefreshPreview then RefreshPreview() end
end

local function PickColor(key, onDone)
    local c = Cfg(key)
    local function commit()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        Commit(key, { nr, ng, nb })
        if onDone then onDone() end
    end
    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow({
            r = c[1], g = c[2], b = c[3], hasOpacity = false,
            swatchFunc = commit, cancelFunc = function()
                Commit(key, { c[1], c[2], c[3] })
                if onDone then onDone() end
            end,
        })
    end
end

-- ── shared control pieces ────────────────────────────────────────────────────

-- Canonical Arc toggle: a WoW-style SQUARE CHECKBOX. The box stays constant
-- (fill + border never change); only the cyan checkmark is added or removed,
-- exactly like Blizzard. This replaced the old pill/sliding switch as the Arc
-- standard (Kick Assist / ProcTracker). The mark is the flat "checkmark-minimal"
-- atlas tinted to Arc cyan, sized to overhang the 18px box a hair like WoW's.
local function MakeCheckbox(parent)
    local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
    c:SetSize(18, 18); Skin(c, COL.well, COL.line2)   -- stronger, clearer border
    c.check = c:CreateTexture(nil, "OVERLAY")
    c.check:SetAtlas("checkmark-minimal")
    c.check:SetDesaturated(true)                       -- grey the green atlas so the tint reads pure cyan
    c.check:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    c.check:SetSize(20, 20); c.check:SetPoint("CENTER", 0, 0); c.check:Hide()
    c._glow = c:CreateTexture(nil, "ARTWORK")
    c._glow:SetTexture([[Interface\Buttons\ButtonHilight-Square]]); c._glow:SetBlendMode("ADD")
    c._glow:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.55)
    c._glow:SetPoint("TOPLEFT", -3, 3); c._glow:SetPoint("BOTTOMRIGHT", 3, -3); c._glow:Hide()
    function c:SetHover(on) self._glow:SetShown(on and true or false) end
    function c:SetOn(on) self.check:SetShown(on and true or false) end
    c:SetScript("OnEnter", function(self) self._glow:Show() end)
    c:SetScript("OnLeave", function(self) self._glow:Hide() end)
    return c
end
-- Back-compat: every call site + the UI export still say MakeSwitch. They now
-- all build the square checkbox above (same :SetOn / :SetHover interface).
local MakeSwitch = MakeCheckbox

local function MakeSwatch(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 24, h or 14)
    Skin(b, COL.well)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetTexture(WHITE)
    b.tex:SetPoint("TOPLEFT", 1, -1)
    b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    function b:SetColor(c) self.tex:SetVertexColor(c[1], c[2], c[3], 1) end
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    return b
end

local function MakeSmallButton(parent, label, w)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w or 92, 20)
    b.FitText = function(self, minW, maxW)
        local need = (self.fs:GetStringWidth() or 0) + 24
        self:SetWidth(math.max(minW or 92, math.min(need, maxW or 420)))
    end
    -- RAISED: navy-blue fill + STEEL border + centred text, going cyan on hover.
    -- Input fields and dropdowns use the darker well + line border, which is how
    -- you tell a button from a field at a glance.
    Skin(b, COL.btn, COL.steel)
    local bevel = b:CreateTexture(nil, "ARTWORK"); bevel:SetTexture(WHITE)  -- subtle raised top edge
    bevel:SetVertexColor(1, 1, 1, 0.06); bevel:SetPoint("TOPLEFT", 1, -1); bevel:SetPoint("TOPRIGHT", -1, -1); bevel:SetHeight(1)
    b.fs = b:CreateFontString(nil, "OVERLAY")
    b.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    b.fs:SetPoint("CENTER")
    b.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    b.fs:SetText(label or "")
    b:SetScript("OnEnter", function()
        b:SetBackdropColor(COL.btnHover[1], COL.btnHover[2], COL.btnHover[3], 1)
        b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropColor(COL.btn[1], COL.btn[2], COL.btn[3], 1)
        b:SetBackdropBorderColor(COL.steel[1], COL.steel[2], COL.steel[3], 1)
    end)
    return b
end

-- ── Discord footer ──────────────────────────────────────────────────────────
-- Same invite across every Arc addon. Addons cannot open URLs, so the button
-- shows a small popup with the link selected for Ctrl+C.
local ARC_DISCORD = "https://discord.gg/yMZmnFjUTd"
local BLURPLE = { 0.345, 0.396, 0.949 }   -- #5865F2
local discordCopy

local function ShowDiscordCopy(anchor)
    if not discordCopy then
        local d = CreateFrame("Frame", "ArcPingsDiscordCopy", UIParent, "BackdropTemplate")
        d:SetSize(300, 70); d:SetFrameStrata("FULLSCREEN_DIALOG"); d:SetToplevel(true)
        Skin(d, COL.panel, COL.arc)
        local t = d:CreateFontString(nil, "OVERLAY"); t:SetFont(STANDARD_TEXT_FONT, 12, "")
        t:SetPoint("TOP", 0, -10); t:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        t:SetText("Press Ctrl+C to copy, then open it in your browser")
        local box = CreateFrame("EditBox", nil, d, "BackdropTemplate")
        box:SetSize(272, 22); box:SetPoint("TOP", 0, -32); Skin(box, COL.well)
        box:SetFont(STANDARD_TEXT_FONT, 12, ""); box:SetTextInsets(6, 6, 0, 0)
        box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", function() d:Hide() end)
        box:SetScript("OnEnterPressed", function() d:Hide() end)
        box:SetScript("OnEditFocusLost", function() d:Hide() end)
        tinsert(UISpecialFrames, "ArcPingsDiscordCopy")
        d.box = box; discordCopy = d
    end
    discordCopy:ClearAllPoints()
    discordCopy:SetPoint("CENTER", anchor or UIParent, "CENTER", 0, 0)
    discordCopy:Show(); discordCopy:Raise()
    discordCopy.box:SetText(ARC_DISCORD); discordCopy.box:SetFocus(); discordCopy.box:HighlightText()
end

local function MakeDiscordButton(parent)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(84, 20); Skin(b, COL.well)
    local fs = b:CreateFontString(nil, "OVERLAY"); fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    fs:SetPoint("CENTER"); fs:SetText("|cff7289DADiscord|r")
    b:SetScript("OnEnter", function()
        b:SetBackdropBorderColor(BLURPLE[1], BLURPLE[2], BLURPLE[3], 1)
        GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Join the Arc UI Discord", 1, 1, 1)
        GameTooltip:AddLine("Questions, help, and updates", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1); GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function() ShowDiscordCopy(parent) end)
    return b
end

-- ── the row engine: BOXED SECTIONS ──────────────────────────────────────────
-- A page holds section boxes. Section() opens a cyan-titled bordered container;
-- every Row* after it drops INTO that box; LayoutPage() flows the titles and
-- boxes and sizes each box to its VISIBLE rows, so dependent controls collapse
-- and the box shrinks with them.
--
-- This replaced zebra-striped full-width rows. Solid boxes read far better and
-- match Kick Assist / ProcTracker, which is the current Arc standard.

local ROW_H = 26

-- A row's CONTENT is capped; it does not stretch to the panel edge. This window
-- is resizable to 1100px and "label hard left, control hard right" turns absurd
-- at that size: the switch ends up half a screen away from the word it belongs
-- to. Rows now cap their own width and hug the left, so a label and its control
-- stay together at every panel size.
-- Controls sit at a FIXED offset from the row's LEFT edge, never pinned to its
-- right. Pinning right meant that on a window resizable to 1100px a switch ended
-- half a screen from the word it belonged to.
--
-- Do NOT go back to computing this from a width. The previous attempt capped row
-- width from pg:GetWidth() inside LayoutPage, and a sub-page whose anchor chain
-- had not resolved yet reports 0 -- so every row clamped to the 220 floor and the
-- right-pinned controls landed straight on top of their own labels. Fixed offsets
-- need no measurement and cannot fail that way.
-- One table, not five locals: this chunk is close to Lua's 200-local ceiling.
local LAY = {
    ctrl    = 230,  -- full-width section: the label column is everything left of this
    half    = 175,  -- side-by-side section: half the room, so a shorter column
    halfBtn = 110,  -- side-by-side section: a button starts here (it is 100 wide)
    twoA    = 230,  -- two-up row: first control -- SAME column as ctrl so single + paired toggles line up
    twoBLab = 268,  -- two-up row: second label (clear of the first control)
    twoB    = 436,  -- two-up row: second control (fits a checkbox or swatch; row is 468 at min panel width)
}

local function AddRow(pg, h, visibleFn)
    h = h or ROW_H
    local sec = pg._curSection
    local parent = (sec and sec.box) or pg
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(h); row._h = h; row._visibleFn = visibleFn
    row._ctrlX = (sec and sec.ctrlX) or LAY.ctrl
    if sec then sec.rows[#sec.rows + 1] = row else pg._rows[#pg._rows + 1] = row end
    return row
end

-- hover text. Descriptions used to be their own 32px rows, which pushed the tab
-- past the bottom of the panel; as tooltips they cost no height at all.
local function RowTip(row, text)
    if not (row and text) then return row end
    row:EnableMouse(true)
    row:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function RowLabel(row, text)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 12, ""); fs:SetPoint("LEFT", 10, 0)
    fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3]); fs:SetText(text)
    return fs
end

-- cyan mini-title above a bordered box; rows added after this go inside it.
-- visibleFn collapses the ENTIRE section (title, box and rows) when it returns
-- false, which is what "hide the per-spell half while ping keys are off" needs.
-- side = "L" or "R" puts two boxes on ONE line, each half the page wide, sharing
-- a top edge. Anchored relative to the page's TOP (its centre x), so this needs
-- no measurement either.
local function Section(pg, text, visibleFn, side, ctrlX)
    local title = pg:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 11, "")
    title:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]); title:SetText(text)
    local box = CreateFrame("Frame", nil, pg, "BackdropTemplate")
    Skin(box, COL.box, COL.line)
    local sec = {
        title = title, box = box, rows = {}, visibleFn = visibleFn, side = side,
        -- a slider-only box passes its own tight ctrlX so the control hugs the
        -- short label (X / Width) instead of sitting out at the toggle column
        ctrlX = ctrlX or (side and LAY.half) or LAY.ctrl,
    }
    pg._sections[#pg._sections + 1] = sec
    pg._curSection = sec
    return box
end

-- explanatory paragraph under a control. h must be tall enough for the text to
-- wrap into, or the extra lines are simply clipped.
local function RowDesc(pg, text, h, visibleFn)
    local row = AddRow(pg, h or 20, visibleFn)
    local fs = row:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT, 10, ""); fs:SetPoint("LEFT", 10, 1); fs:SetPoint("RIGHT", -10, 1)
    fs:SetJustifyH("LEFT"); fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]); fs:SetText(text)
    return row
end

-- _startY lets a page reserve room at the top for something absolutely placed
-- (the Entry Layout drag canvas) before its sections begin.
local function LayoutPage(pg)
    if not (pg and pg._sections) then return end
    local y = pg._startY or -4
    -- rows are ALWAYS the full width of whatever contains them. Their controls
    -- sit at a fixed left offset, so nothing here has to measure a width.
    for _i, row in ipairs(pg._rows) do
        if row._sync then row._sync() end
        local vis = (not row._visibleFn) or row._visibleFn()
        if vis then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 2, y)
            row:SetPoint("TOPRIGHT", -2, y)
            row:Show(); y = y - row._h
        else row:Hide() end
    end
    -- an "L" section opens a two-column band; the next "R" shares its top edge,
    -- and y resumes below whichever of the two ended up taller
    local pairTopY, pairBottomY
    for _i, sec in ipairs(pg._sections) do
        local side = sec.side
        if sec.visibleFn and not sec.visibleFn() then
            sec.title:Hide(); sec.box:Hide()
            -- a hidden L still opens the band so its R keeps its own column
            if side == "L" then pairTopY, pairBottomY = y, y
            elseif side == "R" then pairTopY, pairBottomY = nil, nil end
        else
            local topY = (side == "R" and pairTopY) or y
            local titled = (sec.title:GetText() or "") ~= ""
            sec.title:ClearAllPoints()
            if side == "R" then
                sec.title:SetPoint("TOPLEFT", pg, "TOP", 10, topY - 2)
            else
                sec.title:SetPoint("TOPLEFT", 4, topY - 2)
            end
            sec.title:SetShown(titled)
            sec.box:Show()
            local boxTop = topY - (titled and 18 or 0)
            sec.box:ClearAllPoints()
            if side == "L" then
                sec.box:SetPoint("TOPLEFT", 0, boxTop)
                sec.box:SetPoint("TOPRIGHT", pg, "TOP", -6, boxTop)
            elseif side == "R" then
                sec.box:SetPoint("TOPLEFT", pg, "TOP", 6, boxTop)
                sec.box:SetPoint("TOPRIGHT", 0, boxTop)
            else
                sec.box:SetPoint("TOPLEFT", 0, boxTop)
                sec.box:SetPoint("TOPRIGHT", 0, boxTop)
            end
            -- CONTROL COLUMN: line every single-control row's control up just
            -- past the WIDEST visible label in THIS section, so a short label
            -- (X, Enable Feed Window, Window Layer) never strands its control out
            -- at a fixed column. Two-up rows keep their own fixed stops.
            local col
            for _c, r in ipairs(sec.rows) do
                if r._colLabel and ((not r._visibleFn) or r._visibleFn()) then
                    local w = 10 + (r._colLabel:GetStringWidth() or 0) + 16
                    if not col or w > col then col = w end
                end
            end
            if col then
                for _c, r in ipairs(sec.rows) do
                    if r._colCtrl then
                        r._colCtrl:ClearAllPoints()
                        r._colCtrl:SetPoint("LEFT", r, "LEFT", col, 0)
                        if r._colFill then r._colCtrl:SetPoint("RIGHT", r._colFill, "LEFT", -8, 0) end
                    end
                end
            end
            local by = -6
            for _j, row in ipairs(sec.rows) do
                if row._sync then row._sync() end
                local vis = (not row._visibleFn) or row._visibleFn()
                if vis then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", sec.box, "TOPLEFT", 6, by)
                    row:SetPoint("TOPRIGHT", sec.box, "TOPRIGHT", -6, by)
                    row:Show()
                    by = by - row._h
                else
                    row:Hide()
                end
            end
            sec.box:SetHeight(math.max(10, -by + 6))
            local bottom = boxTop - (-by + 6) - 12
            if side == "L" then
                pairTopY, pairBottomY = topY, bottom
                y = bottom                                   -- provisional: no R may follow
            elseif side == "R" then
                y = math.min(pairBottomY or bottom, bottom)  -- y grows downward (negative)
                pairTopY, pairBottomY = nil, nil
            else
                y = bottom
            end
        end
    end
    pg._contentH = -y + 8
    if pg._host then
        pg:SetHeight(math.max(1, pg._contentH))
        if pg.UpdateScroll then pg:UpdateScroll() end
    end
end

-- kept for callers that used the old name
local function RestackPage(pg) LayoutPage(pg) end

local function RowToggle(pg, label, key, onChange)
    local row = AddRow(pg)
    row._colLabel = RowLabel(row, label)   -- measured by LayoutPage for the control column
    local sw = MakeSwitch(row)
    sw:SetPoint("LEFT", row._ctrlX, 0)
    row._colCtrl = sw
    local function refresh() sw:SetOn(Cfg(key) == true) end
    refresh()
    row._sync = refresh
    optRefreshers[#optRefreshers + 1] = refresh
    local function flip()
        CloseDropdown()
        Commit(key, not (Cfg(key) == true))
        refresh()
        PlaySound(Cfg(key) == true and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                                    or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
        if onChange then onChange(Cfg(key) == true) end
        LayoutPage(pg)          -- rows this toggle gates appear/collapse now
    end
    sw:SetScript("OnClick", flip)
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", flip)
    -- hovering anywhere on the row lights the toggle's cyan glow
    row:HookScript("OnEnter", function() sw:SetHover(true) end)
    row:HookScript("OnLeave", function() sw:SetHover(false) end)
    return row
end

-- normal-UI numeric row: slider + [-] typed value box [+]. The arrows step
-- the slider, the box takes typed input, all three stay in sync.
local function RowSlider(pg, label, key, minV, maxV, step, isPct, visibleFn)
    local row = AddRow(pg, nil, visibleFn)
    row._colLabel = RowLabel(row, label)   -- measured by LayoutPage for the control column
    -- key may be a { get, set, hardMin, hardMax } table instead of a config key
    local opts = (type(key) == "table") and key or nil
    local getV = opts and opts.get or function() return Cfg(key) end
    local setV = opts and opts.set or function(v) Commit(key, v) end
    local loV  = (opts and opts.hardMin) or minV
    local hiV  = (opts and opts.hardMax) or maxV
    local s = CreateFrame("Slider", nil, row, "BackdropTemplate")
    local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    local settingUp = true
    local function fmt(v)
        v = tonumber(v) or 0
        if isPct then return ("%.0f"):format(v * 100)
        elseif step < 1 then return ("%.1f"):format(v)
        else return ("%d"):format(math.floor(v + 0.5)) end
    end
    local function clamp(v)
        if v < loV then v = loV elseif v > hiV then v = hiV end
        if step >= 1 then v = math.floor(v + 0.5) end
        return v
    end
    local function refresh()
        settingUp = true
        s:SetValue(math.max(minV, math.min(maxV, getV() or 0)))
        if not box:HasFocus() then box:SetText(fmt(getV() or 0)) end
        settingUp = false
    end
    local function setVal(v)
        setV(clamp(v))
        refresh()
    end
    local function MkArrow(glyph, delta)
        local b = CreateFrame("Button", nil, row, "BackdropTemplate")
        b:SetSize(14, 14)
        Skin(b, COL.well)
        local g = b:CreateFontString(nil, "OVERLAY")
        g:SetFont(STANDARD_TEXT_FONT, 11, "")
        g:SetPoint("CENTER", 0, 0)
        g:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        g:SetText(glyph)
        b:SetScript("OnClick", function()
            CloseDropdown()
            setVal((getV() or minV) + delta)
        end)
        b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
        b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
        return b
    end
    local plusB = MkArrow("+", step)
    box:SetSize(38, 16)
    Skin(box, COL.well)
    box:SetFont(STANDARD_TEXT_FONT, 11, "")
    box:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    box:SetJustifyH("CENTER")
    box:SetAutoFocus(false)
    local function commitTyped(self)
        local n = tonumber(self:GetText())
        if n then
            if isPct then n = n / 100 end
            setVal(n)
        else
            refresh()
        end
    end
    box:SetScript("OnEnterPressed", function(self) commitTyped(self); self:ClearFocus() end)
    box:SetScript("OnEditFocusLost", commitTyped)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local minusB = MkArrow("-", -step)
    s:SetOrientation("HORIZONTAL")
    -- The value stepper is right-anchored and the slider FILLS the gap between
    -- the label column and the stepper, so it grows with the box instead of
    -- leaving dead space to the right (and it can never clip in a narrow
    -- side-by-side box -- it just shortens).
    s:SetHeight(10)
    plusB:SetPoint("RIGHT", row, "RIGHT", -12, 0)
    box:SetPoint("RIGHT", plusB, "LEFT", -2, 0)
    minusB:SetPoint("RIGHT", box, "LEFT", -2, 0)
    s:SetPoint("LEFT", row._ctrlX, 0)
    s:SetPoint("RIGHT", minusB, "LEFT", -8, 0)
    row._colCtrl = s
    row._colFill = minusB   -- slider re-fills to the stepper when the column shifts
    Skin(s, COL.well)
    s:SetThumbTexture(WHITE)
    local th = s:GetThumbTexture()
    th:SetSize(8, 10)
    th:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetScript("OnValueChanged", function(_, v)
        if settingUp then return end
        if step >= 1 then v = math.floor(v + 0.5) end
        if not box:HasFocus() then box:SetText(fmt(v)) end
        setV(v)
    end)
    refresh()
    row._sync = refresh
    optRefreshers[#optRefreshers + 1] = refresh
    return row
end

-- THE dropdown, detached from the row. Anything that offers a choice gets this
-- widget -- including choices that are NOT a config key (a view filter, a field
-- on the selected spell). Cycle buttons were the wrong answer for those: they
-- show one option and hide the rest until you click blind, and ArcUI renders the
-- same choices as a real select.
--
-- valuesFn returns {{value, text}, ...} and is re-read on every open, so lists
-- that change (per-spell modes, the sound library) stay live. get/set are plain
-- closures, which is what frees it from the config table.
--
-- WINDOWED SCROLLING: at most 12 rows visible, mouse wheel scrolls, and it opens
-- scrolled to the current selection.
local function MakeDropdown(parent, w, valuesFn, get, set, onSelect)
    local DD_MAXROWS = 12
    w = w or 160
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, 20)
    Skin(b, COL.well)
    local vf = b:CreateFontString(nil, "OVERLAY")
    vf:SetFont(STANDARD_TEXT_FONT, 11, "")
    vf:SetPoint("LEFT", 8, 0)
    vf:SetPoint("RIGHT", -18, 0)
    vf:SetJustifyH("LEFT")
    vf:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    local arrow = b:CreateFontString(nil, "OVERLAY")
    arrow:SetFont(STANDARD_TEXT_FONT, 9, "")
    arrow:SetPoint("RIGHT", -6, -1)
    arrow:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    arrow:SetText("v")

    local offset = 0
    local list = CreateFrame("Frame", nil, optPanel, "BackdropTemplate")
    list:SetFrameLevel(optPanel:GetFrameLevel() + 30)
    list:SetWidth(w)
    Skin(list, COL.panel, COL.arcDeep)
    list:Hide()

    function b.Refresh()
        local cur = get()
        for _i, v in ipairs(valuesFn() or {}) do
            if v[1] == cur then vf:SetText(v[2]) return end
        end
        vf:SetText(cur ~= nil and tostring(cur) or "")
    end

    local items = {}
    for i = 1, DD_MAXROWS do
        local it = CreateFrame("Button", nil, list)
        it:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
        it:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
        it:SetHeight(20)
        local hl = it:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(WHITE)
        hl:SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 0.5)
        hl:SetAllPoints()
        it.fs = it:CreateFontString(nil, "OVERLAY")
        it.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        it.fs:SetPoint("LEFT", 8, 0)
        it.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        it:SetScript("OnClick", function()
            local v = (valuesFn() or {})[offset + i]
            if not v then return end
            set(v[1])
            b.Refresh()
            CloseDropdown()
            if onSelect then onSelect(v[1]) end
        end)
        items[i] = it
    end

    local function refreshList()
        local values = valuesFn() or {}
        local vis = math.min(#values, DD_MAXROWS)
        for i = 1, DD_MAXROWS do
            local v = values[offset + i]
            local show = (v ~= nil) and (i <= vis)
            items[i]:SetShown(show)
            items[i].fs:SetText(show and v[2] or "")
        end
        list:SetHeight(math.max(20, vis * 20 + 2))
    end

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #(valuesFn() or {}) - DD_MAXROWS)
        offset = offset - delta * 3
        if offset < 0 then offset = 0 elseif offset > maxOff then offset = maxOff end
        refreshList()
    end)
    b:SetScript("OnClick", function()
        if openDropdown == list then CloseDropdown() return end
        CloseDropdown()
        local values = valuesFn() or {}
        offset = 0
        for i, v in ipairs(values) do
            if v[1] == get() then
                offset = math.max(0, math.min(i - 1, #values - DD_MAXROWS))
                break
            end
        end
        refreshList()
        list:ClearAllPoints()
        list:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -1)
        list:Show()
        openDropdown = list
    end)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)
    b.Refresh()
    return b
end

-- onSelect fires after commit (e.g. previewing the picked sound).
local function RowDropdown(pg, label, key, values, visibleFn, onSelect)
    local row = AddRow(pg, nil, visibleFn)
    row._colLabel = RowLabel(row, label)   -- measured by LayoutPage for the control column
    local b = MakeDropdown(row, 160, function() return values end,
        function() return Cfg(key) end,
        function(v) Commit(key, v) end,
        onSelect)
    b:SetPoint("LEFT", row._ctrlX, 0)
    row._colCtrl = b
    row._sync = b.Refresh
    optRefreshers[#optRefreshers + 1] = b.Refresh
    return row, b
end

local function RowColor(pg, label, key)
    local row = AddRow(pg)
    row._colLabel = RowLabel(row, label)   -- measured by LayoutPage for the control column
    local sw = MakeSwatch(row)
    sw:SetPoint("LEFT", row._ctrlX, 0)
    row._colCtrl = sw
    local function refresh() sw:SetColor(Cfg(key)) end
    refresh()
    row._sync = refresh
    optRefreshers[#optRefreshers + 1] = refresh
    sw:SetScript("OnClick", function()
        CloseDropdown()
        PickColor(key, refresh)
    end)
end

-- TWO PER ROW. One control per full-width line turned every page into a long
-- vertical list with most of the width wasted. Toggles and swatches are small
-- enough to pair, so related settings sit together and the page halves in
-- height. Sliders stay full width: they need the travel.
local function RowToggle2(pg, labelA, keyA, labelB, keyB, visibleFn)
    local row = AddRow(pg, nil, visibleFn)
    local half = 0.5
    local function half_side(label, key, leftAnchor)
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12, "")
        fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        local sw = MakeSwitch(row)
        -- FIXED stops, not halves of the row. Anchoring to row CENTER meant the
        -- gap between a label and its own switch grew with the window, and on a
        -- narrow row the centre landed on top of the label.
        if leftAnchor then
            fs:SetPoint("LEFT", 12, 0)
            sw:SetPoint("LEFT", LAY.twoA, 0)
        else
            fs:SetPoint("LEFT", LAY.twoBLab, 0)
            sw:SetPoint("LEFT", LAY.twoB, 0)
        end
        fs:SetText(label)
        -- same truth test as RowToggle: a nil default must read as OFF
        local function refresh() sw:SetOn(Cfg(key) == true) end
        sw:SetScript("OnClick", function()
            CloseDropdown()
            Commit(key, not (Cfg(key) == true))
            refresh()
            PlaySound(Cfg(key) == true and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                                        or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
            LayoutPage(pg)      -- same reason as RowToggle
        end)
        refresh()
        optRefreshers[#optRefreshers + 1] = refresh
    end
    half_side(labelA, keyA, true)
    if labelB then half_side(labelB, keyB, false) end
    return row
end

local function RowColor2(pg, labelA, keyA, labelB, keyB)
    local row = AddRow(pg)
    local function half_side(label, key, leftAnchor)
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 12, "")
        fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        local sw = MakeSwatch(row)
        -- FIXED stops, not halves of the row. Anchoring to row CENTER meant the
        -- gap between a label and its own switch grew with the window, and on a
        -- narrow row the centre landed on top of the label.
        if leftAnchor then
            fs:SetPoint("LEFT", 12, 0)
            sw:SetPoint("LEFT", LAY.twoA, 0)
        else
            fs:SetPoint("LEFT", LAY.twoBLab, 0)
            sw:SetPoint("LEFT", LAY.twoB, 0)
        end
        fs:SetText(label)
        local function refresh() sw:SetColor(Cfg(key)) end
        sw:SetScript("OnClick", function() PickColor(key, refresh) end)
        refresh()
        optRefreshers[#optRefreshers + 1] = refresh
    end
    half_side(labelA, keyA, true)
    if labelB then half_side(labelB, keyB, false) end
    return row
end

local function RowButton(pg, label, onClick, visibleFn)
    local row = AddRow(pg, nil, visibleFn)
    -- width follows the TEXT: a fixed size made any long caption overflow its
    -- own box, which is what "Fix Blizzard Ping Settings (...)" was doing
    local b = MakeSmallButton(row, label, 140)
    local need = (b.fs:GetStringWidth() or 0) + 24
    b:SetWidth(math.max(140, math.min(need, 420)))
    b:SetPoint("LEFT", 12, 0)
    b:SetScript("OnClick", function() CloseDropdown(); onClick() end)
    return b
end

-- ── sample rows (preview strip + layout canvas share one renderer) ──────────

-- the sample is the LONGEST callout form ("will be ready in 0:12!"), not the
-- short "is ready!" -- users size the window against the WORST case, so the
-- long cooldown line never surprises them by not fitting

local function MakeSample(parent)
    local sm = CreateFrame("Frame", nil, parent)
    sm._isSample = true   -- centerline pins to the sample's center (stable drag space)
    sm.line = CreateFrame("Frame", nil, sm)
    sm.line:SetHeight(1)
    sm.time = sm:CreateFontString(nil, "OVERLAY")
    sm.text = sm:CreateFontString(nil, "OVERLAY")
    sm.text:SetWordWrap(false)
    sm.sender = sm:CreateFontString(nil, "OVERLAY")
    sm.icon = sm:CreateTexture(nil, "ARTWORK")
    sm.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    sm.time:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    sm.text:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    sm.sender:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    -- IDENTICAL content shape to live rows: same timestamp format and the
    -- same sender rendering path, so piece widths (and therefore the whole
    -- layout) match what the real window shows
    sm.time:SetText(date("%H:%M:%S"))
    sm.icon:Hide()  -- spell icon removed (combat-first rule)
    return sm
end

local function RenderSample(sm)
    sm.text:SetText(PreviewText(false))
    -- same sender render path as live rows -- ApplyRowLayout renders from the
    -- stored identity
    local _, playerClass = UnitClass("player")
    sm._senderClean = UnitName("player") or "Sender"
    ApplyRowLayout(sm)
end

-- ═══════════════════════════════════════════════════════════════════════════

-- Lua 5.1 gives a function only 60 UPVALUES and BuildOptionsPanel referenced
-- 66 file-level locals, so the whole addon failed to load. Bundling the row-
-- builder kit here costs the panel ONE upvalue instead of sixteen.
--
-- NOTE: `luac -p` cannot catch this. Our checker is Lua 5.4, which allows 255
-- upvalues, so the file compiles clean on the desk and only breaks in game.
local UI = {
    AddRow = AddRow,
    MakeSample = MakeSample,
    MakeSmallButton = MakeSmallButton,
    MakeSwatch = MakeSwatch,
    MakeSwitch = MakeSwitch,
    MakeCheckbox = MakeCheckbox,
    PickColor = PickColor,
    RowButton = RowButton,
    LayoutPage = LayoutPage,
    MakeDiscordButton = MakeDiscordButton,
    MakeDropdown = MakeDropdown,
    RowDesc = RowDesc,
    RowColor = RowColor,
    RowColor2 = RowColor2,
    RowDropdown = RowDropdown,
    RowLabel = RowLabel,
    RowPads = RowPads,
    RowSlider = RowSlider,
    RowTip = RowTip,
    RowToggle = RowToggle,
    RowToggle2 = RowToggle2,
    Section = Section,
    RestackPage = RestackPage,
    RowExtents = RowExtents,
}


-- Same reason as SCOPE above: one upvalue instead of twenty-four. Snapshotted
-- here, after every one is defined and before the panel that reads them.
local PKUI = {
    Apply = PKApply,
    AutoNotify = PKAutoNotify,
    AutoOn = PKAutoOn,
    BuildCatalog = PKBuildCatalog,
    Catalog = PKCatalog,
    CatalogDirty = PKCatalogDirty,
    CatalogFiltered = PKCatalogFiltered,
    EnterSelect = PKEnterSelect,
    EntryMode = PKEntryMode,
    EntryOn = PKEntryOn,
    GetCatView = PKGetCatView,
    List = PKList,
    PanelRefresh = PKPanelRefresh,
    PingKeyFor = PKPingKeyFor,
    RemoveSelected = PKRemoveSelected,
    ResolvedCount = PKResolvedCount,
    Select = PKSelect,
    Selected = PKSelected,
    SelectedID = PKSelectedID,
    SetCatSearch = PKSetCatSearch,
    SetCatView = PKSetCatView,
    SetSelectedEnabled = PKSetSelectedEnabled,
    Tracked = PKTracked,
    MatchesBar = PKEntryMatchesBar,
    PK_MAX = PK_MAX,
}

local function BuildOptionsPanel()
    if optPanel then return optPanel end
    local p = CreateFrame("Frame", "ArcPingsOptions", UIParent, "BackdropTemplate")
    optPanel = p
    -- taller than it was: Window's content now sits under a second tab strip
    -- (master toggle + buttons + sub-tabs, ~94px), and the Entry Layout canvas
    -- needs its full height or the piece editor runs off the bottom
    do
        local db = DB()
        -- 760, not 700: the Ping Keys tab with a spell selected in "every press"
        -- mode is the tallest state at ~600px, and 700 left it hanging off the
        -- bottom edge. The minimum below is raised for the same reason.
        p:SetSize(tonumber(db.panelW) or 520, tonumber(db.panelH) or 760)
    end
    p:SetPoint("CENTER", 0, 40)
    p:SetFrameStrata("DIALOG")
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)
    p:SetScript("OnMouseDown", CloseDropdown)
    p:SetScript("OnHide", CloseDropdown)
    Skin(p, COL.bg, COL.line2)   -- SOLID: 0.97 reads washed out

    -- RESIZABLE. Everything inside anchors to the panel edges or to a row's
    -- centre, so widening genuinely gives the content more room instead of
    -- leaving it stranded at the left. Size is remembered per account.
    p:SetResizable(true)
    if p.SetResizeBounds then p:SetResizeBounds(500, 660, 1100, 1000) end
    -- assigned once the ping-key grid exists (declared far below); the grid packs
    -- itself to the panel width, so it has to be re-flowed after a resize
    local pkOnResize
    local grip = CreateFrame("Button", nil, p)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:EnableMouse(true)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture([[Interface\ChatFrame\UI-ChatIM-SizeGrabber-Up]])
    gripTex:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8)
    grip:SetScript("OnEnter", function() gripTex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1) end)
    grip:SetScript("OnLeave", function() gripTex:SetVertexColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.8) end)
    grip:SetScript("OnMouseDown", function()
        CloseDropdown()
        -- The panel is CENTER-anchored. StartSizing from a single CENTER anchor
        -- grows it symmetrically -- the whole window lurches/jumps as you drag
        -- the corner. Pin the CURRENT top-left first so BOTTOMRIGHT sizing keeps
        -- that corner put and only the dragged corner moves.
        local l, t = p:GetLeft(), p:GetTop()
        if l and t then
            p:ClearAllPoints()
            p:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
        end
        p:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        p:StopMovingOrSizing()
        local db = DB()
        db.panelW, db.panelH = math.floor(p:GetWidth() + 0.5), math.floor(p:GetHeight() + 0.5)
        if pkOnResize then pkOnResize() end
        if RefreshPreview then RefreshPreview() end
    end)

    -- ── title bar ────────────────────────────────────────────────────────────
    local bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(30)
    Skin(bar, COL.panel)
    local t1 = bar:CreateFontString(nil, "OVERLAY")
    t1:SetFont(STANDARD_TEXT_FONT, 14, "")
    t1:SetPoint("LEFT", 12, 0)
    t1:SetText("|cff3fc9f2Arc|r|cffd5e2f2 Pings|r")
    local ver = bar:CreateFontString(nil, "OVERLAY")
    ver:SetFont(STANDARD_TEXT_FONT, 10, "")
    ver:SetPoint("LEFT", t1, "RIGHT", 8, -1)
    ver:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    ver:SetText(C_AddOns and C_AddOns.GetAddOnMetadata and (C_AddOns.GetAddOnMetadata(ADDON, "Version") or "") or "")
    local close = CreateFrame("Button", nil, bar)
    close:SetSize(24, 24)
    close:SetPoint("RIGHT", -4, 0)
    local cx = close:CreateFontString(nil, "OVERLAY")
    cx:SetFont(STANDARD_TEXT_FONT, 14, "")
    cx:SetPoint("CENTER")
    cx:SetText("x")
    cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    close:SetScript("OnEnter", function() cx:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3]) end)
    close:SetScript("OnLeave", function() cx:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3]) end)
    close:SetScript("OnClick", function() p:Hide() end)

    -- (live preview strip removed -- the Layout tab's canvas is the preview;
    -- this invisible line is just the anchor the tabs/pages hang from)
    -- ── EDITING SCOPE ────────────────────────────────────────────────────────
    -- Built with the SAME kit as everything else: a skinned well, the panel's
    -- own label/dim colours, and UI.MakeSmallButton. The first pass hung raw
    -- FontStrings straight on the panel, so it sat on a different background
    -- with different spacing and read as a foreign lump above the tabs.
    --
    -- Above the tabs because it decides where EVERY tab's edits land. It is not
    -- a switch that relocates the config: it says where the NEXT thing you
    -- change is kept, setting by setting.
    local scopeBar = CreateFrame("Frame", nil, p, "BackdropTemplate")
    scopeBar:SetPoint("TOPLEFT", 10, -32)
    scopeBar:SetPoint("TOPRIGHT", -10, -32)
    scopeBar:SetHeight(48)
    Skin(scopeBar, COL.panel)

    local scopeLbl = scopeBar:CreateFontString(nil, "OVERLAY")
    scopeLbl:SetFont(STANDARD_TEXT_FONT, 12, "")
    scopeLbl:SetPoint("TOPLEFT", 12, -7)
    scopeLbl:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    scopeLbl:SetText("Changes apply to")

    local scopeReset = UI.MakeSmallButton(scopeBar, "Reset This Scope", 120)
    scopeReset:SetHeight(18)
    scopeReset:SetPoint("TOPRIGHT", -10, -8)

    -- a real dropdown, like every other choice in this panel. It was a button
    -- that cycled, which hides the options until you have clicked past them.
    local scopeBtn = CreateFrame("Button", nil, scopeBar, "BackdropTemplate")
    scopeBtn:SetSize(180, 20)
    scopeBtn:SetPoint("LEFT", scopeLbl, "RIGHT", 10, 0)
    scopeBtn:SetPoint("TOP", scopeBar, "TOP", 0, -6)
    Skin(scopeBtn, COL.well)
    scopeBtn.fs = scopeBtn:CreateFontString(nil, "OVERLAY")
    scopeBtn.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
    scopeBtn.fs:SetPoint("LEFT", 8, 0)
    scopeBtn.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    local scopeArrow = scopeBtn:CreateFontString(nil, "OVERLAY")
    scopeArrow:SetFont(STANDARD_TEXT_FONT, 9, "")
    scopeArrow:SetPoint("RIGHT", -6, -1)
    scopeArrow:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    scopeArrow:SetText("v")
    scopeBtn:SetScript("OnEnter", function(b) b:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1) end)
    scopeBtn:SetScript("OnLeave", function(b) b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1) end)

    local scopeList = CreateFrame("Frame", nil, p, "BackdropTemplate")
    scopeList:SetFrameLevel(p:GetFrameLevel() + 30)
    scopeList:SetWidth(180)
    Skin(scopeList, COL.panel, COL.arcDeep)
    local scopeItems = {}
    for i = 1, 3 do
        local it = CreateFrame("Button", nil, scopeList)
        it:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 20)
        it:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * 20)
        it:SetHeight(20)
        local hl = it:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(WHITE)
        hl:SetVertexColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 0.5)
        hl:SetAllPoints()
        it.fs = it:CreateFontString(nil, "OVERLAY")
        it.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        it.fs:SetPoint("LEFT", 8, 0)
        it.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
        scopeItems[i] = it
    end
    scopeList:Hide()

    local scopeInfo = scopeBar:CreateFontString(nil, "OVERLAY")
    scopeInfo:SetFont(STANDARD_TEXT_FONT, 11, "")
    scopeInfo:SetPoint("BOTTOMLEFT", scopeBar, "BOTTOMLEFT", 12, 6)
    scopeInfo:SetPoint("BOTTOMRIGHT", scopeBar, "BOTTOMRIGHT", -12, 6)
    scopeInfo:SetJustifyH("LEFT")
    scopeInfo:SetWordWrap(false)

    local function ScopeLabel(sc)
        if sc == SCOPE.CHAR then return "Only " .. (UnitName("player") or "This Character") end
        if sc == SCOPE.SPEC then
            local i = GetSpecialization and GetSpecialization()
            local _id, nm = i and GetSpecializationInfo(i)
            return "Only " .. (nm or "This Spec")
        end
        return "All My Characters"
    end
    local function ScopeRefresh()
        local sc = SCOPE.Active()
        scopeBtn.fs:SetText(ScopeLabel(sc))
        local t, n = SCOPE.Ov(sc, false), 0
        if t then for _k in pairs(t) do n = n + 1 end end
        if sc == SCOPE.ACCOUNT then
            scopeInfo:SetText("|cff8298b4Shared by everyone.|r")
        elseif n == 0 then
            scopeInfo:SetText("|cff8298b4Following the account - change anything to break out.|r")
        else
            scopeInfo:SetText(("|cff33ff99%d overridden.|r |cff8298b4Rest follow the account.|r"):format(n))
        end
        scopeReset:SetShown(sc ~= SCOPE.ACCOUNT and n > 0)
    end
    scopeBtn:SetScript("OnClick", function()
        if openDropdown == scopeList then CloseDropdown() return end
        CloseDropdown()
        -- the spec entry is omitted when the client cannot name one
        local order = { SCOPE.ACCOUNT, SCOPE.CHAR }
        if SCOPE.SpecKey() then order[#order + 1] = SCOPE.SPEC end
        for i, it in ipairs(scopeItems) do
            local sc = order[i]
            it:SetShown(sc ~= nil)
            if sc then
                it.fs:SetText(ScopeLabel(sc))
                it:SetScript("OnClick", function()
                    CloseDropdown()
                    SCOPE.Char().pkEditScope = (sc ~= SCOPE.ACCOUNT) and sc or nil
                    ApplyAll()
                    if PKUI.PanelRefresh then PKUI.PanelRefresh() end
                end)
            end
        end
        scopeList:SetHeight(#order * 20 + 2)
        scopeList:ClearAllPoints()
        scopeList:SetPoint("TOPLEFT", scopeBtn, "BOTTOMLEFT", 0, -1)
        scopeList:Show()
        openDropdown = scopeList
    end)
    scopeReset:SetScript("OnClick", function()
        CloseDropdown()
        local db, k = DB(), SCOPE.Key(SCOPE.Active())
        if db._ov and k then db._ov[k] = nil end
        ApplyAll()
        if PKUI.PanelRefresh then PKUI.PanelRefresh() end
    end)
    optRefreshers[#optRefreshers + 1] = ScopeRefresh

    local strip = CreateFrame("Frame", nil, p)
    strip:SetPoint("TOPLEFT", 10, -86)
    strip:SetPoint("TOPRIGHT", -10, -86)
    strip:SetHeight(1)

    -- ── tabs ─────────────────────────────────────────────────────────────────
    local pages, tabBtns = {}, {}
    local activeTab
    local function SelectTab(name)
        CloseDropdown()
        activeTab = name
        for n, pg in pairs(pages) do
            (pg._hostFrame or pg):SetShown(n == name)
            if n == name and pg.Refresh then pg:Refresh() end
        end
        for n, tb in pairs(tabBtns) do
            if n == name then
                Skin(tb, COL.panel, COL.arc)
                tb.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
            else
                Skin(tb, COL.well, COL.line)
                tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end
    end
    -- THREE tabs. Entries and Layout used to be top-level, but they are both
    -- about the feed window, so they became sub-panels of Window instead.
    -- CHIP TABS on a continuous cyan line. Underlines were the old look: a chip
    -- is a physical object (selected = panel fill + arc border + arc text,
    -- unselected = well + line + dim), and the cyan hairline underneath is what
    -- makes the selected chip read as attached to the page.
    local TABS = { "Ping Keys", "Window", "Alerts" }
    local chipX = 0
    for _i, name in ipairs(TABS) do
        local tb = CreateFrame("Button", nil, p, "BackdropTemplate")
        tb:SetHeight(24)
        tb.fs = tb:CreateFontString(nil, "OVERLAY")
        tb.fs:SetFont(STANDARD_TEXT_FONT, 12, "")
        tb.fs:SetPoint("CENTER")
        tb.fs:SetText(name)
        tb:SetWidth(math.max(90, tb.fs:GetStringWidth() + 22))
        tb:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", chipX, -4)
        chipX = chipX + tb:GetWidth() + 3
        Skin(tb, COL.well, COL.line)
        tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        tb:SetScript("OnClick", function() CloseDropdown(); SelectTab(name) end)
        tb:SetScript("OnEnter", function()
            if activeTab ~= name then
                tb:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                tb.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            end
        end)
        tb:SetScript("OnLeave", function()
            if activeTab ~= name then
                tb:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end)
        tabBtns[name] = tb
    end
    local tabLine = p:CreateTexture(nil, "ARTWORK")
    tabLine:SetTexture(WHITE)
    tabLine:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)   -- CYAN, continuous
    tabLine:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -28)
    tabLine:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, -28)
    tabLine:SetHeight(1)

    -- No backdrop on a page any more: the SECTION BOXES are the surface, and a
    -- panel-filled page behind them just muddied the contrast. 40 at the bottom
    -- reserves the Discord footer band.
    -- -34 clears the CHIP ROW, not just the strip. The chips run from -4 to -28
    -- below the strip and the cyan line sits at -28, so a page anchored at -12
    -- started INSIDE the tabs and drew its first section title over them.
    -- A page is a SCROLL CHILD, not a plain frame. Sections used to flow straight
    -- off the bottom edge of the panel with no way to reach them (the Edit Piece
    -- box was the worst offender). Now anything past the bottom scrolls, with a
    -- thumb on the right that only appears when there is something to scroll to.
    --
    -- The scroll child MUST be given an explicit width -- it is the one place a
    -- width has to be set -- so it is driven off the host's OnSizeChanged, which
    -- fires once the anchors actually resolve rather than being read too early.
    local function ScrollHost(parent, topAnchor, topOffset)
        local host = CreateFrame("ScrollFrame", nil, parent)
        if topAnchor then
            host:SetPoint("TOPLEFT", topAnchor, "BOTTOMLEFT", 0, topOffset)
            host:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -10, 40)
        end
        local pg = CreateFrame("Frame", nil, host)
        pg:SetSize(1, 1)
        host:SetScrollChild(pg)

        local track = CreateFrame("Frame", nil, host, "BackdropTemplate")
        track:SetWidth(4)
        track:SetPoint("TOPRIGHT", host, "TOPRIGHT", 2, 0)
        track:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 2, 0)
        Skin(track, COL.well, COL.well)
        local thumb = track:CreateTexture(nil, "OVERLAY")
        thumb:SetTexture(WHITE)
        thumb:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.85)
        thumb:SetPoint("TOPLEFT", 0, 0)
        thumb:SetPoint("TOPRIGHT", 0, 0)
        track:Hide()

        function pg:UpdateScroll()
            local viewH = host:GetHeight() or 0
            local contentH = pg._contentH or 0
            local over = contentH - viewH
            if over <= 1 or viewH <= 0 then
                host:SetVerticalScroll(0)
                track:Hide()
                return
            end
            track:Show()
            local cur = math.min(host:GetVerticalScroll() or 0, over)
            if cur < 0 then cur = 0 end
            host:SetVerticalScroll(cur)
            local thumbH = math.max(20, viewH * (viewH / contentH))
            thumb:SetHeight(thumbH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPLEFT", 0, -(viewH - thumbH) * (cur / over))
            thumb:SetPoint("TOPRIGHT", 0, -(viewH - thumbH) * (cur / over))
        end

        host:EnableMouseWheel(true)
        host:SetScript("OnMouseWheel", function(_, delta)
            local viewH = host:GetHeight() or 0
            local over = (pg._contentH or 0) - viewH
            if over <= 0 then return end
            local cur = (host:GetVerticalScroll() or 0) - delta * 40
            if cur < 0 then cur = 0 elseif cur > over then cur = over end
            host:SetVerticalScroll(cur)
            pg:UpdateScroll()
            CloseDropdown()
        end)
        -- A HIDDEN frame never fires OnSizeChanged, and when it is finally shown
        -- its size usually already matches, so no change event ever arrives. Every
        -- page except the one visible at build time therefore kept a 1px-wide
        -- scroll child: section boxes rendered as hairlines, rows piled up on the
        -- left, and a page could look completely empty. So the width is SYNCED
        -- explicitly on show and on every refresh, and the event is only a bonus.
        local function SyncWidth()
            local w = host:GetWidth() or 0
            if w > 1 and math.abs((pg:GetWidth() or 0) - w) > 0.5 then
                pg:SetWidth(w)
                if pg._onWidth then pg._onWidth() end
                return true
            end
            return false
        end
        pg.SyncWidth = SyncWidth
        host:SetScript("OnSizeChanged", function()
            SyncWidth()
            pg:UpdateScroll()
        end)
        host:SetScript("OnShow", function()
            SyncWidth()
            UI.LayoutPage(pg)
            pg:UpdateScroll()
        end)

        pg._rows, pg._sections, pg._curSection = {}, {}, nil
        function pg:Refresh()
            SyncWidth()
            UI.LayoutPage(self)
            self:UpdateScroll()
        end
        pg._host = host
        return pg, host
    end

    local function Page(name, plain)
        local pg, host
        if plain then
            pg = CreateFrame("Frame", nil, p)
            pg:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -34)
            pg:SetPoint("BOTTOMRIGHT", -10, 40)
            pg._rows, pg._sections, pg._curSection = {}, {}, nil
            function pg:Refresh() UI.LayoutPage(self) end
            host = pg
        else
            pg, host = ScrollHost(p, strip, -34)
        end
        host:Hide()
        pg._hostFrame = host
        pages[name] = pg
        return pg
    end
    local pgAlerts  = Page("Alerts")
    local pgPingKey = Page("Ping Keys")

    -- ── WINDOW: a container with its OWN tab strip ───────────────────────────
    -- The master toggle and the two whole-feed buttons sit on the container,
    -- above the sub-tabs, because they govern all three sub-panels.
    local pgWinTab = Page("Window", true)
    local feedBox = UI.Section(pgWinTab, "Feed")
    -- With the Blizzard CVars off the game sends addons nothing and the feed sits
    -- empty forever. That was a single chat line at login, so anyone who scrolled
    -- past it had no way to find out. Now it is a red row here, and the fix button
    -- only exists while there is something to fix.
    local function BlizzPingsOff() return not BlizzPingSettingsOK() end
    do
        local row = UI.AddRow(pgWinTab, 32, BlizzPingsOff)
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        fs:SetPoint("LEFT", 12, 0); fs:SetPoint("RIGHT", -12, 0)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(1, 0.33, 0.33)
        fs:SetText("WoW's own \"Enable Pings\" or \"Show Pings in Chat\" is turned OFF, so the game sends addons nothing and this feed will stay empty.")
    end
    UI.RowButton(pgWinTab, "Fix Blizzard Ping Settings", function()
        FixBlizzPingSettings()
        print("|cff33ff99Arc Pings|r: Blizzard \"Enable Pings\" + \"Show Pings in Chat\" turned ON.")
    end, BlizzPingsOff)
    UI.RowToggle(pgWinTab, "Enable Feed Window", "enabled")
    do
        local row = UI.AddRow(pgWinTab)
        local test = UI.MakeSmallButton(row, "Show Test Ping", 130)
        test:SetPoint("LEFT", 12, 0)
        test:SetScript("OnClick", function() AddEntry(PreviewText(true), UnitName("player")) end)
        local reset = UI.MakeSmallButton(row, "Reset Whole Layout", 150)
        reset:SetPoint("LEFT", test, "RIGHT", 10, 0)
        reset:SetScript("OnClick", function()
            CloseDropdown()
            -- eighteen layout keys go at once, so ASK first
            StaticPopup_Show("ARCPINGFEED_RESET_LAYOUT")
        end)
    end

    -- the sub-page hosts anchor to feedBox's BOTTOM, which does not exist until
    -- the page has been flowed once
    UI.LayoutPage(pgWinTab)

    local subPages, subBtns, activeSub = {}, {}, nil
    local function SelectSub(name)
        CloseDropdown()
        activeSub = name
        for n, sp in pairs(subPages) do
            (sp._hostFrame or sp):SetShown(n == name)
            if n == name then sp:Refresh() end
        end
        for n, tb in pairs(subBtns) do
            local on = (n == name)
            if on then
                Skin(tb, COL.panel, COL.arc)
                tb.fs:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
            else
                Skin(tb, COL.well, COL.line)
                tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end
    end
    local SUBS = { "Window Layout", "Entry Layout", "Entries Behavior" }
    local subX = 8
    for _i, name in ipairs(SUBS) do
        local tb = CreateFrame("Button", nil, pgWinTab, "BackdropTemplate")
        tb:SetHeight(22)
        tb.fs = tb:CreateFontString(nil, "OVERLAY")
        tb.fs:SetFont(STANDARD_TEXT_FONT, 11, "")
        tb.fs:SetPoint("CENTER")
        tb.fs:SetText(name)
        tb:SetWidth(math.max(80, tb.fs:GetStringWidth() + 20))
        tb:SetPoint("TOPLEFT", feedBox, "BOTTOMLEFT", subX, -14)
        subX = subX + tb:GetWidth() + 3
        Skin(tb, COL.well, COL.line)
        tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
        tb:SetScript("OnClick", function() CloseDropdown(); SelectSub(name) end)
        tb:SetScript("OnEnter", function()
            if activeSub ~= name then
                tb:SetBackdropBorderColor(COL.arcDeep[1], COL.arcDeep[2], COL.arcDeep[3], 1)
                tb.fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
            end
        end)
        tb:SetScript("OnLeave", function()
            if activeSub ~= name then
                tb:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                tb.fs:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
            end
        end)
        subBtns[name] = tb
    end
    local subLine = pgWinTab:CreateTexture(nil, "ARTWORK")
    subLine:SetTexture(WHITE)
    subLine:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
    subLine:SetPoint("TOPLEFT", feedBox, "BOTTOMLEFT", 8, -38)
    subLine:SetPoint("TOPRIGHT", feedBox, "BOTTOMRIGHT", -8, -38)
    subLine:SetHeight(1)

    -- A sub-page is just a page with its own cursor, so every row builder and
    -- the layout canvas work on it unchanged.
    local function SubPage(name)
        local sp, host = ScrollHost(pgWinTab)
        host:SetPoint("TOPLEFT", feedBox, "BOTTOMLEFT", 0, -42)
        host:SetPoint("BOTTOMRIGHT", pgWinTab, "BOTTOMRIGHT", -10, 4)
        host:Hide()
        sp._hostFrame = host
        subPages[name] = sp
        return sp
    end
    local pgWindow  = SubPage("Window Layout")
    local pgLayout  = SubPage("Entry Layout")
    local pgEntries = SubPage("Entries Behavior")
    SelectSub("Window Layout")

    -- ── WINDOW tab ───────────────────────────────────────────────────────────
    -- Position and Size are SLIDER-ONLY boxes with a tight control column (the
    -- 5th Section arg) so the slider hugs the short X / Y / Width labels instead
    -- of sitting out at the toggle column. pgWindow._onWidth (built below) floats
    -- them side by side once the panel is wide enough, and stacks them otherwise.
    UI.Section(pgWindow, "Position", nil, nil, 24)
    local secPos = pgWindow._sections[#pgWindow._sections]
    -- Typed coordinates, for placing the feed exactly or matching another
    -- character without dragging. Slider travel covers a 1080p half-screen; the
    -- typed box reaches a 4K ultrawide.
    UI.RowTip(UI.RowSlider(pgWindow, "X", {
            get = function() local p = Cfg("pos"); return (p and p[1]) or 0 end,
            set = function(v) SetWindowPos(v, nil) end,
            hardMin = -2000, hardMax = 2000,
        }, -960, 960, 1),
        "Horizontal offset from the centre of the screen. Negative is left.")
    UI.RowTip(UI.RowSlider(pgWindow, "Y", {
            get = function()
                local p = Cfg("pos")
                if not p then return 0 end
                local top = Cfg("newestOnTop") ~= false
                return (top and p.top) or (not top and p.bottom) or p[2] or 0
            end,
            set = function(v) SetWindowPos(nil, v) end,
            hardMin = -2000, hardMax = 2000,
        }, -540, 540, 1),
        "Vertical offset from the centre of the screen. Negative is down. This is the edge the window grows away from, so it stays put as entries come and go.")

    UI.Section(pgWindow, "Size", nil, nil, 52)
    local secSize = pgWindow._sections[#pgWindow._sections]
    UI.RowTip(UI.RowSlider(pgWindow, "Width", "width", 160, 900, 10),
        "The window widens past this for a long callout and returns afterwards, so nothing is ever cut off.")
    UI.RowTip(UI.RowSlider(pgWindow, "Height", "height", 0, 800, 10),
        "0 = automatic: the window hugs its entries. Set a value to keep it at least this tall.")
    UI.RowSlider(pgWindow, "Scale", "windowScale", 0.5, 2, 0.05, true)

    -- one column (Arc's call): every toggle lines up under the same control
    -- column via LayoutPage's auto-column, so nothing sits stranded out right
    UI.Section(pgWindow, "Behavior")
    UI.RowTip(UI.RowToggle(pgWindow, "Lock Window Position", "locked"),
        "Locks the window so it can't be dragged. While this options panel is open you can still drag it if Drag While Options Open is on.")
    UI.RowTip(UI.RowToggle(pgWindow, "Drag While Options Open", "panelDrag"),
        "While this options panel is open, let the window be dragged into place even when its position is locked. Turn off to respect the lock at all times.")
    UI.RowTip(UI.RowToggle(pgWindow, "Show Title While Unlocked", "showTitle"),
        "The \"Arc Pings\" label floating above the window while it is unlocked or this options panel is open. It sits outside the window and never touches the entries.")
    UI.RowToggle(pgWindow, "Static Window Size", "staticSize")
    UI.RowToggle(pgWindow, "Show Minimap Button", "showMinimap")
    UI.RowDropdown(pgWindow, "Window Layer", "strata", { { "BACKGROUND", "Background" }, { "LOW", "Low" }, { "MEDIUM", "Medium" }, { "HIGH", "High" }, { "DIALOG", "Dialog" } })
    UI.RowButton(pgWindow, "Fix Blizzard Ping Settings", function()
        FixBlizzPingSettings()
        print("|cff33ff99Arc Pings|r: Blizzard \"Enable Pings\" + \"Show Pings in Chat\" turned ON.")
    end)
    -- WHERE the feed is allowed to appear. Switching a content type off stops
    -- the window AND stops listening for pings there, so nothing piles up out
    -- of sight. Instance type only changes across a loading screen, so this
    -- needs nothing from combat.
    UI.Section(pgWindow, "Show In")
    UI.RowTip(UI.RowToggle(pgWindow, "Open World", "showInWorld"),
        "Anywhere that is not an instance, including your garrison and war mode.")
    UI.RowTip(UI.RowToggle(pgWindow, "Dungeons", "showInDungeon"),
        "Normal, Heroic and Mythic 0 dungeons. Mythic Plus has its own switch below.")
    UI.RowToggle(pgWindow, "Mythic Plus", "showInMythicPlus")
    UI.RowToggle(pgWindow, "Raids", "showInRaid")
    UI.RowToggle(pgWindow, "Battlegrounds", "showInBattleground")
    UI.RowToggle(pgWindow, "Arenas", "showInArena")
    UI.RowTip(UI.RowToggle(pgWindow, "Scenarios and Delves", "showInScenario"),
        "Scenarios, delves and follower dungeons.")

    UI.Section(pgWindow, "Backdrop")
    UI.RowTip(UI.RowToggle2(pgWindow, "Show Background", "showBackground",
                                      "Show Border", "showBorder"),
        "The border always shows while the window is unlocked, as a placement aid.")
    UI.RowColor2(pgWindow, "Background Color", "colBg",
                           "Border Color", "colBorder")
    UI.RowSlider(pgWindow, "Background Opacity", "bgAlpha", 0, 1, 0.05, true,
        function() return Cfg("showBackground") == true end)

    -- Position + Size ride side by side once the page is wide enough for both
    -- slider boxes, and stack full-width below that. Only the section side flips
    -- (each box keeps its tight ctrlX), so the sliders hug their labels either
    -- way. Fires on show and on every resize via the scroll host's SyncWidth.
    pgWindow._onWidth = function()
        local wide = (pgWindow:GetWidth() or 0) >= 540
        secPos.side  = wide and "L" or nil
        secSize.side = wide and "R" or nil
        UI.LayoutPage(pgWindow)
    end

    -- ── ENTRIES tab ──────────────────────────────────────────────────────────
    -- font settings belong with the layout: they shape the LINE, not how the
    -- feed behaves. Added down where the Entry Layout page builds its rows.
    UI.Section(pgEntries, "Behavior")
    UI.RowSlider(pgEntries, "Max Entries Shown", "maxEntries", 1, 20, 1)
    UI.RowTip(UI.RowSlider(pgEntries, "Top Padding", "rowPadTop", 0, 40, 1),
        "Same as the top band on the Layout Designer canvas -- moving one moves the other.")
    UI.RowTip(UI.RowSlider(pgEntries, "Bottom Padding", "rowPadBottom", 0, 40, 1),
        "Same as the bottom band on the Layout Designer canvas -- moving one moves the other.")
    UI.RowTip(UI.RowSlider(pgEntries, "Entry Duration (seconds)", "entrySeconds", 0, 60, 1),
        "0 = stay until pushed out by newer pings.")
    UI.RowToggle(pgEntries, "Newest Entries On Top", "newestOnTop")
    UI.Section(pgEntries, "Animations")
    UI.RowDropdown(pgEntries, "New Ping Animation", "animStyle", { { "none", "None" }, { "fade", "Fade In" }, { "pulse", "Pulse" }, { "flash", "Flash" }, { "zoom", "Zoom (pop in)" } })
    UI.RowSlider(pgEntries, "Entrance Duration (seconds)", "animInSecs", 0.1, 2, 0.1, nil,
        function() return Cfg("animStyle") ~= "none" end)
    UI.RowDropdown(pgEntries, "Expire Animation", "animOutStyle", { { "none", "None (snap off)" }, { "fade", "Fade Out" } })
    UI.RowSlider(pgEntries, "Fade Out Duration (seconds)", "animOutSecs", 0.1, 3, 0.1, nil,
        function() return Cfg("animOutStyle") == "fade" end)

    -- ── ALERTS tab ───────────────────────────────────────────────────────────
    UI.Section(pgAlerts, "Alerts")
    UI.RowToggle(pgAlerts, "Enable Ping Alerts", "alertsEnabled")
    -- full sound library: builtins + ArcUI's 36-sound pack (when installed) +
    -- every LibSharedMedia sound; clicking an entry PREVIEWS it
    local soundValues = {}
    for _i, n in ipairs(BuildSoundList()) do soundValues[#soundValues + 1] = { n, n } end
    -- all three fall away with the master toggle, as they do in ArcUI. They used
    -- to stay live, so a sound could be picked and previewed that would never
    -- actually play.
    local function AlertsOn() return Cfg("alertsEnabled") == true end
    UI.RowDropdown(pgAlerts, "Alert Sound", "alertSound", soundValues, AlertsOn, function(name)
        local f = ResolveSound(name)
        if f then PlaySoundFile(f, "Master") end
    end)
    UI.RowSlider(pgAlerts, "Alert Throttle (seconds)", "alertThrottle", 0, 10, 0.5, nil, AlertsOn)
    UI.RowButton(pgAlerts, "Test Alert", function()
        local f = ResolveSound(Cfg("alertSound"))
        if f then PlaySoundFile(f, "Master") end
    end, AlertsOn)

    -- ═════════════════════════════════════════════════════════════════════════
    -- PING KEYS tab
    -- ═════════════════════════════════════════════════════════════════════════
    -- one modal key-catcher shared by the ping key and every per-spell override
    local pkCatch = CreateFrame("Frame", nil, p, "BackdropTemplate")
    pkCatch:SetPoint("CENTER")
    pkCatch:SetSize(260, 70)
    pkCatch:SetFrameStrata("FULLSCREEN_DIALOG")
    Skin(pkCatch, COL.panel, COL.arcDeep)
    pkCatch:EnableMouse(true)
    pkCatch:EnableKeyboard(true)
    pkCatch:SetPropagateKeyboardInput(false)
    local pkCatchFS = pkCatch:CreateFontString(nil, "OVERLAY")
    pkCatchFS:SetFont(STANDARD_TEXT_FONT, 12, "")
    pkCatchFS:SetPoint("CENTER")
    pkCatchFS:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    pkCatch:Hide()

    local function PKModPrefix()
        local s = ""
        if IsAltKeyDown() then s = s .. "ALT-" end
        if IsControlKeyDown() then s = s .. "CTRL-" end
        if IsShiftKeyDown() then s = s .. "SHIFT-" end
        return s
    end
    -- bare modifier presses are never a binding on their own
    local PK_MODKEYS = {
        LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
        LALT = true, RALT = true, UNKNOWN = true,
    }
    local pkCatchDone
    local function PKCapture(prompt, onDone)
        CloseDropdown()
        pkCatchDone = onDone
        pkCatchFS:SetText(prompt .. "\n|cff8298b4press a key, or ESC to cancel|r")
        pkCatch:Show()
    end
    local function PKCatchFinish(key)
        pkCatch:Hide()
        local fn = pkCatchDone
        pkCatchDone = nil
        if fn then fn(key) end
    end
    pkCatch:SetScript("OnKeyDown", function(_, key)
        if key == "ESCAPE" then PKCatchFinish(nil) return end
        if PK_MODKEYS[key] then return end
        PKCatchFinish(PKModPrefix() .. key)
    end)
    pkCatch:SetScript("OnMouseDown", function(_, button)
        local map = { LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
                      Button4 = "BUTTON4", Button5 = "BUTTON5" }
        local k = map[button] or button:upper()
        PKCatchFinish(PKModPrefix() .. k)
    end)

    -- The intro sits ABOVE the first box, not inside it: it describes the tab,
    -- not the controls in that one section. Pre-section rows are flowed first by
    -- UI.LayoutPage, so adding it before any Section() puts it at the top.
    local pkHint = UI.AddRow(pgPingKey, 34)
    local pkHintFS = pkHint:CreateFontString(nil, "OVERLAY")
    pkHintFS:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkHintFS:SetPoint("LEFT", 6, 0)
    pkHintFS:SetPoint("RIGHT", -6, 0)
    pkHintFS:SetJustifyH("LEFT")
    pkHintFS:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pkHintFS:SetText("Ping your cooldowns to the group without editing a macro. Pick your spells, then choose per spell whether it pings on the ping key or on every cast.")

    -- TWO BOXES, SIDE BY SIDE. Ping Key is the held-key system; Auto-Ping is a
    -- separate system with its own on/off and its own key. Stacking them made
    -- Auto-Ping read as a sub-option of the ping key, and cost a whole band of
    -- height the tab did not have. Every explanation here is a TOOLTIP: as rows
    -- they pushed the tab off the bottom of the panel.
    UI.Section(pgPingKey, "Ping Key", nil, "L")
    UI.RowTip(UI.RowToggle(pgPingKey, "Enable Ping Keys", "pkEnabled", function(on)
            if PKUI.Apply then PKUI.Apply() end
            if on then PKUI.CatalogDirty(); PKUI.BuildCatalog() end
            if PKPanelRefresh then PKPanelRefresh() end
        end),
        "Arms the ping key. Nothing is rebound until this is on.")
    UI.RowTip(UI.RowToggle(pgPingKey, "Only Selected Spells", "pkOnlySelected"),
        "By default the ping key works on EVERY spell you have bound. Turn this on to restrict it to the spells you pick below. Spells you pick keep their own settings either way.")

    local pkKeyRow = UI.AddRow(pgPingKey)
    UI.RowLabel(pkKeyRow, "Ping Key")
    local pkKeyBtn = UI.MakeSmallButton(pkKeyRow, "", 100)
    pkKeyBtn:SetPoint("LEFT", LAY.halfBtn, 0)
    UI.RowTip(pkKeyRow,
        "Hold this and press a spell's normal key to ping it instead of casting it. Individual spells can override it with a ping key of their own.")

    UI.Section(pgPingKey, "Auto-Ping", nil, "R")
    local pkAutoRow = UI.AddRow(pgPingKey)
    UI.RowLabel(pkAutoRow, "Ping Without Holding")
    local pkAutoSw = UI.MakeSwitch(pkAutoRow)
    pkAutoSw:SetPoint("LEFT", pkAutoRow._ctrlX, 0)
    UI.RowTip(pkAutoRow,
        "Master switch for every spell set to \"Every time I press its key\". Spells on their own key ignore it.")

    local pkAutoKeyRow = UI.AddRow(pgPingKey)
    UI.RowLabel(pkAutoKeyRow, "Toggle Key")
    local pkAutoKeyBtn = UI.MakeSmallButton(pkAutoKeyRow, "", 100)
    pkAutoKeyBtn:SetPoint("LEFT", LAY.halfBtn, 0)
    UI.RowTip(pkAutoKeyRow,
        "Flips Auto-Ping mid-fight, and the switch above follows along. This is the one ping-key control that works in combat.")

    -- Untitled full-width strip under the pair. The status sentences run to a
    -- hundred characters, which no half box can hold on one line.
    UI.Section(pgPingKey, "")
    local pkStatus = UI.AddRow(pgPingKey, 22)
    local pkStatusFS = pkStatus:CreateFontString(nil, "OVERLAY")
    pkStatusFS:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkStatusFS:SetPoint("LEFT", 12, 0)
    pkStatusFS:SetPoint("RIGHT", -12, 0)
    pkStatusFS:SetJustifyH("LEFT")

    local function PKKeyRowRefresh()
        local k = Cfg("pkKey")
        pkKeyBtn.fs:SetText((k and k ~= "") and k or "click to set")
        pkAutoSw:SetOn(PKUI.AutoOn())
        local tk = Cfg("pkToggleKey")
        pkAutoKeyBtn.fs:SetText((tk and tk ~= "") and ("Toggle: " .. tk) or "set toggle key")
    end
    pkAutoSw:SetScript("OnClick", function()
        local on = not PKUI.AutoOn()
        SCOPE.Char().pkAutoOn = on
        PKUI.AutoNotify(on)
        if PKUI.Apply then PKUI.Apply() end
        PKKeyRowRefresh()
    end)
    PKKeyRowRefresh()
    optRefreshers[#optRefreshers + 1] = PKKeyRowRefresh

    pkKeyBtn:SetScript("OnClick", function()
        PKCapture("Ping Key", function(key)
            if key then Commit("pkKey", key); if PKUI.Apply then PKUI.Apply() end end
            PKPanelRefresh()
        end)
    end)
    pkAutoKeyBtn:SetScript("OnClick", function()
        PKCapture("Key that toggles Auto-Ping   |cff8298b4(works in combat)|r", function(key)
            if key and Cfg("pkToggleKey") == key then key = "" end
            Commit("pkToggleKey", key or "")
            if PKUI.Apply then PKUI.Apply() end
            PKPanelRefresh()
        end)
    end)

    -- "any spell" mode needs no list at all, so the whole picking half of the
    -- tab collapses away in that mode (UI.Section has no visibleFn of its own --
    -- it is the row it just appended)
    -- the picker is useful in BOTH modes: a spell can be set to Always or its
    -- own key even while the ping key already covers everything
    local function PKPicksShown() return Cfg("pkEnabled") == true end
    -- was: reaching into pg._rows to tag the row the OLD Section appended.
    -- Sections are not rows any more, so they carry their own visibleFn.
    UI.Section(pgPingKey, "Your Spells", PKPicksShown)

    local PKRowsRefresh  -- fwd

    local pkAddRow = UI.AddRow(pgPingKey, nil, PKPicksShown)
    local pkPick = UI.MakeSmallButton(pkAddRow, "Pick On My Bars", 150)
    pkPick:SetPoint("LEFT", 12, 0)
    local pkAddBox = CreateFrame("EditBox", nil, pkAddRow, "BackdropTemplate")
    pkAddBox:SetSize(90, 20)
    -- room to the right of Pick for the "Add By Spell ID" label to sit INLINE
    -- (left of the box), instead of floating above it
    pkAddBox:SetPoint("LEFT", pkPick, "RIGHT", 130, 0)
    Skin(pkAddBox, COL.well)
    pkAddBox:SetFontObject("GameFontHighlightSmall")
    pkAddBox:SetAutoFocus(false)
    pkAddBox:SetTextInsets(6, 6, 0, 0)
    pkAddBox:SetNumeric(true)
    local pkAddBoxHint = pkAddBox:CreateFontString(nil, "OVERLAY")
    pkAddBoxHint:SetFont(STANDARD_TEXT_FONT, 10, "")
    pkAddBoxHint:SetPoint("LEFT", 6, 0)
    pkAddBoxHint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pkAddBoxHint:SetText("spell ID")
    local pkAddBoxLab = pkAddRow:CreateFontString(nil, "OVERLAY")
    pkAddBoxLab:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkAddBoxLab:SetPoint("RIGHT", pkAddBox, "LEFT", -8, 0)   -- inline, centred left of the box
    pkAddBoxLab:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
    pkAddBoxLab:SetText("Add By Spell ID")
    pkAddBox:SetScript("OnTextChanged", function(self)
        pkAddBoxHint:SetShown((self:GetText() or "") == "")
    end)

    -- Add By ID: the spell is not on a bar, so the catalog has to be rebuilt to
    -- pick it up (PKUI.BuildCatalog appends tracked-but-off-bar entries) and then
    -- SELECTED, otherwise the user adds something and sees nothing happen.
    local function PKAddSpell(spellID)
        if not spellID or spellID <= 0 then return end
        local list = PKUI.List()
        for i = 1, #list do
            if list[i].id == spellID then   -- already tracked: just show it
                PKUI.Select(spellID)
                if PKRowsRefresh then PKRowsRefresh() end
                return
            end
        end
        if #list >= PKUI.PK_MAX then
            print("|cff33ff99Arc Pings|r: ping-key list is full (" .. PKUI.PK_MAX .. " entries).")
            return
        end
        list[#list + 1] = { id = spellID }
        SCOPE.Char().pkSpells = list
        PKUI.CatalogDirty()
        PKUI.Select(spellID)
        if PKUI.Apply then PKUI.Apply() end
        if PKRowsRefresh then PKRowsRefresh() end
    end

    -- picking happens ON the bars themselves: overlays light up every button,
    -- click one to add/remove. The options panel hides so the bars are clear.
    pkPick:SetScript("OnClick", function()
        CloseDropdown()
        p:Hide()
        PKUI.EnterSelect()
    end)

    -- ── CATALOG GRID ────────────────────────────────────────────────────────
    -- The same subjects the overlay offers, browsable without leaving the panel.
    -- A grid rather than a row list on purpose: the page does not scroll, and 48
    -- icons fit where 48 rows would not.
    -- The grid PACKS to the box width rather than sitting as a fixed 12-wide
    -- block centred in the row: at 1100px the old block left a hand's width of
    -- dead space either side while its own toolbar ran full width, which is what
    -- made this tab look unfinished. Columns are recomputed on every refresh and
    -- after a panel resize; the pool is a flat 60 cells, flowed into whatever
    -- number of rows that takes.
    local PK_CELL, PK_POOL, PK_MIN_ROWS = 32, 60, 3
    -- declared BEFORE the toolbar: the view dropdown below closes over it, and a
    -- local declared after a closure resolves as a nil global inside it.
    local PKGridRefresh   -- fwd
    local pkCatRow = UI.AddRow(pgPingKey, 30, PKPicksShown)
    local pkCatSearchBox = CreateFrame("EditBox", nil, pkCatRow, "BackdropTemplate")
    pkCatSearchBox:SetSize(150, 20)
    pkCatSearchBox:SetPoint("LEFT", 12, 0)
    Skin(pkCatSearchBox, COL.well)
    pkCatSearchBox:SetFontObject("GameFontHighlightSmall")
    pkCatSearchBox:SetAutoFocus(false)
    pkCatSearchBox:SetTextInsets(6, 6, 0, 0)
    local pkCatHint = pkCatSearchBox:CreateFontString(nil, "OVERLAY")
    pkCatHint:SetFont(STANDARD_TEXT_FONT, 10, "")
    pkCatHint:SetPoint("LEFT", 6, 0)
    pkCatHint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pkCatHint:SetText("search your bars")
    UI.RowTip(pkCatRow,
        "Green dot = pinging.  Grey dot = added but turned off.  Faded = no keybind, so nothing can reach it.")
    -- Rescan sits on the SEARCH/filter row (it rebuilds the grid the search and
    -- view filter act on), which also uncrowds the add row above (Pick + the
    -- "Add By Spell ID" box + Add ID).
    local pkCatRescan = UI.MakeSmallButton(pkCatRow, "Rescan Bars", 110)
    pkCatRescan:SetPoint("LEFT", 350, 0)
    -- A REAL DROPDOWN, matching ArcUI's "Show" select. This was a cycle button
    -- because RowDropdown only spoke config keys and this is view state; the fix
    -- was to give the dropdown get/set closures, not to downgrade the widget.
    local PK_VIEWS = { { "all", "All" }, { "on", "Pinging" }, { "off", "Not Pinging" } }
    local pkCatViewDD = UI.MakeDropdown(pkCatRow, 130, function() return PK_VIEWS end,
        PKUI.GetCatView,
        function(v) PKUI.SetCatView(v); if PKGridRefresh then PKGridRefresh() end end)
    pkCatViewDD:SetPoint("LEFT", 208, 0)
    local pkCatViewLab = pkCatRow:CreateFontString(nil, "OVERLAY")
    pkCatViewLab:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkCatViewLab:SetPoint("LEFT", 170, 0)
    pkCatViewLab:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pkCatViewLab:SetText("Show")

    local pkCountRow = UI.AddRow(pgPingKey, 18, PKPicksShown)
    local pkCatCount = pkCountRow:CreateFontString(nil, "OVERLAY")
    pkCatCount:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkCatCount:SetPoint("LEFT", 12, 0)
    pkCatCount:SetPoint("RIGHT", -12, 0)
    pkCatCount:SetJustifyH("LEFT")
    pkCatCount:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])

    local pkGridRow = UI.AddRow(pgPingKey, PK_MIN_ROWS * PK_CELL + 8, PKPicksShown)
    local pkGrid = {}
    for i = 1, PK_POOL do
        local b = CreateFrame("Button", nil, pkGridRow, "BackdropTemplate")
        b:SetSize(28, 28)
        -- placed in PKGridRefresh: the column count depends on the panel width
        Skin(b, COL.well)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetPoint("TOPLEFT", 1, -1)
        b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
        b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.mark = b:CreateFontString(nil, "OVERLAY")
        b.mark:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
        b.mark:SetPoint("TOPRIGHT", -1, 1)
        b.mark:SetText("|cff33ff99*|r")
        -- clicking SELECTS; the editor below is where enable / mode / key /
        -- remove live, so one click never silently changes what is armed
        b:SetScript("OnClick", function(self)
            local e = self._entry
            if not e then return end
            CloseDropdown()
            PKUI.Select(e.id)
            if PKRowsRefresh then PKRowsRefresh() end
            PKGridRefresh()
        end)
        b:SetScript("OnEnter", function(self)
            local e = self._entry
            if not e then return end
            self:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(e.name or "?", 1, 1, 1)
            if e.key then
                GameTooltip:AddLine("Key: " .. e.key, 0.51, 0.60, 0.71)
            else
                GameTooltip:AddLine("No keybind - cannot be pinged", 1, 0.33, 0.33)
            end
            local tr = PKUI.Tracked(e.id)
            if tr then
                GameTooltip:AddLine(PKUI.EntryOn(tr) and "Pinging" or "Added, turned off", 0.2, 1, 0.6)
            end
            GameTooltip:AddLine("Click to edit", 0.6, 0.85, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
            GameTooltip:Hide()
        end)
        b:Hide()
        pkGrid[i] = b
    end

    PKGridRefresh = function()
        local entries = PKUI.CatalogFiltered()
        -- pack to the row's real width; 12 is the left inset the toolbars use.
        -- Before the first LayoutPage the row has no width yet, so fall back to
        -- the page (which is anchored to the panel and sized from the start).
        local rowW = pkGridRow:GetWidth() or 0
        if rowW < 50 then rowW = (pgPingKey:GetWidth() or 0) - 12 end
        local avail = rowW - 24
        local cols = math.floor((avail + 4) / PK_CELL)
        if cols < 6 then cols = 6 end
        for i = 1, #pkGrid do
            local b, e = pkGrid[i], entries[i]
            b._entry = e
            if e then
                local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", pkGridRow, "TOPLEFT", 12 + col * PK_CELL, -4 - row * PK_CELL)
                b.tex:SetTexture(e.icon or 134400)
                -- no keybind = nothing a ping key can reach; dim it rather than
                -- hide it, so the user can see it IS on a bar and why it is out
                b.tex:SetDesaturated(e.key == nil)
                b.tex:SetAlpha(e.key and 1 or 0.45)
                local tr = PKUI.Tracked(e.id)
                b.mark:SetShown(tr ~= nil)
                b.mark:SetText(PKUI.EntryOn(tr) and "|cff33ff99*|r" or "|cff8298b4*|r")
                if PKUI.SelectedID() == e.id then
                    b:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 1)
                else
                    b:SetBackdropBorderColor(COL.line[1], COL.line[2], COL.line[3], 1)
                end
                b:Show()
            else
                b:Hide()
            end
        end
        local all = PKUI.Catalog()
        local keyed = 0
        for i = 1, #all do if all[i].key then keyed = keyed + 1 end end
        local shown = math.min(#entries, #pkGrid)
        -- shrink the row to the rows actually used, so an empty or filtered grid
        -- does not leave a slab of blank box under it
        local used = math.max(PK_MIN_ROWS, math.ceil(shown / cols))
        local wantH = used * PK_CELL + 8
        if pkGridRow._h ~= wantH then
            pkGridRow._h = wantH
            pkGridRow:SetHeight(wantH)
            UI.LayoutPage(pgPingKey)
        end
        if shown < #entries then
            pkCatCount:SetText(("showing %d of %d"):format(shown, #entries))
        elseif PKUI.GetCatView() ~= "all" then
            pkCatCount:SetText(("%d of %d shown"):format(#entries, #all))
        else
            -- the slot budget was only ever visible in the on-bars overlay, so
            -- from in here twelve was an invisible ceiling
            pkCatCount:SetText(("%d on bars, %d keybound   |cff8298b4%d of %d ping slots used|r")
                :format(#all, keyed, #PKUI.List(), PKUI.PK_MAX))
        end
        pkCatViewDD.Refresh()
    end

    pkCatSearchBox:SetScript("OnTextChanged", function(self)
        pkCatHint:SetShown((self:GetText() or "") == "")
        PKUI.SetCatSearch(self:GetText() or "")
        PKGridRefresh()
    end)
    pkCatSearchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    pkCatRescan:SetScript("OnClick", function()
        CloseDropdown()
        PKUI.CatalogDirty(); PKUI.BuildCatalog(); PKGridRefresh()
    end)
    optRefreshers[#optRefreshers + 1] = PKGridRefresh
    -- called by the resize grip, and by the scroll host the first time its width
    -- resolves (the grid packs to that width, so it has to re-flow then)
    pkOnResize = function()
        PKGridRefresh()
        UI.LayoutPage(pgPingKey)
    end
    pgPingKey._onWidth = pkOnResize
    local pkAddBtn = UI.MakeSmallButton(pkAddRow, "Add ID", 70)
    pkAddBtn:SetPoint("LEFT", pkAddBox, "RIGHT", 8, 0)
    pkAddBtn:SetScript("OnClick", function()
        local sid = tonumber(pkAddBox:GetText())
        if sid then
            pkAddBox:SetText("")
            pkAddBox:ClearFocus()
            PKAddSpell(sid)
        end
    end)

    -- fixed pool of spell rows; rows past the list length hide themselves and
    -- UI.RestackPage closes the gap
    -- ── SELECTED ICON EDITOR ────────────────────────────────────────────────
    -- One editor for whichever grid icon is clicked, replacing the old row per
    -- tracked spell. The list grew without bound and pushed the grid off the
    -- page; this keeps the tab a fixed height however many spells are tracked.
    -- its OWN box. As a trailing row of the catalog box it read as part of the
    -- grid, and it vanished entirely with nothing selected, so the tab jumped
    -- every time an icon was clicked. Now the box is always there and says what
    -- to do when it is empty.
    UI.Section(pgPingKey, "Selected Spell", PKPicksShown)

    local function PKSelT()   return PKUI.Tracked((PKUI.Selected() or {}).id) end
    local function PKHasSel() return PKPicksShown() and PKUI.Selected() ~= nil end
    -- mode / presses / key / remove are meaningless until the spell is ADDED
    local function PKHasTracked() return PKHasSel() and PKSelT() ~= nil end
    local function PKCommitEntry()
        SCOPE.Char().pkSpells = PKUI.List()
        if PKUI.Apply then PKUI.Apply() end
        PKRowsRefresh()
    end

    -- header: icon + name on the left, "Ping this" and Remove on the right
    local pkEd = UI.AddRow(pgPingKey, 30, PKPicksShown)
    local pkEdEmpty = pkEd:CreateFontString(nil, "OVERLAY")
    pkEdEmpty:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkEdEmpty:SetPoint("LEFT", 12, 0)
    pkEdEmpty:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pkEdEmpty:SetText("Click a spell above to choose how it pings.")
    local pkEdIcon = pkEd:CreateTexture(nil, "ARTWORK")
    pkEdIcon:SetSize(22, 22)
    pkEdIcon:SetPoint("LEFT", 12, 0)
    pkEdIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local pkEdName = pkEd:CreateFontString(nil, "OVERLAY")
    pkEdName:SetFont(STANDARD_TEXT_FONT, 12, "")
    pkEdName:SetPoint("LEFT", pkEdIcon, "RIGHT", 8, 0)
    pkEdName:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    local pkEdOnFS = pkEd:CreateFontString(nil, "OVERLAY")
    pkEdOnFS:SetFont(STANDARD_TEXT_FONT, 11, "")
    pkEdOnFS:SetPoint("LEFT", LAY.ctrl, 0)
    local pkEdOn = UI.MakeSwitch(pkEd)
    pkEdOn:SetPoint("LEFT", LAY.ctrl + 62, 0)
    local pkEdDel = UI.MakeSmallButton(pkEd, "Remove", 70)
    pkEdDel:SetPoint("LEFT", LAY.ctrl + 104, 0)
    pkEdOnFS:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
    pkEdOnFS:SetText("Ping this")

    -- "Pings When": a REAL DROPDOWN with ArcUI's fuller labels. It was a cycle
    -- button that showed one mode and hid the other two behind a blind click,
    -- which is the most consequential setting on the tab.
    local PK_MODES = {
        { "key",    "I hold the ping key" },
        { "always", "Every time I press its key" },
        { "own",    "Its own key (ping only)" },
    }
    local pkModeRow = UI.AddRow(pgPingKey, nil, PKHasTracked)
    UI.RowLabel(pkModeRow, "Pings When")
    local pkEdMode = UI.MakeDropdown(pkModeRow, 190, function() return PK_MODES end,
        function() local t = PKSelT(); return (t and PKUI.EntryMode(t)) or "key" end,
        function(v)
            local t = PKSelT()
            if not t then return end
            t.mode = (v ~= "key") and v or nil
            PKCommitEntry()
        end)
    pkEdMode:SetPoint("LEFT", pkModeRow._ctrlX, 0)
    UI.RowTip(pkModeRow,
        "Hold: your bar key still casts, and holding the ping key pings instead. "
        .. "Every press: casts AND pings. "
        .. "Its own key: pings only, casts nothing, and ignores Auto-Ping.")

    -- Presses Per Ping: counts presses, not seconds (a timed throttle is
    -- impossible in combat). Only "every press" mode has anything to gate.
    local PK_EVERY = {
        { 1, "Every press" }, { 2, "Every 2nd press" }, { 3, "Every 3rd press" },
        { 4, "Every 4th press" }, { 5, "Every 5th press" },
    }
    local function PKModeIsAlways()
        local t = PKHasTracked() and PKSelT()
        return (t and PKUI.EntryMode(t) == "always") and true or false
    end
    local pkEveryRow = UI.AddRow(pgPingKey, nil, PKModeIsAlways)
    UI.RowLabel(pkEveryRow, "Presses Per Ping")
    local pkEdEvery = UI.MakeDropdown(pkEveryRow, 190, function() return PK_EVERY end,
        function() local t = PKSelT(); return tonumber(t and t.every) or 1 end,
        function(v)
            local t = PKSelT()
            if not t then return end
            t.every = (v > 1) and v or nil
            PKCommitEntry()
        end)
    pkEdEvery:SetPoint("LEFT", pkEveryRow._ctrlX, 0)
    UI.RowTip(pkEveryRow,
        "Stops a spammed button flooding the group. It counts presses, not time, and the count never resets, so Every 2nd is always the even-numbered press. The cast always goes through.")

    -- the key control edits a DIFFERENT field per mode, so the row is labelled
    -- per mode rather than leaving one button silently meaning three things
    local pkKeyEdRow = UI.AddRow(pgPingKey, nil, PKHasTracked)
    local pkEdKeyLab = UI.RowLabel(pkKeyEdRow, "Ping Key For This Spell")
    local pkEdKey = UI.MakeSmallButton(pkKeyEdRow, "", 150)
    pkEdKey:SetPoint("LEFT", pkKeyEdRow._ctrlX, 0)

    local pkEdInfoRow = UI.AddRow(pgPingKey, 22, PKHasSel)
    local pkEdInfo = pkEdInfoRow:CreateFontString(nil, "OVERLAY")
    pkEdInfo:SetFont(STANDARD_TEXT_FONT, 10, "")
    pkEdInfo:SetPoint("LEFT", 12, 0)
    pkEdInfo:SetPoint("RIGHT", -12, 0)
    pkEdInfo:SetJustifyH("LEFT")

    pkEdOn:SetScript("OnClick", function()
        CloseDropdown()
        local t = PKSelT()
        local nv = not (t ~= nil and PKUI.EntryOn(t))
        PKUI.SetSelectedEnabled(nv)
        PKRowsRefresh(); PKGridRefresh()
        PlaySound(nv and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                     or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
    end)
    -- in "own" mode it is the key that pings outright, otherwise it is which
    -- PING key wakes this spell (its action bar key is never touched)
    pkEdKey:SetScript("OnClick", function()
        local t = PKUI.Tracked((PKUI.Selected() or {}).id)
        if not t then return end
        local own = PKUI.EntryMode(t) == "own"
        if not own and PKUI.EntryMode(t) == "always" then return end   -- nothing to set
        PKCapture(own and "Key that pings this spell on its own"
                      or "Ping key for this spell   |cff8298b4(held, not its bar key)|r",
            function(key)
                local cur = PKUI.Tracked((PKUI.Selected() or {}).id)
                if cur then
                    local field = own and "ownKey" or "pingKey"
                    -- capturing the same key twice clears it
                    if key and cur[field] == key then cur[field] = nil else cur[field] = key end
                    SCOPE.Char().pkSpells = PKUI.List()
                    if PKUI.Apply then PKUI.Apply() end
                end
                PKRowsRefresh()
            end)
    end)
    pkEdDel:SetScript("OnClick", function()
        CloseDropdown()
        PKUI.RemoveSelected()
        PKRowsRefresh(); PKGridRefresh()
    end)

    PKRowsRefresh = function()
        local sel = PKUI.Selected()
        -- the header row is the only one that renders with nothing selected;
        -- every other editor row carries a visibleFn and collapses on its own
        pkEdEmpty:SetShown(sel == nil)
        pkEdIcon:SetShown(sel ~= nil)
        pkEdName:SetShown(sel ~= nil)
        pkEdOn:SetShown(sel ~= nil)
        pkEdOnFS:SetShown(sel ~= nil)
        pkEdDel:SetShown(sel ~= nil and PKUI.Tracked(sel.id) ~= nil)
        if sel then
            local tracked = PKUI.Tracked(sel.id)
            pkEdIcon:SetTexture(sel.icon or 134400)
            pkEdName:SetText(sel.name or "?")
            pkEdOn:SetOn(tracked ~= nil and PKUI.EntryOn(tracked))
            pkEdMode.Refresh()
            pkEdEvery.Refresh()
            local mode = tracked and PKUI.EntryMode(tracked) or "key"
            local barKey = sel.key   -- the key the action bar has it on
            if mode == "own" then
                pkEdKeyLab:SetText("Key That Pings It On Its Own")
                local k = tracked and tracked.ownKey
                pkEdKey.fs:SetText((k and k ~= "") and k or "|cffff5555set key|r")
                if k and k ~= "" then
                    pkEdInfo:SetText(("|cff8298b4Press %s on its own to ping. Nothing is cast. Auto-Ping does not affect this mode.|r"):format(k))
                else
                    pkEdInfo:SetText("|cffff5555This mode needs a key - click it to set one.|r")
                end
            elseif not barKey then
                pkEdKeyLab:SetText("Bar Key")
                pkEdKey.fs:SetText("|cffff5555no bar key|r")
                pkEdInfo:SetText("|cffff5555No keybind on your bars - bind it, or switch to Its own key.|r")
            elseif mode == "always" then
                pkEdKeyLab:SetText("Bar Key (read only)")
                pkEdKey.fs:SetText("|cff8298b4" .. barKey .. "|r")
                pkEdInfo:SetText(("|cff8298b4Casts and pings on %s.|r"):format(barKey))
            else
                pkEdKeyLab:SetText("Ping Key For This Spell")
                local pk = tracked and PKUI.PingKeyFor(tracked)
                local own = tracked and tracked.pingKey and tracked.pingKey ~= ""
                pkEdKey.fs:SetText(own and pk or ("|cff8298b4" .. tostring(pk or "-") .. "|r"))
                if not pk then
                    pkEdInfo:SetText("|cffff5555No ping key set.|r")
                else
                    pkEdInfo:SetText(("|cff8298b4Hold %s%s then press %s.|r")
                        :format(pk, own and " (this spell only)" or "", barKey))
                end
            end
            -- "always" has nothing to capture: the bar key IS the trigger. Grey
            -- it out rather than letting a click silently do nothing.
            local inert = (mode == "always")
            pkEdKey:SetEnabled(not inert)
            pkEdKey:SetAlpha(inert and 0.5 or 1)
            -- PAUSED. The engine refuses to arm an entry whose bar slot no
            -- longer holds it (spec change, or the spell was dragged elsewhere)
            -- and said nothing about it, so the spell simply stopped pinging.
            if tracked and PKUI.MatchesBar and not PKUI.MatchesBar(tracked) then
                pkEdInfo:SetText("|cffffd100Paused - this spell is not on that bar slot right now (spec change or moved). Put it back and it resumes on its own.|r")
            end
        end
        local list = PKUI.List()
        local total, resolved = #list, PKUI.ResolvedCount()
        local key = Cfg("pkKey")
        local needKey = (not key or key == "")
        -- states the engine already has but the panel never reported: no 12.1
        -- client, changes parked until combat ends, and the 12-slot budget
        if not PKUsable() then
            pkStatusFS:SetText("|cffff5555Requires Patch 12.1.|r")
        elseif InCombatLockdown() then
            pkStatusFS:SetText("|cffffd100In combat - ping key changes apply when you leave combat.|r")
        elseif total > PKUI.PK_MAX then
            pkStatusFS:SetText(("|cffff5555%d spells saved but only the first %d can arm.|r"):format(total, PKUI.PK_MAX))
        elseif not Cfg("pkEnabled") then
            pkStatusFS:SetText("|cff8298b4Off.|r")
        elseif not Cfg("pkOnlySelected") then
            pkStatusFS:SetText(needKey and "|cffff5555Set a ping key above.|r"
                or ("|cff33ff99Active:|r hold %s over any bound spell%s"):format(key,
                    total > 0 and (", plus %d of %d with their own settings."):format(resolved, total) or "."))
        elseif total == 0 then
            pkStatusFS:SetText("|cff8298b4No spells selected yet.|r")
        elseif resolved == 0 then
            pkStatusFS:SetText("|cffff5555None of them will ping - click one below to see why.|r")
        else
            local autoOff = not PKUI.AutoOn()
            pkStatusFS:SetText((("|cff33ff99Active:|r %d of %d.%s"):format(resolved, total,
                autoOff and " |cffff5555Auto-Ping is off.|r" or "")))
        end
        UI.RestackPage(pgPingKey)
    end
    optRefreshers[#optRefreshers + 1] = PKRowsRefresh
    -- keep the list live while the user is clicking spells on their bars, and
    -- put them back in this panel when they press Done
    pkSel.notify = PKRowsRefresh
    pkSel.onExit = function()
        p:Show()
        SelectTab("Ping Keys")
        PKRowsRefresh()
    end

    -- ═════════════════════════════════════════════════════════════════════════
    -- LAYOUT tab: drag canvas + piece list + INLINE editor
    -- ═════════════════════════════════════════════════════════════════════════
    local pvHint = pgLayout:CreateFontString(nil, "OVERLAY")
    pvHint:SetFont(STANDARD_TEXT_FONT, 10, "")
    pvHint:SetPoint("TOPLEFT", 12, -8)
    pvHint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    pvHint:SetText("drag a piece into place, or click it (here or in the list) to edit")

    local rowWell = CreateFrame("Frame", nil, pgLayout, "BackdropTemplate")
    rowWell:SetPoint("TOPLEFT", 10, -22)
    rowWell:SetPoint("TOPRIGHT", -10, -22)
    rowWell:SetHeight(120)
    Skin(rowWell, COL.well)
    -- the canvas CLIPS: nothing inside it can ever render past its border
    -- (previews wider than the well used to bleed across the panel)
    rowWell:SetClipsChildren(true)
    local midline = rowWell:CreateTexture(nil, "BACKGROUND", nil, 1)
    midline:SetTexture(WHITE)
    midline:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 0.35)
    midline:SetPoint("LEFT", 4, 0)
    midline:SetPoint("RIGHT", -4, 0)
    midline:SetHeight(1)
    -- the canvas sample is the SAME WIDTH as the real window, so dragged
    -- offsets translate 1:1 (designing on a wider surface made layouts land
    -- somewhere else on the live 280px window)
    local sample = UI.MakeSample(rowWell)
    sample:SetPoint("CENTER", 0, 0)
    sample:SetSize(280, 106)
    -- the DISPLAY AREA band: shows EXACTLY the box the real window renders.
    -- The box SHRINK-WRAPS the pieces (it always hugs whatever you lay out,
    -- top and bottom independently), and its top/bottom edges are GRABBABLE:
    -- drag them to trim the padding to zero (flush against the pieces) or
    -- add breathing room. It can never cut into a piece.
    -- child of the SAMPLE so it scales with it when the preview shrinks-to-fit
    local bandF = CreateFrame("Frame", nil, sample)
    bandF:SetFrameLevel(sample:GetFrameLevel())
    local band = bandF:CreateTexture(nil, "BACKGROUND", nil, 2)
    band:SetTexture(WHITE)
    band:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.07)
    band:SetAllPoints(bandF)

    local function BandHandle(side)
        local isTop = (side == "top")
        local h = CreateFrame("Frame", nil, rowWell)
        h:SetFrameLevel(sample:GetFrameLevel() + 25)
        h:EnableMouse(true)
        h:SetHeight(8)
        if isTop then
            h:SetPoint("TOPLEFT", bandF, "TOPLEFT", 0, 4)
            h:SetPoint("TOPRIGHT", bandF, "TOPRIGHT", 0, 4)
        else
            h:SetPoint("BOTTOMLEFT", bandF, "BOTTOMLEFT", 0, -4)
            h:SetPoint("BOTTOMRIGHT", bandF, "BOTTOMRIGHT", 0, -4)
        end
        local tex = h:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(WHITE)
        tex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.12)
        tex:SetAllPoints()
        h:SetScript("OnEnter", function() tex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.5) end)
        h:SetScript("OnLeave", function() if not h._dragging then tex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.12) end end)
        h:SetScript("OnMouseDown", function()
            h._dragging = true
            -- SAMPLE's effective scale: band coords live in the sample's
            -- (possibly shrunk-to-fit) space, not the well's
            local scale = sample:GetEffectiveScale()
            h:SetScript("OnUpdate", function()
                local _mx, my = GetCursorPosition()
                my = my / scale
                local _lcx, lineY = sample:GetCenter()   -- the canvas centerline
                if not lineY then return end
                local up, down = UI.RowExtents()
                -- padding = distance from the piece extent to the cursor;
                -- clamps at 0 so the edge can NEVER cut into a piece
                local pad
                if isTop then pad = (my - lineY) - up
                else pad = (lineY - my) - down end
                pad = math.floor(pad + 0.5)
                if pad < 0 then pad = 0 elseif pad > 40 then pad = 40 end
                local key = isTop and "rowPadTop" or "rowPadBottom"
                if pad ~= Cfg(key) then
                    SetCfg(key, pad)
                    if RefreshPreview then RefreshPreview() end
                end
            end)
        end)
        h:SetScript("OnMouseUp", function()
            h._dragging = nil
            h:SetScript("OnUpdate", nil)
            tex:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.12)
            if RefreshPreview then RefreshPreview() end
        end)
    end
    BandHandle("top"); BandHandle("bottom")

    -- icon piece removed (combat-first rule)
    local PIECES = {
        time   = { label = "Timestamp", el = sample.time,   posKey = "timePos",   xKey = "timeX",   yKey = "timeY",   colorKey = "colTime",   showKey = "showTimestamp", anchorKey = "timeAnchorTo", sizeKey = "timeSize" },
        sender = { label = "Sender",    el = sample.sender, posKey = "senderPos", xKey = "senderX", yKey = "senderY", colorKey = "colSender", showKey = "showSender", anchorKey = "senderAnchorTo", sizeKey = "senderSize" },
        text   = { label = "Ping Text", el = sample.text,   posKey = "textPos",   xKey = "textX",   yKey = "textY",   colorKey = "colText", sizeKey = "textSize" },
    }
    local PIECE_ORDER = { "time", "sender", "text" }
    local selectedKey
    local grips = {}         -- key -> canvas grab frame (ring anchors here)
    local UpdateTextGrip     -- fwd: re-hugs the text grip to the glyph box

    local selRing = CreateFrame("Frame", nil, rowWell, "BackdropTemplate")
    selRing:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    selRing:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.9)
    selRing:SetFrameLevel(rowWell:GetFrameLevel() + 8)
    selRing:Hide()

    local function Select(key)
        selectedKey = key
        local g = key and grips[key]
        if g then
            selRing:ClearAllPoints()
            selRing:SetPoint("TOPLEFT", g, "TOPLEFT", -1, 1)
            selRing:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 1, -1)
            selRing:Show()
        else
            selRing:Hide()
        end
    end

    local clampingWidth = false
    RefreshPreview = function()
        -- dependent option rows collapse/reveal with their parent setting
        UI.RestackPage(pgEntries)
        local avail = (rowWell:GetWidth() or 0) - 16
        if avail < 100 then avail = 458 end  -- pre-layout fallback
        -- live rows sit 6px inset inside the window (Render uses width - 12):
        -- the canvas sample is the piece-drag space at REAL window width; when
        -- the window is wider than the canvas, the preview SCALES DOWN to fit
        -- (whole layout visible, mildly smaller -- never overflow, never a
        -- fake ellipsis the real window doesn't have)
        local winW = math.max(160, tonumber(Cfg("width")) or 340)
        sample:SetScale((winW > avail) and (avail / winW) or 1)
        sample:SetWidth(winW - 12)
        sample:SetHeight(106)
        local up, down = UI.RowExtents()
        local padT, padB = UI.RowPads()
        bandF:SetSize(winW, up + padT + down + padB)
        bandF:ClearAllPoints()
        bandF:SetPoint("CENTER", sample, "CENTER", 0, ((up + padT) - (down + padB)) / 2)
        RenderSample(sample)
        -- WIDTH FLOOR: the width may NEVER be too small for the worst-case
        -- callout at the current layout/fonts. The sample IS the worst case
        -- (its _neededW = piece insets + full untruncated line): if it does
        -- not fit, the width auto-raises -- a truncated standard callout is
        -- not a configurable state.
        if not clampingWidth and sample._neededW then
            -- NO 600 cap: the floor must win even past the slider's max (big
            -- fonts need more; capping at the slider max silently re-allowed
            -- truncation -- the exact bug the floor exists to prevent)
            local minW = math.min(1200, math.ceil(sample._neededW + 12))
            if (tonumber(Cfg("width")) or 0) < minW then
                clampingWidth = true
                SetCfg("width", minW)
                for _i, fn in ipairs(optRefreshers) do fn() end  -- incl. this fn + width slider
                clampingWidth = false
                return
            end
        end
        if UpdateTextGrip then UpdateTextGrip() end
        if selectedKey then Select(selectedKey) end
    end

    -- canvas pieces: outlined, labeled, FREE-dragged. The Ping Text piece is a
    -- spanning fontstring, so its grip hugs the rendered GLYPHS (not the full
    -- span) and drops store its side/X like any other piece.
    local function MakeDraggable(piece, key)
        local pc = PIECES[key]
        local isText = (key == "text")
        local grip = CreateFrame("Button", nil, sample, "BackdropTemplate")
        grips[key] = grip
        grip:SetFrameLevel(sample:GetFrameLevel() + 10)
        grip:RegisterForDrag("LeftButton")
        grip:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
        grip:SetBackdropBorderColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.6)
        if not isText then
            grip:SetPoint("TOPLEFT", piece, "TOPLEFT", -2, 2)
            grip:SetPoint("BOTTOMRIGHT", piece, "BOTTOMRIGHT", 2, -2)
        end
        local tag = grip:CreateFontString(nil, "OVERLAY")
        tag:SetFont(STANDARD_TEXT_FONT, 8, "")
        tag:SetPoint("BOTTOMLEFT", grip, "TOPLEFT", 0, 1)
        tag:SetTextColor(COL.faint[1], COL.faint[2], COL.faint[3])
        tag:SetText(pc.label)
        local hl = grip:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture(WHITE)
        hl:SetVertexColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.15)
        hl:SetAllPoints()
        grip:SetScript("OnEnter", function()
            grip:SetBackdropBorderColor(COL.arc[1], COL.arc[2], COL.arc[3], 0.8)
            tag:SetTextColor(COL.arc[1], COL.arc[2], COL.arc[3])
        end)
        grip:SetScript("OnLeave", function()
            grip:SetBackdropBorderColor(COL.faint[1], COL.faint[2], COL.faint[3], 0.6)
            tag:SetTextColor(COL.faint[1], COL.faint[2], COL.faint[3])
        end)
        grip:SetScript("OnClick", function() Select(key) end)

        if isText then
            -- hug the glyph box: anchored at the justified side, sized to the string
            UpdateTextGrip = function()
                local w = (piece.GetStringWidth and piece:GetStringWidth() or 60) + 6
                local h = (Cfg("fontSize") or 12) + 8
                grip:SetSize(w, h)
                grip:ClearAllPoints()
                local tp = Cfg("textPos")
                if tp == "right" then
                    grip:SetPoint("RIGHT", piece, "RIGHT", 2, 0)
                elseif tp == "center" then
                    grip:SetPoint("CENTER", piece, "CENTER", 0, 0)
                else
                    grip:SetPoint("LEFT", piece, "LEFT", -2, 0)
                end
            end
            UpdateTextGrip()
        end

        -- the width used for drop math: the text piece measures its glyphs,
        -- everything else measures its frame
        local function PieceWidth()
            if isText then return (piece.GetStringWidth and piece:GetStringWidth() or 60) end
            return piece:GetWidth() or 16
        end
        -- the glyph-box center (differs from the span center for the text)
        local function PieceCenterX()
            if isText then
                local w = PieceWidth()
                local tp = Cfg("textPos")
                if tp == "right" then return (piece:GetRight() or 0) - w / 2 end
                if tp == "center" then local cxp = piece:GetCenter() return cxp or 0 end
                return (piece:GetLeft() or 0) + w / 2
            end
            local cxp = piece:GetCenter()
            return cxp or 0
        end

        local dragging, grabDX, grabDY
        grip:SetScript("OnDragStart", function()
            Select(key)
            dragging = true
            local scale = sample:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx, my = mx / scale, my / scale
            local pcx = PieceCenterX()
            local _cx, pcy = piece:GetCenter()
            grabDX, grabDY = (pcx or mx) - mx, (pcy or my) - my
            grip:SetScript("OnUpdate", function()
                local ux, uy = GetCursorPosition()
                ux, uy = ux / scale, uy / scale
                -- floating: single point -> the fontstring auto-sizes to its
                -- glyphs, so the text piece stops spanning while dragged
                piece:ClearAllPoints()
                piece:SetPoint("CENTER", UIParent, "BOTTOMLEFT", ux + grabDX, uy + grabDY)
            end)
        end)
        grip:SetScript("OnDragStop", function()
            if not dragging then return end
            dragging = false
            grip:SetScript("OnUpdate", nil)
            local pcx, pcy = piece:GetCenter()
            local sl, sb = sample:GetLeft() or 0, sample:GetBottom() or 0
            local sw, sh = sample:GetWidth() or 1, sample:GetHeight() or 1
            if not (pcx and pcy) then RefreshPreview() return end
            local relX = pcx - sl
            local relY = pcy - (sb + sh / 2)
            local half = sh / 2 - 10
            if relY > half then relY = half elseif relY < -half then relY = -half end
            local pw = PieceWidth()
            -- dragging = free placement: detach any piece anchor first
            if pc.anchorKey then SetCfg(pc.anchorKey, "row") end
            if pc.posKey and pc.xKey then
                if relX < sw / 2 then
                    SetCfg(pc.posKey, "left")
                    local x = math.floor(relX - pw / 2 + 0.5)
                    SetCfg(pc.xKey, (x > 0) and x or 0)
                else
                    SetCfg(pc.posKey, "right")
                    local x = math.floor((sw - relX) - pw / 2 + 0.5)
                    SetCfg(pc.xKey, (x > 0) and x or 0)
                end
            end
            if pc.yKey then SetCfg(pc.yKey, math.floor(relY + 0.5)) end
            RefreshPreview()
        end)
    end
    MakeDraggable(sample.time, "time")
    MakeDraggable(sample.sender, "sender")
    MakeDraggable(sample.text, "text")

    -- ── pieces: ONE EXPANDED BOX EACH ────────────────────────────────────────
    -- ArcUI has no "click a piece to edit it" step and neither does this now.
    -- That pattern needed a tall editor box reserved whether or not anything was
    -- selected, which is exactly what kept hanging off the bottom of the panel,
    -- and it hid five of six controls behind a click. Every piece is simply
    -- listed with its own controls, and a hidden piece collapses its whole box.
    --
    -- The drag canvas above is absolutely anchored, so tell UI.LayoutPage where
    -- the section flow begins rather than starting it under the page top.
    pgLayout._startY = -148
    UI.Section(pgLayout, "Entry Globals")
    UI.RowSlider(pgLayout, "Font Size", "fontSize", 8, 24, 1)
    UI.RowDropdown(pgLayout, "Font Outline", "fontOutline",
        { { "NONE", "None" }, { "OUTLINE", "Outline" }, { "THICKOUTLINE", "Thick Outline" } })

    UI.Section(pgLayout, "Pieces")
    UI.RowDesc(pgLayout,
        "Every piece of an entry is listed below. Place it here, or drag it on the canvas above. The entry box always shrink-wraps whatever you build.", 32)
    do
        local row = UI.AddRow(pgLayout)
        local x = 12
        for _i, key in ipairs(PIECE_ORDER) do
            local pc = PIECES[key]
            if pc.showKey then
                local sw = UI.MakeSwitch(row)
                sw:SetPoint("LEFT", x, 0)
                local fs = row:CreateFontString(nil, "OVERLAY")
                fs:SetFont(STANDARD_TEXT_FONT, 12, "")
                fs:SetPoint("LEFT", sw, "RIGHT", 8, 0)
                fs:SetTextColor(COL.ink[1], COL.ink[2], COL.ink[3])
                fs:SetText("Show " .. pc.label)
                local function refresh() sw:SetOn(Cfg(pc.showKey) == true) end
                refresh()
                optRefreshers[#optRefreshers + 1] = refresh
                sw:SetScript("OnClick", function()
                    CloseDropdown()
                    Commit(pc.showKey, not (Cfg(pc.showKey) == true))
                    refresh()
                    UI.LayoutPage(pgLayout)   -- the piece's box appears/collapses
                    PlaySound(Cfg(pc.showKey) == true and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
                                                       or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF, "Master")
                end)
                x = x + 40 + (fs:GetStringWidth() or 60) + 24
            end
        end
    end

    -- Anchor: place this piece relative to another piece instead of the row edge
    local ANCHOR_VALUES = {
        { "row",    "Free (row edge)" },
        { "time",   "Timestamp" },
        { "sender", "Sender" },
        { "text",   "Ping Text" },
    }
    local POS_LABELS_FREE     = { left = "Left", center = "Center", right = "Right", top = "Top", bottom = "Bottom" }
    local POS_LABELS_ANCHORED = { left = "Left of it", center = "Centered on it", right = "Right of it", top = "Above it", bottom = "Below it" }
    local POS_ORDER = { "left", "center", "right", "top", "bottom" }

    for _i, key in ipairs(PIECE_ORDER) do
        local pc = PIECES[key]
        -- a piece that is switched off collapses its entire box
        local function PieceShown()
            return (not pc.showKey) or Cfg(pc.showKey) == true
        end
        local function Anchored()
            return pc.anchorKey and (Cfg(pc.anchorKey) or "row") ~= "row"
        end

        UI.Section(pgLayout, pc.label, PieceShown)

        if pc.anchorKey then
            local row = UI.AddRow(pgLayout)
            local lbl = UI.RowLabel(row, "Anchor To")
            -- self is OMITTED rather than rendered greyed: a piece cannot anchor
            -- to itself, so it should not be in the list at all
            local dd = UI.MakeDropdown(row, 170, function()
                    local out = {}
                    for _j, v in ipairs(ANCHOR_VALUES) do
                        if v[1] ~= key then out[#out + 1] = v end
                    end
                    return out
                end,
                function() return Cfg(pc.anchorKey) or "row" end,
                function(v) Commit(pc.anchorKey, v); UI.LayoutPage(pgLayout) end)
            dd:SetPoint("LEFT", row._ctrlX, 0)
            row._colLabel, row._colCtrl = lbl, dd   -- join the auto-column with the sliders below
            optRefreshers[#optRefreshers + 1] = dd.Refresh
            UI.RowTip(row, "Place this piece relative to another piece instead of the edge of the line.")
        end

        if pc.posKey then
            local row = UI.AddRow(pgLayout)
            local lbl = UI.RowLabel(row, "Position")
            local dd = UI.MakeDropdown(row, 170, function()
                    local anch, out = Anchored(), {}
                    for _j, v in ipairs(POS_ORDER) do
                        -- the ping text SPANS the line: only left/center/right apply
                        if not (key == "text" and (v == "top" or v == "bottom")) then
                            out[#out + 1] = { v, (anch and POS_LABELS_ANCHORED[v]) or POS_LABELS_FREE[v] or v }
                        end
                    end
                    return out
                end,
                function() return Cfg(pc.posKey) or "left" end,
                function(v) Commit(pc.posKey, v) end)
            dd:SetPoint("LEFT", row._ctrlX, 0)
            row._colLabel, row._colCtrl = lbl, dd   -- join the auto-column with the sliders below
            optRefreshers[#optRefreshers + 1] = dd.Refresh
        end

        -- ArcUI's ranges. The typed box reaches past the slider on all three.
        if pc.xKey then UI.RowSlider(pgLayout, "X Offset", pc.xKey, -600, 900, 1) end
        if pc.yKey then UI.RowSlider(pgLayout, "Y Offset", pc.yKey, -200, 200, 1) end
        if pc.sizeKey then
            UI.RowTip(UI.RowSlider(pgLayout, "Font Size (0 = global)", pc.sizeKey, 0, 48, 1),
                "0 follows the Font Size under Entry Globals. Any other value overrides it for this piece only.")
        end
        if pc.colorKey then UI.RowColor(pgLayout, "Color", pc.colorKey) end

        do
            local row = UI.AddRow(pgLayout)
            local b = UI.MakeSmallButton(row, "Reset " .. pc.label, 140)
            b:SetPoint("LEFT", 12, 0)
            b:SetScript("OnClick", function()
                CloseDropdown()
                local function resetKey(k)
                    if not k then return end
                    local d = DEFAULTS[k]
                    if type(d) == "table" then d = { d[1], d[2], d[3] } end
                    SetCfg(k, d)
                end
                resetKey(pc.posKey); resetKey(pc.xKey); resetKey(pc.yKey)
                resetKey(pc.colorKey); resetKey(pc.anchorKey); resetKey(pc.sizeKey)
                for _j, fn in ipairs(optRefreshers) do fn() end
                UI.LayoutPage(pgLayout)
                RefreshPreview()
            end)
        end
    end

    ResetWholeLayout = function()
        -- Blizzard's chat baseline: "10:59 [Sender]: [Spell] is ready!" --
        -- timestamp at the left edge, sender right of it, text flowing after,
        -- everything on one line at automatic height. VISIBILITY is part of
        -- the shape: reset turns the pieces back ON (a hidden timestamp
        -- orphans the sender's anchor and the whole line falls apart).
        SetCfg("showTimestamp", false); SetCfg("showSender", true)
        SetCfg("timePos", "left"); SetCfg("timeX", 0); SetCfg("timeY", 0)
        SetCfg("senderPos", "right"); SetCfg("senderX", 0); SetCfg("senderY", 0)
        SetCfg("textPos", "left"); SetCfg("textX", 0); SetCfg("textY", 0)
        SetCfg("timeAnchorTo", "row"); SetCfg("senderAnchorTo", "time")
        SetCfg("timeSize", 0); SetCfg("senderSize", 0); SetCfg("textSize", 0)
        SetCfg("rowPadTop", 2); SetCfg("rowPadBottom", 2)
        for _i, fn in ipairs(optRefreshers) do fn() end  -- switches update too
    end
    -- the confirmation popup is declared at file scope, long before this closure
    _G.ArcPings_ResetLayout = ResetWholeLayout
    Select(nil)
    optRefreshers[#optRefreshers + 1] = RefreshPreview

    -- Footer: the Arc UI Discord, under every tab page (pages reserve 40px).
    local footLine = p:CreateTexture(nil, "ARTWORK"); footLine:SetTexture(WHITE)
    footLine:SetVertexColor(COL.line[1], COL.line[2], COL.line[3], 1)
    footLine:SetPoint("BOTTOMLEFT", 10, 34); footLine:SetPoint("BOTTOMRIGHT", -10, 34)
    footLine:SetHeight(1)
    local discord = UI.MakeDiscordButton(p); discord:SetPoint("BOTTOMLEFT", 10, 9)
    local dhint = p:CreateFontString(nil, "OVERLAY"); dhint:SetFont(STANDARD_TEXT_FONT, 10, "")
    dhint:SetPoint("LEFT", discord, "RIGHT", 8, 0)
    dhint:SetTextColor(COL.dim[1], COL.dim[2], COL.dim[3])
    dhint:SetText("Questions or help? Join the Arc UI Discord")

    SelectTab("Ping Keys")
    p:SetScript("OnShow", function()
        for _i, fn in ipairs(optRefreshers) do fn() end
        -- while configuring: window visible (border + title) even when locked,
        -- with a live sample ping in it (real pings win)
        panelOpen = true
        ApplyAll()
        ShowPreviewEntry()
    end)
    p:SetScript("OnHide", function()
        CloseDropdown()
        panelOpen = false
        RemovePreviewEntries()
        ApplyAll()
    end)

    p:Hide()
    return p
end
function _G.ArcPings_ToggleOptions()
    local p = BuildOptionsPanel()
    p:SetShown(not p:IsShown())
end

-- ── boot ─────────────────────────────────────────────────────────────────────
local booted = false
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
-- content type changed: re-run the Show In gate
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("CHALLENGE_MODE_START")
boot:RegisterEvent("CHALLENGE_MODE_COMPLETED")
boot:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
boot:SetScript("OnEvent", function(_, ev)
    if ev ~= "PLAYER_LOGIN" then
        if booted then ApplyAll() end
        return
    end
    -- Everything used to live in one flat account table, so an existing user's
    -- tracked spell list sits in the ROOT while pkSpells now reads per
    -- character. Hand it to whoever logs in first and clear the root copy, or
    -- their setup would silently vanish. Only ever runs once.
    do
        local db = DB()
        if not db._scopeMigrated then
            db._scopeMigrated = true
            local c = CharDB()
            for k in pairs(PK_CHAR_ONLY) do
                if c[k] == nil and db[k] ~= nil then c[k] = db[k] end
                db[k] = nil
            end
        end
    end
    RegisterSettings()
    BuildMinimapButton()
    ApplyAll()
    booted = true
    if not HAS_ACTION_PINGS then
        print("|cff33ff99Arc Pings|r: waiting for Patch 12.1 (the action-ping system) — nothing to do on this client yet.")
    end
end)

SLASH_ARCPINGS1 = "/arcpings"
SLASH_ARCPINGS2 = "/pingfeed"
SlashCmdList["ARCPINGS"] = function(msg)
    msg = (msg or ""):lower():gsub("%s+", "")
    if msg == "pkdebug" then
        if _G.ArcPings_PKDebug then _G.ArcPings_PKDebug() end
        return
    end
    if msg == "blizz" or msg == "settings" then
        if settingsCategory and Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(settingsCategory:GetID())
        end
        return
    end
    print("|cff33ff99[Arc Pings]|r action-ping API: " .. (HAS_ACTION_PINGS and "|cff00ff00available|r" or "|cffff5555requires 12.1|r"))
    print(("  enabled=%s entries=%d  (/arcpings blizz for the Blizzard Settings page)"):format(tostring(Cfg("enabled")), #entries))
    _G.ArcPings_ToggleOptions()
end
