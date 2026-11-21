if EUI_CLIENT_BLOCKED then return end -- same pre-12.1 client failsafe the EllesmereUI files use
-------------------------------------------------------------------------------
--  EUI_GCDSpark.lua
--
--  Standalone player/target overlays for EllesmereUI:
--    - a global cooldown spark on the power bar,
--    - a cast spark on the cast bar (follows casts, channels and empowers),
--    - the missing health amount as text on the player and target health bars.
--  It never edits or hooks an EllesmereUI file: it asks EUI for the player
--  unit frame and its bars, and draws its own children on them.
--
--  The power spark is a StatusBar parented to the power bar, with the
--  engine's own GCD duration object fed to SetTimerDuration, so it moves with
--  no Lua per frame. Combat makes the cooldown values secret; then a short
--  ticker watches the plain isActive flag to end the sweep (the same pattern
--  EUI's GCD bar uses).
--
--  The cast spark hangs off the cast bar's fill texture, so the engine's own
--  fill animation carries it; EUI's cast driver already shows and hides
--  element.Spark at cast start/stop/fail.
--
--  Missing health uses UnitHealthMissing, which is secret-safe, and passes the
--  amount through AbbreviateValue into SetFormattedText: no Lua arithmetic or
--  string concatenation on unit data.
--
--  Settings live in EUI_GCDSparkDB and are exposed as plugin modules. The
--  modules join LootRollFrames' single "Plugins" sidebar section through the
--  EUI_PLUGIN_SECTIONS table, so they do not add a second Plugins header.
-------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

local DEFAULTS = {
    enabled = true, width = 8, castbarEnabled = true, castbarWidth = 8,
    missingPlayer = true, missingTarget = true, missingPos = "center",
    missingColor = { r = 1, g = 0.35, b = 0.35, a = 1 },
}
local MAX_GCD = 1.6
local GCD_SPELL = EllesmereUI.GCD_SPELL or 61304
local SPARK_TEX = "Interface\\AddOns\\EllesmereUI\\media\\cast_spark.tga"
local ADDON_VERSION = "1.3.1"

-- Saved settings first: a client API below must never stop the table from
-- being seeded or saved.
local DB = _G.EUI_GCDSparkDB
if type(DB) ~= "table" then
    DB = {}
    _G.EUI_GCDSparkDB = DB
end
local function SeedDB(t)
    if t.enabled == nil then t.enabled = DEFAULTS.enabled end
    if t.width == nil then t.width = DEFAULTS.width end
    if t.castbarEnabled == nil then t.castbarEnabled = DEFAULTS.castbarEnabled end
    if t.castbarWidth == nil then t.castbarWidth = DEFAULTS.castbarWidth end
    if t.missingPlayer == nil then t.missingPlayer = DEFAULTS.missingPlayer end
    if t.missingTarget == nil then t.missingTarget = DEFAULTS.missingTarget end
    if t.missingPos == nil then t.missingPos = DEFAULTS.missingPos end
    if type(t.missingColor) ~= "table" then
        local c = DEFAULTS.missingColor
        t.missingColor = { r = c.r, g = c.g, b = c.b, a = c.a }
    end
end
SeedDB(DB)

local IMMEDIATE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
local ELAPSED = Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime
local GetCD = C_Spell and C_Spell.GetSpellCooldown
local GetCDDur = C_Spell and C_Spell.GetSpellCooldownDuration
local UnitHealthMissing = _G.UnitHealthMissing
local UnitHealth, UnitHealthMax = _G.UnitHealth, _G.UnitHealthMax
local UnitExists = _G.UnitExists
local UnitIsConnected = _G.UnitIsConnected
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local UnitHasVehicleUI = _G.UnitHasVehicleUI
local AbbreviateNumbers = _G.AbbreviateNumbers

local frame = CreateFrame("Frame")
local overlay
local hookedBar
local EnsureOverlay
local OwnSection
local UpdateMissing
local castSpark            -- the castbar spark texture (castbar.Spark)
local castBar              -- the castbar holding it
local gcdEnd              -- end time of the running GCD sweep; nil while idle
local gcdObj              -- duration object for the running GCD
local gcdTicker           -- end watcher while the GCD values are secret
local gcdStamp            -- same-frame collapse for SPELL_UPDATE_COOLDOWN
local lastGcdStart        -- start of the last captured GCD
local gcdDur = C_DurationUtil and C_DurationUtil.CreateDuration and C_DurationUtil.CreateDuration()
local gcdTimer = frame:CreateAnimationGroup()
local gcdSpan = gcdTimer:CreateAnimation("Animation")

-- The player frame: EUI's own global first (so a stale FindPlayerUnitFrame
-- cache can never hand back a hidden Blizzard frame), then EUI's resolver.
local function GetPlayerFrame()
    local pf = _G.EllesmereUIUnitFrames_Player
    if not pf and EllesmereUI.FindPlayerUnitFrame then
        pf = EllesmereUI.FindPlayerUnitFrame()
    end
    return pf
