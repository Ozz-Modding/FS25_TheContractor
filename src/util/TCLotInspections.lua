-- Auction lot inspections (152): on a machinery auction's (137) sale day,
-- with FS25_AdvancedDamageSystem, farmers ask the contractor to give a
-- tractor lot a proper look over before its bidding closes. The job's an
-- ADS standard inspection of that lot (a complete one counts too, ADS's
-- quick visual one doesn't), for a small fee. The farmer only wants to know;
-- nobody bids for them.
--
--   Offered (server): once the lots are out on the sale day, from
--     OFFER_HOUR, once per auction (auction.inspectionsOffered, saved by
--     Auctions). COUNT requests, but never more than there are tractor lots
--     ADS looks after, or farmers to ask. They're shared round the company
--     farms evenly, in a shuffled order, so with fewer requests than farms
--     some get none. Each is a different lot and a different farmer: never
--     the official or the auction's host, and not one fallen out with the
--     farm (113), picked by the relationship's offer weight. Needs ADS to
--     treat lots as for sale (TCADSUsedLots.isSellerRegistered) and to say
--     what's been inspected (TCADSUsedLots.canReadInspections).
--   The job (JOB_TYPES' lotInspection, made only here): on the auction's
--     field (offField: the marker's on the lot), the farmer its customer,
--     the player's as it's accepted (allocateOnAccept), due by the lot's
--     closing time (deadlineDay the sale day, as a backstop). Its price is
--     PRICE at the default job pay rate (getBasePrice). job.lotInspection is { auctionId,
--     lotNumber, farmerId, xmlFilename, closeMinute } on every machine, and
--     on the server inspectionMark, where ADS's inspections of the lot stood
--     when it was offered (TCADSUsedLots.getInspectionMark).
--   Done (server, TCJobProgress): every part of the tractor inspected at
--     standard depth or deeper since the offer (TCADSUsedLots.
--     isInspectedSince): the impact wrench's standard inspection, or a
--     workshop's; a complete one counts, the quick visual one doesn't. ADS
--     doesn't say which farm did it, and each lot's offered to one farm.
--     A wrench scan started before the offer and finished after it the same
--     day goes into ADS's earlier record, so it doesn't count.
--   Ended (server): at the lot's close (AuctionSale:closeLot) an offer
--     lapses, and a job taken on is done if it's inspected, else missed.
--     A lot that's gone (it tipped over and was taken away) or an auction
--     called off takes an offer away and ends a job taken on with nothing
--     lost.
--
-- No state of its own but the auction's flag: the jobs carry their lot,
-- and Jobs saves and syncs them. Rule 099: nothing ADS found is read or
-- shown, only that an inspection was done.

TCLotInspections = {}

TCLotInspections.JOB_TYPE = "lotInspection"
TCLotInspections.MESSAGE_KIND = "lotInspection"
TCLotInspections.NAMED_BODY_KEYS = { tc_lotInspection_offerBody = true }

-- How many farmers ask, at most, on a sale day.
TCLotInspections.COUNT = { 2, 7 }
-- The hour they ask from, before viewing (Auctions.VIEWING_HOUR).
TCLotInspections.OFFER_HOUR = 7
-- The fee at the default Job pay rate (100%). The setting moves it as it
-- moves any job's, and EconomyScale applies as it's read (Job:getPrice).
TCLotInspections.PRICE = 300

local function isTakenOn(job)
    return job.state == TheContractorJob.STATE.ACCEPTED or job.state == TheContractorJob.STATE.ALLOCATED or
        job.state == TheContractorJob.STATE.IN_PROGRESS
end

local function isOffer(job)
    return job.state == TheContractorJob.STATE.OFFERED or job.state == TheContractorJob.STATE.NEGOTIATING
end

-- Every machine, at load, before the save loads.
function TCLotInspections.register(inbox)
    inbox:registerMessageKind(TCLotInspections.MESSAGE_KIND, {
        endsWithJob = true,
        category = "job",
        getArgs = function(message)
            return TheContractorInbox.getCustomerNamedArgs(message, TCLotInspections.NAMED_BODY_KEYS)
        end,
    })
end

-- Reading (every machine) ------------------------------------------------------------------

-- Every job (any farm, any state) inspecting a lot of this auction, in id
-- order; one lot's only with lotNumber.
function TCLotInspections.getJobs(auctionId, lotNumber)
    local found = {}
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil then
        return found
    end
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            local inspection = job.lotInspection
            if inspection ~= nil and inspection.auctionId == auctionId and
                    (lotNumber == nil or inspection.lotNumber == lotNumber) then
                table.insert(found, job)
            end
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    return found
end

-- The lot's vehicle while it's out, or nil.
function TCLotInspections.getLotVehicle(job)
    local tc = g_currentMission.TheContractor
    local auction = tc.Auctions ~= nil and tc.Auctions:getAuction() or nil
    local inspection = job.lotInspection
    if inspection == nil or auction == nil or auction.id ~= inspection.auctionId or tc.AuctionSite == nil then
        return nil
    end
    local lot = tc.AuctionSite:getLot(inspection.lotNumber)
    local vehicle = lot ~= nil and lot.vehicleId ~= nil and NetworkUtil.getObject(lot.vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

function TCLotInspections.getMachineName(inspection)
    return TheContractorFarmerFleet.getModelName(inspection.xmlFilename)
end

-- The menu's machine row: "Lot 12, Fendt 724 Vario: bidding closes 17:24".
function TCLotInspections.getDetailText(job)
    local inspection = job.lotInspection
    return string.format(g_i18n:getText("tc_lotInspection_detailValue"), inspection.lotNumber,
        TCLotInspections.getMachineName(inspection), TheContractorAuctionSite.formatCloseTime(inspection.closeMinute))
end

-- TCJobHotspots: on the lot while the job's taken on.
function TCLotInspections.getSpot(job)
    if not isTakenOn(job) then
        return nil
    end
    local vehicle = TCLotInspections.getLotVehicle(job)
    if vehicle == nil or vehicle.rootNode == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return { x = x, z = z }
end

-- Done (server) -------------------------------------------------------------------------

function TCLotInspections.isInspected(job)
    local inspection = job.lotInspection
    local vehicle = inspection ~= nil and TCLotInspections.getLotVehicle(job) or nil
    return vehicle ~= nil and TCADSUsedLots.isInspectedSince(vehicle, inspection.inspectionMark or 0)
end

-- TCJobProgress: all or nothing.
function TCLotInspections.getCompletion(job)
    return TCLotInspections.isInspected(job) and 1 or 0
end

-- The offers (server) ------------------------------------------------------------------------

function TCLotInspections.isAvailable()
    return TCADSUsedLots.isSellerRegistered() and TCADSUsedLots.canReadInspections()
end

local function isTractor(role)
    local ROLE = TheContractorFarmerFleet.ROLE
    return role == ROLE.SMALL_TRACTOR or role == ROLE.MEDIUM_TRACTOR or role == ROLE.LARGE_TRACTOR
end

-- The site's tractor lots that could be inspected: still open, out, and
-- looked after by ADS. { { lot, vehicle } }, in lot order.
function TCLotInspections.getTractorLots(site)
    local result = {}
    for _, lot in ipairs(site.site ~= nil and site.site.lots or {}) do
        local vehicle = lot.vehicleId ~= nil and NetworkUtil.getObject(lot.vehicleId) or nil
        if isTractor(lot.role) and lot.soldTo == nil and vehicle ~= nil and not vehicle.isDeleted and
                site:getLotStateNow(lot) == TheContractorAuctionSite.LOT_STATE.OPEN and
                TCADSUsedLots.isADSVehicle(vehicle) then
            table.insert(result, { lot = lot, vehicle = vehicle })
        end
    end
    table.sort(result, function(a, b) return a.lot.number < b.lot.number end)
    return result
end

-- The farmers who might ask a farm: never the official or the host, and
-- not one fallen out with it. { { farmer, weight } }, skipping taken.
function TCLotInspections.getCandidateFarmers(farmId, hostFarmerId, taken)
    local tc = g_currentMission.TheContractor
    local candidates = {}
    for _, farmer in ipairs(tc.Farmers:getFarmers()) do
        local weight = tc.Relationships:getOfferWeight(farmId, farmer.id)
        if not farmer.isOfficial and farmer.id ~= hostFarmerId and not taken[farmer.id] and weight > 0 then
            table.insert(candidates, { farmer = farmer, weight = weight })
        end
    end
    return candidates
end

-- Which farm each of count requests goes to (pure): round the farms in a
-- shuffled order, so they're shared evenly.
function TCLotInspections.shareRequests(farmIds, count, random)
    local order = {}
    for i, farmId in ipairs(farmIds) do
        order[i] = farmId
    end
    for i = #order, 2, -1 do
        local j = math.min(i, math.floor(random() * i) + 1)
        order[i], order[j] = order[j], order[i]
    end
    local result = {}
    if #order == 0 then
        return result
    end
    for i = 1, count do
        table.insert(result, order[(i - 1) % #order + 1])
    end
    return result
end

-- The job's price: PRICE at the default pay rate. getJobPayMultiplier is
-- JOB_PAY_BASELINE (the share of vanilla's pay a job gets at 100%) times
-- the setting, so the baseline's taken back out.
function TCLotInspections.getBasePrice(payMultiplier)
    return math.floor(TCLotInspections.PRICE * payMultiplier / TheContractorJobGeneration.JOB_PAY_BASELINE + 0.5)
end

-- Server: one farmer's request for a lot, to a farm. Returns the job.
function TCLotInspections.offer(farmId, farmer, lot, vehicle, auction)
    local tc = g_currentMission.TheContractor
    local environment = g_currentMission.environment
    local inspection = {
        auctionId = auction.id,
        lotNumber = lot.number,
        farmerId = farmer.id,
        xmlFilename = lot.xmlFilename,
        closeMinute = lot.closeMinute or 0,
        inspectionMark = TCADSUsedLots.getInspectionMark(vehicle),
    }
    local price = TCLotInspections.getBasePrice(tc.Settings:getJobPayMultiplier())
    local today = environment.currentMonotonicDay
    local job = tc.Jobs:createJob(farmId, TCLotInspections.JOB_TYPE, auction.fieldId, 1,
        environment:getPeriodFromDay(today), environment:getDayInPeriodFromDay(today), price, true, nil,
        auction.day, false, nil, nil, nil, nil, nil, nil, nil, nil, nil, inspection)
    if job == nil then
        return nil
    end
    local field = g_fieldManager:getFieldById(auction.fieldId)
    tc.Inbox:postMessage(farmId, TCLotInspections.MESSAGE_KIND, "tc_lotInspection_offerTitle",
        "tc_lotInspection_offerBody", { tostring(lot.number), field ~= nil and field:getName() or
            tostring(auction.fieldId), TCLotInspections.getMachineName(inspection),
            TheContractorAuctionSite.formatCloseTime(inspection.closeMinute) }, nil, { jobId = job.id })
    TCLog.info("TheContractor: farm %d job %d: farmer #%d asks for lot %d (%s) inspected by %s, ADS record %d",
        farmId, job.id, farmer.id, lot.number, tostring(lot.xmlFilename),
        TheContractorAuctionSite.formatCloseTime(inspection.closeMinute), inspection.inspectionMark)
    return job
end

-- Server: the sale day's requests: count of them (COUNT's roll when nil),
-- or fewer if there aren't the lots or farmers. Returns how many were made,
-- or nil and why none could be.
function TCLotInspections.makeOffers(auction, count, random)
    local tc = g_currentMission.TheContractor
    random = random or math.random
    if not TCLotInspections.isAvailable() then
        return nil, "ADS can't inspect auction lots or say what's been inspected"
    end
    local site = tc.AuctionSite
    if site.site == nil or site.site.fieldId ~= auction.fieldId or site.site.isSpawning then
        return nil, "the lots aren't out yet"
    end
    local farmIds = tc.RandomEvents:getCompanyFarmIds()
    if #farmIds == 0 then
        return nil, "no farm has a company"
    end
    local lots = TCLotInspections.getTractorLots(site)
    local lotCount = #lots
    if count == nil then
        count = TCLotInspections.COUNT[1] +
            math.floor(random() * (TCLotInspections.COUNT[2] - TCLotInspections.COUNT[1] + 1))
    end
    count = math.min(count, #lots)
    local made = 0
    local takenFarmers = {}
    for _, farmId in ipairs(TCLotInspections.shareRequests(farmIds, count, random)) do
        local farmer = TheContractorYardBales.pickWeighted(
            TCLotInspections.getCandidateFarmers(farmId, auction.hostFarmerId, takenFarmers), random)
        if farmer ~= nil and #lots > 0 then
            local choice = table.remove(lots, math.min(#lots, math.floor(random() * #lots) + 1))
            if TCLotInspections.offer(farmId, farmer, choice.lot, choice.vehicle, auction) ~= nil then
                takenFarmers[farmer.id] = true
                made = made + 1
            end
        end
    end
    TCLog.info("TheContractor: auction %d: %d of %d lot inspection request(s) made, %d tractor lot(s), %d farm(s)",
        auction.id, made, count, lotCount, #farmIds)
    return made
end

-- Server, each hour (Auctions): on the sale day, from OFFER_HOUR until the
-- first lot closes, the requests once the lots are out (once an auction).
-- Then any job whose lot has gone.
function TCLotInspections.onHour(auction, today, hour)
    if auction == nil then
        return
    end
    TCLotInspections.offerIfDue(auction, today, hour)
    TCLotInspections.dropGoneLots(auction)
end

-- Server (AuctionSite, as the last lot's out): setting 120 lots out can take
-- a minute, and a sleep runs through 07:00 and 08:00 in seconds, so the
-- hour may have passed while they were still coming out.
function TCLotInspections.onLotsOut()
    local auctions = g_currentMission.TheContractor.Auctions
    local auction = auctions ~= nil and auctions:getAuction() or nil
    local environment = g_currentMission.environment
    if auction ~= nil then
        TCLotInspections.offerIfDue(auction, environment.currentMonotonicDay, environment.currentHour or 0)
    end
end

-- Server: the requests, if it's the sale day from OFFER_HOUR until the lots
-- start closing and they haven't been made. Tried again later if the lots
-- aren't out yet.
function TCLotInspections.offerIfDue(auction, today, hour)
    if auction.inspectionsOffered or today ~= auction.day or hour < TCLotInspections.OFFER_HOUR or
            hour >= TheContractorAuctionSite.CLOSE_HOURS[1] then
        return
    end
    local made, reason = TCLotInspections.makeOffers(auction)
    if made ~= nil then
        auction.inspectionsOffered = true
    else
        TCLog.info("TheContractor: auction %d: no lot inspection requests yet: %s", auction.id, reason)
    end
end

-- Server: a job for a lot that's no longer out (it tipped over and was
-- taken away) goes, with nothing lost. A closed lot's jobs are over
-- already (onLotClosed).
function TCLotInspections.dropGoneLots(auction)
    for _, job in ipairs(TCLotInspections.getJobs(auction.id)) do
        if not job:isTerminal() and TCLotInspections.getLotVehicle(job) == nil then
            TCLotInspections.endWithoutBlame(job)
        end
    end
end

-- Server: an offer taken away, or a job taken on ended with nothing lost.
function TCLotInspections.endWithoutBlame(job)
    local jobs = g_currentMission.TheContractor.Jobs
    TCLog.info("TheContractor: farm %d job %d: lot %d's inspection called off", job.farmId, job.id,
        job.lotInspection.lotNumber)
    if isOffer(job) then
        jobs:removeJob(job)
    elseif isTakenOn(job) then
        jobs:missJob(job, true)
    end
end

-- Server (AuctionSale:closeLot, before the lot's settled): the lot's
-- bidding has closed, so its inspection's done or too late.
function TCLotInspections.onLotClosed(auctionId, lotNumber)
    local jobs = g_currentMission.TheContractor.Jobs
    for _, job in ipairs(TCLotInspections.getJobs(auctionId, lotNumber)) do
        if isOffer(job) then
            jobs:transitionJobState(job.farmId, job.id, TheContractorJob.STATE.DECLINED, nil,
                TheContractorRelationships.DECLINE_REASON.LAPSED)
        elseif isTakenOn(job) then
            -- Done since the last progress poll: it counts.
            if TCLotInspections.isInspected(job) then
                jobs:completeJob(job, true)
            else
                jobs:missJob(job)
            end
        end
    end
end

-- Server: the auction's called off (or its day moved): every job for it
-- that isn't over goes, with nothing lost.
function TCLotInspections.endAll(auctionId)
    for _, job in ipairs(TCLotInspections.getJobs(auctionId)) do
        if not job:isTerminal() then
            TCLotInspections.endWithoutBlame(job)
        end
    end
end

-- Saving and streaming ---------------------------------------------------------------------

function TCLotInspections.writeStream(streamId, inspection)
    if streamWriteBool(streamId, inspection ~= nil) then
        streamWriteInt32(streamId, inspection.auctionId)
        streamWriteInt32(streamId, inspection.lotNumber)
        streamWriteInt32(streamId, inspection.farmerId or 0)
        streamWriteString(streamId, inspection.xmlFilename or "")
        streamWriteInt32(streamId, inspection.closeMinute or 0)
    end
end

function TCLotInspections.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local inspection = {
        auctionId = streamReadInt32(streamId),
        lotNumber = streamReadInt32(streamId),
        farmerId = streamReadInt32(streamId),
        xmlFilename = streamReadString(streamId),
        closeMinute = streamReadInt32(streamId),
    }
    if inspection.farmerId == 0 then
        inspection.farmerId = nil
    end
    return inspection
end

function TCLotInspections.saveToXML(xmlFile, key, inspection)
    setXMLInt(xmlFile, key .. "#auctionId", inspection.auctionId)
    setXMLInt(xmlFile, key .. "#lotNumber", inspection.lotNumber)
    if inspection.farmerId ~= nil then
        setXMLInt(xmlFile, key .. "#farmerId", inspection.farmerId)
    end
    setXMLString(xmlFile, key .. "#xmlFilename", inspection.xmlFilename or "")
    setXMLInt(xmlFile, key .. "#closeMinute", inspection.closeMinute or 0)
    setXMLInt(xmlFile, key .. "#inspectionMark", inspection.inspectionMark or 0)
end

function TCLotInspections.loadFromXML(xmlFile, key)
    if not hasXMLProperty(xmlFile, key) then
        return nil
    end
    local auctionId = getXMLInt(xmlFile, key .. "#auctionId")
    local lotNumber = getXMLInt(xmlFile, key .. "#lotNumber")
    if auctionId == nil or lotNumber == nil then
        return nil
    end
    return {
        auctionId = auctionId,
        lotNumber = lotNumber,
        farmerId = getXMLInt(xmlFile, key .. "#farmerId"),
        xmlFilename = getXMLString(xmlFile, key .. "#xmlFilename") or "",
        closeMinute = getXMLInt(xmlFile, key .. "#closeMinute") or 0,
        inspectionMark = getXMLInt(xmlFile, key .. "#inspectionMark") or 0,
    }
end

-- Console ---------------------------------------------------------------------------------------

function TCLotInspections.registerConsoleCommands()
    TCConsole.register("debug", "auctionInspections", {
        args = "[count]",
        description = "Farmers ask for tractor lots to be inspected now (2 to 7 requests, or count), shared round the company farms",
        run = function(_, args)
            local count = args[1] ~= nil and tonumber(args[1]) or nil
            if (args[1] ~= nil and (count == nil or count < 1)) or args[2] ~= nil then
                return false
            end
            local auctions = g_currentMission.TheContractor.Auctions
            local auction = auctions ~= nil and auctions:getAuction() or nil
            if auction == nil then
                return "There's no auction announced."
            end
            local made, reason = TCLotInspections.makeOffers(auction, count ~= nil and math.floor(count) or nil)
            if made == nil then
                return "No requests: " .. reason .. "."
            end
            auction.inspectionsOffered = true
            return string.format("%d lot inspection request(s) made (tcDebug auctionLots lists the lots).", made)
        end,
    })
end
