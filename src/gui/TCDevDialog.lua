-- The dev dialog (tcDebug dev): testing tools with a screen, for things
-- that are slow to do by typing. A page picker at the top:
--
--   Jobs     every job the farm has, in a table. Change state offers the
--            states the highlighted job can go to (tcJob state), Delete
--            takes it back as if it never was (tcDebug removeJob), and New
--            job walks through making one: Auto, a real offer from the
--            generator (tcJob offer), or Select field, on a farmland you
--            pick (tcJob create).
--   Hitches  the farm's tractors and mowers. Tick a tractor and the mowers,
--            and Test hitches runs the dispatch's own planner
--            (TCHitchExplain, TCJobSiteSetup.planHitches), moving nothing,
--            and says which mower goes on the front and which on the rear;
--            the log has the why.
--
-- Everything that changes the game goes through the same console commands
-- a player would type (TCConsole.dispatch), so it runs on the server and
-- is checked there like any command: on a joined client it's sent, and
-- the answer comes back through TCConsole.resultListener. The list catches
-- up when any of our events lands (TC_DATA_UPDATED). The hitch test only
-- reads, so it runs where it's asked.
--
-- A testing tool, so its texts are plain English like tcDebug's, not l10n,
-- and it's only reachable with tcDebug's marker file. Gamepad-first like
-- the other dialogs: the button bar acts on the highlighted row, and
-- up from the list reaches the page picker.

TCDevDialog = {}
local TCDevDialog_mt = Class(TCDevDialog, MessageDialog)

TCDevDialog.PAGE_JOBS = 1
TCDevDialog.PAGE_HITCHES = 2
TCDevDialog.PAGE_TITLES = { "Jobs", "Hitches" }

local CHECKBOX_ON_COLOR = { 0.30, 0.62, 0.06, 1 }
local CHECKBOX_OFF_COLOR = { 0.22, 0.22, 0.23, 1 }

-- A new job's suggested details, for the "on a field you choose" path.
TCDevDialog.DEFAULT_PRICE = 5000
TCDevDialog.DEFAULT_DUE_DAYS = 7
TCDevDialog.DEFAULT_SKILL = 3

function TCDevDialog.register()
    local dialog = TCDevDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCDevDialog.xml", "TCDevDialog", dialog)
    TCDevDialog.INSTANCE = dialog
end

function TCDevDialog.registerConsoleCommands()
    TCConsole.register("debug", "dev", {
        description = "Open the dev dialog: the farm's jobs (change state, delete, add one) and the hitch test",
        serverOnly = false,
        run = function(farmId)
            if not TCDevDialog.show(farmId) then
                return "The dev dialog isn't loaded on this machine."
            end
            return "Opened the dev dialog. Close the console to use it."
        end,
    })
end

function TCDevDialog.show(farmId)
    local dialog = TCDevDialog.INSTANCE
    if dialog == nil or g_gui == nil then
        return false
    end
    dialog.farmId = farmId
    g_gui:showDialog("TCDevDialog")
    return true
end

function TCDevDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCDevDialog_mt)

    self.farmId = nil
    self.page = TCDevDialog.PAGE_JOBS
    self.jobs = {}
    self.selectedJobIndex = 1
    -- Hitches: rows { kind = "tractor"|"mower", vehicle }, the ticked
    -- tractor, and the ticked mowers in the order they were ticked.
    self.vehicleRows = {}
    self.selectedVehicleIndex = 1
    self.tractor = nil
    self.mowers = {}
    self.isDirty = false
    -- The New job journey's answers so far.
    self.draft = nil

    return self
end

function TCDevDialog:onGuiSetupFinished()
    TCDevDialog:superClass().onGuiSetupFinished(self)

    self.pageOption = self:getDescendantById("pageOption")
    self.hintText = self:getDescendantById("hintText")
    self.statusText = self:getDescendantById("statusText")
    self.jobsPage = self:getDescendantById("jobsPage")
    self.jobList = self:getDescendantById("jobList")
    self.jobsEmptyText = self:getDescendantById("jobsEmptyText")
    self.hitchesPage = self:getDescendantById("hitchesPage")
    self.vehicleList = self:getDescendantById("vehicleList")
    self.vehiclesEmptyText = self:getDescendantById("vehiclesEmptyText")
    self.hitchResultText = self:getDescendantById("hitchResultText")
    self.okButton = self:getDescendantById("okButton")
    self.activateButton = self:getDescendantById("activateButton")
    self.extraButton = self:getDescendantById("extraButton")

    self.jobList:setDataSource(self)
    self.jobList:setDelegate(self)
    self.vehicleList:setDataSource(self)
    self.vehicleList:setDelegate(self)
