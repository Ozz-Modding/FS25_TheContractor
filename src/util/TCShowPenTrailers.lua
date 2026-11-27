-- The show's pens (182), on a machine with a client: an animal standing in
-- its pen isn't also seen in its trailer. The animal never leaves the
-- trailer (166: vanilla's or RL's systems keep it), so its look there,
-- vanilla's LivestockTrailer slot mesh (updateAnimals: a posed model a
-- slot, the clusters' animals in turn), is hidden while ShowLivestock's
-- synced pen says it's penned from that trailer, and shown again when it
-- isn't. Looked at every CHECK_MS, since the trailer rebuilds its meshes
-- whenever its animals change. Which slot is which: TCShowPens.matchSlots,
-- an RL animal by its key, a vanilla one by its subtype and age.
--
-- Nothing's kept but the meshes hidden: never saved or synced (every client
-- works it out from the pens).

TCShowPenTrailers = {}

TCShowPenTrailers.CHECK_MS = 500

-- hidden[mesh node] = true, the meshes this machine has hidden.
TCShowPenTrailers.hidden = {}
TCShowPenTrailers.timer = 0

-- The trailer's slot meshes, in slot order, for its animals' type (nil if
-- it isn't showing any).
local function getSlots(trailer)
    local spec = trailer.spec_livestockTrailer
    if spec == nil or spec.animalTypeIndexToPlaces == nil or type(trailer.getCurrentAnimalType) ~= "function" then
        return nil
    end
    local animalType = trailer:getCurrentAnimalType()
    local place = animalType ~= nil and spec.animalTypeIndexToPlaces[animalType.typeIndex] or nil
    return place ~= nil and place.slots or nil
end

-- The trailer's clusters as matchSlots reads them.
local function readClusters(trailer)
    local clusters = {}
    local animalSystem = g_currentMission.animalSystem
    for _, cluster in ipairs(trailer:getClusters() or {}) do
        local read = TCShowAnimals.readCluster(animalSystem, cluster)
        table.insert(clusters, {
            subTypeName = read ~= nil and read.subTypeName or nil,
            age = read ~= nil and read.age or nil,
            count = read ~= nil and read.count or 0,
            key = read ~= nil and read.animal ~= nil and read.animal.key or nil,
        })
    end
    return clusters
end

-- Every frame: the penned animals' meshes hidden, the others shown.
function TCShowPenTrailers.update(dt)
    TCShowPenTrailers.timer = TCShowPenTrailers.timer - dt
    if TCShowPenTrailers.timer > 0 then
        return
    end
    TCShowPenTrailers.timer = TCShowPenTrailers.CHECK_MS
    local tc = g_currentMission.TheContractor
    local livestock = tc ~= nil and tc.ShowLivestock or nil
    -- The present pens by trailer.
    local byTrailer = {}
    for _, pen in ipairs(livestock ~= nil and livestock.pens or {}) do
        if pen.present and pen.trailerId ~= nil then
            local trailer = NetworkUtil.getObject(pen.trailerId)
            if TCShowAnimals.isTrailer(trailer) then
                byTrailer[trailer] = byTrailer[trailer] or {}
                table.insert(byTrailer[trailer], pen)
            end
        end
    end
    local hidden = {}
    for trailer, pens in pairs(byTrailer) do
        local slots = getSlots(trailer)
        if slots ~= nil then
            for _, index in ipairs(TCShowPens.matchSlots(readClusters(trailer), pens)) do
                local slot = slots[index]
                local mesh = slot ~= nil and slot.loadedMesh or nil
                if mesh ~= nil and entityExists(mesh) then
                    if getVisibility(mesh) then
                        setVisibility(mesh, false)
                    end
                    hidden[mesh] = true
                end
            end
        end
    end
    for mesh in pairs(TCShowPenTrailers.hidden) do
        if not hidden[mesh] and entityExists(mesh) then
            setVisibility(mesh, true)
        end
    end
    TCShowPenTrailers.hidden = hidden
end

-- deleteMap: everything shown again.
function TCShowPenTrailers.reset()
    for mesh in pairs(TCShowPenTrailers.hidden) do
        if entityExists(mesh) then
            setVisibility(mesh, true)
        end
    end
    TCShowPenTrailers.hidden = {}
    TCShowPenTrailers.timer = 0
end
