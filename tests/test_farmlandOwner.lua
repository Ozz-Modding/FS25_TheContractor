-- Field info's "Owned by": vanilla reads farmland:getNPC().title, which
-- names the farmer holding the land, or the map's NPC when none does.

local function setup()
    local world = stubs.install()
    world.holders = {}
    g_currentMission.TheContractor.Farmers = {
        getHolder = function(_, farmlandId)
            return world.holders[farmlandId]
        end,
    }

    world.npc = { title = "Mia", imageFilename = "mia.dds" }
    Farmland = {
        getNPC = function(self)
            return self.npc
        end,
        getId = function(self)
            return self.id
        end,
    }
    world:load("src/util/TCFarmlandOwner.lua")

    function world:addFarmland(id, npc)
        return setmetatable({ id = id, npc = npc }, { __index = Farmland })
    end
    return world
end

test("land a farmer holds is owned by the farmer, with the NPC's other fields", function()
    local world = setup()
    local farmland = world:addFarmland(8, world.npc)
    world.holders[8] = { id = 3, name = "Ted Barker" }

    local npc = farmland:getNPC()
    assertEquals("Ted Barker", npc.title)
    assertEquals("mia.dds", npc.imageFilename)
    assertEquals("Mia", world.npc.title)
end)

test("land no farmer holds keeps the NPC", function()
    local world = setup()
    local farmland = world:addFarmland(8, world.npc)

    assertEquals(world.npc, farmland:getNPC())
end)

test("one NPC's land held by two farmers names each, and a rename shows", function()
    local world = setup()
    local first = world:addFarmland(8, world.npc)
    local second = world:addFarmland(9, world.npc)
    world.holders[8] = { id = 3, name = "Ted Barker" }
    world.holders[9] = { id = 4, name = "Ann Hale" }

    assertEquals("Ted Barker", first:getNPC().title)
    assertEquals("Ann Hale", second:getNPC().title)

    world.holders[8].name = "Ted Walker"
    assertEquals("Ted Walker", first:getNPC().title)
end)

test("land the map gave no NPC still names its farmer", function()
    local world = setup()
    local farmland = world:addFarmland(8, nil)
    world.holders[8] = { id = 3, name = "Ted Barker" }

    assertEquals("Ted Barker", farmland:getNPC().title)
end)

test("before the farmers exist the NPC is untouched", function()
    local world = setup()
    g_currentMission.TheContractor.Farmers = nil
    local farmland = world:addFarmland(8, world.npc)

    assertEquals(world.npc, farmland:getNPC())
end)
