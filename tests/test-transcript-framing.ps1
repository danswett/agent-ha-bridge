#Requires -Version 7.0
<#
    Real byte-framing readers and consumers, with one canonical sandbox/import setup.
    Only the REST transport and a file-backed Stream's I/O are simulated. No client,
    installer, fixture child, reader result, publisher or logger is substituted.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Requests = [Collections.Generic.List[object]]::new()
$script:RestRejections = [Collections.Generic.List[object]]::new()
$script:RestAttemptCount = 0
$script:ActivityTopicCounts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
foreach ($node in @('agent_bridge_1111111111114111', 'agent_bridge_2222222222224222', 'agent_bridge_3333333333334333')) {
    foreach ($suffix in @('state', 'attr')) {
        $script:ActivityTopicCounts.Add("copilot/cli/$node/activity/$suffix", 0)
    }
}

function Write-FramingRestRejection {
    param([string]$Reason)
    # Publication callers can catch ordinary transport errors. Keep a separate latch
    # without copying an unexpected URI, body or credential into the diagnostic.
    $record = [ordered]@{ request = $script:RestAttemptCount; reason = $Reason }
    $script:RestRejections.Add($record)
    [Console]::Out.WriteLine('P7-FRAMING-REST-REJECTION ' + ($record | ConvertTo-Json -Compress))
}

function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
    $script:RestAttemptCount++
    $reason = ''
    $message = $null
    if ($script:RestRejections.Count) { $reason = 'request after a rejected boundary' }
    elseif ($args.Count -ne 0 -or $Method -cne 'Post' -or $Uri -cne 'http://127.0.0.1:1/api/services/mqtt/publish') {
        $reason = 'unexpected REST route or arguments'
    }
    elseif ($Body -isnot [byte[]] -or $ContentType -cne 'application/json; charset=utf-8') {
        $reason = 'unexpected REST encoding or content type'
    }
    else {
        try { $message = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -NoEnumerate }
        catch {
            $failure = $_.Exception
            while ($null -ne $failure) {
                if ($failure.Data['BridgeTestWriteBlocked'] -or $failure.Data['BridgeTestNetworkBlocked']) {
                    Write-FramingRestRejection -Reason 'marked guard failure at the REST boundary'
                    throw
                }
                $failure = $failure.InnerException
            }
            $reason = 'unparseable MQTT request body'
        }
        if (-not $reason) {
            if ($null -eq $message -or $message -is [Array] -or
                -not $message.PSObject.Properties['topic'] -or $message.topic -isnot [string] -or
                -not $message.PSObject.Properties['payload'] -or $message.payload -isnot [string] -or
                -not $message.PSObject.Properties['qos'] -or $message.qos -ne 1 -or
                -not $message.PSObject.Properties['retain'] -or $message.retain -isnot [bool] -or -not $message.retain) {
                $reason = 'unexpected MQTT publication shape'
            }
            elseif (-not $script:ActivityTopicCounts.ContainsKey($message.topic)) {
                $reason = 'unexpected activity topic'
            }
            elseif ($script:ActivityTopicCounts[$message.topic] -ne 0) {
                $reason = 'duplicate activity publication'
            }
        }
    }
    if ($reason) {
        Write-FramingRestRejection -Reason $reason
        throw [InvalidOperationException]::new("Fixture REST rejection: $reason.")
    }
    $script:ActivityTopicCounts[$message.topic]++
    $script:Requests.Add($message)
    @()
}

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
. (Join-Path $PSScriptRoot '..\hooks\agent-bridge-daemon.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-session.ps1')
. (Join-Path $PSScriptRoot '..\claude\hooks\claude-transcript.ps1')
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-session.ps1')
. (Join-Path $PSScriptRoot '..\codex\hooks\codex-transcript.ps1')
$script:ClaudeAdapterLoaded = $true
$script:CodexAdapterLoaded = $true

