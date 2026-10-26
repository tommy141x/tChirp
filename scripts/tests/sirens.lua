-- client/cl_sirens.lua — the provider cascade.
--
-- This is the half of tChirp that decides whether anything happens at all, it
-- talks to six third-party resources none of which are installed here, and it had
-- no test of any kind. The three-state contract (true / false / nil-for-not-mine)
-- is the part worth pinning: it is invisible in the code's shape, every rung
-- depends on it, and getting it wrong produces a resource that either never
-- chirps or chirps on every park.

local ROOT = (arg[0] or ''):match('^(.*)scripts[/\\]tests[/\\]') or './'
local function path(p) return ROOT .. p end

local VEH, OTHER = 10, 11

-- ── Host stubs ─────────────────────────────────────────────────────────────

local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end
local function fire(name, ...)
    local fn = handlers[name] or error('no handler registered for ' .. name, 2)
    fn(...)
end

local myVehicle = 0
function PlayerPedId() return 1 end
function PlayerId() return 0 end
function GetPlayerServerId() return 7 end
function GetVehiclePedIsIn() return myVehicle end

-- ⚠️ THESE STUBS RETURN 1 AND 0, NOT true AND false, AND THAT IS THE POINT.
--
-- FiveM's Lua runtime hands a BOOL native back as a number, so a suite that
-- stubs them as booleans measures a cascade nothing in the game can reach: it
-- passes `answer == true` and `not answer` happily, while the real native makes
-- the first always-false and the second always-false-for-0-too. That is how the
-- `== true` on the pinned path, and a native rung whose 0 was truthy and chirped
-- every park, both survived a green suite.
local nativeSirenAudio, exiting = 0, 0

-- The LIGHT BAR flag. Stubbed and deliberately never read by the cascade: it is
-- what the native rung used to read, it is true for "lights on, siren off", and
-- a rung that goes back to it must fail the audio assertions below.
local nativeSirenOn = 0

function IsVehicleSirenOn() return nativeSirenOn end
function IsVehicleSirenAudioOn() return nativeSirenAudio end
function GetIsTaskActive(_, task)
    if task ~= 2 then return 0 end
    return exiting
end

-- Only tLS/JLS reach this, and only to decide whether to ask at all.
local started = {}
function GetResourceState(name) return started[name] and 'started' or 'missing' end

local logged = {}
tlib = {
    logger = {
        DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4,
        create = function() return function(message, level) logged[#logged + 1] = { message, level } end end,
    },
}

-- `exports[name]:IsSirenActive(v)`. A resource that is not installed must THROW,
-- exactly as FiveM does — the pcall in askExport is there for that case, and a
-- stub returning nil instead would let a real regression pass.
local installed = {}
exports = setmetatable({}, {
    __index = function(_, name)
        local stub = installed[name]
        if not stub then error(('No such export resource %s'):format(name), 0) end
        return stub
    end,
})

--- Start a provider resource and give it an IsSirenActive. Both halves, because
--- the cascade now asks GetResourceState before it asks the export: a stub that
--- set only one of the two would test a state no server can be in.
local function install(name, isSirenActive)
    started[name] = true
    installed[name] = { IsSirenActive = isSirenActive }
end

-- Empty, as config.lua now ships it: the resource names are resolved from the
-- candidate lists in cl_sirens.lua, not from the config.
Config = {
    sirenSystem = 'auto',
    sirenResources = {},
}

dofile(path('client/cl_sirens.lua'))

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function reset()
    tchirpClearSirenCache()
    installed, started = {}, {}
    nativeSirenOn, nativeSirenAudio, exiting = 0, 0, 0
    myVehicle = 0
    Config.sirenSystem = 'auto'
    Config.sirenResources = {}
    logged = {}
end

-- ── Native is the last rung, and it reads AUDIO, not the light bar ─────────
--
-- The 2026-10-26 report: "the chirp will happen even if you just get out of your
-- car w the lights activated". `IsVehicleSirenOn` is the siren SWITCH, which in
-- GTA is the light bar, so it is true for a parked unit with its lights on at a
-- scene and every exit read as a park kill. Audio is the only flag that can tell
-- the two apart, so the assertion is: lights on + audio off is NOT a siren.

reset()
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == true, 'the native fallback did not answer for an unclaimed vehicle')
nativeSirenAudio = 0
check(tchirpIsSirenActive(VEH) == false, 'the native fallback reported a siren that was off')
check(tchirpIsSirenActive(0) == false, 'entity 0 was treated as a vehicle')
check(tchirpIsSirenActive(nil) == false, 'nil was treated as a vehicle')

