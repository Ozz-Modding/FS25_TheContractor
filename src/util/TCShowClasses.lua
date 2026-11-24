-- The show's livestock classes (167): which class an animal shows in, and
-- what each class is called. Pure, apart from reading the animal system
-- (every machine has the same one) and the texts.
--
-- A class is a subtype (a breed and sex: vanilla's COW_HOLSTEIN and
-- BULL_HOLSTEIN, or RealisticLivestock's own subtypes, split the same way)
-- and an age band of its type. Its key is "<SUBTYPE>:<band>", e.g.
-- "COW_HOLSTEIN:young". Nothing here names an animal: a class is called by
-- its subtype's own title (the game's or RL's fill type title, "Holstein
-- Bull") and its ages in months. Cattle, sheep and pigs have bands of their
-- own; any other type a trailer can carry (horses, a map's own) is young
-- until its breeding age, then adult. Chickens can't go in a livestock
-- trailer, so they have no classes.
--
-- Best Kept Herd (HERD_KEY) is judged on a husbandry, not on an animal.
-- The supreme champion of each animal type is "champion:<TYPE>".
-- Tested in tests/test_showLivestock.lua.

TCShowClasses = {}

TCShowClasses.HERD_KEY = "herd"
TCShowClasses.CHAMPION_PREFIX = "champion:"

-- Types never shown (no livestock trailer takes them).
TCShowClasses.EXCLUDED_TYPES = { CHICKEN = true }

-- Months. Each band: { key, from (inclusive), to (exclusive, nil: no end),
-- primeFrom, primeTo (the ages a judge likes best) }, youngest first; an
-- animal younger than the first band's `from` isn't shown.
TCShowClasses.BANDS = {
    COW = {
        { key = "young", from = 6, to = 24, primeFrom = 12, primeTo = 22 },
        { key = "adult", from = 24, primeFrom = 30, primeTo = 96 },
    },
    SHEEP = {
        { key = "young", from = 3, to = 12, primeFrom = 5, primeTo = 11 },
        { key = "yearling", from = 12, to = 24, primeFrom = 13, primeTo = 22 },
        { key = "adult", from = 24, primeFrom = 24, primeTo = 72 },
    },
    PIG = {
        { key = "young", from = 3, to = 12, primeFrom = 6, primeTo = 11 },
        { key = "adult", from = 12, primeFrom = 14, primeTo = 48 },
    },
}

-- Any other type: young until it can breed, then adult.
TCShowClasses.GENERIC_MIN_AGE = 3
TCShowClasses.GENERIC_ADULT_AGE = 12
TCShowClasses.GENERIC_PRIME_YEARS = 4

-- Where a judge counts a female's pregnancy (or, grown, her lactation) in
-- her favour, by band.
TCShowClasses.BREEDING_BANDS = { adult = "adult", yearling = "young", young = "young" }

-- The bands for a type (pure). adultAge: the subtype's breeding age, for a
-- type with no bands of its own.
function TCShowClasses.getBands(typeName, adultAge)
    if typeName == nil or TCShowClasses.EXCLUDED_TYPES[typeName] then
        return {}
    end
    local bands = TCShowClasses.BANDS[typeName]
    if bands ~= nil then
        return bands
    end
    local adult = math.max(TCShowClasses.GENERIC_MIN_AGE + 1, adultAge or TCShowClasses.GENERIC_ADULT_AGE)
    return {
        { key = "young", from = TCShowClasses.GENERIC_MIN_AGE, to = adult, primeFrom = TCShowClasses.GENERIC_MIN_AGE,
            primeTo = adult },
        { key = "adult", from = adult, primeFrom = adult, primeTo = adult + 12 * TCShowClasses.GENERIC_PRIME_YEARS },
    }
end

-- The band an age falls in, or nil (too young, or no bands). tolerance:
-- months past a band's end still taken as in it (a vanilla entry, which
-- may have had a birthday since it was entered).
function TCShowClasses.findBand(bands, age, bandKey, tolerance)
    if age == nil then
        return nil
    end
    for _, band in ipairs(bands) do
        if bandKey == nil or band.key == bandKey then
            local to = band.to ~= nil and band.to + (tolerance or 0) or nil
            if age >= band.from and (to == nil or age < to) then
                return band
            end
        end
    end
    return nil
end

function TCShowClasses.makeKey(subTypeName, bandKey)
    return string.format("%s:%s", subTypeName, bandKey)
end

function TCShowClasses.isChampionKey(key)
    return type(key) == "string" and string.sub(key, 1, #TCShowClasses.CHAMPION_PREFIX) == TCShowClasses.CHAMPION_PREFIX
end

function TCShowClasses.getChampionKey(typeName)
    return TCShowClasses.CHAMPION_PREFIX .. typeName
end

-- subTypeName, bandKey of a class key (nil for Best Kept Herd or a
-- champion).
function TCShowClasses.parseKey(classKey)
    if classKey == nil or classKey == TCShowClasses.HERD_KEY or TCShowClasses.isChampionKey(classKey) then
        return nil, nil
    end
    return string.match(classKey, "^(.+):([^:]+)$")
end

-- Reading the animal system (every machine) ----------------------------------------------------

-- The subtype and its type's name, or nil.
local function getSubType(animalSystem, subTypeName)
    if animalSystem == nil or subTypeName == nil then
        return nil, nil
    end
    local subType = animalSystem:getSubTypeByName(subTypeName)
    if subType == nil then
        return nil, nil
    end
    local animalType = animalSystem:getTypeByIndex(subType.typeIndex)
    return subType, animalType ~= nil and animalType.name or nil
end

-- A class from its key: { key, subTypeName, typeName, band } or nil when
-- the map hasn't the subtype (or it's not a class).
function TCShowClasses.getClass(animalSystem, classKey)
    local subTypeName, bandKey = TCShowClasses.parseKey(classKey)
    local subType, typeName = getSubType(animalSystem, subTypeName)
    if subType == nil then
        return nil
    end
    for _, band in ipairs(TCShowClasses.getBands(typeName, subType.reproductionMinAgeMonth)) do
        if band.key == bandKey then
            return { key = classKey, subTypeName = subTypeName, typeName = typeName, band = band }
        end
    end
    return nil
end

-- The class an animal shows in (an entry read from a husbandry or a
-- trailer: subTypeName, age, and RL's `animal`), or nil. A castrated male
-- isn't shown.
function TCShowClasses.getClassFor(animalSystem, read)
    if read == nil or read.subTypeName == nil then
        return nil
    end
    if read.animal ~= nil and read.animal.isCastrated then
        return nil
    end
    local subType, typeName = getSubType(animalSystem, read.subTypeName)
    if subType == nil then
        return nil
    end
    local band = TCShowClasses.findBand(TCShowClasses.getBands(typeName, subType.reproductionMinAgeMonth), read.age)
    if band == nil then
        return nil
    end
    return { key = TCShowClasses.makeKey(read.subTypeName, band.key), subTypeName = read.subTypeName,
        typeName = typeName, band = band }
end

-- Every class the map's animals can show in, by type then subtype then age.
function TCShowClasses.listClasses(animalSystem)
    local classes = {}
    if animalSystem == nil or animalSystem.getTypes == nil then
        return classes
    end
    for _, animalType in ipairs(animalSystem:getTypes() or {}) do
        if not TCShowClasses.EXCLUDED_TYPES[animalType.name] then
            for _, subTypeIndex in ipairs(animalType.subTypes or {}) do
                local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
                if subType ~= nil then
                    for _, band in ipairs(TCShowClasses.getBands(animalType.name, subType.reproductionMinAgeMonth)) do
                        table.insert(classes, { key = TCShowClasses.makeKey(subType.name, band.key),
                            subTypeName = subType.name, typeName = animalType.name, band = band })
                    end
                end
            end
        end
    end
    return classes
end

-- How well an age sits in a band (0.3-1): 1 in its prime, less a
-- twenty-fourth for each month either side.
function TCShowClasses.getAgeFactor(band, age)
    if band == nil or age == nil then
        return nil
    end
    local off = 0
    if age < band.primeFrom then
        off = band.primeFrom - age
    elseif band.primeTo ~= nil and age > band.primeTo then
        off = age - band.primeTo
    end
    return math.max(0.3, 1 - off / 24)
end

-- Texts (every machine) ------------------------------------------------------------------------

-- A subtype's name: its fill type's title, the game's or RL's own
-- ("Holstein Bull").
function TCShowClasses.getSubTypeTitle(animalSystem, subTypeName)
    local subType = getSubType(animalSystem, subTypeName)
    if subType ~= nil and g_fillTypeManager ~= nil then
        local title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
        if title ~= nil and title ~= "" then
            return title
        end
    end
    return subTypeName or "-"
end

-- A band's ages, in months.
function TCShowClasses.getAgeText(band)
    if band.to == nil then
        return string.format(g_i18n:getText("tc_showClass_agesFrom"), band.from)
    end
    return string.format(g_i18n:getText("tc_showClass_ages"), band.from, band.to)
end

-- What a class (or the herd, or a champion) is called on this machine.
function TCShowClasses.getTitle(classKey)
    local animalSystem = g_currentMission ~= nil and g_currentMission.animalSystem or nil
    if classKey == TCShowClasses.HERD_KEY then
        return g_i18n:getText("tc_showClass_herd")
    end
    if TCShowClasses.isChampionKey(classKey) then
        local typeName = string.sub(classKey, #TCShowClasses.CHAMPION_PREFIX + 1)
        local animalType = animalSystem ~= nil and animalSystem:getTypeByName(typeName) or nil
        local typeTitle = animalType ~= nil and animalType.groupTitle or typeName
        return string.format(g_i18n:getText("tc_showClass_champion"), typeTitle)
    end
    local class = TCShowClasses.getClass(animalSystem, classKey)
    if class == nil then
        return classKey or "-"
    end
    return string.format(g_i18n:getText("tc_showClass_title"),
        TCShowClasses.getSubTypeTitle(animalSystem, class.subTypeName), TCShowClasses.getAgeText(class.band))
end
