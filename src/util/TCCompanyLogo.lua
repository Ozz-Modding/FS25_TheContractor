-- The company logo on the Overview's company card. A player's own logo.dds
-- in modSettings/FS25_TheContractor/ is used if there is one, otherwise
-- ours. DDS only: the logo also goes on 084's sign, where a PNG (no
-- mipmaps) shimmers at a distance. It's read from this machine's
-- modSettings only, so in multiplayer every player sees their own file (or
-- the default): an image can't sensibly be sent over the network.
--
-- The card's logo box is square, so the image must be too (other shapes
-- are stretched), with sides a multiple of 4: 512x512 or 1024x1024.

TCCompanyLogo = {}

TCCompanyLogo.DEFAULT_FILENAME = "images/defaultLogo.dds"
TCCompanyLogo.CUSTOM_FILENAME = "logo.dds"

-- g_currentModSettingsDirectory is only set while the mod's scripts are
-- being sourced, so it's captured here rather than read later.
TCCompanyLogo.settingsDir = g_currentModSettingsDirectory

TCCompanyLogo.README_FILENAME = "README.txt"

-- What the README in the settings folder says: where the logo and the
-- custom sign's images go (085). Written once; a player's edits are kept.
TCCompanyLogo.README_TEXT = [[
THE CONTRACTOR - YOUR LOGO AND SIGNS
====================================

This folder is read by The Contractor mod. Nothing here is needed: without
it the mod uses its own placeholder logo.

YOUR COMPANY LOGO
-----------------
Put your logo here as logo.dds to replace the placeholder.
It shows on the Overview tab's company card and on the Company Logo Sign
(construction menu, Contractor tab).

SIGN DESIGNS
------------
Put images in the signs folder next to this file. Each one becomes a design
you can pick for the Custom Sign (construction menu, Contractor tab) when
you place it. The file name is the design's name: "for_sale.dds" is offered
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
- Your logo shows only on your own farm's Company Logo Signs. Everyone
  else's show the placeholder.
- The Custom Sign is single-player only. In multiplayer it isn't in the
  construction menu, and any already placed show the company logo. If such
  a save is saved in multiplayer, those signs keep the company logo after.
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
    if fileExists(path) or createFile == nil or fileWrite == nil or FileAccess == nil then
        return
    end
    local file = createFile(path, FileAccess.WRITE)
    if file == nil or file == 0 then
        return
    end
    fileWrite(file, (TCCompanyLogo.README_TEXT:gsub("\r?\n", "\r\n")))
    delete(file)
end

function TCCompanyLogo.getFilename()
    local dir = TCCompanyLogo.settingsDir
    if dir ~= nil and fileExists(dir .. TCCompanyLogo.CUSTOM_FILENAME) then
        return dir .. TCCompanyLogo.CUSTOM_FILENAME
    end
    return TCCompanyLogo.getDefaultFilename()
end

function TCCompanyLogo.getDefaultFilename()
    return Utils.getFilename(TCCompanyLogo.DEFAULT_FILENAME, TheContractor.dir)
end
