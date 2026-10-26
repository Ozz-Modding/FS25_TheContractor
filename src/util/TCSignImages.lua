-- The signs' own images (085): one design per image the player puts in
-- modSettings/FS25_TheContractor/signs/, offered as options of the company
-- and wall signs' tcSignDesign configuration (PlaceableTCLogoSign's
-- TCSignDesignConfigurationItem).
-- A design is saved by its file name, so adding, removing or reordering
-- images doesn't change what an existing sign shows; one whose image has
-- gone falls back to the company logo.
--
-- Single-player only. Configurations are synced by index, and every
-- machine would build its list from its own folder, so in multiplayer the
-- list is just the company logo on every machine. With one option the
-- construction menu shows no picker, so the signs are logo signs there.
--
-- The list is read when the save loads (store items are built then), so a
-- new image shows after reloading the save.

TCSignImages = {}

TCSignImages.FOLDER = "signs/"
-- Configurations are sent in 7 bits (ConfigurationUtil.SEND_NUM_BITS), and
-- the company logo takes one option.
TCSignImages.MAX_IMAGES = 127
TCSignImages.SAVE_ID_PREFIX = "sign_"

-- Example designs shipped in the mod, copied into signs/ on every load
-- (TCCompanyLogo.createSettingsFolder) to show players how it's laid out.
TCSignImages.EXAMPLES_DIR = "images/signs/"
TCSignImages.EXAMPLES = { "Contractors_At_Work.dds", "No_Entry.dds" }

-- g_currentModSettingsDirectory is only set while the mod's scripts are
-- being sourced, so it's captured here rather than read later.
TCSignImages.settingsDir = g_currentModSettingsDirectory

-- Copies the examples into signsDir, over any of the same name.
function TCSignImages.seedExamples(signsDir)
    if copyFile == nil then
        return
    end
    for _, name in ipairs(TCSignImages.EXAMPLES) do
        copyFile(Utils.getFilename(TCSignImages.EXAMPLES_DIR .. name, TheContractor.dir), signsDir .. name, true)
    end
end

-- Same answer as FS25_EconomyScale's: a listen server, a dedicated server
-- or a client. The flag is set when the mission is made, before the store
-- items load; with no mission yet, treat it as multiplayer, the safe side.
function TCSignImages.getIsMultiplayer()
    local dynamicInfo = g_currentMission ~= nil and g_currentMission.missionDynamicInfo or nil
    if dynamicInfo == nil then
        return true
    end
    return dynamicInfo.isMultiplayer == true
end

function TCSignImages.getFolder()
    if TCSignImages.settingsDir == nil then
        return nil
    end
    return TCSignImages.settingsDir .. TCSignImages.FOLDER
end

-- "for_sale-now" -> "For Sale Now".
function TCSignImages.getDisplayName(stem)
    local name = stem:gsub("[_%-]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("(%a)(%w*)", function(first, rest)
        return first:upper() .. rest
    end)
    return name
end

-- The names of the files (not folders) in a folder, through the engine's
-- getFiles callback, the way the game's own Files.new lists one. Vanilla's
-- FileSystemUtil wraps the same call but the game never loads it.
function TCSignImages.listFiles(folder)
    local files = {}
    if getFiles == nil then
        return files
    end
    local target = {
        onFile = function(_, filename, isDirectory)
            if not isDirectory then
                table.insert(files, filename)
            end
        end,
    }
    getFiles((folder:gsub("/$", "")), "onFile", target)
    return files
end

-- The image formats signs/ takes, in order of preference. A PNG works, like
-- the logo's, but the game logs performance warnings for it (no mipmaps,
-- so it shimmers at a distance).
TCSignImages.EXTENSIONS = { dds = 1, png = 2 }

-- The images in signs/, sorted by name: { name, saveId, filename } each.
-- A design is saved by its name without the extension, so a DDS and a PNG
-- of the same name are one design, the DDS.
function TCSignImages.getImages()
    local folder = TCSignImages.getFolder()
    if folder == nil then
        return {}
    end

    local images = {}
    local byKey = {}
    for _, file in ipairs(TCSignImages.listFiles(folder)) do
        local stem, extension = file:match("^(.+)%.(%a+)$")
        local preference = extension ~= nil and TCSignImages.EXTENSIONS[extension:lower()] or nil
        if stem ~= nil and preference ~= nil then
            local key = stem:lower()
            local existing = byKey[key]
            if existing == nil then
                existing = {
                    name = TCSignImages.getDisplayName(stem),
                    saveId = TCSignImages.SAVE_ID_PREFIX .. key,
                    sortKey = key,
                }
                byKey[key] = existing
                table.insert(images, existing)
            end
            if existing.preference == nil or preference < existing.preference then
                existing.filename = folder .. file
                existing.preference = preference
            end
        end
    end
    table.sort(images, function(a, b)
        return a.sortKey < b.sortKey
    end)
    if #images > TCSignImages.MAX_IMAGES then
        TCLog.warning("The Contractor: only the first %d images in %s are used as sign designs",
            TCSignImages.MAX_IMAGES, folder)
        for i = #images, TCSignImages.MAX_IMAGES + 1, -1 do
            images[i] = nil
        end
    end
    return images
end

-- The designs the signs offer on this machine: none in multiplayer. Run
-- once per sign store item, so the folder is listed for each.
function TCSignImages.getDesigns()
    if TCSignImages.getIsMultiplayer() then
        TCLog.info("TheContractor: multiplayer, so signs only offer the company logo")
        return {}
    end
    local images = TCSignImages.getImages()
    TCLog.info("TheContractor: %d sign design(s) found in %s", #images, tostring(TCSignImages.getFolder()))
    return images
end
