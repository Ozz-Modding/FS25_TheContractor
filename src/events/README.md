# Events

Multiplayer event convention for TheContractor, following the pattern already used across the user's other FS25 mods (RedTape, UsedEquipmentYards, EverythingConstructable, MoistureSystem, EconomyScale).

## Shape

Every event is its own file, one class per file, named `TC<Name>Event.lua`:

```lua
TCFooEvent = {}
local TCFooEvent_mt = Class(TCFooEvent, Event)

InitEventClass(TCFooEvent, "TCFooEvent")

function TCFooEvent.emptyNew()
    return Event.new(TCFooEvent_mt)
end

function TCFooEvent.new(...)
    local self = TCFooEvent.emptyNew()
    -- assign fields
    return self
end

function TCFooEvent:writeStream(streamId, connection)
    -- streamWrite* fields
end

function TCFooEvent:readStream(streamId, connection)
    -- streamRead* fields
    self:run(connection)
end

function TCFooEvent:run(connection)
    -- apply state / re-broadcast
end
```

`InitEventClass` is the base-game registration call (base game itself also uses `InitStaticEventClass` for some events, e.g. `AIJobStartEvent` — same role, different game-internal naming, not something we need to use ourselves).

Reactive events (fired in response to a single action — a job accepted, reputation changed, etc.) should be small and action-named, one concern per event, not a generic "state changed" blob.

## Initial client state

`TCInitialClientStateEvent` is the one aggregate event, sent once per joining connection. It doesn't carry its own fields — it delegates into each subsystem's `writeInitialClientState(streamId, connection)` / `readInitialClientState(streamId, connection)`, mirroring the subsystem split already used for save/load (`Reputation`, `Jobs`, `Staff`, and any subsystem added later).

Hooked via:

```lua
FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
    TheContractor.sendInitialClientState)
```

`TheContractor:sendInitialClientState(connection, user, farm)` just sends the event — it does not need the `Mission00`-fallback dance that `installSaveHook` uses, since RedTape's own equivalent hook doesn't need it either.

## Gotchas

- **`g_server:broadcastEvent()` does not loop back to the local client in single-player.** Server-side `run()` code must apply state directly (e.g. call into the subsystem), not rely on the broadcast round-trip to update the host's own state.
- **Never send raw node objects over the wire.** Use `NetworkUtil.getObjectId(object)` to write an object reference (as an int32) and `NetworkUtil.getObject(objectId)` to resolve it on receipt. Same goes for anything that isn't a plain value — no local string ids, no `uniqueId`.
- **During `TCInitialClientStateEvent` specifically, referenced objects may not be resolved yet** on the joining client (vehicles/placeables may still be streaming in). Defer resolution (store the id, resolve lazily on first use) rather than resolving immediately the way a reactive event can.
