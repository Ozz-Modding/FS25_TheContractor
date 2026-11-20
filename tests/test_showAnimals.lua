-- 166: the show's livestock, read from a livestock trailer (TCShowAnimals)
-- with and without FS25_RealisticLivestockRM (TCRealisticLivestock), and
-- where the trailer stands in the showground's trailer lines
-- (TCShowScene.findBay).
--
-- The fake trailer follows vanilla's LivestockTrailer (getClusters, spec
-- present); a vanilla cluster is AnimalCluster's fields (numAnimals,
-- subTypeIndex, age, health, reproduction); an RL animal is RL's Animal
-- (isIndividual, uniqueId, farmId as its herd id, birthday.country, name,
-- breed, gender, weight, targetWeight, genetics, isPregnant, isLactating,
-- getHasAnyDisease), as in refs/FS25_RealisticLivestockRM.

local RL = "FS25_RealisticLivestockRM"

local function setup(rlEnv)
    local world = stubs.install()
    world.rlEnv = rlEnv
    TheContractorDrivers = {
        getModEnv = function(modName)
            return modName == RL and world.rlEnv or nil
        end,
    }
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/util/TCRealisticLivestock.lua")
    world:load("src/util/TCShowAnimals.lua")
    TCRealisticLivestock.reset()
    TCRealisticLivestock.detect()

    local cow = world:addFillType("COW_HOLSTEIN", "Holstein")
    local bull = world:addFillType("BULL_HOLSTEIN", "Holstein bull")
    local types = { { name = "COW", typeIndex = 1 } }
    local subTypes = {
        { name = "COW_HOLSTEIN", subTypeIndex = 1, typeIndex = 1, fillTypeIndex = cow },
        { name = "BULL_HOLSTEIN", subTypeIndex = 2, typeIndex = 1, fillTypeIndex = bull },
    }
    g_currentMission.animalSystem = {
        getSubTypeByIndex = function(_, index)
            return subTypes[index]
        end,
        getTypeByIndex = function(_, index)
            return types[index]
        end,
    }
    -- A node is a table of its world position.
    getWorldTranslation = function(node)
        return node.x, 0, node.z
    end
    return world
end

-- RL's Animal class: getHasAnyDisease reads the fake animal's `sick`.
local function rlEnv(withDiseases)
    local animal = {}
    if withDiseases then
        animal.getHasAnyDisease = function(self)
            return self.sick == true
        end
    end
    return { Animal = animal }
end

local function newTrailer(clusters, def)
    def = def or {}
    return {
        spec_livestockTrailer = {},
        rootNode = { x = def.x or 0, z = def.z or 0 },
        getClusters = function()
            return clusters
        end,
        getOwnerFarmId = function()
            return def.farmId or 1
        end,
        getLastSpeed = function()
            return def.speed or 0
        end,
        getAttacherVehicle = function()
            return def.attacher
        end,
    }
end

local function vanillaCluster(subTypeIndex, numAnimals, age, health)
    return { subTypeIndex = subTypeIndex, numAnimals = numAnimals, age = age, health = health, reproduction = 20 }
end

local function rlAnimal(def)
    return {
        isIndividual = true,
        numAnimals = 1,
        subTypeIndex = def.subTypeIndex or 1,
        uniqueId = def.uniqueId,
        farmId = def.herdId or "482913",
        birthday = { day = 4, month = 3, year = 1, country = def.country or 7 },
        name = def.name,
        breed = def.breed,
        gender = def.gender or "female",
        age = def.age or 24,
        health = def.health or 90,
        reproduction = 40,
        weight = 610,
        targetWeight = 650,
        genetics = def.genetics,
        isPregnant = def.isPregnant,
        sick = def.sick,
    }
end

