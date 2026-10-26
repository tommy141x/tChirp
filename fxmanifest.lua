fx_version 'cerulean'
game 'gta5'

name 'tChirp'
description 'Park-kill siren chirp reminder for FiveM'
author 'Tommy Johnston'
-- Second author entry, not a rename of the first: tlib.versioncheck grants the
-- studio banner only when the CALLING resource's manifest carries an author
-- equal to 'TIMMYG Studios'. Folder name and opts.name do not count.
author 'TIMMYG Studios'
version '2.0.1'

lua54 'yes'

dependency 'tLib'

-- 1.0 is the first tLib carrying `occupancy` and `diag.command`, which tChirp
-- cannot run without. Do not lower this line to start on an older tLib: a
-- missing module is not nil, it is a truthy export proxy, so no `if
-- tlib.occupancy` guard catches it and you get "attempt to index a function
-- value" partway down a script instead of "update tLib".
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

-- No `escrow_ignore`, and do not add one. tChirp is never escrow-packed, so
-- every file here is already readable; the block only carves exceptions out of
-- an encrypted build, and declaring one would assert a build that does not
-- exist. See LICENSE.
