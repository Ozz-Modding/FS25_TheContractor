-- Equipment size/capability classification (009). Only tractors carry a
-- vanilla small/medium/large split, and it's expressed as a suffix on the
-- store category id (TRACTORSS/TRACTORSM/TRACTORSL), not a numeric stat.
-- Confirmed by FS25_RedTape's tractor demo scheme (SchemeList.lua's
-- rt_scheme_tractor_demo), which already relies on exactly these three
-- category ids to pick a tractor of a given size for its demo events — so
-- we reuse the game's own bucketing instead of inventing power/mass
-- thresholds (see 009's Outcome for why the original threshold plan was
-- dropped). No other vehicle type has an equivalent S/M/L split, so
-- everything else is left as a single category (e.g. "COMBINES") rather
-- than force-fit into small/medium/large.

TCEquipmentClass = {}

TCEquipmentClass.TRACTOR_SIZE_CATEGORIES = {
    TRACTORSS = "small",
    TRACTORSM = "medium",
    TRACTORSL = "large",
}

-- storeItem.categoryName is categoryNames[1], the item's primary category
-- (shop/StoreManager.lua, StoreItemUtil.loadSpecsFromXML) — fine here since
-- vanilla tractors only ever carry one of the three size categories as
-- their primary category.
local function getStoreItem(vehicle)
    if vehicle == nil or vehicle.configFileName == nil then
        return nil
    end

    return g_storeManager:getItemByXMLFilename(vehicle.configFileName)
end

-- Returns "small" | "medium" | "large" for a tractor, or nil for anything
-- else — implements, harvesters, etc. don't carry a size-tiered store
-- category in vanilla (see file header). Callers that need to bucket
-- non-tractor equipment should match on getCategory() instead.
function TCEquipmentClass.getSizeTier(vehicle)
    local storeItem = getStoreItem(vehicle)
    if storeItem == nil or storeItem.categoryName == nil then
        return nil
    end

    return TCEquipmentClass.TRACTOR_SIZE_CATEGORIES[storeItem.categoryName]
end

-- Returns the vehicle's primary store category id (e.g. "COMBINES",
-- "TRACTORSM", "PLOWS"), or nil if it has no resolvable store item. This is
-- the single bucket non-tractor equipment is classified by, since it has no
-- size tier of its own.
function TCEquipmentClass.getCategory(vehicle)
    local storeItem = getStoreItem(vehicle)
    if storeItem == nil then
        return nil
    end

    return storeItem.categoryName
end

-- Job equipment requirements --------------------------------------------
--
-- Matched on what a vehicle can actually *do* (its specializations), not
-- its store category. Store categories turned out too coarse and
-- inconsistent to key jobs off: combines live under HARVESTERS (there is no
-- COMBINES category, the original harvest requirement never matched
-- anything), a spinach harvester under SPINACHHARVESTERS, planters under
-- PLANTERS rather than SEEDERS, disc harrows under DISCHARROWS rather than
-- CULTIVATORS, and so on. Specializations are also what vanilla's own AI
-- and field missions care about, and mod equipment gets them for free.
--
-- Harvest is crop-specific: something has to *cut* the job's crop (a header
-- whose spec_cutter lists that fruit, or a combined cutter+harvester unit
-- like the spinach/beet harvesters), something has to *harvest* it
-- (spec_combine — the combine itself, or that same combined unit), and if
-- the harvester has no engine of its own (a trailed spinach harvester) a
-- tractor to pull it.

function TCEquipmentClass.isTractor(vehicle)
    return TCEquipmentClass.getSizeTier(vehicle) ~= nil
end

-- fruitTypeIndex nil means "any crop" — used where a harvest job's crop
-- isn't known (e.g. the tcJob availability per-type summary).
function TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex)
    local spec = vehicle.spec_cutter
    if spec == nil or spec.fruitTypeIndices == nil then
        return false
    end
    if fruitTypeIndex == nil then
        return #spec.fruitTypeIndices > 0
    end
    for _, index in ipairs(spec.fruitTypeIndices) do
        if index == fruitTypeIndex then
            return true
        end
    end
    return false
