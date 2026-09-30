<#
    Dynamic per-session Home Assistant entities for the Copilot CLI bridge.

    Replaces the eight fixed decision/response slots with entities created on demand,
    one set per live CLI session, published through MQTT discovery.

    Why MQTT discovery rather than input_* helpers:
      - No .storage churn. Helper create/delete rewrites the helper store and the
        entity registry on every session; discovery messages do not.
      - No orphans. A retained discovery topic is cleared by publishing an empty
        payload, and an availability topic marks a session offline the moment the
        daemon stops, so a crashed daemon degrades to "unavailable" rather than
        leaving dead helpers behind forever.
      - Entities group into a per-session device, so Home Assistant shows one card
        per Copilot session instead of eight anonymous slots.

    No MQTT broker credentials are required and no MQTT client library is used.
    Everything is published through Home Assistant's own `mqtt.publish` service
    using the existing long-lived token. Verified end to end 2026-09-21: publishing
    a retained discovery config registered the entity in about four seconds,
    omitting `state_topic` gave optimistic mode so `select.select_option` updated
    the state instantly, and an empty retained payload removed the entity with the
    state API returning 404 and no orphan left behind.
#>

$script:CopilotMqttConfig = @{
    DiscoveryPrefix = 'homeassistant'
    TopicRoot = 'copilot/cli'
    # Home Assistant caps an entity state at 255 characters. Long text therefore
    # rides in attributes via json_attributes_topic, and the state carries a short
    # summary only.
    StateMaxChars = 255
    # The MQTT text platform allows at most 255 characters for a value.
    ReplyMaxChars = 255
}

# The resume selector's "start fresh" option. Shared because the daemon compares the
# selector's state against it and the dashboard shows it as the default.
$script:CopilotMqttNewSessionOption = 'New session'

function Get-CopilotMqttNodeId {
    <#
        A stable, MQTT-safe node id for a session. Discovery topics and object ids
        allow only [a-zA-Z0-9_-], so anything else is stripped.

        Namespaced `agent_bridge_` rather than `copilot_`: the bridge serves Copilot
        CLI, Claude Code, Codex and MCP clients alike, and calling a Claude session's
        entities sensor.copilot_... was actively misleading.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $clean = ($SessionId -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        # An id with no alphanumerics would otherwise collapse to a single shared
        # 'unknown' node, colliding every such session onto one card and topic set.
        # Derive a short stable hash of the raw id so distinct ids stay distinct. Real
        # ids are UUIDs and never reach this branch, so their node ids are unchanged
        # and existing entities are undisturbed.
        $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes([string]$SessionId))
        $clean = ([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 12)
    }
    if ($clean.Length -gt 16) {
        $clean = $clean.Substring(0, 16)
    }
    "agent_bridge_$($clean.ToLowerInvariant())"
}

function Get-CopilotMqttMachineNode {
    <#
        The MQTT node id that carries everything the bridge publishes once per machine.

        One Home Assistant is normally shared between machines, so these were the
        entities that collided: a fixed `agent_bridge` node meant the laptop's update
        entity, launch button and session counter overwrote the desktop's instead of
        appearing next to them.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    "agent_bridge_$Slug"
}

function Get-CopilotMqttMachineDevice {
    <#
        The Home Assistant device every per-machine entity hangs off.

        One device per machine rather than one for the whole bridge, so Home Assistant
        groups each machine's controls together and the device page reads as "what is
        this computer doing" instead of merging every computer into one list.
    #>
    param([string]$Slug, [string]$MachineName)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    if (-not $MachineName) { $MachineName = [Environment]::MachineName }
    @{
        identifiers  = @("agent_bridge_$Slug")
        name         = "AI Agent Bridge ($MachineName)"
        manufacturer = 'AI CLI bridge'
    }
}

function Get-CopilotMqttMachineTopicRoot {
    <#
        The topic prefix for one machine's own controls.

        Namespacing the topics matters as much as namespacing the ids. Home Assistant
        subscribes each MQTT entity to the command topic in its discovery payload, so
        two machines sharing `copilot/cli/newsession/prompt/set` would have had every
        keystroke typed on one machine's prompt box land in the other's as well.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    "$($script:CopilotMqttConfig.TopicRoot)/machine/$Slug"
}

function Get-BridgeMachineEntityId {
    <#
        The entity id of one of this machine's per-machine entities, e.g.
        button.agent_bridge_desktop_new_session.

        Every reader goes through here rather than writing the literal, because the
        daemon polls these by id on each reconcile and the generated dashboard
        references them in templates - so the id has to be derived one way or the two
        drift apart silently.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Key,
        [string]$Slug
    )
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    "$Domain.agent_bridge_${Slug}_$Key"
}

function Get-CopilotMqttTopics {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId
    $root = "$($script:CopilotMqttConfig.TopicRoot)/$node"

    @{
        Node = $node
        Root = $root
        Availability = "$root/available"
        DecisionCommand = "$root/decision/set"
        DecisionState = "$root/decision/state"
        DecisionAttributes = "$root/decision/attr"
        ReplyCommand = "$root/reply/set"
        ReplyState = "$root/reply/state"
        # The reply card publishes here. It is a state topic rather than a command
        # topic because the payload has to reach the daemon through a sensor's
        # attributes, which is the only part of an entity Home Assistant does not
        # cap at 255 characters.
        ReplyPayload = Get-CopilotMqttReplyPayloadTopic -Node $node
        StatusState = "$root/status/state"
        StatusAttributes = "$root/status/attr"
        ActivityState = "$root/activity/state"
        ActivityAttributes = "$root/activity/attr"
        FieldCommandPrefix = "$root/field"
        SubmitCommand = "$root/submit/set"
        StopCommand = "$root/stop/set"
    }
}

# A multi-field question gets one dropdown per field, mirroring the native prompt's
# tabbed form. Capped so the card stays readable; a form with more fields falls back
# to the free-text outline.
$script:CopilotMqttMaxFields = 4

function Get-CopilotMqttFieldEntityId {
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][int]$Index
    )
    "select.${Node}_f$Index"
}

function Get-CopilotMqttEntityIds {
    <#
        Entity ids Home Assistant derives from the discovery payloads below. The
        device name prefixes each entity, so these must track the `name` fields in
        Publish-CopilotMqttSession.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId
    )

    $node = Get-CopilotMqttNodeId -SessionId $SessionId

    @{
        Decision = "select.${node}_decision"
        Reply = "text.${node}_reply"
        ReplyPayload = "sensor.${node}_reply_payload"
        Status = "sensor.${node}_status"
        Activity = "sensor.${node}_activity"
    }
}

function Publish-CopilotMqttMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Topic,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Payload,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [switch]$Retain
    )

    Invoke-HomeAssistantService -Domain 'mqtt' -Service 'publish' -Headers $Headers -Data @{
        topic = $Topic
        payload = $Payload
        retain = [bool]$Retain
        qos = 1
    }
}

function New-CopilotMqttDeviceBlock {
    param(
        [Parameter(Mandatory)]
        [string]$Node,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine
    )

    @{
        identifiers = @($Node)
        # Already carries its harness prefix - "Copilot: ...", "Claude: ...", "Codex:
        # ..." - from the adapter that named it. Prefixing again here is what produced
        # devices called "Copilot: Copilot: 6fcbab0c", and "Copilot: Claude: repo" on
        # every Claude session.
        name = $SessionName
        manufacturer = 'AI CLI bridge'
        model = $Machine
    }
}

