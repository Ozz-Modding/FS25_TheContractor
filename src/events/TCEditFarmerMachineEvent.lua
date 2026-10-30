-- Changing a farmer's machine to another model (122). Both ways: a client's
-- request (new) goes to the server, which checks and applies it
-- (TheContractorFarmerFleet.editMachine) and sends the new fleet in a
-- TCFarmerFleetEvent. The server then broadcasts how it went (newResult:
-- refused and why, or which attachment was re-picked), so the farm that
-- asked can tell its player. See src/events/README.md for the general event
-- conventions.

TCEditFarmerMachineEvent = {}
local TCEditFarmerMachineEvent_mt = Class(TCEditFarmerMachineEvent, Event)

InitEventClass(TCEditFarmerMachineEvent, "TCEditFarmerMachineEvent")

function TCEditFarmerMachineEvent.emptyNew()
    return Event.new(TCEditFarmerMachineEvent_mt)
end

function TCEditFarmerMachineEvent.new(farmId, personId, machineId, xmlFilename)
    local self = TCEditFarmerMachineEvent.emptyNew()
    self.isResult = false
    self.farmId = farmId
    self.personId = personId
    self.machineId = machineId
    self.xmlFilename = xmlFilename
    return self
end

-- problem: TheContractorFarmerFleet.EDIT_PROBLEM, or nil once applied.
-- repickedId: the attachment given a new model, or nil.
function TCEditFarmerMachineEvent.newResult(farmId, personId, machineId, problem, repickedId)
    local self = TCEditFarmerMachineEvent.emptyNew()
    self.isResult = true
    self.farmId = farmId
    self.personId = personId
    self.machineId = machineId
    self.problem = problem
    self.repickedId = repickedId
    return self
end

function TCEditFarmerMachineEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isResult)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.personId)
    streamWriteInt32(streamId, self.machineId)
    if self.isResult then
        streamWriteString(streamId, self.problem or "")
        streamWriteInt32(streamId, self.repickedId or 0)
    else
        streamWriteString(streamId, self.xmlFilename)
    end
end

function TCEditFarmerMachineEvent:readStream(streamId, connection)
    self.isResult = streamReadBool(streamId)
    self.farmId = streamReadInt32(streamId)
    self.personId = streamReadInt32(streamId)
    self.machineId = streamReadInt32(streamId)
    if self.isResult then
        local problem = streamReadString(streamId)
        self.problem = problem ~= "" and problem or nil
        local repickedId = streamReadInt32(streamId)
        self.repickedId = repickedId ~= 0 and repickedId or nil
    else
        self.xmlFilename = streamReadString(streamId)
    end
    self:run(connection)
end

function TCEditFarmerMachineEvent:run(connection)
    if self.isResult then
        if connection:getIsServer() then
            TheContractorFarmerFleet.onEditResult(self.farmId, self.personId, self.machineId, self.problem,
                self.repickedId)
        end
    elseif g_currentMission:getIsServer() then
        TheContractorFarmerFleet.editMachine(self.farmId, self.personId, self.machineId, self.xmlFilename)
    end
end
