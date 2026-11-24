-- Ploughing match scoring (168, spike): a trial plot, driven from the
-- console (tcDebug showPlough) with no match around it. The scoring itself
-- is TCPloughScore's; this is the engine half that feeds it.
--
--   start (server): a square plot laid from where the typing player is, in
--     the middle of its near edge and facing in (from a vehicle, the
--     vehicle's position and heading, so the tractor stands at the plot's
--     edge pointing down the opening split). The ground's grid is read once
--     (each cell's ploughed share), so only ploughing since counts.
--   The path (update, server, every SAMPLE_MS): the ploughman is the vehicle
--     the player started from, or else the first one seen with a lowered
--     plough over the plot. Each sample is the plough's position and heading
--     (its directionNode, the one vanilla dates the furrow angle from), the
--     tractor's speed and direction, and whether the plough's lowered. It's
--     the server's own copy of the vehicle, which it simulates, so a
--     client's driving is sampled the same as the host's.
--   The clock: game minutes (the clock, what the limit's in) and real
--     minutes of driving (the mission's time, which vehicles move in
--     whatever the time scale), until the plough was last down in the plot.
--   score (server): the grid read again, the furrow angle's histogram over
--     the plot (one read per angle value), the runs from the path, and the
--     total with its breakdown. It can be run any number of times.
--   The debug lines (this machine): the plot white, its margin grey, the
--     path green where it's a judged run, red reversing with the plough
--     down, blue with the plough up.
--
-- A spike: nothing's saved or synced, and a load forgets the trial.

TCPloughTrial = {}

TCPloughTrial.SAMPLE_MS = 200
TCPloughTrial.MAX_SAMPLES = 30000
-- The ploughman is looked for this far outside the plot.
TCPloughTrial.FIND_GROW = 10

-- Server: { plot, rules, grid, samples, vehicleId, realMs, gameMs,
-- lastWorkRealMs, lastWorkGameMs, sinceSampleMs, readMs }, or nil.
TCPloughTrial.trial = nil
-- This machine: the lines drawn.
TCPloughTrial.debugVisible = false

-- The ground -----------------------------------------------------------------------------------

local function getPloughedFilter()
    local fieldGroundSystem = g_currentMission.fieldGroundSystem
    local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local filter = DensityMapFilter.new(modifier)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, FieldGroundType.getValueByType(FieldGroundType.PLOWED))
    return modifier, filter
end

-- A plot-local rectangle (centre u, v, half sizes) onto a modifier.
local function setArea(modifier, plot, u, v, halfU, halfV)
    local sx, sz = TCPloughScore.toWorld(plot, u - halfU, v - halfV)
    local wx, wz = TCPloughScore.toWorld(plot, u + halfU, v - halfV)
    local hx, hz = TCPloughScore.toWorld(plot, u - halfU, v + halfV)
    modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
end

-- Each cell's ploughed share into field `key` (before or ploughed). Returns
-- the milliseconds it took. 169: the match reads its plots with it too.
function TCPloughTrial.readGrid(plot, grid, key)
    local started = getTimeSec()
    local modifier, filter = getPloughedFilter()
    local half = grid.cellSize * 0.5
    for _, cell in ipairs(grid.cells) do
        setArea(modifier, plot, cell.u, cell.v, half, half)
        local _, area, totalArea = modifier:executeGet(filter)
        cell[key] = totalArea ~= nil and totalArea > 0 and (area or 0) / totalArea or 0
    end
    return (getTimeSec() - started) * 1000
end

local function readGrid(trial, key)
    return TCPloughTrial.readGrid(trial.plot, trial.grid, key)
end

-- The plot's ploughed pixels by furrow angle value: histogram[value + 1].
-- nil if the map has no angle channel.
function TCPloughTrial.readAngles(plot)
    local fieldGroundSystem = g_currentMission.fieldGroundSystem
    local maxValue = fieldGroundSystem.getGroundAngleMaxValue ~= nil and fieldGroundSystem:getGroundAngleMaxValue() or nil
    local mapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_ANGLE)
    if maxValue == nil or mapId == nil then
        return nil, nil
    end
    local _, ploughedFilter = getPloughedFilter()
    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    local angleFilter = DensityMapFilter.new(modifier)
    local half = plot.size * 0.5
    setArea(modifier, plot, half, 0, half, half)
    local histogram = {}
    for value = 0, maxValue do
        angleFilter:setValueCompareParams(DensityValueCompareType.EQUAL, value)
        local _, area = modifier:executeGet(ploughedFilter, angleFilter)
        histogram[value + 1] = area or 0
    end
    return histogram, maxValue
end

-- The ploughman ----------------------------------------------------------------------------------

