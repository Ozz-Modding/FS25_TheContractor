-- Protest outside the farm (151), a random event (068): a gimmick and a
-- minor annoyance, with no consequences. Locals stand in groups on the
-- roads near the farm's base, holding placards, from 07:00 to 19:00 for
-- one day. The local official (110) warns the farm the evening before.
--
-- When: about once every 24 months by chance (RATE_PER_PERIOD, no
-- cooldown, so two in a year can happen), rolled the evening before
-- (TRIGGER_HOURS) for the next day. Never in winter, never on a day an
-- auction's crowd is up (137: the sale day to its collection days, for the
-- frame rate), and never two on one day (any farm).
--
-- Where (pick): the farm's base, the middle of the farmland with most of
-- its own yard buildings (TCProtestLayout.findBase); GROUPS_MIN-GROUPS_MAX
-- groups on the road samples near it (TCProtestLayout.pickSpots), each a
-- round crowd on the road's middle (isSpotUsable rules out bridges, slopes
-- and walls). The farm with no buildings has no protest.
--
-- Stages: notice posts the official's warning (Show on map) and waits; the
-- server moves it on to out at TCProtestLayout.START_HOUR on the day and
-- closes it at END_HOUR (checkIncidents). Everyone's there while it's out. TCProtestCrowd shows the people, placards,
-- collision and map markers on every machine from the incident's synced
-- data while it's out.
--
-- tcEvent trigger protest now: the protest goes out today, straight away,
-- whatever the hour or season; it ends at the next day change (or tcDebug
-- protest clear).
--
-- State: none of its own. The incident's data is { day, seed, baseX,
-- baseZ, forced, groupCount, g<n>_x/_z/_dirX/_dirZ/_count }
-- (TCProtestLayout.getGroups).

TheContractorProtest = {}
TheContractorProtest_mt = Class(TheContractorProtest)

TheContractorProtest.EVENT_TYPE = "protest"
TheContractorProtest.MESSAGE_KIND = "protest"
TheContractorProtest.SHOW_ON_MAP_ACTION = { key = "showOnMap", textKey = "tc_protest_showOnMap" }

-- On average one every 24 months.
TheContractorProtest.RATE_PER_PERIOD = 1 / 24
-- Rolled at the day change, triggered (the warning) that evening.
TheContractorProtest.TRIGGER_HOURS = { 18, 21 }

TheContractorProtest.STAGE = {
    NOTICE = "notice",
    OUT = "out",
}
-- The warning stays in the inbox this many days.
TheContractorProtest.MESSAGE_DAYS = 2
TheContractorProtest.CHECK_INTERVAL_MS = 1000

