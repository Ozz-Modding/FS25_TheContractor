-- Spilt crop (106): when 105's hauler tips their trailer over on the last
-- load, in the field, its load pours out of its top beside it, and the farm
-- has to put it right. The crop is tipped there (DensityMapHeightUtil's
-- tipToGroundAroundLine, as vanilla's own heaps are), and the farm gets an
-- urgent follow-on job, accepted and allocated to its players at once: get
-- the crop to the customer's selling point by the end of tomorrow. It pays
-- nothing.
--
--   done     DELIVERY_SHARE of what was spilt delivered, from anywhere: the
--            tracker counts the crop by fill type and farm, as 067's straw
--            does, so the farm's own stores can make it up. Whatever's left
--            of the heap is cleared away.
--   missed   a heavy reputation loss (the spill's reputationPenalty, set at
--            the spill, nothing taken off for what was delivered) and, at
--            CLAIM_CHANCE, a liability claim (052) for the crop that never
--            arrived plus the farmer's clear-up. The heap is cleared away.
--
-- The field is the customer's, not the farm's, and vanilla only lets a
-- shovel pick up, a bucket or trailer tip to the ground, or a leveler push,
-- on land the farm can work. While a spill job is allocated, its site
-- circle counts as the farm's for those three (the hooks at the end of this
-- file). Every machine works that out from its own copy of the job
-- (refreshSites).
--
-- No state of its own: everything lives on the job (job.spill, saved and
-- streamed): fillTypeName, liters (what landed), the site circle (x, z,
-- radius), pricePerLiter (the selling point's, the day of the spill),
-- reputationPenalty, sourceJobId and incidentId.

TheContractorCropSpill = {}
TheContractorCropSpill_mt = Class(TheContractorCropSpill)

TheContractorCropSpill.JOB_TYPE = "spillRecovery"
TheContractorCropSpill.MESSAGE_KIND = "cropSpill"

-- Of the trailer's capacity for the crop, never more than MAX_LITERS (a
-- big trailer's load would bury the place). Next to nothing landing is no
-- spill at all.
TheContractorCropSpill.SPILL_SHARE = 0.9
TheContractorCropSpill.MAX_LITERS = 12000
TheContractorCropSpill.MIN_LITERS = 500

-- Delivered to call it done, of what was spilt.
TheContractorCropSpill.DELIVERY_SHARE = 0.8

-- Where it goes, in metres. The heap's line runs HEAP_GAP past the
-- trailer's top, along HEAP_LINE_SHARE of its length, and the site (the
-- access circle) reaches SITE_MARGIN past the line's ends and however far
-- the crop can have spread (getSiteRadius).
TheContractorCropSpill.HEAP_GAP = 1.5
TheContractorCropSpill.HEAP_LINE_SHARE = 0.8
TheContractorCropSpill.SITE_MARGIN = 8
-- Calls to tip it before giving up on the rest.
TheContractorCropSpill.TIP_ATTEMPTS = 20

-- Missed: this many times the harvest job's base reputation reward, never
-- less than the minimum.
TheContractorCropSpill.REPUTATION_PENALTY_MULTIPLIER = 2
TheContractorCropSpill.MIN_REPUTATION_PENALTY = 20
TheContractorCropSpill.CLAIM_CHANCE = 0.5
-- The farmer clearing up what's left in their field, 1x UK (scaleCost).
TheContractorCropSpill.CLEANUP_COST = 400

TheContractorCropSpill.SITE_REFRESH_MS = 1000

-- farmId -> { { x, z, radiusSq }, ... }, every machine (refreshSites).
local sitesByFarm = {}

function TheContractorCropSpill.new()
    local self = {}
    setmetatable(self, TheContractorCropSpill_mt)

    self.refreshMs = 0
    -- Server, not saved: the next missed spill's claim forced from the
    -- console (true: a claim, false: none), read once.
    self.forcedClaim = nil

    sitesByFarm = {}
    return self
end

-- Every machine, at load.
function TheContractorCropSpill:register(inbox)
    inbox:registerMessageKind(TheContractorCropSpill.MESSAGE_KIND, {
        category = "claim",
        chipTone = "bad",
    })
end

-- 105's console: tcDebug outcome tippedTrailer claim|noClaim.
function TheContractorCropSpill:setForcedClaim(isClaim)
    self.forcedClaim = isClaim
