-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

-- =============================================================================
-- Floating Combat Text
-- Damage and healing numbers drawn above the unit they land on, replacing
-- Blizzard's own floating combat text (whose fct CVars are zeroed while this is on).
-- =============================================================================

local addon = select(2, ...)
local L = addon.L

local KEY = "combattext"
local FONT = addon.Fonts.PRIMARY

-- Everything tunable from DragonUI Options. The options tab holds the same numbers; read from the profile
-- at spawn time rather than at load, so a change shows on the next number without a reload.
local DEFAULTS = {
    lifetime = 0.6,     -- total time on screen
    textSize = 16,      -- font height
    verticalSpread = 16, -- drift is randomised within +/- this, so numbers go up or down
    offsetX = 28,       -- horizontal jitter around the anchor
    offsetY = -70,      -- start below the plate's centre, over the body rather than the top of the head
    fontStyle = "SHADOW",
    showDamageTaken = false,  -- off by default: incoming hits are noise while you are watching your own
}

-- SetFont flags: NONE means "no flags at all", which is an empty string, not the word NONE. THICKOUTLINE
-- is the longest so it sets the min height by itself; SHADOW is SetShadowOffset, not a flag string.
local FONT_FLAGS = { NONE = "", OUTLINE = "OUTLINE", THICKOUTLINE = "THICKOUTLINE" }

local FADE = 0.15       -- fade runs over the last FADE seconds of the lifetime
-- Crits are told apart by size alone, not colour: spells are already yellow, so a differently coloured
-- crit would be indistinguishable from a normal spell hit.
local CRIT_SCALE = 1.6
-- A crit arrives with a punch: it appears at CRIT_GROW_FROM of its size and snaps up to full over
-- CRIT_GROW_DURATION, then holds that size for the rest of its life. Growing up from a smaller start
-- reads far more than a swell around the final size, which the eye barely catches at this lifetime.
local CRIT_GROW_DURATION = 0.06
local CRIT_GROW_FROM = 0.4
-- Spells and companion hits (the yellow numbers) read 20% larger than the player's own auto attacks.
local SPELL_BOOST = 1.2

local function Setting(key)
    local modules = addon.db and addon.db.profile and addon.db.profile.modules
    local stored = modules and modules[KEY] and modules[KEY][key]
    if type(stored) == type(DEFAULTS[key]) then return stored end
    return DEFAULTS[key]
end

-- The client's own list, read out of Wow.exe's CVar descriptions. fctDamage does not exist on
-- 3.3.5a; the damage switches are the plain ones (CombatDamage, CombatHealing, PetMeleeDamage,
-- PetSpellDamage, CombatLogPeriodicSpells), and enableCombatText is the master switch.
local FCT_CVARS = {
    "enableCombatText",
    "CombatDamage", "CombatHealing", "PetMeleeDamage", "PetSpellDamage", "CombatLogPeriodicSpells",
    "fctSpellMechanicsOther", "fctSpellMechanics", "fctAllSpellMechanics", "fctAuras",
    "fctHonorGains", "fctPeriodicEnergyGains", "fctEnergyGains", "fctLowManaHealth",
    "fctComboPoints", "fctFriendlyHealers", "fctReactives", "fctRepChanges",
    "fctDamageReduction", "fctDodgeParryMiss", "fctCombatState",
}

-- A CVar this client does not carry raises a Lua error on both GetCVar and SetCVar on 3.3.5a
-- ("Couldn't find CVar named ..."), not a silent no-op, so both are probed.
local function ReadCVar(name)
    local ok, value = pcall(GetCVar, name)
    return ok and value or nil
end

local function SetCVarIfKnown(name, value)
    if ReadCVar(name) then pcall(SetCVar, name, value) end
end

local CombatText = {
    initialized = false,
    applied = false,
}

if addon.RegisterModule then
    addon:RegisterModule(KEY, CombatText,
        L["Floating Combat Text"],
        L["Damage and healing numbers over the unit they land on, replacing Blizzard's floating combat text."],
        { lifecyclePrefix = "CombatText" })
end

-- =============================================================================
-- ANCHOR RESOLUTION
-- =============================================================================

-- Only numbers the player is responsible for: self, own pet, own vehicle. The combat log fires for
-- every entity in range, and without this the screen fills with damage other players take and deal.
local function IsMine(guid)
    if not guid then return false end
    if guid == UnitGUID("player") then return true end
    if UnitExists("pet") and guid == UnitGUID("pet") then return true end
    if UnitExists("vehicle") and guid == UnitGUID("vehicle") then return true end
    return false
