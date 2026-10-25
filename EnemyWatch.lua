-- EnemyWatch: nearby opposing-faction player list + "you are being targeted" alerts.
--
-- Detection sources (the combat log is not available to addons on the Midnight/Forever API):
--   * enemy nameplates (enable them with V, or /ew nameplates)
--   * your target and mouseover
--   * your party/raid members' targets
--
-- Rows are secure buttons, so clicking one targets that player. Blizzard does not allow
-- secure buttons to be re-assigned during combat, so the list layout is frozen while you
-- are in combat; new contacts found in combat are shown in the footer and become
-- clickable as soon as combat ends.

local ADDON_NAME = ...

local MAX_ROWS     = 15
local ROW_HEIGHT   = 18
local FRAME_WIDTH  = 240
local HEADER_H     = 22
local FOOTER_H     = 16
local TICK         = 0.3   -- seconds between scans
local VISIBLE_GRACE = 3    -- seconds after last sighting a contact still counts as "in view"

local defaults = {
    point        = { "CENTER", "CENTER", 350, 120 },
    locked       = false,
    hidden       = false,
    scale        = 1,
    expire       = 60,     -- seconds before an unseen contact is dropped
    alertCooldown = 8,     -- seconds between "targeting you" alerts for the same player
    alertSound   = true,
    alertScreen  = true,
    newSound     = true,
    newChat      = false,
}

local db
local myFaction
local enemies    = {}  -- fullName -> contact
local plateUnits = {}  -- nameplate unit token -> true
local rows       = {}
local frame, title, footer
local inCombat   = false
local needsLayout = false

---------------------------------------------------------------------------
-- Secret-value safe wrappers
---------------------------------------------------------------------------

local issecret = issecretvalue or function() return false end

local function clean(v)
    if v == nil or issecret(v) then return nil end
    return v
end

-- Calls an API and discards errors and secret return values.
local function call(f, ...)
    local ok, a, b, c, d = pcall(f, ...)
    if not ok then return end
    return clean(a), clean(b), clean(c), clean(d)
end

local function Print(msg)
    print("|cffff5555EnemyWatch|r: " .. msg)
end

local function PlayKit(id)
    if id then PlaySound(id, "Master") end
end

local function ClassColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 0.3, 0.3
end

local function ColoredName(e)
    local r, g, b = ClassColor(e.classFile)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, e.name)
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------

local function AlertTargeted(e)
    local lvl = (e.level and e.level > 0) and tostring(e.level) or "??"
    local text = string.format("%s (%s %s) is targeting you!", e.name, lvl, e.className or "")
    if db.alertSound then PlayKit(SOUNDKIT and SOUNDKIT.RAID_WARNING) end
    if db.alertScreen and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
    end
    Print("|cffff2020" .. ColoredName(e) .. " (" .. lvl .. " " .. (e.className or "") .. ") is targeting you!|r")
end

local function AlertNew(e)
    if db.newSound then PlayKit(SOUNDKIT and SOUNDKIT.TELL_MESSAGE) end
    if db.newChat then
        local lvl = (e.level and e.level > 0) and tostring(e.level) or "??"
        Print("Enemy spotted: " .. ColoredName(e) .. " (" .. lvl .. " " .. (e.className or "") .. ")")
    end
end

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------

local function IsEnemyPlayer(unit)
    if not call(UnitExists, unit) or not call(UnitIsPlayer, unit) then return false end
    local faction = call(UnitFactionGroup, unit)
    return faction ~= nil and faction ~= "Neutral" and faction ~= myFaction
end

local RequestRefresh

local function Track(unit)
    if not IsEnemyPlayer(unit) then return end

    local name, realm = call(UnitName, unit)
    if not name or name == UNKNOWNOBJECT then return end
    local full = (realm and realm ~= "") and (name .. "-" .. realm) or name

    local now = GetTime()
    local e = enemies[full]
    local isNew = not e
    if isNew then
        e = { name = name, full = full, firstSeen = now }
        enemies[full] = e
        if not inCombat then needsLayout = true end
    end

    e.lastSeen = now
    local className, classFile = call(UnitClass, unit)
    e.className = className or e.className
    e.classFile = classFile or e.classFile
    e.race      = call(UnitRace, unit) or e.race
    e.level     = call(UnitLevel, unit) or e.level
    e.guild     = call(GetGuildInfo, unit) or e.guild

    -- Only trust a positive/negative answer; a secret/unknown result leaves state alone.
    local targetsMe = call(UnitIsUnit, unit .. "target", "player")
    if targetsMe ~= nil then
        local was = e.targetsMe
        e.targetsMe = targetsMe and true or false
        e.targetCheckedAt = now
        if e.targetsMe ~= (was == true) and not inCombat then needsLayout = true end
        if e.targetsMe and not was and now - (e.lastAlert or 0) >= db.alertCooldown then
            e.lastAlert = now
            AlertTargeted(e)
        end
    end

    if isNew then AlertNew(e) end
    RequestRefresh()
