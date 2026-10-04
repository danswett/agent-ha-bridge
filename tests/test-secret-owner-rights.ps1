#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runner-support.ps1')
Assert-BridgeTestEnvironment -Required
. (Join-Path $PSScriptRoot '..\hooks\bridge-platform.ps1')
. (Join-Path $PSScriptRoot '..\hooks\bridge-secrets.ps1')

if (-not $IsWindows) {
    Write-Host 'SKIP Windows owner-rights matrix: no rights cases were run on this platform.'
    exit 0
}

$script:Failures = 0
$script:OwnerRightsAssertions = 0
function Test-That {
    param([string]$Name, [scriptblock]$Condition)
    $script:OwnerRightsAssertions++
    # Only ordinary false assertions accumulate for the baseline comparison.
    # Unexpected exceptions and containment violations must still stop the matrix.
    if ([bool](& $Condition)) { Write-Host "  PASS  $Name" }
    else {
        Write-Host "  FAIL  $Name"
        $script:Failures++
    }
}

$credentialRoot = Join-Path $env:TEMP ("bridge credentials ' " + [char]0x96EA + '-' + [guid]::NewGuid().ToString('N'))
Assert-BridgeTestPath -Path $credentialRoot
[void][IO.Directory]::CreateDirectory($credentialRoot)
try {
    Write-Host '--- an owned DACL repair does not require an owner rewrite ---'

    function Get-OwnerRightsFixtureState {
        param([string]$Path)
        Assert-BridgeTestPath -Path $Path
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $descriptor = [IO.FileSystemAclExtensions]::GetAccessControl(
            $item, [Security.AccessControl.AccessControlSections]'Access, Owner')
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rules = @($descriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $ownerMatches = $descriptor.GetOwner([Security.Principal.SecurityIdentifier]) -eq $currentUser
        $singleAllow = $rules.Count -eq 1 -and $rules[0].IdentityReference -eq $currentUser -and
            $rules[0].AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
        $inheritance = if ($item.PSIsContainer) {
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else { [Security.AccessControl.InheritanceFlags]::None }
        $flagsMatch = $singleAllow -and $rules[0].InheritanceFlags -eq $inheritance -and
            $rules[0].PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None
        $rights = if ($rules.Count -eq 1) { [long]$rules[0].FileSystemRights } else { $null }
        $exactBase = $ownerMatches -and $descriptor.AreAccessRulesProtected -and $flagsMatch -and -not $rules[0].IsInherited
        $modify = [long]([Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::Synchronize)
        [pscustomobject]@{
            Path = $Path; IsDirectory = $item.PSIsContainer; OwnerMatchesCurrentUser = $ownerMatches
            AccessRulesProtected = $descriptor.AreAccessRulesProtected; RuleCount = $rules.Count
            SingleCurrentUserAllow = $singleAllow; Rights = $rights; InheritanceMatches = $flagsMatch
            RuleInherited = $(if ($rules.Count -eq 1) { $rules[0].IsInherited } else { $null })
            ExactModifyDacl = $exactBase -and $rights -eq $modify
            ExactPrivateDacl = $exactBase -and $rights -eq [long][Security.AccessControl.FileSystemRights]::FullControl
        }
    }

    function Set-OwnerRightsFixtureModifyDacl {
        param([string]$Path)
        $before = Get-OwnerRightsFixtureState -Path $Path
        if (-not $before.OwnerMatchesCurrentUser) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the synthetic target is not already current-user-owned; no ownership change was attempted.'
        }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $descriptor = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]::Access)
        $descriptor.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($descriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            $descriptor.RemoveAccessRuleAll($rule)
        }
        $inheritance = if ($item.PSIsContainer) {
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else { [Security.AccessControl.InheritanceFlags]::None }
        $descriptor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            [Security.AccessControl.FileSystemRights]::Modify, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        # Access-only setup never asks to change an owner or creates a deny ACE.
        [IO.FileSystemAclExtensions]::SetAccessControl($item, $descriptor)
        $after = Get-OwnerRightsFixtureState -Path $Path
        if (-not $after.ExactModifyDacl) { throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the actual owner/Modify-only DACL shape differs.' }
        $after
    }

    function Assert-OwnerRightsErrorNotGuard {
        param([Management.Automation.ErrorRecord]$ErrorRecord)
        $exception = $ErrorRecord.Exception
        while ($null -ne $exception) {
            if ($exception.Data['BridgeTestWriteBlocked'] -or $exception.Data['BridgeTestNetworkBlocked']) {
                throw $ErrorRecord
            }
            $exception = $exception.InnerException
        }
    }

    $ownerRightsRoot = Join-Path $credentialRoot 'owner-rights'
    Assert-BridgeTestPath -Path $ownerRightsRoot
    [void][IO.Directory]::CreateDirectory($ownerRightsRoot)
    $ownerRightsControls = @{}
    foreach ($ownerRightsKind in @('directory', 'file')) {
        $ownerRightsControl = Join-Path $ownerRightsRoot "$ownerRightsKind-control"
        $ownerRightsTarget = Join-Path $ownerRightsRoot "$ownerRightsKind-target"
        Assert-BridgeTestPath -Path @($ownerRightsControl, $ownerRightsTarget)
        if ($ownerRightsKind -eq 'directory') {
            [void][IO.Directory]::CreateDirectory($ownerRightsControl)
            [void][IO.Directory]::CreateDirectory($ownerRightsTarget)
            $ownerRightsBytesPath = Join-Path $ownerRightsTarget 'existing.bin'
        }
        else {
            [IO.File]::WriteAllBytes($ownerRightsControl, [byte[]](0, 1, 2, 127, 255))
            $ownerRightsBytesPath = $ownerRightsTarget
        }
        Assert-BridgeTestPath -Path $ownerRightsBytesPath
        [IO.File]::WriteAllBytes($ownerRightsBytesPath, [byte[]](0, 1, 2, 127, 255))
        $ownerRightsControlBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsControl
        $ownerRightsTargetBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsTarget
        $ownerRightsDescriptor = [IO.FileSystemAclExtensions]::GetAccessControl(
            (Get-Item -LiteralPath $ownerRightsControl -Force), [Security.AccessControl.AccessControlSections]::Owner)
        $ownerRightsSameOwner = $ownerRightsDescriptor.GetOwner([Security.Principal.SecurityIdentifier])
        if ($ownerRightsSameOwner -ne [Security.Principal.WindowsIdentity]::GetCurrent().User) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the control owner changed before the same-owner write.'
        }
        $ownerRightsDescriptor.SetOwner($ownerRightsSameOwner)
        $ownerRightsDenial = $null
        try {
            [IO.FileSystemAclExtensions]::SetAccessControl(
                (Get-Item -LiteralPath $ownerRightsControl -Force), $ownerRightsDescriptor)
        }
        catch {
            $ownerRightsControlError = $_
            Assert-OwnerRightsErrorNotGuard -ErrorRecord $ownerRightsControlError
            $ownerRightsDenial = $ownerRightsControlError.Exception.GetBaseException()
            if ($ownerRightsDenial.GetType() -ne [UnauthorizedAccessException] -or $ownerRightsDenial.HResult -ne -2147024891) {
                Write-Host ('OWNER_RIGHTS_CONTROL ' + (@{
                    kind = $ownerRightsKind; outcome = 'unexpected-error'
                    type = $ownerRightsDenial.GetType().FullName; hresult = $ownerRightsDenial.HResult
                    message = $ownerRightsDenial.Message
                } | ConvertTo-Json -Compress))
                throw
            }
        }
        if ($null -eq $ownerRightsDenial) {
            Write-Host "OWNER_RIGHTS_CONTROL $ownerRightsKind unexpectedly succeeded; the intended rights asymmetry is not established."
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: same-owner Owner-only persistence succeeded; no helper comparison is valid.'
        }
        $ownerRightsControlAfter = Get-OwnerRightsFixtureState -Path $ownerRightsControl
        if (-not $ownerRightsControlAfter.ExactModifyDacl) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the denied owner-only control changed its actual owner/DACL shape.'
        }
        $ownerRightsControls[$ownerRightsKind] = [pscustomobject]@{
            Kind = $ownerRightsKind
            Outcome = 'owner-only-denied'; Before = $ownerRightsControlBefore; After = $ownerRightsControlAfter
            ExceptionType = $ownerRightsDenial.GetType().FullName; HResult = $ownerRightsDenial.HResult
        }
        Write-Host ('OWNER_RIGHTS_CONTROL ' + ($ownerRightsControls[$ownerRightsKind] | ConvertTo-Json -Depth 5 -Compress))
        Test-That "the $ownerRightsKind control really denies a same-owner Owner-only write" {
            $ownerRightsControls[$ownerRightsKind].Outcome -eq 'owner-only-denied' -and $ownerRightsControlAfter.ExactModifyDacl
        }

        $ownerRightsProtected = Protect-BridgeSecretFile -Path $ownerRightsTarget
        if ($ownerRightsProtected -isnot [bool]) { throw 'The real protector returned something other than its scalar Boolean.' }
        $ownerRightsAfter = Get-OwnerRightsFixtureState -Path $ownerRightsTarget
        $ownerRightsVerified = Test-BridgeSecretFileProtected -Path $ownerRightsTarget
        $ownerRightsRepeated = if ($ownerRightsProtected) { Protect-BridgeSecretFile -Path $ownerRightsTarget } else { $null }
        $ownerRightsRepeatState = Get-OwnerRightsFixtureState -Path $ownerRightsTarget
        $ownerRightsBytesKept = ([IO.File]::ReadAllBytes($ownerRightsBytesPath) -join ',') -ceq '0,1,2,127,255'
        Write-Host ('OWNER_RIGHTS_PROTECT ' + (@{
            kind = $ownerRightsKind; before = $ownerRightsTargetBefore; returned = $ownerRightsProtected
            after = $ownerRightsAfter; finalVerifier = $ownerRightsVerified
            repeatAttempted = $ownerRightsProtected; repeated = $ownerRightsRepeated
            repeatState = $ownerRightsRepeatState; originalBytesPreserved = $ownerRightsBytesKept
        } | ConvertTo-Json -Depth 5 -Compress))
        Test-That "the real protector hardens an owned Modify-only $ownerRightsKind without changing its owner or bytes" {
            $ownerRightsProtected -and $ownerRightsAfter.ExactPrivateDacl -and $ownerRightsVerified -and $ownerRightsBytesKept
        }
        Test-That "repeating protection keeps the exact private $ownerRightsKind result" {
            $ownerRightsRepeated -eq $true -and $ownerRightsRepeatState.ExactPrivateDacl -and $ownerRightsBytesKept
        }
        if ($ownerRightsKind -eq 'directory') {
            $ownerRightsChildState = $null
            if ($ownerRightsProtected) {
                $ownerRightsChild = Join-Path $ownerRightsTarget 'inherited.bin'
                Assert-BridgeTestPath -Path $ownerRightsChild
                [IO.File]::WriteAllBytes($ownerRightsChild, [byte[]](9, 8, 7))
                $ownerRightsChildState = Get-OwnerRightsFixtureState -Path $ownerRightsChild
            }
            Write-Host ('OWNER_RIGHTS_INHERITANCE ' + (@{ attempted = $ownerRightsProtected; child = $ownerRightsChildState } | ConvertTo-Json -Depth 4 -Compress))
            Test-That 'the protected directory actually passes only current-user FullControl to a new child' {
                $null -ne $ownerRightsChildState -and $ownerRightsChildState.OwnerMatchesCurrentUser -and
                    $ownerRightsChildState.SingleCurrentUserAllow -and $ownerRightsChildState.InheritanceMatches -and
                    $ownerRightsChildState.RuleInherited -eq $true -and
                    $ownerRightsChildState.Rights -eq [long][Security.AccessControl.FileSystemRights]::FullControl
            }
        }
    }

    foreach ($ownerRightsWriterKind in @('existing-file', 'new-directory')) {
        if ($ownerRightsWriterKind -eq 'existing-file') {
            $ownerRightsWriterPath = Join-Path $ownerRightsRoot 'writer-existing.json'
            Assert-BridgeTestPath -Path $ownerRightsWriterPath
            [IO.File]::WriteAllText($ownerRightsWriterPath, 'synthetic-original-bytes')
            $ownerRightsWriterBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsWriterPath
            $ownerRightsWriterControl = $ownerRightsControls['file']
        }
        else {
            $ownerRightsWriterParent = Join-Path $ownerRightsRoot 'writer-parent'
            Assert-BridgeTestPath -Path $ownerRightsWriterParent
            [void][IO.Directory]::CreateDirectory($ownerRightsWriterParent)
            $ownerRightsWriterBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsWriterParent
            $ownerRightsWriterPath = Join-Path $ownerRightsWriterParent 'new\config.json'
            Assert-BridgeTestPath -Path $ownerRightsWriterPath
            $ownerRightsWriterControl = $ownerRightsControls['directory']
        }
        $ownerRightsWriterError = $null
        try { Write-BridgeSecretFile -Path $ownerRightsWriterPath -Content 'synthetic-written-by-real-writer' }
        catch {
            $ownerRightsWriterError = $_
            Assert-OwnerRightsErrorNotGuard -ErrorRecord $ownerRightsWriterError
        }
        $ownerRightsWriterAfter = $null
        $ownerRightsWriterBytes = $null
        $ownerRightsWriterVerified = $false
        if (Test-Path -LiteralPath $ownerRightsWriterPath -PathType Leaf) {
            $ownerRightsWriterAfter = Get-OwnerRightsFixtureState -Path $ownerRightsWriterPath
            $ownerRightsWriterBytes = [IO.File]::ReadAllText($ownerRightsWriterPath)
            $ownerRightsWriterVerified = Test-BridgeSecretFileProtected -Path $ownerRightsWriterPath
        }
        if ($ownerRightsWriterError -and
            (($ownerRightsWriterKind -eq 'existing-file' -and $ownerRightsWriterBytes -cne 'synthetic-original-bytes') -or
             ($ownerRightsWriterKind -eq 'new-directory' -and -not [string]::IsNullOrEmpty($ownerRightsWriterBytes)))) {
            throw 'OWNER_RIGHTS_WRITER: a refused real write changed or exposed credential bytes.'
        }
        Write-Host ('OWNER_RIGHTS_WRITER ' + (@{
            kind = $ownerRightsWriterKind; ownerControl = $ownerRightsWriterControl.Outcome; before = $ownerRightsWriterBefore
            error = $(if ($ownerRightsWriterError) { $ownerRightsWriterError.Exception.ToString() } else { $null })
            after = $ownerRightsWriterAfter; finalVerifier = $ownerRightsWriterVerified
            requestedBytesWritten = ($ownerRightsWriterBytes -ceq 'synthetic-written-by-real-writer')
            originalBytesPreserved = ($ownerRightsWriterBytes -ceq 'synthetic-original-bytes')
        } | ConvertTo-Json -Depth 5 -Compress))
        Test-That "the real writer protects the $ownerRightsWriterKind case under an owned Modify-only boundary" {
            $null -eq $ownerRightsWriterError -and $null -ne $ownerRightsWriterAfter -and
                $ownerRightsWriterAfter.ExactPrivateDacl -and $ownerRightsWriterVerified -and
                $ownerRightsWriterBytes -ceq 'synthetic-written-by-real-writer'
        }
    }
}
finally {
    Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $credentialRoot
}

if ($script:OwnerRightsAssertions -ne 9) {
    throw "The owner-rights matrix did not attempt all nine assertions: $($script:OwnerRightsAssertions)."
}
Write-Host ('OWNER_RIGHTS_MATRIX_COMPLETE ' + (@{
    matrixCompleted = $true
    assertionsAttempted = $script:OwnerRightsAssertions
    assertionsPassed = $script:OwnerRightsAssertions - $script:Failures
    assertionsFailed = $script:Failures
    allAssertionsPassed = ($script:Failures -eq 0)
    cleanupCompleted = $true
} | ConvertTo-Json -Compress))
if ($script:Failures) { exit 1 }
exit 0
