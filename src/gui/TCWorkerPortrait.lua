-- People tab portrait (042): the highlighted worker's look (041), or (111) a
-- farmer's or the official's, rendered live in a vanilla Render element.
-- 112: and the Inbox's, for who an offer is from (setRender).
--
-- A Render element draws a small separate scene through its own camera
-- into a GUI box - vanilla's colour picker and licence plate preview do
-- this, and RealisticLivestock's ear tag picker is the mod precedent. Our
-- scene (workerPortrait.i3d) is a camera and a few lights around an empty
-- "character" node. The character is a HumanGraphicsComponent, the same
-- thing the wardrobe screen uses to show the player, loaded from the
-- worker's PlayerStyle and left playing its default idle animation.
--
-- Everything here is local to the machine looking at the menu - no state,
-- events or saving. The scene is loaded the first time a portrait is
-- needed and destroyed when the menu closes. Changing worker is debounced
-- (SWITCH_DELAY_MS) so scrolling through the list doesn't load every model
-- on the way past.

TCWorkerPortrait = {}
TCWorkerPortrait_mt = Class(TCWorkerPortrait)

TCWorkerPortrait.SCENE_FILENAME = "src/gui/workerPortrait.i3d"
TCWorkerPortrait.SWITCH_DELAY_MS = 150

-- Framing, applied to the scene's camera once it's loaded - tune here, not
-- in the .i3d. Head-and-shoulders on a ~1.8m model standing at the origin
-- facing the camera (+Z, confirmed in-game), turned MODEL_YAW (radians).
-- Straight on at the user's request - 20 degrees read as too angled.
TCWorkerPortrait.CAMERA_POSITION = { 0, 1.55, 1.1 }
TCWorkerPortrait.CAMERA_PITCH = math.rad(-3)
TCWorkerPortrait.MODEL_YAW = 0

-- Child indices inside the scene's root TransformGroup (see the .i3d).
TCWorkerPortrait.NODE_CHARACTER = 0
TCWorkerPortrait.NODE_CAMERA = 1

