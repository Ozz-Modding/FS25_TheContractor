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
-- isn't known (e.g. the tcJobAvailability per-type summary).
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

-- What part a vehicle can play in a job, or nil if none:
-- "harvester" | "header" | "implement" | "tractor". jobDef is a
-- TheContractorJobGeneration.JOB_TYPES entry.
function TCEquipmentClass.getJobRole(vehicle, jobDef, fruitTypeIndex)
    if jobDef.cropDependent then
        if TCEquipmentClass.isHarvester(vehicle) and
            (vehicle.spec_cutter == nil or TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex)) then
            return "harvester"
        end
        if TCEquipmentClass.canCutFruit(vehicle, fruitTypeIndex) then
            return "header"
        end
    elseif vehicle[jobDef.implementSpec] ~= nil then
        return "implement"
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
--   "implement" non-harvest: no plow/cultivator/seeder (per jobDef)
--   "tractor"   something needs pulling and there's no tractor
-- See getMissingEquipmentText for the player-facing wording.
function TCEquipmentClass.getMissingEquipment(vehicles, jobDef, fruitTypeIndex)
    local hasCutter, hasHarvester, hasSelfPropelledHarvester, hasImplement, hasTractor = false, false, false, false,
        false
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
        elseif vehicle[jobDef.implementSpec] ~= nil then
            hasImplement = true
        end

        if TCEquipmentClass.isTractor(vehicle) then
            hasTractor = true
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
        if jobDef.requiresTractor and not hasTractor then
            table.insert(missing, "tractor")
        end
    end
    return missing
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