end

-- The spill (server) ---------------------------------------------------------------

-- Where it all goes for a trailer laid at 105's spot (data: x, z, dirX,
-- dirZ, sideX, sideZ: its wheels, and its top toward sideX/Z, its height
-- away): the heap's line and the site. size is vehicle.size.
function TheContractorCropSpill.planSpill(data, size)
    local T = TheContractorCropSpill
    local length = size.length or 8
    local across = (size.height or 3) + T.HEAP_GAP
    local heapX, heapZ = data.x + data.sideX * across, data.z + data.sideZ * across
    local halfLine = length * T.HEAP_LINE_SHARE * 0.5
    return {
        heapStartX = heapX - data.dirX * halfLine,
        heapStartZ = heapZ - data.dirZ * halfLine,
        heapEndX = heapX + data.dirX * halfLine,
        heapEndZ = heapZ + data.dirZ * halfLine,
        x = heapX,
        z = heapZ,
        radius = halfLine + T.SITE_MARGIN,
    }
end

-- The trailer's biggest fill unit for the crop, or 0.
function TheContractorCropSpill.getCapacity(trailer, fillTypeIndex)
    local fillUnits = trailer.spec_fillUnit ~= nil and trailer.spec_fillUnit.fillUnits or {}
    local capacity = 0
    for index in ipairs(fillUnits) do
        if trailer:getFillUnitSupportsFillType(index, fillTypeIndex) then
            capacity = math.max(capacity, trailer:getFillUnitCapacity(index) or 0)
        end
    end
    return capacity
end

function TheContractorCropSpill.getSpillLiters(capacity)
    return math.min(capacity * TheContractorCropSpill.SPILL_SHARE, TheContractorCropSpill.MAX_LITERS)
end

