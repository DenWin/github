#Requires -Version 7.0

<#
.SYNOPSIS
    Runs the repository's local audit, script analysis and Pester tests.
.DESCRIPTION
    Imports the exact module versions pinned in DevelopmentDependencies.psd1.
    Checks run in three tiers:
      default  local workflow audit, script analysis and unit tests (seconds);
               run on every change.
      -Full    adds integration tests against real Git repositories and writes
               test results, matching the CI checks job; run before pushing.
      -Proof   additionally proves that every test can fail, by running it
               against stubbed copies of its function (Invoke-TestProof.ps1,
               minutes); run before merging and at releases.
.PARAMETER Full
    Runs integration tests and writes test results in addition to the default
    checks.
.PARAMETER Proof
    Runs Invoke-TestProof.ps1 after the other checks and fails on any test that
    cannot be shown to fail. Combine with -Full for the complete milestone run.
.PARAMETER Coverage
    Writes TestResults\coverage.xml as a diagnostic for finding untested code.
    Coverage is not a gate: the run never fails because of it.
.PARAMETER SkipLint
    Skips both the local workflow security audit and PSScriptAnalyzer.
.PARAMETER SkipTests
    Skips Pester, including test-result and coverage generation. -Proof still
    runs when given.
.EXAMPLE
    .\Invoke-Checks.ps1
    Runs fast local checks without integration tests.
.EXAMPLE
    .\Invoke-Checks.ps1 -Full
    Runs every test and writes test results, matching the CI checks job.
.EXAMPLE
    .\Invoke-Checks.ps1 -Full -Proof
    Runs every check and proves every test, matching the CI proof job.
.EXAMPLE
    .\Invoke-Checks.ps1 -SkipTests
    Runs the local workflow audit and script analysis only.
.EXAMPLE
    .\Invoke-Checks.ps1 -SkipLint
    Runs only the Pester suite with the repository configuration.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.Management.Automation.PSCustomObject
    Audit findings, plus formatted analyzer findings when present. Progress and
    Pester diagnostics are displayed; reports are written under TestResults.
.NOTES
    Install the pinned modules first and make them discoverable via PSModulePath.
    All pinned modules are imported even when a check is skipped. Exits with code
    1 for analyzer findings, a non-passing test result or an unproven test.
    Audit, import and other
    terminating errors propagate immediately. Run from a separate pwsh process
    when an exit must not close the calling interactive session.
#>
[CmdletBinding()]
param (
    [switch] $SkipLint,

    [switch] $SkipTests,

    [switch] $Full,

    [switch] $Proof,

    [switch] $Coverage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
foreach ($module in $dependencies.Keys) {
    Import-Module -Name $module -RequiredVersion $dependencies[$module] -ErrorAction Stop
}

$failed = $false

if (-not $SkipLint) {
    Write-Host 'Auditing local workflow security...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Invoke-RepositorySecurity.ps1') -LocalOnly -FailOnFinding

    Write-Host 'Running PSScriptAnalyzer...' -ForegroundColor Cyan

    $scripts = Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1'

    $findings = foreach ($script in $scripts) {
        Invoke-ScriptAnalyzer `
            -Path $script.FullName `
            -Settings (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1')
    }

    if ($findings) {
        $findings | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap
        $failed = $true
    }
}

if (-not $SkipTests) {
    Write-Host 'Running Pester...' -ForegroundColor Cyan

    $configuration = & (Join-Path $PSScriptRoot 'PesterConfiguration.ps1')
    $configuration.Run.Exit = $false
    $configuration.Run.PassThru = $true
    $configuration.CodeCoverage.Enabled = [bool] $Coverage
    if (-not $Full) {
        $configuration.Filter.ExcludeTag = @('Integration')
        $configuration.TestResult.Enabled = $false
        $configuration.Output.Verbosity = 'Normal'
    }
    $result = Invoke-Pester -Configuration $configuration

    if ($result.Result -ne 'Passed') {
        $failed = $true
    }
}

if ($Proof) {
    Write-Host 'Proving that every test can fail...' -ForegroundColor Cyan
    $problems = @(& (Join-Path $PSScriptRoot 'Invoke-TestProof.ps1'))
    if ($problems.Count) {
        $problems | Format-Table Kind, Describe, Function, Detail -AutoSize -Wrap
    }
    if (@($problems | Where-Object Kind -In @('Unproven', 'Uncaught', 'Failed')).Count) {
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