end

function TCEquipmentClass.isHarvester(vehicle)
    return vehicle.spec_combine ~= nil
end

function TCEquipmentClass.isSelfPropelled(vehicle)
    return vehicle.spec_motorized ~= nil
end

-- A standalone header, as opposed to a harvester with its own cutter built
-- in (spinach/beet harvesters).
function TCEquipmentClass.isStandaloneCutter(vehicle, fruitTypeIndex)
    return TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex) and not TCEquipmentClass.isHarvester(vehicle)
end

-- Whether `implement` could ever hitch to one of `attacher`'s joints -
-- the same jointType + AttacherJoints.getAttacherJointCompatibility test
-- TCJobSiteSetup's rigging uses, minus anything about what's currently
-- occupying the joints.
function TCEquipmentClass.canHitch(attacher, implement)
    if attacher.getAttacherJoints == nil or implement.getInputAttacherJoints == nil then
        return false
    end
    for _, attacherJoint in ipairs(attacher:getAttacherJoints()) do
        for _, inputJoint in ipairs(implement:getInputAttacherJoints()) do
            if inputJoint.jointType == attacherJoint.jointType and
                AttacherJoints.getAttacherJointCompatibility(attacher, attacherJoint, implement, inputJoint) then
                return true
            end
        end
    end
    return false
end

-- Whether a header fits a harvester: it has to hitch on, and the
-- harvester's tank has to take what the header puts out - the same check
-- base-game Cutter:isAttachAllowed makes (Combine:getIsCutterCompatible),
-- which is what stops a player hitching e.g. a grain header to a forage
-- harvester by hand.
function TCEquipmentClass.isCutterCompatible(harvester, cutter)
    local spec = cutter.spec_cutter
    if spec == nil or spec.outputFillTypes == nil or harvester.getIsCutterCompatible == nil then
        return false
    end
    return harvester:getIsCutterCompatible(spec.outputFillTypes) and TCEquipmentClass.canHitch(harvester, cutter)
end

-- Whether `vehicle` is the implement a non-harvest job type needs (032):
-- it carries the job's implementSpec, and on top of that a weeder has to be
-- the right kind (a hoe for hoeing, a tine weeder for weeding - vanilla's
-- WeedMission/HoeMission tell them apart by Weeder's isHoeWeeder), and a
-- sprayer has to take one of the job's products (fertilizer or herbicide -
-- the same sprayer spec covers fertilizer spreaders, manure spreaders and
-- slurry tankers).
function TCEquipmentClass.isJobImplement(vehicle, jobDef)
    if jobDef.implementSpec == nil or vehicle[jobDef.implementSpec] == nil then
        return false
    end

    if jobDef.weederType ~= nil then
        return (vehicle.spec_weeder.isHoeWeeder == true) == (jobDef.weederType == "hoe")
    end

    if jobDef.implementSpec == "spec_sprayer" and jobDef.supplyFillTypeNames ~= nil then
        local fillUnitIndex = vehicle.spec_sprayer.fillUnitIndex
        if fillUnitIndex == nil or vehicle.getFillUnitSupportsFillType == nil then
            return false
        end
        for _, fillTypeName in ipairs(jobDef.supplyFillTypeNames) do
            local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if fillTypeIndex ~= nil and vehicle:getFillUnitSupportsFillType(fillUnitIndex, fillTypeIndex) then
                return true
            end
        end
        return false
    end

    return true
end

-- Seed tanks (032 follow-up): some seeders have no hopper of their own
-- (capacity 0) and are fed from a separate tank - typically a front hopper
-- on the tractor's front linkage. Vanilla draws their seed from any vehicle
-- in the same rig with a fill unit that takes the seed
-- (SowingMachine:onStateChange -> FillUnit.addFillTypeSources), so that's
-- what counts as a seed tank here: something hitchable, not itself a
-- seeder, trailer or pallet, with a fill unit that takes SEED_TANK_FILL_TYPE.
TCEquipmentClass.SEED_TANK_FILL_TYPE = FillType.SEEDS

