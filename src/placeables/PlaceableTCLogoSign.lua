-- Logo sign (084): a board on two posts showing the company logo on both
-- faces. The faces' texture is swapped at load for TCCompanyLogo's file
-- (the player's logo in modSettings, else ours), the way vanilla's pallets
-- swap theirs (Pallet:onPostLoad).
--
-- The logo file is read on each machine, so in multiplayer a player's own
-- logo only goes on their own farm's signs; everyone else's show the
-- default. The swap is redone when the sign changes hands or the local
-- player changes farm. Visual only: nothing saved or streamed, vanilla
-- owns the placeable's saving, sync and ownership.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCLogoSign = {}

PlaceableTCLogoSign.KEY = "tcLogoSignData"

function PlaceableTCLogoSign.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCLogoSign.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCLogoSign")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".logoSign.face(?)#node",
        "Shape whose material's diffuse map becomes the company logo")
    schema:setXMLSpecializationType()
end

function PlaceableTCLogoSign.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "tcUpdateLogo", PlaceableTCLogoSign.tcUpdateLogo)
end

function PlaceableTCLogoSign.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCLogoSign)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCLogoSign)
    SpecializationUtil.registerEventListener(placeableType, "onOwnerChanged", PlaceableTCLogoSign)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTCLogoSign)
end

function PlaceableTCLogoSign:onLoad(savegame)
    local data = { faces = {}, filename = nil }
    self[PlaceableTCLogoSign.KEY] = data
    if not self.isClient then
        return
    end
    self.xmlFile:iterate("placeable.logoSign.face", function(_, key)
        local node = self.xmlFile:getValue(key .. "#node", nil, self.components, self.i3dMappings)
        if node ~= nil then
            -- The i3d's own material, kept so every swap starts from it.
            table.insert(data.faces, { node = node, baseMaterial = getMaterial(node, 0) })
        end
    end)
    if #data.faces == 0 then
        Logging.xmlWarning(self.xmlFile, "Logo sign has no logo faces")
        return
    end
    -- A construction preview is the player's own sign-to-be.
    self:tcUpdateLogo()
end

function PlaceableTCLogoSign:onFinalizePlacement()
    self:tcUpdateLogo()
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.tcUpdateLogo, self)
    g_messageCenter:subscribe(MessageType.PLAYER_CREATED, self.tcUpdateLogo, self)
end

function PlaceableTCLogoSign:onOwnerChanged()
    self:tcUpdateLogo()
end

function PlaceableTCLogoSign:onDelete()
    g_messageCenter:unsubscribeAll(self)
end

-- The file a sign should show: the player's logo on their own farm's signs
-- (and while placing one), the default on anyone else's.
function PlaceableTCLogoSign.getLogoFilename(ownerFarmId, localFarmId, isPreview)
    if isPreview or (ownerFarmId ~= nil and ownerFarmId == localFarmId) then
        return TCCompanyLogo.getFilename()
    end
    return TCCompanyLogo.getDefaultFilename()
end

function PlaceableTCLogoSign:tcUpdateLogo()
    local data = self[PlaceableTCLogoSign.KEY]
    if data == nil or #data.faces == 0 then
        return
    end
    local filename = PlaceableTCLogoSign.getLogoFilename(self:getOwnerFarmId(), g_currentMission:getFarmId(),
        self.propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW)
    if filename == data.filename then
        return
    end
    data.filename = filename
    for _, face in ipairs(data.faces) do
        local material = setMaterialDiffuseMapFromFile(face.baseMaterial, filename, true, true, false)
        setMaterial(face.node, material, 0)
    end
end
