if EUI_CLIENT_BLOCKED then return end -- same pre-12.1 client failsafe the EllesmereUI files use
-------------------------------------------------------------------------------
--  EUI_GCDSpark.lua
--
--  Standalone overlay sparks for the EllesmereUI player frames:
--    - a global cooldown spark on the power bar,
--    - a cast spark on the cast bar (follows casts, channels and empowers).
--  It never edits or hooks an EllesmereUI file: it asks EUI for the player
--  unit frame, takes its .Power StatusBar and .Castbar StatusBar, and draws
--  its own textures on them.
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
--  Settings live in EUI_GCDSparkDB and are also exposed as a plugin section
--  in the EllesmereUI options panel.
-------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local EllesmereUI = _G.EllesmereUI
if not EllesmereUI then return end

local DEFAULTS = { enabled = true, width = 8, castbarEnabled = true, castbarWidth = 8 }
local MAX_GCD = 1.6
local GCD_SPELL = EllesmereUI.GCD_SPELL or 61304
local SPARK_TEX = "Interface\\AddOns\\EllesmereUI\\media\\cast_spark.tga"
local IMMEDIATE = Enum.StatusBarInterpolation.Immediate
local ELAPSED = Enum.StatusBarTimerDirection.ElapsedTime
local GetCD = C_Spell and C_Spell.GetSpellCooldown
local GetCDDur = C_Spell and C_Spell.GetSpellCooldownDuration

local DB = _G.EUI_GCDSparkDB
if type(DB) ~= "table" then
    DB = {}
    _G.EUI_GCDSparkDB = DB
end
if DB.enabled == nil then DB.enabled = DEFAULTS.enabled end
if DB.width == nil then DB.width = DEFAULTS.width end
if DB.castbarEnabled == nil then DB.castbarEnabled = DEFAULTS.castbarEnabled end
if DB.castbarWidth == nil then DB.castbarWidth = DEFAULTS.castbarWidth end

local frame = CreateFrame("Frame")
local overlay
local hookedBar
local EnsureOverlay
local castSpark            -- the castbar spark texture (castbar.Spark)
local castBar              -- the castbar holding it
local gcdEnd              -- end time of the running GCD sweep; nil while idle
local gcdObj              -- duration object for the running GCD
local gcdTicker           -- end watcher while the GCD values are secret
local gcdStamp            -- same-frame collapse for SPELL_UPDATE_COOLDOWN
local lastGcdStart        -- start of the last captured GCD
local gcdDur = C_DurationUtil and C_DurationUtil.CreateDuration()
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

frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        Apply()
        C_Timer.After(1, Apply)
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

if EllesmereUI.RegisterPlugin then
    EllesmereUI.RegisterPlugin("EUI_GCDSpark", {
        -- EUI gives every plugin its own sidebar section; there is no shared
        -- "Plugins" group, so the section itself is named Plugins, the same
        -- convention LootRollFrames uses.
        label = "Plugins",
        modules = {
            {
                key = "Spark",
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
        },
    })
end

SLASH_EUIGCDSPARK1 = "/gcdspark"
SlashCmdList["EUIGCDSPARK"] = function()
    if EllesmereUI.OpenPlugin then
        EllesmereUI.OpenPlugin("EUI_GCDSpark")
    end
end

Apply()
