-- Top-level "Contractor" in-game menu page: four sub-tabs (Overview, Inbox,
-- Calendar, Staff) — Inbox/Calendar/Staff are placeholders later tickets
-- fill in. Structure mirrors FS25_RedTape/src/gui/MenuRedTape.lua's own
-- top-level page + subCategory-tab pattern.

MenuContractor = {}
MenuContractor._mt = Class(MenuContractor, TabbedMenuFrameElement)

-- Overview is tab 1 (and so the default tab on first open): it's the only
-- tab reachable before a farm has a company, since that's where "Create
-- Company" lives. Once a company exists it's the central status page —
-- company name, reputation tier/progress, and (for now) a "more actions
-- coming soon" note; job history/reputation-over-time land once 008 (job
-- data model) exists to source them.
MenuContractor.SUB_CATEGORY = {
    OVERVIEW = 1,
    INBOX = 2,
    CALENDAR = 3,
    STAFF = 4,
}

MenuContractor.HEADER_SLICES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "gui.icon_ingameMenu_contracts",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "gui.icon_ingameMenu_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "gui.icon_ingameMenu_animals",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "gui.icon_ingameMenu_finances",
}

MenuContractor.HEADER_TITLES = {
    [MenuContractor.SUB_CATEGORY.INBOX] = "tc_header_inbox",
    [MenuContractor.SUB_CATEGORY.CALENDAR] = "tc_header_calendar",
    [MenuContractor.SUB_CATEGORY.STAFF] = "tc_header_staff",
    [MenuContractor.SUB_CATEGORY.OVERVIEW] = "tc_header_overview",
}

function MenuContractor.new(i18n)
    local self = MenuContractor:superClass().new(nil, MenuContractor._mt)
    self.name = "MenuContractor"
    self.i18n = i18n
    self.menuButtonInfo = {}

    return self
end

function MenuContractor:initialize()
    MenuContractor:superClass().initialize(self)

    for i, tab in pairs(self.subCategoryTabs) do
        tab:getDescendantByName("background").getIsSelected = function()
            return i == self.subCategoryPaging:getState()
        end
        function tab.getIsSelected()
            return i == self.subCategoryPaging:getState()
        end
    end

    self.btnBack = {
        inputAction = InputAction.MENU_BACK
    }
    self.btnNextPage = {
        inputAction = InputAction.MENU_PAGE_NEXT,
        text = g_i18n:getText("ui_ingameMenuNext"),
        callback = self.onPageNext
    }
    self.btnPrevPage = {
        inputAction = InputAction.MENU_PAGE_PREV,
        text = g_i18n:getText("ui_ingameMenuPrev"),
        callback = self.onPagePrevious
    }

    self.btnCreateCompany = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("tc_actions_createButton"),
        callback = function()
            self:onClickCreateCompany()
        end
    }

    self.menuButtonInfoDefault = { self.btnBack, self.btnNextPage, self.btnPrevPage }
    for _, category in pairs(MenuContractor.SUB_CATEGORY) do
        self.menuButtonInfo[category] = self.menuButtonInfoDefault
    end

    -- Overview tab gets the Create Company button appended, but only while
    -- the farm has no company yet (see getMenuButtonInfo) — following
    -- FS25_RedTape/src/gui/MenuRedTape.lua's own bottom-bar action-button
    -- pattern (e.g. its Grants tab), rather than an in-page GUI button.
    self.menuButtonInfoOverviewNoCompany = { self.btnBack, self.btnNextPage, self.btnPrevPage, self.btnCreateCompany }
end

function MenuContractor:getMenuButtonInfo()
    local state = self.subCategoryPaging:getState()

    if state == MenuContractor.SUB_CATEGORY.OVERVIEW and not self:hasCompany() then
        return self.menuButtonInfoOverviewNoCompany
    end

    return self.menuButtonInfo[state]
end

