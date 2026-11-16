#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

$configuration = New-PesterConfiguration

$configuration.Run.Path = $PSScriptRoot
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $PSScriptRoot 'TestResults\testResults.xml'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' |
    Where-Object { $_.Name -notmatch '\.Tests\.ps1$|^PesterConfiguration\.ps1$|^Invoke-Checks\.ps1$' } |
    ForEach-Object FullName
$configuration.CodeCoverage.OutputPath = Join-Path $PSScriptRoot 'TestResults\coverage.xml'

$configuration
