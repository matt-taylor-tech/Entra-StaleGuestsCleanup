<#
=============================================================================================
Name:           Invoke-StaleGuestCleanup (Azure Automation runbook)
Version:        1.0.0
Description:    Finds stale Microsoft Entra ID guest accounts, disables them after one
                threshold, and deletes them after a second, longer threshold.

                A guest is stale when it has not signed in for N days. A guest that has
                never signed in is aged from its creation date instead.

                The job holds no state. A disabled account cannot sign in, so its last
                activity date is frozen and the inactive count keeps rising on its own.
                Every run recomputes the full picture from Entra, so the job is
                idempotent: a missed run or a double run causes no drift.

                Runs as an Azure Automation PowerShell 7.4 runbook using the Automation
                Account's system-assigned managed identity. No certificate, no secret.
                The same file also runs on a workstation for testing.

Author:         Matt Taylor
Licence:        MIT

Graph scopes:   Application roles required on the managed identity.
                    User.Read.All                    read the guest list
                    AuditLog.Read.All               read signInActivity
                    User.EnableDisableAccount.All   disable an account
                    User.DeleteRestore.All          delete an account
                    GroupMember.Read.All            read memberships for the audit record
                    RoleManagement.Read.Directory   find guests holding a directory role

Requirements:   PowerShell 7.2 or later
                Microsoft.Graph.Authentication  (the only required module)
                Az.Accounts + Az.Storage        (only if -ReportSink includes Blob)

Safety:         Defaults to -Mode Report, which changes nothing. Enforcement must be
                asked for. Per-run caps and an abort ceiling limit the damage a wrong
                parameter can do. A deleted Entra user is restorable for 30 days.
=============================================================================================
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param(
    # ----- Thresholds -------------------------------------------------------------------
    # Days of inactivity before an account is disabled.
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3650)]
    [int]$DisableAfterDays = 90,

    # Days of inactivity before an account is deleted. Must be >= DisableAfterDays.
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3650)]
    [int]$DeleteAfterDays = 120,

    # ----- Mode and limits --------------------------------------------------------------
    # Report changes nothing. Enforce applies the decisions.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Report', 'Enforce')]
    [string]$Mode = 'Report',

    # Most accounts to disable in a single run. The rest are logged as deferred.
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100000)]
    [int]$MaxDisablesPerRun = 50,

    # Most accounts to delete in a single run. The rest are logged as deferred.
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100000)]
    [int]$MaxDeletesPerRun = 50,

    # Stop the run and change nothing if the candidate count is above this.
    # Guards against a filter or permission change that makes everything look stale.
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000000)]
    [int]$AbortIfCandidatesExceed = 500,

    # ----- Exclusions -------------------------------------------------------------------
    # Object ID of a group whose members are never touched. Nested groups are honoured.
    # Use a group rather than a list in code, so an exception needs no code change.
    [Parameter(Mandatory = $false)]
    [string]$ExcludeGroupId,

    # Email domains to leave alone, for example @('partner.com','vendor.co.uk').
    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeDomains = @(),

    # Individual user principal names to leave alone.
    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeUpn = @(),

    # ----- Reporting --------------------------------------------------------------------
    # One or more of JobLog, Blob, Teams, None.
    [Parameter(Mandatory = $false)]
    [ValidateSet('JobLog', 'Blob', 'Teams', 'None')]
    [string[]]$ReportSink = @('JobLog'),

    # Storage account and container for the Blob sink.
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$ContainerName = 'stale-guest-reports',

    # Incoming webhook for the Teams sink. Keep this in an Automation variable,
    # never in source control.
    [Parameter(Mandatory = $false)]
    [string]$TeamsWebhookUrl,

    # Skip the group membership lookup on actioned accounts. Faster, but the audit
    # record then does not say what access was removed.
    [Parameter(Mandatory = $false)]
    [switch]$SkipGroupMemberships,

    # Client ID of a user-assigned managed identity. Omit to use the system-assigned one.
    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityClientId
)

$ErrorActionPreference = 'Stop'

#region Logging and configuration helpers

function Write-Log {
    <#
        In Azure Automation there is no persistent local disk, so log lines go to the job
        streams instead of a file. INFO/SUCCESS -> host, WARNING -> warning, ERROR -> error
        (non-terminating, so the run can finish and still report).

        INFO and SUCCESS use Write-Verbose, NOT Write-Output, and that is load bearing.
        Write-Output writes to the success stream, and the success stream IS a function's
        return value. With Write-Output here, `$x = Get-Thing` captured every log line
        Get-Thing wrote. Get-GuestUser returned six log strings plus a single array holding
        every guest, so the caller saw seven objects, the whole guest list was converted to
        one unreadable record, and no account was ever actioned. A logger must never write
        to the success stream.

        Write-Host was the first fix and it was wrong: it keeps the return value clean, but
        Azure Automation does not capture it. A real run produced 501 Output records and 3
        Warning records, and not one INFO line, so the guests-read count vanished from the
        job log. Write-Verbose is the only writer that both stays off the success stream and
        reaches an Automation job log, and it needs two things to show up: VerbosePreference
        set to Continue in the run, and 'Log verbose records' enabled on the runbook. The
        deploy script sets the second and Verify checks it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Error   $logMessage -ErrorAction Continue }
        'WARNING' { Write-Warning $logMessage }
        default   { Write-Verbose $logMessage }
    }
}

