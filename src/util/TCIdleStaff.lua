-- Idle staff on standing spots (065). Workers with nothing on (idle, or
-- back from a job in a cooldown) are shown standing on their farm's
-- Standing Spots (PlaceableTCStandingSpot), one per spot, in their own look
-- (041), playing an idle animation.
--
-- It's only visual, local to each machine with a client, and has no state,
-- events or saving of its own. Every machine works out the same answer
-- from what it already has: the farm's spots (vanilla syncs placeables and
-- their owner), the workers' status (TCWorkerStatusChangedEvent) and the
-- day. `assign` is that answer, a pure function: every (worker, spot) pair
-- gets a score hashed from the farm, the day, the worker id and the spot's
-- position, and the pairs are taken best first, greedily. A new day gives
-- new scores, which is the daily shuffle. A worker coming or going only
-- moves the others who'd rather have the spot they took or freed - anyone
-- on the spot they like best stays put. The hash is our own, not
-- math.random, so every machine gets the same order and the game's random
-- state isn't touched.
--
-- Showing them follows vanilla's NPC (ai/npcs/characters/NPC.lua): a
-- HumanGraphicsComponent per worker loaded from their PlayerStyle,
-- isNPC set so it plays the NPC idle, culled beyond CLIP_DISTANCE. Like
-- the NPCs, nobody is put on, taken off or swapped while the player can see
-- the spot: a change waits until it's out of view or out of range. Who's
-- standing where is kept apart from their model, so a worker takes their
-- spot even while the player is far away; the model is loaded once the
-- spot is within LOAD_DISTANCE (it appears when it's ready, like anything
-- else streaming in) and freed beyond UNLOAD_DISTANCE. A worker turns to
-- face a local player who walks up (NPC:update's turn) and back to the
-- spot's arrow when they leave. While someone's standing on a spot its
-- blocker is in physics, so players can't walk through them.
--
-- They're only about during working hours (START_HOUR to END_HOUR, game
-- time): outside them nobody is wanted, so everyone goes home as their
-- spot drops out of view, and turns up again the same way in the morning.
-- The time of day is vanilla's, synced to every machine.

TCIdleStaff = {}

-- How often (ms) who-should-stand-where is worked out again.
TCIdleStaff.RECHECK_MS = 2000
-- Metres from the camera: shown within CLIP, model loaded within LOAD,
-- freed beyond UNLOAD.
TCIdleStaff.CLIP_DISTANCE = 100
TCIdleStaff.LOAD_DISTANCE = 150
TCIdleStaff.UNLOAD_DISTANCE = 200
-- A local player on foot this close (metres) is turned to.
TCIdleStaff.FACE_DISTANCE = 5
-- Radians per ms, NPC's rotationSpeed.
TCIdleStaff.ROTATION_SPEED = 0.006283185307179587
-- The point tested against the screen, this far above the stand node, and
-- how far off the edge of the screen (in screen widths) still counts as
-- seen.
TCIdleStaff.VIEW_HEIGHT = 1
TCIdleStaff.VIEW_MARGIN = 0.2
-- Working hours (game time, hours of the day): from START_HOUR up to but
-- not including END_HOUR.
TCIdleStaff.START_HOUR = 7
TCIdleStaff.END_HOUR = 19

local HASH_MODULUS = 2147483647

-- Assignment (pure, every machine) ---------------------------------------

function TCIdleStaff.isStandingStatus(status)
    return status == TheContractorWorker.STATUS.IDLE or status == TheContractorWorker.STATUS.COOLDOWN
end

-- A spot's key: its position in whole decimetres, so every machine names it
-- the same however its float position arrived.
function TCIdleStaff.getSpotKey(x, z)
    return string.format("%d:%d", math.floor(x * 10 + 0.5), math.floor(z * 10 + 0.5))
end

local function hash(text)
    local h = 0
    for i = 1, #text do
        h = (h * 31 + text:byte(i)) % HASH_MODULUS
    end
    for _ = 1, 3 do
        h = (h * 48271) % HASH_MODULUS
    end
    return h
end

function TCIdleStaff.getScore(farmId, day, workerId, spotKey)
    return hash(string.format("%d|%d|%d|%s", farmId, day, workerId, spotKey))
