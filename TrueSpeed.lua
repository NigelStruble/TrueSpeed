----------------------------------------------------------------------
-- TrueSpeed - True character speed measurement via map coordinates
-- Works everywhere including flight paths!
----------------------------------------------------------------------

local ADDON_NAME, ns = ...
local BASE_RUN_SPEED = 7.0    -- yards per second at 100% speed

-- Version pulled from the .toc so we only ever maintain it in one place.
local VERSION = "?"
do
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if meta then
        VERSION = meta(ADDON_NAME, "Version") or VERSION
    end
end

-- Defaults for configurable sampling
local DEFAULT_INTERVAL = 0.1   -- seconds between coordinate samples
local DEFAULT_WINDOW   = 10    -- number of samples to average over
local MAX_WINDOW       = 50    -- max buffer size

----------------------------------------------------------------------
-- Saved variables defaults
----------------------------------------------------------------------
local defaults = {
    locked = false,
    showTitle = true,
    showYards = true,
    showPercent = true,
    showKnots = false,
    showAPI = true,
    userHidden = false,
    updateInterval = DEFAULT_INTERVAL,
    smoothingWindow = DEFAULT_WINDOW,
    point = { "CENTER", nil, "CENTER", 0, -200 },
    scale = 1.0,
}

----------------------------------------------------------------------
-- Local state
----------------------------------------------------------------------
local samples = {}       -- circular buffer of { time, x, y, mapID }
local sampleIndex = 0
local elapsed = 0
local currentSpeed = 0   -- yards/sec
local isMoving = false
local isInWorld = false   -- true when in open world (not instanced)
local db                 -- saved variables reference

-- Pre-allocate circular buffer to max possible size
for i = 1, MAX_WINDOW do
    samples[i] = { time = 0, x = 0, y = 0, mapID = 0 }
end

-- Scratch + last-value caches so the per-tick Format* helpers don't
-- churn through a fresh table + a handful of strings on every update.
-- The user-visible value only changes at most a few times a second; the
-- update loop can fire 10-100x faster than that depending on settings.
local _formatScratch = {}
local _fmtSpeed10, _fmtShowY, _fmtShowP, _fmtShowK
local _fmtText, _fmtPct
local _apiPctCache, _apiTextCache

----------------------------------------------------------------------
-- Coordinate helpers
----------------------------------------------------------------------
local function GetWorldPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end

    local x, y = pos:GetXY()
    if x == 0 and y == 0 then return nil end

    local _, worldPos = C_Map.GetWorldPosFromMapPos(mapID, pos)
    if not worldPos then return nil end

    local wx, wy = worldPos:GetXY()
    return wx, wy, mapID
end

local function WorldDistance(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

----------------------------------------------------------------------
-- Speed calculation
----------------------------------------------------------------------
local function RecordSample()
    local wx, wy, mapID = GetWorldPosition()
    if not wx then return end

    local window = db and db.smoothingWindow or DEFAULT_WINDOW
    sampleIndex = sampleIndex + 1
    local idx = ((sampleIndex - 1) % window) + 1

    samples[idx].time  = GetTime()
    samples[idx].x     = wx
    samples[idx].y     = wy
    samples[idx].mapID = mapID
end

local function CalculateSpeed()
    if sampleIndex < 2 then return 0 end

    local window = db and db.smoothingWindow or DEFAULT_WINDOW
    local count = math.min(sampleIndex, window)
    local newestIdx = ((sampleIndex - 1) % window) + 1
    local oldestIdx = (((sampleIndex - count)) % window) + 1

    local newest = samples[newestIdx]
    local oldest = samples[oldestIdx]

    if not newest or not oldest then return 0 end
    if newest.mapID ~= oldest.mapID then return 0 end

    local dt = newest.time - oldest.time
    if dt < 0.01 then return 0 end

    local dist = WorldDistance(oldest.x, oldest.y, newest.x, newest.y)
    return dist / dt
end

----------------------------------------------------------------------
-- Reset samples (used when changing settings or zones)
----------------------------------------------------------------------
local function ResetSamples()
    sampleIndex = 0
    currentSpeed = 0
    for i = 1, MAX_WINDOW do
        samples[i].time  = 0
        samples[i].x     = 0
        samples[i].y     = 0
        samples[i].mapID = 0
    end
end

----------------------------------------------------------------------
-- Display frame
----------------------------------------------------------------------
local frame = CreateFrame("Frame", "TrueSpeedFrame", UIParent, "BackdropTemplate")
frame:SetSize(180, 60)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")

frame:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.7)
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.8)
frame:Hide() -- starts hidden; shown after zone check confirms open world

