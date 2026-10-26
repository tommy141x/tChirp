-- server/sv_chirp.lua — the parked-vehicle list and what a client may put on it.
--
-- ⚠️ THIS SUITE EXISTS FOR ONE ASSERTION ABOVE ALL THE OTHERS.
--
-- tChirp 1.0.0 accepted any non-empty sound string from any client and broadcast
-- it to every client, which turned this resource into a way to make any networked
-- vehicle in the world emit any native sound. The refusal tests below are the
-- regression guard on that, and they are the reason a resource of 500 lines has a
-- server suite at all.

local ROOT = (arg[0] or ''):match('^(.*)scripts[/\\]tests[/\\]') or './'
local function path(p) return ROOT .. p end

-- ── Host stubs ─────────────────────────────────────────────────────────────

function GetCurrentResourceName() return 'tChirp' end
function GetResourceMetadata() return '1.1.0' end

local netHandlers = {}
function RegisterNetEvent(name, fn) netHandlers[name] = fn end
function AddEventHandler(name, fn) netHandlers[name] = fn end
function RegisterCommand() end

-- The sweep thread would loop forever. It is driven by Wait, which never returns
-- here, so running the body once and parking it is the whole of what a stub needs
-- to do: the loop's FIRST Wait is at the top.
function CreateThread(fn) coroutine.resume(coroutine.create(fn)) end
function Wait() coroutine.yield() end

local clock = 0
function GetGameTimer() return clock end

local hashes = setmetatable({}, { __index = function(t, k)
    -- Any stable injective mapping will do; the code only ever compares hashes.
    local h = 0
    for i = 1, #k do h = (h * 31 + k:byte(i)) % 2147483647 end
    t[k] = h
    return h
end })
function GetHashKey(name) return hashes[name] end

-- The server's view of the world. `nil` for a net ID is a real state — a vehicle
-- mid-ownership-migration — and the fallback path depends on it.
local world = {}
function NetworkGetEntityFromNetworkId(netId) return world[netId] and netId or 0 end
function DoesEntityExist(entity) return world[entity] ~= nil end
function GetEntityModel(entity) return world[entity] end

-- `retiredBroadcasts` counts the `tChirp:` spelling, which must now be ZERO:
-- dual-firing an outbound name doubled every "did this re-broadcast?" count for
-- anyone listening to both.
local broadcasts = 0
local retiredBroadcasts = 0
local lastList = nil
function TriggerClientEvent(event, target, payload)
    if event == 'tchirp:SyncChirpList' then
        broadcasts = broadcasts + 1
        if target == -1 then lastList = payload end
    elseif event == 'tChirp:SyncChirpList' then
        retiredBroadcasts = retiredBroadcasts + 1
    end
end

