fx_version 'cerulean'
game 'gta5'

name 'tChirp'
description 'Park-kill siren chirp reminder for FiveM'
author 'Tommy Johnston'
-- Second author entry, not a rename of the first: tlib.versioncheck grants the
-- studio banner only when the CALLING resource's manifest carries an author
-- equal to 'TIMMYG Studios'. Folder name and opts.name do not count.
author 'TIMMYG Studios'
version '1.1.0'

lua54 'yes'

dependency 'tLib'

-- 0.8, and the module that sets the floor is `occupancy` — the shared front-seat
-- rule tELS, tRadar and tRadio use, which tRadar's own manifest records as
-- having arrived in tLib 0.8. `config`, `logger` and `versioncheck` all predate
-- it (tAFK pins 0.8 with logger; tRadar names 0.6 as the floor for `assets`),
-- so 0.8 is the highest evidenced floor rather than a round number.
--
-- A floor that is too LOW is the failure this line exists to prevent, not one
-- that is too high: tLib's imports.lua answers an unknown module name with a
-- truthy export PROXY rather than nil, so a missing module is not caught by any
-- `if tlib.occupancy` guard. It lands as "attempt to index a function value"
-- partway down client/cl_chirp.lua instead of as "update tLib".
tlib_min_version '0.8'

tlib_modules {
    -- Eager on purpose: shared/config-spec.lua validates at FILE scope, which is
    -- the whole point of it — every later chunk reads a Config that has already
    -- been checked and had its gaps filled.
    'config',
    -- Eager for the same reason: both cl_chirp.lua and sv_chirp.lua take
    -- tlib.logger.create at file scope.
    'logger',
    -- server/sv_version.lua calls tlib.versioncheck. Listing it only makes the
    -- load eager; it would lazy-load either way. Declared so the manifest is an
    -- honest inventory of what this resource uses.
    'versioncheck',
    -- The shared front-seat rule. client/cl_chirp.lua takes tlib.occupancy at
    -- FILE scope and drives it with `occupancy.poll()` from its own loop — the
    -- module's documented shape for a consumer that already has one, rather
    -- than asking it to spawn a second thread.
    'occupancy',
}

shared_scripts {
    '@tLib/imports.lua',
    'config.lua',
    -- Immediately after the file it validates, and before every client and
    -- server chunk. Both VMs: the server reads chirpAssignments to whitelist a
    -- client's payload, so it needs the same filled-in table the client has.
    'shared/config-spec.lua',
}

client_scripts {
    -- Before cl_chirp.lua: it calls tchirpIsSirenActive, and the provider
    -- cascade registers its event handlers at file scope.
    'client/cl_sirens.lua',
    'client/cl_chirp.lua',
}

server_scripts {
    'server/sv_chirp.lua',
    'server/sv_version.lua',
}

-- No `escrow_ignore`. tChirp is free and source-available: escrow_ignore exists
-- to carve readable exceptions OUT of an encrypted build, so on a resource that
-- is never escrow-packed it is not a smaller carve-out, it is a claim about the
-- build that is not true. The whole tree is readable; there is nothing to
-- except. See LICENSE.
