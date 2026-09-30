#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the canonical offline suites in separate, private environments.
.DESCRIPTION
    Host and platform groups are explicit disposable-CI gates. Integration suites
    are inventoried but never run here. This isolates reviewed regression tests;
    it is not an OS sandbox for untrusted scripts.
#>
[CmdletBinding()]
param(
    [ValidateSet('Offline', 'Host', 'Platform', 'Integration')][string]$Group = 'Offline',
    [string[]]$Suite = @(),
    [switch]$List,
    [switch]$AllowHostTests,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 180,
    [string]$ResultsDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')

$suites = @(Get-BridgeTestSuite -Group $Group -Suite $Suite)
if ($List) {
    $suites | Select-Object Group, Suite
    return
}
if ($Group -eq 'Integration') { throw 'Integration suites require an explicitly configured disposable Home Assistant. This runner never enables them.' }
if ($Group -ne 'Offline') { Assert-BridgeHostedTest -AllowHostTests:$AllowHostTests }

if (-not $ResultsDirectory) {
    $ResultsDirectory = Join-Path ([IO.Path]::GetTempPath()) ("bridge-tests-" + [guid]::NewGuid().ToString('N'))
}
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
if (Test-Path -LiteralPath $ResultsDirectory) { throw "Use a new results directory; refusing to overwrite $ResultsDirectory" }
[void][IO.Directory]::CreateDirectory($ResultsDirectory)
[IO.File]::WriteAllText((Join-Path $ResultsDirectory '.bridge-test-results'), '')

Write-Host "$Group suites: $($suites.Count). Logs: $ResultsDirectory"
if ($Group -eq 'Offline') { Write-Host 'Excluded by design: Host (installer), Platform (terminal delivery), Integration (live Home Assistant).' }
$results = [Collections.Generic.List[object]]::new()
foreach ($entry in $suites) {
    $sandbox = New-BridgeTestSandbox -ParentDirectory $ResultsDirectory
    try {
        $start = New-BridgeTestProcessStartInfo -ScriptPath $entry.Path -Sandbox $sandbox -Group $Group
        $result = Invoke-BridgeTestProcess -StartInfo $start -TimeoutSeconds $TimeoutSeconds
        $key = $entry.Suite -replace '[\\/.]', '_'
        $log = Join-Path $ResultsDirectory "$key.log"
        [IO.File]::WriteAllText($log, $result.Output, [Text.UTF8Encoding]::new($false))
        $skips = @($result.Output -split '\r?\n' | Where-Object { $_ -match '^\s*SKIP\b' })
        $record = [pscustomobject]@{
            Suite = $entry.Suite
            Group = $Group
            ExitCode = $result.ExitCode
            TimedOut = $result.TimedOut
            Seconds = $result.Seconds
            PassedAssertions = [regex]::Matches($result.Output, '(?m)^\s*PASS\b').Count
            FailedAssertions = [regex]::Matches($result.Output, '(?m)^\s*FAIL\b').Count
            Skips = $skips
            Log = $log
        }
        $results.Add($record)
        $failed = $result.TimedOut -or $result.ExitCode -ne 0
        $label = if ($failed) { 'FAIL' } elseif ($skips.Count) { 'PASS with skips' } else { 'PASS' }
        Write-Host "$label $($entry.Suite) ($($result.Seconds)s, exit $($result.ExitCode), timeout=$($result.TimedOut))"
        foreach ($skip in $skips) { Write-Host $skip }
        if ($failed) { Write-Host $result.Output }
    }
    finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force
        $results.ToArray() | ConvertTo-Json -Depth 5 -AsArray |
            Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.json') -Encoding utf8
    }
}
$failures = @($results | Where-Object { $_.TimedOut -or $_.ExitCode -ne 0 })
$skipCount = @($results | ForEach-Object { $_.Skips }).Count
Write-Host "Completed $($results.Count) suite(s); $($failures.Count) failed; $skipCount explicit skip(s). Summary: $(Join-Path $ResultsDirectory 'summary.json')"
if ($failures.Count) { exit 1 }
exit 0
