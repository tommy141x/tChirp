-- Startup validation for config.lua, through tlib.config.
--
-- Runs on BOTH VMs, immediately after config.lua and before any client or server
-- chunk. Unvalidated, `chirpMinIntervalMs` spelled `chirpMinInverval` reaches the
-- chirp thread as nil and dies on `math.random(nil, 6000)` with an error naming
-- neither the file nor the key.
--
-- `config.lua` IS THE AUTHORITY. The `default =` fields are only what tlib.config
-- writes into `Config` for a key the owner DELETED; it never overwrites a value
-- the owner set. scripts/tests/config-spec.lua asserts the two files agree
-- literal for literal, and that the shipped file passes with zero errors and
-- zero warnings.
--
-- The two pair rules below are hand-written and FATAL, because tlib.config
-- validates keys independently and a per-key min/max cannot say "this key must
-- not exceed that key". Undeclared, a reversed pair is a bare
-- `bad argument #2 to 'random' (interval is empty)` thrown inside a
-- Citizen.CreateThread, which kills the chirp loop for the session and names
-- nothing.

local RESOURCE = 'tChirp'
local FILE = 'config.lua'

--- Global so `tchirp_diag` can re-run the same checks on demand, rather than
--- asking an owner to restart and catch the boot lines scrolling past.
tchirpConfigSpec = {
    file = FILE,
    resource = RESOURCE,
    keys = {
        -- tlib.access validates the inside of the block (mode spelling, the job
        -- map's grades, a `custom` that is not a function) and prints its own
        -- problems at boot. Restating any of it here gives a copy that can
        -- disagree with the one the gate acts on. No default, because a missing
        -- block is legal: tlib.access falls back to its own "everyone", which is
        -- what config.lua ships.
        access = { type = 'table' },

        -- An unlisted name resolves to nil in cl_sirens.lua's checker table,
        -- making IsSirenActive answer false forever. Without the oneOf a typo'd
        -- provider looks exactly like "the chirp never works".
        sirenSystem = {
            type = 'string', default = 'auto',
            oneOf = { 'auto', 'tels', 'lvc', 'lvc_fleet', 'els_fivem', 'jls', 'als', 'native' },
        },

        -- Only the type: the keys inside are resource names, which cannot be
        -- validated without asserting a server has a resource installed, and
        -- every one of them is optional.
        sirenResources = { type = 'table' },

        -- min = 1 rather than 0: both go into math.random as the low bound, and
        -- a 0 ms gap is a chirp every frame.
        chirpMinIntervalMs = { type = 'number', default = 4000, min = 1 },
        chirpMaxIntervalMs = { type = 'number', default = 6000, min = 1 },
        chirpMinDurationMs = { type = 'number', default = 75, min = 1 },
        chirpMaxDurationMs = { type = 'number', default = 125, min = 1 },

        -- A map of model name → { sound, ref }, so `list` would reject it. An
        -- empty table is legal and means "nothing chirps".
        --
        -- ⚠️ `default` matters here, unlike on the other tables. cl_chirp.lua and
        -- sv_chirp.lua both walk this with a bare `pairs()` at FILE scope, so an
        -- operator who drops the key -- which merging a shipped config forward
        -- makes easy -- gets `bad argument #1 to 'pairs' (table expected, got
        -- nil)` and NEITHER file loads. The resource is then dead with
        -- `tchirp_diag` never registered to say why.
        --
        -- tlib.config assigns a default BY REFERENCE (`tbl[key] = def.default`),
        -- so this table is shared with Config. Nothing writes to it; if that
        -- changes, copy it here instead.
        chirpAssignments = { type = 'table', default = {} },

        debug = { type = 'boolean', default = false },
    },

    -- ⚠️ No `deprecated` table: a silently mapped old key reads as working while
    -- the shipped default applies. Old keys must trip the unknown-key check and
    -- be named at every boot instead.
}

--- Rules tlib.config cannot express, plus the shape checks for the tables it is
--- only told the type of. Separate from the spec so `tchirp_diag` can print them
--- with the rest.
--- @return string[] problems  empty when the file is coherent
local function crossChecks(cfg)
    local problems = {}
    local function bad(message)
        problems[#problems + 1] = ('[%s] %s: %s'):format(RESOURCE, FILE, message)
    end

    local function pair(minKey, maxKey, what)
        local lo, hi = cfg[minKey], cfg[maxKey]
        -- Only when both are numbers: a wrong type is already an error from
        -- tlib.config, and reporting it twice reads like two separate faults.
        if type(lo) == 'number' and type(hi) == 'number' and lo > hi then
            bad(('Config.%s (%s) is greater than Config.%s (%s), so no %s can be drawn.\n  Fix: make %s the smaller of the two in %s.')
                :format(minKey, tostring(lo), maxKey, tostring(hi), what, minKey, FILE))
        end
    end

    pair('chirpMinIntervalMs', 'chirpMaxIntervalMs', 'gap between chirps')
    pair('chirpMinDurationMs', 'chirpMaxDurationMs', 'chirp length')

    -- Assignment shapes. Reported rather than skipped: a malformed entry is one
    -- model that quietly never chirps while the rest do, the hardest version of
    -- this bug to notice. Not fatal — refusing to start would take the healthy
    -- models down too.
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

--- The boot verdict, read by cl_chirp.lua and sv_chirp.lua. A boolean rather
--- than each chunk calling `tchirpConfigOk()` itself: calling it twice per VM
--- prints the same wall of red twice, and an owner reading a duplicated error
--- reasonably concludes there are two of them.
tchirpConfigValid = tchirpConfigOk()