$scratch = Join-Path ([IO.Path]::GetTempPath()) 'transcript-framing'
Assert-BridgeTestPath -Path $scratch
if (Test-Path -LiteralPath $scratch) { throw 'The framing fixture directory already exists.' }
[void][IO.Directory]::CreateDirectory($scratch)
$script:TranscriptFixture = Join-Path $scratch 'transcript.jsonl'
$replacementBackup = Join-Path $scratch 'previous.jsonl'
$script:DaemonConfig.LogFile = Join-Path $scratch 'daemon.log'
$script:DecisionBridgeConfig.LogFile = Join-Path $scratch 'bridge.log'
$script:Checks = 0
$script:Failures = 0
$primaryFailure = $null
$expectedChecks = 204

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public sealed class BridgeTranscriptFixtureStream : Stream
{
    private readonly FileStream inner;
    public int ReadLimit = int.MaxValue;
    public long TruncateAfter = -1;
    public byte[] AppendBytes;
    public bool ReportReadable = true;
    public bool ReportSeekable = true;
    public bool Truncated { get; private set; }
    public bool Appended { get; private set; }
    public int ReadCalls { get; private set; }
    public int ZeroReads { get; private set; }
    public int LengthQueries { get; private set; }
    public List<byte> ReadBytes { get; } = new List<byte>();

    public BridgeTranscriptFixtureStream(FileStream stream) { inner = stream; }
    public override bool CanRead => ReportReadable && inner.CanRead;
    public override bool CanSeek => ReportSeekable && inner.CanSeek;
    public override bool CanWrite => false;
    public override long Length { get { LengthQueries++; return inner.Length; } }
    public override long Position { get => inner.Position; set => inner.Position = value; }
    public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
    public override void Flush() => inner.Flush();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    public override int Read(byte[] buffer, int offset, int count)
    {
        ReadCalls++;
        if (!Truncated && TruncateAfter >= 0 && ReadBytes.Count >= TruncateAfter)
        {
            inner.SetLength(TruncateAfter);
            inner.Flush();
            Truncated = true;
        }
        int requested = Math.Min(count, ReadLimit);
        if (!Truncated && TruncateAfter >= 0)
            requested = (int)Math.Min(requested, TruncateAfter - ReadBytes.Count);
        int read = inner.Read(buffer, offset, requested);
        for (int i = 0; i < read; i++) ReadBytes.Add(buffer[offset + i]);
        if (read == 0) ZeroReads++;
        if (read > 0 && !Appended && AppendBytes != null)
        {
            long position = inner.Position;
            inner.Seek(0, SeekOrigin.End);
            inner.Write(AppendBytes, 0, AppendBytes.Length);
            inner.Flush();
            inner.Position = position;
            Appended = true;
        }
        return read;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) inner.Dispose();
        base.Dispose(disposing);
    }
}
'@

function Write-FramingObservation {
    param([string]$Name, [hashtable]$Data)
    $Data['case'] = $Name
    [Console]::Out.WriteLine('P7-FRAMING-OBSERVATION ' + ($Data | ConvertTo-Json -Depth 8 -Compress))
}

function Test-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks++
    $rejected = $script:RestRejections.Count
    if (-not $Condition -or $rejected -gt 0) {
        $script:Failures++
        Write-FramingObservation -Name $Name -Data @{
            outcome = 'failed'; assertionMatched = $Condition; check = $script:Checks
            rejectedRestCalls = $rejected; detail = $Detail
        }
        Write-Host "  FAIL  $Name - $Detail; rejected REST calls=$rejected"
        throw [InvalidOperationException]::new("Framing fixture stopped at failed check '$Name'.")
    }
    Write-Host "  PASS  $Name"
}

function Test-AppendResult {
    param([string]$Name, $Result, [long]$Offset, [AllowEmptyCollection()][string[]]$Lines)
    $matches = $Result.Offset -is [long] -and $Result.Offset -eq $Offset -and
        $Result.Lines -is [Array] -and $Result.Lines.Count -eq $Lines.Count
    if ($matches) {
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if (-not [StringComparer]::Ordinal.Equals($Result.Lines[$i], $Lines[$i])) { $matches = $false }
        }
    }
    $exists = [IO.File]::Exists($script:TranscriptFixture)
    Write-FramingObservation -Name $Name -Data @{
        offset = $Result.Offset; lines = @($Result.Lines); fileExists = $exists
        fileLength = $(if ($exists) { [IO.FileInfo]::new($script:TranscriptFixture).Length } else { $null })
    }
    Test-That -Name $Name -Condition $matches -Detail "expected offset $Offset and $($Lines.Count) exact lines"
}

function Test-ExpectedException {
    param([string]$Name, [scriptblock]$Action, [type]$ExceptionType)
    $caught = $null
    try { & $Action | Out-Null }
    catch {
        # A marked guard error can wrap the ordinary exception this case expects.
        $failure = $_.Exception
        while ($null -ne $failure) {
            if ($failure.Data['BridgeTestWriteBlocked'] -or $failure.Data['BridgeTestNetworkBlocked']) { throw }
            $caught = $failure
            $failure = $failure.InnerException
        }
    }
    Write-FramingObservation -Name $Name -Data @{
        exception = $(if ($null -ne $caught) { $caught.GetType().FullName } else { $null })
    }
    Test-That -Name $Name -Condition ($null -ne $caught -and $ExceptionType.IsInstanceOfType($caught))
}

