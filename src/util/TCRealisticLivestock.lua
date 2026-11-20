-- FS25_RealisticLivestockRM (RL), read for the show's livestock (166,
-- spike; 167 judges with it). The only place that knows RL's animal shape.
--
-- Without RL a livestock trailer holds vanilla clusters: "N animals of this
-- subtype, this age, health and reproduction", merged and split as they're
-- moved, with ids that last a session. With RL every animal in a trailer is
-- its own record (RL's Animal: numAnimals 1, isIndividual true), and RL
-- streams the whole record to every client (AnimalSerialization), so what
-- the judge reads is the same on every machine.
--
-- Nothing here calls RL: an RL animal is read field by field, each one
-- type-checked, so a field RL renames is only left out. The features that
-- do call RL are detected once per loadMap, one flag each, and a missing
-- function hides only what needs it, with one warning per session:
--   diseases   Animal.getHasAnyDisease (a sick animal can't be shown)
-- Checked against refs/FS25_RealisticLivestockRM.

TCRealisticLivestock = {}

-- The names RL has been published under.
TCRealisticLivestock.MOD_NAMES = { "FS25_RealisticLivestockRM", "FS25_RealisticLivestock" }

-- The genetics RL keeps (1.0 is average; productivity only for milk, wool
-- and egg animals).
TCRealisticLivestock.GENETICS = { "quality", "health", "productivity", "metabolism", "fertility" }

local capabilities = {}
local entryPoints = {}
local warned = {}

-- RL's mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCRealisticLivestock.getEnv()
    for _, modName in ipairs(TCRealisticLivestock.MOD_NAMES) do
        local env = TheContractorDrivers.getModEnv(modName)
        if env ~= nil then
            return env
        end
    end
    return nil
end

local function lookUp(env, tableName, fieldName)
    local owner = env[tableName]
    local value = type(owner) == "table" and owner[fieldName] or nil
    if type(value) ~= "function" then
        local name = tableName .. "." .. fieldName
        if not warned[name] then
            warned[name] = true
            TCLog.warning("TheContractor: RealisticLivestock's %s is missing or has changed - what needs it is switched off",
                name)
        end
        return nil
    end
    return value
end

-- Called every loadMap.
function TCRealisticLivestock.detect()
    capabilities = {}
    entryPoints = {}
    local env = TCRealisticLivestock.getEnv()
    if env == nil then
        return
    end
    capabilities.loaded = true
    entryPoints.getHasAnyDisease = lookUp(env, "Animal", "getHasAnyDisease")
    capabilities.diseases = entryPoints.getHasAnyDisease ~= nil
end

function TCRealisticLivestock.isLoaded()
    return capabilities.loaded == true
end

function TCRealisticLivestock.canReadDiseases()
    return capabilities.diseases == true
end

-- Whether a cluster from a trailer is one of RL's animals.
function TCRealisticLivestock.isAnimal(cluster)
    return type(cluster) == "table" and cluster.isIndividual == true and type(cluster.uniqueId) == "string"
end

local function readNumber(value)
    return type(value) == "number" and value or nil
end

local function readString(value)
    return type(value) == "string" and value ~= "" and value or nil
end

-- What the judge reads of one RL animal: {
--   key        "country herdId uniqueId", the animal across loads and moves
--   herdId, uniqueId, country (RL's birth country number)
--   name, breed, gender, weight, targetWeight
--   genetics = { quality, health, productivity, metabolism, fertility }
--   isPregnant, isLactating, isCastrated
--   isSick     (nil when RL's disease check is missing)
-- }, every field nil when RL doesn't have it. Plain data, safe to keep.
function TCRealisticLivestock.readAnimal(animal)
    if not TCRealisticLivestock.isAnimal(animal) then
        return nil
    end
    local herdId = readString(animal.farmId)
    local country = type(animal.birthday) == "table" and readNumber(animal.birthday.country) or nil
    local read = {
        herdId = herdId,
        uniqueId = animal.uniqueId,
        country = country,
        key = string.format("%s %s %s", tostring(country or 0), herdId or "-", animal.uniqueId),
        name = readString(animal.name),
        breed = readString(animal.breed),
        gender = readString(animal.gender),
        weight = readNumber(animal.weight),
        targetWeight = readNumber(animal.targetWeight),
        isPregnant = animal.isPregnant == true,
        isLactating = animal.isLactating == true,
        isCastrated = animal.isCastrated == true,
        genetics = {},
    }
    if type(animal.genetics) == "table" then
        for _, trait in ipairs(TCRealisticLivestock.GENETICS) do
            read.genetics[trait] = readNumber(animal.genetics[trait])
        end
    end
    if TCRealisticLivestock.canReadDiseases() then
        read.isSick = entryPoints.getHasAnyDisease(animal) == true
    end
    return read
end

-- Tests.
function TCRealisticLivestock.reset()
    capabilities = {}
    entryPoints = {}
    warned = {}
end
