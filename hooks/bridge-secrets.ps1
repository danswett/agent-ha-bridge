function ConvertTo-BridgeHomeAssistantUrl {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    $text = ([string]$Value).Trim()
    $uri = $null
    if (-not $text -or $text -match '[\s\\]' -or
        -not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Home Assistant URL must be an absolute HTTP(S) URL without user info, a query, or a fragment.'
    }
    $uri.AbsoluteUri.TrimEnd('/')
}

function Read-BridgeSecret {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$InputRedirected = [Console]::IsInputRedirected)
    if ($InputRedirected) {
        # Read-Host's secure reader requires a terminal on some platforms. Console
        # stdin does not echo or transcribe the piped value, and preserves automation.
        Write-Host "${Prompt}: " -NoNewline
        return [Console]::ReadLine()
    }
    $secret = Read-Host -Prompt $Prompt -AsSecureString
    try { [Net.NetworkCredential]::new('', $secret).Password }
    finally { if ($secret) { $secret.Dispose() } }
}

function Test-BridgeUnixModeApi {
    $null -ne [IO.File].GetMethod('GetUnixFileMode', [type[]]@([string]))
}

function Get-BridgeSecretUnixMode {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-BridgeUnixModeApi) { return [int][IO.File]::GetUnixFileMode($Path) }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $mode = if ($IsMacOS) { & /usr/bin/stat -f '%Lp' $fullPath 2>$null }
            else { & /usr/bin/stat -c '%a' $fullPath 2>$null }
    if ($LASTEXITCODE -ne 0 -or [string]$mode -notmatch '^[0-7]{3,4}$') {
        throw 'Could not read Unix credential-file permissions with stat.'
    }
    [Convert]::ToInt32([string]$mode, 8)
}

function Set-BridgeSecretUnixMode {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('600', '700')][string]$Mode)
    if (Test-BridgeUnixModeApi) {
        [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode][Convert]::ToInt32($Mode, 8))
        return
    }
    & /bin/chmod $Mode ([IO.Path]::GetFullPath($Path)) 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not restrict Unix credential-file permissions with chmod.' }
}

function Test-BridgeSecretFileProtected {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        if (-not $script:BridgeIsWindows) {
            $mode = if ($item.PSIsContainer) { '700' } else { '600' }
            return (Get-BridgeSecretUnixMode -Path $Path) -eq [Convert]::ToInt32($mode, 8)
        }
        $acl = Get-Acl -LiteralPath $Path
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $acl.AreAccessRulesProtected -or
            $acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $me) { return $false }
        $rules = @($acl.Access)
        if ($rules.Count -ne 1) { return $false }
        $rule = $rules[0]
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $me) { return $false }
        $full = [Security.AccessControl.FileSystemRights]::FullControl
        if (($rule.FileSystemRights -band $full) -ne $full) { return $false }
        if ($item.PSIsContainer) {
            $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            return $rule.InheritanceFlags -eq $inherit -and
                $rule.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None
        }
        return $true
    }
    catch { return $false }
}

function Protect-BridgeSecretFile {
    param([Parameter(Mandatory)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if (Test-BridgeSecretFileProtected -Path $Path) { return $true }
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warning 'Credential files must be regular files or directories, not symbolic links or reparse points.'
            return $false
        }
        if (-not $script:BridgeIsWindows) {
            Set-BridgeSecretUnixMode -Path $Path -Mode $(if ($item.PSIsContainer) { '700' } else { '600' })
        }
        else {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
            # Do not request the SACL: re-hardening must work without SeSecurityPrivilege.
            $sections = [Security.AccessControl.AccessControlSections]'Access, Owner'
            $acl = [IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleAll($rule) }
            $inherit = if ($item.PSIsContainer) {
                [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
            } else { [Security.AccessControl.InheritanceFlags]::None }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                $me, [Security.AccessControl.FileSystemRights]::FullControl, $inherit,
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
            # DACL repair needs WRITE_DAC; marking even the same owner for
            # persistence additionally requests WRITE_OWNER.
            if ($acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $me) {
                $acl.SetOwner($me)
            }
            [IO.FileSystemAclExtensions]::SetAccessControl($item, $acl)
        }
        return Test-BridgeSecretFileProtected -Path $Path
    }
    catch {
        Write-Warning 'Could not restrict credential-file access. Check ownership, filesystem permissions, and PowerShell support.'
        return $false
    }
}

function Initialize-BridgeSecretFile {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $missing = [Collections.Generic.List[string]]::new()
    while (-not [IO.Directory]::Exists($parent)) {
        if (-not $parent -or [IO.File]::Exists($parent)) { throw 'The credential directory is not available.' }
        $missing.Add($parent)
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    for ($i = $missing.Count - 1; $i -ge 0; $i--) {
        [void][IO.Directory]::CreateDirectory($missing[$i])
        if (-not (Protect-BridgeSecretFile -Path $missing[$i])) {
            throw 'Could not protect the new credential directory; no credential contents were written.'
        }
    }
    if (-not (Test-Path -LiteralPath $fullPath)) {
        # An empty file may inherit permissions briefly; no secret bytes exist until
        # protection succeeds. CreateNew never truncates a file that appeared meanwhile.
        $empty = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $empty.Dispose()
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
        -not (Protect-BridgeSecretFile -Path $fullPath)) {
        throw 'Could not protect the credential file; no new contents were written.'
    }
}

function Write-BridgeSecretFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    Initialize-BridgeSecretFile -Path $Path
    try { [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false)) }
    catch { throw 'Credential-file write failed. Check available space and file permissions before retrying.' }
}

function Copy-BridgeSecretFile {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)

    if (-not (Protect-BridgeSecretFile -Path $Source)) {
        throw 'Could not protect the original credential file; no backup was written.'
    }
    Initialize-BridgeSecretFile -Path $Destination
    try { [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source)) }
    catch { throw 'Credential backup failed. Check available space and file permissions before retrying.' }
}
