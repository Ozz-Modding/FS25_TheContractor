-- Parking slot filter dialog (086), opened from TCParkingSlotActivatable's
-- prompt. One list: the store categories on offer for the slot
-- (TCParkingSlotFilter.getCategoryChoices), then the farm's machines of
-- the slot's type, those standing in the slot first. Gamepad-first: the
-- button bar acts on the highlighted row. Toggle ticks it, Clear unticks
-- everything, Save sends TCParkingSlotFilterEvent, Back throws the changes
-- away. Same MessageDialog shape as TCDriverPickerDialog.
--
-- 100: repair zones use it too, through an adapter (show's second
-- argument): where the filter lives, what's on offer, the summary, the
-- texts and the event. SLOT_ADAPTER is the parking slot's own.
--
-- 120: standing spots use it for staff (TCStandingSpotActivatable's
-- SPOT_ADAPTER). An adapter whose filter isn't categories and machines
-- gives its own getRows, getTickedKeys and newFilter (all three, see the
-- defaults below), and can give its own headingKey and emptyKey.

TCParkingSlotDialog = {}
local TCParkingSlotDialog_mt = Class(TCParkingSlotDialog, MessageDialog)

TCParkingSlotDialog.KIND_TONE = {
    category = "info",
    vehicle = "neutral",
    staff = "neutral",
}

local CHECKBOX_ON_COLOR = { 0.30, 0.62, 0.06, 1 }
local CHECKBOX_OFF_COLOR = { 0.22, 0.22, 0.23, 1 }

function TCParkingSlotDialog.register()
    local dialog = TCParkingSlotDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCParkingSlotDialog.xml", "TCParkingSlotDialog", dialog)
    TCParkingSlotDialog.INSTANCE = dialog
end

TCParkingSlotDialog.SLOT_ADAPTER = {
    getTitle = function()
        return g_i18n:getText("tc_parkingSlot_dialogTitle")
    end,
    getHint = function(slot)
        return g_i18n:getText("tc_parkingSlot_dialogHint_" .. PlaceableTCParkingSlot.getSlotType(slot))
    end,
    getFilter = function(slot)
        return PlaceableTCParkingSlot.getFilter(slot)
    end,
    getCategoryChoices = function(slot, farmId, filter)
        return TCParkingSlotFilter.getCategoryChoices(slot, farmId, filter)
    end,
    getEligibleVehicles = function(slot, farmId)
        return TCParkingSlotFilter.getEligibleVehicles(slot, farmId)
    end,
    getArea = function(slot)
        return PlaceableTCParkingSlot.getArea(slot)
    end,
    getSummary = function(slot, filter)
        return TCParkingSlotFilter.getSummary(slot, filter)
    end,
    send = function(slot, farmId, filter)
        g_client:getServerConnection():sendEvent(TCParkingSlotFilterEvent.new(NetworkUtil.getObjectId(slot), farmId,
            filter))
    end,
}

function TCParkingSlotDialog.show(slot, adapter)
    local dialog = TCParkingSlotDialog.INSTANCE
    if dialog == nil then
        return
    end
    dialog.slot = slot
    dialog.adapter = adapter or TCParkingSlotDialog.SLOT_ADAPTER
    dialog.farmId = slot:getOwnerFarmId()
    g_gui:showDialog("TCParkingSlotDialog")
end

function TCParkingSlotDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCParkingSlotDialog_mt)

    self.slot = nil
    self.adapter = TCParkingSlotDialog.SLOT_ADAPTER
    self.farmId = nil
    -- { kind = "category"|"vehicle", key (name or object id), title,
    --   isHere }
    self.rows = {}
    -- The draft: kind -> { key -> true }.
    self.ticked = {}
    self.isChanged = false
    self.selectedIndex = 1

    return self
end

