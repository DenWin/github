#Requires -Version 7.0

<#
.SYNOPSIS
    Shared Pester helpers for the Git workflow script tests.
.DESCRIPTION
    Provides output capture and real temporary Git repository fixtures. Loaded by
    test files with dot-sourcing; performs no action when loaded. Not a test file.
.EXAMPLE
    . "$PSScriptRoot\GitTooling.TestHelpers.ps1"
    Loads the helpers inside a Pester BeforeAll block.
.INPUTS
    None.
.OUTPUTS
    None when dot-sourced; see the individual functions.
.NOTES
    Requires GitTooling.Common.ps1 (Invoke-Git) to be loaded first and Git on PATH
    for the repository fixtures.
#>

function Invoke-Captured {
    <#
    .SYNOPSIS
        Runs a script block and separates its result from host and warning output.
    #>
    param ([scriptblock] $ScriptBlock)

    $output = @(& $ScriptBlock 3>&1 6>&1)
    [pscustomobject]@{
        Result = @($output | Where-Object {
                $_ -isnot [System.Management.Automation.WarningRecord] -and
                $_ -isnot [System.Management.Automation.InformationRecord]
            })
        Warning = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
                ForEach-Object Message)
        Host = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
                ForEach-Object { "$($_.MessageData)" })
    }
}


function New-SourceRepository {
    <#
    .SYNOPSIS
        Creates a non-bare repository on main with one empty commit and optional branches.
    .DESCRIPTION
        Reftable stores refs outside the file system, so case-distinct branches
        such as Feature and feature/login can coexist on Windows.
    #>
    param ([string] $Path, [string[]] $Branch = @(), [switch] $Reftable)

    $format = if ($Reftable) { 'reftable' } else { 'files' }
    Invoke-Git -Arguments @('init', '--quiet', '--initial-branch=main', "--ref-format=$format", $Path) | Out-Null
    Invoke-Git -Arguments @(
        '-C', $Path, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
        '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m', 'Initial'
    ) | Out-Null
    foreach ($name in $Branch) {
        Invoke-Git -Arguments @('-C', $Path, 'branch', $name)
    }
}
