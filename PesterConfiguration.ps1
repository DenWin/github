#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Creates the repository's Pester test and coverage configuration.
.DESCRIPTION
    Returns a configuration that discovers tests under the script directory,
    displays detailed results and writes NUnit XML results under the
    repository's TestResults. Creating the configuration does not execute tests.

    Code coverage is disabled. It shows which lines ran, not whether a test can
    detect a wrong result, so it is not a quality gate here; Invoke-TestProof.ps1
    proves that instead. Enable it only to look for untested code. Its paths
    cover the root-level product scripts, excluding tests and test tooling.
.EXAMPLE
    Invoke-Pester -Configuration (.\PesterConfiguration.ps1)
    Runs the full suite, writes reports and exits with Pester's status code.
.EXAMPLE
    $configuration = & .\PesterConfiguration.ps1
    $configuration.Run.Exit = $false
    $configuration.CodeCoverage.Enabled = $true
    $result = Invoke-Pester -Configuration $configuration
    Runs with a coverage report, without terminating the current session, and
    returns results.
.INPUTS
    None. This script has no parameters and does not accept pipeline input.
.OUTPUTS
    PesterConfiguration
    A configuration with Run.PassThru and Run.Exit enabled. Test execution writes
    TestResults\testResults.xml, plus TestResults\coverage.xml when coverage is
    enabled.
.NOTES
    Requires PowerShell 7 and Pester 5 or later; use the repository-pinned version
    for parity with CI. Disable Run.Exit before invoking Pester in a session that
    must remain open. Subsequent runs overwrite the report paths.
.LINK
    https://pester.dev/docs/usage/configuration
#>
$configuration = New-PesterConfiguration

$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $PSScriptRoot 'TestResults\testResults.xml'
$configuration.CodeCoverage.Enabled = $false
$testTooling = '\.Tests\.ps1$|^PesterConfiguration\.ps1$|^Invoke-Checks\.ps1$|^GitTooling\.TestHelpers\.ps1$|^Invoke-TestProof\.ps1$'
$configuration.CodeCoverage.Path = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' |
    Where-Object { $_.Name -notmatch $testTooling } |
    ForEach-Object FullName
$configuration.CodeCoverage.OutputPath = Join-Path $PSScriptRoot 'TestResults\coverage.xml'

$configuration
