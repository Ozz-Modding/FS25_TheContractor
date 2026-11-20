-- The show's livestock (166, spike; 167 builds the classes on it): the
-- animals in a livestock trailer, as the judge reads them.
--
-- Entrants bring their animals in a livestock trailer parked in the show's
-- trailer lines (TCShowScene.findBay). The animals never leave vanilla's
-- (or RealisticLivestock's) own systems: the trailer is only read.
--
-- A trailer is read through vanilla's LivestockTrailer (getClusters), which
-- RL overrides to hand back its individual animals. Every cluster becomes
-- an entry:
--   vanilla  { count, subTypeName, title, typeName, age, health,
--              reproduction }: a group of animals alike, with no lasting
--              identity (vanilla's cluster ids are per session and change
--              as clusters merge or split).
--   RL       the same with count 1, plus `animal` (TCRealisticLivestock.
--              readAnimal: its herd id, name, breed, genetics, ...), whose
--              key names the animal across loads and moves.
-- Tested in tests/test_showAnimals.lua.

TCShowAnimals = {}

-- Metres: how far `tcDebug showTrailer` looks for a trailer.
TCShowAnimals.FIND_RADIUS = 15

-- Whether a vehicle is a livestock trailer we can read.
function TCShowAnimals.isTrailer(vehicle)
    return type(vehicle) == "table" and vehicle.spec_livestockTrailer ~= nil and type(vehicle.getClusters) == "function"
end

-- The trailer's animals: { typeName, individual, count, entries } or nil
-- when it isn't a livestock trailer. `individual` is true when every
-- entry is one of RL's animals.
function TCShowAnimals.readTrailer(trailer)
    if not TCShowAnimals.isTrailer(trailer) then
        return nil
    end
    local animalSystem = g_currentMission.animalSystem
    local result = { entries = {}, count = 0, individual = false }
    local clusters = trailer:getClusters() or {}
    local allIndividual = #clusters > 0
    for _, cluster in ipairs(clusters) do
        local entry = TCShowAnimals.readCluster(animalSystem, cluster)
        if entry ~= nil then
            table.insert(result.entries, entry)
            result.count = result.count + entry.count
            result.typeName = result.typeName or entry.typeName
            if entry.animal == nil then
                allIndividual = false
            end
        end
    end
    result.individual = allIndividual and #result.entries > 0
    return result
end

local function getCount(cluster)
    if type(cluster.getNumAnimals) == "function" then
        return cluster:getNumAnimals()
    end
    return cluster.numAnimals or 0
end

-- One cluster (see the header), or nil for an empty one.
function TCShowAnimals.readCluster(animalSystem, cluster)
    local count = getCount(cluster)
    if count == nil or count < 1 then
        return nil
    end
    local subTypeIndex = cluster.subTypeIndex
    local subType = animalSystem ~= nil and subTypeIndex ~= nil and animalSystem:getSubTypeByIndex(subTypeIndex) or nil
    local animalType = subType ~= nil and animalSystem:getTypeByIndex(subType.typeIndex) or nil
    local entry = {
        count = count,
        subTypeIndex = subTypeIndex,
        subTypeName = subType ~= nil and subType.name or nil,
        title = subType ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex) or nil,
        typeName = animalType ~= nil and animalType.name or nil,
        age = cluster.age,
        health = cluster.health,
        reproduction = cluster.reproduction,
    }
    if TCRealisticLivestock.isAnimal(cluster) then
        entry.animal = TCRealisticLivestock.readAnimal(cluster)
    end
    return entry
end

-- The trailer the typing player means: the one they're in or towing, or
-- else the nearest within FIND_RADIUS of where they stand. `vehicle` is
-- what they're in (or nil), `trailers` vanilla's list
-- (husbandrySystem.livestockTrailers).
function TCShowAnimals.findTrailer(vehicle, x, z, trailers)
    if vehicle ~= nil then
        if TCShowAnimals.isTrailer(vehicle) then
            return vehicle
        end
        if type(vehicle.getChildVehicles) == "function" then
            for _, child in ipairs(vehicle:getChildVehicles() or {}) do
                if TCShowAnimals.isTrailer(child) then
                    return child
                end
            end
        end
    end
    if x == nil or z == nil then
        return nil
    end
    local best, bestDistance = nil, TCShowAnimals.FIND_RADIUS
    for _, trailer in ipairs(trailers or {}) do
        if TCShowAnimals.isTrailer(trailer) and trailer.rootNode ~= nil then
            local tx, _, tz = getWorldTranslation(trailer.rootNode)
            local distance = math.sqrt((tx - x) ^ 2 + (tz - z) ^ 2)
            if distance <= bestDistance then
                best, bestDistance = trailer, distance
            end
        end
    end
    return best
end

