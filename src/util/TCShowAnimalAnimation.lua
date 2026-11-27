-- The show's penned animals, alive (182): an animal in its pen plays its
-- idle animation instead of standing as the trailer's posed statue.
--
-- The animal system keeps only the posed model and the animated model's
-- file for a visual (visualAnimal.filenamePosed, .filename). The rest is in
-- its animal type's config XML (animalType.configFilename, as vanilla's
-- AnimalSystem:validateAnimalType reads it): each
-- animalHusbandry.animals.animal's assets (#filename the skinned model,
-- #animation an i3d holding the clips' character set, #skeletonIndex,
-- #meshIndex, #proxyIndex) and locomotion#filename, whose
-- locomotion.animation#filename is the animation XML naming each state's
-- clips. Cattle keep their mesh in one i3d and their clips in another, so a
-- model on its own has no character set: the clips are grafted on, as
-- FS25_AnimalSystemsForRLRM's AnimalVisualCache does it (the user pointed us
-- at it), which is where these rules come from:
--   - the animation file's skin node (its skeleton's first child) cloned
--     onto the model's (cloneAnimCharacterSet), else skeleton onto skeleton;
--   - a young animal's (skeletonIndex not "0": its mesh first, its skeleton
--     second) mesh moved to the end first, so the skeleton's child 0;
--   - the proxy at proxyIndex is the animal's collision: taken out of
--     physics here (these props are a client's own; a body only one machine
--     has would disagree with the server's);
--   - the animated mesh's dirt set clean with its tiling (0, 20, 20): nil
--     tiling smears one texel over the whole animal.
-- The clip looped is the animation XML's idle state's (its first clip the
-- character set has), else one found by name (pickClip), from a random
-- point so a row of pens isn't in step.
--
-- The config's entry for a visual is found by its model file (the one whose
-- assets#filename the visual's filename ends with), not by index, so a
-- mod's (RL's) own configs can't put the wrong one on; its other paths are
-- resolved against the same directory. Anything missing falls back: no
-- entry, the posed model (getAsset nil); no character set or clip, the
-- animated model standing still. Each animation file's clips and the one
-- picked are logged once, for tuning.
-- Machine-local, nothing saved or synced. The pure parts are tested in
-- tests/test_showAnimalAnimation.lua.

TCShowAnimalAnimation = {}

-- The animation XML's state looped, and the words a clip's name is looked
-- for by when it can't be read (lower case, in order).
TCShowAnimalAnimation.IDLE_STATE = "idle"
TCShowAnimalAnimation.CLIP_WORDS = { "idle", "chew", "stand" }
-- The animated mesh's dirt texture tiling (as the models author it).
TCShowAnimalAnimation.DIRT_TILING = 20

-- assets[visual filename] = asset (see findAsset) or false, read once a session.
TCShowAnimalAnimation.assets = {}
-- configs[config filename] = { entries } or false.
TCShowAnimalAnimation.configs = {}
-- idleClips[locomotion filename] = { names } (possibly empty).
TCShowAnimalAnimation.idleClips = {}
-- The animation files whose clips have been logged.
TCShowAnimalAnimation.logged = {}

-- An index path as the config writes it ("0>0|1") as I3DUtil reads it.
function TCShowAnimalAnimation.toIndexPath(index)
    if type(index) ~= "string" or index == "" then
        return nil
    end
    return (string.gsub(index, ">", "|"))
end

