-- Startup validation for config.lua, through tlib.config.
--
-- Runs on BOTH VMs, immediately after config.lua and before any client or
-- server chunk, so a mistyped key is a line in the console at boot instead of a
-- setting that silently did nothing forever. Unvalidated, `chirpMinIntervalMs`
-- spelled `chirpMinInverval` reaches the chirp thread as nil and dies on
-- `math.random(nil, 6000)` with an error that names neither the file nor the key.
--
-- ── Where the numbers live ───────────────────────────────────────────────────
--
-- `config.lua` IS THE AUTHORITY. The `default =` fields below are only what
-- tlib.config writes into `Config` for a key the owner DELETED; tlib.config never
-- overwrites a value the owner actually set. `scripts/tests/config-spec.lua`
-- asserts the two files agree, literal for literal, and that the shipped file
-- passes its own spec with zero errors and zero warnings.
--
-- Do not restate the non-scalar defaults (`sirenResources`,
-- `chirpAssignments`) here. The type is enough to catch the mistake that
-- actually happens — a bare string where a table belongs — and their INSIDES
-- are checked below, by code, because a shape error there is what silently
-- stops one model chirping.
--
-- ── The two pair rules are hand-written, and FATAL ───────────────────────────
--
-- tlib.config validates keys independently, and a `min`/`max` per key cannot
-- say "this key must not exceed that key". Both of tChirp's ranges are pairs.
-- Undeclared, a reversed pair is not a wrong value: it is a bare
-- `bad argument #2 to 'random' (interval is empty)` thrown inside a
-- Citizen.CreateThread, which kills the chirp loop for the rest of the session
-- and names nothing.

local RESOURCE = 'tChirp'
local FILE = 'config.lua'

