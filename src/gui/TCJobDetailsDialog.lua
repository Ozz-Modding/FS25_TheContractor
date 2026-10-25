-- Job details (093): opened from the Calendar's Job details button for the
-- highlighted job. Read-only: who's on it (the player who took it on, or
-- the hired crew), its equipment, status and progress, as label/value rows
-- under section titles, the same shape as the Logbook's detail list. The
-- menu builds the rows (MenuContractor:getJobDetailRows); this re-asks for
-- them every REFRESH_MS while open, so progress and status move as the job
-- does. Same MessageDialog frame as TCDriverPickerDialog.
--
-- 094: Unallocate, while the job has a crew to take off it, asks first
-- (the menu's getUnallocateText says what it'll cost) and then sends
-- TCUnallocateJobEvent and closes.

TCJobDetailsDialog = {}
local TCJobDetailsDialog_mt = Class(TCJobDetailsDialog, MessageDialog)

TCJobDetailsDialog.REFRESH_MS = 1000

function TCJobDetailsDialog.register()
    local dialog = TCJobDetailsDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCJobDetailsDialog.xml", "TCJobDetailsDialog", dialog)
    TCJobDetailsDialog.INSTANCE = dialog
end

-- The menu's side, in `handlers`: getRows(job) returns the rows to show for
-- the job, getUnallocateText(job) the Unallocate confirm's text, and
-- onUnallocated(job) runs once the request's sent.
function TCJobDetailsDialog.show(farmId, jobId, handlers)
    local dialog = TCJobDetailsDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.farmId = farmId
    dialog.jobId = jobId
    dialog.handlers = handlers
    g_gui:showDialog("TCJobDetailsDialog")
end

function TCJobDetailsDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCJobDetailsDialog_mt)

    self.farmId = nil
    self.jobId = nil
    self.handlers = nil
    self.rows = {}
    self.refreshMs = 0

    return self
end

function TCJobDetailsDialog:onGuiSetupFinished()
    TCJobDetailsDialog:superClass().onGuiSetupFinished(self)

    self.headingText = self:getDescendantById("headingText")
    self.detailList = self:getDescendantById("detailList")
    self.detailList:setDataSource(self)
    self.detailList:setDelegate(self)
    self.buttonBox = self:getDescendantById("buttonBox")
    self.unallocateButton = self:getDescendantById("unallocateButton")
    self.unallocateSeparator = self:getDescendantById("unallocateSeparator")
end

function TCJobDetailsDialog:onOpen()
    TCJobDetailsDialog:superClass().onOpen(self)

    self.refreshMs = 0
    self:refresh()
    self.detailList:setSelectedIndex(1, true)
    FocusManager:setFocus(self.detailList)
end

function TCJobDetailsDialog:onClose()
    TCJobDetailsDialog:superClass().onClose(self)

    self.handlers = nil
    self.rows = {}
end

function TCJobDetailsDialog:update(dt)
    TCJobDetailsDialog:superClass().update(self, dt)

    self.refreshMs = self.refreshMs + dt
    if self.refreshMs >= TCJobDetailsDialog.REFRESH_MS then
        self.refreshMs = 0
        self:refresh()
    end
end

-- A job that's gone (declined, or replaced by a fresh copy from the
-- server) is looked up again by id each time, so the rows always come
-- from the current copy. If it's gone altogether, the last rows stay.
function TCJobDetailsDialog:refresh()
    local job = self:getJob()
    self:updateUnallocateButton(job)
    if job == nil or self.handlers == nil then
        return
    end

    self.headingText:setText(job:getDisplayTitle())
    self.rows = self.handlers.getRows(job)
    self.detailList:reloadData()
end

function TCJobDetailsDialog:getJob()
    local tc = g_currentMission.TheContractor
    return tc ~= nil and tc.Jobs ~= nil and tc.Jobs:getJob(self.farmId, self.jobId) or nil
end

function TCJobDetailsDialog:updateUnallocateButton(job)
    local canUnallocate = TheContractorJobs.getUnallocateProblem(job) == nil
    if self.unallocateButton:getIsVisible() ~= canUnallocate then
        self.unallocateButton:setVisible(canUnallocate)
        self.unallocateSeparator:setVisible(canUnallocate)
        self.buttonBox:invalidateLayout()
    end
end

function TCJobDetailsDialog:onClickUnallocate()
    local job = self:getJob()
    if TheContractorJobs.getUnallocateProblem(job) ~= nil then
        return false
    end

    local farmId, jobId, handlers = self.farmId, self.jobId, self.handlers
    YesNoDialog.show(function(dialog, yes)
        if yes then
            g_client:getServerConnection():sendEvent(TCUnallocateJobEvent.new(farmId, jobId))
            dialog:close()
            handlers.onUnallocated(job)
        end
    end, self, handlers.getUnallocateText(job))
    return false
end

function TCJobDetailsDialog:getNumberOfItemsInSection(list, section)
    return #self.rows
end

-- Section titles can't be selected: landing on one moves on to the next
-- row the way the selection was going (or back the other way past the
-- first or last title). Selecting the title first means scrolling up onto
-- the top one still brings it into view.
function TCJobDetailsDialog:onListSelectionChanged(list, section, index)
    local row = self.rows[index]
    if row == nil or row.section == nil then
        return
    end

    local step = list.lastScrollDirection == -1 and -1 or 1
    for _, direction in ipairs({ step, -step }) do
        local i = index + direction
        while self.rows[i] ~= nil do
            if self.rows[i].section == nil then
                list:setSelectedIndex(i)
                return
            end
            i = i + direction
        end
    end
end

function TCJobDetailsDialog:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then
        return
    end

    local isSection = row.section ~= nil
    cell:getAttribute("surface"):setVisible(not isSection)
    cell:getAttribute("section"):setVisible(isSection)
    cell:getAttribute("section"):setText(row.section or "")
    cell:getAttribute("label"):setVisible(not isSection)
    cell:getAttribute("label"):setText(row.label or "")
    -- No setter for it: TextElement reads the field as it draws.
    cell:getAttribute("label").textBold = row.isHeading == true
    cell:getAttribute("value"):setVisible(not isSection)
    cell:getAttribute("value"):setText(row.value or "")

    local chip, chipText = cell:getAttribute("chip"), cell:getAttribute("chipText")
    local hasChip = not isSection and row.chip ~= nil and row.chip ~= ""
    chip:setVisible(hasChip)
    chipText:setVisible(hasChip)
    if hasChip then
        chip.color = MenuContractor.CHIP_COLORS[row.tone] or MenuContractor.CHIP_COLORS.neutral
        chipText:setText(row.chip)
    end
end

function TCJobDetailsDialog:onClickBack()
    self:close()
    return false
end