-- How it's tipped, tried in turn, each taking whatever's still to land:
-- a natural heap by the trailer's top kept out from under vehicles (their
-- tip occlusion areas), the same without (a trailer's area is built for it
-- upright, so lying on its side it can cover the line), then as Easy Dev
-- Controls' tip anywhere does it, spread wide so the game finds ground that
-- takes a heap. In game (2026-10-27), on a road's verge, the first two
-- landed nothing while the wide spread put it all down beside the road
-- (it's in the field now, where a heap is happy to lie).
-- innerRadius/radius are tipToGroundAroundLine's, in metres.
TheContractorCropSpill.TIP_STEPS = {
    { innerRadius = 0, radius = 6, useOcclusionAreas = true },
    { innerRadius = 0, radius = 6, useOcclusionAreas = false },
    { innerRadius = 10, radius = 40, useOcclusionAreas = false },
}

-- Tips it along the plan's line, a share at a time as vanilla's heap
-- spawners do, through TIP_STEPS until it's all down. Returns the litres
-- that landed and how far from the line they can have spread (the widest
-- step that put anything down). Engine side, replaced in the tests.
function TheContractorCropSpill.tipHeap(fillTypeIndex, liters, plan)
    local tipped, reach = 0, 0
    for i, step in ipairs(TheContractorCropSpill.TIP_STEPS) do
        if liters - tipped < 1 then
            break
        end
        local landed = TheContractorCropSpill.tipAlongLine(fillTypeIndex, liters - tipped, plan, step)
        TCLog.info("TheContractor: spill step %d (inner %d m, radius %d m, %s): %.0f of %.0f l landed", i,
            step.innerRadius, step.radius, step.useOcclusionAreas and "off vehicles" or "anywhere", landed,
            liters - tipped)
        if landed > 0 then
            tipped = tipped + landed
            reach = math.max(reach, step.radius)
        end
    end
    return tipped, reach
end

function TheContractorCropSpill.tipAlongLine(fillTypeIndex, liters, plan, step)
    local sx, sz, ex, ez = plan.heapStartX, plan.heapStartZ, plan.heapEndX, plan.heapEndZ
    local sy = getTerrainHeightAtWorldPos(g_terrainNode, sx, 0, sz)
    local ey = getTerrainHeightAtWorldPos(g_terrainNode, ex, 0, ez)
    local tipped, lineOffset = 0, 0
    for _ = 1, TheContractorCropSpill.TIP_ATTEMPTS do
        local remaining = liters - tipped
        if remaining < 1 then
            break
        end
        local dropped, offset = DensityMapHeightUtil.tipToGroundAroundLine(nil, remaining, fillTypeIndex, sx, sy, sz,
            ex, ey, ez, step.innerRadius, step.radius, lineOffset, false, nil, step.useOcclusionAreas)
        lineOffset = offset or lineOffset
        if dropped == nil or dropped <= 0 then
            break
        end
        tipped = tipped + dropped
    end
    return tipped
end

-- The site's radius once the heap's down: the planned one, or out to the
-- heap line's ends plus how far it can have spread, whichever's bigger.
function TheContractorCropSpill.getSiteRadius(plan, reach)
    local dx, dz = plan.heapEndX - plan.x, plan.heapEndZ - plan.z
    return math.max(plan.radius, math.sqrt(dx * dx + dz * dz) + (reach or 0))
end

-- Whether the crop can lie on the ground at all. Engine side, replaced in
-- the tests.
function TheContractorCropSpill.canTip(fillTypeIndex)
    return DensityMapHeightUtil ~= nil and DensityMapHeightUtil.getCanTipToGround(fillTypeIndex)
end

-- The selling point's price per litre today, or 0.
function TheContractorCropSpill.getPricePerLiter(station, fillTypeIndex)
    if station == nil or station.getEffectiveFillTypePrice == nil then
        return 0
    end
    return station:getEffectiveFillTypePrice(fillTypeIndex) or 0
end

-- From 105's onTipped, once the trailer (and its tractor) are down. Tips
-- the load and makes the job, accepted and allocated to the farm's
-- players. Returns the job, or nil with no spill (no crop, one that can't
-- lie on the ground, nowhere to deliver it, or next to nothing landing).
function TheContractorCropSpill:spill(farmId, sourceJob, trailer, data, incidentId)
    local tc = g_currentMission.TheContractor
    local T = TheContractorCropSpill
    -- Rare enough, and puzzling enough when it happens, that why there's no
    -- spill is always logged.
    local function noSpill(fmt, ...)
        TCLog.warning("TheContractor: farm %d job %s: no spill from the tipped trailer: " .. fmt, farmId,
            tostring(sourceJob ~= nil and sourceJob.id or nil), ...)
        return nil
    end

    if sourceJob == nil then
        return noSpill("the harvest job is gone")
    end
    local fillTypeIndex = TCHaulage.getDeliveryFillType(sourceJob)
    if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        return noSpill("no crop recorded on it (%s, crop '%s')", tostring(sourceJob.jobType),
            tostring(sourceJob.fruitTypeName))
    end
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    if not T.canTip(fillTypeIndex) then
        return noSpill("%s can't lie on the ground", tostring(fillTypeName))
    end
    local station = TCHaulage.resolveDeliveryStation(sourceJob) or TCHaulage.findDeliveryStation(fillTypeIndex)
    if station == nil then
        return noSpill("nowhere takes %s", tostring(fillTypeName))
    end
    local capacity = T.getCapacity(trailer, fillTypeIndex)
    local liters = T.getSpillLiters(capacity)
    if liters < T.MIN_LITERS then
        return noSpill("the %s holds only %.0f l of %s", trailer:getFullName(), capacity, tostring(fillTypeName))
    end

    local plan = T.planSpill(data, trailer.size or {})
    local tipped, reach = T.tipHeap(fillTypeIndex, liters, plan)
    if tipped < T.MIN_LITERS then
        return noSpill("only %.0f of %.0f l of %s would lie on the ground at %.0f, %.0f", tipped, liters,
            tostring(fillTypeName), plan.x, plan.z)
    end

    local spill = {
        fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex),
        liters = tipped,
        x = plan.x,
        z = plan.z,
        radius = T.getSiteRadius(plan, reach),
        pricePerLiter = T.getPricePerLiter(station, fillTypeIndex),
        reputationPenalty = math.floor(math.max(T.MIN_REPUTATION_PENALTY,
            TheContractorJobs.getBaseReputationReward(sourceJob) * T.REPUTATION_PENALTY_MULTIPLIER)),
        sourceJobId = sourceJob.id,
        incidentId = incidentId or 0,
    }

    local environment = g_currentMission.environment
    local deadlineDay = environment.currentMonotonicDay + 1
    local job = tc.Jobs:createJob(farmId, T.JOB_TYPE, sourceJob.fieldId, 1, TCCalendar.getPeriodFromDay(deadlineDay),
        TCCalendar.getDayInPeriodFromDay(deadlineDay), 0, true, sourceJob.fruitTypeName, deadlineDay, true, station,
        nil, nil, spill)
    if job == nil then
        return nil
    end
    tc.Jobs:transitionJobState(farmId, job.id, TheContractorJob.STATE.ACCEPTED)
    if not tc.Allocation:allocateJob(farmId, job.id, {}, {}, {}, nil, nil) then
        TCLog.warning("TheContractor: farm %d spill job %d couldn't be allocated to the farm's players", farmId, job.id)
    end
    TheContractorCropSpill.refreshSites()

    TCLog.info("TheContractor: farm %d job %d: %.0f l of %s spilt at %.0f, %.0f (of %.0f l), %.0f l to deliver to %s",
        farmId, job.id, tipped, spill.fillTypeName, plan.x, plan.z, liters, job.requiredLiters,
        tostring(job.deliveryStationName))
    return job
