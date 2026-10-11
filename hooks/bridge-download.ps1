<#
    Fetching a file while saying how far it has got.

    Invoke-WebRequest is the transport everywhere else in the bridge, and the offline
    test boundary is built around it: Assert-BridgeHttpAllowed permits a call
    precisely because a suite has replaced that cmdlet with a function. It reports
    nothing programmatically as it goes, though - -OutFile blocks until the file is
    complete - so an update's Downloading stage could only ever say "downloading",
    never how much of it was left (#155).

    Measured against codeload.github.com, which is where a release archive comes from.
    A GET carries Content-Length: 1,625,940 bytes for v1.33.14. A HEAD answers 200
    with no Content-Length at all, and a Range request is ignored and answered 200
    with the whole body. So the total is knowable only from the response to the
    download itself, which is why this reads the body as it arrives rather than asking
    the size first and handing the transfer back to Invoke-WebRequest.

    That makes this the one place in the bridge that speaks HTTP through HttpClient,
    so it carries its own place in the test boundary: the Download transport is
    refused outright under test, with no stub detection, because there is no cmdlet
    whose type can stand in for "nobody has replaced this". The decision worth testing
    is not the socket anyway - it is what gets reported while bytes arrive, which is
    why that half lives in Write-BridgeDownloadStream and takes an ordinary Stream.
#>

Set-StrictMode -Version Latest

# How much of the body is read at a time, and how long a progress report suppresses
# the next one. Script scope rather than parameters so a suite can drive both
# deterministically instead of sleeping. The interval exists because reporting every
# chunk would rewrite the progress record continuously for the whole download, on the
# disk the installer is about to write to (#155).
$script:BridgeDownloadBufferSize = 81920
$script:BridgeDownloadReportIntervalMs = 1000

function Write-BridgeDownloadStream {
    <#
        Copies $Source to $OutFile, calling -OnProgress with the fraction completed.

        Returns { Bytes, Total, Proportioned }. Pass -Total 0 for a body whose length
        the server did not state - chunked, or a redirect that dropped Content-Length.
        A proportion is then never reported at all, rather than reported as 0 or as
        100: a bar that cannot move is a worse answer than no bar.

        -OnProgress is called at most once per whole percent and at most once per
        $script:BridgeDownloadReportIntervalMs, and never at 0%.
    #>
    param(
        [Parameter(Mandatory)][IO.Stream]$Source,
        [Parameter(Mandatory)][string]$OutFile,
        [long]$Total = 0,
        [scriptblock]$OnProgress
    )

    $target = $null
    $completed = $false
    try {
        $target = [IO.File]::Open($OutFile, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = [byte[]]::new($script:BridgeDownloadBufferSize)
        $written = 0L
        $lastPercent = 0
        $lastReportAt = [DateTimeOffset]::MinValue
        while ($true) {
            $read = $Source.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            $target.Write($buffer, 0, $read)
            $written += $read
            if ($Total -le 0 -or $null -eq $OnProgress) { continue }
            $percent = [int][Math]::Floor(($written * 100.0) / $Total)
            if ($percent -le $lastPercent -or ([DateTimeOffset]::Now - $lastReportAt).
                TotalMilliseconds -lt $script:BridgeDownloadReportIntervalMs) { continue }
            $lastPercent = $percent
            $lastReportAt = [DateTimeOffset]::Now
            # Best effort by construction, like the stage writer it usually drives: a
            # progress report that throws must not fail a download that is fine.
            try { & $OnProgress ([double]([Math]::Min(1.0, $written / $Total))) }
            catch {
                if ($_.Exception.Data['BridgeTestWriteBlocked'] -or $_.Exception.Data['BridgeTestNetworkBlocked']) { throw }
            }
        }
        $target.Flush()
        $completed = $true
        [pscustomobject]@{ Bytes = $written; Total = $Total; Proportioned = ($Total -gt 0) }
    }
    finally {
        if ($target -is [IDisposable]) { $target.Dispose() }
        # A half-written archive is worse than none: Expand-Archive fails on it with a
        # ZIP error, and the update is then reported as a corrupt release rather than
        # as an interrupted download.
        if (-not $completed) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    }
}

function Save-BridgeUpdateDownload {
    <#
        Downloads $Uri to $OutFile, calling -OnProgress with the fraction completed.

        Returns what Write-BridgeDownloadStream returns: Total is 0 and Proportioned
        false when the server stated no length.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$UserAgent = 'agent-ha-bridge',
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnProgress
    )

    # Outside the try, as the guard's own contract requires: a boundary violation must
    # propagate rather than become an ordinary failed download.
    Assert-BridgeHttpAllowed -Uri $Uri -Transport Download

    $client = [Net.Http.HttpClient]::new()
    $response = $null
    $source = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
        # ResponseHeadersRead is what makes this streaming at all. The default buffers
        # the entire body before returning, which is the behaviour that leaves nothing
        # to report.
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).
            GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()

        $total = 0L
        $length = $response.Content.Headers.ContentLength
        if ($length.HasValue -and $length.Value -gt 0) { $total = [long]$length.Value }
        $source = $response.Content.ReadAsStream()
        Write-BridgeDownloadStream -Source $source -OutFile $OutFile -Total $total -OnProgress $OnProgress
    }
    finally {
        foreach ($disposable in @($source, $response, $client)) {
            if ($disposable -is [IDisposable]) { $disposable.Dispose() }
        }
    }
}
