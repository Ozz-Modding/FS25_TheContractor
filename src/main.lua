TheContractor = {}
TheContractor.dir = g_currentModDirectory
TheContractor.SaveKey = "TheContractor"

source(TheContractor.dir .. "src/util/DisableVanillaContracts.lua")
source(TheContractor.dir .. "src/gui/MenuContractor.lua")
source(TheContractor.dir .. "src/business/Reputation.lua")
source(TheContractor.dir .. "src/business/Jobs.lua")
source(TheContractor.dir .. "src/business/Staff.lua")
source(TheContractor.dir .. "src/business/Company.lua")
source(TheContractor.dir .. "src/events/TCInitialClientStateEvent.lua")
source(TheContractor.dir .. "src/events/TCCreateCompanyEvent.lua")
source(TheContractor.dir .. "src/events/TCReputationChangedEvent.lua")
source(TheContractor.dir .. "src/events/TCDebugAddReputationEvent.lua")

-- The top-level Contractor page itself stays always-visible (see Company.lua
-- and MenuContractor's Overview tab): "Create Company" has to live somewhere
-- reachable before a company exists, so the page can't be gated on having
-- one without a chicken-and-egg problem. Inbox/Calendar/Staff content is
-- what's actually gated on hasCompany(), from within MenuContractor.
function TheContractor:makeIsContractorMenuEnabledPredicate()
    return function()
        return true
    end
end

function TheContractor:loadMap()
    g_currentMission.TheContractor = self

    self.Reputation = TheContractorReputation.new()
    self.Jobs = TheContractorJobs.new()
    self.Staff = TheContractorStaff.new()
    self.Company = TheContractorCompany.new()

    TheContractorDisableVanillaContracts.hideContractsTab()

    g_gui:loadProfiles(TheContractor.dir .. "src/gui/guiProfiles.xml")

    local menuContractor = MenuContractor.new(g_i18n)
    g_gui:loadGui(TheContractor.dir .. "src/gui/MenuContractor.xml", "menuContractor", menuContractor, true)

    MenuContractor.registerInIngameMenu(menuContractor, "pageContractor", { 0, 0, 128, 128 }, { 128, 128 },
        self:makeIsContractorMenuEnabledPredicate(), "pageSettings")
    menuContractor:initialize()

    self.MenuContractor = menuContractor

    self:loadFromXMLFile()

    -- Cheat-gated, following FS25_RedTape's own rtAddPoints console command
    -- (RedTape.lua's consoleCommandAddPoints): easy manual testing of
    -- reputation-tier progression without waiting for 011/014/022/024 to
    -- exist and actually award/deduct it.
    if g_addCheatCommands and g_currentMission:getIsServer() then
        addConsoleCommand("tcAddReputation",
            "Add or remove reputation points for current farm. Usage: tcAddReputation amount", "consoleCommandAddReputation", self)
    end

    Logging.info("TheContractor: loadMap")
end

function TheContractor:consoleCommandAddReputation(amount)
    if not g_currentMission:getIsServer() then return "Server only" end

    local numAmount = tonumber(amount)
    if numAmount == nil then
        return "Usage: tcAddReputation amount (e.g. tcAddReputation 100 or tcAddReputation -50)"
    end

    local farm = g_farmManager:getFarmByUserId(g_currentMission.playerUserId)
    if farm == nil or farm.farmId == 0 then
        return "Error: No farm found for current player"
    end

    g_client:getServerConnection():sendEvent(TCDebugAddReputationEvent.new(farm.farmId, numAmount))
    return string.format("Applied %d reputation to farm %d", numAmount, farm.farmId)
end

-- Called as a normal method (self == TheContractor) from loadMap, once the
-- savegame directory is known.
function TheContractor:loadFromXMLFile()
    if not g_currentMission:getIsServer() then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory
    if savegameFolderPath == nil then
        savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(),
            g_currentMission.missionInfo.savegameIndex)
    end
    savegameFolderPath = savegameFolderPath .. "/"

    local filePath = savegameFolderPath .. TheContractor.SaveKey .. ".xml"
    if not fileExists(filePath) then
        return
    end

    local xmlFile = loadXMLFile(TheContractor.SaveKey, filePath)

    self.Reputation:loadFromXMLFile(xmlFile)
    self.Jobs:loadFromXMLFile(xmlFile)
    self.Staff:loadFromXMLFile(xmlFile)
    self.Company:loadFromXMLFile(xmlFile)

    delete(xmlFile)
end

-- Appended onto FSBaseMission.saveSavegame (see installSaveHook below), so
-- this runs with `self` bound to the mission instance, not TheContractor —
-- go via g_currentMission.TheContractor instead, same as RedTape does.
function TheContractor:saveToXmlFile()
    if not g_currentMission:getIsServer() then return end

    local tc = g_currentMission.TheContractor
    if tc == nil then return end

    local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory .. "/"

    local xmlFile = createXMLFile(TheContractor.SaveKey, savegameFolderPath .. TheContractor.SaveKey .. ".xml",
        TheContractor.SaveKey)

    tc.Reputation:saveToXmlFile(xmlFile)
    tc.Jobs:saveToXmlFile(xmlFile)
    tc.Staff:saveToXmlFile(xmlFile)
    tc.Company:saveToXmlFile(xmlFile)

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

-- Mission00.saveSavegame is inherited from FSBaseMission via metatable, so it is
-- ALWAYS non-nil even when Mission00 has no override of its own. Checking it directly
-- (without rawget) would make us always shadow Mission00, permanently orphaning any
-- mod that later hooks FSBaseMission.saveSavegame (the standard convention most mods
-- use, e.g. inside FSBaseMission.onStartMission). Only target Mission00 if another mod
-- has already put its own property there — otherwise stay on FSBaseMission so we remain
-- part of the shared chain. (Same reasoning as FS25_RedTape's installSaveHook.)
function TheContractor.installSaveHook()
    if TheContractor.saveHookInstalled then
        return
    end

    local target = FSBaseMission
    if Mission00 ~= nil and rawget(Mission00, "saveSavegame") ~= nil then
        target = Mission00
    end

    target.saveSavegame = Utils.appendedFunction(target.saveSavegame, TheContractor.saveToXmlFile)
    TheContractor.saveHookInstalled = true
end

function TheContractor:sendInitialClientState(connection, user, farm)
    connection:sendEvent(TCInitialClientStateEvent.new())
end

function TheContractor.installInitialClientStateHook()
    if TheContractor.initialClientStateHookInstalled then
        return
    end

    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        TheContractor.sendInitialClientState)
    TheContractor.initialClientStateHookInstalled = true
end

function TheContractor:deleteMap()
    Logging.info("TheContractor: deleteMap")

    if g_addCheatCommands then
        removeConsoleCommand("tcAddReputation")
    end

    if g_currentMission ~= nil and g_currentMission.TheContractor == self then
        g_currentMission.TheContractor = nil
    end
end

function TheContractor:update(dt)
end

TheContractor.installSaveHook()
TheContractor.installInitialClientStateHook()

addModEventListener(TheContractor)