-- A spot (isSpotUsable, metres; the road's middle): the spline within MAX_ROAD_HEIGHT_GAP of
-- the ground (else a bridge); the ground within MAX_GROUND_STEP of the
-- middle's GROUND_REACH along the road and either side; and nothing solid
-- (walls, buildings, trees) within ROOM_HALF_ACROSS of the middle,
-- ROOM_HALF_ALONG along it, ROOM_FLOOR to ROOM_TOP up.
TheContractorProtest.MAX_ROAD_HEIGHT_GAP = 1.5
TheContractorProtest.GROUND_REACH = 6
TheContractorProtest.MAX_GROUND_STEP = 1.0
TheContractorProtest.ROOM_HALF_ACROSS = 3
TheContractorProtest.ROOM_HALF_ALONG = 5
TheContractorProtest.ROOM_FLOOR = 0.3
TheContractorProtest.ROOM_TOP = 2.5
-- Seeds below 2^24, so they go over the wire (Float32) exactly.
TheContractorProtest.MAX_SEED = 9999999

local ROOM_MASK = CollisionFlag ~= nil and (CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING +
    CollisionFlag.TREE) or 0

function TheContractorProtest.new()
    local self = {}
    setmetatable(self, TheContractorProtest_mt)
    -- tcEvent trigger protest now: the next one goes out today. Server,
    -- not saved.
    self.consoleNow = false
    self.checkMs = 0
    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorProtest:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    local STAGE = TheContractorProtest.STAGE

    randomEvents:registerEventType(TheContractorProtest.EVENT_TYPE, {
        l10nKey = "tc_protest_eventName",
        ratePerPeriod = function(farmId)
            return TheContractorProtest.RATE_PER_PERIOD
        end,
        triggerHours = TheContractorProtest.TRIGGER_HOURS,
        canTrigger = function(farmId)
            return self:pick(farmId, math.random)
        end,
        -- tcEvent trigger protest [now]
        console = {
            details = "[now]",
            prepareTrigger = function(farmId, details, context)
                return self:prepareConsole(details)
            end,
            clearTrigger = function()
                self.consoleNow = false
            end,
        },
        stages = {
            { key = STAGE.NOTICE, run = function(incident)
                return self:onNotice(incident)
            end },
            { key = STAGE.OUT, run = function(incident)
                TCLog.info("TheContractor: farm %d incident %d: the protest is out", incident.farmId, incident.id)
                return TheContractorRandomEvents.WAIT
            end },
        },
    })

    inbox:registerMessageKind(TheContractorProtest.MESSAGE_KIND, {
        category = "message",
        chipTone = "warn",
        fromFarmer = true,
        getArgs = function(message)
            return TheContractorProtest.getMessageArgs(message)
        end,
        onClientAction = function(message, actionKey)
            if actionKey ~= TheContractorProtest.SHOW_ON_MAP_ACTION.key then
                return false
            end
            TCProtestCrowd.showOnMap(message.payload.incidentId)
            return true
        end,
    })
end

-- The warning's args, worked out live: the official's name as it is now.
function TheContractorProtest.getMessageArgs(message)
    local farmers = g_currentMission.TheContractor.Farmers
    local person = farmers ~= nil and farmers:getPerson(message.payload.farmerId) or nil
    return { person ~= nil and person.name or g_i18n:getText("tc_protest_councilName") }
end

-- tcEvent trigger protest [now]. Returns nil, or an error.
function TheContractorProtest:prepareConsole(details)
    if #details > 1 or (details[1] ~= nil and string.lower(details[1]) ~= "now") then
        return "Error: protest takes nothing or 'now'"
    end
    self.consoleNow = details[1] ~= nil
    return nil
end

-- Queries (every machine) ---------------------------------------------------------------

-- Every open protest incident (any farm), oldest first.
function TheContractorProtest.getIncidents()
    local tc = g_currentMission.TheContractor
    local result = {}
    if tc == nil or tc.RandomEvents == nil then
        return result
    end
    for _, incident in pairs(tc.RandomEvents.incidents) do
        if incident.eventType == TheContractorProtest.EVENT_TYPE then
            table.insert(result, incident)
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

function TheContractorProtest.isOut(incident)
    return incident.stage == TheContractorProtest.STAGE.OUT
end

-- Whether any farm has a protest on that day.
function TheContractorProtest.hasProtestOn(day)
    for _, incident in ipairs(TheContractorProtest.getIncidents()) do
        if incident.data.day == day then
            return true
        end
    end
    return false
end

-- Picking (server) ----------------------------------------------------------------------

-- The farm's own buildings, for TCProtestLayout.findBase: { farmlandId, x,
-- z, isYard }.
function TheContractorProtest.getFarmBuildings(farmId)
    local buildings = {}
    local placeableSystem = g_currentMission.placeableSystem
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        if not placeable.isDeleted and not placeable.isDeleting and placeable.getOwnerFarmId ~= nil and
                placeable:getOwnerFarmId() == farmId and placeable.getPosition ~= nil then
            local storeItem = placeable.storeItem
            local category = string.upper(storeItem ~= nil and storeItem.categoryName or "UNKNOWN")
            local x, _, z = placeable:getPosition()
            table.insert(buildings, {
                farmlandId = placeable.getFarmlandId ~= nil and placeable:getFarmlandId() or 0,
                x = x,
                z = z,
                isYard = TheContractorYards.isYardCategory(category),
            })
        end
    end
    return buildings
end

local function terrainY(x, z)
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
end

