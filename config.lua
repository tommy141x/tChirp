--[[----------------------------------------------------------------------
    TIMMYG Studios — tChirp 2.0.1
    config.lua — the file you edit. It is the only one.

    NOTHING HERE IS REQUIRED. tChirp runs with zero edits.

    HOW TO EDIT: change values to the RIGHT of the = sign only. Keep the
    commas, and do not remove the quotes around text.

    APPLYING CHANGES: restart the resource. `ensure tChirp` in the server
    console, or txAdmin > Resources > tChirp > Restart. Nothing here is read
    again while the server runs.

    IF SOMETHING IS WRONG: `shared/config-spec.lua` checks this file at boot.
    Delete a key and it comes back as the value shipped here; set one to
    something illegal and you get a line naming the key, the file and the
    fix. Your file is never rewritten.

    Docs: https://timmygstudios.com/docs/tChirp/configuration
------------------------------------------------------------------------]]

Config = {}

-- =========================================================================
--  1. ACCESS — who may park-kill
-- =========================================================================
--  A tlib.access block. `mode` is "everyone", "ace", "job", "item" or
--  "custom", or a list of them — any one passing opens the gate. Six
--  frameworks and nine inventories resolve out of the box, as two
--  INDEPENDENT questions, and every failure DENIES: an absent framework, an
--  unset ace, a `custom` that errors.
--
--  AS SHIPPED, `mode = "everyone"` lets any player park-kill. To limit it to
--  your police department:
--
--      Config.access = { mode = "ace" }
--      -- and in server.cfg:
--      add_ace group.police tchirp.use allow
--
--  THIS GATES ADDING A CHIRP ONLY. It does not control who can SILENCE one
--  or who HEARS them: every client runs the playback, so gating the read
--  would leave a civilian standing next to a chirping patrol car in
--  silence.

Config.access = {
    mode = "everyone",

    -- mode "ace":  add_ace group.police tchirp.use allow
    ace  = "tchirp.use",

    -- mode "job": job NAME = MINIMUM GRADE. `0` accepts any grade.
    job  = { police = 0, sheriff = 0, statepolice = 0 },

    -- mode "item".
    item  = "police_radio",
    count = 1,

    -- mode "custom". Takes a player id, returns true to allow.
    --   custom = function(playerId) return myCheck(playerId) end,
    custom = nil,
}

-- =========================================================================
--  2. SIREN SYSTEM
-- =========================================================================
--  Which siren provider tChirp asks whether the siren was on when you left
--  the vehicle — the "park kill" trigger.
--
--  'auto'      cascade: tLS → LVC / LVC Fleet → ELS-FiveM → JLS → ALS → native
--  'tels'      tLS (formerly tELS) only
--  'lvc'       Luxart Vehicle Control only
--  'lvc_fleet' LVC Fleet only
--  'els_fivem' ELS-FiveM only
--  'jls'       JLS only
--  'als'       Advanced Lighting System only
--  'native'    native GTA siren only
--
--  LEAVE THIS ON 'auto' UNLESS YOU HAVE A REASON. `auto` asks each provider in
--  turn and the first one that recognises the vehicle answers, so it is correct
--  on a mixed fleet and correct on a single-ELS server alike. Pinning removes
--  the other providers AND the fallback: a car the pinned provider does not
--  recognise is treated as siren-off and never chirps.

Config.sirenSystem = 'auto'

--  AN OVERRIDE, NOT A REQUIREMENT. Leave it empty.
--
--  tLS and JLS are the only two providers asked by export, so they are the only
--  two whose folder name matters -- and tChirp already knows the names both of
--  them ship under, current and previous, and uses whichever is running. Fill a
--  key in ONLY if you renamed the folder to something of your own; a name here
--  that is not a started resource is ignored rather than trusted.
--
--  LVC, LVC Fleet, ALS and ELS-FiveM are not listed here and cannot be: they
--  are detected by event (`lvc:UpdateThirdParty`, the four `ALS:*SirenClient`
--  events, `els:setSirenState_c`), and an event keeps its own name however the
--  sending resource is renamed.
Config.sirenResources = {
    -- tels = 'MyRenamedTLS',
    -- jls  = 'MyRenamedJLS',
}

-- =========================================================================
--  3. CHIRP TIMING
-- =========================================================================
--  Milliseconds. Both ranges are inclusive and are drawn fresh for every
--  chirp, so a gap of 4000-6000 means every chirp waits somewhere in that
--  window rather than a fixed 5 seconds.
--
--  Each value must be at least 1: they go straight into math.random as the
--  low bound, and a 0 ms gap is a chirp every frame. Setting a minimum above
--  its maximum is refused at startup rather than crashing the chirp thread
--  later.

Config.chirpMinIntervalMs = 4000   -- Shortest gap between chirps
Config.chirpMaxIntervalMs = 6000   -- Longest gap between chirps
Config.chirpMinDurationMs = 75     -- Shortest chirp
Config.chirpMaxDurationMs = 125    -- Longest chirp

-- =========================================================================
--  4. VEHICLE ASSIGNMENTS
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
--  5. DIAGNOSTICS
-- =========================================================================
--  Lowers tChirp's log level to DEBUG on both VMs. Leave it off on a live
--  server: a busy department produces a line per chirp per parked car.

Config.debug = false