-- Title
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
title:SetText("|cff00ccffTrueSpeed|r")

-- Speed text (main line)
local speedText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
speedText:SetFont(speedText:GetFont(), 16, "OUTLINE")

-- Secondary line (API %)
local secondaryText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

----------------------------------------------------------------------
-- Dynamic layout
----------------------------------------------------------------------
local PADDING_TOP = 6
local PADDING_BOTTOM = 8
local PADDING_H = 16
local GAP = 2
local MIN_WIDTH = 60

local function UpdateLayout()
    if not db then return end

    local totalHeight = PADDING_TOP
    local maxWidth = MIN_WIDTH

    -- Title
    if db.showTitle then
        title:Show()
        title:ClearAllPoints()
        title:SetPoint("TOP", frame, "TOP", 0, -totalHeight)
        totalHeight = totalHeight + title:GetStringHeight() + GAP
        maxWidth = math.max(maxWidth, title:GetStringWidth())
    else
        title:Hide()
    end

    -- Speed text
    local speedStr = speedText:GetText() or ""
    if speedStr ~= "" then
        speedText:Show()
        speedText:ClearAllPoints()
        speedText:SetPoint("TOP", frame, "TOP", 0, -totalHeight)
        totalHeight = totalHeight + speedText:GetStringHeight() + GAP
        maxWidth = math.max(maxWidth, speedText:GetStringWidth())
    else
        speedText:Hide()
    end

    -- Secondary (API %)
    if db.showAPI then
        secondaryText:Show()
        secondaryText:ClearAllPoints()
        secondaryText:SetPoint("TOP", frame, "TOP", 0, -totalHeight)
        totalHeight = totalHeight + secondaryText:GetStringHeight() + GAP
        maxWidth = math.max(maxWidth, secondaryText:GetStringWidth())
    else
        secondaryText:Hide()
    end

    totalHeight = totalHeight - GAP + PADDING_BOTTOM
    local finalWidth = maxWidth + PADDING_H

    frame:SetSize(math.max(finalWidth, MIN_WIDTH), math.max(totalHeight, 24))
end

----------------------------------------------------------------------
-- Dragging
----------------------------------------------------------------------
frame:SetScript("OnDragStart", function(self)
    if db and not db.locked then
        self:StartMoving()
    end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if db then
        local point, _, relPoint, xOfs, yOfs = self:GetPoint()
        db.point = { point, nil, relPoint, xOfs, yOfs }
    end
end)

----------------------------------------------------------------------
-- Scale helper — keeps the frame in the same screen position
----------------------------------------------------------------------
local function SetScaleSafe(newScale)
    local oldScale = frame:GetScale()
    local point, _, relPoint, xOfs, yOfs = frame:GetPoint()

    -- Convert offset from old-scale space to screen, then to new-scale space
    local newX = xOfs * oldScale / newScale
    local newY = yOfs * oldScale / newScale

    db.scale = newScale
    frame:SetScale(newScale)
    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, relPoint, newX, newY)
    db.point = { point, nil, relPoint, newX, newY }
end

----------------------------------------------------------------------
-- Format helpers
----------------------------------------------------------------------
local function FormatSpeed()
    -- Quantise to 0.1 yd/s -- matches the %.1f display precision, so any
    -- two raw values that would print identically share a cache slot.
    local quantSpeed = math.floor(currentSpeed * 10 + 0.5)
    local sy, sp, sk = db.showYards, db.showPercent, db.showKnots

    if _fmtText
        and quantSpeed == _fmtSpeed10
        and sy == _fmtShowY
        and sp == _fmtShowP
        and sk == _fmtShowK then
        return _fmtText, _fmtPct
    end

    local rawPct = (currentSpeed / BASE_RUN_SPEED) * 100
    local roundedPct = math.floor(rawPct + 0.5)

    local parts = _formatScratch
    local n = 0
    if sy then
        n = n + 1; parts[n] = string.format("%.1f yd/s", currentSpeed)
    end
    if sp then
        n = n + 1; parts[n] = string.format("%d%%", roundedPct)
    end
    if sk then
        n = n + 1; parts[n] = string.format("%.1f kn", currentSpeed * 0.9144 / 0.5144)
    end

    local text = (n > 0) and table.concat(parts, "  |cff888888·|r  ", 1, n) or ""

    _fmtSpeed10, _fmtShowY, _fmtShowP, _fmtShowK = quantSpeed, sy, sp, sk
    _fmtText, _fmtPct = text, roundedPct
    return text, roundedPct
