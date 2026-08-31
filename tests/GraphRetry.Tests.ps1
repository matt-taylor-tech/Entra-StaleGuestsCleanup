<#
.SYNOPSIS
    Pester tests for Invoke-GraphRequestWithRetry and the paging helper.

.DESCRIPTION
    This path had no coverage at all. The other test files mock Get-GuestUser,
    Disable-GuestAccount and Remove-GuestAccount, which sit above the retry wrapper, so
    nothing exercised the wrapper itself or the paging loop underneath it.

    That mattered: an earlier version of the wrapper took a scriptblock that splatted a
    variable belonging to the calling function. It worked only because the caller happened
    to be in the scope chain. Called from anywhere else the splat resolved to an empty
    hashtable and the request went out with no method and no URI, with no error raised.

    Invoke-MgGraphRequest belongs to a module that need not be installed to run these, so
    a stub is defined and then mocked.

.EXAMPLE
    Invoke-Pester -Path .\tests\GraphRetry.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1')

    # Stand-in for the real cmdlet, so Mock has something to replace.
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $Body, $Headers, $ErrorAction)
        throw 'the stub should always be mocked'
    }

    function New-ThrottleError {
        <# An error that looks like a Graph 429 to the wrapper's own test. #>
        param([string]$Message = 'Response status code does not indicate success: 429 (Too Many Requests).')
        return [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($Message), 'Throttled',
            [System.Management.Automation.ErrorCategory]::LimitsExceeded, $null)
    }
}

Describe 'Invoke-GraphRequestWithRetry' {

    BeforeEach {
        # Never actually sleep in a test.
        Mock -CommandName Start-Sleep -MockWith { }
        Mock -CommandName Write-Log   -MockWith { }
    }

    It 'passes the method and URI through, which the old scriptblock version could silently lose' {
        $script:seen = $null
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            $script:seen = @{ Method = $Method; Uri = $Uri }
            return @{ value = @() }
        }

        Invoke-GraphRequestWithRetry -Method GET -Uri 'https://graph.microsoft.com/v1.0/users' | Out-Null

        $script:seen.Method | Should -Be 'GET'
        $script:seen.Uri    | Should -Be 'https://graph.microsoft.com/v1.0/users'
    }

    It 'passes a body through on a write' {
        $script:body = $null
        Mock -CommandName Invoke-MgGraphRequest -MockWith { $script:body = $Body }

        Invoke-GraphRequestWithRetry -Method PATCH -Uri 'https://graph/x' -Body @{ accountEnabled = $false } | Out-Null

        $script:body.accountEnabled | Should -BeFalse
    }

    It 'returns the response on the first attempt when nothing goes wrong' {
        Mock -CommandName Invoke-MgGraphRequest -MockWith { return @{ ok = $true } }

        (Invoke-GraphRequestWithRetry -Uri 'https://graph/x').ok | Should -BeTrue
        Should -Invoke -CommandName Invoke-MgGraphRequest -Times 1
        Should -Invoke -CommandName Start-Sleep -Times 0
    }

    It 'retries a throttled call and returns the eventual success' {
        $script:calls = 0
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            $script:calls++
            if ($script:calls -lt 3) { throw (New-ThrottleError) }
            return @{ ok = $true }
        }

        (Invoke-GraphRequestWithRetry -Uri 'https://graph/x').ok | Should -BeTrue
        $script:calls | Should -Be 3
        Should -Invoke -CommandName Start-Sleep -Times 2
    }

    It 'gives up after MaxAttempts and rethrows' {
        Mock -CommandName Invoke-MgGraphRequest -MockWith { throw (New-ThrottleError) }

        { Invoke-GraphRequestWithRetry -Uri 'https://graph/x' -MaxAttempts 3 } | Should -Throw
        Should -Invoke -CommandName Invoke-MgGraphRequest -Times 3
    }

    It 'does not retry an error that is not throttling' {
        # A 404 or a permission problem must fail at once. Retrying it wastes the run and
        # hides the real cause.
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            throw [System.Exception]::new('Insufficient privileges to complete the operation.')
        }

        { Invoke-GraphRequestWithRetry -Uri 'https://graph/x' } | Should -Throw
        Should -Invoke -CommandName Invoke-MgGraphRequest -Times 1
        Should -Invoke -CommandName Start-Sleep -Times 0
    }

    It 'treats a service unavailable message as retryable' {
        $script:calls = 0
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            $script:calls++
            if ($script:calls -eq 1) { throw [System.Exception]::new('503 Service Unavailable') }
            return @{ ok = $true }
        }

        (Invoke-GraphRequestWithRetry -Uri 'https://graph/x').ok | Should -BeTrue
        $script:calls | Should -Be 2
    }
}

Describe 'Invoke-GraphGetAll' {

    BeforeEach {
        Mock -CommandName Write-Log -MockWith { }
        Mock -CommandName Start-Sleep -MockWith { }
    }

    It 'follows nextLink until the pages run out' {
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            switch ($Uri) {
                'page1' { return @{ value = @(@{ id = 'a' }, @{ id = 'b' }); '@odata.nextLink' = 'page2' } }
                'page2' { return @{ value = @(@{ id = 'c' }); '@odata.nextLink' = 'page3' } }
                'page3' { return @{ value = @(@{ id = 'd' }) } }
            }
        }

        $result = Invoke-GraphGetAll -Uri 'page1'
        $result.Count | Should -Be 4
        $result[0].id | Should -Be 'a'
        $result[3].id | Should -Be 'd'
        Should -Invoke -CommandName Invoke-MgGraphRequest -Times 3
    }

    It 'returns an array for a single result, not a bare object' {
        # Returning the List let PowerShell unroll it, so one result came back as the
        # object itself and no results came back as $null.
        Mock -CommandName Invoke-MgGraphRequest -MockWith { return @{ value = @(@{ id = 'only' }) } }

        $result = Invoke-GraphGetAll -Uri 'page1'
        $result -is [array] | Should -BeTrue
        $result.Count      | Should -Be 1
    }

    It 'returns an empty array when there are no results, not null' {
        Mock -CommandName Invoke-MgGraphRequest -MockWith { return @{ value = @() } }

        $result = Invoke-GraphGetAll -Uri 'page1'
        $null -eq $result | Should -BeFalse
        $result.Count     | Should -Be 0
    }

    It 'sends the headers it was given' {
        $script:seenHeaders = $null
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            $script:seenHeaders = $Headers
            return @{ value = @() }
        }

        Invoke-GraphGetAll -Uri 'page1' -Headers @{ ConsistencyLevel = 'eventual' } | Out-Null
        $script:seenHeaders.ConsistencyLevel | Should -Be 'eventual'
    }

    It 'retries a throttled page rather than losing the whole read' {
        $script:attempts = 0
        Mock -CommandName Invoke-MgGraphRequest -MockWith {
            $script:attempts++
            if ($script:attempts -eq 1) { throw [System.Exception]::new('429 Too Many Requests') }
            return @{ value = @(@{ id = 'a' }) }
        }

        (Invoke-GraphGetAll -Uri 'page1').Count | Should -Be 1
        $script:attempts | Should -Be 2
    }
}
