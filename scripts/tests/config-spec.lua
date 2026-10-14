-- shared/config-spec.lua against the config file it validates.
--
-- Loads tLib's REAL config module out of the sibling directory rather than
-- stubbing it. A stubbed validator would assert that this suite agrees with
-- itself; what has to hold is that the file we ship passes the spec tLib
-- actually runs.

local ROOT = (arg[0] or ''):match('^(.*)scripts[/\\]tests[/\\]') or './'
local function path(p) return ROOT .. p end

function GetCurrentResourceName() return 'tChirp' end

-- Everything printed by config.check is expected output, not a result. Captured
-- so a passing run is quiet and a failing one still has the text to show.
local printed = {}
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

tlib = { config = dofile(path('../tLib/shared/imports/config/shared.lua')) }

dofile(path('config.lua'))
local shipped = Config
dofile(path('shared/config-spec.lua'))

print = realPrint

local function fail(message)
    for _, text in ipairs(printed) do realPrint('    ' .. text) end
    error(message, 2)
end

-- ── The file we ship passes its own spec ────────────────────────────────────
--
-- The one assertion that has to hold forever. A spec that rejects the shipped
-- config would greet every new install with a wall of red on a file the owner has
-- not touched, which is worse than no validation at all.

if not tchirpConfigValid then
    fail('config.lua does not pass shared/config-spec.lua')
end

local report = tlib.config.validate(shipped, tchirpConfigSpec)
if #report.errors ~= 0 then fail(#report.errors .. ' error(s) on the shipped config') end

