<#
.SYNOPSIS
    Pester tests for the decision logic in Invoke-StaleGuestCleanup.ps1.

.DESCRIPTION
    These cover the part of the job that decides whether an account lives or dies.

    They matter more than a live tenant test does. Account age cannot be faked in a real
    tenant: a test guest you create today is zero days old, so a tenant run can never
    exercise the 90 or 120 day boundary. Synthetic dates here can.

    The runbook is dot-sourced, which loads its functions without running the job.

.EXAMPLE
    Invoke-Pester -Path .\tests\StaleGuestLogic.Tests.ps1

.NOTES
    Requires: Pester 5.x
#>

BeforeAll {
    $script:RunbookPath = Join-Path $PSScriptRoot '..' 'src' 'Invoke-StaleGuestCleanup.ps1'
    . $script:RunbookPath

    # Fixed reference time, so no test depends on the day it runs.
    $script:Now = [datetime]::new(2026, 6, 1, 12, 0, 0, [System.DateTimeKind]::Utc)

    function New-TestGuest {
        param(
            $LastSignIn = $null,
            $LastNonInteractive = $null,
            $LastSuccessful = $null,
            $Created = $null,
            [bool]$Enabled = $true,
            [string]$Upn = 'someone_partner.com#EXT#@contoso.onmicrosoft.com',
            [string]$Mail = 'someone@partner.com',
            [string]$Id = '11111111-1111-1111-1111-111111111111'
        )

        # Shaped like an Invoke-MgGraphRequest result: nested hashtables.
        @{
            id                = $Id
            displayName       = 'Test Guest'
            userPrincipalName = $Upn
            mail              = $Mail
            companyName       = 'Partner Co'
            creationType      = 'Invitation'
            externalUserState = 'Accepted'
            accountEnabled    = $Enabled
            createdDateTime   = $Created
            signInActivity    = @{
                lastSignInDateTime               = $LastSignIn
                lastNonInteractiveSignInDateTime = $LastNonInteractive
                lastSuccessfulSignInDateTime     = $LastSuccessful
            }
        }
    }

    function Get-Decision {
        <# Runs a guest through the whole decision chain and returns the outcome. #>
        param(
            $Guest,
            [int]$DisableAfter = 90,
            [int]$DeleteAfter = 120,
            [string]$Exclusion
        )

        $record   = ConvertTo-GuestRecord -Guest $Guest
        $activity = Get-GuestLastActivity -Record $record -AsOfUtc $script:Now
        $decision = Get-GuestStaleAction -Activity $activity -AccountEnabled $record.AccountEnabled -DisableAfterDays $DisableAfter -DeleteAfterDays $DeleteAfter -ExclusionReason $Exclusion

        [pscustomobject]@{
            Action       = $decision.Action
            Reason       = $decision.Reason
            Basis        = $activity.Basis
            InactiveDays = $activity.InactiveDays
        }
    }

    function New-IdSet {
        param([string[]]$Id)
        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($i in $Id) { [void]$set.Add($i) }
        return $set
    }
}