-- Whether a seeder has no hopper of its own to sow from (a seeder that uses
-- up a consumable instead - a tree planter's saplings - doesn't count).
function TCEquipmentClass.needsSeedTank(vehicle)
    local spec = vehicle.spec_sowingMachine
    if spec == nil or spec.consumableName ~= nil or vehicle.getFillUnitCapacity == nil then
        return false
    end
    local capacity = vehicle:getFillUnitCapacity(spec.fillUnitIndex)
    return capacity == nil or capacity <= 0
end

function TCEquipmentClass.isSeedTank(vehicle)
    if vehicle.spec_sowingMachine ~= nil or vehicle.spec_trailer ~= nil or vehicle.isPallet or
        vehicle.spec_motorized ~= nil or vehicle.getInputAttacherJoints == nil or vehicle.spec_fillUnit == nil then
        return false
    end
    for _, fillUnit in pairs(vehicle.spec_fillUnit.fillUnits) do
        if fillUnit.capacity > 0 and fillUnit.supportedFillTypes[TCEquipmentClass.SEED_TANK_FILL_TYPE] then
            return true
        end
    end
    return false
end

-- What part a vehicle can play in a job, or nil if none:
-- "harvester" | "header" | "implement" | "seedTank" | "tractor". jobDef is
-- a TheContractorJobGeneration.JOB_TYPES entry.
function TCEquipmentClass.getJobRole(vehicle, jobDef, fruitTypeIndex)
    if jobDef.cropDependent then
        if TCEquipmentClass.isHarvester(vehicle) and
            (vehicle.spec_cutter == nil or TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex)) then
            return "harvester"
        end
        if TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex) then
            return "header"
        end
    elseif TCEquipmentClass.isJobImplement(vehicle, jobDef) then
        return "implement"
    elseif jobDef.implementSpec == "spec_sowingMachine" and TCEquipmentClass.isSeedTank(vehicle) then
        return "seedTank"
    end

    if TCEquipmentClass.isTractor(vehicle) then
        return "tractor"
    end
    return nil
end

