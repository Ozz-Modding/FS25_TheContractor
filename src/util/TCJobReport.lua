-- The job report (tcDebug jobReport, the dev dialog's Reports page): why a
-- farm is or isn't being offered a job type, written to a text file a
-- player can send in with a bug report ("I never get harvest jobs").
--
-- It runs the generator's own checks (JobGeneration's getTypeRejection,
-- getFieldRejection, getWorkWindowStart, getLastDoableDay,
-- getAvailabilitySnapshot), never copies of them, so it can't drift from
-- what the hourly roll does. Every field on the map gets a verdict:
--
--   typeRejected   the job type can't happen on this save at all
--   owned / protected / notEligible / customerRefuses   getFieldRejection
--   unpredictable  harvest: the crop isn't ready and its ready day can't be
--                  predicted (TCCropPrediction)
--   notDoable      no deadline: the job isn't doable from the work window's
--                  start through the earliest day an offer can be due
--   offerable      the roll could offer it
--
-- Server only: field states, the NPC plan and relationships live there.
-- collect() builds plain data and format() the lines, so tests check the
-- data and never the wording. A testing tool, so its text is plain English
-- like the console's, not l10n.

TCJobReport = {}

TCJobReport.FILENAME = "jobReport.txt"
-- modSettings/FS25_TheContractor/; g_currentModSettingsDirectory is only
-- set while the mod's scripts are sourced.
TCJobReport.settingsDir = g_currentModSettingsDirectory

TCJobReport.VERDICT_TEXTS = {
    typeRejected = "the job type can't happen on this save",
    owned = "owned by a player farm",
    protected = "protected (a live job on it, or an auction or show site)",
    notEligible = "doesn't qualify for this job type now",
    customerRefuses = "its farmer won't work with this farm",
    unpredictable = "crop not ready, and its ready day can't be predicted",
    notDoable = "no workable deadline (not doable through the earliest due day)",
    offerable = "OFFERABLE",
}

TCJobReport.CROP_TEXTS = {
    invalidState = "no valid field state",
    noCrop = "no crop",
    catchCrop = "catch crop",
    grass = "grass (mow and bale work)",
}

TCJobReport.GROWTH_MODE_NAMES = { "seasonal", "daily", "off" }

-- Why a harvest (cropDependent) type turns a field down by its crop, as a
-- key, or nil if the crop qualifies: the same rules as isFieldEligible.
function TCJobReport.getCropIneligibility(fieldState)
    if fieldState == nil or not fieldState.isValid then
        return "invalidState"
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex)
    if fruitType == nil then
        return "noCrop"
    end
    if fruitType:getIsCatchCrop() then
        return "catchCrop"
    end
    if TheContractorJobGeneration.isGrass(fruitType.index) then
        return "grass"
    end
    return nil
end

