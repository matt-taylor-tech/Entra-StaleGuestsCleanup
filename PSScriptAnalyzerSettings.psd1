<#
    PSScriptAnalyzer settings.

    Every rule below is excluded on purpose, with the reason. Nothing here is switched
    off because it was inconvenient. Run the analyzer with:

        Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

    The project has no analyzer errors. These are warnings.
#>
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # Write-Host is correct in deploy/. Those scripts are run by a person at a
        # console, and the coloured progress output is the interface. The runbook itself
        # uses Write-Log to the output streams, because Azure Automation captures those
        # and has no console.
        'PSAvoidUsingWriteHost'

        # Reported against Remove-GuestAccount and Disable-GuestAccount. Those are thin
        # wrappers over one Graph call each. ShouldProcess is handled one level up in
        # Invoke-StaleGuestCleanup, which is the right place: the confirmation prompt has
        # to include the account's group memberships, and only the caller knows them.
        # Also reported against the New-* test fixtures, which build hashtables.
        'PSUseShouldProcessForStateChangingFunctions'

        # Reported against the stage functions in Deploy-StaleGuestCleanup.ps1, which
        # call $PSCmdlet.ShouldProcess without declaring SupportsShouldProcess of their
        # own. They deliberately use the script's $PSCmdlet, so one -WhatIf on the script
        # covers every stage. PowerShell resolves $PSCmdlet up the scope chain, so this
        # works: running the script with -WhatIf prints the "What if:" lines and skips the
        # action inside the nested function. Verified, not assumed.
        'PSShouldProcess'

        # Reported against the script parameters that are only read inside those same
        # stage functions. The analyzer does not follow a parameter into a nested
        # function, so it reads them as unused. They are all used.
        'PSReviewUnusedParameter'

        # Reported against Write-Log. PSScriptAnalyzer carries a list of cmdlet names
        # taken from a PowerShell 6.1 Windows build that included a Write-Log. No such
        # cmdlet exists in PowerShell 7, and there is no real collision. The name also
        # matches the convention used by the other runbooks this one sits beside.
        'PSAvoidOverwritingBuiltInCmdlets'

        # Reported against Write-ReportToTeams. Teams is a product name.
        'PSUseSingularNouns'
    )
}