-- The plough on a vehicle's train (the vehicle itself or anything hitched
-- to its root), or nil.
function TCPloughTrial.findPlough(vehicle)
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local chain = root.getChildVehicles ~= nil and root:getChildVehicles() or { root }
    for _, child in pairs(chain) do
        if child.spec_plow ~= nil then
            return child, root
        end
    end
    return nil, root
end

function TCPloughTrial.isLowered(plough)
    return plough.getIsLowered ~= nil and plough:getIsLowered(false) == true
end
local isLowered = TCPloughTrial.isLowered

local function getPloughPosition(plough)
    local x, _, z = getWorldTranslation(plough.rootNode)
    return x, z
end

-- The first vehicle with a lowered plough over the plot.
local function findPloughman(trial)
    for _, vehicle in ipairs(g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles or {}) do
        if vehicle.spec_plow ~= nil and isLowered(vehicle) then
            local x, z = getPloughPosition(vehicle)
            local u, v = TCPloughScore.toLocal(trial.plot, x, z)
            if TCPloughScore.isInside(trial.plot, u, v, TCPloughTrial.FIND_GROW) then
                local _, root = TCPloughTrial.findPlough(vehicle)
                return root
            end
        end
    end
    return nil
end

-- One sample of a ploughman (a vehicle with a plough on its train) at
-- t seconds, or nil with no plough: TCPloughScore's sample (with y, for the
-- debug lines). 169: the match samples its plots' kit with it too.
function TCPloughTrial.sampleVehicle(root, t)
    local plough = TCPloughTrial.findPlough(root)
    if plough == nil then
        return nil
    end
    local x, z = getPloughPosition(plough)
    local directionNode = plough.spec_plow.directionNode or plough.rootNode
    local hx, _, hz = localDirectionToWorld(directionNode, 0, 0, 1)
    return {
        t = t,
        x = x,
        z = z,
        y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.3,
        hx = hx,
        hz = hz,
        speed = root.getLastSpeed ~= nil and root:getLastSpeed() or 0,
        dir = root.movingDirection or 0,
        lowered = isLowered(plough),
    }
end

local function sample(trial, root)
    local entry = TCPloughTrial.sampleVehicle(root, trial.realMs / 1000)
    if entry == nil then
        return
    end
    local x, z, lowered = entry.x, entry.z, entry.lowered
    if #trial.samples < TCPloughTrial.MAX_SAMPLES then
        table.insert(trial.samples, entry)
    end
    local u, v = TCPloughScore.toLocal(trial.plot, x, z)
    if lowered and TCPloughScore.isInside(trial.plot, u, v) then
        trial.lastWorkRealMs, trial.lastWorkGameMs = trial.realMs, trial.gameMs
    end
end

-- Every frame (server).
function TCPloughTrial.update(dt)
    local trial = TCPloughTrial.trial
    if trial == nil or g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    trial.realMs = trial.realMs + dt
    trial.gameMs = trial.gameMs + dt * g_currentMission:getEffectiveTimeScale()
    trial.sinceSampleMs = trial.sinceSampleMs + dt
    if trial.sinceSampleMs < TCPloughTrial.SAMPLE_MS then
        return
    end
    trial.sinceSampleMs = 0
    local root = trial.vehicleId ~= nil and NetworkUtil.getObject(trial.vehicleId) or nil
    if root == nil then
        root = findPloughman(trial)
        if root == nil then
            return
        end
        trial.vehicleId = NetworkUtil.getObjectId(root)
    end
    sample(trial, root)
end

-- Console ------------------------------------------------------------------------------------------

