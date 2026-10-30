-- TCADSStock (064): FS25_AdvancedDamageSystem's workshop stock, read
-- through ADS's own classifier and parts box functions, and hiding only
-- what needs an ADS function that isn't there.
--
-- The fake ADS below follows refs/FS25_AdvancedDamageSystem (0.10.0.0):
-- ADS_PlayerWorkshop.collectStockSources(object, list) appends
-- { kind, key, tier, grade, amount, fillUnitIndex, fillTypeIndex } entries
-- (a drum pallet's opened drum and full ones as two entries from one fill
-- unit), ADS_SparePartsBox.isBox/getState/isReserved/isUsed, and (103)
-- ADS_ConsumablePack.isPack/isGrippable/getPartState for old batteries and
-- air filters, checked at ADS 0.10.0.8.

local MOD = "FS25_AdvancedDamageSystem"

-- The fake ADS env: each object's `adsSources` is what the classifier
-- reports for it, `adsBox` its box state, `adsReserved` its reservation,
-- `adsPack` a pack's part state and `adsPallet` a pack that's a pallet.
local function newADSEnv()
    return {
        ADS_PlayerWorkshop = {
            STOCK_KINDS = { FLUID = "fluid", GREASE = "grease", PACK = "pack" },
            collectStockSources = function(object, list)
                for _, source in ipairs(object.adsSources or {}) do
                    local copy = {}
                    for k, v in pairs(source) do
                        copy[k] = v
                    end
                    copy.object = object
                    table.insert(list, copy)
                end
            end,
        },
        ADS_SparePartsBox = {
            isBox = function(object)
                return object.adsBox ~= nil
            end,
            getState = function(object)
                return object.adsBox
            end,
            isReserved = function(object)
                return object.adsReserved == true
            end,
            -- ADS's own rule: the removal flag, the legacy USED tier, or
            -- carried wear or stress.
            isUsed = function(object)
                local state = object.adsBox
                return state.isUsed == true or state.tier == "USED" or (state.resource or 1) < 1 or
                    (state.stress or 0) > 0
            end,
        },
        ADS_ConsumablePack = {
            isPack = function(object)
                return object.adsPack ~= nil and not object.isDeleted
            end,
            isGrippable = function(object)
                return object.adsPack ~= nil and not object.adsPallet
            end,
            getPartState = function(object)
                return object.adsPack
            end,
        },
    }
end

local function setup(env)
    local world = stubs.install()
    world.adsEnv = env
    TheContractorDrivers = {
        getModEnv = function(modName)
            assertEquals(modName, MOD, "mod name")
            return world.adsEnv
        end,
    }
    world:load("src/util/TCADSStock.lua")
    world.modTexts[MOD] = {
        ads_ws_quality_premium = "Premium",
        ads_spec_part_types_oem = "OEM",
    }
    world.oil = world:addFillType("ADS_MOTOR_OIL_PREMIUM", "ADS Motor Oil Premium")
    world.grease = world:addFillType("ADS_GREASE_ORIGINAL", "Original grease", "g")
    return world
end

local function addItem(world, def)
    local object = world:addVehicle({ name = def.name, farmId = def.farmId, isPallet = true,
        fillUnits = def.fillUnits })
    object.adsSources = def.sources
    object.adsBox = def.box
    object.adsReserved = def.reserved
    object.adsPack = def.pack
    object.adsPallet = def.isPallet
    return object
end

local function addOilDrums(world, def)
    -- A 400 l pallet of two drums, one opened: two entries, one fill unit.
    return addItem(world, { name = "Motor Oil Drum (Premium)", farmId = def.farmId,
        fillUnits = { { capacity = 400, level = 350, fillType = world.oil } },
        sources = {
            { kind = "fluid", key = "motorOil", tier = "PREMIUM", amount = 150, fillUnitIndex = 1,
                fillTypeIndex = world.oil },
            { kind = "fluid", key = "motorOil", tier = "PREMIUM", amount = 200, fillUnitIndex = 1,
                fillTypeIndex = world.oil },
        } })
end

local function addBatteries(world, count, tier)
    return addItem(world, { name = "Battery", sources = {
        { kind = "pack", key = "battery", tier = tier, grade = "L", amount = count },
    } })
