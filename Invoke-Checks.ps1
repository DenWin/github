#Requires -Version 7.0

<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester tests (same checks as CI).
#>
[CmdletBinding()]
param (
    [switch] $SkipLint,

    [switch] $SkipTests
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
    $result = Invoke-Pester -Configuration $configuration

    if ($result.Result -ne 'Passed') {
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
