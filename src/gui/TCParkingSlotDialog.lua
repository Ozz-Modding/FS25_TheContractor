-- Parking slot filter dialog (086), opened from TCParkingSlotActivatable's
-- prompt. One list: the store categories on offer for the slot
-- (TCParkingSlotFilter.getCategoryChoices), then the farm's machines of
-- the slot's type, those standing in the slot first. Gamepad-first: the
-- button bar acts on the highlighted row. Toggle ticks it, Clear unticks
-- everything, Save sends TCParkingSlotFilterEvent, Back throws the changes
-- away. Same MessageDialog shape as TCDriverPickerDialog.

TCParkingSlotDialog = {}
local TCParkingSlotDialog_mt = Class(TCParkingSlotDialog, MessageDialog)

TCParkingSlotDialog.KIND_TONE = {
    category = "info",
    vehicle = "neutral",
}

local CHECKBOX_ON_COLOR = { 0.30, 0.62, 0.06, 1 }
local CHECKBOX_OFF_COLOR = { 0.22, 0.22, 0.23, 1 }

function TCParkingSlotDialog.register()
    local dialog = TCParkingSlotDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCParkingSlotDialog.xml", "TCParkingSlotDialog", dialog)
    TCParkingSlotDialog.INSTANCE = dialog
end

function TCParkingSlotDialog.show(slot)
    local dialog = TCParkingSlotDialog.INSTANCE
    if dialog == nil then
        return
    end
    dialog.slot = slot
    dialog.farmId = slot:getOwnerFarmId()
    g_gui:showDialog("TCParkingSlotDialog")
end

function TCParkingSlotDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCParkingSlotDialog_mt)

    self.slot = nil
    self.farmId = nil
    -- { kind = "category"|"vehicle", key (name or object id), title,
    --   isHere }
    self.rows = {}
    -- The draft: category name / vehicle id -> true.
    self.categories = {}
    self.vehicleIds = {}
    self.isChanged = false
    self.selectedIndex = 1

    return self
end

function TCParkingSlotDialog:onGuiSetupFinished()
    TCParkingSlotDialog:superClass().onGuiSetupFinished(self)

    self.headingText = self:getDescendantById("headingText")
    self.hintText = self:getDescendantById("hintText")
    self.emptyText = self:getDescendantById("emptyText")
    self.choiceList = self:getDescendantById("choiceList")
    self.toggleButton = self:getDescendantById("toggleButton")
    self.saveButton = self:getDescendantById("saveButton")
    self.clearButton = self:getDescendantById("clearButton")
    self.choiceList:setDataSource(self)
    self.choiceList:setDelegate(self)
end