end

-- The player power bar. Power is EUI's own bar; the rest are fallbacks for
-- when EUI unit frames are off.
local function GetBar()
    local pf = GetPlayerFrame()
    local bar = pf and (pf.Power or pf.PowerBar or pf.ManaBar)
    if not bar then
        local blizz = _G.PlayerFrame
        bar = (blizz and (blizz.PowerBar or blizz.ManaBar or blizz.powerBar))
            or _G.PlayerFrameManaBar
    end
    if bar and bar.GetStatusBarTexture and bar.SetTimerDuration then
        return bar
    end
    return nil
end

-- The player castbar StatusBar. EUI creates it as frame.Castbar; its parent
-- is the holder frame.
local function GetCastbar()
    local pf = GetPlayerFrame()
    local cb = pf and pf.Castbar
    if cb and cb.GetStatusBarTexture then
        return cb
    end
    return nil
end

-------------------------------------------------------------------------------
--  Missing health text
--
--  A FontString over the player/target health bar showing the missing amount
--  (-12.3K). UnitHealthMissing handles secret values; the amount goes through
--  AbbreviateValue (also secret-safe) and into SetFormattedText, never Lua
--  arithmetic or concatenation.
-------------------------------------------------------------------------------
local missingRecs = {}   -- unit -> { bar, box, fs }

local function GetUnitFrame(unit)
    if unit == "player" then
        return GetPlayerFrame()
    elseif unit == "target" then
        return _G.EllesmereUIUnitFrames_Target
    end
    return nil
end

local function MissingValue(unit)
    if UnitHealthMissing then return UnitHealthMissing(unit, true) end
    if not (UnitHealth and UnitHealthMax) then return nil end
    local cur, max = UnitHealth(unit), UnitHealthMax(unit)
    if issecretvalue and (issecretvalue(cur) or issecretvalue(max)) then return nil end
    if type(cur) == "number" and type(max) == "number" then return max - cur end
    return nil
end

local function IsZeroValue(v)
    if EllesmereUI.IsZeroValue then return EllesmereUI.IsZeroValue(v) end
    if issecretvalue and issecretvalue(v) then return false end
    return v == 0
end

local function FormatMissing(v)
    if EllesmereUI.AbbreviateValue then return EllesmereUI.AbbreviateValue(v, "health") end
    if AbbreviateNumbers then return AbbreviateNumbers(v) end
    return nil
end

local function MissingOn(unit)
    if unit == "player" then return DB.missingPlayer == true end
    if unit == "target" then return DB.missingTarget == true end
    return false
end

-- A vehicle swaps the player frame to the vehicle unit; read that health.
local function PlayerHealthUnit()
    if UnitHasVehicleUI and UnitExists and UnitExists("vehicle") and UnitHasVehicleUI("player") then
        return "vehicle"
    end
    return "player"
end

-- Matches the unit frame's own text (font path, size and outline flag).
local function MissingFont(frame)
    local src = frame.CenterText or frame.RightText or frame.LeftText
    if src then
        local path, size, flags = src:GetFont()
        if path then return path, size, flags end
    end
    local path = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath("unitFrames")
    local flags = EllesmereUI.GetFontOutlineFlag and EllesmereUI.GetFontOutlineFlag("unitFrames")
    return path or "Fonts\\FRIZQT__.TTF", 12, flags or ""
end

