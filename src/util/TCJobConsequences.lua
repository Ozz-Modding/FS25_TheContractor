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

-- Extra dirt (0-1, as Washable's dirt amount) for the untidiest worker
-- (cleanliness 1), down to none at the tidiest.
TCJobConsequences.MAX_EXTRA_DIRT = 0.3
-- Chance they wash the equipment, cleanliness 1 to 10.
TCJobConsequences.WASH_CHANCE_MIN = 0.05
TCJobConsequences.WASH_CHANCE_MAX = 0.95
-- In-game minutes to wash one fully dirty vehicle, cleanliness 1 to 10.
TCJobConsequences.WASH_MAX_MINUTES = 40
TCJobConsequences.WASH_MIN_MINUTES = 15

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
            job.startCondition[vehicleId] = { damage = vehicle:getDamageAmount(), wear = vehicle:getWearTotalAmount() }
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

-- Adds a vehicle's skill-gap share of extra damage and wear. Returns the
-- extra as a whole percentage of vanilla's, or nil if none was added.
function TCJobConsequences.applyExtraWear(job, vehicle, vehicleId, gap)
    local start = job.startCondition ~= nil and job.startCondition[vehicleId] or nil
    if start == nil or gap <= 0 or vehicle.spec_wearable == nil then
        return nil
    end

    local vanillaDamage = math.max(0, vehicle:getDamageAmount() - start.damage)
    local vanillaWear = math.max(0, vehicle:getWearTotalAmount() - start.wear)
    if vanillaDamage + vanillaWear < TCJobConsequences.MIN_REPORTED_WEAR then
        return nil
    end

    local factor = gap * TCJobConsequences.WEAR_PER_SKILL_POINT
    vehicle:addDamageAmount(vanillaDamage * factor, true)
    vehicle:addWearAmount(vanillaWear * factor, true)
    return math.floor(factor * 100 + 0.5)
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
            local report = { workerId = worker.id, wash = TCJobConsequences.WASH.NONE, extraWear = {} }

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
                local washableIds = {}
                for _, entry in ipairs(vehicles) do
                    if entry.vehicle.spec_washable ~= nil then
                        if extraDirt > 0 then
                            entry.vehicle:addDirtAmount(extraDirt, true)
                        end
                        totalDirt = totalDirt + entry.vehicle:getDirtAmount()
                        table.insert(washableIds, entry.id)
                    end
                end

                local minutes = 0
                if math.random() < lerp(TCJobConsequences.WASH_CHANCE_MIN, TCJobConsequences.WASH_CHANCE_MAX, t) then
                    report.wash = TCJobConsequences.WASH.WASHED
                    for _, vehicleId in ipairs(washableIds) do
                        table.insert(job.washVehicleIds, vehicleId)
                    end
                    -- By how dirty it all is, summed over their vehicles.
                    -- Each worker washes their own; the cooldown waits for
                    -- the slower one.
                    minutes = totalDirt * lerp(TCJobConsequences.WASH_MAX_MINUTES, TCJobConsequences.WASH_MIN_MINUTES, t)
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

-- Server-only, from Cooldown:endCooldown once the equipment's been taken
-- home and before it's revealed: whatever the workers washed comes out
-- clean. Vanilla's Washable syncs the dirt to clients itself.
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

-- Player-facing lines for the completion notifications, one or two per
-- worker: "Amy Hall washed the equipment before bringing it back." and
-- "Extra wear from skill gaps: Fendt 942 Vario +60%, ...". Every machine
-- builds them from workerReports itself.
function TCJobConsequences.getReportLines(job)
    local lines = {}
    if job.workerReports == nil then
        return lines
    end

    local staff = g_currentMission.TheContractor.Staff
    for _, report in ipairs(job.workerReports) do
        local worker = staff:getWorker(job.farmId, report.workerId)
        local name = worker ~= nil and worker.name or g_i18n:getText("tc_consequences_unknownWorker")

        if report.wash == TCJobConsequences.WASH.WASHED then
            table.insert(lines, string.format(g_i18n:getText("tc_consequences_washed"), name))
        elseif report.wash == TCJobConsequences.WASH.UNWASHED then
            table.insert(lines, string.format(g_i18n:getText("tc_consequences_unwashed"), name))
        end

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
    end
end

function TCJobConsequences.readReports(streamId)
    local reports = {}
    for _ = 1, streamReadUInt8(streamId) do
        local report = { workerId = streamReadInt32(streamId), wash = streamReadUInt8(streamId), extraWear = {} }
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(report.extraWear, { vehicleName = streamReadString(streamId),
                percent = streamReadInt32(streamId) })
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
            local key = string.format("%s.startCondition(%d)", jobKey, index)
            setXMLInt(xmlFile, key .. "#vehicleId", vehicleId)
            setXMLFloat(xmlFile, key .. "#damage", condition.damage)
            setXMLFloat(xmlFile, key .. "#wear", condition.wear)
            index = index + 1
        end
    end

    if job.washVehicleIds ~= nil and #job.washVehicleIds > 0 then
        setXMLString(xmlFile, jobKey .. "#washVehicleIds", TheContractorJobs.encodeIdList(job.washVehicleIds))
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
    end
end

function TCJobConsequences.loadFromXML(xmlFile, jobKey, job)
    local index = 0
    while true do
        local key = string.format("%s.startCondition(%d)", jobKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        job.startCondition = job.startCondition or {}
        job.startCondition[getXMLInt(xmlFile, key .. "#vehicleId")] = {
            damage = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#damage"), 0),
            wear = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#wear"), 0),
        }
        index = index + 1
    end

    local washVehicleIds = getXMLString(xmlFile, jobKey .. "#washVehicleIds")
    if washVehicleIds ~= nil then
        job.washVehicleIds = TheContractorJobs.decodeIdList(washVehicleIds)
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
        job.workerReports = job.workerReports or {}
        table.insert(job.workerReports, report)
        index = index + 1
    end
end