function TCPloughTrial.start(context, size, minutes)
    local rules = {}
    for key, value in pairs(TCPloughScore.RULES) do
        rules[key] = value
    end
    rules.plotSize = size or rules.plotSize
    rules.timeLimitMinutes = minutes or rules.timeLimitMinutes

    local vehicle = TCConsole.getVehicle(context)
    local x, z, dirX, dirZ
    if vehicle ~= nil and vehicle.rootNode ~= nil then
        local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
        x, _, z = getWorldTranslation(root.rootNode)
        dirX, _, dirZ = localDirectionToWorld(root.rootNode, 0, 0, 1)
        vehicle = root
    elseif TCConsole.hasPosition(context) then
        x, z, dirX, dirZ = context.x, context.z, context.dirX or 0, context.dirZ or 1
    else
        return "No position: stand where the plot's near edge goes, facing in, or sit in the tractor there."
    end

    local plot = TCPloughScore.newPlot(x, z, dirX, dirZ, rules.plotSize)
    local trial = {
        plot = plot,
        rules = rules,
        grid = TCPloughScore.makeGrid(plot, rules),
        samples = {},
        vehicleId = vehicle ~= nil and NetworkUtil.getObjectId(vehicle) or nil,
        realMs = 0,
        gameMs = 0,
        sinceSampleMs = 0,
    }
    trial.readMs = readGrid(trial, "before")
    TCPloughTrial.trial = trial
    TCPloughTrial.debugVisible = true

    local ground = TCPloughScore.measureGround(trial.grid, plot, true, rules)
    local lines = {
        string.format("Ploughing trial: a %d m plot from here, %d game minutes allowed. Grid of %d cells (%d m) read in %.0f ms.",
            rules.plotSize, rules.timeLimitMinutes, #trial.grid.cells, rules.cellSize, trial.readMs),
        vehicle ~= nil and "Ploughman: the vehicle you're in." or
            "Ploughman: the first vehicle with a lowered plough over the plot.",
        string.format("Estimate at %d km/h with %d s turns: %.0f real min with a 3-furrow (1.2 m), %.0f with a 4-furrow (1.6 m).",
            rules.estimateSpeedKmh, rules.estimateTurnSeconds, TCPloughScore.estimateMinutes(rules.plotSize, 1.2, rules),
            TCPloughScore.estimateMinutes(rules.plotSize, 1.6, rules)),
        "The plot white, its margin grey (this machine). 'tcDebug showPlough score' scores it.",
    }
    if ground.alreadyPloughed > 0.01 then
        table.insert(lines, string.format("Warning: %.0f%% of the plot is ploughed already; only what's left is scored.",
            ground.alreadyPloughed * 100))
    end
    return table.concat(lines, "\n")
end

local PART_WORDS = {
    coverage = "Coverage",
    straightness = "Straightness",
    split = "Opening split",
    furrowAngle = "Furrow angle",
    ends = "Neat ends",
    outside = "Outside the plot",
    tidiness = "Tidiness",
}

function TCPloughTrial.score()
    local trial = TCPloughTrial.trial
    if trial == nil then
        return "There's no trial: 'tcDebug showPlough start' first."
    end
    local plot, rules = trial.plot, trial.rules
    local readMs = readGrid(trial, "ploughed")
    local started = getTimeSec()
    local histogram, maxAngle = TCPloughTrial.readAngles(plot)
    local angleMs = (getTimeSec() - started) * 1000

    local runs, reverses, stops = TCPloughScore.splitRuns(trial.samples, plot, rules)
    local alongU = TCPloughScore.getWorkAxis(runs, plot)
    local ground = TCPloughScore.measureGround(trial.grid, plot, alongU, rules)
    local angles = histogram ~= nil and TCPloughScore.measureAngles(histogram) or nil
    local realMinutes = (trial.lastWorkRealMs or trial.realMs) / 60000
    local gameMinutes = (trial.lastWorkGameMs or trial.gameMs) / 60000
    local result = TCPloughScore.score({
        ground = ground,
        runs = runs,
        angles = angles,
        reverses = reverses,
        stops = stops,
        minutes = gameMinutes,
    }, rules)

    local runLength = 0
    for _, run in ipairs(runs) do
        runLength = runLength + run.length
    end
    local width = runLength > 0 and ground.ploughedArea / runLength or nil

    local lines = {
        string.format("Ploughing trial score: %.1f / 100 (time %.0f game min, %.1f real min; limit %d game min%s).",
            result.total, gameMinutes, realMinutes, rules.timeLimitMinutes,
            result.minutesOver > 0 and string.format(", %d over: -%.1f", result.minutesOver, result.timePenalty) or ""),
    }
    for _, name in ipairs(TCPloughScore.PARTS) do
        local part = result.parts[name]
        if part ~= nil then
            local detail
            if name == "coverage" then
                detail = string.format("%.1f%% of the plot", part.value * 100)
            elseif name == "ends" then
                detail = string.format("%.1f%% of the end bands unploughed (runs along the %s)", part.value * 100,
                    alongU and "plot" or "width")
            elseif name == "outside" then
                detail = string.format("%.0f m2 ploughed outside", part.value)
            elseif name == "split" then
                local split = runs[1]
                detail = split ~= nil and string.format("%.0f m, drift %.2f m RMS (%.2f max), heading %.1f deg RMS",
                    split.length, split.lateralRms, split.lateralMax, split.headingRms) or "no run"
            elseif name == "straightness" then
                detail = string.format("%d run(s) after the split", math.max(0, #runs - 1))
            elseif name == "furrowAngle" then
                detail = string.format("%.0f%% in the best two of %d angles (%.1f deg each)", part.value * 100,
                    maxAngle + 1, 180 / (maxAngle + 1))
            elseif name == "tidiness" then
                detail = string.format("%d reverse(s) and %d stop(s) with the plough down", reverses, stops)
            end
            table.insert(lines, string.format("  %s: %.1f / %d - %s", PART_WORDS[name], part.marks, part.max, detail))
        end
    end
    if histogram == nil then
        table.insert(lines, "  Furrow angle: the map has no angle channel, left out.")
    end
    for i, run in ipairs(runs) do
        table.insert(lines, string.format("  run %d: %.0f m, drift %.2f m RMS (%.2f max), heading %.1f deg RMS, %d samples",
            i, run.length, run.lateralRms, run.lateralMax, run.headingRms, run.count))
    end
    if histogram ~= nil then
        local counts = {}
        for i, count in ipairs(histogram) do
            counts[i] = tostring(count)
        end
        table.insert(lines, "  Angle pixels by value: " .. table.concat(counts, " "))
    end
    table.insert(lines, string.format("  %d samples; ground read in %.0f ms (%d cells), angles in %.0f ms.",
        #trial.samples, readMs, #trial.grid.cells, angleMs))
    if width ~= nil then
        table.insert(lines, string.format("  Working width from the ground: %.2f m; this plot estimated at %.0f real min, %d m would take 15.",
            width, TCPloughScore.estimateMinutes(plot.size, width, rules),
            TCPloughScore.sizeForMinutes(15, width, rules)))
    end
    return table.concat(lines, "\n")
end

function TCPloughTrial.clear()
    if TCPloughTrial.trial == nil then
        return "There's no trial."
    end
    TCPloughTrial.trial = nil
    TCPloughTrial.debugVisible = false
    return "Ploughing trial cleared (the ground stays as it is)."
end

function TCPloughTrial.describe()
    local trial = TCPloughTrial.trial
    if trial == nil then
        return "There's no trial. 'tcDebug showPlough start [size] [minutes]' marks one where you stand."
    end
    return string.format("Ploughing trial: %d m plot, %.0f game min (%.1f real) so far, %d samples, ploughman %s.",
        trial.plot.size, trial.gameMs / 60000, trial.realMs / 60000, #trial.samples,
        trial.vehicleId ~= nil and "found" or "not found yet")
end

-- Debug lines --------------------------------------------------------------------------------------

local function drawLoop(points, r, g, b)
    for i = 1, #points do
        local a, c = points[i], points[i % #points + 1]
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) + 0.3
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, c.x, 0, c.z) + 0.3
        drawDebugLine(a.x, ay, a.z, r, g, b, c.x, cy, c.z, r, g, b)
    end
end

-- Every frame on a machine with a client.
function TCPloughTrial.draw()
    local trial = TCPloughTrial.trial
    if not TCPloughTrial.debugVisible or trial == nil or drawDebugLine == nil then
        return
    end
    drawLoop(TCPloughScore.getCorners(trial.plot), 1, 1, 1)
    drawLoop(TCPloughScore.getCorners(trial.plot, trial.rules.margin), 0.5, 0.5, 0.5)
    local samples = trial.samples
    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        local r, g, bl = 0.3, 0.3, 1
        if b.lowered and b.dir == -1 then
            r, g, bl = 1, 0.2, 0.2
        elseif b.lowered then
            r, g, bl = 0.2, 1, 0.2
        end
        drawDebugLine(a.x, a.y, a.z, r, g, bl, b.x, b.y, b.z, r, g, bl)
    end
end

function TCPloughTrial.registerConsoleCommands()
    TCConsole.register("debug", "showPlough", {
        args = "[start [size] [minutes]|score|clear]",
        description = "Ploughing match scoring spike: mark a plot where you stand (or from the tractor), plough it, then score it",
        run = function(_, args, context)
            local action = args[1] ~= nil and string.lower(args[1]) or nil
            if action == nil then
                return TCPloughTrial.describe()
            elseif action == "start" then
                local size = args[2] ~= nil and tonumber(args[2]) or nil
                local minutes = args[3] ~= nil and tonumber(args[3]) or nil
                if (args[2] ~= nil and (size == nil or size < 10 or size > 200)) or
                    (args[3] ~= nil and (minutes == nil or minutes < 1)) or args[4] ~= nil then
                    return false
                end
                return TCPloughTrial.start(context, size ~= nil and math.floor(size) or nil,
                    minutes ~= nil and math.floor(minutes) or nil)
            elseif args[2] ~= nil then
                return false
            elseif action == "score" then
                return TCPloughTrial.score()
            elseif action == "clear" then
                return TCPloughTrial.clear()
            end
            return false
        end,
    })
end
