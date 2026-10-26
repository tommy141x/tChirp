-- `/tchirp` — the status dialog.
--
-- A readout, not a settings panel: every setting is server-side `config.lua` and
-- there is no per-player preference, because a chirp is a reminder to the person
-- who left the siren on and letting them mute it removes the only thing it does.
-- So it answers questions — will THIS car chirp, is anything chirping, and which
-- of the six providers answered for this vehicle. That last one is the support
-- story: `tchirp_diag` prints it to the server console, where the confused
-- player cannot see it.
--
-- The one action is Silence, which sends the same `tchirp:RemoveChirpVehicle`
-- event taking a front seat sends (not ownership-checked; see sv_chirp.lua).
--
-- Rows are tLib's `display` type, not disabled buttons: greyed out with
-- `cursor: not-allowed` a panel of readouts looks broken.

local log = tlib.logger.create('tChirp')

if not tchirpConfigValid then
    -- Registering the command on a broken config would offer a dialog whose
    -- every reading is a lie, because `Config` was never filled in.
    return
end

local DIALOG = 'tchirp_status'

--- How far away a chirping car counts as "this one", in metres. Bounded because
--- the list is server-wide: unbounded, the nearest entry can be across the map
--- and Silence becomes an action at a distance on a car nobody can hear.
local SILENCE_RANGE = 50.0

local function modelLabel(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    local name = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle))
    if type(name) ~= 'string' or name == '' or name == 'CARNOTFOUND' then return nil end
    -- The spawn name stays alongside the label: it is what config.lua is keyed
    -- on, and an owner reading this row is about to go and look for it.
    local label = GetLabelText(name)
    if type(label) == 'string' and label ~= '' and label ~= 'NULL' then
        return ('%s (%s)'):format(label, name:lower())
    end
    return name:lower()
end

--- The Feedback tab's staged draft. Module-level because `refresh()` rebuilds
--- every field once a second and the draft has to outlive that. Staged rather
--- than sent as typed: a textarea reports every keystroke, and each send is a
--- round trip under a per-minute limiter.
local feedbackMessage = ''

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
            -- ⚠️ Spell out WHICH name the key is: both names an owner can see
            -- are the wrong one. GetDisplayNameFromVehicleModel returns
            -- vehicles.meta's <gameName>, as does Luxart's /lvcdebug; the key is
            -- <modelName>, the spawn name. They coincide on stock cars (`police`
            -- either way) and routinely differ on an add-on. A support ticket was
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

        -- The provider is named even when the siren is off: which one answered is
        -- the fact that explains a car that does not chirp.
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

    -- Config facts, so an owner can confirm from in game what the file says.
    -- `tchirp_diag` remains the full report.
    local modelCount = 0
    for _ in pairs(Config.chirpAssignments or {}) do modelCount = modelCount + 1 end

    fields[#fields + 1] = { id = 'install', type = 'display',
        label = ('Provider: %s · %d model%s configured')
            :format(tostring(Config.sirenSystem), modelCount, modelCount == 1 and '' or 's'),
        description = ('Chirps every %d-%dms for %d-%dms. All of it is config.lua; `tchirp_diag` in the '
         .. 'server console prints the full report.')
            :format(Config.chirpMinIntervalMs, Config.chirpMaxIntervalMs,
                    Config.chirpMinDurationMs, Config.chirpMaxDurationMs) }

    -- Everything above is Status. tLib puts an untagged field on the first tab,
    -- so only the feedback pair below has to name its tab -- as would any row
    -- added up here in future.

    -- Built in buildFields, not at the ShowDialog call: `refresh()` replaces the
    -- whole field list once a second through UpdateDialogFields, so a field
    -- declared anywhere else survives for under a second. The typed draft
    -- survives the swap because UpdateDialogFields preserves existing values and
    -- the page keys its rows by field id, reusing the textarea node and its
    -- caret rather than rebuilding it.
    --
    -- `SubmitFeedback` attributes the message to the calling resource, so the
    -- wiring is this pair, the tab and the two handler branches -- no net event,
    -- no server file, nothing in tLib.
    fields[#fields + 1] = {
        id          = 'feedbackMessage',
        type        = 'textarea',
        label       = 'Your message',
        placeholder = "What's broken, slow, or worth changing?",
        description = 'This reaches TIMMYG Studios, who make tChirp — not this '
                   .. "server's staff. Nothing identifying you is sent with it.",
        rows        = 6,
        maxLength   = 2000,
        defaultValue = feedbackMessage,
        tab         = 'feedback',
    }
    fields[#fields + 1] = {
        id      = 'feedbackSend',
        type    = 'button',
        label   = 'Send',
        variant = 'primary',
        tab     = 'feedback',
    }

    return fields
end

-- Seven of the ten rows derive from world state that moves continuously -- the
-- siren, the chirping count, and a distance that is wrong as soon as the player
-- takes a step -- so they are re-read on a tick.

local dialogOpen = false
local refreshGeneration = 0

--- Rebuilt rather than re-opened: UpdateDialogFields keeps the window where it
--- is. Guarded on `dialogOpen` because tLib logs a line for an update aimed at a
--- closed dialog, and both callers below can fire after a close.
local function refresh()
    if not dialogOpen then return end
    exports['tLib']:UpdateDialogFields(DIALOG, buildFields())
end

-- The 1s tick below would pick the list up anyway, but this is the one update
-- whose timing the player can feel: /tchirp opens on a possibly-empty local list
-- and asks for the real one in the same frame, so "Chirping now" goes correct
-- the moment the round trip lands rather than up to a second later.
AddEventHandler('tchirp:SyncChirpList', function() refresh() end)

