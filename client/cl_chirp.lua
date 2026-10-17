-- =========================================================================
--  tChirp — park-kill detection and chirp playback (client)
-- =========================================================================

local log = tlib.logger.create('tChirp')

if not tchirpConfigValid then
    log('not starting: config.lua has errors, listed above', tlib.logger.ERROR)
    return
end

if Config.debug then tlib.logger.setLevel(tlib.logger.DEBUG) end

local occupancy = tlib.occupancy

--- How often the player's seat and siren are read, and how often the playback
--- loop below checks what is due. Lowering it costs a frame budget on every
--- client for a fresher siren snapshot the ELS's own park-kill timing already
--- bounds; raising it widens the park-kill snapshot window below by as much.
local POLL_MS = 500

-- ── Model lookup ──────────────────────────────────────────────────────────
-- Hashed once at load so the per-park check is one table index rather than a
-- string compare per configured model.

local chirpHashes = {}
for model in pairs(Config.chirpAssignments) do
    chirpHashes[GetHashKey(model)] = model
end

local function chirpConfigFor(vehicle)
    if not DoesEntityExist(vehicle) then return nil end
    local model = chirpHashes[GetEntityModel(vehicle)]
    return model and Config.chirpAssignments[model] or nil
end

-- ── The list of parked vehicles, as the server sees it ────────────────────

local chirpVehicles = {}   -- netId → { soundCfg = { sound, ref } }
local chirpNextTime = {}   -- netId → GetGameTimer() ms of its next chirp
local activeSounds = {}    -- netId → sound id currently playing

--- Stop and release whatever this vehicle is sounding.
---
--- `expected` guards a double release. A chirp's stop is scheduled on its own
--- thread, and the sync event can clear the same entry while that thread is
--- waiting; without the identity check both would call ReleaseSoundId on the
--- same id, which is the one way to hand a freed id back twice and have a later,
--- unrelated chirp stopped by whoever is issued it next.
local function stopChirp(netId, expected)
    local soundId = activeSounds[netId]
    if not soundId then return end
    if expected ~= nil and soundId ~= expected then return end
    StopSound(soundId)
    ReleaseSoundId(soundId)
    activeSounds[netId] = nil
end

local function nextInterval()
    return math.random(Config.chirpMinIntervalMs, Config.chirpMaxIntervalMs)
end

RegisterNetEvent('tchirp:SyncChirpList', function(list)
    if type(list) ~= 'table' then return end

    for netId in pairs(chirpNextTime) do
        if not list[netId] then
            chirpNextTime[netId] = nil
            stopChirp(netId)
            TriggerEvent('tchirp:cleared', netId)
        end
    end

    local now = GetGameTimer()
    for netId in pairs(list) do
        if not chirpNextTime[netId] then
            chirpNextTime[netId] = now + nextInterval()
            TriggerEvent('tchirp:armed', netId)
        end
    end

    chirpVehicles = list

    local count = 0
    for _ in pairs(chirpVehicles) do count = count + 1 end
    log(('chirp list synced — %d vehicle(s)'):format(count), tlib.logger.DEBUG)
end)

-- ── Park-kill detection ───────────────────────────────────────────────────
--
-- ⚠️ THE SIREN IS READ ON THE TICK BEFORE THE EXIT, NOT AFTER IT.
--
-- Killing the siren is PART of a park kill: by the time the player is out of the
-- seat, every provider correctly reports the siren as off. Checking then would
-- return false every single time and nothing would ever chirp. So each tick
-- snapshots the siren while the player is still seated, and the exit is decided
-- against the previous tick's snapshot.
--
-- The cost of that is stated plainly in the docs: a siren switched off by hand
-- and then left within the same 500 ms window still counts as a park kill.

local lastVehicle, lastNetId = nil, nil
local lastSirenOn = false

