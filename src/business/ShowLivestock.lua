-- The show's livestock classes (167): a competition on 165's show day.
--
-- Classes (TCShowClasses): a subtype and an age band, named by the
--   subtype's own title (the game's or RL's) and its ages in months, e.g.
--   "Holstein Bull, 6 to 24 months"; Best Kept Herd, judged on a
--   husbandry; and a supreme
--   champion of each animal type from its class winners (when two or more of
--   its classes ran). A class with nobody in it doesn't run.
-- Entering: in the Show tab while entries are open (TheContractorShow.
--   isEntryOpen), a farm with a company picks a husbandry, then a class its
--   animals can show in, and with RealisticLivestock the animal itself (its
--   key, 166). Without RL an entry is one animal of the breed and band from
--   that husbandry. At most CLASS_LIMIT entries a farm in a class,
--   HERD_LIMIT in Best Kept Herd. Sent as TCShowEntryEvent; the server checks
--   it (getEntryProblem) and sends every entry to every machine
--   (TCShowLivestockEvent).
-- Farmers: when entries close, 2-4 farmers enter each class a player has,
--   and a few classes of their own and Best Kept Herd, each with a rolled
--   score moved by the farmer's hidden stockman trait (TCShowJudging).
--   Server-only, never streamed: the farmers' entries, scores and traits.
-- On the day: a herd is read at midnight before (the day before's state;
--   at judging if that was slept through). At 10:00 the entered animals
--   must be in a livestock trailer of the farm's, stopped in one of the
--   show's trailer line bays (166's TCShowAnimals.getStanding). Each is read
--   from the trailer, scored (TCShowJudging) with the judge's eye, and the
--   classes ranked. An entry with no animal there is a no-show (no penalty);
--   a sick RL animal is turned away by the vet.
-- The pens (182, TCShowPens): at set-out each animal entry gets a pen,
--   players' first and the farmers' filling the rest, their number in the
--   scene (the show's getPens hook). From the gates opening to their
--   closing a farmer's animal is in its pen, and a player's while its
--   trailer stands in the lines (updatePens, every PEN_CHECK_MS): its look
--   read from the trailer, the trailer named so a client hides it there.
--   Judged, a pen has its animal's placing (and a champion's), for the
--   rosettes. Every machine has the pens (looks, placings, never a score),
--   TCShowScene.layOutPens shows them. Saved without who's there (read
--   again after a load).
-- Results: TheContractorShow collects the placings at 16:00 (getPlacings)
--   and pays them (prizes, reputation, the host's opinion), each class with
--   its own amounts here. A player sees their entries' placings and the stats
--   that counted (the judge's card), never the eye or a farmer's numbers.
--
-- Entries last until the next show's announced (or this one's cancelled),
-- so the card can be read after the day. Saved in TheContractor.xml
-- (.showLivestock), in the initial client state; entries hold farms
-- (forgetFarm) and farmers' entries farmers (replacePerson, through the
-- show). A husbandry is its network object id, saved as its uniqueId.
-- Tested in tests/test_showLivestock.lua.

TheContractorShowLivestock = {}
TheContractorShowLivestock_mt = Class(TheContractorShowLivestock)

TheContractorShowLivestock.KEY = "livestock"
-- The results' titleKey; each placing's titleArg is its class key.
TheContractorShowLivestock.TITLE_KEY = "tc_showLivestock_title"

TheContractorShowLivestock.CLASS_LIMIT = 2
TheContractorShowLivestock.HERD_LIMIT = 1
-- Farmers in each class they enter, and the classes they fill with no
-- player in them.
TheContractorShowLivestock.FARMERS_PER_CLASS = { 2, 4 }
TheContractorShowLivestock.FARMER_ONLY_CLASSES = 4
-- Months past its band a vanilla animal is still taken for its entry (it
-- can have had a birthday since it was entered).
TheContractorShowLivestock.VANILLA_AGE_TOLERANCE = 1
-- km/h: a trailer slower than this is stopped.
TheContractorShowLivestock.STOPPED_SPEED = 1
-- 182: how often the server looks for animals to put in their pens (ms).
TheContractorShowLivestock.PEN_CHECK_MS = 1000
-- Rows of pens at most.
TheContractorShowLivestock.PEN_ROWS = 2

-- Prize money (unscaled pounds, real UK show rates), reputation (jobs'
-- worth) and the host's opinion, by placing; highly commended gets a
-- rosette and nothing else. Best Kept Herd takes the show's own amounts.
TheContractorShowLivestock.CLASS_PRIZES = { 20, 15, 10, 0 }
TheContractorShowLivestock.CLASS_REPUTATION = { 2, 1, 1, 0 }
TheContractorShowLivestock.CLASS_OPINION = { 2, 1, 1, 0 }
TheContractorShowLivestock.CHAMPION_PRIZE = 75
TheContractorShowLivestock.CHAMPION_REPUTATION = 5
TheContractorShowLivestock.CHAMPION_OPINION = 6

TheContractorShowLivestock.STATUS = {
    ENTERED = "entered",
    PLACED = "placed",
    UNPLACED = "unplaced",
    NO_SHOW = "noShow",
    SICK = "sick",
}
local STATUS = TheContractorShowLivestock.STATUS
local HERD_KEY = TCShowClasses.HERD_KEY

-- The problems an entry can have (l10n keys, tc_showEntry_<problem>).
TheContractorShowLivestock.PROBLEMS = {
    noShow = "tc_showEntry_noShow",
    closed = "tc_showEntry_closed",
    noCompany = "tc_showEntry_noCompany",
    noHusbandry = "tc_showEntry_noHusbandry",
    noClass = "tc_showEntry_noClass",
    limit = "tc_showEntry_limit",
    noAnimal = "tc_showEntry_noAnimal",
    wrongClass = "tc_showEntry_wrongClass",
    sick = "tc_showEntry_sick",
    alreadyEntered = "tc_showEntry_alreadyEntered",
    notYours = "tc_showEntry_notYours",
}
local PROBLEMS = TheContractorShowLivestock.PROBLEMS

function TheContractorShowLivestock.new()
    local self = setmetatable({}, TheContractorShowLivestock_mt)
    -- Every machine: the show these entries are for (nil for none), the
    -- entries (see newEntry) and whether they've been judged.
    self.showId = nil
    self.entries = {}
    self.nextEntryId = 1
    self.judged = false
    -- Server only, never streamed: farmers' entries ({ classKey, farmerId,
    -- model, score }), whether they've been drawn, and each farmer's
    -- stockman trait (-1 to 1, rolled once).
    self.farmerEntries = {}
    self.drawn = false
    self.stockman = {}
    -- 182, every machine: the pens (TCShowPens: pens[number] = { entryId,
    -- farmId } or a farmer's look; and present, subTypeName, age,
    -- variation, trailerId, animalKey, placing, champion), whether they've
    -- been given out, and a count that goes up whenever they change (the
    -- props follow it, TCAuctionProps).
    self.pens = {}
    self.pensAssigned = false
    self.penVersion = 0
    -- Server: ms to the next look for animals to pen.
    self.penTimer = 0
    -- Server: the rolls (the tests swap it).
    self.random = math.random
    return self
end