function TCParkingSlotDialog:onOpen()
    TCParkingSlotDialog:superClass().onOpen(self)

    local filter = PlaceableTCParkingSlot.getFilter(self.slot)
    self.categories = {}
    for _, name in ipairs(filter.categories) do
        self.categories[name] = true
    end
    self.vehicleIds = {}
    for _, vehicleId in ipairs(filter.vehicleIds) do
        self.vehicleIds[vehicleId] = true
    end
    self.isChanged = false
    self:buildRows(filter)

    self.hintText:setText(g_i18n:getText("tc_parkingSlot_dialogHint_" .. PlaceableTCParkingSlot.getSlotType(self.slot)))
    self.emptyText:setVisible(#self.rows == 0)

    self.selectedIndex = 1
    self.choiceList:reloadData()
    self.choiceList:setSelectedIndex(1)
    self:refresh()

    FocusManager:setFocus(self.choiceList)
end

function TCParkingSlotDialog:onClose()
    TCParkingSlotDialog:superClass().onClose(self)

    self.slot = nil
    self.rows = {}
end

-- Categories by title, then machines: those standing in the slot first,
-- then by name.
function TCParkingSlotDialog:buildRows(filter)
    local rows = {}
    for _, name in ipairs(TCParkingSlotFilter.getCategoryChoices(self.slot, self.farmId, filter)) do
        table.insert(rows, { kind = "category", key = name, title = TCParkingSlotFilter.getCategoryTitle(name) })
    end

    local area = PlaceableTCParkingSlot.getArea(self.slot)
    local vehicleRows = {}
    for _, vehicle in ipairs(TCParkingSlotFilter.getEligibleVehicles(self.slot, self.farmId)) do
        local vehicleId = NetworkUtil.getObjectId(vehicle)
        if vehicleId ~= nil then
            local isHere = false
            if area ~= nil and vehicle.rootNode ~= nil then
                local x, _, z = getWorldTranslation(vehicle.rootNode)
                isHere = PlaceableTCParkingSlot.isInArea(area, x, z)
            end
            table.insert(vehicleRows, { kind = "vehicle", key = vehicleId, title = vehicle:getFullName(), isHere = isHere })
        end
    end
    table.sort(vehicleRows, function(a, b)
        if a.isHere ~= b.isHere then
            return a.isHere
        end
        return a.title < b.title
    end)
    for _, row in ipairs(vehicleRows) do
        table.insert(rows, row)
    end

    self.rows = rows
end

function TCParkingSlotDialog:isTicked(row)
    if row.kind == "category" then
        return self.categories[row.key] == true
    end
    return self.vehicleIds[row.key] == true
end

function TCParkingSlotDialog:getDraftFilter()
    local categories, vehicleIds = {}, {}
    for name in pairs(self.categories) do
        table.insert(categories, name)
    end
    for vehicleId in pairs(self.vehicleIds) do
        table.insert(vehicleIds, vehicleId)
    end
    return PlaceableTCParkingSlot.newFilter(categories, vehicleIds)
end

function TCParkingSlotDialog:refresh()
    self.headingText:setText(string.format(g_i18n:getText("tc_parkingSlot_dialogHeading"),
        TCParkingSlotFilter.getSummary(self.slot, self:getDraftFilter())))

    local row = self.rows[self.selectedIndex]
    self.toggleButton:setDisabled(row == nil)
    self.toggleButton:setText(g_i18n:getText(row ~= nil and self:isTicked(row) and "tc_parkingSlot_untick" or
        "tc_parkingSlot_tick"))
    self.saveButton:setDisabled(not self.isChanged)
    self.clearButton:setDisabled(next(self.categories) == nil and next(self.vehicleIds) == nil)
end

function TCParkingSlotDialog:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function TCParkingSlotDialog:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then
        return
    end

    cell:getAttribute("checkBox").color = self:isTicked(row) and CHECKBOX_ON_COLOR or CHECKBOX_OFF_COLOR
    cell:getAttribute("name"):setText(row.title)

    local kindChip, kindChipText = cell:getAttribute("kindChip"), cell:getAttribute("kindChipText")
    kindChip.color = MenuContractor.CHIP_COLORS[TCParkingSlotDialog.KIND_TONE[row.kind]]
    kindChipText:setText(g_i18n:getText("tc_parkingSlot_kind_" .. row.kind))

    local hereChip, hereChipText = cell:getAttribute("hereChip"), cell:getAttribute("hereChipText")
    hereChip:setVisible(row.isHere == true)
    hereChipText:setVisible(row.isHere == true)
    hereChip.color = MenuContractor.CHIP_COLORS.good
end

-- Side-effect free - SmoothList's reloadData re-fires it.
function TCParkingSlotDialog:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
    if self.toggleButton ~= nil and self.slot ~= nil then
        local row = self.rows[index]
        self.toggleButton:setText(g_i18n:getText(row ~= nil and self:isTicked(row) and "tc_parkingSlot_untick" or
            "tc_parkingSlot_tick"))
    end
end

-- Toggle (the OK button, so accept on a gamepad).
function TCParkingSlotDialog:onClickOk()
    local row = self.rows[self.selectedIndex]
    if row == nil then
        return false
    end
    local set = row.kind == "category" and self.categories or self.vehicleIds
    if set[row.key] then
        set[row.key] = nil
    else
        set[row.key] = true
    end
    self.isChanged = true
    self.choiceList:reloadData()
    self:refresh()
    return false
end

function TCParkingSlotDialog:onClickClear()
    self.categories = {}
    self.vehicleIds = {}
    self.isChanged = true
    self.choiceList:reloadData()
    self:refresh()
end

function TCParkingSlotDialog:onClickSave()
    if self.isChanged and self.slot ~= nil then
        g_client:getServerConnection():sendEvent(TCParkingSlotFilterEvent.new(NetworkUtil.getObjectId(self.slot),
            self.farmId, self:getDraftFilter()))
    end
    self:close()
end

function TCParkingSlotDialog:onClickBack()
    self:close()
    return false
end