-- Whether a road sample will take a group (engine checks; see the header).
function TheContractorProtest.isSpotUsable(sample)
    local T = TheContractorProtest
    local y = terrainY(sample.x, sample.z)
    if math.abs(y - sample.y) > T.MAX_ROAD_HEIGHT_GAP then
        return false
    end
    local reach = T.GROUND_REACH
    local rightX, rightZ = sample.dirZ, -sample.dirX
    for _, offset in ipairs({ { reach, 0 }, { -reach, 0 }, { 0, reach * 0.5 }, { 0, -reach * 0.5 } }) do
        local x = sample.x + sample.dirX * offset[1] + rightX * offset[2]
        local z = sample.z + sample.dirZ * offset[1] + rightZ * offset[2]
        if math.abs(terrainY(x, z) - y) > T.MAX_GROUND_STEP then
            return false
        end
    end
    local target = { blocked = false }
    function target:onOverlap(node)
        if node ~= g_terrainNode then
            self.blocked = true
            return false
        end
        return true
    end
    local halfHeight = (T.ROOM_TOP - T.ROOM_FLOOR) * 0.5
    overlapBox(sample.x, y + T.ROOM_FLOOR + halfHeight, sample.z, 0,
        MathUtil.getYRotationFromDirection(sample.dirX, sample.dirZ), 0, T.ROOM_HALF_ACROSS, halfHeight,
        T.ROOM_HALF_ALONG, "onOverlap", target, ROOM_MASK, true, true, true, true)
    return not target.blocked
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

-- canTrigger (068): the incident's starting data, or nil. random is
-- math.random, or the tests' (random() and random(m, n)).
function TheContractorProtest:pick(farmId, random)
    local T = TheContractorProtest
    local L = TCProtestLayout
    local tc = g_currentMission.TheContractor
    local environment = g_currentMission.environment
    local forced = self.consoleNow == true
    local day = forced and getToday() or getToday() + 1

    if not forced and Season ~= nil and environment.getSeasonAtDay ~= nil and
            environment:getSeasonAtDay(day) == Season.WINTER then
        return nil
    end
    if T.hasProtestOn(day) then
        return nil
    end
    local auctions = tc.Auctions
    if auctions ~= nil and L.clashesWithAuction(day, auctions:getAuction(), TheContractorAuctions.COLLECTION_DAYS) then
        return nil
    end

    local baseX, baseZ = L.findBase(T.getFarmBuildings(farmId))
    if baseX == nil then
        return nil
    end
    local samples = TheContractorFallenTree.sampleRoads()
    local spots = L.pickSpots(samples, baseX, baseZ, random(L.GROUPS_MIN, L.GROUPS_MAX), T.isSpotUsable)
    if #spots == 0 then
        return nil
    end
    local groups = {}
    for _, spot in ipairs(spots) do
        table.insert(groups, L.makeGroup(spot, samples, baseX, baseZ, random(L.PEOPLE_MIN, L.PEOPLE_MAX)))
    end
    local data = {
        day = day,
        seed = random(1, T.MAX_SEED),
        baseX = baseX,
        baseZ = baseZ,
        forced = forced,
    }
    L.setGroups(data, groups)
    return data
end

-- Stages (server) -----------------------------------------------------------------------

function TheContractorProtest:onNotice(incident)
    if incident.data.forced then
        return TheContractorProtest.STAGE.OUT
    end
    local tc = g_currentMission.TheContractor
    local official = tc.Farmers ~= nil and tc.Farmers:getOfficial() or nil
    tc.Inbox:postMessage(incident.farmId, TheContractorProtest.MESSAGE_KIND, "tc_protest_noticeTitle",
        "tc_protest_noticeBody", {}, { TheContractorProtest.SHOW_ON_MAP_ACTION, TheContractorInbox.DISMISS_ACTION },
        { incidentId = incident.id, farmerId = official ~= nil and official.id or nil },
        TheContractorProtest.MESSAGE_DAYS)
    TCLog.info("TheContractor: farm %d incident %d: protest set for day %d, %d groups", incident.farmId, incident.id,
        incident.data.day, incident.data.groupCount or 0)
    return TheContractorRandomEvents.WAIT
end

-- What should happen to a protest now: "out" (go out), "close" or nil
-- (nothing), from the day and hour (pure).
function TheContractorProtest.getDue(incident, today, hour)
    local T = TheContractorProtest
    local data = incident.data
    if data.forced then
        return today > data.day and "close" or nil
    end
    if today > data.day or (today == data.day and hour >= TCProtestLayout.END_HOUR) then
        return "close"
    end
    if incident.stage == T.STAGE.NOTICE and today == data.day and hour >= TCProtestLayout.START_HOUR then
        return "out"
    end
    return nil
end

-- Server: moves protests on and ends them (every CHECK_INTERVAL_MS, so a
-- load or a skipped hour catches up).
function TheContractorProtest:checkIncidents()
    local today = getToday()
    local hour = g_currentMission.environment.currentHour or 0
    for _, incident in ipairs(TheContractorProtest.getIncidents()) do
        local due = TheContractorProtest.getDue(incident, today, hour)
        if due == "out" then
            self.randomEvents:goToStage(incident, TheContractorProtest.STAGE.OUT)
        elseif due == "close" then
            self:close(incident)
        end
    end