local function onFrontSeatLeft(vehicle, sirenWasOn)
    if not sirenWasOn then return end

    local cfg = chirpConfigFor(vehicle)
    if not cfg then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not netId or netId == 0 then return end

    log(('park kill — vehicle %d (netId %d, sound %s)'):format(vehicle, netId, cfg.sound),
        tlib.logger.DEBUG)
    TriggerServerEvent('tchirp:AddChirpVehicle', netId, cfg)
end

local function onFrontSeatTaken(netId)
    if not netId or not chirpVehicles[netId] then return end
    log(('front seat taken in chirping vehicle %d — clearing'):format(netId), tlib.logger.DEBUG)
    TriggerServerEvent('tchirp:RemoveChirpVehicle', netId)
    chirpNextTime[netId] = nil
    stopChirp(netId)
end

CreateThread(function()
    TriggerServerEvent('tchirp:RequestChirpList')
    Wait(1000)

    while true do
        Wait(POLL_MS)

        -- occupancy's documented shape for a consumer that already has a loop:
        -- poll it from that loop rather than asking it to spawn a second thread.
        occupancy.poll()
        local vehicle, netId = occupancy.myVehicle()

        if lastVehicle and vehicle ~= lastVehicle then
            onFrontSeatLeft(lastVehicle, lastSirenOn)
            tchirpClearSirenCache()
        end

        -- Not `elseif`, and not gated on having been on foot a tick ago.
        -- Stepping straight out of one cruiser into another is a single tick, so
        -- requiring a 0 → vehicle transition here would leave the second car
        -- chirping with a driver sitting in it. So would getting in before the
        -- list had synced, which is the common case on a busy server.
        if netId and netId ~= lastNetId then
            onFrontSeatTaken(netId)
        end

        -- Snapshot LAST, so everything above read the previous tick.
        lastSirenOn = (vehicle ~= nil) and tchirpIsSirenActive(vehicle) or false
        lastVehicle, lastNetId = vehicle, netId
    end
end)

-- ── Playback ──────────────────────────────────────────────────────────────
--
-- Every client runs this for every parked vehicle in the list, because
-- PlaySoundFromEntity is local: the sound is positional in each listener's own
-- world, and a server that emitted it once would emit it for nobody.

--- Is anyone in a position to have already noticed? The mirror of the front-seat
--- rule the park-kill trigger uses. A car with somebody in a front seat is not
--- reminding anybody of anything, so it stays quiet even if the list has not yet
--- caught up — which it will not have, for the tick between someone sitting down
--- and the server's broadcast arriving.
local function frontSeatsEmpty(vehicle)
    return GetPedInVehicleSeat(vehicle, occupancy.SEAT_DRIVER) == 0
        and GetPedInVehicleSeat(vehicle, occupancy.SEAT_PASSENGER) == 0
end

CreateThread(function()
    while true do
        Wait(POLL_MS)

        local now = GetGameTimer()

        for netId, entry in pairs(chirpVehicles) do
            local due = chirpNextTime[netId]
            local cfg = entry and entry.soundCfg

            if due and now >= due and cfg and cfg.sound then
                local vehicle = NetworkGetEntityFromNetworkId(netId)

                if vehicle ~= 0 and DoesEntityExist(vehicle) and frontSeatsEmpty(vehicle) then
                    -- Rescheduled before the sound is started, so a chirp that
                    -- throws cannot leave the entry due forever.
                    chirpNextTime[netId] = now + nextInterval()

                    local soundId = GetSoundId()
                    activeSounds[netId] = soundId
                    PlaySoundFromEntity(soundId, cfg.sound, vehicle, cfg.ref or 0, 0, 0)

                    log(('chirp — netId %d, sound %s'):format(netId, cfg.sound), tlib.logger.DEBUG)

                    -- Its own thread, not a Wait() in this loop. Waiting here
                    -- would hold the whole list for the length of the chirp, so
                    -- with three cars parked the second and third would each slip
                    -- a chirp-length past their own timer, every round. Two cars
                    -- in a lot are meant to chirp independently.
                    CreateThread(function()
                        Wait(math.random(Config.chirpMinDurationMs, Config.chirpMaxDurationMs))
                        stopChirp(netId, soundId)
                    end)
                end
            end
        end
    end
end)

