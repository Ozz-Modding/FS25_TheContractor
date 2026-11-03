-- 099: the Logbook shows only what the player knows about an ADS vehicle.
-- Its condition is the last inspection's (getLastInspectedCondition, shown
-- through ADS_Utils.formatCondition), and only faults found (isVisible)
-- are listed. ADS's live condition and hidden faults never reach a
-- snapshot, its stream or its save. Which job caused a fault isn't told.

local function setup(withUtils)
    local world = stubs.install()
    -- ADS's environment, as getModEnv finds it. formatCondition stands in
    -- for ADS's own: a percentage only after a complete inspection.
    -- world.formatted records what it was asked to show.
    world.adsEnv = {}
    world.formatted = {}
    if withUtils ~= false then
        world.adsEnv.ADS_Utils = {
            formatCondition = function(value, isExact)
                table.insert(world.formatted, { value = value, isExact = isExact })
                if value == nil then
                    return "ADS unknown"
                end
                return isExact and string.format("%d%%", math.floor(value * 100 + 0.5)) or "Good"
            end,
        }
    end
    TheContractorDrivers = {
        getModEnv = function()
            return world.adsEnv
        end,
    }
    dofile("src/util/TCVehicleCondition.lua")
    return world
end

-- An ADS vehicle: a live condition, faults (some hidden), and what its
-- last inspection found.
local function adsVehicle(def)
    local vehicle = {
        spec_wearable = {},
        spec_AdvancedDamageSystem = {},
        breakdowns = def.breakdowns or {},
    }
    function vehicle:getWearTotalAmount() return 0.2 end
    function vehicle:getOperatingTime() return 3600000 * 10 end
    function vehicle:getConditionLevel() return def.liveCondition or 0.31 end
    function vehicle:getActiveBreakdowns() return self.breakdowns end
    if def.inspected ~= false then
        function vehicle:getLastInspectedCondition()
            return def.known, def.isExact == true, def.isStale == true
        end
    end
    return vehicle
end

local MODEL = function()
    return TCVehicleCondition.MODEL
end

test("capture: the last inspection's condition, never the live one", function()
    setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ liveCondition = 0.31, known = 0.8, isExact = true }))
    assertEquals(snapshot.model, MODEL().ADS)
    assertEquals(snapshot.knownCondition, 0.8)
    assertEquals(snapshot.conditionExact, true)
    assertEquals(snapshot.conditionStale, false)
    assertEquals(snapshot.condition, nil, "the live condition isn't recorded")
end)

test("capture: only faults found are recorded", function()
    setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ known = 0.8, breakdowns = {
        HYDRAULIC_LEAK = { isVisible = true, breakdownProgress = 0.4 },
        BEARING_WEAR = { isVisible = false, breakdownProgress = 0.2 },
        RADIATOR_CLOG = { breakdownProgress = 0.1 },
    } }))
    assertEquals(#snapshot.faults, 1)
    assertEquals(snapshot.faults[1].id, "HYDRAULIC_LEAK")
    assertEquals(snapshot.faults[1].stage, nil)
end)

test("display: ADS's own text, from the inspection's figure and whether it was complete", function()
    local world = setup()
    local partial = TCVehicleCondition.capture(adsVehicle({ liveCondition = 0.31, known = 0.8, isExact = false }))
    TCVehicleCondition.formatKnownCondition(partial)
    local complete = TCVehicleCondition.capture(adsVehicle({ liveCondition = 0.31, known = 0.8, isExact = true }))
    assertEquals(TCVehicleCondition.getHeadline(complete), TCVehicleCondition.formatKnownCondition(complete),
        "the chip shows the same")
    assertEquals(world.formatted[1].value, 0.8, "the known condition, never the live one")
    assertEquals(world.formatted[1].isExact, false)
    assertEquals(world.formatted[2].value, 0.8)
    assertEquals(world.formatted[2].isExact, true)
end)

test("display: never inspected is ADS's unknown, and the chip's neutral", function()
    local world = setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ known = nil }))
    assertEquals(snapshot.knownCondition, nil)
    TCVehicleCondition.formatKnownCondition(snapshot)
    assertEquals(world.formatted[1].value, nil, "ADS words an unknown condition")
    assertEquals(TCVehicleCondition.getTone(snapshot), "neutral")

    -- An older ADS without getLastInspectedCondition reads the same.
    local old = TCVehicleCondition.capture(adsVehicle({ inspected = false }))
    assertEquals(old.knownCondition, nil)
end)

test("display: an outdated inspection is marked", function()
    setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ known = 0.8, isExact = true, isStale = true }))
    local fresh = TCVehicleCondition.capture(adsVehicle({ known = 0.8, isExact = true }))
    assertTrue(TCVehicleCondition.formatKnownCondition(snapshot) ~= TCVehicleCondition.formatKnownCondition(fresh),
        "marked")
    assertEquals(TCVehicleCondition.getHeadline(snapshot), TCVehicleCondition.getHeadline(fresh),
        "the chip has no room for it")
