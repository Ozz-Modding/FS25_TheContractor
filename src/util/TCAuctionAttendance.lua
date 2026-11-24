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
-- 165: the agricultural show has the same job (attendShow), on its own day
-- and hours. Every function takes the day out's kind (a
-- TheContractorEventDay subclass: its ATTEND_JOB_TYPE, START_HOUR and
-- END_HOUR) as its last argument, the auction's if it's left off. A job's
-- kind is its type's (JOB_TYPES' eventKind), since each kind numbers its
-- own days.
--
-- No state of its own: the jobs carry their day's id (Job.auctionId,
-- whatever the kind), and Jobs saves and syncs them.

TCAuctionAttendance = {}

TCAuctionAttendance.JOB_TYPE = "attendAuction"

-- The kind a call's for: the one given, or the auction.
local function kindOf(kind)
    return kind or g_currentMission.TheContractor.Auctions or TheContractorAuctions
end

local function getJobType(kind)
    return kind ~= nil and kind.ATTEND_JOB_TYPE or TCAuctionAttendance.JOB_TYPE
end

-- The KIND a job's for (JOB_TYPES' eventKind), or nil for no attend job.
function TCAuctionAttendance.getJobKind(job)
    local jobDef = job ~= nil and TheContractorJobGeneration.JOB_TYPES[job.jobType] or nil
    return jobDef ~= nil and jobDef.eventKind or nil
end

-- Whether a job is an attend job for this kind (nil: the auction).
function TCAuctionAttendance.isJobFor(job, kind)
    return job ~= nil and job.auctionId ~= nil and
        TCAuctionAttendance.getJobKind(job) == (kind ~= nil and kind.KIND or "auction")
end

-- Every machine: the farm's attend job for a day out, whatever its state,
-- or nil.
function TCAuctionAttendance.getJob(farmId, auctionId, kind)
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil or auctionId == nil then
        return nil
    end
    for _, job in ipairs(jobs:getAllJobs(farmId)) do
        if job.auctionId == auctionId and TCAuctionAttendance.isJobFor(job, kind) then
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

-- Whether a farm should have an attend job for the day now: from the first
-- day of its month until it's over (END_HOUR on the day).
function TCAuctionAttendance.isDue(auction, today, hour, kind)
    if auction == nil then
        return false
    end
    kind = kindOf(kind)
    if today > auction.day or (today == auction.day and hour >= kind.END_HOUR) then
        return false
    end
    local salePeriodIndex = TCCalendar.getDayInfo(auction.day)
    return TCCalendar.getDayInfo(today) >= salePeriodIndex
end

-- Whether it's the day's hours: when turning up counts.
function TCAuctionAttendance.isSaleHours(auction, today, hour, kind)
    kind = kindOf(kind)
    return auction ~= nil and today == auction.day and hour >= kind.START_HOUR and hour <= kind.END_HOUR
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getHour()
    return g_currentMission.environment.currentHour or 0
end

-- Server: a farm's attend job for the day, made and accepted, unless it has
-- one already. Returns the job made, or nil.
function TCAuctionAttendance.createJobFor(farmId, auction, kind)
    local tc = g_currentMission.TheContractor
    if not g_currentMission:getIsServer() or tc.Jobs == nil or auction == nil or
            TCAuctionAttendance.getJob(farmId, auction.id, kind) ~= nil then
        return nil
    end
    local periodIndex, dayInPeriod = TCCalendar.getDayInfo(auction.day)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    local job = tc.Jobs:createJob(farmId, getJobType(kind), auction.fieldId, 1, period, dayInPeriod, 0,
        true, nil, auction.day, false, nil, nil, nil, nil, nil, nil, nil, auction.day, auction.id)
    if job == nil then
        return nil
    end
    tc.Jobs:transitionJobState(farmId, job.id, TheContractorJob.STATE.ACCEPTED)
    TCLog.info("TheContractor: farm %d job %d: attend %s %d on field %d, day %d", farmId, job.id,
        kind ~= nil and kind.NAME or "auction", auction.id, auction.fieldId, auction.day)
    return job