function Get-AutomationVariableSafe {
    <#
        Reads an Automation Account variable, returning $null if it is missing or if the
        cmdlet is unavailable, which is the case when running outside the Automation
        sandbox. Never throws, so callers can fall back to a parameter value.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command Get-AutomationVariable -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        return Get-AutomationVariable -Name $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

#endregion

# Most accounts the JobLog sink lists individually. Beyond this it reports the count and
# points at the Blob sink, because Azure Automation caps the size of an output record.
$script:JobLogRowLimit = 500

#region Pure logic - no Graph calls, covered by tests/StaleGuestLogic.Tests.ps1

function ConvertTo-NullableUtc {
    <#
        Graph date values arrive as a string, a DateTime, or a DateTimeOffset depending on
        which client made the call. Entra also uses 0001-01-01 as a "no value" marker on
        some sign-in properties. Normalise all of that to either a UTC DateTime or $null,
        so the decision logic never has to care.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }

    try {
        $parsed = switch ($Value) {
            { $_ -is [datetime] } {
                # ToUniversalTime() on a DateTime whose Kind is Unspecified treats it as
                # local and shifts it by the machine's offset. Graph values are UTC, so an
                # Unspecified Kind is stamped as UTC rather than converted. Getting this
                # wrong moves an account across a threshold by up to a day.
                $dt = [datetime]$_
                if ($dt.Kind -eq [System.DateTimeKind]::Unspecified) {
                    [datetime]::SpecifyKind($dt, [System.DateTimeKind]::Utc)
                }
                else {
                    $dt.ToUniversalTime()
                }
            }
            { $_ -is [datetimeoffset] } { ([datetimeoffset]$_).UtcDateTime }
            default {
                [datetime]::Parse(
                    [string]$_,
                    [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                    [System.Globalization.DateTimeStyles]::AssumeUniversal
                )
            }
        }
    }
    catch {
        return $null
    }

    # Entra's placeholder for "never". Treat it as no value.
    if ($parsed.Year -le 1) { return $null }

    return $parsed
}

function Get-GraphProperty {
    <#
        Reads a property from either a hashtable or an object with one call.
        Invoke-MgGraphRequest returns hashtables, the typed SDK returns objects, and the
        tests pass literals. This is the one place that difference is handled.
    #>
    param($Source, [string]$Name)

    if ($null -eq $Source) { return $null }

    if ($Source -is [System.Collections.IDictionary]) {
        # Index rather than call .Contains(). Invoke-MgGraphRequest returns a Hashtable at
        # the top level, but a nested object such as signInActivity can arrive as a
        # Dictionary[string,object], and .Contains() throws "cannot find an overload" on
        # that type even after a cast to IDictionary. Indexing returns $null for a missing
        # key on both types, so it is both simpler and the only shape-safe option.
        return $Source[$Name]
    }

    $property = $Source.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-GuestRecord {
    <#
        Flattens a Graph user object into a plain record with normalised dates.

        This exists so the decision logic below is immune to the shape Graph returns.
        Invoke-MgGraphRequest gives back a hashtable, the typed SDK gives back an object,
        and the tests give back a literal. All three flatten to the same thing here.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Guest
    )

    $activity = Get-GraphProperty $Guest 'signInActivity'

    [pscustomobject]@{
        Id                          = Get-GraphProperty $Guest 'id'
        DisplayName                 = Get-GraphProperty $Guest 'displayName'
        UserPrincipalName           = Get-GraphProperty $Guest 'userPrincipalName'
        Mail                        = Get-GraphProperty $Guest 'mail'
        CompanyName                 = Get-GraphProperty $Guest 'companyName'
        CreationType                = Get-GraphProperty $Guest 'creationType'
        ExternalUserState           = Get-GraphProperty $Guest 'externalUserState'
        AccountEnabled              = [bool](Get-GraphProperty $Guest 'accountEnabled')
        CreatedDateTime             = ConvertTo-NullableUtc (Get-GraphProperty $Guest 'createdDateTime')
        LastSignIn                  = ConvertTo-NullableUtc (Get-GraphProperty $activity 'lastSignInDateTime')
        LastNonInteractiveSignIn    = ConvertTo-NullableUtc (Get-GraphProperty $activity 'lastNonInteractiveSignInDateTime')
        LastSuccessfulSignIn        = ConvertTo-NullableUtc (Get-GraphProperty $activity 'lastSuccessfulSignInDateTime')
    }
}

function Get-GuestLastActivity {
    <#
        Works out the date the staleness clock runs from, and how many days have passed.

        All three sign-in timestamps are considered, and the latest one wins.
        lastNonInteractiveSignInDateTime matters: a guest who opens a shared file
        registers a non-interactive sign-in and no interactive one. Reading only the
        interactive timestamp would age guests who are actually using their access.

        Basis tells you which clock was used:
            LastSignIn      the guest signed in at least once
            NeverSignedIn   no sign-in ever, so the clock runs from the creation date
            Indeterminate   no sign-in and no creation date. Never actioned.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Record,

        [Parameter(Mandatory = $true)]
        [datetime]$AsOfUtc
    )

    $signIns = @(
        $Record.LastSignIn
        $Record.LastNonInteractiveSignIn
        $Record.LastSuccessfulSignIn
    ) | Where-Object { $null -ne $_ }

    if ($signIns.Count -gt 0) {
        $reference = ($signIns | Sort-Object -Descending)[0]
        $basis     = 'LastSignIn'
    }
    elseif ($null -ne $Record.CreatedDateTime) {
        $reference = $Record.CreatedDateTime
        $basis     = 'NeverSignedIn'
    }
    else {
        return [pscustomobject]@{
            ReferenceDate = $null
            Basis         = 'Indeterminate'
            InactiveDays  = $null
        }
    }

    # Floor, so an account is only "90 days inactive" once 90 full days have passed.
    # A future-dated reference gives a negative span; clamp it to 0 rather than letting
    # it read as stale.
    $span = $AsOfUtc - $reference
    $days = [int][math]::Floor($span.TotalDays)
    if ($days -lt 0) { $days = 0 }

    [pscustomobject]@{
        ReferenceDate = $reference
        Basis         = $basis
        InactiveDays  = $days
    }
}

function Get-GuestStaleAction {
    <#
        Decides what should happen to one guest. Returns Action and Reason.

        Order matters. Exclusions come first, so nothing excluded is ever actioned.
        Delete is then checked before Disable, so an account that is already past the
        delete threshold is deleted even if it was never disabled. That is what makes
        the job safe to start late or to run after a gap.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Activity,

        [Parameter(Mandatory = $true)]
        [bool]$AccountEnabled,

        [Parameter(Mandatory = $true)]
        [int]$DisableAfterDays,

        [Parameter(Mandatory = $true)]
        [int]$DeleteAfterDays,

        [Parameter(Mandatory = $false)]
        [string]$ExclusionReason
    )

    if ($ExclusionReason) {
        return [pscustomobject]@{ Action = 'NoAction'; Reason = $ExclusionReason }
    }

    if ($Activity.Basis -eq 'Indeterminate') {
        return [pscustomobject]@{
            Action = 'NoAction'
            Reason = 'No sign-in history and no creation date. Not enough data to act on.'
        }
    }

    $days = $Activity.InactiveDays

    if ($days -ge $DeleteAfterDays) {
        return [pscustomobject]@{
            Action = 'Delete'
            Reason = "Inactive $days days, at or past the delete threshold of $DeleteAfterDays."
        }
    }

    if ($days -ge $DisableAfterDays) {
        if (-not $AccountEnabled) {
            return [pscustomobject]@{
                Action = 'NoAction'
                Reason = "Inactive $days days and already disabled. Waiting for the delete threshold of $DeleteAfterDays."
            }
        }
        return [pscustomobject]@{
            Action = 'Disable'
            Reason = "Inactive $days days, at or past the disable threshold of $DisableAfterDays."
        }
    }

    [pscustomobject]@{
        Action = 'NoAction'
        Reason = "Inactive $days days, below the disable threshold of $DisableAfterDays."
    }
}