local function LayoutMissing(rec)
    local fs, bar = rec.fs, rec.bar
    fs:ClearAllPoints()
    local pos = DB.missingPos or "center"
    if pos == "left" then
        fs:SetJustifyH("LEFT")
        fs:SetPoint("LEFT", bar, "LEFT", 5, 0)
    elseif pos == "right" then
        fs:SetJustifyH("RIGHT")
        fs:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    else
        fs:SetJustifyH("CENTER")
        fs:SetPoint("CENTER", bar, "CENTER", 0, 0)
    end
    local c = DB.missingColor
    fs:SetTextColor(c.r, c.g, c.b, c.a or 1)
end

local function EnsureMissing(unit)
    local frame = GetUnitFrame(unit)
    local bar = frame and frame.Health
    if not bar or not bar.CreateFontString then
        local rec = missingRecs[unit]
        if rec then rec.box:Hide() end
        return nil
    end
    local rec = missingRecs[unit]
    if rec and rec.bar == bar and rec.box:GetParent() == bar then
        LayoutMissing(rec)
        return rec
    end
    if not bar.__euiMissingHooked then
        bar.__euiMissingHooked = true
        bar:HookScript("OnShow", function() UpdateMissing(unit) end)
    end
    if InCombatLockdown() then return nil end
    if rec then rec.box:Hide() end
    local box = CreateFrame("Frame", nil, bar)
    box:SetAllPoints(bar)
    box:SetFrameLevel(bar:GetFrameLevel() + 14)
    local fs = box:CreateFontString(nil, "OVERLAY")
    local path, size, flags = MissingFont(frame)
    fs:SetFont(path, size, flags)
    fs:SetWordWrap(false)
    box.fs = fs
    rec = { bar = bar, box = box, fs = fs }
    missingRecs[unit] = rec
    LayoutMissing(rec)
    return rec
end

UpdateMissing = function(unit)
    local rec = missingRecs[unit]
    if not MissingOn(unit) then
        if rec then rec.box:Hide() end
        return
    end
    local realUnit = (unit == "player") and PlayerHealthUnit() or unit
    if not UnitExists or not UnitExists(realUnit) then
        if rec then rec.box:Hide() end
        return
    end
    if (UnitIsConnected and not UnitIsConnected(realUnit))
       or (UnitIsDeadOrGhost and UnitIsDeadOrGhost(realUnit)) then
        if rec then rec.box:Hide() end
        return
    end
    local v = MissingValue(realUnit)
    if v == nil or IsZeroValue(v) then
        if rec then rec.box:Hide() end
        return
    end
    rec = EnsureMissing(unit)
    if not rec then return end
    local text = FormatMissing(v)
    if text == nil then
        rec.box:Hide()
        return
    end
    rec.fs:SetFormattedText("-%s", text)
    rec.box:Show()
end

local function SetMissingListening(on)
    if on then
        frame:RegisterUnitEvent("UNIT_HEALTH", "player", "target")
        frame:RegisterUnitEvent("UNIT_MAXHEALTH", "player", "target")
        frame:RegisterUnitEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED", "player", "target")
        frame:RegisterUnitEvent("UNIT_CONNECTION", "player", "target")
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    else
        frame:UnregisterEvent("UNIT_HEALTH")
        frame:UnregisterEvent("UNIT_MAXHEALTH")
        frame:UnregisterEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED")
        frame:UnregisterEvent("UNIT_CONNECTION")
        frame:UnregisterEvent("PLAYER_TARGET_CHANGED")
    end
end

local function ApplyMissing()
    local on = DB.missingPlayer == true or DB.missingTarget == true
    SetMissingListening(on)
    if not on then
        for _, rec in pairs(missingRecs) do rec.box:Hide() end
        return
    end
    UpdateMissing("player")
    UpdateMissing("target")
end

local function HideSpark()
    if overlay then overlay:Hide() end
end

