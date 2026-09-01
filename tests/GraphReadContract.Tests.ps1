<#
.SYNOPSIS
    Pester tests for the contract between the logger and any function that returns data.

.DESCRIPTION
    Orchestration.Tests.ps1 mocks both Write-Log and Get-GuestUser. That pair of mocks
    meant neither the logger's choice of stream nor the guest read's return shape was ever
    exercised, and together they hid a bug that made the job evaluate seven records instead
    of the tenant's guests and action nothing at all.

    Write-Log used Write-Output. The success stream IS a function's return value, so every
    log line a data-returning function wrote came back to its caller. Get-GuestUser handed
    back six log strings plus one array holding every guest.

    These tests use the real Write-Log and the real Get-GuestUser, and mock only the HTTP
    layer underneath them.

.EXAMPLE
    Invoke-Pester -Path .\tests\GraphReadContract.Tests.ps1

.NOTES
    Requires: Pester 5.x or later. No network and no tenant.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1')
}

Describe 'Write-Log never writes to the success stream' {

    It 'leaves an INFO-logging function returning only its data' {
        function Get-ThingInfo {
            Write-Log 'reading something'
            return @(1, 2, 3)
        }

        @(Get-ThingInfo).Count | Should -Be 3
    }

    It 'leaves a SUCCESS-logging function returning only its data' {
        function Get-ThingSuccess {
            Write-Log 'read something' -Level SUCCESS
            return @(1, 2, 3)
        }

        @(Get-ThingSuccess).Count | Should -Be 3
    }

    It 'survives many log lines around the data' {
        function Get-ThingChatty {
            Write-Log 'starting'
            1..10 | ForEach-Object { Write-Log "progress $_" }
            $data = @('a', 'b')
            Write-Log "read $($data.Count) items" -Level SUCCESS
            return $data
        }

        $result = @(Get-ThingChatty)
        $result.Count | Should -Be 2
        $result | Should -Not -Contain 'starting'
        ($result | Where-Object { $_ -is [string] -and $_ -match '\[INFO\]' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GuestUser return contract' {

    BeforeEach {
        $script:page1 = @{
            value             = @(1..100 | ForEach-Object { @{ id = "g$_"; userPrincipalName = "g$_@example.com" } })
            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=page2'
        }
        $script:page2 = @{
            value = @(101..150 | ForEach-Object { @{ id = "g$_"; userPrincipalName = "g$_@example.com" } })
        }
        $script:pageCalls = 0
    }

    It 'returns one object per guest across every page' {
        Mock -CommandName Invoke-GraphRequestWithRetry -MockWith {
            $script:pageCalls++
            if ($script:pageCalls -eq 1) { $script:page1 } else { $script:page2 }
        }

        $guests = @(Get-GuestUser)

        $guests.Count | Should -Be 150
        $script:pageCalls | Should -Be 2
    }

    It 'returns no log strings among the guests' {
        Mock -CommandName Invoke-GraphRequestWithRetry -MockWith {
            $script:pageCalls++
            if ($script:pageCalls -eq 1) { $script:page1 } else { $script:page2 }
        }

        $guests = @(Get-GuestUser)

        ($guests | Where-Object { $_ -is [string] }) | Should -BeNullOrEmpty
    }

    It 'returns guests that still carry their identifying fields' {
        Mock -CommandName Invoke-GraphRequestWithRetry -MockWith {
            $script:pageCalls++
            if ($script:pageCalls -eq 1) { $script:page1 } else { $script:page2 }
        }

        $guests = @(Get-GuestUser)

        $guests[0].id                | Should -Be 'g1'
        $guests[149].id              | Should -Be 'g150'
        $guests[0].userPrincipalName | Should -Be 'g1@example.com'
    }

    It 'converts every guest to a usable record rather than collapsing them into one' {
        # This is the assertion that would have caught the original bug end to end: the
        # guest list must survive the hop from Get-GuestUser into ConvertTo-GuestRecord.
        Mock -CommandName Invoke-GraphRequestWithRetry -MockWith {
            $script:pageCalls++
            if ($script:pageCalls -eq 1) { $script:page1 } else { $script:page2 }
        }

        $raw     = Get-GuestUser
        $records = @(foreach ($g in $raw) { ConvertTo-GuestRecord -Guest $g })

        $records.Count | Should -Be 150
        @($records | Where-Object { $_.Id }).Count | Should -Be 150
    }

    It 'returns an empty result, not a log line, when the tenant has no guests' {
        Mock -CommandName Invoke-GraphRequestWithRetry -MockWith { @{ value = @() } }

        @(Get-GuestUser).Count | Should -Be 0
    }
}