function Get-ExclusionReason {
    <#
        Returns the reason a guest is excluded, or $null if it is not.
        Kept pure so the tests can cover the matching rules without a tenant.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Record,

        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.HashSet[string]]$ExcludedIds,

        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.HashSet[string]]$RoleHolderIds,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeDomains = @(),

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeUpn = @()
    )

    if ($RoleHolderIds -and $Record.Id -and $RoleHolderIds.Contains($Record.Id)) {
        return 'Holds a directory role. Skipped on purpose.'
    }

    if ($ExcludedIds -and $Record.Id -and $ExcludedIds.Contains($Record.Id)) {
        return 'Member of the exclusion group.'
    }

    if ($ExcludeUpn.Count -gt 0 -and $Record.UserPrincipalName) {
        foreach ($upn in $ExcludeUpn) {
            if ($Record.UserPrincipalName -ieq $upn) {
                return 'On the excluded user list.'
            }
        }
    }

    if ($ExcludeDomains.Count -gt 0) {
        # Check the mail address and the UPN. A guest's UPN is mangled
        # (user_domain.com#EXT#@tenant.onmicrosoft.com) so the mail address is the
        # reliable one, but it can be empty on a pending invite.
        $candidates = @($Record.Mail, $Record.UserPrincipalName) | Where-Object { $_ }
        foreach ($domain in $ExcludeDomains) {
            $clean = $domain.TrimStart('@').Trim()
            if (-not $clean) { continue }

            # Match the domain itself and any subdomain of it, so a rule for partner.com
            # also protects someone@eu.partner.com. For an exclusion list, matching too
            # little is the dangerous direction: it deletes an account somebody meant to
            # keep. The label boundary still keeps notpartner.com out.
            $pattern = "(@|_)([A-Za-z0-9-]+\.)*" + [regex]::Escape($clean) + "(#EXT#|$)"

            foreach ($candidate in $candidates) {
                if ($candidate -imatch $pattern) {
                    return "Domain $clean is on the excluded domain list."
                }
            }
        }
    }

    return $null
}

#endregion

#region Graph access

function Connect-GraphApi {
    <#
        Cloud auth: the Automation Account's managed identity. No certificate, no secret,
        no Key Vault lookup. Falls back to whatever context already exists when running
        on a workstation, so a developer can sign in first with Connect-MgGraph.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$ClientId
    )

    $existing = Get-MgContext -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Using the existing Microsoft Graph connection for tenant $($existing.TenantId)."
        return $true
    }

    try {
        Write-Log 'Connecting to Microsoft Graph with the managed identity...'
        if ($ClientId) {
            Connect-MgGraph -Identity -ClientId $ClientId -NoWelcome -ErrorAction Stop
        }
        else {
            Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
        }

        $context = Get-MgContext
        Write-Log 'Connected to Microsoft Graph.' -Level SUCCESS
        Write-Log "Tenant: $($context.TenantId)"
        Write-Log "Auth:   $($context.AuthType) / $($context.TokenCredentialType)"
        return $true
    }
    catch {
        Write-Log "Could not connect to Microsoft Graph: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Invoke-GraphRequestWithRetry {
    <#
        Makes one Graph request and retries it if Graph throttles or is briefly
        unavailable.

        A run can make a hundred or more write calls, and Graph throttles writes to /users.
        Without this a single 429 would fail one account, fail the job, and send a
        needless alert. Retry-After is honoured when Graph sends it, because Graph's own
        number is better than a guess.

        The request is described by parameters rather than by a scriptblock. An earlier
        version took a scriptblock that splatted a variable from the calling function,
        which worked only because the caller happened to sit in the scope chain. Called
        from anywhere else the splat silently resolved to an empty hashtable and the
        request went out with no method and no URI, with no error at all.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string]$Method = 'GET',

        [Parameter(Mandatory = $false)]
        $Body,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [string]$Description = 'Graph call',

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 4
    )

    $params = @{
        Method      = $Method
        Uri         = $Uri
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) { $params['Body'] = $Body }
    if ($Headers)        { $params['Headers'] = $Headers }

    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-MgGraphRequest @params
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }

            $throttled = ($status -in @(429, 503, 504)) -or
                         ($_.Exception.Message -match '(?i)429|too\s*many\s*requests|throttl|service unavailable')

            if (-not $throttled -or $attempt -ge $MaxAttempts) { throw }

            # Graph's own Retry-After if present, otherwise back off.
            $wait = 0
            try { $wait = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } catch { $wait = 0 }
            if ($wait -le 0) { $wait = [int][math]::Min(60, [math]::Pow(2, $attempt) * 5) }

            Write-Log "$Description was throttled or unavailable (attempt $attempt of $MaxAttempts). Waiting $wait seconds." -Level WARNING
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-GraphGetAll {
    <#
        Pages through a Graph collection and returns every item.

        Paging is done here rather than with a typed SDK cmdlet for two reasons. The job
        then needs only the Microsoft.Graph.Authentication module, which is one less thing
        to keep at a matching version inside the Automation Account. And selecting
        signInActivity reduces the page size Graph will return, so the number of pages is
        not predictable and has to be followed rather than assumed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [string]$Activity
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $next    = $Uri
    $page    = 0

    while ($next) {
        $page++

        $response = Invoke-GraphRequestWithRetry -Method GET -Uri $next -Headers $Headers -Description "GET page $page"

        if ($response.value) {
            foreach ($item in $response.value) { $results.Add($item) }
        }

        $next = $response.'@odata.nextLink'

        if ($Activity -and ($page % 5 -eq 0)) {
            Write-Log "$Activity - $($results.Count) records after $page pages."
        }
    }

    # Always hand back an array. Returning the List let PowerShell unroll it, so a caller
    # got $null for no results and a bare object for one, which is a trap for the next
    # change even though every current caller happens to survive it.
    return Write-Output -InputObject $results.ToArray() -NoEnumerate
}

