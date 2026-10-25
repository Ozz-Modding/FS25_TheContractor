-- TCVehicleCondition.getDeltas (060): how much worse a vehicle got over one
-- use, for the logbook's one-line history (damage and paint wear).

local function setup()
    stubs.install()
    dofile("src/util/TCVehicleCondition.lua")
    return TCVehicleCondition.MODEL
end

test("vanilla: damage and paint wear rises", function()
    local MODEL = setup()
    local damage, wear = TCVehicleCondition.getDeltas({ model = MODEL.VANILLA, damage = 0.11, wear = 0.44 },
        { model = MODEL.VANILLA, damage = 0.14, wear = 0.45 })
    assertNear(damage, 0.03, 1e-9)
    assertNear(wear, 0.01, 1e-9)
end)

test("ADS: no damage figure (099: only inspections reveal condition), paint wear still", function()
    local MODEL = setup()
    local damage, wear = TCVehicleCondition.getDeltas({ model = MODEL.ADS, knownCondition = 0.9, wear = 0.1 },
        { model = MODEL.ADS, knownCondition = 0.85, wear = 0.12 })
    assertEquals(damage, nil)
    assertNear(wear, 0.02, 1e-9)
end)

test("nothing to compare: a missing snapshot or a change of model", function()
    local MODEL = setup()
    local after = { model = MODEL.VANILLA, damage = 0.1, wear = 0.1 }
    assertEquals(TCVehicleCondition.getDeltas(nil, after), nil)
    assertEquals(TCVehicleCondition.getDeltas({ model = MODEL.ADS, condition = 1, wear = 0 }, after), nil)
end)