-- The growth state the field's crop moves to at the next month change
-- (seasonal growth's mapping for this month), or nil.
function TCJobReport.getNextGrowthState(fruitType, growthState)
    if fruitType == nil or growthState == nil or fruitType.getSeasonalGrowthData == nil then
        return nil
    end
    local growthData = fruitType:getSeasonalGrowthData()
    local periodInfo = growthData ~= nil and growthData.periods ~= nil and
        growthData.periods[g_currentMission.environment.currentPeriod] or nil
    if periodInfo == nil or periodInfo.growthMapping == nil then
        return nil
    end
    return periodInfo.growthMapping[growthState]
end

-- About what share of offers goes to this type right now: pickJobType's
-- split (FULFILLABLE_TYPE_SHARE across the types the farm can do, the rest
-- across every type with work, each by its offerWeight), from
-- getAvailabilitySnapshot. Only types with a datable field count, since a
-- roll re-picks past the rest.
function TCJobReport.estimateTypeShare(snapshot, jobType)
    local datableWeight, fulfillableWeight, entry = 0, 0, nil
    for _, item in ipairs(snapshot) do
        local weight = TheContractorJobGeneration.getOfferWeight(TheContractorJobGeneration.JOB_TYPES[item.jobType])
        if item.datable > 0 then
            datableWeight = datableWeight + weight
        end
        if item.fulfillable > 0 then
            fulfillableWeight = fulfillableWeight + weight
        end
        if item.jobType == jobType then
            entry = item
        end
    end
    if entry == nil or entry.datable == 0 then
        return 0
    end
    local weight = TheContractorJobGeneration.getOfferWeight(TheContractorJobGeneration.JOB_TYPES[jobType])
    if fulfillableWeight == 0 then
        return weight / datableWeight
    end
    local share = TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
    local fulfillablePart = entry.fulfillable > 0 and share * weight / fulfillableWeight or 0
    return fulfillablePart + (1 - share) * weight / datableWeight
end

-- One field's row: what's on it, and the generator's verdict for the type.
function TCJobReport.collectField(generation, farmId, field, jobDef, typeRejection, vehicles, missingByCrop)
    local fieldId = field:getId()
    local tc = g_currentMission.TheContractor
    local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
    local row = {
        fieldId = fieldId,
        farmlandId = farmland ~= nil and farmland:getId() or nil,
        areaHa = field.getAreaHa ~= nil and field:getAreaHa() or nil,
        owner = field:getOwner(),
        customerId = tc.Farmers:getCustomerIdForField(fieldId),
    }

    local fieldState = field:getFieldState()
    local fruitType = fieldState ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    row.isValid = fieldState ~= nil and fieldState.isValid == true
    if fruitType ~= nil then
        row.crop = fruitType.name
        row.growthState = fieldState.growthState
        row.readyNow = fruitType:getIsHarvestReady(fieldState.growthState) == true
        row.withered = fruitType.getIsWithered ~= nil and fruitType:getIsWithered(fieldState.growthState) == true
        row.nextGrowthState = TCJobReport.getNextGrowthState(fruitType, fieldState.growthState)
    end
    if jobDef.cropDependent then
        row.cropIneligibility = TCJobReport.getCropIneligibility(fieldState)
    end

    if typeRejection ~= nil then
        row.verdict = "typeRejected"
        return row
    end
    local rejection = TheContractorJobGeneration.getFieldRejection(farmId, field, jobDef)
    if rejection ~= nil then
        row.verdict = rejection
        return row
    end

    local workStartDay, earliest = generation:getWorkWindowStart(field, jobDef)
    if workStartDay == nil then
        row.verdict = "unpredictable"
    else
        row.workStartDay = workStartDay
        row.earliestDay = earliest
        row.lastDoableDay = generation:getLastDoableDay(field, jobDef, workStartDay,
            earliest + TheContractorJobGeneration.MAX_EXTRA_DAYS)
        if row.lastDoableDay ~= nil and row.lastDoableDay >= earliest then
            row.verdict = "offerable"
        else
            row.verdict = "notDoable"
        end
    end

    -- What the farm lacks for it (033's fulfillable), worked out once per crop.
    local fruitTypeIndex = nil
    if jobDef.cropDependent then
        fruitTypeIndex = fieldState.fruitTypeIndex
    elseif jobDef.recordsPlannedCrop then
        fruitTypeIndex = field:getPlannedFruitTypeIndex()
    end
    local key = fruitTypeIndex or 0
    if missingByCrop[key] == nil then
        missingByCrop[key] = TCEquipmentClass.getMissingEquipment(vehicles, jobDef, fruitTypeIndex)
    end
    row.missingEquipment = missingByCrop[key]
    return row
end

-- The farm's machines that matter to a harvest: harvesters and headers,
-- with the crops each takes (nil means it isn't one).
function TCJobReport.collectHarvestKit(vehicles)
    local kit = {}
    for _, vehicle in ipairs(vehicles) do
        local isHarvester = TCEquipmentClass.isHarvester(vehicle)
        local cutter = vehicle.spec_cutter
        if isHarvester or cutter ~= nil then
            local crops = {}
            if cutter ~= nil and cutter.fruitTypeIndices ~= nil then
                for _, index in ipairs(cutter.fruitTypeIndices) do
                    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(index)
                    table.insert(crops, fruitType ~= nil and fruitType.name or tostring(index))
                end
            end
            table.insert(kit, {
                name = vehicle.getFullName ~= nil and vehicle:getFullName() or "?",
                isHarvester = isHarvester,
                hasCutter = cutter ~= nil,
                crops = crops,
                propertyState = vehicle.propertyState,
            })
        end
    end
    return kit
end

-- Everything the report says, as data.
function TCJobReport.collect(farmId, jobType)
    local mission = g_currentMission
    local tc = mission.TheContractor
    local generation = tc.JobGeneration
    local environment = mission.environment
    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]

    local data = {
        farmId = farmId,
        jobType = jobType,
        today = environment.currentMonotonicDay,
        period = environment.currentPeriod,
        dayInPeriod = environment.currentDayInPeriod,
        hour = environment.currentHour,
        daysPerPeriod = environment.daysPerPeriod,
        plannedDaysPerPeriod = environment.plannedDaysPerPeriod,
        growthMode = mission.missionInfo.growthMode,
        weedsEnabled = mission.missionInfo.weedsEnabled,
        stonesEnabled = mission.missionInfo.stonesEnabled,
        limeRequired = mission.missionInfo.limeRequired,
        economicDifficulty = mission.missionInfo.economicDifficulty,
        isMultiplayer = mission.missionDynamicInfo ~= nil and mission.missionDynamicInfo.isMultiplayer == true,
        hasCompany = tc.Company:hasCompany(farmId),
        reputationScore = tc.Reputation:getReputationScore(farmId),
        reputationTier = tc.Reputation:getReputationTier(farmId),
        standing = tc.Reputation:getStanding(farmId),
        hourlyChance = generation:getHourlyChance(farmId),
        typeRejection = TheContractorJobGeneration.getTypeRejection(farmId, jobDef),
    }
    data.hitsPerPeriod = data.hourlyChance * 24 * data.daysPerPeriod

    data.settings = {}
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        table.insert(data.settings, { id = id, value = tc.Settings:get(id) })
    end

    -- Refreshes every field's state first, as a roll does.
    data.snapshot = generation:getAvailabilitySnapshot(farmId)
    data.typeShare = TCJobReport.estimateTypeShare(data.snapshot, jobType)

    -- The farm's jobs still held (finished ones are trimmed at save).
    data.jobCounts, data.liveJobs = {}, {}
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        local counts = data.jobCounts[job.jobType] or { total = 0, byState = {} }
        counts.total = counts.total + 1
        counts.byState[job.state] = (counts.byState[job.state] or 0) + 1
        data.jobCounts[job.jobType] = counts
        if not job:isTerminal() then
            table.insert(data.liveJobs, { id = job.id, jobType = job.jobType, fieldId = job.fieldId,
                state = job.state, deadlineDay = job.deadlineDay })
        end
    end
    table.sort(data.liveJobs, function(a, b) return a.id < b.id end)

    local vehicles = TheContractorJobGeneration.getFarmVehicles(farmId)
    data.vehicleCount = #vehicles
    if jobDef.cropDependent then
        data.harvestKit = TCJobReport.collectHarvestKit(vehicles)
    end

    data.fields, data.verdictCounts = {}, {}
    local missingByCrop = {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        local row = TCJobReport.collectField(generation, farmId, field, jobDef, data.typeRejection, vehicles,
            missingByCrop)
        table.insert(data.fields, row)
        data.verdictCounts[row.verdict] = (data.verdictCounts[row.verdict] or 0) + 1
    end
    table.sort(data.fields, function(a, b) return a.fieldId < b.fieldId end)

    data.mods = {}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        for _, mod in ipairs(g_modManager:getActiveMods()) do
            table.insert(data.mods, { name = mod.modName, version = mod.version })
        end
    end
    local ownMod = g_modManager ~= nil and TheContractor.modName ~= nil and
        g_modManager:getModByName(TheContractor.modName) or nil
    data.modVersion = ownMod ~= nil and ownMod.version or nil
    data.mapId = mission.missionInfo.mapId
    return data
end

-- Formatting -------------------------------------------------------------------------

local function dayText(day)
    if day == nil then
        return "-"
    end
    return string.format("%s (day %d)", TCCalendar.formatDayShort(day), day)
end

local function flag(value)
    if value == nil then
        return "-"
    end
    return value and "yes" or "no"
end

-- The report as lines of text.
function TCJobReport.format(data)
    local lines = {}
    local function add(text, ...)
        table.insert(lines, select("#", ...) > 0 and string.format(text, ...) or text)
    end

    add("The Contractor: job report for '%s' jobs", data.jobType)
    add("Written %s. Please send this file, with your log.txt, along with your bug report.",
        getDate ~= nil and getDate("%Y-%m-%d %H:%M") or "?")
    add("")
    add("== Game ==")
    add("Mod version %s, map %s, %s", tostring(data.modVersion), tostring(data.mapId),
        data.isMultiplayer and "multiplayer" or "single player")
    add("Today: %s, %02d:00 (month %d, day %d of %d; days per month planned: %s)", dayText(data.today), data.hour,
        data.period, data.dayInPeriod, data.daysPerPeriod, tostring(data.plannedDaysPerPeriod))
    add("Growth: %s. Weeds %s, stones %s, lime required %s, economic difficulty %s",
        TCJobReport.GROWTH_MODE_NAMES[data.growthMode or 0] or tostring(data.growthMode), flag(data.weedsEnabled),
        flag(data.stonesEnabled), flag(data.limeRequired), tostring(data.economicDifficulty))
    local settings = {}
    for _, setting in ipairs(data.settings) do
        table.insert(settings, string.format("%s=%s", setting.id, tostring(setting.value)))
    end
    add("Settings: %s", table.concat(settings, ", "))
    add("")

    add("== Farm %d ==", data.farmId)
    add("Company: %s. Reputation %s (%s, standing %.2f)", flag(data.hasCompany), tostring(data.reputationScore),
        data.reputationTier ~= nil and data.reputationTier.key or "?", data.standing or 0)
    add("Offer rolls: hourly chance %.4f, about %.1f offers a month (%.1f a day), plus a daily floor of one",
        data.hourlyChance, data.hitsPerPeriod, data.hitsPerPeriod / math.max(data.daysPerPeriod, 1))
    add("Share of offers going to '%s' right now: about %d%% (about %.1f a month)", data.jobType,
        math.floor(data.typeShare * 100 + 0.5), data.typeShare * data.hitsPerPeriod)
    if data.typeRejection ~= nil then
        add("'%s' can't happen on this save: %s", data.jobType,
            TheContractorJobGeneration.TYPE_REJECTION_TEXTS[data.typeRejection])
    end
    add("")

    add("== Every job type right now ==")
    add("(eligible fields / with a workable deadline / the farm has the kit for)")
    for _, entry in ipairs(data.snapshot) do
        add("  %-13s %3d / %3d / %3d", entry.jobType, entry.candidates, entry.datable, entry.fulfillable)
    end
    add("")

    add("== This farm's jobs held in the save ==")
    local types = {}
    for jobType in pairs(data.jobCounts) do
        table.insert(types, jobType)
    end
    table.sort(types)
    for _, jobType in ipairs(types) do
        local counts = data.jobCounts[jobType]
        local states = {}
        for state, count in pairs(counts.byState) do
            table.insert(states, string.format("%s %d", state, count))
        end
        table.sort(states)
        add("  %-13s %3d (%s)", jobType, counts.total, table.concat(states, ", "))
    end
    if #types == 0 then
        add("  none")
    end
    for _, job in ipairs(data.liveJobs) do
        add("  live: job %d %s on field %s, %s, due %s", job.id, job.jobType, tostring(job.fieldId), job.state,
            dayText(job.deadlineDay))
    end
    add("")

    if data.harvestKit ~= nil then
        add("== Harvest kit (%d vehicles on the farm) ==", data.vehicleCount)
        for _, item in ipairs(data.harvestKit) do
            local kind = item.isHarvester and (item.hasCutter and "harvester with its own cutter" or "harvester")
                or "header"
            add("  %s: %s, property state %s%s", item.name, kind, tostring(item.propertyState),
                #item.crops > 0 and (", cuts " .. table.concat(item.crops, " ")) or "")
        end
        if #data.harvestKit == 0 then
            add("  no harvesters or headers")
        end
        add("")
    end

    add("== Fields ==")
    local verdicts = {}
    for verdict, count in pairs(data.verdictCounts) do
        table.insert(verdicts, string.format("%s %d", verdict, count))
    end
    table.sort(verdicts)
    add("Verdicts: %s", table.concat(verdicts, ", "))
    add("(field, farmland, ha, owner, customer, crop, growth state now > next month, ready now, withered: verdict)")
    for _, row in ipairs(data.fields) do
        local text = string.format("  field %d, farmland %s, %.2f ha, owner %s, customer %s, %s, %s > %s, ready %s, withered %s: %s",
            row.fieldId, tostring(row.farmlandId), row.areaHa or 0, tostring(row.owner), tostring(row.customerId),
            row.crop or (row.isValid and "no crop" or "invalid state"), tostring(row.growthState),
            tostring(row.nextGrowthState), flag(row.readyNow), flag(row.withered),
            TCJobReport.VERDICT_TEXTS[row.verdict] or row.verdict)
        if row.cropIneligibility ~= nil and row.verdict == "notEligible" then
            text = text .. " - " .. TCJobReport.CROP_TEXTS[row.cropIneligibility]
        end
        if row.workStartDay ~= nil then
            text = text .. string.format("; work from %s, earliest due %s, doable to %s", dayText(row.workStartDay),
                dayText(row.earliestDay), dayText(row.lastDoableDay))
        end
        if row.missingEquipment ~= nil then
            text = text .. (#row.missingEquipment == 0 and "; farm has the kit" or
                ("; farm lacks: " .. table.concat(row.missingEquipment, ", ")))
        end
        add(text)
    end
    add("")

    add("== Active mods ==")
    for _, mod in ipairs(data.mods) do
        add("  %s %s", tostring(mod.name), tostring(mod.version))
    end
    return lines
end

-- Writes the report to modSettings/FS25_TheContractor/ on this machine.
-- Returns the path, or nil if it couldn't be written.
function TCJobReport.write(farmId, jobType)
    local dir = TCJobReport.settingsDir
    if dir == nil or createFile == nil or fileWrite == nil or FileAccess == nil then
        return nil
    end
    local lines = TCJobReport.format(TCJobReport.collect(farmId, jobType))
    if createFolder ~= nil then
        createFolder(dir)
    end
    local path = dir .. TCJobReport.FILENAME
    local file = createFile(path, FileAccess.WRITE)
    if file == nil or file == 0 then
        return nil
    end
    fileWrite(file, table.concat(lines, "\r\n") .. "\r\n")
    delete(file)
    TCLog.info("TheContractor: wrote the %s job report to %s", jobType, path)
    return path
end

function TCJobReport.registerConsoleCommands()
    TCConsole.register("debug", "jobReport", {
        args = "[jobType]",
        description = "Write a report of why this farm is or isn't offered a job type (default harvest) to a file to send in",
        run = function(farmId, args)
            local jobType = TheContractorJobGeneration.findJobType(args[1] or "harvest")
            if jobType == nil then
                return string.format("Unknown job type '%s'. Job types: %s", tostring(args[1]),
                    table.concat(TheContractorJobGeneration.JOB_TYPE_KEYS, ", "))
            end
            local path = TCJobReport.write(farmId, jobType)
            if path == nil then
                return "Couldn't write the report on this machine."
            end
            return "Wrote file to " .. path
        end,
    })
end
