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

Write-Host '--- knowing when every chunk has arrived ---'

$manifestMsg = [pscustomobject]@{ sha256 = ('a' * 64); bytes = 300; chunks = 3; session = 'x'; kind = 'copilot' }
$c0 = [pscustomobject]@{ s = 0; o = 0;   d = 'AA==' }
$c1 = [pscustomobject]@{ s = 1; o = 100; d = 'AA==' }
$c2 = [pscustomobject]@{ s = 2; o = 200; d = 'AA==' }

Test-That 'nothing is complete before the manifest arrives' {
    -not (Test-BridgeTransferComplete -Messages @($c0, $c1, $c2))
}
Test-That 'a partial set is not complete' {
    -not (Test-BridgeTransferComplete -Messages @($manifestMsg, $c0, $c1))
}
Test-That 'the full set is complete' {
    Test-BridgeTransferComplete -Messages @($manifestMsg, $c0, $c1, $c2)
}
Test-That 'a chunk redelivered at QoS 1 does not stand in for one still missing' {
    # The bug this replaced: three payloads carrying d, so the raw count reached the
    # manifest's chunk total, the socket closed and reassembly failed as incomplete
    # while the sender was still publishing chunk 2 quite happily.
    -not (Test-BridgeTransferComplete -Messages @($manifestMsg, $c0, $c1, $c1))
}
Test-That 'and the duplicate does no harm once the last one lands' {
    Test-BridgeTransferComplete -Messages @($manifestMsg, $c0, $c1, $c1, $c2)
}
Test-That 'a duplicate chunk rebuilds the same bytes rather than corrupting them' {
    $src = New-Bytes -N 600
    $pieces = @(Get-BridgeBundleChunk -Bytes $src -Topic 'copilot/cli/x' -Budget 400)
    $wire = @($pieces | ForEach-Object { $_.Payload | ConvertFrom-Json })
    $rebuilt = Join-BridgeBundleChunk -Chunks @($wire + $wire[0]) -TotalBytes $src.Length
    (-join ($rebuilt | ForEach-Object { $_.ToString('x2') })) -eq (-join ($src | ForEach-Object { $_.ToString('x2') }))
}

Write-Host '--- signing, which is what makes the transport''s openness survivable ---'
# Everything else about a request is shape: an id, a slug, a timestamp, all of which
# anything holding broker credentials can produce. On a normal instance that is a far
# lower bar than Home Assistant admin.
$sigSecret = 'fleet-secret-value'
$sigFields = Get-BridgeTransferRequestFields -SessionId 'aaaa1111-0000-0000-0000-000000000001' `
    -Launcher 'copilot' -Requester 'peer' -Correlation 'abcdef01' -At '2026-01-01T00:00:00.0000000+00:00'
$sigA = Get-BridgeTransferSignature -Secret $sigSecret -Fields $sigFields

Test-That 'a signature is a hex SHA256 and is stable for the same input' {
    $sigA -cmatch '^[0-9a-f]{64}$' -and $sigA -ceq (Get-BridgeTransferSignature -Secret $sigSecret -Fields $sigFields)
}
Test-That 'a different secret produces a different signature' {
    (Get-BridgeTransferSignature -Secret 'other-secret' -Fields $sigFields) -cne $sigA
}
Test-That 'no secret produces no signature rather than one over an empty key' {
    (Get-BridgeTransferSignature -Secret '' -Fields $sigFields) -eq ''
}
foreach ($moved in @(
    @{ what = 'the session'; f = (Get-BridgeTransferRequestFields -SessionId 'bbbb2222-0000-0000-0000-000000000002' -Launcher 'copilot' -Requester 'peer' -Correlation 'abcdef01' -At '2026-01-01T00:00:00.0000000+00:00') }
    @{ what = 'the requester, which names the delivery topic'; f = (Get-BridgeTransferRequestFields -SessionId 'aaaa1111-0000-0000-0000-000000000001' -Launcher 'copilot' -Requester 'attacker' -Correlation 'abcdef01' -At '2026-01-01T00:00:00.0000000+00:00') }
    @{ what = 'the correlation, which names the delivery topic too'; f = (Get-BridgeTransferRequestFields -SessionId 'aaaa1111-0000-0000-0000-000000000001' -Launcher 'copilot' -Requester 'peer' -Correlation 'deadbeef' -At '2026-01-01T00:00:00.0000000+00:00') }
    @{ what = 'the timestamp'; f = (Get-BridgeTransferRequestFields -SessionId 'aaaa1111-0000-0000-0000-000000000001' -Launcher 'copilot' -Requester 'peer' -Correlation 'abcdef01' -At '2026-06-06T00:00:00.0000000+00:00') }
)) {
    Test-That "changing $($moved.what) invalidates the signature" {
        (Get-BridgeTransferSignature -Secret $sigSecret -Fields $moved.f) -cne $sigA
    }
}
Test-That 'comparison refuses an empty presented or expected value' {
    -not (Test-BridgeTransferSignature -Presented '' -Expected $sigA) -and
    -not (Test-BridgeTransferSignature -Presented $sigA -Expected '') -and
    -not (Test-BridgeTransferSignature -Presented $null -Expected $sigA)
}
Test-That 'and accepts only an exact match' {
    (Test-BridgeTransferSignature -Presented $sigA -Expected $sigA) -and
    -not (Test-BridgeTransferSignature -Presented ($sigA.Substring(0, 63) + 'f') -Expected $sigA) -and
    -not (Test-BridgeTransferSignature -Presented $sigA.ToUpperInvariant() -Expected $sigA)
}

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$($script:Failures) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
