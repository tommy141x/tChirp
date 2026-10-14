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

local nativeSirenOn = false
function IsVehicleSirenOn() return nativeSirenOn end

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

Config = {
    sirenSystem = 'auto',
    sirenResources = { tels = 'tELS', jls = 'Jace3483_JLS' },
}

dofile(path('client/cl_sirens.lua'))

local function check(condition, message)
    if not condition then error(message, 2) end
end

local function reset()
    tchirpClearSirenCache()
    installed = {}
    nativeSirenOn = false
    myVehicle = 0
    Config.sirenSystem = 'auto'
    logged = {}
end

-- ── Native is the last rung, and it does answer ────────────────────────────

reset()
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == true, 'the native fallback did not answer for an unclaimed vehicle')
nativeSirenOn = false
check(tchirpIsSirenActive(VEH) == false, 'the native fallback reported a siren that was off')
check(tchirpIsSirenActive(0) == false, 'entity 0 was treated as a vehicle')
check(tchirpIsSirenActive(nil) == false, 'nil was treated as a vehicle')

-- ── An export provider that CLAIMS the vehicle stops the cascade ────────────
--
-- The case that matters: tELS says the siren is off while the native check would
-- say it is on. Whoever owns the vehicle is right.

reset()
nativeSirenOn = true
installed['tELS'] = { IsSirenActive = function() return false end }
check(tchirpIsSirenActive(VEH) == false,
    'tELS said the siren was off and the native fallback overrode it')

installed['tELS'] = { IsSirenActive = function() return true end }
nativeSirenOn = false
check(tchirpIsSirenActive(VEH) == true, 'tELS said the siren was on and was ignored')

-- nil means "not a tELS vehicle" and must fall through, which is what makes a
-- mixed fleet work.
reset()
nativeSirenOn = true
installed['tELS'] = { IsSirenActive = function() return nil end }
check(tchirpIsSirenActive(VEH) == true, 'a tELS nil did not fall through to the next provider')

-- A provider that is not installed throws, and must be survivable.
reset()
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == true, 'an absent tELS export took the cascade down')

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
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == false,
    'LVC reported tone 0 and the native fallback overrode it')

-- A payload without the field is not a state update.
reset()
myVehicle = VEH
fire('lvc:UpdateThirdParty', { some_other_field = 1 })
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == true, 'a payload with no state_lxsiren was treated as a claim')

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
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == false,
    'ALS stopped its siren and the native fallback false-positived — the exact bug '
    .. 'the false-not-nil return exists to prevent')

reset()
myVehicle = VEH
fire('ALS:PlaySecondarySirenClient', VEH)
check(tchirpIsSirenActive(VEH) == true, 'an ALS secondary siren was not read')

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
nativeSirenOn = false
check(tchirpIsSirenActive(VEH) == false, "another player's ELS-FiveM state was read as ours")

-- ── Explicit providers do not cascade ──────────────────────────────────────

reset()
Config.sirenSystem = 'native'
nativeSirenOn = true
check(tchirpIsSirenActive(VEH) == true, 'sirenSystem = native did not read the native siren')

reset()
Config.sirenSystem = 'tels'
nativeSirenOn = true
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
nativeSirenOn = true
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
nativeSirenOn = true
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
nativeSirenOn = true
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
nativeSirenOn = true
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
