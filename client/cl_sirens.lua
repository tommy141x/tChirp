-- tChirp — siren provider cascade (client)
--
-- tLS and JLS are asked by EXPORT, which needs the resource's name — so they are
-- the only two in `Config.sirenResources`, and that key is an override for a
-- folder you renamed yourself, not the list of names actually tried (see
-- RESOURCE_CANDIDATES). LVC, LVC Fleet, ALS and ELS-FiveM push their state at us
-- and we cache it; an event arrives under its own name however the sender is
-- renamed, so there is nothing to configure.
--
-- ⚠️ A leftover `Config.sirenResources.lvc` from 1.0.0 is never reported:
-- tlib.config only sweeps TOP-LEVEL keys and `sirenResources` is a bare table.
-- The key is never read. Delete it by hand when merging a config forward.
--
-- A checker answers true, false, or nil for "not my vehicle". Only nil falls
-- through to the next provider, which is what makes a mixed fleet work. It
-- matters most in the other direction: ALS never calls SetVehicleSiren(false)
-- when it stops a siren, so on an ALS car the native rung reads TRUE with the
-- audio off. Returning `false` and not nil for a car ALS has claimed is what
-- stops the cascade before it gets there.
--
-- A bool native comes back as the NUMBER 1 or 0. Don't compare to `true` (that
-- rejects every yes) and don't use `not not` (0 is truthy, so that accepts every
-- no). Everything leaving this file goes through `yes()`.

local log = tlib.logger.create('tChirp')

--- A yes in either shape — a native return and a third-party export are equally
--- free to answer 1.
local function yes(value)
    return value == true or (type(value) == 'number' and value ~= 0)
end

--- Task 2 is CODE_TASK_EXIT_VEHICLE, active from the start of the exit until the
--- ped detaches — about a second of animation. The same signal LVC watches to
--- fire `lvc:onVehicleExit` (UTIL/cl_lvc.lua), so tChirp's idea of "getting out"
--- is the same instant as the provider's.
local function leavingSeat()
    return yes(GetIsTaskActive(PlayerPedId(), 2))
end

-- ── Event-driven state caches ─────────────────────────────────────────────
-- Keyed to the vehicle the local player is in, so another player's siren never
-- bleeds through.
--
-- ⚠️ AN "OFF" THAT ARRIVES MID-EXIT IS PART OF THE PARK KILL, NOT A CANCELLATION
-- OF IT. Ignoring it is what makes these three providers able to fire at all.
--
-- LVC's own park kill calls SetLxSirenStateForVeh(veh, 0) from
-- `lvc:onVehicleExit`, fired the instant CODE_TASK_EXIT_VEHICLE goes active, and
-- that broadcasts `state_lxsiren = 0` to us (UTIL/cl_lvc.lua, upstream v3). The
-- ped stays seated for the ~1s of exit animation, so cl_chirp.lua's 500 ms poll
-- re-snapshots the siren as OFF before it ever sees the seat empty. On siren
-- state alone an LVC park kill could therefore never chirp — the whole of the
-- `sirenSystem = 'lvc'` bug report of 2026-10-26. No shorter poll fixes it; the
-- zero always lands first.
--
-- Not the 500 ms snapshot window in cl_chirp.lua: that is a sampling artefact and
-- still applies to a siren switched off by hand while seated. This is a provider
-- zeroing its own state because the player is getting out.

local lvcTone, lvcVehicle = 0, 0
local alsActive, alsVehicle = false, 0
local elsState, elsVehicle = 0, 0

-- LVC and LVC Fleet. One event, one cache: Fleet is a fork that kept the
-- third-party broadcast identical, so it is the same checker below.
AddEventHandler('lvc:UpdateThirdParty', function(data)
    if not data or data.state_lxsiren == nil then return end
    if data.state_lxsiren == 0 and lvcTone > 0 and leavingSeat() then return end
    lvcTone = data.state_lxsiren
    lvcVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
end)

-- ALS — primary and secondary are separate events and either one is a siren.
AddEventHandler('ALS:PlayPrimarySirenClient', function(vehicle)
    if vehicle == GetVehiclePedIsIn(PlayerPedId(), false) then
        alsActive, alsVehicle = true, vehicle
    end
end)
AddEventHandler('ALS:PlaySecondarySirenClient', function(vehicle)
    if vehicle == GetVehiclePedIsIn(PlayerPedId(), false) then
        alsActive, alsVehicle = true, vehicle
    end
end)
AddEventHandler('ALS:StopPrimarySirenClient', function(vehicle)
    if vehicle == alsVehicle and not leavingSeat() then alsActive = false end
end)
AddEventHandler('ALS:StopSecondarySirenClient', function(vehicle)
    if vehicle == alsVehicle and not leavingSeat() then alsActive = false end
end)

