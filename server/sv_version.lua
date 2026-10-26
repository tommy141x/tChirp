-- The startup update check: one request, an eight-second timeout, nothing held
-- up if it fails. `studios()` is the TIMMYG Studios changelog API, which reports
-- "update check not run" rather than claiming the installed version is current
-- when the product is not published there yet.
local current = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)

tlib.versioncheck({
    name    = 'tChirp',
    current = current,
    author  = 'TIMMYG Studios',
    fetch   = tlib.versioncheck.studios('tChirp', current),
    -- Fired by sv_chirp.lua's onResourceStart. NOT `required`: a config.lua with
    -- errors stops that file before it registers anything, and a banner that
    -- refuses to draw over a missing row is worst on exactly the install that
    -- most needs the version check to stay readable.
    info    = {
        { key = 'Models', event = 'tchirp:vcInfo:models' },
        { key = 'Sirens', event = 'tchirp:vcInfo:sirens' },
    },
})