function Get-GuestUser {
    <#
        Reads every guest account with the properties the decision needs.

        The filter is applied server side on userType only. Filtering on signInActivity is
        deliberately not attempted: Graph answers a signInActivity filter with
        "400 Filter not supported" on this endpoint, so the aging is done in memory. A few
        thousand records is not a problem, and in-memory logic is testable.
    #>
    $select = @(
        'id'
        'displayName'
        'userPrincipalName'
        'mail'
        'createdDateTime'
        'signInActivity'
        'externalUserState'
        'externalUserStateChangeDateTime'
        'accountEnabled'
        'companyName'
        'creationType'
    ) -join ','

    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$select=$select"

    Write-Log 'Reading guest accounts from Entra ID...'
    $guests = Invoke-GraphGetAll -Uri $uri -Activity 'Guest read'
    Write-Log "Read $($guests.Count) guest accounts." -Level SUCCESS

    return $guests
}

function Get-DirectoryRoleHolderId {
    <#
        Every principal holding an active directory role. A guest should never hold one.
        If it does, the job skips it: removing a role holder needs a privileged role on
        the app, so the delete would fail anyway, and an admin should look at it by hand.
    #>
    try {
        $uri = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$select=principalId'
        $assignments = Invoke-GraphGetAll -Uri $uri

        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($a in $assignments) {
            if ($a.principalId) { [void]$set.Add([string]$a.principalId) }
        }

        $activeCount = $set.Count

        # Also cover PIM: a principal that is only *eligible* for a role holds no active
        # assignment, so the call above does not see it. Somebody who can raise themselves
        # to Global Administrator should not be removed by a scheduled job.
        #
        # This one degrades rather than failing closed. Eligibility needs Entra ID P2, and
        # a tenant without it answers with an error that is not a permission problem.
        try {
            $eligibleUri = 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilitySchedules?$select=principalId'
            foreach ($e in (Invoke-GraphGetAll -Uri $eligibleUri)) {
                if ($e.principalId) { [void]$set.Add([string]$e.principalId) }
            }
            Write-Log "Found $activeCount principals with an active directory role, and $($set.Count - $activeCount) more eligible for one."
        }
        catch {
            Write-Log "Could not read PIM role eligibility, so only active role assignments are protected. This is expected without Entra ID P2. Error: $($_.Exception.Message)" -Level WARNING
            Write-Log "Found $activeCount principals holding an active directory role."
        }

        return $set
    }
    catch {
        # Fail closed on this one. Without the list the job cannot tell whether a
        # candidate is an admin, and guessing is not acceptable for a delete.
        throw "Could not read directory role assignments, so the job cannot confirm that no candidate is an admin. Grant RoleManagement.Read.Directory to the managed identity. Error: $($_.Exception.Message)"
    }
}

function Get-ExclusionGroupMemberId {
    <#
        Transitive members of the exclusion group, so a nested group also protects its
        members. Returns an empty set when no group is configured.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $GroupId) { return $set }

    try {
        $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMembers?`$select=id"
        $members = Invoke-GraphGetAll -Uri $uri
        foreach ($m in $members) {
            if ($m.id) { [void]$set.Add([string]$m.id) }
        }
        Write-Log "Exclusion group holds $($set.Count) members, including nested groups."
        return $set
    }
    catch {
        # Fail closed. An empty set here would silently drop every exception the
        # administrator set up, and the next run would action all of them.
        throw "Could not read the exclusion group $GroupId, so its members cannot be protected. Check the group ID and that GroupMember.Read.All is granted. Error: $($_.Exception.Message)"
    }
}

function Get-GuestMembershipSummary {
    <#
        Group, Team, and site memberships for one guest, as a short string for the audit
        record. Called only for accounts that are actually actioned, which keeps this to
        a handful of calls rather than one per guest in the directory.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )

    try {
        $uri = "https://graph.microsoft.com/v1.0/users/$UserId/memberOf?`$select=id,displayName,groupTypes,resourceProvisioningOptions"
        $groups = Invoke-GraphGetAll -Uri $uri

        if ($groups.Count -eq 0) { return 'none' }

        $names = foreach ($g in $groups) {
            $name = if ($g.displayName) { $g.displayName } else { $g.id }
            $isTeam = $g.resourceProvisioningOptions -and ($g.resourceProvisioningOptions -contains 'Team')
            if ($isTeam) { "$name (Team)" } else { $name }
        }

        return ($names -join '; ')
    }
    catch {
        Write-Log "Could not read memberships for $UserId : $($_.Exception.Message)" -Level WARNING
        return 'lookup failed'
    }
}

