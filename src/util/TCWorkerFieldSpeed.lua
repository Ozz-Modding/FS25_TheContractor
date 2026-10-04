-- Worker field speed (046): a hired worker drives their AI Helper below the
-- equipment's own working speed, by their workSpeed - a slowest worker at
-- MIN_FIELD_SPEED_FACTOR of it, a fastest at the full speed.
--
-- Vanilla already works out "the slowest implement": AIFieldWorker caps its
-- maxSpeed with vehicle:getSpeedLimit(true), the lowest working speed limit
-- across the vehicle and everything attached (math.huge while nothing is
-- working). We cap it again at that limit times the worker's factor, at the
-- one place the AI turns maxSpeed into a motor limit -
-- AIVehicleUtil.driveToPoint (a class-level hook, same as
-- TCFreezeNPCFieldwork's FieldManager patches). Turns already run well under
-- the working speed, so in practice only the straight work slows down.
--
-- Deliberately not done through the vehicle's cruise control speed (the
-- other cap driveToPoint applies): vanilla saves that per vehicle and the
-- player drives with it, so it would leak out of our jobs. This keeps no
-- state of its own - the factor sits on our AIJob instance
-- (aiJob.tcFieldSpeedFactor, set by TheContractorDispatch:startAIJob), so
-- it's gone with the job, and any re-dispatch (after load, a watchdog
-- retry, a supplies restart) works it out again. AI driving is server-only,
-- and clients just see the vehicle move, so nothing needs syncing.

TCWorkerFieldSpeed = {}

TCWorkerFieldSpeed.MIN_FIELD_SPEED_FACTOR = 0.7

-- The factor for a job's operator - nil (player-driven) is full speed, see
-- TheContractorWorker.PLAYER_WORK_SPEED.
function TCWorkerFieldSpeed.getFactor(worker)
    return TheContractorWorker.scaleBySpeed(worker, TCWorkerFieldSpeed.MIN_FIELD_SPEED_FACTOR, 1)
end

function TCWorkerFieldSpeed.driveToPoint(vehicle, superFunc, dt, acceleration, allowedToDrive, moveForwards, tX, tZ,
                                         maxSpeed, doNotSteer)
    local aiJob = vehicle.getJob ~= nil and vehicle:getJob() or nil
    local factor = aiJob ~= nil and aiJob.tcFieldSpeedFactor or nil
    if factor ~= nil and factor < 1 and maxSpeed ~= nil then
        local workingLimit = vehicle:getSpeedLimit(true)
        if workingLimit ~= math.huge then
            maxSpeed = math.min(maxSpeed, workingLimit * factor)
        end
    end

    return superFunc(vehicle, dt, acceleration, allowedToDrive, moveForwards, tX, tZ, maxSpeed, doNotSteer)
end

AIVehicleUtil.driveToPoint = Utils.overwrittenFunction(AIVehicleUtil.driveToPoint, TCWorkerFieldSpeed.driveToPoint)