-- ELS-FiveM broadcasts every player's state to every client, so the sender has
-- to be filtered down to us before the cache is touched.
AddEventHandler('els:setSirenState_c', function(sender, newstate)
    if tonumber(sender) ~= GetPlayerServerId(PlayerId()) then return end
    local state = newstate or 0
    if state == 0 and elsState > 0 and leavingSeat() then return end
    elsState = state
    elsVehicle = GetVehiclePedIsIn(PlayerPedId(), false)
end)

--- Forget everything. Called after a park-kill decision has been taken, so the
--- next vehicle starts from "no provider has claimed this".
function tchirpClearSirenCache()
    lvcTone, lvcVehicle = 0, 0
    alsActive, alsVehicle = false, 0
    elsState, elsVehicle = 0, 0
end

-- A LIST per provider, because this is the consuming side of other people's
-- renames: one hard-coded name makes a rename a silent, permanent detection
-- failure — the checker reads "not installed" and returns nil forever, with
-- nothing in the console to say why.
--
--   tels: tELS was renamed tLS on 2026-10-24. The current build answers to both,
--         but a server still on the old resource answers only to `tELS`.
--   jls:  reported 2026-10-24 as now shipping as `Burkhardt_Software_JLS`, where
--         tChirp 2.0.0 knew only `Jace3483_JLS`.
--
-- The keys are ids, not labels: `Config.sirenSystem` and `Config.sirenResources`
-- are written in terms of them, so they do not move with a product name.
local RESOURCE_CANDIDATES = {
    tels = { 'tLS', 'tELS' },
    jls  = { 'Burkhardt_Software_JLS', 'Jace3483_JLS' },
}

--- The started resource to ask for this provider, or nil if none is running.
---
--- `Config.sirenResources` is tried first but is not final. A server upgrading
--- from 2.0.0 keeps a config.lua pinning `jls = 'Jace3483_JLS'`, so honouring a
--- pinned name that is not running would leave exactly the servers this fix is
--- for still broken.
local function sirenResource(resourceKey)
    local override = Config.sirenResources and Config.sirenResources[resourceKey]
    if type(override) == 'string' and override ~= '' and GetResourceState(override) == 'started' then
        return override
    end
    for _, name in ipairs(RESOURCE_CANDIDATES[resourceKey]) do
        if GetResourceState(name) == 'started' then return name end
    end
    return nil
end

--- Ask an export-based provider.
---
--- The GetResourceState check is not an optimisation: `exports[name]` THROWS for
--- an unknown resource, and this runs on every park check, so without it every
--- server not running tLS raised and caught a Lua error forever. Not cached —
--- server.cfg start order is arbitrary and a provider may start after tChirp, so
--- a cached negative would kill detection for the session. The `pcall` is for a
--- provider that is started and raises inside its own export.
local function askExport(resourceKey, vehicle)
    local name = sirenResource(resourceKey)
    if not name then return nil end
    local ok, active = pcall(function()
        return exports[name]:IsSirenActive(vehicle)
    end)
    if ok and active ~= nil then return yes(active) end
    return nil
end

local checkers = {}

checkers.tels = function(vehicle) return askExport('tels', vehicle) end
checkers.jls = function(vehicle) return askExport('jls', vehicle) end

checkers.lvc = function(vehicle)
    if lvcVehicle ~= 0 and vehicle ~= lvcVehicle then
        lvcTone, lvcVehicle = 0, 0
    end
    if lvcVehicle == vehicle then return lvcTone > 0 end
    return nil
end

checkers.als = function(vehicle)
    if alsVehicle ~= 0 and vehicle ~= alsVehicle then
        alsActive, alsVehicle = false, 0
    end
    if alsVehicle == vehicle then return alsActive end
    return nil
end

checkers.els_fivem = function(vehicle)
    if elsVehicle ~= 0 and vehicle ~= elsVehicle then
        elsState, elsVehicle = 0, 0
    end
    if elsVehicle == vehicle then return elsState > 0 end
    return nil
end

