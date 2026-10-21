-- The company logo on the Overview's company card. A player's own logo.dds
-- in modSettings/FS25_TheContractor/savegame<N>/ (just this save) or else
-- modSettings/FS25_TheContractor/ (every save) is used if there is one,
-- otherwise ours. DDS only: the logo also goes on 084's sign, where a PNG (no
-- mipmaps) shimmers at a distance. It's read from this machine's
-- modSettings only, so in multiplayer every player sees their own file (or
-- the default): an image can't sensibly be sent over the network.
--
-- The card's logo box is square, so the image must be too (other shapes
-- are stretched), with sides a multiple of 4: 512x512 or 1024x1024.

TCCompanyLogo = {}

TCCompanyLogo.DEFAULT_FILENAME = "images/defaultLogo.dds"
TCCompanyLogo.CUSTOM_FILENAME = "logo.dds"
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
Put your logo here as logo.dds to replace the placeholder.
It shows on the Overview tab's company card and on the Company Sign and
Company Wall Signs (construction menu, Contractor tab).

A different logo for one save: make a folder here named after its save slot
(savegame1, savegame2, ...) and put that save's logo.dds in it. A save with
no logo.dds of its own uses the one in this folder.

SIGN DESIGNS
------------
Put images in the signs folder next to this file. Each one becomes a design
you can pick for a Company Sign or Wall Sign when you place it. The file name is the design's name: "for_sale.dds" is offered
as "For Sale". The company logo is always the first design.

New images show after you reload the save. A sign keeps its design by file
name, so if you delete or rename its image it goes back to the company logo.

IMAGE SIZE AND FORMAT
---------------------
- Square, with sides a multiple of 4: 512x512 or 1024x1024 are best.
  Other shapes are stretched to fit.
- DDS only, ideally with mipmaps (GIANTS Texture Tool, or paint.net's
  DDS export). Other formats such as PNG are ignored.
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
-- folder (085), and the README explaining both.
function TCCompanyLogo.createSettingsFolder()
    local dir = TCCompanyLogo.settingsDir
    if dir == nil or createFolder == nil then
        return
    end
    createFolder(dir)
    if TCSignImages ~= nil then
        createFolder(dir .. TCSignImages.FOLDER)
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

-- The save's own logo.dds if its folder has one, else the shared one, else ours.
function TCCompanyLogo.getFilename()
    local dirs = { TCCompanyLogo.getSavegameDir(), TCCompanyLogo.settingsDir }
    for i = 1, 2 do
        local dir = dirs[i]
        if dir ~= nil and fileExists(dir .. TCCompanyLogo.CUSTOM_FILENAME) then
            return dir .. TCCompanyLogo.CUSTOM_FILENAME
        end
    end
    return TCCompanyLogo.getDefaultFilename()
end

function TCCompanyLogo.getDefaultFilename()
    return Utils.getFilename(TCCompanyLogo.DEFAULT_FILENAME, TheContractor.dir)
end
