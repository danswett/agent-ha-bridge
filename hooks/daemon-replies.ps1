<#
    Bridge daemon: dashboard to agent text.

    Delivers what is typed or pasted into a card to its session - images included -
    and confirms it was submitted.

    Part of agent-bridge-daemon.ps1, which dot-sources it into its own scope after
    declaring the shared $script: state; see docs/daemon-split.md.
    It changes no shared state.
#>

function Get-BridgeAttachmentRoot {
    <#
        Where images from the reply card are written before being attached.

        A space in the private path is a transport limitation, not permission to
        put the file in Public or shared TEMP. Formatting refuses that submission.
        Unidentified legacy storage is left alone rather than claimed by this writer.
    #>
    param([switch]$NoCreate)
    $context = Get-BridgeInstallContext
    Get-BridgeAttachmentRootForInstallation -BridgeHome $context.BridgeHome -LocalAppData $context.LocalAppData `
        -InstallationId $context.Id -Legacy $context.Legacy -NoCreate:$NoCreate
}

function Get-BridgeAttachmentRootForInstallation {
    <# The production allocator; context acquisition remains with the public wrapper. #>
    param(
        [Parameter(Mandatory)][string]$BridgeHome,
        [AllowNull()][AllowEmptyString()][string]$LocalAppData,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$InstallationId,
        [Parameter(Mandatory)][bool]$Legacy,
        [switch]$NoCreate
    )

    if ($Legacy -or [string]::IsNullOrWhiteSpace($InstallationId)) {
        throw 'Attachment staging requires an installation identity. Reconfigure the installation before sending attachments; legacy files were not changed.'
    }
    $root = if ($script:BridgeIsWindows -and -not [string]::IsNullOrWhiteSpace($LocalAppData)) {
        Join-Path $LocalAppData 'agent-ha-bridge\attachments'
    }
    else {
        Join-Path $BridgeHome 'attachments'
    }
    $root = Join-Path $root "install-$($InstallationId)"
    if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $root }
    Assert-BridgeInstallPayload -Root $root -CheckAncestors
    if (-not $NoCreate) {
        [void][IO.Directory]::CreateDirectory($root)
        if (-not (Protect-BridgeSecretFile -Path $root)) {
            throw 'Could not protect the attachment directory; no attachment contents were written.'
        }
    }
    $root
}

function Get-BridgeReplyPayload {
    <#
        Reads one submission from the reply card's payload sensor.

        Returns $null when there is nothing usable to send.

        The stamp is the card's own timestamp, carried in the sensor state via
        value_template. Comparing it against the last one handled is what makes a
        duplicate delivery impossible - the same contract the Submit button's press
        stamp already uses. The text itself is read from the attributes rather than
        the state because Home Assistant caps a state at 255 characters and does not
        cap attributes, which is the whole reason this entity exists.
    #>
    param([object]$State)

    if ($null -eq $State) { return $null }

    $stamp = ''
    if ($State.PSObject.Properties['state']) { $stamp = [string]$State.state }
    if ([string]::IsNullOrWhiteSpace($stamp) -or $stamp -in @('unknown', 'unavailable')) { return $null }

    $attrs = $null
    if ($State.PSObject.Properties['attributes']) { $attrs = $State.attributes }
    if ($null -eq $attrs) { return $null }

    $text = ''
    if ($attrs.PSObject.Properties['text']) { $text = [string]$attrs.text }

    $images = [System.Collections.Generic.List[object]]::new()
    if ($attrs.PSObject.Properties['images'] -and $null -ne $attrs.images) {
        foreach ($image in @($attrs.images)) {
            if ($null -eq $image) { continue }
            $id = ''
            if ($image.PSObject.Properties['id']) { $id = [string]$image.id }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $name = ''
            if ($image.PSObject.Properties['name']) { $name = [string]$image.name }
            $images.Add([pscustomobject]@{ Id = $id; Name = $name })
        }
    }

    # Anything that is not an image arrives as bytes rather than an id. Home
    # Assistant's /api/image/upload runs what it is given through an image decoder
    # and answers 400 for a document, so there is nothing to fetch back by id and the
    # card base64s the file into this payload instead.
    $files = [System.Collections.Generic.List[object]]::new()
    if ($attrs.PSObject.Properties['files'] -and $null -ne $attrs.files) {
        foreach ($file in @($attrs.files)) {
            if ($null -eq $file) { continue }
            $b64 = ''
            if ($file.PSObject.Properties['b64']) { $b64 = [string]$file.b64 }
            if ([string]::IsNullOrWhiteSpace($b64)) { continue }
            $name = ''
            if ($file.PSObject.Properties['name']) { $name = [string]$file.name }
            $files.Add([pscustomobject]@{ Name = $name; Base64 = $b64 })
        }
    }

    # An empty submission is not an error, it is just nothing to do.
    if ([string]::IsNullOrWhiteSpace($text) -and $images.Count -eq 0 -and $files.Count -eq 0) { return $null }

    # Who sent it. A Submit press commits through a service call and Home Assistant
    # records the account on it, but this arrives over MQTT and an MQTT-published
    # state carries no context at all - measured: context.user_id comes back empty.
    # So there is nothing authenticated to read here and the publisher has to say.
    # Saying nothing means a person, which is what the reply card does: a reply typed
    # on the dashboard stays the person's, and only a client that marks itself gets
    # treated as an agent. This is presentation - which colour the card glows - not a
    # permission, and publishing here already requires a Home Assistant token.
    $driver = 'human'
    if ($attrs.PSObject.Properties['driver'] -and ([string]$attrs.driver) -eq 'agent') { $driver = 'agent' }

    [pscustomobject]@{
        Stamp  = $stamp
        Text   = $text
        Driver = $driver
        Images = $images.ToArray()
        Files  = $files.ToArray()
    }
}

function New-BridgeAttachmentPrompt {
    <#
        Builds the text that is typed into the CLI for a reply carrying attachments.

        Copilot CLI attaches a file when the prompt references it as `@<path>`, so
        the attachments lead and the typed text follows. No quoted-path transport
        has been established here. Refuse unrepresentable paths rather than sending
        the text or a subset of the attachments without telling the sender.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$Paths = @()
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path) -or $path -match '\s') {
            throw 'An attachment path cannot be represented by the current reply transport; no reply was sent.'
        }
        $parts.Add("@$path")
    }

    $clean = ([string]$Text).Trim()
    if (-not [string]::IsNullOrWhiteSpace($clean)) { $parts.Add($clean) }

    $parts -join ' '
}

function Save-BridgeReplyAttachment {
    <#
        Downloads one image the reply card uploaded to Home Assistant.

        Returns the local path, or '' if it could not be fetched. The extension is
        taken from the original file name because the CLI decides how to treat an
        attachment from its extension, and falls back to .png - the format anything
        pasted from a clipboard arrives as.
    #>
    param(
        [Parameter(Mandatory)][string]$ImageId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $extension = ''
    try { $extension = [System.IO.Path]::GetExtension($Name) }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        $extension = ''
    }
    if ($extension -notin @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic', '.heif', '.pdf')) {
        $extension = '.png'
    }

    $safeId = $ImageId -replace '[^0-9a-zA-Z]', ''
    if ([string]::IsNullOrWhiteSpace($safeId)) {
        Write-DaemonLog -Message 'could not stage an attachment with an unusable image identifier'
        return ''
    }

    try {
        $uri = "$($script:DecisionBridgeConfig.HomeAssistantBaseUrl)/api/image/serve/$ImageId/original"
        Assert-BridgeHttpAllowed -Uri $uri -Transport WebRequest
        $root = Get-BridgeAttachmentRoot
        # A repeated image id must not truncate bytes retained from an earlier send.
        $path = Join-Path $root "$([guid]::NewGuid().ToString('N'))-$safeId$extension"
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
        Assert-BridgeInstallPayload -Root $path -CheckAncestors
        Initialize-BridgeSecretFile -Path $path
        Invoke-WebRequest -Uri $uri -Headers $Headers -OutFile $path -UseBasicParsing -ErrorAction Stop | Out-Null
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
        Assert-BridgeInstallPayload -Root $path -CheckAncestors
        if (-not (Test-BridgeSecretFileProtected -Path $root) -or
            -not (Test-BridgeSecretFileProtected -Path $path) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path -Force).Length -eq 0) {
            throw 'The downloaded attachment is missing, empty or no longer protected.'
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Write-DaemonLog -Message "could not fetch attachment $ImageId : $($_.Exception.Message)"
        return ''
    }

    $path
}

function Get-BridgeAttachmentFileName {
    <#
        A file name from the reply card, rewritten into one that is safe to hand the
        CLI as `@<path>`.

        The current transport has no established quoting, so a space would split
        one attachment into two broken words. The name arrives from a browser, so
        a directory separator or `..` in it would write the file
        somewhere other than the attachment root. The extension is kept, and only the
        extension is trusted to be short, because the CLI decides how to treat an
        attachment from it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    # Greedy, so everything up to the last separator goes - including a `..` segment.
    $leaf = ([string]$Name) -replace '.*[\\/]', ''

    # An extension is a dot and a few alphanumerics, or it is not one worth keeping.
    # That also disposes of a trailing dot and of a name that is only punctuation.
    $extension = [IO.Path]::GetExtension($leaf)
    if ($extension -notmatch '^\.[0-9A-Za-z]{1,12}$') { $extension = '' }

    $base = [IO.Path]::GetFileNameWithoutExtension($leaf) -replace '[^0-9A-Za-z._-]', '-'
    $base = $base.Trim('-', '.')
    if ($base.Length -gt 48) { $base = $base.Substring(0, 48) }
    if ([string]::IsNullOrWhiteSpace($base)) { $base = 'attachment' }

    "$base$extension"
}

function Save-BridgeReplyFile {
    <#
        Writes one non-image attachment the reply card sent inline.

        Returns the local path, or '' if it could not be written. Images take the
        other route - uploaded to Home Assistant, fetched back by id - because that
        endpoint decodes what it is given and answers 400 for anything that is not an
        image, so a document has nowhere to go but the payload itself.

        The size is checked again here rather than trusted from the card: the card's
        limit keeps the state machine healthy, and this one is what stops a payload
        that did not come from the card writing whatever it likes to disk.

        The random prefix keeps a later send from overwriting a private copy retained
        after failure or still awaiting the client's read.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Base64,
        [int]$MaxBytes = 262144
    )

    if ([string]::IsNullOrWhiteSpace($Base64)) {
        Write-DaemonLog -Message 'could not stage an inline attachment with no bytes'
        return ''
    }

    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($Base64) }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Write-DaemonLog -Message "could not decode attachment '$Name': $($_.Exception.Message)"
        return ''
    }

    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        Write-DaemonLog -Message 'could not stage an empty inline attachment'
        return ''
    }
    if ($bytes.Length -gt $MaxBytes) {
        Write-DaemonLog -Message "attachment '$Name' is $($bytes.Length) bytes, over the $MaxBytes limit"
        return ''
    }

    try {
        $safe = Get-BridgeAttachmentFileName -Name $Name
        $token = [guid]::NewGuid().ToString('N')
        $root = Get-BridgeAttachmentRoot
        $path = Join-Path $root "$token-$safe"
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
        Assert-BridgeInstallPayload -Root $path -CheckAncestors
        Initialize-BridgeSecretFile -Path $path
        [IO.File]::WriteAllBytes($path, $bytes)
        if (Test-BridgeTestExecution) { Assert-BridgeTestPath -Path $path }
        Assert-BridgeInstallPayload -Root $path -CheckAncestors
        if (-not (Test-BridgeSecretFileProtected -Path $root) -or
            -not (Test-BridgeSecretFileProtected -Path $path) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw 'The inline attachment is missing or no longer protected.'
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Write-DaemonLog -Message "could not write attachment '$Name': $($_.Exception.Message)"
        return ''
    }

    $path
}

function Remove-BridgeHomeAssistantImage {
    <#
        Deletes an uploaded image after staging and successful reply transport.
        Transport success is not proof that the client has read the local copy.

        Best effort: a failure leaves a file in Home Assistant's upload store, which
        is untidy but harmless, and must never stop a reply being delivered.
    #>
    param([Parameter(Mandatory)][string]$ImageId)

    try {
        [void](Invoke-CopilotHaWebSocket -Commands @(@{ type = 'image/delete'; image_id = $ImageId }))
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Write-DaemonLog -Message "could not remove uploaded image $ImageId from Home Assistant: $($_.Exception.Message)"
    }
}

function Remove-BridgeStaleAttachment {
    <#
        Clears attachments left behind by previous replies.

        Immediate deletion would race the client's read. This opportunistic sweep
        after a successful reply is not an acknowledgement or an idle expiry budget.
    #>
    param([int]$MaxAgeHours = 24)

    try {
        $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
        $root = Get-BridgeAttachmentRoot -NoCreate
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        Write-DaemonLog -Message "could not clean up old attachments: $($_.Exception.Message)"
    }
}

function Invoke-PendingReplies {
    <#
        Delivers any reply box that currently holds text.

        The WebSocket watch only sees a reply if the state change fires during its
        active window, so a reply that lands in the gap between windows would be lost.
        Reading the retained value on every reconcile closes that race: the box keeps
        its value until the daemon clears it, so it is always seen within one
        reconcile interval regardless of timing. The push path stays as a latency
        optimization on top of this.

        A per-session hash guards the brief window between delivering a reply and the
        clear taking effect, so the same text is never injected twice.

        For each session: whether the reply box is free (Test-DaemonReplyBoxFree), then
        the reply card's payload (Send-DaemonCardPayload), then the text box and its
        Send button (Send-DaemonReplyBoxText).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Live
    )

    foreach ($sessionId in @($State.Keys)) {
        if (-not $Live.ContainsKey($sessionId)) { continue }
        if (-not (Test-DaemonReplyBoxFree -SessionId $sessionId -Session $Live[$sessionId] -State $State -Headers $Headers)) { continue }
        $entry = $State[$sessionId]
        if (Send-DaemonCardPayload -SessionId $sessionId -Entry $entry -Headers $Headers) { continue }
        Send-DaemonReplyBoxText -SessionId $sessionId -Entry $entry -Headers $Headers
    }
}

function Test-DaemonReplyBoxFree {
    <#
        Whether a session's reply box is free for a reply, rather than owned by a
        local question or approval. Remote card state cannot override local ownership;
        a card left over from an answered question is cleared only while unowned.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $ownsInput = {
        try {
            if ($null -ne (Get-CopilotDecisionMarker -SessionId $sessionId -RequireReadable)) { return $true }
            $readApproval = (Get-DaemonAgent -Kind (Get-DaemonEntryKind -Entry $Session)).ApprovalMarker
            if ($readApproval) { return $null -ne (& $readApproval $sessionId $true) }
            $false
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            Write-DaemonLog -Message "could not establish local input ownership for $sessionId : $($_.Exception.Message)"
            $true
        }
    }
    # An existing local owner takes precedence even when the card is empty or absent.
    # Recheck around I/O because a hook can write a marker while the read is in flight.
    if (& $ownsInput) { return $false }

    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $armedQuestion = ''
    try {
        $decisionState = Get-DaemonEntityState -EntityId "select.${node}_decision" -Headers $Headers
        $armedQuestion = Get-BridgeStateAttribute -State $decisionState -Name 'question'
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        # Only a card that genuinely could not be read reaches this now, so it says why.
        # It used to be written for every session on every reconcile, because an idle
        # selector has no `question` attribute and reading one throws under StrictMode -
        # so the commonest healthy state in the system was reported as a failure, four
        # lines every sixteen seconds, and the log stopped being worth reading.
        Write-DaemonLog -Message "reply ownership card unavailable for $sessionId : $($_.Exception.Message); rechecking local owners"
    }
    if (& $ownsInput) { return $false }
    if ([string]::IsNullOrWhiteSpace($armedQuestion)) { return $true }

    # Armed card with no marker behind it. Either the old blocking router is genuinely
    # waiting on it, or the question was already answered and the card was never torn
    # down - in which case every reply typed here is dropped silently, which is how a
    # session ends up unable to be replied to at all. The transcript settles it.
    $stale = $false
    try {
        $askState = Get-DaemonAskUserState -Session $Session
        $stale = (-not $askState.Pending)
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "reply ownership transcript check failed for $sessionId : $($_.Exception.Message)"
    }

    if (-not $stale -or (& $ownsInput)) { return $false }

    try {
        Clear-CopilotMqttDecision -SessionId $sessionId `
            -SessionName ([string]$State[$sessionId].Name) `
            -Machine ([string]$State[$sessionId].Machine) -Headers $Headers | Out-Null
        Write-DaemonLog -Message "cleared a stale decision card for $($sessionId.Substring(0,8)) so replies work again"
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
        Write-DaemonLog -Message "could not clear the stale decision card for $sessionId : $($_.Exception.Message)"
        return $false
    }
    -not (& $ownsInput)
}

function Send-DaemonCardPayload {
    <#
        Delivers a new payload from the reply card - text and images - and returns
        whether there was one. It takes precedence over the text box.

        It sends what is on screen at the instant Send is pressed rather than whatever
        Home Assistant last managed to commit, so it needs no arming and no waiting, and
        it can carry images and text of any length.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $entry = $Entry
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $payload = $null
    $payloadState = $null
    try {
        $payloadState = Get-DaemonEntityState -EntityId "sensor.${node}_reply_payload" -Headers $Headers
        $payload = Get-BridgeReplyPayload -State $payloadState
    }
    catch {
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        # No payload sensor yet (a session published before this existed), or it is
        # unreadable. The text box still works.
    }

    # The parser tolerates missing attachment metadata for older callers. The send
    # consumer must not turn that tolerance into an apparently complete text-only send.
    $requestedAttachments = 0
    if ($payloadState -and $payloadState.PSObject.Properties['attributes'] -and $payloadState.attributes) {
        foreach ($field in @('images', 'files')) {
            if ($payloadState.attributes.PSObject.Properties[$field] -and $null -ne $payloadState.attributes.$field) {
                $requestedAttachments += @($payloadState.attributes.$field).Count
            }
        }
    }
    $stamp = if ($payload) { [string]$payload.Stamp }
        elseif ($payloadState -and $payloadState.PSObject.Properties['state']) { [string]$payloadState.state }
        else { '' }
    if ([string]::IsNullOrWhiteSpace($stamp) -or $stamp -in @('unknown', 'unavailable') -or
        ($null -eq $payload -and $requestedAttachments -eq 0)) { return $false }
    $lastPayload = if ($entry.PSObject.Properties['LastReplyPayloadAt']) { [string]$entry.LastReplyPayloadAt } else { '' }
    if ($stamp -eq $lastPayload) { return $false }

    # Words published for a form, not a reply. Send answer tags its payload with the
    # question they were typed for: the decision path consumes it while that question
    # is still armed, and refuses it when the question was answered from the terminal
    # or another dashboard while the publish was in flight.
    #
    # Either way it is never an ordinary reply, and this runs after Invoke-Pending-
    # Decisions has already cleared the answered question's marker - so without this
    # the refused words were typed into the session as a chat reply moments after the
    # card had said they were not sent and emptied the box, which is both a surprise
    # and a second copy of an answer the person was about to retype.
    #
    # Marked consumed rather than merely skipped, so it does not sit there being
    # reconsidered on every reconcile.
    $taggedFor = ''
    if ($payloadState -and $payloadState.PSObject.Properties['attributes'] -and $payloadState.attributes -and
        $payloadState.attributes.PSObject.Properties['decision_id']) {
        $taggedFor = [string]$payloadState.attributes.decision_id
    }
    if ($taggedFor) {
        Set-DaemonSessionProperty -Entry $entry -Name 'LastReplyPayloadAt' -Value $stamp
        return $false
    }

    # Record the stamp before delivering, not after. Delivery types the reply into the
    # console one character at a time, which is long enough for the next reconcile to
    # see the same payload still sitting there and send it a second time.
    Set-DaemonSessionProperty -Entry $entry -Name 'LastReplyPayloadAt' -Value $stamp

    # Who is driving from here, and armed so the turn this is about to start is not
    # read as somebody typing in the terminal - the same reason a Submit press arms it.
    # Without this the only replies that come this way, the ones too long for the text
    # box's 255 characters, left an agent-driven session showing as the person's the
    # moment it began answering. Guarded because a payload built by an older card - or
    # by a test - has no Driver, and reading a missing property throws under StrictMode.
    if ($payload) {
        $payloadDriver = if ($payload.PSObject.Properties['Driver'] -and $payload.Driver) {
            [string]$payload.Driver
        } else { 'human' }
        Set-DaemonDriverPending -Entry $entry -Driver $payloadDriver
    }

    $paths = [System.Collections.Generic.List[string]]::new()
    $fetched = [System.Collections.Generic.List[string]]::new()
    try {
        if ($null -eq $payload) { throw 'The attachment metadata is incomplete; no reply was sent.' }
        $parsedAttachments = @($payload.Images).Count
        if ($payload.PSObject.Properties['Files']) { $parsedAttachments += @($payload.Files).Count }
        if ($parsedAttachments -ne $requestedAttachments) {
            throw 'The attachment metadata is incomplete; no reply was sent.'
        }
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers | Out-Null
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
            Write-DaemonLog -Message "could not show reply progress for $sessionId : $($_.Exception.Message)"
        }

        foreach ($image in @($payload.Images)) {
            $saved = Save-BridgeReplyAttachment -ImageId $image.Id -Name $image.Name -Headers $Headers
            if ([string]::IsNullOrWhiteSpace($saved)) {
                throw 'An image could not be staged privately; no reply was sent and source images were kept.'
            }
            $paths.Add($saved)
            $fetched.Add($image.Id)
        }

        # Old cards have no Files property; their text/image submissions still work.
        if ($payload.PSObject.Properties['Files']) {
            foreach ($file in @($payload.Files)) {
                if ($null -eq $file) { throw 'The attachment metadata is incomplete; no reply was sent.' }
                $written = Save-BridgeReplyFile -Name $file.Name -Base64 $file.Base64
                if ([string]::IsNullOrWhiteSpace($written)) {
                    throw 'A file could not be staged privately; no reply was sent and source images were kept.'
                }
                $paths.Add($written)
            }
        }

        $prompt = New-BridgeAttachmentPrompt -Text $payload.Text -Paths $paths.ToArray()
        if ([string]::IsNullOrWhiteSpace($prompt)) {
            Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
            Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8)) had nothing deliverable"
            return $true
        }

        $attachmentNote = if ($paths.Count -gt 0) { " with $($paths.Count) attachment(s)" } else { '' }
        Write-DaemonLog -Message "reply card payload for $($sessionId.Substring(0,8))$attachmentNote"
        Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $payload.Text
        # Card output must not join the Boolean and turn a failed send into success.
        $delivered = @(Invoke-DaemonReply -SessionId $sessionId -Text $prompt -Headers $Headers `
            -DisplayText $payload.Text -ClearReplyBox:$false) | Select-Object -Last 1
    }
    catch {
        Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
        if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
        $failure = $_.Exception.Message
        Write-DaemonLog -Message "reply card payload failed for $sessionId : $failure"
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Reply NOT sent' `
                -Extra @{ error = $failure } -Headers $Headers | Out-Null
        }
        catch {
            if ($_.Exception.Data['BridgeTestNetworkBlocked'] -or $_.Exception.Data['BridgeTestWriteBlocked']) { throw }
            Write-DaemonLog -Message "could not show reply failure for $sessionId : $($_.Exception.Message)"
        }
        return $true
    }
    if (-not $delivered) {
        # Nothing was sent, so no agent turn is coming and the arming above has to go
        # back. Left armed, the next thing typed in the terminal would consume it and
        # show a person's turn with the agent's edge.
        Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
        return $true
    }
    else {
        # The window starts now, not when the payload was picked up, so a slow delivery
        # cannot expire the arm for the turn it is about to produce.
        Update-DaemonDriverPendingStamp -Entry $entry
        # Recorded separately from the arm because the press that follows re-arms and
        # re-stamps before it reads the box, so by then the arm's own stamp can no
        # longer tell "a payload just went in" from "somebody just pressed Send".
        Set-DaemonSessionProperty -Entry $entry -Name 'LastPayloadDeliveredAt' `
            -Value ([DateTimeOffset]::Now.ToString('o'))
    }

    # Only successful transport permits cleanup; failures keep all source images and
    # staged private data. This is not a client-read or completed-turn acknowledgement.
    foreach ($id in $fetched) { Remove-BridgeHomeAssistantImage -ImageId $id | Out-Null }
    Remove-BridgeStaleAttachment | Out-Null
    $true
}

function Send-DaemonReplyBoxText {
    <#
        Delivers the text box's reply when its Send button has been pressed - waiting
        a moment, and if need be a few passes, for Home Assistant to commit what was
        typed, and saying so on the card rather than letting a press look ignored.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $sessionId = $SessionId
    $entry = $Entry
    $node = Get-CopilotMqttNodeId -SessionId $sessionId
    $replyEntity = "text.${node}_reply"

    # Read the press first. The old order read the reply box first and bailed on a
    # blank one, which lost the race Home Assistant creates: a text entity commits
    # when it loses focus, and on a phone the tap that commits it *is* the tap on
    # Send. The first read could therefore still see the old, blank value, nothing
    # was sent, and nothing said so - which is why a reply sometimes needed Send
    # pressed twice.
    $press = ''
    try {
        $btn = Get-HomeAssistantState -EntityId "button.${node}_submit" -Headers $Headers
        $press = [string]$btn.state
    }
    catch {
        return
    }
    if ($press -in @('unknown', 'unavailable', '')) { return }

    $lastSubmit = if ($entry.PSObject.Properties['LastSubmitAt']) { [string]$entry.LastSubmitAt } else { '' }
    if ($press -eq $lastSubmit) { return }

    # Snapshot the arm before the press overwrites it. Set-DaemonDriverPending below
    # replaces the flag, the driver and the stamp, so by the time an empty box is seen
    # there is nothing left to tell an arm a payload is still waiting on from one this
    # very press manufactured a few lines earlier.
    $armBefore = [pscustomobject]@{
        Outstanding = [bool](Test-DaemonDriverPending -Entry $entry)
        Driver      = if ($entry.PSObject.Properties['Driver']) { [string]$entry.Driver } else { '' }
        At          = if ($entry.PSObject.Properties['DriverPendingAt']) { [string]$entry.DriverPendingAt } else { '' }
    }

    # Who pressed it. The card glows while an agent is driving, and this is the only
    # place that can tell: the press itself carries the account behind it. Pending,
    # because the turn this is about to start would otherwise be read as typed in the
    # terminal and hand the session straight back to the person.
    Set-DaemonDriverPending -Entry $entry -Driver (Get-BridgeDriverFromState -State $btn)

    try {
        $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
    }
    catch {
        return
    }
    $value = [string]$replyState.state

    # Give the commit time to land before concluding there is nothing to send.
    #
    # Home Assistant commits a text entity when it loses focus, and the tap that
    # commits it IS the tap on Send. The daemon is woken by the button's own state
    # change, so it reads the box within milliseconds of the press - reliably
    # before the typed value has landed. A single short re-read was not enough:
    # the first Send of a message regularly reported "Nothing to send" and it took
    # a second press to get through.
    #
    # Polling briefly costs nothing when the value is already there, which is the
    # common case on the reconcile sweep.
    $attempts = 0
    while (($attempts -lt $script:DaemonConfig.ReplyCommitAttempts) -and
           ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable'))) {
        $attempts++
        Start-Sleep -Milliseconds $script:DaemonConfig.ReplyCommitWaitMs
        try {
            $replyState = Get-HomeAssistantState -EntityId $replyEntity -Headers $Headers
            $value = [string]$replyState.state
        }
        catch { }
    }

    # Acknowledge the press immediately - a press that produces no visible change
    # for even a second reads as a dead button, which is the other half of why it
    # got pressed twice. Which acknowledgement depends on whether the typed text
    # has actually reached Home Assistant yet, so it happens in each branch below
    # rather than unconditionally here: a blanket 'Sending...' on every pass would
    # overwrite the armed message it is meant to sit alongside.
    if ([string]::IsNullOrWhiteSpace($value) -or $value -in @('unknown', 'unavailable')) {
        # An agent setting the text does so through the API, where the value commits
        # the moment it is set - so an empty box really is empty, and arming would
        # leave "Waiting for your text" on the card for the full ten minutes waiting
        # for a person who is not there. Only a person gets the benefit of the doubt.
        $pressedBy = if ($entry.PSObject.Properties['Driver']) { [string]$entry.Driver } else { 'human' }
        if ($pressedBy -eq 'agent') {
            Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
            # An agent publishes a payload and then presses Send. The payload is
            # delivered on its own the moment it lands, so the press that follows finds
            # the box empty because the message has already gone - not because there
            # was nothing to say. Disarming here cost exactly the attribution the arm
            # exists for: on 2026-10-02 a 2,234-character reply went in at 08:57:39,
            # this press cleared the arm six seconds later, and the turn it produced at
            # 08:58:50 was published as the person's. It only shows when the session is
            # busy - an idle one starts its turn before the press arrives and keeps the
            # edge - which is why it survived both earlier attempts at this bug.
            #
            # All three conditions are load-bearing, and the arm is restored to exactly
            # what it was rather than to what this press set. A recency test on its own
            # re-armed a session whose payload arm had ALREADY been consumed by its
            # turn, because the arming above runs first: the flag read false before the
            # press and true after it, manufacturing an agent arm from a timestamp for
            # a message that had already been accounted for, and the next thing the
            # person typed would have worn the agent's edge.
            if ($armBefore.Outstanding -and $armBefore.Driver -eq 'agent' -and
                (Test-DaemonPayloadJustDelivered -Entry $entry)) {
                Set-DaemonSessionProperty -Entry $entry -Name 'Driver' -Value $armBefore.Driver
                Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $true
                # The original stamp, so a press arriving late cannot extend the window
                # of the arm it is preserving. Left alone when there was none, which is
                # an arm carried across an upgrade from before the stamp existed.
                if ($armBefore.At) {
                    Set-DaemonSessionProperty -Entry $entry -Name 'DriverPendingAt' -Value $armBefore.At
                }
                Write-DaemonLog -Message ("send for $($sessionId.Substring(0, 8)) had an empty box because its " +
                    'payload had already gone; its arm kept as it was')
                return
            }
            # Nothing was sent, so no agent turn is coming. Leaving this armed would
            # hand the glow to whatever the person types next in the terminal.
            Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Nothing to send' -Headers $Headers
            }
            catch { }
            Write-DaemonLog -Message "send for $($sessionId.Substring(0,8)) had an empty box and came from an agent; not armed"
            return
        }

        # The text is almost certainly on screen - it just is not in Home Assistant
        # yet. A text entity only commits when it loses focus or you press Enter,
        # and pressing Send does neither: Home Assistant's own history showed three
        # presses landing before the box was committed even once. Burning the press
        # here is what forced a second one, so it stays armed instead and fires the
        # moment the value arrives.
        $pendingAt = if ($entry.PSObject.Properties['PendingSubmitAt']) { [string]$entry.PendingSubmitAt } else { '' }
        if ($pendingAt -ne $press) {
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value $press
            Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitSince' -Value ([DateTimeOffset]::Now.ToString('o'))
            try {
                Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Waiting for your text' `
                    -Extra @{ hint = 'Press Enter in the box, or tap outside it, and this sends on its own.' } `
                    -Headers $Headers
            }
            catch { }
            Write-DaemonLog -Message "send armed for $($sessionId.Substring(0,8)); the typed text has not reached Home Assistant yet"
            return
        }

        $since = [DateTimeOffset]::MinValue
        if ($entry.PSObject.Properties['PendingSubmitSince']) {
            try { $since = [DateTimeOffset]::Parse([string]$entry.PendingSubmitSince) } catch { }
        }
        if (([DateTimeOffset]::Now - $since).TotalSeconds -lt $script:DaemonConfig.SubmitArmSeconds) {
            # Still armed; say nothing further and look again next pass.
            return
        }

        # Long enough that the box really was empty. Say so rather than doing
        # nothing: silence here is indistinguishable from a broken button.
        Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
        Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
        try {
            Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Nothing to send' `
                -Extra @{ hint = 'Type a reply first, then press Send.' } -Headers $Headers
        }
        catch { }
        Write-DaemonLog -Message "send for $($sessionId.Substring(0,8)) gave up waiting for the typed text"
        return
    }

    Set-DaemonSessionProperty -Entry $entry -Name 'LastSubmitAt' -Value $press
    Set-DaemonSessionProperty -Entry $entry -Name 'PendingSubmitAt' -Value ''
    Set-DaemonSessionProperty -Entry $entry -Name 'LastReply' -Value $value

    try {
        Set-DaemonTransientActivity -SessionId $sessionId -Summary 'Sending...' -Headers $Headers
    }
    catch { }

    # Same as the payload path: the window starts when the text has actually gone in,
    # and a send that did not land gives the arm back rather than leaving it to mark
    # whatever is typed next.
    $sent = @(Invoke-DaemonReply -SessionId $sessionId -Text $value -Headers $Headers) | Select-Object -Last 1
    if ($sent) { Update-DaemonDriverPendingStamp -Entry $entry }
    else { Set-DaemonSessionProperty -Entry $entry -Name 'DriverPending' -Value $false }
}

