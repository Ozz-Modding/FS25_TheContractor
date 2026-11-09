-- Fly-tipping (075), a random event (068): someone has dumped a pile of
-- junk, either just inside an NPC's field by the gate (the farmer offers
-- the job) or on a road's verge (148: the local official offers it, for the
-- council). The player carries the pieces (TCDebris) to a skip the farm has
-- placed (PlaceableTCDisposalSkip), where they disappear. Each piece from a
-- job costs a small tipping fee.
--
-- Which (pick): ROADSIDE_SHARE of hits go to a verge, the rest to a field;
-- if the one rolled has nowhere to go, the other is tried. The console can
-- ask for either, and then gets only that one.
--
-- Which fields (getEligibleFields): owned by nobody (an NPC's) and with no
-- live job for any farm on it. Never the farm's own, never another
-- player's. Any season.
--
-- Which verges (findRoadsideSpot, 148): points on AI road splines
-- (TheContractorFallenTree.sampleRoads), in random order, the pile
-- VERGE_OFFSET out from the road's middle on a random side. Skipped on a
-- bridge, where the verge drops or rises too far from the road (a ditch, a
-- bank), where the ground under the pile isn't flat, near another road (a
-- junction), where anything's in the way (walls, hedges, buildings,
-- vehicles, players), with a player within MIN_PLAYER_DISTANCE (nobody sees
-- it appear), or with no field without a live job within the fallen tree's
-- MAX_FIELD_DISTANCE: the nearest names the job ("Roadside by Field 12")
-- and is its field, nothing more (JOB_TYPES' flyTippingRoadside is
-- offField, so the official is its customer, 110). No ruts, and the pieces'
-- own map markers show where it is. Turned down or left to lapse, it costs
-- a little reputation (JOB_TYPES' declineReputation) as well as the usual
-- relationship knock with the official.
--
-- The job (JobGeneration's flyTipping type) is due this month, like 072's
-- plow job, priced per piece. Its pieces are tracked by item uniqueId in
-- job.debrisIds, server-only and saved; taking one to a skip counts it
-- (job.debrisDisposed) and TCJobProgress measures the rest. Whatever's left
-- of the pile goes when the job's over (TCFieldPreparation.clearUpAfterJob),
-- or when the offer is declined or runs out.
--
-- State: none of its own. The incident's data is { fieldId }, plus
-- roadside, x, z for a verge (148).

TheContractorFlyTipping = {}
TheContractorFlyTipping_mt = Class(TheContractorFlyTipping)

TheContractorFlyTipping.EVENT_TYPE = "flyTipping"
TheContractorFlyTipping.MESSAGE_KIND = "flyTipping"
-- 112: the body that ends with the customer's name (getCustomerNamedArgs).
TheContractorFlyTipping.NAMED_BODY_KEYS = { tc_flyTipping_offerBody = true }
TheContractorFlyTipping.JOB_TYPE = "flyTipping"
-- 148: the same on a road's verge, for the council.
TheContractorFlyTipping.ROADSIDE_JOB_TYPE = "flyTippingRoadside"
TheContractorFlyTipping.NAMED_BODY_KEYS.tc_flyTipping_roadsideOfferBody = true

-- 148: the share of hits that go to a verge rather than a field.
TheContractorFlyTipping.ROADSIDE_SHARE = 0.5
-- The console's names for the two (tcEvent trigger flyTipping [field|road]).
TheContractorFlyTipping.SITES = { field = "field", road = "road" }

-- About one every couple of years, like joyriders: it's the area's fields
-- that get hit, not the farm's.
TheContractorFlyTipping.RATE_PER_PERIOD = 0.04
TheContractorFlyTipping.COOLDOWN_PERIODS = 4

TheContractorFlyTipping.MIN_PIECES = 10
TheContractorFlyTipping.MAX_PIECES = 30

-- Where the pile lands: TCJoyriderRuts.planDumpSite's spot 4-7 m in from
-- the field's edge, by its gate where it can, with the van's ruts painted in
-- to it and the ground churned up under it, so it can be found from the
-- edge. A field without a boundary falls back to GATE_INSET in from its
-- gate (its teleport point) towards its middle. Metres.
TheContractorFlyTipping.GATE_INSET = 6

-- Per job piece taken to a skip, 1x UK (a landfill gate fee's share for a
-- bulky item), charged through scaleCost. An old ADS part (103) costs the
-- same.
TheContractorFlyTipping.TIPPING_FEE = 5

-- 148: finding a verge (see the header). Metres.
TheContractorFlyTipping.SPOT_TRIES = 120
-- The pile's middle from the road's middle, and how close it may be to any
-- road's middle (a junction's other road).
TheContractorFlyTipping.VERGE_OFFSET = 6
TheContractorFlyTipping.MIN_ROAD_DISTANCE = 5
-- The ground under the spline (a bridge if further), and the verge's
-- against the road's (a ditch or a bank if further).
TheContractorFlyTipping.MAX_ROAD_HEIGHT_GAP = 1.5
TheContractorFlyTipping.MAX_VERGE_STEP = 1
-- The pile's footprint (half its side) and how flat it must be under it.
TheContractorFlyTipping.PILE_HALF_SIZE = 2
TheContractorFlyTipping.MAX_PILE_SLOPE = 0.6
-- The room it needs above the ground.
TheContractorFlyTipping.ROOM_FLOOR = 0.3
TheContractorFlyTipping.ROOM_TOP = 2.5
TheContractorFlyTipping.MIN_PLAYER_DISTANCE = 150

table.insert(FinanceStats.statNames, "tcWasteDisposal")
FinanceStats.statNameToIndex["tcWasteDisposal"] = #FinanceStats.statNames

function TheContractorFlyTipping.new()
    local self = {}
    setmetatable(self, TheContractorFlyTipping_mt)

    MoneyType.TC_WASTE_DISPOSAL = MoneyType.register("tcWasteDisposal", "tc_moneyType_wasteDisposal")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFlyTipping:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorFlyTipping.EVENT_TYPE, {
        l10nKey = "tc_flyTipping_eventName",
        cooldownPeriods = TheContractorFlyTipping.COOLDOWN_PERIODS,
        ratePerPeriod = function(farmId)
            return TheContractorFlyTipping.RATE_PER_PERIOD
        end,
        canTrigger = function(farmId)
            return self:pick(farmId, math.random)
        end,
        -- tcEvent trigger flyTipping [field|road]
        console = {
            details = "[field|road]",
            prepareTrigger = function(farmId, details, context)
                return self:prepareConsole(details)
            end,
            clearTrigger = function()
                self.consoleSite = nil
            end,
        },
        stages = {
            { key = "dump", run = function(incident)
                return self:onDump(incident)
            end },
        },
    })

    inbox:registerMessageKind(TheContractorFlyTipping.MESSAGE_KIND, {
        category = "job",
        endsWithJob = true,
        chipTone = "bad",
        -- 112: the offer names the farmer.
        getArgs = function(message)
            return TheContractorInbox.getCustomerNamedArgs(message, TheContractorFlyTipping.NAMED_BODY_KEYS)
        end,
    })
