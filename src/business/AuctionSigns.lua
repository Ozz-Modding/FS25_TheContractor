-- Auction roadside signs (136, spike): signs at the map's busiest junctions
-- giving an auction's month, driven from the console (tcCompany
-- auctionSigns) with no auction around them yet (137 puts them up a month
-- before a sale, with its month).
--
--   Finding spots (server, place): the AI road splines (sampleRoads; only
--     the server keeps them) and TCAuctionSigns.pick (pure, tested): one
--     sign at each of the best junctions, spread over the map. Each spot is
--     checked here (isSpotClear): not by a bridge, not in water, not on a
--     field, the ground level enough and near the road's height, nothing in
--     the way (buildings, static objects, trees, vehicles).
--   Showing them (every machine, applySync): a plain model, not a
--     placeable (vanilla would save, sell and list one), loaded from the
--     synced spots, linked to the scene's root with a static collision, so
--     nothing drives through it. The server loads them too, a dedicated one
--     included: it runs the vehicles' physics. The board shows "COMING IN
--     <MONTH>": one of its twelve, the rest hidden (no day: the auction's
--     job gives that). Every machine with a map has a marker on each.
--   Saving: the month and the spots in TheContractor.xml, so they stay up
--     over a load.
--
-- Server-wide, not a farm's: nothing to forget when a farm is deleted.

TheContractorAuctionSigns = {}
local TheContractorAuctionSigns_mt = Class(TheContractorAuctionSigns)

TheContractorAuctionSigns.FILENAME = "i3d/auctionSign.i3d"
TheContractorAuctionSigns.MARKER_RADIUS = 12

-- The spot's checks (metres): the box that must be clear round the board
-- and posts (across the board, either side of it, and from the ground up),
-- the most the ground may vary under it, the most it may be above or below
-- the road, and the most the road may be above the ground (a bridge).
TheContractorAuctionSigns.CLEARANCE = { halfWidth = 1.0, halfDepth = 0.35, floor = 0.15, top = 2.2 }
TheContractorAuctionSigns.MAX_GROUND_STEP = 0.5
TheContractorAuctionSigns.MAX_VERGE_HEIGHT = 1.5
TheContractorAuctionSigns.MAX_ROAD_HEIGHT_GAP = 1.5

-- The posts' feet in the model's own x and z (genAuctionSignI3d.py's POST_X,
-- POST_Z and POST): each post's four corners. The sign stands at the lowest
-- ground under them, so on a slope neither post hangs in the air (the uphill
-- one goes a little into the ground instead).
TheContractorAuctionSigns.POST_FEET = {}
for _, postX in ipairs({ -0.6, 0.6 }) do
    for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
        table.insert(TheContractorAuctionSigns.POST_FEET, { postX + 0.045 * corner[1], -0.065 + 0.045 * corner[2] })
    end
end

-- Why isSpotClear turned a spot down (the console's counts).
TheContractorAuctionSigns.REJECT = {
    BRIDGE = "bridge",
    WATER = "water",
    FIELD = "field",
    STEEP = "steep",
    BANK = "bank",
    BLOCKED = "blocked",
}

-- The console's month names (English, as the board's are), by their first
-- three letters.
local MONTH_NAMES = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }
local MONTH_WORDS = { "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December" }

local OVERLAP_MASK = CollisionFlag ~= nil and (CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING +
    CollisionFlag.TREE + CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TRAFFIC_VEHICLE) or 0