end

local function ScanGroupTargets()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Track("raid" .. i .. "target") end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do Track("party" .. i .. "target") end
    end
end

local function Scan()
    for unit in pairs(plateUnits) do Track(unit) end
    Track("target")
    Track("mouseover")
    ScanGroupTargets()

    local now = GetTime()
    for full, e in pairs(enemies) do
        -- A "targeting you" flag we can no longer verify fades out.
        if e.targetsMe and now - (e.targetCheckedAt or 0) > VISIBLE_GRACE then
            e.targetsMe = false
            if not inCombat then needsLayout = true end
        end
        if not inCombat and now - e.lastSeen > db.expire then
            enemies[full] = nil
            needsLayout = true
        end
    end
    RequestRefresh()
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function SortedContacts()
    local list = {}
    for _, e in pairs(enemies) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        if (a.targetsMe == true) ~= (b.targetsMe == true) then return a.targetsMe == true end
        -- Newest first by first sighting, so rows don't shuffle under the mouse.
        return a.firstSeen > b.firstSeen
    end)
    return list
end

local function UpdateRowVisual(row, e, now)
    local seenAgo = now - e.lastSeen
    local inView = seenAgo <= VISIBLE_GRACE
    local r, g, b = ClassColor(e.classFile)
    local a = inView and 1 or 0.45

    row.name:SetText(e.name)
    row.name:SetTextColor(r, g, b, a)

    local lvl = (e.level and e.level > 0) and tostring(e.level) or "??"
    local info
    if e.targetsMe then
        info = "|cffff2020TARGETING YOU|r  " .. lvl
    elseif inView then
        info = lvl .. " " .. (e.className or "")
    else
        info = string.format("%ds ago  %s", math.floor(seenAgo), lvl)
    end
    row.info:SetText(info)
    row.info:SetAlpha(a)

    if e.targetsMe then
        row.bg:SetColorTexture(0.6, 0, 0, 0.55)
    else
        row.bg:SetColorTexture(0, 0, 0, 0.25)
    end
end

local function ClearRowVisual(row)
    row.name:SetText("")
    row.info:SetText("")
    row.bg:SetColorTexture(0, 0, 0, 0)
end

