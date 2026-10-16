-- `/tchirp` — the status dialog. tChirp has no editor, so there is no
-- `/tchirpedit`.
--
-- Mostly a READOUT. Every setting is server-side `config.lua` and there is no
-- per-player preference, deliberately: a chirp is a reminder to the person who
-- left the siren on, and letting them switch it off for themselves removes the
-- only thing it does. So the dialog answers questions — will THIS car chirp
-- when I park it, is anything chirping, and which of the six siren providers
-- answered for this vehicle. That last one is the support story: `tchirp_diag`
-- prints it to the server console, where the confused player cannot see it.
--
-- The one ACTION is Silence. It sends the same `tchirp:RemoveChirpVehicle`
-- event that taking a front seat sends, and the server deliberately applies no
-- ownership check to it (see server/sv_chirp.lua).
--
-- Read-only rows are tLib's `display` type: text, full opacity, carrying no
-- value. They were disabled buttons until tLib grew the type, which meant seven
-- of this dialog's ten rows — every readout it exists for — rendered greyed out
-- with `cursor: not-allowed`, so the whole thing looked broken.

local log = tlib.logger.create('tChirp')

if not tchirpConfigValid then
    -- Same early return every other chunk takes on a broken config. Registering
    -- the command anyway would offer a dialog whose every reading is a lie,
    -- because `Config` was never filled in.
    return
end

local DIALOG = 'tchirp_status'

--- How far away a chirping car counts as "this one", in metres.
---
--- 50 m rather than unbounded: the list is server-wide and the nearest entry
--- could be across the map, where "Silence It" would be an action at a distance
--- on a car the player cannot see or hear. A chirp is audible well inside this.
local SILENCE_RANGE = 50.0

