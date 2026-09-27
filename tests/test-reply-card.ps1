#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for the dashboard reply card and the payload path behind it.

.DESCRIPTION
    The reply box used to be a Home Assistant `text` entity, which imposed three
    limits that could not be worked around from the daemon side: a text entity only
    commits on blur or Enter, so tapping Send sent the *previous* value and the press
    had to be armed and retried; an entity state is capped at 255 characters, so long
    replies were impossible; and an image cannot be put into an entity state at all.

    The card replaces that with one MQTT message carrying the text, any uploaded
    image ids, and a timestamp. The text arrives through the sensor's attributes,
    which have no length limit, and the timestamp is what stops a reply being
    delivered twice.

    Everything here is offline: the payload parsing and prompt building are pure, and
    the install path is exercised against a temporary folder with an injected
    WebSocket invoker.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')

$env:BRIDGE_FRONTEND_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\bridge-frontend-cards.ps1')
Remove-Item Env:\BRIDGE_FRONTEND_NORUN -ErrorAction SilentlyContinue

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
Remove-Item Env:\AGENT_BRIDGE_DAEMON_NORUN -ErrorAction SilentlyContinue

$script:Failures = 0
function Test-That {
    # Underscored locals: an assertion scriptblock resolves its free variables in this
    # scope, so a plain $ok here would shadow one the caller set up for it to read.
    param([string]$Name, [scriptblock]$Condition, [string]$Detail = '')
    $__ok = $false
    try { $__ok = [bool](& $Condition) } catch { $Detail = $_.Exception.Message }
    if ($__ok) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red
        $script:Failures++
    }
}

function New-PayloadState {
    param(
        [string]$Stamp = '2026-09-26T21:00:00.000Z',
        [AllowEmptyString()][string]$Text = 'hello',
        [object[]]$Images = @()
    )
    [pscustomobject]@{
        state      = $Stamp
        attributes = [pscustomobject]@{
            at     = $Stamp
            text   = $Text
            images = $Images
        }
    }
}

Write-Host '--- reading a submission from the card ---'

Test-That 'nothing at all is not a submission' {
    $null -eq (Get-BridgeReplyPayload -State $null)
}
Test-That 'an entity that has never received a message is not a submission' {
    $null -eq (Get-BridgeReplyPayload -State (New-PayloadState -Stamp 'unknown'))
}
Test-That 'an unavailable entity is not a submission' {
    $null -eq (Get-BridgeReplyPayload -State (New-PayloadState -Stamp 'unavailable'))
}
Test-That 'a state with no attributes is not a submission' {
    $null -eq (Get-BridgeReplyPayload -State ([pscustomobject]@{ state = '2026-09-26T21:00:00Z' }))
}
Test-That 'an empty message with no images is not a submission' {
    $null -eq (Get-BridgeReplyPayload -State (New-PayloadState -Text '   '))
}
Test-That 'typed text comes back with its timestamp' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Text 'fix the build')
    $__p.Text -eq 'fix the build' -and $__p.Stamp -eq '2026-09-26T21:00:00.000Z'
}

# The entire reason this entity exists rather than reusing the text box.
Test-That 'a reply far longer than a state can hold survives intact' {
    $__long = 'x' * 4000
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Text $__long)
    $__p.Text.Length -eq 4000
}

Test-That 'newlines survive, so a multi-line reply stays multi-line' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Text "one`ntwo")
    $__p.Text -eq "one`ntwo"
}

Write-Host '--- image references ---'

Test-That 'an uploaded image is carried through' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Images @(
        [pscustomobject]@{ id = 'abc123'; name = 'shot.png' }))
    $__p.Images.Count -eq 1 -and $__p.Images[0].Id -eq 'abc123' -and $__p.Images[0].Name -eq 'shot.png'
}
Test-That 'an image with no id is skipped rather than fetched' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Images @(
        [pscustomobject]@{ name = 'broken.png' },
        [pscustomobject]@{ id = 'good'; name = 'ok.png' }))
    $__p.Images.Count -eq 1 -and $__p.Images[0].Id -eq 'good'
}
Test-That 'an image on its own, with no text, is still a submission' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Text '' -Images @(
        [pscustomobject]@{ id = 'abc'; name = 'a.png' }))
    $null -ne $__p -and $__p.Images.Count -eq 1
}
Test-That 'a null entry in the image list does not throw' {
    $__p = Get-BridgeReplyPayload -State (New-PayloadState -Images @($null, [pscustomobject]@{ id = 'z' }))
    $__p.Images.Count -eq 1
}

