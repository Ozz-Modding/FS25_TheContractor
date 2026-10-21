-- The company logo on the Overview's company card. A player's own image in
-- modSettings/FS25_TheContractor/ is used if there is one (logo.dds, else
-- logo.png), otherwise ours. A PNG works but logs performance warnings
-- (raw format, no mipmaps, often non-power-of-two size): harmless. It's
-- read from this machine's modSettings only, so in multiplayer every
-- player sees their own file (or the default): an image can't sensibly be
-- sent over the network.
--
-- The card's logo box is square, so the image must be too (other shapes
-- are stretched), with sides a multiple of 4: 512x512 or 1024x1024.

TCCompanyLogo = {}

TCCompanyLogo.DEFAULT_FILENAME = "images/defaultLogo.dds"
TCCompanyLogo.CUSTOM_FILENAMES = { "logo.dds", "logo.png" }

-- g_currentModSettingsDirectory is only set while the mod's scripts are
-- being sourced, so it's captured here rather than read later.
TCCompanyLogo.settingsDir = g_currentModSettingsDirectory

-- Makes the folder so players can find where to put their logo.
function TCCompanyLogo.createSettingsFolder()
    if TCCompanyLogo.settingsDir ~= nil and createFolder ~= nil then
        createFolder(TCCompanyLogo.settingsDir)
    end
end

function TCCompanyLogo.getFilename()
    local dir = TCCompanyLogo.settingsDir
    if dir ~= nil then
        for _, name in ipairs(TCCompanyLogo.CUSTOM_FILENAMES) do
            local path = dir .. name
            if fileExists(path) then
                return path
            end
        end
    end
    return TCCompanyLogo.getDefaultFilename()
end

function TCCompanyLogo.getDefaultFilename()
    return Utils.getFilename(TCCompanyLogo.DEFAULT_FILENAME, TheContractor.dir)
end
