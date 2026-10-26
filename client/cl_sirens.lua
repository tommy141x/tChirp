-- =========================================================================
--  tChirp — siren provider cascade (client)
-- =========================================================================
--
--  One question, asked of whichever ELS a server actually runs: WAS THE SIREN
--  ON? Everything else in tChirp hangs off the answer.
--
--  ── Two kinds of provider, and why the config only names two resources ─────
--
--  EXPORT-based (tLS, JLS) are asked directly, at the moment the answer is
--  needed. Calling an export needs the resource's name, which is why those two
--  — and only those two — appear in `Config.sirenResources`, and why that key is
--  an OVERRIDE for a renamed folder rather than the list of names actually tried
--  (see RESOURCE_CANDIDATES).
--
--  EVENT-based (LVC, LVC Fleet, ALS, ELS-FiveM) push their state at us and we
--  cache it. A FiveM event arrives under its own name regardless of what the
--  sending resource is called, so there is nothing to configure and a renamed
--  LVC folder still works.
--
--  ⚠️ A leftover `Config.sirenResources.lvc` from tChirp 1.0.0 is NOT reported.
--  tlib.config only sweeps TOP-LEVEL keys for unknowns, and `sirenResources`
--  is declared as a bare table whose insides are resource names it cannot
--  check. The key is simply never read. Delete it by hand when merging an old
--  config forward.
--
--  ── nil is a third answer and it is the load-bearing one ───────────────────
--
--  A checker returns true, false, or nil for "this is not my vehicle". Only nil
--  falls through to the next provider, which is what makes a mixed fleet work:
--  one server can run tLS cars and LVC cars, and each is answered by the
--  provider that owns it rather than by whichever one is checked first.
--
--  The distinction matters most in the other direction. ALS never calls
--  SetVehicleSiren(false) when it stops a siren, so on an ALS car the native
--  fallback reads TRUE with the siren audibly off. Returning `false` — not nil —
--  for a vehicle ALS has claimed is what stops the cascade before it reaches the
--  native check and false-positives every park.
--
--  ── An answer is never trusted raw ─────────────────────────────────────────
--
--  FiveM's Lua runtime hands a BOOL native back as the NUMBER 1 or 0, so both
--  `answer == true` and `not not answer` are wrong: the first rejects every yes,
--  the second accepts every no because 0 is truthy in Lua. Everything that
--  reaches a caller from here goes through `yes()`.
-- =========================================================================

local log = tlib.logger.create('tChirp')

--- Is this answer a yes? Spelled out for both shapes a provider can return —
--- see the header. Used on native returns and on third-party export returns,
--- which are equally free to answer 1.
local function yes(value)
    return value == true or (type(value) == 'number' and value ~= 0)
end

--- Is the player part-way out of the seat right now?
---
--- Task 2 is CODE_TASK_EXIT_VEHICLE, and it is active from the moment the exit
--- begins until the ped detaches — about a second of animation. This is the same
--- signal LVC watches to fire `lvc:onVehicleExit` (its UTIL/cl_lvc.lua), which
--- is why it is the right one here and not merely a plausible one: it makes
--- tChirp's idea of "getting out" the same instant as the provider's.
local function leavingSeat()
    return yes(GetIsTaskActive(PlayerPedId(), 2))
end

-- ── Event-driven state caches ─────────────────────────────────────────────
-- All keyed to the vehicle the local player is in, so another player's siren
-- never bleeds through.
--
-- ⚠️ AN "OFF" THAT ARRIVES MID-EXIT IS PART OF THE PARK KILL, NOT A CANCELLATION
-- OF IT, and ignoring it is what makes these three providers able to fire at all.
--
-- LVC has a park kill of its own, on by default. Its exit thread fires
-- `lvc:onVehicleExit` the instant CODE_TASK_EXIT_VEHICLE goes active, and that
-- handler calls SetLxSirenStateForVeh(veh, 0) — which broadcasts
-- `state_lxsiren = 0` to us (UTIL/cl_lvc.lua, upstream v3). The ped is still in
-- the seat for the ~1s of exit animation that follows, so cl_chirp.lua's 500 ms
-- poll re-snapshots the siren as OFF at least once BEFORE it ever sees the seat
-- empty. Keyed on siren state alone, an LVC park kill therefore could not chirp
-- — not sometimes, never — which is the whole of the `sirenSystem = 'lvc'`
-- bug report of 2026-10-26. Widening the poll could not fix it: the zero always
-- lands first, so there is no interval short enough.
--
-- This is NOT the 500 ms snapshot window documented below. That window is a
-- sampling artefact and still applies to a siren switched off by hand while
-- seated. This is an event: a provider zeroing its own state because the player
-- is getting out, which is the thing being detected.

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

-- ── Per-provider checkers ─────────────────────────────────────────────────

-- Each entry is a LIST because this is the CONSUMING side of other people's
-- renames, and a single hard-coded name turns one into a silent, permanent
-- detection failure — the checker reads "not installed" and returns nil forever,
-- with nothing in the console to say why.
--
--   tels: tELS was renamed tLS on 2026-10-24. The current build answers to both
--         (`provide 'tELS'` plus routed legacy exports), but a server still on
--         the OLD resource answers only to `tELS`, so that name has to stay.
--   jls:  reported on 2026-10-24 as now shipping as `Burkhardt_Software_JLS`,
--         where tChirp 2.0.0 knew only `Jace3483_JLS`.
--
-- The KEYS are ids, not labels: they are what `Config.sirenSystem` and
-- `Config.sirenResources` are written in terms of, so they do not move with a
-- product name.
local RESOURCE_CANDIDATES = {
    tels = { 'tLS', 'tELS' },
    jls  = { 'Burkhardt_Software_JLS', 'Jace3483_JLS' },
}

