-- HUD progress bars for jobs: a job of the local player's farm shows
-- vanilla's contract progress bar in the side notifications while it's
-- allocated or in progress, as a running vanilla contract does
-- (AbstractMission:update). Which jobs is this machine's jobProgressBars
-- setting: those allocated to a player (the default), every job (hired
-- crews' too), or none. Like vanilla it's shown to everyone on the farm,
-- not only the player who took the job on.
--
-- Client-side and visual only: every machine reads the job state it already
-- has (completionPercentage is kept live by TCJobProgress, or sent by the
-- server for a serverMeasured job), so there's no saving and no events. The
-- list of jobs is rebuilt every CHECK_INTERVAL_MS, as TCJobHotspots does;
-- the bars are marked for drawing every frame, since the HUD hides any bar
-- not marked since its last draw.

TCJobHud = {}

TCJobHud.CHECK_INTERVAL_MS = 1000

-- jobId -> { job, bar }
TCJobHud.barsByJobId = {}
TCJobHud.accumulatedMs = 0

local function getHud()
    return g_currentMission ~= nil and g_currentMission.hud or nil
end

-- The jobProgressBars setting (PLAYER_ONLY before the settings exist).
function TCJobHud.getMode()
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    local mode = tc ~= nil and tc.Settings ~= nil and tc.Settings:get("jobProgressBars") or nil
    return mode or TheContractorSettings.JOB_PROGRESS_BARS.PLAYER_ONLY
end

-- Whether a job gets a bar under a mode: allocated or in progress, and for
-- PLAYER_ONLY allocated to a player, not a hired crew. A workshop job (100)
-- is never allocated, so never shows one.
function TCJobHud.isShown(job, mode)
    local modes = TheContractorSettings.JOB_PROGRESS_BARS
    mode = mode or modes.PLAYER_ONLY
    if mode == modes.NONE then
        return false
    end
    if not (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) or
        job:isWorkshop() then
        return false
    end
    return mode == modes.ALL or job:isPlayerDriven()
end

-- The farm's jobs that get a bar, in job order.
function TCJobHud.getShownJobs(farmId)
    local shown = {}
    local tc = g_currentMission.TheContractor
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID or tc == nil or tc.Jobs == nil then
        return shown
    end
    local mode = TCJobHud.getMode()
    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if TCJobHud.isShown(job, mode) then
            table.insert(shown, job)
        end
    end
    table.sort(shown, function(a, b)
        return a.id < b.id
    end)
    return shown
end

-- 0-1. Player-driven haulage (035) isn't done until it's delivered as well
-- as cut, so the bar is half each; a delivery-only job's (067) completion
-- is its delivery already.
function TCJobHud.getProgress(job)
    local progress = (job.completionPercentage or 0) / 100
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if job:needsPlayerDelivery() and (job.requiredLiters or 0) > 0 and not (jobDef ~= nil and jobDef.deliveryOnly) then
        local delivered = math.min(1, (job.deliveredLiters or 0) / job.requiredLiters)
        progress = (math.min(1, progress) + delivered) / 2
    end
    return math.clamp(progress, 0, 1)
end

-- "Harvest, Field 12", or the job's own place where it has one (a yard,
-- 107's roads).
function TCJobHud.getText(job)
    local location = job:getLocationText()
    local jobDef = TheContractorJobGeneration.JOB_TYPES[job.jobType]
    if not job:isYardJob() and not (jobDef ~= nil and jobDef.locationKey ~= nil) then
        location = string.format(g_i18n:getText("tc_jobHud_field"), location)
    end
    return string.format(g_i18n:getText("tc_jobHud_text"), job:getTypeText(), location)
end

function TCJobHud.removeBar(jobId)
    local entry = TCJobHud.barsByJobId[jobId]
    if entry == nil then
        return
    end
    TCJobHud.barsByJobId[jobId] = nil
    local hud = getHud()
    if hud ~= nil and hud.removeSideNotificationProgressBar ~= nil then
        hud:removeSideNotificationProgressBar(entry.bar)
    end
end

-- Adds and removes bars to match the local farm's jobs now (and the
-- setting, whose onChanged calls this).
function TCJobHud.refresh()
    local hud = getHud()
    if hud == nil or hud.addSideNotificationProgressBar == nil then
        return
    end

    local wanted = {}
    for _, job in ipairs(TCJobHud.getShownJobs(g_currentMission:getFarmId())) do
        wanted[job.id] = job
    end

    for jobId, entry in pairs(TCJobHud.barsByJobId) do
        -- A client's job snapshot replaces the job object, so follow it.
        if wanted[jobId] == nil then
            TCJobHud.removeBar(jobId)
        else
            entry.job = wanted[jobId]
        end
    end

    -- In job order, so bars keep their places as others come and go.
    local newIds = {}
    for jobId in pairs(wanted) do
        if TCJobHud.barsByJobId[jobId] == nil then
            table.insert(newIds, jobId)
        end
    end
    table.sort(newIds)
    for _, jobId in ipairs(newIds) do
        local job = wanted[jobId]
        local bar = hud:addSideNotificationProgressBar(g_i18n:getText("tc_jobHud_title"), TCJobHud.getText(job),
            TCJobHud.getProgress(job))
        TCJobHud.barsByJobId[jobId] = { job = job, bar = bar }
    end

    for _, entry in pairs(TCJobHud.barsByJobId) do
        entry.bar.text = TCJobHud.getText(entry.job)
    end
end

function TCJobHud.update(dt)
    TCJobHud.accumulatedMs = TCJobHud.accumulatedMs + dt
    if TCJobHud.accumulatedMs >= TCJobHud.CHECK_INTERVAL_MS then
        TCJobHud.accumulatedMs = 0
        TCJobHud.refresh()
    end

    local hud = getHud()
    if hud == nil or hud.markSideNotificationProgressBarForDrawing == nil then
        return
    end
    for _, entry in pairs(TCJobHud.barsByJobId) do
        entry.bar.progress = TCJobHud.getProgress(entry.job)
        hud:markSideNotificationProgressBarForDrawing(entry.bar)
    end
end

-- loadMap and deleteMap: no bars carried between savegames.
function TCJobHud.reset()
    for jobId in pairs(TCJobHud.barsByJobId) do
        TCJobHud.removeBar(jobId)
    end
    TCJobHud.barsByJobId = {}
    TCJobHud.accumulatedMs = 0
end
