-- =========================================================================
--  tChirp — siren provider cascade (client)
-- =========================================================================
--
--  One question, asked of whichever ELS a server actually runs: WAS THE SIREN
--  ON? Everything else in tChirp hangs off the answer.
--
--  ── Two kinds of provider, and why the config only names two resources ─────
--
--  EXPORT-based (tELS, JLS) are asked directly, at the moment the answer is
--  needed. Calling an export needs the resource's name, which is why those two
--  — and only those two — appear in `Config.sirenResources`.
--
--  EVENT-based (LVC, LVC Fleet, ALS, ELS-FiveM) push their state at us and we
--  cache it. A FiveM event arrives under its own name regardless of what the
--  sending resource is called, so there is nothing to configure and a renamed
--  LVC folder still works. tChirp 1.0.0 shipped a `Config.sirenResources.lvc`
--  key anyway, told owners to change it if their resource was renamed, and never
--  read it. It is gone; `shared/config-spec.lua` reports it if it is still in an
--  owner's file.
--
--  ── nil is a third answer and it is the load-bearing one ───────────────────
--
--  A checker returns true, false, or nil for "this is not my vehicle". Only nil
--  falls through to the next provider, which is what makes a mixed fleet work:
--  one server can run tELS cars and LVC cars, and each is answered by the
--  provider that owns it rather than by whichever one is checked first.
--
--  The distinction matters most in the other direction. ALS never calls
--  SetVehicleSiren(false) when it stops a siren, so on an ALS car the native
--  fallback reads TRUE with the siren audibly off. Returning `false` — not nil —
--  for a vehicle ALS has claimed is what stops the cascade before it reaches the
--  native check and false-positives every park.
-- =========================================================================

local log = tlib.logger.create('tChirp')

-- ── Event-driven state caches ─────────────────────────────────────────────
-- All keyed to the vehicle the local player is in, so another player's siren
-- never bleeds through.

local lvcTone, lvcVehicle = 0, 0
local alsActive, alsVehicle = false, 0
local elsState, elsVehicle = 0, 0

-- LVC and LVC Fleet. One event, one cache: Fleet is a fork that kept the
-- third-party broadcast identical, so it is the same checker below.
AddEventHandler('lvc:UpdateThirdParty', function(data)
    if not data or data.state_lxsiren == nil then return end
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
    if vehicle == alsVehicle then alsActive = false end
end)
AddEventHandler('ALS:StopSecondarySirenClient', function(vehicle)
    if vehicle == alsVehicle then alsActive = false end
end)

-- ELS-FiveM broadcasts every player's state to every client, so the sender has
-- to be filtered down to us before the cache is touched.
AddEventHandler('els:setSirenState_c', function(sender, newstate)
    if tonumber(sender) ~= GetPlayerServerId(PlayerId()) then return end
    elsState = newstate or 0
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

--- Ask an export-based provider. `pcall` because the export is absent on a
--- server that does not run it, and a missing export is a throw rather than a
--- nil — which would take the whole cascade down instead of falling through.
local function askExport(resourceKey, vehicle)
    local name = Config.sirenResources and Config.sirenResources[resourceKey]
    if type(name) ~= 'string' or name == '' then return nil end
    local ok, active = pcall(function()
        return exports[name]:IsSirenActive(vehicle)
    end)
    if ok and active ~= nil then return active end
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
checkers.native = function(vehicle) return IsVehicleSirenOn(vehicle) end

checkers.lvc_fleet = checkers.lvc

-- tELS first because it is ours and it answers definitively. `native` last for
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

    local answer = checker(vehicle)
    return answer == true
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