end

local function addBox(world, def)
    return addItem(world, { name = def.name or "Hydraulic pump", farmId = def.farmId, reserved = def.reserved,
        box = { componentId = def.componentId or "hydraulicPump", tier = def.tier or "OEM",
            vehicleName = def.vehicleName or "Fendt 942", isPreview = def.isPreview or false,
            isUsed = def.isUsed, resource = def.resource } })
end

-- A single loose battery (or a pallet of them), with its part state.
local function addBattery(world, def)
    local state = { targetId = "battery", grade = "L", quality = "ORIGINAL", health = def.health or 1,
        clogging = def.clogging }
    return addItem(world, { name = "Battery", pack = state, isPallet = def.isPallet, sources = {
        { kind = "pack", key = "battery", tier = "ORIGINAL", grade = "L", amount = def.count or 1 },
    } })
end

test("without ADS nothing is offered and nothing is logged", function()
    local world = setup(nil)
    TCADSStock.detect()
    assertTrue(not TCADSStock.isAvailable(), "available")
    assertTrue(not TCADSStock.hasConsumables(), "consumables")
    assertTrue(not TCADSStock.hasPartsBoxes(), "parts boxes")
    assertEquals(#TCADSStock.getConsumableRows(1), 0, "consumable rows")
    assertEquals(#TCADSStock.getPartBoxRows(1), 0, "part rows")
    assertEquals(#world.warnings, 0, "warnings")
end)

test("with the whole API every view is offered", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    assertTrue(TCADSStock.hasConsumables(), "consumables")
    assertTrue(TCADSStock.hasPartsBoxes(), "parts boxes")
    assertTrue(TCADSStock.hasReservations(), "reservations")
    assertEquals(#world.warnings, 0, "warnings")
end)

test("consumables group by kind/key/tier, fluids counting a fill unit's room once", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    addOilDrums(world, {})
    addOilDrums(world, {})
    addOilDrums(world, { farmId = 2 })
    addBatteries(world, 4, "PREMIUM")
    addBatteries(world, 2, "PREMIUM")
    addBatteries(world, 3, "LIZARD")
    addItem(world, { name = "Grease box", fillUnits = { { capacity = 4000, level = 1000, fillType = world.grease } },
        sources = { { kind = "grease", key = "grease", tier = "ORIGINAL", amount = 1000, fillUnitIndex = 1,
            fillTypeIndex = world.grease } } })
    -- A tractor: the classifier reports nothing for it.
    world:addVehicle({ name = "Tractor", dieselUsagePerHour = 40 })

    local rows = TCADSStock.getConsumableRows(1)
    assertEquals(#rows, 4, "rows")

    local oil = rows[1]
    assertEquals(oil.fillTypeIndex, world.oil, "the oil")
    assertEquals(oil.amount, 700, "oil amount")
    assertEquals(oil.capacity, 800, "oil capacity, once per drum pallet")
    assertEquals(#oil.sources, 2, "oil sources")
    assertEquals(oil.sources[1].capacity, 400, "source capacity")

    assertEquals(rows[2].fillTypeIndex, world.grease, "grease after fluids")
    assertEquals(rows[2].capacity, 4000, "grease capacity")

    assertEquals(rows[3].kind, "pack", "packs after them")
    assertEquals(rows[3].amount, 3, "lizard batteries, a row of their own")
    assertEquals(rows[4].kind, "pack")
    assertEquals(rows[4].amount, 6, "premium batteries, both pallets")
    assertEquals(rows[4].capacity, nil, "packs are counts")
end)

test("spare parts boxes group by part and tier, without ADS's free samples", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    addBox(world, { vehicleName = "Fendt 942" })
    addBox(world, { vehicleName = "Fendt 942", reserved = true })
    addBox(world, { vehicleName = "Claas Axion" })
    addBox(world, { tier = "USED" })
    addBox(world, { isPreview = true })
    addBox(world, { farmId = 2 })

    local rows = TCADSStock.getPartBoxRows(1)
    assertEquals(#rows, 2, "rows")
    local oem = rows[1].tierText == "OEM" and rows[1] or rows[2]
    local used = rows[1].tierText == "OEM" and rows[2] or rows[1]
    assertEquals(oem.count, 3, "OEM boxes")
    assertEquals(oem.reserved, 1, "reserved")
    assertEquals(#oem.fits, 2, "fits")
    assertEquals(oem.fits[1].vehicleName, "Claas Axion", "fits sorted")
    assertEquals(oem.fits[2].count, 2, "Fendt boxes")
    assertEquals(used.tierText, "USED", "raw tier without an ADS text")
    assertEquals(used.count, 1, "used boxes")
    assertTrue(used.isUsed and not oem.isUsed, "the legacy USED tier counts as used")
end)

test("a part a replacement took off has a row of its own, after the new ones", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    addBox(world, {})
    addBox(world, { isUsed = true, vehicleName = "Customer's Deutz" })
    addBox(world, { resource = 0.4 })

    local rows = TCADSStock.getPartBoxRows(1)
    assertEquals(#rows, 2, "new and used rows of the same part and tier")
    assertTrue(not rows[1].isUsed, "new first")
    assertEquals(rows[1].count, 1, "new boxes")
    assertTrue(rows[2].isUsed, "then used")
    assertEquals(rows[2].count, 2, "used boxes: the removal flag or carried wear")
    assertEquals(rows[2].tierText, "OEM", "same tier text")
    assertTrue(rows[1].key ~= rows[2].key, "keys differ")
end)

test("old batteries and air filters have rows of their own; a pallet of packs is new", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    addBattery(world, {})
    addBattery(world, { isPallet = true, count = 4 })
    addBattery(world, { health = 0.3 })
    addBattery(world, { clogging = 0.2 })

    local rows = TCADSStock.getConsumableRows(1)
    assertEquals(#rows, 2, "rows")
    assertTrue(not rows[1].isUsed, "new first")
    assertEquals(rows[1].amount, 5, "a loose new one and a pallet of four")
    assertTrue(rows[2].isUsed, "then used")
    assertEquals(rows[2].amount, 2, "worn health or clogging")
end)

test("isUsedPart: used boxes and worn loose packs, never samples, new parts or other machines", function()
    local world = setup(newADSEnv())
    TCADSStock.detect()
    assertTrue(TCADSStock.isUsedPart(addBox(world, { isUsed = true })), "used box")
    assertTrue(not TCADSStock.isUsedPart(addBox(world, {})), "new box")
    assertTrue(not TCADSStock.isUsedPart(addBox(world, { isUsed = true, isPreview = true })), "ADS's sample")
    assertTrue(TCADSStock.isUsedPart(addBattery(world, { health = 0.9 })), "worn battery")
    assertTrue(not TCADSStock.isUsedPart(addBattery(world, {})), "new battery")
    assertTrue(not TCADSStock.isUsedPart(addBattery(world, { health = 0.5, isPallet = true })), "pallet")
    assertTrue(not TCADSStock.isUsedPart(world:addVehicle({ name = "Tractor" })), "a tractor")
    local gone = addBox(world, { isUsed = true })
    gone.isDeleted = true
    assertTrue(not TCADSStock.isUsedPart(gone), "deleted")

    assertTrue(TCADSStock.isReservedPart(addBox(world, { isUsed = true, reserved = true })), "reserved box")
    assertTrue(not TCADSStock.isReservedPart(addBattery(world, { health = 0.5 })), "packs are never reserved")
end)

test("without isUsed no box is used, and nothing else goes", function()
    local env = newADSEnv()
    env.ADS_SparePartsBox.isUsed = nil
    local world = setup(env)
    TCADSStock.detect()
    assertTrue(TCADSStock.hasPartsBoxes(), "parts boxes")
    local box = addBox(world, { isUsed = true })
    assertTrue(not TCADSStock.isUsedPart(box), "not used")
    assertEquals(#TCADSStock.getPartBoxRows(1), 1, "still listed")
    assertTrue(TCADSStock.isUsedPart(addBattery(world, { health = 0.5 })), "packs still known")
    assertEquals(#world.warnings, 1, "one warning")
end)

test("without the consumable pack functions no pack is used, and nothing else goes", function()
    for _, name in ipairs({ "isPack", "isGrippable", "getPartState" }) do
        local env = newADSEnv()
        env.ADS_ConsumablePack[name] = nil
        local world = setup(env)
        TCADSStock.detect()
        assertTrue(TCADSStock.hasConsumables() and TCADSStock.hasPartsBoxes(), "views")
        assertTrue(not TCADSStock.isUsedPart(addBattery(world, { health = 0.5 })), "no used pack without " .. name)
        assertTrue(TCADSStock.isUsedPart(addBox(world, { isUsed = true })), "boxes still known")
        assertEquals(#world.warnings, 1, "one warning")
    end
end)

-- Each ADS entry point removed in turn: only what needs it goes.
local function withoutEntryPoint(tableName, fieldName)
    local env = newADSEnv()
    env[tableName][fieldName] = nil
    local world = setup(env)
    TCADSStock.detect()
    return world
end

local function assertWarnedAbout(world, name)
    assertEquals(#world.warnings, 1, "one warning about " .. name)
end

test("without collectStockSources only the consumables view goes", function()
    local world = withoutEntryPoint("ADS_PlayerWorkshop", "collectStockSources")
    assertTrue(not TCADSStock.hasConsumables(), "consumables")
    assertTrue(TCADSStock.hasPartsBoxes(), "parts boxes")
    assertTrue(TCADSStock.hasReservations(), "reservations")
    assertTrue(TCADSStock.isAvailable(), "available")
    addOilDrums(world, {})
    assertEquals(#TCADSStock.getConsumableRows(1), 0, "consumable rows")
    assertWarnedAbout(world, "ADS_PlayerWorkshop.collectStockSources")
end)

test("without STOCK_KINDS only the consumables view goes", function()
    local world = withoutEntryPoint("ADS_PlayerWorkshop", "STOCK_KINDS")
    assertTrue(not TCADSStock.hasConsumables(), "consumables")
    assertTrue(TCADSStock.hasPartsBoxes(), "parts boxes")
    assertWarnedAbout(world, "ADS_PlayerWorkshop.STOCK_KINDS")
end)

test("without isBox the spare parts view goes, and its reservations with it", function()
    local world = withoutEntryPoint("ADS_SparePartsBox", "isBox")
    assertTrue(TCADSStock.hasConsumables(), "consumables")
    assertTrue(not TCADSStock.hasPartsBoxes(), "parts boxes")
    assertTrue(not TCADSStock.hasReservations(), "reservations")
    addBox(world, {})
    assertEquals(#TCADSStock.getPartBoxRows(1), 0, "part rows")
    assertWarnedAbout(world, "ADS_SparePartsBox.isBox")
end)

test("without getState the spare parts view goes", function()
    local world = withoutEntryPoint("ADS_SparePartsBox", "getState")
    assertTrue(TCADSStock.hasConsumables(), "consumables")
    assertTrue(not TCADSStock.hasPartsBoxes(), "parts boxes")
    assertWarnedAbout(world, "ADS_SparePartsBox.getState")
end)

test("without isReserved boxes are listed with no free/reserved split", function()
    local world = withoutEntryPoint("ADS_SparePartsBox", "isReserved")
    assertTrue(TCADSStock.hasPartsBoxes(), "parts boxes")
    assertTrue(not TCADSStock.hasReservations(), "reservations")
    addBox(world, { reserved = true })
    local rows = TCADSStock.getPartBoxRows(1)
    assertEquals(#rows, 1, "rows")
    assertEquals(rows[1].count, 1, "count")
    assertEquals(rows[1].reserved, nil, "no reserved count")
    assertWarnedAbout(world, "ADS_SparePartsBox.isReserved")
end)

test("with neither half there's no ADS view at all", function()
    local env = newADSEnv()
    env.ADS_PlayerWorkshop = nil
    env.ADS_SparePartsBox = nil
    local world = setup(env)
    TCADSStock.detect()
    assertTrue(not TCADSStock.isAvailable(), "available")
    assertEquals(#world.warnings, 4, "a warning per missing entry point")
end)

test("a missing entry point is only warned about once a session", function()
    local world = withoutEntryPoint("ADS_SparePartsBox", "isReserved")
    TCADSStock.detect()
    TCADSStock.detect()
    assertEquals(#world.warnings, 1, "warnings")
end)
