-- tChirp — the parked-vehicle list (server)
--
-- The server owns which network IDs are on the chirp list and what each one
-- sounds like. It plays nothing: PlaySoundFromEntity is client-side, so every
-- client runs the playback against this list.

local log = tlib.logger.create('tChirp')

if not tchirpConfigValid then
    log('not starting: config.lua has errors, listed above', tlib.logger.ERROR)
    return
end

if Config.debug then tlib.logger.setLevel(tlib.logger.DEBUG) end

local chirpVehicles = {}

local function broadcast()
    TriggerClientEvent('tchirp:SyncChirpList', -1, chirpVehicles)
end

-- ⚠️ THE PAYLOAD ARRIVES FROM A PLACE A PLAYER CONTROLS. Trusting it means any
-- client can make any networked vehicle emit any sound it names.
--
-- The server never has to. `config.lua` is a shared_script, so the set of
-- (sound, ref) pairs this server configured is right here, closed and known
-- before a client says anything. A payload is honoured only if it is one of
-- them, so the worst a forged event does is pick another of the server's own
-- configured tones.

local allowedSounds = {}   -- "sound\0ref" → true
local assignmentsByModel = {}   -- model hash → { sound, ref }

local function soundKey(cfg)
    return ('%s\0%s'):format(tostring(cfg.sound), tostring(cfg.ref or 0))
end

for model, cfg in pairs(Config.chirpAssignments) do
    allowedSounds[soundKey(cfg)] = true
    assignmentsByModel[GetHashKey(model)] = cfg
end