Describe 'ConvertTo-NullableUtc' {

    It 'returns null for a null value' {
        ConvertTo-NullableUtc -Value $null | Should -BeNullOrEmpty
    }

    It 'returns null for an empty or whitespace string' {
        ConvertTo-NullableUtc -Value ''    | Should -BeNullOrEmpty
        ConvertTo-NullableUtc -Value '   ' | Should -BeNullOrEmpty
    }

    It 'parses an ISO 8601 string from Graph as UTC' {
        $result = ConvertTo-NullableUtc -Value '2026-03-04T05:06:07Z'
        $result.Kind  | Should -Be 'Utc'
        $result.Year  | Should -Be 2026
        $result.Month | Should -Be 3
        $result.Day   | Should -Be 4
    }

    It 'accepts a DateTimeOffset from the typed Graph SDK and converts it to UTC' {
        $offset = [datetimeoffset]::new(2026, 3, 4, 5, 6, 7, [timespan]::FromHours(-5))
        $result = ConvertTo-NullableUtc -Value $offset
        $result.Kind | Should -Be 'Utc'
        $result.Hour | Should -Be 10   # 05:06 less a five hour offset
    }

    It 'treats the Entra 0001-01-01 placeholder as no value' {
        # Entra returns this instead of null on some sign-in properties. Read literally,
        # it makes an account look two thousand years stale.
        ConvertTo-NullableUtc -Value '0001-01-01T00:00:00Z' | Should -BeNullOrEmpty
    }

    It 'returns null rather than throwing on an unparseable value' {
        ConvertTo-NullableUtc -Value 'not a date' | Should -BeNullOrEmpty
    }

    It 'stamps an Unspecified-Kind DateTime as UTC instead of shifting it' {
        # ToUniversalTime() on an Unspecified Kind treats it as local time and moves it by
        # the machine offset. Graph values are UTC, so a shift here can push an account
        # across a threshold by a day depending on where the machine is.
        $unspecified = [datetime]::new(2026, 3, 4, 5, 6, 7, [System.DateTimeKind]::Unspecified)
        $result = ConvertTo-NullableUtc -Value $unspecified

        $result.Kind   | Should -Be 'Utc'
        $result.Hour   | Should -Be 5      # unchanged
        $result.Day    | Should -Be 4
    }

    It 'still converts a Local-Kind DateTime properly' {
        $local = [datetime]::new(2026, 3, 4, 5, 6, 7, [System.DateTimeKind]::Local)
        $result = ConvertTo-NullableUtc -Value $local

        $result.Kind | Should -Be 'Utc'
        $result      | Should -Be $local.ToUniversalTime()
    }
}

Describe 'Get-GuestLastActivity' {

    It 'uses the interactive sign-in when it is the only one present' {
        $guest  = New-TestGuest -LastSignIn $script:Now.AddDays(-30)
        $result = Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now

        $result.Basis        | Should -Be 'LastSignIn'
        $result.InactiveDays | Should -Be 30
    }

    It 'uses the non-interactive sign-in when it is the most recent' {
        # The case that matters most. A guest opening a shared file registers a
        # non-interactive sign-in only. Aging on the interactive timestamp alone would
        # delete a guest who is actively using their access.
        $guest = New-TestGuest -LastSignIn $script:Now.AddDays(-200) -LastNonInteractive $script:Now.AddDays(-5)

        $result = Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now

        $result.Basis        | Should -Be 'LastSignIn'
        $result.InactiveDays | Should -Be 5
    }

    It 'uses the last successful sign-in when it is the most recent' {
        $guest = New-TestGuest -LastSignIn $script:Now.AddDays(-100) -LastNonInteractive $script:Now.AddDays(-100) -LastSuccessful $script:Now.AddDays(-2)

        (Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now).InactiveDays | Should -Be 2
    }

    It 'falls back to the creation date when the guest never signed in' {
        $guest  = New-TestGuest -Created $script:Now.AddDays(-45)
        $result = Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now

        $result.Basis        | Should -Be 'NeverSignedIn'
        $result.InactiveDays | Should -Be 45
    }

    It 'reports Indeterminate when there is no sign-in and no creation date' {
        $result = Get-GuestLastActivity -Record (ConvertTo-GuestRecord (New-TestGuest)) -AsOfUtc $script:Now

        $result.Basis         | Should -Be 'Indeterminate'
        $result.InactiveDays  | Should -BeNullOrEmpty
        $result.ReferenceDate | Should -BeNullOrEmpty
    }

    It 'clamps a future dated sign-in to zero days instead of a negative count' {
        $guest = New-TestGuest -LastSignIn $script:Now.AddDays(10)
        (Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now).InactiveDays | Should -Be 0
    }

    It 'floors a partial day, so 89 and a half days is not yet 90' {
        $guest = New-TestGuest -LastSignIn $script:Now.AddDays(-90).AddHours(12)
        (Get-GuestLastActivity -Record (ConvertTo-GuestRecord $guest) -AsOfUtc $script:Now).InactiveDays | Should -Be 89
    }
}