-- Where the trailer stands for judging (166's "in the lines" question):
-- { farmId, bay (or nil, outside the lines or no show set out), speed
-- (km/h), isHitched }.
function TCShowAnimals.getStanding(trailer, scene)
    local standing = {
        farmId = type(trailer.getOwnerFarmId) == "function" and trailer:getOwnerFarmId() or nil,
        speed = type(trailer.getLastSpeed) == "function" and trailer:getLastSpeed() or 0,
        isHitched = type(trailer.getAttacherVehicle) == "function" and trailer:getAttacherVehicle() ~= nil,
    }
    if scene ~= nil and TCShowScene.isShowDressing(scene) and trailer.rootNode ~= nil then
        local x, _, z = getWorldTranslation(trailer.rootNode)
        standing.bay = TCShowScene.findBay(scene, x, z)
    end
    return standing
end

-- Console ------------------------------------------------------------------------------------

local function formatFactor(value)
    return value ~= nil and string.format("%.2f", value) or "-"
end

local function describeEntry(entry)
    local parts = {}
    if entry.animal == nil then
        table.insert(parts, string.format("%d x %s (%s)", entry.count, tostring(entry.title), tostring(entry.subTypeName)))
    else
        local animal = entry.animal
        table.insert(parts, string.format("%s \"%s\" (%s)", animal.key, animal.name or "-", tostring(entry.subTypeName)))
        table.insert(parts, string.format("breed %s, %s", animal.breed or "-", animal.gender or "-"))
    end
    table.insert(parts, string.format("age %s months", tostring(entry.age)))
    table.insert(parts, string.format("health %s", entry.health ~= nil and string.format("%.0f", entry.health) or "-"))
    table.insert(parts, string.format("reproduction %s", entry.reproduction ~= nil and string.format("%.0f", entry.reproduction) or "-"))
    local line = "  " .. table.concat(parts, ", ")
    local animal = entry.animal
    if animal ~= nil then
        local genetics = {}
        for _, trait in ipairs(TCRealisticLivestock.GENETICS) do
            table.insert(genetics, string.format("%s %s", trait, formatFactor(animal.genetics[trait])))
        end
        local flags = {}
        if animal.isPregnant then table.insert(flags, "pregnant") end
        if animal.isLactating then table.insert(flags, "lactating") end
        if animal.isCastrated then table.insert(flags, "castrated") end
        if animal.isSick then table.insert(flags, "sick") end
        line = line .. string.format("\n    weight %s of %s kg; genetics %s%s",
            animal.weight ~= nil and string.format("%.0f", animal.weight) or "-",
            animal.targetWeight ~= nil and string.format("%.0f", animal.targetWeight) or "-",
            table.concat(genetics, ", "),
            #flags > 0 and ("; " .. table.concat(flags, ", ")) or "")
    end
    return line
end

-- The readout for `tcDebug showTrailer` (a debug tool: plain English).
function TCShowAnimals.describe(trailer, scene)
    local read = TCShowAnimals.readTrailer(trailer)
    local standing = TCShowAnimals.getStanding(trailer, scene)
    local lines = {}
    local name = type(trailer.getFullName) == "function" and trailer:getFullName() or "Livestock trailer"
    table.insert(lines, string.format("%s (farm %s): %d animal(s), %s, %s.", name, tostring(standing.farmId),
        read.count, read.typeName or "empty",
        read.individual and "RealisticLivestock individuals" or (TCRealisticLivestock.isLoaded() and
            "vanilla clusters (RealisticLivestock is loaded)" or "vanilla clusters")))
    local where
    if scene == nil or not TCShowScene.isShowDressing(scene) then
        where = "no showground set out"
    elseif standing.bay ~= nil then
        where = string.format("in trailer line bay %d", standing.bay)
    else
        where = "outside the trailer lines"
    end
    table.insert(lines, string.format("  Standing: %s, %s, %.1f km/h.", where,
        standing.isHitched and "hitched" or "unhitched", standing.speed))
    for _, entry in ipairs(read.entries) do
        table.insert(lines, describeEntry(entry))
    end
    return table.concat(lines, "\n")
end

function TCShowAnimals.registerConsoleCommands()
    TCConsole.register("debug", "showTrailer", {
        description = "The animals in the livestock trailer you're in, towing or standing by, as the show's judge reads them",
        run = function(_, _, context)
            local husbandrySystem = g_currentMission.husbandrySystem
            local trailers = husbandrySystem ~= nil and husbandrySystem.livestockTrailers or {}
            local x, z
            if TCConsole.hasPosition(context) then
                x, z = context.x, context.z
            end
            local trailer = TCShowAnimals.findTrailer(TCConsole.getVehicle(context), x, z, trailers)
            if trailer == nil then
                return string.format("No livestock trailer here: get in one, hitch one, or stand within %d m of one.",
                    TCShowAnimals.FIND_RADIUS)
            end
            local site = g_currentMission.TheContractor.AuctionSite
            return TCShowAnimals.describe(trailer, site ~= nil and site:getScene() or nil)
        end,
    })
end
