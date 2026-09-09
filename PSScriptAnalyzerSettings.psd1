@{
    # This is an interactive console tool: Write-Host is the output channel, and
    # the state-changing helpers are internal, not exported cmdlets.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