end

-- Fields (server) -------------------------------------------------------------------

function TheContractorFlyTipping:getEligibleFields(farmId)
    local result = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, field in ipairs(g_fieldManager:getFields()) do
        local fieldId = field:getId()
        if fieldId ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
            not jobs:isFieldProtected(fieldId) then
            table.insert(result, field)
        end
    end
    return result
end

-- A random eligible field's data, or nil.
function TheContractorFlyTipping:pickField(farmId)
    local fields = self:getEligibleFields(farmId)
    if #fields == 0 then
        return nil
    end
    return { fieldId = fields[math.random(1, #fields)]:getId() }
end

-- tcEvent trigger flyTipping [field|road]. Returns nil, or an error.
function TheContractorFlyTipping:prepareConsole(details)
    local site = details[1] ~= nil and TheContractorFlyTipping.SITES[string.lower(details[1])] or nil
    if #details > 1 or (details[1] ~= nil and site == nil) then
        return "Error: flyTipping takes nothing, 'field' or 'road'"
    end
    self.consoleSite = site
    return nil
end

-- canTrigger (068): the incident's starting data, or nil. ROADSIDE_SHARE
-- of the time a verge, else a field, falling back to the other (148). The
-- console's choice has no fallback. random is for the tests.
function TheContractorFlyTipping:pick(farmId, random)
    if not TCDebris.hasRandomProps() then
        return nil
    end
    local SITES = TheContractorFlyTipping.SITES
    local first = self.consoleSite
    if first == nil then
        first = random() < TheContractorFlyTipping.ROADSIDE_SHARE and SITES.road or SITES.field
    end
    local order = { first }
    if self.consoleSite == nil then
        table.insert(order, first == SITES.road and SITES.field or SITES.road)
    end
    for _, site in ipairs(order) do
        local data
        if site == SITES.road then
            data = self:pickRoadside(random)
        else
            data = self:pickField(farmId)
        end
        if data ~= nil then
            return data
        end
    end
    return nil
end

-- Verges (server, 148) -----------------------------------------------------------------

-- The distance from (x, z) to the nearest road's middle, each sample
-- standing for the stretch of road ROAD_SAMPLE_STEP long through it.
function TheContractorFlyTipping.getRoadDistance(x, z, samples)
    local halfStep = TheContractorFallenTree.ROAD_SAMPLE_STEP * 0.5
    local best = math.huge
    for _, sample in ipairs(samples) do
        local dx, dz = x - sample.x, z - sample.z
        local along = math.max(-halfStep, math.min(halfStep, dx * sample.dirX + dz * sample.dirZ))
        local ex, ez = dx - sample.dirX * along, dz - sample.dirZ * along
        best = math.min(best, math.sqrt(ex * ex + ez * ez))
    end
    return best
end

-- Whether the ground under the pile is flat: each corner of its footprint
-- within MAX_PILE_SLOPE of its middle.
function TheContractorFlyTipping.isGroundFlat(x, z)
    local T = TheContractorFlyTipping
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local h = T.PILE_HALF_SIZE
    for _, corner in ipairs({ { -h, -h }, { h, -h }, { h, h }, { -h, h } }) do
        local cornerY = getTerrainHeightAtWorldPos(g_terrainNode, x + corner[1], 0, z + corner[2])
        if math.abs(cornerY - y) > T.MAX_PILE_SLOPE then
            return false
        end
    end
    return true
end

-- Whether nothing's in the pile's way: static objects, buildings, trees,
-- vehicles, traffic, dynamic objects, players (the terrain and the road
-- aren't in it).
function TheContractorFlyTipping.hasRoom(x, z, rotY)
    local T = TheContractorFlyTipping
    local mask = CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING + CollisionFlag.TREE +
        CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TRAFFIC_VEHICLE + CollisionFlag.PLAYER
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local halfHeight = (T.ROOM_TOP - T.ROOM_FLOOR) * 0.5
    local target = { blocked = false }
    function target:onOverlap(node)
        if node ~= g_terrainNode then
            self.blocked = true
            return false
        end
        return true
    end
    overlapBox(x, y + T.ROOM_FLOOR + halfHeight, z, 0, rotY, 0, T.PILE_HALF_SIZE, halfHeight, T.PILE_HALF_SIZE,
        "onOverlap", target, mask, true, true, true, true)
    return not target.blocked
end

local function isNearAny(x, z, points, distance)
    for _, point in ipairs(points) do
        local dx, dz = x - point.x, z - point.z
        if dx * dx + dz * dz < distance * distance then
            return true
        end
    end
    return false
end

-- A verge that will do (see the header), as { x, z, fieldId }, or nil.
-- random is for the tests.
function TheContractorFlyTipping.findRoadsideSpot(random)
    local T = TheContractorFlyTipping
    local samples = TheContractorFallenTree.sampleRoads()
    local order = {}
    for i = 1, #samples do
        order[i] = samples[i]
    end
    for i = #order, 2, -1 do
        local j = math.min(i, math.floor(random() * i) + 1)
        order[i], order[j] = order[j], order[i]
    end

    local players = TheContractorFallenTree.getPlayerPositions()
    for i = 1, math.min(T.SPOT_TRIES, #order) do
        local sample = order[i]
        local side = random() < 0.5 and -1 or 1
        -- Square off the road, to one side.
        local x = sample.x - sample.dirZ * side * T.VERGE_OFFSET
        local z = sample.z + sample.dirX * side * T.VERGE_OFFSET
        local roadY = getTerrainHeightAtWorldPos(g_terrainNode, sample.x, 0, sample.z)
        local vergeY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        if math.abs(roadY - sample.y) <= T.MAX_ROAD_HEIGHT_GAP and
                math.abs(vergeY - roadY) <= T.MAX_VERGE_STEP and
                not isNearAny(x, z, players, T.MIN_PLAYER_DISTANCE) and
                T.getRoadDistance(x, z, samples) >= T.MIN_ROAD_DISTANCE and
                T.isGroundFlat(x, z) and
                T.hasRoom(x, z, MathUtil.getYRotationFromDirection(sample.dirX, sample.dirZ)) then
            local field = TheContractorFallenTree.findNearestField(x, z)
            if field ~= nil then
                return { x = x, z = z, fieldId = field:getId() }
            end
        end
    end
    return nil
end

-- A verge's data, or nil.
function TheContractorFlyTipping:pickRoadside(random)
    local spot = TheContractorFlyTipping.findRoadsideSpot(random)
    if spot == nil then
        return nil
    end
    return { fieldId = spot.fieldId, roadside = true, x = spot.x, z = spot.z }
end

-- The fallback spot (see GATE_INSET): in from the field's gate towards its
-- middle (or halfway there, on a field that small).
function TheContractorFlyTipping.getDumpSpot(field)
    local gateX, gateZ = field:getTeleportPosition()
    local centreX, centreZ = field:getCenterOfFieldWorldPosition()
    local dx, dz = centreX - gateX, centreZ - gateZ
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 0.01 then
        return gateX, gateZ
    end
    local inset = math.min(TheContractorFlyTipping.GATE_INSET, distance * 0.5)
    return gateX + dx / distance * inset, gateZ + dz / distance * inset
end

-- Stages (server) ---------------------------------------------------------------------

function TheContractorFlyTipping:onDump(incident)
    local tc = g_currentMission.TheContractor
    local data = incident.data
    local field = g_fieldManager:getFieldById(data.fieldId)
    -- Someone may have taken a job on it since the roll (a load in between).
    if field == nil or tc.Jobs:isFieldProtected(data.fieldId) then
        return TheContractorRandomEvents.DONE
    end

    local count = math.random(TheContractorFlyTipping.MIN_PIECES, TheContractorFlyTipping.MAX_PIECES)
    local x, z
    if data.roadside then
        -- 148: on the verge, as found. No ruts.
        x, z = data.x, data.z
    else
        local site = TCJoyriderRuts.paintDumpSite(field)
        if site ~= nil then
            x, z = site.x, site.z
        else
            x, z = TheContractorFlyTipping.getDumpSpot(field)
        end
    end
    local pieces = TCDebris.spawnPileAt(x, z, count, incident.farmId)
    if #pieces == 0 then
        return TheContractorRandomEvents.DONE
    end

    local jobType = data.roadside and TheContractorFlyTipping.ROADSIDE_JOB_TYPE or TheContractorFlyTipping.JOB_TYPE
    local job = tc.JobGeneration:createJobOnField(incident.farmId, jobType, field, true, #pieces)
    if job == nil then
        for _, debris in ipairs(pieces) do
            debris:delete()
        end
        TCLog.info("TheContractor: farm %d incident %d: fly-tipping by field %d, but no job could be dated",
            incident.farmId, incident.id, data.fieldId)
        return TheContractorRandomEvents.DONE
    end
    for _, debris in ipairs(pieces) do
        table.insert(job.debrisIds, debris:getUniqueId())
    end
    job.workTotal = #pieces

    local titleKey, bodyKey = "tc_flyTipping_offerTitle", "tc_flyTipping_offerBody"
    if data.roadside then
        titleKey, bodyKey = "tc_flyTipping_roadsideOfferTitle", "tc_flyTipping_roadsideOfferBody"
    end
    tc.Inbox:postMessage(incident.farmId, TheContractorFlyTipping.MESSAGE_KIND, titleKey,
        bodyKey, { data.fieldId, #pieces }, nil,
        { incidentId = incident.id, jobId = job.id })
    TCLog.info("TheContractor: farm %d incident %d: %d pieces fly-tipped %s field %d, job %d offered",
        incident.farmId, incident.id, #pieces, data.roadside and "on the verge by" or "on", data.fieldId, job.id)
    return TheContractorRandomEvents.DONE
end

-- Disposal (server) -------------------------------------------------------------------

-- The live (not finished) job a piece of debris belongs to, or nil.
function TheContractorFlyTipping:getJobForDebris(debris)
    local uniqueId = debris:getUniqueId()
    if uniqueId == nil then
        return nil, nil
    end
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(g_currentMission.TheContractor.Jobs:getAllJobs(farm.farmId)) do
            if job.debrisIds ~= nil and not job:isTerminal() then
                for i, id in ipairs(job.debrisIds) do
                    if id == uniqueId then
                        return job, i
                    end
                end
            end
        end
    end
    return nil, nil
end

-- The tipping fee for one piece, at today's prices.
function TheContractorFlyTipping.getTippingFee()
    return g_currentMission.TheContractor.Settings:scaleCost(TheContractorFlyTipping.TIPPING_FEE)
end

-- A skip took a piece: it counts towards its job (and costs the job's farm
-- the tipping fee), then it's gone. Debris from no job goes for nothing.
function TheContractorFlyTipping:disposeDebris(debris)
    local job, index = self:getJobForDebris(debris)
    if job ~= nil then
        table.remove(job.debrisIds, index)
        job.debrisDisposed = job.debrisDisposed + 1
        local fee = TheContractorFlyTipping.getTippingFee()
        if fee > 0 then
            g_currentMission:addMoney(-fee, job.farmId, MoneyType.TC_WASTE_DISPOSAL, true, true)
            g_currentMission.TheContractor.Finances:recordDisposal(job.farmId, fee)
        end
        TCLog.info("TheContractor: farm %d job %d: debris taken to a skip (%d taken, %d left), fee %.0f",
            job.farmId, job.id, job.debrisDisposed, #job.debrisIds, fee)
    end
    debris:delete()
    return job
end

-- A skip took an old part a replacement left (103, TCADSStock.isUsedPart):
-- its owner pays the tipping fee, then it's gone. Selling it to a dealer
-- through ADS stays the other way out. Returns the fee charged.
function TheContractorFlyTipping:disposeUsedPart(part)
    local farmId = part.getOwnerFarmId ~= nil and part:getOwnerFarmId() or nil
    local fee = 0
    if farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID then
        fee = TheContractorFlyTipping.getTippingFee()
        if fee > 0 then
            g_currentMission:addMoney(-fee, farmId, MoneyType.TC_WASTE_DISPOSAL, true, true)
            g_currentMission.TheContractor.Finances:recordDisposal(farmId, fee)
        end
    end
    TCLog.info("TheContractor: farm %s: old part %s taken to a skip, fee %.0f", tostring(farmId),
        part.getName ~= nil and part:getName() or "?", fee)
    part:delete()
    return fee
end