end

local function FormatSecondary()
    if not db.showAPI then return "" end
    local unitPct = math.floor((GetUnitSpeed("player") / BASE_RUN_SPEED) * 100 + 0.5)
    if unitPct == _apiPctCache and _apiTextCache then
        return _apiTextCache
    end
    _apiPctCache = unitPct
    _apiTextCache = string.format("|cff888888API: %d%%|r", unitPct)
    return _apiTextCache
end

----------------------------------------------------------------------
-- Colour speed text based on rounded percentage
----------------------------------------------------------------------
local function SpeedColour(pct)
    if pct < 1 then
        return 0.5, 0.5, 0.5      -- stationary (grey)
    elseif pct <= 100 then
        return 1, 1, 1             -- walking/running (white)
    elseif pct <= 200 then
        return 0.2, 1, 0.2         -- mounted ground (green)
    elseif pct <= 400 then
        return 0.3, 0.7, 1         -- fast mount / flight form (blue)
    else
        return 1, 0.5, 0           -- flight path / very fast (orange)
    end
end

----------------------------------------------------------------------
-- Update loop -- runs on a separate always-shown driver so sampling
-- keeps going while the display frame is hidden (in instances, after
-- `/ts hide`, etc.). That lets optional integrations like the ElvUI
-- datatext continue to read a live speed value.
----------------------------------------------------------------------
local updateDriver = CreateFrame("Frame")
updateDriver:SetScript("OnUpdate", function(self, dt)
    elapsed = elapsed + dt
    local interval = db and db.updateInterval or DEFAULT_INTERVAL
    if elapsed < interval then return end
    elapsed = elapsed - interval

    RecordSample()
    currentSpeed = CalculateSpeed()
    isMoving = currentSpeed > 0.5

    if frame:IsShown() then
        local speedStr, roundedPct = FormatSpeed()
        speedText:SetText(speedStr)
        speedText:SetTextColor(SpeedColour(roundedPct))
        secondaryText:SetText(FormatSecondary())
        UpdateLayout()
    end
end)

----------------------------------------------------------------------
-- Right-click context menu
----------------------------------------------------------------------
local menuFrame = CreateFrame("Frame", "TrueSpeedMenu", UIParent, "UIDropDownMenuTemplate")

local function ToggleOption(key)
    db[key] = not db[key]
    UpdateLayout()
end

local SCALE_VALUES = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0 }