function New-CopilotMqttSensorConfigs {
    <#
        The discovery configs for a session's two sensors, which the daemon owns.

        Shared by the initial publish and by a rename, so the two cannot drift: a
        rename republishes exactly these, and nothing else.
    #>
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)]$Topics,
        [Parameter(Mandatory)][hashtable]$Device,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Availability
    )

    @(
        @{
            Object = 'status'
            Config = @{
                name = 'Status'
                unique_id = "${Node}_status"
                state_topic = $Topics.StatusState
                json_attributes_topic = $Topics.StatusAttributes
                icon = 'mdi:robot'
                device = $Device
                availability = $Availability
            }
        }
        # Live activity. The state is a short label; the full text, including reasoning
        # when the verbose toggle is on, rides in the attributes.
        @{
            Object = 'activity'
            Config = @{
                name = 'Activity'
                unique_id = "${Node}_activity"
                state_topic = $Topics.ActivityState
                json_attributes_topic = $Topics.ActivityAttributes
                icon = 'mdi:pulse'
                device = $Device
                availability = $Availability
            }
        }
    )
}

function Update-CopilotMqttSessionName {
    <#
        Renames a session's device, so the names Home Assistant shows follow a rename
        instead of keeping whatever the session was called when it was adopted - which
        for Copilot is normally the id, because the workspace file naming it is written
        after the daemon first sees the session.

        Every entity of a session shares one device block, so renaming it through any
        of them renames the device and every entity name derived from it. The two
        sensors are the ones used because they are the only entities with nothing to
        lose: they take their state from a retained state topic, while the selects, the
        reply box and the buttons are optimistic, and republishing one of those would
        reset a live question to Idle.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix

    foreach ($entry in (New-CopilotMqttSensorConfigs -Node $node -Topics $topics -Device $device -Availability $availability)) {
        Publish-CopilotMqttMessage -Topic "$prefix/sensor/$node/$($entry.Object)/config" `
            -Payload ($entry.Config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }
}

function Publish-CopilotMqttSession {
    <#
        Registers the four entities for one live session. Idempotent: republishing
        the same retained configs simply updates them, so a daemon restart re-arms
        every session without creating duplicates.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix

    # Availability must be retained and published before the entities appear, so a
    # session never shows up already stale.
    Publish-CopilotMqttMessage -Topic $topics.Availability -Payload 'online' -Headers $Headers -Retain

    # Decision selector. Deliberately has no state_topic: that puts the MQTT select
    # into optimistic mode, so tapping a choice updates the Home Assistant state
    # immediately instead of waiting for a device to echo the value back on a state
    # topic. Nothing is subscribed to the command topic - the bridge never connects
    # to the broker - so with a state_topic the selection would never stick.
    # The daemon observes the resulting state change over the Home Assistant
    # WebSocket, which keeps the whole path push-based and credential-free.
    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = @('Idle')
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
        enabled_by_default = $true
    }

    # Reply box for continuing a session whose turn has already ended. Optimistic for
    # the same reason as the selector above.
    $reply = @{
        name = 'Reply'
        unique_id = "${node}_reply"
        command_topic = $topics.ReplyCommand
        max = $script:CopilotMqttConfig.ReplyMaxChars
        mode = 'text'
        icon = 'mdi:reply'
        device = $device
        availability = $availability
    }

    # Where the custom reply card delivers what you typed.
    #
    # The card publishes one JSON message carrying the text, any uploaded image
    # ids, and a timestamp. The state is only that timestamp - short enough for the
    # 255-character state limit, and the same "press stamp" contract the Submit
    # button already uses, so a replayed message cannot resend an old reply. The
    # text itself rides in the attributes, which have no such limit.
    $replyPayload = New-CopilotMqttReplyPayloadConfig -Node $node -Device $device `
        -Availability $availability -Topic $topics.ReplyPayload

    # Sensors are published by the daemon, so these keep a state topic. Built by the
    # helper a rename reuses, so the two paths publish the same configs.
    $sensors = @(New-CopilotMqttSensorConfigs -Node $node -Topics $topics -Device $device -Availability $availability)

    $map = @(
        @{ Component = 'select'; Object = 'decision'; Config = $decision }
        @{ Component = 'text'; Object = 'reply'; Config = $reply }
        @{ Component = 'sensor'; Object = 'replypayload'; Config = $replyPayload }
    ) + @($sensors | ForEach-Object { @{ Component = 'sensor'; Object = $_.Object; Config = $_.Config } })

    foreach ($entry in $map) {
        $topic = "$prefix/$($entry.Component)/$node/$($entry.Object)/config"
        $payload = $entry.Config | ConvertTo-Json -Depth 8 -Compress
        Publish-CopilotMqttMessage -Topic $topic -Payload $payload -Headers $Headers -Retain
    }

    # Every session also gets its four per-field dropdown slots, parked on a single
    # 'Idle' option. They exist from the start so the dashboard's per-field cards
    # always reference a real entity - a conditional card pointing at a missing entity
    # renders an "Entity not found" box on every session that has never been asked a
    # multi-field question.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $fieldConfig = @{
            name = "Field $i"
            unique_id = "${node}_f$i"
            command_topic = "$($topics.FieldCommandPrefix)$i/set"
            options = @('Idle')
            icon = 'mdi:form-select'
            device = $device
            availability = $availability
        }
        Publish-CopilotMqttMessage -Topic "$prefix/select/$node/f$i/config" `
            -Payload ($fieldConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }

    # A Submit button for multi-field questions. Without it the bridge would inject
    # the moment the last dropdown got a value, so there was no chance to review or
    # change a selection. An MQTT button's state is the timestamp of its last press,
    # which is exactly what the daemon needs to tell "submitted now" from "pressed for
    # a previous question".
    $submitConfig = @{
        name = 'Submit answer'
        unique_id = "${node}_submit"
        command_topic = $topics.SubmitCommand
        icon = 'mdi:send-check'
        device = $device
        availability = $availability
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/submit/config" `
        -Payload ($submitConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Ending a session from the dashboard. The bridge can already start one, and
    # being able to start work remotely but not stop it means a session that has gone
    # wrong can only be dealt with at the keyboard.
    #
    # Safe to press: the stop is graceful, and the transcript survives, so the
    # session stays in the resume list and can be reopened. A mistaken press costs a
    # window, not the work.
    $stopConfig = @{
        name          = 'End session'
        unique_id     = "${node}_stop"
        command_topic = $topics.StopCommand
        icon          = 'mdi:stop-circle-outline'
        device        = $device
        availability  = $availability
    }
    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/stop/config" `
        -Payload ($stopConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $topics
}

function Get-CopilotMqttReplyPayloadTopic {
    <#
        Where the reply card publishes for one session.

        Derived from the node alone so the dashboard can build it without a session
        id, and defined once so the card's topic and the sensor's state topic can
        never drift apart - a mismatch there would leave a reply box that silently
        goes nowhere.
    #>
    param([Parameter(Mandatory)][string]$Node)
    "$($script:CopilotMqttConfig.TopicRoot)/$Node/replypayload/set"
}

function Get-CopilotMqttSessionDiscoveryTopic {
    <#
        Every retained discovery topic belonging to one session node.

        Shared by the two things that withdraw a session - the clean exit path, which
        knows the session id, and the startup orphan sweep, which only ever has a node
        id recovered from an entity id. They had a list each, and they drifted: the
        stop button was added to one and not the other, so every swept session left a
        dead Stop button behind in Home Assistant.
    #>
    param([Parameter(Mandatory)][string]$Node)

    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $topics = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @('select', 'decision'), @('text', 'reply'),
        @('sensor', 'replypayload'),
        @('sensor', 'status'), @('sensor', 'activity'),
        @('button', 'submit'), @('button', 'stop')
    )) {
        $topics.Add("$prefix/$($entry[0])/$Node/$($entry[1])/config")
    }
    # The per-field dropdown slots are part of the session too.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $topics.Add("$prefix/select/$Node/f$i/config")
    }
    $topics.ToArray()
}