-- Every machine, at load: the livestock classes as a show competition.
function TheContractorShowLivestock:register(show)
    show:registerCompetition(TheContractorShowLivestock.KEY, {
        titleKey = TheContractorShowLivestock.TITLE_KEY,
        takesEntries = true,
        getTitle = function(titleArg)
            return TCShowClasses.getTitle(titleArg)
        end,
        getPlacings = function(event)
            return self:getPlacings(event)
        end,
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        onNewDay = function(event)
            if not TheContractorShow.isEntryOpen(event, g_currentMission.environment.currentMonotonicDay) then
                self:drawFarmerEntries(event)
            end
        end,
        onSetOut = function(event)
            self:readHerds(event)
        end,
        -- 182: the pens the showground needs, given out before it's laid out.
        getPens = function(event)
            return self:assignPens(event)
        end,
        onHour = function(event, hour)
            if hour >= TheContractorShow.JUDGING_HOUR then
                self:judge(event)
            end
        end,
        onCancelled = function(event)
            self:reset(nil)
        end,
        replacePerson = function(oldId, newId)
            return self:replacePerson(oldId, newId)
        end,
    })
end

-- Queries (every machine) -----------------------------------------------------------------

-- A farm's entries (this show's, or the last one's until the next), by id.
function TheContractorShowLivestock:getFarmEntries(farmId)
    local entries = {}
    for _, entry in ipairs(self.entries) do
        if entry.farmId == farmId then
            table.insert(entries, entry)
        end
    end
    return entries
end

function TheContractorShowLivestock:getEntry(id)
    for _, entry in ipairs(self.entries) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

-- How many of a farm's entries are in a class (from one husbandry, if
-- given).
function TheContractorShowLivestock:countFarmEntries(farmId, classKey, husbandryId)
    local count = 0
    for _, entry in ipairs(self.entries) do
        if entry.farmId == farmId and entry.classKey == classKey and
                (husbandryId == nil or entry.husbandryId == husbandryId) then
            count = count + 1
        end
    end
    return count
end

function TheContractorShowLivestock:isAnimalEntered(animalKey)
    for _, entry in ipairs(self.entries) do
        if animalKey ~= nil and entry.animalKey == animalKey then
            return true
        end
    end
    return false
end

function TheContractorShowLivestock.getClassLimit(classKey)
    return classKey == HERD_KEY and TheContractorShowLivestock.HERD_LIMIT or TheContractorShowLivestock.CLASS_LIMIT
end

-- The classes a husbandry's animals can enter (every machine, for the
-- entry form): { { classKey, animals = { read, ... } } } in the order the
-- animals come, each read one cluster (TCShowAnimals.readCluster), with
-- castrated, too young and (RL) sick animals left out.
function TheContractorShowLivestock.getHusbandryClasses(husbandry)
    local animalSystem = g_currentMission.animalSystem
    local classes, byKey = {}, {}
    for _, read in ipairs(TCShowAnimals.readHusbandry(husbandry)) do
        local class = TCShowClasses.getClassFor(animalSystem, read)
        if class ~= nil and not (read.animal ~= nil and read.animal.isSick) then
            local item = byKey[class.key]
            if item == nil then
                item = { classKey = class.key, animals = {}, count = 0 }
                byKey[class.key] = item
                table.insert(classes, item)
            end
            table.insert(item.animals, read)
            item.count = item.count + read.count
        end
    end
    return classes
end

