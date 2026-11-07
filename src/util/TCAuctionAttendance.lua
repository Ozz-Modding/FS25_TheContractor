-- "Attend the auction" (141): when a machinery auction's (137) sale month
-- begins, every farm with a company gets a job, already accepted, to go to
-- it. It's a reminder, nothing more: it puts the sale in the Jobs tab (133)
-- and 088's due-job circle on its field, and costs nothing either way
-- (JOB_TYPES' attendAuction: noConsequences, noAllocation).
--
--   Made (server): on the first day of the sale's month (or at the
--     announcement if that's in it already), for every company farm that
--     hasn't one for this auction; a farm that sets up its company later in
--     the month gets one too, while the sale's still to come. Ready day and
--     deadline are both the sale day, so it's listed under Upcoming until
--     then. Its field is the sale's, its customer the host (Farmers:
--     getCustomerIdForJob, for show).
--   Done (server): someone from the farm on the site's field during sale
--     hours (SALE_HOUR to SALE_END_HOUR, on foot or in a vehicle), checked
--     each hour; or the farm leaving a bid or winning a lot (139). Otherwise
--     the day's end misses it quietly (TheContractorJobs:
--     endWithoutConsequences).
--   Called off: the auction cancelled (137) takes any attend job not yet
--     over away (TheContractorJobs:removeJob).
--
-- No state of its own: the jobs carry their auction (Job.auctionId), and
-- Jobs saves and syncs them.

TCAuctionAttendance = {}

TCAuctionAttendance.JOB_TYPE = "attendAuction"

-- Every machine: the farm's attend job for an auction, whatever its state,
-- or nil.
function TCAuctionAttendance.getJob(farmId, auctionId)
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil or auctionId == nil then
        return nil
    end
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if job.auctionId == auctionId then
            return job
        end
    end
    return nil
end

-- Every machine: how many lots an attend job's sale has out, or nil before
-- they're set out on its field (the morning of the sale).
function TCAuctionAttendance.getLotCount(job)
    local site = g_currentMission.TheContractor.AuctionSite
    if job == nil or site == nil or not site:isFieldInUse(job.fieldId) then
        return nil
    end
    local count = #site:getLots()
    return count > 0 and count or nil
end

-- Whether a farm should have an attend job for the auction now: from the
-- first day of the sale's month until the sale's over (its last lot's
-- closed, SALE_END_HOUR).
function TCAuctionAttendance.isDue(auction, today, hour)
    if auction == nil then
        return false
    end
    if today > auction.saleDay or (today == auction.saleDay and hour >= TheContractorAuctions.SALE_END_HOUR) then
        return false
    end
    local salePeriodIndex = TCCalendar.getDayInfo(auction.saleDay)
    return TCCalendar.getDayInfo(today) >= salePeriodIndex
end

-- Whether it's sale hours on the sale day: when turning up counts.
function TCAuctionAttendance.isSaleHours(auction, today, hour)
    return auction ~= nil and today == auction.saleDay and hour >= TheContractorAuctions.SALE_HOUR and
        hour <= TheContractorAuctions.SALE_END_HOUR
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getHour()
    return g_currentMission.environment.currentHour or 0
end

-- Server: a farm's attend job for the auction, made and accepted, unless
-- it has one already. Returns the job made, or nil.
function TCAuctionAttendance.createJobFor(farmId, auction)
    local tc = g_currentMission.TheContractor
    if not g_currentMission:getIsServer() or tc.Jobs == nil or auction == nil or
            TCAuctionAttendance.getJob(farmId, auction.id) ~= nil then
        return nil
    end
    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(auction.saleDay)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    local job = tc.Jobs:createJob(farmId, TCAuctionAttendance.JOB_TYPE, auction.fieldId, 1, period, dayInPeriod, 0,
        true, nil, auction.saleDay, false, nil, nil, nil, nil, nil, nil, nil, auction.saleDay, auction.id)
    if job == nil then
        return nil
    end
    tc.Jobs:transitionJobState(farmId, job.id, TheContractorJob.STATE.ACCEPTED)
    TCLog.info("TheContractor: farm %d job %d: attend auction %d on field %d, day %d", farmId, job.id, auction.id,
        auction.fieldId, auction.saleDay)
    return job
end

-- Server: every company farm's attend job, once the sale's month has come.
-- Run each day, at the announcement and when the sale day moves.
function TCAuctionAttendance.createDueJobs(auction)
    local tc = g_currentMission.TheContractor
    if not TCAuctionAttendance.isDue(auction, getToday(), getHour()) or tc.RandomEvents == nil then
        return
    end
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        TCAuctionAttendance.createJobFor(farmId, auction)
    end
end

-- Server: a company just set up gets one too, if it's due.
function TCAuctionAttendance.onCompanyCreated(farmId)
    local auctions = g_currentMission.TheContractor.Auctions
    local auction = auctions ~= nil and auctions:getAuction() or nil
    if auction ~= nil and TCAuctionAttendance.isDue(auction, getToday(), getHour()) then
        TCAuctionAttendance.createJobFor(farmId, auction)
    end
end

-- Server: the farm's been to the sale (on the site, or a bid or a win), so
-- its attend job's done.
function TCAuctionAttendance.markAttended(farmId)
    local tc = g_currentMission.TheContractor
    local auction = tc.Auctions ~= nil and tc.Auctions:getAuction() or nil
    local job = auction ~= nil and TCAuctionAttendance.getJob(farmId, auction.id) or nil
    if job ~= nil and job.state == TheContractorJob.STATE.ACCEPTED then
        tc.Jobs:completeJob(job, true)
    end
end

-- Server: farmId -> true for every farm with a player on the field now (on
-- foot or in a vehicle: a driver's position is the vehicle's).
function TCAuctionAttendance.getFarmsOnField(fieldId)
    local farmIds = {}
    local field = g_fieldManager:getFieldById(fieldId)
    local polygon = field ~= nil and TCAuctionCrowd.getFieldPolygon(field) or {}
    local playerSystem = g_currentMission.playerSystem
    if #polygon < 3 or playerSystem == nil or playerSystem.getPlayerCount == nil then
        return farmIds
    end
    for i = 1, playerSystem:getPlayerCount() do
        local player = playerSystem:getPlayerByIndex(i)
        if player ~= nil and player.farmId ~= nil and player.farmId ~= FarmManager.SPECTATOR_FARM_ID and
                player.getPosition ~= nil then
            local x, _, z = player:getPosition()
            if x ~= nil and TCAuctionCrowd.pointInPolygon(x, z, polygon) then
                farmIds[player.farmId] = true
            end
        end
    end
    return farmIds
end

-- Server, each hour: in sale hours, every farm with someone on the site has
-- attended.
function TCAuctionAttendance.checkAttendance(auction)
    if not TCAuctionAttendance.isSaleHours(auction, getToday(), getHour()) then
        return
    end
    local farmIds = {}
    for farmId in pairs(TCAuctionAttendance.getFarmsOnField(auction.fieldId)) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for _, farmId in ipairs(farmIds) do
        TCAuctionAttendance.markAttended(farmId)
    end
end

-- Server: the auction's called off (or its day moved), so every attend job
-- for it that isn't over goes.
function TCAuctionAttendance.removeJobs(auctionId)
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil then
        return
    end
    local found = {}
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.auctionId == auctionId and not job:isTerminal() then
                table.insert(found, job)
            end
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    for _, job in ipairs(found) do
        jobs:removeJob(job)
    end
end
