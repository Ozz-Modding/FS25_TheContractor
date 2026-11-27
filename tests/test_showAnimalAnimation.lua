-- 182: the show's penned animals, alive (TCShowAnimalAnimation): a visual's
-- entry found in its type's config by its model file, its files found
-- where they are (the config's own directory first: RL's sheep), the
-- config's index paths read, and the clip picked: the idle state's, else
-- by name.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCShowAnimalAnimation.lua")
    return world
end

-- As Utils.getFilename: a $ path stays, anything else is under base.
local function resolve(path, base)
    if string.sub(path, 1, 1) == "$" then
        return path
    end
    return (base or "") .. path
end

-- A file system holding these files.
local function filesOf(list)
    local files = {}
    for _, filename in ipairs(list) do
        files[filename] = true
    end
    return function(filename)
        return files[filename] == true
    end
end

local GAME = "$dataS/character/animals/domesticated/"

test("the game's own animals: $ paths taken as they are", function()
    setup()
    local entries = {
        { filename = GAME .. "horse/horse.i3d", animation = GAME .. "horse/animations/horseAnimations.i3d",
            skeletonIndex = "0>0", meshIndex = "1", proxyIndex = "2", locomotion = GAME .. "horse/locomotion.xml" },
    }
    local asset = TCShowAnimalAnimation.findAsset(entries, "dataS/character/animals/domesticated/horse/horse.i3d",
        resolve, "data/placeables/animals/", filesOf({}))
    assertEquals(asset.filename, GAME .. "horse/horse.i3d")
    assertEquals(asset.animation, GAME .. "horse/animations/horseAnimations.i3d")
    assertEquals(asset.locomotion, GAME .. "horse/locomotion.xml")
    assertEquals(asset.skeletonIndex, "0|0", "the config's > read as I3DUtil's |")
    assertEquals(asset.meshIndex, "1")
    assertEquals(asset.proxyIndex, "2")
end)

test("RL's sheep: the model beside its config, not where RL's visual says", function()
    setup()
    local mod = "C:/mods/FS25_RealisticLivestockRM/"
    local configDirectory = mod .. "animals/domesticated/sheep/"
    local entries = {
        { filename = "sheepEwe.i3d", animation = GAME .. "sheep/animations/adult/sheepAdultAnimations.i3d",
            skeletonIndex = "0", meshIndex = "1", proxyIndex = "2" },
    }
    -- RL hands the animal system the model under its mod's root, where it isn't.
    local asset = TCShowAnimalAnimation.findAsset(entries, mod .. "sheepEwe.i3d", resolve, configDirectory,
        filesOf({ configDirectory .. "sheepEwe.i3d" }))
    assertEquals(asset.filename, configDirectory .. "sheepEwe.i3d")
    assertEquals(asset.base, configDirectory)
    assertEquals(asset.animation, GAME .. "sheep/animations/adult/sheepAdultAnimations.i3d")

    -- A model nowhere to be found: posed.
    assertEquals(TCShowAnimalAnimation.findAsset(entries, mod .. "sheepEwe.i3d", resolve, configDirectory,
        filesOf({})), nil)
end)

test("a relative model and animation: the config's directory, else the visual's, else the visual's own file", function()
    setup()
    local entries = {
        { filename = "holstein/cattleHolstein.i3d", animation = "animations/cattleAnimations.i3d",
            skeletonIndex = "0", locomotion = "locomotion.xml" },
    }
    local visual = "C:/maps/myMap/animals/cow/holstein/cattleHolstein.i3d"
    -- Where the visual says (the config's somewhere else).
    local asset = TCShowAnimalAnimation.findAsset(entries, visual, resolve, "C:/maps/myMap/xml/",
        filesOf({ visual, "C:/maps/myMap/animals/cow/animations/cattleAnimations.i3d" }))
    assertEquals(asset.filename, visual)
    assertEquals(asset.animation, "C:/maps/myMap/animals/cow/animations/cattleAnimations.i3d")
    assertEquals(asset.locomotion, nil, "no locomotion file: the clip's found by name")
    -- No animation file anywhere: posed.
    assertEquals(TCShowAnimalAnimation.findAsset(entries, visual, resolve, "C:/maps/myMap/xml/", filesOf({ visual })),
        nil)
end)

test("no entry for a model the config doesn't have, or one with no animation or skeleton", function()
    setup()
    local exists = filesOf({})
    local entries = { { filename = "$dataS/a/cow.i3d", animation = "$dataS/a/anim.i3d", skeletonIndex = "0" } }
    assertEquals(TCShowAnimalAnimation.findAsset(entries, "dataS/a/pig.i3d", resolve, nil, exists), nil)
    assertEquals(TCShowAnimalAnimation.findAsset(entries, nil, resolve, nil, exists), nil)
    assertEquals(TCShowAnimalAnimation.findAsset({ { filename = "$dataS/a/cow.i3d", skeletonIndex = "0" } },
        "dataS/a/cow.i3d", resolve, nil, exists), nil, "no animation")
    assertEquals(TCShowAnimalAnimation.findAsset({ { filename = "$dataS/a/cow.i3d", animation = "$dataS/a/anim.i3d" } },
        "dataS/a/cow.i3d", resolve, nil, exists), nil, "no skeleton")
    assertTrue(TCShowAnimalAnimation.findAsset(entries, "dataS/a/cow.i3d", resolve, nil, exists) ~= nil)
    assertEquals(TCShowAnimalAnimation.toIndexPath(""), nil)
end)

test("the clip looped: the idle state's first the set has, else by name, else the first", function()
    setup()
    local names = { [0] = "walk", [1] = "chewSource", [2] = "cowIdle02", [3] = "cowIdle01" }
    assertEquals(TCShowAnimalAnimation.pickClip(names, 4, { "missing", "cowIdle01" }), 3, "the idle state's")
    assertEquals(TCShowAnimalAnimation.pickClip(names, 4, {}), 2, "by name: idle")
    assertEquals(TCShowAnimalAnimation.pickClip({ [0] = "walk", [1] = "chewSource", [2] = "standUp" }, 3), 1,
        "chewing before standing up")
    assertEquals(TCShowAnimalAnimation.pickClip({ [0] = "walk", [1] = "run" }, 2), 0)
    assertEquals(TCShowAnimalAnimation.pickClip({}, 0, { "idle" }), nil)
end)
