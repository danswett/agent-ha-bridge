#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the canonical offline suites in separate, private environments.
.DESCRIPTION
    Host and platform groups are explicit disposable-CI gates. Integration suites
    are inventoried but never run here. This isolates reviewed regression tests;
    it is not an OS sandbox for untrusted scripts.

    Fixture writes require the allocated sandbox identity, matching synthetic homes,
    confined effective context paths and unlinked path components. A marker or HOME
    assignment alone does not authorize a write. Direct suites without that boundary
    fail before reading configuration or mutating an installation. Descendants retain
    the same checks; tests must propagate marked boundary failures through real callers.
    Filesystem checks do not promise atomic protection against adversarial link swaps.

    The existing platform-default temporary base is physically resolved before
    allocating results. Explicit results paths are never resolved through links.
#>
[CmdletBinding()]
param(
    [ValidateSet('Offline', 'Host', 'Platform', 'Integration')][string]$Group = 'Offline',
    [string[]]$Suite = @(),
    [switch]$List,
    [switch]$AllowHostTests,
    # 300, not 180. test-dashboard needs about 168 seconds once the publication
    # fixtures exist: 48 scenarios that each build a synthetic install, three that
    # launch a real child process to prove behaviour survives a restart. Measured
    # 19.4s inside the assertions and 148.3s between them, in setup. At 180 the
    # margin was smaller than the difference between two machines - one host
    # recorded 172.9s and passed while another was killed at the wall on every
    # run, so whether main's CI went green depended on which runner it landed on.
    # The installer group already passes 300 explicitly for the same reason.
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
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

if ($ResultsDirectory) {
    $ResultsDirectory = New-BridgeTestResultsDirectory -Directory $ResultsDirectory
}
else {
    $defaultResults = New-BridgeTestDefaultResultsDirectory
    $ResultsDirectory = $defaultResults.Directory
    Write-Host "Default temporary base: $($defaultResults.PlatformBase) -> $($defaultResults.PhysicalBase) ($($defaultResults.LinksResolved) link resolution(s))."
}

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
        try { Remove-BridgeTestSandbox -Sandbox $sandbox }
        finally {
            $results.ToArray() | ConvertTo-Json -Depth 5 -AsArray |
                Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.json') -Encoding utf8
        }
    }
}
$failures = @($results | Where-Object { $_.TimedOut -or $_.ExitCode -ne 0 })
$skipCount = @($results | ForEach-Object { $_.Skips }).Count
Write-Host "Completed $($results.Count) suite(s); $($failures.Count) failed; $skipCount explicit skip(s). Summary: $(Join-Path $ResultsDirectory 'summary.json')"
if ($failures.Count) { exit 1 }
exit 0