test("without RL a trailer reads as vanilla's groups: subtype, count, age, health, no identity", function()
    setup(nil)
    assertTrue(not TCRealisticLivestock.isLoaded(), "RL loaded")
    local trailer = newTrailer({ vanillaCluster(1, 3, 24, 100), vanillaCluster(2, 1, 30, 80), vanillaCluster(1, 0, 5, 50) })
    local read = TCShowAnimals.readTrailer(trailer)
    assertEquals(read.count, 4, "animals")
    assertEquals(#read.entries, 2, "an empty cluster is skipped")
    assertEquals(read.typeName, "COW")
    assertTrue(not read.individual, "individual")
    local first = read.entries[1]
    assertEquals(first.count, 3)
    assertEquals(first.subTypeName, "COW_HOLSTEIN")
    assertEquals(first.title, "Holstein")
    assertEquals(first.age, 24)
    assertEquals(first.health, 100)
    assertEquals(first.reproduction, 20)
    assertEquals(first.animal, nil, "no animal record")
    assertEquals(read.entries[2].subTypeName, "BULL_HOLSTEIN")
end)

test("an empty trailer reads as nothing, and a vehicle that isn't one reads as nil", function()
    setup(nil)
    local read = TCShowAnimals.readTrailer(newTrailer({}))
    assertEquals(read.count, 0)
    assertEquals(#read.entries, 0)
    assertTrue(not read.individual)
    assertEquals(TCShowAnimals.readTrailer({ rootNode = {} }), nil)
end)

test("with RL each animal is its own record, keyed by country, herd and id whatever order it's in", function()
    setup(rlEnv(true))
    assertTrue(TCRealisticLivestock.isLoaded(), "RL loaded")
    local daisy = rlAnimal({ uniqueId = "1203", name = "Daisy", breed = "HOLSTEIN", isPregnant = true,
        genetics = { quality = 1.4, health = 1.1, productivity = 0.9, metabolism = 1.0, fertility = 1.2 } })
    local bella = rlAnimal({ uniqueId = "1207", name = "Bella", breed = "HOLSTEIN", sick = true,
        genetics = { quality = 0.8, health = 1.0, metabolism = 1.0, fertility = 1.0 } })
    local read = TCShowAnimals.readTrailer(newTrailer({ daisy, bella }))
    assertEquals(read.count, 2)
    assertTrue(read.individual, "individual")
    local first = read.entries[1].animal
    assertEquals(first.key, "7 482913 1203")
    assertEquals(first.herdId, "482913")
    assertEquals(first.uniqueId, "1203")
    assertEquals(first.name, "Daisy")
    assertEquals(first.breed, "HOLSTEIN")
    assertEquals(first.gender, "female")
    assertEquals(first.weight, 610)
    assertEquals(first.targetWeight, 650)
    assertEquals(first.genetics.quality, 1.4)
    assertEquals(first.genetics.fertility, 1.2)
    assertTrue(first.isPregnant, "pregnant")
    assertTrue(first.isSick == false, "Daisy's well")
    local second = read.entries[2].animal
    assertEquals(second.genetics.productivity, nil, "no productivity for a beef animal")
    assertTrue(second.isSick, "Bella's sick")

    local again = TCShowAnimals.readTrailer(newTrailer({ bella, daisy }))
    assertEquals(again.entries[2].animal.key, first.key, "the key doesn't depend on the order")
end)

test("RL without its disease check: the rest is read, sickness is unknown and it's warned about once", function()
    local world = setup(rlEnv(false))
    local animal = rlAnimal({ uniqueId = "9", name = "Flo", genetics = { quality = 1 }, sick = true })
    local read = TCShowAnimals.readTrailer(newTrailer({ animal }))
    assertEquals(read.entries[1].animal.isSick, nil, "sickness unknown")
    assertEquals(read.entries[1].animal.name, "Flo")
    assertEquals(#world.warnings, 1, "one warning")
    TCRealisticLivestock.detect()
    assertEquals(#world.warnings, 1, "still one warning")
end)

test("an RL animal missing fields RL may rename is still read, with those left out", function()
    setup(rlEnv(true))
    local animal = rlAnimal({ uniqueId = "12" })
    animal.farmId = nil
    animal.birthday = nil
    animal.breed = 5
    animal.genetics = "bad"
    local read = TCShowAnimals.readTrailer(newTrailer({ animal }))
    local record = read.entries[1].animal
    assertEquals(record.key, "0 - 12")
    assertEquals(record.breed, nil)
    assertEquals(record.genetics.quality, nil)
    assertTrue(read.individual)
end)

test("a vanilla cluster in an RL game (not yet converted) is read as a group", function()
    setup(rlEnv(true))
    local read = TCShowAnimals.readTrailer(newTrailer({ rlAnimal({ uniqueId = "1" }), vanillaCluster(1, 2, 10, 90) }))
    assertEquals(read.count, 3)
    assertTrue(not read.individual, "not all individuals")
    assertEquals(read.entries[2].animal, nil)
end)

test("the trailer meant: the one you're in, the one you're towing, or the nearest within reach", function()
    setup(nil)
    local near = newTrailer({}, { x = 10, z = 0 })
    local nearer = newTrailer({}, { x = 4, z = 3 })
    local far = newTrailer({}, { x = 100, z = 0 })
    local trailers = { near, nearer, far }
    assertTrue(TCShowAnimals.findTrailer(near, 500, 500, trailers) == near, "in it")
    local tractor = {
        getChildVehicles = function()
            return { far }
        end,
    }
    assertTrue(TCShowAnimals.findTrailer(tractor, 0, 0, trailers) == far, "towing it")
    assertTrue(TCShowAnimals.findTrailer(nil, 0, 0, trailers) == nearer, "the nearest")
    assertEquals(TCShowAnimals.findTrailer(nil, 60, 0, trailers), nil, "none in reach")
    assertEquals(TCShowAnimals.findTrailer(nil, nil, nil, trailers), nil, "nowhere to look from")
end)

-- 164's showground, as tests/test_showScene.lua makes it.
local function makeScene(angle, dressing)
    local rect = { cx = 100, cz = 50, angle = angle or 0, halfU = 60, halfV = 30 }
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local entrance = { x = rect.cx + cosA * (rect.halfU + 10), z = rect.cz + sinA * (rect.halfU + 10) }
    local layout = TCAuctionLayout.layOutOpenRect(rect, entrance)
    local scene = TCAuctionLayout.getScene(layout, entrance, 99)
    scene.dressing = dressing or "show"
    return scene
end

-- A bay's middle in world space, from the scene's areas.
local function bayMiddle(scene, bay)
    local lines = TCShowScene.getAreas(scene).lines
    local d = (lines.dFrom + lines.dTo) * 0.5
    local v = lines.vFrom + (bay - 0.5) * lines.bayWidth
    local u = scene.nearEdge - scene.nearSign * d
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    return scene.cx + u * cosA - v * sinA, scene.cz + u * sinA + v * cosA
end

test("the trailer lines: each bay's middle is that bay, the ring and outside are none, turned or not", function()
    setup(nil)
    for _, angle in ipairs({ 0, 0.7, math.pi }) do
        local scene = makeScene(angle)
        local lines = TCShowScene.getAreas(scene).lines
        assertTrue(lines ~= nil and lines.count >= 2, "lines laid out")
        for bay = 1, lines.count do
            local x, z = bayMiddle(scene, bay)
            assertEquals(TCShowScene.findBay(scene, x, z), bay, "bay " .. bay .. " at angle " .. angle)
        end
        assertEquals(TCShowScene.findBay(scene, scene.cx, scene.cz), nil, "the middle of the showground")
        assertEquals(TCShowScene.findBay(scene, scene.cx + 500, scene.cz), nil, "far away")
    end
end)

test("where a trailer stands: its bay on a show's ground only, hitched or not, moving or not", function()
    setup(nil)
    local scene = makeScene(0)
    local x, z = bayMiddle(scene, 2)
    local trailer = newTrailer({}, { x = x, z = z, farmId = 3, speed = 4, attacher = {} })
    local standing = TCShowAnimals.getStanding(trailer, scene)
    assertEquals(standing.bay, 2)
    assertEquals(standing.farmId, 3)
    assertEquals(standing.speed, 4)
    assertTrue(standing.isHitched, "hitched")
    assertEquals(TCShowAnimals.getStanding(trailer, makeScene(0, "auction")).bay, nil, "an auction's ground")
    assertEquals(TCShowAnimals.getStanding(trailer, nil).bay, nil, "no ground")
    assertTrue(not TCShowAnimals.getStanding(newTrailer({}), scene).isHitched, "unhitched")
end)