-- No warnings either, which is stronger than it looks: an unknown key warns, so
-- this is also the assertion that the spec's key set and config.lua's key set are
-- the SAME set. Drop a key from the spec and this fails; add one to the spec that
-- config.lua does not ship and the default-parity block below fails.
if #report.warnings ~= 0 then
    fail(#report.warnings .. ' warning(s) on the shipped config: ' .. report.warnings[1])
end

-- ── Nothing is required ─────────────────────────────────────────────────────
-- The house north star: the product works with zero edits.

local empty = {}
local emptyReport = tlib.config.validate(empty, tchirpConfigSpec)
if not emptyReport.ok then
    fail('an empty config is fatal, so something is marked required: ' .. emptyReport.errors[1])
end

-- ── A deleted key comes back as the value config.lua ships ──────────────────
-- The whole point of carrying defaults in the spec. If these two ever disagree
-- the owner's "working" server is tuned to a number printed nowhere.

for _, key in ipairs({ 'sirenSystem', 'chirpMinIntervalMs', 'chirpMaxIntervalMs',
    'chirpMinDurationMs', 'chirpMaxDurationMs', 'debug' }) do
    if empty[key] == nil then
        fail(('Config.%s has no default in the spec, so deleting it leaves it unset'):format(key))
    end
    if empty[key] ~= shipped[key] then
        fail(('Config.%s defaults to %s in the spec but config.lua ships %s')
            :format(key, tostring(empty[key]), tostring(shipped[key])))
    end
end

-- `false` is a value, not an absence.
if empty.debug ~= false then fail('the boolean default did not survive') end

-- ── The constraints that exist are the ones the code enforces ───────────────

local function firstError(tbl)
    local r = tlib.config.validate(tbl, { file = 'config.lua', resource = 'tChirp',
        keys = tchirpConfigSpec.keys, allowUnknown = true })
    return r.errors[1]
end

if not firstError({ sirenSystem = 'luxart' }) then
    fail('an unknown sirenSystem was accepted, though cl_sirens.lua has no checker for it')
end
if not firstError({ chirpMinIntervalMs = 0 }) then
    fail('a 0 ms minimum interval was accepted, which is a chirp every frame')
end
if not firstError({ chirpMinIntervalMs = '4000' }) then fail('a quoted number was accepted') end
if not firstError({ chirpAssignments = 'police' }) then
    fail('a bare string where the assignment TABLE belongs was accepted')
end

-- ── The pair rules tlib.config cannot express ───────────────────────────────
--
-- These are the reason crossChecks() exists. Undeclared, an inverted range is a
-- bare "interval is empty" thrown inside a Citizen.CreateThread, which kills the
-- chirp loop for the session and names neither the file nor the key.

local function okWith(overrides)
    for key, value in pairs(shipped) do
        if overrides[key] == nil then overrides[key] = value end
    end
    Config = overrides
    printed = {}
    local realPrint2 = print
    print = function() end
    local verdict = tchirpConfigOk()
    print = realPrint2
    return verdict
end

if okWith({ chirpMinIntervalMs = 9000, chirpMaxIntervalMs = 6000 }) then
    fail('an inverted interval range was accepted')
end
if okWith({ chirpMinDurationMs = 500, chirpMaxDurationMs = 100 }) then
    fail('an inverted duration range was accepted')
end
-- Equal is a legal range: math.random(n, n) returns n.
if not okWith({ chirpMinIntervalMs = 5000, chirpMaxIntervalMs = 5000 }) then
    fail('a min equal to its max was rejected, though math.random accepts it')
end

-- ── Assignment shapes ───────────────────────────────────────────────────────
-- A malformed entry is one model that quietly never chirps while every other one
-- does, which is the hardest version of this bug to notice.

if okWith({ chirpAssignments = { police = 4 } }) then
    fail('a bare siren ID was accepted — that is the 1.0.0 documented shape and the code '
        .. 'does not read it, so it must be reported rather than ignored')
end
if okWith({ chirpAssignments = { police = { ref = 0 } } }) then
    fail('an assignment with no sound name was accepted')
end
if not okWith({ chirpAssignments = {} }) then
    fail('an empty assignment table was rejected, though "nothing chirps" is a supported state')
end

-- ── The 1.0.0 key names are NAMED at boot, not quietly dropped ──────────────
--
-- Nothing copies ChirpMinInterval onto chirpMinIntervalMs any more, and
-- nothing should. config.lua is not escrow-packed and never was,
-- so a server that kept ITS copy across the update is still on the old
-- spellings and will fall back to the shipped timings. The ONLY thing that
-- turns that from a silent reset into a fixable boot warning is the unknown-key
-- check firing on every one of them, which is what this now asserts.

local old = {
    ChirpMinInterval = 1000,
    ChirpMaxInterval = 2000,
    ChirpMinDuration = 50,
    ChirpMaxDuration = 60,
    ChirpAssignments = { police = { sound = 'VEHICLES_HORNS_SIREN_1', ref = 0 } },
    Debug = true,
    -- Never read even by 1.0.0; the published GitBook page documents it anyway,
    -- so it is the likeliest key to be sitting in a real file.
    LVCResourceName = 'lvc',
}
local oldReport = tlib.config.validate(old, tchirpConfigSpec)
if not oldReport.ok then
    fail('a 1.0.0 config.lua must not be FATAL, only reported: ' .. oldReport.errors[1])
end
-- The new names take their SHIPPED defaults, not the old keys' values. That is
-- the loss the warnings below exist to announce: 4000ms, not the 1000 above.
if old.chirpMinIntervalMs ~= 4000 or old.debug ~= false then
    fail('a 1.0.0 key was still carried onto its new name; nothing should translate them now')
end
for _, key in ipairs({ 'ChirpMinInterval', 'ChirpMaxInterval', 'ChirpMinDuration',
                       'ChirpMaxDuration', 'ChirpAssignments', 'Debug', 'LVCResourceName' }) do
    local sawIt = false
    for _, message in ipairs(oldReport.warnings) do
        if message:find(key, 1, true) and message:find('doing nothing', 1, true) then
            sawIt = true
        end
    end
    if not sawIt then
        fail('Config.' .. key .. ' is no longer read, and a config that still sets it was '
            .. 'not warned about -- the owner would lose the setting in silence')
    end
end

realPrint('PASS config-spec.lua')
