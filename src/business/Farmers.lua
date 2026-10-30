-- Farmers and the local official (110): the people jobs come from.
--
-- The first time the mod runs on a save, the server shares the map's field
-- land out with 109's split (a random seed, saved) and turns each share
-- into a farmer: a name in the nameStyle setting's style, a look (041's
-- appearance data), their farmland ids, their target size and an optional
-- yard (108). The local official is made at the same time: one person of
-- the same shape with no land, the customer for any job that belongs to no
-- farmer. People are server-wide, not farm-scoped (every farm deals with
-- the same farmers; relationships with them are per farm, 113), and their
-- ids come from their own counter, never the staff's.
--
-- Land follows its owner. The server tidies every farmer's holding
-- whenever a farmland changes hands (FARMLAND_OWNER_CHANGED) and once at
-- load (reconcileLand): land a player owns, or that's gone from the map,
-- leaves its farmer (who may end up with none, and stays on the list), and
-- field land nobody has goes to a farmer near it: among those whose land is
-- within NEAR_MARGIN of the nearest, the one with the fewest acres for
-- their target. It never makes a new farmer. A yard follows the same way,
-- with 109's rule for yards. A yard the player declared (117) isn't field
-- land: it leaves whoever farmed it and goes to the nearest farmer without
-- a yard, however far. Each farmer whose holding changed goes to the
-- clients in a TCFarmerLandEvent.
--
-- Jobs get their customer as they're created (getCustomerIdForJob): the
-- farmer holding the job's field, the official for an offField job or land
-- no farmer holds, the original job's customer for a spilt crop (106), the
-- farmer whose machine it is for a favour (116), and nobody for any other
-- ADS repair contract (100-102). A loaded job without one gets one the same
-- way (linkJobs).
--
-- 116, 121: a farmer's machines (machines, their fleet, made by
-- TheContractorFarmerFleet when they're set up and whenever land or a yard
-- changes hands) are kept on their record: { id, role, attachedTo,
-- xmlFilename, seed, hours, hoursDay, hoursPerMonth, fitted = { [part] =
-- day } }. Saved here; 122 streams each machine's id, role, xmlFilename and
-- attachedTo (TheContractorFarmerFleet.writeStream), the rest stays on the
-- server.
--
-- 113: each farmer also has a pay habit (PAY_HABITS), rolled as they're
-- made and never shown or streamed: it only changes how their invoices
-- (049) are paid, on the server. The official is always AVERAGE_PAY_HABIT.
-- Relationships with them are TheContractorRelationships'.
--
-- 111: the People tab's Others view lists them (getPeopleRows), with what
-- the player's farm has done for each from its logbook, whose job entries
-- now keep the customer (older ones are linked from their fields,
-- linkLogbook). Any farm with a company may rename someone or change their
-- look (editPerson, through TCEditPersonEvent), for everyone.

TheContractorFarmers = {}
TheContractorFarmers_mt = Class(TheContractorFarmers)

-- Metres: land nobody has goes to the farmer with the fewest acres for
-- their target among those whose land (or yard) is within this of the
-- nearest farmer's.
TheContractorFarmers.NEAR_MARGIN = 500
-- Tries at a name nobody else here has before settling for a repeat.
TheContractorFarmers.NAME_TRIES = 10

-- 113: how a farmer pays their invoices, hidden from the player: the
-- weight a new farmer gets each, and what it multiplies 049's late-payer
-- and bad-debt chances by.
TheContractorFarmers.PAY_HABITS = {
    { key = "prompt", weight = 25, latePayerMultiplier = 0.3, badDebtMultiplier = 0.5 },
    { key = "average", weight = 50, latePayerMultiplier = 1, badDebtMultiplier = 1 },
    { key = "slow", weight = 25, latePayerMultiplier = 3, badDebtMultiplier = 1.5 },
}
TheContractorFarmers.AVERAGE_PAY_HABIT = "average"

function TheContractorFarmers.new()
    local self = {}
    setmetatable(self, TheContractorFarmers_mt)

    -- id -> person: { id, name, gender, appearance (TCWorkerAppearance
    -- data, or nil), isOfficial, farmlandIds (sorted list), yardFarmlandId
    -- (or nil), targetAcres }. The official has no land and no target.
    self.people = {}
    self.officialId = nil
    self.nextId = 1
    -- The split the farmers came from (console only).
    self.seed = nil
    self.targetAcres = nil

    -- Server: generated or tidied up for this load (setUp).
    self.isSetUp = false

    return self
end

-- Queries ---------------------------------------------------------------------

function TheContractorFarmers:hasGenerated()
    return self.officialId ~= nil
end

function TheContractorFarmers:getPerson(id)
    if id == nil then
        return nil
    end
    return self.people[id]
end

function TheContractorFarmers:getOfficial()
    return self:getPerson(self.officialId)
end

-- Every farmer (not the official), by id.
function TheContractorFarmers:getFarmers()
    local farmers = {}
    for _, person in pairs(self.people) do
        if not person.isOfficial then
            table.insert(farmers, person)
        end
    end
    table.sort(farmers, function(a, b)
        return a.id < b.id
    end)
    return farmers
