-- Job consequences (045): what a hired worker does to the machines. Two
-- things, both applied once, server-side, when the job completes
-- (TheContractorJobs:completeJob), for each worker on it - the operator on
-- the field equipment, and the hauler on the haulage rig (035):
--
-- Extra wear from skill gaps. Vanilla wear and damage keep happening as
-- normal - jobs run the real AI Helper (020), so the base game's Wearable
-- already wears the equipment while it works. On top of that, each machine
-- takes an extra share of what vanilla added during the job, for every
-- point the worker's rating for it falls short of the job's
-- requiredSkillLevel: the tractor by their tractor rating, everything else
-- (implement, header, harvester, trailer) by the operation skill (044). A
-- share of vanilla's own wear rather than a flat amount, so it scales with
-- field size, how hard the machine worked and its own wear rate - and it's
-- one calculation per job, not a per-frame hook. Vanilla syncs damage and
-- wear to clients itself (Wearable's dirty flags). The condition each
-- machine started in is recorded when the worker sets off
-- (recordStartCondition, from Dispatch) and saved with the job.
--
-- Cleanliness (the worker's 1-10 trait). Untidy workers bring the
-- equipment back extra dirty, and each worker rolls on whether they wash
-- it before it's back in the yard. Washing lengthens the job's cooldown
-- (023 - Cooldown's "washing" buffer factor) by how dirty it all is, faster
-- for a tidier worker, and the equipment comes out of cooldown clean
-- (washEquipment, from Cooldown:endCooldown once it's home). None of this
-- happens on a save with dirt switched off.
--
-- Breakdowns (059), only with FS25_AdvancedDamageSystem. ADS zeroes
-- vanilla damage on the vehicles it manages, so the extra damage above
-- does nothing there (the extra wear still lands). Instead, each machine
-- that did some work rolls for an ADS breakdown, more likely the more
-- careless the worker (cleanliness, as Claims reads it) and the further
-- short of the job their rating for that machine is. A hit adds a random
-- failure that suits the vehicle through ADS's vehicle:addBreakdown(),
-- already some way along, and ADS develops and syncs it from there. No
-- ADS, or a vehicle it excludes, means no roll.
--
-- What happened goes on the job as workerReports - sent to clients with the
-- completed job and saved - for the completion notifications.
--
-- Player-driven jobs have no worker, so none of this applies to them.

TCJobConsequences = {}

-- Extra wear: this share of what vanilla added during the job, per point
-- short of requiredSkillLevel - 4 points short is +60%.
TCJobConsequences.WEAR_PER_SKILL_POINT = 0.15
-- Below this much vanilla damage + wear, there's nothing worth reporting
-- (e.g. a haulage rig that never left the yard - the carting is synthetic).
TCJobConsequences.MIN_REPORTED_WEAR = 0.0005

-- 059: chance per machine of an ADS breakdown - base, plus up to
-- BREAKDOWN_CARELESS_CHANCE for the untidiest worker, plus this much per
-- point short of requiredSkillLevel. A tidy, qualified worker is 1%, the
-- untidiest 4 points short 25%.
TCJobConsequences.BREAKDOWN_BASE_CHANCE = 0.01
TCJobConsequences.BREAKDOWN_CARELESS_CHANCE = 0.04
TCJobConsequences.BREAKDOWN_CHANCE_PER_SKILL_POINT = 0.05
-- How far along (0-1) the failure starts: random, up to BASE plus
-- PER_SKILL_POINT per point short, capped at MAX.
TCJobConsequences.BREAKDOWN_PROGRESS_BASE = 0.1
TCJobConsequences.BREAKDOWN_PROGRESS_PER_SKILL_POINT = 0.05
TCJobConsequences.BREAKDOWN_PROGRESS_MAX = 0.5

-- Extra dirt (0-1, as Washable's dirt amount) for the untidiest worker
-- (cleanliness 1), down to none at the tidiest.
TCJobConsequences.MAX_EXTRA_DIRT = 0.3
-- Chance they wash the equipment, cleanliness 1 to 10.
TCJobConsequences.WASH_CHANCE_MIN = 0.05
TCJobConsequences.WASH_CHANCE_MAX = 0.95
-- In-game minutes to wash one fully dirty vehicle, cleanliness 1 to 10.
TCJobConsequences.WASH_MAX_MINUTES = 40
TCJobConsequences.WASH_MIN_MINUTES = 15
-- Each other vehicle adds this many minutes per unit of its dirt, and a
-- worker's whole wash is capped at WASH_CAP_MINUTES.
TCJobConsequences.WASH_EXTRA_VEHICLE_MINUTES = 5
TCJobConsequences.WASH_CAP_MINUTES = 30

-- workerReports' wash outcome.
TCJobConsequences.WASH = {
    NONE = 0, -- dirt is off in this save
    WASHED = 1,
    UNWASHED = 2,
}

-- 0 for the untidiest worker, 1 for the tidiest.
local function getCleanlinessFactor(worker)
    local minC, maxC = TheContractorWorker.MIN_CLEANLINESS, TheContractorWorker.MAX_CLEANLINESS
    return (math.max(minC, math.min(maxC, worker.cleanliness)) - minC) / (maxC - minC)
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Whether the save has dirt at all (the "dirt interval" setting can be off).
function TCJobConsequences.isDirtEnabled()
    return Washable.getIntervalMultiplier() > 0
end

-- Each hired worker on the job and the equipment that's theirs: the
-- operator's field equipment, the hauler's haulage rig.
function TCJobConsequences.getCrew(job)
    local crew = {}
    if job.assignedWorkerId ~= nil then
        table.insert(crew, { workerId = job.assignedWorkerId, equipmentIds = job.assignedEquipmentIds,
            isHauler = false })
    end
    if job.haulerWorkerId ~= nil then
        table.insert(crew, { workerId = job.haulerWorkerId, equipmentIds = job.haulageEquipmentIds, isHauler = true })
    end
    return crew
end

-- Server-only, from Dispatch as a hired worker sets off. First call wins,
-- so resuming after a load (the condition was saved) or retrying after a
-- watchdog reset keeps the original baseline.
function TCJobConsequences.recordStartCondition(job)
    if not g_currentMission:getIsServer() or job.startCondition ~= nil or job.assignedWorkerId == nil then
        return
    end

    job.startCondition = {}
    for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and vehicle.spec_wearable ~= nil then
            local condition = { damage = vehicle:getDamageAmount(), wear = vehicle:getWearTotalAmount() }
            -- 080: ADS zeroes vanilla damage, so job quality reads its
            -- condition instead.
            if TCVehicleCondition.isManagedByADS(vehicle) then
                condition.adsCondition = vehicle:getConditionLevel()
            end
            job.startCondition[vehicleId] = condition
        end
    end
end

-- How many points a rating falls short of the job's requirement (0 if it
-- doesn't, or there's no rating to judge).
local function getGap(job, rating)
    if rating == nil then
        return 0
    end
    return math.max(0, job.requiredSkillLevel - rating)
end

-- The damage and wear vanilla added to a vehicle during the job, or nil if
-- there's no baseline or it barely worked.
local function getJobWear(job, vehicle, vehicleId)
    local start = job.startCondition ~= nil and job.startCondition[vehicleId] or nil
    if start == nil or vehicle.spec_wearable == nil then
        return nil
    end

    local vanillaDamage = math.max(0, vehicle:getDamageAmount() - start.damage)
    local vanillaWear = math.max(0, vehicle:getWearTotalAmount() - start.wear)
    if vanillaDamage + vanillaWear < TCJobConsequences.MIN_REPORTED_WEAR then
        return nil
    end
    return vanillaDamage, vanillaWear
end

-- Adds a vehicle's skill-gap share of extra damage and wear. Returns the
-- extra as a whole percentage of vanilla's, or nil if none was added.
function TCJobConsequences.applyExtraWear(job, vehicle, vehicleId, gap)
    if gap <= 0 then
        return nil
    end
    local vanillaDamage, vanillaWear = getJobWear(job, vehicle, vehicleId)
    if vanillaDamage == nil then
        return nil
    end

    local factor = gap * TCJobConsequences.WEAR_PER_SKILL_POINT
    vehicle:addDamageAmount(vanillaDamage * factor, true)
    vehicle:addWearAmount(vanillaWear * factor, true)
    return math.floor(factor * 100 + 0.5)
end

-- 059: whether ADS manages this vehicle and can give it a breakdown.
function TCJobConsequences.canBreakDown(vehicle)
    return vehicle.addBreakdown ~= nil and vehicle.spec_AdvancedDamageSystem ~= nil
        and (vehicle.getIsADSExcluded == nil or not vehicle:getIsADSExcluded())
end

function TCJobConsequences.getBreakdownChance(worker, gap)
    return TCJobConsequences.BREAKDOWN_BASE_CHANCE
        + TCJobConsequences.BREAKDOWN_CARELESS_CHANCE * (1 - getCleanlinessFactor(worker))
        + TCJobConsequences.BREAKDOWN_CHANCE_PER_SKILL_POINT * gap
end

-- 059: rolls for an ADS breakdown on a machine that worked during the job.
-- Returns the ADS breakdown id if one was added, else nil.
function TCJobConsequences.rollBreakdown(job, worker, vehicle, vehicleId, gap)
    if not TCJobConsequences.canBreakDown(vehicle) or getJobWear(job, vehicle, vehicleId) == nil then
        return nil
    end
    if math.random() >= TCJobConsequences.getBreakdownChance(worker, gap) then
        return nil
    end

    local maxProgress = math.min(TCJobConsequences.BREAKDOWN_PROGRESS_MAX,
        TCJobConsequences.BREAKDOWN_PROGRESS_BASE + TCJobConsequences.BREAKDOWN_PROGRESS_PER_SKILL_POINT * gap)
    local added, breakdownId = vehicle:addBreakdown(nil, { breakdownProgress = math.random() * maxProgress })
    if added ~= true then
        return nil
    end
    return breakdownId
end

-- In-game minutes for one worker to wash their vehicles: the dirtiest one
-- at the full per-vehicle rate (by cleanliness factor t), the rest's dirt
-- at WASH_EXTRA_VEHICLE_MINUTES, capped at WASH_CAP_MINUTES.
function TCJobConsequences.getWashMinutes(maxDirt, totalDirt, t)
    local minutes = maxDirt * lerp(TCJobConsequences.WASH_MAX_MINUTES, TCJobConsequences.WASH_MIN_MINUTES, t)
        + (totalDirt - maxDirt) * TCJobConsequences.WASH_EXTRA_VEHICLE_MINUTES
    return math.min(TCJobConsequences.WASH_CAP_MINUTES, minutes)
end

-- Server-only, from TheContractorJobs:completeJob before the cooldown
-- starts (it reads washMinutes) and before the completed job is broadcast
-- (it carries workerReports).
function TCJobConsequences.applyOnCompletion(job)
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    local allocation = g_currentMission.TheContractor.Allocation
    local dirtEnabled = TCJobConsequences.isDirtEnabled()

    job.workerReports = {}
    job.washVehicleIds = {}
    job.washMinutes = 0

    for _, member in ipairs(TCJobConsequences.getCrew(job)) do
        local worker = staff:getWorker(job.farmId, member.workerId)
        if worker ~= nil then
            local report = { workerId = worker.id, wash = TCJobConsequences.WASH.NONE, extraWear = {},
                breakdowns = {} }

            local ratings = allocation:getWorkerJobRatings(worker, job, member.equipmentIds, member.isHauler)
            local tractorGap = getGap(job, ratings.tractorRating)
            local operationGap = getGap(job, ratings.operationRating)

            local vehicles = {}
            for _, vehicleId in ipairs(member.equipmentIds) do
                local vehicle = NetworkUtil.getObject(vehicleId)
                if vehicle ~= nil then
                    table.insert(vehicles, { id = vehicleId, vehicle = vehicle })
                end
            end

            for _, entry in ipairs(vehicles) do
                local gap = TCEquipmentClass.isTractor(entry.vehicle) and tractorGap or operationGap
                local percent = TCJobConsequences.applyExtraWear(job, entry.vehicle, entry.id, gap)
                if percent ~= nil then
                    table.insert(report.extraWear, { vehicleName = entry.vehicle:getFullName(), percent = percent })
                end

                local breakdownId = TCJobConsequences.rollBreakdown(job, worker, entry.vehicle, entry.id, gap)
                if breakdownId ~= nil then
                    table.insert(report.breakdowns, entry.vehicle:getFullName())
                    Logging.info("TheContractor: farm %d job %d worker %d (%s) caused ADS breakdown %s on %s",
                        job.farmId, job.id, worker.id, worker.name, tostring(breakdownId),
                        entry.vehicle:getFullName())
                end
            end

            local washableCount = 0
            for _, entry in ipairs(vehicles) do
                if entry.vehicle.spec_washable ~= nil then
                    washableCount = washableCount + 1
                end
            end

            if dirtEnabled and washableCount > 0 then
                local t = getCleanlinessFactor(worker)
                local extraDirt = TCJobConsequences.MAX_EXTRA_DIRT * (1 - t)
                local totalDirt = 0
                local maxDirt = 0
                local washableIds = {}
                for _, entry in ipairs(vehicles) do
                    if entry.vehicle.spec_washable ~= nil then
                        if extraDirt > 0 then
                            entry.vehicle:addDirtAmount(extraDirt, true)
                        end
                        local dirt = entry.vehicle:getDirtAmount()
                        totalDirt = totalDirt + dirt
                        maxDirt = math.max(maxDirt, dirt)
                        table.insert(washableIds, entry.id)
                    end
                end

                local minutes = 0
                if math.random() < lerp(TCJobConsequences.WASH_CHANCE_MIN, TCJobConsequences.WASH_CHANCE_MAX, t) then
                    report.wash = TCJobConsequences.WASH.WASHED
                    for _, vehicleId in ipairs(washableIds) do
                        table.insert(job.washVehicleIds, vehicleId)
                    end
                    minutes = TCJobConsequences.getWashMinutes(maxDirt, totalDirt, t)
                    -- Each worker washes their own; the cooldown waits for
                    -- the slower one.
                    job.washMinutes = math.max(job.washMinutes, minutes)
                else
                    report.wash = TCJobConsequences.WASH.UNWASHED
                end

                Logging.info("TheContractor: farm %d job %d worker %d (%s, cleanliness %d) +%.2f dirt, %s (%.1f min)",
                    job.farmId, job.id, worker.id, worker.name, worker.cleanliness, extraDirt,
                    report.wash == TCJobConsequences.WASH.WASHED and "washed" or "unwashed", minutes)
            end

            for _, wear in ipairs(report.extraWear) do
                Logging.info("TheContractor: farm %d job %d worker %d (%s) +%d%% wear on %s", job.farmId, job.id,
                    worker.id, worker.name, wear.percent, wear.vehicleName)
            end

            table.insert(job.workerReports, report)
        end
    end

    -- The baseline's done its job.
    job.startCondition = nil
end

-- Server-only, from Cooldown:endCooldown before the equipment goes to be
-- parked (062): whatever the workers washed comes out clean. Vanilla's Washable syncs the dirt to clients itself.
function TCJobConsequences.washEquipment(job)
    if not g_currentMission:getIsServer() or job.washVehicleIds == nil then
        return
    end

    for _, vehicleId in ipairs(job.washVehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and vehicle.spec_washable ~= nil then
            vehicle:setDirtAmount(0)
        end
    end
    job.washVehicleIds = nil
end

-- Player-facing lines for the completion notifications, per worker:
-- "Extra wear from skill gaps: Fendt 942 Vario +60%, ...". Washing is left
-- to the logbook. The ADS faults they caused (report.breakdowns) aren't
-- told (099): ADS adds them undiscovered, for an inspection or a symptom
-- to reveal, and the player never learns which job caused one. Every
-- machine builds them from workerReports itself.
function TCJobConsequences.getReportLines(job)
    local lines = {}
    if job.workerReports == nil then
        return lines
    end

    local staff = g_currentMission.TheContractor.Staff
    for _, report in ipairs(job.workerReports) do
        local worker = staff:getWorker(job.farmId, report.workerId)
        local name = worker ~= nil and worker.name or g_i18n:getText("tc_consequences_unknownWorker")

        if #report.extraWear > 0 then
            local parts = {}
            for _, wear in ipairs(report.extraWear) do
                table.insert(parts, string.format("%s +%d%%", wear.vehicleName, wear.percent))
            end
            table.insert(lines, string.format(g_i18n:getText("tc_consequences_extraWear"), name,
                table.concat(parts, ", ")))
        end
    end
    return lines
end

-- Wire / save helpers for job.workerReports and the server-only fields,
-- called from TheContractorJobs' own writeJob/readJob and XML pair.

function TCJobConsequences.writeReports(streamId, job)
    local reports = job.workerReports or {}
    streamWriteUInt8(streamId, #reports)
    for _, report in ipairs(reports) do
        streamWriteInt32(streamId, report.workerId)
        streamWriteUInt8(streamId, report.wash)
        streamWriteUInt8(streamId, #report.extraWear)
        for _, wear in ipairs(report.extraWear) do
            streamWriteString(streamId, wear.vehicleName)
            streamWriteInt32(streamId, wear.percent)
        end
        streamWriteUInt8(streamId, #report.breakdowns)
        for _, vehicleName in ipairs(report.breakdowns) do
            streamWriteString(streamId, vehicleName)
        end
    end
end

function TCJobConsequences.readReports(streamId)
    local reports = {}
    for _ = 1, streamReadUInt8(streamId) do
        local report = { workerId = streamReadInt32(streamId), wash = streamReadUInt8(streamId), extraWear = {},
            breakdowns = {} }
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(report.extraWear, { vehicleName = streamReadString(streamId),
                percent = streamReadInt32(streamId) })
        end
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(report.breakdowns, streamReadString(streamId))
        end
        table.insert(reports, report)
    end
    return reports
end

function TCJobConsequences.saveToXML(xmlFile, jobKey, job)
    -- Only while the job's still running - a missed job's baseline is moot.
    if job.startCondition ~= nil and not job:isTerminal() then
        local index = 0
        for vehicleId, condition in pairs(job.startCondition) do
            local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
            if uniqueId ~= nil then
                local key = string.format("%s.startCondition(%d)", jobKey, index)
                setXMLString(xmlFile, key .. "#uniqueId", uniqueId)
                setXMLFloat(xmlFile, key .. "#damage", condition.damage)
                setXMLFloat(xmlFile, key .. "#wear", condition.wear)
                if condition.adsCondition ~= nil then
                    setXMLFloat(xmlFile, key .. "#adsCondition", condition.adsCondition)
                end
                index = index + 1
            end
        end
    end

    if job.washVehicleIds ~= nil then
        TCVehicleIds.saveList(xmlFile, jobKey .. ".wash", job.washVehicleIds)
    end

    for i, report in ipairs(job.workerReports or {}) do
        local key = string.format("%s.workerReport(%d)", jobKey, i - 1)
        setXMLInt(xmlFile, key .. "#workerId", report.workerId)
        setXMLInt(xmlFile, key .. "#wash", report.wash)
        for j, wear in ipairs(report.extraWear) do
            local wearKey = string.format("%s.extraWear(%d)", key, j - 1)
            setXMLString(xmlFile, wearKey .. "#vehicle", wear.vehicleName)
            setXMLInt(xmlFile, wearKey .. "#percent", wear.percent)
        end
        for j, vehicleName in ipairs(report.breakdowns) do
            setXMLString(xmlFile, string.format("%s.breakdown(%d)#vehicle", key, j - 1), vehicleName)
        end
    end
end

function TCJobConsequences.loadFromXML(xmlFile, jobKey, job)
    local index = 0
    while true do
        local key = string.format("%s.startCondition(%d)", jobKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        -- By uniqueId until resolveSavedVehicles.
        local uniqueId = getXMLString(xmlFile, key .. "#uniqueId")
        if uniqueId ~= nil then
            job.savedStartCondition = job.savedStartCondition or {}
            job.savedStartCondition[uniqueId] = {
                damage = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#damage"), 0),
                wear = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#wear"), 0),
                adsCondition = getXMLFloat(xmlFile, key .. "#adsCondition"),
            }
        end
        index = index + 1
    end

    if hasXMLProperty(xmlFile, jobKey .. ".wash") then
        job.savedWashUniqueIds = TCVehicleIds.loadList(xmlFile, jobKey .. ".wash")
    end

    index = 0
    while true do
        local key = string.format("%s.workerReport(%d)", jobKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local report = {
            workerId = getXMLInt(xmlFile, key .. "#workerId"),
            wash = Utils.getNoNil(getXMLInt(xmlFile, key .. "#wash"), TCJobConsequences.WASH.NONE),
            extraWear = {},
            breakdowns = {},
        }
        local wearIndex = 0
        while true do
            local wearKey = string.format("%s.extraWear(%d)", key, wearIndex)
            if not hasXMLProperty(xmlFile, wearKey) then
                break
            end
            table.insert(report.extraWear, { vehicleName = getXMLString(xmlFile, wearKey .. "#vehicle") or "?",
                percent = Utils.getNoNil(getXMLInt(xmlFile, wearKey .. "#percent"), 0) })
            wearIndex = wearIndex + 1
        end
        local breakdownIndex = 0
        while true do
            local breakdownKey = string.format("%s.breakdown(%d)", key, breakdownIndex)
            if not hasXMLProperty(xmlFile, breakdownKey) then
                break
            end
            table.insert(report.breakdowns, getXMLString(xmlFile, breakdownKey .. "#vehicle") or "?")
            breakdownIndex = breakdownIndex + 1
        end
        job.workerReports = job.workerReports or {}
        table.insert(job.workerReports, report)
        index = index + 1
    end
end

-- Server, from TheContractorJobs:resolveSavedVehicles once vehicles exist:
-- the saved baseline and wash list back to object ids.
function TCJobConsequences.resolveSavedVehicles(job)
    if job.savedStartCondition ~= nil then
        job.startCondition = {}
        for uniqueId, condition in pairs(job.savedStartCondition) do
            local vehicleId = TCVehicleIds.getObjectId(uniqueId)
            if vehicleId ~= nil then
                job.startCondition[vehicleId] = condition
            end
        end
        job.savedStartCondition = nil
    end
    if job.savedWashUniqueIds ~= nil then
        job.washVehicleIds = TCVehicleIds.resolveList(job.savedWashUniqueIds)
        job.savedWashUniqueIds = nil
    end
end