end

function TCDevDialog:onOpen()
    TCDevDialog:superClass().onOpen(self)

    self.farmId = self.farmId or g_currentMission:getFarmId()
    self.pageOption:setTexts(TCDevDialog.PAGE_TITLES)
    self.pageOption:setState(self.page)
    self.statusText:setText("")

    g_messageCenter:subscribe(MessageType.TC_DATA_UPDATED, self.onDataUpdated, self)
    TCConsole.resultListener = function(text)
        self:setStatus(text)
        self.isDirty = true
    end

    self:loadVehicles()
    self:showPage(self.page)
end

function TCDevDialog:onClose()
    TCDevDialog:superClass().onClose(self)

    g_messageCenter:unsubscribe(MessageType.TC_DATA_UPDATED, self)
    TCConsole.resultListener = nil
    self.jobs = {}
    self.vehicleRows = {}
    self.draft = nil
end

function TCDevDialog:onDataUpdated()
    self.isDirty = true
end

-- Catches up with the server's changes on the next frame, not in the
-- middle of an event's readStream.
function TCDevDialog:update(dt)
    TCDevDialog:superClass().update(self, dt)

    if self.isDirty then
        self.isDirty = false
        if self.page == TCDevDialog.PAGE_JOBS then
            self:reloadJobs()
        end
    end
end

-- Pages -----------------------------------------------------------------------------

function TCDevDialog:onClickPage(state)
    self:showPage(state)
end