end

-- Every machine: the in-game notification as the job arrives (Jobs:
-- registerJob), on the farm's own machines.
function TheContractorCropSpill.showNotification(job)
    if job.spill == nil or g_currentMission:getFarmId() ~= job.farmId then
        return
    end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(job.spill.fillTypeName)
    local field = g_fieldManager:getFieldById(job.fieldId)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText("tc_spill_notification"),
            g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or job.spill.fillTypeName,
            field ~= nil and field:getName() or tostring(job.fieldId),
            g_i18n:formatVolume(job.spill.liters * TheContractorCropSpill.DELIVERY_SHARE, 0),
            job.deliveryStationName or "?"))
end

-- Progress (server) -------------------------------------------------------------------

function TheContractorCropSpill.getRequiredLiters(job)
    return job.spill.liters * TheContractorCropSpill.DELIVERY_SHARE
end

-- TCJobProgress's measure (server): the delivered share.
function TheContractorCropSpill.getCompletion(job)
    if job.spill == nil or job.requiredLiters <= 0 then
        return 0
    end
    return math.min(1, job.deliveredLiters / job.requiredLiters)
end

-- Every machine: the status chip's text, from synced state.
function TheContractorCropSpill.getStatusText(job)
    local delivered = job.requiredLiters > 0 and math.floor(100 * job.deliveredLiters / job.requiredLiters) or 0
    return string.format(g_i18n:getText("tc_spill_chipDelivering"), delivered)
end

-- The end (server) --------------------------------------------------------------------

-- Every bit of the spilt crop left on the site cleared away. Engine side, replaced in the tests.
function TheContractorCropSpill.clearSite(job)
    local spill = job.spill
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(spill.fillTypeName)
    if fillTypeIndex == nil or DensityMapHeightUtil == nil then
        return
    end
    local r = spill.radius
    DensityMapHeightUtil.removeFromGroundByArea(spill.x - r, spill.z - r, spill.x + r, spill.z - r, spill.x - r,
        spill.z + r, fillTypeIndex)
end

-- From Jobs:completeJob: the crop's in.
function TheContractorCropSpill:onJobCompleted(job)
    TheContractorCropSpill.clearSite(job)
    TheContractorCropSpill.refreshSites()
    TCLog.info("TheContractor: farm %d job %d: spill cleared up, %.0f of %.0f l delivered", job.farmId, job.id,
        job.deliveredLiters, job.requiredLiters)
end

-- What a miss costs in reputation (Jobs:missJob): the lot, whatever was
-- delivered.
function TheContractorCropSpill.getMissPenalty(job)
    return job.spill.reputationPenalty or TheContractorCropSpill.MIN_REPUTATION_PENALTY
end