-- The config entry for a visual's model file (pure): entries { filename,
-- animation, skeletonIndex, meshIndex, proxyIndex, locomotion } as the
-- config has them (paths relative to the config's directory, or $ paths).
-- configDirectory: the config file's own directory. Returns { filename,
-- animation, locomotion, skeletonIndex, meshIndex, proxyIndex, base } or
-- nil. resolve(path, baseDirectory): Utils.getFilename; exists(filename):
-- fileExists.
--
-- Where its files are (locate): a relative path is tried against the
-- config's own directory first (where a mod keeps its models: RL's sheep
-- are beside its sheep config, though RL hands the animal system a path
-- under its mod's root that doesn't exist), then the directory the
-- visual's own filename gives, then (the model) the visual's filename as
-- it is; the first that exists. A $ path (the game's, in its archives,
-- which fileExists may not see) is taken as it is. No model or animation
-- file: nil, the posed model (a skinned model with no clips would stand
-- in its bind pose).
function TCShowAnimalAnimation.findAsset(entries, visualFilename, resolve, configDirectory, exists)
    if visualFilename == nil then
        return nil
    end
    local normalized = string.lower(string.gsub(visualFilename, "\\", "/"))
    for _, entry in ipairs(entries or {}) do
        local relative = entry.filename ~= nil and string.lower(string.gsub(entry.filename, "\\", "/")) or nil
        if relative ~= nil and entry.animation ~= nil and entry.skeletonIndex ~= nil then
            local tail = string.gsub(relative, "^%$[%a]+/", "")
            if #tail > 0 and string.sub(normalized, -#tail) == tail then
                local visualBase = string.sub(visualFilename, 1, #visualFilename - #tail)
                local bases = {}
                if configDirectory ~= nil then
                    table.insert(bases, configDirectory)
                end
                table.insert(bases, visualBase)
                local function locate(path, fallback)
                    if path == nil then
                        return nil
                    end
                    if string.sub(path, 1, 1) == "$" then
                        return resolve(path, nil)
                    end
                    for _, base in ipairs(bases) do
                        local candidate = resolve(path, base)
                        if exists(candidate) then
                            return candidate, base
                        end
                    end
                    if fallback ~= nil and exists(fallback) then
                        return fallback, visualBase
                    end
                    return nil
                end
                local filename, base = locate(entry.filename, visualFilename)
                local animation = locate(entry.animation)
                if filename == nil or animation == nil then
                    return nil
                end
                return {
                    filename = filename,
                    base = base or visualBase,
                    animation = animation,
                    locomotion = locate(entry.locomotion),
                    skeletonIndex = TCShowAnimalAnimation.toIndexPath(entry.skeletonIndex),
                    meshIndex = TCShowAnimalAnimation.toIndexPath(entry.meshIndex),
                    proxyIndex = TCShowAnimalAnimation.toIndexPath(entry.proxyIndex),
                }
            end
        end
    end
    return nil
end

-- The clip to loop (pure). idleNames: the idle state's clips from the
-- animation XML, tried in order; names: the character set's { [index] =
-- name } from 0, count of them. The first idle clip the set has, else the
-- first whose name has the first of CLIP_WORDS found, else the first clip.
-- Returns the clip index or nil with none.
function TCShowAnimalAnimation.pickClip(names, count, idleNames)
    if count == nil or count < 1 then
        return nil
    end
    for _, wanted in ipairs(idleNames or {}) do
        for index = 0, count - 1 do
            if names[index] == wanted then
                return index
            end
        end
    end
    for _, word in ipairs(TCShowAnimalAnimation.CLIP_WORDS) do
        for index = 0, count - 1 do
            local name = names[index]
            if name ~= nil and string.find(string.lower(name), word, 1, true) ~= nil then
                return index
            end
        end
    end
    return 0
end

-- Engine side -------------------------------------------------------------------------

local function getDirectory(filename)
    return string.match(filename, "^(.*[/\\])") or ""
end

-- An animal type's config entries, read once.
local function readConfig(configFilename)
    local cached = TCShowAnimalAnimation.configs[configFilename]
    if cached ~= nil then
        return cached or nil
    end
    local entries = false
    local xmlFile = configFilename ~= nil and loadXMLFile("tcShowAnimalConfig", configFilename) or nil
    if xmlFile ~= nil and xmlFile ~= 0 then
        entries = {}
        local i = 0
        while true do
            local key = string.format("animalHusbandry.animals.animal(%d)", i)
            if not hasXMLProperty(xmlFile, key .. ".assets") then
                break
            end
            table.insert(entries, {
                filename = getXMLString(xmlFile, key .. ".assets#filename"),
                animation = getXMLString(xmlFile, key .. ".assets#animation"),
                skeletonIndex = getXMLString(xmlFile, key .. ".assets#skeletonIndex"),
                meshIndex = getXMLString(xmlFile, key .. ".assets#meshIndex"),
                proxyIndex = getXMLString(xmlFile, key .. ".assets#proxyIndex"),
                locomotion = getXMLString(xmlFile, key .. ".locomotion#filename"),
            })
            i = i + 1
        end
        delete(xmlFile)
    end
    TCShowAnimalAnimation.configs[configFilename] = entries
    return entries or nil
end

