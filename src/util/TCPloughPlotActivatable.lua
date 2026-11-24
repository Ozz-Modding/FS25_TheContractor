-- The ploughing match's prompt at a plot's start peg (169): one activatable,
-- registered at loadMap, built like TCAuctionLotActivatable. On foot within
-- ACTIVATE_DISTANCE of a start peg, a player of a company farm sees "Take
-- plot N" on a free plot (while the match isn't over, when their farm
-- hasn't one), or "Finish my run on plot N" on their farm's own once the
-- match has started. Taking sends TCPloughPlotEvent straight away;
-- finishing asks first. Everything it needs is the synced match and scene,
-- so it works the same on every machine.

TCPloughPlotActivatable = {}
local TCPloughPlotActivatable_mt = Class(TCPloughPlotActivatable)

-- Metres from the start peg.
TCPloughPlotActivatable.ACTIVATE_DISTANCE = 3

TCPloughPlotActivatable.ACTION = { TAKE = "take", FINISH = "finish" }
local ACTION = TCPloughPlotActivatable.ACTION

function TCPloughPlotActivatable.new()
    local self = setmetatable({}, TCPloughPlotActivatable_mt)
    self.activateText = ""
    self.number = nil
    self.action = nil
    self.distance = math.huge
    return self
end

-- Registered once per load, taken away in deleteMap.
function TCPloughPlotActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCPloughPlotActivatable.INSTANCE = TCPloughPlotActivatable.new()
    system:addActivatable(TCPloughPlotActivatable.INSTANCE)
end

function TCPloughPlotActivatable.uninstall()
    local activatable = TCPloughPlotActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCPloughPlotActivatable.INSTANCE = nil
end

-- What a farm's player can do at a plot's start peg (pure on the match's
-- getTakeProblem/getFinishProblem): ACTION.TAKE, ACTION.FINISH or nil.
function TCPloughPlotActivatable.getAction(match, number, farmId)
    if match:getTakeProblem(number, farmId) == nil then
        return ACTION.TAKE
    end
    if match:getFinishProblem(number, farmId) == nil then
        return ACTION.FINISH
    end
    return nil
end

-- The nearest start peg within reach: its plot number and distance, or nil.
function TCPloughPlotActivatable.findNearest(match, x, z)
    local best, bestDistance = nil, TCPloughPlotActivatable.ACTIVATE_DISTANCE
    for _, frame in ipairs(match:getFrames()) do
        local px, pz = TCShowScene.getStartPeg(frame)
        local distance = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
        if distance <= bestDistance then
            best, bestDistance = frame.number, distance
        end
    end
    return best, bestDistance
end

function TCPloughPlotActivatable:getIsActivatable()
    self.number, self.action, self.distance = nil, nil, math.huge
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local tc = g_currentMission.TheContractor
    local match = tc ~= nil and tc.PloughingMatch or nil
    if match == nil or not match:isOnField() then
        return false
    end
    local x, _, z = player:getPosition()
    local number, distance = TCPloughPlotActivatable.findNearest(match, x, z)
    if number == nil then
        return false
    end
    local action = TCPloughPlotActivatable.getAction(match, number, g_currentMission:getFarmId())
    if action == nil then
        return false
    end
    if action ~= self.shownAction or number ~= self.shownNumber then
        self.shownAction, self.shownNumber = action, number
        self.activateText = string.format(g_i18n:getText(action == ACTION.TAKE and "tc_ploughMatch_take" or
            "tc_ploughMatch_finish"), number)
    end
    self.number, self.action, self.distance = number, action, distance
    return true
end

function TCPloughPlotActivatable:getDistance(x, y, z)
    return self.distance
end

function TCPloughPlotActivatable:run()
    local number, action = self.number, self.action
    if number == nil or action == nil then
        return
    end
    local farmId = g_currentMission:getFarmId()
    if action == ACTION.TAKE then
        g_client:getServerConnection():sendEvent(TCPloughPlotEvent.new(TCPloughPlotEvent.TAKE, number, farmId))
        return
    end
    YesNoDialog.show(function(_, yes)
        if yes then
            g_client:getServerConnection():sendEvent(TCPloughPlotEvent.new(TCPloughPlotEvent.FINISH, number, farmId))
        end
    end, self, string.format(g_i18n:getText("tc_ploughMatch_finishConfirm"), number))
end
