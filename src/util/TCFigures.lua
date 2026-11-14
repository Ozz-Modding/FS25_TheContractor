-- Our own people (134's crowd, split out for 151): vanilla
-- HumanGraphicsComponents we place and animate ourselves, as 065's idle
-- staff are. The auction crowd (TCAuctionCrowd) and the protest
-- (TCProtestCrowd) each lay theirs out; this file loads, culls, shows and
-- animates them.
--
-- A figure is a plain table: { kind ("stand" or "walk"), template (a look,
-- readTemplates'), x, y, z, yaw, rank (optional: there while rank < the
-- share passed to update), walker = { speed } for a walker }. Standers
-- play vanilla's NPC idle (isNPC); walkers are animated as vanilla animates
-- a remote player (PlayerGraphicsState:updateRemote: absSpeed, isWalking,
-- isGrounded), the idea from FS25_PlaceableNPCSystem by Arrow-kb (its
-- NPCGraphicsComponent drives HumanGraphicsComponent's animation from its
-- own movement).
--
-- Looks are copied from the base maps' pedestrian XMLs (SOURCE_XMLS), so no
-- style name of vanilla's is written into our code.
--
-- Models are loaded within LOAD_DISTANCE of the camera (at most
-- MAX_LOADS_PER_FRAME a frame), freed beyond UNLOAD_DISTANCE and shown
-- within CLIP_DISTANCE. Local and visual only: nothing is saved or synced,
-- and nothing happens on a dedicated server.

TCFigures = {}

-- The base maps' pedestrian XMLs, whose people's looks we copy.
TCFigures.SOURCE_XMLS = {
    "$data/maps/mapEU/config/pedestrianSystem.xml",
    "$data/maps/mapUS/config/pedestrianSystem.xml",
    "$data/maps/mapAS/config/pedestrianSystem.xml",
}

-- Metres from the camera: shown within CLIP, model loaded within LOAD,
-- freed beyond UNLOAD (TCIdleStaff's).
TCFigures.CLIP_DISTANCE = 100
TCFigures.LOAD_DISTANCE = 150
TCFigures.UNLOAD_DISTANCE = 200
-- Models started loading a frame at most: starting dozens at once stalled
-- a frame for about 90 ms (134).
TCFigures.MAX_LOADS_PER_FRAME = 2

-- Every person in the base maps' pedestrian XMLs: { variation, style,
-- walk = { animationName, blendWithAnimationName, distance, speedScaleMin,
-- speedScaleMax, triggers }, idle, staticIdles }.
function TCFigures.readTemplates()
    local templates = {}
    for _, source in ipairs(TCFigures.SOURCE_XMLS) do
        local filename = Utils.getFilename(source, nil)
        if fileExists(filename) then
            local xmlFile = XMLFile.load("tcCrowdSource", filename, PedestrianSystem.xmlSchema)
            if xmlFile ~= nil then
                for _, key in xmlFile:iterator("pedestrianSystem.pedestrians.pedestrian") do
                    local style = PlayerStyle.new()
                    if style:loadFromXMLFile(xmlFile, key .. ".style") then
                        local template = {
                            variation = xmlFile:getValue(key .. "#variation", "male"),
                            style = style,
                            idle = xmlFile:getValue(key .. ".idleAnimation#animationName"),
                            staticIdles = {},
                            walk = {
                                animationName = xmlFile:getValue(key .. ".walkAnimation#animationName"),
                                blendWithAnimationName = xmlFile:getValue(key ..
                                    ".walkAnimation#blendWithAnimationName"),
                                distance = xmlFile:getValue(key .. ".walkAnimation#distance"),
                                speedScaleMin = xmlFile:getValue(key .. ".walkAnimation#speedScaleMin"),
                                speedScaleMax = xmlFile:getValue(key .. ".walkAnimation#speedScaleMax"),
                                triggers = {},
                            },
                        }
                        for _, idleKey in xmlFile:iterator(key .. ".staticIdleAnimation") do
                            table.insert(template.staticIdles, xmlFile:getValue(idleKey .. "#animationName"))
                        end
                        for _, triggerKey in xmlFile:iterator(key .. ".walkAnimation.stepSoundTrigger") do
                            table.insert(template.walk.triggers, xmlFile:getValue(triggerKey .. "#time"))
                        end
                        if template.walk.animationName ~= nil then
                            table.insert(templates, template)
                        end
                    end
                end
                xmlFile:delete()
            end
        else
            TCLog.info("TheContractor: crowd source %s not found", filename)
        end
    end
    return templates
end

function TCFigures.groundY(x, z)
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
end

-- Whether this machine shows people at all, or why not.
function TCFigures.getUnavailableReason()
    if g_dedicatedServer ~= nil then
        return "There's no crowd on a dedicated server: nobody's there to see it."
    end
    if g_currentMission == nil or not g_currentMission:getIsClient() then
        return "This machine has no client to show a crowd."
    end
    return nil
end

-- The camera's position, or nil without one.
function TCFigures.getCameraPosition()
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    if camera == nil or camera == 0 then
        return nil
    end
    return getWorldTranslation(camera)
end

-- Frees a figure's model (hooks.onFreed first, for anything linked to it).
function TCFigures.freeModel(figure, hooks)
    if figure.graphics ~= nil then
        if hooks ~= nil and hooks.onFreed ~= nil then
            hooks.onFreed(figure)
        end
        figure.graphics:delete()
        figure.graphics = nil
    end
    figure.isReady = false
    figure.isVisible = false
end

local function setVisible(figure, isVisible, hooks)
    if figure.isVisible ~= isVisible then
        figure.isVisible = isVisible
        if isVisible then
            figure.graphics:show()
        else
            figure.graphics:hide()
        end
        if hooks ~= nil and hooks.onVisible ~= nil then
            hooks.onVisible(figure, isVisible)
        end
    end
end

-- Starts loading a figure's model: a vanilla character in its look,
-- standing (vanilla's NPC idle) or walking (as a remote player's walk).
-- hooks.onLoaded(figure) once it's ready.
function TCFigures.loadModel(figure, hooks)
    local graphics = HumanGraphicsComponent.new()
    local state = graphics.defaultState
    if figure.kind == "walk" then
        state.isNPC = false
        state.isIdling = false
        state.isWalking = true
        state.absSpeed = figure.walker.speed
        state.movementDirX = 0
        state.movementDirZ = 1
        state.isGrounded = true
        state.isCloseToGround = true
    else
        state.isNPC = true
    end
    graphics:setSoundsEnabled(false)
    graphics:initialize()
    figure.graphics = graphics
    figure.isReady = false
    figure.isVisible = false

    local style = PlayerStyle.new()
    style:copyFrom(figure.template.style)
    graphics:setStyleAsync(style, function(_, loadingState)
        if figure.graphics ~= graphics then
            return
        end
        if loadingState == HumanModelLoadingState.OK then
            -- Loading shows the model at the origin: hidden until the next
            -- update places it.
            graphics:hide()
            graphics:defaultAllParameters()
            figure.isReady = true
            if hooks ~= nil and hooks.onLoaded ~= nil then
                hooks.onLoaded(figure)
            end
        else
            figure.noModel = true
        end
    end, nil, nil, true)
end

-- One frame for a list of figures, from the camera at (cx, cy, cz). share:
-- figures with a rank at or over it aren't there (their model's freed).
-- hooks (all optional): place(figure) moves a figure before its distance is
-- checked (walkers), onLoaded, onFreed, onVisible(figure, isVisible) and
-- afterUpdate(figure, dt) once a shown figure's been animated. Returns
-- loaded, shown, present.
function TCFigures.update(figures, dt, cx, cy, cz, share, hooks)
    hooks = hooks or {}
    local loaded, shown, present, loadsStarted = 0, 0, 0, 0
    for _, figure in ipairs(figures) do
        if figure.rank ~= nil and figure.rank >= share then
            -- Not here at this hour: their model's freed until they come.
            if figure.graphics ~= nil then
                TCFigures.freeModel(figure, hooks)
            end
        else
            present = present + 1
            if hooks.place ~= nil then
                hooks.place(figure)
            end
            local distance = MathUtil.vector3Length(figure.x - cx, figure.y - cy, figure.z - cz)
            if figure.graphics == nil then
                if distance <= TCFigures.LOAD_DISTANCE and not figure.noModel and
                    loadsStarted < TCFigures.MAX_LOADS_PER_FRAME then
                    TCFigures.loadModel(figure, hooks)
                    loadsStarted = loadsStarted + 1
                end
            elseif distance > TCFigures.UNLOAD_DISTANCE then
                TCFigures.freeModel(figure, hooks)
            end

            if figure.graphics ~= nil then
                loaded = loaded + 1
            end
            if figure.isReady then
                if distance > TCFigures.CLIP_DISTANCE then
                    setVisible(figure, false, hooks)
                else
                    setVisible(figure, true, hooks)
                    shown = shown + 1
                    figure.graphics:setModelPosition(figure.x, figure.y, figure.z)
                    figure.graphics:setModelYaw(figure.yaw)
                    figure.graphics:defaultAllParameters()
                    figure.graphics:update(dt)
                    if hooks.afterUpdate ~= nil then
                        hooks.afterUpdate(figure, dt)
                    end
                end
            end
        end
    end
    return loaded, shown, present
end

-- Frees every figure's model.
function TCFigures.freeAll(figures, hooks)
    for _, figure in ipairs(figures) do
        TCFigures.freeModel(figure, hooks)
    end
end
