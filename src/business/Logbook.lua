-- Logbook (060): the business's records, shown on the Logbook tab. Two
-- kinds, both snapshots taken when things happen and never changed after
-- (bar a claim landing on a job later):
--
-- Job entries, one per finished job (completed or missed), farm-scoped and
-- kept JOB_RETENTION_YEARS: who did it, the machines they took and the
-- state each came back in, where the time went (travel out, fieldwork,
-- return and wash), fuel, the supplies it used (158) and what they'd cost,
-- an estimated labour and wear cost, income, reputation and any claim, and
-- the margin left. A crew member's entry also keeps what they got better at
-- from the job (issue #16): its growth roll (030) or stepping up (074), each
-- { stat, from, to }, from nil for a new tractor size.
--
-- Vehicle entries, kept VEHICLE_RETENTION_YEARS, grouped per vehicle: each
-- time a job used it, a staff driver (037) drove it, or a player drove one
-- of the business's machines (one used on a job in the last year) - who,
-- when, for how long and its condition before and after.
--
-- Why not read completed jobs: the time split, condition and reputation
-- were never kept on them. So the server records what it needs as it
-- happens: the condition each machine set off in when work starts
-- (onWorkStarted), when a hired worker reached the field (onArrived),
-- supplies used (onTanksFound, onSuppliesLoaded, then what's left in the
-- tanks taken off), all saved per job until it finishes.
--
-- Vehicles (TCVehicleIds): in memory and on the wire a vehicle is its
-- network object id; the save stores its uniqueId, turned back into an
-- object id by resolveSavedVehicles. A vehicle's history goes when the
-- vehicle does (it isn't saved once it's sold); job entries copy machine
-- names in, so they still read properly.
--
-- Conditions are TCVehicleCondition snapshots: vanilla or ADS, per vehicle.

TheContractorLogbook = {}
TheContractorLogbook_mt = Class(TheContractorLogbook)

TheContractorLogbook.JOB_RETENTION_YEARS = 2
TheContractorLogbook.VEHICLE_RETENTION_YEARS = 1

-- Staff-driver and player sessions shorter than this (in-game minutes)
-- aren't logged, and a vehicle's history leaves out any use this short.
TheContractorLogbook.MIN_SESSION_MINUTES = 10
-- How often the server checks who's in the business's machines (real ms).
TheContractorLogbook.PLAYER_POLL_MS = 1000

-- Labour estimate: a worker's weekly pay over a full-time UK week.
TheContractorLogbook.HOURS_PER_WEEK = 37.5

-- Margin chip: below this share of the price it's amber, below 0 red.
TheContractorLogbook.THIN_MARGIN_RATIO = 0.2

TheContractorLogbook.OUTCOME = {
    COMPLETED = "completed",
    MISSED = "missed",
}

TheContractorLogbook.KIND = {
    JOB = "job",
    DRIVER = "driver",
    PLAYER = "player",
    -- 069: stolen and recovered; minutes is how long it was missing.
    THEFT = "theft",
}

TheContractorLogbook.ROLE = {
    OPERATOR = "operator",
    HAULER = "hauler",
    PLAYER = "player",
}

TheContractorLogbook.SOURCE = {
    AUTODRIVE = "autodrive",
    COURSEPLAY = "courseplay",
    FOLLOWME = "followme",
    AI = "ai",
}

function TheContractorLogbook.new()
    local self = {}
    setmetatable(self, TheContractorLogbook_mt)

    -- Every machine: jobEntriesByFarm[farmId][jobId] = entry, and
    -- vehicles[vehicleId] = { vehicleId, name, entries = { ... } }.
    self.jobEntriesByFarm = {}
    self.vehicles = {}

    -- Server-only from here.
    -- pendingByJobId[jobId] = { arrivedAt, start = { [vehicleId] = snapshot },
    -- supplies = { [fillTypeName] = liters }, tanksCounted, playerName,
    -- earlierCrew }, saved. earlierCrew (094): who had the job before it was
    -- unallocated, as one line of names. supplies (158): what's been used so
    -- far, counted as the tanks' contents go in and come out (onTanksFound).
    self.pendingByJobId = {}
    -- Open staff-driver sessions by the bound vehicle's object id (as
    -- Drivers keys them): { farmId, workerId, start, sources }.
    self.driverSessions = {}
    -- Driver sessions from the save, by vehicle id, waiting for Drivers to
    -- bind them again; closed on the first update if it didn't.
    self.loadedDriverSessions = {}
    -- Open player sessions, by vehicle: { farmId, who, minutes, start }.
    self.playerSessions = {}
    -- What the save holds by uniqueId, until resolveSavedVehicles: vehicle
    -- records ({ uniqueId, name, entries }), and driver and player sessions
    -- ({ uniqueId, kind, ... }).
    self.savedVehicles = {}
    self.savedSessions = {}
    self.playerPollMs = 0
    self.hasClosedLoadedSessions = true

    return self
end

-- Helpers ---------------------------------------------------------------------

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getYearDays()
    return g_currentMission.environment.daysPerPeriod * Environment.PERIODS_IN_YEAR
end

local function writeOptionalFloat(streamId, value)
    streamWriteBool(streamId, value ~= nil)
    if value ~= nil then
        streamWriteFloat32(streamId, value)
    end
end

local function readOptionalFloat(streamId)
    if streamReadBool(streamId) then
        return streamReadFloat32(streamId)
    end
    return nil
end

local function setOptionalFloat(xmlFile, key, value)
    if value ~= nil then
        setXMLFloat(xmlFile, key, value)
    end
end

-- Vehicle records ---------------------------------------------------------------

-- Server-only: the record for a live vehicle, created if `create`. Keeps
-- its name current.
function TheContractorLogbook:getVehicleRecord(vehicle, create)
    local vehicleId = vehicle ~= nil and NetworkUtil.getObjectId(vehicle) or nil
    if vehicleId == nil then
        return nil
    end

    local record = self.vehicles[vehicleId]
    if record == nil then
        if not create then
            return nil
        end
        record = { vehicleId = vehicleId, entries = {} }
        self.vehicles[vehicleId] = record
    end
    record.name = vehicle:getFullName()
    return record
end

-- Every machine: the live vehicle behind a record, or nil if it's gone
-- (sold, or not streamed to this client yet).
function TheContractorLogbook.getRecordVehicle(record)
    local vehicle = NetworkUtil.getObject(record.vehicleId)
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Every machine: the record for a live vehicle, if it has one.
function TheContractorLogbook:getRecordForVehicle(vehicle)
    local vehicleId = NetworkUtil.getObjectId(vehicle)
    return vehicleId ~= nil and self.vehicles[vehicleId] or nil
end

-- Whether a vehicle counts as one of the business's machines for player
-- sessions: used on a job in the last year.
function TheContractorLogbook:hasRecentJobUse(record)
    for _, entry in ipairs(record.entries) do
        if entry.kind == TheContractorLogbook.KIND.JOB then
            return true
        end
    end
    return false
end

-- Pending job data (server) -----------------------------------------------------

local function getPending(self, job)
    local pending = self.pendingByJobId[job.id]
    if pending == nil then
        pending = { start = {}, supplies = {} }
        self.pendingByJobId[job.id] = pending
    end
    return pending
end

-- 158: a product the tank is for, in it now: its fill type, or nil.
local function getTankProduct(tank)
    local vehicle, fillUnitIndex = tank.vehicle, tank.fillUnitIndex
    if vehicle:getFillUnitFillLevel(fillUnitIndex) <= 0.001 then
        return nil
    end
    local fillTypeIndex = vehicle:getFillUnitFillType(fillUnitIndex)
    for _, candidate in ipairs(tank.fillTypes) do
        if candidate == fillTypeIndex then
            return fillTypeIndex
        end
    end
    return nil
end

-- 158: adds (sign 1) or takes off (sign -1) what the job's product tanks
-- hold. Diesel's left out: the fuel line has what was burned.
local function addTankLevels(pending, tanks, sign)
    for _, tank in ipairs(tanks) do
        local fillTypeIndex = not tank.isFuel and getTankProduct(tank) or nil
        local name = fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or nil
        if name ~= nil then
            local level = tank.vehicle:getFillUnitFillLevel(tank.fillUnitIndex)
            pending.supplies[name] = (pending.supplies[name] or 0) + sign * level
        end
    end
end

