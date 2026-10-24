-- Supplies tab (064): what the farm has in stock of each supply its jobs
-- draw on (032, 063), and how much room it has for more. Read-only and
-- worked out locally on every machine: storage and pallet fill levels are
-- already synced by vanilla, so nothing here is saved or streamed.
--
-- The supplies are the ones TCJobSupplies actually draws, never a list of
-- our own: diesel, the seed tank fill type and the seed of every sowing
-- machine the farm owns, every job type's products (JOB_TYPES'
-- supplyFillTypeNames), and whatever the farm's consumable holders (bale
-- net, twine, wrap film) take. A supply the farm has none of still gets a
-- row.
--
-- Amounts are counted the way TCJobSupplies.getFarmStock counts them
-- (storages, then pallets). Capacity is only storage: for each of the
-- farm's storages that takes the fill type, what's in it plus the room it
-- has left for that type (Storage:getFreeCapacity). In a storage whose
-- capacity is shared between fill types, a neighbour filling up shrinks the
-- room shown - that's the truth, not a display bug. A supply with no
-- storage at all (pallets only) has no capacity and so no bar.

TCSupplyStock = {}

-- A supply is Low below a set amount in stock - storages and pallets
-- together, in its own unit - not a share of its storage. A big silo
-- (or a map's shared one, where every farm gets its own room) would make
-- any sensible amount look nearly empty. LOW_AMOUNTS is by fill type name;
-- anything not in it uses LOW_AMOUNT_VOLUME, or LOW_AMOUNT_PIECES for one
-- counted in pieces (bale net, twine, film).
TCSupplyStock.LOW_AMOUNTS = {
    SEEDS = 10000,
}
TCSupplyStock.LOW_AMOUNT_VOLUME = 10000
TCSupplyStock.LOW_AMOUNT_PIECES = 10

-- ADS consumables (TCADSStock) are still judged by how full they are:
-- below this share of capacity - vanilla's production storage list uses
-- the same (InGameMenuProductionFrame.STATUS_BAR_LOW).
TCSupplyStock.LOW_RATIO = 0.2

-- How little of a supply counts as Low (see LOW_AMOUNTS).
function TCSupplyStock.getLowAmount(fillTypeIndex)
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    if name ~= nil and TCSupplyStock.LOW_AMOUNTS[name] ~= nil then
        return TCSupplyStock.LOW_AMOUNTS[name]
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType ~= nil and fillType.unitShort ~= nil and fillType.unitShort ~= "" then
        return TCSupplyStock.LOW_AMOUNT_PIECES
    end
    return TCSupplyStock.LOW_AMOUNT_VOLUME
end

local function isOwnedBy(object, farmId)
    return object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId
end

local function addFillType(list, seen, fillTypeIndex)
    if fillTypeIndex ~= nil and fillTypeIndex ~= FillType.UNKNOWN and not seen[fillTypeIndex] then
        seen[fillTypeIndex] = true
        table.insert(list, fillTypeIndex)
    end
end

-- The farm's vehicles that aren't pallets.
local function getFarmMachines(farmId)
    local result = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        -- 100: not a customer's machine in a repair zone.
        if not vehicle.isPallet and isOwnedBy(vehicle, farmId) and
                not (TheContractorRepairContracts ~= nil and TheContractorRepairContracts.isContractVehicle(vehicle)) then
            table.insert(result, vehicle)
        end
    end
    return result
end

-- The supplies' fill type indices, in display order: diesel, seed, the job
-- types' products, then consumables.
function TCSupplyStock.getSupplyFillTypes(farmId)
    local list, seen = {}, {}
    local machines = getFarmMachines(farmId)

    addFillType(list, seen, FillType.DIESEL)
    addFillType(list, seen, TCEquipmentClass.SEED_TANK_FILL_TYPE)
    for _, vehicle in ipairs(machines) do
        if vehicle.spec_sowingMachine ~= nil then
            addFillType(list, seen, vehicle.spec_sowingMachine.seedFillType)
        end
    end

    local jobTypeKeys = {}
    for key in pairs(TheContractorJobGeneration.JOB_TYPES) do
        table.insert(jobTypeKeys, key)
    end
    table.sort(jobTypeKeys)
    for _, key in ipairs(jobTypeKeys) do
        for _, name in ipairs(TheContractorJobGeneration.JOB_TYPES[key].supplyFillTypeNames or {}) do
            addFillType(list, seen, g_fillTypeManager:getFillTypeIndexByName(name))
        end
    end

    local consumables = {}
    for _, vehicle in ipairs(machines) do
        local spec = vehicle.spec_consumable
        if spec ~= nil and spec.types ~= nil and vehicle.getFillUnitSupportedFillTypes ~= nil then
            for _, consumableType in ipairs(spec.types) do
                for fillTypeIndex, isSupported in pairs(vehicle:getFillUnitSupportedFillTypes(
                    consumableType.fillUnitIndex) or {}) do
                    if isSupported then
                        addFillType(consumables, seen, fillTypeIndex)
                    end
                end
            end
        end
    end
    table.sort(consumables)
    for _, fillTypeIndex in ipairs(consumables) do
        table.insert(list, fillTypeIndex)
    end

    return list
end

-- Storage names ---------------------------------------------------------------
--
-- A storage doesn't know which placeable it belongs to. Each placeable
-- keeps its own in a spec table (a silo's storages, an extension's storage,
-- a husbandry's storage, a production point's storage, ...), so this looks
-- through the farm's placeables' spec tables a level or two down for the
-- storages it was asked about, rather than naming each kind of placeable.

local function findStorages(map, wanted, placeable, value, depth)
    if type(value) ~= "table" then
        return
    end
    if wanted[value] then
        map[value] = map[value] or placeable
        return
    end
    if depth >= 2 then
        return
    end
    for _, child in pairs(value) do
        if type(child) == "table" and child ~= placeable then
            findStorages(map, wanted, placeable, child, depth + 1)
        end
    end
end

-- A storage's unloading/loading stations (vanilla keeps them as sets).
local function getStations(storage)
    local stations = {}
    for _, set in ipairs({ storage.unloadingStations or {}, storage.loadingStations or {} }) do
        for station in pairs(set) do
            if type(station) == "table" then
                table.insert(stations, station)
            end
        end
    end
    return stations
end

-- storage -> placeable, for the storages in `wanted` (a set). One the spec
-- search misses (a mod keeping it further down) is found through its
-- stations, which know the building they belong to.
local function mapStoragesToPlaceables(farmId, wanted)
    local map = {}
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem ~= nil and placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(placeableSystem.placeables) do
            if isOwnedBy(placeable, farmId) then
                for key, spec in pairs(placeable) do
                    if type(key) == "string" and key:sub(1, 5) == "spec_" then
                        findStorages(map, wanted, placeable, spec, 0)
                    end
                end
            end
        end
    end
    for storage in pairs(wanted) do
        if map[storage] == nil then
            for _, station in ipairs(getStations(storage)) do
                if station.owningPlaceable ~= nil then
                    map[storage] = station.owningPlaceable
                    break
                end
            end
        end
    end
    return map
end

-- The building's name, else a station's own name, else plain "Storage".
local function getStorageName(storage, placeable)
    if placeable ~= nil and placeable.getName ~= nil then
        local name = placeable:getName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    for _, station in ipairs(getStations(storage)) do
        local name = station.stationName
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return g_i18n:getText("tc_supplies_storage")
end

-- Supplies --------------------------------------------------------------------

-- The farm's jobs on hold because it's run out of this fill type.
local function getHeldJobs(farmId, fillTypeName)
    local result = {}
    local jobs = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.Jobs or nil
    if jobs == nil or fillTypeName == nil then
        return result
    end
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) and
            job.supplyStatus == TCJobSupplies.STATUS.NO_STOCK and job.supplyFillTypeName == fillTypeName then
            table.insert(result, job)
        end
    end
    return result
