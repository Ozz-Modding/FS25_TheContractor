-- Show site (164, spike): finding the ground for the agricultural show's
-- one combined day (165) on real maps, and dressing it and putting it back,
-- driven from the console (tcDebug showSite) with no show around it yet.
-- The pure half is TCShowSite.
--
--   Picking (getCandidates, server): a field nobody's farm owns, held by a
--     farmer (110), with no live job and no day out on it (135's
--     getFieldRefusal), not a vine or orchard (156's PERMANENT_CROPS: not
--     ground to plough). Any crop otherwise: the site's put back as it was
--     afterwards. Each such field is tried on its own (TCShowSite.
--     splitSingle), and every pair of them next to each other (findPairs)
--     both ways round. The showground's entrance is the road point nearest
--     its field (135's findEntrance). Plots are picked for flat ground
--     (each plot's steepest 8 m, from terrain heights), the showground's
--     slope measured too. Ranked by TCShowSite.rankCandidates: one field
--     before a pair.
--   Dressing (dress, server): every field in the site is snapshotted as
--     143 does for an auction (snapshotField), then painted: one field,
--     its showground side of the dividing line put down to short grass and
--     the rest to even stubble of its own crop (wheat's if it has none
--     with a cut state); a pair, the showground field all grass and the
--     other all stubble. The plots are in the stubble, nothing ploughed or
--     cultivated in them.
--   Putting it back (restore, server): each field to its snapshot, the
--     plots and all, whatever its crop and stage.
--   Saving: the plan (fields, rectangles, line, plots, entrance), whether
--     it's dressed and the snapshots, in TheContractor.xml, so a save between
--     the two still puts the ground back after a load. The ground itself is
--     synced and saved by the engine, so clients need nothing of ours.
--   The debug lines (this machine, the one the console ran on): the
--     showground green, the ploughing ground's edge and the dividing line
--     yellow, the plots white, the entrance a yellow post.
--
-- 165 calls dress at midnight before the day and restore at midnight after.
-- Server-wide, not a farm's: nothing to forget when a farm is deleted.

TheContractorShowSite = {}
local TheContractorShowSite_mt = Class(TheContractorShowSite)

-- Metres between the terrain samples a slope is measured from.
TheContractorShowSite.SLOPE_STEP = 8
-- A field smaller than this isn't tried.
TheContractorShowSite.MIN_AREA_HA = 1
-- The candidates listed.
TheContractorShowSite.TOP_CANDIDATES = 8

function TheContractorShowSite.new()
    local self = setmetatable({}, TheContractorShowSite_mt)
    -- Server: { plan, dressed, snapshots = { [fieldId] = snapshot } }, or
    -- nil. plan: { mode, showFieldId, ploughFieldId, showRect, ploughRect,
    -- line (one field only), plots, entrance }.
    self.site = nil
    -- This machine: the plan's lines drawn (the console's).
    self.debugVisible = false
    return self
end

-- Measuring (server) ----------------------------------------------------------------------

-- A rectangle's steepest slope (percent), from terrain heights.
function TheContractorShowSite.measureRectSlope(rect)
    local step = TheContractorShowSite.SLOPE_STEP
    local heights = {}
    for _, point in ipairs(TCAuctionLayout.getSamplePoints(rect, step)) do
        heights[point.row] = heights[point.row] or {}
        heights[point.row][point.col] = getTerrainHeightAtWorldPos(g_terrainNode, point.x, 0, point.z)
    end
    local steepest = TCAuctionLayout.measureSlope(heights, step)
    return steepest or 0
end

local function getHolder(field)
    return TheContractorEventDay.getHolder(field)
end

-- Why a field can't be part of a show site at all (nil if it can): the
-- console's words.
function TheContractorShowSite.getFieldRefusal(field)
    local refusal = TheContractorAuctionSite.getFieldRefusal(field)
    if refusal ~= nil then
        return refusal
    end
    if getHolder(field) == nil then
        return "no farmer holds it"
    end
    local fieldState = field.getFieldState ~= nil and field:getFieldState() or nil
    local fruitType = fieldState ~= nil and fieldState.fruitTypeIndex ~= nil and
        g_fruitTypeManager:getFruitTypeByIndex(fieldState.fruitTypeIndex) or nil
    if fruitType ~= nil and fruitType.name ~= nil and TCSiteClearance.PERMANENT_CROPS[string.upper(fruitType.name)] then
        return "it's a vine or orchard"
    end
    return nil
end

-- A field's shape: { field, id, polygon, rect, areaHa, entrance }.
local function measureField(field, roads)
    local polygon = TCAuctionCrowd.getFieldPolygon(field)
    return {
        field = field,
        id = field:getId(),
        polygon = polygon,
        rect = TCAuctionCrowd.findLargestRect(polygon, TCShowSite.RECT_LAYOUT),
        areaHa = field:getAreaHa() or 0,
        entrance = TCAuctionLayout.findEntrance(polygon, roads, TCShowSite.RULES.entranceReach),
    }
end

-- The plots in a ploughing ground, picked for flat ground.
local function planPlots(region)
    local rows = TCShowSite.layPlots(region)
    local slopes = {}
    local plots, worst = TCShowSite.pickPlots(rows, nil, function(plot)
        local key = plot.row .. ":" .. plot.slot
        if slopes[key] == nil then
            slopes[key] = TheContractorShowSite.measureRectSlope(TCShowSite.plotRect(plot))
        end
        return slopes[key]
    end)
    return plots, worst
end

-- A candidate on one field (its shape, measureField's).
function TheContractorShowSite.planSingle(shape)
    local candidate = {
        mode = TCShowSite.MODE.SINGLE,
        fieldIds = { shape.id },
        areaHa = shape.areaHa,
        hasShowground = false,
        plotCount = 0,
        entranceDistance = shape.entrance ~= nil and shape.entrance.distance or nil,
    }
    local split = shape.rect ~= nil and TCShowSite.splitSingle(shape.rect, shape.entrance) or nil
    if split == nil then
        return candidate
    end
    local plots, worst = planPlots(split.ploughRect)
    candidate.hasShowground = true
    candidate.plotCount = #plots
    candidate.plotSlope = #plots > 0 and worst or nil
    candidate.showgroundSlope = TheContractorShowSite.measureRectSlope(split.showRect)
    candidate.plan = {
        mode = TCShowSite.MODE.SINGLE,
        showFieldId = shape.id,
        ploughFieldId = shape.id,
        showRect = split.showRect,
        ploughRect = split.ploughRect,
        line = split.line,
        plots = plots,
        entrance = shape.entrance,
    }
    return candidate
end

-- A candidate on two fields: the showground on one, the plots on the other.
function TheContractorShowSite.planPair(showShape, ploughShape)
    local candidate = {
        mode = TCShowSite.MODE.PAIR,
        fieldIds = { showShape.id, ploughShape.id },
        areaHa = showShape.areaHa + ploughShape.areaHa,
        hasShowground = TCShowSite.isShowground(showShape.rect),
        plotCount = 0,
        entranceDistance = showShape.entrance ~= nil and showShape.entrance.distance or nil,
    }
    if not candidate.hasShowground or ploughShape.rect == nil then
        return candidate
    end
    local plots, worst = planPlots(ploughShape.rect)
    candidate.plotCount = #plots
    candidate.plotSlope = #plots > 0 and worst or nil
    candidate.showgroundSlope = TheContractorShowSite.measureRectSlope(showShape.rect)
    candidate.plan = {
        mode = TCShowSite.MODE.PAIR,
        showFieldId = showShape.id,
        ploughFieldId = ploughShape.id,
        showRect = showShape.rect,
        ploughRect = ploughShape.rect,
        plots = plots,
        entrance = showShape.entrance,
    }
    return candidate
end

-- Server: every field and pair that could be a show site, ranked. Returns
-- the ranked list and how many fields were tried.
function TheContractorShowSite:getCandidates()
    local roads = TheContractorFallenTree.sampleRoads()
    local shapes, byId = {}, {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        if (field:getAreaHa() or 0) >= TheContractorShowSite.MIN_AREA_HA and
                TheContractorShowSite.getFieldRefusal(field) == nil then
            local shape = measureField(field, roads)
            if #shape.polygon >= 3 then
                table.insert(shapes, shape)
                byId[shape.id] = shape
            end
        end
    end
    local candidates = {}
    for _, shape in ipairs(shapes) do
        table.insert(candidates, TheContractorShowSite.planSingle(shape))
    end
    for _, pair in ipairs(TCShowSite.findPairs(shapes)) do
        local a, b = byId[pair.a], byId[pair.b]
        table.insert(candidates, TheContractorShowSite.planPair(a, b))
        table.insert(candidates, TheContractorShowSite.planPair(b, a))
    end
    return TCShowSite.rankCandidates(candidates), #shapes
end

-- Server: the best site, or nil (165's pick).
function TheContractorShowSite:pickBest()
    local ranked = self:getCandidates()
    local best = ranked[1]
    if best == nil or #best.problems > 0 then
        return nil
    end
    return best
end

-- Server: a plan on a field, or on two (the showground's first). Returns
-- the candidate, or nil and why not.
function TheContractorShowSite:planOn(fieldId, ploughFieldId)
    local roads = TheContractorFallenTree.sampleRoads()
    local shapes = {}
    for _, id in ipairs({ fieldId, ploughFieldId or false }) do
        if id then
            local field = g_fieldManager:getFieldById(id)
            if field == nil then
                return nil, string.format("No field %d.", id)
            end
            local refusal = TheContractorShowSite.getFieldRefusal(field)
            if refusal ~= nil then
                return nil, string.format("Field %d can't be part of a show site: %s.", id, refusal)
            end
            table.insert(shapes, measureField(field, roads))
        end
    end
    if #shapes == 1 then
        return TheContractorShowSite.planSingle(shapes[1])
    end
    local gap = TCShowSite.getGap(shapes[1].polygon, shapes[2].polygon)
    if gap > TCShowSite.RULES.pairMaxGap then
        return nil, string.format("Fields %d and %d are %.0f m apart: at most %.0f m.", fieldId, ploughFieldId, gap,
            TCShowSite.RULES.pairMaxGap)
    end
    return TheContractorShowSite.planPair(shapes[1], shapes[2])
end

-- Dressing and putting back (server) -----------------------------------------------------------

-- The site's fields, the showground's first (once each).
function TheContractorShowSite.getFieldIds(plan)
    if plan.ploughFieldId == plan.showFieldId then
        return { plan.showFieldId }
    end
    return { plan.showFieldId, plan.ploughFieldId }
end

-- Snapshots every field in the site, then dresses it: the showground grass,
-- the ploughing ground stubble. Returns the text to print.
function TheContractorShowSite:dress()
    local site = self.site
    if site == nil then
        return "There's no show site planned: 'tcDebug showSite <fieldId>' first."
    end
    if site.dressed then
        return "The show site's dressed already."
    end
    local plan = site.plan
    site.snapshots = {}
    for _, fieldId in ipairs(TheContractorShowSite.getFieldIds(plan)) do
        local field = g_fieldManager:getFieldById(fieldId)
        local snapshot = field ~= nil and TCFieldPreparation.snapshotField(field) or nil
        if snapshot == nil then
            site.snapshots = {}
            return string.format("Field %d has no state to keep: nothing dressed.", fieldId)
        end
        site.snapshots[fieldId] = snapshot
    end
    local showField = g_fieldManager:getFieldById(plan.showFieldId)
    local ploughField = g_fieldManager:getFieldById(plan.ploughFieldId)
    local ploughCrop = site.snapshots[plan.ploughFieldId].fruitType
    if plan.mode == TCShowSite.MODE.SINGLE then
        local showPart, ploughPart = TCShowSite.splitPolygon(TCAuctionCrowd.getFieldPolygon(showField), plan.line)
        TCFieldPreparation.putDownGrass(showField, TCFieldPreparation.makeArea(showPart))
        TCFieldPreparation.putDownStubble(ploughField, ploughCrop, TCFieldPreparation.makeArea(ploughPart))
    else
        TCFieldPreparation.putDownGrass(showField)
        TCFieldPreparation.putDownStubble(ploughField, ploughCrop)
    end
    site.dressed = true
    TCLog.info("TheContractor: show site dressed (%s, showground field %d, plots on field %d)", plan.mode,
        plan.showFieldId, plan.ploughFieldId)
    local stubble = TCFieldPreparation.getStubbleCrop(ploughCrop)
    return string.format("Show site dressed: the showground to grass, the ploughing ground to %s stubble (field %d was %s). 'tcDebug showSite restore' puts it back.",
        stubble ~= nil and stubble.name or "?", plan.ploughFieldId, ploughCrop)
end

-- Every field back to its snapshot. Returns the text to print.
function TheContractorShowSite:restore()
    local site = self.site
    if site == nil or not site.dressed then
        return "The show site isn't dressed: nothing to put back."
    end
    local restored = {}
    for fieldId, snapshot in pairs(site.snapshots or {}) do
        local field = g_fieldManager:getFieldById(fieldId)
        if field ~= nil and TCFieldPreparation.restoreField(field, snapshot) then
            table.insert(restored, string.format("field %d to %s", fieldId, snapshot.fruitType))
        end
    end
    table.sort(restored)
    site.dressed = false
    site.snapshots = nil
    TCLog.info("TheContractor: show site put back: %s", table.concat(restored, ", "))
    return "Show site put back: " .. (#restored > 0 and table.concat(restored, ", ") or "nothing") .. "."
end

-- The plan dropped (put back first if it's dressed). Returns the text.
function TheContractorShowSite:clear()
    if self.site == nil then
        return "There's no show site."
    end
    local text = "Show site cleared."
    if self.site.dressed then
        text = self:restore() .. " " .. text
    end
    self.site = nil
    self.debugVisible = false
    return text
end

-- Debug lines -----------------------------------------------------------------------------------

local function drawLoop(points, r, g, b)
    for i = 1, #points do
        local a, c = points[i], points[i % #points + 1]
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) + 0.3
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, c.x, 0, c.z) + 0.3
        drawDebugLine(a.x, ay, a.z, r, g, b, c.x, cy, c.z, r, g, b)
    end
end

-- Every frame on a machine with a client: the plan this session made.
function TheContractorShowSite:draw()
    local site = self.site
    if not self.debugVisible or site == nil or drawDebugLine == nil then
        return
    end
    local plan = site.plan
    drawLoop(TCShowSite.getCorners(plan.showRect), 0.2, 1, 0.2)
    drawLoop(TCShowSite.getCorners(plan.ploughRect), 1, 1, 0.2)
    for _, plot in ipairs(plan.plots) do
        drawLoop(TCShowSite.getCorners(TCShowSite.plotRect(plot)), 1, 1, 1)
    end
    if plan.line ~= nil then
        local x, z = plan.line.x, plan.line.z
        local dx, dz = -plan.line.nz * 200, plan.line.nx * 200
        drawLoop({ { x = x - dx, z = z - dz }, { x = x + dx, z = z + dz } }, 1, 1, 0.2)
    end
    local entrance = plan.entrance
    if entrance ~= nil then
        local y = getTerrainHeightAtWorldPos(g_terrainNode, entrance.x, 0, entrance.z)
        drawDebugLine(entrance.x, y, entrance.z, 1, 1, 0, entrance.x, y + 6, entrance.z, 1, 1, 0)
    end
end

-- Console text ----------------------------------------------------------------------------------

local PROBLEM_WORDS = {
    [TCShowSite.PROBLEM.NO_SHOWGROUND] = "no room for the showground",
    [TCShowSite.PROBLEM.TOO_FEW_PLOTS] = "too few plots",
    [TCShowSite.PROBLEM.TOO_STEEP] = "too steep",
    [TCShowSite.PROBLEM.NO_ROAD] = "no road near",
}

function TheContractorShowSite.describeCandidate(candidate)
    local problems = {}
    for _, problem in ipairs(candidate.problems or {}) do
        table.insert(problems, PROBLEM_WORDS[problem] or problem)
    end
    local fields = candidate.mode == TCShowSite.MODE.SINGLE and string.format("field %d", candidate.fieldIds[1]) or
        string.format("fields %d (showground) + %d (plots)", candidate.fieldIds[1], candidate.fieldIds[2])
    return string.format("  %s: %.2f ha, %d plot(s)%s, showground %s, road %s - %s", fields, candidate.areaHa,
        candidate.plotCount or 0,
        candidate.plotSlope ~= nil and string.format(" steepest %.1f%%", candidate.plotSlope) or "",
        candidate.showgroundSlope ~= nil and string.format("steepest %.1f%%", candidate.showgroundSlope) or "none",
        candidate.entranceDistance ~= nil and string.format("%.0f m away", candidate.entranceDistance) or "none",
        #problems == 0 and "can hold the show" or table.concat(problems, ", "))
end

function TheContractorShowSite:getListText()
    local lines = {}
    if self.site ~= nil then
        table.insert(lines, self:describe())
        table.insert(lines, "")
    end
    local started = getTimeSec()
    local ranked, fieldCount = self:getCandidates()
    local R = TCShowSite.RULES
    table.insert(lines, string.format(
        "Show site candidates (a farmer's field, no live job, no vine or orchard; a showground %d x %d m and %d-%d plots of %d m, one field before a pair), best first:",
        R.showgroundLength, R.showgroundWidth, R.minPlots, R.maxPlots, R.plotSize))
    for i = 1, math.min(#ranked, TheContractorShowSite.TOP_CANDIDATES) do
        table.insert(lines, TheContractorShowSite.describeCandidate(ranked[i]))
    end
    local qualifying = 0
    for _, candidate in ipairs(ranked) do
        if #candidate.problems == 0 then
            qualifying = qualifying + 1
        end
    end
    table.insert(lines, string.format("%d of %d candidates can hold the show (%d fields tried), checked in %.0f ms.",
        qualifying, #ranked, fieldCount, (getTimeSec() - started) * 1000))
    return table.concat(lines, "\n")
end

function TheContractorShowSite:describe()
    local site = self.site
    if site == nil then
        return "There's no show site. 'tcDebug showSite <fieldId> [fieldId]' plans one."
    end
    local plan = site.plan
    local lines = {
        string.format("Show site (%s): showground on field %d, %d plot(s) on field %d, %s.", plan.mode,
            plan.showFieldId, #plan.plots, plan.ploughFieldId, site.dressed and "dressed" or "not dressed"),
        string.format("  Showground %.0f x %.0f m; ploughing ground %.0f x %.0f m; entrance %s.",
            plan.showRect.halfU * 2, plan.showRect.halfV * 2, plan.ploughRect.halfU * 2, plan.ploughRect.halfV * 2,
            plan.entrance ~= nil and string.format("at %.0f, %.0f", plan.entrance.x, plan.entrance.z) or "none"),
    }
    for i, plot in ipairs(plan.plots) do
        table.insert(lines, string.format("  plot %d at %.0f, %.0f", i, plot.cx, plot.cz))
    end
    return table.concat(lines, "\n")
end

-- tcDebug showSite <fieldId> [fieldId]: plans and draws one. Returns the text.
function TheContractorShowSite:consolePlan(fieldId, ploughFieldId)
    if self.site ~= nil and self.site.dressed then
        return "The show site's dressed: 'tcDebug showSite restore' first."
    end
    local candidate, reason = self:planOn(fieldId, ploughFieldId)
    if candidate == nil then
        return reason
    end
    candidate = TCShowSite.rankCandidates({ candidate })[1]
    if candidate.plan == nil then
        return "No show site fits:\n" .. TheContractorShowSite.describeCandidate(candidate)
    end
    self.site = { plan = candidate.plan, dressed = false }
    self.debugVisible = true
    return table.concat({
        self:describe(),
        TheContractorShowSite.describeCandidate(candidate),
        "Showground green, ploughing ground and the dividing line yellow, plots white, the entrance a yellow post (this machine). 'tcDebug showSite dress' dresses it.",
    }, "\n")
end

-- Persistence -----------------------------------------------------------------------------------

local RECT_KEYS = { "cx", "cz", "angle", "halfU", "halfV" }

local function saveRect(xmlFile, key, rect)
    for _, name in ipairs(RECT_KEYS) do
        setXMLFloat(xmlFile, key .. "#" .. name, rect[name])
    end
end

local function loadRect(xmlFile, key)
    local rect = {}
    for _, name in ipairs(RECT_KEYS) do
        rect[name] = getXMLFloat(xmlFile, key .. "#" .. name)
        if rect[name] == nil then
            return nil
        end
    end
    return rect
end

function TheContractorShowSite:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() or self.site == nil then
        return
    end
    local key = TheContractor.SaveKey .. ".showSite"
    local site, plan = self.site, self.site.plan
    setXMLString(xmlFile, key .. "#mode", plan.mode)
    setXMLInt(xmlFile, key .. "#showFieldId", plan.showFieldId)
    setXMLInt(xmlFile, key .. "#ploughFieldId", plan.ploughFieldId)
    setXMLBool(xmlFile, key .. "#dressed", site.dressed == true)
    saveRect(xmlFile, key .. ".showRect", plan.showRect)
    saveRect(xmlFile, key .. ".ploughRect", plan.ploughRect)
    if plan.line ~= nil then
        for _, name in ipairs({ "x", "z", "nx", "nz" }) do
            setXMLFloat(xmlFile, key .. ".line#" .. name, plan.line[name])
        end
    end
    if plan.entrance ~= nil then
        setXMLFloat(xmlFile, key .. ".entrance#x", plan.entrance.x)
        setXMLFloat(xmlFile, key .. ".entrance#z", plan.entrance.z)
        setXMLFloat(xmlFile, key .. ".entrance#distance", plan.entrance.distance or 0)
    end
    for i, plot in ipairs(plan.plots) do
        local plotKey = string.format("%s.plot(%d)", key, i - 1)
        for _, name in ipairs({ "cx", "cz", "angle", "half" }) do
            setXMLFloat(xmlFile, plotKey .. "#" .. name, plot[name])
        end
    end
    local index = 0
    for fieldId, snapshot in pairs(site.snapshots or {}) do
        local snapshotKey = string.format("%s.snapshot(%d)", key, index)
        setXMLInt(xmlFile, snapshotKey .. "#fieldId", fieldId)
        TCFieldPreparation.saveSnapshot(xmlFile, snapshotKey, snapshot)
        index = index + 1
    end
end

function TheContractorShowSite:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".showSite"
    local mode = getXMLString(xmlFile, key .. "#mode")
    if mode == nil then
        return
    end
    local plan = {
        mode = mode,
        showFieldId = getXMLInt(xmlFile, key .. "#showFieldId"),
        ploughFieldId = getXMLInt(xmlFile, key .. "#ploughFieldId"),
        showRect = loadRect(xmlFile, key .. ".showRect"),
        ploughRect = loadRect(xmlFile, key .. ".ploughRect"),
        plots = {},
    }
    if hasXMLProperty(xmlFile, key .. ".line") then
        plan.line = {}
        for _, name in ipairs({ "x", "z", "nx", "nz" }) do
            plan.line[name] = getXMLFloat(xmlFile, key .. ".line#" .. name) or 0
        end
    end
    local entranceX = getXMLFloat(xmlFile, key .. ".entrance#x")
    if entranceX ~= nil then
        plan.entrance = { x = entranceX, z = getXMLFloat(xmlFile, key .. ".entrance#z"),
            distance = getXMLFloat(xmlFile, key .. ".entrance#distance") or 0 }
    end
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.plot(%d)", key, i)) do
        local plotKey = string.format("%s.plot(%d)", key, i)
        local plot = {}
        for _, name in ipairs({ "cx", "cz", "angle", "half" }) do
            plot[name] = getXMLFloat(xmlFile, plotKey .. "#" .. name) or 0
        end
        table.insert(plan.plots, plot)
        i = i + 1
    end
    local snapshots = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.snapshot(%d)", key, i)) do
        local snapshotKey = string.format("%s.snapshot(%d)", key, i)
        local fieldId = getXMLInt(xmlFile, snapshotKey .. "#fieldId")
        local snapshot = TCFieldPreparation.loadSnapshot(xmlFile, snapshotKey)
        if fieldId ~= nil and snapshot ~= nil then
            snapshots[fieldId] = snapshot
        end
        i = i + 1
    end
    if plan.showFieldId == nil or plan.ploughFieldId == nil or plan.showRect == nil or plan.ploughRect == nil or
            (plan.mode == TCShowSite.MODE.SINGLE and plan.line == nil) then
        TCLog.xmlWarning(xmlFile, "TheContractor: skipping the show site")
        return
    end
    self.site = { plan = plan, dressed = getXMLBool(xmlFile, key .. "#dressed") == true, snapshots = snapshots }
end

-- Nothing of ours goes to clients: the ground's the engine's to sync.
function TheContractorShowSite:writeInitialClientState(streamId, connection)
end

function TheContractorShowSite:readInitialClientState(streamId, connection)
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorShowSite.registerConsoleCommands()
    TCConsole.register("debug", "showSite", {
        args = "[fieldId [fieldId]|dress|restore|clear]",
        description = "Show site spike: the best fields (or pairs) for the show, or plan one on a field or two, dress it, put it back or drop it",
        hints = { fieldId = "a field's number (tcDebug showSite lists those that could hold the show)" },
        run = function(_, args)
            local showSite = g_currentMission.TheContractor.ShowSite
            if args[1] == nil then
                return showSite:getListText()
            end
            local action = string.lower(args[1])
            if action == "dress" or action == "restore" or action == "clear" then
                if args[2] ~= nil then
                    return false
                end
                if action == "dress" then
                    return showSite:dress()
                elseif action == "restore" then
                    return showSite:restore()
                end
                return showSite:clear()
            end
            local fieldId = tonumber(args[1])
            local ploughFieldId = args[2] ~= nil and tonumber(args[2]) or nil
            if fieldId == nil or (args[2] ~= nil and ploughFieldId == nil) or args[3] ~= nil then
                return false
            end
            return showSite:consolePlan(math.floor(fieldId), ploughFieldId ~= nil and math.floor(ploughFieldId) or nil)
        end,
    })
end
