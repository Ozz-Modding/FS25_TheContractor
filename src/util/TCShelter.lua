-- Shelter from the weather (155). While it's raining, snowing or hailing
-- (or a twister's through), people standing about go indoors: an outdoor
-- standing spot or seat is out of use, for our staff (065, 153) and the
-- farmers in their yards (114, 154) alike. Staff move to a free indoor
-- spot or go out of sight; a farmer picks among their yard's indoor spots,
-- or stays in. Nobody's moved while the player can see them: the usual
-- "wait until you look away" does that.
--
-- Wet or not is read from the weather's type, not its fall scales: the
-- forecast is synced, so every machine agrees (the scales fade in and out
-- on each machine's own clock). It's not polled: vanilla's WEATHER_CHANGED,
-- published on every machine as a new weather starts, sets it, with
-- HOUR_CHANGED as a backstop and a read at mission start.
--
-- Indoors is vanilla's indoor mask (g_currentMission.indoorMask), the one
-- that keeps a vehicle dry in a shed: painted by the map, and by a shed's
-- indoor areas as it's placed, the same on every machine. It's only asked
-- while it's wet.

TCShelter = {}

-- Whether people should be indoors now.
TCShelter.isWet = false

-- The WeatherType names that send people in.
TCShelter.WET_TYPE_NAMES = { "RAIN", "SNOW", "HAIL", "TWISTER" }

function TCShelter.isWetType(weatherType)
    if weatherType == nil or WeatherType == nil then
        return false
    end
    for _, name in ipairs(TCShelter.WET_TYPE_NAMES) do
        if WeatherType[name] ~= nil and WeatherType[name] == weatherType then
            return true
        end
    end
    return false
end

-- Sets isWet from the weather's current type (nothing if it's not ready).
function TCShelter.refresh()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local weather = environment ~= nil and environment.weather or nil
    if weather == nil or weather.getCurrentWeatherType == nil or
            (weather.getIsReady ~= nil and not weather:getIsReady()) then
        return
    end
    TCShelter.setWet(TCShelter.isWetType(weather:getCurrentWeatherType()))
end

function TCShelter.setWet(isWet)
    if TCShelter.isWet ~= isWet then
        TCShelter.isWet = isWet
        TCLog.info("TheContractor: weather turned %s, outdoor standing spots %s", isWet and "wet" or "dry",
            isWet and "out of use" or "back in use")
    end
end

function TCShelter.onWeatherChanged(_, weatherObject)
    if weatherObject ~= nil and weatherObject.weatherType ~= nil then
        TCShelter.setWet(TCShelter.isWetType(weatherObject.weatherType))
    else
        TCShelter.refresh()
    end
end

function TCShelter.onHourChanged()
    TCShelter.refresh()
end

-- loadMap (every machine).
function TCShelter.install()
    TCShelter.isWet = false
    g_messageCenter:subscribe(MessageType.WEATHER_CHANGED, TCShelter.onWeatherChanged, TCShelter)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, TCShelter.onHourChanged, TCShelter)
    TCShelter.refresh()
end

function TCShelter.uninstall()
    g_messageCenter:unsubscribeAll(TCShelter)
    TCShelter.isWet = false
end

-- Whether x, z is under cover by vanilla's indoor mask (outdoors on a map
-- without one).
function TCShelter.isIndoors(x, z)
    local mask = g_currentMission ~= nil and g_currentMission.indoorMask or nil
    if mask == nil or mask.getIsIndoorAtWorldPosition == nil then
        return false
    end
    return mask:getIsIndoorAtWorldPosition(x, z) == true
end

-- Whether someone may stand at x, z now: anywhere when it's dry, indoors
-- when it's wet.
function TCShelter.isUsable(x, z)
    return not TCShelter.isWet or TCShelter.isIndoors(x, z)
end
