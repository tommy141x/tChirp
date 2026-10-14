fx_version 'cerulean'
game 'gta5'

name 'tChirp'
description 'Park-kill siren chirp reminder for FiveM'
author 'Tommy Johnston'
-- Second author entry, not a rename of the first: tlib.versioncheck grants the
-- studio banner only when the CALLING resource's manifest carries an author
-- equal to 'TIMMYG Studios'. Folder name and opts.name do not count.
author 'TIMMYG Studios'
version '2.0.0'

lua54 'yes'

dependency 'tLib'

-- 1.0 — the first tLib that carries `occupancy` and `diag.command`, both of
-- which this resource is now configuration for. There is no lower floor to
-- express: 0.6 is the only earlier tLib ever released, and it has neither.
--
-- A floor that is too LOW is the failure this line exists to prevent, not one
-- that is too high: tLib's imports.lua answers an unknown module name with a
-- truthy export PROXY rather than nil, so a missing module is not caught by any
-- `if tlib.occupancy` guard. It lands as "attempt to index a function value"
-- partway down client/cl_chirp.lua — and for `diag.command`, which builds
-- `tchirp_diag` at FILE SCOPE in server/sv_chirp.lua, while that script loads —
-- instead of as "update tLib". The gate in @tLib/imports.lua runs before any
-- consumer script, which is what makes it the only place that can say the latter.
tlib_min_version '1.0'


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
    -- Last: /tchirp's dialog reads the globals both files above declare
    -- (tchirpAssignmentFor, tchirpNearestChirping, tchirpResolvedProvider).
    -- Only at runtime, inside the command handler, so the order is for
    -- readability rather than correctness -- but it also means a load failure
    -- here cannot take the chirp loop itself down.
    'client/cl_menu.lua',
}

server_scripts {
    -- Before sv_chirp.lua, whose add handler calls tchirpMayChirp. The gate is
    -- built at file scope from Config.access, so after shared/config-spec.lua --
    -- every shared_script is.
    'server/sv_access.lua',
    'server/sv_chirp.lua',
    'server/sv_version.lua',
}

-- No `escrow_ignore`. tChirp is free and source-available: escrow_ignore exists
-- to carve readable exceptions OUT of an encrypted build, so on a resource that
-- is never escrow-packed it is not a smaller carve-out, it is a claim about the
-- build that is not true. The whole tree is readable; there is nothing to
-- except. See LICENSE.
