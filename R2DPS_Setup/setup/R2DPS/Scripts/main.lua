-- R2DPS  -  Remnant 2 damage meter (UE4SS Lua mod)
-- All tunables live in config.txt, display names in names.txt.
-- https://github.com/OzakiJUN/Remnant2-DPS-Meter  (MIT License)
--
-- Data source (found by probing the game's functions with UE4SS):
--   host / solo : BP_RemnantGameMode_C:PostApplyDamage(DamageInfo)  - every damage, server side
--   HOST ONLY   : only the host's game sees everyone's damage. When this PC joins someone else's
--                 game the mod does nothing (no stats, no UI) until it is the host / solo again.
--   heal        : CombatUtil:ApplyHealing
--   downed      : WoundedComponent:MulticastOnWounded
--   revived     : WoundedComponent:MulticastOnRevived / MulticastOnTargetRevived
--   death       : Character_Master_Player_C:OnDead_Event
--   rest        : Character_Master_Player_Base_C:CheckpointBegin
--   top bars    : Widget_BossHealth_C visibility + its name text
--
-- THREADING (since 0.6.0): every bit of this mod's Lua runs on the GAME THREAD. UE4SS runs RegisterHook
-- callbacks on the game thread, but LoopAsync callbacks on its async thread and RegisterKeyBind
-- callbacks on its update thread, all on the same Lua state and without a shared lock. Lua is not
-- thread-safe, so a hook firing at the same moment as a timer / key callback can corrupt the Lua
-- state and crash the game natively (no Lua error, nothing in the log). 0.5.x used LoopAsync and
-- bound the left mouse button, i.e. Lua ran on another thread on every shot while damage hooks
-- ran on the game thread. Therefore:
--   * one timer, LoopInGameThreadWithDelay (game thread), drives everything
--   * keys are polled with PlayerController:IsInputKeyDown, no RegisterKeyBind
--   * panel clicks come from a transparent Button's IsPressed, no mouse key bind
--   * no NotifyOnNewObject (it can fire on the async loading thread)
-- If this UE4SS has no LoopInGameThreadWithDelay, the mod does nothing at all (never falls back).

local MOD = "R2DPS"
local VERSION = "1.0.0"

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------
local function safe(fn, ...)
    local ok, r = pcall(fn, ...)
    if ok then return r end
    return nil
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function split(s)
    local t = {}
    for part in string.gmatch(s or "", "[^,]+") do
        local p = trim(part)
        if p ~= "" then t[#t + 1] = p end
    end
    return t
end

local function file_exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end

local function now() return os.clock() end -- wall clock on Windows

----------------------------------------------------------------------
-- folders
----------------------------------------------------------------------
-- Lua's io.open passes the path to the C runtime, which reads it in the Windows ANSI code page.
-- UE4SS gives us paths in UTF-8, so when the game is installed under a folder name with non-ASCII
-- characters (Chinese etc.) the absolute path cannot be opened. Relative paths from the game's
-- working directory are plain ASCII and work in that case, so they are tried too.
local function find_mod_dir()
    local cands = {}
    local src = safe(function() return (debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/", "\\")) end)
    local dir = src and src:match("^(.*)\\[^\\]+\\[^\\]+$")   -- ...\R2DPS\Scripts\main.lua -> ...\R2DPS
    if dir then cands[#cands + 1] = dir end
    for _, rel in ipairs({ "ue4ss\\Mods\\", "Mods\\", "Binaries\\Win64\\ue4ss\\Mods\\", "Remnant2\\Binaries\\Win64\\ue4ss\\Mods\\" }) do
        cands[#cands + 1] = rel .. MOD
    end
    local w = safe(function() return IterateGameDirectories().Game.Binaries.Win64.__absolute_path end)
    if type(w) == "string" then
        cands[#cands + 1] = w .. "\\ue4ss\\Mods\\" .. MOD
        cands[#cands + 1] = w .. "\\Mods\\" .. MOD
    end
    for _, d in ipairs(cands) do
        if file_exists(d .. "\\config.txt") then return d end
    end
    return "."
end
local MOD_DIR = find_mod_dir()

----------------------------------------------------------------------
-- config
----------------------------------------------------------------------
local DEFAULTS = {
    hud_enabled = "1", hud_offset_x = "40", hud_offset_y = "470", hud_width = "300", hud_row_height = "26",
    hud_font_size = "14", hud_max_players = "4", hud_show_title = "1", hud_bg_alpha = "0.55",
    detail_key = "H", detail_key_mode = "auto", detail_tap_time = "0.35", hold_page = "auto", reset_key = "",
    panel_width = "566", panel_height = "918", panel_offset_x = "32", panel_offset_y = "82",
    panel_bg_alpha = "0.90", panel_sources = "3",
    hold_side = "left", hold_width = "520", hold_offset_x = "40", hold_offset_y = "190",
    hold_max_height = "720", hold_show_chart = "0", hold_bg_alpha = "0.86",
    tab_label_width = "300", tab_label_offset_x = "60", tab_label_offset_y = "84",
    animations = "1", chart_bucket = "2", ui_enabled = "1", bar_search_interval = "10", diag_bars = "1",
    idle_gap = "5", dps_window = "5", history_max = "10",
    damage_mode = "health", count_heal_regen = "0",
    debug = "1", debug_max_lines = "4000", log_dir = "",
    host_damage_hooks = "/Game/_Core/GameModes/BP_RemnantGameMode.BP_RemnantGameMode_C:PostApplyDamage",
}

local function load_kv(path)
    local t = {}
    local f = io.open(path, "r")
    if not f then return t end
    for raw in f:lines() do
        local line = raw:gsub("^\239\187\191", "")
        if not line:match("^%s*#") then
            local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
            if k and k ~= "" then t[k] = v end
        end
    end
    f:close()
    return t
end

local RAW = load_kv(MOD_DIR .. "\\config.txt")
for k, v in pairs(DEFAULTS) do
    -- missing keys take the default; empty values stay empty only where "empty" means "off"
    if RAW[k] == nil or (RAW[k] == "" and k ~= "reset_key" and k ~= "log_dir") then RAW[k] = v end
end
local function num(k) return tonumber(RAW[k]) or tonumber(DEFAULTS[k]) or 0 end
local function flag(k) return num(k) ~= 0 end

local CFG = {
    hud_enabled = flag("hud_enabled"), hud_x = num("hud_offset_x"), hud_y = num("hud_offset_y"),
    hud_w = math.max(200, num("hud_width")), hud_rh = math.max(18, num("hud_row_height")),
    hud_font = math.max(9, num("hud_font_size")), hud_max = math.max(1, math.min(4, num("hud_max_players"))),
    hud_title = flag("hud_show_title"), hud_alpha = num("hud_bg_alpha"),
    detail_key = RAW.detail_key or "H", detail_mode = string.lower(RAW.detail_key_mode or "auto"),
    tap_time = math.max(0.15, num("detail_tap_time")), hold_page = string.lower(RAW.hold_page or "auto"),
    reset_key = RAW.reset_key or "",
    pw = math.max(420, num("panel_width")), ph = math.max(500, num("panel_height")),
    px = num("panel_offset_x"), py = num("panel_offset_y"), palpha = num("panel_bg_alpha"),
    psrc = math.max(0, math.min(5, num("panel_sources"))),
    hold_side = string.lower(RAW.hold_side or "left"), hw = math.max(420, num("hold_width")),
    hx = num("hold_offset_x"), hy = num("hold_offset_y"), hmaxh = math.max(400, num("hold_max_height")),
    hold_chart = flag("hold_show_chart"), halpha = num("hold_bg_alpha"),
    tw = math.max(220, num("tab_label_width")), tx = num("tab_label_offset_x"), ty = num("tab_label_offset_y"),
    anim = flag("animations"), bucket = math.max(1, num("chart_bucket")), 
    ui_enabled = flag("ui_enabled"), bar_gap = math.max(3, num("bar_search_interval")), diag_bars = flag("diag_bars"),
    idle_gap = num("idle_gap"), window = math.max(1, num("dps_window")), hist_max = num("history_max"),
    dmg_mode = string.lower(RAW.damage_mode or "health"), regen = flag("count_heal_regen"),
    debug = flag("debug"), debug_max = num("debug_max_lines"), log_dir = RAW.log_dir or "",
    host_hooks = split(RAW.host_damage_hooks or DEFAULTS.host_damage_hooks),
}

-- names.txt: internal id = display name (official Chinese if you know it)
local NAMES = load_kv(MOD_DIR .. "\\names.txt")
local function dn(id)
    if not id then return "?" end
    local n = NAMES[id]
    if n and n ~= "" then return n end
    return id
end

-- ids seen in combat that have no name yet -> names_todo.txt (written every 30 s when changed)
local TODO = { ids = {}, dirty = false, t = -100 }
local function note_unnamed(id, kind)
    if not id or id == "" or (NAMES[id] and NAMES[id] ~= "") or TODO.ids[id] then return end
    TODO.ids[id] = kind or "?"
    TODO.dirty = true
end

----------------------------------------------------------------------
-- debug log (capped)
----------------------------------------------------------------------
-- log folder: log_dir from config.txt if set, else the mod folder; if that cannot be written (see
-- find_mod_dir), the game's own log folder %LOCALAPPDATA%\Remnant2\Saved\Logs, else %TEMP%
local function writable_dir(d)
    if type(d) ~= "string" or d == "" then return nil end
    d = d:gsub("[\\/]+$", "")
    local f = io.open(d .. "\\R2DPS_debug.txt", "a")
    if f then f:close() return d end
    return nil
end
local LOCALAPPDATA = os.getenv("LOCALAPPDATA")
local LOG_DIR = writable_dir(CFG.log_dir) or writable_dir(MOD_DIR)
    or (LOCALAPPDATA and writable_dir(LOCALAPPDATA .. "\\Remnant2\\Saved\\Logs"))
    or writable_dir(os.getenv("TEMP")) or MOD_DIR
local dbg_lines = 0
local dbgf = CFG.debug and io.open(LOG_DIR .. "\\R2DPS_debug.txt", "w") or nil
local function dbg(s)
    if not dbgf or dbg_lines >= CFG.debug_max then return end
    dbg_lines = dbg_lines + 1
    dbgf:write(string.format("[%9.3f] %s\n", now(), s))
    dbgf:flush()
end
local function say(s)
    print("[" .. MOD .. "] " .. s .. "\n")
    dbg("# " .. s)
end
if not file_exists(MOD_DIR .. "\\config.txt") then
    say("config.txt could not be opened (game installed under a non-ASCII folder name?): default settings are used")
end
local dbg_once_seen = {}
local function dbg_once(key, s)
    if dbg_once_seen[key] then return end
    dbg_once_seen[key] = true
    dbg(s)
end

----------------------------------------------------------------------
-- performance log: hook call counts and slow operations, summarised every 30 s in the debug log
-- (os.clock on Windows has 1 ms resolution: only operations of a few ms show up, which is the point)
----------------------------------------------------------------------
local PERF = { n = {}, slow = {}, nslow = 0 }
local function perf_count(k) PERF.n[k] = (PERF.n[k] or 0) + 1 end
local function perf_slow(what, ms)
    PERF.nslow = PERF.nslow + 1
    local e = PERF.slow[what]
    if not e then e = { n = 0, max = 0, sum = 0 }; PERF.slow[what] = e end
    e.n, e.sum = e.n + 1, e.sum + ms
    if ms > e.max then e.max = ms end
end
-- run fn, note it when it took 2 ms or more; returns fn's results
local function timed(what, fn, ...)
    local t0 = os.clock()
    local r = table.pack(fn(...))
    local ms = (os.clock() - t0) * 1000
    if ms >= 2 then perf_slow(what, ms) end
    return table.unpack(r, 1, r.n)
end
local function perf_report()
    local parts = {}
    for k, v in pairs(PERF.n) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    local sl = {}
    for k, e in pairs(PERF.slow) do sl[#sl + 1] = string.format("%s x%d max %.0fms avg %.0fms", k, e.n, e.max, e.sum / e.n) end
    table.sort(sl)
    PERF.n, PERF.slow, PERF.nslow = {}, {}, 0
    return "calls/30s: " .. (#parts > 0 and table.concat(parts, " ") or "-") ..
        (#sl > 0 and ("  SLOW: " .. table.concat(sl, "; ")) or "")
end

----------------------------------------------------------------------
-- Unreal helpers
----------------------------------------------------------------------
local function unwrap(v)
    if type(v) ~= "userdata" then return v end
    local t = safe(function() return v:type() end)
    if t == "RemoteUnrealParam" or t == "LocalUnrealParam" then
        local ok, inner = pcall(function() return v:get() end)
        if ok then return inner end
    end
    return v
end

local function valid(o)
    if type(o) ~= "userdata" then return false end
    local ok, r = pcall(function() return o:IsValid() end)
    return ok and r == true
end

local function addr(o) return safe(function() return o:GetAddress() end) end

local function fname_str(n)
    if n == nil then return nil end
    if type(n) == "string" then return n end
    return safe(function() return n:ToString() end)
end

-- class name cache keyed by the CLASS object's address: classes stay put for the whole
-- session, while object addresses get reused when actors die and spawn
local CLS_CACHE = {}
local function class_name_of_class(c)
    local ca = c:GetAddress()
    local n = CLS_CACHE[ca]
    if not n then
        n = c:GetFName():ToString()
        CLS_CACHE[ca] = n
    end
    return n, ca
end
local function cls_name(o)
    if not valid(o) then return nil end
    return safe(function() return (class_name_of_class(o:GetClass())) end)
end
local function cls_addr(o)
    return safe(function() return o:GetClass():GetAddress() end)
end

local function obj_name(o)
    if not valid(o) then return nil end
    return safe(function() return o:GetFName():ToString() end)
end

local function weak_get(w)
    w = unwrap(w)
    if w == nil then return nil end
    if valid(w) then return w end
    local o = safe(function() return w:Get() end)
    if valid(o) then return o end
    return nil
end

local PC_CACHE = { pc = nil, t = -100, gap = 2 }
local function find_local_pc()
    local pcs = safe(function() return timed("FindAllOf PlayerController", FindAllOf, "PlayerController") end)
    if type(pcs) ~= "table" then return nil end
    for _, pc in ipairs(pcs) do
        if valid(pc) and safe(function() return pc:IsLocalController() end) == true then return pc end
    end
    for _, pc in ipairs(pcs) do
        if valid(pc) and valid(safe(function() return pc.Player end)) then return pc end
    end
    return nil
end

-- cached: FindAllOf walks every object in the game, so it only runs when the cached controller is
-- gone, at most every 2 s, slowing down to every 10 s while it keeps finding nothing (loading)
local function local_pc()
    if valid(PC_CACHE.pc) then return PC_CACHE.pc end
    local t = now()
    if t - PC_CACHE.t < PC_CACHE.gap then return nil end
    PC_CACHE.t = t
    PC_CACHE.pc = find_local_pc()
    PC_CACHE.gap = PC_CACHE.pc and 2 or math.min(PC_CACHE.gap + 2, 10)
    return PC_CACHE.pc
end

local function strip_id(n)
    if not n then return "?" end
    n = n:gsub("_C$", "")
    n = n:gsub("^Weapon_", ""):gsub("^Mod_", ""):gsub("^Skill_", "")
    n = n:gsub("^Character_Minion_Summon_", ""):gsub("^Character_Minion_", ""):gsub("^Character_", ""):gsub("^Char_", "")
    return n
end

----------------------------------------------------------------------
-- player resolution (owner chain -> PlayerState), cached per object
----------------------------------------------------------------------
local PLAYERS = {}      -- ps address -> { name, ps }
local res_cache = {}    -- object address -> { key, pawn, t }
local LOCAL_KEY = nil

-- players are keyed by NAME: leaving and rejoining (or a map change) creates a new PlayerState
-- object, and the same person must stay one row. The object address is only a fallback when
-- the game never reports a name for that player.
-- PS_KEY: PlayerState address -> { k = key, t = when the name was last checked }. A destroyed
-- PlayerState's address can be reused by another player's new one (map change, leave / join), so
-- the name behind a cached address is re-checked every 10 s, and the table is cleared on map load.
local PS_KEY = { first = {} }   -- first[address] = when it was first seen unnamed
local function ps_name(ps)
    local name = safe(function() return fname_str(ps:GetPlayerName()) end)
    if not name or name == "" then name = safe(function() return fname_str(ps.PlayerNamePrivate) end) end
    return name
end
local function player_key_of_ps(ps)
    local a = addr(ps)
    if not a then return nil end
    local e = PS_KEY[a]
    if e then
        local t = now()
        if t - e.t < 10 then
            PLAYERS[e.k].ps = ps
            return e.k
        end
        e.t = t
        local n = ps_name(ps)
        if not n or n == "" or e.k == "n:" .. n or (e.k == a) then
            PLAYERS[e.k].ps = ps
            return e.k
        end
        dbg("PlayerState address reused by another player: " .. tostring(PLAYERS[e.k] and PLAYERS[e.k].name) .. " -> " .. n)
        PS_KEY[a] = nil
        for oa, c in pairs(res_cache) do if c.key == e.k then res_cache[oa] = nil end end
    end
    local name, k = ps_name(ps), nil
    if name and name ~= "" then
        k = "n:" .. name
    else
        local t = now()
        PS_KEY.first[a] = PS_KEY.first[a] or t
        if t - PS_KEY.first[a] < 5 then return nil end -- the name usually arrives within a moment
        k = a
        name = "P" .. tostring(a)
    end
    PS_KEY[a] = { k = k, t = now() }
    local p = PLAYERS[k]
    if not p then
        PLAYERS[k] = { key = k, name = name, ps = ps }
        if k ~= a then dbg("player: " .. name) end
    else
        p.ps = ps
        dbg("player rejoined / new map: " .. name .. " (same row as before)")
    end
    return k
end

-- returns playerKey, playerPawn, isPlayerItself  (key nil when the object is not owned by a player;
-- isPlayerItself = the object itself has a PlayerState, also while the player's name is unknown)
local function resolve_player(o)
    if not valid(o) then return nil end
    local a = addr(o)
    local ca = cls_addr(o)
    local t = now()
    local c = a and res_cache[a]
    if c and t - c.t < 3 and c.ca == ca then return c.key, c.pawn, c.isp end
    local cur = o
    local key, pawn, unnamed, isp = nil, nil, false, false
    for depth = 1, 7 do
        if not valid(cur) then break end
        local ps = safe(function() return cur.PlayerState end)
        if valid(ps) then
            if depth == 1 then isp = true end
            key = player_key_of_ps(ps)
            unnamed = key == nil
            pawn = cur
            -- a controller has PlayerState too; prefer its pawn
            local p = safe(function() return cur.Pawn end)
            if valid(p) then pawn = p end
            break
        end
        local nxt = safe(function() return cur.Owner end)
        if not valid(nxt) or addr(nxt) == addr(cur) then nxt = safe(function() return cur.Instigator end) end
        if not valid(nxt) or addr(nxt) == addr(cur) then break end
        cur = nxt
    end
    if a and not unnamed then res_cache[a] = { key = key, pawn = pawn, t = t, ca = ca, isp = isp } end
    return key, pawn, isp
end

local function is_player_pawn(o)
    if not valid(o) then return false end
    local ps = safe(function() return o.PlayerState end)
    return valid(ps)
end

----------------------------------------------------------------------
-- classification
----------------------------------------------------------------------
local CAT_ORDER = { "long", "hand", "melee", "mod", "skill", "summon", "other" }
local CAT_LABEL = { long = "长枪", hand = "手枪", melee = "近战", mod = "改装", skill = "技能", summon = "召唤", other = "其他" }
for k, v in pairs(CAT_LABEL) do if NAMES["cat_" .. k] and NAMES["cat_" .. k] ~= "" then CAT_LABEL[k] = NAMES["cat_" .. k] end end

local weapon_slot_cache = {}
local function weapon_slot(cause, dtype)
    local cn = cls_name(cause) or "?"
    local s = weapon_slot_cache[cn]
    if s then return s end
    local path = safe(function() return cause:GetClass():GetFullName() end) or ""
    local lp = path:lower()
    if lp:find("/handgun", 1, true) then s = "hand"
    elseif lp:find("/longgun", 1, true) then s = "long"
    elseif lp:find("/melee", 1, true) then s = "melee"
    elseif (dtype or ""):find("Melee", 1, true) then s = "melee"
    elseif (dtype or ""):lower():find("handgun", 1, true) then s = "hand"
    else s = "long" end
    weapon_slot_cache[cn] = s
    dbg("weapon class " .. cn .. " -> " .. s .. "  (" .. path .. ")")
    return s
end

local function status_of(dtype)
    local d = (dtype or ""):lower()
    if d:find("bleed") then return "Bleed" end
    if d:find("burn") or d:find("fire") then return "Burning" end
    if d:find("overload") then return "Overloaded" end
    if d:find("corro") or d:find("acid") then return "Corroded" end
    if d:find("shock") then return "Shock" end
    if d:find("curse") then return "Curse" end
    if d:find("blight") or d:find("rot") then return "Blight" end
    return "DOT"
end

-- returns category, source id
local function classify(owner, owner_is_pawn, cause, dtype)
    local d = dtype or ""
    if owner and not owner_is_pawn then
        return "summon", strip_id(cls_name(owner))
    end
    local cc = cause and cls_name(cause) or nil
    if cc then
        if cc:match("^Mod_") then return "mod", strip_id(cc) end
        if cc:match("^Skill_") then return "skill", strip_id(cc) end
        if cc:match("^Weapon_") then return weapon_slot(cause, d), strip_id(cc) end
        if not is_player_pawn(cause) then
            -- some other actor owned by the player (projectile, aura, relic effect ...)
            if cc:find("Summon") or cc:find("Minion") or cc:find("Companion") or cc:find("Turret") then
                return "summon", strip_id(cc)
            end
            dbg_once("cause:" .. cc, "unclassified cause actor " .. cc .. " dtype=" .. d)
            return "other", strip_id(cc)
        end
    end
    -- cause is the player himself (or missing): decide by damage type name
    local src = d:gsub("^DamageType_", ""):gsub("_C$", "")
    if d:find("Skill") then return "skill", src end
    if d:find("_Mod") then return "mod", src end
    if d:find("Melee") then return "melee", src end
    if d:lower():find("handgun") then return "hand", src end
    dbg_once("dtype:" .. d, "unclassified damage type " .. d .. " (cause=" .. tostring(cc) .. ")")
    return "other", src
end

----------------------------------------------------------------------
-- fights
----------------------------------------------------------------------
local F = {
    cur = nil,          -- current fight
    pending = true,     -- true: next player damage starts a new fight
    next_title = nil,   -- title for the next fight (top bar names)
    next_kind = nil,    -- "boss" / "elite"
    history = {},       -- finished bar fights, newest first
    rev = 0,            -- bumps on every change (UI refresh)
}

local function new_player_stats(key)
    return {
        key = key, total = 0, hits = 0, direct = 0, crits = 0, weak = 0, maxhit = 0,
        cats = {}, taken = 0, heal = 0, heal_ally = 0, downs = 0, revived = 0, revives = 0, deaths = 0,
        buckets = {},   -- per-second damage, recent seconds only (live DPS)
        tl = {},        -- damage per chart_bucket seconds of fight time (DPS chart)
    }
end

local function fstats(f, key)
    local p = f.players[key]
    if not p then
        p = new_player_stats(key)
        f.players[key] = p
    end
    return p
end

-- downs / deaths / revives / damage taken that happen while no fight is running (e.g. enemies hit
-- you before anyone hits back) are kept here and join the next fight if it starts within 20 s
F.pre = {}
local PRE_FIELDS = { "taken", "downs", "revived", "revives", "deaths" }

local function start_fight(t)
    F.cur = {
        title = F.next_title, kind = F.next_kind or "normal",
        start = t, last = t, active = 0, players = {}, total = 0, nb = 0,
    }
    for key, e in pairs(F.pre) do
        if t - e.t <= 20 then
            local p = fstats(F.cur, key)
            for _, k in ipairs(PRE_FIELDS) do p[k] = p[k] + e[k] end
        end
    end
    F.pre = {}
    F.pending = false
    F.rev = F.rev + 1
    F.just_started = true -- the top bar code searches for new bar widgets once
    dbg("fight start: " .. tostring(F.cur.title or "normal") .. " kind=" .. F.cur.kind)
end

local function end_fight(reason)
    local f = F.cur
    if f and not F.pending then
        dbg(string.format("fight end (%s): %s total=%.0f active=%.1fs", reason, tostring(f.title or "normal"), f.total, f.active))
        f.ended = true
        if f.kind ~= "normal" and f.total > 0 then
            table.insert(F.history, 1, f)
            while #F.history > CFG.hist_max do table.remove(F.history) end
        end
    end
    F.pending = true
    F.rev = F.rev + 1
end

local function touch_fight(t)
    if F.pending or not F.cur then start_fight(t) end
    local f = F.cur
    local dt = t - f.last
    if dt > 0 and dt <= CFG.idle_gap then f.active = f.active + dt end
    f.last = t
    return f
end

-- stats that should receive non-damage events: the running fight, or the buffer for the next one
-- (a finished fight never changes again)
local function ev_stats(key)
    if F.cur and not F.pending then return fstats(F.cur, key) end
    local e = F.pre[key]
    if not e then
        e = { taken = 0, downs = 0, revived = 0, revives = 0, deaths = 0 }
        F.pre[key] = e
    end
    e.t = now()
    return e
end

local function add_bucket(p, t, amt)
    local s = math.floor(t)
    p.buckets[s] = (p.buckets[s] or 0) + amt
end

local function realtime_dps(p, t)
    local s = math.floor(t)
    local sum = 0
    for k, v in pairs(p.buckets) do
        if k > s - CFG.window then sum = sum + v
        elseif k < s - 60 then p.buckets[k] = nil end
    end
    return sum / CFG.window
end

----------------------------------------------------------------------
-- damage processing
----------------------------------------------------------------------
local ev_count = 0
local target_ok_cache = {}

local function target_is_valid_enemy(target)
    local cn = cls_name(target)
    if not cn then return false end
    local ok = target_ok_cache[cn]
    if ok == nil then
        ok = (safe(function() return target:IsA("/Script/Engine.Character") end) == true)
            and not cn:find("Breakable", 1, true)
        target_ok_cache[cn] = ok
        dbg("target class " .. cn .. " counted=" .. tostring(ok))
    end
    return ok
end

local function read_amounts(info)
    return info.Damage, info.HealthDelta, info.AbsorbedDamage
end
local function read_rest(info)
    return info.Owner, info.Cause, info.Target, info.DamageType, info.Critical, info.WeakSpot, info.SecondaryDamage
end

local IS_HOST = nil -- true: host / solo, false: joined someone else's game (mod idle), nil: unknown yet

-- add one hit of a player to the running fight
local function account_hit(okey, cat, src, eff, dtype, crit, weakspot, dot, t)
    local f = touch_fight(t)
    local p = fstats(f, okey)
    p.total = p.total + eff
    p.hits = p.hits + 1
    if not dot then
        p.direct = p.direct + 1
        if crit then p.crits = p.crits + 1 end
        if weakspot then p.weak = p.weak + 1 end
    end
    if eff > p.maxhit then p.maxhit = eff end
    note_unnamed(src, CAT_LABEL[cat])
    local c = p.cats[cat]
    if not c then
        c = { total = 0, dot = 0, src = {}, dots = {} }
        p.cats[cat] = c
    end
    c.total = c.total + eff
    c.src[src] = (c.src[src] or 0) + eff
    if dot then
        c.dot = c.dot + eff
        local st = status_of(dtype)
        note_unnamed(st, "持续伤害")
        c.dots[st] = (c.dots[st] or 0) + eff
    end
    add_bucket(p, t, eff)
    local bi = math.floor(f.active / CFG.bucket) + 1
    p.tl[bi] = (p.tl[bi] or 0) + eff
    if bi > f.nb then f.nb = bi end
    f.total = f.total + eff
    F.rev = F.rev + 1
end

local function process_damage(info)
    info = unwrap(info)
    if info == nil then return end
    local t = now()
    local ok, dmg, hd, absorbed = pcall(read_amounts, info)
    if not ok then dbg_once("readamt", "damage struct read failed: " .. tostring(dmg)) return end
    dmg, hd, absorbed = dmg or 0, hd or 0, absorbed or 0

    local eff
    if CFG.dmg_mode == "raw" then
        eff = dmg
    else
        eff = (hd < 0 and -hd or 0) + (absorbed > 0 and absorbed or 0)
        if eff > dmg and dmg > 0 then eff = dmg end
    end
    if eff <= 0 then return end

    local ok2, owner, cause, target, dtc, crit, weakspot, secondary = pcall(read_rest, info)
    if not ok2 then dbg_once("readrest", "damage struct read failed: " .. tostring(owner)) return end
    owner, cause, target = weak_get(owner), weak_get(cause), weak_get(target)
    local dtype = (dtc and safe(class_name_of_class, dtc)) or ""
    crit, weakspot, secondary = crit == true, weakspot == true, secondary == true

    ev_count = ev_count + 1
    local okey, opawn = resolve_player(owner)
    local tkey, _, tisp = resolve_player(target)
    if not tkey and tisp then return end -- a player whose name is not known yet

    if ev_count <= 60 then
        dbg(string.format("dmg %s -> %s  cause=%s type=%s dmg=%.1f hd=%.1f abs=%.1f crit=%s weak=%s dot=%s okey=%s tkey=%s",
            tostring(cls_name(owner)), tostring(cls_name(target)), tostring(cls_name(cause)), dtype,
            dmg, hd, absorbed, tostring(crit), tostring(weakspot), tostring(secondary), tostring(okey), tostring(tkey)))
    end

    -- damage taken by a player (from non-players only; friendly fire and self damage ignored)
    if tkey then
        if not okey then
            local p = ev_stats(tkey)
            p.taken = p.taken + eff
            F.rev = F.rev + 1
        end
        return
    end

    if not okey then return end                       -- enemy vs enemy, environment ...
    if not target_is_valid_enemy(target) then return end

    local owner_is_pawn = opawn and owner and addr(opawn) == addr(owner) or false
    if owner and not owner_is_pawn and is_player_pawn(owner) then owner_is_pawn = true end
    local cat, src = classify(owner, owner_is_pawn, cause, dtype)
    local dot = secondary or dtype:find("DOT", 1, true) ~= nil
    account_hit(okey, cat, src, eff, dtype, crit, weakspot, dot, t)
end

----------------------------------------------------------------------
-- other events
----------------------------------------------------------------------
local function owner_of_component(comp)
    comp = unwrap(comp)
    if not valid(comp) then return nil end
    return safe(function() return comp:GetOwner() end)
end

local function on_heal(owner, cause, target, healing, mod, scalar)
    local f = F.cur
    if not f or F.pending then return end           -- most regen ticks end here, no reads at all
    if IS_HOST ~= true then return end
    local h = unwrap(healing) or 0
    if type(h) ~= "number" or h <= 0 then return end
    local o = unwrap(owner)
    local tg = unwrap(target)
    local m = unwrap(mod) or 0
    local s = unwrap(scalar) or 1
    if not CFG.regen and h < 1 and valid(o) and valid(tg) and addr(o) == addr(tg) then return end -- regen ticks
    local amount = h * (1 + (type(m) == "number" and m or 0) / 100) * (type(s) == "number" and s or 1)
    local key = resolve_player(o)
    if not key then return end
    local p = fstats(f, key)
    p.heal = p.heal + amount
    -- healing a teammate (not yourself) counts for the MVP support score
    local tkey = valid(tg) and resolve_player(tg) or nil
    if tkey and tkey ~= key then p.heal_ally = p.heal_ally + amount end
    F.rev = F.rev + 1
end

local function on_wounded(comp)
    local key = resolve_player(owner_of_component(comp))
    dbg("downed: " .. tostring(key and PLAYERS[key] and PLAYERS[key].name))
    if key then local p = ev_stats(key); p.downs = p.downs + 1; F.rev = F.rev + 1 end
end

local function on_revived(comp, self_revive)
    local key = resolve_player(owner_of_component(comp))
    dbg("revived: " .. tostring(key and PLAYERS[key] and PLAYERS[key].name) .. " self=" .. tostring(unwrap(self_revive)))
    if key then local p = ev_stats(key); p.revived = p.revived + 1; F.rev = F.rev + 1 end
end

local function on_target_revived(self_comp, target_comp)
    local key = resolve_player(owner_of_component(self_comp))
    local tkey = resolve_player(owner_of_component(target_comp))
    dbg("revive given by " .. tostring(key and PLAYERS[key] and PLAYERS[key].name) .. " to " .. tostring(tkey and PLAYERS[tkey] and PLAYERS[tkey].name))
    if key and key ~= tkey then local p = ev_stats(key); p.revives = p.revives + 1; F.rev = F.rev + 1 end
end

local last_death = {}
local function on_dead(char)
    local key = resolve_player(unwrap(char))
    if not key then return end
    local t = now()
    if last_death[key] and t - last_death[key] < 2 then return end
    last_death[key] = t
    dbg("death: " .. tostring(PLAYERS[key] and PLAYERS[key].name))
    local p = ev_stats(key); p.deaths = p.deaths + 1; F.rev = F.rev + 1
end

local BAR -- defined below
local function on_checkpoint()
    local t = now()
    if F.last_cp and t - F.last_cp < 3 then return end -- one rest fires this for every player character
    F.last_cp = t
    dbg("checkpoint / rest")
    local cur = F.cur
    end_fight("rest")
    F.pre = {}
    -- resting wipes a normal fight from the screen (boss / elite fights stay: they are in the history)
    if cur and cur.kind == "normal" then
        F.cur = nil
        F.rev = F.rev + 1
    end
    F.next_title, F.next_kind = nil, nil
    if BAR then BAR.prev_any = false end -- a bar still visible after respawn starts a fresh bar fight
end

----------------------------------------------------------------------
-- hooks (retried after every map load; re-registered if the function object changed)
----------------------------------------------------------------------
local HOOKS = {}   -- path -> { fn_addr, gen, ok }

local function hook(path, handler)
    local fobj = safe(function() return StaticFindObject(path) end)
    if not valid(fobj) then return false end
    local fa = addr(fobj)
    local h = HOOKS[path]
    if h and h.ok and h.fn_addr == fa then return true end
    local gen = (h and h.gen or 0) + 1
    local short = "hook " .. (path:match(":([^:]+)$") or path)
    local ok, err = pcall(RegisterHook, path, function(ctx, ...)
        local cur = HOOKS[path]
        if not cur or cur.gen ~= gen then return end
        local t0 = os.clock()
        local ok2, err2 = pcall(handler, ctx, ...)
        local ms = (os.clock() - t0) * 1000
        if ms >= 2 then perf_slow(short, ms) end
        if not ok2 then dbg_once("err:" .. path .. tostring(err2), "handler error " .. path .. ": " .. tostring(err2)) end
    end)
    HOOKS[path] = { fn_addr = fa, gen = gen, ok = ok }
    dbg((ok and "hooked " or "hook FAILED ") .. path .. (ok and "" or (": " .. tostring(err))))
    return ok
end

local function detect_host()
    local pc = local_pc()
    if not pc then return nil end
    local auth = safe(function() return pc:HasAuthority() end)
    if auth == nil then
        auth = valid(safe(function() return FindFirstOf("GameModeBase") end))
    end
    return auth == true
end

local function install_hooks()
    local h = detect_host()
    if h ~= nil and h ~= IS_HOST then
        IS_HOST = h
        say("mode: " .. (h and "host / solo" or "joined someone else's game: mod idle (only the host sees everyone's damage)"))
        if not h then end_fight("joined another game"); F.cur = nil; F.rev = F.rev + 1 end
    end
    -- nothing is hooked until we know we are the host; hooks stay once installed (handlers check IS_HOST)
    if IS_HOST ~= true then return end
    for _, p in ipairs(CFG.host_hooks) do
        hook(p, function(ctx, info) if IS_HOST == true then perf_count("dmg"); process_damage(info) end end)
    end
    hook("/Script/GunfireRuntime.CombatUtil:ApplyHealing", function(ctx, o, c, tg, h, m, s) if IS_HOST == true then perf_count("heal"); on_heal(o, c, tg, h, m, s) end end)
    hook("/Script/GunfireRuntime.WoundedComponent:MulticastOnWounded", function(ctx) if IS_HOST == true then on_wounded(ctx) end end)
    hook("/Script/GunfireRuntime.WoundedComponent:MulticastOnRevived", function(ctx, selfrev) if IS_HOST == true then on_revived(ctx, selfrev) end end)
    hook("/Script/GunfireRuntime.WoundedComponent:MulticastOnTargetRevived", function(ctx, tcomp) if IS_HOST == true then on_target_revived(ctx, tcomp) end end)
    hook("/Game/Characters/Player/Base/Character_Master_Player.Character_Master_Player_C:OnDead_Event", function(ctx) if IS_HOST == true then on_dead(ctx) end end)
    hook("/Game/Characters/Player/Base/Character_Master_Player_Base.Character_Master_Player_Base_C:CheckpointBegin", function(ctx) if IS_HOST == true then on_checkpoint() end end)
end

----------------------------------------------------------------------
-- top health bars (boss / elite)
-- Bar widgets (Widget_BossHealth_C and subclasses) are found with FindAllOf, which walks every
-- object in the game (slow). So it never runs on a timer while nothing happens, only:
--   * 3 s and 15 s after a map load
--   * when a fight starts (at most every bar_search_interval s)
--   * during a fight in which no bar is visible, every bar_search_interval s (a boss can bring a
--     NEW bar widget while an old one still exists; 0.6.0 and older never looked again then)
-- Visibility of the known widgets is checked cheaply every 0.25 s.
----------------------------------------------------------------------
BAR = { widgets = {}, search_t = -100, due = { now() + 3 }, names = {}, prev_any = false, name_cache = {}, last_n = -1, diag_map = false }

local poll_bars, bar_map_loaded
do
local function bar_search(t, why)
    BAR.search_t = t
    local list = safe(function() return timed("FindAllOf Widget_BossHealth_C", FindAllOf, "Widget_BossHealth_C") end)
    BAR.widgets = type(list) == "table" and list or {}
    if #BAR.widgets ~= BAR.last_n then
        BAR.last_n = #BAR.widgets
        dbg("top bar widgets: " .. #BAR.widgets .. " (search: " .. why .. ")")
    end
end

bar_map_loaded = function(t)
    BAR.widgets, BAR.prev_any, BAR.name_cache, BAR.last_n = {}, false, {}, -1
    BAR.due = { t + 3, t + 15 }
    BAR.diag_map = false
end

-- walk a widget and its children (into nested user widgets too); visit(w, class) may return "skip"
local function walk(w, depth, visit, budget)
    if budget.n <= 0 or depth > 14 or not valid(w) then return end
    budget.n = budget.n - 1
    local cn = cls_name(w) or ""
    if visit(w, cn) == "skip" then return end
    local tree = safe(function() return w.WidgetTree end)
    if valid(tree) then
        walk(safe(function() return tree.RootWidget end), depth + 1, visit, budget)
        return
    end
    local n = safe(function() return w:GetChildrenCount() end)
    if type(n) == "number" and n > 0 then
        for i = 0, math.min(n, 64) - 1 do
            walk(safe(function() return w:GetChildAt(i) end), depth + 1, visit, budget)
        end
    end
end

local function is_text_class(cn) return cn == "TextBlock" or cn:find("TextBlock", 1, true) ~= nil end
local function text_of(tb) return safe(function() return fname_str(tb:GetText()) end) or "" end
local function is_name_text(txt) return txt ~= "" and not txt:match("^[%d%.,%%%s/]+$") end

-- name (largest text in the bar) + whether it shows affixes (= elite), from the bar's own widgets
local function read_bar_tree(w)
    local best, best_size, affix, ntext = "", -1, false, 0
    walk(w, 0, function(o, cn)
        if cn == "Widget_HUD_Boss_Attribute_C" then
            if safe(function() return o:IsVisible() end) == true then
                walk(o, 0, function(o2, cn2)
                    if is_text_class(cn2) and text_of(o2) ~= "" and safe(function() return o2:IsVisible() end) == true then affix = true end
                end, { n = 40 })
            end
            return "skip"
        end
        if is_text_class(cn) then
            ntext = ntext + 1
            local txt = text_of(o)
            local size = safe(function() return o.Font.Size end) or 0
            if is_name_text(txt) and size > best_size then best, best_size = txt, size end
        end
    end, { n = 400 })
    return best, affix, ntext
end

-- old method (all TextBlocks in the game): only as a last resort, once per bar
local function read_bar_scan(w, wa)
    local tbs = safe(function() return timed("FindAllOf TextBlock", FindAllOf, "TextBlock") end) or {}
    local best, best_size = "", -1
    for _, tb in ipairs(tbs) do
        local owner = safe(function() return tb:GetOuter():GetOuter() end)
        if valid(owner) and addr(owner) == wa then
            local txt = text_of(tb)
            local size = safe(function() return tb.Font.Size end) or 0
            if is_name_text(txt) and size > best_size then best, best_size = txt, size end
        end
    end
    return best
end

local function read_bar(w)
    local wa = addr(w)
    local c = BAR.name_cache[wa]
    if c and (c.name ~= "" or c.tries >= 3) then return c end
    local tries = c and c.tries or 0
    local name, affix, ntext = timed("read bar name", read_bar_tree, w)
    if name == "" and tries == 2 then name = read_bar_scan(w, wa) end
    c = { name = name, elite = affix or (c and c.elite) or false, tries = tries + 1 }
    BAR.name_cache[wa] = c
    dbg(string.format("top bar %s: name='%s' affixes=%s (texts in bar: %s, try %d)", tostring(cls_name(w)), name, tostring(c.elite), tostring(ntext), c.tries))
    return c
end

-- once per map, when a fight runs 15 s with no bar: list widgets that look like health bars, so
-- a boss with a different bar widget can be added later
local function diag_no_bar(t)
    BAR.diag_map = true
    local list = safe(function() return timed("diag FindAllOf UserWidget", FindAllOf, "UserWidget") end) or {}
    local seen, lines = {}, 0
    for _, w in ipairs(list) do
        local cn = cls_name(w) or ""
        local l = cn:lower()
        if not seen[cn] and (l:find("boss") or l:find("health") or l:find("hpbar") or l:find("enemybar")) then
            seen[cn] = true
            lines = lines + 1
            if lines > 40 then break end
            dbg(string.format("diag widget: %s visible=%s inviewport=%s", cn,
                tostring(safe(function() return w:IsVisible() end)), tostring(safe(function() return w:IsInViewport() end))))
        end
    end
    dbg("diag: fight ran 15 s without a top bar; " .. #list .. " widgets checked, " .. lines .. " look like bars (listed above)")
end

poll_bars = function(t)
    -- scheduled / triggered searches
    if BAR.due[1] and t >= BAR.due[1] then
        table.remove(BAR.due, 1)
        bar_search(t, "map load")
    elseif F.just_started then
        F.just_started = false
        if t - BAR.search_t >= CFG.bar_gap then bar_search(t, "fight start") end
    elseif not BAR.prev_any and F.cur and not F.pending and t - BAR.search_t >= CFG.bar_gap then
        bar_search(t, "fight without bar")
    end

    local names, elite, any = {}, false, false
    for _, w in ipairs(BAR.widgets) do
        if valid(w) and safe(function() return w:IsVisible() end) == true then
            any = true
            local c = read_bar(w)
            if c.name ~= "" then names[#names + 1] = c.name end
            if c.elite then elite = true end
        elseif valid(w) then
            BAR.name_cache[addr(w)] = nil
        end
    end
    local f = F.cur
    if any and not BAR.prev_any then
        local title = (#names > 0) and table.concat(names, " / ") or "?"
        local kind = elite and "elite" or "boss"
        if f and not F.pending and f.kind == "normal" and t - f.start <= 20 then
            -- the bar was found a bit late (new widget): this fight IS the bar fight
            f.title, f.kind = title, kind
            F.rev = F.rev + 1
            dbg("top bar found during a fresh fight: fight becomes " .. kind .. " '" .. title .. "'")
        else
            -- a bar appeared: close the running fight, next damage starts the bar fight
            end_fight("bar appeared")
            F.next_title, F.next_kind = title, kind
        end
    elseif any and BAR.prev_any and #names > 0 then
        local title = table.concat(names, " / ")
        if f and not F.pending and f.kind ~= "normal" and (f.title == nil or f.title == "?" or #title > #f.title) then
            f.title = title
            F.rev = F.rev + 1
        elseif F.pending then
            F.next_title = title
        end
        if f and not F.pending and f.kind == "boss" and elite then f.kind = "elite"; F.rev = F.rev + 1 end
    elseif not any and BAR.prev_any then
        if f and not F.pending and f.kind ~= "normal" then end_fight("bar gone") end
        F.next_title, F.next_kind = nil, nil
    end
    BAR.prev_any = any
    if CFG.diag_bars and not any and not BAR.diag_map and f and not F.pending and f.kind == "normal" and f.active >= 15 then
        diag_no_bar(t)
    end
end
end -- do (top bars)


----------------------------------------------------------------------
-- number formatting
----------------------------------------------------------------------
local function fmt(n)
    n = n or 0
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
    local s = string.format("%d", math.floor(n + 0.5))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (r:gsub("^,", ""))
end
local function pct(a, b)
    if not b or b <= 0 then return "0%" end
    return string.format("%d%%", math.floor(a * 100 / b + 0.5))
end
local function mmss(s)
    s = math.floor(s or 0)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
local function numeps(v) return math.max(0.5, math.abs(v or 0) * 0.003) end

local function sorted_players(f)
    local list = {}
    for _, p in pairs(f.players) do list[#list + 1] = p end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.key) < tostring(b.key)
    end)
    return list
end

local function pname(key)
    local p = PLAYERS[key]
    return p and p.name or "?"
end

local function title_text(f)
    if not f then return "无战斗数据" end
    if f.kind == "normal" then return "普通战斗" end
    return f.title or "?"
end

----------------------------------------------------------------------
-- MVP score + fun titles (evaluated per fight, cached until the data changes)
--   score: each part is "this player's share of the team", weighted, times the player count
--          (team average = 100). damage 55%, revives given 20%, healing teammates 10%,
--          survival 15% (1 / (1 + downs + 2 x deaths)). A part nobody on the team did moves
--          its weight to damage. No MVP for solo fights or normal fights shorter than 15 s.
--   titles: 3 per player, the most remarkable ones first
----------------------------------------------------------------------
local MVPW = { dmg = 0.55, rev = 0.20, heal = 0.10, live = 0.15 }

local function utf8_len(s)
    local ok, n = pcall(utf8.len, s)
    return (ok and n) or #s
end

-- t = { name, strength, tone }  tone: "best" (gold) / "fun" (red) / category key (its color) / "plain"
local function player_facts(f, p, dur)
    local x = { p = p }
    x.share = f.total > 0 and p.total / f.total or 0
    x.crit = p.direct >= 20 and p.crits / p.direct or nil
    x.weak = p.direct >= 20 and p.weak / p.direct or nil
    x.cat = {}
    local ncat10 = 0
    local dot = 0
    for _, k in ipairs(CAT_ORDER) do
        local c = p.cats[k]
        local sh = (c and p.total > 0) and c.total / p.total or 0
        x.cat[k] = sh
        if sh >= 0.10 then ncat10 = ncat10 + 1 end
        if c then dot = dot + c.dot end
    end
    x.ncat10 = ncat10
    x.dot = p.total > 0 and dot / p.total or 0
    -- timeline: peak bucket, first / second half, active buckets
    local nb = math.max(f.nb or 0, 0)
    local tl = p.tl or {}
    local peak, h1, h2, act = 0, 0, 0, 0
    for b = 1, nb do
        local v = tl[b] or 0
        if v > peak then peak = v end
        if v > 0 then act = act + 1 end
        if b <= nb / 2 then h1 = h1 + v else h2 = h2 + v end
    end
    x.peak = peak / CFG.bucket
    x.h1, x.h2, x.nb, x.active_ratio = h1, h2, nb, nb > 0 and act / nb or 0
    return x
end

local function eval_fight(f)
    if not f then return nil end
    -- a finished fight never changes again: compute once (after it ended); a running one when data changed
    if f._ev and (f._ev_final or f._ev_rev == F.rev or (not f.ended and now() - (f._ev_t or 0) < 0.5)) then return f._ev end
    local list = sorted_players(f)
    local n = #list
    local dur = math.max(f.active, 1)
    local ev = { score = {}, titles = {}, mvp = nil }

    -- MVP score
    if n >= 2 and f.total > 0 and (f.kind ~= "normal" or f.active >= 15) then
        local srev, sheal, slive = 0, 0, 0
        local live = {}
        for _, p in ipairs(list) do
            srev = srev + p.revives
            sheal = sheal + (p.heal_ally or 0)
            live[p.key] = 1 / (1 + p.downs + 2 * p.deaths)
            slive = slive + live[p.key]
        end
        local wd = MVPW.dmg + (srev > 0 and 0 or MVPW.rev) + (sheal > 0 and 0 or MVPW.heal)
        local best, bestv = nil, -1
        for _, p in ipairs(list) do
            local v = wd * p.total / f.total
            if srev > 0 then v = v + MVPW.rev * p.revives / srev end
            if sheal > 0 then v = v + MVPW.heal * (p.heal_ally or 0) / sheal end
            v = v + MVPW.live * live[p.key] / slive
            v = 100 * n * v
            ev.score[p.key] = v
            if v > bestv + 0.001 or (math.abs(v - bestv) <= 0.001 and best and p.total > best.total) then
                best, bestv = p, v
            end
        end
        ev.mvp = best and best.key
    end

    -- titles
    local fx = {}
    for _, p in ipairs(list) do fx[p.key] = player_facts(f, p, dur) end
    local cand = {}
    for _, p in ipairs(list) do cand[p.key] = {} end
    local function add(key, name, strength, tone) local c = cand[key]; c[#c + 1] = { name, strength, tone } end
    -- team-best titles (2+ players): the single best player on that stat
    local function top(getter, minv)
        local bk, bv, second = nil, nil, nil
        for _, p in ipairs(list) do
            local v = getter(fx[p.key])
            if v ~= nil and v >= (minv or -math.huge) then
                if bv == nil or v > bv then second = bv; bk, bv = p.key, v
                elseif second == nil or v > second then second = v end
            end
        end
        return bk, bv, second
    end
    if n >= 2 then
        local k, v = top(function(x) return x.share end)
        if k and v >= 1.2 / n then add(k, "输出担当", 3 + v, "best") end
        k = top(function(x) return x.p.revives end, 1)
        if k then add(k, "救火队员", 3.2, "best") end
        k = top(function(x) return x.p.heal_ally end, 100)
        if k then add(k, "奶妈", 3.0, "best") end
        k, v = top(function(x) return x.weak end, 0.3)
        if k then add(k, "狙神", 2.5 + v, "best"); fx[k].no_weak = true end
        k, v = top(function(x) return x.crit end, 0.2)
        if k then add(k, "暴击狂人", 2.5 + v, "best"); fx[k].no_crit = true end
        local s2
        k, v, s2 = top(function(x) return x.p.maxhit end, 1)
        if k and (not s2 or v >= 1.3 * s2) then add(k, "一击入魂", 2.4, "best") end
        k = top(function(x) return x.peak end, 1)
        if k then add(k, "爆发之王", 2.3, "best") end
        k = top(function(x) return x.p.deaths == 0 and x.p.taken > 0 and x.p.taken or nil end)
        if k then add(k, "肉盾", 2.2, "best") end
        k = top(function(x) return x.p.downs end, 2)
        if k then add(k, "躺平大师", 2.6, "fun") end
        local lk, lv = nil, nil
        for _, p in ipairs(list) do
            local sh = fx[p.key].share
            if lv == nil or sh < lv then lk, lv = p.key, sh end
        end
        if lk and lv < 0.6 / n then add(lk, "气氛组", 2.0, "fun") end
    end
    -- style titles (also solo)
    for _, p in ipairs(list) do
        local x, key = fx[p.key], p.key
        if x.cat.summon >= 0.4 then add(key, "召唤大师", 2 + x.cat.summon, "summon") end
        if x.dot >= 0.25 then add(key, "持续伤害专家", 2 + x.dot, "mod") end
        if x.cat.mod >= 0.4 then add(key, "改装达人", 2 + x.cat.mod, "mod") end
        if x.cat.skill >= 0.4 then add(key, "技能流", 2 + x.cat.skill, "skill") end
        if x.cat.melee >= 0.3 then add(key, "近战狂魔", 2 + x.cat.melee, "melee") end
        if x.cat.hand >= 0.4 then add(key, "手枪侠", 1.8 + x.cat.hand, "hand") end
        if x.cat.long >= 0.7 then add(key, "长枪信仰", 1.5 + x.cat.long, "long") end
        if x.ncat10 >= 4 then add(key, "全能选手", 2.0, "plain") end
        if x.weak and x.weak >= 0.5 and not x.no_weak then add(key, "精准射手", 1.8 + x.weak, "plain") end
        if x.crit and x.crit >= 0.3 and not x.no_crit then add(key, "欧皇", 1.8 + x.crit, "plain") end
        if p.taken == 0 and p.downs == 0 and p.deaths == 0 and f.active >= 20 then add(key, "毫发无伤", 2.2, "plain") end
        if p.downs == 0 and p.deaths == 0 and p.taken > 0 and f.active >= 30 then add(key, "稳如泰山", 1.2, "plain") end
        if p.revived >= 2 then add(key, "死而复生", 2.0, "fun") end
        if x.nb >= 6 and x.h1 > 0 and x.h2 >= 1.6 * x.h1 then add(key, "越战越勇", 1.6, "plain") end
        if x.nb >= 6 and x.h1 >= 2 * x.h2 then add(key, "开局爆发", 1.6, "plain") end
        if x.nb >= 10 and x.active_ratio >= 0.9 then add(key, "全勤奖", 1.4, "plain") end
    end
    local fill = { { "打工人", 1.0, "plain" }, { "默默耕耘", 0.9, "plain" }, { "到此一游", 0.5, "fun" } }
    for _, p in ipairs(list) do
        local c = cand[p.key]
        table.sort(c, function(a, b) return a[2] > b[2] end)
        local out, seen = {}, {}
        for _, tt in ipairs(c) do
            if #out < 3 and not seen[tt[1]] then out[#out + 1] = tt; seen[tt[1]] = true end
        end
        for _, tt in ipairs(fill) do
            if #out < 3 and not seen[tt[1]] then out[#out + 1] = tt; seen[tt[1]] = true end
        end
        ev.titles[p.key] = out
    end

    if f.ended and not f._ev_logged and ev.mvp then
        f._ev_logged = true
        local parts = {}
        for _, p in ipairs(list) do
            local tn = {}
            for _, tt in ipairs(ev.titles[p.key]) do tn[#tn + 1] = tt[1] end
            parts[#parts + 1] = string.format("%s %.0f [%s]", pname(p.key), ev.score[p.key] or 0, table.concat(tn, ","))
        end
        dbg("MVP " .. pname(ev.mvp) .. " | " .. table.concat(parts, " | "))
    end
    f._ev, f._ev_rev, f._ev_final, f._ev_t = ev, F.rev, f.ended == true, now()
    return ev
end

----------------------------------------------------------------------
-- colors: config values are sRGB hex, UMG wants linear colors
----------------------------------------------------------------------
local COL, CATCOL, PCOL, mix
do
local function s2l(c)
    c = c / 255
    if c <= 0.04045 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end
local function hexcol(v, fallback)
    local h = (tostring(v or ""):gsub("[%s#]", ""))
    if not h:match("^%x%x%x%x%x%x$") then h = (fallback:gsub("#", "")) end
    return { R = s2l(tonumber(h:sub(1, 2), 16)), G = s2l(tonumber(h:sub(3, 4), 16)), B = s2l(tonumber(h:sub(5, 6), 16)) }
end
mix = function(a, b, p)
    return { R = a.R + (b.R - a.R) * p, G = a.G + (b.G - a.G) * p, B = a.B + (b.B - a.B) * p }
end

COL = {
    text = hexcol(nil, "#E4E0D8"), dim = hexcol(nil, "#8F8B84"), white = hexcol(nil, "#FFFFFF"),
    black = hexcol(nil, "#000000"), panel = hexcol(nil, "#0A0A0A"), warn = hexcol(nil, "#E7837C"),
    dottxt = hexcol(nil, "#C9A66B"), flash = hexcol(nil, "#FFF6DC"), normal = hexcol(nil, "#55524D"),
    accent = hexcol(RAW.color_accent, "#D9C18D"), boss = hexcol(RAW.color_boss, "#9E2328"),
    elite = hexcol(RAW.color_elite, "#B0662A"),
}
CATCOL = {
    long = hexcol(RAW.color_long, "#E0913F"), hand = hexcol(RAW.color_hand, "#E8CF5A"),
    melee = hexcol(RAW.color_melee, "#D9534A"), mod = hexcol(RAW.color_mod, "#4DB6E2"),
    skill = hexcol(RAW.color_skill, "#A67FE8"), summon = hexcol(RAW.color_summon, "#5FC98F"),
    other = hexcol(RAW.color_other, "#8D8D8D"),
}
PCOL = {
    hexcol(RAW.color_player_self, "#E6C278"), hexcol(RAW.color_player_2, "#6CB4EE"),
    hexcol(RAW.color_player_3, "#E7837C"), hexcol(RAW.color_player_4, "#93D38A"),
}
end
-- stable color per player: you are always slot 1, others get 2, 3, 4 in the order they first show up
local PSLOT, NEXT_PSLOT = {}, 2
local function pcolor(key)
    if key ~= nil and key == LOCAL_KEY then return PCOL[1] end
    local name = PLAYERS[key] and PLAYERS[key].name or tostring(key)
    if LOCAL_KEY and PLAYERS[LOCAL_KEY] and PLAYERS[LOCAL_KEY].name == name then return PCOL[1] end
    local s = PSLOT[name]
    if not s then
        s = NEXT_PSLOT
        NEXT_PSLOT = NEXT_PSLOT + 1
        if NEXT_PSLOT > 4 then NEXT_PSLOT = 2 end
        PSLOT[name] = s
    end
    return PCOL[s]
end

----------------------------------------------------------------------
-- UI building blocks (engine classes only, no game blueprints)
-- Every root = UserWidget > CanvasPanel > "frame" CanvasPanel > pooled Images + TextBlocks.
-- Each refresh builds a draw list (rects, texts, click areas) and the pool is updated in place:
-- only properties that actually changed are sent to the engine.
----------------------------------------------------------------------
local VIS = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }
local UI = { cls = nil, font = nil, faces = nil, built = false, last_build = -100 }

local function ui_classes()
    if UI.cls then return true end
    local c = {}
    for k, p in pairs({ UserWidget = "/Script/UMG.UserWidget", WidgetTree = "/Script/UMG.WidgetTree",
        CanvasPanel = "/Script/UMG.CanvasPanel", TextBlock = "/Script/UMG.TextBlock", Image = "/Script/UMG.Image" }) do
        c[k] = safe(function() return StaticFindObject(p) end)
        if not valid(c[k]) then return false end
    end
    c.Button = safe(function() return StaticFindObject("/Script/UMG.Button") end)
    if not valid(c.Button) then c.Button = nil end
    UI.cls = c
    return true
end

local function find_game_font()
    if UI.font and valid(UI.font) then return end
    local tbs = safe(function() return timed("FindAllOf TextBlock (font)", FindAllOf, "TextBlock") end)
    if type(tbs) ~= "table" then return end
    -- the game's main UI font renders Chinese; typefaces in it: Default, Semi-Bold, Bold, ExtraBold
    for _, tb in ipairs(tbs) do
        local fo = valid(tb) and safe(function() return tb.Font.FontObject end)
        local fn = fo and valid(fo) and (safe(function() return fo:GetFullName() end) or "") or ""
        if fn:find("GFGRemnant", 1, true) then
            UI.font = fo
            dbg("font: " .. fn)
            break
        end
    end
    if not UI.font then
        for _, tb in ipairs(tbs) do
            if valid(tb) and safe(function() return tb:IsVisible() end) == true then
                local fo = safe(function() return tb.Font.FontObject end)
                if valid(fo) then
                    UI.font = fo
                    dbg("font (fallback): " .. tostring(safe(function() return fo:GetFullName() end)))
                    break
                end
            end
        end
    end
    if UI.font then
        local function fn(s) return safe(function() return FName(s) end) end
        local r = fn("Default")
        UI.faces = { r = r, m = fn("Semi-Bold") or r, b = fn("Bold") or r }
    end
end

local function new_root(pc, z, vis)
    local w = StaticConstructObject(UI.cls.UserWidget, pc)
    local tree = StaticConstructObject(UI.cls.WidgetTree, w)
    w.WidgetTree = tree
    w:SetOwningPlayer(pc)
    local canvas = StaticConstructObject(UI.cls.CanvasPanel, tree)
    tree.RootWidget = canvas
    w:AddToViewport(z)
    pcall(function() w:SetVisibility(vis) end)
    return { w = w, tree = tree, canvas = canvas, shown = true, vis_on = vis }
end

local function add_frame(r)
    local fr = StaticConstructObject(UI.cls.CanvasPanel, r.tree)
    local slot = r.canvas:AddChildToCanvas(fr)
    pcall(function() slot:SetAutoSize(false) end)
    pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
    pcall(function() fr:SetVisibility(VIS.SelfHitTestInvisible) end)
    r.frame = { obj = fr, slot = slot }
end

local function add_pool(r, kind, n)
    local list = {}
    for i = 1, n do
        local o = StaticConstructObject(UI.cls[kind], r.tree)
        local slot = r.frame.obj:AddChildToCanvas(o)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
        pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() o:SetVisibility(VIS.Collapsed) end)
        if kind == "TextBlock" then
            pcall(function() o:SetShadowOffset({ X = 1, Y = 1 }) end)
            pcall(function() o:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
            pcall(function() o:SetClipping(1) end) -- ClipToBounds
        end
        list[i] = { obj = o, slot = slot, vis = VIS.Collapsed }
    end
    return list
end

-- frame placement: right = anchored to the right screen edge (x = gap between frame and that edge)
local function set_frame(r, right, x, y, w, h)
    local g = r.fgeom
    if g and g[1] == right and g[2] == x and g[3] == y and g[4] == w and g[5] == h then return end
    r.fgeom = { right, x, y, w, h }
    local ax = right and 1 or 0
    local s = r.frame.slot
    pcall(function() s:SetAnchors({ Minimum = { X = ax, Y = 0 }, Maximum = { X = ax, Y = 0 } }) end)
    pcall(function() s:SetPosition({ X = right and -(x + w) or x, Y = y }) end)
    pcall(function() s:SetSize({ X = w, Y = h }) end)
end

local function set_frame_fx(r, opacity, dx)
    opacity = math.floor(opacity * 100 + 0.5) / 100
    dx = math.floor(dx + 0.5)
    if r.fop ~= opacity then
        r.fop = opacity
        pcall(function() r.frame.obj:SetRenderOpacity(opacity) end)
    end
    if r.fdx ~= dx then
        r.fdx = dx
        pcall(function() r.frame.obj:SetRenderTranslation({ X = dx, Y = 0 }) end)
    end
end

local function show_root(r, on)
    if not r then return end
    if r.shown ~= on then
        r.shown = on
        pcall(function() r.w:SetVisibility(on and r.vis_on or VIS.Collapsed) end)
    end
end

-- draw list ---------------------------------------------------------
local DR = { r = {}, t = {}, nr = 0, nt = 0, maxr = 0, maxt = 0, clicks = {} }

local function dr_begin(maxr, maxt)
    DR.nr, DR.nt, DR.maxr, DR.maxt = 0, 0, maxr, maxt
    DR.clicks = {}
end

local function q(v) return math.floor(v * 2 + 0.5) / 2 end

local function pool_full(kind)
    dbg_once("poolfull" .. kind, "UI pool full (" .. kind .. "): some elements were not drawn")
end

local function RR(x, y, w, h, c, a, block)
    if w < 0.5 or h < 0.5 then return end
    if DR.nr >= DR.maxr then pool_full("rect") return end
    DR.nr = DR.nr + 1
    local it = DR.r[DR.nr]
    if not it then it = {}; DR.r[DR.nr] = it end
    it.x, it.y, it.w, it.h, it.c, it.a, it.block = q(x), q(y), q(w), q(h), c, a or 1, block
end

-- reserve n rect slots (filled in later with SETR, e.g. a background whose height is known at the end)
local function RESERVE(n)
    local first = DR.nr + 1
    for _ = 1, n do
        if DR.nr >= DR.maxr then break end
        DR.nr = DR.nr + 1
        local it = DR.r[DR.nr]
        if not it then it = {}; DR.r[DR.nr] = it end
        it.x, it.y, it.w, it.h, it.c, it.a, it.block = 0, 0, 0, 0, COL.black, 0, nil
    end
    return first
end
local function SETR(i, x, y, w, h, c, a, block)
    local it = DR.r[i]
    if not it or i > DR.nr then return end
    it.x, it.y, it.w, it.h, it.c, it.a, it.block = q(x), q(y), q(w), q(h), c, a or 1, block
end

local function BOX(x, y, w, h, c, a)
    RR(x, y, w, 1, c, a); RR(x, y + h - 1, w, 1, c, a)
    RR(x, y + 1, 1, h - 2, c, a); RR(x + w - 1, y + 1, 1, h - 2, c, a)
end

-- text: x, y = top-left of its box; just 0 left, 1 center, 2 right; face r / m / b
local function TT(x, y, w, s, size, c, just, face, a)
    if s == nil or s == "" or w < 1 then return end
    if DR.nt >= DR.maxt then pool_full("text") return end
    DR.nt = DR.nt + 1
    local it = DR.t[DR.nt]
    if not it then it = {}; DR.t[DR.nt] = it end
    it.x, it.y, it.w, it.h = q(x), q(y), q(w), math.floor(size * 1.75 + 2)
    it.s, it.size, it.c, it.just, it.face, it.a = s, size, c, just or 0, face or "r", a or 1
end

local function CLICK(id, x, y, w, h, act)
    DR.clicks[#DR.clicks + 1] = { id = id, x = x, y = y, w = w, h = h, act = act }
end

local dr_apply
do
local function put_geom(e, it)
    if e.x ~= it.x or e.y ~= it.y then
        e.x, e.y = it.x, it.y
        pcall(function() e.slot:SetPosition({ X = it.x, Y = it.y }) end)
    end
    if e.w ~= it.w or e.h ~= it.h then
        e.w, e.h = it.w, it.h
        pcall(function() e.slot:SetSize({ X = it.w, Y = it.h }) end)
    end
end

local function put_vis(e, v)
    if e.vis ~= v then
        e.vis = v
        pcall(function() e.obj:SetVisibility(v) end)
    end
end

local function put_rect(e, it)
    if it.a <= 0 or it.w <= 0 or it.h <= 0 then put_vis(e, VIS.Collapsed) return end
    put_geom(e, it)
    if e.c ~= it.c or e.a ~= it.a then
        e.c, e.a = it.c, it.a
        local c = it.c
        pcall(function() e.obj:SetColorAndOpacity({ R = c.R, G = c.G, B = c.B, A = it.a }) end)
    end
    put_vis(e, it.block and VIS.Visible or VIS.HitTestInvisible)
end

local function put_text(e, it)
    put_geom(e, it)
    if e.size ~= it.size or e.face ~= it.face then
        e.size, e.face = it.size, it.face
        if UI.font then
            local face = UI.faces and UI.faces[it.face]
            pcall(function() e.obj:SetFont({ FontObject = UI.font, TypefaceFontName = face, Size = it.size }) end)
        end
    end
    if e.just ~= it.just then
        e.just = it.just
        pcall(function() e.obj:SetJustification(it.just) end)
    end
    if e.c ~= it.c or e.a ~= it.a then
        e.c, e.a = it.c, it.a
        local c = it.c
        pcall(function() e.obj:SetColorAndOpacity({ SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = it.a }, ColorUseRule = 0 }) end)
    end
    if e.s ~= it.s then
        e.s = it.s
        pcall(function() e.obj:SetText(FText(it.s)) end)
    end
    put_vis(e, VIS.HitTestInvisible)
end

dr_apply = function(r)
    for i, e in ipairs(r.rects) do
        if i <= DR.nr then put_rect(e, DR.r[i]) else put_vis(e, VIS.Collapsed) end
    end
    for i, e in ipairs(r.texts) do
        if i <= DR.nt then put_text(e, DR.t[i]) else put_vis(e, VIS.Collapsed) end
    end
end
end -- do (pool helpers)

-- animation: every animated value eases toward its target --------------
local AN = { ns = { h = {}, d = {}, l = {} }, busy = { h = false, d = false, l = false }, was = {}, dt = 0, last = nil }

local function anim_begin(t)
    local was = AN.was
    was.h, was.d, was.l = AN.busy.h, AN.busy.d, AN.busy.l
    AN.busy.h, AN.busy.d, AN.busy.l = false, false, false
    local dt = AN.last and (t - AN.last) or 0
    AN.last = t
    if not (was.h or was.d or was.l) then dt = 1 / 30 end -- first frame of a new change: no jump
    if dt < 0 then dt = 0 elseif dt > 0.1 then dt = 0.1 end
    AN.dt = dt
end

local function av(ns, key, target, eps)
    target = target or 0
    if not CFG.anim then return target end
    local tb = AN.ns[ns]
    local v = tb[key] or 0
    eps = eps or 0.5
    if math.abs(target - v) > eps then
        v = v + (target - v) * (1 - math.exp(-AN.dt / 0.09))
        if math.abs(target - v) <= eps then v = target else AN.busy[ns] = true end
    else
        v = target
    end
    tb[key] = v
    return v
end

local function ease_in(t0, t, len, ns)
    if not CFG.anim then return 1 end
    local p = (t - (t0 or -100)) / len
    if p >= 1 then return 1 end
    if p < 0 then p = 0 end
    AN.busy[ns] = true
    return 1 - (1 - p) ^ 3
end

-- shared pieces ------------------------------------------------------
local CHIP = { boss = { "BOSS", 44 }, elite = { "精英", 40 }, normal = { "普通", 40 } }
local function chip(x, y, kind)
    local c = CHIP[kind] or CHIP.normal
    local col = kind == "boss" and COL.boss or (kind == "elite" and COL.elite or COL.normal)
    RR(x, y, c[2], 20, col, 0.95)
    TT(x, y + 1, c[2], c[1], 11, COL.white, 1, "b")
    return c[2]
end

local function tone_col(tone)
    if tone == "best" then return COL.accent end
    if tone == "fun" then return COL.warn end
    return CATCOL[tone] or COL.text
end
-- one fun title as a small tag; returns its width
local function title_chip(x, y, tt, maxw)
    local w = math.min(utf8_len(tt[1]) * 16 + 14, maxw or 999)
    local c = tone_col(tt[3])
    RR(x, y, w, 20, c, 0.20)
    RR(x, y, 2, 20, c, 0.9)
    TT(x + 2, y + 1, w - 2, tt[1], 12, c, 1, "m")
    return w
end
local function mvp_chip(x, y)
    RR(x, y, 36, 16, COL.accent, 0.95)
    TT(x, y - 1, 36, "MVP", 10, COL.black, 1, "b")
    return 36
end

-- boss / elite title flashes for a moment when the fight starts
local function title_color(f, t, ns)
    if not f or f.kind == "normal" or not CFG.anim then return COL.accent end
    local p = (t - (f.start or -100)) / 1.2
    if p >= 1 or p < 0 then return COL.accent end
    AN.busy[ns] = true
    return mix(COL.flash, COL.accent, p)
end

----------------------------------------------------------------------
-- HUD (top-right, under the minimap) - never clickable
----------------------------------------------------------------------
local HUD = nil
local PANEL = nil
local VIEW = { expanded = false, tab = "all", hist = 0, hold = false, toggle = false, clicks = {}, hover = nil }

local function build_hud(pc)
    local r = new_root(pc, 9990, VIS.HitTestInvisible)
    add_frame(r)
    r.rects = add_pool(r, "Image", 8 + 2 * CFG.hud_max + 2)
    r.texts = add_pool(r, "TextBlock", 8 + 4 * CFG.hud_max)
    set_frame(r, true, CFG.hud_x, CFG.hud_y, CFG.hud_w, 40 + CFG.hud_rh * CFG.hud_max)
    return r
end

local function draw_hud(t)
    local f = F.cur
    if f ~= HUD.fight then
        HUD.fight = f
        HUD.fade_t = t
        AN.ns.h = {}
    end
    dr_begin(#HUD.rects, #HUD.texts)
    if f then
        local W, rh, fs = CFG.hud_w, CFG.hud_rh, CFG.hud_font
        local list = sorted_players(f)
        local n = 0
        for _, p in ipairs(list) do if p.total > 0 then n = n + 1 end end
        n = math.min(n, CFG.hud_max)
        local head = CFG.hud_title and 32 or 6
        -- after a fight with 2+ players: one more row with the MVP
        local ev = (F.pending and n >= 2) and eval_fight(f) or nil
        local mvp = ev and ev.mvp and f.players[ev.mvp]
        local H = head + n * rh + 5 + (mvp and rh + 2 or 0)
        local kc = f.kind == "boss" and COL.boss or (f.kind == "elite" and COL.elite or COL.accent)
        RR(0, 0, W, H, COL.black, CFG.hud_alpha)
        RR(0, 0, 2, H, kc, 0.9)
        if CFG.hud_title then
            local cw = chip(10, 7, f.kind)
            TT(16 + cw, 5, W - cw - 84, title_text(f), fs - 1, title_color(f, t, "h"), 0, "m")
            TT(W - 70, 5, 60, mmss(f.active), fs - 1, F.pending and COL.dim or COL.text, 2, "m")
        end
        local dur = math.max(f.active, 1)
        local y = head
        for i = 1, n do
            local p = list[i]
            local pc = pcolor(p.key)
            local share = f.total > 0 and p.total / f.total or 0
            RR(6, y, av("h", "f" .. tostring(p.key), (W - 12) * share), rh - 3, pc, 0.30)
            RR(6, y, 3, rh - 3, pc, 1)
            -- columns: name | DPS (big) | total | share, each right-aligned with a gap in between
            TT(16, y + 2, W * 0.44 - 16, pname(p.key), fs, p.key == LOCAL_KEY and pc or COL.text, 0, "m")
            local live = (not F.pending) and realtime_dps(p, t) or (p.total / dur)
            TT(W * 0.58 - 64, y + 1, 64, fmt(av("h", "d" .. tostring(p.key), live, numeps(live))), fs + 1, COL.white, 2, "b")
            TT(W * 0.82 - 64, y + 4, 64, fmt(p.total), fs - 2, COL.text, 2, "r")
            TT(W - 12 - 44, y + 4, 44, pct(p.total, f.total), fs - 2, COL.dim, 2, "r")
            y = y + rh
        end
        if mvp then
            if HUD.mvp_fight ~= f then HUD.mvp_fight, HUD.mvp_t = f, t end
            local glow = ease_in(HUD.mvp_t, t, 1.2, "h")
            RR(6, y + 2, W - 12, rh - 3, COL.accent, 0.35 * (1 - glow) + 0.10)
            mvp_chip(12, y + 5)
            TT(54, y + 2, W * 0.58 - 54, pname(mvp.key), fs, pcolor(mvp.key), 0, "b")
            TT(W * 0.58, y + 4, W * 0.42 - 12, "评分 " .. string.format("%d", math.floor((ev.score[mvp.key] or 0) + 0.5)), fs - 2, COL.accent, 2, "m")
        end
    end
    dr_apply(HUD)
    set_frame_fx(HUD, ease_in(HUD.fade_t, t, 0.25, "h"), 0)
end

----------------------------------------------------------------------
-- detail dashboard (hold key in combat / Tab fragments page) + collapsed label card
----------------------------------------------------------------------
local LABEL_H = 78

-- A fully transparent Button over the whole panel frame, on top of everything else. It is only
-- visible (= clickable) on the Tab menu page. Its IsPressed() is polled on the game thread and
-- the click position comes from the mouse position, so no key bind (= no other thread) is needed.
local function add_click_catcher(r)
    if not UI.cls.Button then dbg("no Button class: clicks use the mouse key state") return end
    local ok, err = pcall(function()
        local b = StaticConstructObject(UI.cls.Button, r.tree)
        -- set before the Slate widget is built
        pcall(function() b.IsFocusable = false end)       -- never take keyboard focus from the game menu
        pcall(function() b.BackgroundColor = { R = 1, G = 1, B = 1, A = 0 } end)
        local slot = r.frame.obj:AddChildToCanvas(b)
        pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } }) end)
        pcall(function() slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 }) end)
        pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
        pcall(function() slot:SetZOrder(1000) end)
        pcall(function() b:SetBackgroundColor({ R = 1, G = 1, B = 1, A = 0 }) end)
        pcall(function() b:SetColorAndOpacity({ R = 1, G = 1, B = 1, A = 0 }) end)
        pcall(function() b:SetVisibility(VIS.Collapsed) end)
        r.catcher = { obj = b, slot = slot, vis = VIS.Collapsed }
    end)
    if not ok then
        r.catcher = nil
        dbg("click catcher not created (" .. tostring(err) .. "): clicks use the mouse key state")
    end
end

local function set_catcher(r, on)
    local c = r and r.catcher
    if not c then return end
    local v = on and VIS.Visible or VIS.Collapsed
    if c.vis ~= v then
        c.vis = v
        pcall(function() c.obj:SetVisibility(v) end)
    end
end

local function build_panel(pc)
    local r = new_root(pc, 9995, VIS.SelfHitTestInvisible)
    add_frame(r)
    r.rects = add_pool(r, "Image", 400)
    r.texts = add_pool(r, "TextBlock", 200)
    add_click_catcher(r) -- last, so it is the top-most child
    return r
end

local draw_dashboard
do
local function viewed_fight(interactive)
    if not interactive then return F.cur end
    if VIEW.hist_ref then
        for i, hf in ipairs(F.history) do
            if hf == VIEW.hist_ref then VIEW.hist = i; return hf end
        end
    end
    VIEW.hist, VIEW.hist_ref = 0, nil
    return F.cur
end

local function btn(id, x, y, w, h, label, act, enabled)
    local hv = enabled and VIEW.hover == id
    RR(x, y, w, h, COL.white, (not enabled) and 0.02 or (hv and 0.14 or 0.06))
    BOX(x, y, w, h, COL.white, (not enabled) and 0.06 or (hv and 0.38 or 0.18))
    TT(x, y + math.floor((h - 20) / 2), w, label, 13, enabled and (hv and COL.white or COL.text) or COL.dim, 1, "m")
    if enabled then CLICK(id, x, y, w, h, act) end
end

-- chart columns: values per column for one player (or the sum of all players when p == nil)
local function chart_columns(f, plist)
    local nb = math.max(f.nb or 1, 1)
    local per = math.ceil(nb / (#plist > 1 and 30 or 60))
    local ncol = math.ceil(nb / per)
    local cols = {}
    for c = 1, ncol do
        local seg = {}
        for i, p in ipairs(plist) do
            local s, tl = 0, p.tl or {}
            local b1, b2 = (c - 1) * per + 1, math.min(c * per, nb)
            for b = b1, b2 do s = s + (tl[b] or 0) end
            seg[i] = s / ((b2 - b1 + 1) * CFG.bucket) -- the last column may cover fewer buckets

        end
        cols[c] = seg
    end
    return cols, per
end

-- DPS chart at the bottom; plist = one player, or the whole team (stacked, one color per player)
local function draw_chart(f, plist, title, total, L, R, IW, y, Hfix)
    local top = math.max(y + 12, (Hfix or 0) - 150)
    RR(L, top - 10, IW, 1, COL.white, 0.10)
    local cols, per = chart_columns(f, plist)
    local peak = 0
    for _, seg in ipairs(cols) do
        local s = 0
        for _, v in ipairs(seg) do s = s + v end
        if s > peak then peak = s end
    end
    local avg = total / math.max(f.active, CFG.bucket)
    TT(L, top, 200, title, 12, COL.dim, 0, "r")
    TT(R - 320, top + 1, 320, string.format("每 %g 秒一格    峰值 %s    平均 %s", CFG.bucket * per, fmt(peak), fmt(avg)), 11, COL.dim, 2, "r")
    local cy, chh = top + 24, 92
    local scale = math.max(peak, avg, 1)
    -- short fights: narrow bars from the left; merged columns: always fill the width
    local cw = IW / (per > 1 and #cols or math.max(#cols, 30))
    local bw = cw > 4 and cw - 2 or math.max(cw - 1, 1)
    local single = #plist == 1
    for c, seg in ipairs(cols) do
        local base = cy + chh
        local sum = 0
        for _, v in ipairs(seg) do sum = sum + v end
        for i, v in ipairs(seg) do
            local h = av("d", "ch" .. c .. ":" .. i, chh * v / scale)
            local a = single and (sum >= peak and 1.0 or 0.72) or 0.85
            RR(L + (c - 1) * cw, base - h, bw, h, pcolor(plist[i].key), a)
            base = base - h
        end
    end
    RR(L, cy + chh - math.floor(chh * avg / scale), IW, 1, COL.white, 0.45)
    RR(L, cy + chh, IW, 1, COL.white, 0.25)
    TT(L, cy + chh + 3, 60, "0:00", 10, COL.dim, 0, "r")
    TT(R - 60, cy + chh + 3, 60, mmss(f.active), 10, COL.dim, 2, "r")
    return cy + chh + 22
end

local function sorted_cats(p)
    local cats = {}
    for _, k in ipairs(CAT_ORDER) do if p.cats[k] and p.cats[k].total > 0 then cats[#cats + 1] = k end end
    table.sort(cats, function(a, b) return p.cats[a].total > p.cats[b].total end)
    return cats
end

-- stacked composition bar of one player (category colors, DOT part darker)
local function comp_bar(p, x, y, w, h, ns)
    local bx = x
    for _, k in ipairs(sorted_cats(p)) do
        local c = p.cats[k]
        local sw = av("d", ns .. k, w * c.total / math.max(p.total, 1))
        local gap = sw > 3 and 1 or 0
        RR(bx, y, sw - gap, h, CATCOL[k], 0.95)
        if c.dot > 0 then
            local wd = sw * c.dot / c.total
            RR(bx + sw - wd, y, wd - gap, h, COL.black, 0.35)
        end
        bx = bx + sw
    end
end

---------------------------------------------------------------- team overview page
local function draw_overview(t, f, list, L, R, IW, y, interactive, show_chart, limit, Hfix)
    local ev = eval_fight(f)
    -- damage share
    TT(L, y, 200, "伤害占比", 12, COL.dim, 0, "r")
    y = y + 22
    local bx = L
    for _, p in ipairs(list) do
        local w = av("d", "os" .. tostring(p.key), IW * (f.total > 0 and p.total / f.total or 0))
        RR(bx, y, w > 3 and w - 1 or w, 14, pcolor(p.key), 0.95)
        bx = bx + w
    end
    y = y + 24

    -- comparison table: one row per stat, one column per player
    local n = #list
    local colw = (IW - 96) / n
    local barw = colw - 80
    local RH = 23
    RR(L, y, IW, 24, COL.white, 0.04)
    for i, p in ipairs(list) do
        local cx = L + 96 + (i - 1) * colw
        local id = "col" .. tostring(p.key)
        local hv = interactive and VIEW.hover == id
        local is_mvp = ev and ev.mvp == p.key
        if hv then RR(cx, y, colw, 24, COL.white, 0.08) end
        RR(cx + 4, y + 8, 8, 8, pcolor(p.key), 1)
        TT(cx + 16, y + 2, colw - 18 - (is_mvp and 40 or 0), pname(p.key), 12, pcolor(p.key), 0, "m")
        if is_mvp then mvp_chip(cx + colw - 40, y + 4) end
        if interactive then CLICK(id, cx, y, colw, 24, { "tab", p.key }) end
    end
    y = y + 30
    local dur = math.max(f.active, 1)
    local function rate(a, b) return b > 0 and a / b or 0 end
    local rows = {}
    if ev and ev.mvp then
        rows[#rows + 1] = { "评分", function(p) return ev.score[p.key] or 0 end, function(v) return string.format("%d", math.floor(v + 0.5)) end, true }
    end
    local base_rows = {
        { "DPS", function(p) return p.total / dur end, fmt, true },
        { "总伤害", function(p) return p.total end, fmt, true },
        { "暴击率", function(p) return rate(p.crits, p.direct) end, function(v) return pct(v, 1) end, true },
        { "弱点率", function(p) return rate(p.weak, p.direct) end, function(v) return pct(v, 1) end, true },
        { "最高单发", function(p) return p.maxhit end, fmt, true },
        { "治疗", function(p) return p.heal end, fmt, true },
        { "承伤", function(p) return p.taken end, fmt, false },
    }
    for _, r in ipairs(base_rows) do rows[#rows + 1] = r end
    for ri, r in ipairs(rows) do
        TT(L, y, 92, r[1], 12, ri == 1 and ev and ev.mvp and COL.accent or COL.dim, 0, "r")
        local mx = 0
        for _, p in ipairs(list) do mx = math.max(mx, r[2](p)) end
        for i, p in ipairs(list) do
            local cx = L + 96 + (i - 1) * colw
            local v = r[2](p)
            local best = r[4] and mx > 0 and v >= mx and n > 1
            TT(cx + 4, y - 1, math.min(70, colw - 6), r[3](v), 13, best and COL.accent or COL.white, 0, best and "b" or "m")
            if barw >= 16 then
                RR(cx + 74, y + 8, barw, 4, COL.white, 0.08)
                RR(cx + 74, y + 8, av("d", "ob" .. r[1] .. ":" .. tostring(p.key), barw * (mx > 0 and v / mx or 0)), 4, pcolor(p.key), 0.85)
            end
        end
        y = y + RH
    end
    TT(L, y, 92, "倒地 / 阵亡", 12, COL.dim, 0, "r")
    for i, p in ipairs(list) do
        TT(L + 96 + (i - 1) * colw + 4, y - 1, colw - 6, p.downs .. " / " .. p.deaths, 13, p.deaths > 0 and COL.warn or COL.white, 0, "m")
    end
    y = y + RH
    TT(L, y, 92, "被救 / 救人", 12, COL.dim, 0, "r")
    for i, p in ipairs(list) do
        TT(L + 96 + (i - 1) * colw + 4, y - 1, colw - 6, p.revived .. " / " .. p.revives, 13, COL.white, 0, "m")
    end
    y = y + RH + 2
    -- fun titles: 3 per player
    if ev then
        TT(L, y + 1, 92, "称号", 12, COL.dim, 0, "r")
        for j = 1, 3 do
            for i, p in ipairs(list) do
                local tt = ev.titles[p.key] and ev.titles[p.key][j]
                if tt then title_chip(L + 96 + (i - 1) * colw + 4, y, tt, colw - 10) end
            end
            y = y + 24
        end
    end
    y = y + 10

    -- composition per player
    if y + 22 + n * 22 + 26 <= limit then
        RR(L, y - 8, IW, 1, COL.white, 0.10)
        TT(L, y, 200, "伤害构成对比", 12, COL.dim, 0, "r")
        y = y + 22
        local used = {}
        for _, p in ipairs(list) do
            TT(L, y - 2, 92, pname(p.key), 12, pcolor(p.key), 0, "m")
            comp_bar(p, L + 96, y + 2, IW - 96, 12, "oc" .. tostring(p.key) .. ":")
            for k, c in pairs(p.cats) do if c.total > 0 then used[k] = true end end
            y = y + 22
        end
        local lx = L + 96
        local lw2 = (IW - 96) / 7
        for _, k in ipairs(CAT_ORDER) do
            if used[k] then
                RR(lx, y + 5, 8, 8, CATCOL[k], 1)
                TT(lx + 12, y, lw2 - 12, CAT_LABEL[k], 11, COL.dim, 0, "r")
                lx = lx + lw2
            end
        end
        y = y + 26
    end
    if show_chart then y = draw_chart(f, list, "全队 DPS 曲线", f.total, L, R, IW, y, Hfix) end
    return y
end

---------------------------------------------------------------- one player's page
local function draw_player(t, f, p, L, R, IW, y, interactive, show_chart, limit, Hfix)
    local pc = pcolor(p.key)
    RR(L, y + 6, 10, 10, pc, 1)
    TT(L + 18, y - 3, IW * 0.7, pname(p.key), 16, pc, 0, "b")
    TT(R - 160, y + 1, 160, pct(p.total, f.total) .. " 的全队伤害", 11, COL.dim, 2, "r")
    y = y + 30
    local ev = eval_fight(f)
    local tls = ev and ev.titles[p.key]
    if tls then
        local tx = L
        for _, tt in ipairs(tls) do tx = tx + title_chip(tx, y, tt) + 6 end
        local sc = ev.score[p.key]
        if sc then
            local is_mvp = ev.mvp == p.key
            TT(R - 150 - (is_mvp and 42 or 0), y, 150, "评分 " .. string.format("%d", math.floor(sc + 0.5)), 13, is_mvp and COL.accent or COL.text, 2, "b")
            if is_mvp then mvp_chip(R - 36, y + 2) end
        end
        y = y + 30
    end
    local dur = math.max(f.active, 1)
    local st = {
        { "DPS", fmt(av("d", "pd", p.total / dur, numeps(p.total / dur))) },
        { "暴击率", pct(p.crits, p.direct), p.direct > 0 and p.crits / p.direct or 0 },
        { "弱点率", pct(p.weak, p.direct), p.direct > 0 and p.weak / p.direct or 0 },
        { "最高单发", fmt(p.maxhit) },
    }
    local sw = (IW - 24) / 4
    for i, s in ipairs(st) do
        local sx = L + (i - 1) * (sw + 8)
        RR(sx, y, sw, 52, COL.white, 0.04)
        TT(sx + 8, y + 4, sw - 12, s[1], 11, COL.dim, 0, "r")
        TT(sx + 8, y + 18, sw - 12, s[2], 16, COL.white, 0, "b")
        if s[3] then
            RR(sx + 8, y + 45, sw - 16, 3, COL.white, 0.12)
            RR(sx + 8, y + 45, av("d", "st" .. i, (sw - 16) * s[3]), 3, COL.accent, 0.9)
        end
    end
    y = y + 60
    local ev = { { "倒地", tostring(p.downs) }, { "被救", tostring(p.revived) }, { "救人", tostring(p.revives) },
                 { "阵亡", tostring(p.deaths), p.deaths > 0 }, { "治疗", fmt(p.heal) }, { "承伤", fmt(p.taken) } }
    local ew = IW / 6
    for i, e in ipairs(ev) do
        local ex = L + (i - 1) * ew
        TT(ex, y, 36, e[1], 12, COL.dim, 0, "r")
        TT(ex + 39, y, ew - 41, e[2], 12, e[3] and COL.warn or COL.white, 0, "b")
    end
    y = y + 26

    local cats = sorted_cats(p)
    if #cats > 0 and p.total > 0 then
        TT(L, y, 200, "伤害构成", 12, COL.dim, 0, "r")
        y = y + 22
        comp_bar(p, L, y, IW, 14, "cs")
        y = y + 24
        -- sources: every category gets its 1st source before any gets a 2nd (big categories first)
        local srcs_of, alloc = {}, {}
        local budget = limit - y
        for _, k in ipairs(cats) do
            local sl = {}
            for s, v in pairs(p.cats[k].src) do sl[#sl + 1] = { s, v } end
            table.sort(sl, function(a, b) return a[2] > b[2] end)
            srcs_of[k], alloc[k] = sl, 0
            budget = budget - 27 - (p.cats[k].dot > 0 and 19 or 0)
        end
        for level = 1, CFG.psrc do
            for _, k in ipairs(cats) do
                if #srcs_of[k] >= level and budget >= 19 then
                    alloc[k] = level
                    budget = budget - 19
                end
            end
        end
        local bl = L + 150
        local bw = IW - 150 - 110
        for _, k in ipairs(cats) do
            if y + 23 > limit then break end
            local c = p.cats[k]
            local col = CATCOL[k]
            RR(L, y + 5, 10, 10, col, 1)
            TT(L + 18, y - 2, 120, CAT_LABEL[k], 14, COL.text, 0, "m")
            RR(bl, y + 6, bw, 8, COL.white, 0.08)
            local fw = av("d", "cb" .. k, bw * c.total / p.total)
            RR(bl, y + 6, fw, 8, col, 0.9)
            if c.dot > 0 then
                local wd = fw * c.dot / c.total
                RR(bl + fw - wd, y + 6, wd, 8, COL.black, 0.40)
            end
            TT(R - 142, y - 1, 90, fmt(c.total), 13, COL.white, 2, "m")
            TT(R - 50, y - 1, 50, pct(c.total, p.total), 13, COL.text, 2, "r")
            y = y + 23
            local sl = srcs_of[k]
            for i = 1, alloc[k] do
                TT(L + 24, y - 1, bl - L - 30, dn(sl[i][1]), 12, COL.dim, 0, "r")
                RR(bl, y + 8, av("d", "ss" .. k .. i, bw * sl[i][2] / p.total), 3, col, 0.5)
                TT(R - 142, y - 1, 90, fmt(sl[i][2]), 12, COL.dim, 2, "r")
                y = y + 19
            end
            if c.dot > 0 and y + 19 <= limit then
                TT(L + 24, y - 1, 172, "其中持续 " .. fmt(c.dot) .. " (" .. pct(c.dot, c.total) .. ")", 12, COL.dottxt, 0, "m")
                local dl = {}
                for s, v in pairs(c.dots) do dl[#dl + 1] = { s, v } end
                table.sort(dl, function(a, b) return a[2] > b[2] end)
                local parts = {}
                for i = 1, #dl do parts[#parts + 1] = dn(dl[i][1]) .. " " .. fmt(dl[i][2]) end
                TT(L + 202, y - 1, IW - 202, table.concat(parts, "    "), 12, COL.dim, 0, "r")
                y = y + 19
            end
            y = y + 4
        end
    end
    if show_chart then y = draw_chart(f, { p }, "DPS 曲线", p.total, L, R, IW, y, Hfix) end
    return y
end

-- which page to show: "all" (team overview) or a player key
local function current_page(f, list, interactive)
    if #list <= 1 then return list[1] and list[1].key or nil end
    if not interactive then
        if CFG.hold_page == "self" and LOCAL_KEY and f.players[LOCAL_KEY] then return LOCAL_KEY end
        return "all"
    end
    if VIEW.tab ~= "all" and not f.players[VIEW.tab] then VIEW.tab = "all" end
    return VIEW.tab
end

-- returns the content height
draw_dashboard = function(t, W, Hfix, interactive, show_chart, limit)
    local f = viewed_fight(interactive)
    local list = f and sorted_players(f) or {}
    while #list > 4 do table.remove(list) end
    local page = f and current_page(f, list, interactive) or nil
    -- switching fight / page replays the grow-in animation
    local vk = tostring(f) .. "|" .. tostring(page)
    if vk ~= PANEL.view_key then
        PANEL.view_key = vk
        AN.ns.d = {}
    end

    local L, R = 18, W - 18
    local IW = R - L
    local bg = RESERVE(6)
    local y = 16
    local cw = chip(L, y + 3, f and f.kind or "normal")
    TT(L + cw + 10, y - 3, IW - cw - 10 - (interactive and 84 or 0), title_text(f), 20, title_color(f, t, "d"), 0, "b")
    if interactive then btn("close", R - 72, y, 72, 28, "收起", { "collapse" }, true) end
    y = y + 40
    if interactive then
        local nh = #F.history
        btn("older", L, y, 104, 26, "<  上一场", { "hist_older" }, VIEW.hist < nh)
        btn("newer", R - 104, y, 104, 26, "下一场  >", { "hist_newer" }, VIEW.hist > 0)
        local nav
        if VIEW.hist > 0 then nav = string.format("历史 %d / %d", VIEW.hist, nh)
        else nav = F.pending and "最近一场" or "当前战斗" end
        TT(L + 104, y - 4, IW - 208, nav, 13, COL.text, 1, "m")
        local nd = math.min(nh + 1, 11)
        local dx = L + IW / 2 - nd * 7
        for j = 1, nd do
            local on = (nd - j) == VIEW.hist
            RR(dx + (j - 1) * 14 + (on and 0 or 2), y + 24, on and 10 or 6, 3, on and COL.accent or COL.white, on and 0.95 or 0.25)
        end
        y = y + 38
    end
    RR(L, y, IW, 1, COL.white, 0.10)
    y = y + 12
    if not f then
        TT(L, y, IW, "还没有伤害数据，打一下怪就开始统计", 14, COL.dim, 0, "r")
        y = y + 40
    else
        -- page tabs (team overview + one per player), only with 2+ players
        if #list > 1 then
            if interactive then
                local tabs = { { "all", "总览" } }
                for _, p in ipairs(list) do tabs[#tabs + 1] = { p.key, pname(p.key), p } end
                local tw = IW / #tabs
                for i, tb in ipairs(tabs) do
                    local tx = L + (i - 1) * tw
                    local on = tb[1] == page
                    local id = "tab" .. tostring(tb[1])
                    local hv = VIEW.hover == id
                    local tc = tb[3] and pcolor(tb[3].key) or COL.accent
                    RR(tx, y, tw - 4, 30, COL.white, on and 0.10 or (hv and 0.07 or 0.035))
                    RR(tx, y + 28, tw - 4, 2, tc, on and 1 or 0.35)
                    -- long names: left-aligned so the start of the name stays visible
                    local fits = utf8_len(tb[2]) * 18 <= tw - 12
                    TT(tx + 4, y + 4, tw - 12, tb[2], 13, on and (tb[3] and tc or COL.white) or (hv and COL.text or COL.dim), fits and 1 or 0, on and "b" or "m")
                    if not on then CLICK(id, tx, y, tw - 4, 30, { "tab", tb[1] }) end
                end
            else
                TT(L, y + 2, IW, page == "all" and "全队总览" or pname(page), 13, COL.dim, 0, "m")
            end
            y = y + 42
        end
        -- team summary tiles
        local dur = math.max(f.active, 1)
        local taken = 0
        for _, pp in pairs(f.players) do taken = taken + pp.taken end
        local tiles = { { "战斗时间", mmss(f.active) }, { "全队伤害", f.total, "tt" }, { "全队 DPS", f.total / dur, "td" }, { "全队承伤", taken, "tk" } }
        local tw = (IW - 24) / 4
        for i, tl in ipairs(tiles) do
            local tx = L + (i - 1) * (tw + 8)
            RR(tx, y, tw, 54, COL.white, 0.045)
            RR(tx, y, tw, 2, i == 3 and COL.accent or COL.white, i == 3 and 0.7 or 0.12)
            TT(tx + 10, y + 5, tw - 14, tl[1], 11, COL.dim, 0, "r")
            local v = tl[2]
            if tl[3] then v = fmt(av("d", tl[3], v, numeps(v))) end
            TT(tx + 10, y + 18, tw - 14, v, 19, COL.white, 0, "b")
        end
        y = y + 66
        if page == "all" then
            y = draw_overview(t, f, list, L, R, IW, y, interactive, show_chart, limit, Hfix)
        elseif page and f.players[page] then
            y = draw_player(t, f, f.players[page], L, R, IW, y, interactive, show_chart, limit, Hfix)
        end
    end

    local H = Hfix or (y + 8)
    local block = interactive or nil
    SETR(bg, 0, 0, W, H, COL.panel, interactive and CFG.palpha or CFG.halpha, block)
    SETR(bg + 1, 0, 0, W, 1, COL.white, 0.07)
    SETR(bg + 2, 0, H - 1, W, 1, COL.white, 0.07)
    SETR(bg + 3, 0, 1, 1, H - 2, COL.white, 0.07)
    SETR(bg + 4, W - 1, 1, 1, H - 2, COL.white, 0.07)
    SETR(bg + 5, 0, 0, W, 2, COL.accent, 0.8)
    return H
end

end -- do (dashboard)

local function draw_label(t, W)
    local hv = VIEW.hover == "label"
    RR(0, 0, W, LABEL_H, COL.panel, 0.88, true) -- the only clickable part of the label: the card itself
    if hv then RR(0, 0, W, LABEL_H, COL.white, 0.05) end
    BOX(0, 0, W, LABEL_H, COL.white, hv and 0.38 or 0.18)
    RR(0, 0, 2, LABEL_H, COL.accent, 0.9)
    TT(14, 6, 160, "伤害统计", 15, COL.accent, 0, "b")
    TT(W - 112, 8, 100, "展开  >", 13, hv and COL.white or COL.text, 2, "m")
    local f = F.cur
    if f then
        local cw = chip(14, 36, f.kind)
        TT(20 + cw, 35, W - cw - 32, title_text(f) .. "    " .. mmss(f.active) .. "    全队 " .. fmt(f.total), 12, COL.text, 0, "r")
        local bx = 14
        for _, p in ipairs(sorted_players(f)) do
            local w = av("l", "lb" .. tostring(p.key), (W - 28) * (f.total > 0 and p.total / f.total or 0))
            RR(bx, 66, w > 3 and w - 1 or w, 4, pcolor(p.key), 0.9)
            bx = bx + w
        end
    else
        TT(14, 37, W - 28, "暂无数据", 12, COL.dim, 0, "r")
    end
    CLICK("label", 0, 0, W, LABEL_H, { "expand" })
end

-- forget what we think each widget shows, so the next draw sends everything again
local function invalidate_pool(r)
    if not r then return end
    for _, e in ipairs(r.rects) do e.x, e.y, e.w, e.h, e.c, e.a, e.vis = nil, nil, nil, nil, nil, nil, nil end
    for _, e in ipairs(r.texts) do
        e.x, e.y, e.w, e.h, e.c, e.a, e.vis = nil, nil, nil, nil, nil, nil, nil
        e.s, e.size, e.face, e.just = nil, nil, nil, nil
    end
    r.fgeom, r.fop, r.fdx = nil, nil, nil
end
-- re-send the color of the next n visible widgets (round robin). Costs n engine calls,
-- so a whole panel is refreshed every ~2 s at 30 fps without any spike.
local function resync_colors(r, n)
    local nr, nt = #r.rects, #r.texts
    local total = nr + nt
    if total == 0 then return end
    local i = r.rs_i or 0
    local sent, tries = 0, 0
    while sent < n and tries < total do
        i = i % total + 1
        tries = tries + 1
        local e = i <= nr and r.rects[i] or r.texts[i - nr]
        if e.vis and e.vis ~= VIS.Collapsed and e.c then
            local c, a = e.c, e.a or 1
            if i <= nr then
                pcall(function() e.obj:SetColorAndOpacity({ R = c.R, G = c.G, B = c.B, A = a }) end)
            else
                pcall(function() e.obj:SetColorAndOpacity({ SpecifiedColor = { R = c.R, G = c.G, B = c.B, A = a }, ColorUseRule = 0 }) end)
            end
            sent = sent + 1
        end
    end
    r.rs_i = i
end

-- panel mode: "off" | "label" | "hold" | "expanded"
local function set_panel_mode(mode, t)
    if not PANEL or PANEL.mode == mode then return end
    PANEL.mode = mode
    if mode ~= "off" then invalidate_pool(PANEL) end
    show_root(PANEL, mode ~= "off")
    set_catcher(PANEL, mode == "label" or mode == "expanded")
    PANEL.open_t = t
    PANEL.view_key = nil
    AN.ns.d, AN.ns.l = {}, {}
    VIEW.hover = nil
    VIEW.clicks = {}
    PANEL.dirty = true
    if CFG.anim then set_frame_fx(PANEL, 0, 0) end
end

local function draw_panel(t)
    local m = PANEL.mode
    dr_begin(#PANEL.rects, #PANEL.texts)
    local right
    if m == "label" then
        right = true
        set_frame(PANEL, true, CFG.tx, CFG.ty, CFG.tw, LABEL_H)
        draw_label(t, CFG.tw)
    elseif m == "expanded" then
        right = true
        set_frame(PANEL, true, CFG.px, CFG.py, CFG.pw, CFG.ph)
        draw_dashboard(t, CFG.pw, CFG.ph, true, true, CFG.ph - 166)
    else -- hold
        right = CFG.hold_side ~= "left"
        set_frame(PANEL, right, CFG.hx, CFG.hy, CFG.hw, CFG.hmaxh)
        draw_dashboard(t, CFG.hw, nil, false, CFG.hold_chart, CFG.hmaxh - (CFG.hold_chart and 166 or 12))
    end
    dr_apply(PANEL)
    VIEW.clicks = DR.clicks
    local e = ease_in(PANEL.open_t, t, 0.18, m == "label" and "l" or "d")
    set_frame_fx(PANEL, e, (1 - e) * 24 * (right and 1 or -1))
end
----------------------------------------------------------------------
-- menu detection
----------------------------------------------------------------------
local MENU = { menu = nil, frag = nil, last_find = -100, last_frag_find = -100 }

-- A menu instance is created every time the menu opens and destroyed (later, by GC) after it
-- closes. It is looked up by searching, never with NotifyOnNewObject (that callback can run on the
-- async loading thread). FindAllOf walks every object, so it only runs while the mouse cursor is
-- shown (menus), every 0.7 s; until the menu has been seen with a cursor once, also every 15 s.
local function find_open_menu()
    local list = safe(function() return timed("FindAllOf Widget_InGameMenu_C", FindAllOf, "Widget_InGameMenu_C") end)
    if type(list) ~= "table" then return nil end
    for _, m in ipairs(list) do
        if valid(m) and safe(function() return m:IsInViewport() end) == true
            and safe(function() return m:IsVisible() end) == true then
            return m
        end
    end
    return nil
end

local function menu_open_now(m)
    return valid(m) and safe(function() return m:IsInViewport() end) == true
        and safe(function() return m:IsVisible() end) == true
end

local function menu_state(t)
    local pc = local_pc()
    local cur = pc and safe(function() return pc.bShowMouseCursor end)
    if not menu_open_now(MENU.menu) then
        local gap = (cur == true) and 0.7 or 15
        if (cur == true or not MENU.cursor_ok) and t - MENU.last_find > gap then
            MENU.last_find = t
            local m = find_open_menu()
            if m and addr(m) ~= addr(MENU.menu) then
                MENU.menu, MENU.frag, MENU.ignore = m, nil, nil
            end
        end
    end
    local open = menu_open_now(MENU.menu)
    if not open then
        MENU.ignore = nil
        return false, false
    end
    -- the detail key was pressed while our panel was up: treat this menu instance as closed
    if MENU.ignore and MENU.ignore == addr(MENU.menu) then return false, false end
    -- after alt-tab the menu widget can stay "visible" although the game is back in play:
    -- once we have seen the mouse cursor in the menu, no cursor means no menu
    if cur == true then
        if not MENU.cursor_ok then dbg("menu shows the mouse cursor: menu search now only runs while the cursor is shown") end
        MENU.cursor_ok = true
    elseif cur == false and MENU.cursor_ok then
        if not MENU.stale_logged then
            MENU.stale_logged = true
            dbg("menu widget still visible but no mouse cursor: treated as closed")
        end
        return false, false
    end
    MENU.stale_logged = false
    -- menu is open: searching here is fine (never runs during combat)
    -- (the fragments page is a child of the menu: a new menu instance resets MENU.frag above)
    if not valid(MENU.frag) and t - MENU.last_frag_find > 1.5 then
        MENU.last_frag_find = t
        MENU.frag = safe(function() return timed("FindFirstOf fragments page", FindFirstOf, "Widget_RelicFragmentsScreen_C") end)
    end
    local frag = valid(MENU.frag) and safe(function() return MENU.frag:IsVisible() end) == true
    return true, frag
end

----------------------------------------------------------------------
-- hold key
----------------------------------------------------------------------
-- config uses UE4SS key names (H, F10, CAPS_LOCK ...); the engine wants Unreal FKey names
local UNREAL_KEY = {
    CAPS_LOCK = "CapsLock", TAB = "Tab", SPACE = "SpaceBar", BACKSPACE = "BackSpace", RETURN = "Enter",
    ENTER = "Enter", ESCAPE = "Escape", PAUSE = "Pause", PAGE_UP = "PageUp", PAGE_DOWN = "PageDown",
    END = "End", HOME = "Home", INS = "Insert", INSERT = "Insert", DEL = "Delete", DELETE = "Delete",
    LEFT_ARROW = "Left", RIGHT_ARROW = "Right", UP_ARROW = "Up", DOWN_ARROW = "Down",
    LEFT_SHIFT = "LeftShift", RIGHT_SHIFT = "RightShift", LEFT_CONTROL = "LeftControl",
    RIGHT_CONTROL = "RightControl", LEFT_ALT = "LeftAlt", RIGHT_ALT = "RightAlt",
    ZERO = "Zero", ONE = "One", TWO = "Two", THREE = "Three", FOUR = "Four", FIVE = "Five",
    SIX = "Six", SEVEN = "Seven", EIGHT = "Eight", NINE = "Nine",
    NUM_ZERO = "NumPadZero", NUM_ONE = "NumPadOne", NUM_TWO = "NumPadTwo", NUM_THREE = "NumPadThree",
    NUM_FOUR = "NumPadFour", NUM_FIVE = "NumPadFive", NUM_SIX = "NumPadSix", NUM_SEVEN = "NumPadSeven",
    NUM_EIGHT = "NumPadEight", NUM_NINE = "NumPadNine", MULTIPLY = "Multiply", ADD = "Add",
    SUBTRACT = "Subtract", DECIMAL = "Decimal", DIVIDE = "Divide", OEM_TILDE = "Tilde",
    OEM_MINUS = "Hyphen", OEM_PLUS = "Equals", OEM_COMMA = "Comma", OEM_PERIOD = "Period",
    LEFT_MOUSE_BUTTON = "LeftMouseButton", RIGHT_MOUSE_BUTTON = "RightMouseButton",
    MIDDLE_MOUSE_BUTTON = "MiddleMouseButton", XBUTTON_ONE = "ThumbMouseButton", XBUTTON_TWO = "ThumbMouseButton2",
}
local function unreal_key_name(k)
    k = trim(k or "")
    if k == "" then return nil end
    local up = k:upper()
    if UNREAL_KEY[up] then return UNREAL_KEY[up] end
    if up:match("^%a$") or up:match("^F%d%d?$") then return up end
    if k:find("%l") then return k end                       -- already an Unreal name (CapsLock ...)
    -- SOME_KEY -> SomeKey
    return (up:lower():gsub("_(%a)", function(c) return c:upper() end):gsub("^%a", string.upper))
end

-- cached FKey structs; IsInputKeyDown only works while the game has input (not in menus)
local FKEYS = {}
local function fkey(name)
    local k = FKEYS[name]
    if k == nil then
        local un = unreal_key_name(name)
        local fn = un and safe(function() return FName(un) end)
        k = fn and { KeyName = fn } or false
        FKEYS[name] = k
        dbg("key " .. tostring(name) .. " -> " .. tostring(un))
    end
    return k or nil
end

local KEY_ERR = false
local function key_down(pc, name)
    local k = fkey(name)
    if not pc or not k then return false end
    local ok, r = pcall(function() return pc:IsInputKeyDown(k) end)
    if not ok then
        if not KEY_ERR then KEY_ERR = true; say("key state check failed: " .. tostring(r)) end
        return false
    end
    return r == true
end

local KEY = { press_t = nil, long = false }
local function hold_still_down(pc)
    return key_down(pc, CFG.detail_key)
end

----------------------------------------------------------------------
-- main UI tick (game thread)
----------------------------------------------------------------------
local LAST = { rev = -1, mode = nil, live_t = -100, anim_t = -100 }
local UI_OK = false
local ANIM_LOOP = false

local function ensure_ui(t)
    if HUD and PANEL and valid(HUD.w) and valid(PANEL.w)
        and safe(function() return HUD.w:IsInViewport() end) == true then
        return true
    end
    if t - UI.last_build < 2 then return false end
    UI.last_build = t
    local pc = local_pc()
    if not pc or not ui_classes() then return false end
    find_game_font()
    -- local player key first, so the player colors are right from the start
    local ps = safe(function() return pc.PlayerState end)
    if valid(ps) then LOCAL_KEY = player_key_of_ps(ps) end
    -- an old UI that is somehow still on screen goes away first (no double HUD)
    local function drop(r) if r and valid(r.w) then pcall(function() r.w:RemoveFromParent() end) end end
    drop(HUD); drop(PANEL)
    HUD, PANEL = nil, nil
    local t0 = os.clock()
    local ok, err = pcall(function()
        HUD = build_hud(pc)
        PANEL = build_panel(pc)
        PANEL.mode = nil
        set_panel_mode("off", t)
    end)
    if not ok then
        say("UI build failed: " .. tostring(err))
        drop(HUD); drop(PANEL)
        HUD, PANEL = nil, nil
        return false
    end
    dbg(string.format("UI built (%d widgets, %.0f ms)", #HUD.rects + #HUD.texts + #PANEL.rects + #PANEL.texts, (os.clock() - t0) * 1000))
    LAST.rev, LAST.mode = -1, nil
    AN.ns.h = {}
    return true
end

local function update_mode(t)
    local open, frag = menu_state(t)
    if not open then VIEW.expanded = false end
    local mode
    if open then
        VIEW.hold, VIEW.toggle = false, false -- opening the menu closes the combat panel
        mode = frag and (VIEW.expanded and "expanded" or "label") or "off"
    else
        if VIEW.hold then
            -- tap = panel stays open (until the next press), hold = open while the key is held.
            -- The game may report the key as "not held" for a moment right after the press,
            -- so nothing is decided during the first tap time.
            local pc = local_pc()
            local held = pc and hold_still_down(pc) or false
            local dt = t - (KEY.press_t or t)
            if held then
                if dt >= CFG.tap_time then KEY.long = true end
            elseif dt >= CFG.tap_time then
                VIEW.hold = false
                if KEY.long or CFG.detail_mode == "hold" then
                    dbg(string.format("detail key: released after %.2fs, panel closed", dt))
                else
                    VIEW.toggle = true
                    dbg(string.format("detail key: tap (not held after %.2fs), panel stays open until the next press", dt))
                end
            end
        end
        mode = (VIEW.hold or VIEW.toggle) and "hold" or "off"
    end
    if mode ~= LAST.mode then
        if LAST.mode ~= nil then dbg("panel mode " .. tostring(LAST.mode) .. " -> " .. mode) end
        LAST.mode = mode
        set_panel_mode(mode, t)
    end
    show_root(HUD, CFG.hud_enabled and not open and F.cur ~= nil)
end

local function render(t, live)
    anim_begin(t)
    if F.rev ~= LAST.rev then
        LAST.rev = F.rev
        HUD.dirty, PANEL.dirty = true, true
    end
    if HUD.shown and (HUD.dirty or live or AN.was.h) then
        HUD.dirty = false
        draw_hud(t)
    end
    -- a lost color update cannot stick for long: re-send a few colors each frame
    if PANEL.mode ~= "off" then resync_colors(PANEL, 6) end
    if HUD.shown and live then resync_colors(HUD, 6) end
    if PANEL.mode ~= "off" and (PANEL.dirty or AN.was.d or AN.was.l or (live and PANEL.mode == "label")) then
        PANEL.dirty = false
        draw_panel(t)
    end
    -- the fast loop only runs while something moves or a panel is on screen
    ANIM_LOOP = CFG.anim and (PANEL.mode ~= "off" or AN.busy.h)
end

local LIB = nil
local function mouse_and_viewport(pc)
    if not valid(LIB) then LIB = safe(function() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end) end
    if not valid(LIB) then return nil end
    local m = safe(function() return LIB:GetMousePositionOnViewport(pc) end)
    local size = safe(function() return LIB:GetViewportSize(pc) end)
    local scale = safe(function() return LIB:GetViewportScale(pc) end) or 1
    if not m or not size or scale <= 0 then return nil end
    local mx, my = safe(function() return m.X end), safe(function() return m.Y end)
    local vw = safe(function() return size.X end)
    if not mx or not vw then return nil end
    return mx, my, vw / scale
end

-- click area under the mouse (top-most first)
local function hit_test()
    if not PANEL or not PANEL.fgeom then return nil end
    local pc = local_pc()
    if not pc then return nil end
    local mx, my, vw = mouse_and_viewport(pc)
    if not mx then return nil, true end
    local g = PANEL.fgeom
    local ox = g[1] and (vw - g[2] - g[4]) or g[2]
    local lx, ly = mx - ox, my - g[3]
    for i = #VIEW.clicks, 1, -1 do
        local c = VIEW.clicks[i]
        if lx >= c.x and lx <= c.x + c.w and ly >= c.y and ly <= c.y + c.h then return c end
    end
    return nil
end

local function update_hover()
    local c = hit_test()
    local id = c and c.id or nil
    if id ~= VIEW.hover then
        VIEW.hover = id
        PANEL.dirty = true
    end
end

local function ui_tick()
    local t = now()
    poll_bars(t)
    if not CFG.ui_enabled then UI_OK = false return end -- statistics only (config: ui_enabled = 0)
    if IS_HOST == false then
        -- joined someone else's game: nothing to show (only the host sees everyone's damage)
        if UI_OK then
            set_panel_mode("off", t)
            show_root(HUD, false)
            VIEW.hold, VIEW.toggle, VIEW.expanded = false, false, false
        end
        UI_OK = false
        return
    end
    UI_OK = ensure_ui(t)
    if not UI_OK then return end
    update_mode(t)
    if not LOCAL_KEY then
        local pc = local_pc()
        local ps = pc and safe(function() return pc.PlayerState end)
        if valid(ps) then LOCAL_KEY = player_key_of_ps(ps) end
    end
    local live = t - LAST.live_t >= 0.5
    if live then LAST.live_t = t end
    render(t, live)
end

-- ~30 fps while a panel is open or something is animating
local function anim_tick()
    if not UI_OK or not HUD or not PANEL then return end
    local t = now()
    if t - LAST.anim_t < 0.025 then return end
    LAST.anim_t = t
    update_mode(t)
    if PANEL.mode == "label" or PANEL.mode == "expanded" then update_hover() end
    render(t, false)
end

----------------------------------------------------------------------
-- clicks (Tab fragments page only)
----------------------------------------------------------------------
local function do_action(a)
    if not a then return end
    local kind = a[1]
    if kind == "collapse" then VIEW.expanded = false
    elseif kind == "expand" then VIEW.expanded = true
    elseif kind == "tab" then VIEW.tab = a[2]
    elseif kind == "hist_older" then
        if VIEW.hist < #F.history then VIEW.hist = VIEW.hist + 1 end
        VIEW.hist_ref = F.history[VIEW.hist]
    elseif kind == "hist_newer" then
        if VIEW.hist > 0 then VIEW.hist = VIEW.hist - 1 end
        VIEW.hist_ref = VIEW.hist > 0 and F.history[VIEW.hist] or nil
    end
    dbg("click action " .. tostring(kind) .. " " .. tostring(a[2] or ""))
    if PANEL then PANEL.dirty = true end
end

local function on_click()
    if not PANEL or not (PANEL.mode == "label" or PANEL.mode == "expanded") then return end
    local c, nomouse = hit_test()
    if nomouse then dbg("click: mouse position unavailable") return end
    if c then do_action(c.act) end
    if UI_OK then update_mode(now()); render(now(), false) end
end

----------------------------------------------------------------------
-- keys and clicks: polled on the game thread (see THREADING at the top)
----------------------------------------------------------------------
local ERR_SEEN, ERR_N = {}, 0
local function run_logged(fn, what)
    local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
    if not ok then
        local key = what .. tostring(err):sub(1, 200)
        if not ERR_SEEN[key] and ERR_N < 12 then
            ERR_SEEN[key] = true
            ERR_N = ERR_N + 1
            dbg(what .. " error: " .. tostring(err):gsub("\n", " | "))
        end
    end
end

local function on_detail_press()
    if PANEL and (PANEL.mode == "label" or PANEL.mode == "expanded") then
        -- escape hatch: our menu panel is up (possibly stuck after alt-tab) -> hide it
        MENU.ignore = addr(MENU.menu)
        VIEW.expanded = false
        dbg("detail key in menu: menu panel hidden")
        ui_tick()
        return
    end
    if CFG.detail_mode == "toggle" or VIEW.toggle then
        VIEW.toggle = not VIEW.toggle
        VIEW.hold = false
    else
        VIEW.hold = true
        KEY.press_t, KEY.long = now(), false
    end
    dbg("detail key: press (" .. (VIEW.toggle and "toggle on" or (VIEW.hold and "hold" or "off")) .. ")")
    ui_tick()
end

local function on_reset_press()
    end_fight("manual reset")
    F.cur = nil
    F.rev = F.rev + 1
    dbg("manual reset")
end

-- edge detection: a press is "down now, up at the previous poll". Polls run every ~33 ms and a
-- key tap lasts ~80+ ms, so taps are not missed.
local KS = { detail = false, reset = false, click = false, click_logged = false }
local function poll_keys()
    local pc = (IS_HOST ~= false) and local_pc() or nil
    if not pc then
        KS.detail, KS.reset = false, false
        return
    end
    if CFG.ui_enabled then
        local d = key_down(pc, CFG.detail_key)
        if d and not KS.detail then run_logged(on_detail_press, "detail key") end
        KS.detail = d
    end
    if CFG.reset_key ~= "" then
        local r = key_down(pc, CFG.reset_key)
        if r and not KS.reset then run_logged(on_reset_press, "reset key") end
        KS.reset = r
    end
end

-- Tab menu page: the transparent catcher Button reports the press (Slate handles it, so it works
-- in menus); the mouse key state is only a fallback (the game may not see keys in menus)
local function poll_click()
    if not PANEL or not (PANEL.mode == "label" or PANEL.mode == "expanded") then
        KS.click = false
        return
    end
    local pressed = false
    local c = PANEL.catcher
    if c then pressed = safe(function() return c.obj:IsPressed() end) == true end
    if not pressed then pressed = key_down(local_pc(), "LEFT_MOUSE_BUTTON") end
    if pressed and not KS.click then
        if not KS.click_logged then
            KS.click_logged = true
            dbg("first click detected via " .. ((c and safe(function() return c.obj:IsPressed() end) == true) and "catcher button" or "mouse key state"))
        end
        run_logged(on_click, "click")
    end
    KS.click = pressed
end

local function write_todo(t)
    if not TODO.dirty or t - TODO.t < 30 then return end
    TODO.t, TODO.dirty = t, false
    local ids = {}
    for id, kind in pairs(TODO.ids) do ids[#ids + 1] = { id, kind } end
    table.sort(ids, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    local f = io.open(LOG_DIR .. "\\names_todo.txt", "w")
    if not f then return end
    f:write("# ids seen in combat without a name in names.txt. Copy lines into names.txt and fill in the name.\n")
    for _, e in ipairs(ids) do f:write("# [", e[2], "]\n", e[1], " =\n") end
    f:close()
end

----------------------------------------------------------------------
-- the one timer (game thread)
----------------------------------------------------------------------
local TICK_MS = 33
local T = { hook_check = -100, slow = -100, prune = 0, start = now(), ticks = 0 }

local function slow_tick(t)
    if t - T.hook_check > 5 then
        T.hook_check = t
        run_logged(install_hooks, "install_hooks")
    end
    run_logged(ui_tick, "ui_tick")
    if t - T.prune > 30 then
        T.prune = t
        local np = 0
        if F.cur then for _ in pairs(F.cur.players) do np = np + 1 end end
        dbg(string.format("alive %.0fs: %s, panel=%s, fight=%s (%d players, %s), ticks=%d | %s", t - T.start,
            IS_HOST == false and "joined (idle)" or (IS_HOST and "host" or "?"), tostring(PANEL and PANEL.mode),
            F.cur and (F.pending and "ended" or "running") or "none", np, F.cur and fmt(F.cur.total) or "-", T.ticks,
            perf_report()))
        for k, v in pairs(res_cache) do if t - v.t > 10 then res_cache[k] = nil end end
    end
    pcall(write_todo, t)
end

local function main_tick()
    T.ticks = T.ticks + 1
    local t = now()
    poll_keys()
    if UI_OK then poll_click() end
    if t - T.slow >= 0.25 then
        T.slow = t
        timed("slow tick (HUD / bars / menu)", slow_tick, t)
    elseif ANIM_LOOP then
        timed("animation tick", run_logged, anim_tick, "anim_tick")
    end
end

pcall(RegisterLoadMapPostHook, function()
    dbg("map load")
    res_cache = {}
    PS_KEY = { first = {} }
    bar_map_loaded(now())
    MENU.menu, MENU.frag, MENU.last_find = nil, nil, -100
    PC_CACHE.pc, PC_CACHE.t = nil, -100
    T.hook_check = -100
    ANIM_LOOP = false
    KS.detail, KS.reset, KS.click = false, false, false
    end_fight("map load")
    F.next_title, F.next_kind = nil, nil
end)

-- read-only handle for testing / other mods
R2DPS_STATE = { F = F, VIEW = VIEW, PLAYERS = PLAYERS, ui = function() return HUD, PANEL end, anim = function() anim_tick() end,
    tick = function() main_tick() end, KS = KS, MENU = MENU }

-- Start the timer LAST: from here on Lua runs on the game thread only.
if type(LoopInGameThreadWithDelay) ~= "function" then
    say("v" .. VERSION .. " NOT started: this UE4SS has no LoopInGameThreadWithDelay (too old). " ..
        "Run Install.bat again, it upgrades UE4SS. The mod stays off so it cannot crash the game.")
else
    say("v" .. VERSION .. " loaded. detail key=" .. CFG.detail_key .. " (" .. CFG.detail_mode .. ")" ..
        (CFG.ui_enabled and "" or "  UI OFF (ui_enabled = 0)") .. "  log=" .. LOG_DIR)
    local ok, err = pcall(LoopInGameThreadWithDelay, TICK_MS, function()
        local ok2, err2 = pcall(main_tick)
        if not ok2 then dbg_once("tick:" .. tostring(err2), "tick error: " .. tostring(err2)) end
    end)
    if not ok then say("could not start the game-thread timer (" .. tostring(err) .. "): mod stays off") end
end