reset()
nativeSirenOn, nativeSirenAudio = 1, 0
check(tchirpIsSirenActive(VEH) == false,
    'lights on with the siren silent was read as a siren -- the native rung is back on '
    .. 'IsVehicleSirenOn, which cannot tell a light bar from a siren')

-- A number is the ONLY shape a BOOL native returns here, and 0 is truthy in Lua.
-- Pinned to `native`, `answer == true` rejected the 1 and nothing ever chirped;
-- on `auto` the 0 was passed out as a truthy value and EVERY park chirped.
reset()
Config.sirenSystem = 'native'
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == true,
    'a pinned provider answered 1 and it was compared against `true`')
nativeSirenAudio = 0
check(tchirpIsSirenActive(VEH) == false, 'a native 0 was treated as a siren, because 0 is truthy')

-- ── An export provider that CLAIMS the vehicle stops the cascade ────────────
--
-- The case that matters: tLS says the siren is off while the native check would
-- say it is on. Whoever owns the vehicle is right.

reset()
nativeSirenAudio = 1
install('tLS', function() return false end)
check(tchirpIsSirenActive(VEH) == false,
    'tLS said the siren was off and the native fallback overrode it')

install('tLS', function() return true end)
nativeSirenAudio = 0
check(tchirpIsSirenActive(VEH) == true, 'tLS said the siren was on and was ignored')

-- A third-party export is as free to answer 1 as a native is.
reset()
install('tLS', function() return 1 end)
check(tchirpIsSirenActive(VEH) == true, 'an export answered 1 and it was not read as a yes')
install('tLS', function() return 0 end)
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == false, 'an export answered 0 and it was read as a yes')

-- nil means "not a tLS vehicle" and must fall through, which is what makes a
-- mixed fleet work.
reset()
nativeSirenAudio = 1
install('tLS', function() return nil end)
check(tchirpIsSirenActive(VEH) == true, 'a tLS nil did not fall through to the next provider')

-- Both names each of the two export providers ships under must be found, or the
-- rename is a silent permanent detection failure on every server still on the
-- old one. This is the tRadio bug of 2026-10-24, checked for here.
for _, name in ipairs({ 'tLS', 'tELS' }) do
    reset()
    install(name, function() return true end)
    check(tchirpIsSirenActive(VEH) == true, ('a tLS/tELS resource named %s was not found'):format(name))
end
for _, name in ipairs({ 'Burkhardt_Software_JLS', 'Jace3483_JLS' }) do
    reset()
    install(name, function() return true end)
    check(tchirpIsSirenActive(VEH) == true, ('a JLS resource named %s was not found'):format(name))
end

-- A config override naming a resource that is not running must not end the
-- search, or a server upgrading with `jls = 'Jace3483_JLS'` still in its
-- config.lua stays broken on the renamed build.
reset()
Config.sirenResources = { jls = 'Jace3483_JLS' }
install('Burkhardt_Software_JLS', function() return true end)
check(tchirpIsSirenActive(VEH) == true,
    'a stale pinned resource name stopped the candidate search')

-- A started provider that raises inside its own export must be survivable.
reset()
nativeSirenAudio = 1
install('tLS', function() error('third-party ELS blew up', 0) end)
check(tchirpIsSirenActive(VEH) == true, 'a raising tLS export took the cascade down')

-- And one that is not running at all is not asked, so it cannot throw.
reset()
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == true, 'an absent tLS export took the cascade down')

-- ── LVC: cached from its event, and keyed to one vehicle ───────────────────

reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 2 })
check(tchirpIsSirenActive(VEH) == true, 'an LVC tone above 0 was not read as a siren')
check(tchirpIsSirenActive(OTHER) == false,
    "another vehicle inherited this vehicle's LVC state")

reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 0 })
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == false,
    'LVC reported tone 0 and the native fallback overrode it')

-- A payload without the field is not a state update.
reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { some_other_field = 1 })
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == true, 'a payload with no state_lxsiren was treated as a claim')

-- ── The LVC park kill, which is why `sirenSystem = 'lvc'` never chirped ────
--
-- LVC kills its own siren the instant the exit task starts and broadcasts tone 0
-- for it (`lvc:onVehicleExit` -> SetLxSirenStateForVeh(veh, 0) ->
-- BroadcastPlayerVehicleState, upstream UTIL/cl_lvc.lua). The ped stays in the
-- seat for the ~1s of exit animation that follows, so cl_chirp.lua's 500 ms poll
-- re-reads the siren as off BEFORE it sees the seat empty, and the park kill it
-- is trying to detect has erased its own evidence. A zero that lands while the
-- player is leaving is therefore not believed.
reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 2 })
exiting = 1
fire('lvc:UpdateThirdParty', { state_lxsiren = 0 })
check(tchirpIsSirenActive(VEH) == true,
    "LVC's own park kill cleared the siren tChirp was about to act on, so an LVC park "
    .. 'kill can never chirp')

-- Still believed when it is the player switching the siren off, which is the
-- whole discrimination: same event, same tone, different moment.
reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 2 })
fire('lvc:UpdateThirdParty', { state_lxsiren = 0 })
check(tchirpIsSirenActive(VEH) == false,
    'a siren switched off while seated was ignored, so every LVC park would chirp')

-- Mid-exit does not invent a siren that was never on: the guard only protects a
-- tone that was already above zero.
reset()
myVehicle = VEH
exiting = 1
fire('lvc:UpdateThirdParty', { state_lxsiren = 0 })
check(tchirpIsSirenActive(VEH) == false, 'leaving a siren-off LVC car was read as a park kill')

-- ── ALS: the one that must return false rather than nil ────────────────────
--
-- ALS never calls SetVehicleSiren(false) when it stops a siren, so on an ALS car
-- the native check reads TRUE with the siren audibly off. This is the assertion
-- that the cascade stops at ALS for a vehicle ALS has claimed.

reset()
myVehicle = VEH
fire('ALS:PlayPrimarySirenClient', VEH)
check(tchirpIsSirenActive(VEH) == true, 'an ALS primary siren was not read')
fire('ALS:StopPrimarySirenClient', VEH)
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == false,
    'ALS stopped its siren and the native fallback false-positived — the exact bug '
    .. 'the false-not-nil return exists to prevent')

reset()
myVehicle = VEH
fire('ALS:PlaySecondarySirenClient', VEH)
check(tchirpIsSirenActive(VEH) == true, 'an ALS secondary siren was not read')

-- The same mid-exit rule as LVC, applied to the other two event providers. Not
-- because either is known to have a park kill of its own — LVC's is the one read
-- in its source — but because the rule is about the moment, not the provider: a
-- siren going off while the player is climbing out is part of the park kill
-- whoever turns it off, and a provider that gains a park kill later must not
-- quietly stop chirping the way LVC did.
reset()
myVehicle = VEH
fire('ALS:PlayPrimarySirenClient', VEH)
exiting = 1
fire('ALS:StopPrimarySirenClient', VEH)
check(tchirpIsSirenActive(VEH) == true, 'an ALS siren stopped mid-exit erased its own park kill')

reset()
myVehicle = VEH
fire('els:setSirenState_c', 7, 1)
exiting = 1
fire('els:setSirenState_c', 7, 0)
check(tchirpIsSirenActive(VEH) == true, 'an ELS-FiveM siren zeroed mid-exit erased its own park kill')

-- Another player's ALS car must not touch our cache.
reset()
myVehicle = VEH
fire('ALS:PlayPrimarySirenClient', OTHER)
check(tchirpIsSirenActive(OTHER) == false, "someone else's ALS siren bled through")