--- The started resource to ask for this provider, or nil if none is running.
---
--- `Config.sirenResources` is tried FIRST but is not final: a server upgrading
--- from 2.0.0 keeps a config.lua pinning `jls = 'Jace3483_JLS'`, and honouring a
--- pinned name that is not running would leave exactly the servers this fix is
--- for still broken. So an override that names nothing started falls through to
--- the candidates rather than ending the search.
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
--- The GetResourceState check is not merely an optimisation. `exports[name]`
--- THROWS for an unknown resource, and this runs on every park check, so without
--- it every server that does not run tLS raised and caught a Lua error for it
--- forever. Not cached: server.cfg start order is arbitrary and a provider may
--- start after tChirp, so a cached negative would disable detection for the
--- whole session.
---
--- `pcall` still wraps the call itself, for a provider that is started but
--- raises inside its own export.
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

-- Always answers, which is what makes it usable as the last rung and unusable
-- as any other: a native check placed above ALS would answer for an ALS car.
--
-- ⚠️ IsVehicleSirenAudioOn, **NOT** IsVehicleSirenOn. This is the other half of
-- the 2026-10-26 report — "the chirp will happen even if you just get out of
-- your car w the lights activated".
--
-- `IsVehicleSirenOn` is the siren SWITCH, and in GTA that switch is the light
-- bar: SetVehicleSiren(true) raises lights and audio together, and every ELS
-- drives the lights through it. So on "lights on, siren off" — the normal state
-- of a parked unit at a scene — it reads true, and every exit looked like a park
-- kill. There is no configuration that fixes that, because the flag genuinely
-- cannot tell the two apart.
--
-- IsVehicleSirenAudioOn (0xB5CC40FBCB586380) can: it reports the siren AUDIO,
-- and is documented as false for a vehicle whose lights are on with the audio
-- silenced. That also makes this rung harmless on an LVC server, which is what
-- lets `auto` stay usable there: LVC calls SetVehicleHasMutedSirens every frame
-- on the car it controls (that is what its TogMuteDfltSrnForVeh does — the
-- native's other alias is DisableVehicleImpactExplosionActivation) because it
-- plays its own tones, so the audio flag is false on an LVC car and the real
-- answer can only come from the LVC rung above.
--
-- The trade, stated so it is not rediscovered: audio is a stricter test than the
-- switch, so this rung can only ever chirp LESS than before. A missed reminder
-- is the right direction to fail; a siren-off car chirping at a scene is not.
checkers.native = function(vehicle) return yes(IsVehicleSirenAudioOn(vehicle)) end

checkers.lvc_fleet = checkers.lvc

-- tLS first because it is ours and it answers definitively. `native` last for
-- the reason above. ALS below JLS because ALS's false-for-claimed behaviour is
-- inferred from its events rather than asked, so a provider that can be asked
-- gets the first word.
local AUTO_ORDER = { 'tels', 'lvc', 'els_fivem', 'jls', 'als', 'native' }

--- Was the siren on for this vehicle?
--- @param vehicle number  entity handle
--- @return boolean
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
        -- Unreachable on a validated config: shared/config-spec.lua's `oneOf`
        -- refuses an unknown provider at boot and the resource does not start.
        -- Kept as a loud line rather than a silent false because the one way to
        -- get here is for the spec and this table to drift apart, and a silent
        -- false is indistinguishable from "the siren was off".
        log(('sirenSystem "%s" has no checker; no vehicle will ever chirp'):format(tostring(system)),
            tlib.logger.ERROR)
        return false
    end

    -- Returned as given, with nil meaning "no". It USED to be `answer == true`,
    -- which is the trap this file's header names: the two rungs that read a
    -- foreign value — `native` and `askExport` — handed back the number 1, and
    -- `1 == true` is false in Lua, so a pinned provider that said yes was heard
    -- as "the siren was off". Both of those rungs now normalise at the boundary,
    -- which is the only place that knows it is holding a foreign value, so there
    -- is nothing left to compare here.
    local answer = checker(vehicle)
    if answer == nil then return false end
    return answer
end

--- What a single named provider says right now, for `tchirp_diag`. Returns the
--- raw three-state answer, nil included, because "not my vehicle" is the thing
--- an owner debugging a mixed fleet needs to see.
function tchirpProviderAnswers(vehicle)
    local out = {}
    for _, name in ipairs(AUTO_ORDER) do
        out[name] = checkers[name](vehicle)
    end
    return out
end

--- WHICH provider owns this vehicle, and what it says. For the `/tchirp` dialog.
---
--- The first provider to answer anything but nil owns the car, which is the
--- whole reason nil is a third answer (see the header of this file). The NAME
--- matters as much as the answer: "the siren is off" and "LVC says the siren is
--- off, so the native check never ran" are different facts, and the second is
--- the one that explains a car that does not chirp.
---
--- On a pinned `Config.sirenSystem` there is only ever one candidate, so the
--- answer is that provider or nothing.
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

--- Display labels for the provider names, for the same dialog. `native` is
--- spelled out because "native" to a server owner reading a status line is not
--- obviously "GTA's own siren flag, which ALS lies about".
TCHIRP_PROVIDER_LABELS = {
    tels      = 'tLS',
    lvc       = 'Luxart Vehicle Control',
    lvc_fleet = 'LVC Fleet',
    els_fivem = 'ELS-FiveM',
    jls       = 'JLS',
    als       = 'Advanced Lighting System',
    native    = "GTA's own siren flag",
}
