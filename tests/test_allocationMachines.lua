-- TheContractorAllocation.hasDoubledMachines (035 follow-up): one worker
-- drives one of each, so the server refuses two tractors or harvesters in
-- the field equipment, or two tractors or trailers in a haulage rig.

local function setup()
    stubs.install()
    Class = Class or function()
        return {}
    end
    -- Vehicles here say what they are; the real classifier reads store
    -- categories and specs.
    TCEquipmentClass = {
        isTractor = function(vehicle)
            return vehicle.kind == "tractor"
        end,
        isHarvester = function(vehicle)
            return vehicle.kind == "harvester"
        end,
        isTrailerFor = function(vehicle, fillTypeIndex)
            return vehicle.kind == "trailer" and vehicle.fillTypeIndex == fillTypeIndex
        end,
    }
    dofile("src/business/Allocation.lua")
end

local WHEAT = 7
local tractor = { kind = "tractor" }
local tractor2 = { kind = "tractor" }
local combine = { kind = "harvester" }
local combine2 = { kind = "harvester" }
local header = { kind = "header" }
local trailer = { kind = "trailer", fillTypeIndex = WHEAT }
local trailer2 = { kind = "trailer", fillTypeIndex = WHEAT }

test("a combine and header with a tractor and trailer to haul is fine", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ combine, header }, { tractor, trailer }, WHEAT), false)
end)

test("a plain job with no haulage rig is fine", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ tractor, header }, {}, nil), false)
end)

test("two haul tractors are refused", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ combine, header }, { tractor, tractor2, trailer },
        WHEAT), true)
end)

test("two trailers are refused", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ combine, header }, { tractor, trailer, trailer2 },
        WHEAT), true)
end)

test("two field tractors or two combines are refused", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ tractor, tractor2 }, {}, nil), true)
    assertEquals(TheContractorAllocation.hasDoubledMachines({ combine, combine2, header }, {}, WHEAT), true)
end)

test("the field tractor and the haul tractor are counted separately", function()
    setup()
    assertEquals(TheContractorAllocation.hasDoubledMachines({ tractor, combine }, { tractor2, trailer }, WHEAT), false)
end)