function TCWorkerPortrait.new(renderElement)
    local self = setmetatable({}, TCWorkerPortrait_mt)

    self.render = renderElement
    self.characterNode = nil
    self.graphics = nil
    -- Bumped on every load, so a load that finishes after being replaced is
    -- ignored.
    self.loadToken = 0
    self.isCharacterReady = false

    -- What's been asked for, and the key of who's shown/loading. Compared by
    -- key (the id, unless setWorker's given one): a client swaps in a fresh
    -- worker object on some updates (e.g. a hire), and that's still the
    -- same person.
    self.wantedWorker = nil
    self.wantedKey = nil
    self.shownKey = nil
    self.switchTimer = 0

    return self
end

-- The worker (or any person with a look) to show, or nil to show nothing.
-- key tells people apart, the id by default: 111's farmers count their ids
-- separately from the staff, so they pass their own.
function TCWorkerPortrait:setWorker(worker, key)
    if worker ~= nil and TCWorkerAppearance.getPlayerStyle(worker) == nil then
        worker = nil
    end

    local previousKey = self.wantedKey
    self.wantedWorker = worker
    self.wantedKey = nil
    if worker == nil then
        self:setSceneVisible(false)
        return
    end
    if key == nil then
        key = worker.id
    end
    self.wantedKey = key

    self:ensureScene()
    if key == self.shownKey then
        self:setSceneVisible(self.isCharacterReady)
    elseif previousKey ~= key then
        -- Only a new pick restarts the delay - setWorker also runs on every
        -- menu refresh.
        self.switchTimer = TCWorkerPortrait.SWITCH_DELAY_MS
    end
end

-- 112: the Render box to draw in. The menu has one portrait and a box on
-- each tab that shows one (People, Inbox), so moving it frees the old box's
-- scene first: only one scene may be in the world at a time.
function TCWorkerPortrait:setRender(renderElement)
    if renderElement == self.render then
        return
    end
    self:deleteCharacter()
    self.shownKey = nil
    self.characterNode = nil
    if self.render.scene ~= nil or self.render.loadingRequestId ~= nil then
        self.render:destroyScene()
    end
    self.render = renderElement
end

-- The shown worker's look changed (066): load it again on the next update.
function TCWorkerPortrait:reload()
    self:deleteCharacter()
    self.shownKey = nil
    self.switchTimer = 0
    self:setSceneVisible(false)
end

-- Menu closed: frees the character and the scene.
function TCWorkerPortrait:destroy()
    self:deleteCharacter()
    self.shownKey = nil
    self.wantedWorker = nil
    self.wantedKey = nil
    self.characterNode = nil
    if self.render.scene ~= nil or self.render.loadingRequestId ~= nil then
        self.render:destroyScene()
    end
end

function TCWorkerPortrait:update(dt)
    if self.wantedWorker == nil then
        return
    end

    if self.characterNode == nil then
        if self.render.overlay == nil then
            return
        end
        self:setupScene()
    end

    if self.wantedKey ~= self.shownKey then
        self.switchTimer = self.switchTimer - dt
        if self.switchTimer <= 0 then
            self:loadCharacter(self.wantedWorker, self.wantedKey)
        end
    end

    if self.graphics ~= nil and self.isCharacterReady then
        self.graphics:defaultAllParameters()
        self.graphics:update(dt)
        self.render:setRenderDirty()
    end
end

-- Scene ------------------------------------------------------------------------

function TCWorkerPortrait:ensureScene()
    if self.render.scene == nil and self.render.loadingRequestId == nil then
        self.render:setScene(TheContractor.dir .. TCWorkerPortrait.SCENE_FILENAME)
    end
end

-- Once the Render element has loaded the scene and made its overlay.
function TCWorkerPortrait:setupScene()
    local root = getChildAt(self.render.scene, 0)
    self.characterNode = getChildAt(root, TCWorkerPortrait.NODE_CHARACTER)

    local camera = getChildAt(root, TCWorkerPortrait.NODE_CAMERA)
    local x, y, z = unpack(TCWorkerPortrait.CAMERA_POSITION)
    setTranslation(camera, x, y, z)
    setRotation(camera, TCWorkerPortrait.CAMERA_PITCH, 0, 0)

    self:setSceneVisible(false)
end

-- RenderElement:setVisible also shows/hides its scene - which sits in the
-- world - so it's only shown while there's a character to draw.
function TCWorkerPortrait:setSceneVisible(isVisible)
    if self.render.scene ~= nil then
        self.render:setVisible(isVisible)
    end
end

-- Character -------------------------------------------------------------------

function TCWorkerPortrait:loadCharacter(worker, key)
    self:deleteCharacter()
    self.shownKey = key
    self:setSceneVisible(false)

    local style = TCWorkerAppearance.getPlayerStyle(worker)
    if style == nil then
        return
    end

    local graphics = HumanGraphicsComponent.new()
    graphics:setSoundsEnabled(false)
    graphics:initialize()
    link(self.characterNode, graphics.graphicsRootNode)
    setTranslation(graphics.graphicsRootNode, 0, 0, 0)
    graphics:setModelYaw(TCWorkerPortrait.MODEL_YAW)
    self.graphics = graphics

    self.loadToken = self.loadToken + 1
    local token = self.loadToken
    graphics:setStyleAsync(style, function(_, loadingState)
        if token ~= self.loadToken or self.graphics ~= graphics then
            return
        end
        if loadingState == HumanModelLoadingState.OK then
            self.isCharacterReady = true
            graphics:defaultAllParameters()
            self:setSceneVisible(self.wantedWorker ~= nil and self.wantedKey == key)
            self.render:setRenderDirty()
        else
            TCLog.warning("TheContractor: couldn't load the portrait for %s (%s)", tostring(key), worker.name)
        end
    end, nil, nil, true)
end

function TCWorkerPortrait:deleteCharacter()
    self.loadToken = self.loadToken + 1
    self.isCharacterReady = false
    if self.graphics ~= nil then
        self.graphics:delete()
        self.graphics = nil
    end
end