function Get-CopilotMqttSessionStateTopic {
    <#
        Every retained *state* topic belonging to one session node.

        Separate from the discovery list because the two are cleared at different
        points - discovery removes the entity, state removes what it last said - but
        derived from the node alone so the startup sweep can clear them too. The sweep
        only ever recovers a node id from an entity id; it has no session id to hand.

        Without this the sweep withdrew a dead session's entities and left its retained
        state behind in the broker permanently, a handful of messages per session that
        nothing would ever clean up.
    #>
    param([Parameter(Mandatory)][string]$Node)

    $root = "$($script:CopilotMqttConfig.TopicRoot)/$Node"
    @(
        "$root/decision/state"
        "$root/decision/attr"
        "$root/reply/state"
        "$root/replypayload/set"
        "$root/status/state"
        "$root/status/attr"
        "$root/activity/state"
        "$root/activity/attr"
        "$root/available"
    )
}

function Remove-CopilotMqttSession {
    <#
        Clears the retained discovery configs so Home Assistant drops the entities
        and leaves no orphan behind. Also clears the retained state topics, so a
        node id reused by a later session cannot inherit stale values.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId

    Publish-CopilotMqttMessage -Topic $topics.Availability -Payload 'offline' -Headers $Headers -Retain

    foreach ($topic in (Get-CopilotMqttSessionDiscoveryTopic -Node $topics.Node)) {
        Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
    }

    foreach ($topic in (Get-CopilotMqttSessionStateTopic -Node $topics.Node)) {
        Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
    }
}