function TheContractorAuctionSigns.new()
    local self = setmetatable({}, TheContractorAuctionSigns_mt)
    -- Every machine, as the server sent them: the month (1 to 12, 0: none
    -- up) and each sign { x, z, yaw } (the server's have side, offset,
    -- junctionX/Z and busyMetres too).
    self.month = 0
    self.signs = {}
    -- Every machine: the loaded models ({ node, sharedLoadRequestId }) and
    -- map markers, rebuilt on the next update after the signs change (the
    -- terrain's there by then).
    self.models = {}
    self.markers = {}
    self.isDirty = false
    return self
end

-- Every machine ------------------------------------------------------------------------------

-- The signs as the server sent them (TCAuctionSignsEvent).
function TheContractorAuctionSigns:applySync(month, signs)
    self.month = month or 0
    self.signs = signs or {}
    self.isDirty = true
end

function TheContractorAuctionSigns:update(dt)
    if self.isDirty then
        self.isDirty = false
        self:rebuild()
    end
end

function TheContractorAuctionSigns:removeAll()
    for _, model in ipairs(self.models) do
        if model.node ~= nil and entityExists(model.node) then
            delete(model.node)
        end
        if model.sharedLoadRequestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(model.sharedLoadRequestId)
        end
    end
    self.models = {}
    for _, hotspot in ipairs(self.markers) do
        if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
            g_currentMission:removeMapHotspot(hotspot)
        end
        hotspot:delete()
    end
    self.markers = {}
end

-- Shows the board's month (docs/auction-sign-i3d.md): visuals (0) > date
-- (3) > month1 to month12, one shown.
function TheContractorAuctionSigns.setMonth(node, month)
    local date = getChildAt(getChildAt(node, 0), 3)
    for i = 0, getNumOfChildren(date) - 1 do
        setVisibility(getChildAt(date, i), i == month - 1)
    end
end

-- The height a sign stands at: the lowest ground under its posts' feet.
function TheContractorAuctionSigns.getBaseHeight(sign)
    local acrossX, acrossZ = math.cos(sign.yaw), -math.sin(sign.yaw)
    local depthX, depthZ = math.sin(sign.yaw), math.cos(sign.yaw)
    local lowest = nil
    for _, foot in ipairs(TheContractorAuctionSigns.POST_FEET) do
        local x = sign.x + acrossX * foot[1] + depthX * foot[2]
        local z = sign.z + acrossZ * foot[1] + depthZ * foot[2]
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        if lowest == nil or y < lowest then
            lowest = y
        end
    end
    return lowest
end

-- A sign's model at its spot, or nil if it won't load.
function TheContractorAuctionSigns.loadModel(sign, month)
    local filename = Utils.getFilename(TheContractorAuctionSigns.FILENAME, TheContractor.dir)
    local root, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(filename, false, false)
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: could not load the auction sign '%s'", filename)
        return nil
    end
    local node = getChildAt(root, 0)
    link(getRootNode(), node)
    delete(root)
    setTranslation(node, sign.x, TheContractorAuctionSigns.getBaseHeight(sign), sign.z)
    setRotation(node, 0, sign.yaw, 0)
    TheContractorAuctionSigns.setMonth(node, month)
    return { node = node, sharedLoadRequestId = sharedLoadRequestId }
end

function TheContractorAuctionSigns:rebuild()
    self:removeAll()
    if self.month < 1 then
        return
    end
    for _, sign in ipairs(self.signs) do
        local model = TheContractorAuctionSigns.loadModel(sign, self.month)
        if model ~= nil then
            table.insert(self.models, model)
        end
    end
    if g_currentMission.hud ~= nil and AbstractFieldMissionHotspot ~= nil and g_currentMission.addMapHotspot ~= nil then
        for _, sign in ipairs(self.signs) do
            TheContractorYards.addMarker(self.markers, sign.x, sign.z, TheContractorAuctionSigns.MARKER_RADIUS)
        end
    end
end

function TheContractorAuctionSigns:delete()
    self:removeAll()
end

-- Server: the signs to this machine and every client.
function TheContractorAuctionSigns:sync()
    self:applySync(self.month, self.signs)
    if g_server ~= nil then
        g_server:broadcastEvent(TCAuctionSignsEvent.new(self.month, self.signs))
    end
end

-- Finding spots (server) -----------------------------------------------------------------------

-- Every AI road spline as its points every sampleStep metres, in order, {
-- x, y, z }. Server only (vanilla only keeps the splines there).
function TheContractorAuctionSigns.sampleRoads()
    local splines = {}
    local aiSystem = g_currentMission.aiSystem
    if aiSystem == nil or aiSystem.getRoadSplines == nil then
        return splines
    end
    local step = TCAuctionSigns.RULES.sampleStep
    for spline in pairs(aiSystem:getRoadSplines()) do
        local length = getSplineLength(spline)
        if length ~= nil and length > 0 then
            local count = math.max(1, math.ceil(length / step))
            local points = {}
            for i = 0, count do
                local x, y, z = getSplinePosition(spline, i / count)
                table.insert(points, { x = x, y = y, z = z })
            end
            table.insert(splines, points)
        end
    end
    return splines
end

local overlapTarget = { blocked = false }
function overlapTarget:onOverlap(node)
    if node ~= g_terrainNode then
        self.blocked = true
        return false
    end
    return true
end

-- TCAuctionSigns.pick's isClear: true, or false and a REJECT reason.
function TheContractorAuctionSigns.isSpotClear(candidate)
    local S = TheContractorAuctionSigns
    local REJECT = S.REJECT
    local x, z = candidate.x, candidate.z
    local roadGroundY = getTerrainHeightAtWorldPos(g_terrainNode, candidate.roadX, 0, candidate.roadZ)
    if candidate.roadY ~= nil and math.abs(candidate.roadY - roadGroundY) > S.MAX_ROAD_HEIGHT_GAP then
        return false, REJECT.BRIDGE
    end
    local groundY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local environment = g_currentMission.environmentAreaSystem
    local waterY = environment ~= nil and environment.getWaterYAtWorldPosition ~= nil and
        environment:getWaterYAtWorldPosition(x, groundY, z) or nil
    if waterY ~= nil and groundY < waterY then
        return false, REJECT.WATER
    end

    -- The board's across (its local x) and depth (z) on the ground.
    local acrossX, acrossZ = math.cos(candidate.yaw), -math.sin(candidate.yaw)
    local depthX, depthZ = math.sin(candidate.yaw), math.cos(candidate.yaw)
    local clearance = S.CLEARANCE
    local lowest, highest = groundY, groundY
    for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 }, { 0, 0 } }) do
        local cx = x + acrossX * clearance.halfWidth * corner[1] + depthX * clearance.halfDepth * corner[2]
        local cz = z + acrossZ * clearance.halfWidth * corner[1] + depthZ * clearance.halfDepth * corner[2]
        if FSDensityMapUtil ~= nil and FSDensityMapUtil.getIsFieldAtWorldPos(cx, cz) then
            return false, REJECT.FIELD
        end
        local y = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
        lowest, highest = math.min(lowest, y), math.max(highest, y)
    end
    if highest - lowest > S.MAX_GROUND_STEP then
        return false, REJECT.STEEP
    end
    if math.abs(groundY - roadGroundY) > S.MAX_VERGE_HEIGHT then
        return false, REJECT.BANK
    end

    local halfHeight = (clearance.top - clearance.floor) * 0.5
    overlapTarget.blocked = false
    overlapBox(x, groundY + clearance.floor + halfHeight, z, 0, candidate.yaw, 0, clearance.halfWidth, halfHeight,
        clearance.halfDepth, "onOverlap", overlapTarget, OVERLAP_MASK, true, true, true, true)
    if overlapTarget.blocked then
        return false, REJECT.BLOCKED
    end
    return true
