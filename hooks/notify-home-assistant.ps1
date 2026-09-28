<#
    Mirrors a Copilot permission prompt to Home Assistant as a one-way alert.

    Wired to the `notification` hook with a `permission_prompt` matcher; what it does is
    Invoke-CopilotPermissionHook (copilot-hooks.ps1). It is purely informational - the
    prompt is still answered in the terminal - so a delivery failure is swallowed, and
    it always replies `{}`.
#>

$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot 'decision-bridge-common.ps1')
    . (Join-Path $PSScriptRoot 'copilot-hooks.ps1')

    $rawEvent = [Console]::In.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($rawEvent)) {
        Invoke-CopilotPermissionHook -HookEvent ($rawEvent | ConvertFrom-Json) | Out-Null
    }
}
catch {
    try {
        Write-DecisionBridgeLog -Message "permission notification failed: $($_.Exception.Message)"
    }
    catch {
        # Notification delivery must never affect the session.
    }
}

Write-Output '{}'