-- ── ELS-FiveM: broadcast to everyone, so the sender has to be filtered ─────

reset()
myVehicle = VEH
fire('els:setSirenState_c', 7, 1)
check(tchirpIsSirenActive(VEH) == true, 'our own ELS-FiveM state was not read')

reset()
myVehicle = VEH
fire('els:setSirenState_c', 99, 1)
nativeSirenAudio = 0
check(tchirpIsSirenActive(VEH) == false, "another player's ELS-FiveM state was read as ours")

-- ── Explicit providers do not cascade ──────────────────────────────────────

reset()
Config.sirenSystem = 'native'
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == true, 'sirenSystem = native did not read the native siren')

reset()
Config.sirenSystem = 'tels'
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == false,
    'sirenSystem = tels fell through to native, which is what `auto` is for')

-- LVC Fleet is the same event as LVC, deliberately.
reset()
Config.sirenSystem = 'lvc_fleet'
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 3 })
check(tchirpIsSirenActive(VEH) == true, 'lvc_fleet did not read the shared LVC event')

-- ── An unknown provider is loud, not silently false ───────────────────────
-- Unreachable on a validated config; this pins the behaviour if the spec's
-- `oneOf` and the checker table ever drift apart.

reset()
Config.sirenSystem = 'luxart'
nativeSirenAudio = 1
check(tchirpIsSirenActive(VEH) == false, 'an unknown provider answered')
check(#logged == 1 and logged[1][2] == tlib.logger.ERROR,
    'an unknown provider did not log at ERROR, so it would look like "the siren was off"')

-- ── tchirpResolvedProvider: WHICH provider owns the vehicle ───────────────
--
-- The `/tchirp` dialog's explanation rests entirely on this. "The siren is off"
-- and "LVC says the siren is off, so the native check never ran" are different
-- facts, and the second is the one that explains a car that does not chirp — so
-- the NAME has to be the one the cascade actually stopped at, not the first
-- plausible candidate.

reset()
Config.sirenSystem = 'auto'
myVehicle = VEH
fire('lvc:UpdateThirdParty', { state_lxsiren = 0 })
nativeSirenAudio = 1
do
    local name, answer = tchirpResolvedProvider(VEH)
    check(name == 'lvc', 'the owning provider must be the rung the cascade stopped at, not the last one')
    check(answer == false, 'the owning provider\'s own answer must be reported, false included')
    -- The distinction the dialog exists to show: the cascade stopped at LVC, so
    -- the native flag that says "on" was never consulted.
    check(tchirpIsSirenActive(VEH) == false, 'the cascade and the resolver must agree')
end

reset()
Config.sirenSystem = 'auto'
nativeSirenAudio = 1
do
    local name, answer = tchirpResolvedProvider(VEH)
    check(name == 'native', 'with nothing else claiming it, native is the owner')
    check(answer == true, 'native always answers, which is why it is last')
end

-- A pinned provider that does not know this car answers nothing at all, rather
-- than falling through. That is the row the dialog shows as "no provider claims
-- this vehicle", and it is a real misconfiguration rather than a quiet off.
reset()
Config.sirenSystem = 'lvc'
nativeSirenAudio = 1
check(tchirpResolvedProvider(VEH) == nil,
    'a pinned provider with no claim on the vehicle must resolve to nothing')

reset()
Config.sirenSystem = 'luxart'
check(tchirpResolvedProvider(VEH) == nil, 'an unknown provider resolves to nothing')

reset()
check(tchirpResolvedProvider(0) == nil, 'entity 0 is not a vehicle')

-- Every name the resolver can return must have a label, or the dialog prints a
-- raw table key at a server owner. Checked against AUTO_ORDER's own contents.
reset()
for _, name in pairs({ 'tels', 'lvc', 'lvc_fleet', 'els_fivem', 'jls', 'als', 'native' }) do
    check(type(TCHIRP_PROVIDER_LABELS[name]) == 'string',
        'provider ' .. name .. ' has no display label')
end

print('PASS sirens.lua')