end

-- Puts signs up at the map's best junctions for a month (1 to 12),
-- replacing any. Returns the text to print.
function TheContractorAuctionSigns:place(month)
    local started = getTimeSec()
    local splines = TheContractorAuctionSigns.sampleRoads()
    local result = TCAuctionSigns.pick(splines, TheContractorAuctionSigns.isSpotClear)
    local tookMs = (getTimeSec() - started) * 1000

    self.month = month
    self.signs = result.signs
    self:sync()
    TCLog.info("TheContractor: %d auction sign(s) in %.0f ms", #result.signs, tookMs)

    local lines = { string.format(
        "Auction signs for %s: %d up, of %d junction(s) on %d road spline(s), in %.0f ms. Marked on the map.",
        MONTH_WORDS[month], #result.signs, result.junctionCount, #splines, tookMs) }
    for i, sign in ipairs(result.signs) do
        table.insert(lines, TheContractorAuctionSigns.describeSign(i, sign))
    end
    local reasons = {}
    for reason, count in pairs(result.rejected) do
        table.insert(reasons, string.format("%s %d", reason, count))
    end
    table.sort(reasons)
    if #reasons > 0 then
        table.insert(lines, "  Spots passed over: " .. table.concat(reasons, ", "))
    end
    return table.concat(lines, "\n")
end

function TheContractorAuctionSigns.describeSign(i, sign)
    local text = string.format("  %d. %.1f, %.1f", i, sign.x, sign.z)
    if sign.busyMetres ~= nil then
        text = text .. string.format(", %s verge %.2f m out, %.0f m of road round its junction", tostring(sign.side),
            sign.offset or 0, sign.busyMetres)
    end
    return text
end

-- Takes them down. Returns the text to print.
function TheContractorAuctionSigns:clear()
    if #self.signs == 0 then
        return "There are no auction signs up."
    end
    local count = #self.signs
    self.month = 0
    self.signs = {}
    self:sync()
    return string.format("%d auction sign(s) taken down.", count)
end

function TheContractorAuctionSigns:describe()
    if #self.signs == 0 then
        return "There are no auction signs up. 'tcCompany auctionSigns <month>' puts them up."
    end
    local lines = { string.format("%d auction sign(s) up for %s:", #self.signs,
        MONTH_WORDS[self.month] or "?") }
    for i, sign in ipairs(self.signs) do
        table.insert(lines, TheContractorAuctionSigns.describeSign(i, sign))
    end
    return table.concat(lines, "\n")
end

-- The month from the console: 1 to 12, or a name (its first three letters
-- will do). nil if it's neither.
function TheContractorAuctionSigns.parseMonth(text)
    local number = tonumber(text)
    if number ~= nil then
        if number >= 1 and number <= 12 and number == math.floor(number) then
            return number
        end
        return nil
    end
    local prefix = string.sub(string.lower(text), 1, 3)
    for month, name in ipairs(MONTH_NAMES) do
        if name == prefix then
            return month
        end
    end
    return nil
end

-- Persistence -----------------------------------------------------------------------------------

function TheContractorAuctionSigns:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() or #self.signs == 0 then
        return
    end
    local key = TheContractor.SaveKey .. ".auctionSigns"
    setXMLInt(xmlFile, key .. "#month", self.month)
    for i, sign in ipairs(self.signs) do
        local signKey = string.format("%s.sign(%d)", key, i - 1)
        setXMLFloat(xmlFile, signKey .. "#x", sign.x)
        setXMLFloat(xmlFile, signKey .. "#z", sign.z)
        setXMLFloat(xmlFile, signKey .. "#yaw", sign.yaw)
    end
end

function TheContractorAuctionSigns:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctionSigns"
    local month = getXMLInt(xmlFile, key .. "#month")
    if month == nil or month < 1 or month > 12 then
        return
    end
    local signs = {}
    local i = 0
    while true do
        local signKey = string.format("%s.sign(%d)", key, i)
        if not hasXMLProperty(xmlFile, signKey) then
            break
        end
        local sign = {
            x = getXMLFloat(xmlFile, signKey .. "#x"),
            z = getXMLFloat(xmlFile, signKey .. "#z"),
            yaw = getXMLFloat(xmlFile, signKey .. "#yaw") or 0,
        }
        if sign.x ~= nil and sign.z ~= nil then
            table.insert(signs, sign)
        else
            TCLog.xmlWarning(xmlFile, "TheContractor: skipping auction sign %s", signKey)
        end
        i = i + 1
    end
    self:applySync(month, signs)
end

function TheContractorAuctionSigns:writeInitialClientState(streamId, connection)
    TCAuctionSignsEvent.writeSigns(streamId, self.month, self.signs)
end

function TheContractorAuctionSigns:readInitialClientState(streamId, connection)
    self:applySync(TCAuctionSignsEvent.readSigns(streamId))
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorAuctionSigns.registerConsoleCommands()
    TCConsole.register("company", "auctionSigns", {
        args = "[month|clear]",
        description = "Auction signs spike: put up signs at the map's busiest junctions for a month, or take them down",
        run = function(_, args)
            local signs = g_currentMission.TheContractor.AuctionSigns
            if args[1] == nil then
                return signs:describe()
            end
            if string.lower(args[1]) == "clear" and args[2] == nil then
                return signs:clear()
            end
            local month = TheContractorAuctionSigns.parseMonth(args[1])
            if month == nil or args[2] ~= nil then
                return false
            end
            return signs:place(month)
        end,
    })
end