-- Lays the spark on the overlay fill edge in the bar's orientation. The
-- anchors stand until the bar's orientation or reverse fill changes; the
-- thickness follows the width setting on every call.
local function Layout(bar)
    if not overlay or not bar or overlay:GetParent() ~= bar then return end
    local vert = bar:GetOrientation() == "VERTICAL"
    local rev = bar:GetReverseFill() and true or false
    local s = overlay.spark
    if overlay.vert ~= vert or overlay.rev ~= rev then
        overlay.vert, overlay.rev = vert, rev
        overlay:SetOrientation(vert and "VERTICAL" or "HORIZONTAL")
        overlay:SetReverseFill(rev)
        local ft = overlay:GetStatusBarTexture()
        s:ClearAllPoints()
        if vert then
            s:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
            s:SetPoint("LEFT", ft, rev and "BOTTOMLEFT" or "TOPLEFT")
            s:SetPoint("RIGHT", ft, rev and "BOTTOMRIGHT" or "TOPRIGHT")
        else
            s:SetTexCoord(0, 1, 0, 1)
            s:SetPoint("TOP", ft, rev and "TOPLEFT" or "TOPRIGHT")
            s:SetPoint("BOTTOM", ft, rev and "BOTTOMLEFT" or "BOTTOMRIGHT")
        end
    end
    local w = DB.width or DEFAULTS.width
    if vert then
        s:SetHeight(w)
    else
        s:SetWidth(w)
    end
end

local function Arm()
    if DB.enabled ~= true or not gcdEnd then
        HideSpark()
        return
    end
    local bar = GetBar()
    if not bar or not bar:IsVisible() then
        HideSpark()
        return
    end
    local o = EnsureOverlay(bar)
    if not o then return end
    local obj = gcdObj or gcdDur
    if not obj then
        HideSpark()
        return
    end
    o:Show()
    o:SetTimerDuration(obj, IMMEDIATE, ELAPSED)
end

local function HookBar(bar)
    if hookedBar == bar then return end
    hookedBar = bar
    bar:HookScript("OnShow", function()
        if overlay and overlay:GetParent() == bar then Arm() end
    end)
    bar:HookScript("OnHide", function()
        if overlay then overlay:Hide() end
    end)
end

-- Creates the overlay once, reparents it when EUI rebuilds the frame, and
-- never creates or reparents one on a protected bar in combat.
EnsureOverlay = function(bar)
    if not bar then
        HideSpark()
        return nil
    end
    if overlay and overlay:GetParent() == bar then
        Layout(bar)
        return overlay
    end
    if InCombatLockdown() then return nil end
    if not overlay then
        overlay = CreateFrame("StatusBar", "EUI_GCDSparkOverlay", bar)
        overlay:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        overlay:GetStatusBarTexture():SetAlpha(0)
        overlay:SetMinMaxValues(0, 1)
        overlay:SetValue(0)
        overlay:Hide()
        local s = overlay:CreateTexture(nil, "OVERLAY", nil, 1)
        s:SetTexture(SPARK_TEX)
        s:SetBlendMode("ADD")
        overlay.spark = s
    else
        overlay:SetParent(bar)
    end
    overlay:SetAllPoints(bar)
    overlay:SetFrameLevel(bar:GetFrameLevel() + 2)
    Layout(bar)
    HookBar(bar)
    return overlay
end

-- Castbar spark: a texture sitting on the fill's leading edge. EUI's castbar
-- driver already shows and hides element.Spark at cast start/stop/fail, and
-- the StatusBar fill moves the edge, so the spark needs no timer of its own.
local function LayoutCastSpark()
    if not (castSpark and castBar) then return end
    local vert = castBar:GetOrientation() == "VERTICAL"
    local rev = castBar:GetReverseFill() and true or false
    local fill = castBar:GetStatusBarTexture()
    local w = DB.castbarWidth or DEFAULTS.castbarWidth
    castSpark:ClearAllPoints()
    if vert then
        castSpark:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
        castSpark:SetSize(castBar:GetWidth(), w)
        castSpark:SetPoint("CENTER", fill, rev and "BOTTOM" or "TOP", 0, 0)
    else
        castSpark:SetTexCoord(0, 1, 0, 1)
        castSpark:SetSize(w, castBar:GetHeight())
        castSpark:SetPoint("CENTER", fill, rev and "LEFT" or "RIGHT", 0, 0)
    end
end

local function HideCastSpark()
    if castSpark then castSpark:Hide() end
    if castBar and castBar.Spark == castSpark then castBar.Spark = nil end
end

