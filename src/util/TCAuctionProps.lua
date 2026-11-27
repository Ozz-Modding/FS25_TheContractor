-- Auction site dressing (140): the engine half. Loads the props
-- TCAuctionScene lays out from the site's synced scene (AuctionSite:
-- getScene) and takes them away when the site goes: the car park, the food
-- van, picnic benches, bins, toilets, the sale office, bunting, straw
-- bales, the site signs and the chalkboards. Plus the crowd's murmur (a
-- local sound) while people are about.
--
-- Plain models, never placeables or vehicles (nothing saved, sold or in
-- the construction menu), loaded with vanilla's shared i3d loads, one at
-- a time asynchronously so a site going up doesn't stall a frame. Built on
-- every machine with a client, and on the server (a dedicated one too) for
-- the props with collision (MODELS' collision), as 136's signs: the server
-- runs vehicles' physics, so without them there nothing would stop a
-- vehicle driving through a car. Bunting and bales have none.
--
-- The vanilla models (traffic cars, a park bin, a square bale) are the base game's own, read from $data; ours come from
-- dev/tools (dev/docs/auction-site-props.md). Anything here is the user's to
-- swap.

TCAuctionProps = {}

-- Ours, relative to the mod; vanilla's from $data. originX/originZ: where the
-- footprint's middle is in the model's own frame (the model is set so that
-- point lands on the prop's spot). yawOffset turns the model against the
-- way the prop faces. collision: loaded on a server too, and added to
-- physics.
TCAuctionProps.MODELS = {
    -- Side on to its footprint, its hatch to the front: set 1.6 m forward
    -- of the footprint's middle, so its counter meets the queue.
    foodVan = { filename = "i3d/auctionFoodVan.i3d", isMod = true, originZ = -1.6, collision = true },
    bench = { filename = "i3d/auctionPicnicBench.i3d", isMod = true, collision = true },
    bin = { filename = "$data/maps/mapEU/textures/props/parkTrashCan.i3d", collision = true },
    toilet = { filename = "i3d/auctionToilet.i3d", isMod = true, collision = true },
    office = { filename = "i3d/auctionGazebo.i3d", isMod = true, collision = true },
    bunting = { filename = "i3d/auctionBunting.i3d", isMod = true },
    -- Its length (1.2 m) runs along its own z: turned so it's across, as
    -- the layout has it. Its root is its middle.
    bale = { filename = "$data/objects/bales/squarebales/squarebale120/squarebale120.i3d", yawOffset = math.pi / 2,
        heightOffset = 0.175, stackHeight = 0.35 },
    sign = { filename = "i3d/auctionSiteSign.i3d", isMod = true, collision = true },
    gateSign = { filename = "i3d/auctionGateSign.i3d", isMod = true, collision = true },
    board = { filename = "i3d/auctionBoard.i3d", isMod = true, collision = true },
    -- 165: the show's arena (TCShowScene). childName: only that node of the
    -- file is used (found by name anywhere below its root), the rest
    -- thrown away: a cone's look without its loose body. The user's to
    -- swap:
    --   hurdle: ours (182, genShowPropsI3d.py), a galvanised hurdle 3 m
    --     along its own z (TCShowScene.PANEL), its origin at its middle,
    --     standing on its own feet: neighbours meet upright to upright;
    --   cone: the US traffic cone's look (no collision: it'd be knocked
    --     about as a loose body);
    --   stand: our own sale office gazebo, as a trade stand.
    hurdle = { filename = "i3d/showHurdle.i3d", isMod = true, collision = true },
    cone = { filename = "$data/maps/mapUS/textures/props/trafficCone.i3d", childName = "visual_lod" },
    stand = { filename = "i3d/auctionGazebo.i3d", isMod = true, collision = true },
    showGateSign = { filename = "i3d/showGateSign.i3d", isMod = true, collision = true },
    -- 169: the ploughing plots' pegs (TCShowScene.layOutPlots). Base game
    -- stand-ins, the user's to swap: the traffic cone's look at the corners
    -- (a wooden stake with a flag wanted), and the US signpost (with its
    -- collision) for the start peg (a peg with a number board wanted).
    plotPeg = { filename = "$data/maps/mapUS/textures/props/trafficCone.i3d", childName = "visual_lod" },
    plotStartPeg = { filename = "$data/maps/mapUS/textures/props/signPost01.i3d", collision = true },
    -- 171: a stall's table at its gazebo's front (TCShowScene's stalls).
    -- The base game's wooden table (mapEU), the user's to swap.
    standTable = { filename = "$data/maps/mapEU/textures/props/woodenTable.i3d", collision = true },
}
-- The bale's straw (vanilla's straw bale texture, as Bale's STRAW fill type).
TCAuctionProps.BALE_STRAW = "$data/objects/bales/squarebales/squarebale120/fillTypes/straw_diffuse.dds"

-- The site sign's faces (genAuctionSiteSignI3d.py): visuals (0) > faces (2)
-- > one per FACES entry, in this order; visuals > digits (3) > six slots
-- (0-5) of the digits 0-9, and the dash (6).
TCAuctionProps.SIGN_FACES = { "hours", "food", "parking", "toilets", "lots" }

-- The crowd's murmur: vanilla's farmers' market (mapUS), a loop at each of
-- the scene's sound spots, as loud as the share of the crowd that's there.
TCAuctionProps.SOUND = {
    filename = "$data/sounds/placeables/productions/farmersMarketIndoor.ogg",
    radius = 80,
    innerRadius = 20,
    volume = 1.5,
    height = 1.6,
}

-- Live state (this machine only): the scene's seed the props are for, and
-- each prop { prop, node, requestId }.
TCAuctionProps.active = nil
-- Cars' XMLs, read once a session: { filename, colours = { { r, g, b } },
-- colourNodes = { "2|0", ... } } or false.
TCAuctionProps.carData = {}

-- Engine helpers -------------------------------------------------------------------------

local function getFilename(model)
    if model.isMod then
        return Utils.getFilename(model.filename, TheContractor.dir)
    end
    return Utils.getFilename(model.filename, nil)
end

-- A node by an index path below it ("2|0": child 2, then its child 0).
local function nodeAt(root, path)
    local node = root
    for index in string.gmatch(path, "%d+") do
        local i = tonumber(index)
        if node == nil or i >= getNumOfChildren(node) then
            return nil
        end
        node = getChildAt(node, i)
    end
    return node
end

-- Every node below root, depth first.
local function eachNode(root, func)
    func(root)
    for i = getNumOfChildren(root) - 1, 0, -1 do
        eachNode(getChildAt(root, i), func)
    end
end

-- A car's XML (legacy XML API), once a session.
function TCAuctionProps.getCarData(model)
    local cached = TCAuctionProps.carData[model.xml]
    if cached ~= nil then
        return cached or nil
    end
    local filename = Utils.getFilename(model.xml, nil)
    local xmlFile = fileExists(filename) and loadXMLFile("tcAuctionCar", filename) or nil
    if xmlFile == nil or xmlFile == 0 then
        TCLog.warning("TheContractor: auction car '%s' not found", filename)
        TCAuctionProps.carData[model.xml] = false
        return nil
    end
    local data = {
        filename = getXMLString(xmlFile, "vehicle.assets#filenameParked") or getXMLString(xmlFile, "vehicle.assets#filename"),
        colours = {},
        colourNodes = {},
    }
    local i = 0
    while true do
        local rgb = getXMLString(xmlFile, string.format("vehicle.assets.colors.availableColors.color(%d)#rgb", i))
        if rgb == nil then
            break
        end
        local r, g, b = string.match(rgb, "([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
        if r ~= nil then
            table.insert(data.colours, { tonumber(r), tonumber(g), tonumber(b) })
        end
        i = i + 1
    end
    i = 0
    while true do
        local path = getXMLString(xmlFile, string.format("vehicle.assets.colors.colorNodes.colorNode(%d)#node", i))
        if path == nil then
            break
        end
        table.insert(data.colourNodes, path)
        i = i + 1
    end
    delete(xmlFile)
    if data.filename == nil then
        TCAuctionProps.carData[model.xml] = false
        return nil
    end
    TCAuctionProps.carData[model.xml] = data
    return data
end

-- Paints a car's body: on each paint node, the material slots that are
-- the body paint (vanilla names it "<car>_metalPainted_mat"; the trim's
-- "...PaintedBlack" and the like are left). Returns how many were painted.
local function paintCar(component, data, colour)
    local painted = 0
    for _, path in ipairs(data.colourNodes) do
        local node = nodeAt(component, path)
        if node ~= nil and getHasClassId(node, ClassIds.SHAPE) then
            for m = 0, getNumOfMaterials(node) - 1 do
                local slot = getMaterialSlotName(node, m)
                if slot ~= nil and string.find(string.lower(slot), "_metalpainted_mat$") ~= nil and
                        getHasShaderParameter(node, "colorScale", m) then
                    setShaderParameter(node, "colorScale", colour[1], colour[2], colour[3], 0, false, m)
                    painted = painted + 1
                end
            end
        end
    end
    return painted
end

-- Readies a loaded model for its prop (its node is the i3d's first child).
local function setUp(node, prop, data)
    local kind = prop.kind
    if kind == "car" then
        -- Parked and empty: no driver, and its real lights (the light
        -- sources) off. The lamps' own meshes (staticLights, beside them in
        -- lights) stay: they're what's behind the clear lenses, and without
        -- them you see through the car. They only glow when lit.
        for i = getNumOfChildren(node) - 1, 0, -1 do
            local child = getChildAt(node, i)
            local name = getName(child)
            if name == "driver" then
                setVisibility(child, false)
            end
        end
        -- The lamps' meshes are lit by their shader's lightIds0, as vanilla's
        -- traffic switches them (TrafficSystem); the models come with it on,
        -- so the indicators blink as if the alarm's going. All off.
        eachNode(node, function(child)
            if getName(child) == "realLights" then
                setVisibility(child, false)
            elseif getHasClassId(child, ClassIds.SHAPE) and getHasShaderParameter(child, "lightIds0") then
                setShaderParameter(child, "lightIds0", 0, 0, 0, 0, false)
            end
        end)
        if data ~= nil and #data.colours > 0 then
            local colour = data.colours[math.floor((prop.colour or 0) * #data.colours) % #data.colours + 1]
            local painted = paintCar(node, data, colour)
            if painted == 0 and not TCAuctionProps.reportedPaint then
                TCAuctionProps.reportedPaint = true
                TCLog.info("TheContractor: auction car %s: no paint slot found to colour", getName(node))
            end
        end
    elseif kind == "board" then
        -- visuals (0) > one board per BOARDS entry: the prop's shown.
        local visuals = getChildAt(node, 0)
        for i = 0, getNumOfChildren(visuals) - 1 do
            setVisibility(getChildAt(visuals, i), i == (prop.board or 1) - 1)
        end
    elseif kind == "sign" then
        TCAuctionProps.setSignFace(node, prop)
    end
end

-- The site sign's face, and for a row's sign its lots' numbers.
function TCAuctionProps.setSignFace(node, prop)
    local visuals = getChildAt(node, 0)
    local faces = getChildAt(visuals, 2)
    for i, face in ipairs(TCAuctionProps.SIGN_FACES) do
        if i - 1 < getNumOfChildren(faces) then
            setVisibility(getChildAt(faces, i - 1), face == prop.face)
        end
    end
    local digits = getChildAt(visuals, 3)
    local text = prop.face == "lots" and TCAuctionProps.getLotsText(prop.lotFrom, prop.lotTo) or ""
    local layout = TCAuctionProps.layOutGlyphs(text, TCAuctionProps.GLYPH_WIDTH, TCAuctionProps.DASH_WIDTH)
    -- Six digit slots (each ten shapes, 0-9) and a dash.
    local slot = 0
    local dash = getChildAt(digits, 6)
    setVisibility(dash, false)
    for _, glyph in ipairs(layout) do
        if glyph.char == "-" then
            setVisibility(dash, true)
            setTranslation(dash, glyph.x, 0, 0)
        elseif slot < 6 then
            local slotNode = getChildAt(digits, slot)
            setVisibility(slotNode, true)
            setTranslation(slotNode, glyph.x, 0, 0)
            local digit = tonumber(glyph.char)
            for d = 0, 9 do
                setVisibility(getChildAt(slotNode, d), d == digit)
            end
            slot = slot + 1
        end
    end
    for s = slot, 5 do
        setVisibility(getChildAt(digits, s), false)
    end
end

-- The glyphs' widths on the sign (metres; genAuctionSiteSignI3d.py's
-- DIGIT_WIDTH and DASH_WIDTH, the digits all one width).
TCAuctionProps.GLYPH_WIDTH = 0.1
TCAuctionProps.DASH_WIDTH = 0.1

-- "12-24", or "7" for a row of one lot (pure).
function TCAuctionProps.getLotsText(lotFrom, lotTo)
    if lotFrom == nil then
        return ""
    end
    if lotTo == nil or lotTo == lotFrom then
        return tostring(lotFrom)
    end
    return string.format("%d-%d", lotFrom, lotTo)
end

-- Each glyph's middle across the sign, the line centred on 0 (pure).
-- Returns { { char, x } }.
function TCAuctionProps.layOutGlyphs(text, glyphWidth, dashWidth)
    local widths, total = {}, 0
    for i = 1, #text do
        local char = string.sub(text, i, i)
        widths[i] = char == "-" and dashWidth or glyphWidth
        total = total + widths[i]
    end
    local glyphs = {}
    local x = -total * 0.5
    for i = 1, #text do
        table.insert(glyphs, { char = string.sub(text, i, i), x = x + widths[i] * 0.5 })
        x = x + widths[i]
    end
    return glyphs
end

-- The ground under a prop: the lowest under its footprint's corners and
-- middle, so nothing floats on a slope.
local function getBaseHeight(prop)
    local lowest = getTerrainHeightAtWorldPos(g_terrainNode, prop.x, 0, prop.z)
    for _, corner in ipairs(TCAuctionLayout.getFootprintCorners(prop.x, prop.z, prop.yaw, prop.width, prop.length)) do
        lowest = math.min(lowest, getTerrainHeightAtWorldPos(g_terrainNode, corner.x, 0, corner.z))
    end
    return lowest
end

-- Puts a loaded model on its prop's spot.
local function place(node, prop, model)
    local yaw = prop.yaw + (model.yawOffset or 0)
    local fx, fz = math.sin(yaw), math.cos(yaw)
    local rx, rz = fz, -fx
    local ox, oz = model.originX or 0, model.originZ or 0
    local x = prop.x - rx * ox - fx * oz
    local z = prop.z - rz * ox - fz * oz
    if prop.kind == "car" then
        -- Its root is the rear axle: back from the middle by its forward.
        local car = TCAuctionScene.CAR_MODELS[prop.model]
        local forward = car ~= nil and car.forward or 0
        x, z = prop.x - fx * forward, prop.z - fz * forward
        -- Sat on the slope: its nose and tail on the ground.
        local half = car ~= nil and car.length * 0.5 or 2
        local frontY = getTerrainHeightAtWorldPos(g_terrainNode, prop.x + fx * half, 0, prop.z + fz * half)
        local backY = getTerrainHeightAtWorldPos(g_terrainNode, prop.x - fx * half, 0, prop.z - fz * half)
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
        setTranslation(node, x, y, z)
        local dy = (frontY - backY) / (half * 2)
        setDirection(node, fx, dy, fz, 0, 1, 0)
        return
    end
    -- A stacked prop (the bales) sits its level's height up.
    local stacked = (prop.level or 0) * (model.stackHeight or 0)
    setTranslation(node, x, getBaseHeight(prop) + (model.heightOffset or 0) + stacked, z)
    setRotation(node, 0, yaw, 0)
end

-- Loading -----------------------------------------------------------------------------------

-- Whether this machine loads a prop: with a client, everything; a server
-- without one, only what has collision.
local function isWanted(prop)
    if g_dedicatedServer == nil and g_currentMission:getIsClient() then
        return true
    end
    if prop.kind == "car" then
        return true
    end
    local model = TCAuctionProps.MODELS[prop.kind]
    return model ~= nil and model.collision == true
end

-- The prop's file and model entry, or nil.
local function resolve(prop)
    if prop.kind == "car" then
        local car = TCAuctionScene.CAR_MODELS[prop.model]
        local data = car ~= nil and TCAuctionProps.getCarData(car) or nil
        if data == nil then
            return nil
        end
        return Utils.getFilename(data.filename, nil), { collision = true }, data
    end
    local model = TCAuctionProps.MODELS[prop.kind]
    if model == nil then
        return nil
    end
    return getFilename(model), model, nil
end

function TCAuctionProps.onModelLoaded(_, root, failedReason, args)
    local active, entry = TCAuctionProps.active, args.entry
    local stale = active == nil or active.generation ~= args.generation
    if root == nil or root == 0 then
        if not stale then
            TCLog.warning("TheContractor: auction prop '%s' could not be loaded", tostring(args.filename))
            active.loading = nil
        end
        return
    end
    if stale then
        delete(root)
        if entry.requestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(entry.requestId)
        end
        return
    end
    active.loading = nil
    local prop, model = entry.prop, args.model
    local node = nil
    if model.childName ~= nil then
        node = TCAuctionProps.findNode(root, model.childName)
        if node == nil then
            TCLog.warning("TheContractor: auction prop '%s' has no node '%s'", tostring(args.filename),
                model.childName)
            delete(root)
            return
        end
    else
        node = getChildAt(root, 0)
    end
    link(getRootNode(), node)
    delete(root)
    if prop.kind == "bale" then
        node = TCAuctionProps.takeBaleVisual(node)
    end
    if node ~= nil then
        setUp(node, prop, args.data)
        place(node, prop, model)
        if model.collision then
            addToPhysics(node)
        end
        entry.node = node
    end
end

-- 165: the first node named name below root (depth first), or nil.
function TCAuctionProps.findNode(root, name)
    local found = nil
    eachNode(root, function(node)
        if found == nil and node ~= root and getName(node) == name then
            found = node
        end
    end)
    return found
end

-- A bale's look without its body: the visual, out from under the dynamic
-- rigid body (deleted), in straw. Returns the visual's new holder.
function TCAuctionProps.takeBaleVisual(body)
    local visual = nil
    for i = 0, getNumOfChildren(body) - 1 do
        local child = getChildAt(body, i)
        if string.find(getName(child), "_vis", 1, true) ~= nil then
            visual = child
        end
    end
    if visual == nil then
        delete(body)
        return nil
    end
    local holder = createTransformGroup("tcAuctionBale")
    link(getRootNode(), holder)
    link(holder, visual)
    setTranslation(visual, 0, 0, 0)
    setRotation(visual, 0, 0, 0)
    delete(body)
    local material = getMaterial(visual, 0)
    if material ~= nil and material ~= 0 then
        local straw = Utils.getFilename(TCAuctionProps.BALE_STRAW, nil)
        local strawMaterial = setMaterialDiffuseMapFromFile(material, straw, true, true, false)
        if strawMaterial ~= nil and strawMaterial ~= 0 then
            setMaterial(visual, strawMaterial, 0)
        end
    end
    return holder
end

-- Starts the next prop's load, one at a time.
local function loadNext(active)
    while active.loading == nil and active.next <= #active.entries do
        local entry = active.entries[active.next]
        active.next = active.next + 1
        local filename, model, data = resolve(entry.prop)
        if filename ~= nil then
            active.loading = entry
            local args = { entry = entry, model = model, data = data, generation = active.generation,
                filename = filename }
            entry.requestId = g_i3DManager:loadSharedI3DFileAsync(filename, false, false, TCAuctionProps.onModelLoaded,
                nil, args)
            return
        end
    end
end

-- The props for a scene, replacing any. scene: nil to take them away.
function TCAuctionProps.build(scene)
    TCAuctionProps.clear()
    if scene == nil then
        return
    end
    local dressed = TCAuctionScene.layOut(scene)
    TCAuctionProps.generation = (TCAuctionProps.generation or 0) + 1
    local active = {
        seed = scene.seed,
        generation = TCAuctionProps.generation,
        entries = {},
        next = 1,
        sounds = {},
        dressed = dressed,
    }
    for _, prop in ipairs(dressed.props) do
        if isWanted(prop) then
            table.insert(active.entries, { prop = prop })
        end
    end
    TCAuctionProps.active = active
    TCAuctionProps.addSounds(active, dressed.sounds)
    TCLog.info("TheContractor: auction site dressing: %d props (%d cars) to load", #active.entries,
        dressed.carCount or 0)
    loadNext(active)
end

-- Takes every prop and sound away. A load still on its way deletes itself
-- when it lands (its generation's gone).
function TCAuctionProps.clear()
    local active = TCAuctionProps.active
    if active == nil then
        return
    end
    for _, entry in ipairs(active.entries) do
        if entry.node ~= nil then
            if entityExists(entry.node) then
                delete(entry.node)
            end
            entry.node = nil
            if entry.requestId ~= nil then
                g_i3DManager:releaseSharedI3DFile(entry.requestId)
            end
        end
    end
    for _, sound in ipairs(active.sounds) do
        if sound.isOn then
            stopSample(sound.sample, 0, 0)
        end
        if entityExists(sound.node) then
            delete(sound.node)
        end
    end
    TCAuctionProps.active = nil
end

-- Sound ----------------------------------------------------------------------------------

-- The murmur at each of the scene's sound spots (a machine with a client).
function TCAuctionProps.addSounds(active, spots)
    if g_dedicatedServer ~= nil or not g_currentMission:getIsClient() or createAudioSource == nil then
        return
    end
    local config = TCAuctionProps.SOUND
    local filename = Utils.getFilename(config.filename, nil)
    if not fileExists(filename) then
        TCLog.info("TheContractor: auction crowd sound '%s' not found", filename)
        return
    end
    for i, spot in ipairs(spots or {}) do
        local holder = createTransformGroup("tcAuctionCrowdSound")
        link(getRootNode(), holder)
        local y = getTerrainHeightAtWorldPos(g_terrainNode, spot.x, 0, spot.z) + config.height
        setTranslation(holder, spot.x, y, spot.z)
        local source = createAudioSource("tcAuctionCrowd" .. i, filename, config.radius, config.innerRadius,
            config.volume, 0)
        if source ~= nil and source ~= 0 then
            link(holder, source)
            local sample = getAudioSourceSample(source)
            if sample ~= nil and sample ~= 0 then
                setSampleGroup(sample, AudioGroup.ENVIRONMENT)
                table.insert(active.sounds, { node = holder, source = source, sample = sample, isOn = false })
            else
                delete(holder)
            end
        else
            delete(holder)
        end
    end
end

-- The murmur on (a looped sample, played and stopped) while people are
-- about, as loud as the share of them there (TCAuctionCrowd's hours; full
-- for a crowd without them).
local function updateSounds(active)
    local crowd = TCAuctionCrowd.active
    local share = crowd ~= nil and (crowd.share or 1) or 0
    local isOn = share > 0.1
    local volume = TCAuctionProps.SOUND.volume * math.min(1, share)
    for _, sound in ipairs(active.sounds) do
        if sound.isOn ~= isOn then
            sound.isOn = isOn
            if isOn then
                playSample(sound.sample, 0, volume, 0, 0, 0)
            else
                stopSample(sound.sample, 0, 0)
            end
        end
        if isOn and math.abs((sound.volume or 0) - volume) > 0.01 then
            sound.volume = volume
            setSampleVolume(sound.sample, volume)
        end
    end
end

-- Every machine, every frame: the props follow the site's scene (rebuilt
-- when its seed changes or it goes), loaded one at a time.
function TCAuctionProps.update(dt)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    local site = tc ~= nil and tc.AuctionSite or nil
    if site == nil then
        return
    end
    local scene = site:getScene()
    local active = TCAuctionProps.active
    local seed = scene ~= nil and scene.seed or nil
    local current = active ~= nil and active.seed or nil
    if seed ~= current then
        TCAuctionProps.build(scene)
        active = TCAuctionProps.active
    end
    if active ~= nil then
        loadNext(active)
        updateSounds(active)
    end
end

-- How the dressing's doing, for the console.
function TCAuctionProps.describe()
    local active = TCAuctionProps.active
    if active == nil then
        return "The auction site isn't dressed."
    end
    local loaded = 0
    for _, entry in ipairs(active.entries) do
        if entry.node ~= nil then
            loaded = loaded + 1
        end
    end
    return string.format("Auction site dressing: %d of %d props loaded, %d crowd sounds.", loaded,
        #active.entries, #active.sounds)
end

-- deleteMap.
function TCAuctionProps.reset()
    TCAuctionProps.clear()
    TCAuctionProps.carData = {}
    TCAuctionProps.reportedPaint = nil
end