function MenuContractor:onFrameOpen()
    local texts = {}
    for k, tab in pairs(self.subCategoryTabs) do
        tab:setVisible(true)
        table.insert(texts, tostring(k))
    end
    self.subCategoryBox:invalidateLayout()
    self.subCategoryPaging:setTexts(texts)
    self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)

    self:updateContent()
    self:setMenuButtonInfoDirty()
end

function MenuContractor:hasCompany()
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Company == nil then
        return false
    end
    return tc.Company:hasCompany(g_currentMission:getFarmId())
end

-- Inbox/Calendar/Staff stay visible as tabs (see main.lua's note on the
-- always-visible top-level predicate) but their content is gated on the
-- farm having a company, until the real per-tab content lands in later
-- tickets. The Overview tab itself swaps between a "no company yet" prompt
-- and the company name/reputation-rank status once one exists.
function MenuContractor:refreshCompanyState()
    local hasCompany = self:hasCompany()

    self.textNoCompany:setVisible(not hasCompany)
    self.textCompanyName:setVisible(hasCompany)
    self.nextRankText:setVisible(hasCompany)
    self.textActionsAvailable:setVisible(hasCompany)
    self.textJobHistoryPlaceholder:setVisible(hasCompany)
    self.progressBox:setVisible(hasCompany)

    if hasCompany then
        local farmId = g_currentMission:getFarmId()
        local tc = g_currentMission.TheContractor
        local name = tc.Company:getCompanyName(farmId)
        self.textCompanyName:setText(name)

        local progress = tc.Reputation:getProgress(farmId)
        self.rankTierText:setText(g_i18n:getText("tc_reputationTier_" .. progress.tier.key))

        if progress.nextTier ~= nil then
            self.progressText:setText(string.format("%d/%d", progress.score, progress.nextTier.minScore))
            self.nextRankText:setText(string.format(g_i18n:getText("tc_overview_nextRank"),
                g_i18n:getText("tc_reputationTier_" .. progress.nextTier.key)))
        else
            self.progressText:setText(g_i18n:getText("tc_overview_rankMax"))
            self.nextRankText:setText(string.format(g_i18n:getText("tc_overview_nextRank"),
                g_i18n:getText("tc_overview_nextRankNone")))
        end

        local fullWidth = self.progressBarBg.size[1] - self.progressBar.margin[1] * 2
        local minProgressBarWidthRatio = self.progressBar.startSize[1] * 2 / fullWidth
        local progressBarRatio = math.max(progress.progressPercentage, minProgressBarWidthRatio)
        self.progressBar:setSize(fullWidth * math.min(progressBarRatio, 1), nil)
    end

    local lockedText = g_i18n:getText("tc_placeholder_locked")
    self.placeholderInbox:setText(hasCompany and g_i18n:getText("tc_placeholder_inbox") or lockedText)
    self.placeholderCalendar:setText(hasCompany and g_i18n:getText("tc_placeholder_calendar") or lockedText)
    self.placeholderStaff:setText(hasCompany and g_i18n:getText("tc_placeholder_staff") or lockedText)
end

function MenuContractor:onClickCreateCompany()
    local farmId = g_currentMission:getFarmId()
    local company = g_currentMission.TheContractor.Company

    if company:hasCompany(farmId) then
        return
    end

    if not company:canCreateCompany(farmId) then
        InfoDialog.show(g_i18n:getText("tc_actions_cannotAfford"))
        return
    end

    local dialogPrompt = string.format(g_i18n:getText("tc_actions_createCompanyPrompt"),
        g_i18n:formatMoney(TheContractorCompany.CREATION_COST, 0, true, true))

    TextInputDialog.show(function(target, text, clickOk)
        if not clickOk then
            return
        end

        local name = text
        if name == nil or name == "" then
            name = g_i18n:getText("tc_actions_defaultCompanyName")
        end

        g_client:getServerConnection():sendEvent(TCCreateCompanyEvent.new(farmId, name))
        target:refreshCompanyState()
        target:setMenuButtonInfoDirty()
    end, self, "", dialogPrompt, dialogPrompt, 30, g_i18n:getText("tc_actions_createButton"))
