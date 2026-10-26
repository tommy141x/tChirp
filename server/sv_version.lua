-- `studios()` is the TIMMYG Studios changelog API. A product not published there
-- yet reports "update check not run" rather than claiming the installed version
-- is current.
local current = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)

tlib.versioncheck({
    name    = 'tChirp',
    current = current,
    author  = 'TIMMYG Studios',
    fetch   = tlib.versioncheck.studios('tChirp', current),
    -- Fired by sv_chirp.lua's onResourceStart. NOT `required`: a config.lua with
    -- errors stops that file before it registers anything, and the banner must
    -- still draw on exactly that install.
    info    = {
        { key = 'Models', event = 'tchirp:vcInfo:models' },
        { key = 'Sirens', event = 'tchirp:vcInfo:sirens' },
    },
})