local function EnsureCastSpark()
    if DB.castbarEnabled ~= true then
        HideCastSpark()
        return nil
    end
    local cb = GetCastbar()
    if not cb then return nil end
    if castSpark and castBar == cb and castSpark:GetParent() == cb then
        cb.Spark = castSpark
        LayoutCastSpark()
        return castSpark
    end
    if InCombatLockdown() then return nil end
    if castSpark then castSpark:Hide() end
    if castBar and castBar ~= cb and castBar.Spark == castSpark then castBar.Spark = nil end
    castBar, castSpark = cb, nil
    -- An EUI-owned spark (a future version) wins: leave it alone.
    if cb.Spark then return nil end
    local s = cb:CreateTexture(nil, "OVERLAY", nil, 2)
    s:SetTexture(SPARK_TEX)
    s:SetBlendMode("ADD")
    castSpark = s
    cb.Spark = s
    LayoutCastSpark()
    return s
end

-- Ends the GCD sweep and hides the spark.
local function EndGCD()
    gcdEnd = nil
    gcdObj = nil
    gcdTimer:Stop()
    if gcdTicker then
        gcdTicker:Cancel()
        gcdTicker = nil
    end
    HideSpark()
end

gcdTimer:SetScript("OnFinished", EndGCD)

-- Plain read of the GCD's elapsed time and length; pcall'd because combat
-- makes both values secret (arithmetic on them errors).
local function ReadGCD(cd)
    local d, s = cd.duration, cd.startTime
    if d and d > 0 and d <= MAX_GCD and s and s > 0 then
        return GetTime() - s, d
    end
end

-- Starts (or refreshes) the GCD sweep. The engine's duration object draws
-- the true progress; when the values are secret the window is only a
-- ceiling and the ticker ends the sweep when the cooldown reports it over.
local function StartGCD(startT, len, secret)
    local now = GetTime()
    gcdObj = GetCDDur and GetCDDur(GCD_SPELL) or nil
    if not gcdObj and gcdDur then
        gcdDur:SetTimeFromStart(startT, len)
        gcdObj = gcdDur
    end
    gcdEnd = startT + len
    gcdTimer:Stop()
    gcdSpan:SetDuration(math.max(gcdEnd - now, 0.05))
    gcdTimer:Play()
    if secret then
        if not gcdTicker then
            gcdTicker = C_Timer.NewTicker(0.1, function()
                local cd = GetCD and GetCD(GCD_SPELL)
                if not (cd and cd.isActive) then EndGCD() end
            end)
        end
    elseif gcdTicker then
        gcdTicker:Cancel()
        gcdTicker = nil
    end
    Arm()
end

-- (Re)captures the GCD from the client's cooldown for the reference spell.
-- windowOnly marks SPELL_UPDATE_COOLDOWN chatter: with secret values it may
-- only refresh an open sweep, never open one (a cast event does that).
local function CaptureGCD(windowOnly)
    local cd = GetCD and GetCD(GCD_SPELL)
    if not cd or not cd.startTime then return end
    local ok, elapsed, len = pcall(ReadGCD, cd)
    if ok and elapsed and not (issecretvalue and (issecretvalue(elapsed) or issecretvalue(len))) then
        local startT = GetTime() - elapsed
        if (len - elapsed) > 0.05 and ((not lastGcdStart) or startT > lastGcdStart + 0.05) then
            lastGcdStart = startT
            StartGCD(startT, len, false)
        end
    elseif not ok then
        -- Secret cooldown values (instanced combat): isActive is never secret.
        if windowOnly then
            if gcdEnd and GetCDDur then
                local obj = GetCDDur(GCD_SPELL)
                if obj then
                    gcdObj = obj
                    Arm()
                end
            end
            return
        end
        if not cd.isActive then return end
        lastGcdStart = nil
        StartGCD(GetTime(), MAX_GCD, true)
    end
end

local GCD_EVENTS = {
    "SPELL_UPDATE_COOLDOWN",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_EMPOWER_START",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_STOP",
}

local function SetListening(on)
    for i = 1, #GCD_EVENTS do
        local e = GCD_EVENTS[i]
        if on then
            if e == "SPELL_UPDATE_COOLDOWN" then
                frame:RegisterEvent(e)
            else
                frame:RegisterUnitEvent(e, "player")
            end
        else
            frame:UnregisterEvent(e)
        end
    end
    if not on then EndGCD() end
