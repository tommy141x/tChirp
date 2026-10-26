fx_version 'cerulean'
game 'gta5'

name 'tChirp'
description 'Park-kill siren chirp reminder for FiveM'
author 'Tommy Johnston'
-- A second author entry, not a rename of the first: tlib.versioncheck grants the
-- studio banner only when the calling resource's manifest carries an author
-- equal to 'TIMMYG Studios'. Folder name and opts.name do not count.
author 'TIMMYG Studios'
version '2.0.0'

lua54 'yes'

dependency 'tLib'

-- ⚠️ 1.0 is the first tLib carrying `occupancy` and `diag.command`. Do not lower
-- it to start on an older tLib: a missing module is not nil, it is a truthy
-- export proxy, so no `if tlib.occupancy` guard catches it and you get "attempt
-- to index a function value" partway down a script instead of "update tLib".
tlib_min_version '1.0'


shared_scripts {
    '@tLib/imports.lua',
    'config.lua',
    -- Immediately after the file it validates, and before every client and
    -- server chunk. Shared, not server-only: the server reads chirpAssignments
    -- to whitelist a client's payload, so it needs the same filled-in table.
    'shared/config-spec.lua',
}

client_scripts {
    -- Before cl_chirp.lua: it calls tchirpIsSirenActive, and the provider
    -- cascade registers its event handlers at file scope.
    'client/cl_sirens.lua',
    'client/cl_chirp.lua',
    -- Last. The dialog only reads the globals above at runtime, so the order is
    -- for readability -- but it also means a load failure here cannot take the
    -- chirp loop down.
    'client/cl_menu.lua',
}

server_scripts {
    -- Before sv_chirp.lua, whose add handler calls tchirpMayChirp. The gate is
    -- built at file scope from Config.access.
    'server/sv_access.lua',
    'server/sv_chirp.lua',
    'server/sv_version.lua',
}
