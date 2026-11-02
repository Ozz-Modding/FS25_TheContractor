-- The Jobs tab's list (133): the farm's taken-on jobs, those that can be
-- worked now first, by deadline (so what's due today is on top), then the
-- ones still to come, by the day they're ready (132). Plain functions on
-- synced job state, so every machine lists the same and the tests can
-- check them without the menu.

TCJobList = {}

-- The list's views, in the view selector's order.
TCJobList.VIEWS = { "all", "ready", "upcoming" }

-- Taken on and not over: accepted, allocated or in progress. A missed job
-- leaves the list (its notification and the Logbook have it).
function TCJobList.isListed(job)
    local state = job.state
    return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
        state == TheContractorJob.STATE.IN_PROGRESS
end

-- Whether it's in the "ready now" part: anything already allocated is, and
-- an accepted job once its ready day has come.
function TCJobList.isReadyNow(job)
    return job.state ~= TheContractorJob.STATE.ACCEPTED or job:isReady()
end

local function compareReady(a, b)
    if (a.deadlineDay or 0) ~= (b.deadlineDay or 0) then
        return (a.deadlineDay or 0) < (b.deadlineDay or 0)
    end
    return a.id < b.id
end

local function compareUpcoming(a, b)
    if (a.readyDay or 0) ~= (b.readyDay or 0) then
        return (a.readyDay or 0) < (b.readyDay or 0)
    end
    return compareReady(a, b)
end

-- jobs: any list of the farm's jobs. view: one of VIEWS (anything else is
-- "all"). Returns a new, sorted list.
function TCJobList.build(jobs, view)
    local ready, upcoming = {}, {}
    for _, job in ipairs(jobs) do
        if TCJobList.isListed(job) then
            if TCJobList.isReadyNow(job) then
                table.insert(ready, job)
            else
                table.insert(upcoming, job)
            end
        end
    end
    table.sort(ready, compareReady)
    table.sort(upcoming, compareUpcoming)

    if view == "ready" then
        return ready
    elseif view == "upcoming" then
        return upcoming
    end
    for _, job in ipairs(upcoming) do
        table.insert(ready, job)
    end
    return ready
end

-- Whole days until the end of the job's deadline day: 0 is due today.
-- Never below 0 (a job past its deadline has been missed at the day change).
function TCJobList.getDaysLeft(job, today)
    if job.deadlineDay == nil then
        return nil
    end
    return math.max(0, job.deadlineDay - today)
end