Describe 'Get-GuestStaleAction thresholds' {

    Context 'a guest that has signed in before' {

        It 'takes no action one day below the disable threshold' {
            (Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-89))).Action | Should -Be 'NoAction'
        }

        It 'disables exactly on the disable threshold' {
            $d = Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-90))
            $d.Action       | Should -Be 'Disable'
            $d.InactiveDays | Should -Be 90
        }

        It 'still only disables one day below the delete threshold' {
            (Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-119))).Action | Should -Be 'Disable'
        }

        It 'deletes exactly on the delete threshold' {
            $d = Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-120))
            $d.Action       | Should -Be 'Delete'
            $d.InactiveDays | Should -Be 120
        }

        It 'deletes well past the delete threshold' {
            (Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-500))).Action | Should -Be 'Delete'
        }
    }

    Context 'a guest that never signed in, aged from its creation date' {

        It 'takes no action below the disable threshold' {
            (Get-Decision (New-TestGuest -Created $script:Now.AddDays(-10))).Action | Should -Be 'NoAction'
        }

        It 'disables on the disable threshold' {
            $d = Get-Decision (New-TestGuest -Created $script:Now.AddDays(-95))
            $d.Action | Should -Be 'Disable'
            $d.Basis  | Should -Be 'NeverSignedIn'
        }

        It 'deletes on the delete threshold' {
            $d = Get-Decision (New-TestGuest -Created $script:Now.AddDays(-130))
            $d.Action | Should -Be 'Delete'
            $d.Basis  | Should -Be 'NeverSignedIn'
        }
    }

    Context 'an account that is already disabled' {

        It 'deletes it once past the delete threshold, even though this job never disabled it' {
            # This is what makes the job safe to start late, or to run after a gap.
            (Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-130) -Enabled $false)).Action | Should -Be 'Delete'
        }

        It 'takes no action between the two thresholds, because it is already disabled' {
            $d = Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-100) -Enabled $false)
            $d.Action | Should -Be 'NoAction'
            $d.Reason | Should -Match 'already disabled'
        }
    }

    Context 'missing data' {

        It 'never actions a guest with no sign-in history and no creation date' {
            $d = Get-Decision (New-TestGuest)
            $d.Action | Should -Be 'NoAction'
            $d.Reason | Should -Match 'Not enough data'
        }
    }

    Context 'custom thresholds' {

        It 'honours thresholds passed in, rather than the 90 and 120 day defaults' {
            $guest = New-TestGuest -LastSignIn $script:Now.AddDays(-8)
            (Get-Decision $guest -DisableAfter 5  -DeleteAfter 30).Action | Should -Be 'Disable'
            (Get-Decision $guest -DisableAfter 1  -DeleteAfter 7).Action  | Should -Be 'Delete'
            (Get-Decision $guest -DisableAfter 30 -DeleteAfter 60).Action | Should -Be 'NoAction'
        }
    }

    Context 'exclusions' {

        It 'takes no action when an exclusion reason is supplied, however stale the account is' {
            $d = Get-Decision (New-TestGuest -LastSignIn $script:Now.AddDays(-999)) -Exclusion 'On the list.'
            $d.Action | Should -Be 'NoAction'
            $d.Reason | Should -Be 'On the list.'
        }
    }
}