-- Which required pieces are missing from `vehicles` for a job of this
-- type/crop. Returns a list of requirement keys, in display order — empty
-- means the set covers the job:
--   "cutter"    harvest: nothing that can cut this crop
--   "harvester" harvest: nothing that can harvest (no spec_combine)
--   "cutterMismatch" harvest: headers and harvesters both there, but no
--               header fits any of the harvesters (isCutterCompatible)
--   "implement" non-harvest: no plow/cultivator/seeder/... (isJobImplement)
--   "tractor"   something needs pulling and there's no tractor - a job
--               needs one unless its harvester/implement is self-propelled
--   "seedTank"  sow: the seeders have no hopper of their own (needsSeedTank)
--               and there's no seed tank to feed them
--   "seedTankHitch" sow: seed tanks there, but none hitches to any of the
--               tractors (a front hopper needs front linkage)
-- See getMissingEquipmentText for the player-facing wording.
function TCEquipmentClass.getMissingEquipment(vehicles, jobDef, fruitTypeIndex)
    local hasCutter, hasHarvester, hasSelfPropelledHarvester, hasImplement, hasTractor = false, false, false, false,
        false
    local hasSelfPropelledImplement = false
    local hasSeederWithHopper, hasSeederNeedingTank = false, false
    local seedTanks, tractors = {}, {}
    local hasPairing = false
    local harvesters, cutters = {}, {}

    for _, vehicle in ipairs(vehicles) do
        if jobDef.cropDependent then
            if TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex) then
                hasCutter = true
            end
            if TCEquipmentClass.isStandaloneCutter(vehicle, fruitTypeIndex) then
                table.insert(cutters, vehicle)
            end
            if TCEquipmentClass.isHarvester(vehicle) and
                (vehicle.spec_cutter == nil or TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex)) then
                hasHarvester = true
                table.insert(harvesters, vehicle)
                -- Its own cutter already takes the crop.
                if vehicle.spec_cutter ~= nil then
                    hasPairing = true
                end
                if TCEquipmentClass.isSelfPropelled(vehicle) then
                    hasSelfPropelledHarvester = true
                end
            end
        elseif TCEquipmentClass.isJobImplement(vehicle, jobDef) then
            hasImplement = true
            if TCEquipmentClass.isSelfPropelled(vehicle) then
                hasSelfPropelledImplement = true
            end
            if vehicle.spec_sowingMachine ~= nil then
                if TCEquipmentClass.needsSeedTank(vehicle) then
                    hasSeederNeedingTank = true
                else
                    hasSeederWithHopper = true
                end
            end
        elseif jobDef.implementSpec == "spec_sowingMachine" and TCEquipmentClass.isSeedTank(vehicle) then
            table.insert(seedTanks, vehicle)
        end

        if TCEquipmentClass.isTractor(vehicle) then
            hasTractor = true
            table.insert(tractors, vehicle)
        end
    end

    if not hasPairing then
        for _, harvester in ipairs(harvesters) do
            for _, cutter in ipairs(cutters) do
                if TCEquipmentClass.isCutterCompatible(harvester, cutter) then
                    hasPairing = true
                    break
                end
            end
            if hasPairing then
                break
            end
        end
    end

    local missing = {}
    if jobDef.cropDependent then
        if not hasCutter then
            table.insert(missing, "cutter")
        end
        if not hasHarvester then
            table.insert(missing, "harvester")
        elseif hasCutter and not hasPairing then
            table.insert(missing, "cutterMismatch")
        elseif not hasSelfPropelledHarvester and not hasTractor then
            table.insert(missing, "tractor")
        end
    else
        if not hasImplement then
            table.insert(missing, "implement")
        end
        if not hasSelfPropelledImplement and not hasTractor then
            table.insert(missing, "tractor")
        end
        if hasSeederNeedingTank and not hasSeederWithHopper then
            if #seedTanks == 0 then
                table.insert(missing, "seedTank")
            elseif #tractors > 0 then
                local canHitchTank = false
                for _, tank in ipairs(seedTanks) do
                    for _, tractor in ipairs(tractors) do
                        if TCEquipmentClass.canHitch(tractor, tank) then
                            canHitchTank = true
                        end
                    end
                end
                if not canHitchTank then
                    table.insert(missing, "seedTankHitch")
                end
            end
        end
    end
    return missing
end

-- Operation skills (044) ------------------------------------------------
--
-- What kind of work a single vehicle does, as a worker operation skill
-- (TheContractorWorker.SKILLS), from its specializations - or nil for
-- something that does no work of its own (a plain tractor). Used where
-- there's no job to say (AutoDrive/Courseplay driving, 037 - see
-- getOperationSkillForVehicles). A sowing machine is planting when the
-- seed it's set to is a planted crop
-- (TheContractorJobGeneration.isPlantingFruitType), seeding otherwise.
TCEquipmentClass.OPERATION_SKILL_SPECS = {
    { spec = "spec_combine", skill = "harvesting" },
    { spec = "spec_cutter", skill = "harvesting" },
    { spec = "spec_baler", skill = "baling" },
    { spec = "spec_baleWrapper", skill = "baling" },
    { spec = "spec_mower", skill = "grassland" },
    { spec = "spec_tedder", skill = "grassland" },
    { spec = "spec_windrower", skill = "grassland" },
    { spec = "spec_plow", skill = "tillage" },
    { spec = "spec_cultivator", skill = "tillage" },
    { spec = "spec_stonePicker", skill = "tillage" },
    { spec = "spec_sowingMachine", skill = "seeding" },
    { spec = "spec_sprayer", skill = "cropCare" },
    { spec = "spec_weeder", skill = "cropCare" },
    { spec = "spec_trailer", skill = "haulage" },
}