function Publish-CopilotMqttUpdate {
    <#
        Publishes the bridge's own update status as a Home Assistant `update` entity,
        plus a button to install it.

        The update entity deliberately has no command_topic. Home Assistant's install
        action for an MQTT update entity publishes to that topic and reports no state
        change of its own - confirmed against a live instance - and nothing here
        subscribes to MQTT, so the button it would render could never work. Rather
        than ship a control that silently does nothing, the action is a separate
        button whose press timestamp the daemon can actually see, which is the same
        mechanism the per-session Submit button uses.
    #>
    param(
        [Parameter(Mandatory)][string]$InstalledVersion,
        [Parameter(Mandatory)][string]$LatestVersion,
        [string]$ReleaseUrl = '',
        [string]$ReleaseNotes = '',
        [switch]$InProgress,
        [string]$Slug,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    $node = Get-CopilotMqttMachineNode -Slug $Slug
    $device = Get-CopilotMqttMachineDevice -Slug $Slug
    $stateTopic = "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/update/state"

    $config = @{
        name        = 'Update'
        unique_id   = "agent_bridge_${Slug}_update"
        object_id   = "agent_bridge_${Slug}_update"
        state_topic = $stateTopic
        device_class = 'firmware'
        icon        = 'mdi:package-up'
        device      = $device
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/update/$node/update/config" `
        -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Release notes render in the entity's own dialog. They are capped because the
    # whole payload travels through an MQTT message.
    $notes = [string]$ReleaseNotes
    if ($notes.Length -gt 2000) { $notes = $notes.Substring(0, 1997) + '...' }

    $state = @{
        installed_version = $InstalledVersion
        latest_version    = $LatestVersion
        title             = 'AI coding agent Home Assistant bridge'
        # Always present, so Home Assistant shows a spinner while an install runs and
        # clears it the moment a later publish reports false, rather than inferring
        # the flag from an absent key.
        in_progress       = [bool]$InProgress
    }
    if ($ReleaseUrl) { $state['release_url'] = $ReleaseUrl }
    if ($notes) { $state['release_summary'] = $notes }

    Publish-CopilotMqttMessage -Topic $stateTopic `
        -Payload ($state | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain

    $button = @{
        name          = 'Install Bridge Update'
        unique_id     = "agent_bridge_${Slug}_install_update"
        object_id     = "agent_bridge_${Slug}_install_update"
        command_topic = "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/update/install"
        icon          = 'mdi:download'
        device        = $device
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/button/$node/install_update/config" `
        -Payload ($button | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
}

function Publish-CopilotMqttNewSession {
    <#
        Publishes the controls that start a brand new CLI session, on the same
        bridge-level device as the update entity and the session counter.

        Four entities, deliberately split rather than combined:

          * a `text` box for the opening prompt,
          * a `select` listing the approved working directories,
          * a `button` that actually launches,
          * a `sensor` reporting what the last press did.

        The text and select are optimistic - no state topic - for the same reason
        the per-session reply box is: nothing here subscribes to the broker, so a
        typed value would never be echoed back and would never stick.

        Launching is a separate button rather than an action on the text box because
        Home Assistant commits a text entity as soon as it loses focus. Acting on
        the value alone would spawn a session the moment you clicked away, which is
        easy to do by accident and impossible to undo. The button's state is the
        timestamp of its last press, which is exactly the signal the daemon needs.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Workspaces,

        [AllowEmptyCollection()]
        [string[]]$Profiles = @(),

        [AllowEmptyCollection()]
        [object[]]$Resumable = @(),

        # Labels of the agents installed on this machine (Claude, Copilot, ...).
        [AllowEmptyCollection()]
        [string[]]$Agents = @(),

        # What the chosen agent accepts for model, reasoning effort and context
        # window, keyed by axis ('model', 'effort', 'context'). Every list already
        # carries its 'Agent default' entry first, from Get-BridgeTuningOptions. An
        # axis with no entry gets a single placeholder rather than being left out,
        # so the entity the generated dashboard references always exists.
        [hashtable]$Tuning = @{},

        [string]$LastResult = '',

        [string]$Slug,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    $node = Get-CopilotMqttMachineNode -Slug $Slug
    $device = Get-CopilotMqttMachineDevice -Slug $Slug
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $root = Get-CopilotMqttMachineTopicRoot -Slug $Slug

    # An MQTT select must offer at least one option, so a bridge with nothing
    # configured still publishes a single explanatory entry rather than an invalid
    # discovery payload that Home Assistant would reject outright.
    $options = @(@($Workspaces) | ForEach-Object { [string]$_.Label } | Where-Object { $_ })
    if ($options.Count -eq 0) { $options = @('(no workspaces configured)') }

    $promptConfig = @{
        name          = 'New session prompt'
        unique_id     = "agent_bridge_${Slug}_new_prompt"
        object_id     = "agent_bridge_${Slug}_new_prompt"
        command_topic = "$root/newsession/prompt/set"
        max           = $script:CopilotMqttConfig.ReplyMaxChars
        mode          = 'text'
        icon          = 'mdi:message-plus-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/text/$node/new_prompt/config" `
        -Payload ($promptConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # The prompt box above is a text entity, and Home Assistant caps one at 255
    # characters. That is far too short for the thing the box is most useful for -
    # handing a new session the full context of what it is taking over - and the text
    # was silently truncated rather than refused.
    #
    # So the launch card publishes the whole prompt here instead, exactly as the reply
    # card already does for a long reply: the state carries only the card's timestamp
    # (value_template), and the prompt itself rides in an attribute, which has no cap.
    # The text entity stays, and still works, for a dashboard whose card is too old to
    # know about this one.
    $promptPayloadConfig = @{
        name                  = 'New session prompt payload'
        unique_id             = "agent_bridge_${Slug}_new_prompt_payload"
        object_id             = "agent_bridge_${Slug}_new_prompt_payload"
        state_topic           = "$root/newsession/promptpayload"
        value_template        = '{{ value_json.at }}'
        json_attributes_topic = "$root/newsession/promptpayload"
        icon                  = 'mdi:message-plus-outline'
        device                = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/sensor/$node/new_prompt_payload/config" `
        -Payload ($promptPayloadConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $workspaceConfig = @{
        name          = 'New session workspace'
        unique_id     = "agent_bridge_${Slug}_new_workspace"
        object_id     = "agent_bridge_${Slug}_new_workspace"
        command_topic = "$root/newsession/workspace/set"
        options       = $options
        icon          = 'mdi:folder-open-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/$node/new_workspace/config" `
        -Payload ($workspaceConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # The Agency profile decides which MCP servers and plugins a session gets, and it
    # is an axis of its own rather than a property of the directory - the same folder
    # is routinely opened under different profiles. It therefore gets its own
    # selector instead of being folded into the workspace list.
    #
    # Published even when Agency is not the launcher, so the entity the generated
    # dashboard references always exists; the daemon simply ignores its value.
    $profileOptions = @(@($Profiles) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($profileOptions.Count -eq 0) { $profileOptions = @('(default)') }

    $profileConfig = @{
        name          = 'New session profile'
        unique_id     = "agent_bridge_${Slug}_new_profile"
        object_id     = "agent_bridge_${Slug}_new_profile"
        command_topic = "$root/newsession/profile/set"
        options       = $profileOptions
        icon          = 'mdi:account-cog-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/$node/new_profile/config" `
        -Payload ($profileConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Which agent to start. Only installed ones are offered, and the daemon resolves
    # the chosen label back against that same list before launching anything.
    $agentOptions = @(@($Agents) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($agentOptions.Count -eq 0) { $agentOptions = @('(no agents installed)') }

    $agentConfig = @{
        name          = 'New session agent'
        unique_id     = "agent_bridge_${Slug}_new_agent"
        object_id     = "agent_bridge_${Slug}_new_agent"
        command_topic = "$root/newsession/agent/set"
        options       = $agentOptions
        icon          = 'mdi:robot-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/$node/new_agent/config" `
        -Payload ($agentConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Resume selector. "New session" is always the first option and the default, so
    # the common case needs no interaction and nothing can be resumed by accident.
    $resumeOptions = @($script:CopilotMqttNewSessionOption)
    foreach ($entry in @($Resumable)) {
        $label = [string]$entry.Label
        if (-not [string]::IsNullOrWhiteSpace($label)) { $resumeOptions += $label }
    }

    $resumeConfig = @{
        name          = 'New session resume'
        unique_id     = "agent_bridge_${Slug}_new_resume"
        object_id     = "agent_bridge_${Slug}_new_resume"
        command_topic = "$root/newsession/resume/set"
        options       = $resumeOptions
        icon          = 'mdi:history'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/$node/new_resume/config" `
        -Payload ($resumeConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # Model, reasoning effort and context window. Three selectors rather than one
    # combined knob because the agents treat them as three independent settings, and
    # because their option lists change together with the chosen agent: the daemon
    # republishes these whenever the agent selector moves, so a Claude launch offers
    # Claude's models and not Copilot's.
    #
    # Always published, even for an agent that offers nothing on an axis, for the
    # same reason the profile selector is: the generated dashboard names these
    # entities literally, and a missing one renders an "Entity not found" row.
    foreach ($axis in @(Get-BridgeTuningAxes)) {
        $axisOptions = @()
        if ($Tuning.ContainsKey($axis)) {
            $axisOptions = @(@($Tuning[$axis]) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
        }
        if ($axisOptions.Count -eq 0) { $axisOptions = @($script:BridgeTuningDefaultOption) }

        $key = "new_$axis"
        $axisConfig = @{
            name          = "New session $(Get-BridgeTuningAxisLabel -Axis $axis)"
            unique_id     = "agent_bridge_${Slug}_$key"
            object_id     = "agent_bridge_${Slug}_$key"
            command_topic = "$root/newsession/$axis/set"
            options       = $axisOptions
            icon          = Get-BridgeTuningAxisIcon -Axis $axis
            device        = $device
        }
        Publish-CopilotMqttMessage -Topic "$prefix/select/$node/$key/config" `
            -Payload ($axisConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }

    $buttonConfig = @{
        name          = 'Start new session'
        unique_id     = "agent_bridge_${Slug}_new_session"
        object_id     = "agent_bridge_${Slug}_new_session"
        command_topic = "$root/newsession/start"
        icon          = 'mdi:rocket-launch-outline'
        device        = $device
    }

    # Permissions: whether the launched session may act without stopping to ask. A
    # fixed two-option list, unlike the axes above, because it belongs to the bridge
    # rather than to the chosen agent - each of them spells it differently, and
    # Get-BridgeNewSessionArguments is where that is translated. The daemon opens it
    # on the local newSession.allowAllTools and leaves a picked value alone, so the
    # control states what that machine would have done rather than changing it.
    $permissionsConfig = @{
        name          = 'New session permissions'
        unique_id     = "agent_bridge_${Slug}_new_permissions"
        object_id     = "agent_bridge_${Slug}_new_permissions"
        command_topic = "$root/newsession/permissions/set"
        options       = @(Get-BridgePermissionOptions)
        icon          = 'mdi:shield-key-outline'
        device        = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/select/$node/new_permissions/config" `
        -Payload ($permissionsConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    Publish-CopilotMqttMessage -Topic "$prefix/button/$node/new_session/config" `
        -Payload ($buttonConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $resultTopic = "$root/newsession/result"
    $resultConfig = @{
        name        = 'New session result'
        unique_id   = "agent_bridge_${Slug}_new_session_result"
        object_id   = "agent_bridge_${Slug}_new_session_result"
        state_topic = $resultTopic
        icon        = 'mdi:information-outline'
        device      = $device
    }
    Publish-CopilotMqttMessage -Topic "$prefix/sensor/$node/new_session_result/config" `
        -Payload ($resultConfig | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    if ($PSBoundParameters.ContainsKey('LastResult')) {
        Set-CopilotMqttNewSessionResult -Text $LastResult -Slug $Slug -Headers $Headers
    }
}

function Clear-CopilotMqttNewSessionPrompt {
    <#
        Empties the launch card's prompt payload once it has been used.

        The topic is retained, so without this the prompt that started one session
        would still be sitting there for the next press - the same reason the text
        box is blanked after a launch. An empty object leaves value_json.at undefined,
        which is what Get-BridgeReplyPayload reads as "nothing to send".
    #>
    param(
        [string]$Slug,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Publish-CopilotMqttMessage -Topic "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/newsession/promptpayload" `
        -Payload '{}' -Headers $Headers -Retain
}

function Set-CopilotMqttNewSessionResult {
    <#
        Reports the outcome of the last launch. Truncated to the Home Assistant state
        limit, since a failure detail can easily run past it.
    #>
    param(
        [string]$Text = '',
        [string]$Slug,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $value = [string]$Text
    $limit = $script:CopilotMqttConfig.StateMaxChars
    if ($value.Length -gt $limit) { $value = $value.Substring(0, $limit - 3) + '...' }

    Publish-CopilotMqttMessage -Topic "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/newsession/result" `
        -Payload $value -Headers $Headers -Retain
}

function Clear-CopilotLegacyMqttEntities {
    <#
        Removes the entities published under the pre-rename `copilot_cli_*` and
        `copilot_<hex>` ids.

        An MQTT discovery config is retained on the broker, so renaming a unique_id
        does not replace the old entity - it adds a second one and leaves the first
        sitting there forever, unavailable and confusing. The retained payload has to
        be explicitly cleared, which is done by publishing an empty one.

        Only two sets can still exist by the time this runs. The bridge-wide entities,
        which are a fixed list; and the per-session entities of whatever was live at
        the moment of the switch, because a session's topics are already cleared when
        it exits. Historical sessions therefore need no sweep.

        Returns the number of topics cleared.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,

        # Session ids whose legacy per-session topics should also be cleared.
        [AllowEmptyCollection()]
        [string[]]$SessionIds = @()
    )

    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $topics = @(
        "$prefix/update/copilot_cli_bridge/update/config"
        "$prefix/button/copilot_cli_bridge/install_update/config"
        "$prefix/text/copilot_cli_bridge/new_prompt/config"
        "$prefix/select/copilot_cli_bridge/new_workspace/config"
        "$prefix/select/copilot_cli_bridge/new_profile/config"
        "$prefix/select/copilot_cli_bridge/new_resume/config"
        "$prefix/button/copilot_cli_bridge/new_session/config"
        "$prefix/sensor/copilot_cli_bridge/new_session_result/config"
        "$prefix/sensor/copilot_cli_global/sessions/config"
    )

    foreach ($sessionId in @($SessionIds)) {
        $node = Get-CopilotLegacyMqttNodeId -SessionId $sessionId
        if ([string]::IsNullOrWhiteSpace($node)) { continue }
        $topics += @(
            "$prefix/select/$node/decision/config"
            "$prefix/text/$node/reply/config"
            "$prefix/sensor/$node/status/config"
            "$prefix/sensor/$node/activity/config"
            "$prefix/button/$node/submit/config"
        )
        for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
            $topics += "$prefix/select/$node/f$i/config"
        }
    }

    $cleared = 0
    foreach ($topic in $topics) {
        try {
            Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain
            $cleared++
        }
        catch {
            # A topic that cannot be cleared is not worth failing a daemon start over.
        }
    }

    $cleared
}

function Get-CopilotLegacyMqttNodeId {
    <#
        The node id a session had before the `agent_bridge_` rename. Kept verbatim
        rather than derived from the current function, so a later change to node
        naming cannot silently break the cleanup of the old one.
    #>
    param([Parameter(Mandatory)][string]$SessionId)

    $clean = ($SessionId -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
    if ($clean.Length -gt 16) { $clean = $clean.Substring(0, 16) }
    "copilot_$($clean.ToLowerInvariant())"
}

function Publish-CopilotMqttGlobalStatus {
    <#
        Publishes this machine's session summary, and doubles as its presence marker.

        The count exists because the old dashboard counter only counted sessions in
        the 'working' state, so a set of sessions all idle and waiting for input read
        as 0 - which looked broken. This counts every live session the daemon is
        tracking, whatever their turn state.

        It carries two further jobs now that one Home Assistant serves several
        machines. The `sessions` attribute is how every other machine learns what this
        one is running, so the dashboard can show all of them at once without any
        machine talking to any other. And the entity's mere existence is how an
        uninstall tells whether it is removing the last machine - it is retained, so it
        survives a machine simply being switched off, which is exactly the case where
        the shared dashboard must be left alone.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Sessions,

        # What this machine can offer on its launch card, so other machines can render
        # it correctly without knowing anything about how it is configured.
        [hashtable]$Capabilities = @{},

        [string]$Slug,

        [string]$MachineName,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    if (-not $MachineName) { $MachineName = [Environment]::MachineName }

    $node = Get-CopilotMqttMachineNode -Slug $Slug
    $machineRoot = Get-CopilotMqttMachineTopicRoot -Slug $Slug
    $stateTopic = "$machineRoot/global/state"
    $attrTopic = "$machineRoot/global/attr"

    $config = @{
        name = 'Sessions'
        unique_id = "agent_bridge_${Slug}_sessions"
        object_id = "agent_bridge_${Slug}_sessions"
        state_topic = $stateTopic
        json_attributes_topic = $attrTopic
        icon = 'mdi:robot-happy'
        device = Get-CopilotMqttMachineDevice -Slug $Slug -MachineName $MachineName
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/sensor/$node/sessions/config" `
        -Payload ($config | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain

    Publish-CopilotMqttMessage -Topic $stateTopic -Payload ([string]$Sessions.Count) `
        -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $attrTopic -Payload (@{
        sessions = @($Sessions)
        machine = $MachineName
        machine_slug = $Slug
        capabilities = $Capabilities
        updated = [DateTimeOffset]::Now.ToString('o')
    } | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain
}

function Publish-CopilotMqttMachineOnlineConfig {
    <#
        Declares this machine's liveness sensor.

        Split from the heartbeat because the heartbeat is deliberately not retained, so
        it is dropped outright if it reaches Home Assistant before the discovery config
        has been processed. Publishing both in one breath lost the first beat every
        time, and the machine read as offline for a full heartbeat interval after its
        daemon started - which is exactly when someone is most likely to be looking.

        Retained, so the entity survives a Home Assistant restart even though its state
        does not.
    #>
    param(
        [string]$Slug,
        [string]$MachineName,
        [int]$ExpireAfter = 180,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }
    if (-not $MachineName) { $MachineName = [Environment]::MachineName }

    $node = Get-CopilotMqttMachineNode -Slug $Slug
    $config = @{
        name = 'Online'
        unique_id = "agent_bridge_${Slug}_online"
        object_id = "agent_bridge_${Slug}_online"
        state_topic = "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/online/state"
        device_class = 'connectivity'
        payload_on = 'online'
        payload_off = 'offline'
        expire_after = $ExpireAfter
        device = Get-CopilotMqttMachineDevice -Slug $Slug -MachineName $MachineName
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/binary_sensor/$node/online/config" `
        -Payload ($config | ConvertTo-Json -Depth 6 -Compress) -Headers $Headers -Retain
}

function Publish-CopilotMqttMachineHeartbeat {
    <#
        Says this machine is still running.

        Everything else the bridge publishes is retained, which is what lets a machine
        that is switched off still be *known* - the right behaviour for the machine
        list and for deciding whether an uninstall is removing the last one. It does
        mean presence cannot be inferred from any of it, so liveness gets its own
        signal, and it is the one thing deliberately not retained: `expire_after` turns
        it unavailable when the beats stop, and a Home Assistant restart cannot
        resurrect a stale "online" for a machine that has since been switched off.
    #>
    param(
        [string]$Slug,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Publish-CopilotMqttMessage -Topic "$(Get-CopilotMqttMachineTopicRoot -Slug $Slug)/online/state" `
        -Payload 'online' -Headers $Headers
}

function Get-CopilotMqttGlobalEntityId {
    param([string]$Slug)
    Get-BridgeMachineEntityId -Domain 'sensor' -Key 'sessions' -Slug $Slug
}

function Get-BridgePeerMachine {
    <#
        Every machine publishing bridge entities to this Home Assistant, found by its
        session sensor.

        Discovery is one-directional and needs no coordination: each machine publishes
        a retained sensor describing itself, and any other machine reads them all out
        of /api/states. Nothing subscribes, nothing registers, and a machine that is
        switched off still shows up - which is what makes this safe to use for
        "am I the last one" during an uninstall.

        -States is for tests; without it the state list is fetched. A caller that has
        already read /api/states for another reason should pass it rather than paying
        for a second full read.
    #>
    param(
        [hashtable]$Headers,
        [switch]$ExcludeSelf,
        [AllowNull()][object[]]$States
    )

    if (-not $PSBoundParameters.ContainsKey('States')) {
        $States = Invoke-DecisionHttpRequest -Parameters @{
            Method = 'Get'
            Uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/states"
            Headers = $Headers
            TimeoutSec = 15
        }
    }

    $self = Get-BridgeMachineSlug
    # Liveness rides on a separate, unretained sensor with an expiry, so it is the one
    # thing here that distinguishes a machine that is running from one that merely
    # registered at some point in the past.
    $online = @{}
    foreach ($state in @($States)) {
        if ($null -eq $state) { continue }
        if ([string]$state.entity_id -notmatch '^binary_sensor\.agent_bridge_([a-z0-9_]+)_online$') { continue }
        $online[$Matches[1]] = ([string]$state.state -eq 'on')
    }

    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($state in @($States)) {
        if ($null -eq $state) { continue }
        $entityId = [string]$state.entity_id
        # A session node is alphanumeric only, so it can never end in _sessions; the
        # suffix is therefore unambiguous evidence of a machine sensor.
        if ($entityId -notmatch '^sensor\.agent_bridge_([a-z0-9_]+)_sessions$') { continue }
        $slug = $Matches[1]
        if ($ExcludeSelf -and $slug -eq $self) { continue }

        $attributes = $state.attributes
        $machine = ''
        $sessions = @()
        $capabilities = @{}
        if ($null -ne $attributes) {
            if ($attributes.PSObject.Properties.Name -contains 'machine') { $machine = [string]$attributes.machine }
            if ($attributes.PSObject.Properties.Name -contains 'sessions') { $sessions = @($attributes.sessions) }
            if ($attributes.PSObject.Properties.Name -contains 'capabilities' -and $null -ne $attributes.capabilities) {
                $capabilities = $attributes.capabilities
            }
        }
        # An older machine's sensor predates the machine attribute, so fall back to the
        # slug rather than rendering a card with no name on it.
        if ([string]::IsNullOrWhiteSpace($machine)) { $machine = $slug }

        $found.Add([pscustomobject]@{
            Slug = $slug
            Machine = $machine
            Sessions = @($sessions)
            Capabilities = $capabilities
            Online = [bool]$online[$slug]
            IsSelf = ($slug -eq $self)
            EntityId = $entityId
        })
    }
    # Returned unwrapped so the normal @(...) idiom at every call site works: an empty
    # result yields nothing and collects as zero, rather than as one empty array.
    $found.ToArray()
}

function Get-CopilotMqttMachineTopic {
    <#
        Every retained topic that belongs to one machine's own entities.

        Kept in one place because it is walked in two directions: published on every
        reconcile, and cleared on uninstall. A topic missing from here would leave an
        entity behind in Home Assistant with nothing left to remove it.
    #>
    param([string]$Slug)
    if (-not $Slug) { $Slug = Get-BridgeMachineSlug }

    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $node = Get-CopilotMqttMachineNode -Slug $Slug
    $root = Get-CopilotMqttMachineTopicRoot -Slug $Slug

    @(
        "$prefix/update/$node/update/config"
        "$prefix/button/$node/install_update/config"
        "$prefix/text/$node/new_prompt/config"
        "$prefix/sensor/$node/new_prompt_payload/config"
        "$prefix/select/$node/new_workspace/config"
        "$prefix/select/$node/new_profile/config"
        "$prefix/select/$node/new_agent/config"
        "$prefix/select/$node/new_model/config"
        "$prefix/select/$node/new_effort/config"
        "$prefix/select/$node/new_context/config"
        "$prefix/select/$node/new_resume/config"
        "$prefix/button/$node/new_session/config"
        "$prefix/sensor/$node/new_session_result/config"
        "$prefix/sensor/$node/sessions/config"
        "$prefix/binary_sensor/$node/online/config"
        "$root/update/state"
        "$root/newsession/result"
        "$root/newsession/promptpayload"
        "$root/online/state"
        "$root/global/state"
        "$root/global/attr"
    )
}

function Get-BridgeMachineForgetTopic {
    <#
        Every retained topic that has to be cleared to take one machine off the
        dashboard: its own controls, and the sessions its retained sensor still lists.

        A machine that was renamed - or reimaged, or thrown away - never comes back to
        withdraw its own entities, so removing it cannot be something only its own
        daemon can do. The X on the machine row publishes this list straight from the
        browser, which is why it is built here from the same two lists an uninstall
        walks rather than restated in the card: a topic missing from one of them leaves
        an entity behind with nothing left to remove it.
    #>
    param(
        [string]$Slug,
        [AllowEmptyCollection()][AllowNull()][string[]]$SessionNodes = @()
    )

    $topics = [System.Collections.Generic.List[string]]::new()
    foreach ($topic in (Get-CopilotMqttMachineTopic -Slug $Slug)) { $topics.Add($topic) }
    foreach ($node in @($SessionNodes)) {
        if ([string]::IsNullOrWhiteSpace($node)) { continue }
        foreach ($topic in (Get-CopilotMqttSessionDiscoveryTopic -Node $node)) { $topics.Add($topic) }
        foreach ($topic in (Get-CopilotMqttSessionStateTopic -Node $node)) { $topics.Add($topic) }
    }
    $topics.ToArray()
}

function Get-CopilotMqttLegacyMachineTopic {
    <#
        The retained topics from before entities were scoped to a machine.

        These used a single fixed `agent_bridge` node, which is precisely why a second
        machine overwrote the first. An upgraded install has to withdraw them, or Home
        Assistant keeps showing the unscoped update entity and launch button - and the
        launch button in particular would still be watched by nothing, so pressing it
        would appear to do nothing at all.
    #>
    $prefix = $script:CopilotMqttConfig.DiscoveryPrefix
    $root = $script:CopilotMqttConfig.TopicRoot

    @(
        "$prefix/update/agent_bridge/update/config"
        "$prefix/button/agent_bridge/install_update/config"
        "$prefix/text/agent_bridge/new_prompt/config"
        "$prefix/select/agent_bridge/new_workspace/config"
        "$prefix/select/agent_bridge/new_profile/config"
        "$prefix/select/agent_bridge/new_resume/config"
        "$prefix/button/agent_bridge/new_session/config"
        "$prefix/sensor/agent_bridge/new_session_result/config"
        "$prefix/sensor/agent_bridge_global/sessions/config"
        "$root/update/state"
        "$root/newsession/result"
        "$root/global/state"
        "$root/global/attr"
    )
}

function Remove-CopilotMqttMachineEntities {
    <#
        Withdraws one machine's per-machine entities by clearing their retained topics.
        Used by uninstall, so removing a laptop leaves the desktop's controls intact.
    #>
    param(
        [string]$Slug,
        [switch]$Legacy,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = if ($Legacy) { Get-CopilotMqttLegacyMachineTopic } else { Get-CopilotMqttMachineTopic -Slug $Slug }
    foreach ($topic in $topics) {
        try { Publish-CopilotMqttMessage -Topic $topic -Payload '' -Headers $Headers -Retain }
        catch { }
    }
    @($topics).Count
}

function Set-CopilotMqttStatus {
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [ValidateSet('working', 'idle', 'waiting', 'offline')]
        [string]$Status,

        [hashtable]$Attributes = @{},

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    Publish-CopilotMqttMessage -Topic $topics.StatusState -Payload $Status -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $topics.StatusAttributes `
        -Payload ($Attributes | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
}

function Set-CopilotMqttActivity {
    <#
        Publishes one live activity update. `Summary` is the short state label and is
        truncated to the Home Assistant state limit; `Detail` carries the full text,
        including model reasoning when the verbose toggle is on.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Summary,

        [AllowNull()]
        [hashtable]$Detail,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $state = $Summary
    $limit = $script:CopilotMqttConfig.StateMaxChars
    if ($state.Length -gt $limit) {
        $state = $state.Substring(0, $limit - 3) + '...'
    }

    Publish-CopilotMqttMessage -Topic $topics.ActivityState -Payload $state -Headers $Headers -Retain
    if ($null -ne $Detail) {
        Publish-CopilotMqttMessage -Topic $topics.ActivityAttributes `
            -Payload ($Detail | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }
}

function Publish-CopilotMqttDecisionFields {
    <#
        Publishes one dropdown per field of a multi-field question, mirroring the
        native prompt's tabbed form.

        A multi-field form used to be flattened into the cartesian product of every
        field's options on a single dropdown - two fields of 3 and 2 options became 6
        entries, and a real one reached 9 - which is unreadable and scales terribly.
        One dropdown per field keeps each list short and matches what the terminal
        shows. The daemon injects only once every field has a selection.

        Each dropdown starts on a "Choose..." placeholder so "not yet answered" is
        distinguishable from a real choice.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Fields,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $field = if ($i -le $Fields.Count) { $Fields[$i - 1] } else { $null }

        # Unused field slots collapse to a single Idle option so the dashboard's
        # condition hides them; they are not deleted, which keeps the entity ids
        # stable across questions.
        $options = @('Idle')
        $label = "Field $i"
        if ($null -ne $field -and -not (Test-DecisionFieldIsText -Field $field)) {
            $label = [string]$field.Label
            if ([string]::IsNullOrWhiteSpace($label)) { $label = "Field $i" }
            # A multi-select field offers its combinations, because a select holds one
            # value; the marker keeps the real options for the keystrokes.
            $listed = if (Test-DecisionFieldIsMultiSelect -Field $field) {
                @(Get-DecisionMultiSelectChoices -Field $field)
            }
            else { @($field.Options) }
            $options = @('Choose...') + @(
                $listed | ForEach-Object {
                    $t = [string]$_
                    if ($t.Length -gt 250) { $t = $t.Substring(0, 247) + '...' }
                    $t
                }
            )
        }

        $config = @{
            name = $label
            unique_id = "${node}_f$i"
            command_topic = "$($topics.FieldCommandPrefix)$i/set"
            options = $options
            icon = 'mdi:form-select'
            device = $device
            availability = $availability
        }
        Publish-CopilotMqttMessage `
            -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/f$i/config" `
            -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    }

    # Home Assistant derives an MQTT entity id from the device name plus the entity
    # name, so these register as select.<device>_field_1 rather than the node-based id
    # the dashboard points at. Force them onto the deterministic ids before driving
    # their values, otherwise the dashboard's per-field cards reference entities that
    # do not exist and simply render nothing.
    Start-Sleep -Milliseconds 900
    if (Get-Command Set-CopilotMqttEntityIds -ErrorAction SilentlyContinue) {
        try { [void](Set-CopilotMqttEntityIds -SessionId $SessionId) }
        catch { }
    }

    # Now set each dropdown's starting value. These are optimistic selects, so their
    # state must be driven explicitly. A free-text field has no dropdown - it is
    # answered through the reply box - so its slot is parked on 'Idle' like an unused
    # one. Starting it on 'Choose...' left it holding a value that was not even in its
    # own option list, so the dashboard's "hide while Idle" condition failed to hide
    # it and a blank dropdown appeared between the real ones.
    for ($i = 1; $i -le $script:CopilotMqttMaxFields; $i++) {
        $slotField = if ($i -le $Fields.Count) { $Fields[$i - 1] } else { $null }
        $isChoiceSlot = ($null -ne $slotField) -and -not (Test-DecisionFieldIsText -Field $slotField)
        $start = if ($isChoiceSlot) { 'Choose...' } else { 'Idle' }
        try {
            Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
                entity_id = (Get-CopilotMqttFieldEntityId -Node $node -Index $i)
                option = $start
            }
        }
        catch {
            # Non-fatal; the dashboard condition treats a missing value as unanswered.
        }
    }
}

function New-CopilotMqttReplyPayloadConfig {
    <#
        The discovery payload for a session's reply-payload sensor.

        Shared by the full session publish and the single-entity provisioning below,
        so the two can never drift - the drifted-list mistake that once left every
        swept session with a dead Stop button.
    #>
    param(
        [Parameter(Mandatory)][string]$Node,
        [Parameter(Mandatory)][object]$Device,
        [Parameter(Mandatory)][object[]]$Availability,
        [Parameter(Mandatory)][string]$Topic
    )

    @{
        name = 'Reply payload'
        unique_id = "${Node}_reply_payload"
        state_topic = $Topic
        value_template = '{{ value_json.at }}'
        json_attributes_topic = $Topic
        icon = 'mdi:reply-all'
        device = $Device
        availability = $Availability
    }
}

function Publish-CopilotMqttReplyPayloadSensor {
    <#
        Publishes just the reply-payload sensor for a session.

        Needed for sessions that were already running when the reply card arrived.
        Without it the dashboard would show them the card while nothing in Home
        Assistant subscribed to the topic it publishes to, so every reply typed into
        it would vanish silently - worse than not offering the card at all.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $config = New-CopilotMqttReplyPayloadConfig -Node $node -Device $device `
        -Availability $availability -Topic $topics.ReplyPayload

    Publish-CopilotMqttMessage -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/sensor/$node/replypayload/config" `
        -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
}

function Publish-CopilotMqttSubmitButton {
    <#
        Publishes just the Submit button for a session. Used to provision it onto
        sessions that were created before the button existed, without disturbing their
        other entities.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $config = @{
        name = 'Submit answer'
        unique_id = "${node}_submit"
        command_topic = $topics.SubmitCommand
        icon = 'mdi:send-check'
        device = $device
        availability = $availability
    }
    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/button/$node/submit/config" `
        -Payload ($config | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    Start-Sleep -Milliseconds 900
    if (Get-Command Set-CopilotMqttEntityIds -ErrorAction SilentlyContinue) {
        try { [void](Set-CopilotMqttEntityIds -SessionId $SessionId) } catch { }
    }
}

function Clear-CopilotMqttDecisionFields {
    <#
        Collapses every field dropdown back to Idle so the dashboard hides them once
        the question is answered.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$Machine,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    Publish-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
        -Machine $Machine -Fields @() -Headers $Headers
}

function Set-CopilotMqttSelectOption {
    <#
        Drives an optimistic MQTT select to a value, waiting until Home Assistant has
        actually ingested the discovery config that carries that value.

        The MQTT select platform fixes its option list at configuration time, and
        `select.select_option` rejects anything outside that list with a
        ServiceValidationError. Discovery is asynchronous: the retained config goes to
        the broker, Home Assistant consumes it, and only then does the entity carry the
        new options. Publishing and then immediately selecting is therefore a race.

        This used to be a flat `Start-Sleep -Milliseconds 600`. Under load that is not
        enough: the call lands while the entity still holds the *previous* option list,
        and Home Assistant logs

            Option 'Awaiting answer...' is not valid for entity
            select.<node>_decision, valid options are: Idle

        once per attempt (30 in one observed 24h window). The exception was caught and
        ignored, so the card still carried the question in its attributes - but the
        selector's state stayed 'unknown', which the dashboard cannot tell apart from an
        idle card, so the Answer control was hidden exactly when it was needed.

        Polling for the option to appear fixes it in both directions and is usually
        *faster* than the old fixed sleep, because it returns as soon as the entity is
        ready instead of always paying 600 ms. The wait is bounded; on timeout the
        select is still attempted, since that costs nothing beyond the log line the
        caller already tolerated.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EntityId,

        [Parameter(Mandatory)]
        [string]$Option,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateRange(1, 40)]
        [int]$Attempts = 12,

        [ValidateRange(25, 2000)]
        [int]$DelayMs = 150
    )

    $ready = $false
    foreach ($attempt in 1..$Attempts) {
        try {
            $state = Get-HomeAssistantState -EntityId $EntityId -Headers $Headers
            if ($null -ne $state -and (@($state.attributes.options) -contains $Option)) {
                $ready = $true
                break
            }
        }
        catch {
            # A missing entity is a 404, which the retry layer rethrows immediately
            # rather than treating as transient. Discovery simply has not registered it
            # yet, so keep waiting rather than giving up.
        }
        if ($attempt -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
    }

    try {
        Invoke-HomeAssistantService -Domain 'select' -Service 'select_option' -Headers $Headers -Data @{
            entity_id = $EntityId
            option    = $Option
        }
    }
    catch {
        # Non-fatal by design: the attributes already carry (or have already cleared)
        # the question, so a failed state nudge costs only the dashboard's Answer
        # control, never the answer itself.
    }

    return $ready
}

function Set-CopilotMqttDecision {
    <#
        Arms the decision selector with a question.

        The options list is republished through discovery because the MQTT select
        platform fixes its options at configuration time. Passing no choices leaves
        the selector idle and marks the question freeform, to be answered in the
        reply box instead.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [string]$Question,

        [string[]]$Choices = @(),

        # Per-field option lists. When more than one field is present the question is
        # published as one dropdown per field instead of a single flattened list.
        [AllowNull()][object[]]$Fields = @(),

        [Parameter(Mandatory)]
        [string]$DecisionId,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $fieldList = @($Fields)
    $isMultiField = $fieldList.Count -gt 1 -and $fieldList.Count -le $script:CopilotMqttMaxFields

    # A multi-field question answers through its per-field dropdowns, so the main
    # selector carries only Cancel; a single-field one keeps the full option list.
    $options = @('Awaiting answer...')
    if ($isMultiField) {
        $options = @('Awaiting answer...', 'Cancel request')
    }
    elseif ($Choices.Count -gt 0) {
        $options = @('Awaiting answer...') +
            @($Choices | ForEach-Object {
                $text = [string]$_
                if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
                $text
            }) +
            @('Cancel request')
    }

    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = $options
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
    }

    $topic = "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/decision/config"
    Publish-CopilotMqttMessage -Topic $topic `
        -Payload ($decision | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    # The selector is optimistic, so its state stays 'unknown' until something sets it.
    # Drive it to the placeholder so the state itself says "a question is waiting" -
    # the dashboard keys the Answer control off that, and 'unknown' would otherwise be
    # indistinguishable from an idle card.
    Set-CopilotMqttSelectOption -EntityId "select.${node}_decision" `
        -Option 'Awaiting answer...' -Headers $Headers | Out-Null

    # Publish the per-field dropdowns for a multi-field question, and collapse them
    # for a single-field one so a previous question's fields never linger.
    if ($isMultiField) {
        Publish-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Fields $fieldList -Headers $Headers
    }
    else {
        Clear-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers
    }

    # The card shows the question in full, so it is published whole rather than split
    # into a preview plus a "show more" remainder - the expander is reserved for
    # reasoning and extra detail.
    $fullQuestion = $Question
    if ($fullQuestion.Length -gt $script:DecisionBridgeConfig.DecisionQuestionMaxChars) {
        $fullQuestion = $fullQuestion.Substring(0, $script:DecisionBridgeConfig.DecisionQuestionMaxChars).TrimEnd() +
            "`n`n_(truncated - see terminal)_"
    }
    $questionAttrs = @{
        decision_id = $DecisionId
        question = $fullQuestion
        choices = @($Choices)
        mode = if ($Choices.Count -gt 0 -or $fieldList.Count -gt 0) { 'multiple_choice' } else { 'freeform' }
        multi_field = $isMultiField
        field_count = $(if ($isMultiField) { $fieldList.Count } else { 0 })
        session = $SessionName
        machine = $Machine
        asked_at = [DateTimeOffset]::Now.ToString('o')
    }
    # Field labels ride on the decision attributes so the dashboard can name each
    # dropdown after its field without rebuilding the whole Lovelace config.
    if ($isMultiField) {
        for ($fi = 1; $fi -le $fieldList.Count; $fi++) {
            $lbl = [string]$fieldList[$fi - 1].Label
            if ([string]::IsNullOrWhiteSpace($lbl)) { $lbl = "Field $fi" }
            $questionAttrs["field_${fi}_label"] = $lbl
        }
    }
    Publish-CopilotMqttMessage -Topic $topics.DecisionAttributes `
        -Payload ($questionAttrs | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain

    $topics
}

function Clear-CopilotMqttDecision {
    <#
        Returns the selector to its idle state once an answer has been consumed.

        The selector is optimistic, so its value cannot be reset by publishing to a
        state topic - there is none. Resetting therefore means republishing the
        discovery config with only the idle option, which both clears the stale
        answer and stops the old choices being tappable a second time.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$SessionName,

        [Parameter(Mandatory)]
        [string]$Machine,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $topics = Get-CopilotMqttTopics -SessionId $SessionId
    $node = $topics.Node
    $device = New-CopilotMqttDeviceBlock -Node $node -SessionName $SessionName -Machine $Machine
    $availability = @(@{ topic = $topics.Availability; payload_available = 'online'; payload_not_available = 'offline' })

    $decision = @{
        name = 'Decision'
        unique_id = "${node}_decision"
        command_topic = $topics.DecisionCommand
        json_attributes_topic = $topics.DecisionAttributes
        options = @('Idle')
        icon = 'mdi:comment-question-outline'
        device = $device
        availability = $availability
    }

    Publish-CopilotMqttMessage `
        -Topic "$($script:CopilotMqttConfig.DiscoveryPrefix)/select/$node/decision/config" `
        -Payload ($decision | ConvertTo-Json -Depth 8 -Compress) -Headers $Headers -Retain
    Publish-CopilotMqttMessage -Topic $topics.DecisionAttributes -Payload '{}' -Headers $Headers -Retain

    # Drive the optimistic selector to 'Idle' so its state, not just its attributes,
    # reflects that nothing is waiting. The dashboard shows the Answer control only
    # when the state is something other than Idle.
    Set-CopilotMqttSelectOption -EntityId "select.${node}_decision" `
        -Option 'Idle' -Headers $Headers | Out-Null

    # Collapse any per-field dropdowns from a multi-field question.
    try {
        Clear-CopilotMqttDecisionFields -SessionId $SessionId -SessionName $SessionName `
            -Machine $Machine -Headers $Headers
    }
    catch {
        # Non-fatal.
    }
}