function Set-TranscriptBytes {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    [IO.File]::WriteAllBytes($script:TranscriptFixture, $Bytes)
    Write-FramingObservation -Name 'replace synthetic bytes' -Data @{
        bytes = [BitConverter]::ToString($Bytes); fileLength = [IO.FileInfo]::new($script:TranscriptFixture).Length
    }
}

function Add-TranscriptBytes {
    param([byte[]]$Bytes)
    $writer = [IO.File]::Open($script:TranscriptFixture, 'Append', 'Write', 'ReadWrite')
    try { $writer.Write($Bytes, 0, $Bytes.Length) } finally { $writer.Dispose() }
    Write-FramingObservation -Name 'append synthetic bytes' -Data @{
        bytes = [BitConverter]::ToString($Bytes); fileLength = [IO.FileInfo]::new($script:TranscriptFixture).Length
    }
}

# Literal bytes, not a decoder-generated expectation: record lengths are 8 and 17.
$record1 = [byte[]](0x7B, 0x22, 0x6E, 0x22, 0x3A, 0x31, 0x7D, 0x0A)
$record2 = [byte[]](0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0x41, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x99, 0x82, 0x22, 0x7D, 0x0A)
$centRecord = [byte[]](0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0xC2, 0xA2, 0x22, 0x7D, 0x0A)
$firstText = '{"n":1}'
$secondText = '{"s":"A' + [char]0x20AC + [char]0xD83D + [char]0xDE42 + '"}'
$seed = [byte[]]($record1 + $record2)
$splitCases = @(
    @{ Bytes = $centRecord; Cuts = @(7); Text = ('{"s":"' + [char]0x00A2 + '"}') }
    @{ Bytes = $record2; Cuts = @(8, 9, 11, 12, 13); Text = $secondText }
)
$readers = @(
    @{
        Kind = 'copilot'; ShrinkLines = @()
        Read = {
            param($Path, $Offset, $Cap)
            $previousCap = $script:DaemonConfig.MaxTailBytes
            try {
                $script:DaemonConfig.MaxTailBytes = $Cap
                Read-TranscriptAppend -Path $Path -Offset $Offset
            }
            finally { $script:DaemonConfig.MaxTailBytes = $previousCap }
        }
    }
    @{
        Kind = 'claude'; ShrinkLines = @($firstText)
        Read = { param($Path, $Offset, $Cap) Read-ClaudeTranscriptAppend -Path $Path -Offset $Offset -MaxTailBytes $Cap }
    }
    @{
        Kind = 'codex'; ShrinkLines = @($firstText)
        Read = { param($Path, $Offset, $Cap) Read-CodexTranscriptAppend -Path $Path -Offset $Offset -MaxTailBytes $Cap }
    }
)