function TCEquipmentClass.getOperationSkill(vehicle)
    for _, entry in ipairs(TCEquipmentClass.OPERATION_SKILL_SPECS) do
        if vehicle[entry.spec] ~= nil then
            if entry.spec == "spec_sowingMachine" then
                local spec = vehicle.spec_sowingMachine
                local seeds = spec.seeds
                if seeds ~= nil and spec.currentSeed ~= nil and
                    TheContractorJobGeneration.isPlantingFruitType(seeds[spec.currentSeed]) then
                    return "planting"
                end
            end
            return entry.skill
        end
    end
    return nil
end

-- The skill for a whole rig (a tractor and what's hitched to it): the
-- first vehicle doing real work wins over a trailer, so a seeder with a
-- trailer behind it is still seeding. nil if nothing in it does any work.
function TCEquipmentClass.getOperationSkillForVehicles(vehicles)
    local haulage = nil
    for _, vehicle in pairs(vehicles) do
        local skill = TCEquipmentClass.getOperationSkill(vehicle)
        if skill == "haulage" then
            haulage = skill
        elseif skill ~= nil then
            return skill
        end
    end
    return haulage
end

-- Haulage (035): a trailer the crop can go in - a tipping trailer
-- (spec_trailer) with a fill unit that takes the crop's fill type.
function TCEquipmentClass.isTrailerFor(vehicle, fillTypeIndex)
    if vehicle.spec_trailer == nil or vehicle.getFillUnits == nil or fillTypeIndex == nil then
        return false
    end
    for fillUnitIndex in ipairs(vehicle:getFillUnits()) do
        if vehicle:getFillUnitSupportsFillType(fillUnitIndex, fillTypeIndex) then
            return true
        end
    end
    return false
end

-- Which pieces of a two-worker haulage rig are missing from `vehicles`:
--   "haulTractor"  no tractor
--   "trailer"      no trailer that takes this crop
--   "trailerHitch" both there, but no trailer hitches to any of the tractors
function TCEquipmentClass.getMissingHaulageEquipment(vehicles, fillTypeIndex)
    local tractors, trailers = {}, {}
    for _, vehicle in ipairs(vehicles) do
        if TCEquipmentClass.isTractor(vehicle) then
            table.insert(tractors, vehicle)
        elseif TCEquipmentClass.isTrailerFor(vehicle, fillTypeIndex) then
            table.insert(trailers, vehicle)
        end
    end

    local missing = {}
    if #tractors == 0 then
        table.insert(missing, "haulTractor")
    end
    if #trailers == 0 then
        table.insert(missing, "trailer")
    end
    if #missing == 0 then
        for _, tractor in ipairs(tractors) do
            for _, trailer in ipairs(trailers) do
                if TCEquipmentClass.canHitch(tractor, trailer) then
                    return missing
                end
            end
        end
        table.insert(missing, "trailerHitch")
    end
    return missing
end

-- Player-facing, comma-joined list for getMissingEquipment's result, e.g.
-- "a header or harvester that can harvest Spinach, a tractor".
function TCEquipmentClass.getMissingEquipmentText(missing, jobType, cropTitle)
    local parts = {}
    for _, key in ipairs(missing) do
        if key == "cutter" or key == "cutterMismatch" or key == "trailer" then
            table.insert(parts, string.format(g_i18n:getText("tc_equipment_missing_" .. key),
                cropTitle or g_i18n:getText("tc_equipment_anyCrop")))
        elseif key == "implement" then
            table.insert(parts, g_i18n:getText("tc_equipment_missing_implement_" .. jobType))
        else
            table.insert(parts, g_i18n:getText("tc_equipment_missing_" .. key))
        end
    end
    return table.concat(parts, ", ")
end