end

-- The farmer holding a farmland, or nil.
function TheContractorFarmers:getHolder(farmlandId)
    for _, person in pairs(self.people) do
        for _, id in ipairs(person.farmlandIds) do
            if id == farmlandId then
                return person
            end
        end
    end
    return nil
end

-- The customer for work on a field: the farmer holding its farmland, or the
-- official when no farmer does (the player's own land). nil before the
-- people are generated.
function TheContractorFarmers:getCustomerIdForField(fieldId)
    local field = fieldId ~= nil and g_fieldManager ~= nil and g_fieldManager:getFieldById(fieldId) or nil
    local farmland = field ~= nil and field.getFarmland ~= nil and field:getFarmland() or nil
    if farmland ~= nil then
        local holder = self:getHolder(farmland:getId())
        if holder ~= nil then
            return holder.id
        end
    end
    return self.officialId
end

-- 113: a PAY_HABITS entry by key, or nil.
function TheContractorFarmers.findPayHabit(key)
    for _, habit in ipairs(TheContractorFarmers.PAY_HABITS) do
        if habit.key == key then
            return habit
        end
    end
    return nil
end

-- 113: a habit key at random, by PAY_HABITS' weights.
function TheContractorFarmers.rollPayHabit()
    local total = 0
    for _, habit in ipairs(TheContractorFarmers.PAY_HABITS) do
        total = total + habit.weight
    end
    local roll = math.random() * total
    for _, habit in ipairs(TheContractorFarmers.PAY_HABITS) do
        roll = roll - habit.weight
        if roll < 0 then
            return habit.key
        end
    end
    return TheContractorFarmers.PAY_HABITS[#TheContractorFarmers.PAY_HABITS].key
end

-- 113 (server): how a customer pays, as a PAY_HABITS entry. The official,
-- nobody and a farmer without one pay as average.
function TheContractorFarmers:getPayHabit(customerId)
    local person = self:getPerson(customerId)
    local key = person ~= nil and not person.isOfficial and person.payHabit or nil
    return TheContractorFarmers.findPayHabit(key) or
        TheContractorFarmers.findPayHabit(TheContractorFarmers.AVERAGE_PAY_HABIT)
end

-- 113 (server): farmers from before pay habits, or with one no longer in
-- PAY_HABITS, get one. Returns how many did.
function TheContractorFarmers:ensurePayHabits()
    local count = 0
    for _, farmer in ipairs(self:getFarmers()) do
        if TheContractorFarmers.findPayHabit(farmer.payHabit) == nil then
            farmer.payHabit = TheContractorFarmers.rollPayHabit()
            count = count + 1
        end
    end
    return count
end

-- A job's customer id (see the file header), or nil for none.
function TheContractorFarmers:getCustomerIdForJob(job)
    if job.workshop ~= nil then
        -- 116: a favour is for the farmer whose machine it is.
        local farmerId = job.workshop.farmerId
        return farmerId ~= nil and self.people[farmerId] ~= nil and farmerId or nil
    end
    if job.spill ~= nil and job.spill.sourceJobId ~= nil then
        local jobs = g_currentMission.TheContractor.Jobs
        local source = jobs ~= nil and jobs:getJob(job.farmId, job.spill.sourceJobId) or nil
        if source ~= nil and source.customerId ~= nil then
            return source.customerId
        end
    end
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if jobDef ~= nil and jobDef.offField then
        return self.officialId
    end
    return self:getCustomerIdForField(job.fieldId)
end

-- The live map: farmlandId -> { id, x, z, acres, ownerFarmId } for every
-- farmland with a field, and the list of them by id.
function TheContractorFarmers.getLand()
    local list = TheContractorFarmerSplit.getFieldFarmlands()
    local byId = {}
    for _, farmland in ipairs(list) do
        byId[farmland.id] = farmland
    end
    return byId, list
end

-- The live map: farmlandId -> { farmlandId, x, z } for 108's yards on land
-- no player owns.
function TheContractorFarmers.getFreeYards()
    local byId = {}
    for _, yard in ipairs(TheContractorFarmerSplit.getFreeYards()) do
        byId[yard.farmlandId] = yard
    end
    return byId
end

function TheContractorFarmers.getAcres(person, land)
    local acres = 0
    for _, farmlandId in ipairs(person.farmlandIds) do
        local farmland = land[farmlandId]
        if farmland ~= nil then
            acres = acres + farmland.acres
        end
    end
    return acres
end

-- The People tab (111) ------------------------------------------------------------

-- Everyone, as the Others view lists them: the official first, then the
-- farmers by name (then id). Each row is { person, acres, farmlandCount,
-- hasYard }; the official's land is always none. land: as getLand's map.
function TheContractorFarmers:getPeopleRows(land)
    local farmers = self:getFarmers()
    table.sort(farmers, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.id < b.id
    end)
    local official = self:getOfficial()
    if official ~= nil then
        table.insert(farmers, 1, official)
    end

    local rows = {}
    for _, person in ipairs(farmers) do
        table.insert(rows, {
            person = person,
            acres = TheContractorFarmers.getAcres(person, land),
            farmlandCount = #person.farmlandIds,
            hasYard = person.yardFarmlandId ~= nil,
        })
    end
    return rows
end

-- What a farm has done for a customer, from its logbook entries (060,
-- newest first) and their invoices (049): { completed, missed, paid, owed,
-- last (the newest entry) }. A completed job with no invoice was paid on
-- the spot (the lateInvoices setting off), so its price counts as paid.
-- getInvoice(entry) returns the entry's invoice or nil.
function TheContractorFarmers.getCustomerHistory(entries, customerId, getInvoice)
    local history = { completed = 0, missed = 0, paid = 0, owed = 0, last = nil }
    local STATUS = TheContractorFinances.STATUS
    for _, entry in ipairs(entries) do
        if entry.customerId == customerId then
            history.last = history.last or entry
            if entry.outcome == TheContractorLogbook.OUTCOME.MISSED then
                history.missed = history.missed + 1
            else
                history.completed = history.completed + 1
                local invoice = getInvoice(entry)
                if invoice == nil then
                    history.paid = history.paid + (entry.price or 0)
                elseif invoice.status == STATUS.PAID then
                    history.paid = history.paid + invoice.amount
                elseif invoice.status ~= STATUS.WRITTEN_OFF then
                    history.owed = history.owed + invoice.amount
                end
            end
        end
    end
    return history
end

-- Editing (111) -----------------------------------------------------------------

-- Server: a farm's edit of a farmer or the official (name, gender, look),
-- checked as 066 checks a worker's. Any farm with a company may edit, and
-- the people are shared, so it changes them for everyone. Returns nil once
-- applied, or why it wasn't.
function TheContractorFarmers:editPerson(farmId, personId, name, gender, appearance)
    local person = self.people[personId]
    if person == nil then
        return string.format("there's no person %d", personId)
    end
    local company = g_currentMission.TheContractor.Company
    if company == nil or not company:hasCompany(farmId) then
        TCLog.warning("TheContractor: edit of person %d (%s) refused: farm %d has no company", personId, person.name,
            farmId)
        return "only a farm with a company can edit people"
    end
    local problem = TheContractorStaff.getEditProblem(name, gender, appearance)
    if problem ~= nil then
        TCLog.warning("TheContractor: edit of person %d (%s) refused: %s", personId, person.name, problem)
        return problem
    end

    name = TheContractorStaff.cleanName(name)
    TCLog.info("TheContractor: farm %d edited person %d: %s -> %s, %s -> %s", farmId, personId, person.name, name,
        person.gender, gender)
    self:applyPersonEdited(personId, name, gender, appearance)

    if g_server ~= nil then
        g_server:broadcastEvent(TCEditPersonEvent.new(farmId, personId, name, gender, appearance))
    end
    return nil
end

-- Every machine: the edit lands. The cached look goes, and the menu
-- reloads the portrait (066).
function TheContractorFarmers:applyPersonEdited(personId, name, gender, appearance)
    local person = self.people[personId]
    if person == nil then
        return
    end
    person.name = name
    person.gender = gender
    person.appearance = appearance
    person.playerStyle = nil
    -- 114: a farmer standing in their yard.
    TCYardFarmers.reloadLook(person)

    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil then
        menu:onPersonEdited(personId)
    end
end

-- Any machine: the people or their land changed, so an open People tab
-- shows it.
local function notifyMenu()
    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil and menu.onPeopleChanged ~= nil then
        menu:onPeopleChanged()
    end
end

-- Choosing who gets land (pure) ---------------------------------------------------

local function distance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

-- How far a farmer's land is from a point (0 on it), or math.huge with no
-- land on the map.
local function distanceToLand(farmer, land, point)
    local nearest = math.huge
    for _, farmlandId in ipairs(farmer.farmlandIds) do
        local farmland = land[farmlandId]
        if farmland ~= nil then
            nearest = math.min(nearest, farmlandId == point.id and 0 or distance(farmland, point))
        end
    end
    return nearest
end

-- The farmer to take `farmland` ({ id, x, z }): among those whose land or
-- yard is within NEAR_MARGIN of the nearest, the one with the fewest acres
-- for their target (then the nearer, then the lower id). Farmers with
-- nothing on the map are only considered when nobody has. nil with no
-- farmers. land: farmlandId -> { x, z, acres }; yards: farmlandId -> { x, z }.
function TheContractorFarmers.chooseHolder(farmers, farmland, land, yards)
    local candidates, nearest = {}, math.huge
    for _, farmer in ipairs(farmers) do
        local d = distanceToLand(farmer, land, farmland)
        local yard = farmer.yardFarmlandId ~= nil and yards[farmer.yardFarmlandId] or nil
        if yard ~= nil then
            d = math.min(d, distance(yard, farmland))
        end
        local share = TheContractorFarmers.getAcres(farmer, land) / math.max(farmer.targetAcres or 0, 1)
        table.insert(candidates, { farmer = farmer, distance = d, share = share })
        nearest = math.min(nearest, d)
    end

    local best = nil
    for _, candidate in ipairs(candidates) do
        if candidate.distance <= nearest + TheContractorFarmers.NEAR_MARGIN then
            if best == nil or candidate.share < best.share or (candidate.share == best.share and
                    (candidate.distance < best.distance or (candidate.distance == best.distance and
                    candidate.farmer.id < best.farmer.id))) then
                best = candidate
            end
        end
    end
    return best ~= nil and best.farmer or nil
end

-- The farmer to take a free yard ({ farmlandId, x, z, declared }), by
-- 109's rule: the farmer whose land is nearest, if they have no yard and
-- it's within MAX_YARD_DISTANCE. A declared yard (117): the nearest farmer
-- without a yard, however far (the lowest id among those with no land on
-- the map). nil otherwise.
function TheContractorFarmers.chooseYardHolder(farmers, yard, land)
    local nearest, nearestDistance = nil, math.huge
    local point = { id = yard.farmlandId, x = yard.x, z = yard.z }
    for _, farmer in ipairs(farmers) do
        if not yard.declared or farmer.yardFarmlandId == nil then
            local d = distanceToLand(farmer, land, point)
            if nearest == nil or d < nearestDistance or (d == nearestDistance and farmer.id < nearest.id) then
                nearest, nearestDistance = farmer, d
            end
        end
    end
    if nearest ~= nil and nearest.yardFarmlandId == nil and
            (yard.declared or nearestDistance <= TheContractorFarmerSplit.MAX_YARD_DISTANCE) then
        return nearest
    end
    return nil
end

-- Generation (server) -------------------------------------------------------------

function TheContractorFarmers:takeId()
    local id = self.nextId
    self.nextId = self.nextId + 1
    return id
end

function TheContractorFarmers:isNameTaken(name)
    for _, person in pairs(self.people) do
        if person.name == name then
            return true
        end
    end
    return false
end

-- A new person with a name and a look, not yet added.
function TheContractorFarmers:makePerson()
    local gender = TCWorkerAppearance.rollGender()
    local name = TheContractorStaff.generateName(gender)
    for _ = 2, TheContractorFarmers.NAME_TRIES do
        if not self:isNameTaken(name) then
            break
        end
        name = TheContractorStaff.generateName(gender)
    end
    return {
        id = self:takeId(),
        name = name,
        gender = gender,
        appearance = TCWorkerAppearance.roll(gender),
        isOfficial = false,
        farmlandIds = {},
        yardFarmlandId = nil,
        targetAcres = 0,
    }
end

-- Throws any farmers away and makes them again from a fresh split of the
-- land no player owns. The official is kept (and made if there's none).
function TheContractorFarmers:generate(targetAcres, seed)
    local result = TheContractorFarmerSplit.splitLiveMap(targetAcres, seed)

    local official = self:getOfficial()
    self.people = {}
    if official == nil then
        official = self:makePerson()
        official.isOfficial = true
    end
    self.people[official.id] = official
    self.officialId = official.id

    for _, share in ipairs(result.farmers) do
        local farmer = self:makePerson()
        for _, farmlandId in ipairs(share.farmlandIds) do
            table.insert(farmer.farmlandIds, farmlandId)
        end
        farmer.yardFarmlandId = share.yardFarmlandId
        farmer.targetAcres = share.target
        farmer.payHabit = TheContractorFarmers.rollPayHabit()
        self.people[farmer.id] = farmer
    end
    self.seed = seed
    self.targetAcres = targetAcres

    TCLog.info("TheContractor: generated %d farmer(s) from %.0f acres (target %s, seed %d), official #%d",
        #result.farmers, result.totalAcres, tostring(targetAcres), seed, official.id)
end

-- Server, once a load's map is in place (TheContractor:resolveSavedVehicles):
-- the first time on a save, generates the people; otherwise tidies their
-- land. Then gives any job without a customer one.
function TheContractorFarmers:setUp()
    if self.isSetUp or not g_currentMission:getIsServer() then
        return
    end
    self.isSetUp = true

    if not self:hasGenerated() then
        self:generate(TheContractorFarmerSplit.TARGET_ACRES, math.random(1, 99999))
    else
        self:reconcileLand()
        self:ensurePayHabits()
    end
    -- 121: everyone's fleet, made or filled in.
    TheContractorFarmerFleet.ensureAll()
    self:linkJobs(false)
    self:linkLogbook()
    notifyMenu()
end

-- Server, at setUp (before any client joins, so nobody needs telling): a
-- logbook entry from before 111 has no customer, so it gets one the way a
-- job would from its field (or the official for an offField job). A
-- workshop entry (100) has none.
function TheContractorFarmers:linkLogbook()
    local logbook = g_currentMission.TheContractor.Logbook
    if logbook == nil then
        return 0
    end
    local count = 0
    for _, farmEntries in pairs(logbook.jobEntriesByFarm) do
        for _, entry in pairs(farmEntries) do
            if entry.customerId == nil and entry.location == nil then
                local jobDef = TheContractorJobGeneration.JOB_TYPES[entry.jobType]
                if jobDef ~= nil and jobDef.offField then
                    entry.customerId = self.officialId
                else
                    entry.customerId = self:getCustomerIdForField(entry.fieldId)
                end
                count = count + 1
            end
        end
    end
    if count > 0 then
        TCLog.info("TheContractor: %d older logbook job(s) given a customer from their fields", count)
    end
    return count
end

-- Server: gives jobs their customer, every job's again (all) or only those
-- without one (or whose customer is gone). Spilt crops follow their
-- original job, so jobs go in id order. Returns the changes, { farmId,
-- jobId, customerId (0 for none) }.
function TheContractorFarmers:linkJobs(all)
    local links = {}
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil then
        return links
    end
    local list = {}
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            table.insert(list, job)
        end
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    for _, job in ipairs(list) do
        if all or job.customerId == nil or self.people[job.customerId] == nil then
            local customerId = self:getCustomerIdForJob(job)
            if customerId ~= job.customerId then
                job.customerId = customerId
                table.insert(links, { farmId = job.farmId, jobId = job.id, customerId = customerId or 0 })
            end
        end
    end
    return links
end

-- Server: tcCompany farmers regenerate. A new split and new farmers; every
-- job is linked again from its field, and everyone's told.
function TheContractorFarmers:regenerate(targetAcres)
    self:generate(targetAcres, math.random(1, 99999))
    TheContractorFarmerFleet.ensureAll()
    -- 113: the old farmers' relationships go with them.
    g_currentMission.TheContractor.Relationships:forgetMissing(self.people)
    local links = self:linkJobs(true)
    if g_server ~= nil then
        g_server:broadcastEvent(TCFarmersEvent.new(self, links))
    end
    notifyMenu()
    return links
end

-- Land changing hands (server) ----------------------------------------------------

function TheContractorFarmers:startListening()
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
    end
end

function TheContractorFarmers:stopListening()
    g_messageCenter:unsubscribe(MessageType.FARMLAND_OWNER_CHANGED, self)
end

function TheContractorFarmers:onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
    -- A savegame's own land is tidied up by setUp.
    if loadFromSavegame or not self.isSetUp then
        return
    end
    self:reconcileLand()
end

local function isFree(farmland)
    return farmland ~= nil and farmland.ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID
end

-- Brings every farmer's land in line with the map (see the file header),
-- given its field land and free yards (by farmland id). Returns the ids of
-- the farmers whose holding changed, as a set.
function TheContractorFarmers:reconcileWith(land, landList, yards)
    local changed = {}
    local farmers = self:getFarmers()

    -- 117: a declared yard isn't field land.
    local function isFieldLand(farmlandId)
        local yard = yards[farmlandId]
        return isFree(land[farmlandId]) and not (yard ~= nil and yard.declared)
    end

    -- What a farmer can no longer have.
    local held = {}
    for _, farmer in ipairs(farmers) do
        local kept = {}
        for _, farmlandId in ipairs(farmer.farmlandIds) do
            if isFieldLand(farmlandId) and not held[farmlandId] then
                held[farmlandId] = true
                table.insert(kept, farmlandId)
            end
        end
        if #kept ~= #farmer.farmlandIds then
            farmer.farmlandIds = kept
            changed[farmer.id] = true
        end
        if farmer.yardFarmlandId ~= nil and yards[farmer.yardFarmlandId] == nil then
            farmer.yardFarmlandId = nil
            changed[farmer.id] = true
        end
    end

    -- Field land nobody has.
    for _, farmland in ipairs(landList) do
        if isFieldLand(farmland.id) and not held[farmland.id] then
            local holder = TheContractorFarmers.chooseHolder(farmers, farmland, land, yards)
            if holder ~= nil then
                held[farmland.id] = true
                table.insert(holder.farmlandIds, farmland.id)
                table.sort(holder.farmlandIds)
                changed[holder.id] = true
            end
        end
    end

    -- Yards nobody has.
    local yardTaken = {}
    for _, farmer in ipairs(farmers) do
        if farmer.yardFarmlandId ~= nil then
            yardTaken[farmer.yardFarmlandId] = true
        end
    end
    local freeYards = {}
    for farmlandId, yard in pairs(yards) do
        if not yardTaken[farmlandId] then
            table.insert(freeYards, yard)
        end
    end
    -- Declared ones (117) first, so a farmer without a yard goes to them.
    table.sort(freeYards, function(a, b)
        if (a.declared == true) ~= (b.declared == true) then
            return a.declared == true
        end
        return a.farmlandId < b.farmlandId
    end)
    for _, yard in ipairs(freeYards) do
        local holder = TheContractorFarmers.chooseYardHolder(farmers, yard, land)
        if holder ~= nil then
            holder.yardFarmlandId = yard.farmlandId
            changed[holder.id] = true
        end
    end

    return changed
end

-- Server: reconcileWith on the live map, telling the clients what changed.
function TheContractorFarmers:reconcileLand()
    local land, landList = TheContractorFarmers.getLand()
    local changed = self:reconcileWith(land, landList, TheContractorFarmers.getFreeYards())
    local ids = {}
    for id in pairs(changed) do
        table.insert(ids, id)
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local farmer = self.people[id]
        TCLog.info("TheContractor: farmer #%d now holds %d farmland(s) (%s), yard %s", id, #farmer.farmlandIds,
            table.concat(farmer.farmlandIds, ", "), tostring(farmer.yardFarmlandId))
        if g_server ~= nil then
            g_server:broadcastEvent(TCFarmerLandEvent.new(farmer))
        end
    end
    if #ids > 0 then
        -- 121: a new yard or more land can bring machines (never takes any).
        if self.isSetUp then
            TheContractorFarmerFleet.ensureAll()
        end
        notifyMenu()
    end
    return ids
end

-- Clients: TCFarmerLandEvent.
function TheContractorFarmers:applyLand(personId, farmlandIds, yardFarmlandId)
    local person = self.people[personId]
    if person == nil then
        return
    end
    person.farmlandIds = farmlandIds
    person.yardFarmlandId = yardFarmlandId
    notifyMenu()
end

-- Any machine (122): a farmer's machines changed, so an open People tab
-- shows them.
function TheContractorFarmers:onFleetChanged(personId)
    notifyMenu()
end

-- Clients: TCFarmerFleetEvent (122), the streamed part of a farmer's fleet.
function TheContractorFarmers:applyFleet(personId, machines)
    local person = self.people[personId]
    if person == nil then
        return
    end
    person.machines = machines
    self:onFleetChanged(personId)
end

-- Clients: TCFarmersEvent (new farmers, and the jobs linked to them).
function TheContractorFarmers:applyState(state, links)
    self:setState(state)
    g_currentMission.TheContractor.Relationships:forgetMissing(self.people)
    local jobs = g_currentMission.TheContractor.Jobs
    for _, link in ipairs(links or {}) do
        local job = jobs ~= nil and jobs:getJob(link.farmId, link.jobId) or nil
        if job ~= nil then
            job.customerId = link.customerId ~= 0 and link.customerId or nil
        end
    end
    notifyMenu()
end

-- Persistence ---------------------------------------------------------------------

local function encodeIds(ids)
    local parts = {}
    for _, id in ipairs(ids) do
        table.insert(parts, tostring(id))
    end
    return table.concat(parts, " ")
end

local function decodeIds(text)
    local ids = {}
    for token in string.gmatch(text or "", "%d+") do
        table.insert(ids, tonumber(token))
    end
    table.sort(ids)
    return ids
end

-- 116, 121: a farmer's machines, under their person key; nil with none.
function TheContractorFarmers.loadMachines(xmlFile, personKey)
    local machines = {}
    local index = 0
    while true do
        local key = string.format("%s.machine(%d)", personKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local machine = {
            id = getXMLInt(xmlFile, key .. "#id"),
            -- 121 (nil on 116's machines: TheContractorFarmerFleet gives one).
            role = getXMLString(xmlFile, key .. "#role"),
            attachedTo = getXMLInt(xmlFile, key .. "#attachedTo"),
            xmlFilename = getXMLString(xmlFile, key .. "#xmlFilename"),
            seed = getXMLInt(xmlFile, key .. "#seed"),
            hours = getXMLFloat(xmlFile, key .. "#hours"),
            hoursDay = getXMLInt(xmlFile, key .. "#hoursDay"),
            hoursPerMonth = getXMLFloat(xmlFile, key .. "#hoursPerMonth") or 0,
            fitted = {},
        }
        local fittedIndex = 0
        while true do
            local fittedKey = string.format("%s.fitted(%d)", key, fittedIndex)
            if not hasXMLProperty(xmlFile, fittedKey) then
                break
            end
            local part = getXMLString(xmlFile, fittedKey .. "#part")
            local day = getXMLInt(xmlFile, fittedKey .. "#day")
            if part ~= nil and day ~= nil then
                machine.fitted[part] = day
            end
            fittedIndex = fittedIndex + 1
        end
        if machine.id ~= nil and machine.xmlFilename ~= nil and machine.seed ~= nil then
            table.insert(machines, machine)
        else
            TCLog.warning("TheContractor: skipping %s in the save, no id, model or seed", key)
        end
        index = index + 1
    end
    return #machines > 0 and machines or nil
end

function TheContractorFarmers.saveMachines(xmlFile, personKey, machines)
    for index, machine in ipairs(machines or {}) do
        local key = string.format("%s.machine(%d)", personKey, index - 1)
        setXMLInt(xmlFile, key .. "#id", machine.id)
        if machine.role ~= nil then
            setXMLString(xmlFile, key .. "#role", machine.role)
        end
        if machine.attachedTo ~= nil then
            setXMLInt(xmlFile, key .. "#attachedTo", machine.attachedTo)
        end
        setXMLString(xmlFile, key .. "#xmlFilename", machine.xmlFilename)
        setXMLInt(xmlFile, key .. "#seed", machine.seed)
        if machine.hours ~= nil then
            setXMLFloat(xmlFile, key .. "#hours", machine.hours)
            setXMLInt(xmlFile, key .. "#hoursDay", machine.hoursDay or 0)
        end
        setXMLFloat(xmlFile, key .. "#hoursPerMonth", machine.hoursPerMonth or 0)
        -- By part, so the save doesn't shuffle.
        local parts = {}
        for part in pairs(machine.fitted or {}) do
            table.insert(parts, part)
        end
        table.sort(parts)
        for fittedIndex, part in ipairs(parts) do
            local fittedKey = string.format("%s.fitted(%d)", key, fittedIndex - 1)
            setXMLString(xmlFile, fittedKey .. "#part", part)
            setXMLInt(xmlFile, fittedKey .. "#day", machine.fitted[part])
        end
    end
end

function TheContractorFarmers:loadFromXMLFile(xmlFile)
    local rootKey = string.format("%s.farmers", TheContractor.SaveKey)
    if not hasXMLProperty(xmlFile, rootKey) then
        return
    end
    self.nextId = getXMLInt(xmlFile, rootKey .. "#nextId") or 1
    self.seed = getXMLInt(xmlFile, rootKey .. "#seed")
    self.targetAcres = getXMLFloat(xmlFile, rootKey .. "#targetAcres")
    self.people = {}
    self.officialId = nil

    local index = 0
    while true do
        local key = string.format("%s.person(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local id = getXMLInt(xmlFile, key .. "#id")
        local name = getXMLString(xmlFile, key .. "#name")
        if id ~= nil and name ~= nil then
            local person = {
                id = id,
                name = name,
                gender = getXMLString(xmlFile, key .. "#gender") or TheContractorStaff.guessGender(name),
                appearance = TCWorkerAppearance.readXML(xmlFile, key .. ".appearance"),
                isOfficial = getXMLBool(xmlFile, key .. "#official") == true,
                farmlandIds = decodeIds(getXMLString(xmlFile, key .. "#farmlands")),
                yardFarmlandId = getXMLInt(xmlFile, key .. "#yard"),
                targetAcres = getXMLFloat(xmlFile, key .. "#targetAcres") or 0,
                payHabit = getXMLString(xmlFile, key .. "#payHabit"),
                machines = TheContractorFarmers.loadMachines(xmlFile, key),
            }
            self.people[id] = person
            if person.isOfficial then
                self.officialId = id
            end
            self.nextId = math.max(self.nextId, id + 1)
        else
            TCLog.warning("TheContractor: skipping %s in the save, no id or name", key)
        end
        index = index + 1
    end
end

function TheContractorFarmers:saveToXmlFile(xmlFile)
    if not self:hasGenerated() then
        return
    end
    local rootKey = string.format("%s.farmers", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextId", self.nextId)
    if self.seed ~= nil then
        setXMLInt(xmlFile, rootKey .. "#seed", self.seed)
    end
    if self.targetAcres ~= nil then
        setXMLFloat(xmlFile, rootKey .. "#targetAcres", self.targetAcres)
    end

    local people = self:getFarmers()
    table.insert(people, 1, self:getOfficial())
    for index, person in ipairs(people) do
        local key = string.format("%s.person(%d)", rootKey, index - 1)
        setXMLInt(xmlFile, key .. "#id", person.id)
        setXMLString(xmlFile, key .. "#name", person.name)
        setXMLString(xmlFile, key .. "#gender", person.gender)
        if person.isOfficial then
            setXMLBool(xmlFile, key .. "#official", true)
        else
            setXMLString(xmlFile, key .. "#farmlands", encodeIds(person.farmlandIds))
            setXMLFloat(xmlFile, key .. "#targetAcres", person.targetAcres)
            if person.payHabit ~= nil then
                setXMLString(xmlFile, key .. "#payHabit", person.payHabit)
            end
            if person.yardFarmlandId ~= nil then
                setXMLInt(xmlFile, key .. "#yard", person.yardFarmlandId)
            end
            TheContractorFarmers.saveMachines(xmlFile, key, person.machines)
        end
        TCWorkerAppearance.writeXML(xmlFile, key .. ".appearance", person.appearance)
    end
end

-- Wire ----------------------------------------------------------------------------

function TheContractorFarmers.writeIds(streamId, ids)
    streamWriteInt32(streamId, #ids)
    for _, id in ipairs(ids) do
        streamWriteInt32(streamId, id)
    end
end

function TheContractorFarmers.readIds(streamId)
    local ids = {}
    for _ = 1, streamReadInt32(streamId) do
        table.insert(ids, streamReadInt32(streamId))
    end
    return ids
end

-- The whole state, for initial client state and TCFarmersEvent.
function TheContractorFarmers:writeState(streamId)
    streamWriteInt32(streamId, self.nextId)
    streamWriteInt32(streamId, self.seed or -1)
    streamWriteFloat32(streamId, self.targetAcres or -1)
    local people = {}
    for _, person in pairs(self.people) do
        table.insert(people, person)
    end
    streamWriteInt32(streamId, #people)
    for _, person in ipairs(people) do
        streamWriteInt32(streamId, person.id)
        streamWriteString(streamId, person.name)
        streamWriteString(streamId, person.gender)
        streamWriteBool(streamId, person.isOfficial)
        TCWorkerAppearance.writeStream(streamId, person.appearance)
        TheContractorFarmers.writeIds(streamId, person.farmlandIds)
        streamWriteInt32(streamId, person.yardFarmlandId or 0)
        streamWriteFloat32(streamId, person.targetAcres)
        -- 122
        TheContractorFarmerFleet.writeStream(streamId, person.machines)
    end
end

function TheContractorFarmers.readState(streamId)
    local state = { nextId = streamReadInt32(streamId), people = {} }
    local seed = streamReadInt32(streamId)
    state.seed = seed >= 0 and seed or nil
    local targetAcres = streamReadFloat32(streamId)
    state.targetAcres = targetAcres >= 0 and targetAcres or nil
    for _ = 1, streamReadInt32(streamId) do
        local person = {
            id = streamReadInt32(streamId),
            name = streamReadString(streamId),
            gender = streamReadString(streamId),
            isOfficial = streamReadBool(streamId),
            appearance = TCWorkerAppearance.readStream(streamId),
            farmlandIds = TheContractorFarmers.readIds(streamId),
        }
        local yardFarmlandId = streamReadInt32(streamId)
        person.yardFarmlandId = yardFarmlandId ~= 0 and yardFarmlandId or nil
        person.targetAcres = streamReadFloat32(streamId)
        person.machines = TheContractorFarmerFleet.readStream(streamId)
        table.insert(state.people, person)
    end
    return state
end

function TheContractorFarmers:setState(state)
    self.nextId = state.nextId
    self.seed = state.seed
    self.targetAcres = state.targetAcres
    self.people = {}
    self.officialId = nil
    for _, person in ipairs(state.people) do
        self.people[person.id] = person
        if person.isOfficial then
            self.officialId = person.id
        end
    end
end

function TheContractorFarmers:writeInitialClientState(streamId, connection)
    self:writeState(streamId)
end

function TheContractorFarmers:readInitialClientState(streamId, connection)
    self:setState(TheContractorFarmers.readState(streamId))
end

-- Console -------------------------------------------------------------------------

function TheContractorFarmers:getListText()
    if not self:hasGenerated() then
        return "No farmers yet: they're made on the server once the map has loaded."
    end
    local land = TheContractorFarmers.getLand()
    local farmers = self:getFarmers()
    local lines = { string.format("Farmers (%d), from a split at %s acres a farmer, seed %s:", #farmers,
        self.targetAcres ~= nil and string.format("%.0f", self.targetAcres) or "?", tostring(self.seed)) }
    for _, farmer in ipairs(farmers) do
        local holding = "no land"
        if #farmer.farmlandIds > 0 then
            holding = string.format("%.0f acres (target %.0f), %d farmland(s): %s",
                TheContractorFarmers.getAcres(farmer, land), farmer.targetAcres, #farmer.farmlandIds,
                table.concat(farmer.farmlandIds, ", "))
        end
        local yard = farmer.yardFarmlandId ~= nil and ("yard " .. farmer.yardFarmlandId) or "yard off the map"
        table.insert(lines, string.format("  #%d %s (%s): %s, %s", farmer.id, farmer.name, farmer.gender,
            holding, yard))
    end
    local official = self:getOfficial()
    table.insert(lines, string.format("Local official: #%d %s (%s)", official.id, official.name, official.gender))
    return table.concat(lines, "\n")
end

function TheContractorFarmers.registerConsoleCommands()
    TCConsole.register("company", "farmers", {
        args = "[preview|show|hide|standing|fleet|regenerate] [targetAcres|farmer] [seed]",
        description = "List the farmers and the local official, preview a land split, show who's in their yard, " ..
            "list the farmers' machines, or generate the farmers again",
        serverOnly = false,
        run = function(farmId, args)
            local tc = g_currentMission.TheContractor
            local mode = args[1] ~= nil and string.lower(args[1]) or nil
            if mode == nil then
                return tc.Farmers:getListText()
            elseif mode == "preview" or mode == "show" or mode == "hide" then
                return TheContractorFarmerSplit.runPreview(mode, args)
            elseif mode == "standing" then
                return TCYardFarmers.describe()
            elseif mode == "fleet" then
                -- 121: the machines are the server's.
                if not g_currentMission:getIsServer() then
                    return "tcCompany farmers fleet only works on the server (single player or the host)."
                end
                return TheContractorFarmerFleet.getListText(args[2] ~= nil and table.concat(args, " ", 2) or nil)
            elseif mode ~= "regenerate" then
                return false
            end

            if not g_currentMission:getIsServer() then
                return "tcCompany farmers regenerate only works on the server (single player or the host)."
            end
            local targetAcres = args[2] ~= nil and tonumber(args[2]) or TheContractorFarmerSplit.TARGET_ACRES
            if targetAcres == nil or targetAcres <= 0 then
                return false
            end
            local links = tc.Farmers:regenerate(targetAcres)
            return string.format("%s\nWarning: every job lost its link to the old farmers, and every farm its " ..
                "relationships with them; %d job(s) were linked again from their fields.", tc.Farmers:getListText(),
                #links)
        end,
    })
end
