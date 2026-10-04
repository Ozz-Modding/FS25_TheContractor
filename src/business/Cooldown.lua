-- Buffer/cooldown and equipment hiding (023): once a job completes (022),
-- both the assigned worker and its equipment sit in a skill-scaled "still
-- out on the job" buffer before returning to the available pool (Q20,
-- agreed) - simulating driving back, unloading, etc. Equipment is
-- *physically* hidden for the buffer's duration, not just flagged busy.
--
-- Hiding technique researched from the user's FS25_UsedEquipmentYards mod
-- (YardInventory:hideVehicle/placeVehicleInYard): vehicle:removeFromPhysics()
-- + vehicle:setVisibility(false) to hide, the reverse to bring it back.
-- Unlike UEY, which sells the vehicle out of the farm's fleet entirely, our
-- equipment stays farm-owned and needs to be re-dispatchable on a future
-- job, so this deliberately skips UEY's detachVehicle step - detaching a
-- tractor/implement pair would leave 020's AI dispatch unable to start a
-- future job on it (Dispatch.lua's findOperatingVehicle/getIsStartable
-- requires an already-attached implement). Hiding/revealing every vehicle
-- id in the job's assignedEquipmentIds independently, in place, with no
-- position change, sidesteps that entirely: a tractor+implement pair stays
-- exactly as attached as it was when the job finished, just invisible and
-- physics-inactive for the buffer's duration. That also answers the
-- ticket's open "where does it reappear" question - nowhere new, it just
-- un-hides where the AI/player left it; no separate storage-location
-- concept needed.
--
-- Worker-side reuses Worker.lua's existing COOLDOWN status (016 already
-- defined the enum value, just never had anything driving it). Equipment
-- has no equivalent status field of its own (vehicles aren't our data), so
-- this subsystem is also the single source of truth for "is this vehicle
-- currently buffering" - TheContractorAllocation:isVehicleFree (018)
-- consults it directly rather than this module reaching into Allocation.

TheContractorCooldown = {}
TheContractorCooldown_mt = Class(TheContractorCooldown)

-- Buffer duration, in in-game minutes (counted down against the effective
-- time scale, same as Dispatch's transport wait). Made up of
-- BUFFER_FACTORS - each entry is a function(job, worker) returning that
-- factor's contribution in minutes (worker nil for a player-driven job),
-- summed by getBufferDurationMs. Add new factors (distance home, equipment
-- count, ...) by appending to the list. 026: 45 in-game minutes for the
-- slowest worker down to 15 for the fastest (or the player) - long enough
-- to read as driving back and cleaning down, short enough that a worker
-- can still fit a second job into the same day.
TheContractorCooldown.MAX_BUFFER_MINUTES = 45
TheContractorCooldown.MIN_BUFFER_MINUTES = 15

TheContractorCooldown.BUFFER_FACTORS = {
    -- Worker speed (016): linear between a slowest worker's
    -- MAX_BUFFER_MINUTES and a fastest worker's (or the player's)
    -- MIN_BUFFER_MINUTES.
    {
        name = "workerSpeed",
        getMinutes = function(job, worker)
            return TheContractorWorker.scaleBySpeed(worker, TheContractorCooldown.MAX_BUFFER_MINUTES,
                TheContractorCooldown.MIN_BUFFER_MINUTES)
        end,
    },
    -- 045: washing the equipment down, if the workers chose to - worked
    -- out by TCJobConsequences.applyOnCompletion just before this (the
    -- slower worker's time, on a two-worker job). 0 if nobody washed.
    {
        name = "washing",
        getMinutes = function(job, worker)
            return job.washMinutes or 0
        end,
    },
}

function TheContractorCooldown.new()
    local self = {}
    setmetatable(self, TheContractorCooldown_mt)

    -- entriesByFarm[farmId][cooldownId] = { id, farmId, jobId (server-only,
    -- nil for saves from before it existed), workerIds (empty for a
    -- player-driven job, two for a two-worker haulage job - 035),
    -- vehicleIds = {...}, remainingMs }
    self.entriesByFarm = {}
    -- Live derived index, rebuilt whenever entries change - never persisted
    -- on its own (see loadFromXMLFile) - vehicleId -> true, for
    -- TheContractorAllocation:isVehicleFree's O(1) lookup.
    self.vehicleIdsInCooldown = {}
    self.nextCooldownId = 1

    return self
end

-- Buffer duration ---------------------------------------------------------

-- `worker` is the job's slowest worker (TheContractorJobs.getSlowestWorker)
-- - a two-worker haulage job (035) is only back once its slower half is.
function TheContractorCooldown.getBufferDurationMs(job)
    local worker = TheContractorJobs.getSlowestWorker(job)
    local minutes = 0
    for _, factor in ipairs(TheContractorCooldown.BUFFER_FACTORS) do
        minutes = minutes + factor.getMinutes(job, worker)
    end
    return math.max(0, minutes) * 60000
end

-- Query API ---------------------------------------------------------------

function TheContractorCooldown:isVehicleInCooldown(vehicleId)
    return self.vehicleIdsInCooldown[vehicleId] == true
end

-- Hide/reveal --------------------------------------------------------------

-- Shared with 020's dispatch staging - see TCEquipmentVisibility. Run on
-- every machine (server applies directly per the "no SP loopback" gotcha,
-- other clients apply from the broadcast event, a joining client from
-- initial state, a reloading client from reapplyHidingAfterLoad).
local hideVehicles = TCEquipmentVisibility.hideVehicles
local revealVehicles = TCEquipmentVisibility.revealVehicles

-- Cooldown lifecycle (server-authoritative) --------------------------------

-- Starts a job's post-completion buffer: its workers (if any) and every
-- piece of its equipment - haulage rig included (035) - go into cooldown
-- for getBufferDurationMs (a player-driven job has no worker - see
-- TheContractorWorker.PLAYER_WORK_SPEED). Called from
-- TheContractorJobs:completeJob (022) in place of the direct idle flip that
-- ticket's Outcome left as a stand-in for this one.
function TheContractorCooldown:startCooldown(job)
    if not g_currentMission:getIsServer() then
        return
    end

    local durationMs = TheContractorCooldown.getBufferDurationMs(job)

    local id = self.nextCooldownId
    self.nextCooldownId = self.nextCooldownId + 1

    local entry = {
        id = id,
        farmId = job.farmId,
        jobId = job.id,
        workerIds = job:getWorkerIds(),
        vehicleIds = job:getAllEquipmentIds(),
        remainingMs = durationMs,
    }

    self:applyCooldownStarted(entry)

    for _, workerId in ipairs(entry.workerIds) do
        g_currentMission.TheContractor.Staff:setWorkerStatus(job.farmId, workerId, TheContractorWorker.STATUS.COOLDOWN)
    end

    Logging.info("TheContractor: farm %d job %d entering cooldown %d (%d equipment, %.1f min)", job.farmId, job.id,
        id, #entry.vehicleIds, durationMs / 60000)

    if g_server ~= nil then
        g_server:broadcastEvent(TCEquipmentCooldownStartedEvent.new(entry))
    end
end

-- The actual state application, run on whichever machine (server, or a
-- client receiving TCEquipmentCooldownStartedEvent/initial client state) is
-- applying it. Idempotent-safe against double application (e.g. initial
-- client state replaying an entry the client's own hide already covered) -
-- hiding an already-hidden vehicle is a harmless no-op.
function TheContractorCooldown:applyCooldownStarted(entry)
    self.entriesByFarm[entry.farmId] = self.entriesByFarm[entry.farmId] or {}
    self.entriesByFarm[entry.farmId][entry.id] = entry

    for _, vehicleId in ipairs(entry.vehicleIds) do
        self.vehicleIdsInCooldown[vehicleId] = true
    end

    hideVehicles(entry.vehicleIds)
end

-- Ends a cooldown early or on schedule: reveals equipment, frees the worker
-- back to idle, and drops the entry. Server-only trigger point (see
-- update() below) - other machines only ever apply via the broadcast event.
function TheContractorCooldown:endCooldown(farmId, cooldownId)
    if not g_currentMission:getIsServer() then
        return
    end

    -- Equipment goes back to where dispatch took it from (020) while it's
    -- still hidden, then applyCooldownEnded reveals it there.
    local farmEntries = self.entriesByFarm[farmId]
    local pendingEntry = farmEntries ~= nil and farmEntries[cooldownId] or nil
    if pendingEntry ~= nil and pendingEntry.jobId ~= nil then
        local job = g_currentMission.TheContractor.Jobs:getJobById(pendingEntry.jobId)
        if job ~= nil then
            TCJobSiteSetup.returnHome(job)
            -- 045: and comes out clean, if it was washed.
            TCJobConsequences.washEquipment(job)
        end
    end

    local entry = self:applyCooldownEnded(farmId, cooldownId)
    if entry == nil then
        return
    end

    for _, workerId in ipairs(entry.workerIds) do
        g_currentMission.TheContractor.Staff:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.IDLE)
    end

    Logging.info("TheContractor: farm %d cooldown %d ended, %d equipment back in the pool", farmId, cooldownId,
        #entry.vehicleIds)

    if g_server ~= nil then
        g_server:broadcastEvent(TCEquipmentCooldownEndedEvent.new(farmId, cooldownId))
    end
end

-- The actual state application, run on whichever machine (server, or a
-- client receiving TCEquipmentCooldownEndedEvent) is applying it. Returns
-- the removed entry (nil if already gone - the same "second call finds
-- nothing to do" idempotency guard other subsystems' apply* functions use).
function TheContractorCooldown:applyCooldownEnded(farmId, cooldownId)
    local farmEntries = self.entriesByFarm[farmId]
    if farmEntries == nil then
        return nil
    end

    local entry = farmEntries[cooldownId]
    if entry == nil then
        return nil
    end

    farmEntries[cooldownId] = nil

    for _, vehicleId in ipairs(entry.vehicleIds) do
        self.vehicleIdsInCooldown[vehicleId] = nil
    end

    revealVehicles(entry.vehicleIds)

    return entry
end

-- Background tick (server-only, same shape as TCJobProgress/Watchdog's own
-- update(dt) polling): counts every active cooldown down in game time (so
-- it speeds up with the time scale) and ends whichever ones have expired.
function TheContractorCooldown:update(dt)
    if not g_currentMission:getIsServer() then
        return
    end

    local gameDt = dt * g_currentMission:getEffectiveTimeScale()
    for farmId, farmEntries in pairs(self.entriesByFarm) do
        local expiredIds = {}
        for cooldownId, entry in pairs(farmEntries) do
            entry.remainingMs = entry.remainingMs - gameDt
            if entry.remainingMs <= 0 then
                table.insert(expiredIds, cooldownId)
            end
        end

        for _, cooldownId in ipairs(expiredIds) do
            self:endCooldown(farmId, cooldownId)
        end
    end
end

-- Wire serialization, shared by the cooldown-started event and initial
-- client state. Self-contained (carries its own farmId/id) so callers don't
-- need to track it separately, same convention Job.lua/Worker.lua's own
-- write*/read* pairs use.

function TheContractorCooldown.writeEntry(streamId, entry)
    streamWriteInt32(streamId, entry.farmId)
    streamWriteInt32(streamId, entry.id)
    streamWriteString(streamId, TheContractorJobs.encodeIdList(entry.workerIds))
    streamWriteFloat32(streamId, entry.remainingMs)

    streamWriteInt32(streamId, #entry.vehicleIds)
    for _, vehicleId in ipairs(entry.vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

function TheContractorCooldown.readEntry(streamId)
    local farmId = streamReadInt32(streamId)
    local id = streamReadInt32(streamId)
    local workerIds = TheContractorJobs.decodeIdList(streamReadString(streamId))
    local remainingMs = streamReadFloat32(streamId)

    local vehicleCount = streamReadInt32(streamId)
    local vehicleIds = {}
    for i = 1, vehicleCount do
        vehicleIds[i] = streamReadInt32(streamId)
    end

    return {
        id = id,
        farmId = farmId,
        workerIds = workerIds,
        vehicleIds = vehicleIds,
        remainingMs = remainingMs,
    }
end

-- Persistence ---------------------------------------------------------------
--
-- Vehicle network object ids are the same "id space" Job.lua's own
-- assignedEquipmentIds already persists across save/load (008/018) - this
-- follows that identical, already-accepted convention rather than inventing
-- a more durable vehicle identity of its own. Equipment/worker status
-- itself doesn't need re-deriving here: a hired worker's "cooldown" status
-- string round-trips through Staff.lua's own persistence unchanged; what
-- XML load can't give back for free is the *hidden* rendering/physics state
-- (a freshly loaded vehicle always starts visible - see Vehicle:
-- onFinishedLoading in the base game), which is why loadMap re-hides
-- everything still-active immediately after loading (see
-- reapplyHidingAfterLoad below).

function TheContractorCooldown:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.entriesByFarm = {}
    self.vehicleIdsInCooldown = {}
    self.nextCooldownId = 1

    local rootKey = string.format("%s.cooldowns", TheContractor.SaveKey)
    self.nextCooldownId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextCooldownId"), 1)

    local index = 0
    while true do
        local entryKey = string.format("%s.cooldown(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, entryKey) then
            break
        end

        local farmId = getXMLInt(xmlFile, entryKey .. "#farmId")
        local id = getXMLInt(xmlFile, entryKey .. "#id")
        -- #workerId: a single worker, from saves before 035's two-worker
        -- jobs.
        local workerIds = TheContractorJobs.decodeIdList(getXMLString(xmlFile, entryKey .. "#workerIds"))
        local legacyWorkerId = getXMLInt(xmlFile, entryKey .. "#workerId")
        if legacyWorkerId ~= nil then
            table.insert(workerIds, legacyWorkerId)
        end
        local jobId = getXMLInt(xmlFile, entryKey .. "#jobId")
        local remainingMs = Utils.getNoNil(getXMLFloat(xmlFile, entryKey .. "#remainingMs"), 0)
        local vehicleIds = TheContractorJobs.decodeIdList(getXMLString(xmlFile, entryKey .. "#vehicleIds"))

        local entry = {
            id = id,
            farmId = farmId,
            jobId = jobId,
            workerIds = workerIds,
            vehicleIds = vehicleIds,
            remainingMs = remainingMs,
        }

        self.entriesByFarm[farmId] = self.entriesByFarm[farmId] or {}
        self.entriesByFarm[farmId][id] = entry

        for _, vehicleId in ipairs(vehicleIds) do
            self.vehicleIdsInCooldown[vehicleId] = true
        end

        if id >= self.nextCooldownId then
            self.nextCooldownId = id + 1
        end

        index = index + 1
    end
end

function TheContractorCooldown:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.cooldowns", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextCooldownId", self.nextCooldownId)

    local index = 0
    for _, farmEntries in pairs(self.entriesByFarm) do
        for _, entry in pairs(farmEntries) do
            local entryKey = string.format("%s.cooldown(%d)", rootKey, index)
            setXMLInt(xmlFile, entryKey .. "#farmId", entry.farmId)
            setXMLInt(xmlFile, entryKey .. "#id", entry.id)
            if #entry.workerIds > 0 then
                setXMLString(xmlFile, entryKey .. "#workerIds", TheContractorJobs.encodeIdList(entry.workerIds))
            end
            if entry.jobId ~= nil then
                setXMLInt(xmlFile, entryKey .. "#jobId", entry.jobId)
            end
            setXMLFloat(xmlFile, entryKey .. "#remainingMs", entry.remainingMs)
            setXMLString(xmlFile, entryKey .. "#vehicleIds", TheContractorJobs.encodeIdList(entry.vehicleIds))

            index = index + 1
        end
    end
end

-- Called once from TheContractor:loadMap, after loadFromXMLFile - vehicles
-- are already spawned by this point (the same assumption Allocation/
-- Dispatch/Watchdog's own NetworkUtil.getObject calls already make), so any
-- cooldown entry still active gets its equipment hidden again immediately,
-- rather than sitting fully visible/available for one frame (or forever, if
-- nothing else in-game would ever notice) despite still-frozen worker status
-- and a live remainingMs countdown.
function TheContractorCooldown:reapplyHidingAfterLoad()
    if not g_currentMission:getIsServer() then return end

    for _, farmEntries in pairs(self.entriesByFarm) do
        for _, entry in pairs(farmEntries) do
            hideVehicles(entry.vehicleIds)
        end
    end
end

function TheContractorCooldown:writeInitialClientState(streamId, connection)
    local allEntries = {}
    for _, farmEntries in pairs(self.entriesByFarm) do
        for _, entry in pairs(farmEntries) do
            table.insert(allEntries, entry)
        end
    end

    streamWriteInt32(streamId, #allEntries)
    for _, entry in ipairs(allEntries) do
        TheContractorCooldown.writeEntry(streamId, entry)
    end
end

-- Per src/events/README.md's initial-client-state gotcha, referenced
-- vehicles may not be resolved yet on a joining client - applyCooldownStarted
-- resolves eagerly via NetworkUtil.getObject inside hideVehicles, so any
-- vehicle not yet streamed in simply doesn't get hidden here. That's an
-- acceptable, self-correcting gap for a joining client specifically (not a
-- save/load reload, which is what reapplyHidingAfterLoad exists for): the
-- vehicle will already be hidden from the server/host's perspective (they
-- applied it directly when the cooldown started, long before this client
-- joined), so the joining client briefly sees it visible until whatever
-- vehicle-streaming pass would otherwise reconcile it - the same latent
-- gap this ticket's own equipmentIds resolution has everywhere else,
-- not one introduced here.
function TheContractorCooldown:readInitialClientState(streamId, connection)
    local entryCount = streamReadInt32(streamId)
    for _ = 1, entryCount do
        self:applyCooldownStarted(TheContractorCooldown.readEntry(streamId))
    end
end