-- ── Readers for the /tchirp dialog ────────────────────────────────────────
--
-- client/cl_menu.lua answers off the same tables the chirp loop runs on, rather
-- than a second copy.
--
-- Globals rather than exports: exports cross resources, and nothing outside
-- tChirp needs these. `IsChirping` below is the cross-resource surface and is
-- unchanged.

--- The chirp assignment for a vehicle, or nil if its model is not configured.
function tchirpAssignmentFor(vehicle)
    return chirpConfigFor(vehicle)
end

--- How many vehicles are on the park-kill list, as this client last heard it.
function tchirpChirpingCount()
    local count = 0
    for _ in pairs(chirpVehicles) do count = count + 1 end
    return count
end

--- The nearest chirping vehicle within `maxDistance`, from where the player is.
---
--- Walks the list rather than the world, so it only considers cars the server
--- has actually armed. A netId whose entity is not streamed in here is skipped:
--- `NetworkGetEntityFromNetworkId` answers 0 for those, and treating 0 as an
--- entity is how a "nearest" search returns the player's own feet.
---
--- @return netId|nil, vehicle|nil, distance|nil
function tchirpNearestChirping(maxDistance)
    local origin = GetEntityCoords(PlayerPedId())
    local best, bestVeh, bestDist = nil, nil, tonumber(maxDistance) or 50.0

    for netId in pairs(chirpVehicles) do
        local vehicle = NetworkGetEntityFromNetworkId(netId)
        if vehicle ~= 0 and DoesEntityExist(vehicle) then
            local d = #(origin - GetEntityCoords(vehicle))
            if d <= bestDist then
                best, bestVeh, bestDist = netId, vehicle, d
            end
        end
    end

    if not best then return nil end
    return best, bestVeh, bestDist
end

--- Take a vehicle off the park-kill list.
---
--- The SAME event a front seat being taken sends (`onFrontSeatTaken` above), to
--- which the server deliberately applies no ownership check — see
--- `tchirp:RemoveChirpVehicle` in server/sv_chirp.lua.
---
--- The local entry is cleared optimistically and the sound stopped at once, for
--- the same reason the seat path does it: the broadcast is a round trip away and
--- a button that takes 100 ms to go quiet reads as a button that did nothing.
function tchirpSilence(netId)
    if type(netId) ~= 'number' or not chirpVehicles[netId] then return false end
    TriggerServerEvent('tchirp:RemoveChirpVehicle', netId)
    chirpNextTime[netId] = nil
    stopChirp(netId)
    return true
end

-- ── Exports ───────────────────────────────────────────────────────────────

-- Registered through tlib.platform.wrapExport, the house call site for an
-- export, so these move with it if it ever grows behaviour. It is NOT a throw
-- guard today -- on FiveM it is literally `exports(name, fn)`. What actually
-- keeps a raising third-party ELS from escaping IsSirenActive as an `undefined`
-- return is the `pcall` in cl_sirens.lua's askExport, one layer down.

--- Is this vehicle currently on the park-kill chirp list?
tlib.platform.wrapExport('tChirp', 'IsChirping', function(vehicle)
    if not vehicle or vehicle == 0 then return false end
    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    return (netId and netId ~= 0 and chirpVehicles[netId]) and true or false
end)

--- The provider cascade, for any resource that wants the same answer tChirp
--- acts on. Exported rather than kept private because "was this car's siren on,
--- whatever ELS this server runs" is the genuinely reusable half of tChirp, and
--- the alternative for a consumer is a second copy of the cascade.
tlib.platform.wrapExport('tChirp', 'IsSirenActive', function(vehicle)
    return tchirpIsSirenActive(vehicle)
end)

-- ── Cleanup ───────────────────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for netId in pairs(activeSounds) do stopChirp(netId) end
end)

log('client ready', tlib.logger.DEBUG)
