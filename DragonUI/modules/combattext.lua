-- Copyright (c) 2026 NeticSoul. Licensed under the MIT License; see LICENSE.

-- =============================================================================
-- Floating Combat Text
-- Damage numbers drawn above the unit they land on, replacing Blizzard's own floating combat text (whose
-- fct CVars are zeroed while this is on). Healing is deliberately left to Blizzard's own combat text: a heal
-- on a friendly unit has no plate of ours to ride, and 3.3.5a Lua cannot project a world position to the
-- screen, so Blizzard -- whose text does hang off the unit -- does that half. See NATIVE_HEAL_CVARS.
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
    verticalSpread = 24, -- drift is randomised within +/- this, so numbers go up or down
    offsetX = 28,       -- horizontal jitter around the anchor
    offsetYPercent = -180, -- percent of the plate's height; negative sits below its centre, over the body
    plateHeight = 24,   -- fallback plate height in pixels when the plate cannot be measured
    fontStyle = "SHADOW",
    showDamageTaken = false,  -- off by default: incoming hits are noise while you are watching your own
}

-- SetFont flags: NONE means "no flags at all", which is an empty string, not the word NONE. THICKOUTLINE
-- is the longest so it sets the min height by itself; SHADOW is SetShadowOffset, not a flag string.
local FONT_FLAGS = { NONE = "", OUTLINE = "OUTLINE", THICKOUTLINE = "THICKOUTLINE" }

local FADE = 0.15       -- fade runs over the last FADE seconds of the lifetime
-- Drift speed, randomised per number. The spread distance already differs per number, but every one still
-- follows the same curve, so a burst drifts in lockstep. Scaling how far along that curve a number is at a
-- given time gives each its own velocity. Hardcoded on purpose: this is feel, not a preference.
local DRIFT_SPEED_MIN, DRIFT_SPEED_MAX = 0.7, 1.4
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
-- The player's own auto attacks (white) are the most numerous number on screen, so they read a little
-- smaller than everything else to keep a burst from drowning out the heals and spells.
local PHYSICAL_SCALE = 0.9

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

-- Healing is left to Blizzard's own floating combat text rather than drawn by this module. Its numbers ride
-- the unit in the world, which is exactly what this module cannot do for a friendly target: a heal on a pet
-- or ally has no plate of ours to hang from, and 3.3.5a Lua has no world-to-screen projection to fake one.
-- These are forced back on after the loop above zeroes them -- enableCombatText is the master switch for all
-- of Blizzard's combat text, so it has to be on for any heal number to appear at all. The damage switches
-- stay off, so only healing is left to Blizzard and nothing is drawn twice.
local NATIVE_HEAL_CVARS = { "enableCombatText", "CombatHealing", "fctFriendlyHealers" }

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
local tokenCache = {}                 -- guid -> { frame, token, at }; only positive results are stored
local TOKEN_CACHE_TTL = 1

-- The raw nameplate token still bound to a GUID, and the frame it owns. One UnitGUID call per token, so this
-- is the expensive path and is only reached for a plate DragonUI has not identified yet.
local function FindNameplateToken(guid)
    for i = 1, 40 do
        local token = "nameplate" .. i
        if UnitExists(token) and UnitGUID(token) == guid then
            return token, _G["NamePlate" .. i]
        end
    end
end

-- Is this frame still the plate of this GUID? O(1), no UnitGUID calls: DragonUI clears plateData.guid the
-- moment it rebinds a plate to a different unit (NP.state.SetPlateGUID), so a plate whose guid no longer
-- matches has been recycled. This is the check the per-frame path uses.
local function PlateStillOwns(frame, guid)
    local NP = addon.Nameplates
    local state = NP and NP.state
    local pd = state and state.GUIDToPlate and state.GUIDToPlate[guid]
    if not pd or pd.plate ~= frame then return false end
    return not pd.guid or pd.guid == guid
end