end

local function Apply()
    local on = DB.enabled == true or DB.castbarEnabled == true
    SetListening(on)
    if not on then
        HideSpark()
        HideCastSpark()
        return
    end
    if InCombatLockdown() then return end
    if DB.enabled then
        local bar = GetBar()
        if bar then EnsureOverlay(bar) end
        Arm()
    else
        HideSpark()
    end
    if DB.castbarEnabled then EnsureCastSpark() else HideCastSpark() end
end

frame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGOUT" then
        -- Save the table the settings pages write, even if something replaced
        -- the global during the session, and materialize every key.
        _G.EUI_GCDSparkDB = DB
        SeedDB(DB)
        return
    end
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Apply()
        ApplyMissing()
        OwnSection()
        C_Timer.After(1, Apply)
        C_Timer.After(1, ApplyMissing)
        C_Timer.After(2, ApplyMissing)
        C_Timer.After(5, ApplyMissing)
        return
    end
    if event == "PLAYER_TARGET_CHANGED" then
        UpdateMissing("target")
        return
    end
    if event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH"
       or event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" or event == "UNIT_CONNECTION" then
        if unit == "player" or unit == "target" then UpdateMissing(unit) end
        return
    end
    if event == "SPELL_UPDATE_COOLDOWN" then
        if DB.enabled then
            local now = GetTime()
            if gcdStamp ~= now then
                gcdStamp = now
                CaptureGCD(true)
            end
        end
        return
    end
    if event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED"
       or event == "UNIT_SPELLCAST_STOP" then
        if DB.enabled and gcdEnd then
            local cd = GetCD and GetCD(GCD_SPELL)
            if not (cd and cd.isActive) then EndGCD() end
        end
        return
    end
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
       or event == "UNIT_SPELLCAST_EMPOWER_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
        if DB.enabled then CaptureGCD(false) end
        if DB.castbarEnabled then EnsureCastSpark() end
    end
end)
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")

-- Plugin page in the EllesmereUI options panel.
local function BuildPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h
    _, h = W:SectionHeader(parent, "POWER BAR", y); y = y - h
    _, h = W:Toggle(parent, "Show GCD Spark", y,
        function() return DB.enabled == true end,
        function(v)
            DB.enabled = v and true or false
            Apply()
        end,
        "Sweeps a spark across the player power bar for the global cooldown. Turn off Resource Bars > GCD Bar to replace it."); y = y - h
    _, h = W:Slider(parent, "Spark Width", y, 2, 20, 1,
        function() return DB.width or DEFAULTS.width end,
        function(v)
            DB.width = v
            Layout(GetBar())
        end,
        "Thickness of the spark along the bar."); y = y - h
    _, h = W:SectionHeader(parent, "CAST BAR", y); y = y - h
    _, h = W:Toggle(parent, "Show Castbar Spark", y,
        function() return DB.castbarEnabled == true end,
        function(v)
            DB.castbarEnabled = v and true or false
            Apply()
        end,
        "Puts a spark on the leading edge of the player cast bar. It follows the fill for casts and channels."); y = y - h
    _, h = W:Slider(parent, "Castbar Spark Width", y, 2, 20, 1,
        function() return DB.castbarWidth or DEFAULTS.castbarWidth end,
        function(v)
            DB.castbarWidth = v
            LayoutCastSpark()
        end,
        "Thickness of the spark along the cast bar."); y = y - h
    return math.abs(y)
end