end

function MenuContractor:onClickInbox()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.INBOX, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickCalendar()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.CALENDAR, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickStaff()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.STAFF, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:onClickOverview()
    self.subCategoryPaging:setState(MenuContractor.SUB_CATEGORY.OVERVIEW, true)
    self:setMenuButtonInfoDirty()
end

function MenuContractor:updateSubCategoryPages(subCategoryIndex)
    self:updateContent()
    self:setMenuButtonInfoDirty()
end

function MenuContractor:updateContent()
    local state = self.subCategoryPaging:getState()

    self.categoryHeaderIcon:setImageSlice(nil, MenuContractor.HEADER_SLICES[state])
    self.categoryHeaderText:setText(g_i18n:getText(MenuContractor.HEADER_TITLES[state]))

    for k, v in pairs(self.subCategoryPages) do
        v:setVisible(k == state)
    end

    self:refreshCompanyState()
end

-- Adapted from FS25_RedTape/src/RedTape.lua RedTape.addIngameMenuPage
-- (itself credited there to Courseplay): the public g_inGameMenu API for
-- inserting a new top-level page/icon, since there is no XML/config toggle
-- for adding one declaratively.
--
-- iconImageSize is the actual pixel size of images/menuIcon.dds — GuiUtils.getUVs
-- needs it to normalize `uvs` correctly for a non-1024x1024 icon atlas (see
-- FS25_ImprovedControlsMenu/src/main.lua's addIngameMenuPage, which passes
-- {128, 128} for its own 128x128 icon; RedTape's own 1024x1024 icon gets away
-- with omitting it since that's GuiUtils.getUVs' implicit default).
function MenuContractor.registerInIngameMenu(frame, pageName, uvs, iconImageSize, predicateFunc, insertAfter)
    local targetPosition = 0

    g_inGameMenu.controlIDs[pageName] = nil

    for i = 1, #g_inGameMenu.pagingElement.elements do
        local child = g_inGameMenu.pagingElement.elements[i]
        if child == g_inGameMenu[insertAfter] then
            targetPosition = i + 1
            break
        end
    end

    g_inGameMenu[pageName] = frame
    g_inGameMenu.pagingElement:addElement(g_inGameMenu[pageName])

    g_inGameMenu:exposeControlsAsFields(pageName)

    for i = 1, #g_inGameMenu.pagingElement.elements do
        local child = g_inGameMenu.pagingElement.elements[i]
        if child == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pagingElement.elements, i)
            table.insert(g_inGameMenu.pagingElement.elements, targetPosition, child)
            break
        end
    end

    for i = 1, #g_inGameMenu.pagingElement.pages do
        local child = g_inGameMenu.pagingElement.pages[i]
        if child.element == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pagingElement.pages, i)
            table.insert(g_inGameMenu.pagingElement.pages, targetPosition, child)
            break
        end
    end

    g_inGameMenu.pagingElement:updateAbsolutePosition()
    g_inGameMenu.pagingElement:updatePageMapping()

    g_inGameMenu:registerPage(g_inGameMenu[pageName], nil, predicateFunc)

    local iconFileName = Utils.getFilename("images/menuIcon.dds", TheContractor.dir)
    g_inGameMenu:addPageTab(g_inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs, iconImageSize))

    for i = 1, #g_inGameMenu.pageFrames do
        local child = g_inGameMenu.pageFrames[i]
        if child == g_inGameMenu[pageName] then
            table.remove(g_inGameMenu.pageFrames, i)
            table.insert(g_inGameMenu.pageFrames, targetPosition, child)
            break
        end
    end

    g_inGameMenu:rebuildTabList()
end