UIDropDownMenu_Initialize(menuFrame, function(self, level, menuList)
    if not db then return end
    level = level or 1
    local info

    if level == 1 then
        -- Header
        info = UIDropDownMenu_CreateInfo()
        info.text = "|cff00ccffTrueSpeed|r  |cff888888v" .. VERSION .. "|r"
        info.isTitle = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Show Title
        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Title"
        info.checked = function() return db.showTitle end
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.func = function() ToggleOption("showTitle") end
        UIDropDownMenu_AddButton(info, level)

        -- Show Yards/s
        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Yards/s"
        info.checked = function() return db.showYards end
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.func = function() ToggleOption("showYards") end
        UIDropDownMenu_AddButton(info, level)

        -- Show Percent
        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Percent"
        info.checked = function() return db.showPercent end
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.func = function() ToggleOption("showPercent") end
        UIDropDownMenu_AddButton(info, level)

        -- Show Knots
        info = UIDropDownMenu_CreateInfo()
        info.text = "Show Knots"
        info.checked = function() return db.showKnots end
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.func = function() ToggleOption("showKnots") end
        UIDropDownMenu_AddButton(info, level)

        -- Show API %
        info = UIDropDownMenu_CreateInfo()
        info.text = "Show API %"
        info.checked = function() return db.showAPI end
        info.isNotRadio = true
        info.keepShownOnClick = true
        info.func = function() ToggleOption("showAPI") end
        UIDropDownMenu_AddButton(info, level)

        -- Separator
        info = UIDropDownMenu_CreateInfo()
        info.text = ""
        info.isTitle = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Lock / Unlock
        info = UIDropDownMenu_CreateInfo()
        info.text = db.locked and "Unlock Frame" or "Lock Frame"
        info.notCheckable = true
        info.func = function()
            db.locked = not db.locked
            print("|cff00ccffTrueSpeed|r: Frame " .. (db.locked and "locked." or "unlocked."))
        end
        UIDropDownMenu_AddButton(info, level)

        -- Scale submenu
        info = UIDropDownMenu_CreateInfo()
        info.text = "Scale"
        info.notCheckable = true
        info.hasArrow = true
        info.menuList = "SCALE"
        UIDropDownMenu_AddButton(info, level)

        -- Update Speed submenu
        info = UIDropDownMenu_CreateInfo()
        info.text = "Update Speed"
        info.notCheckable = true
        info.hasArrow = true
        info.menuList = "INTERVAL"
        UIDropDownMenu_AddButton(info, level)

        -- Smoothing Window submenu
        info = UIDropDownMenu_CreateInfo()
        info.text = "Smoothing Window"
        info.notCheckable = true
        info.hasArrow = true
        info.menuList = "SMOOTHING"
        UIDropDownMenu_AddButton(info, level)

        -- Reset Position
        info = UIDropDownMenu_CreateInfo()
        info.text = "Reset Position"
        info.notCheckable = true
        info.func = function()
            db.point = { "CENTER", nil, "CENTER", 0, -200 }
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        end
        UIDropDownMenu_AddButton(info, level)

        -- Hide
        info = UIDropDownMenu_CreateInfo()
        info.text = "Hide  |cff888888(/ts show)|r"
        info.notCheckable = true
        info.func = function()
            db.userHidden = true
            frame:Hide()
        end
        UIDropDownMenu_AddButton(info, level)

    elseif menuList == "SCALE" then
        for _, val in ipairs(SCALE_VALUES) do
            info = UIDropDownMenu_CreateInfo()
            info.text = string.format("%.0f%%", val * 100)
            info.checked = function() return db.scale == val end
            info.func = function()
                SetScaleSafe(val)
                print("|cff00ccffTrueSpeed|r: Scale set to " .. string.format("%.0f%%", val * 100))
            end
            UIDropDownMenu_AddButton(info, level)
        end

    elseif menuList == "INTERVAL" then
        local INTERVAL_VALUES = { 0.05, 0.1, 0.15, 0.2, 0.25, 0.5 }
        for _, val in ipairs(INTERVAL_VALUES) do
            info = UIDropDownMenu_CreateInfo()
            info.text = string.format("%.0f ms", val * 1000)
            info.checked = function() return math.abs(db.updateInterval - val) < 0.001 end
            info.func = function()
                db.updateInterval = val
                elapsed = 0
                ResetSamples()
                print("|cff00ccffTrueSpeed|r: Update interval set to " .. string.format("%.0f ms", val * 1000))
            end
            UIDropDownMenu_AddButton(info, level)
        end

    elseif menuList == "SMOOTHING" then
        local WINDOW_VALUES = { 5, 10, 15, 20, 30, 50 }
        for _, val in ipairs(WINDOW_VALUES) do
            info = UIDropDownMenu_CreateInfo()
            info.text = val .. " samples"
            info.checked = function() return db.smoothingWindow == val end
            info.func = function()
                db.smoothingWindow = val
                ResetSamples()
                print("|cff00ccffTrueSpeed|r: Smoothing window set to " .. val .. " samples")
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end
end, "MENU")

frame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
        ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
    end
end)

----------------------------------------------------------------------
-- Zone / instance helpers
----------------------------------------------------------------------
local function CheckWorldState()
    local inInstance, instanceType = IsInInstance()
    isInWorld = not inInstance
    if isInWorld then
        if not db or not db.userHidden then
            frame:Show()
        end
    else
        frame:Hide()
    end
    ResetSamples()
end

----------------------------------------------------------------------
-- Saved variables & init
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

local hasShownLoadMsg = false

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        if not TrueSpeedDB then
            TrueSpeedDB = {}
        end
        db = TrueSpeedDB
        for k, v in pairs(defaults) do
            if db[k] == nil then
                db[k] = v
            end
        end

        frame:ClearAllPoints()
        local p = db.point
        frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
        frame:SetScale(db.scale)

        UpdateLayout()

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        CheckWorldState()
        if not hasShownLoadMsg then
            hasShownLoadMsg = true
            print("|cff00ccffTrueSpeed|r v" .. VERSION .. " loaded. Type |cff00ff00/ts|r or right-click for options.")
        end

    elseif event == "PLAYER_LOGOUT" then
        -- Position saved on drag stop
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_TRUESPEED1 = "/truespeed"
SLASH_TRUESPEED2 = "/ts"