local logged = {}
tlib = {
    logger = {
        DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4,
        setLevel = function() end,
        create = function() return function(message, level) logged[#logged + 1] = { message, level or 2 } end end,
    },
}

-- Quiet the config check's boot output; a failure prints it below.
local printed = {}
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

tlib.config = dofile(path('../tLib/shared/imports/config/shared.lua'))
-- The real module off disk, not a stub: `tchirp_diag` is built from
-- tlib.diag.command at FILE SCOPE in sv_chirp.lua, so a stub would let a change
-- that broke that call pass this suite. tLib/tests/lua/diag-command.lua is the
-- oracle for what the command itself does.
tlib.diag = dofile(path('../tLib/shared/imports/diag/shared.lua'))
-- Also the real module, and for the same reason: sv_chirp.lua reports the rate
-- floor and the client/server assignment disagreement through
-- `tlib.telemetry.warn`, and both are paths this suite deliberately walks. A
-- stub would let a change to either call site pass; without it the suite dies
-- with "attempt to index a nil value (field 'telemetry')" from inside the
-- handler under test.
--
-- `GetCurrentResourceName` first: `Telemetry.warn` prints its local line
-- through that native UNGUARDED, so a harness that omits it gets "attempt to
-- call a nil value" the first time a warning carries a message. It is a real
-- global in every runtime this ships to; only fengari lacks it. Everything else
-- at the module's file scope is already guarded by `type(x) == 'function'`.
if GetCurrentResourceName == nil then
    function GetCurrentResourceName() return 'tChirp' end
end
tlib.telemetry = dofile(path('../tLib/shared/imports/telemetry/shared.lua'))
dofile(path('config.lua'))
dofile(path('shared/config-spec.lua'))
-- tlib.access, THE REAL MODULE, and sv_access.lua on top of it. The gate is the
-- only thing between a client and the chirp list, and a stub gate is a stub of
-- the one decision in this resource worth getting wrong. `demo` and `permission`
-- are stubbed because they are tLib's own and have their own tests; `telemetry`
-- is already real above.
tlib.demo = { active = function() return false end }
local acePrincipals = {}
tlib.permission = {
    has = function(src, key) return (acePrincipals[src] or {})[key] == true end,
    isAdmin = function() return false end,
}
-- `access` loads its framework/inventory adapter table through
-- LoadResourceFile, and fengari has no `io.open` to read it off disk with. Nil,
-- which the module handles: both lists come back empty and detection answers
-- "none".
--
-- So this suite asserts the `everyone` and `ace` modes ONLY. `job` and `item`
-- would pass here vacuously -- they deny with no adapter -- and asserting them
-- against an empty registry would be asserting nothing. tLib's own tests own the
-- adapters; what tChirp has to get right is which handler consults the gate.
function LoadResourceFile() return nil end
tlib.access = dofile(path('../tLib/shared/imports/access/server.lua'))
dofile(path('server/sv_access.lua'))

dofile(path('server/sv_chirp.lua'))

-- `print` stays RECORDING past the load: several assertions below read a
-- warning out of `printed` that is emitted when a handler RUNS, not at load.
--
-- From here on it also FORWARDS, which the load-time version deliberately does
-- not: a swallowing `print` left installed eats the error message on a failing
-- run, because scripts/run-lua-suite.lua reports through `print` too. The quiet
-- half is only wanted across the config check, whose output is expected.
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    local line = table.concat(parts, '	')
    printed[#printed + 1] = line
    realPrint(line)
end

local function check(condition, message)
    if not condition then
        for _, line in ipairs(printed) do realPrint('    ' .. line) end
        error(message, 2)
    end
end

check(tchirpConfigValid, 'the shipped config did not validate, so sv_chirp.lua never loaded')

local POLICE = GetHashKey('police')
local SULTAN = GetHashKey('sultan')
local CONFIGURED = Config.chirpAssignments['police']

local function add(src, netId, cfg)
    source = src
    netHandlers['tchirp:AddChirpVehicle'](netId, cfg)
end
local function remove(src, netId)
    source = src
    netHandlers['tchirp:RemoveChirpVehicle'](netId)
end
local function listed(netId)
    source = 1
    local captured
    local realTrigger = TriggerClientEvent
    TriggerClientEvent = function(_, _, payload) captured = payload end
    netHandlers['tchirp:RequestChirpList']()
    TriggerClientEvent = realTrigger
    return captured[netId] ~= nil
end

-- Fresh rate-limit window between blocks: the limiter is keyed per player and the
-- suite sends far more events than a human ever would.
local function newWindow() clock = clock + 60000 end

-- ── The happy path ─────────────────────────────────────────────────────────

world[100] = POLICE
add(1, 100, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(listed(100), 'a park kill on a configured model was not added')
check(broadcasts > 0, 'adding a vehicle did not broadcast the new list')

-- Idempotent: the same car parked twice is one entry.
local before = broadcasts
add(1, 100, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(broadcasts == before, 'a duplicate add re-broadcast the whole list to every client')

remove(2, 100)
check(not listed(100), 'a removal did not take')

-- ── A forged sound is refused, not corrected ───────────────────────────────

newWindow()
world[101] = POLICE
add(1, 101, { sound = 'SHOP_TEXT_BLIP', ref = 0 })
check(not listed(101),
    'a client picked a sound the server never configured and the server broadcast it')

-- The refusal is specific: the model IS configured, so the server knows what this
-- car should sound like and does not silently substitute it.
local sawRefusal = false
for _, entry in ipairs(logged) do
    if entry[2] == tlib.logger.WARN and tostring(entry[1]):find('refused', 1, true) then
        sawRefusal = true
    end
end
check(sawRefusal, 'a refused payload was dropped silently, so a misconfigured client is invisible')

-- Another configured tone, but not THIS model's, is still refused when the model
-- can be resolved. The whitelist alone would have let this through.
newWindow()
Config.chirpAssignments['ambulance'] = { sound = 'VEHICLES_HORNS_AMBULANCE_WARNING', ref = 0 }
world[102] = POLICE
add(1, 102, { sound = 'VEHICLES_HORNS_AMBULANCE_WARNING', ref = 0 })
check(not listed(102),
    "a police car was given the ambulance tone, which the model's own assignment refuses")
Config.chirpAssignments['ambulance'] = nil

-- ── An unresolvable entity falls back to the whitelist ────────────────────
--
-- Not a fault: a vehicle whose owner is mid-migration is briefly absent from the
-- server's view of the world. Refusing there would drop legitimate park kills.

newWindow()
world[103] = nil
add(1, 103, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(listed(103),
    'a park kill on a vehicle the server cannot resolve was dropped, which is a lost chirp '
    .. 'rather than a security decision')

newWindow()
world[104] = nil
add(1, 104, { sound = 'SHOP_TEXT_BLIP', ref = 0 })
check(not listed(104), 'the whitelist fallback accepted a sound this server never configured')

-- ── Malformed payloads ─────────────────────────────────────────────────────

newWindow()
add(1, 105, nil)
add(1, 106, { ref = 0 })
add(1, 107, { sound = '', ref = 0 })
add(1, 108, { sound = CONFIGURED.sound, ref = {} })
add(1, -5, { sound = CONFIGURED.sound, ref = 0 })
add(1, 1.5, { sound = CONFIGURED.sound, ref = 0 })
add(1, '109', { sound = CONFIGURED.sound, ref = 0 })
for _, netId in ipairs({ 105, 106, 107, 108, -5, 1.5, '109' }) do
    check(not listed(netId), ('a malformed add for %s was accepted'):format(tostring(netId)))
end

-- ── Rate limiting ──────────────────────────────────────────────────────────
--
-- Both handlers broadcast the whole list to every client, so an unbounded event is
-- an amplification primitive whether or not its payload passes.

newWindow()
local accepted = 0
for i = 1, 40 do
    local netId = 200 + i
    world[netId] = POLICE
    add(1, netId, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
    if listed(netId) then accepted = accepted + 1 end
end
check(accepted < 40, 'a single client added 40 vehicles in one tick with no limit')
check(accepted > 0, 'the rate limiter refused the first event, so nobody can park at all')

-- The limit is per player, so one flooding client cannot silence everyone else.
world[300] = POLICE
add(2, 300, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(listed(300), 'one client hitting the rate limit blocked a different client')

-- The stale-entry sweep is NOT covered here, deliberately. Its loop parks on its
-- first `Wait`, and the only way to drive it from this suite would be a stub that
-- resumed the coroutine on a schedule this file invented — which would assert that
-- the stub schedules correctly, not that the sweep is right. Said plainly rather
-- than faked: the sweep is untested.

-- An unconfigured model can never get on the list in the first place.
newWindow()
world[500] = SULTAN
add(1, 500, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(not listed(500), 'a model with no assignment was added to the chirp list')

-- ── The list goes out under ONE spelling ──────────────────────────────────
--
-- `tChirp:SyncChirpList` and the five other `tChirp:` names are gone. A
-- listener subscribed to both spellings saw every event twice, which is why
-- only the canonical one was ever documented.

newWindow()
broadcasts, retiredBroadcasts = 0, 0
world[600] = POLICE
add(1, 600, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(broadcasts > 0, 'the sync no longer goes out under its canonical name')
check(retiredBroadcasts == 0,
    'the retired `tChirp:SyncChirpList` is still being fired, so a resource listening to '
    .. 'both names sees every sync twice')

-- ── And the retired INBOUND names are not registered at all ───────────────
--
-- Not merely undocumented: absent. A handler left registered under the old name
-- is a second way into the same state that nobody is testing, and whoever is
-- still firing it would never find out they had to change.

for _, retired in ipairs({ 'tChirp:AddChirpVehicle', 'tChirp:RemoveChirpVehicle',
                           'tChirp:RequestChirpList' }) do
    check(netHandlers[retired] == nil,
        retired .. ' is still registered; the retired spellings are gone in 2.0.0')
end

-- ...and the canonical ones are, so the check above is not vacuously true.
for _, canonical in ipairs({ 'tchirp:AddChirpVehicle', 'tchirp:RemoveChirpVehicle',
                             'tchirp:RequestChirpList' }) do
    check(netHandlers[canonical] ~= nil,
        canonical .. ' is not registered -- the retired-name assertions above would pass '
        .. 'for the wrong reason')
end

-- ── The access gate ────────────────────────────────────────────────────────
--
-- THE SHIPPED DEFAULT MUST NOT CHANGE WHO CAN CHIRP. tChirp has never had a
-- use gate, so `mode = "everyone"` is what every install already does; closing
-- the gate here would break all of them.

local report = tchirpAccessReport()
check(report.modes[1] == 'everyone' and #report.modes == 1,
    'the shipped Config.access is not "everyone", so this release changes who can chirp')
check(not report.broken, 'the shipped access block does not validate')
check(Config.access.ace == 'tchirp.use',
    'the documented ace object is not `tchirp.use`; a server.cfg line is copied literally')

-- The gate itself decides. Switched to `ace`, a player without the grant is
-- refused and a player with it is not.
Config.access.mode = 'ace'
local aceGate = tlib.access.gate(Config.access, { key = 'chirpprobe', label = 'the chirp list' })
check(aceGate:allowed(1) == false, 'the ace gate admitted a player holding nothing')
acePrincipals[2] = { ['tchirp.use'] = true }
check(aceGate:allowed(2) == true, '`tchirp.use` did not admit the player it was granted to')
Config.access.mode = 'everyone'

-- AND THE ADD HANDLER ACTUALLY CONSULTS IT. The two assertions above pass
-- perfectly well on a resource that builds a gate and never asks it: deleting
-- the `tchirpMayChirp` line from sv_chirp.lua leaves them green. The live gate
-- cannot be swung from here -- its mode list is a snapshot taken at
-- construction -- so the global the handler calls is what gets swapped.
local realMayChirp = tchirpMayChirp
local asked = {}
local allowChirp = true
function tchirpMayChirp(src)
    asked[#asked + 1] = src
    return allowChirp
end

newWindow()
world[950] = POLICE
allowChirp = false
add(4, 950, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(not listed(950), 'a player the gate refused still put a car on the chirp list')
check(asked[#asked] == 4, 'the gate was asked about the wrong player, or not asked at all')

allowChirp = true
add(4, 950, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(listed(950), 'a player the gate allowed could not chirp')

allowChirp = true
tchirpMayChirp = realMayChirp

-- And the two OPEN events stay open. Gating these would be the easy mistake:
-- every client runs the playback, so a gate on the read means a civilian beside
-- a chirping patrol car hears silence, and a gate on the remove makes
-- cl_chirp.lua's optimistic local clear lie to the player.
check(netHandlers['tchirp:RequestChirpList'] ~= nil, 'the list request stopped being registered')
newWindow()
world[900] = POLICE
add(1, 900, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
remove(2, 900)
check(not listed(900),
    'a player other than the one who parked the car could not silence it; the remove handler '
    .. 'has grown an ownership or permission check it is documented not to have')

print = realPrint
print('PASS chirp-server.lua')