function Invoke-DaemonReply {
    <#
        Delivers a dashboard reply into the running CLI and clears the box.
    #>
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Headers,
        # What to show on the card. A reply carrying attachments is injected as
        # "@C:\...\shot.png your question", which is not what the user typed and
        # should not be echoed back at them.
        [AllowEmptyString()][string]$DisplayText = '',
        # The reply card does not use the text box, so clearing it would wipe
        # anything left sitting there rather than confirming the send.
        [bool]$ClearReplyBox = $true
    )

    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

    # Claude and Codex leave no inuse.<pid>.lock, so their owning process is passed
    # explicitly from the registration their hooks maintain. Without this the
    # injector falls back to the Copilot-only lock file, finds nothing, and the reply
    # box fails silently - which is worse than not offering one.
    #
    # The live set the last reconcile found already has it. Rescanning every
    # registration and the whole process list here cost a noticeable slice of each
    # send, so that is only the fallback.
    $explicitPid = 0
    $known = if ($script:DaemonLive) { $script:DaemonLive[$SessionId] } else { $null }
    $knownAgent = if ($null -ne $known -and $known.PSObject.Properties['Kind']) { Get-DaemonAgent -Kind ([string]$known.Kind) } else { $null }
    if ($null -ne $knownAgent -and $knownAgent.KnowsProcessId -and
        $known.PSObject.Properties['ProcessId'] -and [int]$known.ProcessId -gt 0 -and
        $null -ne (Get-Process -Id ([int]$known.ProcessId) -ErrorAction SilentlyContinue)) {
        $explicitPid = [int]$known.ProcessId
    }
    foreach ($kind in @($script:DaemonAgents.Keys)) {
        if ($explicitPid -gt 0) { break }
        $agent = Get-DaemonAgent -Kind $kind
        if (-not $agent.KnowsProcessId -or -not $agent.FindSessions) { continue }
        $found = (& $agent.FindSessions)[$SessionId]
        if ($null -ne $found) { $explicitPid = [int]$found.ProcessId }
    }

    # For Claude the transcript shows whether the prompt was really submitted, so the
    # send can be confirmed (Confirm-DaemonClaudeSubmit) rather than assumed.
    $claudeTranscript = ''
    $transcriptBefore = 0L
    if ($null -ne $knownAgent -and $knownAgent.TranscriptConfirmsInput -and $known.PSObject.Properties['Transcript'] -and
        [IO.File]::Exists([string]$known.Transcript)) {
        $claudeTranscript = [string]$known.Transcript
        $transcriptBefore = [IO.FileInfo]::new($claudeTranscript).Length
    }

    $delivery = Send-CopilotSessionPrompt -SessionId $SessionId -Text $Text -ProcessId $explicitPid

    if ($delivery.Delivered -and $claudeTranscript) {
        $waitingOnPrompt = $known.PSObject.Properties['HookStatus'] -and [string]$known.HookStatus -eq 'waiting'
        $confirm = Confirm-DaemonClaudeSubmit -ProcessId ([int]$delivery.ProcessId) -Transcript $claudeTranscript `
            -Offset $transcriptBefore -AllowRetry:(-not $waitingOnPrompt)
        if (-not $confirm.Submitted) {
            $delivery.Delivered = $false
            $delivery.Detail = "typed but not submitted ($($confirm.Detail))"
        }
        elseif ($confirm.Retries -gt 0) {
            $delivery.Detail = "$($delivery.Detail); submitted after $($confirm.Retries) extra Enter(s)"
        }
    }

    if ($delivery.Delivered) {
        Write-DaemonLog -Message "reply delivered to $short (pid $($delivery.ProcessId)): $($delivery.Detail)"
    }
    else {
        Write-DaemonLog -Message "reply delivery FAILED for $short : $($delivery.Detail)"
    }

    # Confirm on the card. The box clearing is the only other signal, and on its own
    # it is ambiguous - a cleared box looks the same whether the reply reached the
    # session or vanished. A failure especially must be visible: the whole point of
    # the reply box is that nobody is watching the terminal.
    try {
        $preview = ($(if ([string]::IsNullOrWhiteSpace($DisplayText)) { $Text } else { $DisplayText }) -replace '\s+', ' ').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 57) + '...' }
        if ($delivery.Delivered) {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply sent' `
                -Extra @{ sent = $preview; at = [DateTimeOffset]::Now.ToString('HH:mm:ss') } -Headers $Headers
        }
        else {
            Set-DaemonTransientActivity -SessionId $SessionId -Summary 'Reply NOT sent' `
                -Extra @{ error = [string]$delivery.Detail; unsent = $preview } -Headers $Headers
        }
    }
    catch { }

    # Clear the box either way, so a failed delivery is not silently resent - but only
    # if it still holds what was just sent. Delivery is not instant (a long reply is
    # typed into the console a character at a time), and clearing unconditionally wiped
    # whatever the user had typed in the meantime. Their next Send then found an empty
    # box and reported "Nothing to send", which is what being unable to queue a
    # follow-up reply looks like from the dashboard.
    #
    # The reply box is an optimistic MQTT text entity with no state topic, so its value
    # is cleared with the text.set_value service, not by publishing to a state topic
    # that nothing is subscribed to.
    try {
        if (-not $ClearReplyBox) { return $delivery.Delivered }

        $node = Get-CopilotMqttNodeId -SessionId $SessionId
        $current = $null
        try {
            $current = [string](Get-HomeAssistantState -EntityId "text.${node}_reply" -Headers $Headers).state
        }
        catch {
            # Unreadable: fall through to the clear, which is the safer default.
        }

        if ($null -eq $current -or $current -eq $Text) {
            Invoke-HomeAssistantService -Domain 'text' -Service 'set_value' -Headers $Headers -Data @{
                entity_id = "text.${node}_reply"
                value = $script:DaemonConfig.ReplyBlankValue
            }
        }
        else {
            Write-DaemonLog -Message "kept a follow-up reply typed for $short while the previous one was delivering"
        }
    }
    catch {
        # The guard hash still prevents a re-delivery even if the clear fails.
    }

    $delivery.Delivered
}

function Test-DaemonClaudePromptSubmitted {
    <#
        Whether Claude recorded a submitted prompt in the transcript bytes appended
        since Offset: a user message (not a tool result), or, while a turn is running,
        a queue entry for it. Claude writes either at the moment of submission.
    #>
    param(
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0
    )

    $append = Read-ClaudeTranscriptAppend -Path $Transcript -Offset $Offset
    foreach ($line in @($append.Lines)) {
        if ($line -match '"type":"queue-operation"' -and $line -match '"operation":"enqueue"') { return $true }
        if ($line -notmatch '"type":"user"') { continue }
        $entry = try { $line | ConvertFrom-Json } catch { $null }
        if ($null -eq $entry -or ($entry.PSObject.Properties['isMeta'] -and $entry.isMeta)) { continue }
        $blocks = Get-ClaudeContentBlocks -Message $entry.message
        if (@($blocks | Where-Object { $_.type -eq 'tool_result' }).Count -eq 0) { return $true }
    }
    $false
}

function Confirm-DaemonClaudeSubmit {
    <#
        Confirms a reply typed into Claude was actually submitted, pressing Enter again
        if it was not.

        Claude Code treats a fast burst of more than a few dozen characters as a paste,
        and an Enter that arrives while it is still settling that paste is absorbed
        rather than submitting. The text then sat in the input box, the card said
        "Reply sent", and it went in only with the next reply - run together with it.
        Short replies were unaffected, which is why it looked intermittent.

        The transcript settles it: a submitted prompt is written at once. If nothing
        arrives, the text is still waiting, so Enter is pressed again, twice at most.
        No retry is made while a permission prompt is pending (AllowRetry off), where
        a stray Enter could accept it.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Transcript,
        [long]$Offset = 0,
        [switch]$AllowRetry,
        [int]$WaitMs = 1200,
        [int]$MaxRetries = 2
    )

    $result = [pscustomobject]@{ Submitted = $false; Retries = 0; Detail = '' }
    $attempt = 0
    while ($true) {
        $deadline = [DateTimeOffset]::Now.AddMilliseconds($WaitMs)
        while ([DateTimeOffset]::Now -lt $deadline) {
            if (Test-DaemonClaudePromptSubmitted -Transcript $Transcript -Offset $Offset) {
                $result.Submitted = $true
                $result.Retries = $attempt
                return $result
            }
            Start-Sleep -Milliseconds 100
        }

        if (-not $AllowRetry) { $result.Detail = 'no submit seen; not retried while a prompt is pending'; break }
        if ($attempt -ge $MaxRetries) { $result.Detail = "no submit seen after $attempt extra Enter(s)"; break }

        $attempt++
        try {
            $outcome = Invoke-BridgeConsoleSend -ProcessId $ProcessId -Text '' -Submit $true -DelayMs 0
            if (-not ([string]$outcome).StartsWith('ok:')) { $result.Detail = "extra Enter failed: $outcome"; break }
        }
        catch {
            $result.Detail = "extra Enter failed: $($_.Exception.Message)"
            break
        }
    }
    $result.Retries = $attempt
    $result
}

function Resolve-SessionFromReplyEntity {
    param(
        [Parameter(Mandatory)][string]$EntityId,
        [Parameter(Mandatory)][hashtable]$State
    )

    foreach ($sessionId in @($State.Keys)) {
        $node = Get-CopilotMqttNodeId -SessionId $sessionId
        if ($EntityId -eq "text.${node}_reply") { return $sessionId }
    }
    $null
}

function Resolve-DaemonPrimedCard {
    <#
        Builds the (summary, detail) a restart should re-publish for a session from its
        persisted display state, so a restart restores the card rather than blanking
        it. Reasoning is included only when verbose is on, matching the reconcile, and
        a session with no remembered activity falls back to a generic label.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][ValidateSet('working', 'waiting', 'idle', 'agents', 'error')][string]$Status,
        [bool]$VerboseOn
    )

    $summary = if ($Status -eq 'error') { 'Could not end session' }
    elseif ($Entry.PSObject.Properties['LastSummary'] -and -not [string]::IsNullOrWhiteSpace([string]$Entry.LastSummary)) {
        [string]$Entry.LastSummary
    }
    elseif ($Status -eq 'working') { 'Working' }
    elseif ($Status -eq 'agents') { 'Waiting for background agents' } else { 'Idle' }

    $detail = @{
        session = $Entry.Name
        machine = $Entry.Machine
        verbose = $VerboseOn
        updated = [DateTimeOffset]::Now.ToString('o')
    }
    if ($Entry.PSObject.Properties['LastHistory'] -and $Entry.LastHistory) {
        $detail['history'] = @($Entry.LastHistory)
    }
    # Driver is persisted with the entry, so a restart restores the glow rather than
    # quietly handing a session an agent is still driving back to you.
    $detail['driver'] = if ($Entry.PSObject.Properties['Driver'] -and $Entry.Driver) { [string]$Entry.Driver } else { 'human' }
    Add-DaemonCardText -Entry $Entry -Detail $detail -VerboseOn $VerboseOn

    [pscustomobject]@{ Summary = $summary; Detail = $detail }
}