Describe 'Get-ExclusionReason' {

    BeforeAll {
        $script:GuestId = 'aaaa1111-0000-0000-0000-000000000000'
        $script:Record  = ConvertTo-GuestRecord (New-TestGuest -Id $script:GuestId)
    }

    It 'returns null when no exclusion rule is configured' {
        Get-ExclusionReason -Record $script:Record | Should -BeNullOrEmpty
    }

    It 'excludes a holder of a directory role' {
        Get-ExclusionReason -Record $script:Record -RoleHolderIds (New-IdSet $script:GuestId) | Should -Match 'directory role'
    }

    It 'excludes a member of the exclusion group' {
        Get-ExclusionReason -Record $script:Record -ExcludedIds (New-IdSet $script:GuestId) | Should -Match 'exclusion group'
    }

    It 'puts the directory role check ahead of the group check' {
        $both = New-IdSet $script:GuestId
        Get-ExclusionReason -Record $script:Record -RoleHolderIds $both -ExcludedIds $both | Should -Match 'directory role'
    }

    It 'excludes an exact user principal name, ignoring case' {
        Get-ExclusionReason -Record $script:Record -ExcludeUpn @('SOMEONE_PARTNER.COM#EXT#@CONTOSO.ONMICROSOFT.COM') | Should -Match 'excluded user list'
    }

    It 'excludes by mail domain' {
        Get-ExclusionReason -Record $script:Record -ExcludeDomains @('partner.com') | Should -Match 'partner.com'
    }

    It 'accepts a domain written with a leading at sign' {
        Get-ExclusionReason -Record $script:Record -ExcludeDomains @('@partner.com') | Should -Match 'partner.com'
    }

    It 'matches the domain inside a mangled guest UPN when the mail address is empty' {
        # A pending invite often has no mail address, so the UPN is all there is.
        $noMail = ConvertTo-GuestRecord (New-TestGuest -Mail $null)
        Get-ExclusionReason -Record $noMail -ExcludeDomains @('partner.com') | Should -Match 'partner.com'
    }

    It 'excludes a subdomain of an excluded domain' {
        # A rule for partner.com must also protect someone@eu.partner.com. For an
        # exclusion list, matching too little is the dangerous direction: it deletes an
        # account somebody meant to keep.
        $sub = ConvertTo-GuestRecord (New-TestGuest -Mail 'someone@eu.partner.com' -Upn 'someone_eu.partner.com#EXT#@contoso.onmicrosoft.com')
        Get-ExclusionReason -Record $sub -ExcludeDomains @('partner.com') | Should -Match 'partner.com'
    }

    It 'excludes a deeply nested subdomain' {
        $sub = ConvertTo-GuestRecord (New-TestGuest -Mail 'x@a.b.partner.com' -Upn 'x_a.b.partner.com#EXT#@contoso.onmicrosoft.com')
        Get-ExclusionReason -Record $sub -ExcludeDomains @('partner.com') | Should -Match 'partner.com'
    }

    It 'still refuses a lookalike domain that merely ends the same way' {
        $sub = ConvertTo-GuestRecord (New-TestGuest -Mail 'x@evilpartner.com' -Upn 'x_evilpartner.com#EXT#@contoso.onmicrosoft.com')
        Get-ExclusionReason -Record $sub -ExcludeDomains @('partner.com') | Should -BeNullOrEmpty
    }

    It 'does not treat one domain as excluded just because it is a suffix of another' {
        # A rule for partner.com must not catch notpartner.com.
        $other = ConvertTo-GuestRecord (New-TestGuest -Mail 'someone@notpartner.com' -Upn 'someone_notpartner.com#EXT#@contoso.onmicrosoft.com')
        Get-ExclusionReason -Record $other -ExcludeDomains @('partner.com') | Should -BeNullOrEmpty
    }

    It 'does not exclude an unrelated domain' {
        Get-ExclusionReason -Record $script:Record -ExcludeDomains @('other.com') | Should -BeNullOrEmpty
    }
}