function TCDevDialog:showPage(page)
    self.page = page
    local isJobs = page == TCDevDialog.PAGE_JOBS
    self.jobsPage:setVisible(isJobs)
    self.hitchesPage:setVisible(not isJobs)

    if isJobs then
        self.hintText:setText("Every job this farm has. Change state offers only the states the job can go to; " ..
            "Delete takes it back as if it never was.")
        self:reloadJobs()
        FocusManager:setFocus(#self.jobs > 0 and self.jobList or self.pageOption)
    else
        self.hintText:setText("Tick a tractor and the mowers to try, then Test hitches to see which mower the " ..
            "dispatch would put on the front and which on the rear. Nothing moves.")
        self:reloadVehicles()
        FocusManager:setFocus(#self.vehicleRows > 0 and self.vehicleList or self.pageOption)
    end
    self:updateButtons()
end

function TCDevDialog:setStatus(text)
    -- The first two lines; the console has the rest.
    local lines = {}
    for line in string.gmatch(tostring(text or ""), "[^\n]+") do
        if #lines < 2 then
            table.insert(lines, line)
        end
    end
    self.statusText:setText(table.concat(lines, " "))
end

-- Runs a console command as if it were typed here (TCConsole.dispatch):
-- at once on the server, sent there from a client (the answer arrives
-- through TCConsole.resultListener).
function TCDevDialog:runCommand(groupKey, args)
    local group = TCConsole.groups[groupKey]
    if group == nil or not TCConsole.isGroupEnabled(group) then
        self:setStatus("That console group isn't installed on this machine.")
        return
    end
    TCLog.info("TheContractor: dev dialog runs %s %s", group.command, table.concat(args, " "))
    local text = TCConsole.dispatch(group, args)
    if text ~= nil then
        self:setStatus(text)
    else
        self:setStatus("Sent to the server...")
    end
    self.isDirty = true
end

function TCDevDialog:updateButtons()
    if self.page == TCDevDialog.PAGE_JOBS then
        local job = self.jobs[self.selectedJobIndex]
        self.okButton:setText("Change state")
        self.okButton:setDisabled(job == nil)
        self.activateButton:setText("New job")
        self.activateButton:setDisabled(false)
        self.extraButton:setText("Delete")
        self.extraButton:setDisabled(job == nil)
    else
        local row = self.vehicleRows[self.selectedVehicleIndex]
        self.okButton:setText(row ~= nil and self:isTicked(row) and "Untick" or "Tick")
        self.okButton:setDisabled(row == nil)
        self.activateButton:setText("Test hitches")
        self.activateButton:setDisabled(self.tractor == nil or #self.mowers == 0)
        self.extraButton:setText("Clear")
        self.extraButton:setDisabled(self.tractor == nil and #self.mowers == 0)
    end
end

function TCDevDialog:onClickOk()
    if self.page == TCDevDialog.PAGE_JOBS then
        self:changeJobState()
    else
        self:toggleVehicle()
    end
    return false
end

function TCDevDialog:onClickActivate()
    if self.page == TCDevDialog.PAGE_JOBS then
        self:startNewJob()
    else
        self:testHitches()
    end
end

function TCDevDialog:onClickExtra1()
    if self.page == TCDevDialog.PAGE_JOBS then
        self:deleteJob()
    else
        self.tractor = nil
        self.mowers = {}
        self.hitchResultText:setText("")
        self.vehicleList:reloadData()
        self:updateButtons()
    end
end

function TCDevDialog:onClickBack()
    self:close()
    return false
end

-- Lists -----------------------------------------------------------------------------

function TCDevDialog:getNumberOfItemsInSection(list, section)
    if list == self.jobList then
        return #self.jobs
    end
    return #self.vehicleRows
end

function TCDevDialog:populateCellForItemInSection(list, section, index, cell)
    if list == self.jobList then
        self:populateJobCell(self.jobs[index], cell)
    else
        self:populateVehicleCell(self.vehicleRows[index], cell)
    end
end

-- Side-effect free - SmoothList's reloadData re-fires it.
function TCDevDialog:onListSelectionChanged(list, section, index)
    if list == self.jobList then
        self.selectedJobIndex = index
    else
        self.selectedVehicleIndex = index
    end
    if self.okButton ~= nil then
        self:updateButtons()
    end
end

-- Jobs ------------------------------------------------------------------------------

function TCDevDialog:reloadJobs()
    local selected = self.jobs[self.selectedJobIndex]
    local selectedId = selected ~= nil and selected.id or nil

    self.jobs = {}
    local tc = g_currentMission.TheContractor
    if tc ~= nil and tc.Jobs ~= nil and self.farmId ~= nil then
        for _, job in ipairs(tc.Jobs:getAllJobs(self.farmId)) do
            table.insert(self.jobs, job)
        end
    end
    table.sort(self.jobs, function(a, b)
        return a.id < b.id
    end)

    local index = 1
    for i, job in ipairs(self.jobs) do
        if job.id == selectedId then
            index = i
        end
    end
    self.selectedJobIndex = index
    self.jobsEmptyText:setVisible(#self.jobs == 0)
    self.jobList:reloadData()
    if #self.jobs > 0 then
        self.jobList:setSelectedIndex(index)
    end
    self:updateButtons()
end

function TCDevDialog:populateJobCell(job, cell)
    if job == nil then
        return
    end
    cell:getAttribute("id"):setText(tostring(job.id))
    cell:getAttribute("title"):setText(job:getDisplayTitle())
    cell:getAttribute("field"):setText(job:getListFieldText())
    cell:getAttribute("state"):setText(tostring(job.state))
    cell:getAttribute("price"):setText(g_i18n:formatMoney(job:getPrice(), 0, true, true))
    cell:getAttribute("due"):setText(job.deadlineDay ~= nil and TCCalendar.formatDayShort(job.deadlineDay) or "-")
end

-- The states a job can go to from where it is, sorted.
function TCDevDialog.getNextStates(job)
    local states = {}
    for state in pairs(TheContractorJob.VALID_TRANSITIONS[job.state] or {}) do
        table.insert(states, state)
    end
    table.sort(states)
    return states
end

function TCDevDialog:changeJobState()
    local job = self.jobs[self.selectedJobIndex]
    if job == nil then
        return
    end
    local states = TCDevDialog.getNextStates(job)
    if #states == 0 then
        self:setStatus(string.format("Job %d is %s, which is final.", job.id, job.state))
        return
    end
    local jobId = job.id
    OptionDialog.show(function(index)
        local state = states[index]
        if state ~= nil then
            self:runCommand("job", { "state", tostring(jobId), state })
        end
    end, string.format("Job %d (%s) is %s. Move it to:", jobId, job:getDisplayTitle(), job.state),
        "Change job state", states)
end

function TCDevDialog:deleteJob()
    local job = self.jobs[self.selectedJobIndex]
    if job == nil then
        return
    end
    local jobId = job.id
    YesNoDialog.show(function(_, yes)
        if yes then
            self:runCommand("debug", { "removeJob", tostring(jobId) })
        end
    end, self, string.format("Delete job %d (%s, %s)? It's taken back as if it never was; a crew on it is " ..
        "unallocated first.", jobId, job:getDisplayTitle(), job.state))
end

-- New job: type, then Auto (a real offer) or Select field (a farmland,
-- then price, due in days, skill), each step a dialog of its own.
function TCDevDialog:startNewJob()
    local types = {}
    for _, jobType in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        table.insert(types, jobType)
    end
    local repairKinds = {}
    if TheContractorRepairContracts ~= nil and TheContractorRepairContracts.CONSOLE_OFFER_KINDS ~= nil then
        for _, kind in ipairs(TheContractorRepairContracts.CONSOLE_OFFER_KINDS) do
            table.insert(types, kind)
            repairKinds[kind] = true
        end
    end

    OptionDialog.show(function(index)
        local jobType = types[index]
        if jobType == nil then
            return
        end
        if repairKinds[jobType] then
            -- A customer's machine to a repair zone bay: only ever an offer.
            self:runCommand("job", { "offer", jobType })
            return
        end
        self:chooseNewJobRoute(jobType)
    end, "What kind of job? (repair, maintenance and parts need ADS and a repair zone)", "New job", types)
end

-- Auto is a real offer (tcJob offer: the generator picks the field, price
-- and date); Select field is one on a field you pick, nothing checked
-- (tcJob create).
function TCDevDialog:chooseNewJobRoute(jobType)
    OptionDialog.show(function(index)
        if index == 1 then
            self:runCommand("job", { "offer", jobType })
        elseif index == 2 then
            self.draft = { jobType = jobType }
            self:askDraftField()
        end
    end, string.format("%s job: Auto lets the game pick the field, price and date. Select field puts it on " ..
        "the field you pick, nothing checked.", jobType), "New job", { "Auto", "Select field" })
end

-- The map's farmlands that have a field, by farmland id: { label, fieldId },
-- one per field (a farmland with more than one names each field).
function TCDevDialog.getFieldChoices()
    local entries, fieldCount = {}, {}
    for _, field in ipairs(g_fieldManager:getFields()) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        if farmland ~= nil then
            local farmlandId = farmland:getId()
            table.insert(entries, { farmlandId = farmlandId, fieldId = field:getId() })
            fieldCount[farmlandId] = (fieldCount[farmlandId] or 0) + 1
        end
    end
    table.sort(entries, function(a, b)
        if a.farmlandId ~= b.farmlandId then
            return a.farmlandId < b.farmlandId
        end
        return a.fieldId < b.fieldId
    end)
    for _, entry in ipairs(entries) do
        entry.label = string.format("Farmland %d", entry.farmlandId)
        if fieldCount[entry.farmlandId] > 1 or entry.fieldId ~= entry.farmlandId then
            entry.label = string.format("%s (field %d)", entry.label, entry.fieldId)
        end
    end
    return entries
end

-- The journey's text prompts. Each takes a number; a blank or wrong one
-- stops the journey, and Back at any step leaves it.
local function askNumber(self, prompt, default, onNumber)
    TextInputDialog.show(function(_, text, clickOk)
        if not clickOk then
            self.draft = nil
            return
        end
        local number = tonumber(text)
        if number == nil then
            self:setStatus(string.format("'%s' isn't a number, so no job was made.", tostring(text)))
            self.draft = nil
            return
        end
        onNumber(number)
    end, self, default ~= nil and tostring(default) or "", prompt, prompt, 10, "OK")
end

function TCDevDialog:askDraftField()
    local choices = TCDevDialog.getFieldChoices()
    if #choices == 0 then
        self:setStatus("This map has no fields on its farmlands, so there's nothing to pick.")
        self.draft = nil
        return
    end
    local labels = {}
    for _, choice in ipairs(choices) do
        table.insert(labels, choice.label)
    end
    OptionDialog.show(function(index)
        local choice = choices[index]
        if choice == nil or self.draft == nil then
            self.draft = nil
            return
        end
        self.draft.fieldId = choice.fieldId
        self:askDraftDetails()
    end, string.format("%s job: which farmland?", self.draft.jobType), "Select field", labels)
end

function TCDevDialog:askDraftDetails()
    askNumber(self, "Price (at today's price level)?", TCDevDialog.DEFAULT_PRICE, function(price)
        self.draft.price = math.floor(price)
        askNumber(self, "Due in how many days from today?", TCDevDialog.DEFAULT_DUE_DAYS, function(days)
            self.draft.dueDays = math.max(0, math.floor(days))
            askNumber(self, "Skill needed (1-10)?", TCDevDialog.DEFAULT_SKILL, function(skill)
                self.draft.skill = math.min(10, math.max(1, math.floor(skill)))
                self:createDraftJob()
            end)
        end)
    end)
end

function TCDevDialog:createDraftJob()
    local draft = self.draft
    self.draft = nil
    if draft == nil then
        return
    end
    local dueDay = g_currentMission.environment.currentMonotonicDay + draft.dueDays
    local period = TCCalendar.getPeriodFromDay(dueDay)
    local dayInPeriod = TCCalendar.getDayInPeriodFromDay(dueDay)
    self:runCommand("job", { "create", draft.jobType, tostring(draft.fieldId), tostring(draft.skill),
        tostring(draft.price), tostring(period), tostring(dayInPeriod) })
end

-- Hitches ---------------------------------------------------------------------------

-- On opening: the farm's tractors and mowers, the tractor the player's in
-- ticked to start with.
function TCDevDialog:loadVehicles()
    self.tractor = nil
    self.mowers = {}
    self.hitchResultText:setText("")
    local player = g_localPlayer
    local vehicle = player ~= nil and player.getCurrentVehicle ~= nil and player:getCurrentVehicle() or nil
    if vehicle ~= nil and TCHitchExplain.isTractor(vehicle) and vehicle:getOwnerFarmId() == self.farmId then
        self.tractor = vehicle
    end
end

function TCDevDialog:reloadVehicles()
    self.vehicleRows = {}
    if self.farmId ~= nil then
        local tractors, mowers = TCHitchExplain.getCandidates(self.farmId)
        for _, vehicle in ipairs(tractors) do
            table.insert(self.vehicleRows, { kind = "tractor", vehicle = vehicle })
        end
        for _, vehicle in ipairs(mowers) do
            table.insert(self.vehicleRows, { kind = "mower", vehicle = vehicle })
        end
    end
    -- Anything ticked that's gone (sold, deleted) comes off.
    local present = {}
    for _, row in ipairs(self.vehicleRows) do
        present[row.vehicle] = true
    end
    if self.tractor ~= nil and not present[self.tractor] then
        self.tractor = nil
    end
    for i = #self.mowers, 1, -1 do
        if not present[self.mowers[i]] then
            table.remove(self.mowers, i)
        end
    end

    self.selectedVehicleIndex = math.min(math.max(self.selectedVehicleIndex, 1), math.max(#self.vehicleRows, 1))
    self.vehiclesEmptyText:setVisible(#self.vehicleRows == 0)
    self.vehicleList:reloadData()
    if #self.vehicleRows > 0 then
        self.vehicleList:setSelectedIndex(self.selectedVehicleIndex)
    end
end

-- A ticked mower's place in the tick order, or nil.
function TCDevDialog:getMowerOrder(vehicle)
    for index, mower in ipairs(self.mowers) do
        if mower == vehicle then
            return index
        end
    end
    return nil
end

function TCDevDialog:isTicked(row)
    if row.kind == "tractor" then
        return self.tractor == row.vehicle
    end
    return self:getMowerOrder(row.vehicle) ~= nil
end

function TCDevDialog:populateVehicleCell(row, cell)
    if row == nil then
        return
    end
    local ticked = self:isTicked(row)
    cell:getAttribute("checkBox").color = ticked and CHECKBOX_ON_COLOR or CHECKBOX_OFF_COLOR
    cell:getAttribute("name"):setText(string.format("%s (#%s)", row.vehicle:getFullName(),
        tostring(NetworkUtil.getObjectId(row.vehicle))))

    local chipText = row.kind == "tractor" and "Tractor" or "Mower"
    cell:getAttribute("kindChip").color = MenuContractor.CHIP_COLORS[ticked and "good" or
        (row.kind == "tractor" and "info" or "neutral")]
    cell:getAttribute("kindChipText"):setText(chipText)
end

-- One tractor (ticking another swaps it); mowers in the order ticked.
function TCDevDialog:toggleVehicle()
    local row = self.vehicleRows[self.selectedVehicleIndex]
    if row == nil then
        return
    end
    if row.kind == "tractor" then
        self.tractor = self.tractor ~= row.vehicle and row.vehicle or nil
    else
        local order = self:getMowerOrder(row.vehicle)
        if order ~= nil then
            table.remove(self.mowers, order)
        else
            table.insert(self.mowers, row.vehicle)
        end
    end
    self.vehicleList:reloadData()
    self:updateButtons()
end

-- The dialog's answer: what goes on the front, what on the rear, and
-- anything that couldn't be hitched, one line each.
function TCDevDialog.getPlacementLines(result)
    local front, rear, other, unplaced = {}, {}, {}, {}
    for _, placement in ipairs(result.placements) do
        local name = placement.implement:getFullName()
        if placement.attacher == nil then
            table.insert(unplaced, name)
        elseif placement.attacher ~= result.tractor then
            table.insert(other, string.format("%s (on the %s of %s)", name, placement.side,
                placement.attacher:getFullName()))
        elseif placement.side == "front" then
            table.insert(front, name)
        elseif placement.side == "rear" then
            table.insert(rear, name)
        else
            table.insert(other, name)
        end
    end
    local lines = {
        "Front: " .. (#front > 0 and table.concat(front, ", ") or "nothing"),
        "Rear: " .. (#rear > 0 and table.concat(rear, ", ") or "nothing"),
    }
    if #other > 0 then
        table.insert(lines, "Elsewhere: " .. table.concat(other, ", "))
    end
    if #unplaced > 0 then
        table.insert(lines, string.format("Couldn't be hitched: %s, so a worker couldn't be sent with these",
            table.concat(unplaced, ", ")))
    end
    return lines
end

-- Whether two runs put every mower in the same place.
local function isSamePlacement(a, b)
    local where = {}
    for _, placement in ipairs(a.placements) do
        where[placement.implement] = tostring(placement.attacher) .. ":" .. tostring(placement.jointIndex)
    end
    for _, placement in ipairs(b.placements) do
        if where[placement.implement] ~= tostring(placement.attacher) .. ":" .. tostring(placement.jointIndex) then
            return false
        end
    end
    return true
end

-- The planner hitches one mower at a time, so it's run with the mowers
-- both ways round; the dialog says front and rear, and only mentions the
-- other way if it gives a different answer. The log has both.
function TCDevDialog:testHitches()
    if self.tractor == nil or #self.mowers == 0 then
        return
    end
    local runs = { self.mowers }
    if #self.mowers > 1 then
        local reversed = {}
        for i = #self.mowers, 1, -1 do
            table.insert(reversed, self.mowers[i])
        end
        table.insert(runs, reversed)
    end

    local results = {}
    for _, mowers in ipairs(runs) do
        local result = TCHitchExplain.run(self.tractor, mowers, self.farmId)
        TCHitchExplain.log(result, string.format("(%s planned first)", mowers[1]:getFullName()))
        table.insert(results, result)
    end

    local lines = { string.format("On %s:", self.tractor:getFullName()) }
    for _, line in ipairs(TCDevDialog.getPlacementLines(results[1])) do
        table.insert(lines, line)
    end
    if results[2] ~= nil and not isSamePlacement(results[1], results[2]) then
        local other = TCDevDialog.getPlacementLines(results[2])
        table.insert(lines, string.format("But if %s is hitched first, it's different: %s. %s.",
            runs[2][1]:getFullName(), other[1], other[2]))
    end
    table.insert(lines, TCLog.enabled and "Why: see log.txt (lines starting 'TheContractor hitch test')." or
        "The detailed log is off on this machine: type tcLog to turn it on, then test again.")
    self.hitchResultText:setText(table.concat(lines, "\n"))
end