-- The unit frames that stand for a unit the client gives no plate: player, target, focus, pet, and the four
-- party frames. A friendly unit usually has none -- friendly plates are off by default -- so without this a
-- number on one has nothing to ride. Party frames bind by token, not by a unit an addon can read, so the GUID
-- has to be compared; the fixed units are a plain lookup.
local FIXED_UNIT_FRAMES = { player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame", pet = "PetFrame" }

local function FixedUnitFrame(guid)
    if not guid then return nil end
    for unit, frameName in pairs(FIXED_UNIT_FRAMES) do
        if UnitExists(unit) and UnitGUID(unit) == guid then return _G[frameName] end
    end
    for i = 1, 4 do
        if UnitExists("party" .. i) and UnitGUID("party" .. i) == guid then return _G["PartyMemberFrame" .. i] end
    end
    return nil
end

local function FindPlateFrame(guid)
    if not guid then return nil end

    -- DragonUI's reverse map first. It is exact, and the ownership test is free, so the common case costs
    -- nothing. Requiring a nameplate token to resolve is what wrongly sent numbers to the unit frames: this
    -- client does not expose a resolvable token for every plate, so the common case must not depend on it.
    local NP = addon.Nameplates
    local state = NP and NP.state
    if state and state.GUIDToPlate then
        local pd = state.GUIDToPlate[guid]
        local frame = pd and pd.plate
        if frame and frame.IsShown and frame:IsShown() and (not pd.guid or pd.guid == guid) then
            return frame
        end
    end

    -- Not bound in DragonUI's map yet: sweep the raw tokens, with a short cache so a burst of numbers on the
    -- same unbound plate does not search 40 tokens each time.
    local now = GetTime()
    local cached = tokenCache[guid]
    if cached and (now - cached.at) < TOKEN_CACHE_TTL then
        local frame, token = cached.frame, cached.token
        if frame and frame.IsShown and frame:IsShown()
            and (not token or (UnitExists(token) and UnitGUID(token) == guid)) then
            return frame
        end
        tokenCache[guid] = nil
    end

    local foundToken, found = FindNameplateToken(guid)
    -- Only a hit is cached. A miss must never stick: the plate can come back a moment later, and holding
    -- "not found" for a second is what kept numbers off a target that had returned to the screen.
    if found then
        tokenCache[guid] = { frame = found, token = foundToken, at = now }
    else
        tokenCache[guid] = nil
    end
    return found
end

-- Last known on-screen position, per GUID.
--
-- On 3.3.5a the client hides a nameplate as soon as its unit leaves the camera -- there is no CVar or API
-- to force it back (this client has no nameplate distance CVar at all, and looking away culls the plate
-- regardless of distance). So a DoT ticking on a target the player has turned away from has no frame left
-- to hang a number on. Rather than dropping the number or, worse, drawing it at screen centre (which in
-- third person is where the player's own model sits, and is what put damage on the player), remember where
-- the plate last was and keep using that spot for a short while.
--
-- Only GUIDs a number has actually spawned for are sampled, so the cost stays with the handful of units
-- currently taking damage, not every plate on screen.
local lastPos = {}                 -- guid -> { x, y, at }, in UIParent space
local tracked = {}                 -- guid -> true, the sample set
local LAST_POS_TTL = 3             -- how long a stale position stays usable, in seconds
local SAMPLE_INTERVAL = 0.15

-- GetCenter hands back screen coordinates measured from the screen's bottom-left, in the frame's own scale.
-- A SetPoint offset is measured from the relative point of the frame it names, so a raw screen position used
-- as an offset is off by UIParent's own centre -- a whole screen-width on a 1280-wide UI. Passing one through
-- unchanged is what made a number leave the screen the instant its plate went away: it was drawn at the
-- plate's coordinates *plus* the screen centre. Subtract the centre here, once, for every caller.
local function ToUIParent(x, y, frame)
    local ratio = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local cx, cy = UIParent:GetCenter()
    return x * ratio - (cx or 0), y * ratio - (cy or 0)
end

local function Sample(guid)
    local frame = FindPlateFrame(guid)
    if not (frame and frame.IsShown and frame:IsShown()) then return nil end
    local x, y = frame:GetCenter()
    if not (x and y) then return nil end
    x, y = ToUIParent(x, y, frame)
    lastPos[guid] = { x = x, y = y, at = GetTime() }
    return x, y
end

local sampler = CreateFrame("Frame")
sampler:Hide()
local samplerElapsed = 0
sampler:SetScript("OnUpdate", function(_, elapsed)
    samplerElapsed = samplerElapsed + elapsed
    if samplerElapsed < SAMPLE_INTERVAL then return end
    samplerElapsed = 0
    local now = GetTime()
    for guid in pairs(tracked) do
        if not Sample(guid) then
            local p = lastPos[guid]
            -- Stop tracking once the position is too old to trust: the plate is gone for good, or the unit
            -- died or left. Without this the table grows for the whole session.
            if not p or (now - p.at) > LAST_POS_TTL then
                tracked[guid] = nil
                lastPos[guid] = nil
            end
        end
    end
    if next(tracked) == nil then sampler:Hide() end
end)

-- Keeps a GUID's position warm while it is showing, and parks the sampler while nothing is tracked.
local function Track(guid)
    if not guid then return end
    tracked[guid] = true
    if not sampler:IsShown() then
        samplerElapsed = 0
        sampler:Show()
    end
end

local function CachedPos(guid)
    local p = guid and lastPos[guid]
    if not p then return nil end
    if (GetTime() - p.at) > LAST_POS_TTL then return nil end
    return p.x, p.y
end

-- Screen pixels for the anchor plate's height. A plate whose Lua GetHeight is overridden mid-animation (see
-- NP.layout.ApplyLiftClamp, which keeps the exact C++ method for that reason) would report a collapsed size,
-- so the height DragonUI cached before sizing (_clickboxBaseH, or the module-wide native height) is preferred,
-- then GetHeight, then the configured fallback.
local function PlateHeightPx(guid, anchor)
    if not anchor then return Setting("plateHeight") end
    local NP = addon.Nameplates
    local h = NP and NP.module and NP.module._clickboxNativeH
    local pd = guid and NP and NP.state and NP.state.GUIDToPlate and NP.state.GUIDToPlate[guid]
    if not h and pd then h = pd._clickboxBaseH end
    if not h and anchor.GetHeight then h = anchor:GetHeight() end
    if type(h) ~= "number" or h <= 0 then h = Setting("plateHeight") end
    local ratio = anchor.GetEffectiveScale and anchor:GetEffectiveScale() or 1
    return h * ratio
end

-- =============================================================================
-- TEXT POOL
-- =============================================================================

local COLORS = {
    physical = { 1, 1, 1 },        -- auto attacks: white
    spell    = { 1, 0.85, 0.2 },   -- spells and anything a companion lands: yellow
}

local RED = { 1, 0.25, 0.25 }      -- damage the player takes

local pool = {}
-- Numbers still on screen, kept so a new one can be placed clear of them. Without this a burst of crits lands
-- on one spot: crits carry no spread of their own, so they would draw exactly on top of each other.
local live = {}

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
    -- A crit is pinned to its spawn point: it pulses in size and nothing else. Checking here rather than only
    -- at spawn means a stale pooled frame cannot carry a drift in from a previous number. y is _sy, not 0:
    -- the spawn point is anchor + offset, not the anchor itself.
    local x, y = 0, self._sy or 0
    if not self._pulse then
        -- A slow number is still travelling when it fades; a fast one settles early and holds. The alpha below
        -- stays on t, so only the drift is rescaled, never the lifetime.
        local dt = t * (self._driftSpeed or 1)
        if dt > 1 then dt = 1 end
        local ease = 1 - (1 - dt) * (1 - dt)   -- fast out, slow in
        x = self._sx + (self._dx - self._sx) * ease
        y = self._sy + (self._dy - self._sy) * ease
    end
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

    -- Re-resolve the anchor instead of trusting the frame captured at spawn. A nameplate frame is recycled by
    -- the client, and a recycled plate is still *shown*, so an IsShown check alone cannot tell that it now
    -- belongs to a different unit -- the number would visibly ride off with the stranger the client handed the
    -- plate to. PlateStillOwns is O(1) and uses DragonUI's own GUID binding, so this costs no lookups per frame.
    --
    -- The number then dies with the plate, and that is deliberate. A dead unit has no GUID, token or plate left,
    -- and 3.3.5a Lua has no world-to-screen projection, so a corpse's screen position cannot be recomputed. All
    -- that is left is the fixed screen point it had at death, and a screen point is not a world point: run and
    -- the whole HUD slides over the world while the corpse stays behind, so a held number visibly travels with
    -- the player. Vanishing with the plate is the honest option -- never claims to mark a spot it cannot hold.
    local anchor = self._anchor
    if anchor and (not (anchor.IsShown and anchor:IsShown()) or not PlateStillOwns(anchor, self._guid)) then
        self._anchor = nil
    end
    anchor = self._anchor
    -- Drift applies either way. With an anchor gone the number keeps its rise-and-fade rather than being
    -- pinned to a screen point, which would falsely suggest it marks the corpse.
    -- A SetPoint offset is measured in the frame's own scale, so a growing crit would magnify its own offset and
    -- appear to slide down as it grows. Dividing by the current scale cancels that: every number, crit or not,
    -- then sits the same distance from the anchor, and the crit holds one point for its whole growth.
    local s = self:GetScale()
    if not s or s <= 0 then s = 1 end
    local ox, oy = x / s, y / s
    if anchor then
        self:SetPoint("CENTER", anchor, "CENTER", ox, oy)
        -- Remember the spot while it is valid, so the frozen fallback lands where it last drew.
        local ax, ay = anchor:GetCenter()
        if ax and ay then self._originX, self._originY = ToUIParent(ax, ay, anchor) end
    else
        self:SetPoint("CENTER", UIParent, "CENTER", self._originX + ox, self._originY + oy)
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
    -- (the unit left the camera, or nameplates are toggled off) still returns stale centre coords, so it
    -- must be dropped here rather than at the draw.
    local anchor = FindPlateFrame(guid)
    if not (anchor and anchor.IsShown and anchor:IsShown()) then anchor = nil end

    local useFallback = false
    local staticX, staticY
    if anchor then
        -- On screen: keep its position warm for as long as numbers are landing on this unit.
        Track(guid)
    else
        -- Off screen. Unit frames are the only other thing that tracks a unit; the client gives no way to
        -- force a culled plate back, so the best remaining answer is where that plate last was.
        local frame = FixedUnitFrame(guid)
        if frame and frame.IsShown and frame:IsShown() then
            anchor, useFallback = frame, true
        else
            -- Last known plate position. There is deliberately no screen-centre fallback: in third person
            -- that spot is where the player's own model is drawn, which is exactly how a DoT on a mob the
            -- player had looked away from ended up appearing on the player.
            staticX, staticY = CachedPos(guid)
            if staticX then useFallback = true end
        end
    end

    -- Nothing on screen represents this unit and it has never been seen, so the hit has nowhere honest to
    -- be drawn. Dropping it beats a number that lies about which unit took the damage.
    if not anchor and not staticX then return end

    local f = Acquire()
    -- Read per spawn so an options change applies to the next number, with no reload.
    local vSpread, size = Setting("verticalSpread"), Setting("textSize")
    -- The plate floats in world space above the unit's head, so the gap down to the model has to be a
    -- fraction of the plate: a zoom-scaled plate (NP.layout.SetRetailPlateScale) is pushed further up in
    -- screen terms, and a fixed pixel gap would leave the number sitting above the target's head instead of
    -- on its body. Scaling by height keeps the number over the model at any plate size or zoom.
    local plateH = PlateHeightPx(guid, anchor)
    local spreadX = Setting("offsetX")
    local spreadY = plateH * (Setting("offsetYPercent") / 100)
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
    f._guid = guid
    -- Seed the freeze point from the anchor's own position when there is one. Offsets are measured from that
    -- point, so if the anchor dies mid-life the number holds the exact spot it was last drawn at instead of
    -- snapping to UIParent coordinates (0,0 originally, i.e. somewhere off the bottom-left of the screen).
    f._originX, f._originY = staticX or 0, staticY or 0
    if anchor then
        -- Center-relative, not raw screen coordinates: this is the spot the number holds on to once its
        -- plate is gone, so it has to be in the space the UIParent fallback draws in.
        local ax, ay = anchor:GetCenter()
        if ax and ay then f._originX, f._originY = ToUIParent(ax, ay, anchor) end
    end
    f._elapsed, f._duration = 0, Setting("lifetime")
    -- Every number starts on one point -- the anchor plus the configured offset -- and the spread is applied at
    -- the end of the drift, so a burst fans out from that spot instead of spawning already scattered. Crits keep
    -- the offset and take no spread, so the big number stays on the unit.
    f._sx, f._sy = 0, spreadY
    f._dx = crit and 0 or math.random(-spreadX, spreadX)
    f._dy = crit and spreadY or (spreadY + math.random(-vSpread, vSpread))
    f._driftSpeed = crit and 1 or (DRIFT_SPEED_MIN + math.random() * (DRIFT_SPEED_MAX - DRIFT_SPEED_MIN))
    f.text:SetText(type(payload) == "string" and payload or tostring(payload))
    local c = color or COLORS[kind]
    f.text:SetTextColor(c[1], c[2], c[3])
    -- Fit the frame to the text. SetScale scales the frame about its own centre, and the fontstring is
    -- centred in it, so a frame bigger than its text scales the glyphs about a point that is not their
    -- centre -- which is what makes the number look like it grows from its top edge instead of its middle.
    local tw, th = f.text:GetStringWidth(), f.text:GetStringHeight()
    f:SetSize(tw, th)

    -- Keep the new number clear of the ones already on screen, by pushing it up past the slot they occupy. The
    -- drift already fans a burst out over its life, so only the opening moments can collide -- and those are
    -- exactly the ones a shared spawn point makes unreadable. Expired entries are dropped in the same pass.
    local ox, oy = f._originX + f._dx, f._originY + f._dy
    local now = GetTime()
    local step = th + 2
    local moved = true
    while moved do
        moved = false
        for i = #live, 1, -1 do
            local o = live[i]
            if (now - o.at) > o.duration then
                table.remove(live, i)
            elseif math.abs(ox - o.x) < tw and math.abs(oy - o.y) < step then
                oy = oy + step
                moved = true
            end
        end
    end
    live[#live + 1] = { x = ox, y = oy, at = now, duration = f._duration }
    f._dy = oy - f._originY
    -- Yellow reads larger, and a crit multiplies on top of that rather than replacing it, so a crit spell
    -- is still visibly bigger than a crit auto attack.
    local scale = crit and CRIT_SCALE or 1
    if c == COLORS.spell then scale = scale * SPELL_BOOST
    elseif c == COLORS.physical then scale = scale * PHYSICAL_SCALE end
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
        f:SetPoint("CENTER", UIParent, "CENTER", f._originX + f._sx, f._originY + f._sy)
    end
    f:SetScript("OnUpdate", OnUpdate)
    f:Show()
    lastSpawn = { amount = payload, kind = kind, crit = crit, guid = guid,
        anchored = anchor ~= nil, fallback = useFallback, cached = (not anchor) and staticX ~= nil,
        anchorKind = anchor and "plate" or "cachedPos",
        anchor = anchor and anchor.GetName and anchor:GetName() }
end

-- POC diagnostic: /run DragonUI.CombatTextDebug()
-- Prints what the last number did. Tell us whether an outgoing hit is even reaching Spawn.
function addon.CombatTextDebug()
    local function dump(label, t)
        if not t then print(label, "(none)") return end
        print(string.format("%s amount=%s kind=%s crit=%s guid=%s anchored=%s fallback=%s cachedPos=%s anchorKind=%s anchor=%s",
            label, tostring(t.amount), tostring(t.kind), tostring(t.crit),
            tostring(t.guid), tostring(t.anchored), tostring(t.fallback), tostring(t.cached),
            tostring(t.anchorKind), tostring(t.anchor)))
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

-- Diagnostic: /run DragonUI.CombatTextPlates()
-- What Blizzard's own combat text has to work with: the fct CVars this module forces on, and whether the
-- nameplate module is registering plates at all.
function addon.CombatTextPlates()
    local NP = addon.Nameplates
    local plates = NP and NP.module and NP.module.plates
    if not plates then
        print("[FCT] nameplates module not available")
        return
    end
    local function scan(unit)
        if not UnitExists(unit) then print(string.format("[FCT] %s: does not exist", unit)) return end
        local guid = UnitGUID(unit)
        local pd = NP.state.GUIDToPlate and NP.state.GUIDToPlate[guid]
        print(string.format("[FCT] %s: guid=%s plateInGUIDMap=%s plateName=%s", unit, tostring(guid),
            tostring(pd ~= nil), tostring(pd and pd.plateName)))
    end
    scan("player")
    scan("pet")
    scan("party1")
    scan("target")
    local n = 0
    for key, pd in pairs(plates) do
        n = n + 1
        local plate = pd and pd.plate
        print(string.format("[FCT] plate %d: key=%s name=%s shown=%s guid=%s reaction=%s", n,
            tostring(key ~= nil), tostring(pd and pd.plateName),
            tostring(plate and plate.IsShown and plate:IsShown()),
            tostring(pd and pd.guid),
            tostring(NP.native_style and NP.native_style.GetPlateReaction and NP.native_style.GetPlateReaction(pd))))
    end
    print("[FCT] registered plates total=", tostring(n))
    for _, name in ipairs(NATIVE_HEAL_CVARS) do
        print(string.format("[FCT] native heal cvar %s=%s (1 means Blizzard draws the heal numbers)",
            name, tostring(ReadCVar(name))))
    end
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
    -- The player's own path, anchored to PlayerFrame.
    Spawn(22222, "heal", false, UnitGUID("player"))
    print("[FCT] two numbers drawn: 11111 on the target, 22222 on the player.")
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
    -- The frame is registered at load and stays registered: the registry has no unsubscribe, so the module
    -- has to gate itself. Without this, disabling the module restored Blizzard's fct CVars *and* kept drawing
    -- our own numbers on top -- two combat texts at once, which is what "disable it" must never do.
    if not CombatText.applied then return end
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

    -- Healing is Blizzard's job now (see NATIVE_HEAL_CVARS): its numbers ride the unit in the world, which is
    -- the one thing this module cannot do for a friendly target. Running our own heal path as well would draw
    -- the same heal twice.
    if isHeal then
        for i = 1, n do scratch[i] = nil end
        return
    end

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

-- The snapshot is written to the saved profile, not just kept in memory. The module toggle asks for a UI
-- reload, and a reload wipes every local in this file: the CVars we zeroed would then be restored from
-- nothing, so turning the module off would leave Blizzard's floating combat text permanently disabled.
local function SaveCVarSnapshot(snapshot)
    local db = addon.db
    if not (db and db.global) then return end
    db.global.combatTextCVars = snapshot
end

local function LoadCVarSnapshot()
    local db = addon.db
    return db and db.global and db.global.combatTextCVars
end

local function HideBlizzardFCT()
    if not savedCVars then
        -- A surviving snapshot means a previous session zeroed these and never restored them: keep the
        -- player's original values rather than re-reading our own zeroes as if they were their settings.
        savedCVars = LoadCVarSnapshot()
    end
    if not savedCVars then
        savedCVars = {}
        for _, name in ipairs(FCT_CVARS) do
            local value = ReadCVar(name)
            -- An absent CVar is recorded as false, not nil: nil would read as "no snapshot" next time and
            -- send us back here, overwriting the good values with our own zeroes.
            savedCVars[name] = value or false
        end
        SaveCVarSnapshot(savedCVars)
    end
    for _, name in ipairs(FCT_CVARS) do
        SetCVarIfKnown(name, 0)
    end
    for _, name in ipairs(NATIVE_HEAL_CVARS) do
        SetCVarIfKnown(name, 1)
    end
end

local function RestoreBlizzardFCT()
    local snapshot = savedCVars or LoadCVarSnapshot()
    if not snapshot then return end
    savedCVars = nil
    SaveCVarSnapshot(nil)
    for name, value in pairs(snapshot) do
        -- false means the client has no such CVar; nothing to put back.
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
    -- A reload with the module enabled re-hides on entering world, which is the only moment a fct CVar could
    -- have been reset behind our back. Guarded on `applied` so a disabled module never touches Blizzard's.
    elseif event == "PLAYER_ENTERING_WORLD" then
        if CombatText.applied then
            HideBlizzardFCT()
        else
            -- Disabled, but a previous session may have zeroed the fct CVars and never restored them. The
            -- snapshot in the profile is the only record of the player's originals, so put it back. No
            -- snapshot means the module never touched them and this does nothing.
            RestoreBlizzardFCT()
        end
    end
end)

eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

function addon.ApplyCombatTextSystem()
    CombatText.applied = true
    HideBlizzardFCT()
end

-- A disabled module must still leave Blizzard's floating combat text alone. The snapshot is in the saved
-- profile precisely because the toggle asks for a reload, and a reload empties this file's locals: without
-- this, a session that had zeroed the fct CVars and was then switched off would never put them back.
function addon.RestoreCombatTextSystem()
    CombatText.applied = false
    RestoreBlizzardFCT()
    -- Stop the sampler with the module: it belongs to the feature, and no position can be trusted across
    -- the gap while the module is off.
    sampler:Hide()
    for guid in pairs(tracked) do tracked[guid] = nil end
    for guid in pairs(lastPos) do lastPos[guid] = nil end
    for i = #live, 1, -1 do live[i] = nil end
    for _, f in ipairs(pool) do
        f:Hide()
    end
end