Describe 'Get-GraphProperty' {

    It 'reads a property from a Hashtable, which is what the top level of a Graph reply is' {
        Get-GraphProperty @{ id = 'abc' } 'id' | Should -Be 'abc'
    }

    It 'reads a property from a generic dictionary, which is what a nested Graph object can be' {
        # signInActivity arrives nested. The SDK can materialise it as
        # Dictionary[string,object] rather than Hashtable, and .Contains() throws on that
        # type even after a cast to IDictionary. If this regresses, the job throws for
        # every guest and the whole run dies.
        $dict = [System.Collections.Generic.Dictionary[string, object]]::new()
        $dict['lastSignInDateTime'] = '2026-01-01T00:00:00Z'

        Get-GraphProperty $dict 'lastSignInDateTime' | Should -Be '2026-01-01T00:00:00Z'
    }

    It 'returns null for a missing key on either dictionary type, rather than throwing' {
        $dict = [System.Collections.Generic.Dictionary[string, object]]::new()

        Get-GraphProperty @{ id = 'abc' } 'nope' | Should -BeNullOrEmpty
        Get-GraphProperty $dict 'nope'           | Should -BeNullOrEmpty
    }

    It 'returns null for a missing property on an object, rather than throwing' {
        Get-GraphProperty ([pscustomobject]@{ id = 'abc' }) 'nope' | Should -BeNullOrEmpty
    }

    It 'returns null when the source itself is null' {
        Get-GraphProperty $null 'anything' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-GuestRecord with a generic dictionary from the SDK' {

    It 'flattens a guest whose signInActivity is a generic dictionary' {
        $activity = [System.Collections.Generic.Dictionary[string, object]]::new()
        $activity['lastSignInDateTime'] = '2026-02-01T00:00:00Z'
        $activity['lastNonInteractiveSignInDateTime'] = '2026-05-01T00:00:00Z'

        $guest = [System.Collections.Generic.Dictionary[string, object]]::new()
        $guest['id'] = 'dict-1'
        $guest['userPrincipalName'] = 'd@example.com'
        $guest['accountEnabled'] = $true
        $guest['signInActivity'] = $activity

        $record = ConvertTo-GuestRecord $guest
        $record.Id | Should -Be 'dict-1'
        $record.LastNonInteractiveSignIn.Month | Should -Be 5

        # And the non-interactive date must still win.
        $activityResult = Get-GuestLastActivity -Record $record -AsOfUtc ([datetime]::new(2026, 6, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
        $activityResult.InactiveDays | Should -Be 31
    }
}

Describe 'Test-SignInDataUsable' {

    It 'reports the data unusable when no guest in a large population has ever signed in' {
        # The dangerous case: AuditLog.Read.All removed, so every guest reads as never
        # signed in and the whole directory becomes a delete candidate.
        $records = 1..50 | ForEach-Object {
            ConvertTo-GuestRecord (New-TestGuest -Created $script:Now.AddDays(-400) -Id "id-$_")
        }

        $result = Test-SignInDataUsable -Records $records
        $result.Usable     | Should -BeFalse
        $result.WithSignIn | Should -Be 0
    }

    It 'reports the data usable when at least one guest has signed in' {
        $records = @(ConvertTo-GuestRecord (New-TestGuest -LastSignIn $script:Now.AddDays(-1) -Id 'id-live'))
        $records += 1..50 | ForEach-Object {
            ConvertTo-GuestRecord (New-TestGuest -Created $script:Now.AddDays(-400) -Id "id-$_")
        }

        (Test-SignInDataUsable -Records $records).Usable | Should -BeTrue
    }

    It 'does not call a small population unusable, so a test tenant still runs' {
        $records = 1..3 | ForEach-Object {
            ConvertTo-GuestRecord (New-TestGuest -Created $script:Now.AddDays(-400) -Id "id-$_")
        }

        (Test-SignInDataUsable -Records $records).Usable | Should -BeTrue
    }

    It 'counts a non-interactive sign-in as a sign-in' {
        $records = 1..20 | ForEach-Object {
            ConvertTo-GuestRecord (New-TestGuest -LastNonInteractive $script:Now.AddDays(-3) -Id "id-$_")
        }

        (Test-SignInDataUsable -Records $records).WithSignIn | Should -Be 20
    }
}

Describe 'ConvertTo-GuestRecord' {

    It 'flattens a hashtable from Invoke-MgGraphRequest' {
        $record = ConvertTo-GuestRecord (New-TestGuest -LastSignIn '2026-01-02T03:04:05Z')
        $record.UserPrincipalName | Should -Be 'someone_partner.com#EXT#@contoso.onmicrosoft.com'
        $record.LastSignIn.Year   | Should -Be 2026
        $record.AccountEnabled    | Should -BeTrue
    }

    It 'flattens an object from the typed Graph SDK the same way' {
        $guest = [pscustomobject]@{
            id                = 'obj-1'
            displayName       = 'Object Guest'
            userPrincipalName = 'obj@example.com'
            mail              = 'obj@example.com'
            accountEnabled    = $true
            createdDateTime   = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            signInActivity    = [pscustomobject]@{
                lastSignInDateTime               = [datetime]::new(2026, 2, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
                lastNonInteractiveSignInDateTime = $null
                lastSuccessfulSignInDateTime     = $null
            }
        }

        $record = ConvertTo-GuestRecord $guest
        $record.Id               | Should -Be 'obj-1'
        $record.LastSignIn.Month | Should -Be 2
    }

    It 'handles a guest with no signInActivity property at all' {
        $record = ConvertTo-GuestRecord @{ id = 'x'; userPrincipalName = 'x@y.com'; accountEnabled = $true }
        $record.LastSignIn | Should -BeNullOrEmpty
        { Get-GuestLastActivity -Record $record -AsOfUtc $script:Now } | Should -Not -Throw
    }
}