end

-- One supply: {
--   fillTypeIndex, fillTypeName, title,
--   amount        everything in stock (storages + pallets)
--   storedAmount  the part of it in storages
--   capacity      storedAmount + room left, nil with no storage for it
--   ratio         storedAmount / capacity, nil with no capacity
--   storages      { { name, amount, capacity }... }, every storage that
--                 takes it, empty ones too
--   pallets       { { name, count, amount }... }, grouped by name
--   heldJobs      jobs on hold for it (noStock)
--   isLow         amount under getLowAmount, or none at all
-- }
local function buildSupply(farmId, fillTypeIndex, placeableByStorage, storageEntries)
    local supply = {
        fillTypeIndex = fillTypeIndex,
        fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex),
        title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or tostring(fillTypeIndex),
        amount = 0,
        storedAmount = 0,
        storages = {},
        pallets = {},
    }

    for _, entry in ipairs(storageEntries) do
        local level, room = entry.level, entry.room
        supply.storedAmount = supply.storedAmount + level
        supply.capacity = (supply.capacity or 0) + level + room
        table.insert(supply.storages, {
            name = getStorageName(entry.storage, placeableByStorage[entry.storage]),
            amount = level,
            capacity = level + room,
        })
    end

    local palletsByName = {}
    for _, source in ipairs(TCJobSupplies.getPalletSources(farmId, fillTypeIndex)) do
        local name = source.pallet:getName()
        local group = palletsByName[name]
        if group == nil then
            group = { name = name, count = 0, amount = 0 }
            palletsByName[name] = group
            table.insert(supply.pallets, group)
        end
        group.count = group.count + 1
        group.amount = group.amount + source.level
    end

    supply.amount = supply.storedAmount
    for _, group in ipairs(supply.pallets) do
        supply.amount = supply.amount + group.amount
    end

    if supply.capacity ~= nil and supply.capacity > 0 then
        supply.ratio = math.min(supply.storedAmount / supply.capacity, 1)
    end
    supply.heldJobs = getHeldJobs(farmId, supply.fillTypeName)
    supply.isLow = supply.amount <= 0 or supply.amount < TCSupplyStock.getLowAmount(fillTypeIndex)

    return supply
