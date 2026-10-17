-- =========================================================================
--  tChirp — the parked-vehicle list (server)
-- =========================================================================
--
--  The server owns one thing: which network IDs are currently on the chirp
--  list, and what each one sounds like. It plays nothing — PlaySoundFromEntity
--  is client-side, so every client runs the playback against this list.
-- =========================================================================

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

-- ── What a client is allowed to ask for ───────────────────────────────────
--
-- ⚠️ THE PAYLOAD ARRIVES FROM A PLACE A PLAYER CONTROLS. Trusting it means any
-- client can make any networked vehicle emit any sound it names.
--
-- The server already has the answer, so it never has to. `config.lua` is a
-- shared_script, so `Config.chirpAssignments` is right here: the set of
-- (sound, ref) pairs this server has configured is closed, small, and known
-- before any client says anything. A payload is honoured only if it is one of
-- them, so the worst a forged event can do is pick a different one of the
-- server's OWN configured tones.

local allowedSounds = {}   -- "sound\0ref" → true
local assignmentsByModel = {}   -- model hash → { sound, ref }

local function soundKey(cfg)
    return ('%s\0%s'):format(tostring(cfg.sound), tostring(cfg.ref or 0))
end

for model, cfg in pairs(Config.chirpAssignments) do
    allowedSounds[soundKey(cfg)] = true
    assignmentsByModel[GetHashKey(model)] = cfg
end

