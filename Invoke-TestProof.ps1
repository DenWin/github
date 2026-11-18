#Requires -Version 7.0

<#
.SYNOPSIS
    Proves that tests can fail by running them against stubbed copies of the code.
.DESCRIPTION
    A passing test is only meaningful if it fails when the code under test is
    wrong. For every Describe block whose name (or TestProofs.psd1 mapping) names
    a function, this script runs that Describe once unchanged (baseline) and
    once per stub. Each stub replaces the function body in a temporary copy of
    the scripts, keeping its param block, with code that returns no result or a
    slightly wrong one. Stubs come from DefaultStubs plus any listed for the
    function in TestProofs.psd1.

    The report lists:
      Unproven  baseline-passing tests that did not fail under any stub of
                their function: they cannot detect a wrong result.
      Uncaught  stubs under which every test of the Describe still passed.
      Failed    baseline failures and stub runs that produced no results.
      Unmapped  Describe blocks without a function to stub.
.PARAMETER Function
    Limits the proof to these function names. Defaults to every mapped function.
.PARAMETER ThrottleLimit
    Maximum number of parallel pwsh processes. Defaults to the processor count.
.EXAMPLE
    .\Invoke-TestProof.ps1
    Proves every mapped test; exits with code 1 if any test is unproven.
.EXAMPLE
    .\Invoke-TestProof.ps1 -Function Get-StepFinding, Select-DirectoryName
    Proves only the tests of two functions, for example after changing them.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.Management.Automation.PSCustomObject
    One object per problem with Kind (Unproven, Uncaught, Failed or Unmapped),
    Describe, Function and Detail. A summary is written to the host.
.NOTES
    Requires PowerShell 7 and the modules pinned in DevelopmentDependencies.psd1.
    Each run is a separate pwsh process on a copy of the root *.ps1 and *.psd1
    files in the temporary directory, so stubs never touch the working tree and
    environment changes made by tests cannot leak between runs. Run time grows
    with the integration Describes; this is a milestone check, not a fast one.
    Dot-source the script to load its functions without running a proof.
#>
[CmdletBinding()]
param (
    [string[]] $Function,

    [ValidateRange(1, 64)]
    [int] $ThrottleLimit = [Environment]::ProcessorCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


# ============================================================================
# Pure steps: text and result data in, plans and reports out
# ============================================================================

function Get-DescribeName {
    <#
    .SYNOPSIS
        Returns the literal names of the top-level Describe blocks in a test script.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Text
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $null)
    foreach ($statement in $ast.EndBlock.Statements) {
        $command = $statement.Find({ param ($node) $node -is [System.Management.Automation.Language.CommandAst] }, $false)
        if ($null -ne $command -and $command.GetCommandName() -eq 'Describe' -and
            $command.CommandElements.Count -gt 1 -and
            $command.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $command.CommandElements[1].Value
        }
    }
}


function Get-FunctionName {
    <#
    .SYNOPSIS
        Returns the names of the top-level functions defined in a script.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Text
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $null)
    $ast.FindAll({ param ($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object Name
}


function Get-StubbedScriptText {
    <#
    .SYNOPSIS
        Returns the script text with one function body replaced by a stub.
    .DESCRIPTION
        The param block, including CmdletBinding and parameter attributes, is
        kept so callers still bind. Comment-based help inside the body is dropped.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Text,

        [Parameter(Mandatory)]
        [string] $Function,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Stub
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $null)
    $definition = @($ast.FindAll({
                param ($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Function
            }, $false))
    if ($definition.Count -ne 1) {
        throw "Expected one definition of function '$Function', found $($definition.Count)."
    }
    $body = $definition[0].Body
    $parameters = ''
    if ($null -ne $body.ParamBlock) {
        # The param block extent excludes its attributes, such as CmdletBinding.
        $start = $body.ParamBlock.Extent.StartOffset
        foreach ($attribute in $body.ParamBlock.Attributes) {
            $start = [Math]::Min($start, $attribute.Extent.StartOffset)
        }
        $parameters = $Text.Substring($start, $body.ParamBlock.Extent.EndOffset - $start)
    }
    $replacement = "{`n$parameters`n$Stub`n}"
    $Text.Substring(0, $body.Extent.StartOffset) + $replacement + $Text.Substring($body.Extent.EndOffset)
}


function Get-ProofPlan {
    <#
    .SYNOPSIS
        Pairs each Describe with the function and script it proves, plus its stubs.
    .DESCRIPTION
        Script maps root script names (Name.ps1) to their text. A Describe in
        Name.Tests.ps1 targets the function named by DescribeTarget or, by
        default, the Describe name itself, defined in Name.ps1 or a shared
        script. Unmapped Describe blocks are returned with a $null Function.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable] $Script,

        [Parameter(Mandatory)]
        [hashtable] $Configuration,

        [string[]] $Function
    )

    $definedIn = @{}
    foreach ($name in $Script.Keys | Where-Object { $_ -notlike '*.Tests.ps1' } | Sort-Object) {
        foreach ($definedFunction in Get-FunctionName -Text $Script[$name]) {
            $definedIn["$name|$definedFunction"] = $name
        }
    }

    foreach ($testFile in $Script.Keys | Where-Object { $_ -like '*.Tests.ps1' } | Sort-Object) {
        $scriptFile = $testFile -replace '\.Tests\.ps1$', '.ps1'
        foreach ($describe in Get-DescribeName -Text $Script[$testFile]) {
            $target = if ($Configuration.DescribeTarget.Contains($describe)) { $Configuration.DescribeTarget[$describe] } else { $describe }
            $owner = @($scriptFile) + @($Configuration.SharedScript) |
                Where-Object { $definedIn.ContainsKey("$_|$target") } | Select-Object -First 1
            if ($Function -and $target -notin $Function) {
                continue
            }
            $stubs = @($Configuration.DefaultStub)
            if ($Configuration.Stub.Contains($target)) {
                $stubs += @($Configuration.Stub[$target])
            }
            [pscustomobject]@{
                TestFile = $testFile
                Describe = $describe
                Function = if ($owner) { $target } else { $null }
                Script = if ($owner) { $owner } else { $null }
                Stub = @(if ($owner) { $stubs })
            }
        }
    }
}


