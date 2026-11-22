-- Attach Implements Manually (FS25_attachImplementsManually, BayernGamers)
-- compatibility (177), and the only place this mod touches its globals.
--
-- With its manual attaching on, the mod leaves everything off after a hitch
-- that no player made from inside the cab: hoses, PTO and (with manual top
-- links on) the top link. It also keeps a trailer's handbrake and wheel
-- chocks as they were. Our job-site rigging (TCJobSiteSetup) hitches with
-- nobody there, so a job's implement couldn't be turned on (no PTO or
-- hydraulics) or lowered (no top link), and a trailer would drag on its
-- brake.
--
-- After each job hitch the server makes those connections the way the
-- mod's own player actions do on the server: hoses through
-- processHoseAttachRequest (every group, and the red air line's spring
-- brake), the PTO and top link through their setters plus the mod's own
-- toggle events, and the brake and chocks through the trailer's own
-- setters, which send their events. So every client follows.
--
-- After an unhitch we make ourselves (a foreign implement left in the yard,
-- equipment parked after a job), the trailer's handbrake goes on, as the
-- mod's automatic handbrake does for a player, so with its roll-away
-- setting on nothing we leave rolls off.
--
-- Everything is looked up by its function, nil-checked: a version missing
-- one just skips that connection.

TCAttachImplementsManually = {}

TCAttachImplementsManually.MOD_NAME = "FS25_attachImplementsManually"

-- The mod's environment, or nil when it isn't loaded.
local function getEnv()
    return TheContractorDrivers.getModEnv(TCAttachImplementsManually.MOD_NAME)
end

-- The attacher joint and input joint the implement is hitched by, or nil.
local function getJoints(attacher, implement)
    if attacher.getImplementIndexByObject == nil or attacher.getAttacherJointIndexFromImplementIndex == nil then
        return nil
    end
    local implementIndex = attacher:getImplementIndexByObject(implement)
    if implementIndex == nil then
        return nil
    end
    local jointDescIndex = attacher:getAttacherJointIndexFromImplementIndex(implementIndex)
    local inputJointDescIndex = implement.spec_attachable ~= nil and
        implement.spec_attachable.inputAttacherJointDescIndex or nil
    if jointDescIndex == nil or inputJointDescIndex == nil then
        return nil
    end
    return jointDescIndex, inputJointDescIndex
end

local function hasPTO(env, attacher, implement, jointDescIndex, inputJointDescIndex)
    local util = env.PowerTakeOffUtil
    if util == nil or util.getHasInputPTO == nil or util.getHasOutputPTO == nil then
        return false
    end
    return util.getHasInputPTO(implement, inputJointDescIndex) and util.getHasOutputPTO(attacher, jointDescIndex)
end

local function connectPTO(env, attacher, implement, jointDescIndex, inputJointDescIndex)
    local spec = attacher.spec_attachPowerTakeOffsManually
    local event = env.TogglePTOAttachStateEvent
    if spec == nil or spec.attachedPTOs == nil or spec.attachedPTOs[jointDescIndex] ~= nil or
        attacher.setPTOAttachState == nil or event == nil or event.sendEvent == nil or
        not hasPTO(env, attacher, implement, jointDescIndex, inputJointDescIndex) then
        return false
    end
    attacher:setPTOAttachState(implement, jointDescIndex, inputJointDescIndex, true)
    event.sendEvent(attacher, implement, jointDescIndex, inputJointDescIndex, true, false)
    return spec.attachedPTOs[jointDescIndex] ~= nil
end

-- Every hose group at once, as the player's "attach hoses" key does. It
-- refuses (false) when there's nothing to connect or it's all connected.
local function connectHoses(attacher, implement, jointDescIndex, inputJointDescIndex)
    if attacher.spec_attachConnectionHosesManually == nil or attacher.processHoseAttachRequest == nil then
        return false
    end
    local accepted = attacher:processHoseAttachRequest(implement, nil, jointDescIndex, inputJointDescIndex, true,
        false, nil)
    return accepted == true
end

local function connectTopLink(env, attacher, implement, jointDescIndex, inputJointDescIndex)
    local spec = attacher.spec_attachTopLinksManually
    local util = env.AttacherJointUtil
    local event = env.ToggleTopLinkAttachStateEvent
    if spec == nil or spec.attachedTopLinks == nil or spec.attachedTopLinks[jointDescIndex] ~= nil or
        attacher.setTopLinkAttachState == nil or util == nil or util.getHasTopLink == nil or event == nil or
        event.sendEvent == nil or
        not util.getHasTopLink(attacher, jointDescIndex, implement, inputJointDescIndex) then
        return false
    end
    attacher:setTopLinkAttachState(implement, jointDescIndex, inputJointDescIndex, true)
    event.sendEvent(attacher, implement, jointDescIndex, inputJointDescIndex, true, false)
    return spec.attachedTopLinks[jointDescIndex] ~= nil
end

-- Chocks away and the handbrake off. The handbrake goes through the
-- trailer's own request (the server's check that a spring brake has the
-- air to open, which the red line just connected gives it).
local function releaseBrakes(implement)
    local released = 0
    if implement.getAreWheelChocksPlaced ~= nil and implement.setWheelChockState ~= nil and
        implement:getAreWheelChocksPlaced() then
        implement:setWheelChockState(false, false)
        released = released + 1
    end
    if implement.getHasHandbrake ~= nil and implement.getIsHandbrakeEngaged ~= nil and
        implement.requestHandbrakeState ~= nil and implement:getHasHandbrake() and implement:getIsHandbrakeEngaged() then
        implement:requestHandbrakeState(false)
        if implement:getIsHandbrakeEngaged() then
            TCLog.warning("TheContractor: Attach Implements Manually - '%s' kept its handbrake on (no air to open it)",
                implement:getName())
        else
            released = released + 1
        end
    end
    return released
end

-- Server-only. Makes the connections Attach Implements Manually left off
-- after `attacher` hitched `implement`, as a player would by hand, and
-- releases its handbrake and chocks. Does nothing without the mod. Returns
-- how many things it connected or released.
function TCAttachImplementsManually.connectAll(attacher, implement)
    local env = getEnv()
    if env == nil or attacher == nil or implement == nil then
        return 0
    end
    local jointDescIndex, inputJointDescIndex = getJoints(attacher, implement)
    if jointDescIndex == nil then
        return 0
    end

    local done = 0
    -- Hoses first: the red air line fills the spring brake's reservoir.
    if connectHoses(attacher, implement, jointDescIndex, inputJointDescIndex) then
        done = done + 1
    end
    if connectPTO(env, attacher, implement, jointDescIndex, inputJointDescIndex) then
        done = done + 1
    end
    if connectTopLink(env, attacher, implement, jointDescIndex, inputJointDescIndex) then
        done = done + 1
    end
    done = done + releaseBrakes(implement)

    if done > 0 then
        TCLog.info("TheContractor: Attach Implements Manually - %d connected or released on '%s'", done,
            implement:getName())
    end
    return done
end

-- Server-only. After we unhitch `implement`: its handbrake goes on, so it
-- can't roll away where it's left. Does nothing without the mod, or for a
-- machine without a handbrake. Returns whether it applied it.
function TCAttachImplementsManually.onDetached(implement)
    if getEnv() == nil or implement == nil or implement.getHasHandbrake == nil or
        implement.getIsHandbrakeEngaged == nil or implement.setHandbrakeState == nil or
        not implement:getHasHandbrake() or implement:getIsHandbrakeEngaged() then
        return false
    end
    implement:setHandbrakeState(true, false)
    return true
end
