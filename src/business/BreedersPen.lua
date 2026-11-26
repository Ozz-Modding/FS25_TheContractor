-- The breeders' pen at the show (173): a breeder (a farmer) at a stand
-- selling premium stock from their livestock trailers, with
-- RealisticLivestock only. The rules and numbers are TCBreedersPen's
-- (src/util/TCBreedersPen.lua); the stand and the talking are
-- TCBreedersPenWorld's (and TCShowStandsWorld's, which puts the breeder at
-- the stand). Everything RL goes through RL's own API for other mods
-- (TCRealisticLivestock.getAPI): nothing of RL's is patched or read past it.
--
--   Set out (the show's onSetOut, midnight before): with RL's API, a spare
--     farm id (TCBreedersPen.pickFarmId) and a stand and bays on the
--     showground (TCShowScene.getBreederStand/getBreederBays), a trailer of
--     the breeder's for each of up to TYPES animal types, MISSION state and
--     owned by the spare farm id (no costs, never sold, and no farm can get
--     at it: vanilla's AccessHandler refuses every farm a vehicle of a farm
--     that doesn't exist), each stocked with RL's premium animals
--     (createAnimal, then addAnimalsTo the trailer as the spare farm id).
--     RL keeps nothing ticking in a trailer, saves its animals with it, and
--     streams them to every machine, so the catalogue is the trailers'
--     contents (getAnimalsIn): nothing of ours holds or sends an animal.
--   The day: while the show's stands are open (ShowStands:isOpen), a player
--     at the stand picks an animal and where it goes (handleBuy): one of
--     their livestock trailers at the show, or a husbandry of theirs for a
--     delivery fee. The server checks it all again, moves it with RL's
--     moveAnimals, and only then charges the farm (MoneyType
--     TC_BREEDER_STOCK).
--   Over (onFinished, midnight after; or called off): the trailers and any
--     unsold animals deleted. A farm created on the spare id while they're
--     out (MessageType.FARM_CREATED) closes the pen at once, so the new
--     farm never owns them.
--
-- A competition of the show's that places nobody (registerCompetition), for
-- its hooks. Every machine holds the show it's for, the spare farm id, the
-- breeder and the trailers (object ids); saved in TheContractor.xml
-- (.breedersPen, the trailers by uniqueId), in the initial client state and
-- sent whole (TCBreedersPenEvent). The breeder's a farmer (replacePerson,
-- through the show). Nothing's kept by farm, and nothing's a date. The
-- trailers are locked (TCVehicleLock) and remapped if replaced
-- (TCVehicleReplace). Tested in tests/test_breedersPen.lua.

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
    self.showId = nil
    -- The spare farm id the trailers belong to (0: none out).
    self.farmId = 0
    -- The breeder (a farmer's person id, 0 for none).
    self.breederId = 0
    -- The trailers' object ids.
    self.trailerIds = {}
    -- Server: the trailers' uniqueIds from the save, until resolveSavedVehicles.
    self.savedUniqueIds = nil
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
        onSetOut = function(event)
            self:open(event)
        end,
        onFinished = function()
            self:close()
        end,
        onCancelled = function()
            self:close()
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

-- Whether the pen's trailers are out for the show announced now.
function TheContractorBreedersPen:isOut()
    local event = getShowEvent()
    return #self.trailerIds > 0 and self.farmId > 0 and event ~= nil and self.showId == event.id
end

-- Whether it's selling now: out, and the show's stands open.
function TheContractorBreedersPen:isOpen()
    local tc = getTC()
    return self:isOut() and tc.ShowStands ~= nil and tc.ShowStands:isOpen()
end

function TheContractorBreedersPen:getTrailerIds()
    return self.trailerIds
end

-- Whether a vehicle's one of the breeder's trailers.
function TheContractorBreedersPen:isTrailer(vehicle)
    local vehicleId = vehicle ~= nil and NetworkUtil.getObjectId(vehicle) or nil
    if vehicleId == nil then
        return false
    end
    for _, id in ipairs(self.trailerIds) do
        if id == vehicleId then
            return true
        end
    end
    return false
end

-- The breeder, a farmer's person, or nil.
function TheContractorBreedersPen:getBreeder()
    local tc = getTC()
    if self.breederId <= 0 or tc == nil or tc.Farmers == nil then
        return nil
    end
    return tc.Farmers:getPerson(self.breederId)
end

-- The breeder's id while the pen's open (TCYardFarmers keeps them out of
-- their yard), or nil.
function TheContractorBreedersPen:getBreederAtShow()
    if self.breederId > 0 and self:isOpen() then
        return self.breederId
    end
    return nil
end

-- What's for sale now, read from the trailers through RL's API (on any
-- machine): { { key, trailerId, info (describeAnimal's), value, price,
-- subTypeIndex, title } }, a sick one left out unless withSick.
function TheContractorBreedersPen:getCatalogue(withSick)
    local entries = {}
    local api = TCRealisticLivestock.getAPI()
    if api == nil then
        return entries
    end
    local animalSystem = g_currentMission.animalSystem
    for _, trailerId in ipairs(self.trailerIds) do
        local trailer = NetworkUtil.getObject(trailerId)
        local animals = trailer ~= nil and api.getAnimalsIn(trailer) or nil
        for _, animal in ipairs(animals or {}) do
            local info = api.describeAnimal(animal)
            local value = info ~= nil and api.getAnimalValue(animal) or nil
            if info ~= nil and value ~= nil and (withSick or not info.diseased) then
                local subTypeIndex = animalSystem ~= nil and info.subType ~= nil and
                    animalSystem:getSubTypeIndexByName(info.subType) or nil
                table.insert(entries, {
                    key = TCRealisticLivestock.getAPIKey(info),
                    animal = animal,
                    trailerId = trailerId,
                    info = info,
                    value = value,
                    price = TCBreedersPen.getPrice(value),
                    subTypeIndex = subTypeIndex,
                    title = TCShowClasses.getSubTypeTitle(animalSystem, info.subType),
                })
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
-- REACH of the breeder's stand.
function TheContractorBreedersPen.isTrailerAtShow(trailer, scene)
    if trailer == nil or trailer.rootNode == nil or scene == nil then
        return false
    end
    local x, _, z = getWorldTranslation(trailer.rootNode)
    if TCShowScene.findBay(scene, x, z) ~= nil then
        return true
    end
    local stand = TCShowScene.getBreederStand(scene)
    return stand ~= nil and math.sqrt((x - stand.x) ^ 2 + (z - stand.z) ^ 2) <= TCBreedersPen.REACH
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
-- { { object, objectId, isHusbandry, fee } }.
function TheContractorBreedersPen:getTargets(farmId, subTypeIndex)
    local targets = {}
    if subTypeIndex == nil then
        return targets
    end
    local scene = getScene()
    local husbandrySystem = g_currentMission.husbandrySystem
    for _, trailer in ipairs(husbandrySystem ~= nil and husbandrySystem.livestockTrailers or {}) do
        if TCShowAnimals.isTrailer(trailer) and trailer:getOwnerFarmId() == farmId and not self:isTrailer(trailer) and
                TheContractorBreedersPen.isTrailerAtShow(trailer, scene) and hasRoom(trailer, subTypeIndex) then
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

-- Setting out and clearing away (server) -------------------------------------------------------

-- The stock to put out: { { typeName, classes, model, count } }, one a
-- trailer, for the types the store has a trailer for.
function TheContractorBreedersPen:planStock()
    local plan = {}
    local classes = TCShowClasses.listClasses(g_currentMission.animalSystem)
    local types = TCBreedersPen.pickTypes(classes, #classes, function(n)
        return self.random(n)
    end)
    for _, entry in ipairs(types) do
        if #plan >= TCBreedersPen.TYPES then
            break
        end
        local model, slots = self.engine.pickTrailerModel(entry.typeName, TCBreedersPen.PER_TRAILER)
        if model ~= nil then
            table.insert(plan, { typeName = entry.typeName, classes = entry.classes, model = model,
                count = math.min(TCBreedersPen.PER_TRAILER, slots) })
        end
    end
    return plan
end

-- Server, as the show's set out: the breeder's trailers out and stocked.
-- Returns nil, or why there's no pen.
function TheContractorBreedersPen:open(event)
    if not g_currentMission:getIsServer() then
        return "not the server"
    end
    -- Set out again (the console's show day): what's out stays.
    if self.showId == event.id and self.farmId > 0 then
        return nil
    end
    self:close()
    local problem = nil
    local api = TCRealisticLivestock.getAPI()
    local farmId = TCBreedersPen.pickFarmId(farmExists, FarmManager.MAX_NUM_FARMS)
    local scene = getScene()
    local stand = TCShowScene.getBreederStand(scene)
    local plan = (api ~= nil and farmId ~= nil and stand ~= nil) and self:planStock() or {}
    local bays = TCShowScene.getBreederBays(scene, #plan)
    if api == nil then
        problem = "no RealisticLivestock API"
    elseif farmId == nil then
        problem = "every farm id is in use"
    elseif stand == nil then
        problem = "no stand left on the showground"
    elseif #plan == 0 then
        problem = "no animal type the store has a livestock trailer for"
    elseif #bays == 0 then
        problem = "no trailer line bay to spare"
    end
    if problem ~= nil then
        TCLog.info("TheContractor: no breeders' pen at show %d: %s", event.id, problem)
        return problem
    end
    self.showId = event.id
    self.farmId = farmId
    self.breederId = self:pickBreeder(event) or 0
    self.generation = self.generation + 1
    for i, bay in ipairs(bays) do
        self.engine.spawnTrailer(self, plan[i], bay, self.generation)
    end
    TCLog.info("TheContractor: show %d's breeders' pen: farm id %d, breeder %d, %d trailer(s) on their way", event.id,
        farmId, self.breederId, #bays)
    self:sync()
    return nil
end

-- The breeder: a farmer at the show who isn't the host, at a plot (169),
-- or walking the showground (171).
function TheContractorBreedersPen:pickBreeder(event)
    local tc = getTC()
    if tc.Farmers == nil then
        return nil
    end
    local excluded = { [event.hostFarmerId or 0] = true }
    if tc.ShowStands ~= nil then
        for _, id in ipairs(tc.ShowStands:getFarmersAtShow()) do
            excluded[id] = true
        end
    end
    local match = tc.PloughingMatch
    for _, plot in ipairs(match ~= nil and match.plots or {}) do
        if (plot.farmerId or 0) > 0 then
            excluded[plot.farmerId] = true
        end
    end
    return TCBreedersPen.pickBreeder(event.id, tc.Farmers:getFarmers(), excluded)
end

-- Server: a trailer's loaded (the engine's spawnTrailer, done): kept and
-- stocked, or dropped if the pen's been closed since.
function TheContractorBreedersPen:onTrailerSpawned(vehicle, entry, generation)
    if vehicle == nil then
        return
    end
    if generation ~= self.generation or self.farmId <= 0 then
        self.engine.deleteVehicle(NetworkUtil.getObjectId(vehicle), vehicle)
        return
    end
    local added = self:stock(vehicle, entry)
    if added == 0 then
        TCLog.warning("TheContractor: the breeder's %s trailer got no animals: taken away", entry.typeName)
        self.engine.deleteVehicle(NetworkUtil.getObjectId(vehicle), vehicle)
        return
    end
    table.insert(self.trailerIds, NetworkUtil.getObjectId(vehicle))
    self:sync()
end

-- Server: a trailer stocked with RL's premium animals of its type. Returns
-- how many went in.
function TheContractorBreedersPen:stock(trailer, entry)
    local api = TCRealisticLivestock.getAPI()
    if api == nil or #entry.classes == 0 then
        return 0
    end
    local animals = {}
    local random = self.random
    for _ = 1, entry.count do
        for _ = 1, TCBreedersPen.TRIES do
            local class = entry.classes[random(#entry.classes)]
            local animal, reason = api.createAnimal({
                subType = class.subTypeName,
                age = TCBreedersPen.rollAge(class.band, random),
                quality = TCBreedersPen.QUALITY,
            })
            local info = animal ~= nil and api.describeAnimal(animal) or nil
            if info ~= nil and not info.diseased then
                table.insert(animals, animal)
                break
            end
            TCLog.info("TheContractor: the breeder's %s: drawn again (%s)", class.subTypeName,
                tostring(reason or (info ~= nil and "sick" or "no description")))
        end
    end
    if #animals == 0 then
        return 0
    end
    local ok, reason = api.addAnimalsTo(trailer, animals, self.farmId)
    if not ok then
        TCLog.warning("TheContractor: RealisticLivestock wouldn't put the breeder's %d %s in their trailer: %s",
            #animals, entry.typeName, tostring(reason))
        return 0
    end
    TCLog.info("TheContractor: the breeder's trailer stocked with %d %s", #animals, entry.typeName)
    return #animals
end

-- Server: the trailers and any unsold animals taken away.
function TheContractorBreedersPen:close()
    self.generation = self.generation + 1
    local changed = #self.trailerIds > 0 or self.farmId > 0
    for _, trailerId in ipairs(self.trailerIds) do
        self.engine.deleteVehicle(trailerId, NetworkUtil.getObject(trailerId))
    end
    self.trailerIds = {}
    self.farmId = 0
    self.breederId = 0
    self.showId = nil
    if changed then
        TCLog.info("TheContractor: the breeders' pen taken away")
        self:sync()
    end
end

-- Server (MessageType.FARM_CREATED): a new farm on the spare id closes the
-- pen before it can own the trailers.
function TheContractorBreedersPen:onFarmCreated(farmId)
    if self.farmId > 0 and farmId == self.farmId then
        TCLog.info("TheContractor: farm %d created, the breeders' pen's farm id: the pen's closed", farmId)
        self:close()
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
    local target = NetworkUtil.getObject(targetId)
    local found = nil
    for _, candidate in ipairs(self:getTargets(farmId, entry.subTypeIndex)) do
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
        TCLog.info("TheContractor: farm %d couldn't have the breeder's %s: %s", farmId, entry.key, tostring(reason))
        return TCBreedersPen.getAnswerForReason(api.REASON, reason), 0
    end
    g_currentMission:addMoney(-total, farmId, MoneyType.TC_BREEDER_STOCK, true, true)
    TCLog.info("TheContractor: farm %d bought the breeder's %s (%s) for %d%s", farmId, entry.key,
        tostring(entry.info.subType), entry.price, found.fee > 0 and string.format(", delivered for %d", found.fee) or "")
    return ANSWER.BOUGHT, total
end

-- Farmers and vehicles -------------------------------------------------------------------------------

-- Every machine (128, through the show): a retired breeder's successor
-- takes the stand. Returns how many.
function TheContractorBreedersPen:replacePerson(oldId, newId)
    if self.breederId > 0 and self.breederId == oldId then
        self.breederId = newId
        return 1
    end
    return 0
end

-- Every machine (TCVehicleReplace): a trailer swapped for a copy.
function TheContractorBreedersPen:remapVehicle(oldId, newId)
    for i, id in ipairs(self.trailerIds) do
        if id == oldId then
            self.trailerIds[i] = newId
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
    streamWriteInt32(streamId, state.breederId or 0)
    streamWriteUInt8(streamId, #state.trailerIds)
    for _, id in ipairs(state.trailerIds) do
        streamWriteInt32(streamId, id)
    end
end

function TheContractorBreedersPen.readState(streamId)
    local state = { trailerIds = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    state.farmId = streamReadUInt8(streamId)
    state.breederId = streamReadInt32(streamId)
    for _ = 1, streamReadUInt8(streamId) do
        table.insert(state.trailerIds, streamReadInt32(streamId))
    end
    return state
end

-- A client: the pen as the server sent it.
function TheContractorBreedersPen:applyState(state)
    self.showId = state.showId
    self.farmId = state.farmId
    self.breederId = state.breederId
    self.trailerIds = state.trailerIds
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
    setXMLInt(xmlFile, key .. "#breederId", self.breederId)
    local i = 0
    for _, trailerId in ipairs(self.trailerIds) do
        local uniqueId = TCVehicleIds.getUniqueId(trailerId)
        if uniqueId ~= nil then
            setXMLString(xmlFile, string.format("%s.trailer(%d)#uniqueId", key, i), uniqueId)
            i = i + 1
        end
    end
end

function TheContractorBreedersPen:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorBreedersPen.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.farmId = getXMLInt(xmlFile, key .. "#farmId") or 0
    self.breederId = getXMLInt(xmlFile, key .. "#breederId") or 0
    self.trailerIds = {}
    self.savedUniqueIds = {}
    local i = 0
    while true do
        local uniqueId = getXMLString(xmlFile, string.format("%s.trailer(%d)#uniqueId", key, i))
        if uniqueId == nil then
            break
        end
        table.insert(self.savedUniqueIds, uniqueId)
        i = i + 1
    end
end

-- Server, once vehicles exist: the trailers' object ids from their
-- uniqueIds. Kept only for the show that's still on, its day not past, and
-- while their farm id's still nobody's; otherwise taken away.
function TheContractorBreedersPen:resolveSavedVehicles()
    local uniqueIds = self.savedUniqueIds or {}
    self.savedUniqueIds = nil
    for _, uniqueId in ipairs(uniqueIds) do
        local vehicleId = TCVehicleIds.getObjectId(uniqueId)
        if vehicleId ~= nil then
            table.insert(self.trailerIds, vehicleId)
        end
    end
    local event = getShowEvent()
    local today = g_currentMission.environment.currentMonotonicDay
    local keep = #self.trailerIds > 0 and self.farmId > 0 and event ~= nil and event.id == self.showId and
        today <= event.day and not farmExists(self.farmId)
    if not keep then
        if #self.trailerIds > 0 or self.showId ~= nil then
            TCLog.info("TheContractor: the breeders' pen from the save is over: taken away")
        end
        self:close()
        return
    end
    TCLog.info("TheContractor: the breeders' pen's %d trailer(s) back from the save", #self.trailerIds)
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

-- A trailer out at a bay, owned by the spare farm id, MISSION state.
function ENGINE.spawnTrailer(pen, entry, bay, generation)
    local storeItem = g_storeManager:getItemByXMLFilename(entry.model.xmlFilename)
    if storeItem == nil or VehicleLoadingData == nil then
        return
    end
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    loadingData:setPosition(bay.x, nil, bay.z, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, bay.yaw, 0)
    loadingData:setPropertyState(VehiclePropertyState.MISSION)
    loadingData:setOwnerFarmId(pen.farmId)
    loadingData:load(function(_, vehicles, loadingState)
        local vehicle = vehicles ~= nil and vehicles[1] or nil
        if vehicle == nil or loadingState ~= VehicleLoadingState.OK then
            TCLog.warning("TheContractor: the breeder's %s trailer didn't load", entry.typeName)
            for _, loaded in ipairs(vehicles or {}) do
                if not loaded.isDeleted then
                    loaded:delete()
                end
            end
            return
        end
        pen:onTrailerSpawned(vehicle, entry, generation)
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

-- tcShow breeder: the pen, its trailers and what's in them at what price.
function TheContractorBreedersPen:describe()
    if not TCRealisticLivestock.hasAPI() then
        return "The breeders' pen needs RealisticLivestock (with its RealisticLivestockAPI): it's off."
    end
    if not self:isOut() then
        return "There's no breeders' pen out: it's set out with the show, at midnight before its day."
    end
    local breeder = self:getBreeder()
    local lines = {
        string.format("Show %d's breeders' pen (%s now), farm id %d, breeder %s, %d trailer(s):", self.showId,
            self:isOpen() and "open" or "closed", self.farmId, breeder ~= nil and breeder.name or "-",
            #self.trailerIds),
    }
    local catalogue = self:getCatalogue(true)
    for _, entry in ipairs(catalogue) do
        local info = entry.info
        table.insert(lines, string.format("  %s: %s, %d months%s, %.0f kg, health %.0f, %s; value %.0f, price %d%s",
            entry.key, entry.title or tostring(info.subType), info.age or 0,
            info.pregnant and ", pregnant" or "", info.weight or 0, info.health or 0,
            formatGenetics(info.genetics), entry.value, entry.price, info.diseased and " (sick: not for sale)" or ""))
    end
    if #catalogue == 0 then
        table.insert(lines, "  Sold out.")
    end
    return table.concat(lines, "\n")
end

function TheContractorBreedersPen.registerConsoleCommands()
    TCConsole.register("show", "breeder", {
        description = "The show's breeders' pen (RealisticLivestock only): its trailers, and each animal for sale and its price",
        serverOnly = false,
        run = function(_, args)
            if args[1] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.BreedersPen:describe()
        end,
    })
end