function Get-ProofReport {
    <#
    .SYNOPSIS
        Compares baseline and stub results and returns every problem found.
    .DESCRIPTION
        Baseline and each run's Test hold objects with Path (expanded test name),
        Describe and Result. A run whose Test is $null produced no results.
    #>
    param (
        [Parameter(Mandatory)]
        [object[]] $Plan,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Baseline,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Run
    )

    foreach ($entry in $Plan) {
        if ($null -eq $entry.Function) {
            [pscustomobject]@{ Kind = 'Unmapped'; Describe = $entry.Describe; Function = $null; Detail = $entry.TestFile }
            continue
        }
        $baselineTests = @($Baseline | Where-Object { $_.Describe -eq $entry.Describe })
        foreach ($test in $baselineTests | Where-Object Result -NE 'Passed' | Where-Object Result -NE 'Skipped') {
            [pscustomobject]@{ Kind = 'Failed'; Describe = $entry.Describe; Function = $entry.Function; Detail = "Baseline $($test.Result): $($test.Path)" }
        }
        if ($baselineTests.Count -eq 0) {
            [pscustomobject]@{ Kind = 'Failed'; Describe = $entry.Describe; Function = $entry.Function; Detail = 'Baseline produced no tests.' }
            continue
        }

        $caught = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($stubRun in $Run | Where-Object { $_.Describe -eq $entry.Describe }) {
            if ($null -eq $stubRun.Test) {
                [pscustomobject]@{ Kind = 'Failed'; Describe = $entry.Describe; Function = $entry.Function; Detail = "Stub run produced no results: $($stubRun.Stub)" }
                continue
            }
            $failed = @($stubRun.Test | Where-Object Result -EQ 'Failed' | ForEach-Object Path)
            foreach ($path in $failed) {
                $null = $caught.Add($path)
            }
            if ($failed.Count -eq 0) {
                [pscustomobject]@{ Kind = 'Uncaught'; Describe = $entry.Describe; Function = $entry.Function; Detail = $stubRun.Stub }
            }
        }
        foreach ($test in $baselineTests | Where-Object Result -EQ 'Passed') {
            if (-not $caught.Contains($test.Path)) {
                [pscustomobject]@{ Kind = 'Unproven'; Describe = $entry.Describe; Function = $entry.Function; Detail = $test.Path }
            }
        }
    }
}


# ============================================================================
# File system and process boundary
# ============================================================================

