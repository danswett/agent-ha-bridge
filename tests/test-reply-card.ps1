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

$script:CardSource = (Resolve-Path (Join-Path $PSScriptRoot '..\frontend\agent-bridge-reply-card.js')).Path
$script:InlineUrl = Get-BridgeInlineReplyCardUrl -SourcePath $script:CardSource -Version '1.9.0'

Test-That 'the card is registered inline, as a data url' {
    $script:InlineUrl.StartsWith('data:text/javascript;base64,')
}
Test-That 'the inline url carries the real card' {
    $body = $script:InlineUrl.Substring('data:text/javascript;base64,'.Length).Split('#')[0]
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body)) -eq (Get-Content -LiteralPath $script:CardSource -Raw)
}
Test-That 'its fragment names the card and its version' { $script:InlineUrl.EndsWith('#agent-bridge-reply-card.js?v=1.9.0') }
Test-That 'the resource matcher recognises the inline card' {
    Test-BridgeCardResourceMatch -ResourceUrl $script:InlineUrl -FileName 'agent-bridge-reply-card.js'
}
Test-That 'and a file-served card from an earlier version' {
    Test-BridgeCardResourceMatch -ResourceUrl '/local/agent-bridge-reply-card.js?v=9.9.9' -FileName 'agent-bridge-reply-card.js'
}
Test-That 'but not some other inline resource' {
    -not (Test-BridgeCardResourceMatch -ResourceUrl 'data:text/javascript;base64,YWJj' -FileName 'agent-bridge-reply-card.js')
}

Write-Host '--- installing the card ---'

Test-That 'the card source ships with the bridge' { Test-Path -LiteralPath $script:CardSource }

$script:Sent = @()
$script:Invoker = { param($commands) $script:Sent += $commands; @(@()) }

# The case that used to leave the card missing for good: a first install, with
# nothing in Home Assistant yet and no file share to write to.
$script:First = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { @() }
Test-That 'a first install registers the card' { $script:First.Ok -and $script:First.Action -eq 'deployed' }
Test-That 'as one module resource' {
    $script:Sent.Count -eq 1 -and $script:Sent[0].type -eq 'lovelace/resources/create' -and $script:Sent[0].res_type -eq 'module'
}
Test-That 'pointing at the inline card' { $script:Sent[0].url -eq $script:InlineUrl }

Test-That 'the card version is read from the card itself' {
    (Get-BridgeReplyCardFileVersion -SourcePath $script:CardSource) -match '^\d+\.\d+\.\d+$'
}
Test-That 'a missing card file yields no version rather than throwing' {
    (Get-BridgeReplyCardFileVersion -SourcePath (Join-Path $PSScriptRoot 'nope.js')) -eq ''
}
$script:Sent = @()
$script:Auto = Install-BridgeReplyCard -SourcePath $script:CardSource -Invoker $script:Invoker -Resources { @() }
Test-That 'with no version passed it uses the card file version' {
    $script:Auto.Url.EndsWith("?v=$(Get-BridgeReplyCardFileVersion -SourcePath $script:CardSource)")
}

# Home Assistant is shared, so on the second machine the card is already there.
$script:Sent = @()
$script:Current = @([pscustomobject]@{ id = 'res-1'; url = $script:InlineUrl })
$script:Again = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { $script:Current } -FileProbe { throw 'an inline card has no file to probe' }
Test-That 're-running with nothing to change sends no resource command' { $script:Sent.Count -eq 0 }
Test-That 'it reports the card as already current' { $script:Again.Ok -and $script:Again.Action -eq 'current' }

# An upgrade must not leave two resources pointing at the same card.
$script:Sent = @()
$script:Older = @([pscustomobject]@{ id = 'res-1'; url = (Get-BridgeInlineReplyCardUrl -SourcePath $script:CardSource -Version '1.8.0') })
$script:Upgrade = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { $script:Older }
Test-That 'an upgrade updates the existing resource instead of adding another' {
    $script:Upgrade.Action -eq 'updated' -and $script:Sent.Count -eq 1 -and
    $script:Sent[0].type -eq 'lovelace/resources/update' -and $script:Sent[0].resource_id -eq 'res-1'
}
Test-That 'the update carries the new version' { $script:Sent[0].url -eq $script:InlineUrl }