end

-- workerId -> spotKey for one farm. Extra workers get no spot, spare spots
-- stay empty.
function TCIdleStaff.assign(farmId, day, workerIds, spotKeys)
    local candidates = {}
    for _, workerId in ipairs(workerIds) do
        for _, spotKey in ipairs(spotKeys) do
            table.insert(candidates, {
                workerId = workerId,
                spotKey = spotKey,
                score = TCIdleStaff.getScore(farmId, day, workerId, spotKey),
            })
        end
    end
    table.sort(candidates, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        if a.workerId ~= b.workerId then
            return a.workerId < b.workerId
        end
        return a.spotKey < b.spotKey
    end)

    local assignment = {}
    local takenSpots = {}
    for _, candidate in ipairs(candidates) do
        if assignment[candidate.workerId] == nil and not takenSpots[candidate.spotKey] then
            assignment[candidate.workerId] = candidate.spotKey
            takenSpots[candidate.spotKey] = true
        end
    end
    return assignment
end

-- Are staff on site at this time of day (ms since midnight)?
function TCIdleStaff.isWorkingHours(dayTime)
    local hour = (dayTime or 0) / 3600000
    return hour >= TCIdleStaff.START_HOUR and hour < TCIdleStaff.END_HOUR
end

-- Who should stand where right now: workerId -> { worker, spot }, spot
-- being { key, placeable, x, y, z, yaw }.
function TCIdleStaff.getWanted()
    local wanted = {}
    local mission = g_currentMission
    local tc = mission.TheContractor
    if tc == nil or tc.Staff == nil or mission.placeableSystem == nil or mission.environment == nil then
        return wanted
    end
    if not TCIdleStaff.isWorkingHours(mission.environment.dayTime) then
        return wanted
    end

    local spotsByFarm = {}
    for _, placeable in ipairs(mission.placeableSystem.placeables) do
        if PlaceableTCStandingSpot.isSpot(placeable) and not placeable.isDeleted and
                not placeable.markedForDeletion then
            local x, y, z, yaw = PlaceableTCStandingSpot.getStandPose(placeable)
            if x ~= nil then
                local farmId = placeable:getOwnerFarmId()
                spotsByFarm[farmId] = spotsByFarm[farmId] or {}
                local key = TCIdleStaff.getSpotKey(x, z)
                spotsByFarm[farmId][key] = { key = key, placeable = placeable, x = x, y = y, z = z, yaw = yaw }
            end
        end
    end

    local day = mission.environment.currentMonotonicDay or 0
    for farmId, spots in pairs(spotsByFarm) do
        local people = TCIdleStaff.getStandingPeople(tc, farmId)
        local workerIds = {}
        for workerId in pairs(people) do
            table.insert(workerIds, workerId)
        end
        table.sort(workerIds)
        local spotKeys = {}
        for key in pairs(spots) do
            table.insert(spotKeys, key)
        end
        table.sort(spotKeys)

        for workerId, spotKey in pairs(TCIdleStaff.assign(farmId, day, workerIds, spotKeys)) do
            wanted[workerId] = { worker = people[workerId], spot = spots[spotKey] }
        end
    end
    return wanted
end

-- Everyone of the farm's who'd be standing about, by id: workers with
-- nothing on, and the office staff (090) unless they're away training.
-- Office ids come from the worker counter, so they never collide.
function TCIdleStaff.getStandingPeople(tc, farmId)
    local people = {}
    for _, worker in pairs(tc.Staff.workersByFarm[farmId] or {}) do
        if TCIdleStaff.isStandingStatus(worker.status) then
            people[worker.id] = worker
        end
    end
    if tc.Office ~= nil then
        for _, member in ipairs(tc.Office:getMembers(farmId)) do
            if not TheContractorOffice.isTraining(member) then
                people[member.id] = member
            end
        end
    end
    return people
end

-- Showing them (clients) ------------------------------------------------------