-- The idle state's clip names in an asset's animation XML (through its
-- locomotion file), read once; empty if it can't be read.
function TCShowAnimalAnimation.getIdleClipNames(asset)
    local locomotion = asset.locomotion
    if locomotion == nil then
        return {}
    end
    local cached = TCShowAnimalAnimation.idleClips[locomotion]
    if cached ~= nil then
        return cached
    end
    local names = {}
    local locomotionXML = loadXMLFile("tcShowAnimalLocomotion", locomotion)
    if locomotionXML ~= nil and locomotionXML ~= 0 then
        local animationName = getXMLString(locomotionXML, "locomotion.animation#filename")
        delete(locomotionXML)
        if animationName ~= nil then
            -- Beside the locomotion file, else as the config's paths are.
            local animationFilename = Utils.getFilename(animationName, getDirectory(locomotion))
            if not fileExists(animationFilename) then
                animationFilename = Utils.getFilename(animationName, asset.base)
            end
            local animationXML = loadXMLFile("tcShowAnimalAnimation", animationFilename)
            if animationXML ~= nil and animationXML ~= 0 then
                local i = 0
                while hasXMLProperty(animationXML, string.format("animation.states.state(%d)", i)) do
                    local stateKey = string.format("animation.states.state(%d)", i)
                    if getXMLString(animationXML, stateKey .. "#id") == TCShowAnimalAnimation.IDLE_STATE then
                        local j = 0
                        while hasXMLProperty(animationXML, string.format("%s.animation(%d)", stateKey, j)) do
                            local clip = getXMLString(animationXML, string.format("%s.animation(%d)#clip", stateKey, j))
                            if clip ~= nil then
                                table.insert(names, clip)
                            end
                            j = j + 1
                        end
                    end
                    i = i + 1
                end
                delete(animationXML)
            end
        end
    end
    TCShowAnimalAnimation.idleClips[locomotion] = names
    return names
end

-- The animated asset for an animal prop's subtype (its type's config) and
-- visual animal, or nil (stay posed).
function TCShowAnimalAnimation.getAsset(subTypeName, visualAnimal)
    if visualAnimal == nil or visualAnimal.filename == nil then
        return nil
    end
    local cached = TCShowAnimalAnimation.assets[visualAnimal.filename]
    if cached ~= nil then
        return cached or nil
    end
    local asset = nil
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem ~= nil and animalSystem:getSubTypeByName(subTypeName) or nil
    local animalType = subType ~= nil and animalSystem:getTypeByIndex(subType.typeIndex) or nil
    if animalType ~= nil and animalType.configFilename ~= nil then
        asset = TCShowAnimalAnimation.findAsset(readConfig(animalType.configFilename), visualAnimal.filename,
            function(path, base)
                return Utils.getFilename(path, base)
            end, getDirectory(animalType.configFilename), function(filename)
                return filename ~= nil and fileExists(filename)
            end)
    end
    if asset == nil then
        TCLog.info("TheContractor: show animal %s has no animation found, shown posed", tostring(subTypeName))
    end
    TCShowAnimalAnimation.assets[visualAnimal.filename] = asset or false
    return asset
end

-- The animated model's loaded and placed (node: the whole file): its
-- collision proxy out of physics, a young animal's mesh moved behind its
-- skeleton, the mesh clean, and the animation file loaded to bring it to
-- life. entry: the prop's (checked when the animation lands, in case it's
-- gone). Keeps the model's skeleton on the entry for that.
function TCShowAnimalAnimation.start(node, asset, entry)
    -- Resolved before the shuffle below renumbers the children.
    local skeleton = I3DUtil.indexToObject(node, asset.skeletonIndex)
    local mesh = asset.meshIndex ~= nil and I3DUtil.indexToObject(node, asset.meshIndex) or nil
    local proxy = asset.proxyIndex ~= nil and I3DUtil.indexToObject(node, asset.proxyIndex) or nil
    if proxy ~= nil and proxy ~= 0 then
        removeFromPhysics(proxy)
    end
    if mesh == 0 then
        mesh = nil
    end
    if asset.skeletonIndex ~= "0" and mesh ~= nil then
        local temporary = createTransformGroup("tcShowAnimalShuffle")
        link(getRootNode(), temporary)
        link(temporary, mesh)
        link(node, mesh)
        delete(temporary)
    end
    if mesh ~= nil then
        local tiling = TCShowAnimalAnimation.DIRT_TILING
        I3DUtil.setShaderParameterRec(mesh, "dirt", 0, tiling, tiling, nil)
    end
    if skeleton == nil or skeleton == 0 or asset.animation == nil then
        return
    end
    entry.animalSkeleton = skeleton
    entry.animationRequestId = g_i3DManager:loadSharedI3DFileAsync(asset.animation, false, false,
        TCShowAnimalAnimation.onAnimationLoaded, nil, { node = node, asset = asset, entry = entry })
