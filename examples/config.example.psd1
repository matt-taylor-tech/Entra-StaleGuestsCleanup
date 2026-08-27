<#
    Example settings for Invoke-StaleGuestCleanup.

    Copy this to config.psd1 and edit it. config.psd1 is in .gitignore, because a real
    one names your tenant's groups and domains.

    Nothing reads this file automatically. It is a record of the parameters you decided
    on, so the next person can see them and the deployment can be repeated. Pass them to
    the runbook, or bake them into the schedule with the Deploy script's Schedule stage.

    Every value below is a placeholder. Replace all of them.
#>
@{
    # ----- Thresholds -------------------------------------------------------------
    # Days of inactivity before an account is disabled, and before it is deleted.
    # A guest that never signed in is aged from its creation date instead.
    # There is no correct pair of numbers. Write down whose decision these are.
    #
    # Whatever you choose, keep the gap between them at least twice your schedule
    # interval, or a single missed run deletes accounts that were never disabled:
    #
    #     DeleteAfterDays - DisableAfterDays >= ScheduleIntervalDays * 2
    #
    # 90 and 120 with a 15-day schedule satisfies this. The deploy script checks it.
    DisableAfterDays = 90
    DeleteAfterDays  = 120

    # ----- Mode -------------------------------------------------------------------
    # Report changes nothing. Enforce applies the decisions.
    # Leave this as Report until you have read a full report from your own tenant.
    Mode = 'Report'

    # ----- Limits -----------------------------------------------------------------
    # Most accounts to act on in one run. The rest wait for the next run, oldest first.
    # Keep these low on a directory that has never been cleaned: the first enforcing
    # run can otherwise action years of accumulated accounts at once.
    MaxDisablesPerRun = 50
    MaxDeletesPerRun  = 50

    # Stop the run and change nothing if the candidate count is above this. A number
    # far above your normal run is the point. It catches a bad threshold or a lost
    # permission before either becomes a mass deletion.
    AbortIfCandidatesExceed = 500

    # ----- Exclusions -------------------------------------------------------------
    # Object ID of a group whose members are never touched, nested groups included.
    # Create the group first and put your known exceptions in it. Adding an exception
    # then needs no code change and no redeployment.
    ExcludeGroupId = '00000000-0000-0000-0000-000000000000'

    # Partner or customer domains to leave alone entirely.
    ExcludeDomains = @(
        'example-partner.com'
        'example-vendor.co.uk'
    )

    # Individual accounts to leave alone. Prefer the exclusion group over this list:
    # a group can be changed by someone who does not touch the deployment.
    ExcludeUpn = @(
        'important_example.com#EXT#@yourtenant.onmicrosoft.com'
    )

    # ----- Reporting --------------------------------------------------------------
    # One or more of JobLog, Blob, Teams, None.
    # JobLog needs nothing. Azure Automation prunes job history, so add Blob when you
    # need an audit trail that outlives it.
    ReportSink = @('JobLog')

    # Only used when ReportSink includes Blob. The managed identity needs the
    # Storage Blob Data Contributor role on this account.
    StorageAccountName = 'yourstorageaccount'
    ContainerName      = 'stale-guest-reports'

    # The Teams webhook URL is deliberately absent. A webhook URL is a secret: anyone
    # holding it can post to the channel. Put it in the Automation Account variable
    # StaleGuest-TeamsWebhookUrl, which the runbook reads on its own.
}