local function modelLabel(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    local name = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    if type(name) ~= 'string' or name == '' or name == 'CARNOTFOUND' then return nil end
    -- The spawn name is kept alongside the label rather than replaced by it:
    -- it is the key config.lua is keyed on, and an owner reading this row is
    -- about to go and look for it.
    local label = GetLabelText(name)
    if type(label) == 'string' and label ~= '' and label ~= 'NULL' then
        return ('%s (%s)'):format(label, name:lower())
    end
    return name:lower()
end

local function buildFields()
    local fields = {}

    local ped = PlayerPedId()
    local vehicle = IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false) or 0

    if vehicle ~= 0 then
        local label = modelLabel(vehicle) or 'this vehicle'
        local assignment = tchirpAssignmentFor(vehicle)

        if assignment then
            fields[#fields + 1] = { id = 'thisChirps', type = 'display',
                label = ('Will chirp on park: yes — %s'):format(label),
                description = ('Sound: %s%s. It chirps when you leave a front seat with the siren on.')
                    :format(tostring(assignment.sound),
                        (assignment.ref and assignment.ref ~= 0)
                            and (', soundset ' .. tostring(assignment.ref)) or '') }
        else
            -- Spell out WHICH name the key is, because both names an owner can
            -- see are the wrong one. `GetDisplayNameFromVehicleModel` returns
            -- `vehicles.meta`'s <gameName>, and so does Luxart's `/lvcdebug`;
            -- the key here is <modelName>, the spawn name. On stock cars they
            -- coincide (`police` either way) and nothing looks wrong, but on an
            -- add-on they routinely differ and every surface an owner can reach
            -- then shows a string that will never match. A support ticket was
            -- lost to exactly that, with the row saying only "no entry".
            fields[#fields + 1] = { id = 'thisChirps', type = 'display',
                label = ('Will chirp on park: no — %s'):format(label),
                description = 'This model has no entry in Config.chirpAssignments, which is the on/off '
                .. 'switch: a model that is not listed never chirps. The key is the '
                .. "vehicle's SPAWN name (<modelName> in its vehicles.meta), not the "
                .. 'display name shown here and not the name /lvcdebug reports — on an '
                .. 'add-on those are often different. Model hash: '
                .. ('%d.'):format(GetEntityModel(vehicle)) }
        end

        -- The provider verdict. Named even when it says the siren is off,
        -- because WHICH provider answered is the fact that explains a car that
        -- does not chirp — an ALS car reaching the native check reads as siren-on
        -- forever, and that is exactly what the cascade exists to prevent.
        local provider, answer = tchirpResolvedProvider(vehicle)
        if provider then
            fields[#fields + 1] = { id = 'thisSiren', type = 'display',
                label = ('Siren right now: %s'):format(answer and 'on' or 'off'),
                description = ('Answered by %s. On `auto`, the first provider to claim a vehicle owns it; '
                 .. 'the ones below it are never asked.')
                    :format(TCHIRP_PROVIDER_LABELS[provider] or provider) }
        else
            fields[#fields + 1] = { id = 'thisSiren', type = 'display',
                label = 'Siren right now: no provider claims this vehicle',
                description = 'Every checker answered "not my vehicle". With Config.sirenSystem = "auto" '
                .. 'that should be impossible — the native check always answers — so this '
                .. 'means the pinned provider does not know this car.' }
        end
    else
        fields[#fields + 1] = { id = 'thisChirps', type = 'display', label = 'Not in a vehicle',
            description = 'Get into a front seat to see whether that car is configured to chirp, and which '
            .. 'siren provider is answering for it.' }
    end

    local count = tchirpChirpingCount()
    fields[#fields + 1] = { id = 'chirpingCount', type = 'display',
        label = count == 1 and 'Chirping now: 1 vehicle' or ('Chirping now: %d vehicles'):format(count),
        description = 'Server-wide, as this client last heard it. Every client plays every chirp locally, '
        .. 'because the sound is positional in each listener\'s own world.' }

    local netId, nearVeh, dist = tchirpNearestChirping(SILENCE_RANGE)
    if netId then
        fields[#fields + 1] = { id = 'silence', type = 'button', variant = 'primary',
            label = ('Silence %s — %dm away'):format(modelLabel(nearVeh) or 'the nearest one', math.floor(dist + 0.5)),
            description = 'Takes it off the list, the same as someone getting into it would. '
                       .. 'It chirps again the next time it is parked with the siren on.' }
    elseif count > 0 then
        fields[#fields + 1] = { id = 'silenceNone', type = 'display',
            label = ('Nothing chirping within %dm'):format(math.floor(SILENCE_RANGE)),
            description = 'Something is on the list, but not near enough to you to be the thing you can hear.' }
    end

    -- Config facts, so an owner can confirm from in game what the file says
    -- without reading the server console. `tchirp_diag` remains the full report.
    local modelCount = 0
    for _ in pairs(Config.chirpAssignments or {}) do modelCount = modelCount + 1 end

    fields[#fields + 1] = { id = 'install', type = 'display',
        label = ('Provider: %s · %d model%s configured')
            :format(tostring(Config.sirenSystem), modelCount, modelCount == 1 and '' or 's'),
        description = ('Chirps every %d-%dms for %d-%dms. All of it is config.lua; `tchirp_diag` in the '
         .. 'server console prints the full report.')
            :format(Config.chirpMinIntervalMs, Config.chirpMaxIntervalMs,
                    Config.chirpMinDurationMs, Config.chirpMaxDurationMs) }

    fields[#fields + 1] = { id = 'refresh', type = 'button', label = 'Refresh' }

    return fields
end

local function open()
    local ok, err = pcall(function()
        exports['tLib']:ShowDialog(DIALOG, {
            title       = 'tChirp',
            size        = 'md',
            submitLabel = 'Close',
            fields      = buildFields(),

            onButtonClick = function(fieldId)
                if fieldId == 'refresh' then
                    -- Rebuilt rather than re-opened: UpdateDialogFields keeps the
                    -- window where it is, and every row here is derived, so there
                    -- is no value to preserve across the swap.
                    exports['tLib']:UpdateDialogFields(DIALOG, buildFields())
                    return
                end

                if fieldId == 'silence' then
                    -- Re-resolved, NOT taken from the label the button was built
                    -- with. The player may have walked away, or another officer
                    -- may have got into the car, in the seconds the dialog was
                    -- open — acting on the netId baked into a stale field is how
                    -- a button silences a car that is no longer the nearest one.
                    local netId = tchirpNearestChirping(SILENCE_RANGE)
                    if netId and tchirpSilence(netId) then
                        exports['tLib']:ShowToast(nil, 'success', 'tChirp', 'Silenced.', 2000)
                    else
                        exports['tLib']:ShowToast(nil, 'warning', 'tChirp',
                            'Nothing chirping near you any more.', 2500)
                    end
                    exports['tLib']:UpdateDialogFields(DIALOG, buildFields())
                    return
                end
            end,
        })
    end)

    if not ok then
        -- A tLib taken from the repo's green "Code" button has no built UI, so
        -- ShowDialog raises. Logged rather than swallowed: a command that
        -- silently does nothing is indistinguishable from a resource that
        -- never started.
        log(('/tchirp could not open its dialog: %s'):format(tostring(err)), tlib.logger.ERROR)
        log('This is normally tLib missing its built UI files. Download tLib.zip from the '
            .. 'Releases page rather than the source archive.', tlib.logger.ERROR)
    end
end

RegisterCommand('tchirp', function()
    -- Asked every time rather than cached: this client's copy of the list is
    -- whatever the last broadcast said, and a client that connected during a
    -- quiet period has an empty one. Same reason tUnit re-asks on /tunit.
    TriggerServerEvent('tchirp:RequestChirpList')
    CreateThread(function()
        Wait(120)
        open()
    end)
end, false)

TriggerEvent('chat:addSuggestion', '/tchirp',
    'What tChirp is doing: whether this car chirps, which siren provider answers for it, '
    .. 'and what is chirping near you')