--- Global so `tchirp_diag` can re-run the same checks on demand rather than
--- asking an owner to restart and catch the boot lines scrolling past.
tchirpConfigSpec = {
    file = FILE,
    resource = RESOURCE,
    keys = {
        -- ── Access ───────────────────────────────────────────────────────────
        -- tlib.access validates the INSIDE of the block (mode spelling, the
        -- job map's grades, a `custom` that is not a function) and prints its
        -- own problems at boot. Do not restate any of that here; the copy will
        -- disagree with the one the gate acts on. All this spec owns is that
        -- the key is called `access` and is a table.
        --
        -- No default. A missing block is legal: tlib.access falls back to its
        -- own "everyone", which is the value config.lua ships, so deleting the
        -- block changes nothing.
        access = { type = 'table' },

        -- ── Siren provider ───────────────────────────────────────────────────
        -- client/cl_sirens.lua resolves the value against a table of checkers,
        -- and an unlisted name resolves to nil, which makes IsSirenActive
        -- answer false forever. Without the oneOf a typo'd provider looks
        -- exactly like "the chirp never works", with no error anywhere.
        sirenSystem = {
            type = 'string', default = 'auto',
            oneOf = { 'auto', 'tels', 'lvc', 'lvc_fleet', 'els_fivem', 'jls', 'als', 'native' },
        },

        -- Only the type. The keys INSIDE it are resource names, which cannot be
        -- validated without asserting that a server has a resource installed —
        -- and every one of them is optional.
        sirenResources = { type = 'table' },

        -- ── Timing ───────────────────────────────────────────────────────────
        -- min = 1 rather than 0: both go straight into math.random as the low
        -- bound, and a 0 ms gap is a chirp every frame. No max -- the code
        -- enforces no upper bound, so there is none to declare.
        chirpMinIntervalMs = { type = 'number', default = 4000, min = 1 },
        chirpMaxIntervalMs = { type = 'number', default = 6000, min = 1 },
        chirpMinDurationMs = { type = 'number', default = 75, min = 1 },
        chirpMaxDurationMs = { type = 'number', default = 125, min = 1 },

        -- ── Assignments ──────────────────────────────────────────────────────
        -- A map of model name → { sound, ref }, so `list` would reject it.
        -- An EMPTY table is legal and means "nothing chirps".
        chirpAssignments = { type = 'table' },

        debug = { type = 'boolean', default = false },
    },

    -- Do not add a `deprecated` table. config.lua is not escrow-packed, so a
    -- server that keeps its old file keeps every old key in it, and each one
    -- must trip the unknown-key check -- named, at every boot, as a setting
    -- that is doing nothing. Mapped silently instead, a renamed key would read
    -- as working while the shipped default applied. The mapping belongs in
    -- docs -> Configuration -> Settings that are gone.
}

--- Rules tlib.config cannot express, and the shape checks for the two tables it
--- is only told the type of. Separated from the spec so `tchirp_diag` can print
--- them with the rest.
--- @return string[] problems  empty when the file is coherent
local function crossChecks(cfg)
    local problems = {}
    local function bad(message)
        problems[#problems + 1] = ('[%s] %s: %s'):format(RESOURCE, FILE, message)
    end

    local function pair(minKey, maxKey, what)
        local lo, hi = cfg[minKey], cfg[maxKey]
        -- Only when both are numbers: a wrong TYPE is already an error from
        -- tlib.config, and reporting it twice in different words reads like two
        -- separate faults.
        if type(lo) == 'number' and type(hi) == 'number' and lo > hi then
            bad(('Config.%s (%s) is greater than Config.%s (%s), so no %s can be drawn.\n  Fix: make %s the smaller of the two in %s.')
                :format(minKey, tostring(lo), maxKey, tostring(hi), what, minKey, FILE))
        end
    end

    pair('chirpMinIntervalMs', 'chirpMaxIntervalMs', 'gap between chirps')
    pair('chirpMinDurationMs', 'chirpMaxDurationMs', 'chirp length')

    -- Assignment shapes. Reported rather than skipped: a malformed entry is one
    -- model that quietly never chirps while every other one does, which is the
    -- hardest version of this bug to notice. Not fatal — the other models are
    -- fine and refusing to start would take them down too.
    if type(cfg.chirpAssignments) == 'table' then
        for model, entry in pairs(cfg.chirpAssignments) do
            if type(model) ~= 'string' then
                bad(('Config.chirpAssignments has a key that is not a model name (%s).\n  Fix: keys are vehicle spawn names, as strings.')
                    :format(tostring(model)))
            elseif type(entry) ~= 'table' then
                bad(('Config.chirpAssignments["%s"] is %s, not a table.\n  Fix: write it as { sound = "VEHICLES_HORNS_POLICE_WARNING", ref = 0 }. A bare siren ID is the 1.0.0 documentation and is not read.')
                    :format(model, type(entry)))
            elseif type(entry.sound) ~= 'string' or entry.sound == '' then
                bad(('Config.chirpAssignments["%s"] has no `sound` name.\n  Fix: add sound = "VEHICLES_HORNS_POLICE_WARNING", or delete the entry so the model does not chirp.')
                    :format(model))
            elseif entry.ref ~= nil and type(entry.ref) ~= 'string' and type(entry.ref) ~= 'number' then
                bad(('Config.chirpAssignments["%s"].ref is %s.\n  Fix: a soundset name, or 0 for none.')
                    :format(model, type(entry.ref)))
            end
        end
    end

    return problems
end

--- Validate `Config` and print everything. Re-runnable: `tchirp_diag` calls it.
--- @return boolean ok  false when the resource must not run
function tchirpConfigOk()
    local ok = tlib.config.check(Config, tchirpConfigSpec)

    local problems = crossChecks(Config)
    for _, message in ipairs(problems) do print('^1' .. message .. '^7') end
    if #problems > 0 then
        print(('^1[%s] %d configuration error(s) above. Fix them in %s and restart.^7')
            :format(RESOURCE, #problems, FILE))
    end

    return ok and #problems == 0
end

--- The boot verdict, read by client/cl_chirp.lua and server/sv_chirp.lua.
---
--- A global boolean rather than each VM calling `tchirpConfigOk()` itself:
--- calling it twice per VM would print the same wall of red twice, and an owner
--- reading a duplicated error reasonably concludes there are two of them.
tchirpConfigValid = tchirpConfigOk()