local function open()
    local shown
    local ok, err = pcall(function()
        shown = exports['tLib']:ShowDialog(DIALOG, {
            title       = 'tChirp',
            -- 'lg', not 'md': the sidebar takes a fixed 9rem out of the dialog's
            -- width whatever is in it.
            size        = 'lg',
            submitLabel = 'Close',
            tabs        = {
                { id = 'status',   label = 'Status' },
                { id = 'feedback', label = 'Feedback', separator = true },
            },
            fields      = buildFields(),

            onSubmit = function() dialogOpen = false end,
            onCancel = function() dialogOpen = false end,

            -- The only field with a value. Staged only; feedbackSend commits it.
            onChange = function(fieldId, value)
                if fieldId == 'feedbackMessage' then
                    feedbackMessage = tostring(value or '')
                end
            end,

            onButtonClick = function(fieldId)
                if fieldId == 'feedbackSend' then
                    local message = feedbackMessage:gsub('^%s+', ''):gsub('%s+$', '')
                    if message == '' then
                        exports['tLib']:ShowToast(nil, 'error', 'tChirp',
                            'Type a message first.', 2500)
                        return
                    end
                    -- ⚠️ TWO FAILURE PATHS. `SubmitFeedback` refuses by returning
                    -- `false, reason` and never calling the callback, so a
                    -- handler that reads only the callback leaves the player with
                    -- no toast at all -- which is what made tRadio's first
                    -- version of this button visibly do nothing.
                    --
                    -- Not closed on success: a panel that vanishes on Send reads
                    -- as a crash. The toast is the receipt.
                    local accepted = exports['tLib']:SubmitFeedback(message, function(result)
                        local reason = type(result) == 'table' and result.error or nil
                        if type(result) == 'table' and result.ok then
                            feedbackMessage = ''
                            exports['tLib']:UpdateDialogField(DIALOG, 'feedbackMessage',
                                { defaultValue = '' })
                            exports['tLib']:ShowToast(nil, 'success', 'tChirp',
                                'Thanks — that reached TIMMYG Studios.', 3500)
                        elseif reason == 'rate-limited' then
                            -- Named rather than folded into the generic failure:
                            -- the limit is one a minute, so a player who waits
                            -- gets through and should be told to.
                            exports['tLib']:ShowToast(nil, 'error', 'tChirp',
                                'Too many messages just now. Try again in a minute.', 3500)
                        else
                            exports['tLib']:ShowToast(nil, 'error', 'tChirp',
                                'That could not be sent. Your message is still here — try again later.', 4000)
                        end
                    end)
                    if accepted ~= true then
                        exports['tLib']:ShowToast(nil, 'error', 'tChirp',
                            'That could not be sent. Your message is still here — try again later.', 4000)
                    end
                    return
                end
                if fieldId == 'silence' then
                    -- Re-resolved, not taken from the label the button was built
                    -- with: the player may have walked away or another officer
                    -- got in during the seconds the dialog was open, and acting
                    -- on a stale netId silences the wrong car.
                    local netId = tchirpNearestChirping(SILENCE_RANGE)
                    if netId and tchirpSilence(netId) then
                        exports['tLib']:ShowToast(nil, 'success', 'tChirp', 'Silenced.', 2000)
                    else
                        exports['tLib']:ShowToast(nil, 'warning', 'tChirp',
                            'Nothing chirping near you any more.', 2500)
                    end
                    refresh()
                    return
                end
            end,
        })
    end)

    if not ok then
        -- A tLib taken from the repo's green "Code" button has no built UI, so
        -- ShowDialog raises. Logged rather than swallowed: a command that does
        -- nothing is indistinguishable from a resource that never started.
        log(('/tchirp could not open its dialog: %s'):format(tostring(err)), tlib.logger.ERROR)
        log('This is normally tLib missing its built UI files. Download tLib.zip from the '
            .. 'Releases page rather than the source archive.', tlib.logger.ERROR)
        return
    end

    -- ⚠️ ShowDialog REFUSES by returning nil, not by raising (HUD editor open,
    -- another resource owns the id, a later dialog superseded this one
    -- mid-call). So `ok` is not "it is on screen", and starting the tick on `ok`
    -- aims an update once a second, forever, at a dialog that never opened.
    if not shown then
        log('/tchirp did not open — tLib refused the dialog (the HUD editor being open '
            .. 'is the usual reason).', tlib.logger.WARN)
        return
    end

    dialogOpen = true

    -- The generation check retires the previous tick when the dialog is reopened
    -- inside the one second its loop is still sleeping through.
    refreshGeneration = refreshGeneration + 1
    local generation = refreshGeneration
    CreateThread(function()
        while dialogOpen and refreshGeneration == generation do
            Wait(1000)
            if refreshGeneration ~= generation then return end
            refresh()
        end
    end)
end

RegisterCommand('tchirp', function()
    -- Asked every time: a client that connected during a quiet period has an
    -- empty list. The dialog opens in the SAME frame on whatever it already has.
    -- Waiting for the reply first cost 120 ms on every invocation -- above the
    -- 100 ms a direct manipulation has to answer within -- and did not even buy
    -- correctness: a player on 150 ms ping got the stale list anyway.
    TriggerServerEvent('tchirp:RequestChirpList')
    open()
end, false)

TriggerEvent('chat:addSuggestion', '/tchirp',
    'What tChirp is doing: whether this car chirps, which siren provider answers for it, '
    .. 'and what is chirping near you')
