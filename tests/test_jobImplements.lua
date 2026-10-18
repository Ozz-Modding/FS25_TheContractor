-- TCEquipmentClass.isJobImplement against the real JOB_TYPES: which
-- implements count for a job. A plow with a packer carries spec_cultivator
-- (vanilla's PlowPacker needs both Plow and Cultivator), but it plows, so
-- it's a plow job's implement and never a cultivate job's.

local function setup()
    local world = stubs.install()
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    return world
end

local function jobDef(jobType)
    return TheContractorJobGeneration.JOB_TYPES[jobType]
end

local cultivator = { spec_cultivator = {} }
local plow = { spec_plow = {} }
local plowPacker = { spec_plow = {}, spec_cultivator = {} }

test("a cultivator does a cultivate job", function()
    setup()
    assertTrue(TCEquipmentClass.isJobImplement(cultivator, jobDef("cultivate")), "cultivator")
    assertEquals(TCEquipmentClass.getJobRole(cultivator, jobDef("cultivate")), "implement")
end)

test("a plow, with or without a packer, doesn't do a cultivate job", function()
    setup()
    assertTrue(not TCEquipmentClass.isJobImplement(plow, jobDef("cultivate")), "plain plow")
    assertTrue(not TCEquipmentClass.isJobImplement(plowPacker, jobDef("cultivate")), "plow with packer")
    assertEquals(TCEquipmentClass.getJobRole(plowPacker, jobDef("cultivate")), nil)
    assertEquals(TCEquipmentClass.getMissingEquipment({ plowPacker }, jobDef("cultivate"))[1], "implement")
end)

test("a plow with a packer still does a plow job", function()
    setup()
    assertTrue(TCEquipmentClass.isJobImplement(plowPacker, jobDef("plow")), "plow with packer")
    assertTrue(TCEquipmentClass.isJobImplement(plow, jobDef("plow")), "plain plow")
    assertTrue(not TCEquipmentClass.isJobImplement(cultivator, jobDef("plow")), "cultivator")
end)