end)

test("display without ADS on this machine: a percentage only if exact", function()
    local world = setup(false)
    world.adsEnv = nil
    dofile("src/util/TCVehicleCondition.lua")
    local exact = TCVehicleCondition.formatKnownCondition({ model = MODEL().ADS, knownCondition = 0.8,
        conditionExact = true })
    local inexact = TCVehicleCondition.formatKnownCondition({ model = MODEL().ADS, knownCondition = 0.8,
        conditionExact = false })
    local never = TCVehicleCondition.formatKnownCondition({ model = MODEL().ADS })
    assertEquals(inexact, never, "an incomplete inspection reads as unknown")
    assertTrue(exact ~= never, "a complete one shows its figure")
end)

test("tone: by the known condition, bad with a fault found, hidden ones don't count", function()
    setup()
    assertEquals(TCVehicleCondition.getTone(TCVehicleCondition.capture(adsVehicle({ known = 0.9 }))), "good")
    assertEquals(TCVehicleCondition.getTone(TCVehicleCondition.capture(adsVehicle({ known = 0.9,
        breakdowns = { BEARING_WEAR = { isVisible = false } } }))), "good")
    assertEquals(TCVehicleCondition.getTone(TCVehicleCondition.capture(adsVehicle({ known = 0.9,
        breakdowns = { BEARING_WEAR = { isVisible = true } } }))), "bad")
end)

