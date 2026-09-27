-- Startup validation for config.lua, through tlib.config.
--
-- Runs on BOTH VMs, immediately after config.lua and before any client or
-- server chunk, so a mistyped key is a line in the console at boot instead of a
-- setting that silently did nothing forever. Before this file existed tChirp had
-- no validation of any kind: `Config.ChirpMinInterval = 4000` spelled
-- `ChirpMinInverval` fell back to nothing at all and the chirp thread died on
-- `math.random(nil, 6000)` with an error that named neither the file nor the key.
--
-- ── Where the numbers live ───────────────────────────────────────────────────
--
-- `config.lua` IS THE AUTHORITY. The `default =` fields below are only what
-- tlib.config writes into `Config` for a key the owner DELETED; tlib.config never
-- overwrites a value the owner actually set. `scripts/tests/config-spec.lua`
-- asserts the two files agree, literal for literal, and that the shipped file
-- passes its own spec with zero errors and zero warnings.
--
-- Non-scalar defaults (`sirenResources`, `chirpAssignments`) are NOT restated
-- here. Writing the assignment table out a second time would be exactly the
-- duplication this header warns about, and tlib.config only needs the type to
-- catch the mistake that actually happens — a bare string where a table belongs.
-- Their INSIDES are checked below instead, by code, because a shape error there
-- is what silently stops one model chirping.
--
-- ── Why two checks are hand-written below rather than declared ───────────────
--
-- tlib.config validates keys independently. A `min`/`max` per key cannot say
-- "this key must not exceed that key", and both of tChirp's ranges are pairs.
-- The consequence of leaving it undeclared is not a wrong value, it is a bare
-- `bad argument #2 to 'random' (interval is empty)` thrown inside a
-- Citizen.CreateThread, which kills the chirp loop for the rest of the session
-- and names nothing. So the pair rules are enforced here and are FATAL.

local RESOURCE = 'tChirp'
local FILE = 'config.lua'

--- Global so `tchirp_diag` can re-run the same checks on demand rather than
--- asking an owner to restart and catch the boot lines scrolling past.
tchirpConfigSpec = {
    file = FILE,
    resource = RESOURCE,
    keys = {
        -- ── Siren provider ───────────────────────────────────────────────────
        -- The oneOf is not a taste judgement: client/cl_sirens.lua resolves the
        -- value against a table of checkers, and an unlisted name resolves to
        -- nil, which makes IsSirenActive answer false forever. A typo'd provider
        -- therefore looks exactly like "the chirp never works" with no error.
        sirenSystem = {
            type = 'string', default = 'auto',
            oneOf = { 'auto', 'tels', 'lvc', 'lvc_fleet', 'els_fivem', 'jls', 'als', 'native' },
        },

        -- Only the type. The keys INSIDE it are resource names, which cannot be
        -- validated without asserting that a server has a resource installed —
        -- and every one of them is optional.
        sirenResources = { type = 'table' },

        -- ── Timing ───────────────────────────────────────────────────────────
        -- min = 1 rather than 0 on the intervals: both go straight into
        -- math.random as the low bound, and a 0 ms gap is a chirp every frame.
        -- No max, because there is no upper bound the code enforces and a
        -- fabricated one an owner cannot argue with is worse than none.
        chirpMinIntervalMs = { type = 'number', default = 4000, min = 1 },
        chirpMaxIntervalMs = { type = 'number', default = 6000, min = 1 },
        chirpMinDurationMs = { type = 'number', default = 75, min = 1 },
        chirpMaxDurationMs = { type = 'number', default = 125, min = 1 },

        -- ── Assignments ──────────────────────────────────────────────────────
        -- A map of model name → { sound, ref }, so `list` would reject it.
        -- An EMPTY table is legal and means "nothing chirps", which is a real
        -- and supported state for a server that wants the resource loaded and
        -- inert.
        chirpAssignments = { type = 'table' },

        debug = { type = 'boolean', default = false },
    },

    -- ── Renamed in 1.1.0 ────────────────────────────────────────────────────
    --
    -- config.lua is not escrow-packed and never was, so an existing server keeps
    -- ITS copy across an update. Every one of those copies uses the 1.0.0
    -- spellings. Carrying them here is what makes this release a rename rather
    -- than a silent reset to defaults: tlib.config copies the old value onto the
    -- new name, uses it, and prints one line naming the replacement and the
    -- version the old name stops working in.
    --
    -- The `Ms` suffixes are tLib's unit convention (see its Convars page):
    -- a duration key states its unit, so `chirpMinInterval = 4` cannot be read
    -- as four seconds.
    deprecated = {
        ChirpMinInterval = { replacement = 'chirpMinIntervalMs', removeIn = '2.0.0' },
        ChirpMaxInterval = { replacement = 'chirpMaxIntervalMs', removeIn = '2.0.0' },
        ChirpMinDuration = { replacement = 'chirpMinDurationMs', removeIn = '2.0.0' },
        ChirpMaxDuration = { replacement = 'chirpMaxDurationMs', removeIn = '2.0.0' },
        ChirpAssignments = { replacement = 'chirpAssignments', removeIn = '2.0.0' },
        Debug            = { replacement = 'debug', removeIn = '2.0.0' },

        -- No replacement, deliberately. This is the key the published GitBook
        -- page still documents, and tChirp 1.0.0 already did not read it: LVC is
        -- detected from the `lvc:UpdateThirdParty` event, which arrives under
        -- that name whatever the sending resource is called. There is nothing to
        -- point an owner at, so tlib.config prints "is no longer used and does
        -- nothing" rather than inventing a target.
        LVCResourceName = { removeIn = '2.0.0' },
    },
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
