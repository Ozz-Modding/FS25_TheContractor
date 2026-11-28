-- The show's livestock classes (167): a competition on 165's show day.
--
-- Classes (TCShowClasses): a subtype and an age band, named by the
--   subtype's own title (the game's or RL's) and its ages in months, e.g.
--   "Holstein Bull, 6 to 24 months"; Best Kept Herd, judged on a
--   husbandry; and a supreme
--   champion of each animal type from its class winners (when two or more of
--   its classes ran). A class with nobody in it doesn't run.
-- Entering: in the Show tab while entries are open (TheContractorShow.
--   isEntryOpen; 188: and late, after they close, until 09:30 on the day
--   (TheContractorShow.ENTRY_CLOSE_MINUTE), into a class on the ring's
--   timetable: getWindowProblem), a farm with a company picks a husbandry, then
--   a class its animals can show in, and with RealisticLivestock the animal itself (its
--   key, 166). Without RL an entry is one animal of the breed and band from
--   that husbandry. At most CLASS_LIMIT entries a farm in a class,
--   HERD_LIMIT in Best Kept Herd. Sent as TCShowEntryEvent; the server checks
--   it (getEntryProblem) and sends every entry to every machine
--   (TCShowLivestockEvent).
-- The breeders' entries (188): when entries close (or at set-out if that
--   was missed), the show's breeders are planned (tc.BreedersPen:plan) and
--   enter their own animals, some of each class they have stock for
--   (farmerEntries with a breeder and animal). Premium stock (the user's
--   call): with RL each is judged on the real animal in its breeder's
--   trailer (through RL's API); without, its score's rolled high
--   (TCShowJudging.rollBreederScore), moved by the farmer's hidden stockman
--   trait. Other farmers enter a row of pens' worth of single animals in
--   the classes running (addRowEntries), each a rolled score. Only with no
--   breeders at all (no room for their pens) do farmers enter as 167 had
--   it: 2-4 in each class a player has and a few of their own. Farmers
--   enter Best Kept Herd either way.
--   Server-only, never streamed: the scores and traits. Every machine has
--   each breeder's entry's class and, once given, its placing.
-- The timetable (188, TCShowRing): made with the breeders' entries, a slot
--   for each class with anyone in it (the champions after their type's
--   classes, Best Kept Herd last), from 10:00, about an hour each. Too many
--   and the breeders' own classes go first, never a player's.
-- The ring (188, updateRing on the server, every PEN_CHECK_MS): at a
--   slot's start its entries are judged and its entrants stand in the ring
--   (self.ring's line-up: a player's animal as it's seen in its trailer in
--   the lines, hidden there meanwhile, a farmer's from its pen, a breeder's
--   from their pen); a player's entry
--   with no animal in the lines then is a no-show (no penalty), a sick RL
--   animal turned away by the vet. A farm is told its class is in. At
--   judgeAt the line stands in placing order and the placings are given
--   (the rosettes on the pens, a rosette notice to each placed farm). At
--   its end they're back (a player's in its trailer, the rest in their
--   pens). A champion's slot lines up its type's class winners. A jump in
--   time runs the slots it passes in turn.
-- A herd is read at midnight before (the day before's state; at judging
--   if that was slept through; 188: one entered on the day, as it's
--   entered).
-- The pens (182, TCShowPens): at set-out the farmers' single animals get a
--   row of pens (188: never a player's, which stays in its trailer, so
--   entries can come up to the day; the breeders' are in their own pens),
--   their number in the scene (the show's getPens hook), each animal there
--   from the gates opening to their closing (updatePens). Placed, a pen has
--   its animal's placing (and a champion's), for the rosettes. Every
--   machine has the pens (looks, placings, never who or a score),
--   TCShowScene.layOutPens shows them with the breeders' and the ring
--   (getDisplay).
-- Results: TheContractorShow collects the placings at 16:00 (getPlacings,
--   any slot not yet run run first) and pays them (prizes, reputation, the
--   host's opinion), each class with its own amounts here; the rosette
--   notices are this competition's own, as each class is placed
--   (noticesGiven). A player sees their entries' placings and the stats
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
-- 188: the minute of the show's day a farm is told of entered animals not
-- in the drop-off zone (the trailer lines) yet.
TheContractorShowLivestock.DROP_OFF_CHECK_MINUTE = 9 * 60

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

-- The class order: the map's (type, breed, band), Best Kept Herd last.
local function getClassOrder()
    local order = {}
    for i, class in ipairs(TCShowClasses.listClasses(g_currentMission.animalSystem)) do
        order[class.key] = i
    end
    return order
end

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
    -- 188, server: whether the farms have been told of animals not in the
    -- drop-off zone (checkDropOff, once a show).
    self.dropOffChecked = false
    -- 182, every machine: the pens (TCShowPens: pens[number] = a farmer's
    -- look, { subTypeName, age, variation }, and present, placing,
    -- champion; 188: never a player's), whether they've been given out, and
    -- a count that goes up whenever they or (188) the ring change (the
    -- props follow it, TCAuctionProps).
    self.pens = {}
    self.pensAssigned = false
    self.penVersion = 0
    -- 188, every machine: the timetable (TCShowRing's slots: { key, from,
    -- judgeAt, to }), each slot's state (TCShowRing.STATE), the class in the
    -- ring now ({ slot, placed, lineup = { { pen } or { breeder, animal } } }
    -- or nil), and (a client's copy) the breeders' entries as every machine
    -- has them: { breeder, animal, classKey, placing, champion }.
    self.timetable = {}
    self.slotStates = {}
    self.ring = nil
    self.breederEntries = {}
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
        -- 188: the rosette notices go as each class is placed.
        noticesGiven = true,
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

-- The classes a husbandry's (188: or a livestock trailer's) animals can
-- enter (every machine, for the entry form): { { classKey, animals = {
-- read, ... } } } in the order the animals come, each read one cluster
-- (TCShowAnimals.readCluster), with castrated, too young and (RL) sick
-- animals left out.
function TheContractorShowLivestock.getHusbandryClasses(husbandry)
    local animalSystem = g_currentMission.animalSystem
    local classes, byKey = {}, {}
    for _, read in ipairs(TCShowAnimals.readSource(husbandry)) do
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

local function getMinute()
    return math.floor((g_currentMission.environment.dayTime or 0) / 60000)
end

-- 188 (every machine): whether animals can be entered now at all: while
-- entries are open, or late, after they've closed, until
-- TheContractorShow.ENTRY_CLOSE_MINUTE on the day, once the ring's
-- timetable is made.
function TheContractorShowLivestock:isEntryWindow(event)
    local env = g_currentMission.environment
    if TheContractorShow.isEntryOpen(event, env.currentMonotonicDay) then
        return true
    end
    return TheContractorShow.isLateEntryOpen(event, env.currentMonotonicDay, getMinute()) and
        self.showId == event.id and #self.timetable > 0
end

-- 188 (every machine): what stops a class being entered (or an entry in
-- it withdrawn) now, or nil: any class until 09:30 on the day (a late
-- entry in a class not on the ring's timetable adds it: enter).
function TheContractorShowLivestock:getWindowProblem(event, classKey)
    if not self:isEntryWindow(event) then
        return PROBLEMS.closed
    end
    return nil
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
    if not self:isEntryWindow(event) then
        return PROBLEMS.closed
    end
    if tc.Company == nil or not tc.Company:hasCompany(farmId) then
        return PROBLEMS.noCompany
    end
    local windowProblem = self:getWindowProblem(event, request.classKey)
    if windowProblem ~= nil then
        return windowProblem
    end
    -- 188: a husbandry, or a livestock trailer of the farm's (Best Kept
    -- Herd only a husbandry).
    local husbandry = request.husbandry
    if not TCShowAnimals.isSource(husbandry) or husbandry:getOwnerFarmId() ~= farmId then
        return PROBLEMS.noHusbandry
    end
    local classKey = request.classKey
    if classKey == HERD_KEY and not TCShowAnimals.isHusbandry(husbandry) then
        return PROBLEMS.noHusbandry
    end
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
    local reads = TCShowAnimals.readSource(husbandry)
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
    -- A trailer's: against all the farm's in the class (its entries keep
    -- no trailer).
    local husbandryId = TCShowAnimals.isHusbandry(husbandry) and NetworkUtil.getObjectId(husbandry) or nil
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
    self.dropOffChecked = false
    self.pens = {}
    self.pensAssigned = false
    self.timetable = {}
    self.slotStates = {}
    self.ring = nil
    self.breederEntries = {}
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
        -- 188: none for an animal entered from a trailer.
        husbandryId = TCShowAnimals.isHusbandry(husbandry) and husbandryId or nil,
        animalKey = animalKey,
        subTypeName = info.subTypeName,
        name = info.name,
        entrant = classKey == HERD_KEY and TCShowAnimals.getHusbandryName(husbandry) or nil,
        status = STATUS.ENTERED,
        stats = {},
    }
    -- 188: a herd entered on the day, after the herds were read at
    -- midnight, is read as it stands now.
    if classKey == HERD_KEY and g_currentMission.environment.currentMonotonicDay >= event.day then
        entry.herdReadings = TCShowAnimals.readHerd(husbandry)
    end
    self.nextEntryId = self.nextEntryId + 1
    table.insert(self.entries, entry)
    TCLog.info("TheContractor: farm %d entered %s in %s (entry %d)", farmId, animalKey or info.subTypeName or "a herd",
        classKey, entry.id)
    self:onLateChange(classKey)
    self:sync()
    return entry
end

-- 188, server: an entry made or withdrawn after the timetable's made
-- (before 09:30 on the day, so nothing's been judged): a class new to the
-- show gets a few farmers in it (never a breeder: their stock's planned),
-- and the timetable's made again.
function TheContractorShowLivestock:onLateChange(classKey)
    if not self.drawn then
        return
    end
    if classKey ~= HERD_KEY and TCShowRing.findSlot(self.timetable, classKey) == nil then
        local tc = g_currentMission.TheContractor
        local pen = tc.BreedersPen
        local farmers = {}
        for _, farmer in ipairs(tc.Farmers ~= nil and tc.Farmers:getFarmers() or {}) do
            if pen == nil or not pen:isBreeder(farmer.id) then
                table.insert(farmers, farmer)
            end
        end
        self:addFarmerEntries({ classKey }, farmers)
    end
    self:buildTimetable()
    self.penVersion = self.penVersion + 1
end

-- Server (TCShowEntryEvent): a farm withdraws its own entry while it could
-- enter it (getWindowProblem). Returns nil, or the problem.
function TheContractorShowLivestock:withdraw(farmId, entryId)
    local entry = self:getEntry(entryId)
    if entry == nil or entry.farmId ~= farmId then
        return PROBLEMS.notYours
    end
    local event = g_currentMission.TheContractor.Show:getEvent()
    if event == nil then
        return PROBLEMS.closed
    end
    local problem = self:getWindowProblem(event, entry.classKey)
    if problem ~= nil then
        return PROBLEMS.closed
    end
    for i, candidate in ipairs(self.entries) do
        if candidate == entry then
            table.remove(self.entries, i)
            break
        end
    end
    TCLog.info("TheContractor: farm %d withdrew show entry %d", farmId, entryId)
    self:onLateChange(entry.classKey)
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

-- The model a breeder's entry is judged on (the class's: RL's, or
-- vanilla's).
local function getBreederModel(breeder)
    if breeder ~= nil and breeder.hasTrailer then
        return "rl"
    end
    return TCRealisticLivestock.isLoaded() and "rl" or "vanilla"
end

-- Server, when entries close (or at set-out or judging if that was
-- missed): 188's breeders planned (room left for a row of pens) and their
-- entries made, and other farmers a row's worth of single animals in the
-- classes running (their pens' animals); with no breeders, the farmers
-- enter each class a player's in and a few of their own (167's). Farmers
-- enter Best Kept Herd either way. Then the timetable.
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
    local breeders = tc.BreedersPen ~= nil and tc.BreedersPen:plan(event, TheContractorShowLivestock.getPensPerRow()) or
        {}
    local classKeys, taken = {}, {}
    for _, entry in ipairs(self.entries) do
        if not taken[entry.classKey] then
            taken[entry.classKey] = true
            table.insert(classKeys, entry.classKey)
        end
    end
    if #breeders > 0 then
        for index, breeder in ipairs(breeders) do
            local model = getBreederModel(breeder)
            for _, animalId in ipairs(breeder.entries or {}) do
                local animal = breeder.animals[animalId]
                if animal ~= nil then
                    local farmerEntry = { classKey = animal.classKey, farmerId = breeder.farmerId, model = model,
                        breeder = index, animal = animalId }
                    if breeder.hasTrailer then
                        -- RL's animal, judged on the day.
                        farmerEntry.real = true
                    else
                        -- No real animal to judge: a premium roll.
                        farmerEntry.score = TCShowJudging.rollBreederScore(model, self:getStockman(breeder.farmerId),
                            self.random)
                    end
                    table.insert(self.farmerEntries, farmerEntry)
                end
            end
        end
        -- The row of pens: other farmers' animals, in the classes running.
        local isBreeder, others = {}, {}
        for _, breeder in ipairs(breeders) do
            isBreeder[breeder.farmerId] = true
        end
        for _, farmer in ipairs(farmers) do
            if not isBreeder[farmer.id] then
                table.insert(others, farmer)
            end
        end
        local running, seen = {}, {}
        for _, classKey in ipairs(classKeys) do
            if classKey ~= HERD_KEY and not seen[classKey] then
                seen[classKey] = true
                table.insert(running, classKey)
            end
        end
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if not seen[farmerEntry.classKey] then
                seen[farmerEntry.classKey] = true
                table.insert(running, farmerEntry.classKey)
            end
        end
        self:addRowEntries(running, others, TheContractorShowLivestock.getPensPerRow())
    elseif #farmers > 0 then
        local others = {}
        for _, class in ipairs(TCShowClasses.listClasses(g_currentMission.animalSystem)) do
            if not taken[class.key] then
                table.insert(others, class.key)
            end
        end
        local own = {}
        for _, classKey in ipairs(classKeys) do
            table.insert(own, classKey)
        end
        for _, classKey in ipairs(pickSome(self.random, others, TheContractorShowLivestock.FARMER_ONLY_CLASSES)) do
            table.insert(own, classKey)
        end
        self:addFarmerEntries(own, farmers)
    end
    -- Best Kept Herd: farmers', breeders or not.
    if #farmers > 0 then
        self:addFarmerEntries({ HERD_KEY }, farmers)
    end
    self:buildTimetable()
    TCLog.info("TheContractor: show %d: %d breeder(s), %d farmers' and breeders' entries, %d slot(s) in the ring",
        event.id, #breeders, #self.farmerEntries, #self.timetable)
    self:sync()
end

-- 167: farmers' rolled entries in classes, 2-4 farmers each.
function TheContractorShowLivestock:addFarmerEntries(classKeys, farmers)
    local range = TheContractorShowLivestock.FARMERS_PER_CLASS
    for _, classKey in ipairs(classKeys) do
        local model = TheContractorShowLivestock.getModel(classKey)
        local count = math.min(#farmers, randomInt(self.random, range[1], range[2]))
        for _, farmer in ipairs(pickSome(self.random, farmers, count)) do
            table.insert(self.farmerEntries, { classKey = classKey, farmerId = farmer.id, model = model,
                score = TCShowJudging.rollFarmerScore(model, self:getStockman(farmer.id), self.random) })
        end
    end
end

-- 188, server: other farmers' single animals for the row of pens: count
-- entries over the classes (in a random order, round and round), a farmer
-- once a class, each a rolled score as 167's farmers have.
function TheContractorShowLivestock:addRowEntries(classKeys, farmers, count)
    if #classKeys == 0 or #farmers == 0 then
        return
    end
    local order = pickSome(self.random, classKeys, #classKeys)
    local inClass = {}
    local added, tries = 0, 0
    while added < count and tries < count + #order do
        local classKey = order[tries % #order + 1]
        tries = tries + 1
        inClass[classKey] = inClass[classKey] or {}
        local pool = {}
        for _, farmer in ipairs(farmers) do
            if not inClass[classKey][farmer.id] then
                table.insert(pool, farmer)
            end
        end
        if #pool > 0 then
            local farmer = pool[randomInt(self.random, 1, #pool)]
            inClass[classKey][farmer.id] = true
            local model = TheContractorShowLivestock.getModel(classKey)
            table.insert(self.farmerEntries, { classKey = classKey, farmerId = farmer.id, model = model,
                score = TCShowJudging.rollFarmerScore(model, self:getStockman(farmer.id), self.random) })
            added = added + 1
        end
    end
end

-- 188, server: the timetable from the entries (TCShowRing): every class
-- with anyone in it, in show order, the breeders' own dropped from the end
-- if there are too many (and their entries with them). Only before the
-- first slot's run.
function TheContractorShowLivestock:buildTimetable()
    for _, state in pairs(self.slotStates) do
        if state > TCShowRing.STATE.WAITING then
            return
        end
    end
    local order = getClassOrder()
    local animalSystem = g_currentMission.animalSystem
    local seen, keys, players = {}, {}, {}
    local hasHerd = false
    local function add(classKey, isPlayer)
        if classKey == HERD_KEY then
            hasHerd = true
            return
        end
        if isPlayer then
            players[classKey] = true
        end
        if not seen[classKey] and TCShowClasses.getClass(animalSystem, classKey) ~= nil then
            seen[classKey] = true
            table.insert(keys, classKey)
        end
    end
    for _, entry in ipairs(self.entries) do
        add(entry.classKey, true)
    end
    for _, farmerEntry in ipairs(self.farmerEntries) do
        add(farmerEntry.classKey, false)
    end
    table.sort(keys, function(a, b)
        local orderA, orderB = order[a] or math.huge, order[b] or math.huge
        if orderA ~= orderB then
            return orderA < orderB
        end
        return a < b
    end)
    local function getTypeName(classKey)
        local class = TCShowClasses.getClass(animalSystem, classKey)
        return class ~= nil and class.typeName or nil
    end
    local kept, dropped = TCShowRing.pickClasses(keys, players, getTypeName, hasHerd)
    if #dropped > 0 then
        local gone = {}
        for _, classKey in ipairs(dropped) do
            gone[classKey] = true
        end
        for i = #self.farmerEntries, 1, -1 do
            if gone[self.farmerEntries[i].classKey] then
                table.remove(self.farmerEntries, i)
            end
        end
        TCLog.info("TheContractor: %d class(es) with no player in dropped from the ring: no time for them", #dropped)
    end
    self.timetable = TCShowRing.buildTimetable(TCShowRing.getSlotKeys(kept, getTypeName, hasHerd))
    self.slotStates = {}
    for i = 1, #self.timetable do
        self.slotStates[i] = TCShowRing.STATE.WAITING
    end
end

-- 188, server (BreedersPen:open): breeders the showground hadn't room for
-- stay away, so their entries go and the timetable's made again.
function TheContractorShowLivestock:onBreedersAway(event)
    local pen = g_currentMission.TheContractor.BreedersPen
    if pen == nil or self.showId ~= event.id then
        return
    end
    for i = #self.farmerEntries, 1, -1 do
        local farmerEntry = self.farmerEntries[i]
        local breeder = farmerEntry.breeder ~= nil and pen.breeders[farmerEntry.breeder] or nil
        if breeder ~= nil and breeder.absent then
            table.remove(self.farmerEntries, i)
        end
    end
    self:buildTimetable()
    self.penVersion = self.penVersion + 1
    self:sync()
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
-- Returns the animal it was judged on (a class's: its read), or nil.
function TheContractorShowLivestock:judgeEntry(entry, pool)
    entry.status = STATUS.ENTERED
    entry.score, entry.eye, entry.model, entry.placing, entry.champion = nil, nil, nil, nil, nil
    entry.stats = {}
    local husbandry = entry.husbandryId ~= nil and NetworkUtil.getObject(entry.husbandryId) or nil
    if not TCShowAnimals.isHusbandry(husbandry) then
        husbandry = nil
    end
    local score, stats, model
    local judged = nil
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
        judged = read
    end
    entry.model = model
    entry.eye = TCShowJudging.rollEye(self.random)
    entry.score = math.max(0, math.min(100, score + entry.eye))
    entry.stats = stats
    return judged
end

-- 188, server: a breeder's entry judged at its slot's start. With RL's
-- stock (real), the animal in its breeder's trailer through RL's API
-- (catalogue: BreedersPen:getCatalogue(true)'s), a sick one turned away;
-- one RL hasn't there after all gets a premium roll. A rolled entry's roll
-- stands. One whose animal's gone (sold, or never made) is out: no score.
function TheContractorShowLivestock:judgeBreederEntry(farmerEntry, catalogue)
    local pen = g_currentMission.TheContractor.BreedersPen
    local breeder = pen ~= nil and pen.breeders[farmerEntry.breeder] or nil
    local record = breeder ~= nil and breeder.animals[farmerEntry.animal] or nil
    if record == nil or record.sold or record.missing then
        farmerEntry.score, farmerEntry.out = nil, true
        return
    end
    if not farmerEntry.real then
        return
    end
    local found = nil
    for _, item in ipairs(catalogue or {}) do
        if item.breeder == farmerEntry.breeder and record.key ~= nil and item.key == record.key then
            found = item
        end
    end
    if found == nil then
        farmerEntry.real = nil
        farmerEntry.score = TCShowJudging.rollBreederScore(farmerEntry.model, self:getStockman(farmerEntry.farmerId),
            self.random)
        return
    end
    if found.info.diseased then
        farmerEntry.score, farmerEntry.out = nil, true
        return
    end
    local class = TCShowClasses.getClass(g_currentMission.animalSystem, farmerEntry.classKey)
    local read = TCRealisticLivestock.readDescribed(found.info)
    if class == nil or read == nil then
        farmerEntry.score, farmerEntry.out = nil, true
        return
    end
    local score = TCShowJudging.scoreAnimal(class, read, nil)
    farmerEntry.eye = TCShowJudging.rollEye(self.random)
    farmerEntry.score = math.max(0, math.min(100, score + farmerEntry.eye))
end

-- 188: whether a class (or a champion, or the herd) has been placed: its
-- slot's run that far (a save from before 188, judged, has them all).
function TheContractorShowLivestock:isPlaced(classKey)
    if #self.timetable == 0 then
        return self.judged
    end
    local _, index = TCShowRing.findSlot(self.timetable, classKey)
    return index ~= nil and (self.slotStates[index] or 0) >= TCShowRing.STATE.PLACED
end

-- The type a class key's for: a class's, or a champion's.
local function getKeyType(classKey)
    if TCShowClasses.isChampionKey(classKey) then
        return string.sub(classKey, #TCShowClasses.CHAMPION_PREFIX + 1)
    end
    local class = TCShowClasses.getClass(g_currentMission.animalSystem, classKey)
    return class ~= nil and class.typeName or nil
end

-- 188: a player's animal in the ring's line: its entry and its look (the
-- animal read from its trailer in the lines, and the trailer, where a
-- client hides it while it's in the ring). pool: the farm's from
-- readTrailersInLines.
local function newPlayerItem(entry, read, pool)
    local trailerId = nil
    for _, item in ipairs(pool or {}) do
        if item.read == read then
            trailerId = NetworkUtil.getObjectId(item.trailer)
        end
    end
    return { entry = entry, farmId = entry.farmId, look = { subTypeName = read.subTypeName, age = read.age,
        variation = read.animal ~= nil and read.animal.variation or 1,
        animalKey = read.animal ~= nil and read.animal.key or nil, trailerId = trailerId } }
end

local function publishNotice(farmId, text)
    local notices = g_currentMission.TheContractor.Notices
    if notices ~= nil then
        notices:publish(farmId, text, TheContractorShow.NOTICE_MONTHS)
    end
end

-- 188, server: a slot starts. Its entries are judged (a class's: the
-- players' from the trailers in the lines, the breeders' from theirs; the
-- herd's from its readings) and its entrants stand in the ring, in an
-- order from the roll (a player's animal as it's seen in its trailer, a
-- farmer's from their pen, a breeder's from theirs); a champion's lines up
-- its type's class winners. A farm with an entry in it is told.
function TheContractorShowLivestock:startSlot(index)
    local slot = self.timetable[index]
    if slot == nil then
        return
    end
    self.slotStates[index] = TCShowRing.STATE.IN_RING
    local key = slot.key
    local lineup = {}
    local told = {}
    if key == HERD_KEY then
        for _, entry in ipairs(self.entries) do
            if entry.classKey == HERD_KEY then
                self:judgeEntry(entry, nil)
            end
        end
    elseif TCShowClasses.isChampionKey(key) then
        local typeName = getKeyType(key)
        local lines = nil
        for _, entry in ipairs(self.entries) do
            if entry.placing == 1 and entry.classKey ~= HERD_KEY and getKeyType(entry.classKey) == typeName then
                lines = lines or TheContractorShowLivestock.readTrailersInLines()
                local class = TCShowClasses.getClass(g_currentMission.animalSystem, entry.classKey)
                local pool = lines[entry.farmId]
                local read = class ~= nil and TheContractorShowLivestock.findEntryAnimal(entry, class, pool or {}, nil) or
                    nil
                if read ~= nil then
                    table.insert(lineup, newPlayerItem(entry, read, pool))
                end
                told[entry.farmId] = told[entry.farmId] or entry
            end
        end
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.placing == 1 and getKeyType(farmerEntry.classKey) == typeName then
                if farmerEntry.breeder ~= nil then
                    table.insert(lineup, { breeder = farmerEntry.breeder, animal = farmerEntry.animal,
                        farmerEntry = farmerEntry })
                elseif farmerEntry.pen ~= nil then
                    table.insert(lineup, { pen = farmerEntry.pen, farmerEntry = farmerEntry })
                end
            end
        end
    else
        local lines = TheContractorShowLivestock.readTrailersInLines()
        for _, entry in ipairs(self.entries) do
            if entry.classKey == key then
                local pool = lines[entry.farmId]
                local read = self:judgeEntry(entry, pool)
                if entry.score ~= nil and read ~= nil then
                    table.insert(lineup, newPlayerItem(entry, read, pool))
                end
                if told[entry.farmId] == nil or entry.score ~= nil then
                    told[entry.farmId] = entry
                end
            end
        end
        local pen = g_currentMission.TheContractor.BreedersPen
        local catalogue = pen ~= nil and pen:getCatalogue(true) or {}
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.classKey == key and farmerEntry.breeder ~= nil then
                self:judgeBreederEntry(farmerEntry, catalogue)
                if farmerEntry.score ~= nil then
                    table.insert(lineup, { breeder = farmerEntry.breeder, animal = farmerEntry.animal,
                        farmerEntry = farmerEntry })
                end
            elseif farmerEntry.classKey == key and farmerEntry.pen ~= nil and farmerEntry.score ~= nil then
                -- A farmer's from the row of pens.
                table.insert(lineup, { pen = farmerEntry.pen, farmerEntry = farmerEntry })
            end
        end
        -- In an order from the roll.
        for i = #lineup, 2, -1 do
            local j = math.min(i, 1 + math.floor(self.random() * i))
            lineup[i], lineup[j] = lineup[j], lineup[i]
        end
    end
    self.ring = #lineup > 0 and { slot = index, placed = false, lineup = lineup } or nil
    if key ~= HERD_KEY then
        local title = TCShowClasses.getTitle(key)
        for farmId, entry in pairs(told) do
            local textKey = entry.score ~= nil and "tc_showRing_noticeInRing" or "tc_showRing_noticeNoShow"
            publishNotice(farmId, string.format(g_i18n:getText(textKey), title))
        end
    end
    TCLog.info("TheContractor: show %d: %s in the ring (slot %d), %d in the line", self.showId or -1, key, index,
        #lineup)
    self.penVersion = self.penVersion + 1
    self:sync()
end

-- 188, server: a slot's placings given: the line stood in placing order,
-- the pens' rosettes, and a rosette notice to each placed farm.
function TheContractorShowLivestock:placeSlot(index)
    local slot = self.timetable[index]
    if slot == nil then
        return
    end
    if (self.slotStates[index] or 0) < TCShowRing.STATE.IN_RING then
        self:startSlot(index)
    end
    self.slotStates[index] = TCShowRing.STATE.PLACED
    self:buildPlacings()
    local key = slot.key
    local isChampion = TCShowClasses.isChampionKey(key)
    local ring = self.ring
    if ring ~= nil and ring.slot == index then
        for _, item in ipairs(ring.lineup) do
            local source = item.entry or item.farmerEntry
            item.placing = source ~= nil and source.placing or nil
            item.champion = isChampion and source ~= nil and source.champion == true or nil
            if isChampion and not item.champion then
                item.placing = nil
            end
        end
        ring.lineup = TCShowRing.orderByPlacing(ring.lineup)
        ring.placed = true
    end
    local title = TCShowClasses.getTitle(key)
    local typeName = isChampion and getKeyType(key) or nil
    for _, entry in ipairs(self.entries) do
        local placing = nil
        if isChampion then
            placing = entry.champion and getKeyType(entry.classKey) == typeName and 1 or nil
        elseif entry.classKey == key then
            placing = entry.placing
        end
        if placing ~= nil then
            publishNotice(entry.farmId, string.format(g_i18n:getText("tc_show_rosetteNotice"),
                g_i18n:getText(TheContractorShow.getPlacingNameKey(placing)), title))
        end
    end
    TCLog.info("TheContractor: show %d: %s placed", self.showId or -1, key)
    self.penVersion = self.penVersion + 1
    self:sync()
end

-- 188, server: a slot's over, its entrants back in their pens.
function TheContractorShowLivestock:endSlot(index)
    if (self.slotStates[index] or 0) < TCShowRing.STATE.PLACED then
        self:placeSlot(index)
    end
    self.slotStates[index] = TCShowRing.STATE.OVER
    if self.ring ~= nil and self.ring.slot == index then
        self.ring = nil
    end
    local over = true
    for i = 1, #self.timetable do
        if (self.slotStates[i] or 0) < TCShowRing.STATE.OVER then
            over = false
        end
    end
    if over then
        self.judged = true
    end
    self.penVersion = self.penVersion + 1
    self:sync()
end

-- 188, server, every PEN_CHECK_MS on the show's day once it's set out:
-- each slot started, placed and over as the clock passes its times, in
-- turn (a jump in time runs those it passes).
function TheContractorShowLivestock:updateRing()
    local tc = g_currentMission.TheContractor
    local event = tc.Show ~= nil and tc.Show:getEvent() or nil
    local env = g_currentMission.environment
    if event == nil or self.showId ~= event.id or env.currentMonotonicDay ~= event.day or #self.timetable == 0 then
        return
    end
    local scene = tc.AuctionSite ~= nil and tc.AuctionSite:getScene() or nil
    if not TCShowScene.isShowDressing(scene) then
        return
    end
    local minute = math.floor((env.dayTime or 0) / 60000)
    local STATE = TCShowRing.STATE
    for index, slot in ipairs(self.timetable) do
        if (self.slotStates[index] or 0) < STATE.IN_RING and minute >= slot.from then
            self:startSlot(index)
        end
        if (self.slotStates[index] or 0) < STATE.PLACED and minute >= slot.judgeAt then
            self:placeSlot(index)
        end
        if (self.slotStates[index] or 0) < STATE.OVER and minute >= slot.to then
            self:endSlot(index)
        end
    end
end

-- 188, server, every PEN_CHECK_MS on the show's day once it's set out:
-- from DROP_OFF_CHECK_MINUTE, once a show, each farm with entered animals
-- (still to be judged) not in a trailer in the drop-off zone is told how
-- many, so there's time to bring them.
function TheContractorShowLivestock:checkDropOff()
    if self.dropOffChecked then
        return
    end
    local tc = g_currentMission.TheContractor
    local event = tc.Show ~= nil and tc.Show:getEvent() or nil
    local env = g_currentMission.environment
    if event == nil or self.showId ~= event.id or env.currentMonotonicDay ~= event.day then
        return
    end
    local scene = tc.AuctionSite ~= nil and tc.AuctionSite:getScene() or nil
    if not TCShowScene.isShowDressing(scene) or getMinute() < TheContractorShowLivestock.DROP_OFF_CHECK_MINUTE then
        return
    end
    self.dropOffChecked = true
    local lines = TheContractorShowLivestock.readTrailersInLines(true)
    local missing, farms = {}, {}
    for _, entry in ipairs(self.entries) do
        if entry.classKey ~= HERD_KEY and entry.status == STATUS.ENTERED then
            local class = TCShowClasses.getClass(g_currentMission.animalSystem, entry.classKey)
            local read = class ~= nil and
                TheContractorShowLivestock.findEntryAnimal(entry, class, lines[entry.farmId] or {}, nil) or nil
            if read == nil then
                if missing[entry.farmId] == nil then
                    table.insert(farms, entry.farmId)
                end
                missing[entry.farmId] = (missing[entry.farmId] or 0) + 1
            end
        end
    end
    for _, farmId in ipairs(farms) do
        publishNotice(farmId, string.format(g_i18n:getText("tc_showEntry_noticeDropOff"), missing[farmId]))
    end
    TCLog.info("TheContractor: show %d: %d farm(s) told of entries not in the drop-off zone", self.showId, #farms)
end

-- 188, server (tcDebug showRing): the ring moved on a step now: the class
-- in it placed, or sent back to the pens, or the next class called in.
-- Returns what happened, or nil with nothing left.
function TheContractorShowLivestock:stepRing()
    local STATE = TCShowRing.STATE
    for index, slot in ipairs(self.timetable) do
        local state = self.slotStates[index] or 0
        if state == STATE.IN_RING then
            self:placeSlot(index)
            return "placed", slot
        elseif state == STATE.PLACED then
            self:endSlot(index)
            return "over", slot
        elseif state == STATE.WAITING then
            self:startSlot(index)
            return "started", slot
        end
    end
    return nil
end

-- Server, when the results are wanted (16:00, or a jump past the day) or
-- from the console: every slot not yet run, run now in turn. Once a show.
function TheContractorShowLivestock:judge(event)
    if event == nil or (self.judged and self.showId == event.id) then
        return
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self:drawFarmerEntries(event)
    for index = 1, #self.timetable do
        if (self.slotStates[index] or 0) < TCShowRing.STATE.OVER then
            self:endSlot(index)
        end
    end
    self.judged = true
    self:buildPlacings()
    TCLog.info("TheContractor: show %d's livestock judged: %d entries, %d farmers' and breeders' entries", event.id,
        #self.entries, #self.farmerEntries)
    self:sync()
end

-- Server: the placed classes ranked from the scores, players' entries
-- given their placings, and the supreme champions found once their slots
-- are placed. Returns the placings for the show (see TheContractorShow:
-- registerCompetition). Pure on the scores and slots, so it can run again
-- after a load.
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
        if entry.score ~= nil and self:isPlaced(entry.classKey) then
            add(entry.classKey, { score = entry.score, entry = entry })
        end
    end
    for _, farmerEntry in ipairs(self.farmerEntries) do
        farmerEntry.placing = nil
        farmerEntry.champion = nil
        if farmerEntry.score ~= nil and self:isPlaced(farmerEntry.classKey) then
            add(farmerEntry.classKey, { score = farmerEntry.score, farmerEntry = farmerEntry })
        end
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
    local function getEntrant(competitor)
        local entry, farmerEntry = competitor.entry, competitor.farmerEntry
        if entry ~= nil then
            return entry.name or entry.entrant or entry.animalKey or ""
        end
        -- 188: a breeder's animal by its breed's own title.
        if farmerEntry ~= nil and farmerEntry.breeder ~= nil then
            local pen = g_currentMission.TheContractor.BreedersPen
            local breeder = pen ~= nil and pen.breeders[farmerEntry.breeder] or nil
            local animal = breeder ~= nil and breeder.animals[farmerEntry.animal] or nil
            if animal ~= nil then
                return TCShowClasses.getSubTypeTitle(animalSystem, animal.subTypeName)
            end
        end
        return ""
    end
    local function addPlacing(competitor, placing, titleArg, prize, reputation, opinion)
        local entry, farmerEntry = competitor.entry, competitor.farmerEntry
        table.insert(placings, {
            placing = placing,
            farmId = entry ~= nil and entry.farmId or nil,
            farmerId = farmerEntry ~= nil and farmerEntry.farmerId or nil,
            entrant = getEntrant(competitor),
            titleArg = titleArg,
            prize = prize,
            reputation = reputation,
            opinion = opinion,
        })
    end
    -- The supreme champion of a type: its best class winner, with two or
    -- more of its classes run and (188) its own slot placed. Placed after
    -- the type's last class.
    local flushed = {}
    local function addChampion(typeName)
        if typeName == nil or flushed[typeName] or (classesByType[typeName] or 0) < 2 or
                not self:isPlaced(TCShowClasses.getChampionKey(typeName)) then
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

-- Server (TheContractorShow:giveResults): the placings, every slot run
-- first if they haven't all been.
function TheContractorShowLivestock:getPlacings(event)
    if self.showId ~= event.id or not self.judged then
        self:judge(event)
    end
    return self:buildPlacings()
end

-- 188 (every machine): the breeders' entries as every machine has them: {
-- breeder, animal, classKey, placing, champion } (the server's from its
-- own, a client's as sent).
function TheContractorShowLivestock:getBreederEntries()
    if g_currentMission:getIsServer() then
        local list = {}
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.breeder ~= nil then
                table.insert(list, { breeder = farmerEntry.breeder, animal = farmerEntry.animal,
                    classKey = farmerEntry.classKey, placing = farmerEntry.placing, champion = farmerEntry.champion })
            end
        end
        return list
    end
    return self.breederEntries
end

-- 188 (every machine): the class a breeder's animal's entered in (and its
-- entry), or nil.
function TheContractorShowLivestock:getBreederEntryClass(breeder, animal)
    for _, entry in ipairs(self:getBreederEntries()) do
        if entry.breeder == breeder and entry.animal == animal then
            return entry.classKey, entry
        end
    end
    return nil
end

-- 188 (every machine): until when a breeder's animal is held from sale
-- (the minute its class's slot ends; a class winner's, its champion's
-- slot's, if its type has one still to come), or nil when it's free to
-- sell.
function TheContractorShowLivestock:getHeldUntil(breeder, animal)
    local classKey, entry = self:getBreederEntryClass(breeder, animal)
    if classKey == nil then
        return nil
    end
    local OVER = TCShowRing.STATE.OVER
    local slot, index = TCShowRing.findSlot(self.timetable, classKey)
    if slot ~= nil and (self.slotStates[index] or 0) < OVER then
        return slot.to
    end
    if entry.placing == 1 then
        local typeName = getKeyType(classKey)
        local championSlot, championIndex = TCShowRing.findSlot(self.timetable,
            typeName ~= nil and TCShowClasses.getChampionKey(typeName) or "")
        if championSlot ~= nil and (self.slotStates[championIndex] or 0) < OVER then
            return championSlot.to
        end
    end
    return nil
end

-- The pens (182) ------------------------------------------------------------------------------------

-- Pens a row: as many as the ring's length takes (TCShowScene's).
function TheContractorShowLivestock.getPensPerRow()
    local P = TCShowScene.PENS
    return math.min(P.perRow, math.floor(TCShowScene.RING.length / P.size))
end

-- Server, at set-out (the show's getPens), or the first look after a load
-- that missed it: the farmers' animals given a row of pens (188: never a
-- player's, which stays in its trailer, nor a breeder's, in their own
-- pen). Returns how many pens (0 for none).
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
        local farmers = {}
        for _, farmerEntry in ipairs(self.farmerEntries) do
            if farmerEntry.breeder == nil then
                table.insert(farmers, farmerEntry)
            end
        end
        self.pens = TCShowPens.assign(farmers, TheContractorShowLivestock.getPensPerRow(), function(classKey)
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
    return #self.pens
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
        local source = byPen[number]
        pen.placing = source ~= nil and source.placing or nil
        pen.champion = source ~= nil and source.champion == true or nil
    end
    self.penVersion = self.penVersion + 1
end

-- 188 (every machine): what the pens and the ring show now, for
-- TCShowScene.layOutPens' extra: the farmers' animals in the ring (by pen),
-- each breeder's animals in their pen (those there: not sold, missing or in
-- the ring) and their rosettes (in the timetable's order), and the line in
-- the ring.
function TheContractorShowLivestock:getDisplay()
    local extra = { inRing = {}, breeders = {}, ring = {} }
    local pen = g_currentMission.TheContractor.BreedersPen
    local breeders = pen ~= nil and pen.showId ~= nil and pen.showId == self.showId and pen.breeders or {}
    local present = pen ~= nil and pen.present
    local inRing = {}
    local ring = self.ring
    for _, item in ipairs(ring ~= nil and ring.lineup or {}) do
        if item.pen ~= nil then
            local shown = self.pens[item.pen]
            if shown ~= nil and shown.present and shown.subTypeName ~= nil then
                extra.inRing[item.pen] = true
                table.insert(extra.ring, { subTypeName = shown.subTypeName, age = shown.age,
                    variation = shown.variation })
            end
        elseif item.look ~= nil then
            -- A player's, as it's seen in its trailer.
            table.insert(extra.ring, { subTypeName = item.look.subTypeName, age = item.look.age,
                variation = item.look.variation })
        elseif item.breeder ~= nil then
            local breeder = breeders[item.breeder]
            local animal = breeder ~= nil and breeder.animals[item.animal] or nil
            if present and animal ~= nil and not animal.sold and not animal.missing then
                inRing[item.breeder .. ":" .. item.animal] = true
                table.insert(extra.ring, { subTypeName = animal.subTypeName, age = animal.age,
                    variation = animal.variation })
            end
        end
    end
    -- The breeders' rosettes in the order they were won.
    local rosettes = {}
    for _, entry in ipairs(self:getBreederEntries()) do
        local _, classIndex = TCShowRing.findSlot(self.timetable, entry.classKey)
        if entry.placing ~= nil and TCShowScene.ROSETTE_COLOURS[entry.placing] ~= nil then
            table.insert(rosettes, { breeder = entry.breeder, order = (classIndex or 0) * 10 + 1,
                colour = TCShowScene.ROSETTE_COLOURS[entry.placing] })
        end
        if entry.champion then
            local class = TCShowClasses.getClass(g_currentMission.animalSystem, entry.classKey)
            local _, championIndex = TCShowRing.findSlot(self.timetable,
                class ~= nil and TCShowClasses.getChampionKey(class.typeName) or "")
            table.insert(rosettes, { breeder = entry.breeder, order = (championIndex or 0) * 10,
                colour = TCShowScene.ROSETTE_CHAMPION })
        end
    end
    table.sort(rosettes, function(a, b)
        return a.order < b.order
    end)
    for index, breeder in ipairs(breeders) do
        if not breeder.absent then
            local shown = { animals = {}, rosettes = {} }
            if present then
                for _, animal in ipairs(breeder.animals) do
                    if not animal.sold and not animal.missing and not inRing[index .. ":" .. animal.id] then
                        table.insert(shown.animals, animal)
                    end
                end
            end
            for _, rosette in ipairs(rosettes) do
                if rosette.breeder == index then
                    table.insert(shown.rosettes, rosette.colour)
                end
            end
            extra.breeders[index] = shown
        end
    end
    return extra
end

-- Server, every frame: who's in their pens, looked at every PEN_CHECK_MS.
function TheContractorShowLivestock:update(dt)
    self.penTimer = self.penTimer - dt
    if self.penTimer > 0 then
        return
    end
    self.penTimer = TheContractorShowLivestock.PEN_CHECK_MS
    self:updatePens()
    -- 188: the ring, and the drop-off zone's 09:00 look.
    self:checkDropOff()
    self:updateRing()
end

-- Server: the pens' animals as they are now: a farmer's is there while the
-- gates are open (188: a player's never, it stays in its trailer). Every
-- machine told of a change.
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
    -- 188: the breeders' animals in their pens while the gates are open.
    if tc.BreedersPen ~= nil and tc.BreedersPen.showId == self.showId then
        tc.BreedersPen:setPresent(open)
    end
    local changed = false
    for _, pen in ipairs(self.pens) do
        if pen.subTypeName ~= nil and pen.present ~= (open or nil) then
            pen.present = open or nil
            changed = true
        end
    end
    if changed then
        self.penVersion = self.penVersion + 1
        self:sync()
    end
end

-- Farms and farmers --------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's entries go.
function TheContractorShowLivestock:forgetFarm(farmId)
    for i = #self.entries, 1, -1 do
        if self.entries[i].farmId == farmId then
            table.remove(self.entries, i)
        end
    end
    -- 188: its animals leave the ring.
    local ring = self.ring
    if ring ~= nil then
        for i = #ring.lineup, 1, -1 do
            if ring.lineup[i].farmId == farmId then
                table.remove(ring.lineup, i)
                self.penVersion = (self.penVersion or 0) + 1
            end
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
        -- 188: the stats once its class is placed (it's judged a while
        -- before).
        local stats = entry.status ~= STATUS.ENTERED and entry.stats or {}
        streamWriteUInt8(streamId, #(stats or {}))
        for _, stat in ipairs(stats or {}) do
            streamWriteString(streamId, stat.key)
            streamWriteFloat32(streamId, stat.value or -1)
            streamWriteFloat32(streamId, stat.target or -1)
        end
    end
    -- 182: the pens, a farmer's look and placing (never who or a score).
    local pens = state.pens or {}
    streamWriteUInt8(streamId, #pens)
    for _, pen in ipairs(pens) do
        streamWriteString(streamId, pen.subTypeName or "")
        streamWriteInt16(streamId, pen.age or -1)
        streamWriteUInt8(streamId, pen.variation or 0)
        streamWriteBool(streamId, pen.present == true)
        streamWriteUInt8(streamId, pen.placing or 0)
        streamWriteBool(streamId, pen.champion == true)
    end
    -- 188: the breeders' entries (which animal in which class, its placing
    -- once given: never a score), the timetable, each slot's state and the
    -- class in the ring.
    local breederEntries = {}
    if state.farmerEntries ~= nil then
        for _, farmerEntry in ipairs(state.farmerEntries) do
            if farmerEntry.breeder ~= nil then
                table.insert(breederEntries, farmerEntry)
            end
        end
    else
        breederEntries = state.breederEntries or {}
    end
    streamWriteUInt16(streamId, #breederEntries)
    for _, entry in ipairs(breederEntries) do
        streamWriteUInt8(streamId, entry.breeder)
        streamWriteUInt8(streamId, entry.animal)
        streamWriteString(streamId, entry.classKey or "")
        streamWriteUInt8(streamId, entry.placing or 0)
        streamWriteBool(streamId, entry.champion == true)
    end
    local timetable = state.timetable or {}
    streamWriteUInt8(streamId, #timetable)
    for i, slot in ipairs(timetable) do
        streamWriteString(streamId, slot.key)
        streamWriteUInt16(streamId, slot.from)
        streamWriteUInt16(streamId, slot.judgeAt)
        streamWriteUInt16(streamId, slot.to)
        streamWriteUInt8(streamId, (state.slotStates or {})[i] or 0)
    end
    local ring = state.ring
    if streamWriteBool(streamId, ring ~= nil) then
        streamWriteUInt8(streamId, ring.slot)
        streamWriteBool(streamId, ring.placed == true)
        streamWriteUInt8(streamId, #ring.lineup)
        for _, item in ipairs(ring.lineup) do
            streamWriteUInt8(streamId, item.pen or 0)
            streamWriteUInt8(streamId, item.breeder or 0)
            streamWriteUInt8(streamId, item.animal or 0)
            -- A player's animal: its look and its trailer (never a score).
            local look = item.look
            if streamWriteBool(streamId, look ~= nil) then
                streamWriteInt32(streamId, item.farmId or 0)
                streamWriteString(streamId, look.subTypeName or "")
                streamWriteInt16(streamId, look.age or -1)
                streamWriteUInt8(streamId, look.variation or 0)
                streamWriteInt32(streamId, look.trailerId or -1)
                streamWriteString(streamId, look.animalKey or "")
            end
        end
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
            subTypeName = readOptionalString(streamId),
            age = readOptionalNumber(streamReadInt16(streamId)),
            variation = streamReadUInt8(streamId),
            present = streamReadBool(streamId) or nil,
        }
        if pen.variation == 0 then
            pen.variation = nil
        end
        local placing = streamReadUInt8(streamId)
        pen.placing = placing > 0 and placing or nil
        pen.champion = streamReadBool(streamId) or nil
        table.insert(state.pens, pen)
    end
    state.breederEntries = {}
    for _ = 1, streamReadUInt16(streamId) do
        local entry = { breeder = streamReadUInt8(streamId), animal = streamReadUInt8(streamId),
            classKey = streamReadString(streamId) }
        local placing = streamReadUInt8(streamId)
        entry.placing = placing > 0 and placing or nil
        entry.champion = streamReadBool(streamId) or nil
        table.insert(state.breederEntries, entry)
    end
    state.timetable, state.slotStates = {}, {}
    for i = 1, streamReadUInt8(streamId) do
        table.insert(state.timetable, { key = streamReadString(streamId), from = streamReadUInt16(streamId),
            judgeAt = streamReadUInt16(streamId), to = streamReadUInt16(streamId) })
        state.slotStates[i] = streamReadUInt8(streamId)
    end
    if streamReadBool(streamId) then
        local ring = { slot = streamReadUInt8(streamId), placed = streamReadBool(streamId), lineup = {} }
        for _ = 1, streamReadUInt8(streamId) do
            local pen, breeder, animal = streamReadUInt8(streamId), streamReadUInt8(streamId), streamReadUInt8(streamId)
            local item = { pen = pen > 0 and pen or nil, breeder = breeder > 0 and breeder or nil,
                animal = animal > 0 and animal or nil }
            if streamReadBool(streamId) then
                item.farmId = streamReadInt32(streamId)
                item.look = { subTypeName = readOptionalString(streamId),
                    age = readOptionalNumber(streamReadInt16(streamId)), variation = streamReadUInt8(streamId),
                    trailerId = readOptionalNumber(streamReadInt32(streamId)), animalKey = readOptionalString(streamId) }
                if item.look.variation == 0 then
                    item.look.variation = nil
                end
            end
            table.insert(ring.lineup, item)
        end
        state.ring = ring
    end
    return state
end

-- A client: the entries as the server sent them.
function TheContractorShowLivestock:applyState(state)
    self.showId = state.showId
    self.judged = state.judged
    self.entries = state.entries
    self.pens = state.pens or {}
    self.breederEntries = state.breederEntries or {}
    self.timetable = state.timetable or {}
    self.slotStates = state.slotStates or {}
    self.ring = state.ring
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
    setXMLBool(xmlFile, key .. "#dropOffChecked", self.dropOffChecked)
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
        if farmerEntry.score ~= nil then
            setXMLFloat(xmlFile, farmerKey .. "#score", farmerEntry.score)
        end
        if farmerEntry.eye ~= nil then
            setXMLFloat(xmlFile, farmerKey .. "#eye", farmerEntry.eye)
        end
        if farmerEntry.pen ~= nil then
            setXMLInt(xmlFile, farmerKey .. "#pen", farmerEntry.pen)
        end
        -- 188: a breeder's, their animal, judged on the day (real) or not,
        -- out of it.
        if farmerEntry.breeder ~= nil then
            setXMLInt(xmlFile, farmerKey .. "#breeder", farmerEntry.breeder)
            setXMLInt(xmlFile, farmerKey .. "#animal", farmerEntry.animal)
            setXMLBool(xmlFile, farmerKey .. "#real", farmerEntry.real == true)
            setXMLBool(xmlFile, farmerKey .. "#out", farmerEntry.out == true)
        end
    end
    -- 188: the timetable, each slot's state, and the class in the ring.
    for i, slot in ipairs(self.timetable) do
        local slotKey = string.format("%s.slot(%d)", key, i - 1)
        setXMLString(xmlFile, slotKey .. "#key", slot.key)
        setXMLInt(xmlFile, slotKey .. "#from", slot.from)
        setXMLInt(xmlFile, slotKey .. "#judgeAt", slot.judgeAt)
        setXMLInt(xmlFile, slotKey .. "#to", slot.to)
        setXMLInt(xmlFile, slotKey .. "#state", self.slotStates[i] or 0)
    end
    if self.ring ~= nil then
        setXMLInt(xmlFile, key .. ".ring#slot", self.ring.slot)
        setXMLBool(xmlFile, key .. ".ring#placed", self.ring.placed == true)
        for i, item in ipairs(self.ring.lineup) do
            local itemKey = string.format("%s.ring.animal(%d)", key, i - 1)
            setXMLInt(xmlFile, itemKey .. "#pen", item.pen or 0)
            setXMLInt(xmlFile, itemKey .. "#breeder", item.breeder or 0)
            setXMLInt(xmlFile, itemKey .. "#animal", item.animal or 0)
            -- A player's: its entry and look (its trailer's found again
            -- at the next class).
            if item.look ~= nil and item.entry ~= nil then
                setXMLInt(xmlFile, itemKey .. "#entryId", item.entry.id)
                setXMLString(xmlFile, itemKey .. "#subTypeName", item.look.subTypeName or "")
                setXMLInt(xmlFile, itemKey .. "#age", item.look.age or 0)
                setXMLInt(xmlFile, itemKey .. "#variation", item.look.variation or 1)
                if item.look.animalKey ~= nil then
                    setXMLString(xmlFile, itemKey .. "#animalKey", item.look.animalKey)
                end
            end
        end
    end
    -- 182: the pens as given out (who's in them now is read again).
    setXMLBool(xmlFile, key .. "#pensAssigned", self.pensAssigned)
    for i, pen in ipairs(self.pens) do
        local penKey = string.format("%s.pen(%d)", key, i - 1)
        if pen.subTypeName ~= nil then
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
    self.dropOffChecked = getXMLBool(xmlFile, key .. "#dropOffChecked") == true
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
        local breeder = getXMLInt(xmlFile, farmerKey .. "#breeder")
        local farmerEntry = {
            classKey = getXMLString(xmlFile, farmerKey .. "#classKey") or "",
            farmerId = getXMLInt(xmlFile, farmerKey .. "#farmerId") or 0,
            model = model ~= "" and model or nil,
            score = getXMLFloat(xmlFile, farmerKey .. "#score"),
            eye = getXMLFloat(xmlFile, farmerKey .. "#eye"),
            pen = getXMLInt(xmlFile, farmerKey .. "#pen"),
        }
        if breeder ~= nil then
            farmerEntry.breeder = breeder
            farmerEntry.animal = getXMLInt(xmlFile, farmerKey .. "#animal") or 0
            farmerEntry.real = getXMLBool(xmlFile, farmerKey .. "#real") == true or nil
            farmerEntry.out = getXMLBool(xmlFile, farmerKey .. "#out") == true or nil
        elseif farmerEntry.score == nil then
            farmerEntry.score = 0
        end
        table.insert(self.farmerEntries, farmerEntry)
        i = i + 1
    end
    self.timetable, self.slotStates = {}, {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.slot(%d)", key, i)) do
        local slotKey = string.format("%s.slot(%d)", key, i)
        table.insert(self.timetable, { key = getXMLString(xmlFile, slotKey .. "#key") or "",
            from = getXMLInt(xmlFile, slotKey .. "#from") or 0, judgeAt = getXMLInt(xmlFile, slotKey .. "#judgeAt") or 0,
            to = getXMLInt(xmlFile, slotKey .. "#to") or 0 })
        self.slotStates[i + 1] = getXMLInt(xmlFile, slotKey .. "#state") or 0
        i = i + 1
    end
    self.ring = nil
    if hasXMLProperty(xmlFile, key .. ".ring") then
        local ring = { slot = getXMLInt(xmlFile, key .. ".ring#slot") or 0,
            placed = getXMLBool(xmlFile, key .. ".ring#placed") == true, lineup = {} }
        i = 0
        while hasXMLProperty(xmlFile, string.format("%s.ring.animal(%d)", key, i)) do
            local itemKey = string.format("%s.ring.animal(%d)", key, i)
            local pen = getXMLInt(xmlFile, itemKey .. "#pen") or 0
            local breeder = getXMLInt(xmlFile, itemKey .. "#breeder") or 0
            local item = { pen = pen > 0 and pen or nil, breeder = breeder > 0 and breeder or nil,
                animal = breeder > 0 and getXMLInt(xmlFile, itemKey .. "#animal") or nil }
            local entryId = getXMLInt(xmlFile, itemKey .. "#entryId")
            if entryId ~= nil then
                local subTypeName = getXMLString(xmlFile, itemKey .. "#subTypeName")
                item.entryId = entryId
                item.look = { subTypeName = subTypeName ~= "" and subTypeName or nil,
                    age = getXMLInt(xmlFile, itemKey .. "#age"), variation = getXMLInt(xmlFile, itemKey .. "#variation"),
                    animalKey = getXMLString(xmlFile, itemKey .. "#animalKey") }
                item.pen = nil
            end
            table.insert(ring.lineup, item)
            i = i + 1
        end
        self.ring = ring
    end
    self.pensAssigned = getXMLBool(xmlFile, key .. "#pensAssigned") == true
    self.pens = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.pen(%d)", key, i)) do
        local penKey = string.format("%s.pen(%d)", key, i)
        local pen = {}
        -- A player's pen from before 188 stands empty.
        if getXMLInt(xmlFile, penKey .. "#entryId") == nil then
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
    local anyPlaced = self.judged
    for _, state in pairs(self.slotStates) do
        if state >= TCShowRing.STATE.PLACED then
            anyPlaced = true
        end
    end
    if anyPlaced then
        -- The placings and statuses again, from the saved scores.
        self:buildPlacings()
    end
    -- 188: the ring's line back to its entries (for its placing order).
    for _, item in ipairs(self.ring ~= nil and self.ring.lineup or {}) do
        if item.entryId ~= nil then
            item.entry = self:getEntry(item.entryId)
            item.farmId = item.entry ~= nil and item.entry.farmId or nil
            item.entryId = nil
        elseif item.pen ~= nil then
            for _, farmerEntry in ipairs(self.farmerEntries) do
                if farmerEntry.breeder == nil and farmerEntry.pen == item.pen then
                    item.farmerEntry = farmerEntry
                end
            end
        end
        if item.breeder ~= nil then
            for _, farmerEntry in ipairs(self.farmerEntries) do
                if farmerEntry.breeder == item.breeder and farmerEntry.animal == item.animal and
                        TCShowRing.findSlot(self.timetable, farmerEntry.classKey) == self.timetable[self.ring.slot] then
                    item.farmerEntry = farmerEntry
                end
            end
            if item.farmerEntry == nil then
                for _, farmerEntry in ipairs(self.farmerEntries) do
                    if farmerEntry.breeder == item.breeder and farmerEntry.animal == item.animal then
                        item.farmerEntry = farmerEntry
                    end
                end
            end
        end
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
    if #keys == 0 and #self.timetable == 0 then
        return string.format("Show %d has no livestock entries yet.", self.showId)
    end
    local lines = { string.format("Show %d's livestock entries (%s):", self.showId,
        self.judged and "judged" or (self.drawn and "entries closed" or "entries open")) }
    -- 188: in the ring's order once there's a timetable.
    local STATE_NAMES = { [0] = "to come", "in the ring", "placed", "over" }
    local rows = {}
    if #self.timetable > 0 then
        for i, slot in ipairs(self.timetable) do
            table.insert(rows, { key = slot.key, time = string.format("%s-%s, %s", TCShowRing.formatMinute(slot.from),
                TCShowRing.formatMinute(slot.to), STATE_NAMES[self.slotStates[i] or 0] or "-") })
        end
    else
        for _, classKey in ipairs(keys) do
            table.insert(rows, { key = classKey })
        end
    end
    local pen = g_currentMission.TheContractor.BreedersPen
    for _, row in ipairs(rows) do
        local classKey = row.key
        table.insert(lines, string.format("  %s (%s)%s:", TCShowClasses.getTitle(classKey), classKey,
            row.time ~= nil and (" " .. row.time) or ""))
        for _, entry in ipairs(self.entries) do
            if entry.classKey == classKey or (TCShowClasses.isChampionKey(classKey) and entry.champion and
                    TCShowClasses.getChampionKey(getKeyType(entry.classKey) or "") == classKey) then
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
                local name = getFarmerName(farmerEntry.farmerId)
                if farmerEntry.breeder ~= nil then
                    local breeder = pen ~= nil and pen.breeders[farmerEntry.breeder] or nil
                    local animal = breeder ~= nil and breeder.animals[farmerEntry.animal] or nil
                    name = string.format("%s (breeder %d's animal %d%s%s)", name, farmerEntry.breeder,
                        farmerEntry.animal, animal ~= nil and animal.sold and ", sold" or "",
                        farmerEntry.placing ~= nil and string.format(", placed %d", farmerEntry.placing) or "")
                end
                table.insert(farmers, name)
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
                -- 188: a breeder's, judged on the real animal on the day
                -- (no score till then) or rolled.
                local score = farmerEntry.score ~= nil and string.format("%.1f", farmerEntry.score) or
                    (farmerEntry.out and "out" or "to judge")
                local how = farmerEntry.model or "-"
                if farmerEntry.breeder ~= nil then
                    how = string.format("%s, breeder %d's animal %d, %s", how, farmerEntry.breeder, farmerEntry.animal,
                        farmerEntry.real and string.format("judged on the animal%s", farmerEntry.eye ~= nil and
                            string.format(", eye %+.1f", farmerEntry.eye) or "") or "rolled")
                end
                table.insert(lines, string.format("    %s (stockman %+.2f): score %s (%s)",
                    getFarmerName(farmerEntry.farmerId), self.stockman[farmerEntry.farmerId] or 0, score, how))
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
        description = "Judge every class of the show's livestock now, on its day, from the start (the trailers in the lines read as they stand)",
        run = function()
            local tc = g_currentMission.TheContractor
            local event = tc.Show:getEvent()
            if event == nil or event.day ~= g_currentMission.environment.currentMonotonicDay then
                return "It isn't the show's day: 'tcDebug showDay' makes it today."
            end
            local livestock = tc.ShowLivestock
            livestock.judged = false
            for i = 1, #livestock.timetable do
                livestock.slotStates[i] = TCShowRing.STATE.WAITING
            end
            livestock.ring = nil
            livestock:judge(event)
            return livestock:describeEntries()
        end,
    })

    -- 188: the ring a step on.
    TCConsole.register("debug", "showRing", {
        description = "Move the show's ring on a step now: the class in it placed, or back to the pens, or the next class called in",
        run = function()
            local tc = g_currentMission.TheContractor
            local event = tc.Show:getEvent()
            if event == nil or event.day ~= g_currentMission.environment.currentMonotonicDay then
                return "It isn't the show's day: 'tcDebug showDay' makes it today."
            end
            local livestock = tc.ShowLivestock
            livestock:drawFarmerEntries(event)
            local what, slot = livestock:stepRing()
            if what == nil then
                return "Every class has been in the ring."
            end
            local lineup = livestock.ring ~= nil and #livestock.ring.lineup or 0
            local texts = {
                started = "in the ring now, %d in the line",
                placed = "placed, the line in placing order (%d)",
                over = "back in their pens",
            }
            return string.format("%s (%s): " .. texts[what] .. ".", TCShowClasses.getTitle(slot.key), slot.key, lineup)
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
        local who = pen.subTypeName ~= nil and "a farmer's" or "empty"
        local state = pen.present and "there" or "not there"
        local look = pen.subTypeName ~= nil and string.format("%s, %d months, coat %d", pen.subTypeName, pen.age or 0,
            pen.variation or 1) or "-"
        local placed = pen.placing ~= nil and string.format(", placed %d%s", pen.placing,
            pen.champion and ", champion" or "") or ""
        table.insert(lines, string.format("  %d: %s, %s; %s%s", number, who, state, look, placed))
    end
    return table.concat(lines, "\n")
end