end

-- The number must follow the unit's 3D model, and on 3.3.5a the only Lua frame that tracks a model in
-- the world is its nameplate -- it floats over the model and moves with it. There is no world-to-screen
-- projection available to an addon on this client (MSBT, the reference implementation, cannot do this
-- either; it uses fixed screen corners), so a plate is the whole mechanism.
--
-- Two sources, in order: DragonUI's own nameplates module, whose GUID -> plate reverse map is exact,
-- then the raw nameplate1..N unit tokens for a plate it has not bound yet. NPCs on the 3.3.5a server do
-- carry nameplate tokens, so this catches packs and untargeted mobs too.
local tokenCache = {}
local TOKEN_CACHE_TTL = 1

local function FindPlateFrame(guid)
    if not guid then return nil end

    local NP = addon.Nameplates
    local state = NP and NP.state
    if state and state.GUIDToPlate then
        local pd = state.GUIDToPlate[guid]
        local frame = pd and pd.plate
        if frame and frame.IsShown and frame:IsShown() then
            return frame
        end
    end

    local cached = tokenCache[guid]
    local now = GetTime()
    if cached and (now - cached.at) < TOKEN_CACHE_TTL then
        return cached.frame
    end
    local found
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then
            found = _G["NamePlate" .. i]
            break
        end
    end
    tokenCache[guid] = { frame = found, at = now }
    return found
end

-- =============================================================================
-- TEXT POOL
-- =============================================================================

local COLORS = {
    physical = { 1, 1, 1 },        -- auto attacks: white
    spell    = { 1, 0.85, 0.2 },   -- spells and anything a companion lands: yellow
    heal     = { 0.25, 1, 0.4 },
}

local RED = { 1, 0.25, 0.25 }      -- damage the player takes

local pool = {}

-- Diagnostic: what the last number did. Read with /run DragonUI.CombatTextDebug()
local lastSpawn
local rawSeen, rawDamage = 0, 0