-- Always answers, which makes it the last rung and nothing else: placed above
-- ALS it would answer for an ALS car.
--
-- ⚠️ IsVehicleSirenAudioOn, **NOT** IsVehicleSirenOn — the other half of the
-- 2026-10-26 report, "the chirp will happen even if you just get out of your car
-- w the lights activated". `IsVehicleSirenOn` is the siren SWITCH, and in GTA
-- that switch is the light bar: SetVehicleSiren(true) raises lights and audio
-- together and every ELS drives the lights through it, so "lights on, siren off"
-- — a unit parked at a scene — read true and every exit looked like a park kill.
-- No config fixed it; the flag cannot tell the two apart.
--
-- IsVehicleSirenAudioOn (0xB5CC40FBCB586380) reports the AUDIO, false for a car
-- whose lights are up and audio silenced. That also keeps this rung harmless on
-- an LVC server: LVC calls SetVehicleHasMutedSirens every frame on the car it
-- controls (its TogMuteDfltSrnForVeh; the native's other alias is
-- DisableVehicleImpactExplosionActivation) because it plays its own tones, so
-- the real answer can only come from the LVC rung above.
--
-- Audio is a stricter test than the switch, so this rung can only chirp LESS than
-- it did before.
checkers.native = function(vehicle) return yes(IsVehicleSirenAudioOn(vehicle)) end

checkers.lvc_fleet = checkers.lvc

-- tLS first because it answers definitively, `native` last for the reason above.
-- ALS below JLS because ALS's false-for-claimed behaviour is inferred from its
-- events rather than asked, so a provider that can be asked gets the first word.
local AUTO_ORDER = { 'tels', 'lvc', 'els_fivem', 'jls', 'als', 'native' }

--- Was the siren on for this vehicle?
function tchirpIsSirenActive(vehicle)
    if not vehicle or vehicle == 0 then return false end

    local system = Config.sirenSystem

    if system == 'auto' then
        for _, name in ipairs(AUTO_ORDER) do
            local answer = checkers[name](vehicle)
            if answer ~= nil then return answer end
        end
        return false
    end

    local checker = checkers[system]
    if not checker then
        -- Unreachable on a validated config — config-spec.lua's `oneOf` refuses
        -- an unknown provider at boot. Loud rather than a silent false, because
        -- the only way here is the spec and this table drifting apart, and a
        -- silent false is indistinguishable from "the siren was off".
        log(('sirenSystem "%s" has no checker; no vehicle will ever chirp'):format(tostring(system)),
            tlib.logger.ERROR)
        return false
    end

    -- Returned as given, nil meaning "no". This was `answer == true`, which is
    -- the 1/0 trap in the header: `native` and `askExport` handed back the number
    -- 1 and `1 == true` is false, so a pinned provider saying yes was heard as
    -- "siren off". Both rungs normalise through `yes()` now.
    local answer = checker(vehicle)
    if answer == nil then return false end
    return answer
end

--- What every provider says right now, for `tchirp_diag`. nil included: "not my
--- vehicle" is what an owner debugging a mixed fleet needs to see.
function tchirpProviderAnswers(vehicle)
    local out = {}
    for _, name in ipairs(AUTO_ORDER) do
        out[name] = checkers[name](vehicle)
    end
    return out
end

--- WHICH provider owns this vehicle, and what it says. For the `/tchirp` dialog:
--- "the siren is off" and "LVC says the siren is off, so the native check never
--- ran" are different facts, and the second is the one that explains a car that
--- does not chirp.
---
--- @return name|nil, answer|nil   nil, nil when no provider claims the vehicle.
function tchirpResolvedProvider(vehicle)
    if not vehicle or vehicle == 0 then return nil end

    local system = Config.sirenSystem
    if system ~= 'auto' then
        local checker = checkers[system]
        if not checker then return nil end
        local answer = checker(vehicle)
        if answer == nil then return nil end
        return system, answer
    end

    for _, name in ipairs(AUTO_ORDER) do
        local answer = checkers[name](vehicle)
        if answer ~= nil then return name, answer end
    end
    return nil
end

--- Display labels for the same dialog. `native` is spelled out because "native"
--- in a status line is not obviously "GTA's own siren flag".
TCHIRP_PROVIDER_LABELS = {
    tels      = 'tLS',
    lvc       = 'Luxart Vehicle Control',
    lvc_fleet = 'LVC Fleet',
    els_fivem = 'ELS-FiveM',
    jls       = 'JLS',
    als       = 'Advanced Lighting System',
    native    = "GTA's own siren flag",
}
