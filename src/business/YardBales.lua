-- Bales to a farmer's yard (124), a random event (068): a farmer with a
-- yard (108) is short of hay, straw or silage, has heard the farm has some, and
-- rings up: can the player bring their own bales over? The job is putting
-- them on the ground in a marked area of the yard. The farmer's telehandler
-- and bale fork (121) are waiting beside it, for the player to use or not.
--
-- What the farm holds (getHoldings, server, at the roll): its loose bales
-- (itemSystem items that are a Bale of the farm's, not fermenting, and not
-- a job's own spawned bales) and its bales in a bale storage it owns
-- (PlaceableObjectStorage's storedObjects: a baleAttributes, or a
-- baleObject for one kept live), of STRAW, hay (DRYGRASS_WINDROW) and
-- SILAGE (a wrapped bale once it's fermented: until then it's grass), by
-- fill type and size (a bale's litres, to SIZE_STEP). Other mods replace
-- these objects, so every field is nil-checked.
--
-- What's asked for (pickBales): one fill type, in the size the farm holds
-- most of, ASK_SHARE of those bales (MIN_BALES to MAX_BALES, never more
-- than it holds). Fewer than MIN_BALES of that size, no offer. The job
-- counts litres (count x size); the bale count is only for display.
--
-- When: RATE_PER_PERIOD a month, WINTER_FACTOR times that in winter (feed
-- runs short), in TRIGGER_HOURS, one at a time per farm and per farmer. The
-- farmer has a yard no player owns, isn't fallen out with the farm (113),
-- and is picked by the relationship's offer weight. Their telehandler and
-- bale fork have to be free (not out, 121), and the yard needs room for
-- the drop area with the telehandler beside it, or there's no offer.
--
-- The drop area (pickDropArea): DROP_WIDTH x DROP_LENGTH on open ground
-- (108's test every AREA_STEP), centred on one of the yard's synced spots
-- (114's) facing the yard's middle, with the telehandler's footprint open
-- beside it. Picked on the server as the offer is made, saved and sent
-- with the job (job.yardDelivery). A map marker (TCJobHotspots, a circle
-- just covering the area), a marking on the ground (MARKING_FILENAME, a
-- parking slot's striped border as terrain decals, DROP_WIDTH x
-- DROP_LENGTH: keep the two the same) and vanilla's bale trigger icon over
-- its middle (ICON_FILENAME, a trigger marker, so the game's trigger marker
-- setting hides it: a yard can take in grassland that hides the marking)
-- show it while the job's taken on, on the job's farm's machines.
--
-- The job (JOB_TYPES' yardBales): the farmer is its customer, its field is
-- only the farmer's nearest one (offField), due in DUE_DAYS, allocated to
-- the farm's players as it's accepted (allocateOnAccept). Accepting it
-- brings the telehandler out through 100's queue (a loan arrival, no ADS),
-- fork hitched. It's a contract vehicle (not sold, not on our lists), never
-- locked for driving, and the farmer collects it once the job's over.
--
-- Delivering (server, every COUNT_INTERVAL_MS while allocated): each of the
-- farm's bales of the fill type put down in the area (lying still, not
-- mounted on a fork, loader or trailer) is delivered: it's gone, and its
-- litres go on the job's deliveredLiters (TCJobDeliveryEvent), largest
-- first (pickBalesToTake). Whole bales: the one that takes it past
-- requiredLiters goes whole, and the litres over are paid as excess at the
-- job's rate. Once it's covered the job completes, and any more in the
-- area stay the player's.
--
-- Pay: the litres asked for at the fill type's price (a vanilla price,
-- already EconomyScale's, so divided back to base) times PRICE_FACTOR, plus
-- CALL_OUT_FEE (base, scaled live as job prices are); the excess at the
-- same rate per litre. Reputation is per bale asked for (reputationPerItem
-- on job.workTotal), through quality as any player-driven job.
--
-- State: job.yardDelivery, with the job. The markings are this machine's
-- own (markings), never saved.

TheContractorYardBales = {}
TheContractorYardBales_mt = Class(TheContractorYardBales)

TheContractorYardBales.EVENT_TYPE = "yardBales"
TheContractorYardBales.JOB_TYPE = "yardBales"
TheContractorYardBales.MESSAGE_KIND = "yardBales"
-- 112: the offer is signed by the farmer (getCustomerNamedArgs).
TheContractorYardBales.NAMED_BODY_KEYS = { tc_yardBales_offerBody = true }

-- Straw, hay and silage. A wrapped grass bale is only silage once it's
-- fermented (vanilla changes its fill type then), so one still fermenting
-- is neither held nor delivered.
TheContractorYardBales.FILL_TYPE_NAMES = { "STRAW", "DRYGRASS_WINDROW", "SILAGE" }

-- The console's names for them.
TheContractorYardBales.CONSOLE_FILL_TYPES = { straw = "STRAW", hay = "DRYGRASS_WINDROW", silage = "SILAGE" }

-- About one every two months, twice that in winter.
TheContractorYardBales.RATE_PER_PERIOD = 0.5
TheContractorYardBales.WINTER_FACTOR = 2
TheContractorYardBales.COOLDOWN_PERIODS = 0
TheContractorYardBales.TRIGGER_HOURS = { 8, 15 }

-- How many bales: ASK_SHARE (a range) of those held of the commonest size,
-- MIN_BALES to MAX_BALES. A bale's size is its litres to SIZE_STEP.
TheContractorYardBales.MIN_BALES = 6
TheContractorYardBales.MAX_BALES = 24
TheContractorYardBales.ASK_SHARE = { 0.3, 0.7 }
TheContractorYardBales.SIZE_STEP = 100

-- Due this many days from today (a range): urgent.
TheContractorYardBales.DUE_DAYS = { 2, 3 }

-- Pay: the sell price times this, plus the call-out fee (base, pay).
TheContractorYardBales.PRICE_FACTOR = 1.2
TheContractorYardBales.CALL_OUT_FEE = 250

-- The drop area (metres), checked every AREA_STEP; the telehandler stands
-- KIT_GAP to one side of it.
TheContractorYardBales.DROP_WIDTH = 12
TheContractorYardBales.DROP_LENGTH = 12
TheContractorYardBales.AREA_STEP = 3
TheContractorYardBales.KIT_GAP = 2

-- Counting: how often, and how fast a bale can be moving (m/s) and still
-- count as put down.
TheContractorYardBales.COUNT_INTERVAL_MS = 500
TheContractorYardBales.MAX_RESTING_SPEED = 0.2

-- The marking on the ground (dev/tools/genBaleDropAreaI3d.py, made at
-- DROP_WIDTH x DROP_LENGTH), and how often a machine checks which it
-- should be showing.
TheContractorYardBales.MARKING_FILENAME = "i3d/baleDropArea.i3d"
-- The icon over the area's middle: vanilla's, as over a husbandry's bale
-- trigger, ICON_GROUND_OFFSET up as vanilla's trigger markers sit.
TheContractorYardBales.ICON_FILENAME = "$data/shared/assets/marker/markerIconBales.i3d"
TheContractorYardBales.ICON_GROUND_OFFSET = 0.03
TheContractorYardBales.MARKING_CHECK_MS = 1000

function TheContractorYardBales.new()
    local self = {}
    setmetatable(self, TheContractorYardBales_mt)

    -- Server: tcEvent trigger yardBales [straw|hay|silage] [farmer], for one trigger.
    self.forcedFillTypeName = nil
    self.forcedFarmerId = nil
    -- Every machine with a player: jobId -> { node, sharedLoadRequestId, x,
    -- z, rotY } for each drop area marked on the ground.
    self.markings = {}

    self.countMs = 0
    self.markingMs = TheContractorYardBales.MARKING_CHECK_MS

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorYardBales:register(randomEvents, inbox)
    randomEvents:registerEventType(TheContractorYardBales.EVENT_TYPE, {
        l10nKey = "tc_yardBales_eventName",
        cooldownPeriods = TheContractorYardBales.COOLDOWN_PERIODS,
        triggerHours = TheContractorYardBales.TRIGGER_HOURS,
        ratePerPeriod = function(farmId)
            return TheContractorYardBales.getRate(farmId)
        end,
        canTrigger = function(farmId)
            return self:pickRequest(farmId)
        end,
        stages = {
            { key = "asked", run = function(incident)
                return self:onAsked(incident)
            end },
        },
        console = {
            details = "[straw|hay|silage] [farmer]",
            prepareTrigger = function(farmId, details)
                return self:prepareTrigger(details)
            end,
            clearTrigger = function()
                self.forcedFillTypeName = nil
                self.forcedFarmerId = nil
            end,
        },
    })

    inbox:registerMessageKind(TheContractorYardBales.MESSAGE_KIND, {
        endsWithJob = true,
        category = "job",
        chipTone = "info",
        getArgs = function(message)
            return TheContractorInbox.getCustomerNamedArgs(message, TheContractorYardBales.NAMED_BODY_KEYS)
        end,
    })
end

-- Reading (every machine) -------------------------------------------------------------

local function isTakenOn(job)
    return job.state == TheContractorJob.STATE.ACCEPTED or job.state == TheContractorJob.STATE.ALLOCATED or
        job.state == TheContractorJob.STATE.IN_PROGRESS
end

local function isActive(job)
    return job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS
end

function TheContractorYardBales.getFillTypeIndex(yard)
    return g_fillTypeManager:getFillTypeIndexByName(yard.fillTypeName)
end

-- "Straw", "Hay": the fill type's own title.
function TheContractorYardBales.getFillTypeTitle(yard)
    local fillTypeIndex = TheContractorYardBales.getFillTypeIndex(yard)
    return fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex) or yard.fillTypeName
end

-- Whether a point is in the area (its centre, heading and size).
function TheContractorYardBales.isInArea(area, x, z)
    local dx, dz = x - area.x, z - area.z
    local sinY, cosY = math.sin(area.rotY or 0), math.cos(area.rotY or 0)
    local along = dx * sinY + dz * cosY
    local across = dx * cosY - dz * sinY
    return math.abs(across) <= area.width * 0.5 and math.abs(along) <= area.length * 0.5
end

-- The farm's open (not finished) yard bale jobs, and the farmers asking
-- (126: or with a load of theirs to sell on: one job in a yard at a time).
function TheContractorYardBales.getOpenJobs()
    local farms, farmers = {}, {}
    local jobs = g_currentMission.TheContractor.Jobs
    for farmId, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.yardDelivery ~= nil and not job:isTerminal() then
                farms[farmId] = true
                farmers[job.yardDelivery.farmerId or 0] = true
            elseif job.yardHaul ~= nil and not job:isTerminal() then
                farmers[job.yardHaul.farmerId or 0] = true
            end
        end
    end
    return farms, farmers
end

-- What the farm's paid for the litres over (yard.excessLiters), at today's
-- price level. 0 before the bales are taken.
function TheContractorYardBales.getExcessPay(job)
    local yard = job.yardDelivery
    if yard == nil or (yard.excessLiters or 0) <= 0 then
        return 0
    end
    return TCEconomyScale.scale(yard.excessLiters * (yard.pricePerLiter or 0))
end

-- The logbook's record of it (060): { fillTypeName, requiredLiters,
-- deliveredLiters, excessLiters, excessPay }, or nil for any other job.
function TheContractorYardBales.getLogbookDelivery(job)
    local yard = job.yardDelivery
    if yard == nil then
        return nil
    end
    return {
        fillTypeName = yard.fillTypeName,
        requiredLiters = job.requiredLiters,
        deliveredLiters = yard.takenLiters or job.deliveredLiters,
        excessLiters = yard.excessLiters or 0,
        excessPay = TheContractorYardBales.getExcessPay(job),
    }
end

-- TCJobProgress (server): the share delivered, never done until the
-- delivery's finished (so the sweep can't complete it first).
function TheContractorYardBales.getCompletion(job)
    local yard = job.yardDelivery
    if yard == nil or job.requiredLiters <= 0 then
        return 0
    end
    if yard.takenLiters ~= nil then
        return 1
    end
    return math.min(0.99, job.deliveredLiters / job.requiredLiters)
end

-- The status chip's text (every machine).
function TheContractorYardBales.getStatusText(job)
    local delivered = job.requiredLiters > 0 and math.floor(100 * job.deliveredLiters / job.requiredLiters) or 0
    return string.format(g_i18n:getText("tc_calendar_jobDeliveringOnly"), math.min(delivered, 100))
end

-- The job details' delivery row (every machine): "About 20 bales of straw
-- (80,000 l), 45% delivered".
function TheContractorYardBales.getDeliveryText(job)
    local yard = job.yardDelivery
    local text = string.format(g_i18n:getText("tc_yardBales_deliveryValue"), yard.baleCount or 0,
        g_i18n:getText("tc_yardBales_fill_" .. tostring(yard.fillTypeName)),
        g_i18n:formatVolume(job.requiredLiters, 0))
    if isActive(job) and job.requiredLiters > 0 then
        text = text .. string.format(g_i18n:getText("tc_yardBales_deliveredSuffix"),
            math.min(100, math.floor(100 * job.deliveredLiters / job.requiredLiters)))
    end
    return text
end

-- TCJobHotspots (every machine): the area's centre while it's taken on,
-- the circle as wide as the area's diagonal, so it just covers the area.
function TheContractorYardBales.getSpot(job)
    local yard = job.yardDelivery
    if yard == nil or not isTakenOn(job) then
        return nil
    end
    local width = yard.width or TheContractorYardBales.DROP_WIDTH
    local length = yard.length or TheContractorYardBales.DROP_LENGTH
    return { x = yard.x, z = yard.z, radius = math.sqrt(width * width + length * length) }
end

-- What the farm holds (server) ---------------------------------------------------------

-- A bale's size: its litres, to SIZE_STEP.
function TheContractorYardBales.getSize(fillLevel)
    local step = TheContractorYardBales.SIZE_STEP
    return math.floor((fillLevel or 0) / step + 0.5) * step
end

-- Counts one bale into holdings (fillTypeIndex -> size -> count), if it's
-- straw, hay or silage, has something in it and isn't fermenting.
function TheContractorYardBales.addBale(holdings, fillTypeIndex, fillLevel, isFermenting)
    if fillTypeIndex == nil or holdings[fillTypeIndex] == nil or isFermenting == true then
        return
    end
    local size = TheContractorYardBales.getSize(fillLevel)
    if size <= 0 then
        return
    end
    holdings[fillTypeIndex][size] = (holdings[fillTypeIndex][size] or 0) + 1
end

function TheContractorYardBales.newHoldings()
    local holdings = {}
    for _, name in ipairs(TheContractorYardBales.FILL_TYPE_NAMES) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex ~= nil then
            holdings[fillTypeIndex] = {}
        end
    end
    return holdings
end

-- The uniqueIds of bales a live job laid out (067's straw delivery, bale
-- wrap): those are the job's, not the farm's to sell on.
function TheContractorYardBales.getJobBaleIds()
    local ids = {}
    local jobs = g_currentMission.TheContractor.Jobs
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if not job:isTerminal() then
                for _, uniqueId in ipairs(job.spawnedBaleIds or {}) do
                    ids[uniqueId] = true
                end
            end
        end
    end
    return ids
end

local function isBale(object)
    return object ~= nil and object.isa ~= nil and Bale ~= nil and object:isa(Bale)
end

local function getOwner(object)
    return object.getOwnerFarmId ~= nil and object:getOwnerFarmId() or object.ownerFarmId
end

-- The farm's loose bales into holdings.
function TheContractorYardBales.addLooseBales(holdings, farmId)
    local itemSystem = g_currentMission.itemSystem
    local jobBaleIds = TheContractorYardBales.getJobBaleIds()
    for _, entry in pairs(itemSystem ~= nil and itemSystem.itemsToSave or {}) do
        local bale = entry.item
        if isBale(bale) and getOwner(bale) == farmId and
                not (bale.getUniqueId ~= nil and jobBaleIds[bale:getUniqueId()]) then
            TheContractorYardBales.addBale(holdings, bale.fillType, bale.fillLevel, bale.isFermenting)
        end
    end
end

-- The bales in the farm's bale storages into holdings: each stored object's
-- baleAttributes, or its baleObject when it's kept live.
function TheContractorYardBales.addStoredBales(holdings, farmId)
    local placeableSystem = g_currentMission.placeableSystem
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        local spec = placeable.spec_objectStorage
        if spec ~= nil and spec.storedObjects ~= nil and getOwner(placeable) == farmId then
            for _, object in ipairs(spec.storedObjects) do
                local attributes = object.baleAttributes
                local live = object.baleObject
                if attributes ~= nil then
                    TheContractorYardBales.addBale(holdings, attributes.fillType, attributes.fillLevel,
                        attributes.isFermenting)
                elseif live ~= nil then
                    TheContractorYardBales.addBale(holdings, live.fillType, live.fillLevel, live.isFermenting)
                end
            end
        end
    end
end

-- fillTypeIndex -> size -> count, for straw, hay and silage.
function TheContractorYardBales.getHoldings(farmId)
    local holdings = TheContractorYardBales.newHoldings()
    TheContractorYardBales.addLooseBales(holdings, farmId)
    TheContractorYardBales.addStoredBales(holdings, farmId)
    return holdings
end

-- The size held most of, and how many: size, count (bigger wins a tie).
function TheContractorYardBales.getCommonestSize(sizes)
    local bestSize, bestCount = nil, 0
    for size, count in pairs(sizes or {}) do
        if count > bestCount or (count == bestCount and bestSize ~= nil and size > bestSize) then
            bestSize, bestCount = size, count
        end
    end
    return bestSize, bestCount
end

-- What to ask for: { fillTypeIndex, baleSize, baleCount, liters }, or nil.
-- One fill type (forcedFillTypeIndex, or either the farm has enough of),
-- in its commonest size, ASK_SHARE of those held.
function TheContractorYardBales.pickBales(holdings, forcedFillTypeIndex, random)
    local Y = TheContractorYardBales
    local candidates = {}
    local fillTypeIndices = {}
    for fillTypeIndex in pairs(holdings) do
        table.insert(fillTypeIndices, fillTypeIndex)
    end
    table.sort(fillTypeIndices)
    for _, fillTypeIndex in ipairs(fillTypeIndices) do
        local size, count = Y.getCommonestSize(holdings[fillTypeIndex])
        if size ~= nil and count >= Y.MIN_BALES and
                (forcedFillTypeIndex == nil or forcedFillTypeIndex == fillTypeIndex) then
            table.insert(candidates, { fillTypeIndex = fillTypeIndex, size = size, count = count })
        end
    end
    if #candidates == 0 then
        return nil
    end
    local pick = candidates[math.min(#candidates, math.floor(random() * #candidates) + 1)]
    local share = Y.ASK_SHARE[1] + random() * (Y.ASK_SHARE[2] - Y.ASK_SHARE[1])
    local baleCount = math.floor(pick.count * share + 0.5)
    baleCount = math.max(Y.MIN_BALES, math.min(baleCount, Y.MAX_BALES, pick.count))
    return {
        fillTypeIndex = pick.fillTypeIndex,
        baleSize = pick.size,
        baleCount = baleCount,
        liters = baleCount * pick.size,
    }
end

-- The roll (server) ----------------------------------------------------------------------

function TheContractorYardBales.isWinter()
    local environment = g_currentMission.environment
    return Season ~= nil and environment.getSeasonAtDay ~= nil and
        environment:getSeasonAtDay(environment.currentMonotonicDay) == Season.WINTER
end

-- Expected asks a month (before the setting).
function TheContractorYardBales.getRate(farmId)
    local rate = TheContractorYardBales.RATE_PER_PERIOD
    if TheContractorYardBales.isWinter() then
        rate = rate * TheContractorYardBales.WINTER_FACTOR
    end
    return rate
end

-- A farmer's telehandler and its bale fork, both free: { machine,
-- attachment (its getAttachmentArrival), model (the telehandler's size) },
-- or nil.
function TheContractorYardBales.getKit(farmer)
    local F = TheContractorFarmerFleet
    for _, machine in ipairs(F.getMachinesByRole(farmer, F.ROLE.TELEHANDLER)) do
        local fork = F.getAttachment(farmer, machine)
        local model = F.getSizeModel(machine.xmlFilename)
        if fork ~= nil and fork.role == F.ROLE.BALE_FORK and model ~= nil and not F.isAnyOut(farmer, machine) then
            local attachment = F.getAttachmentArrival(farmer, machine)
            if attachment ~= nil then
                return { machine = machine, attachment = attachment, model = model }
            end
        end
    end
    return nil
end

-- The farmers who could ask: a yard no player owns, not asking any farm
-- already, the kit free, not fallen out with the farm. { { farmer, weight } }.
function TheContractorYardBales:getCandidateFarmers(farmId)
    local tc = g_currentMission.TheContractor
    local _, openFarmers = TheContractorYardBales.getOpenJobs()
    local candidates = {}
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        local weight = tc.Relationships:getOfferWeight(farmId, farmer.id)
        if (self.forcedFarmerId == nil or self.forcedFarmerId == farmer.id) and not farmer.isOfficial and
                weight > 0 and not openFarmers[farmer.id] and #(farmer.farmlandIds or {}) > 0 and
                TheContractorFieldBreakdowns.getUsableYard(farmer) ~= nil and
                TheContractorYardBales.getKit(farmer) ~= nil then
            table.insert(candidates, { farmer = farmer, weight = weight })
        end
    end
    return candidates
end

function TheContractorYardBales.pickWeighted(candidates, random)
    local total = 0
    for _, candidate in ipairs(candidates) do
        total = total + candidate.weight
    end
    local roll = random() * total
    for _, candidate in ipairs(candidates) do
        roll = roll - candidate.weight
        if roll < 0 then
            return candidate.farmer
        end
    end
    return candidates[#candidates] ~= nil and candidates[#candidates].farmer or nil
end

-- canTrigger (068): { farmerId, fillTypeName, baleSize, baleCount }, or nil.
function TheContractorYardBales:pickRequest(farmId)
    local openFarms = TheContractorYardBales.getOpenJobs()
    if openFarms[farmId] then
        return nil
    end
    local forced = self.forcedFillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(self.forcedFillTypeName)
        or nil
    local request = TheContractorYardBales.pickBales(TheContractorYardBales.getHoldings(farmId), forced, math.random)
    if request == nil then
        return nil
    end
    local farmer = TheContractorYardBales.pickWeighted(self:getCandidateFarmers(farmId), math.random)
    if farmer == nil then
        return nil
    end
    return {
        farmerId = farmer.id,
        fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(request.fillTypeIndex),
        baleSize = request.baleSize,
        baleCount = request.baleCount,
    }
end

-- The console's details: [straw|hay|silage] [farmer id or full name].
function TheContractorYardBales:prepareTrigger(details)
    local rest = {}
    for i, detail in ipairs(details) do
        local lower = string.lower(detail)
        local fillTypeName = TheContractorYardBales.CONSOLE_FILL_TYPES[lower]
        if i == 1 and fillTypeName ~= nil then
            self.forcedFillTypeName = fillTypeName
        else
            table.insert(rest, detail)
        end
    end
    if #rest == 0 then
        return nil
    end
    local wanted = table.concat(rest, " ")
    for _, farmer in ipairs(g_currentMission.TheContractor.Farmers:getFarmers()) do
        if tostring(farmer.id) == wanted or string.lower(farmer.name) == string.lower(wanted) then
            self.forcedFarmerId = farmer.id
            return nil
        end
    end
    self.forcedFillTypeName = nil
    return "Usage: tcEvent trigger yardBales [straw|hay|silage] [farmer id or name] (tcFarmer list)"
end

-- The drop area (server) -----------------------------------------------------------------

-- Whether a rectangle (centre, heading, size) is open ground in the yard,
-- every AREA_STEP across and along, edges included.
function TheContractorYardBales.isRectOpen(farmlandId, x, z, rotY, width, length, isOpen)
    local step = TheContractorYardBales.AREA_STEP
    local sinY, cosY = math.sin(rotY), math.cos(rotY)
    local acrossSteps = math.max(1, math.ceil(width / step))
    local alongSteps = math.max(1, math.ceil(length / step))
    for i = 0, acrossSteps do
        local across = -width * 0.5 + width * i / acrossSteps
        for j = 0, alongSteps do
            local along = -length * 0.5 + length * j / alongSteps
            if not isOpen(farmlandId, x + cosY * across + sinY * along, z - sinY * across + cosY * along) then
                return false
            end
        end
    end
    return true
end

-- Where the area and the telehandler go: { x, z, rotY, width, length,
-- kitX, kitZ, kitRotY }, or nil. Each of the yard's synced spots in random
-- order (and the yard's middle) as the area's centre, facing the middle,
-- with the kit's footprint (a model, with its attachment) to either side.
-- isOpen is TheContractorYards.isOpenGround (replaced in the tests).
function TheContractorYardBales.pickDropArea(farmlandId, footprint, random, isOpen)
    local Y = TheContractorYardBales
    isOpen = isOpen or TheContractorYards.isOpenGround
    local entry = g_currentMission.TheContractor.Yards:getSpots(farmlandId)
    if entry == nil then
        return nil
    end
    local centres = {}
    for _, spot in ipairs(entry.spots or {}) do
        table.insert(centres, { x = spot.x, z = spot.z })
    end
    for i = #centres, 2, -1 do
        local j = math.min(i, math.floor(random() * i) + 1)
        centres[i], centres[j] = centres[j], centres[i]
    end
    table.insert(centres, { x = entry.x, z = entry.z })

    local width, length = Y.DROP_WIDTH, Y.DROP_LENGTH
    for _, centre in ipairs(centres) do
        local dx, dz = entry.x - centre.x, entry.z - centre.z
        local rotY = (dx * dx + dz * dz > 0.01) and MathUtil.getYRotationFromDirection(dx, dz) or 0
        if Y.isRectOpen(farmlandId, centre.x, centre.z, rotY, width, length, isOpen) then
            local sinY, cosY = math.sin(rotY), math.cos(rotY)
            local offset = width * 0.5 + Y.KIT_GAP + footprint.width * 0.5
            for _, side in ipairs({ 1, -1 }) do
                local kitX, kitZ = centre.x + cosY * offset * side, centre.z - sinY * offset * side
                if Y.isRectOpen(farmlandId, kitX, kitZ, rotY, footprint.width, footprint.length, isOpen) then
                    return { x = centre.x, z = centre.z, rotY = rotY, width = width, length = length,
                        kitX = kitX, kitZ = kitZ, kitRotY = rotY }
                end
            end
        end
    end
    return nil
end

-- The farmer's field nearest a point (the job's field says where it is),
-- or nil.
function TheContractorYardBales.getNearestField(farmer, x, z)
    local held = {}
    for _, farmlandId in ipairs(farmer.farmlandIds or {}) do
        held[farmlandId] = true
    end
    local best, bestDistanceSq = nil, math.huge
    for _, field in ipairs(g_fieldManager:getFields()) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        if farmland ~= nil and held[farmland:getId()] then
            local fx, fz = field:getCenterOfFieldWorldPosition()
            local distanceSq = (fx - x) ^ 2 + (fz - z) ^ 2
            if distanceSq < bestDistanceSq then
                best, bestDistanceSq = field, distanceSq
            end
        end
    end
    return best
end

-- Pricing (server) ----------------------------------------------------------------------

-- The job's rate per litre, as a base amount: the fill type's sell price
-- (vanilla's, EconomyScale's already, so divided back out) times
-- PRICE_FACTOR.
function TheContractorYardBales.getBasePricePerLiter(fillTypeIndex)
    local economyManager = g_currentMission.economyManager
    local price = economyManager ~= nil and economyManager:getPricePerLiter(fillTypeIndex) or 0
    return price * TheContractorYardBales.PRICE_FACTOR / TCEconomyScale.getFactor()
end

-- The job's base price: the litres at the rate, plus the call-out fee.
function TheContractorYardBales.getBasePrice(liters, basePricePerLiter)
    return math.floor(liters * basePricePerLiter + TheContractorYardBales.CALL_OUT_FEE + 0.5)
end

-- The offer (server) ---------------------------------------------------------------------

function TheContractorYardBales:onAsked(incident)
    local tc = g_currentMission.TheContractor
    local Y = TheContractorYardBales
    local data = incident.data
    local farmer = tc.Farmers:getPerson(data.farmerId)
    local yardFarmlandId = farmer ~= nil and not farmer.isOfficial and
        TheContractorFieldBreakdowns.getUsableYard(farmer) or nil
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(data.fillTypeName)
    local kit = yardFarmlandId ~= nil and Y.getKit(farmer) or nil
    if kit == nil or fillTypeIndex == nil then
        TCLog.info("TheContractor: farm %d incident %d: farmer #%s has no yard or no telehandler free for bales",
            incident.farmId, incident.id, tostring(data.farmerId))
        return TheContractorRandomEvents.DONE
    end
    local footprint = TheContractorFarmerFleet.getFootprint(kit.model, kit.attachment)
    local area = Y.pickDropArea(yardFarmlandId, footprint, math.random)
    local field = area ~= nil and Y.getNearestField(farmer, area.x, area.z) or nil
    if field == nil then
        TCLog.info("TheContractor: farm %d incident %d: no room for bales in farmer #%d's yard %d", incident.farmId,
            incident.id, farmer.id, yardFarmlandId)
        return TheContractorRandomEvents.DONE
    end

    local liters = data.baleCount * data.baleSize
    local pricePerLiter = Y.getBasePricePerLiter(fillTypeIndex)
    local yard = {
        farmerId = farmer.id,
        yardFarmlandId = yardFarmlandId,
        fillTypeName = data.fillTypeName,
        baleSize = data.baleSize,
        baleCount = data.baleCount,
        liters = liters,
        pricePerLiter = pricePerLiter,
        x = area.x,
        z = area.z,
        rotY = area.rotY,
        width = area.width,
        length = area.length,
        kitX = area.kitX,
        kitZ = area.kitZ,
        kitRotY = area.kitRotY,
        machineId = kit.machine.id,
        attachmentMachineId = kit.attachment.machineId,
    }

    local environment = g_currentMission.environment
    local deadlineDay = environment.currentMonotonicDay + math.random(Y.DUE_DAYS[1], Y.DUE_DAYS[2])
    local job = tc.Jobs:createJob(incident.farmId, Y.JOB_TYPE, field:getId(), 1,
        TCCalendar.getPeriodFromDay(deadlineDay), TCCalendar.getDayInPeriodFromDay(deadlineDay),
        Y.getBasePrice(liters, pricePerLiter), true, nil, deadlineDay, false, nil, nil, nil, nil, yard)
    if job == nil then
        return TheContractorRandomEvents.DONE
    end
    -- Reputation is per bale asked for (JOB_TYPES' reputationPerItem).
    job.workTotal = data.baleCount

    tc.Inbox:postMessage(incident.farmId, Y.MESSAGE_KIND, "tc_yardBales_offerTitle", "tc_yardBales_offerBody",
        { "$l10n_tc_yardBales_fill_" .. data.fillTypeName, data.baleCount, "$volume_" .. liters }, nil,
        { incidentId = incident.id, jobId = job.id })
    TCLog.info("TheContractor: farm %d job %d: farmer #%d asks for %d %s bales of %.0f l (%.0f l) in yard %d, at %.0f, %.0f, for %.0f",
        incident.farmId, job.id, farmer.id, data.baleCount, data.fillTypeName, data.baleSize, liters, yardFarmlandId,
        area.x, area.z, job:getPrice())
    return TheContractorRandomEvents.DONE
end

-- The farmer's kit (server) ---------------------------------------------------------------

-- Jobs:onJobAccepted: the telehandler comes out, fork hitched.
function TheContractorYardBales:onJobAccepted(job)
    self:queueKit(job)
end

function TheContractorYardBales:queueKit(job)
    local tc = g_currentMission.TheContractor
    local yard = job.yardDelivery
    local farmer = tc.Farmers:getPerson(yard.farmerId)
    local machine = TheContractorFarmerFleet.getMachine(farmer, yard.machineId)
    local model = machine ~= nil and TheContractorFarmerFleet.getSizeModel(machine.xmlFilename) or nil
    if model == nil then
        TCLog.info("TheContractor: farm %d job %d: farmer #%s's telehandler is gone, no kit", job.farmId, job.id,
            tostring(yard.farmerId))
        return
    end
    local attachment = TheContractorFarmerFleet.getAttachmentArrival(farmer, machine)
    if attachment ~= nil and attachment.machineId ~= yard.attachmentMachineId then
        attachment = nil
    end
    tc.RepairContracts:queueLoanArrival(job.farmId, job.id, farmer, machine, model,
        { x = yard.kitX, z = yard.kitZ, rotY = yard.kitRotY, yardFarmlandId = yard.yardFarmlandId }, attachment)
end

-- RepairContracts: whether a loan arrival is still wanted (its job taken on,
-- its kit not out yet).
function TheContractorYardBales:isLoanWanted(entry)
    local job = g_currentMission.TheContractor.Jobs:getJob(entry.farmId, entry.jobId)
    return job ~= nil and job.yardDelivery ~= nil and isTakenOn(job) and (job.yardDelivery.kitVehicleId or 0) == 0
end

-- RepairContracts: the telehandler's in place (with its fork, or nil).
function TheContractorYardBales:onLoanArrived(entry, vehicle, attachment)
    if not self:isLoanWanted(entry) then
        TheContractorRepairContracts.deleteVehicle(vehicle)
        TheContractorRepairContracts.deleteVehicle(attachment)
        return
    end
    local job = g_currentMission.TheContractor.Jobs:getJob(entry.farmId, entry.jobId)
    self:applyKit(job.farmId, job.id, NetworkUtil.getObjectId(vehicle),
        attachment ~= nil and NetworkUtil.getObjectId(attachment) or 0)
    local yard = job.yardDelivery
    yard.kitUniqueId = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
    yard.kitAttachmentUniqueId = attachment ~= nil and attachment.getUniqueId ~= nil and attachment:getUniqueId() or nil
    if g_server ~= nil then
        g_server:broadcastEvent(TCYardBalesKitEvent.new(job.farmId, job.id, yard.kitVehicleId,
            yard.kitAttachmentId or 0))
    end
    TCLog.info("TheContractor: farm %d job %d: farmer #%d's %s is out in the yard%s", job.farmId, job.id,
        yard.farmerId, vehicle:getFullName(), attachment ~= nil and (" with the " .. attachment:getFullName()) or "")
end

-- Every machine (the server, and TCYardBalesKitEvent): the job's kit.
function TheContractorYardBales:applyKit(farmId, jobId, vehicleId, attachmentId)
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil or job.yardDelivery == nil then
        return
    end
    job.yardDelivery.kitVehicleId = vehicleId ~= 0 and vehicleId or nil
    job.yardDelivery.kitAttachmentId = attachmentId ~= 0 and attachmentId or nil
    TheContractorRepairContracts.clearCache()
end

-- The kit's vehicle ids (for the contract vehicles): { id, ... }.
function TheContractorYardBales.getKitIds(yard)
    local ids = {}
    if yard ~= nil and (yard.kitVehicleId or 0) ~= 0 then
        table.insert(ids, yard.kitVehicleId)
    end
    if yard ~= nil and (yard.kitAttachmentId or 0) ~= 0 then
        table.insert(ids, yard.kitAttachmentId)
    end
    return ids
end

-- Server: a finished job's kit goes home with the farmer.
function TheContractorYardBales:collectKit(job)
    local yard = job.yardDelivery
    local repairContracts = g_currentMission.TheContractor.RepairContracts
    if (yard.kitVehicleId or 0) ~= 0 then
        repairContracts:queueLoanCollection(job.farmId, yard.farmerId, yard.kitVehicleId, yard.kitUniqueId,
            yard.machineId)
    end
    if (yard.kitAttachmentId or 0) ~= 0 then
        repairContracts:queueLoanCollection(job.farmId, yard.farmerId, yard.kitAttachmentId,
            yard.kitAttachmentUniqueId, yard.attachmentMachineId)
    end
    yard.kitCollected = true
end

-- Counting and taking (server) ------------------------------------------------------------

-- Whether a bale counts for a job: the farm's, the fill type, put down
-- (not mounted, at rest) and in the area. Returns its litres, or nil.
function TheContractorYardBales.getCountedLiters(bale, job, fillTypeIndex)
    if not isBale(bale) or getOwner(bale) ~= job.farmId or bale.fillType ~= fillTypeIndex or bale.nodeId == nil then
        return nil
    end
    if bale.getIsMounted ~= nil and bale:getIsMounted() then
        return nil
    end
    if getLinearVelocity ~= nil then
        local vx, vy, vz = getLinearVelocity(bale.nodeId)
        if vx ~= nil and vx * vx + vy * vy + vz * vz > TheContractorYardBales.MAX_RESTING_SPEED ^ 2 then
            return nil
        end
    end
    local x, _, z = getWorldTranslation(bale.nodeId)
    if not TheContractorYardBales.isInArea(job.yardDelivery, x, z) then
        return nil
    end
    return bale.fillLevel or 0
end

-- The bales counting for a job: { { bale, liters } }, and their litres.
function TheContractorYardBales.getAreaBales(job)
    local fillTypeIndex = TheContractorYardBales.getFillTypeIndex(job.yardDelivery)
    local itemSystem = g_currentMission.itemSystem
    local bales, total = {}, 0
    for _, entry in pairs(itemSystem ~= nil and itemSystem.itemsToSave or {}) do
        local liters = TheContractorYardBales.getCountedLiters(entry.item, job, fillTypeIndex)
        if liters ~= nil and liters > 0 then
            table.insert(bales, { bale = entry.item, liters = liters })
            total = total + liters
        end
    end
    return bales, total
end

-- Which bales to take ({ bale, liters } each): whole bales, largest first,
-- until required is covered. Returns them, their litres and the excess.
function TheContractorYardBales.pickBalesToTake(bales, required)
    local sorted = {}
    for i, entry in ipairs(bales) do
        sorted[i] = entry
    end
    table.sort(sorted, function(a, b)
        return a.liters > b.liters
    end)
    local taken, liters = {}, 0
    for _, entry in ipairs(sorted) do
        if liters >= required then
            break
        end
        table.insert(taken, entry)
        liters = liters + entry.liters
    end
    return taken, liters, math.max(0, liters - required)
end

-- Every COUNT_INTERVAL_MS: each allocated job's area. What's put down in
-- it is delivered (gone), largest first, until the order's covered; then
-- the job completes, the excess paid on top (Jobs:completeJob).
function TheContractorYardBales:countJobs()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            local yard = job.yardDelivery
            if yard ~= nil and isActive(job) and yard.takenLiters == nil and job.requiredLiters > 0 then
                local bales = TheContractorYardBales.getAreaBales(job)
                local stillNeeded = job.requiredLiters - job.deliveredLiters
                local taken, liters = TheContractorYardBales.pickBalesToTake(bales, stillNeeded)
                if #taken > 0 then
                    for _, entry in ipairs(taken) do
                        entry.bale:delete()
                    end
                    local delivered = job.deliveredLiters + liters
                    yard.takenBales = (yard.takenBales or 0) + #taken
                    tc.Jobs:applyJobDelivery(job.farmId, job.id, delivered, job.requiredLiters)
                    if g_server ~= nil then
                        g_server:broadcastEvent(TCJobDeliveryEvent.new(job.farmId, job.id, delivered,
                            job.requiredLiters))
                    end
                    TCLog.info("TheContractor: farm %d job %d: %d bale(s), %.0f l delivered (%.0f of %.0f l)",
                        job.farmId, job.id, #taken, liters, delivered, job.requiredLiters)
                    if delivered >= job.requiredLiters then
                        self:finishDelivery(job)
                    end
                end
            end
        end
    end
end

-- The order's covered: the litres over are paid as excess, and the job
-- completes.
function TheContractorYardBales:finishDelivery(job)
    local yard = job.yardDelivery
    yard.takenLiters = job.deliveredLiters
    yard.excessLiters = math.max(0, job.deliveredLiters - job.requiredLiters)
    job.completionPercentage = 100
    TCLog.info("TheContractor: farm %d job %d: delivered, %.0f l over", job.farmId, job.id, yard.excessLiters)
    g_currentMission.TheContractor.Jobs:completeJob(job)
end

-- Server: kit for jobs that are over goes home.
function TheContractorYardBales:collectFinishedKit()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            if job.yardDelivery ~= nil and job:isTerminal() and not job.yardDelivery.kitCollected then
                self:collectKit(job)
            end
        end
    end
end

function TheContractorYardBales:update(dt)
    self.markingMs = self.markingMs + dt
    if self.markingMs >= TheContractorYardBales.MARKING_CHECK_MS then
        self.markingMs = 0
        self:refreshMarkings()
    end
    if not g_currentMission:getIsServer() then
        return
    end
    self.countMs = self.countMs + dt
    if self.countMs >= TheContractorYardBales.COUNT_INTERVAL_MS then
        self.countMs = 0
        self:countJobs()
        self:collectFinishedKit()
    end
end

-- The marking on the ground (every machine with a player) --------------------------------

-- jobId -> area for each of the local farm's jobs taken on.
function TheContractorYardBales.getWantedMarkings()
    local wanted = {}
    local tc = g_currentMission.TheContractor
    local farmId = g_currentMission:getFarmId()
    if g_client == nil or tc.Jobs == nil or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return wanted
    end
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if job.yardDelivery ~= nil and isTakenOn(job) then
            wanted[job.id] = job.yardDelivery
        end
    end
    return wanted
end

-- Loads a file's first node into the world at a point, turned to rotY:
-- node, sharedLoadRequestId, or nil if it won't load.
local function loadNodeAt(filename, x, y, z, rotY)
    local root, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(filename, false, false)
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: could not load the bale drop area's '%s'", filename)
        return nil
    end
    local node = getChildAt(root, 0)
    link(getRootNode(), node)
    delete(root)
    setTranslation(node, x, y, z)
    setRotation(node, 0, rotY, 0)
    return node, sharedLoadRequestId
end

-- Loads the marking at an area (its centre on the ground, turned to its
-- heading) and the icon over it, or nil if the marking won't load.
function TheContractorYardBales.loadMarking(area)
    local Y = TheContractorYardBales
    local y = getTerrainHeightAtWorldPos(g_terrainNode, area.x, 0, area.z)
    local node, sharedLoadRequestId = loadNodeAt(Utils.getFilename(Y.MARKING_FILENAME, TheContractor.dir), area.x, y,
        area.z, area.rotY or 0)
    if node == nil then
        return nil
    end
    local marking = { node = node, sharedLoadRequestId = sharedLoadRequestId, x = area.x, z = area.z,
        rotY = area.rotY }
    marking.iconNode, marking.iconLoadRequestId = loadNodeAt(Utils.getFilename(Y.ICON_FILENAME, nil), area.x,
        y + Y.ICON_GROUND_OFFSET, area.z, 0)
    if marking.iconNode ~= nil then
        g_currentMission:addTriggerMarker(marking.iconNode)
    end
    return marking
end

function TheContractorYardBales.deleteMarking(marking)
    if marking.iconNode ~= nil then
        g_currentMission:removeTriggerMarker(marking.iconNode)
        if entityExists(marking.iconNode) then
            delete(marking.iconNode)
        end
    end
    if marking.iconLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(marking.iconLoadRequestId)
    end
    if marking.node ~= nil and entityExists(marking.node) then
        delete(marking.node)
    end
    if marking.sharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(marking.sharedLoadRequestId)
    end
end

-- Every MARKING_CHECK_MS: a marking on each drop area wanted, and none on
-- any other (job state changes along many paths, so they're re-read, as
-- TCJobHotspots does).
function TheContractorYardBales:refreshMarkings()
    local wanted = TheContractorYardBales.getWantedMarkings()
    for jobId, marking in pairs(self.markings) do
        local area = wanted[jobId]
        if area == nil or area.x ~= marking.x or area.z ~= marking.z or area.rotY ~= marking.rotY then
            TheContractorYardBales.deleteMarking(marking)
            self.markings[jobId] = nil
        end
    end
    for jobId, area in pairs(wanted) do
        if self.markings[jobId] == nil then
            self.markings[jobId] = TheContractorYardBales.loadMarking(area)
        end
    end
end

-- At unload: every marking goes.
function TheContractorYardBales:delete()
    for _, marking in pairs(self.markings) do
        TheContractorYardBales.deleteMarking(marking)
    end
    self.markings = {}
end

-- After a load (server) ------------------------------------------------------------------

-- Every machine (TCVehicleReplace): a kit machine reloaded as a new object.
function TheContractorYardBales:remapVehicle(oldId, newId)
    for _, farmJobs in pairs(g_currentMission.TheContractor.Jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            TCVehicleIds.replaceField(job.yardDelivery, "kitVehicleId", oldId, newId)
            TCVehicleIds.replaceField(job.yardDelivery, "kitAttachmentId", oldId, newId)
        end
    end
end

-- TheContractor:resolveSavedVehicles, after Jobs' and RepairContracts': each
-- job's kit gets its object ids back, and a job taken on without its kit
-- (it never came out, or it's gone) sends for it again.
function TheContractorYardBales:resolveSavedVehicles()
    local tc = g_currentMission.TheContractor
    for _, farm in ipairs(g_farmManager:getFarms()) do
        for _, job in ipairs(tc.Jobs:getAllJobs(farm.farmId)) do
            local yard = job.yardDelivery
            if yard ~= nil then
                yard.kitVehicleId = yard.kitUniqueId ~= nil and TCVehicleIds.getObjectId(yard.kitUniqueId) or nil
                yard.kitAttachmentId = yard.kitAttachmentUniqueId ~= nil and
                    TCVehicleIds.getObjectId(yard.kitAttachmentUniqueId) or nil
                if isTakenOn(job) and yard.kitVehicleId == nil then
                    yard.kitUniqueId, yard.kitAttachmentUniqueId = nil, nil
                    TheContractorRepairContracts.deleteVehicle(yard.kitAttachmentId ~= nil and
                        NetworkUtil.getObject(yard.kitAttachmentId) or nil)
                    yard.kitAttachmentId = nil
                    self:queueKit(job)
                end
            end
        end
    end
    TheContractorRepairContracts.clearCache()
end

-- Sync and saves (with the job) -------------------------------------------------------------

local FLOAT_FIELDS = { "baleSize", "liters", "pricePerLiter", "x", "z", "rotY", "width", "length", "kitX", "kitZ",
    "kitRotY" }
local INT_FIELDS = { "farmerId", "yardFarmlandId", "baleCount", "machineId", "attachmentMachineId" }

-- What clients hold: all but the kit's uniqueIds and what's taken.
function TheContractorYardBales.writeStream(streamId, yard)
    if streamWriteBool(streamId, yard ~= nil) then
        streamWriteString(streamId, yard.fillTypeName or "")
        for _, name in ipairs(FLOAT_FIELDS) do
            streamWriteFloat32(streamId, yard[name] or 0)
        end
        for _, name in ipairs(INT_FIELDS) do
            streamWriteInt32(streamId, yard[name] or 0)
        end
        streamWriteInt32(streamId, yard.kitVehicleId or 0)
        streamWriteInt32(streamId, yard.kitAttachmentId or 0)
    end
end

function TheContractorYardBales.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local yard = { fillTypeName = streamReadString(streamId) }
    for _, name in ipairs(FLOAT_FIELDS) do
        yard[name] = streamReadFloat32(streamId)
    end
    for _, name in ipairs(INT_FIELDS) do
        yard[name] = streamReadInt32(streamId)
    end
    local kitVehicleId = streamReadInt32(streamId)
    local kitAttachmentId = streamReadInt32(streamId)
    yard.kitVehicleId = kitVehicleId ~= 0 and kitVehicleId or nil
    yard.kitAttachmentId = kitAttachmentId ~= 0 and kitAttachmentId or nil
    return yard
end

-- The kit by uniqueId (TCVehicleIds), turned back into object ids by
-- resolveSavedVehicles. The job's deliveredLiters is kept here too (Jobs
-- only saves haulage's), and comes back as yard.deliveredLiters.
function TheContractorYardBales.saveToXML(xmlFile, key, yard, deliveredLiters)
    setXMLString(xmlFile, key .. "#fillTypeName", yard.fillTypeName or "")
    for _, name in ipairs(FLOAT_FIELDS) do
        setXMLFloat(xmlFile, key .. "#" .. name, yard[name] or 0)
    end
    for _, name in ipairs(INT_FIELDS) do
        setXMLInt(xmlFile, key .. "#" .. name, yard[name] or 0)
    end
    setXMLFloat(xmlFile, key .. "#deliveredLiters", deliveredLiters or 0)
    setXMLInt(xmlFile, key .. "#takenBales", yard.takenBales or 0)
    local kitUniqueId = yard.kitUniqueId or TCVehicleIds.getUniqueId(yard.kitVehicleId)
    if kitUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#kitUniqueId", kitUniqueId)
    end
    local attachmentUniqueId = yard.kitAttachmentUniqueId or TCVehicleIds.getUniqueId(yard.kitAttachmentId)
    if attachmentUniqueId ~= nil then
        setXMLString(xmlFile, key .. "#kitAttachmentUniqueId", attachmentUniqueId)
    end
    if yard.kitCollected then
        setXMLBool(xmlFile, key .. "#kitCollected", true)
    end
    if yard.takenLiters ~= nil then
        setXMLFloat(xmlFile, key .. "#takenLiters", yard.takenLiters)
        setXMLFloat(xmlFile, key .. "#excessLiters", yard.excessLiters or 0)
    end
end

function TheContractorYardBales.loadFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local yard = { fillTypeName = getXMLString(xmlFile, key .. "#fillTypeName") or "" }
    for _, name in ipairs(FLOAT_FIELDS) do
        yard[name] = getXMLFloat(xmlFile, key .. "#" .. name) or 0
    end
    for _, name in ipairs(INT_FIELDS) do
        yard[name] = getXMLInt(xmlFile, key .. "#" .. name) or 0
    end
    yard.deliveredLiters = getXMLFloat(xmlFile, key .. "#deliveredLiters") or 0
    yard.takenBales = getXMLInt(xmlFile, key .. "#takenBales") or 0
    yard.kitUniqueId = getXMLString(xmlFile, key .. "#kitUniqueId")
    yard.kitAttachmentUniqueId = getXMLString(xmlFile, key .. "#kitAttachmentUniqueId")
    yard.kitCollected = getXMLBool(xmlFile, key .. "#kitCollected") == true
    yard.takenLiters = getXMLFloat(xmlFile, key .. "#takenLiters")
    yard.excessLiters = getXMLFloat(xmlFile, key .. "#excessLiters")
    return yard
end

-- Nothing of its own to save or send: its state travels with the jobs.
function TheContractorYardBales:writeInitialClientState(streamId, connection)
end

function TheContractorYardBales:readInitialClientState(streamId, connection)
end