test("change rows: one condition unless inspected in between, and faults found", function()
    setup()
    local before = { model = MODEL().ADS, knownCondition = 0.8, conditionExact = false, wear = 0.1,
        faults = { { id = "OLD_FAULT" } } }
    local after = { model = MODEL().ADS, knownCondition = 0.8, conditionExact = false, wear = 0.2,
        faults = { { id = "OLD_FAULT" }, { id = "HYDRAULIC_LEAK" } } }
    local rows = TCVehicleCondition.getChangeRows(before, after)
    assertEquals(#rows, 3, "condition, paint wear and the one new fault")
    assertEquals(rows[1].value, TCVehicleCondition.formatKnownCondition(after), "one condition, no change")
    assertEquals(rows[3].value, TCVehicleCondition.getFaultName("HYDRAULIC_LEAK"), "only the new fault")
    assertEquals(rows[3].tone, "bad")

    -- A complete inspection in between.
    after.conditionExact = true
    assertTrue(TCVehicleCondition.getChangeRows(before, after)[1].value ~= TCVehicleCondition.formatKnownCondition(after),
        "shown as a change")
end)

test("known faults are listed by name, hidden ones left out; none for vanilla", function()
    setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ known = 0.8, breakdowns = {
        HYDRAULIC_LEAK = { isVisible = true },
        ENGINE_KNOCK = { isVisible = true },
        BEARING_WEAR = { isVisible = false },
    } }))
    local names = TCVehicleCondition.getKnownFaultNames(snapshot)
    assertEquals(#names, 2)
    assertEquals(names[1], TCVehicleCondition.getFaultName("ENGINE_KNOCK"))
    assertEquals(names[2], TCVehicleCondition.getFaultName("HYDRAULIC_LEAK"))
    assertEquals(#TCVehicleCondition.getStateRows(snapshot), 2, "condition and paint wear")
    assertEquals(TCVehicleCondition.getKnownFaultNames({ model = MODEL().VANILLA, damage = 0 }), nil)
end)

-- 099: the player can't know what an ADS
-- vehicle's wear costs, so it has none and the Logbook shows none.
test("an ADS vehicle's wear has no cost and isn't shown", function()
    setup()
    local vehicle = adsVehicle({ known = 0.8 })
    vehicle.getADSRepairEstimate = function() return { totalPrice = 5000 } end
    local before = { model = MODEL().ADS, wear = 0, faults = {} }
    local after = { model = MODEL().ADS, wear = 0, faults = { { id = "HYDRAULIC_LEAK" } } }
    assertEquals(TCVehicleCondition.getWearCost(vehicle, before, after), 0)
    assertEquals(TCVehicleCondition.hasWearCost(before, after), false)
    assertEquals(TCVehicleCondition.hasWearCost(after), false, "the vehicle page's one snapshot")
    assertEquals(TCVehicleCondition.hasWearCost({ model = MODEL().VANILLA }, after), false,
        "a vehicle that gained ADS during the job")

    local vanilla = { model = MODEL().VANILLA, damage = 0, wear = 0, repairPrice = 100 }
    assertEquals(TCVehicleCondition.hasWearCost(vanilla, vanilla), true)
    assertEquals(TCVehicleCondition.hasWearCost(vanilla), true)
    assertEquals(TCVehicleCondition.hasWearCost(nil, nil), true, "no snapshot is shown as before")
end)

test("a job counts which machines have a wear cost", function()
    setup()
    TheContractorLogbook = nil
    dofile("src/business/Logbook.lua")
    local ads = { model = MODEL().ADS, wear = 0, faults = {} }
    local vanilla = { model = MODEL().VANILLA, damage = 0, wear = 0, repairPrice = 0 }
    local function job(...)
        return { price = 1000, fuelCost = 100, wearCost = 50, equipment = { ... } }
    end
    local adsMachine = { startSnapshot = ads, endSnapshot = ads }
    local vanillaMachine = { startSnapshot = vanilla, endSnapshot = vanilla, wearCost = 50 }

    local priced, unpriced = TheContractorLogbook.countWearCosts(job(adsMachine, adsMachine))
    assertEquals(priced, 0)
    assertEquals(unpriced, 2)
    priced, unpriced = TheContractorLogbook.countWearCosts(job(adsMachine, vanillaMachine))
    assertEquals(priced, 1)
    assertEquals(unpriced, 1)
    priced, unpriced = TheContractorLogbook.countWearCosts(job())
    assertEquals(priced, 0)
    assertEquals(unpriced, 0)
    assertEquals(TheContractorLogbook.getMargin(job(adsMachine, vanillaMachine)), 850,
        "the margin takes off only the wear that has a cost")
end)

test("stream and save carry the known values, and nothing more", function()
    local world = setup()
    local snapshot = TCVehicleCondition.capture(adsVehicle({ known = 0.7, isExact = true, isStale = true,
        breakdowns = { HYDRAULIC_LEAK = { isVisible = true }, BEARING_WEAR = { isVisible = false } } }))

    local stream = world:newStream()
    TCVehicleCondition.writeStream(stream, snapshot)
    local copy = TCVehicleCondition.readStream(stream)
    assertEquals(copy.knownCondition, 0.7)
    assertEquals(copy.conditionExact, true)
    assertEquals(copy.conditionStale, true)
    assertEquals(#copy.faults, 1)
    assertEquals(stream.position, #stream.values, "everything written was read")

    local never = TCVehicleCondition.capture(adsVehicle({ known = nil }))
    stream = world:newStream()
    TCVehicleCondition.writeStream(stream, never)
    assertEquals(TCVehicleCondition.readStream(stream).knownCondition, nil)

    local xmlFile = {}
    TCVehicleCondition.saveToXML(xmlFile, "s", snapshot)
    assertEquals(xmlFile["s#condition"], nil)
    assertEquals(xmlFile["s#knownFaults"], "HYDRAULIC_LEAK")
    local loaded = TCVehicleCondition.loadFromXML(xmlFile, "s")
    assertEquals(loaded.knownCondition, 0.7)
    assertEquals(loaded.conditionExact, true)
    assertEquals(loaded.conditionStale, true)
    assertEquals(loaded.faults[1].id, "HYDRAULIC_LEAK")
end)

test("a pre-099 save's live condition and hidden faults are ignored", function()
    setup()
    local xmlFile = { ["s#model"] = MODEL().ADS, ["s#wear"] = 0.1, ["s#hours"] = 3,
        ["s#condition"] = 0.42, ["s#faults"] = "BEARING_WEAR:2;HYDRAULIC_LEAK:1" }
    local loaded = TCVehicleCondition.loadFromXML(xmlFile, "s")
    assertEquals(loaded.knownCondition, nil)
    assertEquals(#loaded.faults, 0)
end)

test("the logbook counts a fault found in use, not one a job caused", function()
    setup()
    TheContractorLogbook = nil
    dofile("src/business/Logbook.lua")
    local start = { model = MODEL().ADS, wear = 0, faults = {} }
    local caused = { startSnapshot = start, endSnapshot = { model = MODEL().ADS, wear = 0, faults = {} },
        faultCaused = true }
    local found = { startSnapshot = start,
        endSnapshot = { model = MODEL().ADS, wear = 0, faults = { { id = "HYDRAULIC_LEAK" } } } }
    assertEquals(TheContractorLogbook.hasFoundFault(caused), false)
    assertEquals(TheContractorLogbook.hasFoundFault(found), true)
end)

test("the completion notice doesn't name a machine a worker left a fault on", function()
    local world = setup()
    dofile("src/util/TCJobConsequences.lua")
    g_currentMission.TheContractor = { Staff = { getWorker = function() return { name = "Ann" } end } }
    local lines = TCJobConsequences.getReportLines({ farmId = 1, workerReports = {
        { workerId = 1, wash = 0, extraWear = {}, breakdowns = { "Fendt 942 Vario" } },
    } })
    assertEquals(#lines, 0)
end)