-- Re-binds the secure rows. Only legal out of combat.
local function Layout()
    if InCombatLockdown() then needsLayout = true return end
    needsLayout = false

    local list = SortedContacts()
    local shown = math.min(#list, MAX_ROWS)
    for i, row in ipairs(rows) do
        local e = list[i]
        if e then
            row.key = e.full
            row:SetAttribute("macrotext", "/targetexact " .. e.full)
            row:Show()
        else
            row.key = nil
            row:SetAttribute("macrotext", nil)
            row:Hide()
        end
    end
    frame:SetHeight(HEADER_H + math.max(shown, 1) * ROW_HEIGHT + FOOTER_H + 4)
end

local function Refresh()
    if not frame then return end
    if needsLayout and not InCombatLockdown() then Layout() end

    local now, bound, total, hostileToMe = GetTime(), {}, 0, 0
    for _, row in ipairs(rows) do
        local e = row.key and enemies[row.key]
        if e then
            UpdateRowVisual(row, e, now)
            bound[e.full] = true
        else
            ClearRowVisual(row)
        end
    end

    local unbound = {}
    for full, e in pairs(enemies) do
        total = total + 1
        if e.targetsMe then hostileToMe = hostileToMe + 1 end
        if not bound[full] then unbound[#unbound + 1] = e end
    end

    title:SetText(string.format("EnemyWatch  |cffffffff%d|r%s", total,
        hostileToMe > 0 and ("  |cffff2020(" .. hostileToMe .. " on you)|r") or ""))

    if total == 0 then
        footer:SetText("|cff888888No enemy players nearby|r")
    elseif #unbound > 0 and InCombatLockdown() then
        table.sort(unbound, function(a, b) return a.lastSeen > b.lastSeen end)
        local names = {}
        for i = 1, math.min(#unbound, 3) do
            names[i] = (unbound[i].targetsMe and "|cffff2020>|r" or "") .. ColoredName(unbound[i])
        end
        footer:SetText("+" .. #unbound .. ": " .. table.concat(names, ", ") .. " |cff888888(click after combat)|r")
    elseif #unbound > 0 then
        footer:SetText("|cff888888+" .. #unbound .. " more|r")
    else
        footer:SetText("")
    end
end

local refreshQueued = false
function RequestRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        Refresh()
    end)
end

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint()
    db.point = { point, relPoint, x, y }
end

local function ApplyPosition()
    frame:ClearAllPoints()
    local p = db.point
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    frame:SetScale(db.scale)
end

local function Row_OnEnter(self)
    local e = self.key and enemies[self.key]
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ColoredName(e))
    local lvl = (e.level and e.level > 0) and tostring(e.level) or "??"
    GameTooltip:AddLine(string.format("Level %s %s %s", lvl, e.race or "", e.className or ""), 1, 1, 1)
    if e.guild then GameTooltip:AddLine("<" .. e.guild .. ">", 0.6, 1, 0.6) end
    GameTooltip:AddLine(string.format("Last seen %ds ago", math.floor(GetTime() - e.lastSeen)), 0.7, 0.7, 0.7)
    if e.targetsMe then GameTooltip:AddLine("Targeting you!", 1, 0.1, 0.1) end
    GameTooltip:AddLine("Click to target", 0.4, 0.8, 1)
    GameTooltip:Show()
end

local function CreateUI()
    frame = CreateFrame("Frame", "EnemyWatchFrame", UIParent, "BackdropTemplate")
    frame:SetWidth(FRAME_WIDTH)
    frame:SetHeight(HEADER_H + ROW_HEIGHT + FOOTER_H + 4)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.08, 0.85)
    frame:SetBackdropBorderColor(0.8, 0.2, 0.2, 0.9)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not db.locked and not InCombatLockdown() then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetPoint("TOPRIGHT", -8, -6)
    title:SetJustifyH("LEFT")

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", "EnemyWatchRow" .. i, frame, "SecureActionButtonTemplate")
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 4, -HEADER_H - (i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -4, -HEADER_H - (i - 1) * ROW_HEIGHT)
        -- Both up and down: the template fires once, honouring the ActionButtonUseKeyDown CVar.
        row:RegisterForClicks("AnyUp", "AnyDown")
        row:SetAttribute("type", "macro")

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetJustifyH("LEFT")

        row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.info:SetPoint("RIGHT", -4, 0)
        row.info:SetJustifyH("RIGHT")
        row.name:SetPoint("RIGHT", row.info, "LEFT", -4, 0)

        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:Hide()
        rows[i] = row
    end

    footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("BOTTOMLEFT", 8, 6)
    footer:SetPoint("BOTTOMRIGHT", -8, 6)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(false)

    ApplyPosition()
    frame:SetShown(not db.hidden)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Toggle(key, label)
    db[key] = not db[key]
    Print(label .. ": " .. (db[key] and "|cff20ff20on|r" or "|cffff2020off|r"))
end

local function RunTest()
    local now = GetTime()
    local fakes = {
        { "Testrogue", "ROGUE", "Rogue", 60, true },
        { "Testmage", "MAGE", "Mage", 58, false },
        { "Testwarrior", "WARRIOR", "Warrior", -1, false },
    }
    for _, f in ipairs(fakes) do
        local e = { name = f[1], full = f[1], classFile = f[2], className = f[3], level = f[4],
                    race = "Test", firstSeen = now, lastSeen = now, targetCheckedAt = now + 10 }
        enemies[e.full] = e
        if f[5] then e.targetsMe = true; AlertTargeted(e) end
    end
    needsLayout = true
    RequestRefresh()
    Print("Added 3 test contacts (they expire after " .. db.expire .. "s).")
end

local function Slash(msg)
    local cmd, arg = msg:lower():match("^(%S*)%s*(.-)$")
    if cmd == "" or cmd == "toggle" then
        if InCombatLockdown() then Print("Can't show/hide in combat.") return end
        db.hidden = not db.hidden
        frame:SetShown(not db.hidden)
    elseif cmd == "lock" then
        Toggle("locked", "Frame locked")
    elseif cmd == "reset" then
        if InCombatLockdown() then Print("Can't move the frame in combat.") return end
        db.point = CopyTable(defaults.point)
        db.scale = 1
        ApplyPosition()
    elseif cmd == "scale" then
        local s = tonumber(arg)
        if not s or s < 0.5 or s > 2 then Print("Usage: /ew scale 0.5-2") return end
        if InCombatLockdown() then Print("Can't rescale in combat.") return end
        db.scale = s
        ApplyPosition()
    elseif cmd == "expire" then
        local s = tonumber(arg)
        if not s or s < 5 then Print("Usage: /ew expire <seconds, min 5>") return end
        db.expire = s
        Print("Contacts expire after " .. s .. "s unseen.")
    elseif cmd == "sound" then
        Toggle("alertSound", "Targeted alert sound")
    elseif cmd == "screen" then
        Toggle("alertScreen", "Targeted on-screen warning")
    elseif cmd == "newsound" then
        Toggle("newSound", "New enemy sound")
    elseif cmd == "newchat" then
        Toggle("newChat", "New enemy chat message")
    elseif cmd == "clear" then
        if InCombatLockdown() then Print("Can't clear the list in combat.") return end
        wipe(enemies)
        needsLayout = true
        RequestRefresh()
    elseif cmd == "nameplates" then
        if InCombatLockdown() then Print("Can't change nameplate settings in combat.") return end
        SetCVar("nameplateShowEnemies", 1)
        Print("Enemy nameplates enabled.")
    elseif cmd == "test" then
        RunTest()
    else
        Print("Commands:")
        print("  /ew - show/hide the window")
        print("  /ew lock - lock/unlock dragging")
        print("  /ew reset | scale <n> - position and size")
        print("  /ew expire <sec> - drop contacts unseen this long (now " .. db.expire .. ")")
        print("  /ew sound | screen - targeted-alert sound / raid-warning text")
        print("  /ew newsound | newchat - alerts for newly spotted enemies")
        print("  /ew nameplates - turn on enemy nameplates (main detection source)")
        print("  /ew clear | test")
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")

local handlers = {}

function handlers.PLAYER_LOGIN()
    EnemyWatchDB = EnemyWatchDB or {}
    db = EnemyWatchDB
    for k, v in pairs(defaults) do
        if db[k] == nil then db[k] = (type(v) == "table") and CopyTable(v) or v end
    end

    myFaction = UnitFactionGroup("player")
    CreateUI()
    Refresh()

    SLASH_ENEMYWATCH1 = "/ew"
    SLASH_ENEMYWATCH2 = "/enemywatch"
    SlashCmdList.ENEMYWATCH = Slash

    C_Timer.NewTicker(TICK, Scan)

    if not GetCVarBool("nameplateShowEnemies") then
        Print("Enemy nameplates are off, so detection range is limited. Press V or type /ew nameplates.")
    end
end

-- Pandaren pick a faction after login.
function handlers.NEUTRAL_FACTION_SELECT_RESULT()
    myFaction = UnitFactionGroup("player")
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
    plateUnits[unit] = true
    Track(unit)
end

function handlers.NAME_PLATE_UNIT_REMOVED(unit)
    plateUnits[unit] = nil
end

function handlers.PLAYER_TARGET_CHANGED()
    Track("target")
end

function handlers.UPDATE_MOUSEOVER_UNIT()
    Track("mouseover")
end

-- Fires when any unit we can see changes target: immediate "targeting you" alerts.
function handlers.UNIT_TARGET(unit)
    if plateUnits[unit] or unit == "target" then Track(unit) end
end

function handlers.PLAYER_REGEN_DISABLED()
    inCombat = true
end

function handlers.PLAYER_REGEN_ENABLED()
    inCombat = false
    needsLayout = true
    Refresh()
end

events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
for event in pairs(handlers) do
    pcall(events.RegisterEvent, events, event)  -- tolerate events missing on this client
end