try {
    foreach ($reader in $readers) {
        $kind = $reader.Kind
        Set-TranscriptBytes $seed
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind reads complete byte frames" $tail 25 @($firstText, $secondText)
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind returns an empty array at unchanged EOF" $tail 25 @()

        foreach ($splitCase in $splitCases) {
            foreach ($cut in $splitCase.Cuts) {
                $label = "$kind $($splitCase.Bytes.Length)-byte record split at $cut"
                Set-TranscriptBytes ([byte[]]($record1 + $splitCase.Bytes[0..($cut - 1)]))
                $tail = & $reader.Read $script:TranscriptFixture 0 64
                Test-AppendResult "$label commits only the preceding record" $tail 8 @($firstText)
                $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
                Test-AppendResult "$label keeps its cursor on a repeated partial poll" $tail 8 @()
                Add-TranscriptBytes ([byte[]]$splitCase.Bytes[$cut..($splitCase.Bytes.Length - 1)])
                $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
                $end = 8L + $splitCase.Bytes.Length
                Test-AppendResult "$label delivers the exact completed character sequence" $tail $end @($splitCase.Text)
                $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
                Test-AppendResult "$label never delivers the record twice" $tail $end @()
            }
        }

        Set-TranscriptBytes ([byte[]]$record1[0..6])
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind waits even when JSON is complete without LF" $tail 0 @()
        Add-TranscriptBytes ([byte[]]@(10))
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind accepts delimiter-only completion" $tail 8 @($firstText)
        Set-TranscriptBytes ([byte[]]($record1[0..6] + 13))
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind withholds a CR before its LF" $tail 0 @()
        Add-TranscriptBytes ([byte[]]@(10))
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind preserves CR text and counts both CRLF bytes" $tail 9 @("$firstText`r")

        $filterBytes = [Text.Encoding]::ASCII.GetBytes("plain`n  $firstText `r`n`n`t`n")
        Set-TranscriptBytes $filterBytes
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        $expectedLines = if ($kind -eq 'copilot') { @("  $firstText `r") } else { @('plain', "  $firstText `r") }
        Test-AppendResult "$kind preserves its existing line filtering and whitespace" $tail $filterBytes.Length $expectedLines
        Set-TranscriptBytes ([byte[]](0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D, 0x0A))
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind retains replacement decoding for complete invalid UTF-8" $tail 10 @(('{"s":"' + [char]0xFFFD + '"}'))

        Set-TranscriptBytes ([byte[]]($seed + $record1))
        $tail = & $reader.Read $script:TranscriptFixture 0 25
        Test-AppendResult "$kind retains an aligned capped first record" $tail 33 @($secondText, $firstText)
        $tail = & $reader.Read $script:TranscriptFixture 0 17
        Test-AppendResult "$kind skips a capped leading multibyte fragment" $tail 33 @($firstText)
        Set-TranscriptBytes ([byte[]]([Text.Encoding]::ASCII.GetBytes('noise') + $record1 + $record1))
        $tail = & $reader.Read $script:TranscriptFixture 0 16
        Test-AppendResult "$kind does not mistake a brace-leading fragment for a record" $tail 21 @($firstText)
        Set-TranscriptBytes ([byte[]]$seed[0..23])
        $tail = & $reader.Read $script:TranscriptFixture 8 5
        Test-AppendResult "$kind does not invent a cursor at an unfinished capped window" $tail 8 @()
        Add-TranscriptBytes ([byte[]]@(10))
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 5
        Test-AppendResult "$kind consumes a skipped oversized record only through its LF" $tail 25 @()

        Set-TranscriptBytes $seed
        $adoptedOffset = [IO.FileInfo]::new($script:TranscriptFixture).Length
        $tail = & $reader.Read $script:TranscriptFixture $adoptedOffset 64
        Test-AppendResult "$kind does not replay an existing EOF cursor" $tail 25 @()
        Set-TranscriptBytes ([byte[]]$seed[0..15])
        $adoptedOffset = [IO.FileInfo]::new($script:TranscriptFixture).Length
        $tail = & $reader.Read $script:TranscriptFixture $adoptedOffset 64
        Test-AppendResult "$kind leaves a partial adopted EOF alone" $tail 16 @()
        Add-TranscriptBytes ([byte[]]$seed[16..24])
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind skips the continuation of an already adopted record" $tail 25 @()
        Add-TranscriptBytes $record1
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind reads the next record after an adopted fragment" $tail 33 @($firstText)

        Set-TranscriptBytes $seed
        $prior = & $reader.Read $script:TranscriptFixture 0 64
        Set-TranscriptBytes $record1
        $tail = & $reader.Read $script:TranscriptFixture $prior.Offset 64
        Test-AppendResult "$kind keeps its existing shrink policy" $tail 8 @($reader.ShrinkLines)

        Set-TranscriptBytes $record1
        $prior = & $reader.Read $script:TranscriptFixture 0 64
        [IO.File]::Delete($replacementBackup)
        [IO.File]::Move($script:TranscriptFixture, $replacementBackup)
        Set-TranscriptBytes ([Text.Encoding]::ASCII.GetBytes("{`"n`":2}`n"))
        $tail = & $reader.Read $script:TranscriptFixture $prior.Offset 64
        Test-AppendResult "$kind characterizes undetected equal-size replacement" $tail 8 @()
        [IO.File]::Delete($replacementBackup)
        [IO.File]::Move($script:TranscriptFixture, $replacementBackup)
        Set-TranscriptBytes ([byte[]]([Text.Encoding]::ASCII.GetBytes("{`"n`":2}`n") + $record1))
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind characterizes numeric continuation after larger replacement" $tail 16 @($firstText)
        $regrown = [byte[]]($seed + $record1)
        $writer = [IO.File]::Open($script:TranscriptFixture, 'Open', 'Write', 'ReadWrite')
        try {
            $writer.SetLength(0)
            $truncatedLength = $writer.Length
            $writer.Write($regrown, 0, $regrown.Length)
        }
        finally { $writer.Dispose() }
        Write-FramingObservation -Name "$kind actual truncate and regrow" -Data @{
            truncatedLength = $truncatedLength; regrownLength = [IO.FileInfo]::new($script:TranscriptFixture).Length
            savedOffset = $tail.Offset; bytes = [BitConverter]::ToString($regrown)
        }
        $tail = & $reader.Read $script:TranscriptFixture $tail.Offset 64
        Test-AppendResult "$kind characterizes undetected truncation and regrowth between reads" $tail 33 @($firstText)

        Set-TranscriptBytes $seed
        Test-ExpectedException "$kind propagates a negative core offset" {
            & $reader.Read $script:TranscriptFixture -1 64
        } ([ArgumentException])
        Test-ExpectedException "$kind propagates a nonpositive core limit" {
            & $reader.Read $script:TranscriptFixture 0 0
        } ([ArgumentException])

        $exclusive = [IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'None')
        try {
            if ($kind -eq 'copilot') {
                $tail = & $reader.Read $script:TranscriptFixture 8 64
                Test-AppendResult 'Copilot retains its cursor on an actual sharing failure' $tail 8 @()
                $log = [IO.File]::ReadAllText($script:DaemonConfig.LogFile)
                Test-That 'Copilot records its actual read failure in the real daemon log' ($log.Contains("transcript read failed for '$script:TranscriptFixture':"))
            }
            else {
                Test-ExpectedException "$kind propagates an actual sharing failure" {
                    & $reader.Read $script:TranscriptFixture 8 64
                } ([IO.IOException])
            }
        }
        finally { $exclusive.Dispose() }
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind can reopen its own file after the obstruction is removed" $tail 25 @($firstText, $secondText)

        [IO.File]::Delete($script:TranscriptFixture)
        $tail = & $reader.Read $script:TranscriptFixture 8 64
        $missingOffset = if ($kind -eq 'copilot') { 8L } else { 0L }
        Test-AppendResult "$kind preserves its missing-file result shape" $tail $missingOffset @()
        Set-TranscriptBytes ([byte[]]@())
        $tail = & $reader.Read $script:TranscriptFixture 0 64
        Test-AppendResult "$kind returns an Int64 cursor and an array for an empty file" $tail 0 @()
    }
    $tail = Read-CodexTranscriptAppend -Path '' -Offset 8
    Test-AppendResult 'Codex preserves its blank-path result shape' $tail 0 @()

    foreach ($limit in @(1, 2, 3)) {
        Set-TranscriptBytes $seed
        $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
        try {
            $stream.ReadLimit = $limit
            $snapshot = $stream.Length
            $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength $snapshot -MaxTailBytes 64
            Test-AppendResult "the core completes real $limit-byte positive short reads" $tail 25 @($firstText, $secondText)
            Write-FramingObservation -Name "short reads of $limit bytes" -Data @{
                readCalls = $stream.ReadCalls; bytes = [BitConverter]::ToString($stream.ReadBytes.ToArray())
                lengthQueries = $stream.LengthQueries; streamOpen = $stream.CanRead
            }
            Test-That "the core reads only the snapshot and leaves its $limit-byte stream open" (
                $stream.ReadBytes.Count -eq 25 -and $stream.ReadCalls -eq [Math]::Ceiling(25.0 / $limit) -and
                $stream.LengthQueries -eq 1 -and $stream.CanRead -and
                [BitConverter]::ToString($stream.ReadBytes.ToArray()) -ceq [BitConverter]::ToString($seed))
        }
        finally { $stream.Dispose() }
    }

    Set-TranscriptBytes ([byte[]]($seed + $record1))
    $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
    try {
        $stream.ReadLimit = 3
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength $stream.Length -MaxTailBytes 17
        Test-AppendResult 'the core frames a capped window after its boundary probe' $tail 33 @($firstText)
        Test-That 'the boundary probe costs exactly one byte beyond the 17-byte window' ($stream.ReadBytes.Count -eq 18)
    }
    finally { $stream.Dispose() }

    Set-TranscriptBytes ([byte[]]$seed[0..23])
    $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
    try {
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 8 -SnapshotLength $stream.Length -MaxTailBytes 5
        Test-AppendResult 'the core retains the committed cursor when no LF is consumed' $tail 8 @()
        Test-That 'an unfinished capped record still has bounded I/O' ($stream.ReadBytes.Count -eq 6 -and $stream.CanRead)
    }
    finally { $stream.Dispose() }

    Set-TranscriptBytes $seed
    $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
    try {
        $stream.ReadLimit = 3
        $stream.TruncateAfter = 16
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength $stream.Length -MaxTailBytes 64
        Test-AppendResult 'real mid-read truncation commits only the first eight bytes' $tail 8 @($firstText)
        Write-FramingObservation -Name 'actual mid-read truncation' -Data @{
            readCalls = $stream.ReadCalls; bytes = [BitConverter]::ToString($stream.ReadBytes.ToArray())
            zeroReads = $stream.ZeroReads; fileLength = [IO.FileInfo]::new($script:TranscriptFixture).Length
        }
        Test-That 'the truncated file really ends at byte 16 and the core stops on EOF' (
            $stream.Truncated -and $stream.ReadBytes.Count -eq 16 -and $stream.ZeroReads -eq 1 -and
            [IO.FileInfo]::new($script:TranscriptFixture).Length -eq 16 -and $stream.CanRead)
    }
    finally { $stream.Dispose() }

    Set-TranscriptBytes $seed
    $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
    try {
        $stream.ReadLimit = 3
        $stream.AppendBytes = $record1
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength $stream.Length -MaxTailBytes 64
        Test-AppendResult 'the core does not chase bytes appended after its snapshot' $tail 25 @($firstText, $secondText)
        Test-That 'growth is real but this read still consumes only its original budget' (
            $stream.Appended -and $stream.ReadBytes.Count -eq 25 -and $stream.LengthQueries -eq 1 -and
            [IO.FileInfo]::new($script:TranscriptFixture).Length -eq 33)
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset $tail.Offset -SnapshotLength $stream.Length -MaxTailBytes 64
        Test-AppendResult 'a subsequent snapshot receives the newly appended bytes' $tail 33 @($firstText)
    }
    finally { $stream.Dispose() }

    Set-TranscriptBytes $seed
    $inner = [IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite')
    $stream = [BridgeTranscriptFixtureStream]::new($inner)
    try {
        $snapshot = $stream.Length
        $inner.SetLength(0)
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 8 -SnapshotLength $snapshot -MaxTailBytes 64
        Test-AppendResult 'EOF during the look-behind does not invent progress' $tail 8 @()
        Test-That 'a failed boundary read does not scan or read a second window' ($stream.ReadBytes.Count -eq 0 -and $stream.ZeroReads -eq 1)
    }
    finally { $stream.Dispose() }

    Set-TranscriptBytes $seed
    $stream = [BridgeTranscriptFixtureStream]::new([IO.File]::Open($script:TranscriptFixture, 'Open', 'ReadWrite', 'ReadWrite'))
    try {
        Test-ExpectedException 'a null stream is an explicit contract error' {
            Read-BridgeTranscriptStream -Stream $null -Offset 0 -SnapshotLength 25 -MaxTailBytes 64
        } ([ArgumentException])
        foreach ($bounds in @(
            @{ Name = 'negative offset'; Offset = -1L; Length = 25L; Limit = 64 }
            @{ Name = 'negative snapshot'; Offset = 0L; Length = -1L; Limit = 64 }
            @{ Name = 'offset past snapshot'; Offset = 26L; Length = 25L; Limit = 64 }
            @{ Name = 'zero limit'; Offset = 0L; Length = 25L; Limit = 0 }
            @{ Name = 'negative limit'; Offset = 0L; Length = 25L; Limit = -1 }
        )) {
            Test-ExpectedException "$($bounds.Name) is an explicit contract error" {
                Read-BridgeTranscriptStream -Stream $stream -Offset $bounds.Offset -SnapshotLength $bounds.Length -MaxTailBytes $bounds.Limit
            } ([ArgumentException])
        }
        $stream.ReportReadable = $false
        Test-ExpectedException 'an unreadable stream is an explicit contract error' {
            Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength 25 -MaxTailBytes 64
        } ([ArgumentException])
        $stream.ReportReadable = $true
        $stream.ReportSeekable = $false
        Test-ExpectedException 'a nonseekable stream is an explicit contract error' {
            Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength 25 -MaxTailBytes 64
        } ([ArgumentException])
        $stream.ReportSeekable = $true
        $stream.Dispose()
        Test-ExpectedException 'a disposed stream is an explicit contract error' {
            Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength 25 -MaxTailBytes 64
        } ([ArgumentException])
    }
    finally { $stream.Dispose() }
    Set-TranscriptBytes ([byte[]]@())
    $stream = [IO.File]::OpenRead($script:TranscriptFixture)
    try {
        $tail = Read-BridgeTranscriptStream -Stream $stream -Offset 0 -SnapshotLength $stream.Length -MaxTailBytes 64
        Test-AppendResult 'the core preserves its empty-file array and Int64 shape' $tail 0 @()
    }
    finally { $stream.Dispose() }

    $responseText = 'ok ' + [char]0x20AC + [char]0xD83D + [char]0xDE42
    $responseBytes = [byte[]](0x6F, 0x6B, 0x20, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x99, 0x82)
    $consumers = @(
        @{ Kind = 'copilot'; Id = '11111111-1111-4111-8111-111111111111'; Prefix = '{"type":"assistant.message","data":{"content":"'; Suffix = '"}}' }
        @{ Kind = 'claude'; Id = '22222222-2222-4222-8222-222222222222'; Prefix = '{"type":"assistant","message":{"content":"'; Suffix = '"}}' }
        @{ Kind = 'codex'; Id = '33333333-3333-4333-8333-333333333333'; Prefix = '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"'; Suffix = '"}]}}' }
    )
    foreach ($consumer in $consumers) {
        $prefix = [Text.Encoding]::ASCII.GetBytes($consumer.Prefix)
        $suffix = [Text.Encoding]::ASCII.GetBytes($consumer.Suffix + "`n")
        Set-TranscriptBytes ([byte[]]($prefix + $responseBytes[0..3]))
        $entry = [pscustomobject]@{
            Offset = 0L; Name = 'Synthetic framing session'; Machine = 'FIXTURE'; Kind = $consumer.Kind
            Status = 'working'; LastMessage = 'previous'; LastResponse = 'previous'; LastHistory = @()
        }
        $session = [pscustomobject]@{ SessionId = $consumer.Id; Transcript = $script:TranscriptFixture; ProcessId = 1; Activity = 'Working' }
        $parameters = @{ Id = $consumer.Id; Entry = $entry; Session = $session; Headers = @{}; VerboseOn = $false }
        $before = $script:Requests.Count
        if ($consumer.Kind -eq 'codex') { Update-DaemonCodexActivity @parameters }
        else { Update-DaemonSessionActivity @parameters }
        Test-That "$($consumer.Kind) leaves the real cached card unchanged on a partial character" (
            $entry.Offset -eq 0 -and $entry.LastMessage -ceq 'previous' -and $script:Requests.Count -eq $before)
        Add-TranscriptBytes ([byte[]]($responseBytes[4..9] + $suffix))
        if ($consumer.Kind -eq 'codex') { Update-DaemonCodexActivity @parameters }
        else { Update-DaemonSessionActivity @parameters }
        $end = [long]($prefix.Length + $responseBytes.Length + $suffix.Length)
        Test-That "$($consumer.Kind) records the exact completed reply through its real consumer" (
            $entry.Offset -eq $end -and $entry.LastMessage -ceq $responseText -and $entry.Status -eq 'working')
        $topics = Get-CopilotMqttTopics -SessionId $consumer.Id
        $published = @($script:Requests | Where-Object { $_.topic -ceq $topics.ActivityAttributes })
        $detail = if ($published.Count -eq 1) { $published[0].payload | ConvertFrom-Json } else { $null }
        Write-FramingObservation -Name "$($consumer.Kind) actual published reply" -Data @{
            offset = $entry.Offset; cached = $entry.LastMessage; publications = ($script:Requests.Count - $before)
            detail = $detail
        }
        Test-That "$($consumer.Kind) reaches the exact external REST recorder through real publishers" (
            $script:Requests.Count -eq ($before + 2) -and $null -ne $detail -and $detail.response -ceq $responseText)
        if ($consumer.Kind -eq 'codex') { Update-DaemonCodexActivity @parameters }
        else { Update-DaemonSessionActivity @parameters }
        Test-That "$($consumer.Kind) does not republish an unchanged completed record" (
            $script:Requests.Count -eq ($before + 2) -and $entry.Offset -eq $end)
    }

    $question = [Text.Encoding]::ASCII.GetBytes('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","id":"question-1","input":{}}]}}' + "`n")
    $answerPrefix = [Text.Encoding]::ASCII.GetBytes('{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"question-1","content":"picked ')
    Set-TranscriptBytes ([byte[]]($question + $answerPrefix + 0xE2))
    $answer = Get-ClaudeAskUserState -TranscriptPath $script:TranscriptFixture -ToolCallId 'question-1'
    Test-That 'a partial result leaves the actual named Claude question pending' ($answer.Started -and $answer.Pending -and $answer.ResultContent -eq '')
    Add-TranscriptBytes ([byte[]](@(0x82, 0xAC) + [Text.Encoding]::ASCII.GetBytes('"}]}}' + "`n")))
    $answer = Get-ClaudeAskUserState -TranscriptPath $script:TranscriptFixture -ToolCallId 'question-1'
    Test-That 'the actual named Claude question receives its exact completed answer' (-not $answer.Pending -and $answer.ResultContent -ceq ('picked ' + [char]0x20AC))
    $other = Get-ClaudeAskUserState -TranscriptPath $script:TranscriptFixture -ToolCallId 'question-2'
    Test-That 'a completed result does not answer a different named question' ($other.Pending -and $other.ResultContent -eq '')
    Test-That 'the actual Claude submission consumer excludes tool results' (-not (Test-DaemonClaudePromptSubmitted -Transcript $script:TranscriptFixture))
    Set-TranscriptBytes ([Text.Encoding]::ASCII.GetBytes('{"type":"queue-operation","operation":"enqueue"}'))
    Test-That 'the actual Claude submission consumer waits for the queue record LF' (-not (Test-DaemonClaudePromptSubmitted -Transcript $script:TranscriptFixture))
    Add-TranscriptBytes ([byte[]]@(10))
    Test-That 'the actual Claude submission consumer accepts a completed queue record' (Test-DaemonClaudePromptSubmitted -Transcript $script:TranscriptFixture)
    Set-TranscriptBytes ([byte[]]([Text.Encoding]::ASCII.GetBytes('{"type":"user","message":{"content":"') + 0xE2))
    Test-That 'the actual Claude submission consumer withholds a split user character' (-not (Test-DaemonClaudePromptSubmitted -Transcript $script:TranscriptFixture))
    Add-TranscriptBytes ([byte[]](@(0x82, 0xAC) + [Text.Encoding]::ASCII.GetBytes('"}}' + "`n")))
    Test-That 'the actual Claude submission consumer accepts the complete user record' (Test-DaemonClaudePromptSubmitted -Transcript $script:TranscriptFixture)

    Write-FramingObservation -Name 'total REST publication accounting' -Data @{
        attempts = $script:RestAttemptCount; accepted = $script:Requests.Count
        rejected = $script:RestRejections.Count; topics = $script:ActivityTopicCounts
    }
    Test-That 'only the exact six intended publications reached the REST recorder' (
        $script:BridgeBlockedHttpCalls -eq 0 -and $script:RestRejections.Count -eq 0 -and
        $script:RestAttemptCount -eq 6 -and $script:Requests.Count -eq 6 -and
        $script:ActivityTopicCounts.Count -eq 6 -and
        @($script:ActivityTopicCounts.Values | Where-Object { $_ -ne 1 }).Count -eq 0)
    Test-That 'the declared byte matrix was reached exactly once' ($script:Checks -eq ($expectedChecks - 1))
}
catch {
    $primaryFailure = $_
    if ($script:Failures -eq 0) {
        $script:Failures++
        Write-FramingObservation -Name 'unexpected fixture failure' -Data @{
            outcome = 'failed'; check = $script:Checks; rejectedRestCalls = $script:RestRejections.Count
            exceptionType = $_.Exception.GetType().FullName; line = $_.InvocationInfo.ScriptLineNumber
        }
    }
    throw
}
finally {
    try {
        foreach ($path in @($script:TranscriptFixture, $replacementBackup, $script:DaemonConfig.LogFile, $script:DecisionBridgeConfig.LogFile)) {
            [IO.File]::Delete($path)
        }
        [IO.Directory]::Delete($scratch)
    }
    catch {
        Write-FramingObservation -Name 'fixture cleanup failure' -Data @{
            outcome = 'cleanup-failed'; exceptionType = $_.Exception.GetType().FullName
            line = $_.InvocationInfo.ScriptLineNumber; hresult = $_.Exception.HResult
            primaryExceptionType = $(if ($null -ne $primaryFailure) { $primaryFailure.Exception.GetType().FullName } else { $null })
        }
        if ($null -eq $primaryFailure) { throw }
        # Keep the original assertion/guard error in flight, not the cleanup error.
    }
}
if ($script:Failures) { exit 1 }
Write-Host 'P7-FRAMING-GAP malformed-schema validation and healthy-neighbor iteration containment remain open.'
Write-Host 'P7-FRAMING-GAP numeric cursors do not establish replacement identity or truncate-and-regrow recovery.'
Write-Host "P7-FRAMING-COMPLETE checks=$script:Checks failures=$script:Failures gaps=2 fixtureChildren=0"
exit 0