Write-Host '--- building the prompt that gets typed ---'

Test-That 'a plain reply is typed unchanged' {
    (New-BridgeAttachmentPrompt -Text 'hello there') -eq 'hello there'
}
Test-That 'an attachment is referenced with @ and leads the prompt' {
    (New-BridgeAttachmentPrompt -Text 'what is this?' -Paths @('C:\att\a.png')) -eq '@C:\att\a.png what is this?'
}
Test-That 'several attachments all appear' {
    (New-BridgeAttachmentPrompt -Text 'look' -Paths @('C:\att\a.png', 'C:\att\b.png')) -eq
        '@C:\att\a.png @C:\att\b.png look'
}
Test-That 'an image with no message is still a valid prompt' {
    (New-BridgeAttachmentPrompt -Text '' -Paths @('C:\att\a.png')) -eq '@C:\att\a.png'
}
# There is no way to quote a path in the @ syntax, so a space would split one
# attachment into two broken words and corrupt the rest of the prompt.
Test-That 'a path containing a space is dropped rather than corrupting the prompt' {
    (New-BridgeAttachmentPrompt -Text 'hi' -Paths @('C:\my att\a.png')) -eq 'hi'
}
Test-That 'surrounding whitespace is trimmed off the typed text' {
    (New-BridgeAttachmentPrompt -Text '   padded   ') -eq 'padded'
}
Test-That 'an empty reply with no attachments produces nothing to send' {
    [string]::IsNullOrWhiteSpace((New-BridgeAttachmentPrompt -Text '   '))
}

Write-Host '--- where attachments are stored ---'

Test-That 'the attachment folder never contains a space' {
    (Get-BridgeAttachmentRoot) -notmatch '\s'
}
Test-That 'the attachment folder exists once asked for' {
    Test-Path -LiteralPath (Get-BridgeAttachmentRoot)
}

Write-Host '--- the MQTT entity behind the card ---'

$script:Topics = Get-CopilotMqttTopics -SessionId 'abcdef0123456789'
$script:Ids = Get-CopilotMqttEntityIds -SessionId 'abcdef0123456789'
$script:Node = Get-CopilotMqttNodeId -SessionId 'abcdef0123456789'

Test-That 'the session has a topic for the card to publish to' {
    -not [string]::IsNullOrWhiteSpace($script:Topics.ReplyPayload)
}
Test-That 'the payload topic is scoped to the session node' {
    $script:Topics.ReplyPayload -like "*/$($script:Node)/replypayload/set"
}
Test-That 'the payload sensor entity id is known' {
    $script:Ids.ReplyPayload -eq "sensor.$($script:Node)_reply_payload"
}
# A session that is withdrawn must take the new entity with it, or the orphan sweep
# leaves a dead payload sensor behind exactly as it once did for the Stop button.
Test-That 'withdrawing a session removes the payload sensor too' {
    @(Get-CopilotMqttSessionDiscoveryTopic -Node $script:Node) -contains
        "homeassistant/sensor/$($script:Node)/replypayload/config"
}
Test-That 'withdrawing a session also clears the payload topic' {
    @(Get-CopilotMqttSessionStateTopic -Node $script:Node) -contains
        "copilot/cli/$($script:Node)/replypayload/set"
}

# The same config is used when provisioning the sensor onto a session that was
# already running, so the two can never describe a different entity.
$script:PayloadConfig = New-CopilotMqttReplyPayloadConfig -Node $script:Node `
    -Device ([pscustomobject]@{ name = 'x' }) -Availability @(@{ topic = 'a' }) `
    -Topic $script:Topics.ReplyPayload

