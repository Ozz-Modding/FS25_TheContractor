-- Shared candidate pool + per-farm worker rosters (016).
--
-- Deliberate exception to this codebase's usual "state is farm-scoped"
-- convention (see CLAUDE.md): the candidate pool is global, not keyed by
-- farmId, by explicit design decision — candidates are meant to be a
-- contested shared resource. New candidates trickle in and randomly leave
-- the pool over time, independent of any player action (a daily tick, same
-- shape as Advertising's/Jobs' own daily ticks), and any farm can hire any
-- candidate currently in the pool. In multiplayer this means farms can race
-- to hire the same top talent — first hire request the server processes for
-- a given candidate wins, the rest see that candidate simply vanish from the
-- pool (same "no browsable-pool-was-in-scope" note from this ticket's first
-- pass no longer applies; see its Outcome for the full history).
--
-- Once hired, a worker leaves the pool (farmId goes from nil to the hiring
-- farm's id) and moves into that farm's own roster — the roster itself
-- *is* farm-scoped, same as everything else in this mod.
--
-- Roll magnitudes, pool sizing, and the daily add/remove odds are
-- placeholders (026 owns the real balance pass), same as every other
-- placeholder number in this codebase.

TheContractorStaff = {}
TheContractorStaff_mt = Class(TheContractorStaff)

TheContractorStaff.BASE_HIRE_COST = 300
TheContractorStaff.COST_PER_WORK_SPEED = 50
TheContractorStaff.COST_PER_TIER_POINT = 20

-- Independent per-tier roll: each tier has this chance of the worker being
-- certified on it at all (a random 1-10 rating), otherwise "not certified"
-- (the key stays absent from tierCapability, per Worker.lua's convention).
TheContractorStaff.TIER_CERTIFICATION_CHANCE = 0.65

-- Pool lifecycle: seeded up to INITIAL_POOL_SIZE candidates on first ever
-- load (or if an existing save's pool is found empty, e.g. upgrading a save
-- from before this existed — see ensureInitialPool). Each day thereafter,
-- every candidate currently in the pool independently has a
-- POOL_DAILY_REMOVE_CHANCE chance to leave (poached elsewhere/lost
-- interest), and if the pool is under POOL_MAX_SIZE there's a
-- POOL_DAILY_ADD_CHANCE chance a new candidate appears.
TheContractorStaff.INITIAL_POOL_SIZE = 4
TheContractorStaff.POOL_MAX_SIZE = 8
TheContractorStaff.POOL_DAILY_ADD_CHANCE = 0.5
TheContractorStaff.POOL_DAILY_REMOVE_CHANCE = 0.15

TheContractorStaff.FIRST_NAMES = {
    "James", "Mary", "John", "Sarah", "Robert", "Emma", "Michael", "Olivia",
    "David", "Sophie", "Daniel", "Grace", "Thomas", "Amy", "Peter", "Laura",
}
TheContractorStaff.LAST_NAMES = {
    "Smith", "Jones", "Taylor", "Brown", "Wilson", "Evans", "Walker", "White",
    "Roberts", "Green", "Hall", "Wood", "Baker", "Clarke", "Turner", "Hughes",
}

table.insert(FinanceStats.statNames, "tcHiring")
FinanceStats.statNameToIndex["tcHiring"] = #FinanceStats.statNames

function TheContractorStaff.new()
    local self = {}
    setmetatable(self, TheContractorStaff_mt)

    -- workersByFarm[farmId][workerId] = TheContractorWorker (hired, farmId set)
    self.workersByFarm = {}
    -- candidatePool[id] = TheContractorWorker (unhired, farmId nil). Global,
    -- not farm-scoped — see file header.
    self.candidatePool = {}
    -- Single counter shared by both spaces: a candidate keeps its id when it
    -- gets hired and moves into a farm's roster, so there's only ever one id
    -- space to track, not two.
    self.nextWorkerId = 1

    MoneyType.TC_HIRING = MoneyType.register("tcHiring", "tc_moneyType_hiring")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Query API -------------------------------------------------------------

function TheContractorStaff:getWorker(farmId, workerId)
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil then
        return nil
    end
    return farmWorkers[workerId]
end

function TheContractorStaff:getRoster(farmId)
    local result = {}
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers ~= nil then
        for _, worker in pairs(farmWorkers) do
            table.insert(result, worker)
        end
    end
    return result
end

function TheContractorStaff:getIdleWorkers(farmId)
    local result = {}
    for _, worker in ipairs(self:getRoster(farmId)) do
        if worker:isIdle() then
            table.insert(result, worker)
        end
    end
    return result
end

-- tier is "small"/"medium"/"large" (009), or nil for jobs whose equipment
-- carries no size tier at all (every worker qualifies then).
function TheContractorStaff:getWorkersCapableOfTier(farmId, tier)
    local result = {}
    for _, worker in ipairs(self:getRoster(farmId)) do
        if worker:isCapableOfTier(tier) then
            table.insert(result, worker)
        end
    end
    return result
end

-- The pool any farm can currently hire from (017's Staff UI browse list).
function TheContractorStaff:getCandidatePool()
    local result = {}
    for _, candidate in pairs(self.candidatePool) do
        table.insert(result, candidate)
    end
    return result
end

function TheContractorStaff:getCandidate(candidateId)
    return self.candidatePool[candidateId]
end

-- Stat rolling ------------------------------------------------------------

function TheContractorStaff.rollWorkSpeed()
    return math.random(1, 10)
end

function TheContractorStaff.rollTierCapability()
    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if math.random() < TheContractorStaff.TIER_CERTIFICATION_CHANCE then
            tierCapability[tier] = math.random(1, 10)
        end
    end
    return tierCapability
end

function TheContractorStaff.getHireCost(workSpeed, tierCapability)
    local cost = TheContractorStaff.BASE_HIRE_COST + workSpeed * TheContractorStaff.COST_PER_WORK_SPEED

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        if rating ~= nil then
            cost = cost + rating * TheContractorStaff.COST_PER_TIER_POINT
        end
    end

    return cost
end

function TheContractorStaff.generateName()
    local firstName = TheContractorStaff.FIRST_NAMES[math.random(#TheContractorStaff.FIRST_NAMES)]
    local lastName = TheContractorStaff.LAST_NAMES[math.random(#TheContractorStaff.LAST_NAMES)]
    return firstName .. " " .. lastName
end

function TheContractorStaff.formatTierCapability(tierCapability)
    local parts = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        table.insert(parts, tier .. "=" .. (rating ~= nil and tostring(rating) or "none"))
    end
    return table.concat(parts, ", ")
end

-- Candidate pool lifecycle (server-authoritative) ------------------------

-- Rolls a brand new candidate and adds it to the pool, applying locally and
-- broadcasting to all clients (see file header — every client needs to see
-- the same shared pool, not just the farm that happens to be looking at it).
-- No-ops (returns nil) if the pool is already at POOL_MAX_SIZE.
function TheContractorStaff:addCandidateToPool()
    if not g_currentMission:getIsServer() then
        return nil
    end

    local poolCount = 0
    for _ in pairs(self.candidatePool) do
        poolCount = poolCount + 1
    end
    if poolCount >= TheContractorStaff.POOL_MAX_SIZE then
        return nil
    end

    local id = self.nextWorkerId
    self.nextWorkerId = self.nextWorkerId + 1

    local workSpeed = TheContractorStaff.rollWorkSpeed()
    local tierCapability = TheContractorStaff.rollTierCapability()
    local hireCost = TheContractorStaff.getHireCost(workSpeed, tierCapability)
    local name = TheContractorStaff.generateName()

    local candidate = TheContractorWorker.new(id, nil, name, workSpeed, tierCapability, hireCost)
    self:applyCandidateAdded(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCStaffCandidateAddedEvent.new(candidate))
    end

    Logging.info("TheContractor: staff pool gained candidate %d (%s, speed %d, cost %.0f)", candidate.id,
        candidate.name, candidate.workSpeed, candidate.hireCost)

    return candidate
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCStaffCandidateAddedEvent/initial client state) is applying it.
function TheContractorStaff:applyCandidateAdded(candidate)
    self.candidatePool[candidate.id] = candidate

    if candidate.id >= self.nextWorkerId then
        self.nextWorkerId = candidate.id + 1
    end
end

-- Removes a candidate from the pool without hiring them (poached elsewhere/
-- lost interest, per the daily tick) and broadcasts the removal. A no-op if
-- the candidate is already gone (e.g. another farm just hired them).
function TheContractorStaff:removeCandidateFromPool(candidateId)
    if not g_currentMission:getIsServer() then
        return
    end

    if self.candidatePool[candidateId] == nil then
        return
    end

    self:applyCandidateRemoved(candidateId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCStaffCandidateRemovedEvent.new(candidateId))
    end
end

function TheContractorStaff:applyCandidateRemoved(candidateId)
    self.candidatePool[candidateId] = nil
end

-- Server-only daily tick (same shape as Advertising's/Jobs' own daily
-- ticks): rolls departure for every candidate currently in the pool, then
-- maybe adds one new candidate if there's room. Order matters only in that a
-- candidate could depart and be replaced within the same day — that's fine,
-- there's no reason a leaver and a newcomer can't both happen on the same
-- day.
function TheContractorStaff:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorStaff:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorStaff:onDayChanged()
    local departingIds = {}
    for id in pairs(self.candidatePool) do
        if math.random() < TheContractorStaff.POOL_DAILY_REMOVE_CHANCE then
            table.insert(departingIds, id)
        end
    end
    for _, id in ipairs(departingIds) do
        self:removeCandidateFromPool(id)
    end

    if math.random() < TheContractorStaff.POOL_DAILY_ADD_CHANCE then
        self:addCandidateToPool()
    end
end

-- Called once from TheContractor:loadMap, after persisted state has been
-- loaded — covers both a brand new save (empty pool, .new()'s default) and
-- an existing save from before the candidate pool existed (also an empty
-- pool, since loadFromXMLFile finds no <pool> entries to populate it with).
-- Tops the pool up to INITIAL_POOL_SIZE rather than leaving it to the daily
-- tick to slowly fill in on its own.
function TheContractorStaff:ensureInitialPool()
    if not g_currentMission:getIsServer() then
        return
    end

    local poolCount = 0
    for _ in pairs(self.candidatePool) do
        poolCount = poolCount + 1
    end

    while poolCount < TheContractorStaff.INITIAL_POOL_SIZE do
        if self:addCandidateToPool() == nil then
            break
        end
        poolCount = poolCount + 1
    end
end

-- Hiring (server-authoritative) -------------------------------------------

function TheContractorStaff:canAffordHire(farmId, hireCost)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        return false
    end

    return farm:getBalance() >= hireCost
end

-- Hires a candidate currently in the pool for farmId: checks the candidate
-- is still there (the MP race — first request the server processes wins,
-- see file header) and the farm can afford their cost, deducts it, moves
-- them out of the pool and into the farm's roster, then broadcasts the
-- result. Only the server may hire — see TCHireWorkerEvent for the client-
-- request side. Returns the hired TheContractorWorker, or nil if the
-- candidate was already gone or the farm couldn't afford them.
function TheContractorStaff:hireWorker(farmId, candidateId)
    if not g_currentMission:getIsServer() then
        return nil
    end

    local candidate = self.candidatePool[candidateId]
    if candidate == nil then
        return nil
    end

    if not self:canAffordHire(farmId, candidate.hireCost) then
        return nil
    end

    g_currentMission:addMoney(-candidate.hireCost, farmId, MoneyType.TC_HIRING, true, true)

    candidate.farmId = farmId
    self:applyWorkerHired(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerHiredEvent.new(candidate))
    end

    return candidate
end

-- The actual state flip (pool -> roster), run on whichever machine (server,
-- or a client receiving TCWorkerHiredEvent) is applying the hire.
function TheContractorStaff:applyWorkerHired(worker)
    self.candidatePool[worker.id] = nil
    self:registerWorker(worker)
end

-- Registers an already-constructed, already-hired worker (farmId set) —
-- used by applyWorkerHired and by initial-client-state replay.
function TheContractorStaff:registerWorker(worker)
    self.workersByFarm[worker.farmId] = self.workersByFarm[worker.farmId] or {}
    self.workersByFarm[worker.farmId][worker.id] = worker

    if worker.id >= self.nextWorkerId then
        self.nextWorkerId = worker.id + 1
    end

    Logging.info("TheContractor: farm %d hired worker %d (%s, speed %d, cost %.0f)", worker.farmId, worker.id,
        worker.name, worker.workSpeed, worker.hireCost)
end

-- Releasing (server-authoritative) ----------------------------------------

-- Fires a hired worker from farmId's roster (017's Staff UI roster
-- management action) — no refund, and no move back into the candidate pool
-- (a released worker is just gone, not recycled). Returns true if a worker
-- was actually removed. Unlike hiring there's no race to arbitrate: only the
-- owning farm can ever reference a workerId that's in its own roster, so no
-- re-check-then-act window exists for another farm to interfere with.
function TheContractorStaff:releaseWorker(farmId, workerId)
    if not g_currentMission:getIsServer() then
        return false
    end

    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil or farmWorkers[workerId] == nil then
        return false
    end

    local worker = farmWorkers[workerId]
    self:applyWorkerReleased(farmId, workerId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerReleasedEvent.new(farmId, workerId))
    end

    Logging.info("TheContractor: farm %d released worker %d (%s)", farmId, workerId, worker.name)

    return true
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCWorkerReleasedEvent) is applying it.
function TheContractorStaff:applyWorkerReleased(farmId, workerId)
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil then
        return
    end

    farmWorkers[workerId] = nil
end

-- Worker status (server-authoritative) -------------------------------------

-- Flips a hired worker's status (idle/assigned/cooldown) and broadcasts it —
-- first driven by allocation (018, idle -> assigned on a successful
-- allocateJob), later tickets (022/023) will flip it back on
-- completion/cooldown. Broadcasts just the changed field
-- (TCWorkerStatusChangedEvent) rather than a full worker snapshot, since
-- status is the only thing this ever moves on its own.
function TheContractorStaff:setWorkerStatus(farmId, workerId, status)
    if not g_currentMission:getIsServer() then
        return
    end

    self:applyWorkerStatusChanged(farmId, workerId, status)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerStatusChangedEvent.new(farmId, workerId, status))
    end
end

-- The actual field flip, run on whichever machine (server, or a client
-- receiving TCWorkerStatusChangedEvent) is applying it.
function TheContractorStaff:applyWorkerStatusChanged(farmId, workerId, status)
    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return
    end

    worker.status = status
end

-- Wire serialization, shared by the pool/hire events and initial client
-- state. Self-contained (carries its own farmId) so callers don't need to
-- track it separately. farmId 0 is used as the "no farm" sentinel for a
-- pool candidate — streamWriteInt32 can't write nil, and 0 is never a real
-- company-owning farm id (see main.lua's own farmId == 0 checks).

function TheContractorStaff.writeWorker(streamId, worker)
    streamWriteInt32(streamId, worker.farmId or 0)
    streamWriteInt32(streamId, worker.id)
    streamWriteString(streamId, worker.name)
    streamWriteInt32(streamId, worker.workSpeed)
    streamWriteFloat32(streamId, worker.hireCost)
    streamWriteString(streamId, worker.status)

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        streamWriteBool(streamId, rating ~= nil)
        if rating ~= nil then
            streamWriteInt32(streamId, rating)
        end
    end
end

function TheContractorStaff.readWorker(streamId)
    local farmId = streamReadInt32(streamId)
    if farmId == 0 then
        farmId = nil
    end
    local id = streamReadInt32(streamId)
    local name = streamReadString(streamId)
    local workSpeed = streamReadInt32(streamId)
    local hireCost = streamReadFloat32(streamId)
    local status = streamReadString(streamId)

    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if streamReadBool(streamId) then
            tierCapability[tier] = streamReadInt32(streamId)
        end
    end

    local worker = TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, hireCost)
    worker.status = status

    return worker
end

-- Persistence -------------------------------------------------------------

function TheContractorStaff.writeWorkerXML(xmlFile, key, worker)
    setXMLInt(xmlFile, key .. "#id", worker.id)
    setXMLString(xmlFile, key .. "#name", worker.name)
    setXMLInt(xmlFile, key .. "#workSpeed", worker.workSpeed)
    setXMLFloat(xmlFile, key .. "#hireCost", worker.hireCost)
    setXMLString(xmlFile, key .. "#status", worker.status)

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        if rating ~= nil then
            setXMLInt(xmlFile, key .. "#tier" .. tier, rating)
        end
    end
end

-- farmId is passed in explicitly (nil for a pool candidate) rather than read
-- from the XML node, since farm ownership is expressed structurally there
-- (which section the node lives under), not as its own attribute.
function TheContractorStaff.readWorkerXML(xmlFile, key, farmId)
    local id = getXMLInt(xmlFile, key .. "#id")
    local name = getXMLString(xmlFile, key .. "#name")
    local workSpeed = getXMLInt(xmlFile, key .. "#workSpeed")
    local hireCost = getXMLFloat(xmlFile, key .. "#hireCost")

    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        tierCapability[tier] = getXMLInt(xmlFile, key .. "#tier" .. tier)
    end

    local worker = TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, hireCost)
    worker.status = Utils.getNoNil(getXMLString(xmlFile, key .. "#status"), worker.status)

    return worker
end

function TheContractorStaff:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.workersByFarm = {}
    self.candidatePool = {}
    self.nextWorkerId = 1

    local rootKey = string.format("%s.staff", TheContractor.SaveKey)
    self.nextWorkerId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextWorkerId"), 1)

    local poolIndex = 0
    while true do
        local candidateKey = string.format("%s.pool.candidate(%d)", rootKey, poolIndex)
        if not hasXMLProperty(xmlFile, candidateKey) then
            break
        end

        local candidate = TheContractorStaff.readWorkerXML(xmlFile, candidateKey, nil)
        self.candidatePool[candidate.id] = candidate

        if candidate.id >= self.nextWorkerId then
            self.nextWorkerId = candidate.id + 1
        end

        poolIndex = poolIndex + 1
    end

    local farmIndex = 0
    while true do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        if not hasXMLProperty(xmlFile, farmKey) then
            break
        end

        local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")

        local workerIndex = 0
        while true do
            local workerKey = string.format("%s.worker(%d)", farmKey, workerIndex)
            if not hasXMLProperty(xmlFile, workerKey) then
                break
            end

            local worker = TheContractorStaff.readWorkerXML(xmlFile, workerKey, farmId)

            self.workersByFarm[farmId] = self.workersByFarm[farmId] or {}
            self.workersByFarm[farmId][worker.id] = worker

            if worker.id >= self.nextWorkerId then
                self.nextWorkerId = worker.id + 1
            end

            workerIndex = workerIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorStaff:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.staff", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextWorkerId", self.nextWorkerId)

    local poolIndex = 0
    for _, candidate in pairs(self.candidatePool) do
        local candidateKey = string.format("%s.pool.candidate(%d)", rootKey, poolIndex)
        TheContractorStaff.writeWorkerXML(xmlFile, candidateKey, candidate)
        poolIndex = poolIndex + 1
    end

    local farmIndex = 0
    for farmId, farmWorkers in pairs(self.workersByFarm) do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        setXMLInt(xmlFile, farmKey .. "#farmId", farmId)

        local workerIndex = 0
        for _, worker in pairs(farmWorkers) do
            local workerKey = string.format("%s.worker(%d)", farmKey, workerIndex)
            TheContractorStaff.writeWorkerXML(xmlFile, workerKey, worker)
            workerIndex = workerIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorStaff:writeInitialClientState(streamId, connection)
    local candidates = self:getCandidatePool()
    streamWriteInt32(streamId, #candidates)
    for _, candidate in ipairs(candidates) do
        TheContractorStaff.writeWorker(streamId, candidate)
    end

    local allWorkers = {}
    for farmId, farmWorkers in pairs(self.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            table.insert(allWorkers, worker)
        end
    end

    streamWriteInt32(streamId, #allWorkers)
    for _, worker in ipairs(allWorkers) do
        TheContractorStaff.writeWorker(streamId, worker)
    end
end

function TheContractorStaff:readInitialClientState(streamId, connection)
    local candidateCount = streamReadInt32(streamId)
    for _ = 1, candidateCount do
        self:applyCandidateAdded(TheContractorStaff.readWorker(streamId))
    end

    local workerCount = streamReadInt32(streamId)
    for _ = 1, workerCount do
        self:registerWorker(TheContractorStaff.readWorker(streamId))
    end
end