function TCParkingSlotDialog:onGuiSetupFinished()
    TCParkingSlotDialog:superClass().onGuiSetupFinished(self)

    self.titleText = self:getDescendantById("dialogTitleElement")
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

    local filter = self.adapter.getFilter(self.slot)
    self.ticked = {}
    for kind, keys in pairs((self.adapter.getTickedKeys or TCParkingSlotDialog.getTickedKeys)(filter)) do
        self.ticked[kind] = {}
        for _, key in ipairs(keys) do
            self.ticked[kind][key] = true
        end
    end
    self.isChanged = false
    self.rows = (self.adapter.getRows or TCParkingSlotDialog.getRows)(self.adapter, self.slot, self.farmId, filter)

    if self.titleText ~= nil then
        self.titleText:setText(self.adapter.getTitle())
    end
    self.hintText:setText(self.adapter.getHint(self.slot))
    self.emptyText:setText(g_i18n:getText(self.adapter.emptyKey or "tc_parkingSlot_nothingToPick"))
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

-- The default getTickedKeys: kind -> list of the filter's keys.
function TCParkingSlotDialog.getTickedKeys(filter)
    return { category = filter.categories, vehicle = filter.vehicleIds }
end

-- The default newFilter, from the draft (kind -> list of keys).
function TCParkingSlotDialog.newFilter(keys)
    return PlaceableTCParkingSlot.newFilter(keys.category, keys.vehicle)
end

-- The default getRows: categories by title, then machines, those standing
-- in the slot first, then by name. A row is { kind, key, title, isHere,
-- chipKey (optional, the kind chip's text; tc_parkingSlot_kind_<kind> if
-- not given) }.
function TCParkingSlotDialog.getRows(adapter, slot, farmId, filter)
    local rows = {}
    for _, name in ipairs(adapter.getCategoryChoices(slot, farmId, filter)) do
        table.insert(rows, { kind = "category", key = name, title = TCParkingSlotFilter.getCategoryTitle(name) })
    end

    local area = adapter.getArea(slot)
    local vehicleRows = {}
    for _, vehicle in ipairs(adapter.getEligibleVehicles(slot, farmId)) do
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
    return rows
end

function TCParkingSlotDialog:isTicked(row)
    local set = self.ticked[row.kind]
    return set ~= nil and set[row.key] == true
end

function TCParkingSlotDialog:hasTicked()
    for _, set in pairs(self.ticked) do
        if next(set) ~= nil then
            return true
        end
    end
    return false
end

function TCParkingSlotDialog:getDraftFilter()
    local keys = {}
    for kind, set in pairs(self.ticked) do
        keys[kind] = {}
        for key in pairs(set) do
            table.insert(keys[kind], key)
        end
    end
    return (self.adapter.newFilter or TCParkingSlotDialog.newFilter)(keys)
end

function TCParkingSlotDialog:refresh()
    self.headingText:setText(string.format(g_i18n:getText(self.adapter.headingKey or "tc_parkingSlot_dialogHeading"),
        self.adapter.getSummary(self.slot, self:getDraftFilter())))

    local row = self.rows[self.selectedIndex]
    self.toggleButton:setDisabled(row == nil)
    self.toggleButton:setText(g_i18n:getText(row ~= nil and self:isTicked(row) and "tc_parkingSlot_untick" or
        "tc_parkingSlot_tick"))
    self.saveButton:setDisabled(not self.isChanged)
    self.clearButton:setDisabled(not self:hasTicked())
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
    kindChipText:setText(g_i18n:getText(row.chipKey or "tc_parkingSlot_kind_" .. row.kind))

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
    self.ticked[row.kind] = self.ticked[row.kind] or {}
    local set = self.ticked[row.kind]
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
    self.ticked = {}
    self.isChanged = true
    self.choiceList:reloadData()
    self:refresh()
end

function TCParkingSlotDialog:onClickSave()
    if self.isChanged and self.slot ~= nil then
        self.adapter.send(self.slot, self.farmId, self:getDraftFilter())
    end
    self:close()
end

function TCParkingSlotDialog:onClickBack()
    self:close()
    return false
end
