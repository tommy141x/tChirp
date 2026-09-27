-- The same contract, unpublished-version handling and eight-second timeout as
-- tAFK, tELS, tDetector and tRadar. tChirp had no update check at all: an owner
-- running 1.0.0 had nothing that would ever tell them a release existed.
--
-- `studios('tChirp', current)` is the TIMMYG Studios product changelog API. It
-- reports "update check not run" rather than claiming the installed version is
-- current when the product is not published there yet, which is the failure this
-- provider is specified against.
local current = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)

tlib.versioncheck({
    name    = 'tChirp',
    current = current,
    author  = 'TIMMYG Studios',
    fetch   = tlib.versioncheck.studios('tChirp', current),
})
