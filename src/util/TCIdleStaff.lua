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
-- state isn't touched. A spot can be kept for some of the farm's staff
-- (120, PlaceableTCStandingSpot's filter, synced with the placeable): only
-- they stand there, and they take one of theirs before any open spot.
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
-- They're only about during working hours (097, TheContractorWorkingHours,
-- game time), or after them while they're kept on (staying late or called
-- back) or still in a job's cooldown. Anyone else goes home as their spot
-- drops out of view, and turns up again the same way in the morning. The
-- time of day is vanilla's, synced to every machine, and so is the duty
-- that keeps someone on.

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

-- Our own string hash (not math.random, which every machine rolls
-- differently). 114's farmers pick their spot with it too.
function TCIdleStaff.hash(text)
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
    return TCIdleStaff.hash(string.format("%d|%d|%d|%s", farmId, day, workerId, spotKey))
end

-- Best score first; ties by worker id, then spot key.
local function compareCandidates(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.workerId ~= b.workerId then
        return a.workerId < b.workerId
    end
    return a.spotKey < b.spotKey
end

-- One step of the reserved-spot matching (Kuhn's augmenting path): gives
-- workerId one of its spots, moving whoever holds it to another of theirs
-- if they can go.
local function tryReserved(workerId, choices, holders, assignment, tried)
    for _, spotKey in ipairs(choices[workerId]) do
        if not tried[spotKey] then
            tried[spotKey] = true
            local holder = holders[spotKey]
            if holder == nil or tryReserved(holder, choices, holders, assignment, tried) then
                holders[spotKey] = workerId
                assignment[workerId] = spotKey
                return true
            end
        end
    end
    return false
end

-- workerId -> spotKey for one farm. Extra workers get no spot, spare spots
-- stay empty. reservedFor (120, optional): spotKey -> set of the worker ids
-- it's kept for, for each spot whose filter is active. A kept spot only
-- ever takes its own people, and stays empty while none of them is about.
-- Workers fill the spots kept for them first: as many of them as can be
-- placed (a maximum matching), each trying their spots best score first,
-- so a worker with several picks among them day by day. Anyone left over
-- (a worker with no kept spot, or whose spots are all taken by others
-- they're kept for) goes on the open spots, greedily by score.
function TCIdleStaff.assign(farmId, day, workerIds, spotKeys, reservedFor)
    reservedFor = reservedFor or {}
    local assignment = {}

    local choices = {}
    local reservedWorkers = {}
    for _, workerId in ipairs(workerIds) do
        local candidates = {}
        for _, spotKey in ipairs(spotKeys) do
            local keptFor = reservedFor[spotKey]
            if keptFor ~= nil and keptFor[workerId] then
                table.insert(candidates, { workerId = workerId, spotKey = spotKey,
                    score = TCIdleStaff.getScore(farmId, day, workerId, spotKey) })
            end
        end
        if #candidates > 0 then
            table.sort(candidates, compareCandidates)
            choices[workerId] = {}
            for _, candidate in ipairs(candidates) do
                table.insert(choices[workerId], candidate.spotKey)
            end
            table.insert(reservedWorkers, candidates[1])
        end
    end
    -- Whoever likes their best kept spot most goes first.
    table.sort(reservedWorkers, compareCandidates)
    local holders = {}
    for _, candidate in ipairs(reservedWorkers) do
        tryReserved(candidate.workerId, choices, holders, assignment, {})
    end

    local candidates = {}
    for _, workerId in ipairs(workerIds) do
        if assignment[workerId] == nil then
            for _, spotKey in ipairs(spotKeys) do
                if reservedFor[spotKey] == nil then
                    table.insert(candidates, {
                        workerId = workerId,
                        spotKey = spotKey,
                        score = TCIdleStaff.getScore(farmId, day, workerId, spotKey),
                    })
                end
            end
        end
    end
    table.sort(candidates, compareCandidates)

    local takenSpots = {}
    for _, candidate in ipairs(candidates) do
        if assignment[candidate.workerId] == nil and not takenSpots[candidate.spotKey] then
            assignment[candidate.workerId] = candidate.spotKey
            takenSpots[candidate.spotKey] = true
        end
    end
    return assignment
end

-- Whether id is one of the farm's staff: a worker on its roster or one of
-- its office staff, whatever they're doing.
function TCIdleStaff.isFarmStaff(tc, farmId, id)
    local farmWorkers = tc.Staff.workersByFarm[farmId]
    if farmWorkers ~= nil and farmWorkers[id] ~= nil then
        return true
    end
    return tc.Office ~= nil and tc.Office:getMemberById(farmId, id) ~= nil
end

-- 120: the set of ids a spot is kept for, or nil if it's open to anyone.
-- A filter naming only staff who've left is open again, rather than empty
-- for good (086's sold machines, the same way).
function TCIdleStaff.getKeptFor(tc, farmId, placeable)
    local filter = PlaceableTCStandingSpot.getFilter(placeable)
    for _, id in ipairs(filter.staffIds) do
        if TCIdleStaff.isFarmStaff(tc, farmId, id) then
            return filter.staffSet
        end
    end
    return nil
end

-- Who should stand where right now: workerId -> { worker, spot }, spot
-- being { key, placeable, x, y, z, yaw, keptFor (120: set of ids, or nil
-- if open) }.
function TCIdleStaff.getWanted()
    local wanted = {}
    local mission = g_currentMission
    local tc = mission.TheContractor
    if tc == nil or tc.Staff == nil or mission.placeableSystem == nil or mission.environment == nil then
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
        local reservedFor = {}
        for key, spot in pairs(spots) do
            table.insert(spotKeys, key)
            spot.keptFor = TCIdleStaff.getKeptFor(tc, farmId, spot.placeable)
            reservedFor[key] = spot.keptFor
        end
        table.sort(spotKeys)

        for workerId, spotKey in pairs(TCIdleStaff.assign(farmId, day, workerIds, spotKeys, reservedFor)) do
            wanted[workerId] = { worker = people[workerId], spot = spots[spotKey] }
        end
    end
    return wanted
end

-- Is this worker about the yard now (097): in a job's cooldown, or idle
-- and at work (working hours, or kept on after them).
function TCIdleStaff.isAbout(worker, now)
    if worker.status == TheContractorWorker.STATUS.COOLDOWN then
        return true
    end
    return TCIdleStaff.isStandingStatus(worker.status) and TheContractorWorkingHours.isOnSite(worker, now)
end

-- Everyone of the farm's who'd be standing about, by id: workers with
-- nothing on who are at work, and the office staff (090) during working
-- hours unless they're away training. Office ids come from the worker
-- counter, so they never collide.
function TCIdleStaff.getStandingPeople(tc, farmId)
    local people = {}
    local now = TheContractorWorkingHours.getNow()
    for _, worker in pairs(tc.Staff.workersByFarm[farmId] or {}) do
        if TCIdleStaff.isAbout(worker, now) then
            people[worker.id] = worker
        end
    end
    if tc.Office ~= nil and TheContractorWorkingHours.isOfficeOpen(now) then
        for _, member in ipairs(tc.Office:getMembers(farmId)) do
            if not TheContractorOffice.isTraining(member) then
                people[member.id] = member
            end
        end
    end
    return people
end

-- Showing them (clients) ------------------------------------------------------

-- figures[workerId] = { person (the worker), spot (where they're standing), yaw,
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

-- A figure (here and 114's farmers): { person, spot = { x, y, z, yaw }, yaw,
-- graphics, isReady, isVisible }.
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

-- Starts loading a figure's model from its person's look. noStyle[id] is
-- set when the look can't be built, so it isn't retried every frame.
function TCIdleStaff.loadModel(id, figure, noStyle)
    local style = TCWorkerAppearance.getPlayerStyle(figure.person)
    if style == nil then
        noStyle[id] = true
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
            TCLog.warning("TheContractor: couldn't load the look of #%d (%s) to stand them about", id,
                figure.person.name)
            noStyle[id] = true
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
        figure.person = worker
        TCIdleStaff.freeModel(figure)
    end
end

function TCIdleStaff.putOnSpot(workerId, worker, spot)
    local figure = { person = worker, spot = spot, yaw = spot.yaw, graphics = nil, isReady = false,
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

-- Turns a shown figure towards a local player on foot nearby, or back to
-- the spot's own facing, at NPC's speed, feeding the turn to the animation.
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

    if figure ~= nil then
        TCIdleStaff.updateModel(workerId, figure, TCIdleStaff.noStyle, dt, cx, cy, cz)
    end
end

-- Loads a figure's model once its spot is within LOAD_DISTANCE, frees it
-- beyond UNLOAD_DISTANCE, and shows and animates it within CLIP_DISTANCE.
function TCIdleStaff.updateModel(id, figure, noStyle, dt, cx, cy, cz)
    local distance = getDistance(figure.spot, cx, cy, cz)
    if figure.graphics == nil then
        if distance <= TCIdleStaff.LOAD_DISTANCE and not noStyle[id] then
            TCIdleStaff.loadModel(id, figure, noStyle)
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

function TCIdleStaff.getCamera()
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

    local camera = TCIdleStaff.getCamera()
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

-- tcDebug standing: why each of the farm's workers is or isn't standing.
function TCIdleStaff.describe(farmId)
    local mission = g_currentMission
    local wanted = TCIdleStaff.getWanted()
    local camera = TCIdleStaff.getCamera()
    local cx, cy, cz = 0, 0, 0
    if camera ~= nil then
        cx, cy, cz = getWorldTranslation(camera)
    end

    local spotCount, keptCount = 0, 0
    if mission.placeableSystem ~= nil then
        for _, placeable in ipairs(mission.placeableSystem.placeables) do
            if PlaceableTCStandingSpot.isSpot(placeable) and not placeable.isDeleted and
                    placeable:getOwnerFarmId() == farmId then
                spotCount = spotCount + 1
                if TCIdleStaff.getKeptFor(mission.TheContractor, farmId, placeable) ~= nil then
                    keptCount = keptCount + 1
                end
            end
        end
    end

    local lines = { string.format("Farm %d: %d standing spot(s), %d kept for named staff, day %d", farmId,
        spotCount, keptCount, mission.environment.currentMonotonicDay or 0) }
    local now = TheContractorWorkingHours.getNow()
    if not TheContractorWorkingHours.isWorkingTime(now) then
        table.insert(lines, string.format("Outside working hours (%02d:00-%02d:00): only staff kept on are about",
            TheContractorWorkingHours.START_HOUR, TheContractorWorkingHours.END_HOUR))
    end
    local roster = mission.TheContractor.Staff:getRoster(farmId)
    table.sort(roster, function(a, b) return a.id < b.id end)
    for _, worker in ipairs(roster) do
        local entry = wanted[worker.id]
        local figure = TCIdleStaff.figures[worker.id]
        local text
        if not TCIdleStaff.isStandingStatus(worker.status) then
            text = "not standing (" .. worker.status .. ")"
        elseif not TCIdleStaff.isAbout(worker, now) then
            text = figure ~= nil and "gone home once you look away" or "gone home"
        elseif entry == nil then
            text = "no spot free"
        else
            local spot = entry.spot
            text = string.format("wants spot %s%s, %.0f m away", spot.key,
                spot.keptFor ~= nil and " (kept for them)" or "", getDistance(spot, cx, cy, cz))
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
    TCConsole.register("debug", "standing", {
        description = "Show who's standing on your standing spots, and why anyone isn't",
        serverOnly = false,
        run = function(farmId)
            return TCIdleStaff.describe(farmId)
        end,
    })
end
