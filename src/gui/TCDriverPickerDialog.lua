-- Staff driver picker (037): opened instead of an AutoDrive/Courseplay
-- start while the farm has a company and the vehicle has no driver yet
-- (TheContractorDrivers:gateClientStart). Lists the farm's idle workers;
-- Assign and Back sit in the dialog's button bar and act on the
-- highlighted row, so it's up/down plus accept on a gamepad. Assign sends
-- TCAssignDriverEvent, then runs the start that was held back. Same
-- MessageDialog shape as TCAdvertisingDialog.

TCDriverPickerDialog = {}
local TCDriverPickerDialog_mt = Class(TCDriverPickerDialog, MessageDialog)

function TCDriverPickerDialog.register()
    local dialog = TCDriverPickerDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCDriverPickerDialog.xml", "TCDriverPickerDialog", dialog)
    TCDriverPickerDialog.INSTANCE = dialog
end

-- vehicle is the root vehicle; onPicked() runs the held-back start once the
-- assign request is on its way. With no idle staff it's refused outright.
function TCDriverPickerDialog.show(vehicle, onPicked)
    local dialog = TCDriverPickerDialog.INSTANCE
    if dialog == nil then
        return
    end

    local farmId = vehicle:getOwnerFarmId()
    local workers = g_currentMission.TheContractor.Staff:getIdleWorkers(farmId)
    if #workers == 0 then
        InfoDialog.show(g_i18n:getText("tc_drivers_noIdleStaff"))
        return
    end
    table.sort(workers, function(a, b)
        return a.name < b.name
    end)

    dialog.vehicle = vehicle
    dialog.farmId = farmId
    dialog.workers = workers
    dialog.onPicked = onPicked
    g_gui:showDialog("TCDriverPickerDialog")
end

function TCDriverPickerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCDriverPickerDialog_mt)

    self.vehicle = nil
    self.farmId = nil
    self.workers = {}
    self.onPicked = nil
    self.selectedIndex = 1

    return self
end

function TCDriverPickerDialog:onGuiSetupFinished()
    TCDriverPickerDialog:superClass().onGuiSetupFinished(self)

    self.headingText = self:getDescendantById("headingText")
    self.workerList = self:getDescendantById("workerList")
    self.workerList:setDataSource(self)
    self.workerList:setDelegate(self)
end

function TCDriverPickerDialog:onOpen()
    TCDriverPickerDialog:superClass().onOpen(self)

    local tier = TheContractorDrivers.getVehicleTier(self.vehicle)
    local tierText = tier ~= nil and g_i18n:getText("tc_drivers_picker_tier_" .. tier) or
        g_i18n:getText("tc_drivers_picker_tier_none")
    self.headingText:setText(string.format(g_i18n:getText("tc_drivers_picker_heading"), self.vehicle:getFullName(),
        tierText))

    self.selectedIndex = 1
    self.workerList:reloadData()
    self.workerList:setSelectedIndex(1)

    FocusManager:setFocus(self.workerList)
end

function TCDriverPickerDialog:onClose()
    TCDriverPickerDialog:superClass().onClose(self)

    self.vehicle = nil
    self.workers = {}
    self.onPicked = nil
end

function TCDriverPickerDialog:getNumberOfItemsInSection(list, section)
    return #self.workers
end

function TCDriverPickerDialog:populateCellForItemInSection(list, section, index, cell)
    local worker = self.workers[index]
    if worker == nil then
        return
    end

    cell:getAttribute("name"):setText(worker.name)
    cell:getAttribute("workSpeed"):setText(tostring(worker.workSpeed))
    cell:getAttribute("tier"):setText(MenuContractor.formatTierListCell(worker.tierCapability))
end

-- Side-effect free - SmoothList's reloadData re-fires it.
function TCDriverPickerDialog:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
end

function TCDriverPickerDialog:onClickOk()
    local worker = self.workers[self.selectedIndex]
    if worker == nil or self.vehicle == nil then
        return true
    end

    local vehicleId = TheContractorDrivers.getVehicleKey(self.vehicle)
    local onPicked = self.onPicked

    g_client:getServerConnection():sendEvent(TCAssignDriverEvent.new(self.farmId, worker.id, vehicleId))

    self:close()
    if onPicked ~= nil then
        onPicked()
    end
    return false
end

function TCDriverPickerDialog:onClickBack()
    self:close()
    return false
end