end

-- Server: every company farm's attend job, once the day's month has come.
-- Run each day, at the announcement and when the day moves.
function TCAuctionAttendance.createDueJobs(auction, kind)
    local tc = g_currentMission.TheContractor
    if not TCAuctionAttendance.isDue(auction, getToday(), getHour(), kind) or tc.RandomEvents == nil then
        return
    end
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        TCAuctionAttendance.createJobFor(farmId, auction, kind)
    end
end

-- Server: a company just set up gets one too, for every day out that's due
-- (the auction, and each other kind with an ATTEND_JOB_TYPE).
function TCAuctionAttendance.onCompanyCreated(farmId)
    local tc = g_currentMission.TheContractor
    local kinds = tc.PublicEvents ~= nil and tc.PublicEvents:getKinds() or { tc.Auctions }
    for _, kind in ipairs(kinds) do
        local event = kind ~= nil and kind:getEvent() or nil
        local isAuction = kind == tc.Auctions
        if event ~= nil and (isAuction or kind.ATTEND_JOB_TYPE ~= nil) then
            local forKind = not isAuction and kind or nil
            if TCAuctionAttendance.isDue(event, getToday(), getHour(), forKind) then
                TCAuctionAttendance.createJobFor(farmId, event, forKind)
            end
        end
    end
end

-- Server: the farm's been to the day (on its site, or for the auction a bid
-- or a win), so its attend job's done. 171: a kind with onAttended(farmId,
-- event) is told, once, as the job's done (the show's host's goodwill).
function TCAuctionAttendance.markAttended(farmId, kind)
    local tc = g_currentMission.TheContractor
    local event = nil
    if kind ~= nil then
        event = kind:getEvent()
    elseif tc.Auctions ~= nil then
        event = tc.Auctions:getAuction()
    end
    local job = event ~= nil and TCAuctionAttendance.getJob(farmId, event.id, kind) or nil
    if job ~= nil and job.state == TheContractorJob.STATE.ACCEPTED then
        tc.Jobs:completeJob(job, true)
        if kind ~= nil and kind.onAttended ~= nil then
            kind:onAttended(farmId, event)
        end
    end
end

-- Server: farmId -> true for every farm with a player on the field now (on
-- foot or in a vehicle: a driver's position is the vehicle's), added to
-- farmIds if given.
function TCAuctionAttendance.getFarmsOnField(fieldId, farmIds)
    farmIds = farmIds or {}
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

-- Server, each hour: in the day's hours, every farm with someone on its
-- site (the kind's getSiteFieldIds, or the event's field) has attended.
function TCAuctionAttendance.checkAttendance(auction, kind)
    if not TCAuctionAttendance.isSaleHours(auction, getToday(), getHour(), kind) then
        return
    end
    local fieldIds = kind ~= nil and kind.getSiteFieldIds ~= nil and kind:getSiteFieldIds(auction) or
        { auction.fieldId }
    local onSite = {}
    for _, fieldId in ipairs(fieldIds) do
        TCAuctionAttendance.getFarmsOnField(fieldId, onSite)
    end
    local farmIds = {}
    for farmId in pairs(onSite) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for _, farmId in ipairs(farmIds) do
        TCAuctionAttendance.markAttended(farmId, kind)
    end
end

-- Server: the day's called off (or moved), so every attend job for it that
-- isn't over goes.
function TCAuctionAttendance.removeJobs(auctionId, kind)
    local jobs = g_currentMission.TheContractor.Jobs
    if jobs == nil then
        return
    end
    local found = {}
    for _, farmJobs in pairs(jobs.jobsByFarm) do
        for _, job in pairs(farmJobs) do
            if job.auctionId == auctionId and TCAuctionAttendance.isJobFor(job, kind) and not job:isTerminal() then
                table.insert(found, job)
            end
        end
    end
    table.sort(found, function(a, b) return a.id < b.id end)
    for _, job in ipairs(found) do
        jobs:removeJob(job)
    end
end
