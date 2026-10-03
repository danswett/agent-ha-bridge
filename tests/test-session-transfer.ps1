#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for chunking a session bundle and rebuilding it (hooks/session-launch.ps1).

.DESCRIPTION
    The part that has to measure what actually goes on the wire. A raw slice is not the
    packet: base64 inflates it by a third, the envelope adds fields and the topic rides
    along. Publishing a "2 MB" slice as a ~2.8 MB packet exceeded mosquitto 2.1's default
    max_packet_size of 2,000,000 bytes and disconnected Home Assistant from the broker
    repeatedly, taking every MQTT entity on the instance down with it - not only this
    project's. So the budget is checked against the encoded size, and these tests check
    that it is.

    Pure functions only: no Home Assistant, no broker, no network, nothing published.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
# Both, because the transfer topic is built from the MQTT topic root that decision-mqtt
# owns. The daemon loads them together; a test that loaded only one would pass on a
# function that cannot run in production.
. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\decision-mqtt.ps1')
. (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

function New-Bytes { param([int]$N, [int]$Seed = 7) $b = [byte[]]::new($N); [Random]::new($Seed).NextBytes($b); $b }
function Get-Sha { param([byte[]]$B)
    $s = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($s.ComputeHash($B)).Replace('-', '') } finally { $s.Dispose() }
}
$topic = 'copilot/cli/transfer/dswett_home/abcd1234/c'

Write-Host '--- every chunk fits the budget, measured encoded ---'

foreach ($size in 1KB, 100KB, 1MB) {
    $bytes = New-Bytes -N $size
    $chunks = @(Get-BridgeBundleChunk -Bytes $bytes -Topic $topic -Budget 262144)
    Test-That "a $([int]($size/1KB)) KB bundle produces chunks that all fit" {
        @($chunks | Where-Object { $_.Encoded -gt 262144 }).Count -eq 0
    }
    Test-That "a $([int]($size/1KB)) KB bundle covers every byte exactly once" {
        ((@($chunks | Measure-Object -Property Length -Sum).Sum) -eq $size) -and
        ($chunks[0].Offset -eq 0)
    }
}

Test-That 'the measured size is the ENCODED payload plus topic, not the raw slice' {
    $chunks = @(Get-BridgeBundleChunk -Bytes (New-Bytes -N 300KB) -Topic $topic -Budget 262144)
    $c = $chunks[0]
    # base64 of the slice alone already exceeds the slice; the recorded figure must be
    # at least that, which is the whole point.
    $c.Encoded -ge ([Text.Encoding]::UTF8.GetByteCount($c.Payload)) -and $c.Encoded -gt $c.Length
}
Test-That 'a long topic shrinks the slice rather than overflowing the budget' {
    $long = 'copilot/cli/transfer/' + ('m' * 400) + '/c'
    $chunks = @(Get-BridgeBundleChunk -Bytes (New-Bytes -N 200KB) -Topic $long -Budget 262144)
    @($chunks | Where-Object { $_.Encoded -gt 262144 }).Count -eq 0
}
Test-That 'a tiny budget still makes progress rather than looping' {
    $chunks = @(Get-BridgeBundleChunk -Bytes (New-Bytes -N 4096) -Topic 't' -Budget 1024)
    $chunks.Count -gt 1 -and @($chunks | Where-Object { $_.Encoded -gt 1024 }).Count -eq 0
}
Test-That 'an empty bundle produces no chunks at all' {
    @(Get-BridgeBundleChunk -Bytes ([byte[]]::new(0)) -Topic $topic).Count -eq 0
}
Test-That 'a budget too small for any chunk is refused, not looped on' {
    $threw = $false
    try { Get-BridgeBundleChunk -Bytes (New-Bytes -N 100) -Topic ('x' * 500) -Budget 64 | Out-Null } catch { $threw = $true }
    $threw
}

Write-Host '--- a bundle comes back exactly as it went ---'

$bytes = New-Bytes -N 250KB -Seed 11
$sha = Get-Sha -B $bytes
$chunks = @(Get-BridgeBundleChunk -Bytes $bytes -Topic $topic -Budget 65536)
# what the receiver actually sees: the published JSON, parsed
$wire = @($chunks | ForEach-Object { $_.Payload | ConvertFrom-Json })

Test-That 'it took more than one chunk, so reassembly is really being exercised' { $wire.Count -gt 1 }
Test-That 'the rebuilt bundle is byte-identical' {
    $back = Join-BridgeBundleChunk -Chunks $wire -TotalBytes $bytes.Length -Sha256 $sha
    (Get-Sha -B $back) -eq $sha
}
Test-That 'chunks arriving out of order rebuild just the same' {
    $shuffled = @($wire | Sort-Object { [guid]::NewGuid() })
    $back = Join-BridgeBundleChunk -Chunks $shuffled -TotalBytes $bytes.Length -Sha256 $sha
    (Get-Sha -B $back) -eq $sha
}

Write-Host '--- and anything less than exact is refused ---'

Test-That 'a missing chunk is refused rather than silently short' {
    $threw = $false
    try { Join-BridgeBundleChunk -Chunks @($wire | Select-Object -Skip 1) -TotalBytes $bytes.Length -Sha256 $sha | Out-Null }
    catch { $threw = $_.Exception.Message -like '*incomplete*' }
    $threw
}
Test-That 'a gap in the MIDDLE is refused too - a short archive can still extract' {
    $holed = @($wire[0]) + @($wire | Select-Object -Skip 2)
    $threw = $false
    try { Join-BridgeBundleChunk -Chunks $holed -TotalBytes $bytes.Length -Sha256 $sha | Out-Null }
    catch { $threw = $_.Exception.Message -like '*incomplete*' }
    $threw
}
Test-That 'a flipped byte is caught by the digest' {
    $tampered = @($wire | ForEach-Object { [pscustomobject]@{ s = $_.s; o = $_.o; d = $_.d } })
    $raw = [Convert]::FromBase64String($tampered[0].d); $raw[0] = $raw[0] -bxor 0xFF
    $tampered[0].d = [Convert]::ToBase64String($raw)
    $threw = $false
    try { Join-BridgeBundleChunk -Chunks $tampered -TotalBytes $bytes.Length -Sha256 $sha | Out-Null }
    catch { $threw = $_.Exception.Message -like '*digest mismatch*' }
    $threw
}
Test-That 'a chunk claiming to sit outside the bundle is refused' {
    $bad = @([pscustomobject]@{ s = 0; o = $bytes.Length + 10; d = [Convert]::ToBase64String((New-Bytes -N 16)) })
    $threw = $false
    try { Join-BridgeBundleChunk -Chunks $bad -TotalBytes $bytes.Length | Out-Null }
    catch { $threw = $_.Exception.Message -like '*outside*' }
    $threw
}

Write-Host '--- the topic keeps chunks out of the state machine ---'

$t = Get-BridgeTransferTopic -Slug 'dswett_home' -Correlation 'abcd1234'
Test-That 'a transfer topic is not under the discovery prefix, so no entity is created' {
    $t -notlike 'homeassistant/*'
}
Test-That 'and it is scoped to the machine and the one transfer' {
    $t -like '*dswett_home*' -and $t -like '*abcd1234*'
}

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$($script:Failures) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
