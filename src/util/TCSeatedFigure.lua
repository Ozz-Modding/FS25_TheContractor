-- A person sitting on a seat spot's chair (153). The base game has no
-- sitting animation: a tractor driver is posed (VehicleCharacter), and this
-- poses someone the same way without a vehicle. The HumanModel hangs from a
-- skin node, its hips are turned by VehicleCharacter.SPINE_ROTATION, its
-- arm and foot IK chains are pointed at target nodes, and the driver's
-- seated idle plays on top. The nodes come from a TCSeatTypes entry, built
-- under the seat spot's node.
--
-- It stands in for TCIdleStaff's HumanGraphicsComponent: load, show, hide,
-- update and delete. Local and visual only.

TCSeatedFigure = {}
local TCSeatedFigure_mt = Class(TCSeatedFigure)

local function makeNode(name, parent, part)
    local node = createTransformGroup(name)
    link(parent, node)
    setTranslation(node, part.pos[1], part.pos[2], part.pos[3])
    setRotation(node, math.rad(part.rot[1]), math.rad(part.rot[2]), math.rad(part.rot[3]))
    return node
end

-- linkNode: the seat spot's node (on the ground, facing +Z). Builds the
-- seat's nodes under it straight away; load() brings the person.
function TCSeatedFigure.new(linkNode, seatType)
    local self = setmetatable({}, TCSeatedFigure_mt)
    self.seatType = seatType
    self.root = makeNode("tcSeat", linkNode, seatType.seat)
    self.skin = makeNode("skin", self.root, seatType.skin)
    self.targets = {}
    for _, chain in ipairs(TCSeatTypes.CHAINS) do
        local part = seatType.targets[chain]
        self.targets[chain] = { targetNode = makeNode(chain, self.root, part), poseId = part.poseId }
    end
    self.model = nil
    self.isLoaded = false
    self.isVisible = false
    return self
end

-- Loads the person's look. callback(isLoaded) once it's ready to show, or
-- failed. Hidden until show().
function TCSeatedFigure:load(style, callback)
    local model = HumanModel.new()
    self.model = model
    model:load(style.xmlFilename, false, false, false, function(_, loadingState)
        if self.model ~= model then
            return
        end
        if loadingState ~= HumanModelLoadingState.OK or model.rootNode == nil then
            callback(false)
            return
        end
        self:pose()
        model:setVisibility(false)
        model:loadFromStyleAsync(style, function(_, styleState)
            if self.model ~= model then
                return
            end
            if styleState == HumanModelLoadingState.OK then
                self.isLoaded = true
                model:setVisibility(self.isVisible)
                self:setIKDirty()
                callback(true)
            else
                callback(false)
            end
        end, nil, nil)
    end, nil, nil)
end

-- VehicleCharacter:characterLoaded, on our own nodes.
function TCSeatedFigure:pose()
    local model = self.model
    link(self.skin, model.rootNode)
    local chains = model:getIKChains()
    for chain, target in pairs(self.targets) do
        IKUtil.setTarget(chains, chain, target)
    end

    if model.thirdPersonHipsNode ~= nil then
        local x, y, z = unpack(VehicleCharacter.SPINE_ROTATION)
        local offset = self.seatType.spineOffset
        if offset ~= nil then
            x, y, z = x + offset[1], y + offset[2], z + offset[3]
        end
        setRotation(model.thirdPersonHipsNode, x, y, z)
    end

    -- The driver's seated idle (VehicleCharacter's useIdleAnimation).
    local skeleton = model.skeleton
    if skeleton ~= nil and getNumOfChildren(skeleton) > 0 and Platform.gameplay.hasVehicleCharacterIdleAnimations then
        local animNode = g_animCache:getNode(AnimationCache.VEHICLE_CHARACTER)
        if animNode ~= nil and animNode ~= 0 then
            cloneAnimCharacterSet(getChildAt(animNode, 0), skeleton)
            local charSet = getAnimCharacterSet(skeleton)
            if charSet ~= 0 then
                clearAnimTrackClip(charSet, 0)
                assignAnimTrackClip(charSet, 0, getAnimClipIndex(charSet, "idle1Source"))
                setAnimTrackLoopState(charSet, 0, true)
                self.charSet = charSet
            end
        end
    end
end

function TCSeatedFigure:setIKDirty()
    local chains = self.model:getIKChains()
    for chain in pairs(self.targets) do
        IKUtil.setIKChainDirty(chains, chain)
    end
end

function TCSeatedFigure:show()
    self:setVisible(true)
end

function TCSeatedFigure:hide()
    self:setVisible(false)
end

function TCSeatedFigure:setVisible(isVisible)
    self.isVisible = isVisible
    if self.model ~= nil and self.isLoaded then
        self.model:setVisibility(isVisible)
        if self.charSet ~= nil then
            if isVisible then
                enableAnimTrack(self.charSet, 0)
            else
                disableAnimTrack(self.charSet, 0)
            end
        end
    end
end

-- Every frame it's shown: the idle moves the bones, so the IK is solved
-- again (VehicleCharacter:update).
function TCSeatedFigure:update(dt)
    if self.model ~= nil and self.isLoaded and self.isVisible then
        self:setIKDirty()
        IKUtil.updateIKChains(self.model:getIKChains(), true)
    end
end

function TCSeatedFigure:delete()
    local model = self.model
    self.model = nil
    self.isLoaded = false
    -- The seat spot may have gone first, taking our nodes and the model's
    -- with it: then there's nothing left to delete.
    local isStillThere = self.root ~= nil and entityExists(self.root)
    if model ~= nil then
        if model.rootNode ~= nil and not isStillThere then
            model.rootNode = nil
        end
        -- Clearing the targets deletes the offset nodes IKUtil hung under
        -- ours; then the model, whose root hangs under our skin node.
        if model.rootNode ~= nil then
            local chains = model:getIKChains()
            for chain in pairs(self.targets) do
                IKUtil.setTarget(chains, chain, nil)
            end
        end
        model:delete()
    end
    if isStillThere then
        delete(self.root)
    end
    self.root = nil
end