--- The assignment this server would pick for a net ID, from the vehicle's model.
---
--- ⚠️ THREE ANSWERS, AND COLLAPSING TWO OF THEM IS A HOLE.
---
---   `cfg`           — resolved; this is the tone that model gets.
---   `nil, 'absent'` — real model, no assignment. REFUSE whatever tone was asked
---                     for. This returned a bare nil once, the caller fell
---                     through to the whitelist, and a `sultan` with the
---                     `police` tone was accepted — caught by
---                     scripts/tests/chirp-server.lua.
---   `nil, 'unknown'`— the entity is not in the server's view of the world, as a
---                     vehicle mid-ownership-migration briefly is not. Refusing
---                     would drop legitimate park kills, so the caller falls
---                     back to the whitelist: weaker, but still unable to
---                     introduce a sound this server never configured.
--- @return table|nil cfg, string|nil why
local function assignmentForNetId(netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'unknown' end
    local cfg = assignmentsByModel[GetEntityModel(entity)]
    if not cfg then return nil, 'absent' end
    return cfg
end

-- Both handlers broadcast the whole list to every client, so an unbounded event
-- is an amplification primitive whether or not its payload passes. The ceiling
-- is generous next to what a human can produce — parking a car takes seconds —
-- because this is a flood guard, not a gate.

local RATE_WINDOW_MS = 10000
local RATE_MAX = 12
local rate = {}

local function withinRate(src)
    local now = GetGameTimer()
    local bucket = rate[src]
    if not bucket or now - bucket.since >= RATE_WINDOW_MS then
        rate[src] = { since = now, count = 1 }
        return true
    end
    bucket.count = bucket.count + 1
    if bucket.count > RATE_MAX then
        -- One line per window, not per event: the point is to notice a flood, and
        -- a log line per dropped event IS the flood, moved to disk.
        if bucket.count == RATE_MAX + 1 then
            log(('player %d is sending chirp events faster than %d per %ds; dropping the rest')
                :format(src, RATE_MAX, RATE_WINDOW_MS / 1000), tlib.logger.WARN)
            -- Once per window, same reason as the log line. No player id in the
            -- code -- the code is the grouping key, and a per-player code makes
            -- every flood its own group of one.
            tlib.telemetry.warn('chirp.rate.exceeded', 'limit',
                ('a client exceeded %d chirp events per %ds'):format(RATE_MAX, RATE_WINDOW_MS / 1000))
        end
        return false
    end
    return true
end

AddEventHandler('playerDropped', function()
    rate[source] = nil
end)

RegisterNetEvent('tchirp:AddChirpVehicle', function(netId, soundCfg)
    local src = source

    if type(netId) ~= 'number' or netId <= 0 or netId % 1 ~= 0 then return end
    if type(soundCfg) ~= 'table' then return end
    if type(soundCfg.sound) ~= 'string' or soundCfg.sound == '' then return end
    if soundCfg.ref ~= nil and type(soundCfg.ref) ~= 'string' and type(soundCfg.ref) ~= 'number' then
        return
    end
    if not withinRate(src) then return end
    -- AFTER the shape checks and the rate floor: on a job- or item-gated server
    -- `tlib.access` reaches into a framework's core object or an inventory, and
    -- neither a malformed payload nor a flood should make the server do that.
    if not tchirpMayChirp(src) then return end
    if chirpVehicles[netId] then return end

    -- The strong check first: the model this server can see decides the tone. A
    -- client asking for a different one is refused rather than corrected,
    -- because a silent correction hides a misconfigured client from its owner.
    local expected, why = assignmentForNetId(netId)
    if expected then
        if soundKey(soundCfg) ~= soundKey(expected) then
            log(('player %d asked for sound "%s" on netId %d, whose model is assigned "%s" — refused')
                :format(src, tostring(soundCfg.sound), netId, tostring(expected.sound)),
                tlib.logger.WARN)
            -- The only one of this handler's three refusals that is a
            -- COMPATIBILITY warning: both sides have an assignment for the model
            -- and disagree, so one reloaded its config and the other did not.
            -- The other two are an owner's config not covering a model or a
            -- sound, which belongs in tchirp_diag. No sound name in the code --
            -- the code is the grouping key.
            tlib.telemetry.warn('chirp.assignment.mismatch', 'compatibility',
                'a client asked for a sound its model is not assigned; client and server configs disagree')
            return
        end
    elseif why == 'absent' then
        log(('player %d asked to chirp netId %d, whose model has no entry in Config.chirpAssignments — refused')
            :format(src, netId), tlib.logger.WARN)
        return
    elseif not allowedSounds[soundKey(soundCfg)] then
        log(('player %d asked for sound "%s", which is not in Config.chirpAssignments — refused')
            :format(src, tostring(soundCfg.sound)), tlib.logger.WARN)
        return
    end

    chirpVehicles[netId] = {
        soundCfg = { sound = soundCfg.sound, ref = soundCfg.ref or 0 },
        addedBy = src,
        addedTime = GetGameTimer(),
    }

    log(('added netId %d (player %d, sound %s)'):format(netId, src, soundCfg.sound),
        tlib.logger.DEBUG)
    broadcast()
end)

RegisterNetEvent('tchirp:RemoveChirpVehicle', function(netId)
    local src = source
    if type(netId) ~= 'number' or not chirpVehicles[netId] then return end
    if not withinRate(src) then return end

    -- Not restricted to the player who added it: the officer who parks the car
    -- and the officer who takes it out are routinely different people, so an
    -- ownership check leaves a car chirping under a driver sitting in it. A
    -- forged remove costs one chirp that stops early.
    chirpVehicles[netId] = nil
    log(('removed netId %d (player %d)'):format(netId, src), tlib.logger.DEBUG)
    broadcast()
end)

RegisterNetEvent('tchirp:RequestChirpList', function()
    TriggerClientEvent('tchirp:SyncChirpList', source, chirpVehicles)
end)

-- Sweeps vehicles that have been deleted or streamed out of existence. The grace
-- period keeps a fresh entry from being swept before the server's view of the
-- world has caught up with the client that reported the park.

CreateThread(function()
    local GRACE_MS = 5000

    while true do
        Wait(5000)

        local now = GetGameTimer()
        local stale = {}

        for netId, entry in pairs(chirpVehicles) do
            if now - (entry.addedTime or 0) >= GRACE_MS then
                local entity = NetworkGetEntityFromNetworkId(netId)
                if not entity or entity == 0 or not DoesEntityExist(entity) then
                    stale[#stale + 1] = netId
                end
            end
        end

        if #stale > 0 then
            for _, netId in ipairs(stale) do
                chirpVehicles[netId] = nil
                log(('swept stale netId %d'):format(netId), tlib.logger.DEBUG)
            end
            broadcast()
        end
    end
end)

-- Registered `restricted`, so FiveM's own ACE covers it: the console can always
-- run it and a player needs `command.tchirp_diag`.

tlib.diag.command({
    name = 'tchirp_diag',
    title = 'tChirp diagnostics',
    spec = tchirpConfigSpec,
    report = function(ctx)
        -- The boot snapshot, not the live table. Type-checked rather than
        -- called: a tLib without `configured` answers a plain nil.
        local configFns = tlib.config
        local configured = (type(configFns.configured) == 'function' and configFns.configured('config.lua'))
            or Config

        local parked = 0
        for _ in pairs(chirpVehicles) do parked = parked + 1 end

        ctx.line('tChirp %s — tLib %s', ctx.meta(GetCurrentResourceName()), ctx.meta('tLib'))
        -- The gate's own description, not a re-reading of Config.access, so the
        -- diagnostic cannot disagree with the decision.
        if type(tchirpAccessDescribe) == 'function' then
            ctx.line('who may chirp: %s', tchirpAccessDescribe())
        end
        ctx.line('siren provider: %s', tostring(configured.sirenSystem))
        ctx.line('interval %d-%d ms, duration %d-%d ms',
            configured.chirpMinIntervalMs, configured.chirpMaxIntervalMs,
            configured.chirpMinDurationMs, configured.chirpMaxDurationMs)
        ctx.line('%d model(s) configured, %d vehicle(s) currently chirping',
            ctx.count(Config.chirpAssignments), parked)

        ctx.messages(tlib.config.validate(configured, tchirpConfigSpec))
    end,
})

-- Fired from onResourceStart because sv_version.lua -- which subscribes these
-- events inside tlib.versioncheck -- loads after this file.

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local count = 0
    for _ in pairs(Config.chirpAssignments) do count = count + 1 end
    -- Zero is not a healthy count: an empty table boots clean and nothing ever
    -- chirps. It is also what an operator reaches by dropping the key while
    -- merging a shipped config forward, which the spec's `default = {}` keeps
    -- from killing the resource -- so the banner is the only place that
    -- difference can surface.
    TriggerEvent('tchirp:vcInfo:models', count == 0
        and { value = 'none configured — nothing will chirp. Add models to Config.chirpAssignments in config.lua.',
              color = '^3' }
        or ('%d vehicle model(s) configured'):format(count))
    TriggerEvent('tchirp:vcInfo:sirens', tostring(Config.sirenSystem))
end)
