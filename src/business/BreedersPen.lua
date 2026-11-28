-- The breeders at the show (173, 188): farmers who bring their premium
-- stock, each in their own pen on the showground, enter some of it in the
-- livestock classes (ShowLivestock judges them) and, with
-- RealisticLivestock, sell it. The rules and numbers are TCBreedersPen's
-- (src/util/TCBreedersPen.lua); the pens are TCShowScene's; the talking is
-- TCBreedersPenWorld's (and TCShowStandsWorld's, which puts each breeder
-- at their pen). Everything RL goes through RL's own API for other mods
-- (TCRealisticLivestock.getAPI): nothing of RL's is patched or read past it.
--
--   Planned (plan, server) when the show's entries close, or at set-out if
--     that was missed (ShowLivestock asks, then makes their entries): the
--     breeders (TCBreedersPen.planBreeders: farmers who aren't the host),
--     their types, pens and animals, as many as the showground has room
--     for (TCShowScene's pens on a plan of 164's showground; the rest
--     don't come). With RL's API and a spare farm id (pickFarmId), each
--     brings their stock in a livestock trailer (its model picked then, so
--     the stock fits it).
--   Set out (the show's onSetOut, midnight before): a breeder the real
--     showground has no room for stays away (ShowLivestock drops their
--     entries). With RL, each breeder's trailer out behind their pen,
--     MISSION state and owned by the spare farm id (no costs, never sold,
--     and no farm can get at it: vanilla's AccessHandler refuses every farm
--     a vehicle of a farm that doesn't exist), stocked with RL's premium
--     animals as planned (createAnimal, then addAnimalsTo the trailer as the
--     spare farm id). RL keeps nothing ticking in a trailer, saves its
--     animals with it, and streams them to every machine, so what's for
--     sale is the trailers' contents (getAnimalsIn).
--   The day: the breeders' animals are shown in their pens while the gates
--     are open (present, the server's say). A player at a breeder's pen can
--     buy from them while the stands are open (handleBuy, RL only): an
--     animal not entered, or entered in a class that's over
--     (ShowLivestock:getHeldUntil). The server checks it all again, moves it
--     with RL's moveAnimals, only then charges the farm (MoneyType
--     TC_BREEDER_STOCK), and the animal's gone from the pen.
--   Over (onFinished, midnight after; or called off): the trailers and any
--     unsold animals deleted, the breeders gone. A farm created on the
--     spare id while they're out (MessageType.FARM_CREATED) has the trailers
--     taken away at once, so the new farm never owns them.
--
-- A competition of the show's that places nobody (registerCompetition), for
-- its hooks. Every machine holds the show it's for, the spare farm id and
-- the breeders (who, their type, animals' looks and RL keys, what's sold,
-- their trailers' object ids); saved in TheContractor.xml (.breedersPen,
-- the trailers by uniqueId), in the initial client state and sent whole
-- (TCBreedersPenEvent). The breeders are farmers (replacePerson, through
-- the show). Nothing's kept by farm, and nothing's a date. The trailers are
-- locked (TCVehicleLock) and remapped if replaced (TCVehicleReplace).
-- Tested in tests/test_breedersPen.lua.

TheContractorBreedersPen = {}
TheContractorBreedersPen_mt = Class(TheContractorBreedersPen)

TheContractorBreedersPen.KEY = "breedersPen"
TheContractorBreedersPen.SAVE_KEY = "breedersPen"
TheContractorBreedersPen.TITLE_KEY = "tc_breedersPen_title"

local ANSWER = TCBreedersPen.ANSWER

table.insert(FinanceStats.statNames, "tcBreederStock")
FinanceStats.statNameToIndex["tcBreederStock"] = #FinanceStats.statNames

-- What the pen does in the world, swapped by the tests.
local ENGINE = {}
TheContractorBreedersPen.ENGINE = ENGINE

function TheContractorBreedersPen.new()
    local self = setmetatable({}, TheContractorBreedersPen_mt)
    MoneyType.TC_BREEDER_STOCK = MoneyType.register("tcBreederStock", "tc_moneyType_breederStock")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1
    -- Every machine: the show the breeders are for (nil: none), the spare
    -- farm id their trailers belong to (0: none, nothing for sale), the
    -- breeders (see newBreeder), whether their animals are in their pens
    -- now, and a count that goes up whenever any of it changes (the props
    -- follow it, TCAuctionProps).
    self.showId = nil
    self.farmId = 0
    self.breeders = {}
    self.present = false
    self.version = 0
    -- Server: whether the breeders have been planned for showId.
    self.planned = false
    -- Server: trailers loading, so a close drops them as they arrive.
    self.generation = 0
    self.engine = ENGINE
    self.random = math.random
    return self
end

-- Every machine, at load.
function TheContractorBreedersPen:register(show)
    show:registerCompetition(TheContractorBreedersPen.KEY, {
        titleKey = TheContractorBreedersPen.TITLE_KEY,
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        -- 188: the breeders' pens the showground's laid out with.
        getBreeders = function(event)
            return self:getSceneBreeders(event)
        end,
        onSetOut = function(event)
            self:open(event)
        end,
        onFinished = function()
            self:reset(nil)
        end,
        onCancelled = function()
            self:reset(nil)
        end,
        replacePerson = function(oldId, newId)
            return self:replacePerson(oldId, newId)
        end,
    })
    if g_currentMission:getIsServer() and MessageType ~= nil and MessageType.FARM_CREATED ~= nil then
        g_messageCenter:subscribe(MessageType.FARM_CREATED, self.onFarmCreated, self)
    end
end

function TheContractorBreedersPen:delete()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
end

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

local function getShowEvent()
    local tc = getTC()
    return tc ~= nil and tc.Show ~= nil and tc.Show:getEvent() or nil
end

local function getScene()
    local tc = getTC()
    return tc ~= nil and tc.ShowStands ~= nil and tc.ShowStands:getScene() or nil
end

local function farmExists(farmId)
    return g_farmManager:getFarmById(farmId) ~= nil
end

-- Queries (every machine) ------------------------------------------------------------------

-- The breeders who've come for the show announced now (not one left away
-- for want of room), each with its index: { { index, breeder } }.
function TheContractorBreedersPen:getBreeders()
    local list = {}
    local event = getShowEvent()
    if event == nil or self.showId ~= event.id then
        return list
    end
    for index, breeder in ipairs(self.breeders) do
        if not breeder.absent then
            table.insert(list, { index = index, breeder = breeder })
        end
    end
    return list
end

-- A breeder by index (this show's), or nil.
function TheContractorBreedersPen:getBreeder(index)
    local event = getShowEvent()
    local breeder = self.breeders[index or 0]
    if breeder == nil or breeder.absent or event == nil or self.showId ~= event.id then
        return nil
    end
    return breeder
end

-- The breeders' person ids (farmers), this show's: ShowStands, 169's plots
-- and TCYardFarmers leave them out.
function TheContractorBreedersPen:getBreederIds()
    local ids = {}
    for _, item in ipairs(self:getBreeders()) do
        table.insert(ids, item.breeder.farmerId)
    end
    return ids
end

function TheContractorBreedersPen:isBreeder(personId)
    for _, id in ipairs(self:getBreederIds()) do
        if id == personId then
            return true
        end
    end
    return false
end

-- A breeder's person (a farmer), or nil.
function TheContractorBreedersPen:getPerson(index)
    local tc = getTC()
    local breeder = self:getBreeder(index)
    if breeder == nil or tc == nil or tc.Farmers == nil then
        return nil
    end
    return tc.Farmers:getPerson(breeder.farmerId)
end

-- The breeders' ids while they're at their pens (TCYardFarmers keeps them
-- out of their yards).
function TheContractorBreedersPen:getBreedersAtShow()
    if not self:isOpen() then
        return {}
    end
    return self:getBreederIds()
end

-- Whether the breeders are out for the show announced now.
function TheContractorBreedersPen:isOut()
    return #self:getBreeders() > 0
end

-- Whether they're at their pens now: out, their animals there, and the
-- show's stands open.
function TheContractorBreedersPen:isOpen()
    local tc = getTC()
    return self:isOut() and self.present and tc.ShowStands ~= nil and tc.ShowStands:isOpen()
end

-- Whether anything's for sale at this show: RL's API, and the breeders'
-- trailers out on a spare farm id.
function TheContractorBreedersPen:hasSales()
    return self.farmId > 0 and TCRealisticLivestock.getAPI() ~= nil and #self:getTrailerIds() > 0
end

-- Every breeder's trailers' object ids.
function TheContractorBreedersPen:getTrailerIds()
    local ids = {}
    for _, breeder in ipairs(self.breeders) do
        for _, id in ipairs(breeder.trailerIds or {}) do
            table.insert(ids, id)
        end
    end
    return ids
end

-- Whether a vehicle's one of the breeders' trailers.
function TheContractorBreedersPen:isTrailer(vehicle)
    local vehicleId = vehicle ~= nil and NetworkUtil.getObjectId(vehicle) or nil
    if vehicleId == nil then
        return false
    end
    for _, id in ipairs(self:getTrailerIds()) do
        if id == vehicleId then
            return true
        end
    end
    return false
end

-- A breeder's animal by its RL key, or nil.
function TheContractorBreedersPen:findAnimalByKey(index, key)
    local breeder = self.breeders[index or 0]
    for _, animal in ipairs(breeder ~= nil and breeder.animals or {}) do
        if key ~= nil and animal.key == key then
            return animal
        end
    end
    return nil
end

-- What a breeder has for sale now, read from their trailers through RL's
-- API (on any machine): { { key, animal, trailerId, info (describeAnimal's),
-- value, price, subTypeIndex, title, record (our animal: its id, entry) } },
-- a sick one left out unless withSick. index: one breeder's, nil for all.
function TheContractorBreedersPen:getCatalogue(withSick, index)
    local entries = {}
    local api = TCRealisticLivestock.getAPI()
    if api == nil or self.farmId <= 0 then
        return entries
    end
    local animalSystem = g_currentMission.animalSystem
    for breederIndex, breeder in ipairs(self.breeders) do
        if (index == nil or index == breederIndex) and not breeder.absent then
            for _, trailerId in ipairs(breeder.trailerIds or {}) do
                local trailer = NetworkUtil.getObject(trailerId)
                local animals = trailer ~= nil and api.getAnimalsIn(trailer) or nil
                for _, animal in ipairs(animals or {}) do
                    local info = api.describeAnimal(animal)
                    local value = info ~= nil and api.getAnimalValue(animal) or nil
                    if info ~= nil and value ~= nil and (withSick or not info.diseased) then
                        local key = TCRealisticLivestock.getAPIKey(info)
                        local subTypeIndex = animalSystem ~= nil and info.subType ~= nil and
                            animalSystem:getSubTypeIndexByName(info.subType) or nil
                        table.insert(entries, {
                            key = key,
                            animal = animal,
                            trailerId = trailerId,
                            breeder = breederIndex,
                            record = self:findAnimalByKey(breederIndex, key),
                            info = info,
                            value = value,
                            price = TCBreedersPen.getPrice(value),
                            subTypeIndex = subTypeIndex,
                            title = TCShowClasses.getSubTypeTitle(animalSystem, info.subType),
                        })
                    end
                end
            end
        end
    end
    return entries
end

-- The delivery fee to a husbandry, as charged (scaled).
function TheContractorBreedersPen.getDeliveryFee()
    local amount = TCBreedersPen.DELIVERY_FEE
    local settings = getTC() ~= nil and getTC().Settings or nil
    if settings ~= nil then
        amount = settings:scaleCost(amount)
    end
    return TCEconomyScale.scale(amount)
end

-- Whether a buyer's trailer is at the show: in the trailer lines, or within
-- REACH of a breeder's pen (the breeder's at `index`, or any).
function TheContractorBreedersPen.isTrailerAtShow(trailer, scene, index)
    if trailer == nil or trailer.rootNode == nil or scene == nil then
        return false
    end
    local x, _, z = getWorldTranslation(trailer.rootNode)
    if TCShowScene.findBay(scene, x, z) ~= nil then
        return true
    end
    for _, pen in ipairs(TCShowScene.getBreederPens(scene)) do
        if pen.placed and (index == nil or pen.index == index) and
                math.sqrt((x - pen.x) ^ 2 + (z - pen.z) ^ 2) <= TCBreedersPen.REACH then
            return true
        end
    end
    return false
end

-- Whether an animal of a subtype could go to a place: it takes the
-- subtype and has a free slot.
local function hasRoom(object, subTypeIndex)
    if type(object.getSupportsAnimalSubType) ~= "function" or not object:getSupportsAnimalSubType(subTypeIndex) then
        return false
    end
    if type(object.getNumOfFreeAnimalSlots) ~= "function" then
        return false
    end
    return (object:getNumOfFreeAnimalSlots(subTypeIndex) or 0) >= 1
end

-- Where a farm could have an animal of a subtype go now: its livestock
-- trailers at the show (free), then its husbandries (the delivery fee).
-- index: the breeder it's bought from. { { object, objectId, isHusbandry,
-- fee } }.
function TheContractorBreedersPen:getTargets(farmId, subTypeIndex, index)
    local targets = {}
    if subTypeIndex == nil then
        return targets
    end
    local scene = getScene()
    local husbandrySystem = g_currentMission.husbandrySystem
    for _, trailer in ipairs(husbandrySystem ~= nil and husbandrySystem.livestockTrailers or {}) do
        if TCShowAnimals.isTrailer(trailer) and trailer:getOwnerFarmId() == farmId and not self:isTrailer(trailer) and
                TheContractorBreedersPen.isTrailerAtShow(trailer, scene, index) and hasRoom(trailer, subTypeIndex) then
            table.insert(targets, { object = trailer, objectId = NetworkUtil.getObjectId(trailer), isHusbandry = false,
                fee = 0 })
        end
    end
    local fee = TheContractorBreedersPen.getDeliveryFee()
    for _, placeable in ipairs(TCShowAnimals.getFarmHusbandries(farmId)) do
        if hasRoom(placeable, subTypeIndex) then
            table.insert(targets, { object = placeable, objectId = NetworkUtil.getObjectId(placeable),
                isHusbandry = true, fee = fee })
        end
    end
    return targets
end

-- The breeders' pens for the scene (Show:setOut, the competition's
-- getBreeders): one a breeder, in order (an absent one too, so the indices
-- hold; it isn't placed if there's no room). nil with none.
function TheContractorBreedersPen:getSceneBreeders(event)
    if event == nil or self.showId ~= event.id or #self.breeders == 0 then
        return nil
    end
    local list = {}
    for _, breeder in ipairs(self.breeders) do
        table.insert(list, { length = breeder.pen.length, depth = breeder.pen.depth,
            trailer = breeder.model ~= nil or breeder.hasTrailer == true, typeName = breeder.typeName })
    end
    return list
end

-- Planning (server) ---------------------------------------------------------------------------

-- Server: the breeders start again for a show (or none), any trailers out
-- taken away.
function TheContractorBreedersPen:reset(showId)
    self:closeTrailers()
    local changed = self.showId ~= showId or #self.breeders > 0
    self.showId = showId
    self.breeders = {}
    self.planned = false
    self.present = false
    self.farmId = 0
    if changed then
        self.version = self.version + 1
        self:sync()
    end
end

-- A plan of the showground (164's) as TCShowScene lays it out, for how many
-- breeders it has room for, or nil with no plan.
function TheContractorBreedersPen.getPlanningScene(pens)
    local tc = getTC()
    local showSite = tc ~= nil and tc.ShowSite or nil
    local plan = showSite ~= nil and showSite.site ~= nil and showSite.site.plan or nil
    if plan == nil or plan.showRect == nil then
        return nil
    end
    local layout = TCAuctionLayout.layOutOpenRect(plan.showRect, plan.entrance)
    local scene = TCAuctionLayout.getScene(layout, plan.entrance, 0)
    scene.dressing = TCShowScene.DRESSING
    scene.pens = pens
    return scene
end

-- Server (ShowLivestock, when entries close or at set-out): the breeders
-- for a show, planned once. pens: the small pens beside the ring (188: the
-- farmers' row; the room they take). Returns the breeders.
function TheContractorBreedersPen:plan(event, pens)
    if event == nil or not g_currentMission:getIsServer() then
        return self.breeders
    end
    if self.planned and self.showId == event.id then
        return self.breeders
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self.planned = true
    local tc = getTC()
    local farmers = {}
    for _, farmer in ipairs(tc.Farmers ~= nil and tc.Farmers:getFarmers() or {}) do
        if farmer.id ~= event.hostFarmerId then
            table.insert(farmers, farmer)
        end
    end
    -- RL's stock comes in trailers, on a spare farm id.
    local api = TCRealisticLivestock.getAPI()
    local spare = api ~= nil and TCBreedersPen.pickFarmId(farmExists, FarmManager.MAX_NUM_FARMS) or nil
    local models = {}
    local capacity = nil
    if spare ~= nil then
        capacity = function(typeName, count)
            local model, slots = self.engine.pickTrailerModel(typeName, count)
            models[typeName] = model
            return model ~= nil and slots or 0
        end
    end
    local breeders = TCBreedersPen.planBreeders(TCShowClasses.listClasses(g_currentMission.animalSystem), farmers,
        TCBreedersPen.MAX_BREEDERS, self.random, capacity)
    for _, breeder in ipairs(breeders) do
        breeder.trailerIds = {}
        if spare ~= nil then
            breeder.model = models[breeder.typeName]
            breeder.hasTrailer = breeder.model ~= nil
        end
    end
    -- As many as the showground's plan has room for.
    self.breeders = breeders
    local scene = TheContractorBreedersPen.getPlanningScene(pens)
    if scene ~= nil then
        scene.breeders = self:getSceneBreeders(event)
        local kept = {}
        for _, pen in ipairs(TCShowScene.getBreederPens(scene)) do
            if pen.placed then
                table.insert(kept, breeders[pen.index])
            end
        end
        self.breeders = kept
    end
    self.version = self.version + 1
    TCLog.info("TheContractor: show %d: %d breeder(s) coming (%d planned)%s", event.id, #self.breeders, #breeders,
        spare ~= nil and string.format(", their stock RL's on farm id %d", spare) or ", no stock for sale")
    self:sync()
    return self.breeders
end

-- Setting out and clearing away (server) -------------------------------------------------------

-- Server, as the show's set out: a breeder the showground hasn't room for
-- stays away; with RL, the breeders' trailers out and stocked. Returns nil,
-- or why nothing's for sale.
function TheContractorBreedersPen:open(event)
    if not g_currentMission:getIsServer() then
        return "not the server"
    end
    if self.showId ~= event.id or #self.breeders == 0 then
        return "no breeders"
    end
    -- Set out again (the console's show day): what's out stays.
    if #self:getTrailerIds() > 0 then
        return nil
    end
    local scene = getScene()
    local pens = TCShowScene.getBreederPens(scene)
    local dropped = 0
    for index, breeder in ipairs(self.breeders) do
        local pen = pens[index]
        if (pen == nil or not pen.placed) and not breeder.absent then
            breeder.absent = true
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        TCLog.info("TheContractor: show %d: %d breeder(s) stay away, no room on the showground", event.id, dropped)
        local tc = getTC()
        if tc.ShowLivestock ~= nil then
            tc.ShowLivestock:onBreedersAway(event)
        end
    end
    self.version = self.version + 1
    local problem = nil
    local api = TCRealisticLivestock.getAPI()
    local farmId = api ~= nil and TCBreedersPen.pickFarmId(farmExists, FarmManager.MAX_NUM_FARMS) or nil
    if api == nil then
        problem = "no RealisticLivestock API"
    elseif farmId == nil then
        problem = "every farm id is in use"
    end
    if problem == nil then
        self.farmId = farmId
        self.generation = self.generation + 1
        local spawned = 0
        for index, breeder in ipairs(self.breeders) do
            local pen = pens[index]
            if not breeder.absent and breeder.model ~= nil and pen ~= nil and pen.trailer ~= nil then
                self.engine.spawnTrailer(self, index, pen.trailer, self.generation)
                spawned = spawned + 1
            end
        end
        TCLog.info("TheContractor: show %d's breeders: farm id %d, %d trailer(s) on their way", event.id, farmId,
            spawned)
    else
        TCLog.info("TheContractor: show %d's breeders have nothing to sell: %s", event.id, problem)
    end
    self:sync()
    return problem
end

-- Server: a trailer's loaded (the engine's spawnTrailer, done): kept and
-- stocked, or dropped if the show's been cleared since.
function TheContractorBreedersPen:onTrailerSpawned(vehicle, index, generation)
    if vehicle == nil then
        return
    end
    local breeder = self.breeders[index]
    if generation ~= self.generation or self.farmId <= 0 or breeder == nil then
        self.engine.deleteVehicle(NetworkUtil.getObjectId(vehicle), vehicle)
        return
    end
    local added = self:stock(vehicle, breeder)
    if added == 0 then
        TCLog.warning("TheContractor: breeder %d's %s trailer got no animals: taken away", index, breeder.typeName)
        self.engine.deleteVehicle(NetworkUtil.getObjectId(vehicle), vehicle)
        return
    end
    table.insert(breeder.trailerIds, NetworkUtil.getObjectId(vehicle))
    self.version = self.version + 1
    self:sync()
end

-- Server: a breeder's trailer stocked with RL's premium animals as planned
-- (each animal's subtype and age), each given its RL key and coat. One RL
-- won't make well is missing (not in the pen; its entry a no-show).
-- Returns how many went in.
function TheContractorBreedersPen:stock(trailer, breeder)
    local api = TCRealisticLivestock.getAPI()
    if api == nil then
        return 0
    end
    local animals, records = {}, {}
    for _, record in ipairs(breeder.animals) do
        local made = nil
        for _ = 1, TCBreedersPen.TRIES do
            local animal, reason = api.createAnimal({
                subType = record.subTypeName,
                age = record.age,
                quality = TCBreedersPen.QUALITY,
            })
            local info = animal ~= nil and api.describeAnimal(animal) or nil
            if info ~= nil and not info.diseased then
                made = { animal = animal, info = info }
                break
            end
            TCLog.info("TheContractor: a breeder's %s: drawn again (%s)", record.subTypeName,
                tostring(reason or (info ~= nil and "sick" or "no description")))
        end
        if made ~= nil then
            table.insert(animals, made.animal)
            table.insert(records, { record = record, info = made.info })
        else
            record.missing = true
        end
    end
    if #animals == 0 then
        return 0
    end
    local ok, reason = api.addAnimalsTo(trailer, animals, self.farmId)
    if not ok then
        TCLog.warning("TheContractor: RealisticLivestock wouldn't put a breeder's %d %s in their trailer: %s",
            #animals, breeder.typeName, tostring(reason))
        for _, made in ipairs(records) do
            made.record.missing = true
        end
        return 0
    end
    -- Each animal's key, and its coat as the trailer has it (matched by
    -- subtype and age, each cluster once).
    local clusters = {}
    local read = TCShowAnimals.readTrailer(trailer)
    for _, cluster in ipairs(read ~= nil and read.entries or {}) do
        table.insert(clusters, cluster)
    end
    for _, made in ipairs(records) do
        made.record.key = TCRealisticLivestock.getAPIKey(made.info)
        made.record.age = made.info.age or made.record.age
        for i, cluster in ipairs(clusters) do
            if cluster.subTypeName == made.record.subTypeName and cluster.age == made.record.age then
                if cluster.animal ~= nil and cluster.animal.variation ~= nil then
                    made.record.variation = cluster.animal.variation
                end
                table.remove(clusters, i)
                break
            end
        end
    end
    TCLog.info("TheContractor: a breeder's trailer stocked with %d %s", #animals, breeder.typeName)
    return #animals
end

-- Server: the trailers and any unsold animals taken away (the breeders
-- stay, with nothing for sale).
function TheContractorBreedersPen:closeTrailers()
    self.generation = self.generation + 1
    local changed = false
    for _, breeder in ipairs(self.breeders) do
        for _, trailerId in ipairs(breeder.trailerIds or {}) do
            self.engine.deleteVehicle(trailerId, NetworkUtil.getObject(trailerId))
            changed = true
        end
        breeder.trailerIds = {}
    end
    if self.farmId > 0 then
        changed = true
    end
    self.farmId = 0
    if changed then
        TCLog.info("TheContractor: the breeders' trailers taken away")
        self.version = self.version + 1
    end
    return changed
end

-- Server (MessageType.FARM_CREATED): a new farm on the spare id has the
-- trailers taken away before it can own them.
function TheContractorBreedersPen:onFarmCreated(farmId)
    if self.farmId > 0 and farmId == self.farmId then
        TCLog.info("TheContractor: farm %d created, the breeders' farm id: their trailers are taken away", farmId)
        self:closeTrailers()
        for _, breeder in ipairs(self.breeders) do
            for _, animal in ipairs(breeder.animals) do
                if animal.key ~= nil and not animal.sold then
                    animal.missing = true
                end
            end
        end
        self:sync()
    end
end

-- Server (ShowLivestock, every second): whether the breeders' animals are
-- in their pens (the gates open).
function TheContractorBreedersPen:setPresent(present)
    present = present == true
    if self.present ~= present then
        self.present = present
        self.version = self.version + 1
        self:sync()
    end
end

-- Buying (server) -------------------------------------------------------------------------------

local function findEntry(catalogue, key)
    for _, entry in ipairs(catalogue) do
        if entry.key == key then
            return entry
        end
    end
    return nil
end

-- Server: a farm buys an animal (by its key) for a place (a vehicle's or a
-- placeable's object id). connection: the player's, for their permission
-- (nil on the server's own machine). Returns an ANSWER and what was paid.
function TheContractorBreedersPen:handleBuy(farmId, key, targetId, connection)
    if not g_currentMission:getIsServer() or not self:isOpen() then
        return ANSWER.CLOSED, 0
    end
    local api = TCRealisticLivestock.getAPI()
    if api == nil then
        return ANSWER.CLOSED, 0
    end
    if not g_currentMission:getHasPlayerPermission("tradeAnimals", connection) then
        return ANSWER.NO_PERMISSION, 0
    end
    local entry = findEntry(self:getCatalogue(true), key)
    if entry == nil then
        return ANSWER.SOLD, 0
    end
    if entry.info.diseased then
        return ANSWER.SICK, 0
    end
    -- 188: an entry stays till its class is over.
    local livestock = getTC().ShowLivestock
    if entry.record ~= nil and livestock ~= nil and livestock:getHeldUntil(entry.breeder, entry.record.id) ~= nil then
        return ANSWER.ENTERED, 0
    end
    local target = NetworkUtil.getObject(targetId)
    local found = nil
    for _, candidate in ipairs(self:getTargets(farmId, entry.subTypeIndex, entry.breeder)) do
        if candidate.object == target then
            found = candidate
        end
    end
    if found == nil then
        return ANSWER.NO_ROOM, 0
    end
    local total = entry.price + found.fee
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm:getBalance() < total then
        return ANSWER.CANT_AFFORD, 0
    end
    local trailer = NetworkUtil.getObject(entry.trailerId)
    local ok, reason = api.moveAnimals(trailer, target, { entry.animal }, farmId)
    if not ok then
        TCLog.info("TheContractor: farm %d couldn't have a breeder's %s: %s", farmId, entry.key, tostring(reason))
        return TCBreedersPen.getAnswerForReason(api.REASON, reason), 0
    end
    g_currentMission:addMoney(-total, farmId, MoneyType.TC_BREEDER_STOCK, true, true)
    if entry.record ~= nil then
        entry.record.sold = true
        self.version = self.version + 1
        self:sync()
    end
    TCLog.info("TheContractor: farm %d bought breeder %d's %s (%s) for %d%s", farmId, entry.breeder, entry.key,
        tostring(entry.info.subType), entry.price, found.fee > 0 and string.format(", delivered for %d", found.fee) or "")
    return ANSWER.BOUGHT, total
end

-- Farmers and vehicles -------------------------------------------------------------------------------

-- Every machine (128, through the show): a retired breeder's successor
-- brings their stock. Returns how many.
function TheContractorBreedersPen:replacePerson(oldId, newId)
    local count = 0
    for _, breeder in ipairs(self.breeders) do
        if breeder.farmerId == oldId then
            breeder.farmerId = newId
            count = count + 1
        end
    end
    if count > 0 then
        self.version = self.version + 1
    end
    return count
end

-- Every machine (TCVehicleReplace): a trailer swapped for a copy.
function TheContractorBreedersPen:remapVehicle(oldId, newId)
    for _, breeder in ipairs(self.breeders) do
        for i, id in ipairs(breeder.trailerIds or {}) do
            if id == oldId then
                breeder.trailerIds[i] = newId
            end
        end
    end
end

-- Sync ---------------------------------------------------------------------------------------------

function TheContractorBreedersPen:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCBreedersPenEvent.new(self))
    end
end

function TheContractorBreedersPen.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    streamWriteUInt8(streamId, state.farmId or 0)
    streamWriteBool(streamId, state.present == true)
    streamWriteUInt8(streamId, #state.breeders)
    for _, breeder in ipairs(state.breeders) do
        streamWriteInt32(streamId, breeder.farmerId or 0)
        streamWriteString(streamId, breeder.typeName or "")
        streamWriteUInt8(streamId, breeder.pen.length or 2)
        streamWriteUInt8(streamId, breeder.pen.depth or 2)
        streamWriteBool(streamId, breeder.absent == true)
        streamWriteBool(streamId, breeder.hasTrailer == true or breeder.model ~= nil)
        streamWriteUInt8(streamId, #(breeder.trailerIds or {}))
        for _, id in ipairs(breeder.trailerIds or {}) do
            streamWriteInt32(streamId, id)
        end
        streamWriteUInt8(streamId, #breeder.animals)
        for _, animal in ipairs(breeder.animals) do
            streamWriteUInt8(streamId, animal.id)
            streamWriteString(streamId, animal.classKey or "")
            streamWriteString(streamId, animal.subTypeName or "")
            streamWriteInt16(streamId, animal.age or 0)
            streamWriteUInt8(streamId, animal.variation or 1)
            streamWriteString(streamId, animal.key or "")
            streamWriteBool(streamId, animal.sold == true)
            streamWriteBool(streamId, animal.missing == true)
        end
    end
end

local function readOptionalString(streamId)
    local value = streamReadString(streamId)
    return value ~= "" and value or nil
end

function TheContractorBreedersPen.readState(streamId)
    local state = { breeders = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    state.farmId = streamReadUInt8(streamId)
    state.present = streamReadBool(streamId)
    for _ = 1, streamReadUInt8(streamId) do
        local breeder = { farmerId = streamReadInt32(streamId), typeName = readOptionalString(streamId), pen = {},
            trailerIds = {}, animals = {} }
        breeder.pen.length = streamReadUInt8(streamId)
        breeder.pen.depth = streamReadUInt8(streamId)
        breeder.absent = streamReadBool(streamId) or nil
        breeder.hasTrailer = streamReadBool(streamId)
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(breeder.trailerIds, streamReadInt32(streamId))
        end
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(breeder.animals, {
                id = streamReadUInt8(streamId),
                classKey = readOptionalString(streamId),
                subTypeName = readOptionalString(streamId),
                age = streamReadInt16(streamId),
                variation = streamReadUInt8(streamId),
                key = readOptionalString(streamId),
                sold = streamReadBool(streamId) or nil,
                missing = streamReadBool(streamId) or nil,
            })
        end
        table.insert(state.breeders, breeder)
    end
    return state
end

-- A client: the breeders as the server sent them.
function TheContractorBreedersPen:applyState(state)
    self.showId = state.showId
    self.farmId = state.farmId
    self.present = state.present
    self.breeders = state.breeders
    self.version = self.version + 1
end

function TheContractorBreedersPen:writeInitialClientState(streamId, connection)
    TheContractorBreedersPen.writeState(streamId, self)
end

function TheContractorBreedersPen:readInitialClientState(streamId, connection)
    self:applyState(TheContractorBreedersPen.readState(streamId))
end

-- Persistence (server) -------------------------------------------------------------------------------

function TheContractorBreedersPen:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() or self.showId == nil then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorBreedersPen.SAVE_KEY
    setXMLInt(xmlFile, key .. "#showId", self.showId)
    setXMLInt(xmlFile, key .. "#farmId", self.farmId)
    setXMLBool(xmlFile, key .. "#planned", self.planned)
    for i, breeder in ipairs(self.breeders) do
        local breederKey = string.format("%s.breeder(%d)", key, i - 1)
        setXMLInt(xmlFile, breederKey .. "#farmerId", breeder.farmerId or 0)
        setXMLString(xmlFile, breederKey .. "#type", breeder.typeName or "")
        setXMLInt(xmlFile, breederKey .. "#penLength", breeder.pen.length)
        setXMLInt(xmlFile, breederKey .. "#penDepth", breeder.pen.depth)
        setXMLBool(xmlFile, breederKey .. "#absent", breeder.absent == true)
        if breeder.model ~= nil then
            setXMLString(xmlFile, breederKey .. "#trailerModel", breeder.model.xmlFilename)
        end
        local t = 0
        for _, trailerId in ipairs(breeder.trailerIds or {}) do
            local uniqueId = TCVehicleIds.getUniqueId(trailerId)
            if uniqueId ~= nil then
                setXMLString(xmlFile, string.format("%s.trailer(%d)#uniqueId", breederKey, t), uniqueId)
                t = t + 1
            end
        end
        for j, animal in ipairs(breeder.animals) do
            local animalKey = string.format("%s.animal(%d)", breederKey, j - 1)
            setXMLInt(xmlFile, animalKey .. "#id", animal.id)
            setXMLString(xmlFile, animalKey .. "#classKey", animal.classKey or "")
            setXMLString(xmlFile, animalKey .. "#subType", animal.subTypeName or "")
            setXMLInt(xmlFile, animalKey .. "#age", animal.age or 0)
            setXMLInt(xmlFile, animalKey .. "#variation", animal.variation or 1)
            if animal.key ~= nil then
                setXMLString(xmlFile, animalKey .. "#key", animal.key)
            end
            setXMLBool(xmlFile, animalKey .. "#sold", animal.sold == true)
            setXMLBool(xmlFile, animalKey .. "#missing", animal.missing == true)
        end
    end
end

local function readString(xmlFile, path)
    local value = getXMLString(xmlFile, path)
    return value ~= nil and value ~= "" and value or nil
end

function TheContractorBreedersPen:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorBreedersPen.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.farmId = getXMLInt(xmlFile, key .. "#farmId") or 0
    self.planned = getXMLBool(xmlFile, key .. "#planned") == true
    self.breeders = {}
    -- 173's save had the trailers under the pen, not a breeder: those are
    -- only taken away now (resolveSavedVehicles).
    self.legacyUniqueIds = {}
    local l = 0
    while true do
        local uniqueId = getXMLString(xmlFile, string.format("%s.trailer(%d)#uniqueId", key, l))
        if uniqueId == nil then
            break
        end
        table.insert(self.legacyUniqueIds, uniqueId)
        l = l + 1
    end
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.breeder(%d)", key, i)) do
        local breederKey = string.format("%s.breeder(%d)", key, i)
        local breeder = {
            farmerId = getXMLInt(xmlFile, breederKey .. "#farmerId") or 0,
            typeName = readString(xmlFile, breederKey .. "#type"),
            pen = { length = getXMLInt(xmlFile, breederKey .. "#penLength") or 2,
                depth = getXMLInt(xmlFile, breederKey .. "#penDepth") or 2 },
            absent = getXMLBool(xmlFile, breederKey .. "#absent") == true or nil,
            trailerIds = {},
            savedUniqueIds = {},
            animals = {},
        }
        local model = readString(xmlFile, breederKey .. "#trailerModel")
        if model ~= nil then
            breeder.model = { xmlFilename = model }
            breeder.hasTrailer = true
        end
        local t = 0
        while true do
            local uniqueId = getXMLString(xmlFile, string.format("%s.trailer(%d)#uniqueId", breederKey, t))
            if uniqueId == nil then
                break
            end
            table.insert(breeder.savedUniqueIds, uniqueId)
            t = t + 1
        end
        local j = 0
        while hasXMLProperty(xmlFile, string.format("%s.animal(%d)", breederKey, j)) do
            local animalKey = string.format("%s.animal(%d)", breederKey, j)
            table.insert(breeder.animals, {
                id = getXMLInt(xmlFile, animalKey .. "#id") or (j + 1),
                classKey = readString(xmlFile, animalKey .. "#classKey"),
                subTypeName = readString(xmlFile, animalKey .. "#subType"),
                age = getXMLInt(xmlFile, animalKey .. "#age") or 0,
                variation = getXMLInt(xmlFile, animalKey .. "#variation") or 1,
                key = readString(xmlFile, animalKey .. "#key"),
                sold = getXMLBool(xmlFile, animalKey .. "#sold") == true or nil,
                missing = getXMLBool(xmlFile, animalKey .. "#missing") == true or nil,
            })
            j = j + 1
        end
        table.insert(self.breeders, breeder)
        i = i + 1
    end
end

-- Server: a breeder's trailer the save lost track of (one left by an older
-- version, or a save made as one spawned) taken away: a livestock trailer
-- on loan to the show (MISSION) whose farm id is nobody's, and not one of
-- the breeders' now. Only ours are like that: a real farm owns any other.
function TheContractorBreedersPen:removeStrays()
    local vehicleSystem = g_currentMission.vehicleSystem
    if vehicleSystem == nil or vehicleSystem.vehicles == nil or VehiclePropertyState == nil then
        return 0
    end
    local ours = {}
    for _, trailerId in ipairs(self:getTrailerIds()) do
        ours[trailerId] = true
    end
    local strays = {}
    for _, vehicle in ipairs(vehicleSystem.vehicles) do
        local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or 0
        if vehicle.spec_livestockTrailer ~= nil and vehicle.propertyState == VehiclePropertyState.MISSION and
            farmId > 0 and not farmExists(farmId) and not ours[NetworkUtil.getObjectId(vehicle)] then
            table.insert(strays, vehicle)
        end
    end
    for _, vehicle in ipairs(strays) do
        TCLog.info("TheContractor: a stray breeder's trailer (farm id %d) taken away", vehicle:getOwnerFarmId())
        self.engine.deleteVehicle(NetworkUtil.getObjectId(vehicle), vehicle)
    end
    return #strays
end

-- Server, once vehicles exist: the trailers' object ids from their
-- uniqueIds. Kept only for the show that's still on, its day not past, and
-- while their farm id's still nobody's; otherwise taken away (and the
-- breeders too once the show's day is past).
function TheContractorBreedersPen:resolveSavedVehicles()
    for _, uniqueId in ipairs(self.legacyUniqueIds or {}) do
        local vehicleId = TCVehicleIds.getObjectId(uniqueId)
        if vehicleId ~= nil then
            TCLog.info("TheContractor: a breeder's trailer from an older save taken away")
            self.engine.deleteVehicle(vehicleId, NetworkUtil.getObject(vehicleId))
        end
    end
    self.legacyUniqueIds = nil
    local any = false
    for _, breeder in ipairs(self.breeders) do
        for _, uniqueId in ipairs(breeder.savedUniqueIds or {}) do
            local vehicleId = TCVehicleIds.getObjectId(uniqueId)
            if vehicleId ~= nil then
                table.insert(breeder.trailerIds, vehicleId)
                any = true
            end
        end
        breeder.savedUniqueIds = nil
    end
    self:removeStrays()
    local event = getShowEvent()
    local today = g_currentMission.environment.currentMonotonicDay
    local showOn = event ~= nil and event.id == self.showId and today <= event.day
    if not showOn then
        if self.showId ~= nil then
            TCLog.info("TheContractor: the breeders from the save are for a show that's over: gone")
        end
        self:reset(nil)
        return
    end
    if any and (self.farmId <= 0 or farmExists(self.farmId)) then
        TCLog.info("TheContractor: the breeders' trailers from the save can't stay (their farm id's taken)")
        self:closeTrailers()
    elseif any then
        TCLog.info("TheContractor: the breeders' %d trailer(s) back from the save", #self:getTrailerIds())
    end
    self.version = self.version + 1
    self:sync()
end

-- The world (server) ----------------------------------------------------------------------------------

-- Each store livestock trailer: { xmlFilename, slots = { TYPE -> count },
-- isBaseGame }, read once a load.
function ENGINE.getTrailerModels()
    if ENGINE.models ~= nil then
        return ENGINE.models
    end
    local models = {}
    for _, storeItem in ipairs(g_storeManager ~= nil and g_storeManager:getItems() or {}) do
        local usable = storeItem.bundleInfo == nil and storeItem.showInStore ~= false and storeItem.xmlFilename ~= nil and
            (StoreSpecies == nil or storeItem.species == nil or storeItem.species == StoreSpecies.VEHICLE)
        if usable and g_vehicleTypeManager ~= nil then
            local vehicleType = g_vehicleTypeManager:getObjectTypeFromXML(storeItem.xmlFilename)
            local specs = vehicleType ~= nil and vehicleType.specializationsByName or nil
            usable = specs ~= nil and specs.livestockTrailer ~= nil
        end
        local xmlFile = usable and loadXMLFile("tcLivestockTrailer", storeItem.xmlFilename) or nil
        if xmlFile ~= nil and xmlFile ~= 0 then
            local slots, any = {}, false
            local i = 0
            while true do
                local key = string.format("vehicle.livestockTrailer.animal(%d)", i)
                local typeName = getXMLString(xmlFile, key .. "#type")
                if typeName == nil then
                    break
                end
                slots[string.upper(typeName)] = math.abs(getXMLInt(xmlFile, key .. "#numSlots") or 0)
                any = true
                i = i + 1
            end
            delete(xmlFile)
            if any then
                table.insert(models, { xmlFilename = storeItem.xmlFilename, slots = slots,
                    isBaseGame = storeItem.customEnvironment == nil, name = storeItem.name })
            end
        end
    end
    ENGINE.models = models
    return models
end

function ENGINE.pickTrailerModel(typeName, count)
    return TCBreedersPen.pickTrailerModel(ENGINE.getTrailerModels(), typeName, count)
end

-- A breeder's trailer out behind their pen (spot: TCShowScene.
-- getBreederPens' trailer), owned by the spare farm id, MISSION state.
function ENGINE.spawnTrailer(pen, index, spot, generation)
    local breeder = pen.breeders[index]
    local storeItem = breeder ~= nil and breeder.model ~= nil and
        g_storeManager:getItemByXMLFilename(breeder.model.xmlFilename) or nil
    if storeItem == nil or VehicleLoadingData == nil then
        return
    end
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    loadingData:setPosition(spot.x, nil, spot.z, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, spot.yaw, 0)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(pen.farmId)
    loadingData:load(function(_, vehicles, loadingState)
        local vehicle = vehicles ~= nil and vehicles[1] or nil
        if vehicle == nil or loadingState ~= VehicleLoadingState.OK then
            TCLog.warning("TheContractor: breeder %d's %s trailer didn't load", index, tostring(breeder.typeName))
            for _, loaded in ipairs(vehicles or {}) do
                if not loaded.isDeleted then
                    loaded:delete()
                end
            end
            return
        end
        pen:onTrailerSpawned(vehicle, index, generation)
    end, nil, nil)
end

function ENGINE.deleteVehicle(vehicleId, vehicle)
    vehicle = vehicle or NetworkUtil.getObject(vehicleId)
    if vehicle ~= nil and not vehicle.isDeleted then
        vehicle:delete()
    end
end

-- Console ------------------------------------------------------------------------------------------------

local function formatGenetics(genetics)
    local parts = {}
    for _, trait in ipairs(TCBreedersPen.GENETICS) do
        if genetics ~= nil and genetics[trait] ~= nil then
            table.insert(parts, string.format("%s %.2f", trait, genetics[trait]))
        end
    end
    return table.concat(parts, ", ")
end

-- tcShow breeder [n]: the breeders, or one, with their animals (and, with
-- RL, what's for sale at what price).
function TheContractorBreedersPen:describe(only)
    local breeders = self:getBreeders()
    if #breeders == 0 then
        return "No breeders are coming yet: they're planned when the show's entries close."
    end
    local livestock = getTC().ShowLivestock
    local lines = { string.format("Show %d's breeders (%s now)%s:", self.showId, self:isOpen() and "at their pens" or
        "not at their pens", self:hasSales() and string.format(", their stock RL's on farm id %d", self.farmId) or
        ", nothing for sale") }
    local catalogue = self:getCatalogue(true)
    for _, item in ipairs(breeders) do
        if only == nil or only == item.index then
            local person = self:getPerson(item.index)
            local breeder = item.breeder
            table.insert(lines, string.format("  %d: %s, %s, %d trailer(s):", item.index,
                person ~= nil and person.name or string.format("farmer %d", breeder.farmerId),
                breeder.typeName or "-", #(breeder.trailerIds or {})))
            for _, animal in ipairs(breeder.animals) do
                local held = livestock ~= nil and livestock:getHeldUntil(item.index, animal.id) or nil
                local state = animal.sold and "sold" or (animal.missing and "missing" or "here")
                local entered = livestock ~= nil and livestock:getBreederEntryClass(item.index, animal.id) or nil
                local sale = ""
                for _, entry in ipairs(catalogue) do
                    if entry.breeder == item.index and entry.key == animal.key then
                        sale = string.format("; %s, %.0f kg, health %.0f, %s; value %.0f, price %d%s",
                            entry.key, entry.info.weight or 0, entry.info.health or 0, formatGenetics(entry.info.genetics),
                            entry.value, entry.price, entry.info.diseased and " (sick: not for sale)" or "")
                    end
                end
                table.insert(lines, string.format("    animal %d: %s, %d months, %s%s%s%s", animal.id,
                    animal.subTypeName or "-", animal.age or 0, state,
                    entered ~= nil and string.format(", entered in %s", entered) or "",
                    held ~= nil and string.format(" (held till %s)", TCShowRing.formatMinute(held)) or "", sale))
            end
        end
    end
    return table.concat(lines, "\n")
end

function TheContractorBreedersPen.registerConsoleCommands()
    TCConsole.register("show", "breeder", {
        args = "[breeder]",
        description = "The show's breeders, or one by number: their animals, which are entered, and (with RealisticLivestock) what's for sale and its price",
        hints = { breeder = "a breeder's number (tcShow breeder lists them)" },
        serverOnly = false,
        run = function(_, args)
            local only = args[1] ~= nil and tonumber(args[1]) or nil
            if (args[1] ~= nil and only == nil) or args[2] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.BreedersPen:describe(only ~= nil and math.floor(only) or nil)
        end,
    })
end