SlashCmdList["TRUESPEED"] = function(msg)
    msg = msg:lower():trim()

    if msg == "lock" then
        db.locked = true
        print("|cff00ccffTrueSpeed|r: Frame locked.")

    elseif msg == "unlock" then
        db.locked = false
        print("|cff00ccffTrueSpeed|r: Frame unlocked. Drag to reposition.")

    elseif msg == "reset" then
        db.point = { "CENTER", nil, "CENTER", 0, -200 }
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        print("|cff00ccffTrueSpeed|r: Position reset.")

    elseif msg == "title" then
        ToggleOption("showTitle")
        print("|cff00ccffTrueSpeed|r: Title " .. (db.showTitle and "ON" or "OFF"))

    elseif msg == "yards" then
        ToggleOption("showYards")
        print("|cff00ccffTrueSpeed|r: Yards/s " .. (db.showYards and "ON" or "OFF"))

    elseif msg == "percent" then
        ToggleOption("showPercent")
        print("|cff00ccffTrueSpeed|r: Percent " .. (db.showPercent and "ON" or "OFF"))

    elseif msg == "knots" then
        ToggleOption("showKnots")
        print("|cff00ccffTrueSpeed|r: Knots " .. (db.showKnots and "ON" or "OFF"))

    elseif msg == "api" then
        ToggleOption("showAPI")
        print("|cff00ccffTrueSpeed|r: API % " .. (db.showAPI and "ON" or "OFF"))

    elseif msg:match("^scale") then
        local val = tonumber(msg:match("scale%s+(.+)"))
        if val and val >= 0.5 and val <= 3 then
            SetScaleSafe(val)
            print("|cff00ccffTrueSpeed|r: Scale set to " .. val)
        else
            print("|cff00ccffTrueSpeed|r: Usage: /ts scale 0.5-3.0")
        end

    elseif msg:match("^interval") then
        local val = tonumber(msg:match("interval%s+(.+)"))
        if val and val >= 0.01 and val <= 1.0 then
            db.updateInterval = val
            elapsed = 0
            ResetSamples()
            print("|cff00ccffTrueSpeed|r: Update interval set to " .. string.format("%.0f ms", val * 1000))
        else
            print("|cff00ccffTrueSpeed|r: Usage: /ts interval 0.01-1.0 (seconds)")
        end

    elseif msg:match("^window") then
        local val = tonumber(msg:match("window%s+(.+)"))
        if val and val >= 2 and val <= MAX_WINDOW then
            val = math.floor(val)
            db.smoothingWindow = val
            ResetSamples()
            print("|cff00ccffTrueSpeed|r: Smoothing window set to " .. val .. " samples")
        else
            print("|cff00ccffTrueSpeed|r: Usage: /ts window 2-" .. MAX_WINDOW)
        end

    elseif msg == "hide" then
        db.userHidden = true
        frame:Hide()
        print("|cff00ccffTrueSpeed|r: Hidden. Use /ts show to restore.")

    elseif msg == "show" then
        db.userHidden = false
        if isInWorld then
            frame:Show()
        else
            print("|cff00ccffTrueSpeed|r: Will show when you return to the open world.")
        end

    else
        print("|cff00ccffTrueSpeed|r commands:")
        print("  /ts lock       - Lock frame position")
        print("  /ts unlock     - Unlock frame (drag to move)")
        print("  /ts reset      - Reset position to center")
        print("  /ts title      - Toggle title display")
        print("  /ts yards      - Toggle yards/s display")
        print("  /ts percent    - Toggle percent display")
        print("  /ts knots      - Toggle knots display")
        print("  /ts api        - Toggle API % display")
        print("  /ts scale #    - Set frame scale (0.5-3.0)")
        print("  /ts interval # - Update speed in seconds (0.01-1.0)")
        print("  /ts window #   - Smoothing samples (2-" .. MAX_WINDOW .. ")")
        print("  /ts hide       - Hide the frame")
        print("  /ts show       - Show the frame")
        print("  Right-click the frame for a menu!")
    end
end

----------------------------------------------------------------------
-- Public API
-- Shared with sibling files (e.g. TrueSpeed_ElvUI.lua) through the
-- addon's private namespace. Keep this surface small.
----------------------------------------------------------------------
ns.ADDON_NAME      = ADDON_NAME
ns.BASE_RUN_SPEED  = BASE_RUN_SPEED

function ns.GetSpeed()        return currentSpeed end
function ns.GetSpeedPercent() return (currentSpeed / BASE_RUN_SPEED) * 100 end
function ns.GetSpeedKnots()   return currentSpeed * 0.9144 / 0.5144 end
function ns.IsMoving()        return isMoving end
function ns.IsInWorld()       return isInWorld end
function ns.SpeedColour(pct)  return SpeedColour(pct) end