-- What's wrong with an entry, or nil (every machine: the menu asks before
-- sending, the server again before taking it). request: { classKey,
-- husbandry (the placeable), animalKey (RL's, or nil) }. Returns the
-- problem's l10n key, or nil and what the entry is: { subTypeName, name }.
function TheContractorShowLivestock:getEntryProblem(farmId, request)
    local tc = g_currentMission.TheContractor
    local event = tc.Show ~= nil and tc.Show:getEvent() or nil
    if event == nil then
        return PROBLEMS.noShow
    end
    if not TheContractorShow.isEntryOpen(event, g_currentMission.environment.currentMonotonicDay) then
        return PROBLEMS.closed
    end
    if tc.Company == nil or not tc.Company:hasCompany(farmId) then
        return PROBLEMS.noCompany
    end
    local husbandry = request.husbandry
    if not TCShowAnimals.isHusbandry(husbandry) or husbandry:getOwnerFarmId() ~= farmId then
        return PROBLEMS.noHusbandry
    end
    local classKey = request.classKey
    if classKey == HERD_KEY then
        if self:countFarmEntries(farmId, HERD_KEY) >= TheContractorShowLivestock.HERD_LIMIT then
            return PROBLEMS.limit
        end
        return nil, {}
    end
    if TCShowClasses.getClass(g_currentMission.animalSystem, classKey) == nil then
        return PROBLEMS.noClass
    end
    if self:countFarmEntries(farmId, classKey) >= TheContractorShowLivestock.CLASS_LIMIT then
        return PROBLEMS.limit
    end
    local animalSystem = g_currentMission.animalSystem
    local reads = TCShowAnimals.readHusbandry(husbandry)
    if request.animalKey ~= nil then
        for _, read in ipairs(reads) do
            if read.animal ~= nil and read.animal.key == request.animalKey then
                local class = TCShowClasses.getClassFor(animalSystem, read)
                if class == nil or class.key ~= classKey then
                    return PROBLEMS.wrongClass
                end
                if read.animal.isSick then
                    return PROBLEMS.sick
                end
                if self:isAnimalEntered(request.animalKey) then
                    return PROBLEMS.alreadyEntered
                end
                return nil, { subTypeName = read.subTypeName, name = read.animal.name }
            end
        end
        return PROBLEMS.noAnimal
    end
    -- Without a key: one more of the breed and band than the farm's entered
    -- from here. RL's animals are always entered by name.
    local count, subTypeName = 0, nil
    for _, read in ipairs(reads) do
        local class = TCShowClasses.getClassFor(animalSystem, read)
        if class ~= nil and class.key == classKey then
            if read.animal ~= nil then
                return PROBLEMS.noAnimal
            end
            count = count + read.count
            subTypeName = read.subTypeName
        end
    end
    local husbandryId = NetworkUtil.getObjectId(husbandry)
    if count <= self:countFarmEntries(farmId, classKey, husbandryId) then
        return PROBLEMS.noAnimal
    end
    return nil, { subTypeName = subTypeName }
end

-- Entering (server) ----------------------------------------------------------------------------

-- Server: the show's entries start again (a new show, or none).
function TheContractorShowLivestock:reset(showId)
    self.showId = showId
    self.entries = {}
    self.judged = false
    self.farmerEntries = {}
    self.drawn = false
    self.pens = {}
    self.pensAssigned = false
    self.penVersion = self.penVersion + 1
    self:sync()
end

-- Server (TCShowEntryEvent): a farm's entry, if it's allowed. Returns the
-- entry, or nil and the problem.
function TheContractorShowLivestock:enter(farmId, classKey, husbandryId, animalKey)
    local husbandry = husbandryId ~= nil and NetworkUtil.getObject(husbandryId) or nil
    local problem, info = self:getEntryProblem(farmId, { classKey = classKey, husbandry = husbandry,
        animalKey = animalKey })
    if problem ~= nil then
        TCLog.info("TheContractor: farm %d's show entry in %s refused: %s", farmId, tostring(classKey), problem)
        return nil, problem
    end
    local event = g_currentMission.TheContractor.Show:getEvent()
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    local entry = {
        id = self.nextEntryId,
        farmId = farmId,
        classKey = classKey,
        husbandryId = husbandryId,
        animalKey = animalKey,
        subTypeName = info.subTypeName,
        name = info.name,
        entrant = classKey == HERD_KEY and TCShowAnimals.getHusbandryName(husbandry) or nil,
        status = STATUS.ENTERED,
        stats = {},
    }
    self.nextEntryId = self.nextEntryId + 1
    table.insert(self.entries, entry)
    TCLog.info("TheContractor: farm %d entered %s in %s (entry %d)", farmId, animalKey or info.subTypeName or "a herd",
        classKey, entry.id)
    self:sync()
    return entry
end

-- Server (TCShowEntryEvent): a farm withdraws its own entry while entries
-- are open. Returns nil, or the problem.
function TheContractorShowLivestock:withdraw(farmId, entryId)
    local entry = self:getEntry(entryId)
    if entry == nil or entry.farmId ~= farmId then
        return PROBLEMS.notYours
    end
    local event = g_currentMission.TheContractor.Show:getEvent()
    if event == nil or not TheContractorShow.isEntryOpen(event, g_currentMission.environment.currentMonotonicDay) then
        return PROBLEMS.closed
    end
    for i, candidate in ipairs(self.entries) do
        if candidate == entry then
            table.remove(self.entries, i)
            break
        end
    end
    TCLog.info("TheContractor: farm %d withdrew show entry %d", farmId, entryId)
    self:sync()
    return nil
end

-- Farmers (server) -------------------------------------------------------------------------------

local function randomInt(random, low, high)
    return math.min(high, low + math.floor(random() * (high - low + 1)))
end

-- A farmer's stockman trait, rolled the first time it's needed.
function TheContractorShowLivestock:getStockman(farmerId)
    local value = self.stockman[farmerId]
    if value == nil then
        value = TCShowJudging.rollStockman(self.random)
        self.stockman[farmerId] = value
    end
    return value
end

-- Picks n of a list at random, in a random order (a copy).
local function pickSome(random, list, n)
    local pool = {}
    for i, item in ipairs(list) do
        pool[i] = item
    end
    local picked = {}
    while #picked < n and #pool > 0 do
        table.insert(picked, table.remove(pool, randomInt(random, 1, #pool)))
    end
    return picked
end

-- The model a class is judged on (and farmers rolled for).
function TheContractorShowLivestock.getModel(classKey)
    if classKey == HERD_KEY then
        return "herd"
    end
    return TCRealisticLivestock.isLoaded() and "rl" or "vanilla"
end

-- Server, when entries close (or at judging if that was missed): farmers
-- enter each class a player's in, a few of their own, and Best Kept Herd.
function TheContractorShowLivestock:drawFarmerEntries(event)
    if self.drawn or event == nil then
        return
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self.drawn = true
    local tc = g_currentMission.TheContractor
    local farmers = tc.Farmers ~= nil and tc.Farmers:getFarmers() or {}
    if #farmers == 0 then
        return
    end
    local classKeys, taken = {}, {}
    for _, entry in ipairs(self.entries) do
        if not taken[entry.classKey] then
            taken[entry.classKey] = true
            table.insert(classKeys, entry.classKey)
        end
    end
    local others = {}
    for _, class in ipairs(TCShowClasses.listClasses(g_currentMission.animalSystem)) do
        if not taken[class.key] then
            table.insert(others, class.key)
        end
    end
    for _, classKey in ipairs(pickSome(self.random, others, TheContractorShowLivestock.FARMER_ONLY_CLASSES)) do
        taken[classKey] = true
        table.insert(classKeys, classKey)
    end
    if not taken[HERD_KEY] then
        table.insert(classKeys, HERD_KEY)
    end
    local range = TheContractorShowLivestock.FARMERS_PER_CLASS
    for _, classKey in ipairs(classKeys) do
        local model = TheContractorShowLivestock.getModel(classKey)
        local count = math.min(#farmers, randomInt(self.random, range[1], range[2]))
        for _, farmer in ipairs(pickSome(self.random, farmers, count)) do
            table.insert(self.farmerEntries, { classKey = classKey, farmerId = farmer.id, model = model,
                score = TCShowJudging.rollFarmerScore(model, self:getStockman(farmer.id), self.random) })
        end
    end
    TCLog.info("TheContractor: show %d: farmers entered %d class(es), %d entries", event.id, #classKeys,
        #self.farmerEntries)
end

-- Judging (server) ---------------------------------------------------------------------------------

-- Server, at midnight before: each herd entered, read as it stands at the
-- end of the day before.
function TheContractorShowLivestock:readHerds(event)
    if self.showId ~= event.id then
        return
    end
    for _, entry in ipairs(self.entries) do
        if entry.classKey == HERD_KEY then
            local husbandry = entry.husbandryId ~= nil and NetworkUtil.getObject(entry.husbandryId) or nil
            if TCShowAnimals.isHusbandry(husbandry) then
                entry.herdReadings = TCShowAnimals.readHerd(husbandry)
            end
        end
    end
end

-- Server: the animals stopped in the show's trailer lines, by farm: {
-- [farmId] = { { read (a cluster), left (its count, as taken), trailer,
-- stopped } } }. includeMoving (182's pens): a moving trailer in the lines
-- too, stopped false.
function TheContractorShowLivestock.readTrailersInLines(includeMoving)
    local husbandrySystem = g_currentMission.husbandrySystem
    local site = g_currentMission.TheContractor.AuctionSite
    local scene = site ~= nil and site:getScene() or nil
    local byFarm = {}
    if scene == nil then
        return byFarm
    end
    for _, trailer in ipairs(husbandrySystem ~= nil and husbandrySystem.livestockTrailers or {}) do
        if TCShowAnimals.isTrailer(trailer) then
            local standing = TCShowAnimals.getStanding(trailer, scene)
            local stopped = (standing.speed or 0) < TheContractorShowLivestock.STOPPED_SPEED
            if standing.bay ~= nil and standing.farmId ~= nil and (stopped or includeMoving) then
                local read = TCShowAnimals.readTrailer(trailer)
                byFarm[standing.farmId] = byFarm[standing.farmId] or {}
                for _, cluster in ipairs(read ~= nil and read.entries or {}) do
                    table.insert(byFarm[standing.farmId], { read = cluster, left = cluster.count, trailer = trailer,
                        stopped = stopped })
                end
            end
        end
    end
    return byFarm
end

-- The animal in the lines for an entry, or nil: RL's by its key; a vanilla
-- one the best of the breed and band (in its tolerance) not yet taken by
-- the farm's other entries (pool: the farm's from readTrailersInLines).
function TheContractorShowLivestock.findEntryAnimal(entry, class, pool, productivity)
    if entry.animalKey ~= nil then
        for _, item in ipairs(pool) do
            if item.left > 0 and item.read.animal ~= nil and item.read.animal.key == entry.animalKey then
                item.left = item.left - 1
                return item.read
            end
        end
        return nil
    end
    local best, bestScore = nil, nil
    for _, item in ipairs(pool) do
        local read = item.read
        if item.left > 0 and read.animal == nil and read.subTypeName == class.subTypeName and
                TCShowClasses.findBand({ class.band }, read.age, class.band.key,
                    TheContractorShowLivestock.VANILLA_AGE_TOLERANCE) ~= nil then
            local score = TCShowJudging.scoreAnimal(class, read, productivity)
            if bestScore == nil or score > bestScore then
                best, bestScore = item, score
            end
        end
    end
    if best == nil then
        return nil
    end
    best.left = best.left - 1
    return best.read
end

-- Server: one entry judged, its status, score (with the eye) and stats set.
function TheContractorShowLivestock:judgeEntry(entry, pool)
    entry.status = STATUS.ENTERED
    entry.score, entry.eye, entry.model, entry.placing, entry.champion = nil, nil, nil, nil, nil
    entry.stats = {}
    local husbandry = entry.husbandryId ~= nil and NetworkUtil.getObject(entry.husbandryId) or nil
    if not TCShowAnimals.isHusbandry(husbandry) then
        husbandry = nil
    end
    local score, stats, model
    if entry.classKey == HERD_KEY then
        local readings = entry.herdReadings or (husbandry ~= nil and TCShowAnimals.readHerd(husbandry) or nil)
        if readings == nil then
            entry.status = STATUS.NO_SHOW
            return
        end
        model = "herd"
        score, stats = TCShowJudging.scoreHerd(readings)
    else
        local class = TCShowClasses.getClass(g_currentMission.animalSystem, entry.classKey)
        local productivity = husbandry ~= nil and TCShowAnimals.getProductivity(husbandry) or nil
        local read = class ~= nil and TheContractorShowLivestock.findEntryAnimal(entry, class, pool or {},
            productivity) or nil
        if read == nil then
            entry.status = STATUS.NO_SHOW
            return
        end
        if read.animal ~= nil and read.animal.isSick then
            entry.status = STATUS.SICK
            return
        end
        score, model, stats = TCShowJudging.scoreAnimal(class, read, productivity)
    end
    entry.model = model
    entry.eye = TCShowJudging.rollEye(self.random)
    entry.score = math.max(0, math.min(100, score + entry.eye))
    entry.stats = stats
end

-- Server, at 10:00 on the day (or when the results are wanted, if that was
-- slept through): every entry read and scored, the classes ranked, every
-- machine told. Once a show.
function TheContractorShowLivestock:judge(event)
    if event == nil or (self.judged and self.showId == event.id) then
        return
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self:drawFarmerEntries(event)
    local lines = TheContractorShowLivestock.readTrailersInLines()
    for _, entry in ipairs(self.entries) do
        self:judgeEntry(entry, lines[entry.farmId])
    end
    self.judged = true
    self:buildPlacings()
    TCLog.info("TheContractor: show %d's livestock judged: %d entries, %d farmers' entries", event.id,
        #self.entries, #self.farmerEntries)
    self:sync()
end

-- The class order: the map's (type, breed, band), Best Kept Herd last.
local function getClassOrder()
    local order = {}
    for i, class in ipairs(TCShowClasses.listClasses(g_currentMission.animalSystem)) do
        order[class.key] = i
    end
    return order
end

-- Server: each class ranked from the scores, players' entries given their
-- placings, and the supreme champions found. Returns the placings for the
-- show (see TheContractorShow:registerCompetition). Pure on the scores, so
-- it can run again after a load.
function TheContractorShowLivestock:buildPlacings()
    local animalSystem = g_currentMission.animalSystem
    local byClass, classKeys = {}, {}
    local function add(classKey, competitor)
        if byClass[classKey] == nil then
            byClass[classKey] = {}
            table.insert(classKeys, classKey)
        end
        table.insert(byClass[classKey], competitor)
    end
    for _, entry in ipairs(self.entries) do
        entry.placing = nil
        entry.champion = nil
        if entry.score ~= nil then
            add(entry.classKey, { score = entry.score, entry = entry })
        end
    end
    for _, farmerEntry in ipairs(self.farmerEntries) do
        farmerEntry.placing = nil
        farmerEntry.champion = nil
        add(farmerEntry.classKey, { score = farmerEntry.score, farmerEntry = farmerEntry })
    end
    local order = getClassOrder()
    table.sort(classKeys, function(a, b)
        local orderA = a == HERD_KEY and math.huge or (order[a] or math.huge - 1)
        local orderB = b == HERD_KEY and math.huge or (order[b] or math.huge - 1)
        if orderA ~= orderB then
            return orderA < orderB
        end
        return a < b
    end)

    local placings = {}
    local winnersByType, classesByType = {}, {}
    local function addPlacing(competitor, placing, titleArg, prize, reputation, opinion)
        local entry, farmerEntry = competitor.entry, competitor.farmerEntry
        table.insert(placings, {
            placing = placing,
            farmId = entry ~= nil and entry.farmId or nil,
            farmerId = farmerEntry ~= nil and farmerEntry.farmerId or nil,
            entrant = entry ~= nil and (entry.name or entry.entrant or entry.animalKey) or "",
            titleArg = titleArg,
            prize = prize,
            reputation = reputation,
            opinion = opinion,
        })
    end
    -- The supreme champion of a type: its best class winner, with two or
    -- more of its classes run. Placed after the type's last class.
    local flushed = {}
    local function addChampion(typeName)
        if typeName == nil or flushed[typeName] or (classesByType[typeName] or 0) < 2 then
            return
        end
        flushed[typeName] = true
        local best = nil
        for _, winner in ipairs(winnersByType[typeName]) do
            if best == nil or winner.score > best.score then
                best = winner
            end
        end
        if best.entry ~= nil then
            best.entry.champion = true
        end
        if best.farmerEntry ~= nil then
            best.farmerEntry.champion = true
        end
        addPlacing(best, 1, TCShowClasses.getChampionKey(typeName), TheContractorShowLivestock.CHAMPION_PRIZE,
            TheContractorShowLivestock.CHAMPION_REPUTATION, TheContractorShowLivestock.CHAMPION_OPINION)
    end
    local lastType = nil
    for _, classKey in ipairs(classKeys) do
        local ranked = TCShowJudging.rank(byClass[classKey])
        local isHerd = classKey == HERD_KEY
        local class = not isHerd and TCShowClasses.getClass(animalSystem, classKey) or nil
        local typeName = class ~= nil and class.typeName or nil
        if lastType ~= nil and typeName ~= lastType then
            addChampion(lastType)
        end
        lastType = typeName
        for _, competitor in ipairs(ranked) do
            local placing = competitor.placing
            if competitor.entry ~= nil then
                competitor.entry.placing = placing
                competitor.entry.status = placing ~= nil and STATUS.PLACED or STATUS.UNPLACED
            end
            if competitor.farmerEntry ~= nil then
                competitor.farmerEntry.placing = placing
            end
            if placing ~= nil then
                if isHerd then
                    -- The show's own amounts (highly commended: none).
                    addPlacing(competitor, placing, classKey, nil, nil, nil)
                else
                    addPlacing(competitor, placing, classKey, TheContractorShowLivestock.CLASS_PRIZES[placing],
                        TheContractorShowLivestock.CLASS_REPUTATION[placing],
                        TheContractorShowLivestock.CLASS_OPINION[placing])
                end
            end
        end
        if typeName ~= nil and ranked[1] ~= nil then
            winnersByType[typeName] = winnersByType[typeName] or {}
            table.insert(winnersByType[typeName], ranked[1])
            classesByType[typeName] = (classesByType[typeName] or 0) + 1
        end
    end
    addChampion(lastType)
    self:applyPenPlacings()
    return placings
end

-- Server (TheContractorShow:giveResults): the placings, judged first if
-- they haven't been.
function TheContractorShowLivestock:getPlacings(event)
    if self.showId ~= event.id or not self.judged then
        self:judge(event)
    end
    return self:buildPlacings()
end

-- The pens (182) ------------------------------------------------------------------------------------

-- Pens a row: as many as the ring's length takes (TCShowScene's).
function TheContractorShowLivestock.getPensPerRow()
    local P = TCShowScene.PENS
    return math.min(P.perRow, math.floor(TCShowScene.RING.length / P.size))
end

-- Server, at set-out (the show's getPens), or the first look after a load
-- that missed it: every animal entry given a pen. Returns how many pens,
-- or nil with none (the scene's default).
function TheContractorShowLivestock:assignPens(event)
    if event == nil then
        return nil
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self:drawFarmerEntries(event)
    if not self.pensAssigned then
        local animalSystem = g_currentMission.animalSystem
        self.pens = TCShowPens.assign(self.entries, self.farmerEntries, TheContractorShowLivestock.getPensPerRow(),
            TheContractorShowLivestock.PEN_ROWS, function(classKey)
                return TCShowClasses.getClass(animalSystem, classKey)
            end, self.random)
        self.pensAssigned = true
        if self.judged then
            self:applyPenPlacings()
        end
        self.penVersion = self.penVersion + 1
        TCLog.info("TheContractor: show %d: %d pen(s) given out", event.id, #self.pens)
        self:sync()
    end
    return #self.pens > 0 and #self.pens or nil
end

-- Every pen's placing and champion from its animal's (server, once judged).
function TheContractorShowLivestock:applyPenPlacings()
    local byPen = {}
    for _, farmerEntry in ipairs(self.farmerEntries) do
        if farmerEntry.pen ~= nil then
            byPen[farmerEntry.pen] = farmerEntry
        end
    end
    for number, pen in ipairs(self.pens) do
        local source = pen.entryId ~= nil and self:getEntry(pen.entryId) or byPen[number]
        pen.placing = source ~= nil and source.placing or nil
        pen.champion = source ~= nil and source.champion == true or nil
    end
    self.penVersion = self.penVersion + 1
end

-- Server, every frame: who's in their pens, looked at every PEN_CHECK_MS.
function TheContractorShowLivestock:update(dt)
    self.penTimer = self.penTimer - dt
    if self.penTimer > 0 then
        return
    end
    self.penTimer = TheContractorShowLivestock.PEN_CHECK_MS
    self:updatePens()
end

-- Server: the pens' animals as they are now. A farmer's is there while the
-- gates are open; a player's while its trailer stands in the lines (it
-- must have stopped to be penned; it stays penned until the trailer
-- leaves). A no-show or a sick one isn't penned. Every machine told of a
-- change.
function TheContractorShowLivestock:updatePens()
    local tc = g_currentMission.TheContractor
    local event = tc.Show ~= nil and tc.Show:getEvent() or nil
    local env = g_currentMission.environment
    local scene = tc.AuctionSite ~= nil and tc.AuctionSite:getScene() or nil
    local open = event ~= nil and self.showId == event.id and TCShowScene.isShowDressing(scene) and
        TCShowPens.isOpen(event.day, env.currentMonotonicDay, env.currentHour or 0, TheContractorShow.START_HOUR,
            TheContractorShow.END_HOUR)
    if open and not self.pensAssigned then
        self:assignPens(event)
    end
    local lines = open and TheContractorShowLivestock.readTrailersInLines(true) or {}
    local changed = false
    local function set(pen, field, value)
        if pen[field] ~= value then
            pen[field] = value
            changed = true
        end
    end
    for _, pen in ipairs(self.pens) do
        if pen.entryId == nil then
            if pen.subTypeName ~= nil then
                set(pen, "present", open or nil)
            end
        else
            local read, trailer = nil, nil
            local entry = self:getEntry(pen.entryId)
            if open and entry ~= nil and entry.status ~= STATUS.NO_SHOW and entry.status ~= STATUS.SICK then
                read, trailer = self:findPenAnimal(entry, pen, lines[entry.farmId])
            end
            if read ~= nil then
                set(pen, "present", true)
                set(pen, "trailerId", NetworkUtil.getObjectId(trailer))
                set(pen, "subTypeName", read.subTypeName)
                set(pen, "age", read.age)
                set(pen, "variation", read.animal ~= nil and read.animal.variation or 1)
                set(pen, "animalKey", read.animal ~= nil and read.animal.key or nil)
            else
                set(pen, "present", nil)
                set(pen, "trailerId", nil)
            end
        end
    end
    if changed then
        self.penVersion = self.penVersion + 1
        self:sync()
    end
end

-- Server: a player's pen's animal in the lines, and its trailer, or nil. A
-- moving trailer counts only for the animal already penned from it. pool:
-- the farm's from readTrailersInLines(true), shared by its pens so no
-- animal's in two.
function TheContractorShowLivestock:findPenAnimal(entry, pen, pool)
    if pool == nil then
        return nil
    end
    local usable = {}
    for _, item in ipairs(pool) do
        if item.stopped or (pen.present and pen.trailerId == NetworkUtil.getObjectId(item.trailer)) then
            table.insert(usable, item)
        end
    end
    local class = TCShowClasses.getClass(g_currentMission.animalSystem, entry.classKey)
    if class == nil then
        return nil
    end
    local husbandry = entry.husbandryId ~= nil and NetworkUtil.getObject(entry.husbandryId) or nil
    local productivity = TCShowAnimals.isHusbandry(husbandry) and TCShowAnimals.getProductivity(husbandry) or nil
    local read = TheContractorShowLivestock.findEntryAnimal(entry, class, usable, productivity)
    if read == nil or (read.animal ~= nil and read.animal.isSick) then
        return nil
    end
    for _, item in ipairs(usable) do
        if item.read == read then
            return read, item.trailer
        end
    end
    return nil
end

-- Farms and farmers --------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's entries go.
function TheContractorShowLivestock:forgetFarm(farmId)
    for i = #self.entries, 1, -1 do
        if self.entries[i].farmId == farmId then
            table.remove(self.entries, i)
        end
    end
    -- 182: its pens stand empty (the others keep their numbers).
    for number, pen in ipairs(self.pens or {}) do
        if pen.farmId == farmId then
            self.pens[number] = {}
            self.penVersion = (self.penVersion or 0) + 1
        end
    end
end

-- Server (128, through the show): a retired farmer's entries are their
-- successor's, who has their own trait. Returns how many.
function TheContractorShowLivestock:replacePerson(oldId, newId)
    local count = 0
    for _, farmerEntry in ipairs(self.farmerEntries) do
        if farmerEntry.farmerId == oldId then
            farmerEntry.farmerId = newId
            count = count + 1
        end
    end
    self.stockman[oldId] = nil
    return count
end

-- Sync ------------------------------------------------------------------------------------------------

-- Server: every machine has the entries (an open menu catches up as the
-- event goes, TC_DATA_UPDATED).
function TheContractorShowLivestock:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCShowLivestockEvent.new(self))
    end
end

-- What every machine has of the entries (no scores, no eye).
function TheContractorShowLivestock.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    streamWriteBool(streamId, state.judged == true)
    streamWriteUInt16(streamId, #state.entries)
    for _, entry in ipairs(state.entries) do
        streamWriteInt32(streamId, entry.id)
        streamWriteInt32(streamId, entry.farmId)
        streamWriteString(streamId, entry.classKey)
        streamWriteInt32(streamId, entry.husbandryId or -1)
        streamWriteString(streamId, entry.animalKey or "")
        streamWriteString(streamId, entry.subTypeName or "")
        streamWriteString(streamId, entry.name or "")
        streamWriteString(streamId, entry.entrant or "")
        streamWriteString(streamId, entry.status)
        streamWriteUInt8(streamId, entry.placing or 0)
        streamWriteBool(streamId, entry.champion == true)
        streamWriteUInt8(streamId, #(entry.stats or {}))
        for _, stat in ipairs(entry.stats or {}) do
            streamWriteString(streamId, stat.key)
            streamWriteFloat32(streamId, stat.value or -1)
            streamWriteFloat32(streamId, stat.target or -1)
        end
    end
    -- 182: the pens, a farmer's look and placing too (never a score).
    local pens = state.pens or {}
    streamWriteUInt8(streamId, #pens)
    for _, pen in ipairs(pens) do
        streamWriteInt32(streamId, pen.entryId or -1)
        streamWriteInt32(streamId, pen.farmId or 0)
        streamWriteString(streamId, pen.subTypeName or "")
        streamWriteInt16(streamId, pen.age or -1)
        streamWriteUInt8(streamId, pen.variation or 0)
        streamWriteBool(streamId, pen.present == true)
        streamWriteInt32(streamId, pen.trailerId or -1)
        streamWriteString(streamId, pen.animalKey or "")
        streamWriteUInt8(streamId, pen.placing or 0)
        streamWriteBool(streamId, pen.champion == true)
    end
end

local function readOptionalString(streamId)
    local value = streamReadString(streamId)
    return value ~= "" and value or nil
end

local function readOptionalNumber(value)
    return value >= 0 and value or nil
end

function TheContractorShowLivestock.readState(streamId)
    local state = { entries = {} }
    state.showId = readOptionalNumber(streamReadInt32(streamId))
    state.judged = streamReadBool(streamId)
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local entry = {
            id = streamReadInt32(streamId),
            farmId = streamReadInt32(streamId),
            classKey = streamReadString(streamId),
            husbandryId = readOptionalNumber(streamReadInt32(streamId)),
            animalKey = readOptionalString(streamId),
            subTypeName = readOptionalString(streamId),
            name = readOptionalString(streamId),
            entrant = readOptionalString(streamId),
            status = streamReadString(streamId),
            stats = {},
        }
        local placing = streamReadUInt8(streamId)
        entry.placing = placing > 0 and placing or nil
        entry.champion = streamReadBool(streamId) or nil
        local stats = streamReadUInt8(streamId)
        for _ = 1, stats do
            table.insert(entry.stats, {
                key = streamReadString(streamId),
                value = readOptionalNumber(streamReadFloat32(streamId)),
                target = readOptionalNumber(streamReadFloat32(streamId)),
            })
        end
        table.insert(state.entries, entry)
    end
    state.pens = {}
    local penCount = streamReadUInt8(streamId)
    for _ = 1, penCount do
        local pen = {
            entryId = readOptionalNumber(streamReadInt32(streamId)),
            farmId = streamReadInt32(streamId),
            subTypeName = readOptionalString(streamId),
            age = readOptionalNumber(streamReadInt16(streamId)),
            variation = streamReadUInt8(streamId),
            present = streamReadBool(streamId) or nil,
            trailerId = readOptionalNumber(streamReadInt32(streamId)),
            animalKey = readOptionalString(streamId),
        }
        if pen.variation == 0 then
            pen.variation = nil
        end
        local placing = streamReadUInt8(streamId)
        pen.placing = placing > 0 and placing or nil
        pen.champion = streamReadBool(streamId) or nil
        if pen.farmId == 0 then
            pen.farmId = nil
        end
        table.insert(state.pens, pen)
    end
    return state
end

-- A client: the entries as the server sent them.
function TheContractorShowLivestock:applyState(state)
    self.showId = state.showId
    self.judged = state.judged
    self.entries = state.entries
    self.pens = state.pens or {}
    self.penVersion = self.penVersion + 1
end

function TheContractorShowLivestock:writeInitialClientState(streamId, connection)
    TheContractorShowLivestock.writeState(streamId, self)
end

function TheContractorShowLivestock:readInitialClientState(streamId, connection)
    self:applyState(TheContractorShowLivestock.readState(streamId))
end

-- Persistence (server) -----------------------------------------------------------------------------

TheContractorShowLivestock.SAVE_KEY = "showLivestock"

function TheContractorShowLivestock:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowLivestock.SAVE_KEY
    if self.showId ~= nil then
        setXMLInt(xmlFile, key .. "#showId", self.showId)
    end
    setXMLInt(xmlFile, key .. "#nextEntryId", self.nextEntryId)
    setXMLBool(xmlFile, key .. "#judged", self.judged)
    setXMLBool(xmlFile, key .. "#drawn", self.drawn)
    for i, entry in ipairs(self.entries) do
        local entryKey = string.format("%s.entry(%d)", key, i - 1)
        setXMLInt(xmlFile, entryKey .. "#id", entry.id)
        setXMLInt(xmlFile, entryKey .. "#farmId", entry.farmId)
        setXMLString(xmlFile, entryKey .. "#classKey", entry.classKey)
        local husbandry = entry.husbandryId ~= nil and NetworkUtil.getObject(entry.husbandryId) or nil
        local uniqueId = husbandry ~= nil and husbandry.getUniqueId ~= nil and husbandry:getUniqueId() or
            entry.husbandryUniqueId
        if uniqueId ~= nil then
            setXMLString(xmlFile, entryKey .. "#husbandry", uniqueId)
        end
        for _, name in ipairs({ "animalKey", "subTypeName", "name", "entrant", "status" }) do
            if entry[name] ~= nil then
                setXMLString(xmlFile, entryKey .. "#" .. name, entry[name])
            end
        end
        if entry.score ~= nil then
            setXMLFloat(xmlFile, entryKey .. "#score", entry.score)
            setXMLFloat(xmlFile, entryKey .. "#eye", entry.eye or 0)
            setXMLString(xmlFile, entryKey .. "#model", entry.model or "")
        end
        for j, stat in ipairs(entry.stats or {}) do
            local statKey = string.format("%s.stat(%d)", entryKey, j - 1)
            setXMLString(xmlFile, statKey .. "#key", stat.key)
            if stat.value ~= nil then
                setXMLFloat(xmlFile, statKey .. "#value", stat.value)
            end
            if stat.target ~= nil then
                setXMLFloat(xmlFile, statKey .. "#target", stat.target)
            end
        end
        local readings = entry.herdReadings
        if readings ~= nil then
            for _, item in ipairs(TCShowJudging.WEIGHTS.herd) do
                if readings[item.key] ~= nil then
                    setXMLFloat(xmlFile, entryKey .. ".herd#" .. item.key, readings[item.key])
                end
            end
        end
    end
    for i, farmerEntry in ipairs(self.farmerEntries) do
        local farmerKey = string.format("%s.farmerEntry(%d)", key, i - 1)
        setXMLString(xmlFile, farmerKey .. "#classKey", farmerEntry.classKey)
        setXMLInt(xmlFile, farmerKey .. "#farmerId", farmerEntry.farmerId)
        setXMLString(xmlFile, farmerKey .. "#model", farmerEntry.model or "")
        setXMLFloat(xmlFile, farmerKey .. "#score", farmerEntry.score)
        if farmerEntry.pen ~= nil then
            setXMLInt(xmlFile, farmerKey .. "#pen", farmerEntry.pen)
        end
    end
    -- 182: the pens as given out (who's in them now is read again).
    setXMLBool(xmlFile, key .. "#pensAssigned", self.pensAssigned)
    for i, pen in ipairs(self.pens) do
        local penKey = string.format("%s.pen(%d)", key, i - 1)
        if pen.entryId ~= nil then
            setXMLInt(xmlFile, penKey .. "#entryId", pen.entryId)
            setXMLInt(xmlFile, penKey .. "#farmId", pen.farmId or 0)
        elseif pen.subTypeName ~= nil then
            setXMLString(xmlFile, penKey .. "#subTypeName", pen.subTypeName)
            setXMLInt(xmlFile, penKey .. "#age", pen.age or 0)
            setXMLInt(xmlFile, penKey .. "#variation", pen.variation or 1)
        else
            setXMLBool(xmlFile, penKey .. "#empty", true)
        end
    end
    local farmerIds = {}
    for farmerId in pairs(self.stockman) do
        table.insert(farmerIds, farmerId)
    end
    table.sort(farmerIds)
    for i, farmerId in ipairs(farmerIds) do
        local stockmanKey = string.format("%s.stockman(%d)", key, i - 1)
        setXMLInt(xmlFile, stockmanKey .. "#farmerId", farmerId)
        setXMLFloat(xmlFile, stockmanKey .. "#value", self.stockman[farmerId])
    end
end

function TheContractorShowLivestock:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowLivestock.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.nextEntryId = getXMLInt(xmlFile, key .. "#nextEntryId") or 1
    self.judged = getXMLBool(xmlFile, key .. "#judged") == true
    self.drawn = getXMLBool(xmlFile, key .. "#drawn") == true
    self.entries = {}
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.entry(%d)", key, i)) do
        local entryKey = string.format("%s.entry(%d)", key, i)
        local entry = {
            id = getXMLInt(xmlFile, entryKey .. "#id") or self.nextEntryId,
            farmId = getXMLInt(xmlFile, entryKey .. "#farmId") or 0,
            classKey = getXMLString(xmlFile, entryKey .. "#classKey") or "",
            husbandryUniqueId = getXMLString(xmlFile, entryKey .. "#husbandry"),
            stats = {},
        }
        for _, name in ipairs({ "animalKey", "subTypeName", "name", "entrant", "status" }) do
            entry[name] = getXMLString(xmlFile, entryKey .. "#" .. name)
        end
        entry.status = entry.status or STATUS.ENTERED
        entry.score = getXMLFloat(xmlFile, entryKey .. "#score")
        if entry.score ~= nil then
            entry.eye = getXMLFloat(xmlFile, entryKey .. "#eye")
            local model = getXMLString(xmlFile, entryKey .. "#model")
            entry.model = model ~= "" and model or nil
        end
        local j = 0
        while hasXMLProperty(xmlFile, string.format("%s.stat(%d)", entryKey, j)) do
            local statKey = string.format("%s.stat(%d)", entryKey, j)
            table.insert(entry.stats, { key = getXMLString(xmlFile, statKey .. "#key") or "",
                value = getXMLFloat(xmlFile, statKey .. "#value"), target = getXMLFloat(xmlFile, statKey .. "#target") })
            j = j + 1
        end
        if hasXMLProperty(xmlFile, entryKey .. ".herd") then
            entry.herdReadings = {}
            for _, item in ipairs(TCShowJudging.WEIGHTS.herd) do
                entry.herdReadings[item.key] = getXMLFloat(xmlFile, entryKey .. ".herd#" .. item.key)
            end
        end
        self.nextEntryId = math.max(self.nextEntryId, entry.id + 1)
        table.insert(self.entries, entry)
        i = i + 1
    end
    self.farmerEntries = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.farmerEntry(%d)", key, i)) do
        local farmerKey = string.format("%s.farmerEntry(%d)", key, i)
        local model = getXMLString(xmlFile, farmerKey .. "#model")
        table.insert(self.farmerEntries, {
            classKey = getXMLString(xmlFile, farmerKey .. "#classKey") or "",
            farmerId = getXMLInt(xmlFile, farmerKey .. "#farmerId") or 0,
            model = model ~= "" and model or nil,
            score = getXMLFloat(xmlFile, farmerKey .. "#score") or 0,
            pen = getXMLInt(xmlFile, farmerKey .. "#pen"),
        })
        i = i + 1
    end
    self.pensAssigned = getXMLBool(xmlFile, key .. "#pensAssigned") == true
    self.pens = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.pen(%d)", key, i)) do
        local penKey = string.format("%s.pen(%d)", key, i)
        local pen = {}
        local entryId = getXMLInt(xmlFile, penKey .. "#entryId")
        if entryId ~= nil then
            pen.entryId = entryId
            pen.farmId = getXMLInt(xmlFile, penKey .. "#farmId")
        else
            pen.subTypeName = getXMLString(xmlFile, penKey .. "#subTypeName")
            if pen.subTypeName ~= nil then
                pen.farmer = true
                pen.age = getXMLInt(xmlFile, penKey .. "#age") or 0
                pen.variation = getXMLInt(xmlFile, penKey .. "#variation") or 1
            end
        end
        table.insert(self.pens, pen)
        i = i + 1
    end
    self.stockman = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.stockman(%d)", key, i)) do
        local stockmanKey = string.format("%s.stockman(%d)", key, i)
        local farmerId = getXMLInt(xmlFile, stockmanKey .. "#farmerId")
        if farmerId ~= nil then
            self.stockman[farmerId] = getXMLFloat(xmlFile, stockmanKey .. "#value") or 0
        end
        i = i + 1
    end
    if self.judged then
        -- The placings and statuses again, from the saved scores.
        self:buildPlacings()
    end
end

-- Server, once placeables exist: each entry's husbandry from its uniqueId.
function TheContractorShowLivestock:resolveSavedVehicles()
    local placeableSystem = g_currentMission.placeableSystem
    local byUniqueId = {}
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        if placeable.getUniqueId ~= nil and placeable:getUniqueId() ~= nil then
            byUniqueId[placeable:getUniqueId()] = placeable
        end
    end
    for _, entry in ipairs(self.entries) do
        if entry.husbandryUniqueId ~= nil then
            local placeable = byUniqueId[entry.husbandryUniqueId]
            if placeable ~= nil then
                entry.husbandryId = NetworkUtil.getObjectId(placeable)
                entry.husbandryUniqueId = nil
            else
                TCLog.info("TheContractor: show entry %d's husbandry %s has gone", entry.id, entry.husbandryUniqueId)
            end
        end
    end
end

-- Console ------------------------------------------------------------------------------------------------

local function getFarmName(farmId)
    local farm = g_farmManager ~= nil and g_farmManager:getFarmById(farmId) or nil
    return farm ~= nil and farm.name or string.format("farm %d", farmId)
end

local function getFarmerName(farmerId)
    local farmers = g_currentMission.TheContractor.Farmers
    local person = farmers ~= nil and farmers:getPerson(farmerId) or nil
    return person ~= nil and person.name or string.format("farmer %d", farmerId)
end

-- The classes with anyone in them, in show order.
function TheContractorShowLivestock:getClassKeysEntered()
    local keys, seen = {}, {}
    local function add(classKey)
        if not seen[classKey] then
            seen[classKey] = true
            table.insert(keys, classKey)
        end
    end
    for _, entry in ipairs(self.entries) do
        add(entry.classKey)
    end
    for _, farmerEntry in ipairs(self.farmerEntries) do
        add(farmerEntry.classKey)
    end
    local order = getClassOrder()
    table.sort(keys, function(a, b)
        local orderA = a == HERD_KEY and math.huge or (order[a] or math.huge - 1)
        local orderB = b == HERD_KEY and math.huge or (order[b] or math.huge - 1)
        if orderA ~= orderB then
            return orderA < orderB
        end
        return a < b
    end)
    return keys
end

-- tcShow entries (read only, any player): this show's entries by class,
-- with no scores.
function TheContractorShowLivestock:describeEntries()
    if self.showId == nil then
        return "There are no show entries: entries open when a show's announced."
    end
    local keys = self:getClassKeysEntered()
    if #keys == 0 then
        return string.format("Show %d has no livestock entries yet.", self.showId)
    end
    local lines = { string.format("Show %d's livestock entries (%s):", self.showId,
        self.judged and "judged" or (self.drawn and "entries closed" or "entries open")) }
    for _, classKey in ipairs(keys) do
        table.insert(lines, string.format("  %s (%s):", TCShowClasses.getTitle(classKey), classKey))
        for _, entry in ipairs(self.entries) do
            if entry.classKey == classKey then
                local what = entry.name or entry.animalKey or entry.entrant or entry.subTypeName or "-"
                local outcome = entry.status
                if entry.placing ~= nil then
                    outcome = string.format("placed %d", entry.placing)
                end
                if entry.champion then
                    outcome = outcome .. ", champion"
                end
                table.insert(lines, string.format("    entry %d: %s, %s - %s", entry.id, getFarmName(entry.farmId),
                    what, outcome))
            end
        end
        local farmers = {}
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.classKey == classKey then
                table.insert(farmers, getFarmerName(farmerEntry.farmerId))
            end
        end
        if #farmers > 0 then
            table.insert(lines, string.format("    farmers: %s", table.concat(farmers, ", ")))
        end
    end
    return table.concat(lines, "\n")
end

-- tcDebug showScores: the hidden numbers.
function TheContractorShowLivestock:describeScores()
    if self.showId == nil then
        return "There are no show entries."
    end
    local lines = { string.format("Show %d: %s, %s.", self.showId, self.judged and "judged" or "not judged",
        self.drawn and "farmers drawn" or "farmers not drawn") }
    for _, classKey in ipairs(self:getClassKeysEntered()) do
        table.insert(lines, string.format("  %s:", classKey))
        for _, entry in ipairs(self.entries) do
            if entry.classKey == classKey then
                table.insert(lines, string.format("    entry %d (farm %d): %s, score %s (eye %s, %s)", entry.id,
                    entry.farmId, entry.status, entry.score ~= nil and string.format("%.1f", entry.score) or "-",
                    entry.eye ~= nil and string.format("%+.1f", entry.eye) or "-", entry.model or "-"))
            end
        end
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.classKey == classKey then
                table.insert(lines, string.format("    %s (stockman %+.2f): score %.1f (%s)",
                    getFarmerName(farmerEntry.farmerId), self.stockman[farmerEntry.farmerId] or 0, farmerEntry.score,
                    farmerEntry.model or "-"))
            end
        end
    end
    return table.concat(lines, "\n")
end

function TheContractorShowLivestock.registerConsoleCommands()
    TCConsole.register("show", "entries", {
        description = "This show's livestock entries by class: players' (with their placings once judged) and farmers'",
        serverOnly = false,
        run = function()
            return g_currentMission.TheContractor.ShowLivestock:describeEntries()
        end,
    })

    TCConsole.register("debug", "showScores", {
        description = "The show's hidden livestock scores: each entry's score and judge's eye, farmers' scores and stockman traits",
        run = function()
            return g_currentMission.TheContractor.ShowLivestock:describeScores()
        end,
    })

    TCConsole.register("debug", "showJudge", {
        description = "Judge the show's livestock now, on its day (the trailers in the lines read as they stand)",
        run = function()
            local tc = g_currentMission.TheContractor
            local event = tc.Show:getEvent()
            if event == nil or event.day ~= g_currentMission.environment.currentMonotonicDay then
                return "It isn't the show's day: 'tcDebug showDay' makes it today."
            end
            tc.ShowLivestock.judged = false
            tc.ShowLivestock:judge(event)
            return tc.ShowLivestock:describeEntries()
        end,
    })

    -- 182: the pens as the server has them, read again first.
    TCConsole.register("debug", "showPens", {
        description = "The show's pens: whose animal each holds, whether it's there now (and from which trailer), its look and placing",
        run = function()
            local livestock = g_currentMission.TheContractor.ShowLivestock
            livestock:updatePens()
            return livestock:describePens()
        end,
    })
end

-- 182: the pens, for tcDebug showPens.
function TheContractorShowLivestock:describePens()
    if #self.pens == 0 then
        return self.pensAssigned and "The show's pens were given out, but no animal has one." or
            "No pens given out yet: that's at the show's set-out (midnight before)."
    end
    local lines = { string.format("Show pens (%d):", #self.pens) }
    for number, pen in ipairs(self.pens) do
        local who
        if pen.entryId ~= nil then
            local entry = self:getEntry(pen.entryId)
            who = string.format("%s's entry %d (%s)", getFarmName(pen.farmId or 0), pen.entryId,
                entry ~= nil and entry.classKey or "gone")
        elseif pen.subTypeName ~= nil then
            who = "a farmer's"
        else
            who = "empty"
        end
        local state = pen.present and "there" or "not there"
        if pen.present and pen.trailerId ~= nil then
            state = string.format("there, from trailer %d", pen.trailerId)
        end
        local look = pen.subTypeName ~= nil and string.format("%s, %d months, coat %d", pen.subTypeName, pen.age or 0,
            pen.variation or 1) or "-"
        local placed = pen.placing ~= nil and string.format(", placed %d%s", pen.placing,
            pen.champion and ", champion" or "") or ""
        table.insert(lines, string.format("  %d: %s, %s; %s%s", number, who, state, look, placed))
    end
    return table.concat(lines, "\n")
end
