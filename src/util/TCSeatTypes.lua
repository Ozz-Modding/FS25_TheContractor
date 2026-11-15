-- Seat spot chair types (153). Each is one option of the seat spot's
-- tcSeatType configuration (xml/seatSpot.xml names them by saveId) and says
-- which base-game model to show and how someone sits on it.
--
-- Everything is relative to the spot's stand node: on the ground, facing
-- its +Z (the arrow). Positions in metres, rotations in degrees (as an i3d
-- writes them).
--   filename: the base game's model, loaded from $data (never shipped).
--   part: the model's node below the file's top node, as an index path
--     ("4": its fifth child), for a file holding several props; nil for
--     the whole top node.
--   collision: the model has its own static collision.
--   model: where the model sits.
--   seat: the sitter's root (VehicleCharacter's characterNode parent,
--     FS25_garageContractor's player_root); skin, where the model hangs
--     from (player_skin); targets: the arm and foot IK chains' targets,
--     each relative to the seat. poseId: the hand's pose (vanilla's
--     wideFingers/flatFingers).
--   spineOffset: added to VehicleCharacter.SPINE_ROTATION (radians), or nil.
--
-- The lobby armchair's sitting is FS25_garageContractor's lobbyArmchair
-- (the same base-game model); the wooden chair's hands rest on the thighs
-- (it has no arms) and the rocking chair sits upright as the armchair does,
-- forward of its backrest, its hands on the front of its arms. All three
-- were checked in game (2026-11-15).

TCSeatTypes = {}

-- The order they're offered in is the xml's.
TCSeatTypes.TYPES = {
    woodenChair = {
        filename = "$data/maps/mapEU/textures/props/woodenChair.i3d",
        collision = true,
        model = { pos = { 0, 0, 0 }, rot = { 0, 0, 0 } },
        seat = { pos = { 0, 0.47, 0 }, rot = { -5.873, 0, 0 } },
        skin = { pos = { 0, 0.0114, -0.104 }, rot = { -3.591, 0, 0 } },
        targets = {
            leftFoot = { pos = { 0.173, -0.5, 0.341 }, rot = { 5.984, 0, 0 } },
            rightFoot = { pos = { -0.173, -0.5, 0.34 }, rot = { 5.984, 0, 0 } },
            leftArm = { pos = { 0.13, 0.18, 0.29 }, rot = { -142.878, -65.401, 141.37 }, poseId = "wideFingers" },
            rightArm = { pos = { -0.13, 0.18, 0.29 }, rot = { -135.163, 70.182, -132.483 }, poseId = "wideFingers" },
        },
    },
    rockingChair = {
        filename = "$data/maps/mapUS/textures/props/rockingChair.i3d",
        collision = true,
        model = { pos = { 0, 0, 0 }, rot = { 0, 0, 0 } },
        seat = { pos = { 0, 0.45, 0.04 }, rot = { 0, 0, 0 } },
        skin = { pos = { 0, 0.011, -0.088 }, rot = { 1.385, 0, 0 } },
        targets = {
            leftFoot = { pos = { 0.173, -0.45, 0.38 }, rot = { 1.922, 0, 0 } },
            rightFoot = { pos = { -0.173, -0.45, 0.38 }, rot = { 2.897, 0, 0 } },
            leftArm = { pos = { 0.41, 0.4, 0.24 }, rot = { -90, -90, 90 }, poseId = "wideFingers" },
            rightArm = { pos = { -0.41, 0.4, 0.24 }, rot = { 90, 86.135, 90 }, poseId = "wideFingers" },
        },
    },
    lobbyArmchair = {
        filename = "$data/maps/mapUS/textures/props/vehicleTraderLobby.i3d",
        part = "4",
        collision = false,
        model = { pos = { 0, 0, 0 }, rot = { 0, 0, 0 } },
        seat = { pos = { 0, 0.445, 0 }, rot = { 0, 0, 0 } },
        skin = { pos = { 0, 0.011, -0.088 }, rot = { 1.385, 0, 0 } },
        targets = {
            leftFoot = { pos = { 0.173, -0.436, 0.349 }, rot = { 1.922, 0, 0 } },
            rightFoot = { pos = { -0.173, -0.429, 0.349 }, rot = { 2.897, 0, 0 } },
            leftArm = { pos = { 0.377, 0.312, 0.275 }, rot = { -90, -90, 90 }, poseId = "wideFingers" },
            rightArm = { pos = { -0.367, 0.319, 0.279 }, rot = { 90, 86.135, 90 }, poseId = "wideFingers" },
        },
    },
}

-- The IK chains a type gives targets for: all four, always.
TCSeatTypes.CHAINS = { "leftFoot", "rightFoot", "leftArm", "rightArm" }

-- A type by its configuration's saveId, or nil.
function TCSeatTypes.get(key)
    if key == nil then
        return nil
    end
    return TCSeatTypes.TYPES[key]
end