Test-That 'the sensor listens on the topic the card publishes to' {
    $script:PayloadConfig.state_topic -eq $script:Topics.ReplyPayload
}
# Attributes are the only part of an entity Home Assistant does not cap at 255.
Test-That 'the reply text is read from attributes, not the state' {
    $script:PayloadConfig.json_attributes_topic -eq $script:Topics.ReplyPayload
}
Test-That 'the state is only the timestamp, which is short enough to fit' {
    $script:PayloadConfig.value_template -eq '{{ value_json.at }}'
}
Test-That 'the sensor unique id matches the entity id the daemon reads' {
    $script:PayloadConfig.unique_id -eq "$($script:Node)_reply_payload"
}

Write-Host '--- the card resource url ---'

Test-That 'the card is served from the local www folder' {
    (Get-BridgeReplyCardUrl -Version '') -eq '/local/agent-bridge-reply-card.js'
}
Test-That 'a version is appended so browsers reload it after an upgrade' {
    (Get-BridgeReplyCardUrl -Version '1.9.0') -eq '/local/agent-bridge-reply-card.js?v=1.9.0'
}
Test-That 'the resource matcher recognises the card whatever the version' {
    Test-BridgeCardResourceMatch -ResourceUrl '/local/agent-bridge-reply-card.js?v=9.9.9' `
        -FileName 'agent-bridge-reply-card.js'
}

Write-Host '--- finding the config folder ---'

Test-That 'an explicitly configured path is tried first' {
    @(Get-BridgeConfigPathCandidate -Explicit 'D:\ha' -BaseUrl 'http://hass.local:8123')[0] -eq 'D:\ha'
}
Test-That 'the usual samba share is derived from the server address' {
    @(Get-BridgeConfigPathCandidate -Explicit '' -BaseUrl 'http://192.168.1.188:8123')[0] -eq '\\192.168.1.188\config'
}
Test-That 'a trailing slash on a configured path is not doubled up' {
    @(Get-BridgeConfigPathCandidate -Explicit 'D:\ha\' -BaseUrl '')[0] -eq 'D:\ha'
}
Test-That 'no address and no configured path yields nothing to try' {
    @(Get-BridgeConfigPathCandidate -Explicit '' -BaseUrl '').Count -eq 0
}
Test-That 'an unparseable address does not throw' {
    @(Get-BridgeConfigPathCandidate -Explicit '' -BaseUrl 'not a url').Count -ge 0
}

Write-Host '--- installing the card ---'

$script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-card-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
$script:CardSource = (Resolve-Path (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')).Path

try {
    Test-That 'the card source ships with the bridge' {
        Test-Path -LiteralPath $script:CardSource
    }

    $script:Sent = @()
    $script:Invoker = { param($commands) $script:Sent += $commands; @(@()) }

    $script:Result = Install-BridgeReplyCard -SourcePath $script:CardSource -ConfigPath $script:Sandbox `
        -Version '1.9.0' -Invoker $script:Invoker -Resources { @() }

    Test-That 'the card is copied into the config folder' { $script:Result.Deployed }
    Test-That 'it lands in www, where Home Assistant serves /local from' {
        Test-Path -LiteralPath (Join-Path $script:Sandbox 'www\agent-bridge-reply-card.js')
    }
    Test-That 'the copy is the real card, not an empty file' {
        (Get-Item (Join-Path $script:Sandbox 'www\agent-bridge-reply-card.js')).Length -gt 1000
    }
    Test-That 'the resource is registered' { $script:Result.Registered }
    Test-That 'registering creates a module resource' {
        $script:Sent[0].type -eq 'lovelace/resources/create' -and $script:Sent[0].res_type -eq 'module'
    }
    Test-That 'the registered url is the versioned one' {
        $script:Sent[0].url -eq '/local/agent-bridge-reply-card.js?v=1.9.0'
    }

    # An upgrade must not leave two resources pointing at the same card, one of them
    # stuck on the old version string.
    $script:Sent = @()
    $script:Existing = @([pscustomobject]@{ id = 'res-1'; url = '/local/agent-bridge-reply-card.js?v=1.8.0' })
    $script:Result2 = Install-BridgeReplyCard -SourcePath $script:CardSource -ConfigPath $script:Sandbox `
        -Version '1.9.0' -Invoker $script:Invoker -Resources { $script:Existing }

    Test-That 'an upgrade updates the existing resource instead of adding another' {
        $script:Sent.Count -eq 1 -and $script:Sent[0].type -eq 'lovelace/resources/update'
    }
    Test-That 'the update targets the resource that was already there' {
        $script:Sent[0].resource_id -eq 'res-1'
    }
    Test-That 'the update carries the new version' {
        $script:Sent[0].url -eq '/local/agent-bridge-reply-card.js?v=1.9.0'
    }

    $script:Sent = @()
    $script:Current = @([pscustomobject]@{ id = 'res-1'; url = '/local/agent-bridge-reply-card.js?v=1.9.0' })
    $script:Result3 = Install-BridgeReplyCard -SourcePath $script:CardSource -ConfigPath $script:Sandbox `
        -Version '1.9.0' -Invoker $script:Invoker -Resources { $script:Current }

    Test-That 're-running with nothing to change sends no resource command' {
        $script:Sent.Count -eq 0
    }
    Test-That 'and still reports the card as registered' { $script:Result3.Registered }

    # A bridge that cannot deliver the card is still a working bridge, so none of
    # these may throw.
    $script:Missing = Install-BridgeReplyCard -SourcePath (Join-Path $script:Sandbox 'nope.js') `
        -ConfigPath $script:Sandbox -Version '1.9.0' -Invoker $script:Invoker -Resources { @() }
    Test-That 'a missing card source is reported, not thrown' {
        (-not $script:Missing.Deployed) -and $script:Missing.Detail -match 'not found'
    }

    $script:NoShare = Install-BridgeReplyCard -SourcePath $script:CardSource `
        -ConfigPath (Join-Path $script:Sandbox 'absent') -Version '1.9.0' `
        -Invoker $script:Invoker -Resources { @() }
    Test-That 'an unreachable config folder is reported, not thrown' {
        (-not $script:NoShare.Deployed) -and $script:NoShare.Detail -match 'no reachable'
    }
}
finally {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the card itself ---'

$script:CardText = Get-Content -LiteralPath $script:CardSource -Raw

Test-That 'the card registers itself as a custom element' {
    $script:CardText -match "customElements\.define\('agent-bridge-reply-card'"
}
Test-That 'it refuses a config with no topic, rather than failing silently at send time' {
    $script:CardText -match '"topic" is required'
}
Test-That 'Send reads the textarea directly, which is what removes the double press' {
    $script:CardText -match '_els\.textarea\.value'
}
Test-That 'it publishes over MQTT rather than writing an entity state' {
    $script:CardText -match "callService\('mqtt', 'publish'"
}
Test-That 'it uploads pasted images to Home Assistant' {
    $script:CardText -match "'/api/image/upload'"
}
Test-That 'it handles a paste event' {
    $script:CardText -match "addEventListener\('paste'"
}
# Re-rendering on every state update would wipe half-typed text, which is the exact
# failure this card exists to remove.
Test-That 'the hass setter does not rebuild the card once it is built' {
    $script:CardText -match 'if \(!this\._built\) \{\s*this\._build\(\);\s*\}'
}

Write-Host '--- forcing the payload sensor onto a predictable entity id ---'

# Home Assistant derives an entity id from the device and entity names and ignores
# object_id, so a newly discovered sensor arrives as
# sensor.copilot_<session title>_reply_payload. The daemon reads
# sensor.<node>_reply_payload, so without the rename below it reads nothing at all
# and every reply typed into the card is lost silently.
$script:RegistryCommands = @()
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    if ($Commands[0].type -eq 'config/entity_registry/list') {
        return @(, @(
            [pscustomobject]@{ unique_id = "$($script:Node)_reply_payload"
                               entity_id = 'sensor.copilot_a_long_session_title_reply_payload' }
            [pscustomobject]@{ unique_id = "$($script:Node)_status"
                               entity_id = "sensor.$($script:Node)_status" }
        ))
    }
    $script:RegistryCommands += $Commands
    @()
}

$script:ForcedIds = Set-CopilotMqttEntityIds -SessionId 'abcdef0123456789'
$script:Renames = @($script:RegistryCommands | Where-Object { $_.type -eq 'config/entity_registry/update' })

Test-That 'the payload sensor is one of the ids the bridge pins down' {
    $script:ForcedIds.ReplyPayload -eq "sensor.$($script:Node)_reply_payload"
}
Test-That 'a sensor that came up under the session title is renamed' {
    @($script:Renames | Where-Object { $_.new_entity_id -eq "sensor.$($script:Node)_reply_payload" }).Count -eq 1
}
Test-That 'the rename targets the id Home Assistant actually gave it' {
    @($script:Renames | Where-Object {
        $_.new_entity_id -eq "sensor.$($script:Node)_reply_payload"
    })[0].entity_id -eq 'sensor.copilot_a_long_session_title_reply_payload'
}
Test-That 'an entity already on the right id is left alone' {
    @($script:Renames | Where-Object { $_.new_entity_id -eq "sensor.$($script:Node)_status" }).Count -eq 0
}

Write-Host '--- how the reply box is rendered on the dashboard ---'

# Capture the config that would be saved instead of sending it to Home Assistant.
$script:SavedConfig = $null
function Invoke-CopilotHaWebSocket {
    param([Parameter(Mandatory)][object[]]$Commands)
    $script:SavedConfig = $Commands[0].config
    @()
}

$script:DashSessions = @([pscustomobject]@{
    Node = 'copilot_abc123def456'; Name = 'Copilot: a task'
    Machine = [Environment]::MachineName; Kind = 'copilot'
})

Save-CopilotSessionDashboard -Sessions $script:DashSessions `
    -ReplyCardUrl '/local/agent-bridge-reply-card.js?v=1.9.0'
$script:WithCard = $script:SavedConfig | ConvertTo-Json -Depth 40

Test-That 'the session card uses the bridge reply card when it is installed' {
    $script:WithCard -match 'custom:agent-bridge-reply-card'
}
Test-That 'the card is pointed at that session own payload topic' {
    $script:WithCard -match 'copilot/cli/copilot_abc123def456/replypayload/set'
}

Save-CopilotSessionDashboard -Sessions $script:DashSessions -ReplyCardUrl ''
$script:NoCard = $script:SavedConfig | ConvertTo-Json -Depth 40

# A view referencing a custom card that is not installed renders an error box where
# the reply box should be, so the fallback matters more than it looks.
Test-That 'without the card the plain text box is rendered instead' {
    $script:NoCard -match 'text\.copilot_abc123def456_reply'
}
Test-That 'and the custom card is not referenced at all' {
    -not ($script:NoCard -match 'custom:agent-bridge-reply-card')
}

Write-Host '--- deciding whether the card is available ---'

Test-That 'a registered resource is found whatever its version' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ url = '/local/agent-bridge-reply-card.js?v=2.0.0' })
    }) -eq '/local/agent-bridge-reply-card.js?v=2.0.0'
}
Test-That 'an unrelated resource list means the card is not available' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ url = '/hacsfiles/button-card/button-card.js' })
    }) -eq ''
}
Test-That 'an empty resource list means the card is not available' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources { @() }) -eq ''
}
Test-That 'a resource entry with no url does not throw' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ type = 'module' }, $null)
    }) -eq ''
}
# Falling back to the text box is the safe answer when Home Assistant cannot be asked.
Test-That 'an unreadable resource list falls back rather than throwing' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources { throw 'no websocket' }) -eq ''
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) failing assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'all reply card checks passed' -ForegroundColor Green
