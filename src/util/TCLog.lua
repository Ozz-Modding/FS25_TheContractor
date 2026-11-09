-- The mod's own log. TCLog.info is the mod's running commentary (jobs
-- dispatched, invoices paid, events rolled): on by default, so a player's
-- log.txt already has it when they report a bug, and a player who finds it
-- too chatty toggles it off with `tcLog` (installed by TCConsole). Warnings
-- and errors are real problems and always go to the log, whatever the
-- switch says.
--
-- The switch is this machine's own (nothing is synced) and is kept in
-- LOCAL_FILENAME in this machine's modSettings folder, so it stays on across
-- loads. It's read as the scripts are sourced, so lines logged while a save
-- loads are covered too.

TCLog = {}

TCLog.LOCAL_FILENAME = "debugLog.xml"
TCLog.SAVE_KEY = "TheContractorDebugLog"

TCLog.enabled = true
TCLog.settingsDir = g_currentModSettingsDirectory

function TCLog.info(fmt, ...)
    if TCLog.enabled then
        Logging.info(fmt, ...)
    end
end

function TCLog.warning(fmt, ...)
    Logging.warning(fmt, ...)
end

function TCLog.xmlWarning(xmlFile, fmt, ...)
    Logging.xmlWarning(xmlFile, fmt, ...)
end

function TCLog.error(fmt, ...)
    Logging.error(fmt, ...)
end

function TCLog.getFilename()
    local dir = TCLog.settingsDir
    return dir ~= nil and dir .. TCLog.LOCAL_FILENAME or nil
end

function TCLog.load()
    local filename = TCLog.getFilename()
    if filename == nil or not fileExists(filename) then
        return
    end
    local xmlFile = loadXMLFile(TCLog.SAVE_KEY, filename)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    local enabled = getXMLBool(xmlFile, TCLog.SAVE_KEY .. "#enabled")
    if enabled ~= nil then
        TCLog.enabled = enabled
    end
    delete(xmlFile)
end

function TCLog.save()
    local filename = TCLog.getFilename()
    if filename == nil then
        return
    end
    createFolder(TCLog.settingsDir)
    local xmlFile = createXMLFile(TCLog.SAVE_KEY, filename, TCLog.SAVE_KEY)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    setXMLBool(xmlFile, TCLog.SAVE_KEY .. "#enabled", TCLog.enabled)
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function TCLog.setEnabled(enabled)
    TCLog.enabled = enabled
    TCLog.save()
end

-- The tcLog console command.
function TCLog.toggle()
    TCLog.setEnabled(not TCLog.enabled)
    return string.format("The Contractor's detailed log is %s.", TCLog.enabled and "on" or "off")
end