end

-- The farm's storages that take each of fillTypes: fillTypeIndex ->
-- { { storage, level, room }... }, and the set of them all.
local function getStorageEntries(farmId, fillTypes)
    local entriesByFillType, wanted = {}, {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        entriesByFillType[fillTypeIndex] = {}
    end
    for _, storage in pairs(g_currentMission.storageSystem:getStorages()) do
        if isOwnedBy(storage, farmId) and storage.getIsFillTypeSupported ~= nil then
            for _, fillTypeIndex in ipairs(fillTypes) do
                if storage:getIsFillTypeSupported(fillTypeIndex) then
                    local level = storage:getFillLevel(fillTypeIndex) or 0
                    local room = storage.getFreeCapacity ~= nil and storage:getFreeCapacity(fillTypeIndex) or 0
                    table.insert(entriesByFillType[fillTypeIndex], { storage = storage, level = level, room = room })
                    wanted[storage] = true
                end
            end
        end
    end
    return entriesByFillType, wanted
end

-- Every supply (see buildSupply), in getSupplyFillTypes' order.
function TCSupplyStock.getSupplies(farmId)
    local fillTypes = TCSupplyStock.getSupplyFillTypes(farmId)
    local entriesByFillType, wanted = getStorageEntries(farmId, fillTypes)
    local placeableByStorage = mapStoragesToPlaceables(farmId, wanted)

    local supplies = {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        table.insert(supplies, buildSupply(farmId, fillTypeIndex, placeableByStorage, entriesByFillType[fillTypeIndex]))
    end
    return supplies
end

-- Console commands (tcCompany - see TCConsole) ---------------------------------

local COMPASS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

-- "1.2 km north-east of you" from the local player to a world position, or
-- the bare coordinates when there's no player to measure from.
local function describeWhere(x, z)
    if g_localPlayer == nil or g_localPlayer.getPosition == nil then
        return string.format("at x %.0f, z %.0f", x, z)
    end
    local px, _, pz = g_localPlayer:getPosition()
    local dx, dz = x - px, z - pz
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 50 then
        return "right by you"
    end
    -- World z runs south, so north is -z.
    local sector = math.floor((math.atan2(-dz, dx) / (2 * math.pi) * 8 + 0.5) % 8) + 1
    local distanceText = distance >= 1000 and string.format("%.1f km", distance / 1000) or
        string.format("%.0f m", distance)
    return string.format("%s %s of you", distanceText, COMPASS[sector])
end

local function getStoragePosition(storage, placeable)
    for _, node in ipairs({ storage.rootNode, placeable ~= nil and placeable.rootNode or nil }) do
        if node ~= nil and node ~= 0 and entityExists(node) then
            local x, _, z = getWorldTranslation(node)
            return x, z
        end
    end
    return nil
end

function TCSupplyStock.registerConsoleCommands()
    -- Finding a storage the Supplies tab counts: what it is, whose mod, how
    -- full, and where. Read-only, so it works on any machine.
    TCConsole.register("company", "storages", {
        args = "[fillType]",
        description = "Your storages the Supplies tab counts, with where they are",
        serverOnly = false,
        run = function(farmId, args)
            local fillTypes
            if args[1] ~= nil then
                local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(string.upper(args[1]))
                if fillTypeIndex == nil then
                    return string.format("No fill type called %s (e.g. SEEDS, FERTILIZER, DIESEL).", args[1])
                end
                fillTypes = { fillTypeIndex }
            else
                fillTypes = TCSupplyStock.getSupplyFillTypes(farmId)
            end

            local entriesByFillType, wanted = getStorageEntries(farmId, fillTypes)
            local placeableByStorage = mapStoragesToPlaceables(farmId, wanted)
            local lines = {}
            for _, fillTypeIndex in ipairs(fillTypes) do
                local entries = entriesByFillType[fillTypeIndex]
                if #entries > 0 then
                    table.insert(lines, string.format("%s:", g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)))
                    for _, entry in ipairs(entries) do
                        local placeable = placeableByStorage[entry.storage]
                        local x, z = getStoragePosition(entry.storage, placeable)
                        local mod = placeable ~= nil and placeable.customEnvironment or nil
                        table.insert(lines, string.format("  %s%s - %.0f of %.0f, %s", getStorageName(entry.storage,
                            placeable), mod ~= nil and (" [" .. mod .. "]") or "", entry.level, entry.level + entry.room,
                            x ~= nil and describeWhere(x, z) or "position unknown"))
                    end
                end
            end
            if #lines == 0 then
                return string.format("Farm %d has no storages for %s.", farmId,
                    args[1] ~= nil and args[1] or "its supplies")
            end
            return table.concat(lines, "\n")
        end,
    })
end
