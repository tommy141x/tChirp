fx_version 'cerulean'
game 'gta5'

name 'tChirp'
description 'Park-kill siren chirp reminder for FiveM'
author 'Tommy Johnston'
-- tlib.versioncheck looks for an author equal to 'TIMMYG Studios'; nothing else
-- it can read identifies the resource as ours.
author 'TIMMYG Studios'
version '2.0.0'

lua54 'yes'

dependency 'tLib'

-- 1.0 is the first tLib with `occupancy` and `diag.command`. A missing tLib
-- module is a truthy export proxy, not nil, so on an older tLib no guard
-- catches it and you get "attempt to index a function value" partway down a
-- script instead of "update tLib".
tlib_min_version '1.0'

shared_scripts {
    '@tLib/imports.lua',
    'config.lua',
    -- After the file it validates and before every other chunk. Shared, not
    -- server-only: the server reads chirpAssignments to whitelist a client's
    -- payload, so it needs the same filled-in table.
    'shared/config-spec.lua',
}

client_scripts {
    -- Before cl_chirp.lua: it calls tchirpIsSirenActive, and the provider
    -- cascade registers its event handlers at file scope.
    'client/cl_sirens.lua',
    'client/cl_chirp.lua',
    'client/cl_menu.lua',
}

server_scripts {
    -- Before sv_chirp.lua: its add handler calls tchirpMayChirp, and the gate
    -- is built at file scope.
    'server/sv_access.lua',
    'server/sv_chirp.lua',
    'server/sv_version.lua',
}
