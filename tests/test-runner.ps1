#Requires -Version 7.0
# Constructor arguments are quoted positional data, not named parameter tokens.
param(
    [Parameter(Position = 0)]
    [ValidateSet('Suite', 'ConstructorProbe')]
    [string]$RunnerEntryMode = 'Suite'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:AGENT_HA_BRIDGE_TEST_ROOT) { throw 'Run this suite through tests\run-tests.ps1.' }
if ($RunnerEntryMode -eq 'ConstructorProbe') {
    Assert-BridgeTestEnvironment -Required
    $probeBoundary = Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT
    [ordered]@{
        RunnerEntryMode = $RunnerEntryMode
        Entry = $PSCommandPath
        WorkingDirectory = (Get-Location).Path
        Context = (Get-Command Get-BridgeTestSandbox).ScriptBlock.File
        Root = $probeBoundary['root']
        Repository = $probeBoundary['repository']
        Home = $HOME
        InputClosed = ($null -eq [Console]::ReadLine())
    } | ConvertTo-Json -Compress
    exit 0
}
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot 'write-boundary-fixtures.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = $_.Exception.Message }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name - $Detail"; $script:Failures++ }
}

Write-Host '--- one classified inventory for every platform ---'
Test-That 'the runner marks its results directory so inventory can prune generated suites' {
    Test-Path -LiteralPath (Join-Path (Split-Path -Parent $env:AGENT_HA_BRIDGE_TEST_ROOT) '.bridge-test-results') -PathType Leaf
}
$offline = @(Get-BridgeTestSuite)
foreach ($expected in @(
    'test-http-session.ps1', 'test-launch-permissions.ps1', 'test-reply-card.ps1',
    'test-status-card.ps1', 'test-terminal-window.ps1', 'test-worktree-isolation.ps1',
    'test-codex.ps1', 'test-claude-install.ps1'
)) {
    Test-That "$expected is selected offline" {
        @(Get-BridgeTestSuite -Suite $expected).Count -eq 1
    }
}
Test-That 'installer, platform and integration suites cannot enter the offline selection' {
    @($offline | Where-Object { $_.Suite -match 'test-install-command|test-platform|integration' }).Count -eq 0
}
Test-That 'all suites belong to exactly one group' {
    $all = @(foreach ($group in 'Offline', 'Host', 'Platform', 'Integration') { Get-BridgeTestSuite -Group $group })
    @($all | Group-Object Suite | Where-Object Count -ne 1).Count -eq 0
}
foreach ($bad in 'test-no-such-suite.ps1', 'test-install-command.ps1', '..\install.ps1', '*') {
    Test-That "selection rejects $bad rather than skipping it" {
        try { Get-BridgeTestSuite -Suite $bad; $false }
        catch { $_.Exception.Message -match 'Expected one Offline suite' }
    }
}
Test-That 'duplicate selectors fail instead of running twice' {
    try { Get-BridgeTestSuite -Suite @('test-runner.ps1', 'tests\test-runner.ps1'); $false }
    catch { $_.Exception.Message -match 'more than once' }
}
Test-That 'host execution is refused without an explicit opt-in' {
    try { Assert-BridgeHostedTest; $false }
    catch { $_.Exception.Message -match 'disposable GitHub-hosted' }
}
Test-That 'an opt-in alone never permits a developer or self-hosted machine' {
    try { Assert-BridgeHostedTest -AllowHostTests; $false }
    catch { $_.Exception.Message -match 'disposable GitHub-hosted' }
}

