# This boundary has no configuration dependency: the installer must not load the
# runtime (or an installed credential) just to refuse an unstubbed test transport.
if (-not (Get-Variable -Name BridgeUnderTestSuite -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BridgeUnderTestSuite = $false
}
if (-not (Get-Variable -Name BridgeBlockedHttpCalls -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BridgeBlockedHttpCalls = 0
}
foreach ($bridgeTestFrame in Get-PSCallStack) {
    if ([string]$bridgeTestFrame.ScriptName -match '[\\/]test-[^\\/]+\.ps1$') {
        $script:BridgeUnderTestSuite = $true
        break
    }
}

function Assert-BridgeHttpAllowed {
    <#
        Refuses unstubbed Home Assistant transports in tests, including descendants
        that no longer have a suite on their call stack. A REST stub does not replace
        WebRequest, WebSocket, DNS discovery or a separately launched checker.

        Keep this outside transport catches. The exception marker lets best-effort
        callers propagate a test-boundary violation without changing normal failures.
    #>
    param(
        [string]$Uri,
        [ValidateSet('Rest', 'WebRequest', 'WebSocket', 'Discovery', 'ChildProcess')]
        [string]$Transport = 'Rest'
    )

    $offline = $env:AGENT_HA_BRIDGE_OFFLINE_TEST -eq '1'
    if (-not $script:BridgeUnderTestSuite -and -not $offline) { return }
    if (-not $offline -and $env:BRIDGE_ALLOW_TEST_HTTP -eq '1') { return }

    $command = switch ($Transport) {
        'Rest' { 'Invoke-RestMethod' }
        'WebRequest' { 'Invoke-WebRequest' }
    }
    if ($command) {
        $sender = Get-Command -Name $command -ErrorAction SilentlyContinue
        if ($sender -and $sender.CommandType -in @('Function', 'Filter')) { return }
    }

    # The Host suite deliberately exercises connection-refused results at this one
    # endpoint. Only the gated runner supplies this opt-in; it never permits DNS,
    # another port/host, or any network access from Offline/Platform suites.
    if ($offline -and $env:AGENT_HA_BRIDGE_TEST_GROUP -eq 'Host' -and
        $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and
        $env:AGENT_HA_BRIDGE_TEST_LOOPBACK_ORIGIN -ceq 'http://127.0.0.1:1') {
        # The checker inherits the same boundary; each of its actual requests must
        # still match the endpoint below, even if it loads the wrong configuration.
        if ($Transport -eq 'ChildProcess') { return }
        $endpoint = $null
        if ($Transport -ne 'Discovery' -and [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$endpoint) -and
            $endpoint.Scheme -in @('http', 'ws') -and $endpoint.Host -ceq '127.0.0.1' -and
            $endpoint.Port -eq 1 -and -not $endpoint.UserInfo) { return }
    }

    $script:BridgeBlockedHttpCalls++
    $exception = [InvalidOperationException]::new(
        "A test suite tried to reach a real Home Assistant$(if ($Uri) { " at $Uri" }) ($Transport). " +
        'Stub the function that makes the call, and define the stub above the code ' +
        'under test - PowerShell binds a function as it executes, so a stub written ' +
        'below the call it is meant to intercept does nothing. An integration test ' +
        'that means to use a real Home Assistant sets BRIDGE_ALLOW_TEST_HTTP=1 outside the offline runner.')
    $exception.Data['BridgeTestNetworkBlocked'] = $true
    throw $exception
}
