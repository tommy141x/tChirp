-- =========================================================================
--  tChirp configuration
-- =========================================================================
--
--  THIS FILE IS THE AUTHORITY for every default below. It is the file you
--  read and edit, and the table in docs/content/configuration.mdx is written
--  from it.
--
--  `shared/config-spec.lua` restates the scalar defaults so that a key you
--  DELETE comes back as the value shipped here. It never overwrites a value
--  you actually set — a rejected value is reported and left alone.
--  `scripts/tests/config-spec.lua` asserts the two agree.
--
--  Nothing here is required. tChirp runs with zero edits.
-- =========================================================================

Config = {}

-- =========================================================================
--  SIREN SYSTEM
-- =========================================================================
--  Which siren provider tChirp asks whether the siren was on when you left
--  the vehicle — the "park kill" trigger.
--
--  'auto'      - cascade: tELS → LVC / LVC Fleet → ELS-FiveM → JLS → ALS → native
--  'tels'      - tELS only
--  'lvc'       - Luxart Vehicle Control only
--  'lvc_fleet' - LVC Fleet only
--  'els_fivem' - ELS-FiveM only
--  'jls'       - JLS only
--  'als'       - Advanced Lighting System only
--  'native'    - native GTA siren only

Config.sirenSystem = 'auto'

--  Only the EXPORT-based providers have a resource name here, because a name is
--  only needed to call an export. tELS and JLS are queried with
--  `exports[<name>]:IsSirenActive(vehicle)`.
--
--  LVC, LVC Fleet, ALS and ELS-FiveM are event-based — tChirp listens for
--  `lvc:UpdateThirdParty`, the four `ALS:*SirenClient` events and
--  `els:setSirenState_c`. An event arrives under its own name whatever the
--  sending resource is called, so there is nothing to configure and renaming
--  those resources does not break detection.
--
--  Only change these if your tELS or JLS folder has been renamed.
Config.sirenResources = {
    tels = 'tELS',
    jls  = 'Jace3483_JLS',
}

-- =========================================================================
--  CHIRP TIMING
-- =========================================================================
--  Both ranges are inclusive and are drawn fresh for every chirp. Setting a
--  minimum above its maximum is refused at startup rather than crashing the
--  chirp thread later — see shared/config-spec.lua.

Config.chirpMinIntervalMs = 4000   -- Shortest gap between chirps
Config.chirpMaxIntervalMs = 6000   -- Longest gap between chirps
Config.chirpMinDurationMs = 75     -- Shortest chirp
Config.chirpMaxDurationMs = 125    -- Longest chirp

-- =========================================================================
--  VEHICLE ASSIGNMENTS
-- =========================================================================
--  Key   : vehicle spawn/model name
--  sound : native sound name passed to PlaySoundFromEntity
--  ref   : soundset name, or 0 for no soundset (standard native sounds)
--
--  A model that is not listed here never chirps. That is the on/off switch:
--  delete an entry to stop that model chirping.
--
--  Common native sounds (ref = 0, no extra resource required):
--    'VEHICLES_HORNS_POLICE_WARNING'    — short attention chirp  ← default
--    'VEHICLES_HORNS_SIREN_1'           — wail (long continuous tone)
--    'VEHICLES_HORNS_SIREN_2'           — yelp
--    'VEHICLES_HORNS_AMBULANCE_WARNING' — powercall / ambulance chirp
--
--  WM Sirens (requires the wm-siren resource, ref = soundset name):
--    { sound = 'SIREN_ALPHA',    ref = 'DLC_WMSIRENS_SOUNDSET' }
--    { sound = 'SIREN_PRIORITY', ref = 'DLC_WMSIRENS_SOUNDSET' }

Config.chirpAssignments = {
    ['police']   = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['police2']  = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['police3']  = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['police4']  = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['sheriff']  = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['sheriff2'] = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['fbi']      = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
    ['fbi2']     = { sound = 'VEHICLES_HORNS_POLICE_WARNING', ref = 0 },
}

-- =========================================================================
--  DIAGNOSTICS
-- =========================================================================
--  Lowers tChirp's log level to DEBUG on both VMs. Leave it off on a live
--  server: a busy department produces a line per chirp per parked car.

Config.debug = false
