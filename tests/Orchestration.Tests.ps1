<#
.SYNOPSIS
    Pester tests for the run orchestration in Invoke-StaleGuestCleanup.ps1.

.DESCRIPTION
    The decision logic is covered by StaleGuestLogic.Tests.ps1. This file covers the
    safety rails around it, which are the parts that decide how much damage a wrong
    parameter can do:

        report-only mode changes nothing
        the per-run caps hold, and the oldest accounts go first
        the abort ceiling stops the run and changes nothing
        the null sign-in data guard fires instead of deleting the directory
        exclusions survive the whole pipeline, not just the decision function

    Every Graph call is mocked, so no tenant is touched.

.EXAMPLE
    Invoke-Pester -Path .\tests\Orchestration.Tests.ps1

.NOTES
    Requires: Pester 5.x or later
#>

BeforeAll {
    . (Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1')

    function New-GuestFixture {
        <# A guest as Graph would return it, aged a given number of days. #>
        param(
            [int]$InactiveDays,
            [switch]$NeverSignedIn,
            [bool]$Enabled = $true,
            [string]$Id,
            [string]$Upn,
            [string]$Mail
        )

        $stamp = [datetime]::UtcNow.AddDays(-$InactiveDays).ToString('o')

        $guest = @{
            id                = $Id
            displayName       = "Guest $Id"
            userPrincipalName = $Upn
            mail              = $Mail
            companyName       = 'Fixture Co'
            externalUserState = if ($NeverSignedIn) { 'PendingAcceptance' } else { 'Accepted' }
            accountEnabled    = $Enabled
            createdDateTime   = $stamp
            signInActivity    = $null
        }

        if (-not $NeverSignedIn) {
            $guest['signInActivity'] = @{
                lastSignInDateTime               = $stamp
                lastNonInteractiveSignInDateTime = $null
                lastSuccessfulSignInDateTime     = $null
            }
            # Created well before the last sign-in, so the creation date can never be
            # what makes these fixtures look stale.
            $guest['createdDateTime'] = [datetime]::UtcNow.AddDays(-($InactiveDays + 400)).ToString('o')
        }

        return $guest
    }

    function New-GuestSet {
        <# A population of guests at a given age. #>
        param(
            [int]$Count,
            [int]$InactiveDays,
            [switch]$NeverSignedIn,
            [bool]$Enabled = $true,
            [string]$Prefix = 'g'
        )

        1..$Count | ForEach-Object {
            New-GuestFixture -InactiveDays $InactiveDays -NeverSignedIn:$NeverSignedIn `
                -Enabled $Enabled `
                -Id "$Prefix-$_" -Upn "$Prefix$_@example.com" -Mail "$Prefix$_@example.com"
        }
    }
}

Describe 'Invoke-StaleGuestCleanup orchestration' {

    BeforeEach {
        # Track what the job tried to do to the tenant.
        $script:Disabled = [System.Collections.Generic.List[string]]::new()
        $script:Deleted  = [System.Collections.Generic.List[string]]::new()

        Mock -CommandName Connect-GraphApi              -MockWith { $true }
        Mock -CommandName Get-DirectoryRoleHolderId     -MockWith { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
        Mock -CommandName Get-ExclusionGroupMemberId    -MockWith { [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
        Mock -CommandName Get-GuestMembershipSummary    -MockWith { 'Some Team (Team)' }
        Mock -CommandName Disable-GuestAccount          -MockWith { $script:Disabled.Add($UserId) }
        Mock -CommandName Remove-GuestAccount           -MockWith { $script:Deleted.Add($UserId) }
        Mock -CommandName Write-ReportToBlob            -MockWith { }
        Mock -CommandName Write-ReportToTeams           -MockWith { }

        # Keep the job log out of the test output.
        Mock -CommandName Write-Log -MockWith { }

        $script:Defaults = @{
            DisableAfterDays        = 90
            DeleteAfterDays         = 120
            MaxDisablesPerRun       = 50
            MaxDeletesPerRun        = 50
            AbortIfDeleteCandidatesExceed  = 10000
            AbortIfDisableCandidatesExceed = 10000
            ContainerName           = 'test'
            ReportSink              = @('None')
        }
    }

    Context 'report-only mode' {

        It 'changes nothing, however stale the accounts are' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 20 -InactiveDays 400) + @(New-GuestSet -Count 20 -InactiveDays 95 -Prefix 'd')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Report

            $script:Disabled.Count | Should -Be 0
            $script:Deleted.Count  | Should -Be 0
            Should -Invoke -CommandName Disable-GuestAccount -Times 0
            Should -Invoke -CommandName Remove-GuestAccount  -Times 0
        }

        It 'is the default when no mode is given' {
            # Guards against a future edit that makes Enforce the fallback.
            $scriptParams = (Get-Command (Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1')).Parameters
            $scriptParams['Mode'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateSetAttribute] }).ValidValues |
                Should -Contain 'Report'

            $content = Get-Content (Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1') -Raw
            $content | Should -Match "\`$Mode\s*=\s*'Report'"
        }
    }

    Context 'report mode does not invent deferrals' {

        It 'labels every actionable row as report-only, even past the cap' {
            # The caps only matter when the job acts. Marking rows "Deferred by the per-run
            # cap" in report mode made the first report read as though half the backlog had
            # been handled and the rest queued, when nothing had been touched.
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 120 -InactiveDays 400 }

            $script:capturedRows = $null
            Mock -CommandName Write-ReportToJobLog -MockWith { $script:capturedRows = $Rows }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Report -MaxDeletesPerRun 50 -ReportSink JobLog -AbortIfDeleteCandidatesExceed 10000

            $outcomes = @($script:capturedRows | Where-Object { $_.Action -ne 'NoAction' } | Select-Object -ExpandProperty Outcome -Unique)
            $outcomes.Count | Should -Be 1
            $outcomes[0]    | Should -Be 'Report only, not applied'
            @($script:capturedRows | Where-Object { $_.Outcome -like '*Deferred*' }).Count | Should -Be 0
        }

        It 'reports zero deferred in the summary for a report run' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 120 -InactiveDays 400 }

            $script:capturedSummary = $null
            Mock -CommandName Write-ReportToJobLog -MockWith { $script:capturedSummary = $Summary }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Report -MaxDeletesPerRun 50 -ReportSink JobLog -AbortIfDeleteCandidatesExceed 10000

            $script:capturedSummary.Deleted         | Should -Be 0
            $script:capturedSummary.DeletesDeferred | Should -Be 0
            $script:capturedSummary.DeleteCandidates | Should -Be 120
        }

        It 'still reports deferrals honestly in enforce mode' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 120 -InactiveDays 400 }

            $script:capturedSummary = $null
            Mock -CommandName Write-ReportToJobLog -MockWith { $script:capturedSummary = $Summary }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 50 -ReportSink JobLog -AbortIfDeleteCandidatesExceed 10000

            $script:capturedSummary.Deleted         | Should -Be 50
            $script:capturedSummary.DeletesDeferred | Should -Be 70
        }
    }

    Context 'enforce mode' {

        It 'disables accounts between the two thresholds and deletes those past the second' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 3 -InactiveDays 95  -Prefix 'disable') +
                @(New-GuestSet -Count 2 -InactiveDays 200 -Prefix 'delete')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce

            $script:Disabled.Count | Should -Be 3
            $script:Deleted.Count  | Should -Be 2
            $script:Disabled       | Should -Not -Contain 'delete-1'
            $script:Deleted        | Should -Contain 'delete-1'
        }

        It 'ages a guest that never signed in from its creation date' {
            Mock -CommandName Get-GuestUser -MockWith {
                New-GuestSet -Count 4 -InactiveDays 150 -NeverSignedIn -Prefix 'pending'
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce

            $script:Deleted.Count | Should -Be 4
        }

        It 'reads memberships before deleting, so the audit record is not lost' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 1 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce

            Should -Invoke -CommandName Get-GuestMembershipSummary -Times 1
        }

        It 'skips the membership lookup when asked to' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 1 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -SkipGroupMemberships

            Should -Invoke -CommandName Get-GuestMembershipSummary -Times 0
            $script:Deleted.Count | Should -Be 1
        }

        It 'does not fail the whole run when one account cannot be deleted' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 3 -InactiveDays 200 }
            Mock -CommandName Remove-GuestAccount -MockWith {
                if ($UserId -eq 'g-2') { throw 'Insufficient privileges.' }
                $script:Deleted.Add($UserId)
            }

            # The run still throws at the end, so the Automation alert fires, but the
            # other two accounts are dealt with first.
            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce } | Should -Throw -ExpectedMessage '*failed*'

            $script:Deleted.Count | Should -Be 2
            $script:Deleted | Should -Not -Contain 'g-2'
        }
    }

    Context 'per-run caps' {

        It 'stops at the disable cap' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 30 -InactiveDays 95 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDisablesPerRun 10

            $script:Disabled.Count | Should -Be 10
        }

        It 'stops at the delete cap' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 30 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 7

            $script:Deleted.Count | Should -Be 7
        }

        It 'acts on the most stale accounts first' {
            # So repeated capped runs drain the backlog oldest first, rather than
            # churning the same arbitrary slice.
            Mock -CommandName Get-GuestUser -MockWith {
                @(
                    (New-GuestFixture -InactiveDays 130 -Id 'newest' -Upn 'a@example.com' -Mail 'a@example.com'),
                    (New-GuestFixture -InactiveDays 900 -Id 'oldest' -Upn 'b@example.com' -Mail 'b@example.com'),
                    (New-GuestFixture -InactiveDays 400 -Id 'middle' -Upn 'c@example.com' -Mail 'c@example.com')
                )
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 2

            $script:Deleted | Should -Contain 'oldest'
            $script:Deleted | Should -Contain 'middle'
            $script:Deleted | Should -Not -Contain 'newest'
        }

        It 'caps disables and deletes independently' {
            # The disable slots now go to the most stale accounts across both queues, so
            # here they go to the 200-day delete candidates the delete cap held back, not
            # to the 95-day disable candidates. The caps themselves stay independent.
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 20 -InactiveDays 95  -Prefix 'dis') +
                @(New-GuestSet -Count 20 -InactiveDays 200 -Prefix 'del')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDisablesPerRun 5 -MaxDeletesPerRun 3

            $script:Disabled.Count | Should -Be 5
            $script:Deleted.Count  | Should -Be 3
        }
    }

    Context 'the abort ceilings' {

        It 'freezes the deletes when the delete ceiling is reached, and fails the job' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 60 -InactiveDays 200 }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDeleteCandidatesExceed 50 } |
                Should -Throw -ExpectedMessage '*above the ceiling*'

            $script:Deleted.Count | Should -Be 0
        }

        It 'still disables the accounts it refuses to delete, so the access goes' {
            # This is the point of splitting the ceilings. A single combined ceiling
            # stopped everything, which left the most stale accounts in the directory
            # enabled and usable until somebody intervened by hand.
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 60 -InactiveDays 200 }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDeleteCandidatesExceed 50 } |
                Should -Throw

            $script:Deleted.Count  | Should -Be 0
            $script:Disabled.Count | Should -Be 50
        }

        It 'freezes the disables when the disable ceiling is reached, and fails the job' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 60 -InactiveDays 95 }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDisableCandidatesExceed 50 } |
                Should -Throw -ExpectedMessage '*above the ceiling*'

            $script:Disabled.Count | Should -Be 0
        }

        It 'still deletes when only the disable ceiling is reached' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 60 -InactiveDays 95  -Prefix 'dis') +
                @(New-GuestSet -Count 5  -InactiveDays 200 -Prefix 'del')
            }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDisableCandidatesExceed 50 } |
                Should -Throw

            $script:Disabled.Count | Should -Be 0
            $script:Deleted.Count  | Should -Be 5
        }

        It 'counts each action against its own ceiling, not the combined total' {
            # 30 of each. A single combined ceiling of 50 used to abort on the total of 60.
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 30 -InactiveDays 95  -Prefix 'dis') +
                @(New-GuestSet -Count 30 -InactiveDays 200 -Prefix 'del')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce `
                -AbortIfDeleteCandidatesExceed 50 -AbortIfDisableCandidatesExceed 50

            $script:Deleted.Count  | Should -Be 30
            $script:Disabled.Count | Should -Be 30
        }

        It 'runs normally when both counts are inside their ceilings' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 10 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDeleteCandidatesExceed 50

            $script:Deleted.Count | Should -Be 10
        }

        It 'treats 0 as no ceiling at all' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 60 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce `
                -AbortIfDeleteCandidatesExceed 0 -MaxDeletesPerRun 1000

            $script:Deleted.Count | Should -Be 60
        }
    }

    Context 'delete candidates waiting their turn' {

        It 'disables a delete candidate the per-run cap held back' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 20 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 5

            $script:Deleted.Count  | Should -Be 5
            $script:Disabled.Count | Should -Be 15
        }

        It 'leaves an already disabled one alone' {
            Mock -CommandName Get-GuestUser -MockWith {
                New-GuestSet -Count 20 -InactiveDays 200 -Enabled $false
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 5

            $script:Deleted.Count  | Should -Be 5
            $script:Disabled.Count | Should -Be 0
        }

        It 'holds the interim disables to the disable cap' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 100 -InactiveDays 200 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce `
                -MaxDeletesPerRun 5 -MaxDisablesPerRun 10

            $script:Deleted.Count  | Should -Be 5
            $script:Disabled.Count | Should -Be 10
        }

        It 'neutralises the most stale first, across both queues' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 5 -InactiveDays 95  -Prefix 'young') +
                @(New-GuestSet -Count 5 -InactiveDays 900 -Prefix 'old')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce `
                -MaxDeletesPerRun 0 -MaxDisablesPerRun 5

            @($script:Disabled | Where-Object { $_ -like 'old-*' }).Count   | Should -Be 5
            @($script:Disabled | Where-Object { $_ -like 'young-*' }).Count | Should -Be 0
        }
    }

    Context 'the null sign-in data guard' {

        It 'aborts rather than treating a whole directory of null sign-ins as stale' {
            # AuditLog.Read.All removed: signInActivity comes back null for everyone,
            # every guest reads as never signed in, and without this guard the job
            # would delete the lot.
            Mock -CommandName Get-GuestUser -MockWith {
                1..40 | ForEach-Object {
                    @{
                        id = "n-$_"; displayName = "N$_"; userPrincipalName = "n$_@example.com"
                        mail = "n$_@example.com"; accountEnabled = $true
                        createdDateTime = [datetime]::UtcNow.AddDays(-500).ToString('o')
                        signInActivity = $null
                    }
                }
            }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDeleteCandidatesExceed 10000 } |
                Should -Throw -ExpectedMessage '*AuditLog.Read.All*'

            $script:Deleted.Count | Should -Be 0
        }

        It 'proceeds when at least one guest has a sign-in, so real pending invites are still handled' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestFixture -InactiveDays 5 -Id 'active' -Upn 'a@example.com' -Mail 'a@example.com') +
                @(New-GuestSet -Count 39 -InactiveDays 500 -NeverSignedIn -Prefix 'pending')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -MaxDeletesPerRun 1000 -AbortIfDeleteCandidatesExceed 10000

            $script:Deleted.Count | Should -Be 39
            $script:Deleted | Should -Not -Contain 'active'
        }
    }

    Context 'exclusions through the whole pipeline' {

        It 'never touches a member of the exclusion group' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 3 -InactiveDays 500 }
            Mock -CommandName Get-ExclusionGroupMemberId -MockWith {
                $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                [void]$set.Add('g-2')
                $set
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce

            $script:Deleted.Count | Should -Be 2
            $script:Deleted | Should -Not -Contain 'g-2'
        }

        It 'never touches a holder of a directory role' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 3 -InactiveDays 500 }
            Mock -CommandName Get-DirectoryRoleHolderId -MockWith {
                $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                [void]$set.Add('g-1')
                $set
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce

            $script:Deleted | Should -Not -Contain 'g-1'
            $script:Deleted.Count | Should -Be 2
        }

        It 'never touches an excluded domain' {
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestFixture -InactiveDays 500 -Id 'keep' -Upn 'x@keep.com'  -Mail 'x@keep.com') +
                @(New-GuestFixture -InactiveDays 500 -Id 'go'   -Upn 'y@other.com' -Mail 'y@other.com')
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -ExcludeDomains @('keep.com')

            $script:Deleted | Should -Be @('go')
        }

        It 'excluded accounts do not count towards the abort ceiling' {
            # Otherwise a large, correctly excluded partner domain would block every run.
            Mock -CommandName Get-GuestUser -MockWith {
                @(New-GuestSet -Count 40 -InactiveDays 500 -Prefix 'keep') +
                @(New-GuestSet -Count 2  -InactiveDays 500 -Prefix 'go')
            }
            Mock -CommandName Get-ExclusionGroupMemberId -MockWith {
                $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                1..40 | ForEach-Object { [void]$set.Add("keep-$_") }
                $set
            }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -AbortIfDeleteCandidatesExceed 10

            $script:Deleted.Count | Should -Be 2
        }
    }

    Context 'guard rails on the parameters themselves' {

        It 'refuses to run when the delete threshold is below the disable threshold' {
            # Otherwise an account would be deleted before it was ever disabled.
            Mock -CommandName Get-GuestUser -MockWith { @() }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -DisableAfterDays 120 -DeleteAfterDays 90 } |
                Should -Throw -ExpectedMessage '*cannot be lower than*'
        }

        It 'does nothing gracefully when the tenant has no guests' {
            Mock -CommandName Get-GuestUser -MockWith { @() }

            { Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce } | Should -Not -Throw
            $script:Deleted.Count | Should -Be 0
        }
    }

    Context 'WhatIf' {

        It 'changes nothing in enforce mode when -WhatIf is given' {
            Mock -CommandName Get-GuestUser -MockWith { New-GuestSet -Count 5 -InactiveDays 500 }

            Invoke-StaleGuestCleanup @script:Defaults -Mode Enforce -WhatIf

            $script:Deleted.Count  | Should -Be 0
            $script:Disabled.Count | Should -Be 0
        }
    }
}