-- 158: what's left in the tanks of the crew coming off the job
-- (unallocated, or it's ended), taken off what it used. The next crew's
-- tanks are counted afresh (onTanksFound).
local function takeLeftInTanks(job, pending)
    if not pending.tanksCounted then
        return
    end
    pending.tanksCounted = nil
    addTankLevels(pending, TCJobSupplies.getJobTanks(job), -1)
end

-- From Jobs:markWorkStarted (first call only): the condition each of the
-- job's machines set off in.
function TheContractorLogbook:onWorkStarted(job)
    if not g_currentMission:getIsServer() then
        return
    end
    local pending = getPending(self, job)
    for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and pending.start[vehicleId] == nil then
            pending.start[vehicleId] = TCVehicleCondition.capture(vehicle)
        end
    end
    -- A player-driven job has no trip: work starts on the field.
    if job.assignedWorkerId == nil and pending.arrivedAt == nil then
        pending.arrivedAt = job.workStartedAt
    end
end

-- From Jobs:unallocateJob (094), before the crew's taken off: their names
-- go on the job's entry as its earlier crew. The rest of what's pending
-- (the condition the machines set off in, supplies, the arrival) stays.
function TheContractorLogbook:onCrewChanged(job)
    if not g_currentMission:getIsServer() then
        return
    end
    local names = {}
    if job:isPlayerDriven() then
        table.insert(names, job:getPlayerName())
    else
        local staff = g_currentMission.TheContractor.Staff
        for _, workerId in ipairs(job:getWorkerIds()) do
            local worker = staff:getWorker(job.farmId, workerId)
            table.insert(names, worker ~= nil and worker.name or g_i18n:getText("tc_calendar_formerWorker"))
        end
    end
    local pending = getPending(self, job)
    -- 158: what's left in the crew's tanks goes with them.
    takeLeftInTanks(job, pending)
    local crew = table.concat(names, ", ")
    pending.earlierCrew = pending.earlierCrew ~= nil and (pending.earlierCrew .. "; " .. crew) or crew
end

-- From Dispatch, once a hired worker's equipment is rigged on the field.
-- First call wins, so a watchdog retry or a resume keeps the real arrival.
function TheContractorLogbook:onArrived(job)
    if not g_currentMission:getIsServer() then
        return
    end
    local pending = getPending(self, job)
    if pending.arrivedAt == nil then
        pending.arrivedAt = TheContractorJobs.getGameMinutes()
    end
end

-- From TCJobSupplies.topUp: what went into the job's tanks from the farm's
-- stock.
function TheContractorLogbook:onSuppliesLoaded(job, fillTypeIndex, liters)
    if not g_currentMission:getIsServer() or liters <= 0 then
        return
    end
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    if name == nil then
        return
    end
    local pending = getPending(self, job)
    pending.supplies[name] = (pending.supplies[name] or 0) + liters
end

-- 158: from TCJobSupplies.topUp, before anything goes in: the first time
-- for this crew, whatever's already in the job's tanks counts as used, as
-- what's loaded does, until what's left is taken off at the end.
function TheContractorLogbook:onTanksFound(job, tanks)
    if not g_currentMission:getIsServer() then
        return
    end
    local pending = getPending(self, job)
    if pending.tanksCounted then
        return
    end
    pending.tanksCounted = true
    addTankLevels(pending, tanks, 1)
end

-- 158: a job's entry's supplies from what it used ({ [fillTypeName] =
-- liters }): each product, in name order, with what it would cost to buy
-- today (vanilla's price, so never scaled again - TCEconomyScale). Less
-- than one litre or piece is nothing.
function TheContractorLogbook.getSuppliesUsed(supplies)
    local names = {}
    for name, liters in pairs(supplies) do
        if liters >= 1 then
            table.insert(names, name)
        end
    end
    table.sort(names)

    local economyManager = g_currentMission.economyManager
    local result = {}
    for _, name in ipairs(names) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        local price = fillTypeIndex ~= nil and economyManager ~= nil and
            economyManager:getCostPerLiter(fillTypeIndex) or 0
        table.insert(result, { fillTypeName = name, liters = supplies[name], cost = supplies[name] * price })
    end
    return result
end

-- 158: what an entry's supplies cost. An entry from before 158 has none
-- (it only kept what was loaded).
function TheContractorLogbook.getSuppliesCost(entry)
    local total = 0
    for _, supply in ipairs(entry.supplies or {}) do
        total = total + (supply.cost or 0)
    end
    return total
end

-- Recording a job (server) --------------------------------------------------------

-- The worker report (045) for one worker, if any.
local function getWorkerReport(job, workerId)
    for _, report in ipairs(job.workerReports or {}) do
        if report.workerId == workerId then
            return report
        end
    end
    return nil
end

local function containsName(list, name)
    for _, value in ipairs(list or {}) do
        if value == name then
            return true
        end
    end
    return false
end

-- Each group of the job's machines with whoever had them: the operator's
-- field equipment and the hauler's rig, or everything for a player-driven
-- job (workerId nil).
local function getEquipmentGroups(job)
    local crew = TCJobConsequences.getCrew(job)
    if #crew > 0 then
        return crew
    end
    return { { workerId = nil, equipmentIds = job:getAllEquipmentIds(), isHauler = false } }
end

-- Whether the job got as far as being allocated (it has a crew or machines).
local function wasAllocated(job)
    return job.assignedWorkerId ~= nil or #job:getAllEquipmentIds() > 0
end

function TheContractorLogbook:buildJobEntry(job, outcome, reputation)
    local tc = g_currentMission.TheContractor
    local pending = self.pendingByJobId[job.id] or { start = {}, supplies = {} }
    self.pendingByJobId[job.id] = nil

    local now = TheContractorJobs.getGameMinutes()
    local isCompleted = outcome == TheContractorLogbook.OUTCOME.COMPLETED

    local entry = {
        jobId = job.id,
        farmId = job.farmId,
        outcome = outcome,
        jobType = job.jobType,
        title = job:getDisplayTitle(),
        fieldId = job.fieldId,
        -- 100: a workshop job's machine, shown in place of a field. 124, 126:
        -- or the farmer's yard.
        location = (job.workshop ~= nil or job.yardDelivery ~= nil or job.yardHaul ~= nil) and job:getLocationText()
            or nil,
        -- 124: the bales asked for, delivered and over, or nil. 126: a
        -- farmer's load and where it went. 127: the diesel a farmer's
        -- machine was asked to have, what it had as it ended, and the
        -- machine.
        delivery = TheContractorYardBales ~= nil and TheContractorYardBales.getLogbookDelivery(job) or
            TheContractorYardHaul ~= nil and TheContractorYardHaul.getLogbookDelivery(job) or
            TheContractorEmergencyRefuel ~= nil and TheContractorEmergencyRefuel.getLogbookDelivery(job) or nil,
        -- 101: a breakdown's field, for the list's Field column.
        workshopFieldId = job.workshop ~= nil and job.workshop.fieldId or nil,
        -- 111: who it was for (110's farmer or the official), so the People
        -- tab can show what's been done for them. nil for a workshop job.
        customerId = job.customerId,
        requiredSkillLevel = job.requiredSkillLevel,
        day = getToday(),
        completedAt = now,
        offeredPrice = job:getOfferedPrice(),
        agreedPrice = job:getPrice(),
        price = isCompleted and (job.paymentAmount or job:getPrice()) or 0,
        reputation = reputation,
        qualityScore = job.qualityScore,
        stuckInterventions = job.stuckInterventions or 0,
        earlierCrew = pending.earlierCrew,
        completionPercentage = job.completionPercentage or 0,
        fuelLiters = job.fuelUsedLiters or 0,
        fuelCost = job.fuelCost or 0,
        crew = {},
        equipment = {},
        supplies = {},
        claim = nil,
    }

    -- Time: travel out, fieldwork, then the trip back (and washing) - the
    -- cooldown the job's just gone into, or would have for a missed job
    -- that got some work done. A player-driven job has no trip back (no
    -- cooldown - see TheContractorCooldown:startCooldown).
    if job.workStartedAt ~= nil then
        local arrivedAt = pending.arrivedAt
        if arrivedAt ~= nil then
            entry.travelMinutes = math.max(0, arrivedAt - job.workStartedAt)
            entry.fieldMinutes = math.max(0, now - arrivedAt)
        else
            -- Missed before the crew reached the field: it was all travel.
            entry.travelMinutes = math.max(0, now - job.workStartedAt)
            entry.fieldMinutes = 0
        end
        if (isCompleted or job.completionPercentage > 0) and #job:getWorkerIds() > 0 then
            entry.returnMinutes = TheContractorCooldown.getBufferDurationMs(job) / 60000
        end
    end

    local workedMinutes = (entry.travelMinutes or 0) + (entry.fieldMinutes or 0) + (entry.returnMinutes or 0)

    -- Crew, and the labour estimate.
    local allocated = wasAllocated(job)
    local labour = 0
    local staff = tc.Staff
    for _, member in ipairs(TCJobConsequences.getCrew(job)) do
        local worker = staff:getWorker(job.farmId, member.workerId)
        local crewEntry = {
            workerId = member.workerId,
            name = worker ~= nil and worker.name or nil,
            role = member.isHauler and TheContractorLogbook.ROLE.HAULER or TheContractorLogbook.ROLE.OPERATOR,
        }
        if worker ~= nil then
            local ratings = tc.Allocation:getWorkerJobRatings(worker, job, member.equipmentIds, member.isHauler)
            crewEntry.rating = TheContractorAllocation.getWeakestRating(ratings)
            labour = labour + TheContractorStaff.getWeeklyPay(worker) / TheContractorLogbook.HOURS_PER_WEEK *
                workedMinutes / 60
        end
        table.insert(entry.crew, crewEntry)
    end
    if #entry.crew == 0 and allocated then
        table.insert(entry.crew, { role = TheContractorLogbook.ROLE.PLAYER, name = pending.playerName })
    end
    if job.workStartedAt ~= nil and job.assignedWorkerId ~= nil then
        entry.labourCost = labour
    end

    -- Machines: condition out and back, and what each worker did to them.
    local vehicleUpdates = {}
    entry.wearCost = 0
    if allocated then
        for _, group in ipairs(getEquipmentGroups(job)) do
            local worker = group.workerId ~= nil and staff:getWorker(job.farmId, group.workerId) or nil
            local report = group.workerId ~= nil and getWorkerReport(job, group.workerId) or nil
            local who = worker ~= nil and worker.name or (group.workerId == nil and pending.playerName or nil)

            for _, vehicleId in ipairs(group.equipmentIds) do
                local vehicle = NetworkUtil.getObject(vehicleId)
                local record = self:getVehicleRecord(vehicle, true)
                if record ~= nil then
                    local name = record.name
                    local startSnapshot = pending.start[vehicleId]
                    local endSnapshot = job.workStartedAt ~= nil and TCVehicleCondition.capture(vehicle) or nil
                    local wearCost = TCVehicleCondition.getWearCost(vehicle, startSnapshot, endSnapshot)
                    entry.wearCost = entry.wearCost + wearCost

                    local extraWear = nil
                    for _, wear in ipairs(report ~= nil and report.extraWear or {}) do
                        if wear.vehicleName == name then
                            extraWear = wear.percent
                        end
                    end

                    local machine = {
                        vehicleId = vehicleId,
                        name = name,
                        workerName = who,
                        startSnapshot = startSnapshot,
                        endSnapshot = endSnapshot,
                        extraWear = extraWear,
                        -- Kept, never shown (099): which job caused an ADS
                        -- fault is hidden from the player. hasFoundFault is
                        -- what they know.
                        faultCaused = report ~= nil and containsName(report.breakdowns, name) or false,
                        wash = vehicle.spec_washable ~= nil and report ~= nil and report.wash or
                            TCJobConsequences.WASH.NONE,
                        wearCost = wearCost,
                    }
                    table.insert(entry.equipment, machine)

                    table.insert(vehicleUpdates, {
                        record = record,
                        entry = {
                            kind = TheContractorLogbook.KIND.JOB,
                            farmId = job.farmId,
                            day = entry.day,
                            endedAt = now,
                            minutes = workedMinutes > 0 and workedMinutes or nil,
                            who = who,
                            workerId = group.workerId,
                            jobId = job.id,
                            jobTitle = entry.title,
                            outcome = outcome,
                            startSnapshot = startSnapshot,
                            endSnapshot = endSnapshot,
                            faultCaused = machine.faultCaused,
                            wash = machine.wash,
                            wearCost = wearCost,
                        },
                    })
                end
            end
        end
    end

    takeLeftInTanks(job, pending)
    entry.supplies = TheContractorLogbook.getSuppliesUsed(pending.supplies)

    return entry, vehicleUpdates
end

-- From Jobs:completeJob, after the cooldown's started (its length is the
-- trip back).
function TheContractorLogbook:recordJobCompleted(job, reputationReward)
    self:recordJob(job, TheContractorLogbook.OUTCOME.COMPLETED, reputationReward)
end

-- From Jobs:missJob, before its resources are released.
function TheContractorLogbook:recordJobMissed(job, reputationPenalty)
    self:recordJob(job, TheContractorLogbook.OUTCOME.MISSED, -reputationPenalty)
end

function TheContractorLogbook:recordJob(job, outcome, reputation)
    if not g_currentMission:getIsServer() then
        return
    end

    local entry, vehicleUpdates = self:buildJobEntry(job, outcome, reputation)
    self:applyJobEntry(entry)
    for _, update in ipairs(vehicleUpdates) do
        self:applyVehicleEntry(update.record, update.entry)
    end

    TCLog.info("TheContractor: farm %d job %d logged (%s, %d machine(s), margin %s)", job.farmId, job.id, outcome,
        #entry.equipment, tostring(TheContractorLogbook.getMargin(entry)))

    if g_server ~= nil then
        g_server:broadcastEvent(TCLogJobRecordedEvent.new(entry, vehicleUpdates))
    end
end

-- From Claims:deliverClaim: the claim goes on the job's entry and comes off
-- its margin.
function TheContractorLogbook:recordClaim(farmId, jobId, claim)
    if not g_currentMission:getIsServer() then
        return
    end
    if self:applyClaim(farmId, jobId, claim) and g_server ~= nil then
        g_server:broadcastEvent(TCLogClaimEvent.new(farmId, jobId, claim))
    end
end

-- Staff drivers (037, server) -----------------------------------------------------

function TheContractorLogbook:onDriverBound(vehicleId, farmId, workerId)
    if not g_currentMission:getIsServer() then
        return
    end
    local vehicle = NetworkUtil.getObject(vehicleId)
    if vehicle == nil then
        return
    end

    local existing = self.driverSessions[vehicleId]
    if existing ~= nil and existing.workerId == workerId then
        return
    end

    -- A binding restored from the save carries on its session.
    local loaded = self.loadedDriverSessions[vehicleId]
    if loaded ~= nil and loaded.workerId == workerId then
        self.loadedDriverSessions[vehicleId] = nil
        self.driverSessions[vehicleId] = loaded
        return
    end

    self.driverSessions[vehicleId] = {
        farmId = farmId,
        workerId = workerId,
        start = TCVehicleCondition.capture(vehicle),
        sources = {},
    }
end

-- From Drivers:update while the vehicle's being driven: what's driving it.
function TheContractorLogbook:noteDriverActivity(vehicleId, vehicle)
    local session = self.driverSessions[vehicleId]
    if session == nil then
        return
    end
    local source = TheContractorLogbook.SOURCE.AI
    if TCAutoDrive.isDriving(vehicle) then
        source = TheContractorLogbook.SOURCE.AUTODRIVE
    elseif vehicle.getJob ~= nil and TCCourseplay.isCpJob(vehicle:getJob()) then
        source = TheContractorLogbook.SOURCE.COURSEPLAY
    elseif vehicle.getJob ~= nil and TCFollowMe.isFollowMeJob(vehicle:getJob()) then
        source = TheContractorLogbook.SOURCE.FOLLOWME
    end
    session.sources[source] = true
end

-- "autodrive,courseplay" for the entry.
local function joinSources(sources)
    local list = {}
    for _, source in ipairs({ TheContractorLogbook.SOURCE.AUTODRIVE, TheContractorLogbook.SOURCE.COURSEPLAY,
        TheContractorLogbook.SOURCE.FOLLOWME, TheContractorLogbook.SOURCE.AI }) do
        if sources[source] then
            table.insert(list, source)
        end
    end
    return table.concat(list, ",")
end

-- From Drivers:releaseDriver. vehicle is nil if it's been sold (and its
-- history with it, so there's nothing to log).
function TheContractorLogbook:onDriverReleased(vehicleId, vehicle, binding)
    if not g_currentMission:getIsServer() then
        return
    end
    local session = self.driverSessions[vehicleId]
    self.driverSessions[vehicleId] = nil
    if session == nil then
        return
    end
    self:closeDriverSession(session, vehicle, binding.activeMs / 60000)
end

function TheContractorLogbook:closeDriverSession(session, vehicle, minutes)
    if minutes < TheContractorLogbook.MIN_SESSION_MINUTES then
        return
    end

    local record = self:getVehicleRecord(vehicle, true)
    if record == nil then
        return
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(session.farmId, session.workerId)
    local endSnapshot = TCVehicleCondition.capture(vehicle)
    self:addVehicleEntry(record, {
        kind = TheContractorLogbook.KIND.DRIVER,
        farmId = session.farmId,
        day = getToday(),
        endedAt = TheContractorJobs.getGameMinutes(),
        minutes = minutes,
        who = worker ~= nil and worker.name or nil,
        workerId = session.workerId,
        source = joinSources(session.sources),
        startSnapshot = session.start,
        endSnapshot = endSnapshot,
        wearCost = TCVehicleCondition.getWearCost(vehicle, session.start, endSnapshot),
    })
end

-- Server: a standalone vehicle entry (driver or player), applied and sent.
function TheContractorLogbook:addVehicleEntry(record, entry)
    self:applyVehicleEntry(record, entry)
    if g_server ~= nil then
        g_server:broadcastEvent(TCLogVehicleEntryEvent.new(record, entry))
    end
end

-- 069 (server): a stolen vehicle the police recovered. startSnapshot is its
-- condition before the thieves' damage was added.
function TheContractorLogbook:recordTheftRecovered(farmId, vehicle, startSnapshot, minutes)
    local record = self:getVehicleRecord(vehicle, true)
    if record == nil then
        return
    end
    local endSnapshot = TCVehicleCondition.capture(vehicle)
    self:addVehicleEntry(record, {
        kind = TheContractorLogbook.KIND.THEFT,
        farmId = farmId,
        day = getToday(),
        endedAt = TheContractorJobs.getGameMinutes(),
        minutes = minutes,
        startSnapshot = startSnapshot,
        endSnapshot = endSnapshot,
        wearCost = TCVehicleCondition.getWearCost(vehicle, startSnapshot, endSnapshot),
    })
end

-- Player sessions (server) ------------------------------------------------------

-- Machines out on an allocated/in-progress job: a player in one is doing
-- the job, which its own entry covers.
local function getActiveJobVehicles()
    local result = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS then
                for _, vehicleId in ipairs(job:getAllEquipmentIds()) do
                    result[vehicleId] = job
                end
            end
        end
    end
    return result
end

local function getControllerName(vehicle)
    local name = vehicle.getControllerName ~= nil and vehicle:getControllerName() or ""
    if name == nil or name == "" then
        return g_i18n:getText("tc_logbook_aPlayer")
    end
    return name
end

function TheContractorLogbook:updatePlayerSessions(dt)
    self.playerPollMs = self.playerPollMs + dt
    if self.playerPollMs < TheContractorLogbook.PLAYER_POLL_MS then
        return
    end
    local elapsedMinutes = self.playerPollMs * g_currentMission:getEffectiveTimeScale() / 60000
    self.playerPollMs = 0

    local activeJobVehicles = getActiveJobVehicles()
    local seen = {}

    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        -- 100: a customer's machine has no logbook of ours.
        if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() and vehicle.getOwnerFarmId ~= nil and
                vehicle:getOwnerFarmId() ~= FarmManager.SPECTATOR_FARM_ID and
                not (TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle)) then
            local who = getControllerName(vehicle)
            local job = activeJobVehicles[NetworkUtil.getObjectId(vehicle)]
            if job ~= nil then
                -- Doing a job themselves: the job entry gets their name.
                if job.assignedWorkerId == nil then
                    getPending(self, job).playerName = who
                end
            else
                local record = self:getVehicleRecord(vehicle, false)
                if record ~= nil and self:hasRecentJobUse(record) then
                    seen[vehicle] = true
                    local session = self.playerSessions[vehicle]
                    if session ~= nil and session.who ~= who then
                        self:closePlayerSession(vehicle, session)
                        session = nil
                    end
                    if session == nil then
                        self.playerSessions[vehicle] = {
                            farmId = vehicle:getOwnerFarmId(),
                            who = who,
                            minutes = 0,
                            start = TCVehicleCondition.capture(vehicle),
                        }
                    else
                        session.minutes = session.minutes + elapsedMinutes
                    end
                end
            end
        end
    end

    for vehicle, session in pairs(self.playerSessions) do
        if not seen[vehicle] then
            self:closePlayerSession(vehicle, session)
        end
    end
end

function TheContractorLogbook:closePlayerSession(vehicle, session)
    self.playerSessions[vehicle] = nil
    if session.minutes < TheContractorLogbook.MIN_SESSION_MINUTES then
        return
    end

    if vehicle == nil or vehicle.isDeleted then
        return
    end
    local record = self:getVehicleRecord(vehicle, true)
    if record == nil then
        return
    end

    local endSnapshot = TCVehicleCondition.capture(vehicle)
    self:addVehicleEntry(record, {
        kind = TheContractorLogbook.KIND.PLAYER,
        farmId = session.farmId,
        day = getToday(),
        endedAt = TheContractorJobs.getGameMinutes(),
        minutes = session.minutes,
        who = session.who,
        startSnapshot = session.start,
        endSnapshot = endSnapshot,
        wearCost = TCVehicleCondition.getWearCost(vehicle, session.start, endSnapshot),
    })
end

-- Update / ticks --------------------------------------------------------------------

-- Every frame from TheContractor:update, after Drivers (which relinks its
-- saved bindings - and so our driver sessions - on its first update).
function TheContractorLogbook:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    -- Driver sessions the save left open that Drivers didn't bind again.
    if not self.hasClosedLoadedSessions then
        self.hasClosedLoadedSessions = true
        local loaded = self.loadedDriverSessions
        self.loadedDriverSessions = {}
        for vehicleId, session in pairs(loaded) do
            self:closeDriverSession(session, NetworkUtil.getObject(vehicleId), session.minutes or 0)
        end
    end

    self:updatePlayerSessions(dt)
end

-- Server, once vehicles exist (TheContractor:resolveSavedVehicles): the
-- saved uniqueIds back to object ids. Records and machines whose vehicle is
-- gone drop out; player sessions the save left open are closed off.
function TheContractorLogbook:resolveSavedVehicles()
    for _, saved in ipairs(self.savedVehicles) do
        local vehicleId = TCVehicleIds.getObjectId(saved.uniqueId)
        if vehicleId ~= nil then
            self.vehicles[vehicleId] = { vehicleId = vehicleId, name = saved.name, entries = saved.entries }
        end
    end
    self.savedVehicles = {}

    for _, farmEntries in pairs(self.jobEntriesByFarm) do
        for _, entry in pairs(farmEntries) do
            for _, machine in ipairs(entry.equipment) do
                if machine.savedUniqueId ~= nil then
                    machine.vehicleId = TCVehicleIds.getObjectId(machine.savedUniqueId)
                    machine.savedUniqueId = nil
                end
            end
        end
    end

    for _, pending in pairs(self.pendingByJobId) do
        for uniqueId, snapshot in pairs(pending.savedStart or {}) do
            local vehicleId = TCVehicleIds.getObjectId(uniqueId)
            if vehicleId ~= nil then
                pending.start[vehicleId] = snapshot
            end
        end
        pending.savedStart = nil
    end

    local sessions = self.savedSessions
    self.savedSessions = {}
    for _, session in ipairs(sessions) do
        local vehicleId = TCVehicleIds.getObjectId(session.uniqueId)
        session.uniqueId = nil
        if vehicleId ~= nil then
            if session.kind == TheContractorLogbook.KIND.DRIVER then
                self.loadedDriverSessions[vehicleId] = session
            else
                self:closePlayerSession(NetworkUtil.getObject(vehicleId), session)
            end
        end
    end
end

-- Every machine: the same pruning from the same synced day, so it needs no
-- event.
function TheContractorLogbook:startDailyTick()
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.prune, self)
end

function TheContractorLogbook:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorLogbook:prune()
    local today = getToday()
    local jobCutoff = today - getYearDays() * TheContractorLogbook.JOB_RETENTION_YEARS
    local vehicleCutoff = today - getYearDays() * TheContractorLogbook.VEHICLE_RETENTION_YEARS

    for _, farmEntries in pairs(self.jobEntriesByFarm) do
        for jobId, entry in pairs(farmEntries) do
            if entry.day < jobCutoff then
                farmEntries[jobId] = nil
            end
        end
    end

    for vehicleId, record in pairs(self.vehicles) do
        local kept = {}
        for _, entry in ipairs(record.entries) do
            if entry.day >= vehicleCutoff then
                table.insert(kept, entry)
            end
        end
        record.entries = kept
        if #kept == 0 then
            self.vehicles[vehicleId] = nil
        end
    end
end

-- Applying (every machine) ----------------------------------------------------------

function TheContractorLogbook:applyJobEntry(entry)
    self.jobEntriesByFarm[entry.farmId] = self.jobEntriesByFarm[entry.farmId] or {}
    self.jobEntriesByFarm[entry.farmId][entry.jobId] = entry
end

-- record is the server's own record, or the header a client read
-- (vehicleId, name).
function TheContractorLogbook:applyVehicleEntry(record, entry)
    local local_ = self.vehicles[record.vehicleId]
    if local_ == nil then
        local_ = { vehicleId = record.vehicleId, entries = {} }
        self.vehicles[record.vehicleId] = local_
    end
    local_.name = record.name
    if entry ~= nil then
        table.insert(local_.entries, entry)
    end
end

function TheContractorLogbook:applyClaim(farmId, jobId, claim)
    local entry = self:getJobEntry(farmId, jobId)
    if entry == nil then
        return false
    end
    entry.claim = claim
    return true
end

-- Every machine (Staff:announceGrowth, TCWorkerGrewEvent): a worker grew
-- `stat` from `oldValue` (nil: newly certified on a tractor size) to
-- `newValue` from a job, so it goes on their row in its entry. False if the
-- job or the worker isn't in the logbook.
function TheContractorLogbook:applyGrowth(farmId, jobId, workerId, stat, oldValue, newValue)
    local entry = self:getJobEntry(farmId, jobId)
    for _, member in ipairs(entry ~= nil and entry.crew or {}) do
        if member.workerId == workerId then
            member.growth = member.growth or {}
            table.insert(member.growth, { stat = stat, from = oldValue, to = newValue })
            return true
        end
    end
    return false
end

-- Queries -----------------------------------------------------------------------------

function TheContractorLogbook:getJobEntry(farmId, jobId)
    local farmEntries = self.jobEntriesByFarm[farmId]
    return farmEntries ~= nil and farmEntries[jobId] or nil
end

-- The farm's job entries, newest first.
function TheContractorLogbook:getJobEntries(farmId)
    local result = {}
    for _, entry in pairs(self.jobEntriesByFarm[farmId] or {}) do
        table.insert(result, entry)
    end
    table.sort(result, function(a, b)
        if (a.completedAt or -1) ~= (b.completedAt or -1) then
            return (a.completedAt or -1) > (b.completedAt or -1)
        end
        return a.jobId > b.jobId
    end)
    return result
end

-- A vehicle's entries for a farm, newest first.
function TheContractorLogbook.getVehicleEntries(record, farmId)
    local result = {}
    for _, entry in ipairs(record.entries) do
        if entry.farmId == farmId then
            table.insert(result, entry)
        end
    end
    table.sort(result, function(a, b)
        return (a.endedAt or a.day * 1440) > (b.endedAt or b.day * 1440)
    end)
    return result
end

-- What the business paid on the job's claim, if there was one.
function TheContractorLogbook.getClaimPaid(entry)
    return entry.claim ~= nil and entry.claim.paid or 0
end

-- How many of a job's machines have a wear cost and how many don't (ADS
-- ones, TCVehicleCondition.hasWearCost): priced, unpriced.
function TheContractorLogbook.countWearCosts(entry)
    local priced, unpriced = 0, 0
    for _, machine in ipairs(entry.equipment or {}) do
        if TCVehicleCondition.hasWearCost(machine.startSnapshot, machine.endSnapshot) then
            priced = priced + 1
        else
            unpriced = unpriced + 1
        end
    end
    return priced, unpriced
end

-- Price earned less fuel, supplies (158), labour, wear and any claim paid.
-- ADS machines' wear has no cost, so it isn't in here (countWearCosts).
function TheContractorLogbook.getMargin(entry)
    return (entry.price or 0) - (entry.fuelCost or 0) - TheContractorLogbook.getSuppliesCost(entry) -
        (entry.labourCost or 0) - (entry.wearCost or 0) - TheContractorLogbook.getClaimPaid(entry)
end

-- "good"/"warn"/"bad" for a job's margin chip.
function TheContractorLogbook.getMarginTone(entry)
    if entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
        return "bad"
    end
    local margin = TheContractorLogbook.getMargin(entry)
    if margin < 0 then
        return "bad"
    elseif margin < (entry.price or 0) * TheContractorLogbook.THIN_MARGIN_RATIO then
        return "warn"
    end
    return "good"
end

-- The job's invoice (049), if one was issued.
function TheContractorLogbook.getInvoice(entry)
    for _, invoice in pairs(g_currentMission.TheContractor.Finances.invoicesById) do
        if invoice.farmId == entry.farmId and invoice.jobId == entry.jobId then
            return invoice
        end
    end
    return nil
end

-- 099: whether an ADS fault was found during a use (a job's machine or a
-- vehicle entry): one known at the end that wasn't at the start. Not
-- whether the use caused it (faultCaused): that's ADS's hidden state, and
-- the fault may have been there, undiscovered, before.
function TheContractorLogbook.hasFoundFault(entry)
    return #TCVehicleCondition.getNewFaults(entry.startSnapshot, entry.endSnapshot) > 0
end

-- One year's summary of a vehicle for a farm: { jobs, hours, faults (uses
-- a fault was found in), wearCost, last (newest entry) }.
function TheContractorLogbook.getVehicleSummary(record, farmId)
    local summary = { jobs = 0, hours = 0, faults = 0, wearCost = 0, last = nil }
    for _, entry in ipairs(TheContractorLogbook.getVehicleEntries(record, farmId)) do
        summary.last = summary.last or entry
        if entry.kind == TheContractorLogbook.KIND.JOB then
            summary.jobs = summary.jobs + 1
        end
        summary.hours = summary.hours + (TCVehicleCondition.getHoursBetween(entry.startSnapshot, entry.endSnapshot) or 0)
        if TheContractorLogbook.hasFoundFault(entry) then
            summary.faults = summary.faults + 1
        end
        summary.wearCost = summary.wearCost + (entry.wearCost or 0)
    end
    return summary