local function Release(f)
    -- OnUpdate keeps firing on a hidden frame on 3.3.5a; leaving it attached makes a released
    -- frame age out a second time and push itself into the pool again, so Acquire hands the same
    -- frame to two spawns and one overwrites the other. Detach it instead.
    f:SetScript("OnUpdate", nil)
    f:Hide()
    f._elapsed = nil
    pool[#pool + 1] = f
end

local function OnUpdate(self, elapsed)
    local e = (self._elapsed or 0) + elapsed
    self._elapsed = e
    local t = e / self._duration
    if t >= 1 then
        Release(self)
        return
    end
    local ease = 1 - (1 - t) * (1 - t)   -- fast out, slow in
    local x = self._sx + (self._dx - self._sx) * ease
    local y = self._sy + (self._dy - self._sy) * ease
    if self._pulse then
        -- Ease-out: most of the growth lands in the first frames, then it settles. It ends exactly on the
        -- base size, so there is nothing to overshoot and bounce back from.
        local pe = e / CRIT_GROW_DURATION
        if pe < 1 then
            local grown = 1 - (1 - pe) * (1 - pe)
            self:SetScale(self._baseScale * (CRIT_GROW_FROM + (1 - CRIT_GROW_FROM) * grown))
        elseif not self._pulseDone then
            self:SetScale(self._baseScale)
            self._pulseDone = true
        end
    end
    -- Only the offset is rewritten: the frame keeps the anchor as its point, so a plate that is still
    -- moving carries the number with it instead of leaving it behind (SetParent is not an option -- the
    -- plates are protected, and reparenting from tainted code is refused in combat).
    if self._anchor then
        self:SetPoint("CENTER", self._anchor, "CENTER", x, y)
    else
        self:SetPoint("CENTER", UIParent, "CENTER", x, y)
    end
    -- Fully opaque until the last FADE seconds, then a straight ramp to zero, so the number is readable
    -- for most of its life instead of dimming the whole time.
    local fadeStart = self._duration - FADE
    if e <= fadeStart then
        self:SetAlpha(1)
    else
        self:SetAlpha((self._duration - e) / FADE)
    end
end

local function Acquire()
    local f = #pool > 0 and table.remove(pool) or nil
    if f then return f end
    f = CreateFrame("Frame", nil, UIParent)
    -- DIALOG, not HIGH: DragonUI raises its own unit-frame art to HIGH (see player.lua's dragon
    -- decoration), so a HIGH number of the same level is drawn under it and disappears over the
    -- target frame. Level 0 keeps it under real dialogs while clearing every unit frame.
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(0)
    -- Sized per spawn to the actual text; this is only a starting box so the frame is never zero-sized.
    f:SetSize(40, 16)
    f:SetClampedToScreen(true)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(FONT, DEFAULTS.textSize, "OUTLINE")
    f.text:SetPoint("CENTER")
    return f
end

local function Spawn(payload, kind, crit, guid, color)
    if payload == nil then return end
    if type(payload) == "number" and payload <= 0 then return end

    -- Follow the victim's plate, so the number rides its 3D model. A plate that exists but is not shown
    -- (out of range, or nameplates toggled off) still returns stale centre coords, so it must be dropped
    -- here rather than at the draw. Only then fall back to the target frame, whose art does not move.
    local anchor = FindPlateFrame(guid)
    if not (anchor and anchor.IsShown and anchor:IsShown()) then anchor = nil end

    local useFallback = false
    if not anchor and guid == UnitGUID("target") then
        local tf = _G.TargetFrame
        if tf and tf:IsShown() then
            anchor, useFallback = tf, true
        end
    end

    local f = Acquire()
    -- Read per spawn so an options change applies to the next number, with no reload.
    local vSpread, size = Setting("verticalSpread"), Setting("textSize")
    local spreadX, spreadY = Setting("offsetX"), Setting("offsetY")
    local style = Setting("fontStyle")
    if style == "SHADOW" then
        -- SHADOW is not a flag string, so the font takes no flags and the offset supplies the effect.
        f.text:SetFont(FONT, size, "")
        f.text:SetShadowColor(0, 0, 0, 1)
        f.text:SetShadowOffset(1, -1)
    else
        f.text:SetFont(FONT, size, FONT_FLAGS[style] or FONT_FLAGS.THICKOUTLINE)
        -- A frame is pooled and reused, so a shadow set by a previous number has to be cleared or it
        -- stays on an outline choice too.
        f.text:SetShadowOffset(0, 0)
    end
    -- Offsets are kept in the anchor's space, so the anchor can be resolved by SetPoint every frame and
    -- the number still rides a plate that is moving. Crits get no spread at all, so the big number always
    -- lands on the unit rather than drifting off it.
    f._anchor = anchor
    if crit then
        f._sx, f._sy = 0, spreadY
        f._dx, f._dy = 0, spreadY
    else
        f._sx, f._sy = math.random(-spreadX, spreadX), spreadY
        f._dx, f._dy = f._sx + math.random(-spreadX, spreadX),
            spreadY + math.random(-vSpread, vSpread)
    end
    f._elapsed, f._duration = 0, Setting("lifetime")
    f.text:SetText(type(payload) == "string" and payload or tostring(payload))
    local c = color or COLORS[kind]
    f.text:SetTextColor(c[1], c[2], c[3])
    -- Fit the frame to the text. SetScale scales the frame about its own centre, and the fontstring is
    -- centred in it, so a frame bigger than its text scales the glyphs about a point that is not their
    -- centre -- which is what makes the number look like it grows from its top edge instead of its middle.
    local tw, th = f.text:GetStringWidth(), f.text:GetStringHeight()
    f:SetSize(tw, th)
    -- Yellow reads larger, and a crit multiplies on top of that rather than replacing it, so a crit spell
    -- is still visibly bigger than a crit auto attack.
    local scale = crit and CRIT_SCALE or 1
    if c == COLORS.spell then scale = scale * SPELL_BOOST end
    f._baseScale = scale
    -- Only crits pulse; resetting the flag each spawn stops a pooled non-crit inheriting the last one's.
    f._pulse = crit or false
    f._pulseDone = false
    -- A crit starts at its small size, so the very first rendered frame is already growing instead of
    -- flashing at full size for a frame and then snapping down.
    f:SetScale(crit and scale * CRIT_GROW_FROM or scale)
    f:SetAlpha(1)
    f:ClearAllPoints()
    if anchor then
        f:SetPoint("CENTER", anchor, "CENTER", f._sx, f._sy)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", f._sx, f._sy)
    end
    f:SetScript("OnUpdate", OnUpdate)
    f:Show()
    lastSpawn = { amount = payload, kind = kind, crit = crit, guid = guid,
        anchored = anchor ~= nil, fallback = useFallback, anchor = anchor and anchor.GetName and anchor:GetName() }
end

-- POC diagnostic: /run DragonUI.CombatTextDebug()
-- Prints what the last number did. Tell us whether an outgoing hit is even reaching Spawn.
function addon.CombatTextDebug()
    local function dump(label, t)
        if not t then print(label, "(none)") return end
        print(string.format("%s amount=%s kind=%s crit=%s guid=%s anchored=%s fallback=%s anchor=%s",
            label, tostring(t.amount), tostring(t.kind), tostring(t.crit),
            tostring(t.guid), tostring(t.anchored), tostring(t.fallback), tostring(t.anchor)))
    end
    dump("[FCT] last spawn:", lastSpawn)
    print("[FCT] applied=", tostring(CombatText.applied),
        "targetGUID=", tostring(UnitExists("target") and UnitGUID("target")))
    local NP = addon.Nameplates
    print("[FCT] nameplates applied=", tostring(NP and NP.module and NP.module.applied),
        "plates=", tostring(NP and NP.module and NP.module.plates and #NP.module.plates),
        "guidMap=", tostring(NP and NP.state and NP.state.GUIDToPlate ~= nil))
    if lastSpawn and lastSpawn.guid then
        local pd = NP and NP.state and NP.state.GUIDToPlate and NP.state.GUIDToPlate[lastSpawn.guid]
        print("[FCT] plate for that guid=", tostring(pd and pd.plate and pd.plate:GetName()))
    end
    print("[FCT] CLEU seen=", tostring(rawSeen), "damageSeen=", tostring(rawDamage))
end

-- POC diagnostic: /run DragonUI.CombatTextTest()
-- Draws one number through the exact same path a real hit uses, on the current target if there is one.
-- If this shows, the pipeline and the anchor both work. If it does not, nothing else can work either.
function addon.CombatTextTest()
    if not CombatText.applied then
        print("[FCT] module is not applied - enable it in Modules > Frames first")
        return
    end
    -- Over the current target: the exact path a real hit on it takes.
    Spawn(11111, "physical", true, UnitExists("target") and UnitGUID("target") or nil)
    -- At raw screen centre, the path damage taken already uses and which we know renders
    Spawn(22222, "heal", false, nil)
    print("[FCT] two numbers drawn: 11111 over the target's plate/model, 22222 at screen centre.")
    addon.CombatTextDebug()
end

-- =============================================================================
-- COMBAT LOG
-- =============================================================================

-- Arg positions differ per subevent: SWING carries no spell triple, RANGE and SPELL carry one, and
-- heals put critical where damage puts resisted. a[1] is the timestamp, so the base-8 fields are
-- already shifted by one (a[6] is destGUID).
local SWING_AMOUNT, SWING_CRIT = 9, 15   -- SWING_DAMAGE: no spell triple
local SPELL_AMOUNT, SPELL_CRIT = 12, 18  -- RANGE/SPELL damage, DAMAGE_SHIELD, DAMAGE_SPLIT
local HEAL_AMOUNT, HEAL_CRIT = 12, 15    -- SPELL_HEAL, SPELL_PERIODIC_HEAL: amount..absorbed, critical

-- Miss events carry a missType string instead of an amount. Every non-swing family lays it out the same
-- way (spellID, spellName, spellSchool, missType, absorbed), so one offset covers SPELL, RANGE and
-- DAMAGE_SHIELD; SWING has no spell triple and puts the miss where SWING_DAMAGE puts its amount. A nil
-- missType is the client's way of saying the whole hit was absorbed, the one case worth a number.
local SPELL_MISS_TYPE = 12  -- SPELL_MISSED / RANGE_MISSED / DAMAGE_SHIELD_MISSED: after the spell triple

local MISS_TEXT = {
    MISS    = "Miss",
    DODGE   = "Dodge",
    PARRY   = "Parry",
    BLOCK   = "Block",
    EVADE   = "Evade",
    IMMUNE  = "Immune",
    DEFLECT = "Deflect",
    RESIST  = "Resist",
    REFLECT = "Reflect",
    ABSORB  = "Absorb",
}

local GREY = { 0.7, 0.7, 0.7 }

-- Shared by every event: the combat log is hot, one scratch table beats one allocation per line.
local scratch = {}

local function OnCombatLog(...)
    rawSeen = rawSeen + 1
    local n = select("#", ...)
    for i = 1, n do scratch[i] = select(i, ...) end

    local eventType = scratch[2]
    local sourceGUID = scratch[3]
    local destGUID = scratch[6]

    -- Anything another player did or took is not ours to draw.
    if not (IsMine(sourceGUID) or IsMine(destGUID)) then
        for i = 1, n do scratch[i] = nil end
        return
    end

    local amount, crit, kind, text, isHeal
    local suffix = eventType:match("_(%w+)$")
    if eventType == "SWING_DAMAGE" then
        amount, crit, kind = scratch[SWING_AMOUNT], scratch[SWING_CRIT], "damage"
    elseif suffix == "HEAL" then
        -- Whole absorbed heals also report nil here; they are dropped, not shown as 0.
        amount, crit, kind, isHeal = scratch[HEAL_AMOUNT], scratch[HEAL_CRIT], "heal", true
    elseif suffix == "MISSED" then
        -- The miss is at the family's own offset, and the absorbed amount always follows it directly.
        local missAt = eventType == "SWING_MISSED" and SWING_AMOUNT or SPELL_MISS_TYPE
        local missType = scratch[missAt]
        amount = scratch[missAt + 1]
        kind = "spell"
        if missType then text = MISS_TEXT[missType] or missType end
    elseif eventType == "RANGE_DAMAGE" or eventType == "SPELL_DAMAGE"
        or eventType == "SPELL_PERIODIC_DAMAGE" or eventType == "DAMAGE_SHIELD"
        or eventType == "DAMAGE_SPLIT" then
        amount, crit, kind = scratch[SPELL_AMOUNT], scratch[SPELL_CRIT], "spell"
    else
        return
    end

    -- destGUID is read out before the scratch table is cleared, or it goes nil with it.
    for i = 1, n do scratch[i] = nil end

    -- A miss with words is drawn as words. A miss with no words and no positive amount is a fully absorbed
    -- hit, which has no useful payload at all, so it is dropped rather than shown as a bare 0.
    if type(amount) ~= "number" then amount = nil end
    if text then amount = nil end
    if not text and (not amount or amount <= 0) then return end

    -- Something the player is taking rather than dealing (the source was not ours, the destination was).
    -- Off by default: incoming hits are noise while you watch your own numbers. Covers misses taken too,
    -- so one switch governs every incoming event rather than just the ones with a number.
    local incoming = not IsMine(sourceGUID)
    if incoming and not Setting("showDamageTaken") then return end

    -- Colour by who landed the hit: the player's own auto-attack is white, a pet's SWING is still a
    -- companion hit and reads yellow, and anything the player takes is red so their own numbers read apart.
    local color
    if text then
        color = GREY
    elseif isHeal then
        color = COLORS.heal
    elseif incoming then
        color = RED
    elseif eventType == "SWING_DAMAGE" and sourceGUID == UnitGUID("player") then
        color = COLORS.physical
    else
        color = COLORS.spell
    end

    rawDamage = rawDamage + 1
    local critFlag = (crit == true or crit == 1) and not text
    Spawn(text or amount, kind, critFlag, destGUID, color)
end

-- =============================================================================
-- BLIZZARD OVERRIDE
-- =============================================================================

local savedCVars

local function HideBlizzardFCT()
    if not savedCVars then
        savedCVars = {}
        for _, name in ipairs(FCT_CVARS) do
            savedCVars[name] = ReadCVar(name)
        end
    end
    for _, name in ipairs(FCT_CVARS) do
        SetCVarIfKnown(name, 0)
    end
end

local function RestoreBlizzardFCT()
    if not savedCVars then return end
    for name, value in pairs(savedCVars) do
        if value then SetCVarIfKnown(name, value) end
    end
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog(...)
    elseif event == "PLAYER_ENTERING_WORLD" and CombatText.applied then
        HideBlizzardFCT()
    end
end)

eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

function addon.ApplyCombatTextSystem()
    CombatText.applied = true
    HideBlizzardFCT()
end

function addon.RestoreCombatTextSystem()
    CombatText.applied = false
    RestoreBlizzardFCT()
    for _, f in ipairs(pool) do
        f:Hide()
    end
end
