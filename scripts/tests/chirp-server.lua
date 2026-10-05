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

local broadcasts = 0
local lastList = nil
function TriggerClientEvent(event, target, payload)
    if event == 'tChirp:SyncChirpList' then
        broadcasts = broadcasts + 1
        if target == -1 then lastList = payload end
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
dofile(path('config.lua'))
dofile(path('shared/config-spec.lua'))
dofile(path('server/sv_chirp.lua'))

print = realPrint

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
    netHandlers['tChirp:AddChirpVehicle'](netId, cfg)
end
local function remove(src, netId)
    source = src
    netHandlers['tChirp:RemoveChirpVehicle'](netId)
end
local function listed(netId)
    source = 1
    local captured
    local realTrigger = TriggerClientEvent
    TriggerClientEvent = function(_, _, payload) captured = payload end
    netHandlers['tChirp:RequestChirpList']()
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

-- An unconfigured model can never get on the list in the first place, which is the
-- cheapest of all the checks and the one that makes the others rarely needed.
newWindow()
world[500] = SULTAN
add(1, 500, { sound = CONFIGURED.sound, ref = CONFIGURED.ref })
check(not listed(500), 'a model with no assignment was added to the chirp list')

print('PASS chirp-server.lua')
