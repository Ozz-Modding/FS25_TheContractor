-- The company logo on the Overview's company card. A player's own logo.dds
-- (else logo.png) in modSettings/FS25_TheContractor/savegame<N>/ (just this
-- save) or else modSettings/FS25_TheContractor/ (every save) is used if
-- there is one, otherwise ours. A PNG works but the game logs performance
-- warnings for it (no mipmaps, so it also shimmers at a distance on 084's
-- signs): harmless. It's read from this machine's
-- modSettings only, so in multiplayer every player sees their own file (or
-- the default): an image can't sensibly be sent over the network.
--
-- The card's logo box is square, so the image must be too (other shapes
-- are stretched), with sides a multiple of 4: 512x512 or 1024x1024.

TCCompanyLogo = {}

TCCompanyLogo.DEFAULT_FILENAME = "images/defaultLogo.dds"
-- In order of preference.
TCCompanyLogo.CUSTOM_FILENAMES = { "logo.dds", "logo.png" }
TCCompanyLogo.SAVEGAME_FOLDER_PREFIX = "savegame"

-- g_currentModSettingsDirectory is only set while the mod's scripts are
-- being sourced, so it's captured here rather than read later.
TCCompanyLogo.settingsDir = g_currentModSettingsDirectory

TCCompanyLogo.README_FILENAME = "README.txt"

-- What the README in the settings folder says: where the logo and the
-- signs' own images go (085). Rewritten on every load, so it stays in step
-- with the mod (it's ours, not the player's to edit).
TCCompanyLogo.README_TEXT = [[
THE CONTRACTOR - YOUR LOGO AND SIGNS
====================================

This folder is read by The Contractor mod. Nothing here is needed: without
it the mod uses its own placeholder logo.

YOUR COMPANY LOGO
-----------------
Put your logo here as logo.dds (or logo.png) to replace the placeholder.
It shows on the Overview tab's company card and on the Company Sign and
Company Wall Signs (construction menu, Contractor tab).

A different logo for one save: make a folder here named after its save slot
(savegame1, savegame2, ...) and put that save's logo in it. A save with no
logo of its own uses the one in this folder.

SIGN DESIGNS
------------
Put images in the signs folder next to this file. Each one becomes a design
you can pick for a Company Sign or Wall Sign when you place it. The file
name is the design's name: "for_sale.dds" is offered as "For Sale". The
company logo is always the first design. The mod puts two examples there
on every load, over any file of the same name.

New images show after you reload the save. A sign keeps its design by file
name, so if you delete or rename its image it goes back to the company logo.

IMAGE SIZE AND FORMAT
---------------------
- Square, with sides a multiple of 4: 512x512 or 1024x1024 are best.
  Other shapes are stretched to fit.
- DDS or PNG. DDS is best, ideally with mipmaps (GIANTS Texture Tool, or
  paint.net's DDS export). A PNG works, but you will get warnings in the
  game's log if you don't use DDS format. If there's a DDS and a PNG of the
  same name, the DDS is used.
- Replacing an image the game has already shown needs a game restart.

MULTIPLAYER
-----------
Images are read from each player's own computer and can't be sent to other
players, so:
- Your logo shows only on your own farm's signs. Everyone else's show the
  placeholder.
- Sign designs are single-player only. In multiplayer every sign shows the
  company logo, including any placed with a design. If such a save is
  saved in multiplayer, those signs keep the company logo after.
]]

-- Makes the folder so players can find where to put their logo, its signs
-- folder (085) with our example designs in it, and the README explaining
-- both.
function TCCompanyLogo.createSettingsFolder()
    local dir = TCCompanyLogo.settingsDir
    if dir == nil or createFolder == nil then
        return
    end
    createFolder(dir)
    if TCSignImages ~= nil then
        local signsDir = dir .. TCSignImages.FOLDER
        createFolder(signsDir)
        TCSignImages.seedExamples(signsDir)
    end
    TCCompanyLogo.writeReadme(dir .. TCCompanyLogo.README_FILENAME)
end

function TCCompanyLogo.writeReadme(path)
    if createFile == nil or fileWrite == nil or FileAccess == nil then
        return
    end
    local file = createFile(path, FileAccess.WRITE)
    if file == nil or file == 0 then
        return
    end
    fileWrite(file, (TCCompanyLogo.README_TEXT:gsub("\r?\n", "\r\n")))
    delete(file)
end

-- The current save's own folder, savegame<N>/ (named after the save's slot,
-- as the game's own savegame folders are), or nil. A client joining a game
-- has no save slot of its own (index 0), so it has none.
function TCCompanyLogo.getSavegameDir()
    local dir = TCCompanyLogo.settingsDir
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local index = missionInfo ~= nil and missionInfo.savegameIndex or nil
    if dir == nil or type(index) ~= "number" or index < 1 then
        return nil
    end
    return string.format("%s%s%d/", dir, TCCompanyLogo.SAVEGAME_FOLDER_PREFIX, index)
end

-- The save's own logo if its folder has one, else the shared one, else
-- ours. A DDS comes before a PNG in the same folder.
function TCCompanyLogo.getFilename()
    local dirs = { TCCompanyLogo.getSavegameDir(), TCCompanyLogo.settingsDir }
    for i = 1, 2 do
        local dir = dirs[i]
        if dir ~= nil then
            for _, name in ipairs(TCCompanyLogo.CUSTOM_FILENAMES) do
                if fileExists(dir .. name) then
                    return dir .. name
                end
            end
        end
    end
    return TCCompanyLogo.getDefaultFilename()
end

function TCCompanyLogo.getDefaultFilename()
    return Utils.getFilename(TCCompanyLogo.DEFAULT_FILENAME, TheContractor.dir)
end

-- The Overview logo's tooltip: where this machine looks for a logo (the
-- real folders, the save's own one too when there is one), the README,
-- and which file is showing now.
function TCCompanyLogo.getTooltipContent()
    local paragraphs = {}
    local dir = TCCompanyLogo.settingsDir
    if dir ~= nil then
        table.insert(paragraphs, string.format(g_i18n:getText("tc_logoTip_shared"), dir))
        local savegameDir = TCCompanyLogo.getSavegameDir()
        if savegameDir ~= nil then
            table.insert(paragraphs, string.format(g_i18n:getText("tc_logoTip_savegame"), savegameDir))
        end
        table.insert(paragraphs, string.format(g_i18n:getText("tc_logoTip_readme"), TCCompanyLogo.README_FILENAME))
    end

    local filename = TCCompanyLogo.getFilename()
    local showing = g_i18n:getText("tc_logoTip_placeholder")
    if filename ~= TCCompanyLogo.getDefaultFilename() then
        showing = filename
    end
    table.insert(paragraphs, string.format(g_i18n:getText("tc_logoTip_showing"), showing))

    return g_i18n:getText("tc_logoTip_title"), table.concat(paragraphs, "\n\n")
end