$scratch = Join-Path $env:TEMP ("runner-fixtures-" + [guid]::NewGuid().ToString('N'))
Assert-BridgeTestPath -Path $scratch
[void][IO.Directory]::CreateDirectory($scratch)
$sandboxes = @()
$inventoryLinks = @()
$defaultFixture = Join-Path $env:TEMP 'd'
$defaultFixtureCreated = $false
$saved = @{}
$poison = @{
    AGENT_HA_TOKEN = 'synthetic-parent-token'
    AGENT_HA_AGENT_TOKEN = 'synthetic-parent-agent-token'
    CUSTOM_HOUSE_CREDENTIAL = 'synthetic-custom-token'
    BRIDGE_ALLOW_TEST_HTTP = '1'
    AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN = 'http://127.0.0.1:1'
    COPILOT_HA_BRIDGE_CONFIG = (Join-Path $scratch 'not-a-config.json')
    HTTPS_PROXY = 'http://proxy.invalid:1'
    NODE_OPTIONS = '--require=not-a-module'
    GIT_CONFIG_COUNT = '1'
}
try {
    Write-Host '--- only the platform default base is physically resolved before allocation ---'
    Assert-BridgeTestPath -Path $defaultFixture
    if (Test-Path -LiteralPath $defaultFixture) { throw 'The default-temp fixture already exists; nothing was overwritten.' }
    [void][IO.Directory]::CreateDirectory($defaultFixture)
    $defaultFixtureCreated = $true
    $physicalParent = Join-Path $defaultFixture 'b'
    $physicalBase = Join-Path $physicalParent 't'
    $protectedDefault = Join-Path $defaultFixture 'p'
    foreach ($directory in @($physicalBase, $protectedDefault)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $protectedDefaultFile = Join-Path $protectedDefault 'sentinel.txt'
    Set-Content -LiteralPath $protectedDefaultFile -Value 'default-temp protected stand-in' -Encoding utf8
    $protectedDefaultBefore = (Get-FileHash -LiteralPath $protectedDefaultFile -Algorithm SHA256).Hash
    $defaultAlias = Join-Path $defaultFixture 'a'
    $defaultLinkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    [void](New-Item -ItemType $defaultLinkType -Path $defaultAlias -Value $physicalParent)
    $platformBase = Join-Path $defaultAlias 't'
    $defaultAllocation = New-BridgeTestDefaultResultsDirectory -PlatformTempBase $platformBase
    Test-That 'default allocation preserves the caller spelling and uses the physical existing base' {
        $defaultAllocation.PlatformBase -ceq $platformBase -and
        (Test-BridgeInstallPath $defaultAllocation.PhysicalBase $physicalBase) -and
        (Test-BridgeInstallDescendant $defaultAllocation.Directory $physicalBase) -and
        (Split-Path $defaultAllocation.Directory -Leaf) -match '^bridge-tests-[a-f0-9]{32}$' -and
        $defaultAllocation.LinksResolved -eq 1
    }
    $defaultMarker = Get-Content -LiteralPath (Join-Path $defaultAllocation.Directory '.bridge-test-results') -Raw |
        ConvertFrom-Json
    Test-That 'the default results marker records the physical directory rather than its alias' {
        $defaultMarker.schemaVersion -eq 1 -and
        (Test-BridgeInstallPath $defaultMarker.root $defaultAllocation.Directory)
    }
    $defaultBox = New-BridgeTestSandbox -ParentDirectory $defaultAllocation.Directory
    $sandboxes += $defaultBox
    $defaultBoundary = Get-BridgeTestSandbox -Root $defaultBox
    Test-That 'a sandbox allocated under default results records the same physical parent and root' {
        (Test-BridgeInstallPath $defaultBoundary['parent'] $defaultAllocation.Directory) -and
        (Test-BridgeInstallPath $defaultBoundary['root'] $defaultBox) -and
        (Test-BridgeInstallDescendant $defaultBox $physicalBase)
    }
    $defaultProbe = Join-Path $defaultFixture 'default-child.ps1'
    @'
$boundary = Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT
$written = Join-Path $env:TEMP 'default-temp-child.txt'
Assert-BridgeTestPath -Path $written
Set-Content -LiteralPath $written -Value 'owned child write' -Encoding utf8
[ordered]@{
    Root = $boundary['root']
    Parent = $boundary['parent']
    Home = $HOME
    Temp = [IO.Path]::GetTempPath()
    Config = $env:AGENT_HA_BRIDGE_CONFIG
    Written = $written
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $defaultProbe -Encoding utf8
    $defaultChild = Invoke-BridgeTestProcess -StartInfo (
        New-BridgeTestProcessStartInfo -ScriptPath $defaultProbe -Sandbox $defaultBox)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'default-temp'; Result = $defaultChild
    })
    Test-That 'a real sanitized child of default allocation completes without a timeout' {
        $defaultChild.ExitCode -eq 0 -and -not $defaultChild.TimedOut
    } $defaultChild.Output
    if ($defaultChild.ExitCode -ne 0 -or $defaultChild.TimedOut) { throw 'The default-temp child failed; stopping.' }
    $defaultObserved = $defaultChild.Output | ConvertFrom-Json
    Test-That 'the child roots and actual write use the physical sandbox identity' {
        (Test-BridgeInstallPath $defaultObserved.Root $defaultBox) -and
        (Test-BridgeInstallPath $defaultObserved.Parent $defaultAllocation.Directory) -and
        (Test-BridgeInstallPath $defaultObserved.Home (Join-Path $defaultBox 'home')) -and
        (Test-BridgeInstallPath $defaultObserved.Temp (Join-Path $defaultBox 'temp')) -and
        (Test-BridgeInstallDescendant $defaultObserved.Config $defaultBox) -and
        (Test-BridgeInstallDescendant $defaultObserved.Written (Join-Path $defaultBox 'temp')) -and
        (Get-Content -LiteralPath $defaultObserved.Written -Raw).Trim() -ceq 'owned child write'
    }

    $explicitAliasResult = Join-Path $platformBase 'explicit-refused'
    Test-That 'an explicit results path through the same alias is still rejected before writing' {
        $refused = $false
        try { $null = New-BridgeTestResultsDirectory -Directory $explicitAliasResult }
        catch { $refused = $_.Exception.Message -match 'linked|boundary rejected' }
        $refused -and -not (Test-Path -LiteralPath (Join-Path $physicalBase 'explicit-refused'))
    }
    $nestedAlias = Join-Path $defaultAllocation.Directory 'n'
    [void](New-Item -ItemType $defaultLinkType -Path $nestedAlias -Value $protectedDefault)
    Test-That 'a link nested under physical default results does not authorize another results directory' {
        $refused = $false
        try { $null = New-BridgeTestResultsDirectory -Directory (Join-Path $nestedAlias 'escape') }
        catch { $refused = $_.Exception.Message -match 'linked|boundary rejected' }
        $refused -and -not (Test-Path -LiteralPath (Join-Path $protectedDefault 'escape'))
    }
    Test-That 'a nested linked parent is still refused by the real sandbox allocator' {
        try { $null = New-BridgeTestSandbox -ParentDirectory $nestedAlias; $false }
        catch { $_.Exception.Message -match 'linked|boundary rejected' }
    }
    foreach ($invalidBase in @(
        @{ Name = 'missing'; Path = (Join-Path $defaultFixture 'missing') },
        @{ Name = 'non-directory'; Path = $protectedDefaultFile },
        @{ Name = 'relative'; Path = 'not-an-absolute-base' }
    )) {
        Test-That "a $($invalidBase.Name) default base fails before allocation" {
            try { $null = New-BridgeTestDefaultResultsDirectory -PlatformTempBase $invalidBase.Path; $false }
            catch { $_.Exception.Message -match 'platform default temporary base' }
        }
    }
    $brokenTarget = Join-Path $defaultFixture 'gone'
    [void][IO.Directory]::CreateDirectory($brokenTarget)
    $brokenAlias = Join-Path $defaultFixture 'broken'
    [void](New-Item -ItemType $defaultLinkType -Path $brokenAlias -Value $brokenTarget)
    [IO.Directory]::Delete($brokenTarget)
    Test-That 'a broken default-base alias fails instead of creating its missing target' {
        $refused = $false
        try { $null = New-BridgeTestDefaultResultsDirectory -PlatformTempBase $brokenAlias }
        catch { $refused = $_.Exception.Message -match 'platform default temporary base' }
        $refused -and -not (Test-Path -LiteralPath $brokenTarget)
    }
    $loopAlias = Join-Path $physicalBase 'l'
    [void](New-Item -ItemType $defaultLinkType -Path $loopAlias -Value $physicalBase)
    $overLimitBase = $physicalBase
    for ($hop = 0; $hop -lt 41; $hop++) { $overLimitBase = Join-Path $overLimitBase 'l' }
    Test-That 'real back-edge traversal is bounded before default results can be allocated' {
        try { $null = New-BridgeTestDefaultResultsDirectory -PlatformTempBase $overLimitBase; $false }
        catch { $_.Exception.Message -match 'exceeds 40 link resolutions' }
    }
    $protectedDefaultAfter = (Get-FileHash -LiteralPath $protectedDefaultFile -Algorithm SHA256).Hash
    Test-That 'default-base failures and nested links leave protected data unchanged' {
        $protectedDefaultAfter -ceq $protectedDefaultBefore -and
        @(Get-ChildItem -LiteralPath $protectedDefault -Force).Count -eq 1
    }
    $defaultRecord = [ordered]@{
        PlatformBase = $defaultAllocation.PlatformBase
        PhysicalBase = $defaultAllocation.PhysicalBase
        Directory = $defaultAllocation.Directory
        LinksResolved = $defaultAllocation.LinksResolved
        Sandbox = $defaultBox
        Child = $defaultObserved
        ProtectedBefore = $protectedDefaultBefore
        ProtectedAfter = $protectedDefaultAfter
        ExplicitResultAbsent = -not (Test-Path -LiteralPath (Join-Path $physicalBase 'explicit-refused'))
        NestedResultAbsent = -not (Test-Path -LiteralPath (Join-Path $protectedDefault 'escape'))
    }
    Write-Host ('S1-DEFAULT-TEMP-RESULT ' + ($defaultRecord | ConvertTo-Json -Depth 5 -Compress))
    [Console]::Out.Flush()

    Write-Host '--- nested constructor scopes use the verified boundary, not caller state ---'
    if ($script:Failures) { throw 'Earlier runner checks failed; constructor cases were not started.' }
    $constructorRoot = Join-Path $env:TEMP 'p6'
    Assert-BridgeTestPath -Path $constructorRoot
    if (Test-Path -LiteralPath $constructorRoot) { throw 'The constructor fixture already exists; nothing was overwritten.' }
    [void][IO.Directory]::CreateDirectory($constructorRoot)
    $outerMarker = Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT '.bridge-test-sandbox.json'
    $outerMarkerBefore = (Get-FileHash -LiteralPath $outerMarker -Algorithm SHA256).Hash
    $constructorFailures = $script:Failures
    $constructorChildren = 0
    try {
        $constructorBox = New-BridgeTestSandbox -ParentDirectory $constructorRoot
        $constructorBoundary = Get-BridgeTestSandbox -Root $constructorBox
        $constructorRepository = [string]$constructorBoundary['repository']
        $constructorContext = Join-Path $constructorRepository 'hooks\bridge-install-context.ps1'
        $misleadingRepository = $constructorRepository + '-outside'
        $scopeProbe = Join-Path $constructorRoot 'scope.ps1'
        @'
param([string]$Sandbox, [string]$Entry, [string[]]$EntryArguments,
    [ValidateSet('Absent', 'Misleading')][string]$Mode, [string]$CallerRepository)
Set-StrictMode -Version Latest
if ($Mode -eq 'Misleading') { $BridgeTestRepository = $CallerRepository }
$callerVariable = Get-Variable -Name BridgeTestRepository -Scope Script -ErrorAction SilentlyContinue
$boundary = Get-BridgeTestSandbox -Root $Sandbox
$start = New-BridgeTestProcessStartInfo -ScriptPath $Entry -Sandbox $Sandbox -ScriptArguments $EntryArguments
[pscustomobject]@{
    CallerPresent = ($null -ne $callerVariable)
    CallerValue = $(if ($callerVariable) { $callerVariable.Value } else { $null })
    Boundary = $boundary
    StartInfo = $start
}
'@ | Set-Content -LiteralPath $scopeProbe -Encoding utf8
        $sandboxEntry = Join-Path $constructorBox 'entry.ps1'
        @'
Assert-BridgeTestEnvironment -Required
$probeBoundary = Get-BridgeTestSandbox -Root $env:AGENT_HA_BRIDGE_TEST_ROOT
[ordered]@{
    Entry = $PSCommandPath
    WorkingDirectory = (Get-Location).Path
    Context = (Get-Command Get-BridgeTestSandbox).ScriptBlock.File
    Root = $probeBoundary['root']
    Repository = $probeBoundary['repository']
    Home = $HOME
    InputClosed = ($null -eq [Console]::ReadLine())
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $sandboxEntry -Encoding utf8
        foreach ($mode in 'Absent', 'Misleading') {
            foreach ($entryCase in @(
                @{ Name = 'source'; Path = $PSCommandPath; Arguments = @('ConstructorProbe') },
                @{ Name = 'sandbox'; Path = $sandboxEntry; Arguments = @() }
            )) {
                $caseName = "$mode caller / $($entryCase.Name) entry"
                $constructed = & $scopeProbe -Sandbox $constructorBox -Entry $entryCase.Path `
                    -EntryArguments $entryCase.Arguments -Mode $mode -CallerRepository $misleadingRepository
                $constructorStart = $constructed.StartInfo
                $bootstrap = [Text.Encoding]::Unicode.GetString(
                    [Convert]::FromBase64String($constructorStart.ArgumentList[4]))
                Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
                    Case = $caseName; Stage = 'constructed'
                    CallerPresent = $constructed.CallerPresent; CallerValue = $constructed.CallerValue
                    Boundary = $constructed.Boundary; Entry = $entryCase.Path
                    WorkingDirectory = $constructorStart.WorkingDirectory
                    Arguments = @($constructorStart.ArgumentList); Bootstrap = $bootstrap
                })
                Test-That "$caseName observes its actual caller scope and allocated boundary" {
                    $constructed.CallerPresent -eq ($mode -eq 'Misleading') -and
                    ($mode -eq 'Absent' -or $constructed.CallerValue -ceq $misleadingRepository) -and
                    (Test-BridgeInstallPath $constructed.Boundary['root'] $constructorBox) -and
                    (Test-BridgeInstallPath $constructed.Boundary['parent'] $constructorRoot) -and
                    (Test-BridgeInstallPath $constructed.Boundary['repository'] $constructorRepository)
                }
                Test-That "$caseName binds both source paths and preserves the fixed launch contract" {
                    (Test-BridgeInstallPath $constructorStart.WorkingDirectory $constructorRepository) -and
                    $bootstrap.Contains(". '" + $constructorContext.Replace("'", "''") + "'") -and
                    $constructorStart.ArgumentList.Count -eq 5 -and
                    (@($constructorStart.ArgumentList)[0..3] -join ',') -ceq '-NoLogo,-NoProfile,-NonInteractive,-EncodedCommand' -and
                    -not $constructorStart.UseShellExecute -and $constructorStart.CreateNoWindow -and
                    $constructorStart.RedirectStandardInput -and $constructorStart.RedirectStandardOutput -and
                    $constructorStart.RedirectStandardError -and
                    $constructorStart.StandardOutputEncoding.CodePage -eq 65001 -and
                    $constructorStart.StandardErrorEncoding.CodePage -eq 65001
                }
                if ($script:Failures -ne $constructorFailures) { throw "The $caseName construction failed; no child was started." }
                $constructorChildren++
                $constructorChild = Invoke-BridgeTestProcess -StartInfo $constructorStart
                Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
                    Kind = 'added'; Case = $caseName; Result = $constructorChild
                })
                Test-That "$caseName completes with bounded output and no timeout" {
                    $constructorChild.ExitCode -eq 0 -and -not $constructorChild.TimedOut -and
                    $constructorChild.Output.Length -le 16384
                } $constructorChild.Output
                if ($script:Failures -ne $constructorFailures) { throw "The $caseName child failed; stopping." }
                $constructorObserved = $constructorChild.Output | ConvertFrom-Json
                Test-That "$caseName runs the real entry with the verified context and closed input" {
                    ($entryCase.Name -ne 'source' -or $constructorObserved.RunnerEntryMode -ceq 'ConstructorProbe') -and
                    (Test-BridgeInstallPath $constructorObserved.Entry $entryCase.Path) -and
                    (Test-BridgeInstallPath $constructorObserved.WorkingDirectory $constructorRepository) -and
                    (Test-BridgeInstallPath $constructorObserved.Context $constructorContext) -and
                    (Test-BridgeInstallPath $constructorObserved.Repository $constructorRepository) -and
                    (Test-BridgeInstallPath $constructorObserved.Root $constructorBox) -and
                    (Test-BridgeInstallPath $constructorObserved.Home (Join-Path $constructorBox 'home')) -and
                    $constructorObserved.InputClosed
                }
                if ($script:Failures -ne $constructorFailures) { throw "The $caseName child evidence failed; stopping." }
            }
        }

        $badBox = New-BridgeTestSandbox -ParentDirectory $constructorRoot
        $badMarker = Join-Path $badBox '.bridge-test-sandbox.json'
        $originalMarker = [IO.File]::ReadAllBytes($badMarker)
        $originalMarkerHash = (Get-FileHash -LiteralPath $badMarker -Algorithm SHA256).Hash
        $syntheticSource = Join-Path $constructorRoot 'source'
        $protectedSource = Join-Path $constructorRoot 'protected'
        [void][IO.Directory]::CreateDirectory($syntheticSource)
        [void][IO.Directory]::CreateDirectory($protectedSource)
        Set-Content -LiteralPath (Join-Path $protectedSource 'entry.ps1') `
            -Value "throw 'A linked entry must never be read as a script or launched.'" -Encoding utf8
        $protectedBefore = Get-ProtectedFixtureSnapshot -HomeDirectory $protectedSource
        $repositoryLink = Join-Path $constructorRoot 'repository-link'
        $entryLink = Join-Path $syntheticSource 'linked'
        try {
            [void](New-Item -ItemType $defaultLinkType -Path $repositoryLink -Value $syntheticSource)
            [void](New-Item -ItemType $defaultLinkType -Path $entryLink -Value $protectedSource)
        }
        catch {
            Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
                Case = 'link support'; Stage = 'unexercised'; Error = $_.Exception.ToString()
            })
            throw
        }
        foreach ($markerCase in @(
            @{ Name = 'missing marker'; Change = 'missing'; Cause = 'Cannot find path|Could not find' },
            @{ Name = 'malformed marker'; Change = 'malformed'; Cause = 'JSON|ConvertFrom-Json' },
            @{ Name = 'oversized marker'; Change = 'oversized'; Cause = 'not a bounded runner record' },
            @{ Name = 'mismatched id'; Change = 'id'; Cause = 'identity does not describe' },
            @{ Name = 'mismatched root'; Change = 'root'; Cause = 'identity does not describe' },
            @{ Name = 'mismatched parent'; Change = 'parent'; Cause = 'identity does not describe' },
            @{ Name = 'mismatched home'; Change = 'home'; Cause = 'identity does not describe' },
            @{ Name = 'absent source repository'; Change = 'repository-missing'; Cause = 'source checkout is missing' },
            @{ Name = 'linked source repository'; Change = 'repository-linked'; Cause = 'linked installation payload' }
        )) {
            try {
                $changedMarker = [Text.Encoding]::UTF8.GetString($originalMarker) | ConvertFrom-Json -AsHashtable
                switch ($markerCase.Change) {
                    'missing' { Remove-Item -LiteralPath $badMarker -Force }
                    'malformed' { [IO.File]::WriteAllText($badMarker, '{broken') }
                    'oversized' { [IO.File]::WriteAllText($badMarker, (' ' * 16385)) }
                    'id' { $changedMarker['id'] = 'not-the-allocated-id' }
                    'root' { $changedMarker['root'] = Join-Path $badBox 'other-root' }
                    'parent' { $changedMarker['parent'] = Join-Path $constructorRoot 'other-parent' }
                    'home' { $changedMarker['home'] = Join-Path $badBox 'other-home' }
                    'repository-missing' { $changedMarker['repository'] = Join-Path $constructorRoot 'missing-source' }
                    'repository-linked' { $changedMarker['repository'] = $repositoryLink }
                }
                if ($markerCase.Change -notin @('missing', 'malformed', 'oversized')) {
                    $changedMarker | ConvertTo-Json | Set-Content -LiteralPath $badMarker -Encoding utf8
                }
                foreach ($operation in 'getter', 'constructor') {
                    $refusal = $null
                    $unexpected = $null
                    try {
                        $unexpected = if ($operation -eq 'getter') { Get-BridgeTestSandbox -Root $badBox }
                            else { New-BridgeTestProcessStartInfo -ScriptPath $sandboxEntry -Sandbox $badBox }
                    }
                    catch { $refusal = $_ }
                    Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
                        Case = $markerCase.Name; Stage = $operation; Sandbox = $badBox
                        MarkerBytes = $(if (Test-Path -LiteralPath $badMarker) { (Get-Item -LiteralPath $badMarker -Force).Length } else { $null })
                        MarkerSha256 = $(if (Test-Path -LiteralPath $badMarker) { (Get-FileHash -LiteralPath $badMarker -Algorithm SHA256).Hash } else { $null })
                        MarkerRaw = $(if (Test-Path -LiteralPath $badMarker) { [IO.File]::ReadAllText($badMarker) } else { $null })
                        ReturnedObject = ($null -ne $unexpected); ChildStarted = $false
                        Marked = ($null -ne $refusal -and $refusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true)
                        Error = $(if ($refusal) { $refusal.ToString() } else { $null })
                        Exception = $(if ($refusal) { $refusal.Exception.ToString() } else { $null })
                    })
                    Test-That "$($markerCase.Name) is rejected by the real $operation before launch" {
                        $null -eq $unexpected -and $null -ne $refusal -and
                        $refusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true -and
                        $refusal.Exception.ToString() -match $markerCase.Cause
                    }
                    if ($script:Failures -ne $constructorFailures) { throw "The $($markerCase.Name) $operation rejection failed; stopping." }
                }
            }
            finally { [IO.File]::WriteAllBytes($badMarker, $originalMarker) }
            Test-That "$($markerCase.Name) restores the nested marker before cleanup" {
                (Get-FileHash -LiteralPath $badMarker -Algorithm SHA256).Hash -ceq $originalMarkerHash
            }
            if ($script:Failures -ne $constructorFailures) { throw 'Nested marker restoration failed; stopping.' }
        }
        try {
            $sourceMarker = [Text.Encoding]::UTF8.GetString($originalMarker) | ConvertFrom-Json -AsHashtable
            $sourceMarker['repository'] = $syntheticSource
            $sourceMarker | ConvertTo-Json | Set-Content -LiteralPath $badMarker -Encoding utf8
            $nestedSourceBoundary = Get-BridgeTestSandbox -Root $badBox
            Test-That 'an existing unlinked nested source remains a legitimate boundary' {
                Test-BridgeInstallPath $nestedSourceBoundary['repository'] $syntheticSource
            }
            $linkedEntry = Join-Path $entryLink 'entry.ps1'
            $entryRefusal = $null
            try { $null = New-BridgeTestProcessStartInfo -ScriptPath $linkedEntry -Sandbox $badBox }
            catch { $entryRefusal = $_ }
            Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
                Case = 'linked source entry'; Stage = 'constructor'; Boundary = $nestedSourceBoundary
                Entry = $linkedEntry; ChildStarted = $false
                Marked = ($null -ne $entryRefusal -and $entryRefusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true)
                Exception = $(if ($entryRefusal) { $entryRefusal.Exception.ToString() } else { $null })
            })
            Test-That 'a linked source entry is rejected before its target can be launched' {
                $null -ne $entryRefusal -and $entryRefusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true -and
                $entryRefusal.Exception.ToString() -match 'linked installation payload'
            }
            if ($script:Failures -ne $constructorFailures) { throw 'The linked source entry evidence failed; stopping.' }
        }
        finally { [IO.File]::WriteAllBytes($badMarker, $originalMarker) }
        $forbiddenEntry = Join-Path $misleadingRepository 'entry.ps1'
        $outsideRefusal = $null
        try {
            $null = & $scopeProbe -Sandbox $constructorBox -Entry $forbiddenEntry `
                -EntryArguments @() -Mode Misleading -CallerRepository $misleadingRepository
        }
        catch { $outsideRefusal = $_ }
        Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
            Case = 'misleading caller cannot authorize an external entry'; Stage = 'constructor'
            Entry = $forbiddenEntry; CallerRepository = $misleadingRepository; Boundary = $constructorBoundary
            ChildStarted = $false
            Marked = ($null -ne $outsideRefusal -and $outsideRefusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true)
            Exception = $(if ($outsideRefusal) { $outsideRefusal.Exception.ToString() } else { $null })
        })
        Test-That 'a misleading caller cannot authorize an entry outside the active source and sandbox' {
            $null -ne $outsideRefusal -and $outsideRefusal.Exception.Data['BridgeTestWriteBlocked'] -eq $true -and
            $outsideRefusal.Exception.ToString() -match 'fixture destination escapes its allocated root'
        }
        $protectedAfter = Get-ProtectedFixtureSnapshot -HomeDirectory $protectedSource
        Write-BoundaryRecord -Prefix 'P6-CONSTRUCTOR' -Record ([ordered]@{
            Case = 'final containment'; Stage = 'restored'; AcceptedChildren = $constructorChildren
            ProtectedBefore = ($protectedBefore | ConvertFrom-Json); ProtectedAfter = ($protectedAfter | ConvertFrom-Json)
            OuterMarkerBefore = $outerMarkerBefore
            OuterMarkerAfter = (Get-FileHash -LiteralPath $outerMarker -Algorithm SHA256).Hash
            NestedMarkerBefore = $originalMarkerHash
            NestedMarkerAfter = (Get-FileHash -LiteralPath $badMarker -Algorithm SHA256).Hash
        })
        Test-That 'constructor negatives leave protected bytes, inventory and the outer marker unchanged' {
            $protectedAfter -ceq $protectedBefore -and
            (Get-FileHash -LiteralPath $outerMarker -Algorithm SHA256).Hash -ceq $outerMarkerBefore -and
            (Get-FileHash -LiteralPath $badMarker -Algorithm SHA256).Hash -ceq $originalMarkerHash
        }
        Test-That 'only the four accepted constructor entries started children' { $constructorChildren -eq 4 }
        if ($script:Failures -ne $constructorFailures) { throw 'The final constructor evidence failed; stopping.' }
    }
    finally {
        Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $constructorRoot
    }

    Write-Host '--- repository-wide inventory, including new components and nested suites ---'
    $inventoryRoot = Join-Path $scratch 'inventory'
    $inventoryManifest = @{
        Offline = @('tests\test-base.ps1')
        Host = @('tests\test-host.ps1')
        Platform = @('tests\test-platform.ps1')
        Integration = @('tests\test-integration.ps1')
    }
    function New-InventoryFile {
        param([string]$Relative)
        $fixturePath = Join-Path $inventoryRoot ($Relative.Replace('\', [IO.Path]::DirectorySeparatorChar))
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath))
        Set-Content -LiteralPath $fixturePath -Value "throw 'Inventory must not execute a suite.'"
        $fixturePath
    }
    function Save-InventoryManifest {
        $lines = @('@{')
        foreach ($category in 'Offline', 'Host', 'Platform', 'Integration') {
            $entries = @($inventoryManifest[$category] | ForEach-Object { "'$_'" }) -join ', '
            $lines += "    $category = @($entries)"
        }
        $lines += '}'
        $lines | Set-Content -LiteralPath (Join-Path (Join-Path $inventoryRoot 'tests') 'suites.psd1') -Encoding utf8
    }
    foreach ($category in $inventoryManifest.Keys) {
        foreach ($relative in $inventoryManifest[$category]) { [void](New-InventoryFile $relative) }
    }
    Save-InventoryManifest
    Test-That 'a synthetic inventory retains all four group distinctions without executing files' {
        $found = @(foreach ($category in 'Offline', 'Host', 'Platform', 'Integration') {
            Get-BridgeTestSuite -Repository $inventoryRoot -Group $category
        })
        $found.Count -eq 4 -and @($found.Group | Select-Object -Unique).Count -eq 4
    }
    foreach ($relative in @(
        'mcp\tests\test-foo.ps1', 'new-component\tests\nested\test-deep.ps1',
        'tests\nested\test-nested.ps1', 'test-root.ps1', '.component\test-hidden.ps1'
    )) {
        $fixturePath = New-InventoryFile $relative
        try {
            Test-That "$relative cannot disappear from classification" {
                try { Get-BridgeTestSuite -Repository $inventoryRoot; $false }
                catch {
                    $_.Exception.Message -match 'suite inventory differs' -and
                    $_.Exception.Message.Contains($relative)
                }
            }
        }
        finally { Remove-Item -LiteralPath $fixturePath -Force }
    }

    [void](New-InventoryFile 'mcp\tests\nested\test-component.ps1')
    $inventoryManifest.Offline += 'mcp/tests/nested/test-component.ps1'
    Save-InventoryManifest
    Test-That 'manifest and selectors normalize either separator to the same nested suite' {
        $forward = Get-BridgeTestSuite -Repository $inventoryRoot -Suite 'mcp/tests/nested/test-component.ps1'
        $backward = Get-BridgeTestSuite -Repository $inventoryRoot -Suite 'mcp\tests\nested\test-component.ps1'
        $forward.Suite -eq 'mcp\tests\nested\test-component.ps1' -and
        $forward.Path -eq $backward.Path -and (Test-Path -LiteralPath $forward.Path)
    }
    Test-That 'nested basenames select the same classified suite' {
        (Get-BridgeTestSuite -Repository $inventoryRoot -Suite 'test-component.ps1').Suite -eq
            'mcp\tests\nested\test-component.ps1'
    }
    $inventoryManifest.Host += 'mcp\tests\nested\test-component.ps1'
    Save-InventoryManifest
    Test-That 'different separator spellings cannot classify a suite twice' {
        try { Get-BridgeTestSuite -Repository $inventoryRoot; $false }
        catch { $_.Exception.Message -match 'Suite declared twice' }
    }
    $inventoryManifest.Offline = @('tests\test-base.ps1')
    Save-InventoryManifest
    Test-That 'a newly classified Host suite is still excluded from Offline' {
        @(Get-BridgeTestSuite -Repository $inventoryRoot).Count -eq 1 -and
        @(Get-BridgeTestSuite -Repository $inventoryRoot -Group Host).Count -eq 2
    }

    Write-Host '--- exclusions are pruned before traversal and cannot be declared executable ---'
    foreach ($excluded in @(
        '.git', 'node_modules', 'vendor', '.venv', 'venv',
        'fixtures', '__fixtures__', 'test-results', 'TestResults', 'coverage', 'dist'
    )) {
        [void](New-InventoryFile "$excluded\deep\test-excluded.ps1")
        [void](New-InventoryFile "component\$excluded\deep\test-excluded.ps1")
        Test-That "$excluded is excluded at the root and inside a component" {
            @(Get-BridgeTestSuite -Repository $inventoryRoot).Count -eq 1
        }
    }
    [void](New-InventoryFile 'custom-output\sandbox\test-generated.ps1')
    Set-Content -LiteralPath (Join-Path (Join-Path $inventoryRoot 'custom-output') '.bridge-test-results') -Value ''
    Test-That 'runner-marked results are excluded regardless of the chosen directory name' {
        @(Get-BridgeTestSuite -Repository $inventoryRoot).Count -eq 1
    }
    $inventoryManifest.Offline += 'component\fixtures\deep\test-excluded.ps1'
    Save-InventoryManifest
    Test-That 'declaring an excluded fixture does not make it executable' {
        try { Get-BridgeTestSuite -Repository $inventoryRoot; $false }
        catch { $_.Exception.Message -match 'suite inventory differs' }
    }
    $inventoryManifest.Offline = @('tests\test-base.ps1', '..\test-escape.ps1')
    Save-InventoryManifest
    Test-That 'manifest paths cannot escape the repository' {
        try { Get-BridgeTestSuite -Repository $inventoryRoot; $false }
        catch { $_.Exception.Message -match 'canonical repository-relative' }
    }
    $inventoryManifest.Offline = @('tests\test-base.ps1')
    Save-InventoryManifest

    $externalRoot = Join-Path $scratch 'external-suites'
    [void][IO.Directory]::CreateDirectory($externalRoot)
    Set-Content -LiteralPath (Join-Path $externalRoot 'test-external.ps1') -Value "throw 'External suite must not run.'"
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    foreach ($link in @(
        @{ Path = (Join-Path $inventoryRoot 'linked-component'); Target = $externalRoot },
        @{ Path = (Join-Path (Join-Path $inventoryRoot 'component') 'cycle'); Target = $inventoryRoot }
    )) {
        [void](New-Item -ItemType $linkType -Path $link.Path -Value $link.Target)
        $inventoryLinks += $link.Path
    }
    Test-That 'external directory links and cycles are not traversed' {
        @(Get-BridgeTestSuite -Repository $inventoryRoot).Count -eq 1
    }
    Test-That 'a linked directory cannot itself be a suite repository' {
        try { Get-BridgeTestSuite -Repository $inventoryLinks[0]; $false }
        catch { $_.Exception.Message -match 'not a symbolic link or junction' }
    }
    $inventoryManifest.Offline += 'linked-component\test-external.ps1'
    Save-InventoryManifest
    Test-That 'a manifest cannot opt an external linked suite into execution' {
        try { Get-BridgeTestSuite -Repository $inventoryRoot; $false }
        catch { $_.Exception.Message -match 'suite inventory differs' }
    }

    Write-Host '--- private roots and no inherited credentials, including descendants ---'
    foreach ($key in $poison.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $poison[$key], 'Process')
    }
    $box = New-BridgeTestSandbox -ParentDirectory $scratch
    $sandboxes += $box
    $probe = Join-Path $scratch "probe ' utf8.ps1"
    $probeText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. '__COMMON__'
$text = 'one' + [char]0xb7 + 'two'
$roundTrip = $text | & node -e "process.stdout.write(require('fs').readFileSync(0, 'utf8').trim())"
if ($LASTEXITCODE) { throw 'Node encoding probe failed.' }
$descendant = & pwsh -NoProfile -NonInteractive -Command '@{ Home = $HOME; Temp = [IO.Path]::GetTempPath(); Config = $env:AGENT_HA_BRIDGE_CONFIG; Offline = $env:AGENT_HA_BRIDGE_OFFLINE_TEST; Leaked = [bool]$env:CUSTOM_HOUSE_CREDENTIAL } | ConvertTo-Json -Compress'
if ($LASTEXITCODE) { throw 'Descendant probe failed.' }
[ordered]@{
    Home = $HOME
    Temp = [IO.Path]::GetTempPath()
    Config = $env:AGENT_HA_BRIDGE_CONFIG
    BaseUrl = $script:DecisionBridgeConfig.HomeAssistantBaseUrl
    Token = $script:DecisionBridgeConfig.HomeAssistantToken
    AppData = $env:APPDATA
    LocalAppData = $env:LOCALAPPDATA
    Public = $env:PUBLIC
    Claude = $env:CLAUDE_CONFIG_DIR
    Codex = $env:CODEX_HOME
    Copilot = $env:COPILOT_HOME
    Xdg = $env:XDG_CONFIG_HOME
    GitConfig = $env:GIT_CONFIG_GLOBAL
    Leaked = @(Get-ChildItem Env: | Where-Object Name -in @(
        'AGENT_HA_TOKEN', 'AGENT_HA_AGENT_TOKEN', 'CUSTOM_HOUSE_CREDENTIAL', 'BRIDGE_ALLOW_TEST_HTTP',
        'COPILOT_HA_BRIDGE_CONFIG', 'HTTPS_PROXY', 'NODE_OPTIONS', 'GIT_CONFIG_COUNT',
        'AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN'
    ) | ForEach-Object Name)
    ConsoleInput = [Console]::InputEncoding.CodePage
    ConsoleOutput = [Console]::OutputEncoding.CodePage
    Pipeline = $OutputEncoding.CodePage
    RoundTrip = $roundTrip
    Child = ($descendant | ConvertFrom-Json)
} | ConvertTo-Json -Depth 5 -Compress
'@
    $commonPath = Join-Path (Join-Path $script:BridgeTestRepository 'hooks') 'decision-bridge-common.ps1'
    $probeText.Replace('__COMMON__', $commonPath.Replace("'", "''")) | Set-Content -LiteralPath $probe -Encoding utf8
    $start = New-BridgeTestProcessStartInfo -ScriptPath $probe -Sandbox $box
    $result = Invoke-BridgeTestProcess -StartInfo $start
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'private-environment'; Result = $result
    })
    Test-That 'the isolated child completes' { $result.ExitCode -eq 0 -and -not $result.TimedOut } $result.Output
    if ($result.ExitCode -ne 0 -or $result.TimedOut) { throw 'The initial isolated fixture failed; stopping.' }
    if ($result.ExitCode -eq 0) {
        $observed = $result.Output | ConvertFrom-Json
        Test-That 'HOME is the suite home, not the caller home' {
            $observed.Home -eq (Join-Path $box 'home') -and $observed.Home -ne $HOME
        }
        Test-That '.NET temporary files are inside the private TEMP' {
            $observed.Temp.TrimEnd('\', '/') -eq (Join-Path $box 'temp')
        }
        foreach ($property in 'Config', 'AppData', 'LocalAppData', 'Public', 'Claude', 'Codex', 'Copilot', 'Xdg', 'GitConfig') {
            Test-That "$property is inside the suite sandbox" {
                $observed.$property.StartsWith($box + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            }
        }
        Test-That 'the checkout loads only synthetic loopback configuration' {
            $observed.BaseUrl -eq 'http://127.0.0.1:1' -and $observed.Token -eq 'synthetic-test-token'
        }
        Test-That 'known and arbitrarily named credentials and launch overrides are absent' { @($observed.Leaked).Count -eq 0 }
        Test-That 'child PowerShell inherits the same private roots and guard, not credentials' {
            $observed.Child.Home -eq $observed.Home -and $observed.Child.Temp -eq $observed.Temp -and
            $observed.Child.Config -eq $observed.Config -and $observed.Child.Offline -eq '1' -and -not $observed.Child.Leaked
        }
        Test-That 'redirected console input, output and pipelines are explicitly UTF-8' {
            $observed.ConsoleInput -eq 65001 -and $observed.ConsoleOutput -eq 65001 -and $observed.Pipeline -eq 65001
        }
        Test-That 'a middle dot survives the redirected PowerShell to Node round trip' {
            $observed.RoundTrip -ceq ('one' + [char]0xb7 + 'two')
        }
    }
    Test-That 'building a child environment leaves the caller environment untouched' {
        $env:CUSTOM_HOUSE_CREDENTIAL -eq $poison.CUSTOM_HOUSE_CREDENTIAL -and $env:BRIDGE_ALLOW_TEST_HTTP -eq '1'
    }
    $secondBox = New-BridgeTestSandbox -ParentDirectory $scratch
    $sandboxes += $secondBox
    Test-That 'two suites never share a home or temporary directory' {
        $other = New-BridgeTestProcessStartInfo -ScriptPath $probe -Sandbox $secondBox
        $other.Environment['HOME'] -ne $start.Environment['HOME'] -and $other.Environment['TEMP'] -ne $start.Environment['TEMP']
    }


    Write-Host '--- checkout code wins even when an installed copy exists ---'
    $installedHooks = Join-Path (Join-Path (Join-Path $box 'home') '.agent-ha-bridge') 'hooks'
    [void][IO.Directory]::CreateDirectory($installedHooks)
    Set-Content -LiteralPath (Join-Path $installedHooks 'decision-bridge-common.ps1') -Value "throw 'Installed code must not be loaded.'"
    $codexPath = (Get-BridgeTestSuite -Suite 'test-codex.ps1').Path
    $codexResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $codexPath -Sandbox $box)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'codex-source'; Result = $codexResult
    })
    Test-That 'Codex tests ignore an installed shared helper' { $codexResult.ExitCode -eq 0 } $codexResult.Output

    Write-Host '--- a subprocess cannot opt an offline run into real traffic ---'
    $guardProbe = Join-Path $scratch 'guard-probe.ps1'
    $guardText = @'
. '__COMMON__'
. '__WEBSOCKET__'
if ($script:BridgeUnderTestSuite) { throw 'Probe must run outside the tests call stack.' }
$env:BRIDGE_ALLOW_TEST_HTTP = '1'
$blocked = 0
foreach ($call in @(
    { Invoke-DecisionHttpRequest -Parameters @{ Uri = 'http://127.0.0.1:1/api/'; TimeoutSec = 1 } -RetryCount 0 },
    { Test-HomeAssistantReachable -TimeoutSec 1 },
    { Invoke-CopilotHaWebSocket -Commands @(@{ type = 'get_states' }) -TimeoutSeconds 1 },
    { Wait-CopilotHaStateChange -EntityIds @('sensor.test') -TimeoutSeconds 1 }
)) {
    try { & $call }
    catch {
        if ($_.Exception.Message -notmatch 'tried to reach a real Home Assistant') { throw }
        $blocked++
    }
}
if ($blocked -ne 4 -or $script:BridgeBlockedHttpCalls -ne 4) { throw "Expected four guarded calls, got $blocked." }
Write-Output 'all child transports blocked'
'@
    $websocketPath = Join-Path (Join-Path $script:BridgeTestRepository 'hooks') 'decision-ha-websocket.ps1'
    $guardText.Replace('__COMMON__', $commonPath.Replace("'", "''")).Replace('__WEBSOCKET__', $websocketPath.Replace("'", "''")) |
        Set-Content -LiteralPath $guardProbe -Encoding utf8
    $guardResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $guardProbe -Sandbox $secondBox)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'offline-transports'; Result = $guardResult
    })
    Test-That 'HTTP, reachability and both WebSocket paths refuse traffic in a child' {
        $guardResult.ExitCode -eq 0 -and $guardResult.Output -match 'all child transports blocked'
    } $guardResult.Output

    Write-Host '--- unsafe groups also reject direct execution in an offline child ---'
    foreach ($group in 'Host', 'Platform', 'Integration') {
        foreach ($entry in @(Get-BridgeTestSuite -Group $group)) {
            $refused = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $entry.Path -Sandbox $secondBox)
            Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
                Kind = 'baseline'; Case = $entry.Suite; Group = $group; Result = $refused
            })
            Test-That "$($entry.Suite) fails before loading a live installation" {
                $refused.ExitCode -ne 0 -and $refused.Output -match 'disposable'
            } $refused.Output
        }
    }

    Write-Host '--- installer test namespaces agree without executing an install ---'
    $registryProbe = Join-Path $scratch 'registry-probe.ps1'
    $registryText = @'
$env:BRIDGE_INSTALL_NORUN = '1'
$env:BRIDGE_UNINSTALL_NORUN = '1'
function Get-TestKeys {
    param([string]$Entry, [string]$Namespace, [switch]$Sandboxed)
    $parameters = @{}
    if ($Namespace) { $parameters.TestRegistryId = $Namespace }
    if ($Sandboxed) { $parameters.TargetHome = $env:HOME }
    . (Join-Path '__REPOSITORY__' $Entry) @parameters
    [pscustomobject]@{ Current = $arpKey; Legacy = $legacyArpKey }
}
$firstId = [guid]::NewGuid().ToString('N')
$secondId = [guid]::NewGuid().ToString('N')
foreach ($entry in 'install.ps1', 'uninstall.ps1') {
    $normal = Get-TestKeys -Entry $entry
    if ($normal.Current -notmatch '\\AgentHaBridge$' -or $normal.Legacy -notmatch '\\CopilotHaBridge$') { throw 'Normal registry identity changed.' }
    $first = Get-TestKeys -Entry $entry -Namespace $firstId -Sandboxed
    $second = Get-TestKeys -Entry $entry -Namespace $secondId -Sandboxed
    if ($first.Current -ne ($normal.Current + "_Sandbox_$firstId") -or $first.Legacy -ne ($normal.Legacy + "_Sandbox_$firstId")) { throw 'Incorrect test namespace.' }
    if ($first.Current -eq $second.Current -or $first.Legacy -eq $second.Legacy) { throw 'Test namespaces collided.' }
    $refused = $false
    try { Get-TestKeys -Entry $entry -Namespace $firstId }
    catch { $refused = $_.Exception.Message -match 'requires -TargetHome' }
    if (-not $refused) { throw 'A test namespace was accepted without TargetHome.' }
    $refused = $false
    try { Get-TestKeys -Entry $entry -Namespace '..\shared' -Sandboxed }
    catch { $refused = $_.Exception.Message -match 'pattern' }
    if (-not $refused) { throw 'An invalid registry namespace was accepted.' }
}
Write-Output 'isolated registry names verified without registry writes'
'@
    $registryText.Replace('__REPOSITORY__', $script:BridgeTestRepository.Replace("'", "''")) |
        Set-Content -LiteralPath $registryProbe -Encoding utf8
    $registryResult = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $registryProbe -Sandbox $secondBox)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'registry-names-only'; Result = $registryResult
    })
    Test-That 'install and uninstall preserve normal names and require unique, constrained test names' {
        $registryResult.ExitCode -eq 0 -and $registryResult.Output -match 'without registry writes'
    } $registryResult.Output

    Write-Host '--- failures and timeouts cannot become a green result ---'
    $failureProbe = Join-Path $scratch 'failure.ps1'
    Set-Content -LiteralPath $failureProbe -Value "Write-Output 'failure-output'; exit 23"
    $failure = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $failureProbe -Sandbox $secondBox)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'native-exit-23'; Result = $failure
    })
    Test-That 'the original nonzero exit code and output are preserved' {
        $failure.ExitCode -eq 23 -and $failure.Output -match 'failure-output' -and -not $failure.TimedOut
    } $failure.Output
    Set-Content -LiteralPath $failureProbe -Value "throw 'intentional runner regression failure'"
    $failure = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $failureProbe -Sandbox $secondBox)
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'uncaught-exception'; Result = $failure
    })
    Test-That 'an uncaught exception also fails and keeps its diagnostics' {
        $failure.ExitCode -ne 0 -and $failure.Output -match 'intentional runner regression failure'
    } $failure.Output

    $timeoutProbe = Join-Path $scratch 'timeout.ps1'
    @'
$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60' -NoNewWindow -PassThru
@{ Id = $child.Id; Started = $child.StartTime.ToUniversalTime().Ticks } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $env:AGENT_HA_BRIDGE_TEST_ROOT 'child.json')
Start-Sleep -Seconds 60
'@ | Set-Content -LiteralPath $timeoutProbe -Encoding utf8
    $timeout = Invoke-BridgeTestProcess -StartInfo (New-BridgeTestProcessStartInfo -ScriptPath $timeoutProbe -Sandbox $secondBox) -TimeoutSeconds 5
    Write-BoundaryRecord -Prefix 'P6-RUNNER-CHILD' -Record ([ordered]@{
        Kind = 'baseline'; Case = 'owned-timeout'; Result = $timeout
    })
    Test-That 'a timeout is reported within the bounded wait' { $timeout.TimedOut -and $timeout.Seconds -lt 15 }
    $childInfo = Get-Content -LiteralPath (Join-Path $secondBox 'child.json') -Raw | ConvertFrom-Json
    Test-That 'timing out kills the owned descendant as well as the suite' {
        $childProcess = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
        if (-not $childProcess -or $childProcess.StartTime.ToUniversalTime().Ticks -ne $childInfo.Started) { return $true }
        try { $childProcess.WaitForExit(5000) } finally { $childProcess.Dispose() }
    }
}
finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    foreach ($linkPath in $inventoryLinks) { Remove-Item -LiteralPath $linkPath -Force }
    foreach ($box in $sandboxes) {
        $pidFile = Join-Path $box 'child.json'
        if (Test-Path -LiteralPath $pidFile) {
            $childInfo = Get-Content -LiteralPath $pidFile -Raw | ConvertFrom-Json
            $ownedProcess = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
            if ($ownedProcess) {
                try {
                    if ($ownedProcess.StartTime.ToUniversalTime().Ticks -eq $childInfo.Started) {
                        Stop-Process -Id $ownedProcess.Id -Force
                        [void]$ownedProcess.WaitForExit(5000)
                    }
                }
                finally { $ownedProcess.Dispose() }
            }
        }
    }
    Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $scratch
    if ($defaultFixtureCreated) {
        Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $defaultFixture
    }
}
Test-That 'default temporary-base fixtures are removed through the owned sandbox cleanup' {
    -not (Test-Path -LiteralPath $defaultFixture)
}
if ($script:Failures) { throw "$script:Failures runner check(s) failed." }
Write-Host 'All runner checks passed'
exit 0