-- figures[workerId] = { worker, spot (where they're standing), yaw,
-- graphics (nil until loaded nearby), isReady, isVisible }. A figure only
-- exists while its worker is on a spot. occupied[spotKey] = workerId
-- standing there. noStyle[workerId]: their look couldn't be built, so it
-- isn't retried every frame.
TCIdleStaff.figures = {}
TCIdleStaff.occupied = {}
TCIdleStaff.noStyle = {}
TCIdleStaff.wanted = {}
TCIdleStaff.recheckMs = 0

-- loadMap and deleteMap: frees every model.
function TCIdleStaff.reset()
    for workerId in pairs(TCIdleStaff.figures) do
        TCIdleStaff.takeOffSpot(workerId)
    end
    TCIdleStaff.figures = {}
    TCIdleStaff.occupied = {}
    TCIdleStaff.noStyle = {}
    TCIdleStaff.wanted = {}
    TCIdleStaff.recheckMs = 0
end

local function isSpotGone(spot)
    return spot.placeable.isDeleted or spot.placeable.markedForDeletion
end

local function getDistance(spot, cx, cy, cz)
    return MathUtil.vector3Length(spot.x - cx, spot.y - cy, spot.z - cz)
end

-- Can the player see the spot? Within CLIP_DISTANCE, in front of the camera
-- and on screen (or just off it).
function TCIdleStaff.isSeen(spot, camera, cx, cy, cz)
    if getDistance(spot, cx, cy, cz) > TCIdleStaff.CLIP_DISTANCE then
        return false
    end
    local y = spot.y + TCIdleStaff.VIEW_HEIGHT
    -- Cameras look down their -Z.
    local fx, fy, fz = localDirectionToWorld(camera, 0, 0, -1)
    if fx * (spot.x - cx) + fy * (y - cy) + fz * (spot.z - cz) <= 0 then
        return false
    end
    local sx, sy = project(spot.x, y, spot.z)
    local margin = TCIdleStaff.VIEW_MARGIN
    return sx > -margin and sx < 1 + margin and sy > -margin and sy < 1 + margin
end

local function setFigureVisible(figure, isVisible)
    if figure.isVisible ~= isVisible then
        figure.isVisible = isVisible
        if isVisible then
            figure.graphics:show()
        else
            figure.graphics:hide()
        end
    end
end

local function placeModel(figure)
    figure.graphics:setModelPosition(figure.spot.x, figure.spot.y, figure.spot.z)
    figure.graphics:setModelYaw(figure.yaw)
end

function TCIdleStaff.loadModel(workerId, figure)
    local style = TCWorkerAppearance.getPlayerStyle(figure.worker)
    if style == nil then
        TCIdleStaff.noStyle[workerId] = true
        return
    end

    local graphics = HumanGraphicsComponent.new()
    graphics.defaultState.isNPC = true
    graphics:setSoundsEnabled(false)
    graphics:initialize()
    figure.graphics = graphics
    figure.isReady = false
    figure.isVisible = false

    graphics:setStyleAsync(style, function(_, loadingState)
        if figure.graphics ~= graphics then
            return
        end
        if loadingState == HumanModelLoadingState.OK then
            -- Loading shows the model at the origin: hide it until the
            -- next update decides.
            graphics:hide()
            graphics:defaultAllParameters()
            placeModel(figure)
            figure.isReady = true
        else
            Logging.warning("TheContractor: couldn't load worker %d (%s) for a standing spot", workerId,
                figure.worker.name)
            TCIdleStaff.noStyle[workerId] = true
        end
    end, nil, nil, true)
end

function TCIdleStaff.freeModel(figure)
    if figure.graphics ~= nil then
        figure.graphics:delete()
        figure.graphics = nil
    end
    figure.isReady = false
    figure.isVisible = false
end

-- The worker's look changed (066): they stay on their spot and the next
-- update loads the new model, if they're close enough to need one.
function TCIdleStaff.reloadLook(worker)
    TCIdleStaff.noStyle[worker.id] = nil
    local figure = TCIdleStaff.figures[worker.id]
    if figure ~= nil then
        figure.worker = worker
        TCIdleStaff.freeModel(figure)
    end
end

function TCIdleStaff.putOnSpot(workerId, worker, spot)
    local figure = { worker = worker, spot = spot, yaw = spot.yaw, graphics = nil, isReady = false,
        isVisible = false }
    TCIdleStaff.figures[workerId] = figure
    TCIdleStaff.occupied[spot.key] = workerId
    PlaceableTCStandingSpot.setBlockerActive(spot.placeable, true)
    return figure
end

function TCIdleStaff.takeOffSpot(workerId)
    local figure = TCIdleStaff.figures[workerId]
    if figure == nil then
        return
    end
    TCIdleStaff.freeModel(figure)
    TCIdleStaff.figures[workerId] = nil
    local spot = figure.spot
    if TCIdleStaff.occupied[spot.key] == workerId then
        TCIdleStaff.occupied[spot.key] = nil
    end
    if not isSpotGone(spot) then
        PlaceableTCStandingSpot.setBlockerActive(spot.placeable, false)
    end
end

-- Turns a shown worker towards a local player on foot nearby, or back to
-- the spot's arrow, at NPC's speed, feeding the turn to the animation.
local function updateFacing(figure, dt)
    local targetYaw = figure.spot.yaw
    local player = g_localPlayer
    if player ~= nil and not player:getIsInVehicle() then
        local px, _, pz = player:getPosition()
        local dx, dz = px - figure.spot.x, pz - figure.spot.z
        local distance = MathUtil.vector2Length(dx, dz)
        if distance > 0.01 and distance < TCIdleStaff.FACE_DISTANCE then
            targetYaw = MathUtil.getYRotationFromDirection(dx / distance, dz / distance)
        end
    end

    local target = MathUtil.normalizeRotationForShortestPath(targetYaw, figure.yaw)
    local step = dt * TCIdleStaff.ROTATION_SPEED
    local yaw
    if figure.yaw < target then
        yaw = math.min(figure.yaw + step, target)
    else
        yaw = math.max(figure.yaw - step, target)
    end
    figure.graphics.defaultState.rotationVelocity = MathUtil.getAngleDifference(yaw, figure.yaw)
    figure.yaw = yaw
    figure.graphics:setModelYaw(yaw)
end

function TCIdleStaff.updateWorker(workerId, entry, dt, camera, cx, cy, cz)
    local figure = TCIdleStaff.figures[workerId]

    -- Off a spot that's gone at once, and off one they're no longer wanted
    -- on once nobody can see it.
    if figure ~= nil then
        local isWantedHere = entry ~= nil and entry.spot.key == figure.spot.key
        if isSpotGone(figure.spot) or
                (not isWantedHere and not TCIdleStaff.isSeen(figure.spot, camera, cx, cy, cz)) then
            TCIdleStaff.takeOffSpot(workerId)
            figure = nil
        end
    end

    -- Onto the spot they're wanted on, once it's free and nobody can see it.
    if figure == nil and entry ~= nil and TCIdleStaff.occupied[entry.spot.key] == nil and
            not TCIdleStaff.isSeen(entry.spot, camera, cx, cy, cz) then
        figure = TCIdleStaff.putOnSpot(workerId, entry.worker, entry.spot)
    end

    if figure == nil then
        return
    end

    local distance = getDistance(figure.spot, cx, cy, cz)
    if figure.graphics == nil then
        if distance <= TCIdleStaff.LOAD_DISTANCE and not TCIdleStaff.noStyle[workerId] then
            TCIdleStaff.loadModel(workerId, figure)
        end
    elseif distance > TCIdleStaff.UNLOAD_DISTANCE then
        TCIdleStaff.freeModel(figure)
    end

    if figure.isReady then
        if distance > TCIdleStaff.CLIP_DISTANCE then
            setFigureVisible(figure, false)
        else
            setFigureVisible(figure, true)
            figure.graphics:defaultAllParameters()
            figure.graphics:update(dt)
            updateFacing(figure, dt)
        end
    end
end

local function getCamera()
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    if camera == nil or camera == 0 then
        return nil
    end
    return camera
end

function TCIdleStaff.update(dt)
    local mission = g_currentMission
    if mission == nil or not mission:getIsClient() then
        return
    end

    TCIdleStaff.recheckMs = TCIdleStaff.recheckMs - dt
    if TCIdleStaff.recheckMs <= 0 then
        TCIdleStaff.recheckMs = TCIdleStaff.RECHECK_MS
        TCIdleStaff.wanted = TCIdleStaff.getWanted()
    end

    local camera = getCamera()
    if camera == nil then
        return
    end
    local cx, cy, cz = getWorldTranslation(camera)

    local workerIds = {}
    for workerId in pairs(TCIdleStaff.figures) do
        workerIds[workerId] = true
    end
    for workerId in pairs(TCIdleStaff.wanted) do
        workerIds[workerId] = true
    end
    for workerId in pairs(workerIds) do
        TCIdleStaff.updateWorker(workerId, TCIdleStaff.wanted[workerId], dt, camera, cx, cy, cz)
    end
end

-- Console ---------------------------------------------------------------------

-- tcWorker standing: why each of the farm's workers is or isn't standing.
function TCIdleStaff.describe(farmId)
    local mission = g_currentMission
    local wanted = TCIdleStaff.getWanted()
    local camera = getCamera()
    local cx, cy, cz = 0, 0, 0
    if camera ~= nil then
        cx, cy, cz = getWorldTranslation(camera)
    end

    local spotCount = 0
    if mission.placeableSystem ~= nil then
        for _, placeable in ipairs(mission.placeableSystem.placeables) do
            if PlaceableTCStandingSpot.isSpot(placeable) and not placeable.isDeleted and
                    placeable:getOwnerFarmId() == farmId then
                spotCount = spotCount + 1
            end
        end
    end

    local lines = { string.format("Farm %d: %d standing spot(s), day %d", farmId, spotCount,
        mission.environment.currentMonotonicDay or 0) }
    local isWorkingHours = TCIdleStaff.isWorkingHours(mission.environment.dayTime)
    if not isWorkingHours then
        table.insert(lines, string.format("Outside working hours (%02d:00-%02d:00): staff have gone home",
            TCIdleStaff.START_HOUR, TCIdleStaff.END_HOUR))
    end
    local roster = mission.TheContractor.Staff:getRoster(farmId)
    table.sort(roster, function(a, b) return a.id < b.id end)
    for _, worker in ipairs(roster) do
        local entry = wanted[worker.id]
        local figure = TCIdleStaff.figures[worker.id]
        local text
        if not TCIdleStaff.isStandingStatus(worker.status) then
            text = "not standing (" .. worker.status .. ")"
        elseif not isWorkingHours then
            text = figure ~= nil and "gone home once you look away" or "gone home"
        elseif entry == nil then
            text = "no spot free"
        else
            local spot = entry.spot
            text = string.format("wants spot %s, %.0f m away", spot.key, getDistance(spot, cx, cy, cz))
            if figure == nil then
                local holder = TCIdleStaff.occupied[spot.key]
                if holder ~= nil then
                    text = text .. string.format(", waiting for #%d to leave it", holder)
                elseif camera ~= nil and TCIdleStaff.isSeen(spot, camera, cx, cy, cz) then
                    text = text .. ", waiting until you look away"
                else
                    text = text .. ", not placed yet"
                end
            elseif figure.spot.key ~= spot.key then
                text = text .. string.format(", still on spot %s until you look away", figure.spot.key)
            elseif TCIdleStaff.noStyle[worker.id] then
                text = text .. ", standing, but their look couldn't be loaded"
            elseif figure.graphics == nil then
                text = text .. string.format(", standing, model not loaded (loads within %d m)",
                    TCIdleStaff.LOAD_DISTANCE)
            elseif not figure.isReady then
                text = text .. ", standing, model loading"
            elseif figure.isVisible then
                text = text .. ", standing, shown"
            else
                text = text .. ", standing, hidden (too far)"
            end
        end
        table.insert(lines, string.format("#%d %s - %s", worker.id, worker.name, text))
    end
    return table.concat(lines, "\n")
end

function TCIdleStaff.registerConsoleCommands()
    TCConsole.register("worker", "standing", {
        description = "Show who's standing on your standing spots, and why anyone isn't",
        serverOnly = false,
        run = function(farmId)
            return TCIdleStaff.describe(farmId)
        end,
    })
end
