-- Farmer fleets (121): the machines each of the map's farmers (110) owns,
-- kept as records on the farmer, never as vehicles left on the map. A
-- machine is only in the world while a job needs it (a field breakdown,
-- 101, a favour, 116, or 124's telehandler lent to a yard bale job), and
-- then it's that farmer's machine, every time: the same model and seed,
-- only older.
--
-- The recipe is flat, not a scale by acres (farmers' holdings are all much
-- the same size, 109's target, +-30%); it's there for interesting equipment
-- scenarios:
--   every farmer: a small tractor, a medium tractor, a combine with a
--     header that fits it, and a trailer;
--   about SECOND_SMALL_SHARE of them a second small tractor, rolled when
--     their first small tractor is made;
--   a farmer with a yard (108): a telehandler with a bale fork;
--   a farmer over LARGE_TRACTOR_ACRES who's also in the top
--     LARGE_TRACTOR_SHARE of farmers by acres (rounded up): a large tractor
--     as well. So a small map has one at most, and none if nobody's over.
-- The rank compares farmers, so fleets are made for everyone at once
-- (ensureAll): when the farmers are set up, and whenever land or a yard
-- changes hands (Farmers:reconcileLand). Nothing is ever taken away, and a
-- new machine takes the next id (ids are never reused: favours, saved
-- arrivals and jobs hold them). A farmer who loses their yard or their rank
-- keeps their kit.
--
-- A machine: { id, role, attachedTo (an attachment's machine id), xmlFilename,
-- seed, hours, hoursDay, hoursPerMonth, fitted = { [part] = day } }. 116's
-- machines had no role: they get one from their store category (small,
-- medium or large tractor) and keep everything else.
--
-- Models come from the store by role (buildCatalog), with no need for ADS,
-- so fleets are made without it. An attachment must fit its machine: it
-- comes from the machine's own store combinations (what the shop offers
-- with it), a header for a combine (a grain header, CUTTERS, when there's
-- one) and a bale fork for a telehandler. A combine or telehandler
-- is picked among those with something that fits, and an attachment with
-- nothing to fit is left out. Whether ADS can take a machine is checked
-- where ADS is used (RepairContracts:findModelByXml).
--
-- 125: the manifest (MANIFEST) holds each role to what it must be (a bale
-- fork is a spike, not a grab). Only models that meet it are picked or
-- offered in an edit, and a machine that fails it is changed at setup
-- (enforceManifest), under the same id.
--
-- Saved on the farmer's record (TheContractorFarmers). 122: each machine's
-- id, role, model and attachedTo go to clients (writeStream: in the
-- farmers' state, and TCFarmerFleetEvent as a fleet grows or is edited);
-- seed, age and fitted parts stay on the server.
--
-- 122: any farm with a company may change a machine's model, role by role
-- (editMachine, through TCEditFarmerMachineEvent), for everyone. A changed
-- machine is a new one: a new seed, no age and nothing fitted, under the
-- same id. A combine whose header no longer fits gets one that does.

TheContractorFarmerFleet = {}

TheContractorFarmerFleet.ROLE = {
    SMALL_TRACTOR = "smallTractor",
    MEDIUM_TRACTOR = "mediumTractor",
    LARGE_TRACTOR = "largeTractor",
    TELEHANDLER = "telehandler",
    BALE_FORK = "baleFork",
    COMBINE = "combine",
    HEADER = "header",
    TRAILER = "trailer",
}
local ROLE = TheContractorFarmerFleet.ROLE

-- The order a fleet is listed and made in.
TheContractorFarmerFleet.ROLE_ORDER = {
    ROLE.SMALL_TRACTOR, ROLE.MEDIUM_TRACTOR, ROLE.LARGE_TRACTOR, ROLE.COMBINE, ROLE.HEADER, ROLE.TRAILER,
    ROLE.TELEHANDLER, ROLE.BALE_FORK,
}

-- Machines that drive, so a breakdown or favour can be about them.
TheContractorFarmerFleet.DRIVABLE_ROLES = {
    [ROLE.SMALL_TRACTOR] = true,
    [ROLE.MEDIUM_TRACTOR] = true,
    [ROLE.LARGE_TRACTOR] = true,
    [ROLE.TELEHANDLER] = true,
    [ROLE.COMBINE] = true,
}

-- What goes on each machine that has something.
TheContractorFarmerFleet.ATTACHMENT_ROLE = {
    [ROLE.COMBINE] = ROLE.HEADER,
    [ROLE.TELEHANDLER] = ROLE.BALE_FORK,
}

-- Store categories of the machines that stand alone.
TheContractorFarmerFleet.TRACTOR_ROLES = {
    TRACTORSS = ROLE.SMALL_TRACTOR,
    TRACTORSM = ROLE.MEDIUM_TRACTOR,
    TRACTORSL = ROLE.LARGE_TRACTOR,
}
TheContractorFarmerFleet.TELEHANDLER_CATEGORY = "TELELOADERVEHICLES"
TheContractorFarmerFleet.COMBINE_CATEGORY = "HARVESTERS"
TheContractorFarmerFleet.TRAILER_CATEGORY = "TRAILERS"
-- A grain header's category: preferred over corn and special headers.
TheContractorFarmerFleet.GRAIN_HEADER_CATEGORY = "CUTTERS"

TheContractorFarmerFleet.SECOND_SMALL_SHARE = 0.5
TheContractorFarmerFleet.LARGE_TRACTOR_ACRES = 50
TheContractorFarmerFleet.LARGE_TRACTOR_SHARE = 0.1

-- A drivable machine's work a month: { base, per acre, most } hours (116).
TheContractorFarmerFleet.HOURS_PER_MONTH = { 20, 0.3, 70 }

-- Reading -------------------------------------------------------------------------------

function TheContractorFarmerFleet.getMachine(farmer, machineId)
    for _, machine in ipairs(farmer ~= nil and farmer.machines or {}) do
        if machine.id == machineId then
            return machine
        end
    end
    return nil
end

function TheContractorFarmerFleet.getMachinesByRole(farmer, role)
    local machines = {}
    for _, machine in ipairs(farmer ~= nil and farmer.machines or {}) do
        if machine.role == role then
            table.insert(machines, machine)
        end
    end
    return machines
end

-- The machine hitched to this one (a combine's header), or nil.
function TheContractorFarmerFleet.getAttachment(farmer, machine)
    for _, other in ipairs(farmer ~= nil and farmer.machines or {}) do
        if machine ~= nil and other.attachedTo == machine.id then
            return other
        end
    end
    return nil
end

function TheContractorFarmerFleet.isDrivable(machine)
    return machine ~= nil and TheContractorFarmerFleet.DRIVABLE_ROLES[machine.role] == true
end

-- A machine's operating hours on a day: its first age, plus its months of
-- work since. nil before ADS has aged it.
function TheContractorFarmerFleet.getHours(machine, today, daysPerPeriod)
    if machine.hours == nil then
        return nil
    end
    local months = math.max(0, today - (machine.hoursDay or today)) / math.max(daysPerPeriod or 1, 1)
    return machine.hours + months * (machine.hoursPerMonth or 0)
end

function TheContractorFarmerFleet.getHoursPerMonth(acres)
    local hours = TheContractorFarmerFleet.HOURS_PER_MONTH
    return math.min(hours[1] + acres * hours[2], hours[3])
end

-- Server: whether a farmer's machine is in the world or on its way (an
-- arrival, an open workshop job or yard bale job, or waiting to be
-- collected), so it can't turn up somewhere else as well.
function TheContractorFarmerFleet.isMachineOut(farmerId, machineId)
    local tc = g_currentMission.TheContractor
    local repairContracts = tc.RepairContracts
    local function matches(entry)
        return entry ~= nil and entry.farmerId == farmerId and entry.machineId == machineId
    end
    if repairContracts ~= nil then
        for _, entry in ipairs(repairContracts.arrivals) do
            if matches(entry) then
                return true
            end
        end
        for _, entry in ipairs(repairContracts.removals) do
            if matches(entry) then
                return true
            end
        end
    end
    if tc.Jobs ~= nil then
        for _, farmJobs in pairs(tc.Jobs.jobsByFarm) do
            for _, job in pairs(farmJobs) do
                if matches(job.workshop) and not job:isTerminal() then
                    return true
                end
                -- 124: a yard bale job holds the farmer's telehandler and
                -- fork from its offer until it's over.
                local yard = job.yardDelivery
                if yard ~= nil and not job:isTerminal() and yard.farmerId == farmerId and
                        (yard.machineId == machineId or yard.attachmentMachineId == machineId) then
                    return true
                end
            end
        end
    end
    return false
end

-- Server: a farmer's machines ADS can take that aren't already out, with
-- their models (RepairContracts:findModelByXml), optionally only those
-- `filter` accepts. { { machine, model }, ... }.
function TheContractorFarmerFleet.getRepairableMachines(farmer, repairContracts, filter)
    local result = {}
    for _, machine in ipairs(farmer ~= nil and farmer.machines or {}) do
        if TheContractorFarmerFleet.isDrivable(machine) and (filter == nil or filter(machine)) and
                not TheContractorFarmerFleet.isMachineOut(farmer.id, machine.id) then
            local model = repairContracts:findModelByXml(machine.xmlFilename)
            if model ~= nil then
                table.insert(result, { machine = machine, model = model })
            end
        end
    end
    return result
end

-- The store ------------------------------------------------------------------------------

-- The role a store vehicle stands alone in (by its primary category and its
-- type's specializations), or nil.
function TheContractorFarmerFleet.getRoleForItem(categoryName, specs)
    if specs == nil then
        return nil
    end
    local F = TheContractorFarmerFleet
    if specs.drivable ~= nil then
        if F.TRACTOR_ROLES[categoryName] ~= nil then
            return F.TRACTOR_ROLES[categoryName]
        elseif categoryName == F.TELEHANDLER_CATEGORY then
            return ROLE.TELEHANDLER
        elseif categoryName == F.COMBINE_CATEGORY and specs.combine ~= nil then
            return ROLE.COMBINE
        end
    elseif categoryName == F.TRAILER_CATEGORY and specs.trailer ~= nil then
        return ROLE.TRAILER
    end
    return nil
end

-- The attachment role a store vehicle can take, or nil: a header (cuts, but
-- no harvester of its own), or a bale fork (a bale grab, or a fork that
-- carries what it's given whose file says it's for bales: vanilla's pallet
-- fork is the same type, so the name's all that tells them apart). Whether
-- it's one a farmer may have is the manifest's say (meetsManifest).
function TheContractorFarmerFleet.getAttachmentRoleForItem(xmlFilename, specs)
    if specs == nil or specs.drivable ~= nil then
        return nil
    end
    if specs.cutter ~= nil and specs.combine == nil then
        return ROLE.HEADER
    end
    if specs.baleGrab ~= nil then
        return ROLE.BALE_FORK
    end
    if specs.dynamicMountAttacher ~= nil and specs.shovel == nil and specs.logGrab == nil and
            string.find(string.lower(xmlFilename or ""), "bale", 1, true) ~= nil then
        return ROLE.BALE_FORK
    end
    return nil
end

-- The manifest (125): what each role's model must be, beyond being that
-- role. Every requirement is hard: a model that fails one is never picked,
-- never offered in an edit, and a machine that is one is changed at setup
-- (enforceManifest), the player's own pick too. A role with no entry takes
-- any of its models, so a player's tractor always stays.
TheContractorFarmerFleet.REQUIREMENT = {
    -- A spike takes any bale (124's yard job needs one). A bale grab, the
    -- other kind, often takes only round bales.
    SPIKE = "spike",
}
local REQUIREMENT = TheContractorFarmerFleet.REQUIREMENT

TheContractorFarmerFleet.MANIFEST = {
    [ROLE.BALE_FORK] = { REQUIREMENT.SPIKE },
}

-- Whether a model meets one requirement: (xmlFilename, specs).
TheContractorFarmerFleet.REQUIREMENT_CHECKS = {
    [REQUIREMENT.SPIKE] = function(xmlFilename, specs)
        return specs.dynamicMountAttacher ~= nil and specs.baleGrab == nil and specs.shovel == nil and
            specs.logGrab == nil and string.find(string.lower(xmlFilename or ""), "bale", 1, true) ~= nil
    end,
}

-- Whether a model (its file and its type's specializations) meets every
-- requirement of the role's manifest.
function TheContractorFarmerFleet.meetsManifest(role, xmlFilename, specs)
    for _, requirement in ipairs(TheContractorFarmerFleet.MANIFEST[role] or {}) do
        if specs == nil or not TheContractorFarmerFleet.REQUIREMENT_CHECKS[requirement](xmlFilename, specs) then
            return false
        end
    end
    return true
end

local function isCandidateItem(storeItem)
    if storeItem.bundleInfo ~= nil or storeItem.showInStore == false or storeItem.xmlFilename == nil then
        return false
    end
    if StoreSpecies ~= nil and storeItem.species ~= nil and storeItem.species ~= StoreSpecies.VEHICLE then
        return false
    end
    if g_storeManager.getIsItemUnlocked ~= nil and not g_storeManager:getIsItemUnlocked(storeItem) then
        return false
    end
    return true
end

local function getSpecs(xmlFilename)
    if g_vehicleTypeManager == nil then
        return nil
    end
    local vehicleType = g_vehicleTypeManager:getObjectTypeFromXML(xmlFilename)
    return vehicleType ~= nil and vehicleType.specializationsByName or nil
end

local function getBrandName(storeItem)
    if storeItem == nil or g_brandManager == nil or storeItem.brandIndex == nil then
        return ""
    end
    local brand = g_brandManager:getBrandByIndex(storeItem.brandIndex)
    return brand ~= nil and brand.title or ""
end

local function toModel(storeItem)
    return { xmlFilename = storeItem.xmlFilename, categoryName = storeItem.categoryName,
        name = storeItem.name or storeItem.xmlFilename, brand = getBrandName(storeItem) }
end

-- The store items the shop offers with this one (its combinations).
local function getCombinationItems(storeItem)
    if StoreItemUtil ~= nil and StoreItemUtil.loadSpecsFromXML ~= nil then
        StoreItemUtil.loadSpecsFromXML(storeItem)
    end
    local combinations = storeItem.specs ~= nil and storeItem.specs.combinations or nil
    local items = {}
    if combinations == nil or g_storeManager.getItemsByCombinationData == nil then
        return items
    end
    local seen = {}
    for _, combination in ipairs(combinations) do
        for _, found in ipairs(g_storeManager:getItemsByCombinationData(combination) or {}) do
            local item = found.storeItem
            if item ~= nil and not seen[item] then
                seen[item] = true
                table.insert(items, item)
            end
        end
    end
    return items
end

-- What may go on a parent: the attachment role's items among its
-- combinations, a header's narrowed to grain headers when there are any.
local function getAttachmentModels(parentItem, role)
    local models, preferred = {}, {}
    for _, item in ipairs(getCombinationItems(parentItem)) do
        local specs = isCandidateItem(item) and getSpecs(item.xmlFilename) or nil
        if specs ~= nil and TheContractorFarmerFleet.getAttachmentRoleForItem(item.xmlFilename, specs) == role and
                TheContractorFarmerFleet.meetsManifest(role, item.xmlFilename, specs) then
            table.insert(models, toModel(item))
            if role == ROLE.HEADER and item.categoryName == TheContractorFarmerFleet.GRAIN_HEADER_CATEGORY then
                table.insert(preferred, toModel(item))
            end
        end
    end
    return #preferred > 0 and preferred or models
end

local catalogCache = nil

-- The store's models by role, and what fits each machine with an attachment:
-- { byRole = { [role] = { model, ... } }, attachments = { [parentXml] =
-- { model, ... } } }, only those that meet their role's manifest. Built once
-- per session.
function TheContractorFarmerFleet.buildCatalog()
    if catalogCache ~= nil then
        return catalogCache
    end
    local catalog = { byRole = {}, attachments = {} }
    for _, role in ipairs(TheContractorFarmerFleet.ROLE_ORDER) do
        catalog.byRole[role] = {}
    end
    if g_storeManager == nil then
        return catalog
    end
    for _, storeItem in ipairs(g_storeManager:getItems()) do
        if isCandidateItem(storeItem) then
            local specs = getSpecs(storeItem.xmlFilename)
            local role = TheContractorFarmerFleet.getRoleForItem(storeItem.categoryName, specs)
            if role ~= nil and TheContractorFarmerFleet.meetsManifest(role, storeItem.xmlFilename, specs) then
                table.insert(catalog.byRole[role], toModel(storeItem))
                local attachmentRole = TheContractorFarmerFleet.ATTACHMENT_ROLE[role]
                if attachmentRole ~= nil then
                    catalog.attachments[storeItem.xmlFilename] = getAttachmentModels(storeItem, attachmentRole)
                end
            end
        end
    end
    for _, models in pairs(catalog.byRole) do
        table.sort(models, function(a, b)
            return a.xmlFilename < b.xmlFilename
        end)
    end
    local counts = {}
    for _, role in ipairs(TheContractorFarmerFleet.ROLE_ORDER) do
        if role ~= ROLE.HEADER and role ~= ROLE.BALE_FORK then
            table.insert(counts, string.format("%s %d", role, #catalog.byRole[role]))
        end
    end
    TCLog.info("TheContractor: farmer fleet models: %s", table.concat(counts, ", "))
    catalogCache = catalog
    return catalog
end

-- Every load (the store can change between sessions).
function TheContractorFarmerFleet.clearCatalog()
    catalogCache = nil
end

local function pickFrom(list, random)
    if #list == 0 then
        return nil
    end
    return list[math.floor(random() * #list) + 1] or list[#list]
end

-- The models a role standing alone can be. A machine that takes an
-- attachment is one with something that fits, when there are any.
function TheContractorFarmerFleet.getRoleModels(catalog, role)
    local models = catalog.byRole[role] or {}
    if TheContractorFarmerFleet.ATTACHMENT_ROLE[role] ~= nil then
        local fitted = {}
        for _, model in ipairs(models) do
            if #(catalog.attachments[model.xmlFilename] or {}) > 0 then
                table.insert(fitted, model)
            end
        end
        if #fitted > 0 then
            models = fitted
        end
    end
    return models
end

-- A model for a role standing alone, or nil.
function TheContractorFarmerFleet.pickModel(catalog, role, random)
    return pickFrom(TheContractorFarmerFleet.getRoleModels(catalog, role), random)
end

function TheContractorFarmerFleet.pickAttachmentModel(catalog, parentXml, random)
    return pickFrom(catalog.attachments[parentXml] or {}, random)
end

-- The recipe ------------------------------------------------------------------------------

-- The ids of the farmers who get a large tractor: the top
-- LARGE_TRACTOR_SHARE by acres (rounded up, ties by id) who are over
-- LARGE_TRACTOR_ACRES. A set.
function TheContractorFarmerFleet.getLargeTractorFarmerIds(farmers, land)
    local ranked = {}
    for _, farmer in ipairs(farmers) do
        table.insert(ranked, { id = farmer.id, acres = TheContractorFarmers.getAcres(farmer, land) })
    end
    table.sort(ranked, function(a, b)
        if a.acres ~= b.acres then
            return a.acres > b.acres
        end
        return a.id < b.id
    end)
    local ids = {}
    local count = math.ceil(#ranked * TheContractorFarmerFleet.LARGE_TRACTOR_SHARE)
    for i = 1, math.min(count, #ranked) do
        if ranked[i].acres > TheContractorFarmerFleet.LARGE_TRACTOR_ACRES then
            ids[ranked[i].id] = true
        end
    end
    return ids
end

-- How many of each role standing alone a farmer should have: role -> count.
-- A second small tractor is rolled only when there's no small one yet, so
-- it's rolled once.
function TheContractorFarmerFleet.getWantedCounts(farmer, isLarge, random)
    local smallCount = #TheContractorFarmerFleet.getMachinesByRole(farmer, ROLE.SMALL_TRACTOR)
    if smallCount == 0 then
        smallCount = random() < TheContractorFarmerFleet.SECOND_SMALL_SHARE and 2 or 1
    end
    return {
        [ROLE.SMALL_TRACTOR] = smallCount,
        [ROLE.MEDIUM_TRACTOR] = 1,
        [ROLE.LARGE_TRACTOR] = isLarge and 1 or 0,
        [ROLE.COMBINE] = 1,
        [ROLE.TRAILER] = 1,
        [ROLE.TELEHANDLER] = farmer.yardFarmlandId ~= nil and 1 or 0,
    }
end

-- 116's machines had no role: one from their store category (a tractor
-- whose model's gone counts as medium). Returns how many got one.
function TheContractorFarmerFleet.assignOldRoles(farmer)
    local count = 0
    for _, machine in ipairs(farmer.machines or {}) do
        if machine.role == nil then
            local storeItem = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(machine.xmlFilename) or nil
            local category = storeItem ~= nil and storeItem.categoryName or nil
            machine.role = TheContractorFarmerFleet.TRACTOR_ROLES[category] or ROLE.MEDIUM_TRACTOR
            count = count + 1
        end
    end
    return count
end

local function nextMachineId(farmer)
    local id = 0
    for _, machine in ipairs(farmer.machines) do
        id = math.max(id, machine.id or 0)
    end
    return id + 1
end

local function addMachine(farmer, role, model, hoursPerMonth, random, attachedTo)
    local machine = {
        id = nextMachineId(farmer),
        role = role,
        attachedTo = attachedTo,
        xmlFilename = model.xmlFilename,
        seed = TheContractorRepairContracts.rollSeed(random),
        hoursPerMonth = attachedTo == nil and hoursPerMonth or 0,
        fitted = {},
    }
    table.insert(farmer.machines, machine)
    return machine
end

-- 125: each machine whose model fails its role's manifest becomes one that
-- meets it, under the same id, as 122's edit makes it (a new seed, no age,
-- nothing fitted; a machine whose attachment no longer fits gets one that
-- does). Left as it is: a machine that's out (isOut(farmer, machine), until
-- next time), one whose model the store hasn't got (a mod that may come
-- back; it can't come out meanwhile), and one with nothing to become.
-- Returns how many were changed.
function TheContractorFarmerFleet.enforceManifest(farmer, catalog, random, isOut)
    local F = TheContractorFarmerFleet
    local changed = 0
    for _, machine in ipairs(farmer.machines or {}) do
        local storeItem = g_storeManager:getItemByXMLFilename(machine.xmlFilename)
        local specs = storeItem ~= nil and getSpecs(machine.xmlFilename) or nil
        if specs ~= nil and not F.meetsManifest(machine.role, machine.xmlFilename, specs) and
                (isOut == nil or not isOut(farmer, machine)) then
            local model
            if machine.attachedTo ~= nil then
                local parent = F.getMachine(farmer, machine.attachedTo)
                model = parent ~= nil and F.pickAttachmentModel(catalog, parent.xmlFilename, random) or nil
            else
                model = F.pickModel(catalog, machine.role, random)
            end
            if model ~= nil then
                TCLog.info("TheContractor: farmer #%d's %s (machine %d) doesn't meet the manifest: %s -> %s",
                    farmer.id, tostring(machine.role), machine.id, machine.xmlFilename, model.xmlFilename)
                if machine.attachedTo ~= nil then
                    F.renew(machine, model.xmlFilename, random)
                else
                    F.applyEdit(farmer, machine, model.xmlFilename, catalog, random)
                end
                changed = changed + 1
            end
        end
    end
    return changed
end

-- Brings one farmer's fleet up to the recipe and the manifest, adding only
-- what's missing. Returns how many machines were added or changed.
function TheContractorFarmerFleet.ensureFleet(farmer, catalog, isLarge, acres, random, isOut)
    farmer.machines = farmer.machines or {}
    TheContractorFarmerFleet.assignOldRoles(farmer)
    local changed = TheContractorFarmerFleet.enforceManifest(farmer, catalog, random, isOut)
    local hoursPerMonth = TheContractorFarmerFleet.getHoursPerMonth(acres)
    local added = 0
    local wanted = TheContractorFarmerFleet.getWantedCounts(farmer, isLarge, random)
    for _, role in ipairs(TheContractorFarmerFleet.ROLE_ORDER) do
        local count = wanted[role]
        if count ~= nil then
            for _ = #TheContractorFarmerFleet.getMachinesByRole(farmer, role) + 1, count do
                local model = TheContractorFarmerFleet.pickModel(catalog, role, random)
                if model == nil then
                    break
                end
                addMachine(farmer, role, model, hoursPerMonth, random)
                added = added + 1
            end
        end
    end
    -- Each machine that takes one without one: an attachment that fits it.
    for _, machine in ipairs(TheContractorFarmerFleet.copy(farmer.machines)) do
        local attachmentRole = TheContractorFarmerFleet.ATTACHMENT_ROLE[machine.role]
        if attachmentRole ~= nil and TheContractorFarmerFleet.getAttachment(farmer, machine) == nil then
            local model = TheContractorFarmerFleet.pickAttachmentModel(catalog, machine.xmlFilename, random)
            if model ~= nil then
                addMachine(farmer, attachmentRole, model, hoursPerMonth, random, machine.id)
                added = added + 1
            end
        end
    end
    return added + changed
end

function TheContractorFarmerFleet.copy(list)
    local result = {}
    for i, value in ipairs(list) do
        result[i] = value
    end
    return result
end

-- Every farmer's fleet up to the recipe and the manifest, given the land
-- (getLand's map); isOut as enforceManifest's, optional. Returns how many
-- machines were added or changed, and the farmers whose fleet changed.
function TheContractorFarmerFleet.ensureFleets(farmers, land, catalog, random, isOut)
    local largeIds = TheContractorFarmerFleet.getLargeTractorFarmerIds(farmers, land)
    local added, changed = 0, {}
    for _, farmer in ipairs(farmers) do
        local count = TheContractorFarmerFleet.ensureFleet(farmer, catalog, largeIds[farmer.id] == true,
            TheContractorFarmers.getAcres(farmer, land), random, isOut)
        if count > 0 then
            TCLog.info("TheContractor: farmer #%d (%s) has %d new or changed machine(s), %d in all", farmer.id,
                farmer.name, count, #farmer.machines)
            table.insert(changed, farmer)
        end
        added = added + count
    end
    return added, changed
end

-- Server: everyone's fleet on the live map. 122: clients are told of each
-- fleet that grew or changed (125's manifest).
function TheContractorFarmerFleet.ensureAll()
    local tc = g_currentMission.TheContractor
    if tc.Farmers == nil or not tc.Farmers:hasGenerated() or not g_currentMission:getIsServer() then
        return 0
    end
    local added, changed = TheContractorFarmerFleet.ensureFleets(tc.Farmers:getFarmers(),
        TheContractorFarmers.getLand(), TheContractorFarmerFleet.buildCatalog(), math.random,
        TheContractorFarmerFleet.isAnyOut)
    if g_server ~= nil then
        for _, farmer in ipairs(changed) do
            g_server:broadcastEvent(TCFarmerFleetEvent.new(farmer))
        end
    end
    return added
end

-- Server: a farmer's machine is out (RepairContracts:createOffer and
-- createFavourOffer). Its first time out sets its age (ADS's), counted on
-- from today.
function TheContractorFarmerFleet.onOffered(job, quote)
    local workshop = job.workshop
    if workshop == nil or workshop.machineId == nil then
        return
    end
    local farmer = g_currentMission.TheContractor.Farmers:getPerson(workshop.farmerId)
    local machine = TheContractorFarmerFleet.getMachine(farmer, workshop.machineId)
    if machine ~= nil and machine.hours == nil and quote.operatingHours ~= nil then
        machine.hours = quote.operatingHours
        machine.hoursDay = g_currentMission.environment.currentMonotonicDay
    end
end

-- Spawning with an attachment (server) ----------------------------------------------------

local function getSize(xmlFilename)
    local storeItem = g_storeManager:getItemByXMLFilename(xmlFilename)
    local size = StoreItemUtil.getSizeValues(xmlFilename, "vehicle", storeItem ~= nil and storeItem.rotation or 0, {})
    return {
        width = size.width or 3,
        length = size.length or 3,
        height = size.height or TCParking.DEFAULT_HEIGHT,
        widthOffset = size.widthOffset or 0,
        lengthOffset = size.lengthOffset or 0,
    }
end

-- 124: a model as 100's queue places it ({ xmlFilename, name, width,
-- length, height, widthOffset, lengthOffset }), for any store vehicle,
-- ADS or not; nil if the store hasn't got it.
function TheContractorFarmerFleet.getSizeModel(xmlFilename)
    local storeItem = xmlFilename ~= nil and g_storeManager:getItemByXMLFilename(xmlFilename) or nil
    if storeItem == nil then
        return nil
    end
    local model = getSize(xmlFilename)
    model.xmlFilename = xmlFilename
    model.name = storeItem.name or xmlFilename
    model.categoryName = storeItem.categoryName
    return model
end

-- What an arrival needs to bring a machine's attachment along:
-- { machineId, xmlFilename, width, length, height }, or nil.
function TheContractorFarmerFleet.getAttachmentArrival(farmer, machine)
    local attachment = TheContractorFarmerFleet.getAttachment(farmer, machine)
    if attachment == nil or g_storeManager:getItemByXMLFilename(attachment.xmlFilename) == nil then
        return nil
    end
    local size = getSize(attachment.xmlFilename)
    return { machineId = attachment.id, xmlFilename = attachment.xmlFilename, width = size.width,
        length = size.length, height = size.height }
end

-- The ground a machine and its attachment (in front, where a header or a
-- fork goes) take together, as a model: the machine's model with its
-- size grown and its centre moved forward. Just the model without one.
function TheContractorFarmerFleet.getFootprint(model, attachment)
    if attachment == nil then
        return model
    end
    local footprint = {}
    for key, value in pairs(model) do
        footprint[key] = value
    end
    footprint.width = math.max(model.width, attachment.width)
    footprint.length = model.length + attachment.length
    footprint.height = math.max(model.height or 0, attachment.height or 0)
    footprint.lengthOffset = (model.lengthOffset or 0) + attachment.length * 0.5
    footprint.machineModel = model
    return footprint
end

-- Editing (122) -------------------------------------------------------------------------------

-- Why an edit is refused (the end of its tc_fleet_refused_ key).
TheContractorFarmerFleet.EDIT_PROBLEM = {
    NO_COMPANY = "noCompany",
    NOT_FARMER = "notFarmer",
    NO_MACHINE = "noMachine",
    BAD_MODEL = "badModel",
    OUT = "machineOut",
}
local EDIT_PROBLEM = TheContractorFarmerFleet.EDIT_PROBLEM

-- The models a machine may become, by brand then name: its role's
-- (getRoleModels), or for an attachment what fits the machine it goes on.
function TheContractorFarmerFleet.getModelChoices(catalog, farmer, machine)
    local models
    if machine.attachedTo ~= nil then
        local parent = TheContractorFarmerFleet.getMachine(farmer, machine.attachedTo)
        models = parent ~= nil and catalog.attachments[parent.xmlFilename] or {}
    else
        models = TheContractorFarmerFleet.getRoleModels(catalog, machine.role)
    end
    local sorted = TheContractorFarmerFleet.copy(models)
    table.sort(sorted, function(a, b)
        if (a.brand or "") ~= (b.brand or "") then
            return (a.brand or "") < (b.brand or "")
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.xmlFilename < b.xmlFilename
    end)
    return sorted
end

local function hasModel(models, xmlFilename)
    for _, model in ipairs(models or {}) do
        if model.xmlFilename == xmlFilename then
            return true
        end
    end
    return false
end

-- Server: whether a machine, the one it goes on or its attachment is out
-- (isMachineOut): they travel together.
function TheContractorFarmerFleet.isAnyOut(farmer, machine)
    local F = TheContractorFarmerFleet
    if F.isMachineOut(farmer.id, machine.id) then
        return true
    end
    if machine.attachedTo ~= nil and F.isMachineOut(farmer.id, machine.attachedTo) then
        return true
    end
    local attachment = F.getAttachment(farmer, machine)
    return attachment ~= nil and F.isMachineOut(farmer.id, attachment.id)
end

-- Server: why a farm can't make a person's machine this model
-- (EDIT_PROBLEM), or nil.
function TheContractorFarmerFleet.getEditProblem(farmId, person, machineId, xmlFilename, catalog)
    local company = g_currentMission.TheContractor.Company
    if company == nil or not company:hasCompany(farmId) then
        return EDIT_PROBLEM.NO_COMPANY
    end
    if person == nil or person.isOfficial then
        return EDIT_PROBLEM.NOT_FARMER
    end
    local machine = TheContractorFarmerFleet.getMachine(person, machineId)
    if machine == nil then
        return EDIT_PROBLEM.NO_MACHINE
    end
    if not hasModel(TheContractorFarmerFleet.getModelChoices(catalog, person, machine), xmlFilename) then
        return EDIT_PROBLEM.BAD_MODEL
    end
    if TheContractorFarmerFleet.isAnyOut(person, machine) then
        return EDIT_PROBLEM.OUT
    end
    return nil
end

-- A machine made new as this model: a new seed, no age (ADS ages it the
-- next time it's out) and nothing fitted. Its id and work a month stay.
function TheContractorFarmerFleet.renew(machine, xmlFilename, random)
    machine.xmlFilename = xmlFilename
    machine.seed = TheContractorRepairContracts.rollSeed(random)
    machine.hours = nil
    machine.hoursDay = nil
    machine.fitted = {}
end

-- The edit itself, checked already. A machine whose attachment no longer
-- fits gets one that does (121's pick), made new too. Returns that
-- attachment, or nil when it was kept.
function TheContractorFarmerFleet.applyEdit(farmer, machine, xmlFilename, catalog, random)
    local F = TheContractorFarmerFleet
    F.renew(machine, xmlFilename, random)
    local attachment = F.getAttachment(farmer, machine)
    if attachment == nil or hasModel(catalog.attachments[xmlFilename], attachment.xmlFilename) then
        return nil
    end
    local model = F.pickAttachmentModel(catalog, xmlFilename, random)
    if model == nil then
        TCLog.warning("TheContractor: nothing fits farmer #%d's %s (%s), so machine %d stays %s", farmer.id,
            tostring(machine.role), xmlFilename, attachment.id, attachment.xmlFilename)
        return nil
    end
    F.renew(attachment, model.xmlFilename, random)
    return attachment
end

-- Server: a farm's edit of a farmer's machine, applied and sent to every
-- client. The farm's told how it went (onEditResult, here and through
-- TCEditFarmerMachineEvent). Returns nil once applied (or when it's that
-- model already), or the EDIT_PROBLEM.
function TheContractorFarmerFleet.editMachine(farmId, personId, machineId, xmlFilename)
    local F = TheContractorFarmerFleet
    local farmers = g_currentMission.TheContractor.Farmers
    local person = farmers:getPerson(personId)
    local catalog = F.buildCatalog()
    local problem = F.getEditProblem(farmId, person, machineId, xmlFilename, catalog)
    local repickedId = nil
    if problem ~= nil then
        TCLog.warning("TheContractor: farm %d's change of person %d's machine %d to %s refused: %s", farmId,
            personId, machineId, tostring(xmlFilename), problem)
    else
        local machine = F.getMachine(person, machineId)
        if machine.xmlFilename == xmlFilename then
            return nil
        end
        TCLog.info("TheContractor: farm %d changed farmer #%d's %s (machine %d): %s -> %s", farmId, personId,
            tostring(machine.role), machineId, machine.xmlFilename, xmlFilename)
        local repicked = F.applyEdit(person, machine, xmlFilename, catalog, math.random)
        repickedId = repicked ~= nil and repicked.id or nil
        farmers:onFleetChanged(personId)
        if g_server ~= nil then
            g_server:broadcastEvent(TCFarmerFleetEvent.new(person))
        end
    end
    F.onEditResult(farmId, personId, machineId, problem, repickedId)
    if g_server ~= nil then
        g_server:broadcastEvent(TCEditFarmerMachineEvent.newResult(farmId, personId, machineId, problem, repickedId))
    end
    return problem
end

-- Every machine: how a farm's edit went, for its menu (which tells the
-- player who asked).
function TheContractorFarmerFleet.onEditResult(farmId, personId, machineId, problem, repickedId)
    local menu = g_currentMission.TheContractor.MenuContractor
    if farmId == g_currentMission:getFarmId() and menu ~= nil and menu.onFarmerMachineEdited ~= nil then
        menu:onFarmerMachineEdited(personId, machineId, problem, repickedId)
    end
end

-- Wire (122): what clients hold of a fleet. nil goes as none.
function TheContractorFarmerFleet.writeStream(streamId, machines)
    streamWriteInt32(streamId, machines ~= nil and #machines or 0)
    for _, machine in ipairs(machines or {}) do
        streamWriteInt32(streamId, machine.id)
        streamWriteString(streamId, machine.role or "")
        streamWriteString(streamId, machine.xmlFilename)
        streamWriteInt32(streamId, machine.attachedTo or 0)
    end
end

-- The machines, or nil with none (as a farmer's record has).
function TheContractorFarmerFleet.readStream(streamId)
    local count = streamReadInt32(streamId)
    if count == 0 then
        return nil
    end
    local machines = {}
    for _ = 1, count do
        local machine = { id = streamReadInt32(streamId) }
        local role = streamReadString(streamId)
        machine.role = role ~= "" and role or nil
        machine.xmlFilename = streamReadString(streamId)
        local attachedTo = streamReadInt32(streamId)
        machine.attachedTo = attachedTo ~= 0 and attachedTo or nil
        table.insert(machines, machine)
    end
    return machines
end

-- Showing them -------------------------------------------------------------------------------

-- A model's brand and name, or its file when the store hasn't got it.
function TheContractorFarmerFleet.getModelName(xmlFilename)
    local storeItem = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(xmlFilename) or nil
    if storeItem == nil then
        return xmlFilename
    end
    local brand = getBrandName(storeItem)
    local name = storeItem.name or xmlFilename
    return brand ~= "" and (brand .. " " .. name) or name
end

function TheContractorFarmerFleet.getRoleText(role)
    return g_i18n:getText("tc_fleet_role_" .. tostring(role))
end

-- A fleet in list order (ROLE_ORDER, then id).
function TheContractorFarmerFleet.getSorted(machines)
    local rank = {}
    for index, role in ipairs(TheContractorFarmerFleet.ROLE_ORDER) do
        rank[role] = index
    end
    local sorted = TheContractorFarmerFleet.copy(machines or {})
    table.sort(sorted, function(a, b)
        local rankA, rankB = rank[a.role] or math.huge, rank[b.role] or math.huge
        if rankA ~= rankB then
            return rankA < rankB
        end
        return a.id < b.id
    end)
    return sorted
end

-- Console ------------------------------------------------------------------------------------

local getModelName = TheContractorFarmerFleet.getModelName

-- tcCompany farmers fleet [farmer]: each farmer's machines.
function TheContractorFarmerFleet.getListText(wanted)
    local tc = g_currentMission.TheContractor
    local environment = g_currentMission.environment
    local land = TheContractorFarmers.getLand()
    local lines = {}
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        if wanted == nil or tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted) then
            table.insert(lines, string.format("#%d %s (%.0f acres, %s): %d machine(s)", farmer.id, farmer.name,
                TheContractorFarmers.getAcres(farmer, land),
                farmer.yardFarmlandId ~= nil and ("yard " .. farmer.yardFarmlandId) or "no yard",
                #(farmer.machines or {})))
            for _, machine in ipairs(farmer.machines or {}) do
                local hours = TheContractorFarmerFleet.getHours(machine, environment.currentMonotonicDay,
                    environment.daysPerPeriod)
                table.insert(lines, string.format("  %d %s: %s%s%s%s", machine.id, tostring(machine.role),
                    getModelName(machine.xmlFilename),
                    machine.attachedTo ~= nil and (", on " .. machine.attachedTo) or "",
                    hours ~= nil and string.format(", %.0f h", hours) or "",
                    TheContractorFarmerFleet.isMachineOut(farmer.id, machine.id) and ", out now" or ""))
            end
        end
    end
    if #lines == 0 then
        return wanted ~= nil and string.format("No farmer %s (tcCompany farmers lists them).", wanted) or
            "No farmers yet."
    end
    return table.concat(lines, "\n")
end
