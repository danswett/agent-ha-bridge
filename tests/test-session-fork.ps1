#Requires -Version 7.0
<#
.SYNOPSIS
    Tests for bundling a session and installing it as a fork (hooks/session-launch.ps1).

.DESCRIPTION
    Moving a session to another machine installs it under a NEW id rather than the one it
    had. These check that the copy is a session in its own right, that the original is
    left completely alone, and that a damaged bundle is refused before anything is written
    into an agent's home.

    That last one is the sharp edge. Copilot handed `--session-id` for a session whose
    files are missing does not fail: it starts a new, empty session under that id and
    exits 0, which the daemon would then adopt as a successful resume. So the digest has
    to be checked before the write, not after.

    Everything runs against temporary agent homes. No Home Assistant, no broker, no agent
    CLI, no network.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$env:AGENT_BRIDGE_DAEMON_NORUN = '1'
# decision-bridge-common too: the bundle spec sanitises the session id with
# Get-CopilotSafeSessionKey, which lives there. The daemon loads them together, and a
# test loading only one would pass on a function that cannot run in production.
. (Join-Path $PSScriptRoot '..\hooks\decision-bridge-common.ps1')
. (Join-Path $PSScriptRoot '..\hooks\session-launch.ps1')

$script:Failures = 0
function Test-That {
    param([string]$Name, [scriptblock]$Check, [string]$Detail = '')
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $Detail = "threw: $($_.Exception.Message)" }
    if ($ok) { Write-Host "  PASS  $Name" }
    else { Write-Host "  FAIL  $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:Failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "bridge-fork-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
New-Item -ItemType Directory -Path $root -Force | Out-Null
$oldId = 'aaaaaaaa-1111-2222-3333-444444444444'
$marker = 'PINEAPPLE-ANCHOR-7741'

try {
    # --- a source machine with one session of each kind -------------------------------
    $srcCopilot = Join-Path $root 'src-copilot'
    $dir = Join-Path $srcCopilot "session-state\$oldId"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir 'events.jsonl') -Value @(
        "{`"type`":`"session.start`",`"data`":{`"sessionId`":`"$oldId`"}}"
        "{`"type`":`"user.message`",`"data`":{`"content`":`"$marker`"}}"
    )
    Set-Content -Path (Join-Path $dir 'workspace.yaml') -Value @(
        "id: $oldId"
        'cwd: C:\on\the\other\machine'
        'name: Transferred session'
    )
    Set-Content -Path (Join-Path $dir 'huge-working-file.bin') -Value ('x' * 5000)

    $srcClaude = Join-Path $root 'src-claude'
    $cdir = Join-Path $srcClaude 'projects\-Users-someone-else-repo'
    New-Item -ItemType Directory -Path $cdir -Force | Out-Null
    Set-Content -Path (Join-Path $cdir "$oldId.jsonl") -Value "{`"type`":`"user`",`"sessionId`":`"$oldId`",`"message`":{`"content`":`"$marker`"}}"

    $srcCodex = Join-Path $root 'src-codex'
    $xdir = Join-Path $srcCodex 'sessions\2026\01\05'
    New-Item -ItemType Directory -Path $xdir -Force | Out-Null
    Set-Content -Path (Join-Path $xdir "rollout-2026-01-05T01-02-03-$oldId.jsonl") -Value @(
        "{`"type`":`"session_meta`",`"payload`":{`"id`":`"$oldId`",`"cwd`":`"/elsewhere`"}}"
        "{`"type`":`"user_message`",`"payload`":{`"type`":`"user_message`",`"message`":`"$marker`"}}"
    )

    function Get-BridgeLauncherPath { param($Launcher) $null }   # version lookup stays offline

    Write-Host '--- what counts as the session ---'

    $env:COPILOT_HOME = $srcCopilot
    $spec = Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'copilot'
    Test-That 'a Copilot session is its transcript and workspace record' {
        @($spec.Files | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) -join ',' -eq 'events.jsonl,workspace.yaml'
    }
    Test-That 'and not its working files, which can run to hundreds of megabytes' {
        @($spec.Files | Where-Object { $_ -like '*huge-working-file*' }).Count -eq 0
    }
    Test-That 'a session that is not there yields nothing rather than a guess' {
        $null -eq (Get-BridgeSessionBundleSpec -SessionId 'ffffffff-0000-0000-0000-000000000000' -Launcher 'copilot')
    }
    $env:CLAUDE_CONFIG_DIR = $srcClaude
    Test-That 'a Claude session is found wherever its project folder happens to be' {
        @((Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'claude').Files).Count -eq 1
    }
    $env:CODEX_HOME = $srcCodex
    Test-That 'a Codex session is found by the id in its rollout name' {
        @((Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'codex').Files).Count -eq 1
    }

    Write-Host '--- bundling leaves the original completely alone ---'

    $out = Join-Path $root 'bundles'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $env:COPILOT_HOME = $srcCopilot
    $before = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { "$($_.Name):$($_.Length)" } | Sort-Object)
    $manifest = New-BridgeSessionBundle -SessionId $oldId -Launcher 'copilot' -Destination $out
    $after = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { "$($_.Name):$($_.Length)" } | Sort-Object)

    Test-That 'the source files are untouched - nothing renamed, nothing removed' { ($before -join '|') -eq ($after -join '|') }
    Test-That 'the source session is still resumable where it always was' {
        $null -ne (Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'copilot')
    }
    Test-That 'the bundle carries a digest' { $manifest.Sha256 -and $manifest.Sha256.Length -eq 64 }
    Test-That 'and no staging directory is left behind' {
        @(Get-ChildItem -LiteralPath $out -Directory -Filter 'stage-*').Count -eq 0
    }

    Write-Host '--- a damaged bundle is refused before anything is written ---'

    $target = Join-Path $root 'target-copilot'
    $env:COPILOT_HOME = $target
    New-Item -ItemType Directory -Path (Join-Path $target 'session-state') -Force | Out-Null

    $tampered = Join-Path $out 'tampered.zip'
    Copy-Item -LiteralPath $manifest.Path -Destination $tampered -Force
    Add-Content -Path $tampered -Value 'corruption'
    $threw = $false
    try { Install-BridgeSessionBundle -BundlePath $tampered -Manifest $manifest | Out-Null } catch { $threw = $true }
    Test-That 'a digest mismatch refuses the install' { $threw }
    Test-That 'and writes no session into the agent home - no empty session to adopt' {
        @(Get-ChildItem -LiteralPath (Join-Path $target 'session-state') -Directory -ErrorAction SilentlyContinue).Count -eq 0
    }
    $threw = $false
    try { Install-BridgeSessionBundle -BundlePath (Join-Path $out 'does-not-exist.zip') -Manifest $manifest | Out-Null } catch { $threw = $true }
    Test-That 'a missing bundle refuses too' { $threw }

    # The reviewer's case: a digest proves the archive arrived intact, not that there
    # was a session in it. An empty-but-valid archive used to create the directory and
    # hand back an id - and Copilot against an empty directory starts a new empty
    # session and exits 0, which is the fail-open this whole design exists to avoid.
    $emptyStage = Join-Path $root 'empty-stage'
    New-Item -ItemType Directory -Path $emptyStage -Force | Out-Null
    $emptyZip = Join-Path $out 'empty.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($emptyStage, $emptyZip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $emptyManifest = [pscustomobject]@{
        SessionId = $oldId; Kind = 'copilot'
        Sha256 = (Get-FileHash -LiteralPath $emptyZip -Algorithm SHA256).Hash
    }
    $before = @(Get-ChildItem -LiteralPath (Join-Path $target 'session-state') -Directory -ErrorAction SilentlyContinue).Count
    $threw = $false
    try { Install-BridgeSessionBundle -BundlePath $emptyZip -Manifest $emptyManifest | Out-Null } catch { $threw = $true }
    Test-That 'an empty but digest-valid bundle is refused, not installed' { $threw }
    Test-That 'and leaves no session behind for the launcher to find' {
        @(Get-ChildItem -LiteralPath (Join-Path $target 'session-state') -Directory -ErrorAction SilentlyContinue).Count -eq $before
    }

    Write-Host '--- a crafted session id cannot reach outside the session store ---'
    # Session ids arrive from another machine's payload and build paths and a -Filter.
    foreach ($bad in @('..\..\secret', '*', 'a/../../b', '....//etc')) {
        Test-That "a crafted id '$bad' finds nothing rather than walking out" {
            $null -eq (Get-BridgeSessionBundleSpec -SessionId $bad -Launcher 'copilot') -and
            $null -eq (Get-BridgeSessionBundleSpec -SessionId $bad -Launcher 'claude') -and
            $null -eq (Get-BridgeSessionBundleSpec -SessionId $bad -Launcher 'codex')
        }
    }
    Test-That 'and a real UUID still resolves, so the guard is not simply refusing everything' {
        $env:COPILOT_HOME = $srcCopilot
        $ok = $null -ne (Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'copilot')
        $env:COPILOT_HOME = $target
        $ok
    }

    Write-Host '--- installing is a fork, so no two machines hold one id ---'

    $newId = Install-BridgeSessionBundle -BundlePath $manifest.Path -Manifest $manifest -WorkingDirectory 'C:\here\now'
    $newDir = Join-Path $target "session-state\$newId"

    Test-That 'the copy gets an id of its own' { $newId -ne $oldId -and $newId -match '^[0-9a-f-]{36}$' }
    Test-That 'and lands under that id' { [IO.Directory]::Exists($newDir) }
    Test-That 'the conversation survived the move' {
        (Get-Content (Join-Path $newDir 'events.jsonl') -Raw).Contains($marker)
    }
    Test-That 'the old id is gone from inside the copy, so it is consistently its own session' {
        -not (Get-Content (Join-Path $newDir 'events.jsonl') -Raw).Contains($oldId) -and
        -not (Get-Content (Join-Path $newDir 'workspace.yaml') -Raw).Contains($oldId)
    }
    Test-That 'the workspace record points at the directory it will actually run in' {
        @(Get-Content (Join-Path $newDir 'workspace.yaml')) -contains 'cwd: C:\here\now'
    }
    Test-That 'the original is STILL there on the source machine, untouched' {
        $env:COPILOT_HOME = $srcCopilot
        $still = $null -ne (Get-BridgeSessionBundleSpec -SessionId $oldId -Launcher 'copilot')
        $env:COPILOT_HOME = $target
        $still
    }
    Test-That 'two installs of the same bundle produce two distinct sessions, not a collision' {
        $a = Install-BridgeSessionBundle -BundlePath $manifest.Path -Manifest $manifest
        $b = Install-BridgeSessionBundle -BundlePath $manifest.Path -Manifest $manifest
        $a -ne $b -and [IO.Directory]::Exists((Join-Path $target "session-state\$a")) -and [IO.Directory]::Exists((Join-Path $target "session-state\$b"))
    }
    Test-That 'and no unpack directory is left in temp' {
        @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'bridge-unpack-*' -ErrorAction SilentlyContinue).Count -eq 0
    }

    Write-Host '--- the same for Claude and Codex, whose identity is their filename ---'

    $env:CLAUDE_CONFIG_DIR = $srcClaude
    $cm = New-BridgeSessionBundle -SessionId $oldId -Launcher 'claude' -Destination $out
    $tClaude = Join-Path $root 'target-claude'
    $env:CLAUDE_CONFIG_DIR = $tClaude
    $cNew = Install-BridgeSessionBundle -BundlePath $cm.Path -Manifest $cm -WorkingDirectory 'C:\here\now'
    $cFile = Get-ChildItem -LiteralPath (Join-Path $tClaude 'projects') -Filter '*.jsonl' -Recurse -File | Select-Object -First 1
    Test-That 'a Claude copy is named for its new id, which is how Claude finds it' { $cFile.BaseName -eq $cNew }
    Test-That 'and carries the conversation, with the old id rewritten' {
        $t = Get-Content $cFile.FullName -Raw; $t.Contains($marker) -and -not $t.Contains($oldId)
    }

    $env:CODEX_HOME = $srcCodex
    $xm = New-BridgeSessionBundle -SessionId $oldId -Launcher 'codex' -Destination $out
    $tCodex = Join-Path $root 'target-codex'
    $env:CODEX_HOME = $tCodex
    $xNew = Install-BridgeSessionBundle -BundlePath $xm.Path -Manifest $xm
    $xFile = Get-ChildItem -LiteralPath (Join-Path $tCodex 'sessions') -Filter 'rollout-*.jsonl' -Recurse -File | Select-Object -First 1
    Test-That 'a Codex copy keeps the rollout- prefix and its new id, which is how Codex finds it' {
        $xFile.Name -like 'rollout-*' -and $xFile.Name.EndsWith("$xNew.jsonl")
    }
    Test-That 'and carries the conversation, with the old id rewritten' {
        $t = Get-Content $xFile.FullName -Raw; $t.Contains($marker) -and -not $t.Contains($oldId)
    }
}
finally {
    foreach ($v in 'COPILOT_HOME', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME') { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -gt 0) { Write-Host "$($script:Failures) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