# Earlier versions served the card as a file from `www`. Even at the same version it
# moves to the inline copy, so every install ends up on the one route.
$script:Sent = @()
$script:FileServed = @([pscustomobject]@{ id = 'res-7'; url = '/local/agent-bridge-reply-card.js?v=1.9.0' })
$script:Migrated = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { $script:FileServed } -FileProbe { $true }
Test-That 'a file-served card is re-pointed at the inline copy' {
    $script:Migrated.Action -eq 'updated' -and $script:Sent[0].resource_id -eq 'res-7' -and $script:Sent[0].url -eq $script:InlineUrl
}

# A bridge that cannot deliver the card is still a working bridge, so none of these
# may throw.
$script:Kept = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker { param($c) throw 'websocket down' } -Resources { $script:FileServed } -FileProbe { $true }
Test-That 'an older card that cannot be replaced is kept, not failed' {
    $script:Kept.Ok -and $script:Kept.Action -eq 'kept'
}

$script:Missing = Install-BridgeReplyCard -SourcePath (Join-Path $PSScriptRoot 'nope.js') -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { @() }
Test-That 'a missing card source is reported, not thrown' {
    (-not $script:Missing.Ok) -and $script:Missing.Detail -match 'not readable'
}

$script:NoWebsocket = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker { param($c) throw 'websocket down' } -Resources { @() }
Test-That 'a failed registration is reported, not thrown' {
    (-not $script:NoWebsocket.Ok) -and $script:NoWebsocket.Detail -match 'could not register'
}

$script:Unreadable = Install-BridgeReplyCard -SourcePath $script:CardSource -Version '1.9.0' `
    -Invoker $script:Invoker -Resources { throw 'no websocket' }
Test-That 'an unreadable resource list is reported, not thrown' {
    (-not $script:Unreadable.Ok) -and $script:Unreadable.Detail -match 'could not read'
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
# Home Assistant restarting is exactly when this read fails, and answering "no card"
# there rebuilt the dashboard without its session, activity and launch cards - for the
# length of the cache, so a restart visibly downgraded it to the pre-card layout.
Test-That 'an unreadable resource list keeps the last answer rather than dropping the cards' {
    [void](Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ url = '/local/agent-bridge-reply-card.js?v=1.13.0' })
    })
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources { throw 'no websocket' }) -eq '/local/agent-bridge-reply-card.js?v=1.13.0'
}
Test-That 'and the real answer comes back once it can be read again' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ url = '/local/agent-bridge-reply-card.js?v=1.13.1' })
    }) -eq '/local/agent-bridge-reply-card.js?v=1.13.1'
}
# A read that succeeded and found nothing is different: the card really is not there.
Test-That 'a successful read that finds nothing still means no card' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources { @() }) -eq ''
}

# An inline card's base64 body contains slashes, so it is recognised by its fragment.
$inlineCard = 'data:text/javascript;base64,Ly8gYS9iL2M/ZD0x/abc+/=#agent-bridge-reply-card.js?v=1.10.0'
Test-That 'an inline card resource is found' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources { @([pscustomobject]@{ url = $inlineCard }) }) -eq $inlineCard
}
Test-That 'an inline card of 1.10.0 or later gets the activity header' {
    Test-BridgeActivityCardServed -ReplyCardUrl $inlineCard
}
Test-That 'some other inline resource is not mistaken for the card' {
    (Get-BridgeServedReplyCardUrl -CacheSeconds 0 -Resources {
        @([pscustomobject]@{ url = 'data:text/javascript;base64,YWdlbnQtYnJpZGdlLXJlcGx5LWNhcmQuanM=' })
    }) -eq ''
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) failing assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'all reply card checks passed' -ForegroundColor Green
# Explicit: without it pwsh reports the last external command's exit code.
exit 0