end

-- Network ------------------------------------------------------------------------------

local function writeString(streamId, value)
    streamWriteString(streamId, value or "")
end

local function readString(streamId)
    local value = streamReadString(streamId)
    return value ~= "" and value or nil
end

local function writeOptionalInt(streamId, value)
    streamWriteBool(streamId, value ~= nil)
    if value ~= nil then
        streamWriteInt32(streamId, value)
    end
end

local function readOptionalInt(streamId)
    if streamReadBool(streamId) then
        return streamReadInt32(streamId)
    end
    return nil
end

function TheContractorLogbook.writeClaim(streamId, claim)
    writeString(streamId, claim.cause)
    streamWriteFloat32(streamId, claim.amount or 0)
    streamWriteFloat32(streamId, claim.paid or 0)
    streamWriteBool(streamId, claim.insured == true)
    streamWriteInt32(streamId, claim.reputationPenalty or 0)
end

function TheContractorLogbook.readClaim(streamId)
    return {
        cause = readString(streamId),
        amount = streamReadFloat32(streamId),
        paid = streamReadFloat32(streamId),
        insured = streamReadBool(streamId),
        reputationPenalty = streamReadInt32(streamId),
    }
end

-- Issue #16: a crew member's growth list (nil for none).
function TheContractorLogbook.writeGrowth(streamId, growth)
    growth = growth or {}
    streamWriteUInt8(streamId, #growth)
    for _, grew in ipairs(growth) do
        writeString(streamId, grew.stat)
        writeOptionalInt(streamId, grew.from)
        streamWriteInt32(streamId, grew.to)
    end
end

function TheContractorLogbook.readGrowth(streamId)
    local count = streamReadUInt8(streamId)
    if count == 0 then
        return nil
    end
    local growth = {}
    for _ = 1, count do
        table.insert(growth, { stat = readString(streamId), from = readOptionalInt(streamId),
            to = streamReadInt32(streamId) })
    end
    return growth
end

function TheContractorLogbook.writeJobEntry(streamId, entry)
    streamWriteInt32(streamId, entry.jobId)
    streamWriteInt32(streamId, entry.farmId)
    writeString(streamId, entry.outcome)
    writeString(streamId, entry.jobType)
    writeString(streamId, entry.title)
    streamWriteInt32(streamId, entry.fieldId)
    writeOptionalInt(streamId, entry.requiredSkillLevel)
    streamWriteInt32(streamId, entry.day)
    writeOptionalFloat(streamId, entry.completedAt)
    writeOptionalFloat(streamId, entry.offeredPrice)
    writeOptionalFloat(streamId, entry.agreedPrice)
    streamWriteFloat32(streamId, entry.price or 0)
    writeOptionalInt(streamId, entry.reputation)
    writeOptionalInt(streamId, entry.qualityScore)
    streamWriteInt32(streamId, entry.stuckInterventions or 0)
    writeString(streamId, entry.earlierCrew)
    streamWriteFloat32(streamId, entry.completionPercentage or 0)
    streamWriteFloat32(streamId, entry.fuelLiters or 0)
    streamWriteFloat32(streamId, entry.fuelCost or 0)
    writeOptionalFloat(streamId, entry.travelMinutes)
    writeOptionalFloat(streamId, entry.fieldMinutes)
    writeOptionalFloat(streamId, entry.returnMinutes)
    writeOptionalFloat(streamId, entry.labourCost)
    writeOptionalFloat(streamId, entry.wearCost)

    streamWriteUInt8(streamId, #entry.crew)
    for _, member in ipairs(entry.crew) do
        writeOptionalInt(streamId, member.workerId)
        writeString(streamId, member.name)
        writeString(streamId, member.role)
        writeOptionalInt(streamId, member.rating)
        TheContractorLogbook.writeGrowth(streamId, member.growth)
    end

    streamWriteUInt8(streamId, #entry.equipment)
    for _, machine in ipairs(entry.equipment) do
        streamWriteInt32(streamId, machine.vehicleId or 0)
        writeString(streamId, machine.name)
        writeString(streamId, machine.workerName)
        TCVehicleCondition.writeStream(streamId, machine.startSnapshot)
        TCVehicleCondition.writeStream(streamId, machine.endSnapshot)
        writeOptionalInt(streamId, machine.extraWear)
        streamWriteBool(streamId, machine.faultCaused == true)
        streamWriteUInt8(streamId, machine.wash or 0)
        streamWriteFloat32(streamId, machine.wearCost or 0)
    end

    streamWriteUInt8(streamId, #entry.supplies)
    for _, supply in ipairs(entry.supplies) do
        writeString(streamId, supply.fillTypeName)
        streamWriteFloat32(streamId, supply.liters)
        writeOptionalFloat(streamId, supply.cost)
    end

    streamWriteBool(streamId, entry.claim ~= nil)
    if entry.claim ~= nil then
        TheContractorLogbook.writeClaim(streamId, entry.claim)
    end

    -- 100.
    writeString(streamId, entry.location)
    streamWriteInt32(streamId, entry.workshopFieldId or 0)
    -- 111.
    streamWriteInt32(streamId, entry.customerId or 0)
    -- 124.
    if streamWriteBool(streamId, entry.delivery ~= nil) then
        local delivery = entry.delivery
        writeString(streamId, delivery.fillTypeName)
        streamWriteFloat32(streamId, delivery.requiredLiters or 0)
        streamWriteFloat32(streamId, delivery.deliveredLiters or 0)
        streamWriteFloat32(streamId, delivery.excessLiters or 0)
        streamWriteFloat32(streamId, delivery.excessPay or 0)
        -- 126.
        writeString(streamId, delivery.stationName)
        -- 127.
        writeString(streamId, delivery.machineName)
    end
end

function TheContractorLogbook.readJobEntry(streamId)
    local entry = {
        jobId = streamReadInt32(streamId),
        farmId = streamReadInt32(streamId),
        outcome = readString(streamId),
        jobType = readString(streamId),
        title = readString(streamId),
        fieldId = streamReadInt32(streamId),
        requiredSkillLevel = readOptionalInt(streamId),
        day = streamReadInt32(streamId),
        completedAt = readOptionalFloat(streamId),
        offeredPrice = readOptionalFloat(streamId),
        agreedPrice = readOptionalFloat(streamId),
        price = streamReadFloat32(streamId),
        reputation = readOptionalInt(streamId),
        qualityScore = readOptionalInt(streamId),
        stuckInterventions = streamReadInt32(streamId),
        earlierCrew = readString(streamId),
        completionPercentage = streamReadFloat32(streamId),
        fuelLiters = streamReadFloat32(streamId),
        fuelCost = streamReadFloat32(streamId),
        travelMinutes = readOptionalFloat(streamId),
        fieldMinutes = readOptionalFloat(streamId),
        returnMinutes = readOptionalFloat(streamId),
        labourCost = readOptionalFloat(streamId),
        wearCost = readOptionalFloat(streamId),
        crew = {},
        equipment = {},
        supplies = {},
    }

    for _ = 1, streamReadUInt8(streamId) do
        table.insert(entry.crew, {
            workerId = readOptionalInt(streamId),
            name = readString(streamId),
            role = readString(streamId),
            rating = readOptionalInt(streamId),
            growth = TheContractorLogbook.readGrowth(streamId),
        })
    end

    for _ = 1, streamReadUInt8(streamId) do
        local vehicleId = streamReadInt32(streamId)
        table.insert(entry.equipment, {
            vehicleId = vehicleId ~= 0 and vehicleId or nil,
            name = readString(streamId),
            workerName = readString(streamId),
            startSnapshot = TCVehicleCondition.readStream(streamId),
            endSnapshot = TCVehicleCondition.readStream(streamId),
            extraWear = readOptionalInt(streamId),
            faultCaused = streamReadBool(streamId),
            wash = streamReadUInt8(streamId),
            wearCost = streamReadFloat32(streamId),
        })
    end

    for _ = 1, streamReadUInt8(streamId) do
        table.insert(entry.supplies, { fillTypeName = readString(streamId), liters = streamReadFloat32(streamId),
            cost = readOptionalFloat(streamId) })
    end

    if streamReadBool(streamId) then
        entry.claim = TheContractorLogbook.readClaim(streamId)
    end

    entry.location = readString(streamId)
    local workshopFieldId = streamReadInt32(streamId)
    entry.workshopFieldId = workshopFieldId ~= 0 and workshopFieldId or nil
    local customerId = streamReadInt32(streamId)
    entry.customerId = customerId ~= 0 and customerId or nil
    if streamReadBool(streamId) then
        entry.delivery = {
            fillTypeName = readString(streamId),
            requiredLiters = streamReadFloat32(streamId),
            deliveredLiters = streamReadFloat32(streamId),
            excessLiters = streamReadFloat32(streamId),
            excessPay = streamReadFloat32(streamId),
            stationName = readString(streamId),
            machineName = readString(streamId),
        }
    end
    return entry
end

-- A vehicle's object id and name. Clients key records by the id and look
-- the vehicle up lazily (it may not be streamed in yet).
function TheContractorLogbook.writeVehicleHeader(streamId, record)
    streamWriteInt32(streamId, record.vehicleId)
    writeString(streamId, record.name)
end

function TheContractorLogbook.readVehicleHeader(streamId)
    return { vehicleId = streamReadInt32(streamId), name = readString(streamId) }
end

function TheContractorLogbook.writeVehicleEntry(streamId, entry)
    writeString(streamId, entry.kind)
    streamWriteInt32(streamId, entry.farmId)
    streamWriteInt32(streamId, entry.day)
    writeOptionalFloat(streamId, entry.endedAt)
    writeOptionalFloat(streamId, entry.minutes)
    writeString(streamId, entry.who)
    writeOptionalInt(streamId, entry.workerId)
    writeOptionalInt(streamId, entry.jobId)
    writeString(streamId, entry.jobTitle)
    writeString(streamId, entry.outcome)
    writeString(streamId, entry.source)
    TCVehicleCondition.writeStream(streamId, entry.startSnapshot)
    TCVehicleCondition.writeStream(streamId, entry.endSnapshot)
    streamWriteBool(streamId, entry.faultCaused == true)
    streamWriteUInt8(streamId, entry.wash or 0)
    streamWriteFloat32(streamId, entry.wearCost or 0)
end

function TheContractorLogbook.readVehicleEntry(streamId)
    return {
        kind = readString(streamId),
        farmId = streamReadInt32(streamId),
        day = streamReadInt32(streamId),
        endedAt = readOptionalFloat(streamId),
        minutes = readOptionalFloat(streamId),
        who = readString(streamId),
        workerId = readOptionalInt(streamId),
        jobId = readOptionalInt(streamId),
        jobTitle = readString(streamId),
        outcome = readString(streamId),
        source = readString(streamId),
        startSnapshot = TCVehicleCondition.readStream(streamId),
        endSnapshot = TCVehicleCondition.readStream(streamId),
        faultCaused = streamReadBool(streamId),
        wash = streamReadUInt8(streamId),
        wearCost = streamReadFloat32(streamId),
    }
end

function TheContractorLogbook:writeInitialClientState(streamId, connection)
    local entries = {}
    for _, farmEntries in pairs(self.jobEntriesByFarm) do
        for _, entry in pairs(farmEntries) do
            table.insert(entries, entry)
        end
    end
    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        TheContractorLogbook.writeJobEntry(streamId, entry)
    end

    local records = {}
    for _, record in pairs(self.vehicles) do
        table.insert(records, record)
    end
    streamWriteInt32(streamId, #records)
    for _, record in ipairs(records) do
        TheContractorLogbook.writeVehicleHeader(streamId, record)
        streamWriteInt32(streamId, #record.entries)
        for _, entry in ipairs(record.entries) do
            TheContractorLogbook.writeVehicleEntry(streamId, entry)
        end
    end
end

function TheContractorLogbook:readInitialClientState(streamId, connection)
    for _ = 1, streamReadInt32(streamId) do
        self:applyJobEntry(TheContractorLogbook.readJobEntry(streamId))
    end
    for _ = 1, streamReadInt32(streamId) do
        local header = TheContractorLogbook.readVehicleHeader(streamId)
        self:applyVehicleEntry(header, nil)
        for _ = 1, streamReadInt32(streamId) do
            self:applyVehicleEntry(header, TheContractorLogbook.readVehicleEntry(streamId))
        end
    end
end

-- Save / load --------------------------------------------------------------------------

local function saveClaim(xmlFile, key, claim)
    setXMLString(xmlFile, key .. "#cause", claim.cause or "")
    setXMLFloat(xmlFile, key .. "#amount", claim.amount or 0)
    setXMLFloat(xmlFile, key .. "#paid", claim.paid or 0)
    setXMLBool(xmlFile, key .. "#insured", claim.insured == true)
    setXMLInt(xmlFile, key .. "#reputationPenalty", claim.reputationPenalty or 0)
end

local function loadClaim(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local cause = getXMLString(xmlFile, key .. "#cause")
    return {
        cause = cause ~= "" and cause or nil,
        amount = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#amount"), 0),
        paid = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#paid"), 0),
        insured = Utils.getNoNil(getXMLBool(xmlFile, key .. "#insured"), false),
        reputationPenalty = Utils.getNoNil(getXMLInt(xmlFile, key .. "#reputationPenalty"), 0),
    }
end

local function saveJobEntry(xmlFile, key, entry)
    setXMLInt(xmlFile, key .. "#jobId", entry.jobId)
    setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
    setXMLString(xmlFile, key .. "#outcome", entry.outcome)
    setXMLString(xmlFile, key .. "#jobType", entry.jobType or "")
    setXMLString(xmlFile, key .. "#title", entry.title or "")
    setXMLInt(xmlFile, key .. "#fieldId", entry.fieldId)
    if entry.location ~= nil then
        setXMLString(xmlFile, key .. "#location", entry.location)
    end
    if entry.workshopFieldId ~= nil then
        setXMLInt(xmlFile, key .. "#workshopFieldId", entry.workshopFieldId)
    end
    if entry.customerId ~= nil then
        setXMLInt(xmlFile, key .. "#customerId", entry.customerId)
    end
    if entry.requiredSkillLevel ~= nil then
        setXMLInt(xmlFile, key .. "#requiredSkill", entry.requiredSkillLevel)
    end
    setXMLInt(xmlFile, key .. "#day", entry.day)
    setOptionalFloat(xmlFile, key .. "#completedAt", entry.completedAt)
    setOptionalFloat(xmlFile, key .. "#offeredPrice", entry.offeredPrice)
    setOptionalFloat(xmlFile, key .. "#agreedPrice", entry.agreedPrice)
    setXMLFloat(xmlFile, key .. "#price", entry.price or 0)
    if entry.reputation ~= nil then
        setXMLInt(xmlFile, key .. "#reputation", entry.reputation)
    end
    if entry.qualityScore ~= nil then
        setXMLInt(xmlFile, key .. "#quality", entry.qualityScore)
    end
    setXMLInt(xmlFile, key .. "#stuckInterventions", entry.stuckInterventions or 0)
    if entry.earlierCrew ~= nil then
        setXMLString(xmlFile, key .. "#earlierCrew", entry.earlierCrew)
    end
    setXMLFloat(xmlFile, key .. "#completion", entry.completionPercentage or 0)
    setXMLFloat(xmlFile, key .. "#fuelLiters", entry.fuelLiters or 0)
    setXMLFloat(xmlFile, key .. "#fuelCost", entry.fuelCost or 0)
    setOptionalFloat(xmlFile, key .. "#travelMinutes", entry.travelMinutes)
    setOptionalFloat(xmlFile, key .. "#fieldMinutes", entry.fieldMinutes)
    setOptionalFloat(xmlFile, key .. "#returnMinutes", entry.returnMinutes)
    setOptionalFloat(xmlFile, key .. "#labourCost", entry.labourCost)
    setOptionalFloat(xmlFile, key .. "#wearCost", entry.wearCost)

    for i, member in ipairs(entry.crew) do
        local crewKey = string.format("%s.crew(%d)", key, i - 1)
        if member.workerId ~= nil then
            setXMLInt(xmlFile, crewKey .. "#workerId", member.workerId)
        end
        if member.name ~= nil then
            setXMLString(xmlFile, crewKey .. "#name", member.name)
        end
        setXMLString(xmlFile, crewKey .. "#role", member.role or TheContractorLogbook.ROLE.OPERATOR)
        if member.rating ~= nil then
            setXMLInt(xmlFile, crewKey .. "#rating", member.rating)
        end
        for j, grew in ipairs(member.growth or {}) do
            local growthKey = string.format("%s.growth(%d)", crewKey, j - 1)
            setXMLString(xmlFile, growthKey .. "#stat", grew.stat)
            if grew.from ~= nil then
                setXMLInt(xmlFile, growthKey .. "#from", grew.from)
            end
            setXMLInt(xmlFile, growthKey .. "#to", grew.to)
        end
    end

    for i, machine in ipairs(entry.equipment) do
        local machineKey = string.format("%s.equipment(%d)", key, i - 1)
        local uniqueId = TCVehicleIds.getUniqueId(machine.vehicleId)
        if uniqueId ~= nil then
            setXMLString(xmlFile, machineKey .. "#uniqueId", uniqueId)
        end
        setXMLString(xmlFile, machineKey .. "#name", machine.name or "")
        if machine.workerName ~= nil then
            setXMLString(xmlFile, machineKey .. "#worker", machine.workerName)
        end
        if machine.extraWear ~= nil then
            setXMLInt(xmlFile, machineKey .. "#extraWear", machine.extraWear)
        end
        setXMLBool(xmlFile, machineKey .. "#faultCaused", machine.faultCaused == true)
        setXMLInt(xmlFile, machineKey .. "#wash", machine.wash or 0)
        setXMLFloat(xmlFile, machineKey .. "#wearCost", machine.wearCost or 0)
        TCVehicleCondition.saveToXML(xmlFile, machineKey .. ".start", machine.startSnapshot)
        TCVehicleCondition.saveToXML(xmlFile, machineKey .. ".end", machine.endSnapshot)
    end

    for i, supply in ipairs(entry.supplies) do
        local supplyKey = string.format("%s.supply(%d)", key, i - 1)
        setXMLString(xmlFile, supplyKey .. "#fillType", supply.fillTypeName)
        setXMLFloat(xmlFile, supplyKey .. "#liters", supply.liters)
        setOptionalFloat(xmlFile, supplyKey .. "#cost", supply.cost)
    end

    if entry.claim ~= nil then
        saveClaim(xmlFile, key .. ".claim", entry.claim)
    end

    -- 124.
    if entry.delivery ~= nil then
        local delivery = entry.delivery
        setXMLString(xmlFile, key .. ".delivery#fillType", delivery.fillTypeName or "")
        setXMLFloat(xmlFile, key .. ".delivery#requiredLiters", delivery.requiredLiters or 0)
        setXMLFloat(xmlFile, key .. ".delivery#deliveredLiters", delivery.deliveredLiters or 0)
        setXMLFloat(xmlFile, key .. ".delivery#excessLiters", delivery.excessLiters or 0)
        setXMLFloat(xmlFile, key .. ".delivery#excessPay", delivery.excessPay or 0)
        if delivery.stationName ~= nil then
            setXMLString(xmlFile, key .. ".delivery#stationName", delivery.stationName)
        end
        if delivery.machineName ~= nil then
            setXMLString(xmlFile, key .. ".delivery#machineName", delivery.machineName)
        end
    end
end

local function loadJobEntry(xmlFile, key)
    local entry = {
        jobId = getXMLInt(xmlFile, key .. "#jobId"),
        farmId = getXMLInt(xmlFile, key .. "#farmId"),
        outcome = Utils.getNoNil(getXMLString(xmlFile, key .. "#outcome"), TheContractorLogbook.OUTCOME.COMPLETED),
        jobType = getXMLString(xmlFile, key .. "#jobType"),
        title = getXMLString(xmlFile, key .. "#title"),
        fieldId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#fieldId"), 0),
        location = getXMLString(xmlFile, key .. "#location"),
        workshopFieldId = getXMLInt(xmlFile, key .. "#workshopFieldId"),
        -- 111: nil from an older save until TheContractorFarmers:linkLogbook.
        customerId = getXMLInt(xmlFile, key .. "#customerId"),
        requiredSkillLevel = getXMLInt(xmlFile, key .. "#requiredSkill"),
        day = Utils.getNoNil(getXMLInt(xmlFile, key .. "#day"), 0),
        completedAt = getXMLFloat(xmlFile, key .. "#completedAt"),
        offeredPrice = getXMLFloat(xmlFile, key .. "#offeredPrice"),
        agreedPrice = getXMLFloat(xmlFile, key .. "#agreedPrice"),
        price = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#price"), 0),
        reputation = getXMLInt(xmlFile, key .. "#reputation"),
        qualityScore = getXMLInt(xmlFile, key .. "#quality"),
        stuckInterventions = Utils.getNoNil(getXMLInt(xmlFile, key .. "#stuckInterventions"), 0),
        earlierCrew = getXMLString(xmlFile, key .. "#earlierCrew"),
        completionPercentage = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#completion"), 0),
        fuelLiters = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#fuelLiters"), 0),
        fuelCost = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#fuelCost"), 0),
        travelMinutes = getXMLFloat(xmlFile, key .. "#travelMinutes"),
        fieldMinutes = getXMLFloat(xmlFile, key .. "#fieldMinutes"),
        returnMinutes = getXMLFloat(xmlFile, key .. "#returnMinutes"),
        labourCost = getXMLFloat(xmlFile, key .. "#labourCost"),
        wearCost = getXMLFloat(xmlFile, key .. "#wearCost"),
        crew = {},
        equipment = {},
        supplies = {},
        claim = loadClaim(xmlFile, key .. ".claim"),
    }
    if entry.jobId == nil or entry.farmId == nil then
        return nil
    end
    -- 124.
    if hasXMLProperty(xmlFile, key .. ".delivery") then
        entry.delivery = {
            fillTypeName = getXMLString(xmlFile, key .. ".delivery#fillType"),
            requiredLiters = Utils.getNoNil(getXMLFloat(xmlFile, key .. ".delivery#requiredLiters"), 0),
            deliveredLiters = Utils.getNoNil(getXMLFloat(xmlFile, key .. ".delivery#deliveredLiters"), 0),
            excessLiters = Utils.getNoNil(getXMLFloat(xmlFile, key .. ".delivery#excessLiters"), 0),
            excessPay = Utils.getNoNil(getXMLFloat(xmlFile, key .. ".delivery#excessPay"), 0),
            stationName = getXMLString(xmlFile, key .. ".delivery#stationName"),
            machineName = getXMLString(xmlFile, key .. ".delivery#machineName"),
        }
    end

    local index = 0
    while true do
        local crewKey = string.format("%s.crew(%d)", key, index)
        if not hasXMLProperty(xmlFile, crewKey) then
            break
        end
        local member = {
            workerId = getXMLInt(xmlFile, crewKey .. "#workerId"),
            name = getXMLString(xmlFile, crewKey .. "#name"),
            role = Utils.getNoNil(getXMLString(xmlFile, crewKey .. "#role"), TheContractorLogbook.ROLE.OPERATOR),
            rating = getXMLInt(xmlFile, crewKey .. "#rating"),
        }
        local growthIndex = 0
        while true do
            local growthKey = string.format("%s.growth(%d)", crewKey, growthIndex)
            local stat = getXMLString(xmlFile, growthKey .. "#stat")
            local to = getXMLInt(xmlFile, growthKey .. "#to")
            if stat == nil or to == nil then
                break
            end
            member.growth = member.growth or {}
            table.insert(member.growth, { stat = stat, from = getXMLInt(xmlFile, growthKey .. "#from"), to = to })
            growthIndex = growthIndex + 1
        end
        table.insert(entry.crew, member)
        index = index + 1
    end

    index = 0
    while true do
        local machineKey = string.format("%s.equipment(%d)", key, index)
        if not hasXMLProperty(xmlFile, machineKey) then
            break
        end
        table.insert(entry.equipment, {
            -- Until resolveSavedVehicles.
            savedUniqueId = getXMLString(xmlFile, machineKey .. "#uniqueId"),
            name = getXMLString(xmlFile, machineKey .. "#name"),
            workerName = getXMLString(xmlFile, machineKey .. "#worker"),
            extraWear = getXMLInt(xmlFile, machineKey .. "#extraWear"),
            faultCaused = Utils.getNoNil(getXMLBool(xmlFile, machineKey .. "#faultCaused"), false),
            wash = Utils.getNoNil(getXMLInt(xmlFile, machineKey .. "#wash"), 0),
            wearCost = Utils.getNoNil(getXMLFloat(xmlFile, machineKey .. "#wearCost"), 0),
            startSnapshot = TCVehicleCondition.loadFromXML(xmlFile, machineKey .. ".start"),
            endSnapshot = TCVehicleCondition.loadFromXML(xmlFile, machineKey .. ".end"),
        })
        index = index + 1
    end

    index = 0
    while true do
        local supplyKey = string.format("%s.supply(%d)", key, index)
        if not hasXMLProperty(xmlFile, supplyKey) then
            break
        end
        table.insert(entry.supplies, {
            fillTypeName = getXMLString(xmlFile, supplyKey .. "#fillType"),
            liters = Utils.getNoNil(getXMLFloat(xmlFile, supplyKey .. "#liters"), 0),
            cost = getXMLFloat(xmlFile, supplyKey .. "#cost"),
        })
        index = index + 1
    end
    return entry
end

local function saveVehicleEntry(xmlFile, key, entry)
    setXMLString(xmlFile, key .. "#kind", entry.kind)
    setXMLInt(xmlFile, key .. "#farmId", entry.farmId)
    setXMLInt(xmlFile, key .. "#day", entry.day)
    setOptionalFloat(xmlFile, key .. "#endedAt", entry.endedAt)
    setOptionalFloat(xmlFile, key .. "#minutes", entry.minutes)
    if entry.who ~= nil then
        setXMLString(xmlFile, key .. "#who", entry.who)
    end
    if entry.workerId ~= nil then
        setXMLInt(xmlFile, key .. "#workerId", entry.workerId)
    end
    if entry.jobId ~= nil then
        setXMLInt(xmlFile, key .. "#jobId", entry.jobId)
    end
    if entry.jobTitle ~= nil then
        setXMLString(xmlFile, key .. "#jobTitle", entry.jobTitle)
    end
    if entry.outcome ~= nil then
        setXMLString(xmlFile, key .. "#outcome", entry.outcome)
    end
    if entry.source ~= nil and entry.source ~= "" then
        setXMLString(xmlFile, key .. "#source", entry.source)
    end
    setXMLBool(xmlFile, key .. "#faultCaused", entry.faultCaused == true)
    setXMLInt(xmlFile, key .. "#wash", entry.wash or 0)
    setXMLFloat(xmlFile, key .. "#wearCost", entry.wearCost or 0)
    TCVehicleCondition.saveToXML(xmlFile, key .. ".start", entry.startSnapshot)
    TCVehicleCondition.saveToXML(xmlFile, key .. ".end", entry.endSnapshot)
end

local function loadVehicleEntry(xmlFile, key)
    return {
        kind = Utils.getNoNil(getXMLString(xmlFile, key .. "#kind"), TheContractorLogbook.KIND.JOB),
        farmId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#farmId"), 0),
        day = Utils.getNoNil(getXMLInt(xmlFile, key .. "#day"), 0),
        endedAt = getXMLFloat(xmlFile, key .. "#endedAt"),
        minutes = getXMLFloat(xmlFile, key .. "#minutes"),
        who = getXMLString(xmlFile, key .. "#who"),
        workerId = getXMLInt(xmlFile, key .. "#workerId"),
        jobId = getXMLInt(xmlFile, key .. "#jobId"),
        jobTitle = getXMLString(xmlFile, key .. "#jobTitle"),
        outcome = getXMLString(xmlFile, key .. "#outcome"),
        source = getXMLString(xmlFile, key .. "#source"),
        faultCaused = Utils.getNoNil(getXMLBool(xmlFile, key .. "#faultCaused"), false),
        wash = Utils.getNoNil(getXMLInt(xmlFile, key .. "#wash"), 0),
        wearCost = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#wearCost"), 0),
        startSnapshot = TCVehicleCondition.loadFromXML(xmlFile, key .. ".start"),
        endSnapshot = TCVehicleCondition.loadFromXML(xmlFile, key .. ".end"),
    }
end

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
-- Every machine (TCVehicleReplace): a machine reloaded as a new object
-- keeps its history, its place on a job's record and any open session.
function TheContractorLogbook:remapVehicle(oldId, newId)
    if TCVehicleIds.replaceKey(self.vehicles, oldId, newId) then
        self.vehicles[newId].vehicleId = newId
    end
    for _, entries in pairs(self.jobEntriesByFarm) do
        for _, entry in pairs(entries) do
            for _, machine in ipairs(entry.equipment or {}) do
                TCVehicleIds.replaceField(machine, "vehicleId", oldId, newId)
            end
        end
    end
    for _, pending in pairs(self.pendingByJobId) do
        TCVehicleIds.replaceKey(pending.start, oldId, newId)
    end
    TCVehicleIds.replaceKey(self.driverSessions, oldId, newId)
    TCVehicleIds.replaceKey(self.loadedDriverSessions, oldId, newId)
    TCVehicleIds.replaceKey(self.playerSessions, oldId, newId)
end

function TheContractorLogbook:forgetFarm(farmId, jobIds)
    self.jobEntriesByFarm[farmId] = nil
    for _, jobId in ipairs(jobIds) do
        self.pendingByJobId[jobId] = nil
    end
    for vehicleId, session in pairs(self.driverSessions) do
        if session.farmId == farmId then
            self.driverSessions[vehicleId] = nil
        end
    end
    for vehicleId, session in pairs(self.playerSessions) do
        if session.farmId == farmId then
            self.playerSessions[vehicleId] = nil
        end
    end
end

function TheContractorLogbook:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.jobEntriesByFarm = {}
    self.vehicles = {}
    self.pendingByJobId = {}
    self.loadedDriverSessions = {}
    self.savedVehicles = {}
    self.savedSessions = {}

    local rootKey = string.format("%s.logbook", TheContractor.SaveKey)

    local index = 0
    while true do
        local key = string.format("%s.job(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local entry = loadJobEntry(xmlFile, key)
        if entry ~= nil then
            self:applyJobEntry(entry)
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.vehicle(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local record = {
            uniqueId = getXMLString(xmlFile, key .. "#uniqueId"),
            name = getXMLString(xmlFile, key .. "#name"),
            entries = {},
        }
        local entryIndex = 0
        while true do
            local entryKey = string.format("%s.entry(%d)", key, entryIndex)
            if not hasXMLProperty(xmlFile, entryKey) then
                break
            end
            table.insert(record.entries, loadVehicleEntry(xmlFile, entryKey))
            entryIndex = entryIndex + 1
        end
        if record.uniqueId ~= nil then
            table.insert(self.savedVehicles, record)
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.pending(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local pending = {
            arrivedAt = getXMLFloat(xmlFile, key .. "#arrivedAt"),
            playerName = getXMLString(xmlFile, key .. "#playerName"),
            earlierCrew = getXMLString(xmlFile, key .. "#earlierCrew"),
            -- 158: a save from before it counted what was loaded, which
            -- includes what's in the tanks now.
            tanksCounted = Utils.getNoNil(getXMLBool(xmlFile, key .. "#tanksCounted"), true),
            start = {},
            -- By uniqueId until resolveSavedVehicles.
            savedStart = {},
            supplies = {},
        }
        local startIndex = 0
        while true do
            local startKey = string.format("%s.start(%d)", key, startIndex)
            if not hasXMLProperty(xmlFile, startKey) then
                break
            end
            local uniqueId = getXMLString(xmlFile, startKey .. "#uniqueId")
            if uniqueId ~= nil then
                pending.savedStart[uniqueId] = TCVehicleCondition.loadFromXML(xmlFile, startKey)
            end
            startIndex = startIndex + 1
        end
        local supplyIndex = 0
        while true do
            local supplyKey = string.format("%s.supply(%d)", key, supplyIndex)
            if not hasXMLProperty(xmlFile, supplyKey) then
                break
            end
            local name = getXMLString(xmlFile, supplyKey .. "#fillType")
            if name ~= nil then
                pending.supplies[name] = Utils.getNoNil(getXMLFloat(xmlFile, supplyKey .. "#liters"), 0)
            end
            supplyIndex = supplyIndex + 1
        end
        local jobId = getXMLInt(xmlFile, key .. "#jobId")
        if jobId ~= nil then
            self.pendingByJobId[jobId] = pending
        end
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.session(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local session = {
            uniqueId = getXMLString(xmlFile, key .. "#uniqueId"),
            kind = getXMLString(xmlFile, key .. "#kind"),
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            workerId = getXMLInt(xmlFile, key .. "#workerId"),
            who = getXMLString(xmlFile, key .. "#who"),
            minutes = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#minutes"), 0),
            start = TCVehicleCondition.loadFromXML(xmlFile, key .. ".start"),
            sources = {},
        }
        for source in string.gmatch(getXMLString(xmlFile, key .. "#sources") or "", "([^,]+)") do
            session.sources[source] = true
        end
        if session.uniqueId ~= nil and session.farmId ~= nil then
            table.insert(self.savedSessions, session)
        end
        index = index + 1
    end

    self.hasClosedLoadedSessions = false
end

local function saveSession(xmlFile, key, kind, uniqueId, session, minutes)
    setXMLString(xmlFile, key .. "#kind", kind)
    setXMLString(xmlFile, key .. "#uniqueId", uniqueId)
    setXMLInt(xmlFile, key .. "#farmId", session.farmId)
    if session.workerId ~= nil then
        setXMLInt(xmlFile, key .. "#workerId", session.workerId)
    end
    if session.who ~= nil then
        setXMLString(xmlFile, key .. "#who", session.who)
    end
    setXMLFloat(xmlFile, key .. "#minutes", minutes or 0)
    if session.sources ~= nil then
        setXMLString(xmlFile, key .. "#sources", joinSources(session.sources))
    end
    TCVehicleCondition.saveToXML(xmlFile, key .. ".start", session.start)
end

function TheContractorLogbook:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.logbook", TheContractor.SaveKey)

    local index = 0
    for _, farmEntries in pairs(self.jobEntriesByFarm) do
        for _, entry in pairs(farmEntries) do
            saveJobEntry(xmlFile, string.format("%s.job(%d)", rootKey, index), entry)
            index = index + 1
        end
    end

    -- A vehicle that's gone takes its history with it.
    index = 0
    for vehicleId, record in pairs(self.vehicles) do
        local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
        if uniqueId ~= nil then
            local key = string.format("%s.vehicle(%d)", rootKey, index)
            setXMLString(xmlFile, key .. "#uniqueId", uniqueId)
            setXMLString(xmlFile, key .. "#name", record.name or "")
            for i, entry in ipairs(record.entries) do
                saveVehicleEntry(xmlFile, string.format("%s.entry(%d)", key, i - 1), entry)
            end
            index = index + 1
        end
    end

    index = 0
    for jobId, pending in pairs(self.pendingByJobId) do
        local key = string.format("%s.pending(%d)", rootKey, index)
        setXMLInt(xmlFile, key .. "#jobId", jobId)
        setOptionalFloat(xmlFile, key .. "#arrivedAt", pending.arrivedAt)
        if pending.playerName ~= nil then
            setXMLString(xmlFile, key .. "#playerName", pending.playerName)
        end
        if pending.earlierCrew ~= nil then
            setXMLString(xmlFile, key .. "#earlierCrew", pending.earlierCrew)
        end
        setXMLBool(xmlFile, key .. "#tanksCounted", pending.tanksCounted == true)
        local startIndex = 0
        for vehicleId, snapshot in pairs(pending.start) do
            local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
            if uniqueId ~= nil then
                local startKey = string.format("%s.start(%d)", key, startIndex)
                setXMLString(xmlFile, startKey .. "#uniqueId", uniqueId)
                TCVehicleCondition.saveToXML(xmlFile, startKey, snapshot)
                startIndex = startIndex + 1
            end
        end
        local supplyIndex = 0
        for name, liters in pairs(pending.supplies) do
            local supplyKey = string.format("%s.supply(%d)", key, supplyIndex)
            setXMLString(xmlFile, supplyKey .. "#fillType", name)
            setXMLFloat(xmlFile, supplyKey .. "#liters", liters)
            supplyIndex = supplyIndex + 1
        end
        index = index + 1
    end

    -- Open sessions carry on (drivers) or are closed off (players) after
    -- the reload.
    index = 0
    local function writeSession(kind, vehicleId, session, minutes)
        local uniqueId = TCVehicleIds.getUniqueId(vehicleId)
        if uniqueId ~= nil then
            saveSession(xmlFile, string.format("%s.session(%d)", rootKey, index), kind, uniqueId, session, minutes)
            index = index + 1
        end
    end
    local drivers = g_currentMission.TheContractor.Drivers
    for vehicleId, session in pairs(self.driverSessions) do
        local binding = drivers.bindingsByVehicleId[vehicleId]
        writeSession(TheContractorLogbook.KIND.DRIVER, vehicleId, session,
            binding ~= nil and binding.activeMs / 60000 or 0)
    end
    for vehicleId, session in pairs(self.loadedDriverSessions) do
        writeSession(TheContractorLogbook.KIND.DRIVER, vehicleId, session, session.minutes)
    end
    for vehicle, session in pairs(self.playerSessions) do
        writeSession(TheContractorLogbook.KIND.PLAYER, NetworkUtil.getObjectId(vehicle), session, session.minutes)
    end
end

-- Console commands (tcJob log, tcCompany vehicleLog - see TCConsole) ------------------------

local function formatOptionalMinutes(minutes)
    return minutes ~= nil and TheContractorJob.formatMinutes(minutes) or "-"
end

local function formatMoney(amount)
    return g_i18n:formatMoney(amount or 0, 0, true, true)
end

-- Plain-text version of a job entry, for the console.
function TheContractorLogbook.formatJobEntryText(entry)
    local lines = {}
    local margin = TheContractorLogbook.getMargin(entry)
    table.insert(lines, string.format("Job %d: %s, %s, %s on %s", entry.jobId, entry.title or "?",
        entry.location or ("field " .. tostring(entry.fieldId)), entry.outcome, TCCalendar.formatDay(entry.day)))

    local crew = {}
    for _, member in ipairs(entry.crew) do
        local grew = {}
        for _, growth in ipairs(member.growth or {}) do
            table.insert(grew, growth.from ~= nil and string.format("%s %d->%d", growth.stat, growth.from, growth.to)
                or string.format("%s certified", growth.stat))
        end
        table.insert(crew, string.format("%s (%s%s%s)", member.name or "?", member.role or "?",
            member.rating ~= nil and string.format(", rating %d", member.rating) or "",
            #grew > 0 and ", grew " .. table.concat(grew, ", ") or ""))
    end
    table.insert(lines, "  Crew: " .. (#crew > 0 and table.concat(crew, ", ") or "-"))
    if entry.earlierCrew ~= nil then
        table.insert(lines, "  Earlier crew (unallocated): " .. entry.earlierCrew)
    end

    for _, machine in ipairs(entry.equipment) do
        local parts = {}
        for _, row in ipairs(TCVehicleCondition.getChangeRows(machine.startSnapshot, machine.endSnapshot)) do
            table.insert(parts, row.label .. " " .. row.value)
        end
        table.insert(lines, string.format("  %s (%s): %s%s%s, wear cost %s", machine.name or "?",
            machine.workerName or "-", table.concat(parts, ", "),
            machine.extraWear ~= nil and string.format(", +%d%% extra wear", machine.extraWear) or "",
            TheContractorLogbook.hasFoundFault(machine) and ", fault found" or "", formatMoney(machine.wearCost)))
    end

    table.insert(lines, string.format("  Time: travel %s, fieldwork %s, return %s",
        formatOptionalMinutes(entry.travelMinutes), formatOptionalMinutes(entry.fieldMinutes),
        formatOptionalMinutes(entry.returnMinutes)))
    for _, supply in ipairs(entry.supplies) do
        table.insert(lines, string.format("  Supplies: %s %.0f%s", supply.fillTypeName, supply.liters,
            supply.cost ~= nil and string.format(" used, %s", formatMoney(supply.cost)) or " loaded"))
    end
    table.insert(lines, string.format("  Price %s, fuel %s (%.0f l), supplies %s, labour %s, wear %s%s",
        formatMoney(entry.price), formatMoney(entry.fuelCost), entry.fuelLiters or 0,
        formatMoney(TheContractorLogbook.getSuppliesCost(entry)),
        entry.labourCost ~= nil and formatMoney(entry.labourCost) or "-", formatMoney(entry.wearCost),
        entry.claim ~= nil and string.format(", claim paid %s", formatMoney(entry.claim.paid)) or ""))
    table.insert(lines, string.format("  Margin %s, reputation %s, quality %s", formatMoney(margin),
        entry.reputation ~= nil and string.format("%+d", entry.reputation) or "-",
        entry.qualityScore ~= nil and string.format("%d%%", entry.qualityScore) or "-"))
    return table.concat(lines, "\n")
end

function TheContractorLogbook.registerConsoleCommands()
    TCConsole.register("job", "log", {
        args = "[jobId]",
        description = "Show a job's logbook entry, or list the last 10",
        serverOnly = false,
        hints = { jobId = "a logged job's id (tcJob log on its own lists the last 10)" },
        run = function(farmId, args)
            local logbook = g_currentMission.TheContractor.Logbook
            if args[1] ~= nil then
                local jobId = tonumber(args[1])
                if jobId == nil then
                    return false
                end
                local entry = logbook:getJobEntry(farmId, jobId)
                if entry == nil then
                    return string.format("No logbook entry for job %d on your farm", jobId)
                end
                return TheContractorLogbook.formatJobEntryText(entry)
            end

            local entries = logbook:getJobEntries(farmId)
            if #entries == 0 then
                return "The logbook has no jobs yet"
            end
            local lines = { "Last jobs in the logbook (newest first):" }
            for i = 1, math.min(10, #entries) do
                local entry = entries[i]
                table.insert(lines, string.format("  #%d %s, field %d, %s, %s, margin %s", entry.jobId,
                    entry.title or "?", entry.fieldId, TCCalendar.formatDayShort(entry.day), entry.outcome,
                    formatMoney(TheContractorLogbook.getMargin(entry))))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("company", "vehicleLog", {
        args = "<vehicle>",
        description = "Show a vehicle's logbook history for the last year",
        serverOnly = false,
        hints = { vehicle = "any part of its name, case-insensitive; only vehicles in your farm's logbook" },
        run = function(farmId, args)
            if args[1] == nil then
                return false
            end
            local wanted = string.lower(table.concat(args, " "))
            local logbook = g_currentMission.TheContractor.Logbook
            local matches = {}
            for _, record in pairs(logbook.vehicles) do
                if string.find(string.lower(record.name or ""), wanted, 1, true) ~= nil and
                        #TheContractorLogbook.getVehicleEntries(record, farmId) > 0 then
                    table.insert(matches, record)
                end
            end
            if #matches == 0 then
                return string.format("No vehicle called '%s' in your farm's logbook", wanted)
            end

            local lines = {}
            for _, record in ipairs(matches) do
                local summary = TheContractorLogbook.getVehicleSummary(record, farmId)
                table.insert(lines, string.format("%s: %d job(s), %.1f h, %d use(s) with a fault found, wear cost %s",
                    record.name or "?", summary.jobs, summary.hours, summary.faults, formatMoney(summary.wearCost)))
                for _, entry in ipairs(TheContractorLogbook.getVehicleEntries(record, farmId)) do
                    local parts = {}
                    for _, row in ipairs(TCVehicleCondition.getChangeRows(entry.startSnapshot, entry.endSnapshot)) do
                        table.insert(parts, row.label .. " " .. row.value)
                    end
                    table.insert(lines, string.format("  %s %s: %s, %s%s%s", TCCalendar.formatDayShort(entry.day),
                        entry.kind, entry.who or "-", formatOptionalMinutes(entry.minutes),
                        entry.jobTitle ~= nil and string.format(" (job %d, %s)", entry.jobId or 0, entry.jobTitle) or "",
                        #parts > 0 and ", " .. table.concat(parts, ", ") or ""))
                end
            end
            return table.concat(lines, "\n")
        end,
    })
end
