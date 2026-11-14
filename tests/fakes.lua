-- Fakes for the mod's own modules that the job fuel/supplies tests don't
-- load, plus the real ones they do. fakes.installContractor(world) after
-- stubs.install(); then world:addJob builds real TheContractorJobs.
--
-- Loaded for real: Job.lua, TCJobFuel, TCJobSupplies, Notices.
-- Faked (just enough for those): Jobs, Dispatch, Logbook, TheContractorProtest,
-- TheContractorNegotiation, TheContractorJobGeneration, TCEquipmentClass,
-- TCJobProgress.

local fakes = {}

fakes.JOB_TYPES = {
    harvest = { cropDependent = true },
    plough = { implementSpec = "spec_plow" },
}

function fakes.installContractor(world)
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = {
        rollInitialEagerness = function()
            return 1
        end,
    }
    TheContractorJobGeneration = { JOB_TYPES = fakes.JOB_TYPES }
    TCEquipmentClass = {
        isSeedTank = function()
            return false
        end,
        isJobImplement = function()
            return false
        end,
    }
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    -- 151: world.protestMinutes is what a protest adds to a trip (0: none
    -- out); world.protestDelays the { jobId, isReturn } it was told of.
    world.protestMinutes, world.protestDelays = 0, {}
    TheContractorProtest = {
        getTravelDelayMinutes = function(job)
            return world.protestMinutes
        end,
        notifyDelay = function(job, isReturn)
            if world.protestMinutes > 0 then
                table.insert(world.protestDelays, { jobId = job.id, isReturn = isReturn })
            end
        end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Notices.lua")
    world:load("src/util/TCJobFuel.lua")
    world:load("src/util/TCJobSupplies.lua")

    local tc = g_currentMission.TheContractor
    world.jobs = {}

    tc.Jobs = {
        getAllJobs = function(_, farmId)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(result, job)
                end
            end
            return result
        end,
        setJobSupplyStatus = function(_, job, status, fillTypeName)
            job.supplyStatus = status
            job.supplyFillTypeName = fillTypeName
        end,
        getWorkingJobForVehicle = function(_, vehicleId)
            for _, job in ipairs(world.jobs) do
                if job.state == TheContractorJob.STATE.IN_PROGRESS then
                    for _, id in ipairs(job.assignedEquipmentIds) do
                        if id == vehicleId then
                            return job
                        end
                    end
                end
            end
            return nil
        end,
    }

    -- world.working[jobId] = true for a job whose AI is out working.
    world.working, world.started, world.paused = {}, {}, {}
    tc.Dispatch = {
        isJobActive = function(_, job)
            return world.working[job.id] == true
        end,
        isJobWorking = function(_, job)
            return world.working[job.id] == true
        end,
        takeRanOutOfFill = function()
            return false
        end,
        startJobForWorker = function(_, job)
            table.insert(world.started, job.id)
        end,
        pauseForSupplies = function(_, job)
            world.working[job.id] = nil
            table.insert(world.paused, job.id)
        end,
    }

    world.suppliesLogged = {}
    tc.Logbook = {
        onSuppliesLoaded = function(_, job, fillTypeIndex, liters)
            table.insert(world.suppliesLogged, { jobId = job.id, fillTypeIndex = fillTypeIndex, liters = liters })
        end,
    }

    tc.Notices = TheContractorNotices.new()

    -- def: { id, farmId, jobType, workerId, state, vehicles = {...},
    --        working, haulerId, haulageVehicles = {...} }
    function world:addJob(def)
        local job = TheContractorJob.new(def.id or (#self.jobs + 1), def.farmId or 1, def.jobType or "harvest", 1, 1,
            1, 1, 1000)
        job.state = def.state or TheContractorJob.STATE.IN_PROGRESS
        job.assignedWorkerId = def.workerId
        for _, vehicle in ipairs(def.vehicles or {}) do
            table.insert(job.assignedEquipmentIds, vehicle.id)
        end
        job.haulerWorkerId = def.haulerId
        for _, vehicle in ipairs(def.haulageVehicles or {}) do
            table.insert(job.haulageEquipmentIds, vehicle.id)
        end
        if def.working then
            self.working[job.id] = true
        end
        table.insert(self.jobs, job)
        return job
    end
end

return fakes
