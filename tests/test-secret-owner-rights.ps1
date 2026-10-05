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

    function Get-OwnerRightsSetupIdentityFacts {
        param(
            [AllowNull()][Security.Principal.SecurityIdentifier]$Identity,
            [AllowNull()][Security.Principal.SecurityIdentifier]$FileOwner,
            [AllowNull()][Security.Principal.SecurityIdentifier]$CurrentUser,
            [AllowNull()][Security.Principal.SecurityIdentifier]$TokenDefaultOwner
        )
        [pscustomobject]@{
            Available = $null -ne $Identity
            EqualsFileOwner = $(if ($null -ne $Identity -and $null -ne $FileOwner) { $Identity.Equals($FileOwner) } else { $null })
            EqualsCurrentUser = $(if ($null -ne $Identity -and $null -ne $CurrentUser) { $Identity.Equals($CurrentUser) } else { $null })
            EqualsTokenDefaultOwner = $(if ($null -ne $Identity -and $null -ne $TokenDefaultOwner) { $Identity.Equals($TokenDefaultOwner) } else { $null })
            IsBuiltinAdministrators = $(if ($null -ne $Identity) { $Identity.IsWellKnown([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid) } else { $null })
            IsLocalSystem = $(if ($null -ne $Identity) { $Identity.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid) } else { $null })
        }
    }

    function Add-OwnerRightsSetupReadError {
        param(
            [string]$Stage,
            [Management.Automation.ErrorRecord]$ErrorRecord,
            [AllowEmptyCollection()][Collections.Generic.List[object]]$Errors
        )
        Assert-OwnerRightsErrorNotGuard -ErrorRecord $ErrorRecord
        $cause = $ErrorRecord.Exception.GetBaseException()
        $Errors.Add([pscustomobject]@{
            Stage = $Stage; ExceptionType = $ErrorRecord.Exception.GetType().FullName
            HResult = $ErrorRecord.Exception.HResult
            CauseType = $cause.GetType().FullName; CauseHResult = $cause.HResult
        })
    }

    function Write-OwnerRightsSetupDiagnostic {
        param([string]$Path, [bool]$GuardOwnerMatchesCurrentUser)
        Assert-BridgeTestPath -Path $Path
        $availability = [ordered]@{
            Item = 'not-attempted'; SecurityDescriptor = 'not-attempted'; FileOwner = 'not-attempted'
            CurrentToken = 'not-attempted'; CurrentUser = 'not-attempted'; TokenDefaultOwner = 'not-attempted'
            Dacl = 'not-attempted'
        }
        $errors = [Collections.Generic.List[object]]::new()
        $item = $null; $descriptor = $null; $fileOwner = $null
        $tokenIdentity = $null; $currentUser = $null; $tokenDefaultOwner = $null
        $accessRulesProtected = $null; $accessRulesCanonical = $null; $ruleCount = $null
        $rules = @()
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $availability.Item = 'available'
        }
        catch {
            $readError = $_
            $availability.Item = 'error'
            Add-OwnerRightsSetupReadError -Stage 'item' -ErrorRecord $readError -Errors $errors
        }
        if ($null -ne $item) {
            try {
                $descriptor = [IO.FileSystemAclExtensions]::GetAccessControl(
                    $item, [Security.AccessControl.AccessControlSections]'Access, Owner')
                $availability.SecurityDescriptor = 'available'
            }
            catch {
                $readError = $_
                $availability.SecurityDescriptor = 'error'
                Add-OwnerRightsSetupReadError -Stage 'security-descriptor' -ErrorRecord $readError -Errors $errors
            }
        }
        if ($null -ne $descriptor) {
            try {
                $fileOwner = $descriptor.GetOwner([Security.Principal.SecurityIdentifier])
                $availability.FileOwner = if ($null -ne $fileOwner) { 'available' } else { 'unavailable' }
            }
            catch {
                $readError = $_
                $availability.FileOwner = 'error'
                Add-OwnerRightsSetupReadError -Stage 'file-owner' -ErrorRecord $readError -Errors $errors
            }
            try {
                $rules = @($descriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                $accessRulesProtected = $descriptor.AreAccessRulesProtected
                $accessRulesCanonical = $descriptor.AreAccessRulesCanonical
                $ruleCount = $rules.Count
                $availability.Dacl = 'available'
            }
            catch {
                $readError = $_
                $availability.Dacl = 'error'
                Add-OwnerRightsSetupReadError -Stage 'dacl' -ErrorRecord $readError -Errors $errors
            }
        }
        try {
            try {
                $tokenIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $availability.CurrentToken = if ($null -ne $tokenIdentity) { 'available' } else { 'unavailable' }
            }
            catch {
                $readError = $_
                $availability.CurrentToken = 'error'
                Add-OwnerRightsSetupReadError -Stage 'current-token' -ErrorRecord $readError -Errors $errors
            }
            if ($null -ne $tokenIdentity) {
                try {
                    $currentUser = $tokenIdentity.User
                    $availability.CurrentUser = if ($null -ne $currentUser) { 'available' } else { 'unavailable' }
                }
                catch {
                    $readError = $_
                    $availability.CurrentUser = 'error'
                    Add-OwnerRightsSetupReadError -Stage 'current-user' -ErrorRecord $readError -Errors $errors
                }
                try {
                    $tokenDefaultOwner = $tokenIdentity.Owner
                    $availability.TokenDefaultOwner = if ($null -ne $tokenDefaultOwner) { 'available' } else { 'unavailable' }
                }
                catch {
                    $readError = $_
                    $availability.TokenDefaultOwner = 'error'
                    Add-OwnerRightsSetupReadError -Stage 'token-default-owner' -ErrorRecord $readError -Errors $errors
                }
            }
        }
        finally {
            if ($null -ne $tokenIdentity) {
                try { $tokenIdentity.Dispose() }
                catch {
                    $readError = $_
                    Add-OwnerRightsSetupReadError -Stage 'token-dispose' -ErrorRecord $readError -Errors $errors
                }
            }
        }
        $comparisons = @{ FileOwner = $fileOwner; CurrentUser = $currentUser; TokenDefaultOwner = $tokenDefaultOwner }
        $ruleMetadata = @()
        if ($availability.Dacl -ceq 'available') {
            $ruleMetadata = @(foreach ($rule in $rules) {
                [pscustomobject]@{
                    AccessControlType = [string]$rule.AccessControlType; RightsMask = [long]$rule.FileSystemRights
                    IsInherited = [bool]$rule.IsInherited
                    InheritanceFlags = [string]$rule.InheritanceFlags; PropagationFlags = [string]$rule.PropagationFlags
                    Identity = Get-OwnerRightsSetupIdentityFacts -Identity $rule.IdentityReference @comparisons
                }
            })
        }
        # Keep identities and error text out of logs; the original guard still
        # decides whether setup may proceed, even if an optional read is unavailable.
        $observation = [pscustomobject]@{
            SchemaVersion = 1; Phase = 'before-current-user-owner-precondition'
            TargetLeaf = [IO.Path]::GetFileName($Path)
            IsDirectory = $(if ($null -ne $item) { [bool]$item.PSIsContainer } else { $null })
            GuardOwnerMatchesCurrentUser = $GuardOwnerMatchesCurrentUser
            ReadAvailability = [pscustomobject]$availability
            FileOwner = Get-OwnerRightsSetupIdentityFacts -Identity $fileOwner @comparisons
            CurrentUser = Get-OwnerRightsSetupIdentityFacts -Identity $currentUser @comparisons
            TokenDefaultOwner = Get-OwnerRightsSetupIdentityFacts -Identity $tokenDefaultOwner @comparisons
            Dacl = [pscustomobject]@{
                AccessRulesProtected = $accessRulesProtected; AccessRulesCanonical = $accessRulesCanonical
                RuleCount = $ruleCount; Rules = $ruleMetadata
            }
            ReadErrors = @($errors.ToArray())
        }
        Write-Host ('OWNER_RIGHTS_SETUP_DIAGNOSTIC ' + ($observation | ConvertTo-Json -Depth 7 -Compress))
    }

    function Get-OwnerRightsDaclFingerprint {
        param([string]$Path)
        Assert-BridgeTestPath -Path $Path
        $access = [IO.FileSystemAclExtensions]::GetAccessControl(
            (Get-Item -LiteralPath $Path -Force -ErrorAction Stop), [Security.AccessControl.AccessControlSections]::Access)
        $raw = [Security.AccessControl.RawSecurityDescriptor]::new($access.GetSecurityDescriptorBinaryForm(), 0)
        if ($null -eq $raw.DiscretionaryAcl) { throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the fixture has no readable DACL.' }
        $bytes = [byte[]]::new($raw.DiscretionaryAcl.BinaryLength)
        $raw.DiscretionaryAcl.GetBinaryForm($bytes, 0)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }

    function Get-OwnerRightsByteEvidence {
        param([string[]]$Paths = @())
        foreach ($path in @($Paths | Select-Object -Unique)) {
            Assert-BridgeTestPath -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: a byte-preservation witness is missing.'
            }
            $bytes = [IO.File]::ReadAllBytes($path)
            [pscustomobject]@{
                Leaf = [IO.Path]::GetFileName($path); Length = $bytes.Length
                Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            }
        }
    }

    function Test-OwnerRightsEvidenceEqual {
        param($Before, $After)
        (ConvertTo-Json -InputObject $Before -Depth 8 -Compress) -ceq
            (ConvertTo-Json -InputObject $After -Depth 8 -Compress)
    }

    function ConvertTo-OwnerRightsStateEvidence {
        param($State)
        [pscustomobject]@{
            IsDirectory = $State.IsDirectory; OwnerMatchesCurrentUser = $State.OwnerMatchesCurrentUser
            AccessRulesProtected = $State.AccessRulesProtected; RuleCount = $State.RuleCount
            SingleCurrentUserAllow = $State.SingleCurrentUserAllow; Rights = $State.Rights
            InheritanceMatches = $State.InheritanceMatches; RuleInherited = $State.RuleInherited
            ExactModifyDacl = $State.ExactModifyDacl; ExactPrivateDacl = $State.ExactPrivateDacl
        }
    }

    function Assert-OwnerRightsTokenProfile {
        param([Security.Principal.SecurityIdentifier]$UserSid, [Security.Principal.SecurityIdentifier]$DefaultOwnerSid)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if ($null -eq $identity.User -or $null -eq $identity.Owner -or
                -not $identity.User.Equals($UserSid) -or -not $identity.Owner.Equals($DefaultOwnerSid)) {
                throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the actual user/default-owner profile changed.'
            }
        }
        finally { $identity.Dispose() }
    }

    function Get-OwnerRightsCreationProfile {
        param(
            [string]$Path, [Security.Principal.SecurityIdentifier]$UserSid,
            [Security.Principal.SecurityIdentifier]$DefaultOwnerSid
        )
        Assert-BridgeTestPath -Path $Path
        Assert-OwnerRightsTokenProfile -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        $descriptor = [IO.FileSystemAclExtensions]::GetAccessControl(
            (Get-Item -LiteralPath $Path -Force -ErrorAction Stop), [Security.AccessControl.AccessControlSections]::Owner)
        $owner = $descriptor.GetOwner([Security.Principal.SecurityIdentifier])
        if ($null -eq $owner) { throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the created object owner is unreadable.' }
        [pscustomobject]@{
            State = Get-OwnerRightsFixtureState -Path $Path
            OwnerMatchesTokenDefaultOwner = $owner.Equals($DefaultOwnerSid)
            TokenDefaultOwnerMatchesCurrentUser = $DefaultOwnerSid.Equals($UserSid)
            Owner = Get-OwnerRightsSetupIdentityFacts -Identity $owner -FileOwner $owner -CurrentUser $UserSid -TokenDefaultOwner $DefaultOwnerSid
            TokenDefaultOwner = Get-OwnerRightsSetupIdentityFacts -Identity $DefaultOwnerSid -FileOwner $owner -CurrentUser $UserSid -TokenDefaultOwner $DefaultOwnerSid
        }
    }

    function New-OwnerRightsComparisonPath {
        param([string]$Path, [switch]$Directory)
        Assert-BridgeTestPath -Path $Path
        if ((Test-Path -LiteralPath $Path) -or
            -not (Test-Path -LiteralPath (Split-Path $Path -Parent) -PathType Container)) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: a comparison path must be fresh under an existing fixture parent.'
        }
        if ($Directory) { [void][IO.Directory]::CreateDirectory($Path) }
        else {
            $empty = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $empty.Dispose()
        }
        Assert-BridgeTestPath -Path $Path
        if (-not $script:OwnerRightsFreshComparisonPaths.Add([IO.Path]::GetFullPath($Path))) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: a comparison creation was registered twice.'
        }
    }

    function Write-OwnerRightsComparisonPhase {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('existing-before', 'after-owner-read', 'after-set-owner', 'after-persist', 'after-profile-readback', 'before-postcondition', IgnoreCase = $false)]
            [string]$Phase,
            [Parameter(Mandatory)][string]$Path, [AllowEmptyCollection()][string[]]$BytePaths = @(),
            [Security.Principal.SecurityIdentifier]$UserSid, [Security.Principal.SecurityIdentifier]$DefaultOwnerSid,
            [AllowNull()]$Descriptor = $null
        )
        Assert-BridgeTestPath -Path $Path
        $phases = @('existing-before', 'after-owner-read', 'after-set-owner', 'after-persist', 'after-profile-readback', 'before-postcondition')
        $availability = [ordered]@{
            Item = 'not-attempted'; SecurityDescriptor = 'not-attempted'; Owner = 'not-attempted'
            Dacl = 'not-attempted'; Bytes = 'not-attempted'; Descriptor = 'not-provided'; Runtime = 'not-attempted'
        }
        $errors = [Collections.Generic.List[object]]::new()
        $phaseItem = $null; $diskDescriptor = $null; $fileOwner = $null
        $ownerFacts = $null; $daclFacts = $null; $runtimeFacts = $null
        $byteWitnesses = @(); $byteWitnessCount = $null; $descriptorType = $null
        $witnessPaths = @($BytePaths | Select-Object -Unique)
        try {
            $phaseItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $availability.Item = 'available'
        }
        catch { $availability.Item = 'unavailable'; Add-OwnerRightsSetupReadError -Stage 'phase-item' -ErrorRecord $_ -Errors $errors }
        if ($null -ne $phaseItem) {
            try {
                $diskDescriptor = [IO.FileSystemAclExtensions]::GetAccessControl(
                    $phaseItem, [Security.AccessControl.AccessControlSections]'Access, Owner')
                $availability.SecurityDescriptor = 'available'
            }
            catch {
                $availability.SecurityDescriptor = 'unavailable'
                Add-OwnerRightsSetupReadError -Stage 'phase-security-descriptor' -ErrorRecord $_ -Errors $errors
            }
        }
        if ($null -ne $diskDescriptor) {
            try {
                $fileOwner = $diskDescriptor.GetOwner([Security.Principal.SecurityIdentifier])
                if ($null -eq $fileOwner) { throw [InvalidOperationException]::new('Phase owner metadata is unavailable.') }
                $ownerFacts = Get-OwnerRightsSetupIdentityFacts -Identity $fileOwner -FileOwner $fileOwner `
                    -CurrentUser $UserSid -TokenDefaultOwner $DefaultOwnerSid
                $availability.Owner = 'available'
            }
            catch { $availability.Owner = 'unavailable'; Add-OwnerRightsSetupReadError -Stage 'phase-owner' -ErrorRecord $_ -Errors $errors }
            try {
                # One disk descriptor binds the phase's DACL hash, flags and ACE projection.
                $rawDescriptor = [Security.AccessControl.RawSecurityDescriptor]::new($diskDescriptor.GetSecurityDescriptorBinaryForm(), 0)
                if ($null -eq $rawDescriptor.DiscretionaryAcl) { throw [InvalidOperationException]::new('Phase DACL metadata is unavailable.') }
                $daclBytes = [byte[]]::new($rawDescriptor.DiscretionaryAcl.BinaryLength)
                $rawDescriptor.DiscretionaryAcl.GetBinaryForm($daclBytes, 0)
                $phaseRules = @($diskDescriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
                $inheritedCount = @($phaseRules | Where-Object { $_.IsInherited }).Count
                $ruleShapes = @(for ($ruleIndex = 0; $ruleIndex -lt [Math]::Min(16, $phaseRules.Count); $ruleIndex++) {
                    $phaseRule = $phaseRules[$ruleIndex]
                    [pscustomobject]@{
                        AccessControlType = [string]$phaseRule.AccessControlType; RightsMask = [long]$phaseRule.FileSystemRights
                        IsInherited = [bool]$phaseRule.IsInherited
                        InheritanceFlags = [string]$phaseRule.InheritanceFlags; PropagationFlags = [string]$phaseRule.PropagationFlags
                        Identity = Get-OwnerRightsSetupIdentityFacts -Identity $phaseRule.IdentityReference -FileOwner $fileOwner `
                            -CurrentUser $UserSid -TokenDefaultOwner $DefaultOwnerSid
                    }
                })
                $daclFacts = [pscustomobject]@{
                    Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($daclBytes))
                    AccessRulesProtected = $diskDescriptor.AreAccessRulesProtected
                    AccessRulesCanonical = $diskDescriptor.AreAccessRulesCanonical
                    RuleCount = $phaseRules.Count; InheritedCount = $inheritedCount; ExplicitCount = $phaseRules.Count - $inheritedCount
                    RuleLimit = 16; ProjectedRuleCount = $ruleShapes.Count; RulesTruncated = $phaseRules.Count -gt 16
                    Rules = $ruleShapes
                }
                $availability.Dacl = 'available'
            }
            catch { $availability.Dacl = 'unavailable'; Add-OwnerRightsSetupReadError -Stage 'phase-dacl' -ErrorRecord $_ -Errors $errors }
        }
        try {
            foreach ($witnessPath in $witnessPaths) {
                Assert-BridgeTestPath -Path $witnessPath
                if (-not (Test-BridgeInstallPath $witnessPath $Path) -and
                    -not (Test-BridgeInstallDescendant $witnessPath $Path)) {
                    throw [InvalidOperationException]::new('Phase byte witness is outside its comparison target.')
                }
            }
            $readWitnesses = @(Get-OwnerRightsByteEvidence -Paths $witnessPaths)
            $byteWitnesses = @(for ($witnessIndex = 0; $witnessIndex -lt $readWitnesses.Count; $witnessIndex++) {
                [pscustomobject]@{
                    Ordinal = $witnessIndex + 1; Length = $readWitnesses[$witnessIndex].Length
                    Sha256 = $readWitnesses[$witnessIndex].Sha256
                }
            })
            $byteWitnessCount = $readWitnesses.Count
            $availability.Bytes = 'available'
        }
        catch { $availability.Bytes = 'unavailable'; Add-OwnerRightsSetupReadError -Stage 'phase-bytes' -ErrorRecord $_ -Errors $errors }
        if ($null -ne $Descriptor) {
            try {
                $descriptorType = $Descriptor.GetType().FullName
                if ($Descriptor -isnot [Security.AccessControl.ObjectSecurity]) {
                    throw [InvalidCastException]::new('Phase descriptor is not ObjectSecurity.')
                }
                $availability.Descriptor = 'available'
            }
            catch {
                $availability.Descriptor = 'unavailable'
                Add-OwnerRightsSetupReadError -Stage 'phase-descriptor-type' -ErrorRecord $_ -Errors $errors
            }
        }
        $dirtyFlags = @(foreach ($fieldName in @('_ownerModified', '_daclModified', '_groupModified', '_saclModified')) {
            $flag = [ordered]@{ Name = $fieldName; Availability = $availability.Descriptor; Value = $null }
            if ($availability.Descriptor -ceq 'available') {
                try {
                    $field = [Security.AccessControl.ObjectSecurity].GetField(
                        $fieldName, [Reflection.BindingFlags]'Instance, NonPublic')
                    if ($null -eq $field) { throw [MissingFieldException]::new('Phase dirty-flag metadata is unavailable.') }
                    if ($field.IsStatic -or $field.FieldType -ne [bool] -or
                        $field.DeclaringType -ne [Security.AccessControl.ObjectSecurity]) {
                        throw [InvalidCastException]::new('Phase dirty-flag metadata is not the expected instance Boolean.')
                    }
                    $value = $field.GetValue($Descriptor)
                    if ($value -isnot [bool]) { throw [InvalidCastException]::new('Phase dirty-flag value is not Boolean.') }
                    $flag.Value = $value
                }
                catch {
                    $flag.Availability = 'unavailable'
                    Add-OwnerRightsSetupReadError -Stage "phase-dirty-$fieldName" -ErrorRecord $_ -Errors $errors
                }
            }
            [pscustomobject]$flag
        })
        try {
            $assemblyFacts = @(foreach ($assembly in @(
                [IO.FileSystemAclExtensions].Assembly, [Security.AccessControl.ObjectSecurity].Assembly
            )) {
                $assemblyName = $assembly.GetName()
                [pscustomobject]@{
                    Name = $assemblyName.Name; Version = $assemblyName.Version.ToString()
                    ModuleIdentity = $assembly.ManifestModule.ModuleVersionId.ToString()
                }
            })
            $runtimeFacts = [pscustomobject]@{
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                Runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
                AclAssemblies = $assemblyFacts
            }
            $availability.Runtime = 'available'
        }
        catch { $availability.Runtime = 'unavailable'; Add-OwnerRightsSetupReadError -Stage 'phase-runtime' -ErrorRecord $_ -Errors $errors }
        $observation = [ordered]@{
            SchemaVersion = 1; Phase = $Phase; Ordinal = [Array]::IndexOf($phases, $Phase) + 1
            TargetLeaf = 'directory-control'; ReadAvailability = [pscustomobject]$availability
            Owner = $ownerFacts; Dacl = $daclFacts
            RequestedByteWitnessCount = $witnessPaths.Count; ByteWitnessCount = $byteWitnessCount; ByteWitnesses = $byteWitnesses
            Descriptor = [pscustomobject]@{ ClrType = $descriptorType; DirtyFlags = $dirtyFlags; ManagedObservationOnly = $true }
            Runtime = $runtimeFacts; ReadErrors = @($errors.ToArray())
        }
        [Console]::Out.WriteLine('OWNER_RIGHTS_SETUP_PHASE ' + ($observation | ConvertTo-Json -Depth 9 -Compress))
        [Console]::Out.Flush()
    }

    function Initialize-OwnerRightsComparisonOwner {
        param(
            [string]$Path, [string[]]$PreserveFiles = @(),
            [Security.Principal.SecurityIdentifier]$UserSid, [Security.Principal.SecurityIdentifier]$DefaultOwnerSid
        )
        Assert-BridgeTestPath -Path $Path
        if (-not $script:OwnerRightsFreshComparisonPaths.Remove([IO.Path]::GetFullPath($Path))) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: ownership setup is limited to one fresh comparison creation.'
        }
        $before = Get-OwnerRightsCreationProfile -Path $Path -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        $accessBefore = Get-OwnerRightsDaclFingerprint -Path $Path
        $bytePaths = @($PreserveFiles)
        if (-not $before.State.IsDirectory) { $bytePaths += $Path }
        $bytesBefore = @(Get-OwnerRightsByteEvidence -Paths $bytePaths)
        $required = -not $before.State.OwnerMatchesCurrentUser
        $capturePhases = $before.State.IsDirectory -and [StringComparer]::Ordinal.Equals([IO.Path]::GetFileName($Path), 'directory-control') -and
            -not (Get-Variable -Name OwnerRightsComparisonPhaseClaimed -Scope Script -ErrorAction Ignore)
        if ($capturePhases) {
            $script:OwnerRightsComparisonPhaseClaimed = $true
            Write-OwnerRightsComparisonPhase -Phase existing-before -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        }
        if ($required) {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $ownerOnly = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]::Owner)
            if ($capturePhases) {
                Write-OwnerRightsComparisonPhase -Phase after-owner-read -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid -Descriptor $ownerOnly
            }
            $ownerOnly.SetOwner($UserSid)
            if ($capturePhases) {
                Write-OwnerRightsComparisonPhase -Phase after-set-owner -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid -Descriptor $ownerOnly
            }
            try {
                [IO.FileSystemAclExtensions]::SetAccessControl($item, $ownerOnly)
            }
            catch {
                $setupError = $_
                Assert-OwnerRightsErrorNotGuard -ErrorRecord $setupError
                $cause = $setupError.Exception.GetBaseException()
                Write-Host ('OWNER_RIGHTS_OWNER_ESTABLISH ' + (@{
                    leaf = [IO.Path]::GetFileName($Path); outcome = 'failed'; ownerWriteAttempted = $true
                    beforeOwner = $before.Owner; errorType = $cause.GetType().FullName; hresult = $cause.HResult
                } | ConvertTo-Json -Depth 5 -Compress))
                throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: existing rights did not establish ownership of the fresh comparison.'
            }
            if ($capturePhases) {
                Write-OwnerRightsComparisonPhase -Phase after-persist -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid -Descriptor $ownerOnly
            }
        }
        $after = Get-OwnerRightsCreationProfile -Path $Path -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        if ($capturePhases) {
            Write-OwnerRightsComparisonPhase -Phase after-profile-readback -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid -Descriptor $(if ($required) { $ownerOnly } else { $null })
        }
        $accessUnchanged = $accessBefore -ceq (Get-OwnerRightsDaclFingerprint -Path $Path) -and
            $before.State.AccessRulesProtected -eq $after.State.AccessRulesProtected
        $bytesUnchanged = Test-OwnerRightsEvidenceEqual $bytesBefore @(Get-OwnerRightsByteEvidence -Paths $bytePaths)
        Write-Host ('OWNER_RIGHTS_OWNER_ESTABLISH ' + (@{
            leaf = [IO.Path]::GetFileName($Path); freshCreation = $true; ownerWriteAttempted = $required
            outcome = $(if ($after.State.OwnerMatchesCurrentUser -and $accessUnchanged -and $bytesUnchanged) { 'established' } else { 'readback-failed' })
            beforeOwner = $before.Owner; afterOwner = $after.Owner
            before = ConvertTo-OwnerRightsStateEvidence $before.State
            after = ConvertTo-OwnerRightsStateEvidence $after.State
            daclUnchanged = $accessUnchanged; originalBytesPreserved = $bytesUnchanged
        } | ConvertTo-Json -Depth 6 -Compress))
        if ($capturePhases) {
            Write-OwnerRightsComparisonPhase -Phase before-postcondition -Path $Path -BytePaths $bytePaths -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid -Descriptor $(if ($required) { $ownerOnly } else { $null })
        }
        if (-not $after.State.OwnerMatchesCurrentUser -or -not $accessUnchanged -or -not $bytesUnchanged) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: fresh owner setup changed data/DACL state or did not establish the current user.'
        }
    }

    function Invoke-OwnerRightsNativeChildControl {
        param(
            [string]$Parent, [ValidateSet('directory','file')][string]$Kind,
            [Security.Principal.SecurityIdentifier]$UserSid, [Security.Principal.SecurityIdentifier]$DefaultOwnerSid
        )
        Assert-BridgeTestPath -Path $Parent
        Assert-OwnerRightsTokenProfile -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        $parentBefore = Get-OwnerRightsFixtureState -Path $Parent
        $parentAccess = Get-OwnerRightsDaclFingerprint -Path $Parent
        $parentReady = if ($Kind -eq 'directory') { $parentBefore.ExactModifyDacl } else { $parentBefore.ExactPrivateDacl }
        if (-not $parentBefore.IsDirectory -or -not $parentReady) {
            throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: the real control parent has the wrong ownership/DACL profile.'
        }
        $path = Join-Path $Parent $(if ($Kind -eq 'directory') { 'native-directory-control' } else { 'native-file-control.bin' })
        Assert-BridgeTestPath -Path $path
        if (Test-Path -LiteralPath $path) { throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: a matched child must be newly created.' }
        if ($Kind -eq 'directory') { [void][IO.Directory]::CreateDirectory($path) }
        else {
            $empty = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $empty.Dispose()
        }
        $before = Get-OwnerRightsCreationProfile -Path $path -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        $beforeAccess = Get-OwnerRightsDaclFingerprint -Path $path
        $expectedRights = if ($Kind -eq 'directory') {
            [long]([Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::Synchronize)
        } else { [long][Security.AccessControl.FileSystemRights]::FullControl }
        if ($before.State.IsDirectory -ne ($Kind -eq 'directory') -or
            -not $before.OwnerMatchesTokenDefaultOwner -or $before.State.AccessRulesProtected -or
            -not $before.State.SingleCurrentUserAllow -or -not $before.State.RuleInherited -or
            -not $before.State.InheritanceMatches -or $before.State.Rights -ne $expectedRights) {
            throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: fresh creation did not have the matched raw owner/inherited-ACE profile.'
        }
        $ownerRequired = -not $before.State.OwnerMatchesCurrentUser
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $descriptor = [IO.FileSystemAclExtensions]::GetAccessControl($item, [Security.AccessControl.AccessControlSections]'Access, Owner')
        $descriptor.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($descriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            $descriptor.RemoveAccessRuleAll($rule)
        }
        $inherit = if ($Kind -eq 'directory') {
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else { [Security.AccessControl.InheritanceFlags]::None }
        $descriptor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $UserSid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        if ($ownerRequired) { $descriptor.SetOwner($UserSid) }
        # Owner-only success followed by a DACL write would change the starting
        # rights. Only the matching combined persist may supply a denial result.
        $denial = $null
        try {
            [IO.FileSystemAclExtensions]::SetAccessControl($item, $descriptor)
        }
        catch {
            $controlError = $_
            Assert-OwnerRightsErrorNotGuard -ErrorRecord $controlError
            $denial = $controlError.Exception.GetBaseException()
            if (-not $ownerRequired -or $denial.GetType() -ne [UnauthorizedAccessException] -or $denial.HResult -ne -2147024891) {
                Write-Host ('OWNER_RIGHTS_NATIVE_CONTROL_ERROR ' + (@{
                    kind = $Kind; ownerChangeRequired = $ownerRequired
                    type = $denial.GetType().FullName; hresult = $denial.HResult
                } | ConvertTo-Json -Compress))
                throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: native hardening failed outside the matched ownership-required denial.'
            }
        }
        $after = Get-OwnerRightsCreationProfile -Path $path -UserSid $UserSid -DefaultOwnerSid $DefaultOwnerSid
        $parentUnchanged = (Test-OwnerRightsEvidenceEqual $parentBefore (Get-OwnerRightsFixtureState -Path $Parent)) -and
            $parentAccess -ceq (Get-OwnerRightsDaclFingerprint -Path $Parent)
        $emptyUnchanged = if ($Kind -eq 'directory') {
            @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop).Count -eq 0
        } else { (Get-Item -LiteralPath $path -Force).Length -eq 0 }
        $outcome = if ($null -eq $denial) { 'permitted' } else { 'ownership-required-denied' }
        $established = if ($null -eq $denial) { $after.State.ExactPrivateDacl }
            else {
                $after.OwnerMatchesTokenDefaultOwner -and -not $after.State.OwnerMatchesCurrentUser -and
                    (Test-OwnerRightsEvidenceEqual $before.State $after.State) -and
                    $beforeAccess -ceq (Get-OwnerRightsDaclFingerprint -Path $path)
            }
        if (-not $established -or -not $parentUnchanged -or -not $emptyUnchanged) {
            throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: native capability readback changed the parent/data or did not match its outcome.'
        }
        [pscustomobject]@{
            Path = $path; Outcome = $outcome; OwnerChangeRequired = $ownerRequired
            BeforeState = $before.State; BeforeDaclFingerprint = $beforeAccess
            Observation = [pscustomobject]@{
                kind = $Kind; leaf = [IO.Path]::GetFileName($path); outcome = $outcome
                ownerChangeRequired = $ownerRequired; ownerBefore = $before.Owner; ownerAfter = $after.Owner
                rawOwnerMatchesTokenDefaultOwner = $before.OwnerMatchesTokenDefaultOwner
                tokenDefaultOwnerMatchesCurrentUser = $before.TokenDefaultOwnerMatchesCurrentUser
                before = ConvertTo-OwnerRightsStateEvidence $before.State
                after = ConvertTo-OwnerRightsStateEvidence $after.State
                parentUnchanged = $parentUnchanged; emptyContentPreserved = $emptyUnchanged
                errorType = $(if ($denial) { $denial.GetType().FullName } else { $null })
                hresult = $(if ($denial) { $denial.HResult } else { $null })
            }
        }
    }

    function Set-OwnerRightsFixtureModifyDacl {
        param([string]$Path, [string[]]$PreserveFiles = @())
        Initialize-OwnerRightsComparisonOwner -Path $Path -PreserveFiles $PreserveFiles `
            -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
        $before = Get-OwnerRightsFixtureState -Path $Path
        Write-OwnerRightsSetupDiagnostic -Path $Path -GuardOwnerMatchesCurrentUser $before.OwnerMatchesCurrentUser
        if (-not $before.OwnerMatchesCurrentUser) {
            throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: current-user ownership is not established; the Modify-only DACL was not applied.'
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

    $ownerRightsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $ownerRightsCurrentUser = $ownerRightsIdentity.User
        $ownerRightsDefaultOwner = $ownerRightsIdentity.Owner
    }
    finally { $ownerRightsIdentity.Dispose() }
    if ($null -eq $ownerRightsCurrentUser -or $null -eq $ownerRightsDefaultOwner) {
        throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the actual current-user/default-owner profile is unavailable.'
    }
    $ownerRightsUserDefaultProfile = $ownerRightsDefaultOwner.Equals($ownerRightsCurrentUser)
    $script:OwnerRightsFreshComparisonPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ownerRightsRoot = Join-Path $credentialRoot 'owner-rights'
    Assert-BridgeTestPath -Path $ownerRightsRoot
    [void][IO.Directory]::CreateDirectory($ownerRightsRoot)
    $ownerRightsControls = @{}
    foreach ($ownerRightsKind in @('directory', 'file')) {
        $ownerRightsControl = Join-Path $ownerRightsRoot "$ownerRightsKind-control"
        $ownerRightsTarget = Join-Path $ownerRightsRoot "$ownerRightsKind-target"
        Assert-BridgeTestPath -Path @($ownerRightsControl, $ownerRightsTarget)
        if ($ownerRightsKind -eq 'directory') {
            New-OwnerRightsComparisonPath -Path $ownerRightsControl -Directory
            New-OwnerRightsComparisonPath -Path $ownerRightsTarget -Directory
            $ownerRightsBytesPath = Join-Path $ownerRightsTarget 'existing.bin'
        }
        else {
            New-OwnerRightsComparisonPath -Path $ownerRightsControl
            New-OwnerRightsComparisonPath -Path $ownerRightsTarget
            [IO.File]::WriteAllBytes($ownerRightsControl, [byte[]](0, 1, 2, 127, 255))
            $ownerRightsBytesPath = $ownerRightsTarget
        }
        Assert-BridgeTestPath -Path $ownerRightsBytesPath
        [IO.File]::WriteAllBytes($ownerRightsBytesPath, [byte[]](0, 1, 2, 127, 255))
        $ownerRightsControlBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsControl
        $ownerRightsTargetBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsTarget -PreserveFiles @($ownerRightsBytesPath)
        Assert-OwnerRightsTokenProfile -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
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
            $ownerRightsChildProfile = $null
            $ownerRightsRawChildPrivate = $null
            if ($ownerRightsProtected) {
                $ownerRightsChild = Join-Path $ownerRightsTarget 'inherited.bin'
                Assert-BridgeTestPath -Path $ownerRightsChild
                if (Test-Path -LiteralPath $ownerRightsChild) { throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the raw inherited child is not fresh.' }
                [IO.File]::WriteAllBytes($ownerRightsChild, [byte[]](9, 8, 7))
                $ownerRightsChildProfile = Get-OwnerRightsCreationProfile -Path $ownerRightsChild `
                    -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
                $ownerRightsChildState = $ownerRightsChildProfile.State
                $ownerRightsRawChildPrivate = Test-BridgeSecretFileProtected -Path $ownerRightsChild
            }
            Write-Host ('OWNER_RIGHTS_INHERITANCE ' + (@{
                attempted = $ownerRightsProtected; child = $ownerRightsChildState
                rawOwner = $(if ($ownerRightsChildProfile) { $ownerRightsChildProfile.Owner } else { $null })
                ownerMatchesTokenDefaultOwner = $(if ($ownerRightsChildProfile) { $ownerRightsChildProfile.OwnerMatchesTokenDefaultOwner } else { $null })
                tokenDefaultOwnerMatchesCurrentUser = $ownerRightsUserDefaultProfile
                rawChildVerifiedPrivate = $ownerRightsRawChildPrivate
            } | ConvertTo-Json -Depth 5 -Compress))
            Test-That 'the raw child inherits only current-user FullControl while its owner follows the actual token default' {
                $null -ne $ownerRightsChildState -and $ownerRightsChildProfile.OwnerMatchesTokenDefaultOwner -and
                    $ownerRightsChildState.OwnerMatchesCurrentUser -eq $ownerRightsUserDefaultProfile -and
                    $ownerRightsChildState.SingleCurrentUserAllow -and $ownerRightsChildState.InheritanceMatches -and
                    $ownerRightsChildState.RuleInherited -eq $true -and
                    $ownerRightsChildState.Rights -eq [long][Security.AccessControl.FileSystemRights]::FullControl -and
                    $ownerRightsRawChildPrivate -eq $false
            }
        }
    }

    foreach ($ownerRightsWriterKind in @('existing-file', 'new-directory')) {
        $ownerRightsExpectedWriterOutcome = 'private-write'
        $ownerRightsDirectoryControl = $null
        $ownerRightsFileControl = $null
        $ownerRightsParentBefore = $null
        $ownerRightsParentAccess = $null
        $ownerRightsSourceBefore = @()
        $ownerRightsSourcePath = $null
        if ($ownerRightsWriterKind -eq 'existing-file') {
            $ownerRightsWriterPath = Join-Path $ownerRightsRoot 'writer-existing.json'
            Assert-BridgeTestPath -Path $ownerRightsWriterPath
            New-OwnerRightsComparisonPath -Path $ownerRightsWriterPath
            [IO.File]::WriteAllText($ownerRightsWriterPath, 'synthetic-original-bytes')
            $ownerRightsWriterBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsWriterPath
            $ownerRightsWriterControl = $ownerRightsControls['file']
        }
        else {
            $ownerRightsWriterParent = Join-Path $ownerRightsRoot 'writer-parent'
            Assert-BridgeTestPath -Path $ownerRightsWriterParent
            New-OwnerRightsComparisonPath -Path $ownerRightsWriterParent -Directory
            $ownerRightsSourcePath = Join-Path $ownerRightsWriterParent 'source.bin'
            Assert-BridgeTestPath -Path $ownerRightsSourcePath
            [IO.File]::WriteAllText($ownerRightsSourcePath, 'synthetic-parent-source-bytes')
            $ownerRightsWriterBefore = Set-OwnerRightsFixtureModifyDacl -Path $ownerRightsWriterParent -PreserveFiles @($ownerRightsSourcePath)
            $ownerRightsParentBefore = Get-OwnerRightsFixtureState -Path $ownerRightsWriterParent
            $ownerRightsParentAccess = Get-OwnerRightsDaclFingerprint -Path $ownerRightsWriterParent
            $ownerRightsSourceBefore = @(Get-OwnerRightsByteEvidence -Paths @($ownerRightsSourcePath))
            $ownerRightsWriterPath = Join-Path $ownerRightsWriterParent 'new\config.json'
            Assert-BridgeTestPath -Path $ownerRightsWriterPath
            if (Test-Path -LiteralPath (Split-Path $ownerRightsWriterPath -Parent)) {
                throw 'OWNER_RIGHTS_FIXTURE_UNESTABLISHED: the real writer destination must remain absent before its call.'
            }
            $ownerRightsWriterControl = $ownerRightsControls['directory']
            $ownerRightsDirectoryControl = Invoke-OwnerRightsNativeChildControl -Parent $ownerRightsWriterParent -Kind directory `
                -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
            if ($ownerRightsDirectoryControl.Outcome -ceq 'ownership-required-denied') {
                $ownerRightsExpectedWriterOutcome = 'new-directory-refusal'
            }
            elseif ($ownerRightsDirectoryControl.Outcome -ceq 'permitted') {
                $ownerRightsFileControl = Invoke-OwnerRightsNativeChildControl -Parent $ownerRightsDirectoryControl.Path -Kind file `
                    -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
                if ($ownerRightsFileControl.Outcome -ceq 'ownership-required-denied') {
                    $ownerRightsExpectedWriterOutcome = 'new-file-refusal'
                }
                elseif ($ownerRightsFileControl.Outcome -cne 'permitted') {
                    throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: the file capability has no recognized measured outcome.'
                }
            }
            else { throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: the directory capability has no recognized measured outcome.' }
            if ($ownerRightsUserDefaultProfile -and $ownerRightsExpectedWriterOutcome -cne 'private-write') {
                throw 'OWNER_RIGHTS_CONTROL_UNESTABLISHED: the current-user default-owner profile must retain private writer success.'
            }
            $ownerRightsControlParentKept = (Test-OwnerRightsEvidenceEqual $ownerRightsParentBefore (Get-OwnerRightsFixtureState -Path $ownerRightsWriterParent)) -and
                $ownerRightsParentAccess -ceq (Get-OwnerRightsDaclFingerprint -Path $ownerRightsWriterParent)
            $ownerRightsControlSourceKept = Test-OwnerRightsEvidenceEqual $ownerRightsSourceBefore @(Get-OwnerRightsByteEvidence -Paths @($ownerRightsSourcePath))
            Write-Host ('OWNER_RIGHTS_NESTED_CAPABILITY ' + (@{
                tokenDefaultOwnerMatchesCurrentUser = $ownerRightsUserDefaultProfile
                directory = $ownerRightsDirectoryControl.Observation
                file = $(if ($ownerRightsFileControl) { $ownerRightsFileControl.Observation } else { $null })
                expectedWriterOutcome = $ownerRightsExpectedWriterOutcome
                parentPreserved = $ownerRightsControlParentKept; sourceBytesPreserved = $ownerRightsControlSourceKept
                realTargetStillAbsent = -not (Test-Path -LiteralPath (Split-Path $ownerRightsWriterPath -Parent))
            } | ConvertTo-Json -Depth 8 -Compress))
            Test-That 'the matched native child controls establish a writer outcome without changing its Modify parent or source bytes' {
                $ownerRightsControlParentKept -and $ownerRightsControlSourceKept -and $ownerRightsParentBefore.ExactModifyDacl -and
                    -not (Test-Path -LiteralPath (Split-Path $ownerRightsWriterPath -Parent)) -and
                    $ownerRightsDirectoryControl.Observation.rawOwnerMatchesTokenDefaultOwner -and
                    ($ownerRightsExpectedWriterOutcome -cin @('private-write','new-directory-refusal','new-file-refusal')) -and
                    (-not $ownerRightsUserDefaultProfile -or $ownerRightsExpectedWriterOutcome -ceq 'private-write')
            }
        }
        Assert-OwnerRightsTokenProfile -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
        $ownerRightsWriterError = $null
        try { Write-BridgeSecretFile -Path $ownerRightsWriterPath -Content 'synthetic-written-by-real-writer' }
        catch {
            $ownerRightsWriterError = $_
            Assert-OwnerRightsErrorNotGuard -ErrorRecord $ownerRightsWriterError
        }
        Assert-OwnerRightsTokenProfile -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
        $ownerRightsWriterAfter = $null
        $ownerRightsWriterProfile = $null
        $ownerRightsWriterBytes = $null
        $ownerRightsWriterVerified = $false
        if (Test-Path -LiteralPath $ownerRightsWriterPath -PathType Leaf) {
            $ownerRightsWriterProfile = Get-OwnerRightsCreationProfile -Path $ownerRightsWriterPath `
                -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
            $ownerRightsWriterAfter = $ownerRightsWriterProfile.State
            $ownerRightsWriterBytes = [IO.File]::ReadAllText($ownerRightsWriterPath)
            $ownerRightsWriterVerified = Test-BridgeSecretFileProtected -Path $ownerRightsWriterPath
        }
        if ($ownerRightsWriterError -and
            (($ownerRightsWriterKind -eq 'existing-file' -and $ownerRightsWriterBytes -cne 'synthetic-original-bytes') -or
             ($ownerRightsWriterKind -eq 'new-directory' -and -not [string]::IsNullOrEmpty($ownerRightsWriterBytes)))) {
            throw 'OWNER_RIGHTS_WRITER: a refused real write changed or exposed credential bytes.'
        }
        $ownerRightsParentKept = $true
        $ownerRightsSourceKept = $true
        $ownerRightsTargetDirectoryProfile = $null
        $ownerRightsMatchedOutcome = $null -eq $ownerRightsWriterError -and $null -ne $ownerRightsWriterAfter -and
            $ownerRightsWriterAfter.ExactPrivateDacl -and $ownerRightsWriterVerified -and
            $ownerRightsWriterBytes -ceq 'synthetic-written-by-real-writer'
        if ($ownerRightsWriterKind -eq 'new-directory') {
            $ownerRightsParentKept = (Test-OwnerRightsEvidenceEqual $ownerRightsParentBefore (Get-OwnerRightsFixtureState -Path $ownerRightsWriterParent)) -and
                $ownerRightsParentAccess -ceq (Get-OwnerRightsDaclFingerprint -Path $ownerRightsWriterParent)
            $ownerRightsSourceKept = Test-OwnerRightsEvidenceEqual $ownerRightsSourceBefore @(Get-OwnerRightsByteEvidence -Paths @($ownerRightsSourcePath))
            $ownerRightsTargetDirectory = Split-Path $ownerRightsWriterPath -Parent
            $ownerRightsTargetDirectoryState = $null
            if (Test-Path -LiteralPath $ownerRightsTargetDirectory -PathType Container) {
                $ownerRightsTargetDirectoryProfile = Get-OwnerRightsCreationProfile -Path $ownerRightsTargetDirectory `
                    -UserSid $ownerRightsCurrentUser -DefaultOwnerSid $ownerRightsDefaultOwner
                $ownerRightsTargetDirectoryState = $ownerRightsTargetDirectoryProfile.State
            }
            if ($ownerRightsExpectedWriterOutcome -ceq 'private-write') {
                $ownerRightsMatchedOutcome = $ownerRightsMatchedOutcome -and $null -ne $ownerRightsTargetDirectoryState -and
                    $ownerRightsTargetDirectoryState.ExactPrivateDacl
            }
            elseif ($ownerRightsExpectedWriterOutcome -ceq 'new-directory-refusal') {
                $ownerRightsMatchedOutcome = $null -ne $ownerRightsWriterError -and
                    $ownerRightsWriterError.Exception.Message -ceq 'Could not protect the new credential directory; no credential contents were written.' -and
                    $null -ne $ownerRightsTargetDirectoryState -and -not (Test-Path -LiteralPath $ownerRightsWriterPath) -and
                    $ownerRightsTargetDirectoryProfile.OwnerMatchesTokenDefaultOwner -and
                    (Test-OwnerRightsEvidenceEqual -Before (ConvertTo-OwnerRightsStateEvidence $ownerRightsDirectoryControl.BeforeState) `
                        -After (ConvertTo-OwnerRightsStateEvidence $ownerRightsTargetDirectoryState)) -and
                    $ownerRightsDirectoryControl.BeforeDaclFingerprint -ceq (Get-OwnerRightsDaclFingerprint -Path $ownerRightsTargetDirectory)
            }
            elseif ($ownerRightsExpectedWriterOutcome -ceq 'new-file-refusal') {
                $ownerRightsMatchedOutcome = $null -ne $ownerRightsWriterError -and
                    $ownerRightsWriterError.Exception.Message -ceq 'Could not protect the credential file; no new contents were written.' -and
                    $null -ne $ownerRightsTargetDirectoryState -and $ownerRightsTargetDirectoryState.ExactPrivateDacl -and
                    $null -ne $ownerRightsWriterAfter -and (Get-Item -LiteralPath $ownerRightsWriterPath -Force).Length -eq 0 -and
                    $ownerRightsWriterProfile.OwnerMatchesTokenDefaultOwner -and
                    (Test-OwnerRightsEvidenceEqual -Before (ConvertTo-OwnerRightsStateEvidence $ownerRightsFileControl.BeforeState) `
                        -After (ConvertTo-OwnerRightsStateEvidence $ownerRightsWriterAfter)) -and
                    $ownerRightsFileControl.BeforeDaclFingerprint -ceq (Get-OwnerRightsDaclFingerprint -Path $ownerRightsWriterPath)
            }
        }
        Write-Host ('OWNER_RIGHTS_WRITER ' + (@{
            kind = $ownerRightsWriterKind; ownerControl = $ownerRightsWriterControl.Outcome; before = $ownerRightsWriterBefore
            error = $(if ($ownerRightsWriterError) { @{
                type = $ownerRightsWriterError.Exception.GetType().FullName; hresult = $ownerRightsWriterError.Exception.HResult
            } } else { $null })
            after = $ownerRightsWriterAfter; finalVerifier = $ownerRightsWriterVerified
            requestedBytesWritten = ($ownerRightsWriterBytes -ceq 'synthetic-written-by-real-writer')
            originalBytesPreserved = ($ownerRightsWriterBytes -ceq 'synthetic-original-bytes')
            tokenDefaultOwnerMatchesCurrentUser = $ownerRightsUserDefaultProfile
            expectedOutcome = $ownerRightsExpectedWriterOutcome; matchedOutcome = $ownerRightsMatchedOutcome
            parentPreserved = $ownerRightsParentKept; sourceBytesPreserved = $ownerRightsSourceKept
            fileOwner = $(if ($ownerRightsWriterProfile) { $ownerRightsWriterProfile.Owner } else { $null })
            createdDirectoryOwner = $(if ($ownerRightsTargetDirectoryProfile) { $ownerRightsTargetDirectoryProfile.Owner } else { $null })
        } | ConvertTo-Json -Depth 5 -Compress))
        if ($ownerRightsWriterKind -eq 'existing-file') {
            Test-That 'the real writer protects the existing-file case under an owned Modify-only boundary' {
                $null -eq $ownerRightsWriterError -and $null -ne $ownerRightsWriterAfter -and
                    $ownerRightsWriterAfter.ExactPrivateDacl -and $ownerRightsWriterVerified -and
                    $ownerRightsWriterBytes -ceq 'synthetic-written-by-real-writer'
            }
        }
        else {
            Test-That 'the real nested writer matches the measured ownership capability with private success or the exact byte-free refusal' {
                $ownerRightsMatchedOutcome -and $ownerRightsParentKept -and $ownerRightsSourceKept
            }
        }
    }
}
finally {
    Remove-BridgeTestSandbox -Sandbox $env:AGENT_HA_BRIDGE_TEST_ROOT -Directory $credentialRoot
}

if ($script:OwnerRightsAssertions -ne 10) {
    throw "The owner-rights matrix did not attempt all ten assertions: $($script:OwnerRightsAssertions)."
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