function Disable-GuestAccount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )

    Invoke-GraphRequestWithRetry -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
        -Body @{ accountEnabled = $false } `
        -Description "Disable $UserId" | Out-Null
}

function Remove-GuestAccount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )

    Invoke-GraphRequestWithRetry -Method DELETE `
        -Uri "https://graph.microsoft.com/v1.0/users/$UserId" `
        -Description "Delete $UserId" | Out-Null
}

#endregion

#region Reporting

function Test-SignInDataUsable {
    <#
        The most dangerous failure mode in this job.

        If AuditLog.Read.All is removed, or Graph has a bad day, signInActivity comes back
        null for every guest. Every guest then looks like it never signed in, the clock
        falls back to the creation date, and the whole directory becomes a delete
        candidate. Nothing else in the job would notice.

        So: in a directory of any size, some guests have signed in. If none have, treat it
        as missing data rather than as a real answer.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IEnumerable]$Records,

        [Parameter(Mandatory = $false)]
        [int]$MinimumPopulation = 10
    )

    $total = 0
    $withSignIn = 0
    foreach ($r in $Records) {
        $total++
        if ($r.LastSignIn -or $r.LastNonInteractiveSignIn -or $r.LastSuccessfulSignIn) {
            $withSignIn++
        }
    }

    if ($total -lt $MinimumPopulation) {
        # Too small to draw a conclusion from, for example a test tenant.
        return [pscustomobject]@{ Usable = $true; Total = $total; WithSignIn = $withSignIn }
    }

    [pscustomobject]@{
        Usable     = ($withSignIn -gt 0)
        Total      = $total
        WithSignIn = $withSignIn
    }
}

function Write-ReportToJobLog {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter(Mandatory = $true)]
        $Summary
    )

    Write-Log '--- Stale guest cleanup summary -------------------------------------------'
    Write-Log "Mode:               $($Summary.Mode)"
    Write-Log "Thresholds:         disable at $($Summary.DisableAfterDays) days, delete at $($Summary.DeleteAfterDays) days"
    Write-Log "Guests read:        $($Summary.TotalGuests)"
    Write-Log "Excluded:           $($Summary.Excluded)"
    Write-Log "Disable candidates: $($Summary.DisableCandidates)  (applied $($Summary.Disabled), deferred $($Summary.DisablesDeferred))"
    Write-Log "Delete candidates:  $($Summary.DeleteCandidates)  (applied $($Summary.Deleted), deferred $($Summary.DeletesDeferred))"
    Write-Log "Failures:           $($Summary.Failures)"
    Write-Log '---------------------------------------------------------------------------'

    $actioned = @($Rows | Where-Object { $_.Action -ne 'NoAction' })
    if ($actioned.Count -eq 0) {
        Write-Log 'No accounts met a threshold.'
        return
    }

    # One line per account, not a Format-Table block.
    #
    # The first report-only run against a directory that has never been cleaned can have
    # thousands of candidates. A single formatted table would be one enormous output
    # record, and Azure Automation caps the size of a record, so the report would be
    # truncated exactly when it is most needed. Separate lines each stay small.
    # Take from each action separately, then combine.
    #
    # A single list sorted by Action put every Delete ahead of every Disable, and the row
    # limit was then applied across the lot. On a backlog of a thousand deletes the
    # handful of disables never appeared, which are exactly the accounts likely to
    # produce a "I have lost access" call. Disables go first and are almost never capped.
    $disables = @($actioned | Where-Object { $_.Action -eq 'Disable' } | Sort-Object InactiveDays -Descending)
    $deletes  = @($actioned | Where-Object { $_.Action -eq 'Delete' }  | Sort-Object InactiveDays -Descending)

    $disableBudget = [math]::Min($disables.Count, [math]::Max(1, [int]($script:JobLogRowLimit / 2)))
    $deleteBudget  = $script:JobLogRowLimit - $disableBudget
    if ($deleteBudget -lt 0) { $deleteBudget = 0 }

    $ordered = @($disables | Select-Object -First $disableBudget) +
               @($deletes  | Select-Object -First $deleteBudget)
    $shown = $ordered.Count

    Write-Log "Accounts that met a threshold: $($actioned.Count) ($($disables.Count) to disable, $($deletes.Count) to delete). Listing $shown."
    Write-Output 'Action,InactiveDays,Basis,Outcome,Company,UserPrincipalName'

    foreach ($row in $ordered) {
        # Quote the two free-text fields, so a comma in a company name cannot shift columns.
        Write-Output ('{0},{1},{2},"{3}","{4}",{5}' -f
            $row.Action,
            $row.InactiveDays,
            $row.Basis,
            ($row.Outcome -replace '"', "'"),
            ($row.CompanyName -replace '"', "'"),
            $row.UserPrincipalName)
    }

    if ($actioned.Count -gt $shown) {
        $omittedDisables = $disables.Count - [math]::Min($disables.Count, $disableBudget)
        $omittedDeletes  = $deletes.Count  - [math]::Min($deletes.Count,  $deleteBudget)

        Write-Log "Not listed above: $omittedDisables disables and $omittedDeletes deletes. The ones left out are the least stale of each." -Level WARNING
        Write-Log 'The job log is not the place for a list this long. Add Blob to -ReportSink for the full CSV, which is also the audit trail that outlives the job history.' -Level WARNING
    }
}

function Write-ReportToBlob {
    <#
        One timestamped CSV per run, appended to a container as the permanent audit trail.
        Needs Az.Accounts and Az.Storage, which are imported only when this sink is used,
        and Storage Blob Data Contributor on the managed identity.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,

        [Parameter(Mandatory = $true)]
        [string]$ContainerName,

        [Parameter(Mandatory = $false)]
        $Summary,

        [Parameter(Mandatory = $false)]
        [string]$ClientId
    )

    foreach ($module in @('Az.Accounts', 'Az.Storage')) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Log "The Blob report sink needs the $module module, which is not installed. Skipping the Blob sink." -Level WARNING
            return
        }
        Import-Module $module -ErrorAction Stop
    }

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        if ($ClientId) {
            Connect-AzAccount -Identity -AccountId $ClientId -ErrorAction Stop | Out-Null
        }
        else {
            Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        }
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')

    # An abort produces no per-account rows. Export-Csv writes no file at all for an empty
    # input, and the upload then failed with a storage error that hid the real reason for
    # the abort. Record the summary instead, so the audit trail still shows the run.
    $summaryOnly = ($Rows.Count -eq 0)
    $blobName = if ($summaryOnly) { "stale-guests-$stamp-summary-only.csv" } else { "stale-guests-$stamp.csv" }
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) $blobName

    try {
        if ($summaryOnly) {
            Write-Log 'No per-account rows to write, so the blob records the run summary only.'
            @($Summary) | Export-Csv -Path $tempFile -NoTypeInformation -Encoding UTF8
        }
        else {
            $Rows | Export-Csv -Path $tempFile -NoTypeInformation -Encoding UTF8
        }

        $context = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
        Set-AzStorageBlobContent -File $tempFile -Container $ContainerName -Blob $blobName -Context $context -Force -ErrorAction Stop | Out-Null

        Write-Log "Wrote the run report to $StorageAccountName/$ContainerName/$blobName." -Level SUCCESS
    }
    catch {
        Write-Log "Could not write the report to blob storage: $($_.Exception.Message)" -Level ERROR
    }
    finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Write-ReportToTeams {
    param(
        [Parameter(Mandatory = $true)]
        $Summary,

        [Parameter(Mandatory = $true)]
        [string]$WebhookUrl
    )

    $lines = @(
        "**Mode:** $($Summary.Mode)"
        "**Thresholds:** disable at $($Summary.DisableAfterDays) days, delete at $($Summary.DeleteAfterDays) days"
        "**Guests read:** $($Summary.TotalGuests)"
        "**Disabled:** $($Summary.Disabled) of $($Summary.DisableCandidates) candidates"
        "**Deleted:** $($Summary.Deleted) of $($Summary.DeleteCandidates) candidates"
    )
    if ($Summary.DisablesDeferred -gt 0 -or $Summary.DeletesDeferred -gt 0) {
        $lines += "**Deferred to the next run:** $($Summary.DisablesDeferred) disables, $($Summary.DeletesDeferred) deletes"
    }
    if ($Summary.Failures -gt 0) {
        $lines += "**Failures:** $($Summary.Failures)"
    }
    if ($Summary.Aborted) {
        $lines += "**Run aborted:** $($Summary.AbortReason)"
    }

    $payload = @{
        title = 'Entra stale guest cleanup'
        text  = ($lines -join "`n`n")
    } | ConvertTo-Json -Depth 4

    try {
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $payload -ErrorAction Stop | Out-Null
        Write-Log 'Posted the run summary to Teams.' -Level SUCCESS
    }
    catch {
        Write-Log "Could not post the summary to Teams: $($_.Exception.Message)" -Level ERROR
    }
}

function Write-Report {
    <#
        Sends the run report to every configured sink. One sink failing must not stop the
        others, and must not fail the run: the actions have already happened by this point
        and losing the report is not a reason to hide them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Rows,

        [Parameter(Mandatory = $true)]
        $Summary,

        [Parameter(Mandatory = $true)]
        [string[]]$Sink,

        [Parameter(Mandatory = $false)]
        [hashtable]$Options = @{}
    )

    if ($Sink -contains 'None') {
        Write-Log 'Report sink is None, so no report is written.'
        return
    }

    foreach ($target in $Sink) {
        switch ($target) {
            'JobLog' {
                Write-ReportToJobLog -Rows $Rows -Summary $Summary
            }
            'Blob' {
                if (-not $Options.StorageAccountName) {
                    Write-Log 'The Blob report sink needs -StorageAccountName. Skipping it.' -Level WARNING
                    continue
                }
                Write-ReportToBlob -Rows $Rows `
                    -StorageAccountName $Options.StorageAccountName `
                    -ContainerName $Options.ContainerName `
                    -Summary $Summary `
                    -ClientId $Options.ManagedIdentityClientId
            }
            'Teams' {
                if (-not $Options.TeamsWebhookUrl) {
                    Write-Log 'The Teams report sink needs a webhook URL. Skipping it.' -Level WARNING
                    continue
                }
                Write-ReportToTeams -Summary $Summary -WebhookUrl $Options.TeamsWebhookUrl
            }
        }
    }
}

#endregion

#region Main

function Invoke-StaleGuestCleanup {
    <#
        The whole job. Every input is an explicit parameter rather than a script-scope
        variable, so the caps, the abort ceiling and the report-only gate can be tested
        without a tenant. Defaults live in the script param block at the top of the file,
        which is the one place that states them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$DisableAfterDays,
        [int]$DeleteAfterDays,
        [string]$Mode,
        [int]$MaxDisablesPerRun,
        [int]$MaxDeletesPerRun,
        [int]$AbortIfCandidatesExceed,
        [string]$ExcludeGroupId,
        [string[]]$ExcludeDomains = @(),
        [string[]]$ExcludeUpn = @(),
        [string[]]$ReportSink = @('JobLog'),
        [string]$StorageAccountName,
        [string]$ContainerName,
        [string]$TeamsWebhookUrl,
        [switch]$SkipGroupMemberships,
        [string]$ManagedIdentityClientId
    )

    $asOfUtc = [datetime]::UtcNow
    Write-Log "Stale guest cleanup starting. Mode: $Mode. Reference time: $($asOfUtc.ToString('u'))."

    if ($DeleteAfterDays -lt $DisableAfterDays) {
        throw "DeleteAfterDays ($DeleteAfterDays) cannot be lower than DisableAfterDays ($DisableAfterDays). An account would be deleted before it was ever disabled."
    }

    # Catch the quiet mistake of configuring a sink and never selecting it. Without this
    # you set the webhook, see nothing in Teams, and have no clue why.
    if ($TeamsWebhookUrl -and $ReportSink -notcontains 'Teams') {
        Write-Log "A Teams webhook is configured but 'Teams' is not in -ReportSink, so nothing will be posted. Add Teams to -ReportSink." -Level WARNING
    }
    if ($StorageAccountName -and $ReportSink -notcontains 'Blob') {
        Write-Log "A storage account is configured but 'Blob' is not in -ReportSink, so no CSV will be written. Add Blob to -ReportSink." -Level WARNING
    }

    if (-not (Connect-GraphApi -ClientId $ManagedIdentityClientId)) {
        throw 'Cannot continue without a Microsoft Graph connection.'
    }

    # ----- Read -----------------------------------------------------------------------
    $rawGuests = Get-GuestUser
    $records = foreach ($g in $rawGuests) { ConvertTo-GuestRecord -Guest $g }
    $records = @($records)

    if ($records.Count -eq 0) {
        Write-Log 'No guest accounts found. Nothing to do.'
        return
    }

    # ----- Sanity check on the sign-in data -------------------------------------------
    $dataCheck = Test-SignInDataUsable -Records $records
    Write-Log "$($dataCheck.WithSignIn) of $($dataCheck.Total) guests have a recorded sign-in."

    if (-not $dataCheck.Usable) {
        $reason = "Not one of $($dataCheck.Total) guests has a recorded sign-in. That means the sign-in data is missing, not that every guest is stale. Check that AuditLog.Read.All is granted to the managed identity. No account was changed."
        Write-Log $reason -Level ERROR

        $summary = [pscustomobject]@{
            Mode = $Mode; DisableAfterDays = $DisableAfterDays; DeleteAfterDays = $DeleteAfterDays
            TotalGuests = $records.Count; Excluded = 0
            DisableCandidates = 0; Disabled = 0; DisablesDeferred = 0
            DeleteCandidates = 0; Deleted = 0; DeletesDeferred = 0
            Failures = 0; Aborted = $true; AbortReason = $reason
        }
        Write-Report -Rows @() -Summary $summary -Sink $ReportSink -Options @{
            StorageAccountName = $StorageAccountName; ContainerName = $ContainerName
            TeamsWebhookUrl = $TeamsWebhookUrl; ManagedIdentityClientId = $ManagedIdentityClientId
        }
        throw $reason
    }

    # ----- Build the exclusion sets ---------------------------------------------------
    $roleHolders  = Get-DirectoryRoleHolderId
    $excludedIds  = Get-ExclusionGroupMemberId -GroupId $ExcludeGroupId

    # ----- Evaluate every guest -------------------------------------------------------
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($record in $records) {
        $activity = Get-GuestLastActivity -Record $record -AsOfUtc $asOfUtc

        $exclusion = Get-ExclusionReason -Record $record `
            -ExcludedIds $excludedIds `
            -RoleHolderIds $roleHolders `
            -ExcludeDomains $ExcludeDomains `
            -ExcludeUpn $ExcludeUpn

        $decision = Get-GuestStaleAction -Activity $activity `
            -AccountEnabled $record.AccountEnabled `
            -DisableAfterDays $DisableAfterDays `
            -DeleteAfterDays $DeleteAfterDays `
            -ExclusionReason $exclusion

        $rows.Add([pscustomobject]@{
            Id                = $record.Id
            DisplayName       = $record.DisplayName
            UserPrincipalName = $record.UserPrincipalName
            Mail              = $record.Mail
            CompanyName       = $record.CompanyName
            ExternalUserState = $record.ExternalUserState
            AccountEnabled    = $record.AccountEnabled
            CreatedDateTime   = if ($record.CreatedDateTime) { $record.CreatedDateTime.ToString('u') } else { '' }
            LastActivityDate  = if ($activity.ReferenceDate) { $activity.ReferenceDate.ToString('u') } else { '' }
            Basis             = $activity.Basis
            InactiveDays      = $activity.InactiveDays
            Action            = $decision.Action
            Reason            = $decision.Reason
            Excluded          = [bool]$exclusion
            Memberships       = 'not checked'
            Outcome           = 'Pending'
        })
    }

    $excludedCount    = @($rows | Where-Object { $_.Excluded }).Count
    $disableCandidate = @($rows | Where-Object { $_.Action -eq 'Disable' }) | Sort-Object InactiveDays -Descending
    $deleteCandidate  = @($rows | Where-Object { $_.Action -eq 'Delete' })  | Sort-Object InactiveDays -Descending
    $candidateTotal   = $disableCandidate.Count + $deleteCandidate.Count

    Write-Log "Evaluated $($rows.Count) guests. $($disableCandidate.Count) to disable, $($deleteCandidate.Count) to delete, $excludedCount excluded."

    # ----- Abort ceiling --------------------------------------------------------------
    $aborted = $false
    $abortReason = $null
    if ($candidateTotal -gt $AbortIfCandidatesExceed) {
        $aborted = $true
        $abortReason = "$candidateTotal candidates is above the ceiling of $AbortIfCandidatesExceed. No account was changed. Review the report, then either raise -AbortIfCandidatesExceed on purpose or fix the thresholds."
        Write-Log $abortReason -Level ERROR

        foreach ($row in $rows) {
            if ($row.Action -ne 'NoAction') { $row.Outcome = 'Aborted' }
        }
    }

    # ----- Apply the per-run caps -----------------------------------------------------
    #
    # Only when the job is going to act. In report mode nothing is attempted, so nothing
    # is deferred: saying otherwise made the first report read as though half the backlog
    # had been handled and the rest queued, when the tenant had not been touched at all.
    $toDisable = @()
    $toDelete  = @()
    $disablesDeferred = 0
    $deletesDeferred  = 0

    if ($aborted) {
        # Nothing is attempted, and the rows already say Aborted.
    }
    elseif ($Mode -eq 'Report') {
        # Report the projection instead, which is the useful number: how long the current
        # caps would take to clear what was found.
        if ($disableCandidate.Count -gt $MaxDisablesPerRun -or $deleteCandidate.Count -gt $MaxDeletesPerRun) {
            $disableRuns = if ($MaxDisablesPerRun -gt 0) { [math]::Ceiling($disableCandidate.Count / $MaxDisablesPerRun) } else { 0 }
            $deleteRuns  = if ($MaxDeletesPerRun  -gt 0) { [math]::Ceiling($deleteCandidate.Count  / $MaxDeletesPerRun)  } else { 0 }
            $runsNeeded  = [math]::Max($disableRuns, $deleteRuns)

            Write-Log "At the current caps ($MaxDisablesPerRun disables and $MaxDeletesPerRun deletes per run) this backlog would take about $runsNeeded runs to clear." -Level WARNING
        }
    }
    else {
        $toDisable = @($disableCandidate | Select-Object -First $MaxDisablesPerRun)
        $toDelete  = @($deleteCandidate  | Select-Object -First $MaxDeletesPerRun)

        $disablesDeferred = $disableCandidate.Count - $toDisable.Count
        $deletesDeferred  = $deleteCandidate.Count  - $toDelete.Count

        if ($disablesDeferred -gt 0) {
            Write-Log "$disablesDeferred disable candidates are deferred to a later run by the cap of $MaxDisablesPerRun." -Level WARNING
        }
        if ($deletesDeferred -gt 0) {
            Write-Log "$deletesDeferred delete candidates are deferred to a later run by the cap of $MaxDeletesPerRun." -Level WARNING
        }

        # Mark the deferred rows, so the report never reads as "everything handled".
        $actionedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($r in @($toDisable + $toDelete)) { [void]$actionedIds.Add([string]$r.Id) }
        foreach ($row in $rows) {
            if ($row.Action -ne 'NoAction' -and -not $actionedIds.Contains([string]$row.Id)) {
                $row.Outcome = 'Deferred by the per-run cap'
            }
        }
    }

    # ----- Act ------------------------------------------------------------------------
    $disabled = 0
    $deleted  = 0
    $failures = 0

    if ($Mode -eq 'Report') {
        Write-Log 'Mode is Report, so nothing is changed. Run with -Mode Enforce to apply these decisions.'
        foreach ($row in $rows) {
            if ($row.Action -ne 'NoAction' -and $row.Outcome -eq 'Pending') {
                $row.Outcome = 'Report only, not applied'
            }
        }
    }
    elseif (-not $aborted) {

        foreach ($row in $toDisable) {
            if (-not $SkipGroupMemberships) {
                $row.Memberships = Get-GuestMembershipSummary -UserId $row.Id
            }

            $target = "$($row.UserPrincipalName) (inactive $($row.InactiveDays) days)"
            if (-not $PSCmdlet.ShouldProcess($target, 'Disable guest account')) {
                $row.Outcome = 'Skipped by WhatIf'
                continue
            }

            try {
                Disable-GuestAccount -UserId $row.Id
                $row.Outcome = 'Disabled'
                $disabled++
                Write-Log "Disabled $($row.UserPrincipalName), inactive $($row.InactiveDays) days, basis $($row.Basis)." -Level SUCCESS
            }
            catch {
                $row.Outcome = "Disable failed: $($_.Exception.Message)"
                $failures++
                Write-Log "Could not disable $($row.UserPrincipalName): $($_.Exception.Message)" -Level ERROR
            }
        }

        foreach ($row in $toDelete) {
            # Read the memberships before the delete. Afterwards there is nothing to read,
            # and this record is the only account of what access was removed.
            if (-not $SkipGroupMemberships) {
                $row.Memberships = Get-GuestMembershipSummary -UserId $row.Id
            }

            $target = "$($row.UserPrincipalName) (inactive $($row.InactiveDays) days, member of: $($row.Memberships))"
            if (-not $PSCmdlet.ShouldProcess($target, 'Delete guest account')) {
                $row.Outcome = 'Skipped by WhatIf'
                continue
            }

            try {
                Remove-GuestAccount -UserId $row.Id
                $row.Outcome = 'Deleted'
                $deleted++
                Write-Log "Deleted $($row.UserPrincipalName), inactive $($row.InactiveDays) days, basis $($row.Basis), memberships: $($row.Memberships)." -Level SUCCESS
            }
            catch {
                $row.Outcome = "Delete failed: $($_.Exception.Message)"
                $failures++
                Write-Log "Could not delete $($row.UserPrincipalName): $($_.Exception.Message)" -Level ERROR
            }
        }

        if ($deleted -gt 0) {
            Write-Log "$deleted accounts were deleted. Entra keeps a deleted user restorable for 30 days." -Level WARNING
        }
    }

    # ----- Report ---------------------------------------------------------------------
    $summary = [pscustomobject]@{
        Mode              = $Mode
        DisableAfterDays  = $DisableAfterDays
        DeleteAfterDays   = $DeleteAfterDays
        TotalGuests       = $rows.Count
        Excluded          = $excludedCount
        DisableCandidates = $disableCandidate.Count
        Disabled          = $disabled
        DisablesDeferred  = $disablesDeferred
        DeleteCandidates  = $deleteCandidate.Count
        Deleted           = $deleted
        DeletesDeferred   = $deletesDeferred
        Failures          = $failures
        Aborted           = $aborted
        AbortReason       = $abortReason
    }

    Write-Report -Rows @($rows) -Summary $summary -Sink $ReportSink -Options @{
        StorageAccountName      = $StorageAccountName
        ContainerName           = $ContainerName
        TeamsWebhookUrl         = $TeamsWebhookUrl
        ManagedIdentityClientId = $ManagedIdentityClientId
    }

    if ($aborted) {
        throw $abortReason
    }

    if ($failures -gt 0) {
        # Fail the job so the Automation alert fires. The report is already written.
        throw "$failures account operations failed. See the log above."
    }

    Write-Log 'Stale guest cleanup finished.' -Level SUCCESS
}

# Run, unless the file was dot-sourced. Dot-sourcing loads the functions without acting,
# which is how the test files reach them.
if ($MyInvocation.InvocationName -ne '.') {

    # Write-Log sends INFO and SUCCESS to Write-Verbose, which emits nothing unless this is
    # Continue. Set here rather than at script scope so dot-sourcing the file for tests does
    # not turn verbose output on for the whole test run. Preference variables are
    # dynamically scoped, so this covers everything called from here down.
    $VerbosePreference = 'Continue'

    # An Automation Account variable fills in a value that was not passed on the command
    # line, so the schedule can be retuned without republishing the runbook. An explicit
    # parameter always wins. This has to happen out here, because only the script's own
    # $PSBoundParameters can tell "not supplied" from "supplied".
    if (-not $PSBoundParameters.ContainsKey('TeamsWebhookUrl')) {
        $fromVariable = Get-AutomationVariableSafe -Name 'StaleGuest-TeamsWebhookUrl'
        if ($fromVariable) { $TeamsWebhookUrl = $fromVariable }
    }
    if (-not $PSBoundParameters.ContainsKey('ExcludeGroupId')) {
        $fromVariable = Get-AutomationVariableSafe -Name 'StaleGuest-ExcludeGroupId'
        if ($fromVariable) { $ExcludeGroupId = $fromVariable }
    }

    $runParams = @{
        DisableAfterDays        = $DisableAfterDays
        DeleteAfterDays         = $DeleteAfterDays
        Mode                    = $Mode
        MaxDisablesPerRun       = $MaxDisablesPerRun
        MaxDeletesPerRun        = $MaxDeletesPerRun
        AbortIfCandidatesExceed = $AbortIfCandidatesExceed
        ExcludeGroupId          = $ExcludeGroupId
        ExcludeDomains          = $ExcludeDomains
        ExcludeUpn              = $ExcludeUpn
        ReportSink              = $ReportSink
        StorageAccountName      = $StorageAccountName
        ContainerName           = $ContainerName
        TeamsWebhookUrl         = $TeamsWebhookUrl
        SkipGroupMemberships    = $SkipGroupMemberships
        ManagedIdentityClientId = $ManagedIdentityClientId
    }

    # Carry -WhatIf and -Confirm through to the function, so they still work.
    foreach ($passthrough in @('WhatIf', 'Confirm')) {
        if ($PSBoundParameters.ContainsKey($passthrough)) {
            $runParams[$passthrough] = $PSBoundParameters[$passthrough]
        }
    }

    Invoke-StaleGuestCleanup @runParams
}

#endregion