end

-- Ends a protest: the incident and its warning go.
function TheContractorProtest:close(incident)
    local inbox = g_currentMission.TheContractor.Inbox
    local ids = {}
    for id, message in pairs(inbox.messagesById) do
        if message.kind == TheContractorProtest.MESSAGE_KIND and message.payload.incidentId == incident.id then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        inbox:removeMessage(id)
    end
    TCLog.info("TheContractor: farm %d incident %d: the protest's over", incident.farmId, incident.id)
    self.randomEvents:closeIncident(incident)
end

function TheContractorProtest:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    self.checkMs = self.checkMs + dt
    if self.checkMs < TheContractorProtest.CHECK_INTERVAL_MS then
        return
    end
    self.checkMs = 0
    self:checkIncidents()
end

-- Console --------------------------------------------------------------------------------

function TheContractorProtest.registerConsoleCommands()
    TCConsole.register("debug", "protest", {
        args = "[clear]",
        description = "Protests: where they are and how the crowd's doing on this machine, or end them all",
        run = function(_, args)
            local protest = g_currentMission.TheContractor.Protest
            if args[1] ~= nil then
                if string.lower(args[1]) ~= "clear" then
                    return false
                end
                local incidents = TheContractorProtest.getIncidents()
                for _, incident in ipairs(incidents) do
                    protest:close(incident)
                end
                return string.format("%d protest(s) ended.", #incidents)
            end
            local lines = {}
            for _, incident in ipairs(TheContractorProtest.getIncidents()) do
                local data = incident.data
                table.insert(lines, string.format("Incident %d, farm %d: %s, day %d%s, base %.0f %.0f, seed %d",
                    incident.id, incident.farmId, incident.stage, data.day, data.forced and " (forced)" or "",
                    data.baseX or 0, data.baseZ or 0, data.seed or 0))
                for n, group in ipairs(TCProtestLayout.getGroups(data)) do
                    table.insert(lines, string.format("  group %d: %d people round %.1f %.1f (%.1f m across), base's way %.2f %.2f, %s",
                        n, group.count or 0, group.x or 0, group.z or 0, 2 * TCProtestLayout.getRadius(group.count or 0),
                        group.dirX or 0, group.dirZ or 0,
                        group.paired and "between the road's two lanes" or "on a lone spline (no other lane found)"))
                end
            end
            if #lines == 0 then
                table.insert(lines, "No protest set or out.")
            end
            table.insert(lines, TCProtestCrowd.describe())
            return table.concat(lines, "\n")
        end,
    })
    TCConsole.register("debug", "protestShow", {
        args = "",
        description = "Draw the protest's collision blocks' outlines on this machine, or stop",
        serverOnly = false,
        run = function()
            TCProtestCrowd.showBlocks = not TCProtestCrowd.showBlocks
            return TCProtestCrowd.showBlocks and
                "Showing the protest's blocks: people's in yellow, crowds' in red (only those that are down)." or
                "Not showing the protest's blocks."
        end,
    })
    TCConsole.register("debug", "protestPlacard", {
        args = "[rot|pos <x y z>]",
        description = "How protesters hold their placards: the grip's rotation (degrees) or place (metres) against the hand (this machine only)",
        serverOnly = false,
        run = function(_, args)
            local g = TCProtestCrowd.GRIP
            if #args == 0 then
                return string.format("Placard grip: rot %.1f %.1f %.1f, pos %.3f %.3f %.3f", g[4], g[5], g[6],
                    g[1], g[2], g[3])
            end
            local which = string.lower(args[1])
            local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
            if (which ~= "rot" and which ~= "pos") or #args ~= 4 or x == nil or y == nil or z == nil then
                return false
            end
            local grip = { g[1], g[2], g[3], g[4], g[5], g[6] }
            local first = which == "pos" and 1 or 4
            grip[first], grip[first + 1], grip[first + 2] = x, y, z
            TCProtestCrowd.GRIP = grip
            return string.format("Placard grip now rot %.1f %.1f %.1f, pos %.3f %.3f %.3f (%d placards moved)",
                grip[4], grip[5], grip[6], grip[1], grip[2], grip[3], TCProtestCrowd.regrip())
        end,
    })
end
