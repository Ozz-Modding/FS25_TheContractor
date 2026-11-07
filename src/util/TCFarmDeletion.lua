-- A farm deleted in multiplayer (FarmManager:destroyFarm, server). Vanilla
-- deletes the farm's vehicles, placeables and items, then publishes
-- MessageType.FARM_DELETED. Everything of ours keyed by that farm goes too:
-- the next farm made gets the lowest free id (FarmManager:findNextFarmId),
-- and would otherwise start out with the old one's company, staff (and their
-- wages), jobs, invoices, policies and reputation.
--
-- The server stops what's live (its jobs' delivery counting, field set-up and
-- progress scans), forgets the farm, then tells the clients with
-- TCFarmDeletedEvent, which they get after anything the server sent about the
-- farm first, so nothing comes back afterwards. Clients don't act on
-- vanilla's own FARM_DELETED for this: it reaches them a frame later, out of
-- step with our events.
--
-- Anything new that holds state by farm adds a forgetFarm(farmId, jobIds) to
-- its subsystem and its key to SUBSYSTEMS. jobIds is the farm's jobs' ids,
-- taken before any of them goes, for state kept by job.

TCFarmDeletion = {}

TCFarmDeletion.SUBSYSTEMS = {
    "Company", "Reputation", "Advertising", "JobGeneration", "Jobs", "Staff", "Cooldown", "Drivers",
    "Notices", "Holidays", "Finances", "Inbox", "Overheads", "Claims", "Office", "Logbook",
    "MachineryInsurance", "GoodNews", "Parking", "RandomEvents", "Relationships", "RepairContracts",
    "Dispatch", "Watchdog", "AuctionSale",
}

function TCFarmDeletion.install()
    g_messageCenter:subscribe(MessageType.FARM_DELETED, TCFarmDeletion.onFarmDeleted, TCFarmDeletion)
end

function TCFarmDeletion.uninstall()
    g_messageCenter:unsubscribeAll(TCFarmDeletion)
end

-- Server: vanilla's FARM_DELETED.
function TCFarmDeletion:onFarmDeleted(farmId)
    if not g_currentMission:getIsServer() or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    local tc = g_currentMission.TheContractor
    if tc == nil then
        return
    end

    TCLog.info("TheContractor: farm %d was deleted, forgetting its company", farmId)
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        TCHaulage.stopDelivery(job)
        -- Bales, windrow or a pile laid out on the customer's field.
        TCFieldPreparation.clearUpAfterJob(job)
    end
    TCFarmDeletion.forgetFarm(farmId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCFarmDeletedEvent.new(farmId))
    end
end

-- Every machine: drops everything kept for the farm.
function TCFarmDeletion.forgetFarm(farmId)
    local tc = g_currentMission.TheContractor
    if tc == nil then
        return
    end

    local jobIds = {}
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        table.insert(jobIds, job.id)
        TCJobProgress.clearJob(job.id)
    end

    for _, key in ipairs(TCFarmDeletion.SUBSYSTEMS) do
        local subsystem = tc[key]
        if subsystem ~= nil and subsystem.forgetFarm ~= nil then
            subsystem:forgetFarm(farmId, jobIds)
        end
    end
end