local function BuildMissingPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h
    _, h = W:SectionHeader(parent, "MISSING HEALTH", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type="toggle", text="Player Frame",
          tooltip="Show the missing health amount on the player health bar.",
          getValue=function() return DB.missingPlayer == true end,
          setValue=function(v)
              DB.missingPlayer = v and true or false
              ApplyMissing()
          end },
        { type="toggle", text="Target Frame",
          tooltip="Show the missing health amount on the target health bar.",
          getValue=function() return DB.missingTarget == true end,
          setValue=function(v)
              DB.missingTarget = v and true or false
              ApplyMissing()
          end }); y = y - h
    _, h = W:DualRow(parent, y,
        { type="dropdown", text="Text Position",
          values = { left="Left", center="Center", right="Right" },
          order = { "left", "center", "right" },
          tooltip="Where the missing health text sits on the health bar.",
          getValue=function() return DB.missingPos or "center" end,
          setValue=function(v)
              DB.missingPos = v
              ApplyMissing()
          end },
        { type="colorpicker", text="Text Color", hasAlpha=true,
          tooltip="Color of the missing health text.",
          getValue=function()
              local c = DB.missingColor
              return c.r, c.g, c.b, c.a
          end,
          setValue=function(r, g, b, a)
              DB.missingColor = { r = r, g = g, b = b, a = a or 1 }
              ApplyMissing()
          end }); y = y - h
    return math.abs(y)
end

local MODULES = {
    {
        key = "EUI_Sparks",
        title = "Sparks",
        description = "Overlay sparks for the player power bar and cast bar, independent of EllesmereUI updates.",
        pages = { "Settings" },
        buildPage = BuildPage,
        onReset = function()
            DB.enabled = DEFAULTS.enabled
            DB.width = DEFAULTS.width
            DB.castbarEnabled = DEFAULTS.castbarEnabled
            DB.castbarWidth = DEFAULTS.castbarWidth
            Apply()
        end,
    },
    {
        key = "EUI_MissingHealth",
        title = "Missing Health",
        description = "Shows the missing health amount on the player and target health bars.",
        pages = { "Settings" },
        buildPage = BuildMissingPage,
        onReset = function()
            DB.missingPlayer = DEFAULTS.missingPlayer
            DB.missingTarget = DEFAULTS.missingTarget
            DB.missingPos = DEFAULTS.missingPos
            local c = DEFAULTS.missingColor
            DB.missingColor = { r = c.r, g = c.g, b = c.b, a = c.a }
            ApplyMissing()
        end,
    },
}

-- EUI gives each plugin its own sidebar section. LootRollFrames registers the
-- shared "Plugins" section; publish our modules there so both addons appear as
-- one section with three rows. Without LootRollFrames, register our own.
local REG = _G.EUI_PLUGIN_SECTIONS
if type(REG) ~= "table" then
    REG = {}
    _G.EUI_PLUGIN_SECTIONS = REG
end
local SECTION = REG.Plugins
if type(SECTION) ~= "table" then
    SECTION = { label = "Plugins", modules = {} }
    REG.Plugins = SECTION
end
for i = 1, #MODULES do
    SECTION.modules[#SECTION.modules + 1] = MODULES[i]
end

OwnSection = function()
    local owner = SECTION.owner
    if owner and EllesmereUI.GetPluginModuleKey
       and EllesmereUI.GetPluginModuleKey(owner, "EUI_Sparks") then
        return
    end
    if not EllesmereUI.RegisterPlugin then return end
    if EllesmereUI.RegisterPlugin("EUI_GCDSpark", {
        label = SECTION.label,
        modules = MODULES,
    }) then
        SECTION.owner = SECTION.owner or "EUI_GCDSpark"
    end
end

SLASH_EUIGCDSPARK1 = "/gcdspark"
SlashCmdList["EUIGCDSPARK"] = function(msg)
    msg = type(msg) == "string" and msg:lower() or ""
    if msg == "status" then
        local c = type(DB.missingColor) == "table" and DB.missingColor or DEFAULTS.missingColor
        print(("EUI Extras %s: sparks=%s castbar=%s missing player=%s target=%s pos=%s color=%.2f,%.2f,%.2f,%.2f"):format(
            ADDON_VERSION, tostring(DB.enabled), tostring(DB.castbarEnabled),
            tostring(DB.missingPlayer), tostring(DB.missingTarget), tostring(DB.missingPos),
            c.r, c.g, c.b, c.a or 1))
        return
    end
    if not EllesmereUI.OpenPlugin then return end
    if SECTION.owner and EllesmereUI.OpenPlugin(SECTION.owner, "EUI_Sparks") then return end
    EllesmereUI.OpenPlugin("EUI_GCDSpark", "EUI_Sparks")
end

Apply()
ApplyMissing()