-- What a claim comes to: the crop that never arrived, at the price the day
-- of the spill (a vanilla price, already EconomyScale's, so not scaled),
-- and the farmer's clear-up (scaled).
function TheContractorCropSpill.getClaimAmount(job)
    local undelivered = math.max(0, job.spill.liters - job.deliveredLiters)
    return math.floor(undelivered * (job.spill.pricePerLiter or 0) +
        g_currentMission.TheContractor.Settings:scaleCost(TheContractorCropSpill.CLEANUP_COST))
end

-- From Jobs:missJob, after the logbook entry's written: the farmer clears
-- it up, and may claim. random is for the tests.
function TheContractorCropSpill:onJobMissed(job, random)
    local tc = g_currentMission.TheContractor
    random = random or math.random
    TheContractorCropSpill.clearSite(job)
    TheContractorCropSpill.refreshSites()

    local isClaim = random() < TheContractorCropSpill.CLAIM_CHANCE
    if self.forcedClaim ~= nil then
        isClaim = self.forcedClaim
        self.forcedClaim = nil
    end
    if not isClaim then
        TCLog.info("TheContractor: farm %d job %d: spill missed, no claim", job.farmId, job.id)
        return
    end

    local farmId = job.farmId
    local amount = TheContractorCropSpill.getClaimAmount(job)
    local insured = tc.Claims:isInsured(farmId)
    local paid = tc.Claims:chargeClaim(farmId, amount, insured)
    tc.Claims:addToJobLog(farmId, job.id, { cause = "cropSpill", amount = amount, paid = paid, insured = insured,
        reputationPenalty = 0 })

    local field = g_fieldManager:getFieldById(job.fieldId)
    local fieldName = field ~= nil and field:getName() or tostring(job.fieldId)
    tc.Inbox:postMessage(farmId, TheContractorCropSpill.MESSAGE_KIND, "tc_spill_claimTitle",
        insured and "tc_spill_claimBodyInsured" or "tc_spill_claimBodyUninsured",
        { fieldName, "$money_" .. amount, "$money_" .. paid }, nil, { jobId = job.id })
    TCLog.info("TheContractor: farm %d job %d: spill missed, claim of %.0f, %.0f paid (%s)", farmId, job.id, amount,
        paid, insured and "insured" or "uninsured")
end

-- The site's access (every machine) ----------------------------------------------------

local function isOpen(job)
    return job.spill ~= nil and
        (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS)
end

function TheContractorCropSpill.refreshSites()
    local tc = g_currentMission.TheContractor
    local result = {}
    if tc ~= nil and tc.Jobs ~= nil then
        for _, farm in ipairs(g_farmManager:getFarms()) do
            for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
                if isOpen(job) then
                    result[farm.farmId] = result[farm.farmId] or {}
                    table.insert(result[farm.farmId], { x = job.spill.x, z = job.spill.z,
                        radiusSq = job.spill.radius * job.spill.radius })
                end
            end
        end
    end
    sitesByFarm = result
end

function TheContractorCropSpill:update(dt)
    self.refreshMs = self.refreshMs + dt
    if self.refreshMs < TheContractorCropSpill.SITE_REFRESH_MS then
        return
    end
    self.refreshMs = 0
    TheContractorCropSpill.refreshSites()
end

-- Whether a point is on one of the farm's open spill sites.
function TheContractorCropSpill.isOnSite(farmId, x, z)
    local sites = farmId ~= nil and sitesByFarm[farmId] or nil
    if sites == nil or x == nil or z == nil then
        return false
    end
    for _, site in ipairs(sites) do
        local dx, dz = x - site.x, z - site.z
        if dx * dx + dz * dz <= site.radiusSq then
            return true
        end
    end
    return false
end

-- Sync and saves (with the job) ----------------------------------------------------------

local FLOAT_FIELDS = { "liters", "x", "z", "radius", "pricePerLiter" }

function TheContractorCropSpill.writeStream(streamId, spill)
    if streamWriteBool(streamId, spill ~= nil) then
        streamWriteString(streamId, spill.fillTypeName or "")
        for _, name in ipairs(FLOAT_FIELDS) do
            streamWriteFloat32(streamId, spill[name] or 0)
        end
        streamWriteInt32(streamId, spill.reputationPenalty or 0)
        streamWriteInt32(streamId, spill.sourceJobId or 0)
        streamWriteInt32(streamId, spill.incidentId or 0)
    end
end

function TheContractorCropSpill.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local spill = { fillTypeName = streamReadString(streamId) }
    for _, name in ipairs(FLOAT_FIELDS) do
        spill[name] = streamReadFloat32(streamId)
    end
    spill.reputationPenalty = streamReadInt32(streamId)
    spill.sourceJobId = streamReadInt32(streamId)
    spill.incidentId = streamReadInt32(streamId)
    return spill
end

function TheContractorCropSpill.saveToXML(xmlFile, key, spill)
    setXMLString(xmlFile, key .. "#fillTypeName", spill.fillTypeName or "")
    for _, name in ipairs(FLOAT_FIELDS) do
        setXMLFloat(xmlFile, key .. "#" .. name, spill[name] or 0)
    end
    setXMLInt(xmlFile, key .. "#reputationPenalty", spill.reputationPenalty or 0)
    setXMLInt(xmlFile, key .. "#sourceJobId", spill.sourceJobId or 0)
    setXMLInt(xmlFile, key .. "#incidentId", spill.incidentId or 0)
end

function TheContractorCropSpill.loadFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local spill = { fillTypeName = getXMLString(xmlFile, key .. "#fillTypeName") or "" }
    for _, name in ipairs(FLOAT_FIELDS) do
        spill[name] = getXMLFloat(xmlFile, key .. "#" .. name) or 0
    end
    spill.reputationPenalty = getXMLInt(xmlFile, key .. "#reputationPenalty") or 0
    spill.sourceJobId = getXMLInt(xmlFile, key .. "#sourceJobId") or 0
    spill.incidentId = getXMLInt(xmlFile, key .. "#incidentId") or 0
    return spill
end

-- Land access hooks ------------------------------------------------------------------
--
-- Each is vanilla's own check, then (if it said no) both ends of the tool
-- on one of the farm's spill sites. The specializations' functions are
-- patched before vehicle types are finalized, as CourtesyVehicle's WorkArea
-- hook is; FarmlandManager's is the class's own method (the leveler is its
-- only caller), as TCFieldAccess patches MissionManager.

function TheContractorCropSpill.getCanShovelAtPosition(vehicle, superFunc, shovelNode)
    if superFunc(vehicle, shovelNode) then
        return true
    end
    if shovelNode == nil or shovelNode.node == nil then
        return false
    end
    local farmId = vehicle:getActiveFarm()
    local sx, _, sz = localToWorld(shovelNode.node, -shovelNode.width * 0.5, 0, 0)
    local ex, _, ez = localToWorld(shovelNode.node, shovelNode.width * 0.5, 0, 0)
    return TheContractorCropSpill.isOnSite(farmId, sx, sz) and TheContractorCropSpill.isOnSite(farmId, ex, ez)
end

function TheContractorCropSpill.getCanDischargeToLand(vehicle, superFunc, dischargeNode)
    if superFunc(vehicle, dischargeNode) then
        return true
    end
    local info = dischargeNode ~= nil and dischargeNode.info or nil
    if info == nil or info.node == nil then
        return false
    end
    local farmId = vehicle:getActiveFarm()
    local sx, _, sz = localToWorld(info.node, -info.width, 0, info.zOffset)
    local ex, _, ez = localToWorld(info.node, info.width, 0, info.zOffset)
    return TheContractorCropSpill.isOnSite(farmId, sx, sz) and TheContractorCropSpill.isOnSite(farmId, ex, ez)
end

if Shovel ~= nil and Shovel.getCanShovelAtPosition ~= nil and not Shovel.tcSpillHookInstalled then
    Shovel.getCanShovelAtPosition = Utils.overwrittenFunction(Shovel.getCanShovelAtPosition,
        TheContractorCropSpill.getCanShovelAtPosition)
    Shovel.tcSpillHookInstalled = true
end

if Dischargeable ~= nil and Dischargeable.getCanDischargeToLand ~= nil and not Dischargeable.tcSpillHookInstalled then
    Dischargeable.getCanDischargeToLand = Utils.overwrittenFunction(Dischargeable.getCanDischargeToLand,
        TheContractorCropSpill.getCanDischargeToLand)
    Dischargeable.tcSpillHookInstalled = true
end

-- FarmlandManager outlives any one savegame, so guard against wrapping it
-- twice.
if FarmlandManager ~= nil and FarmlandManager.getCanAccessLandAtWorldPosition ~= nil and
        FarmlandManager.tcOriginalGetCanAccessLand == nil then
    FarmlandManager.tcOriginalGetCanAccessLand = FarmlandManager.getCanAccessLandAtWorldPosition

    function FarmlandManager:getCanAccessLandAtWorldPosition(farmId, x, z)
        if FarmlandManager.tcOriginalGetCanAccessLand(self, farmId, x, z) then
            return true
        end
        return TheContractorCropSpill.isOnSite(farmId, x, z)
    end
end