end

function TCShowAnimalAnimation.onAnimationLoaded(_, animRoot, failedReason, args)
    local entry, node, asset = args.entry, args.node, args.asset
    if animRoot == nil or animRoot == 0 then
        TCLog.warning("TheContractor: show animal animation '%s' could not be loaded", tostring(asset.animation))
        return
    end
    local skeleton = entry.animalSkeleton
    if entry.node ~= node or entry.dropped or not entityExists(node) or skeleton == nil or
            not entityExists(skeleton) then
        delete(animRoot)
        return
    end
    local sourceSkeleton = I3DUtil.indexToObject(animRoot, asset.skeletonIndex)
    if sourceSkeleton == nil or sourceSkeleton == 0 or getNumOfChildren(sourceSkeleton) == 0 or
            getNumOfChildren(skeleton) == 0 then
        TCLog.info("TheContractor: show animal animation '%s' has no skeleton at %s, left standing",
            tostring(asset.animation), tostring(asset.skeletonIndex))
        delete(animRoot)
        return
    end
    local sourceSkin, skin = getChildAt(sourceSkeleton, 0), getChildAt(skeleton, 0)
    local usesSkeleton = false
    local cloned = cloneAnimCharacterSet(sourceSkin, skin)
    if not cloned then
        cloned = cloneAnimCharacterSet(sourceSkeleton, skeleton)
        usesSkeleton = true
    end
    delete(animRoot)
    local charset = cloned and getAnimCharacterSet(usesSkeleton and skeleton or skin) or 0
    if charset == nil or charset == 0 then
        TCLog.info("TheContractor: show animal animation '%s' doesn't fit %s, left standing",
            tostring(asset.animation), tostring(asset.filename))
        return
    end
    local count = getAnimNumOfClips(charset)
    local names = {}
    for index = 0, count - 1 do
        names[index] = getAnimClipName(charset, index)
    end
    local idleNames = TCShowAnimalAnimation.getIdleClipNames(asset)
    local clip = TCShowAnimalAnimation.pickClip(names, count, idleNames)
    if not TCShowAnimalAnimation.logged[asset.animation] then
        TCShowAnimalAnimation.logged[asset.animation] = true
        local list = {}
        for index = 0, count - 1 do
            table.insert(list, tostring(names[index]))
        end
        TCLog.info("TheContractor: show animal animation %s: idle state %s, clips %s; looping %s",
            asset.animation, #idleNames > 0 and table.concat(idleNames, "/") or "(not read)",
            table.concat(list, ", "), clip ~= nil and tostring(names[clip]) or "none")
    end
    if clip == nil then
        return
    end
    clearAnimTrackClip(charset, 0)
    assignAnimTrackClip(charset, 0, clip)
    setAnimTrackLoopState(charset, 0, true)
    -- Each from its own point in the clip, so a row of pens isn't in step.
    local duration = getAnimClipDuration ~= nil and getAnimClipDuration(charset, clip) or 0
    if duration ~= nil and duration > 0 then
        setAnimTrackTime(charset, 0, math.random() * duration)
    end
    enableAnimTrack(charset, 0)
end

-- An animated model that wouldn't load: its visual shown posed from now on.
function TCShowAnimalAnimation.markFailed(visualAnimal, asset)
    if visualAnimal ~= nil and visualAnimal.filename ~= nil then
        TCShowAnimalAnimation.assets[visualAnimal.filename] = false
        TCLog.info("TheContractor: show animal model '%s' wouldn't load, shown posed", tostring(asset ~= nil and
            asset.filename or visualAnimal.filename))
    end
end

-- An animal prop going: its animation file's load given back.
function TCShowAnimalAnimation.release(entry)
    if entry.animationRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(entry.animationRequestId)
        entry.animationRequestId = nil
    end
    entry.animalSkeleton = nil
end

-- deleteMap: read again next session.
function TCShowAnimalAnimation.reset()
    TCShowAnimalAnimation.assets = {}
    TCShowAnimalAnimation.configs = {}
    TCShowAnimalAnimation.idleClips = {}
    TCShowAnimalAnimation.logged = {}
end