function Invoke-ProofRun {
    <#
    .SYNOPSIS
        Runs each job's Describe in its own pwsh process on a temporary copy.
    .OUTPUTS
        One object per job with Id and Test (test results, or $null on failure).
    #>
    param (
        [Parameter(Mandatory)]
        [object[]] $Job,

        [Parameter(Mandatory)]
        [string] $SourceDirectory,

        [Parameter(Mandatory)]
        [string] $PesterVersion,

        [int] $ThrottleLimit
    )

    $child = @'
param ($TestPath, $Describe, $ResultPath, $PesterVersion)
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion $PesterVersion
$configuration = New-PesterConfiguration
$configuration.Run.Path = $TestPath
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$configuration.Filter.FullName = "$Describe.*"
$result = Invoke-Pester -Configuration $configuration
@($result.Tests | Where-Object { "$($_.Result)" -ne 'NotRun' } | ForEach-Object {
        [pscustomobject]@{ Path = $_.ExpandedPath; Describe = $_.Path[0]; Result = "$($_.Result)" }
    }) | ConvertTo-Json -Depth 3 -AsArray | Set-Content -LiteralPath $ResultPath
'@
    $sources = @(Get-ChildItem -LiteralPath $SourceDirectory -File | Where-Object Extension -In @('.ps1', '.psd1'))

    $Job | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $job = $_
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) "test-proof-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $directory | Out-Null
        try {
            foreach ($source in $using:sources) {
                Copy-Item -LiteralPath $source.FullName -Destination $directory
            }
            if ($null -ne $job.ScriptText) {
                Set-Content -LiteralPath (Join-Path $directory $job.Script) -Value $job.ScriptText -NoNewline
            }
            $childPath = Join-Path $directory 'Invoke-TestProof.Child.ps1'
            Set-Content -LiteralPath $childPath -Value $using:child
            $resultPath = Join-Path $directory 'result.json'
            & pwsh -NoProfile -NonInteractive -File $childPath -TestPath (Join-Path $directory $job.TestFile) `
                -Describe $job.Describe -ResultPath $resultPath -PesterVersion $using:PesterVersion *> $null
            $tests = if (Test-Path -LiteralPath $resultPath) {
                @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
            }
            else {
                $null
            }
            [pscustomobject]@{ Id = $job.Id; Test = $tests }
        }
        finally {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


function Invoke-TestProof {
    [CmdletBinding()]
    param (
        [string[]] $Function,

        [int] $ThrottleLimit = [Environment]::ProcessorCount
    )

    $configuration = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'TestProofs.psd1')
    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    $script = @{}
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
        $script[$file.Name] = Get-Content -LiteralPath $file.FullName -Raw
    }

    $plan = @(Get-ProofPlan -Script $script -Configuration $configuration -Function $Function)
    $proven = @($plan | Where-Object { $null -ne $_.Function })
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $proven) {
        $jobs.Add([pscustomobject]@{
                Id = "baseline|$($entry.Describe)"; TestFile = $entry.TestFile; Describe = $entry.Describe
                Script = $null; ScriptText = $null; Stub = $null
            })
        foreach ($stub in $entry.Stub) {
            $jobs.Add([pscustomobject]@{
                    Id = "stub|$($entry.Describe)|$($jobs.Count)"; TestFile = $entry.TestFile; Describe = $entry.Describe
                    Script = $entry.Script; Stub = $stub
                    ScriptText = Get-StubbedScriptText -Text $script[$entry.Script] -Function $entry.Function -Stub $stub
                })
        }
    }

    Write-Host "Proving $($proven.Count) Describe blocks with $($jobs.Count) runs..." -ForegroundColor Cyan
    $started = Get-Date
    $results = @{}
    if ($jobs.Count) {
        foreach ($result in Invoke-ProofRun -Job $jobs.ToArray() -SourceDirectory $PSScriptRoot `
                -PesterVersion $dependencies['Pester'] -ThrottleLimit $ThrottleLimit) {
            $results[$result.Id] = $result.Test
        }
    }

    $baseline = @($jobs | Where-Object { $_.Id -like 'baseline|*' } | ForEach-Object { @($results[$_.Id]) } |
            Where-Object { $null -ne $_ })
    $runs = @($jobs | Where-Object { $_.Id -like 'stub|*' } | ForEach-Object {
            [pscustomobject]@{ Describe = $_.Describe; Stub = $_.Stub; Test = $results[$_.Id] }
        })
    $problems = @(Get-ProofReport -Plan $plan -Baseline $baseline -Run $runs)

    $duration = (Get-Date) - $started
    $provenCount = @($baseline | Where-Object Result -EQ 'Passed').Count - @($problems | Where-Object Kind -EQ 'Unproven').Count
    Write-Host ("Proven tests: {0}; problems: {1}; duration: {2:mm\:ss}" -f $provenCount, $problems.Count, $duration) `
        -ForegroundColor $(if ($problems.Count) { 'Yellow' } else { 'Green' })
    $problems
}


if ($MyInvocation.InvocationName -ne '.') {
    $problems = @(Invoke-TestProof -Function $Function -ThrottleLimit $ThrottleLimit)
    $problems
    if (@($problems | Where-Object Kind -In @('Unproven', 'Uncaught', 'Failed')).Count) {
        exit 1
    }
}
