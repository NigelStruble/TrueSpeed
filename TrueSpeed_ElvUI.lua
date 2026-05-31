----------------------------------------------------------------------
-- TrueSpeed - ElvUI DataText integration
--
-- Registers a "TrueSpeed" datatext in ElvUI's "Information" category
-- so the addon's speed reading can be displayed in any ElvUI panel
-- (chat tabs, minimap panel, bottom bars, etc.).
--
-- This file is harmless if ElvUI isn't installed -- the early returns
-- below make it a no-op.
----------------------------------------------------------------------

local _, ns = ...

-- ElvUI publishes itself as a global table; [1] is the main E module.
local ElvUI = _G.ElvUI
if not ElvUI then return end

local E = ElvUI[1]
if not E or type(E.GetModule) ~= "function" then return end

local DT = E:GetModule("DataTexts", true)
if not DT or type(DT.RegisterDatatext) ~= "function" then return end

local BASE_RUN_SPEED = ns.BASE_RUN_SPEED or 7.0
local MS_TO_KNOTS    = 0.9144 / 0.5144   -- yd/s -> knots (1 yd = 0.9144 m)

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function ColourCode(pct)
    local r, g, b = 1, 1, 1
    if ns.SpeedColour then
        r, g, b = ns.SpeedColour(pct)
    end
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

----------------------------------------------------------------------
-- OnUpdate: refresh the datatext label
-- ElvUI calls this on the panel's own tick. We just read the latest
-- value from the shared namespace -- the heavy lifting (sampling,
-- smoothing) happens in TrueSpeed.lua's always-shown driver frame.
----------------------------------------------------------------------
local function OnUpdate(self)
    local yps = (ns.GetSpeed and ns.GetSpeed()) or 0
    local pct = (yps / BASE_RUN_SPEED) * 100
    self.text:SetFormattedText("%sSpeed:|r %d%%",
        ColourCode(pct),
        math.floor(pct + 0.5))
end

----------------------------------------------------------------------
-- OnEnter: tooltip with the full breakdown
----------------------------------------------------------------------
local function OnEnter(self)
    local tooltip = DT.tooltip
    if not tooltip then return end

    local yps   = (ns.GetSpeed and ns.GetSpeed()) or 0
    local pct   = (yps / BASE_RUN_SPEED) * 100
    local knots = yps * MS_TO_KNOTS

    local apiYps = (GetUnitSpeed and GetUnitSpeed("player")) or 0
    local apiPct = (apiYps / BASE_RUN_SPEED) * 100

    tooltip:ClearLines()
    tooltip:AddLine("|cff00ccffTrueSpeed|r")
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Speed",     string.format("%.1f yd/s", yps),           1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine("Percent",   string.format("%d%%", math.floor(pct + 0.5)), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine("Knots",     string.format("%.1f kn", knots),           1, 1, 1, 1, 1, 1)
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("API speed", string.format("%d%%", math.floor(apiPct + 0.5)),
        0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    tooltip:Show()
end

----------------------------------------------------------------------
-- OnClick: print the slash-command help so users can find the
-- floating-frame controls without leaving the datatext.
----------------------------------------------------------------------
local function OnClick(self, button)
    if button == "LeftButton" and SlashCmdList and SlashCmdList["TRUESPEED"] then
        SlashCmdList["TRUESPEED"]("")
    end
end

----------------------------------------------------------------------
-- Register. Signature:
--   (name, category, events, eventFunc, updateFunc,
--    clickFunc, onEnterFunc, onLeaveFunc, localizedName, colorUpdate)
-- No events needed -- everything we display updates continuously.
----------------------------------------------------------------------
DT:RegisterDatatext(
    "TrueSpeed",       -- name
    "Information",     -- category
    nil,               -- events
    nil,               -- eventFunc
    OnUpdate,          -- updateFunc
    OnClick,           -- clickFunc
    OnEnter,           -- onEnterFunc
    nil,               -- onLeaveFunc (ElvUI hides the tooltip for us)
    "TrueSpeed"        -- localizedName
)