--- The assignment this server would pick for a net ID, resolved from the
--- vehicle's own model.
---
--- ⚠️ THREE ANSWERS, AND COLLAPSING TWO OF THEM IS A HOLE.
---
---   `cfg`           — resolved, and this is the tone that model gets.
---   `nil, 'absent'` — the model is real and has no assignment. REFUSE: an
---                     unconfigured model must never chirp, whatever tone was
---                     asked for. The first version of this function returned a
---                     bare nil here, the caller fell through to the whitelist,
---                     and a `sultan` with the `police` tone was accepted —
---                     `scripts/tests/chirp-server.lua` caught it.
---   `nil, 'unknown'`— the entity is not in the server's view of the world at
---                     all. `NetworkGetEntityFromNetworkId` answers from that
---                     view, and a vehicle whose owner is mid-migration is
---                     briefly not in it. Refusing here would drop legitimate
---                     park kills, so the caller falls back to the whitelist — a
---                     weaker check, but one that still cannot introduce a sound
---                     this server never configured.
--- @return table|nil cfg, string|nil why
local function assignmentForNetId(netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'unknown' end
    local cfg = assignmentsByModel[GetEntityModel(entity)]
    if not cfg then return nil, 'absent' end
    return cfg
end

-- ── Rate limiting ─────────────────────────────────────────────────────────
--
-- Per player, and cheap: both handlers broadcast the whole list to every client,
-- so an unbounded event is an amplification primitive regardless of whether its
-- payload passes. The ceiling is generous next to what a human can produce —
-- parking a car is a several-second act — and is a flood guard, not a gate.

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
            -- A LIMIT warning, on the same once-per-window edge as the log line
            -- above and for the same reason: reporting per dropped event would
            -- move the flood into the telemetry buffer. No player id in the
            -- code -- the code is the grouping key, and a per-player code would
            -- make every flood its own group of one. The rate of this across
            -- installs is the only way to tell a floor that is working from one
            -- set below what ordinary play produces.
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

-- ── Events ────────────────────────────────────────────────────────────────

RegisterNetEvent('tchirp:AddChirpVehicle', function(netId, soundCfg)
    local src = source

    if type(netId) ~= 'number' or netId <= 0 or netId % 1 ~= 0 then return end
    if type(soundCfg) ~= 'table' then return end
    if type(soundCfg.sound) ~= 'string' or soundCfg.sound == '' then return end
    if soundCfg.ref ~= nil and type(soundCfg.ref) ~= 'string' and type(soundCfg.ref) ~= 'number' then
        return
    end
    if not withinRate(src) then return end
    -- AFTER the shape checks and the rate floor: on a job- or item-gated
    -- server `tlib.access` reaches into a framework's core object or an
    -- inventory, and neither a malformed payload nor a flood should be able to
    -- make the server do that. See server/sv_access.lua for why only this
    -- handler is gated.
    if not tchirpMayChirp(src) then return end
    if chirpVehicles[netId] then return end

    -- The strong check first: the model this server can see decides the tone,
    -- and a client asking for a different one is refused rather than corrected,
    -- because a silent correction hides a misconfigured client from its owner.
    local expected, why = assignmentForNetId(netId)
    if expected then
        if soundKey(soundCfg) ~= soundKey(expected) then
            log(('player %d asked for sound "%s" on netId %d, whose model is assigned "%s" — refused')
                :format(src, tostring(soundCfg.sound), netId, tostring(expected.sound)),
                tlib.logger.WARN)
            -- The only one of this handler's three refusals that is a
            -- COMPATIBILITY warning: client and server both have an assignment
            -- for the model and disagree, so one side reloaded its config and
            -- the other did not. The other two refusals are an owner's
            -- Config.chirpAssignments not covering a model or a sound, which is
            -- misconfiguration and belongs in tchirp_diag, not here.
            --
            -- No sound name in the code: the code is the grouping key.
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

    -- Deliberately NOT restricted to the player who added it. The officer who
    -- parks the car and the officer who takes it out are routinely different
    -- people, and an ownership check would leave a car chirping under a driver
    -- who is sitting in it. The blast radius of a forged remove is one chirp
    -- that stops early, which is why this is the one handler with no second
    -- check beyond the rate limit.
    chirpVehicles[netId] = nil
    log(('removed netId %d (player %d)'):format(netId, src), tlib.logger.DEBUG)
    broadcast()
end)

RegisterNetEvent('tchirp:RequestChirpList', function()
    TriggerClientEvent('tchirp:SyncChirpList', source, chirpVehicles)
end)

-- ── Stale entry sweep ─────────────────────────────────────────────────────
-- Vehicles that have been deleted or streamed out of existence. The grace period
-- keeps a freshly added entry from being swept before the server's view of the
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

-- ── Diagnostics ───────────────────────────────────────────────────────────
--
-- Registered `restricted`, so FiveM's own ACE covers it: the console can always
-- run it and a player needs `command.tchirp_diag`. That is deliberately the
-- platform's gate rather than a permission check of tChirp's own — the command
-- prints configuration and a vehicle count, it changes nothing, and the one
-- thing it must never do is require a module a given tLib might not carry in
-- order to answer "why is my install not working".

-- The gate, the pcall guard, the redactor and the routing are all
-- `tlib.diag.command`'s. It prints to the server console always — that copy
-- survives the caller disconnecting — and to the caller as well when there was
-- one. The redactor is derived from the config rather than hand-listed, so a
-- credential-shaped key added to config.lua later is masked without anyone
-- having to remember this file.

tlib.diag.command({
    name = 'tchirp_diag',
    title = 'tChirp diagnostics',
    spec = tchirpConfigSpec,
    report = function(ctx)
        -- The snapshot, not the live table: `tlib.config.configured` returns what
        -- the file said at boot, before anything could have mutated it.
        --
        -- Type-checked rather than called, because a tLib without `configured`
        -- answers a plain nil for it. Falling back to the live table is a
        -- slightly weaker answer to the same question, and a better outcome than
        -- half a report plus a failure line in the one command an owner runs when
        -- their install is already broken.
        local configFns = tlib.config
        local configured = (type(configFns.configured) == 'function' and configFns.configured('config.lua'))
            or Config

        local parked = 0
        for _ in pairs(chirpVehicles) do parked = parked + 1 end

        ctx.line('tChirp %s — tLib %s', ctx.meta(GetCurrentResourceName()), ctx.meta('tLib'))
        -- The gate's own description, not a re-reading of Config.access, so the
        -- diagnostic cannot disagree with the decision. Guarded because
        -- sv_access.lua is a separate file: an install missing it would
        -- otherwise fail in the one command an owner runs to find out why.
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

-- ── Startup ───────────────────────────────────────────────────────────────
--
-- Both facts go to the STARTUP BANNER rather than a log line of their own: the
-- banner already is the one-line summary of a healthy boot, and a second line
-- next to it is what makes consoles scroll past it.
--
-- Fired from onResourceStart because sv_version.lua -- which subscribes these
-- events inside tlib.versioncheck -- loads after this file.

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local count = 0
    for _ in pairs(Config.chirpAssignments) do count = count + 1 end
    TriggerEvent('tchirp:vcInfo:models', ('%d vehicle model(s) configured'):format(count))
    TriggerEvent('tchirp:vcInfo:sirens', tostring(Config.sirenSystem))
end)
