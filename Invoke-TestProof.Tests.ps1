#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests the planning and reporting steps of the test-proof runner.
.DESCRIPTION
    All steps are pure and receive script text and result objects directly.
    The process boundary (Invoke-ProofRun, Invoke-TestProof) is exercised by
    running Invoke-TestProof.ps1 itself.
.EXAMPLE
    Invoke-Pester -Path .\Invoke-TestProof.Tests.ps1
.NOTES
    Requires PowerShell 7 and Pester.
#>
BeforeAll {
    . "$PSScriptRoot\Invoke-TestProof.ps1"

    $script:configuration = @{
        DefaultStub = @('return')
        SharedScript = @('Shared.ps1')
        DescribeTarget = @{ 'Entry point' = 'Invoke-Main' }
        Stub = @{ 'Test-Thing' = @('return $true') }
    }
    $script:sources = @{
        'Tool.ps1' = "function Test-Thing { param ([int] `$Value) `$Value -gt 1 }`nfunction Invoke-Main { 'main' }"
        'Shared.ps1' = 'function Get-Shared { 1 }'
        'Tool.Tests.ps1' = @"
BeforeAll { . `$PSScriptRoot\Tool.ps1 }
Describe 'Test-Thing' { It 'a' { } }
Describe 'Get-Shared' { It 'b' { } }
Describe 'Entry point' { It 'c' { } }
Describe 'Nothing' { It 'd' { } }
"@
    }
}

Describe 'Get-DescribeName' {
    It 'returns only top-level literal Describe names' {
        $text = @'
BeforeAll { }
Describe 'One' { Describe 'Nested' { } }
Describe "Two" -Tag Integration { }
Describe $dynamic { }
'@
        @(Get-DescribeName -Text $text) | Should -BeExactly @('One', 'Two')
    }
}

Describe 'Get-FunctionName' {
    It 'returns only top-level functions' {
        @(Get-FunctionName -Text "function A { function Inner { } }`nfunction B { }") | Should -BeExactly @('A', 'B')
    }
}

Describe 'Get-StubbedScriptText' {
    It 'replaces only the body, keeps the param block and other functions' {
        $text = @'
function Keep { 'kept' }
function Target {
    <# help #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [int] $Value)
    $Value * 2
}
'@
        $stubbed = Get-StubbedScriptText -Text $text -Function 'Target' -Stub 'return 0'
        $stubbed | Should -BeLike "*function Keep { 'kept' }*"
        $stubbed | Should -BeLike '*`[CmdletBinding()]*param (`[Parameter(Mandatory)] `[int] $Value)*return 0*'
        $stubbed | Should -Not -BeLike '*$Value `* 2*'
        & ([scriptblock]::Create("$stubbed; Target -Value 5")) | Should -Be 0
    }

    It 'stubs a function without a param block' {
        $stubbed = Get-StubbedScriptText -Text "function Target { 'real' }" -Function 'Target' -Stub "'stub'"
        & ([scriptblock]::Create("$stubbed; Target")) | Should -BeExactly 'stub'
    }

    It 'throws when the function is missing' {
        { Get-StubbedScriptText -Text 'function Other { }' -Function 'Target' -Stub '' } |
            Should -Throw "*one definition of function 'Target', found 0*"
    }
}

Describe 'Get-ProofPlan' {
    BeforeAll {
        $script:plan = @(Get-ProofPlan -Script $sources -Configuration $configuration)
    }

    It 'maps each Describe to its function and owning script' {
        $plan.Describe | Should -BeExactly @('Test-Thing', 'Get-Shared', 'Entry point', 'Nothing')
        $plan.Function | Should -BeExactly @('Test-Thing', 'Get-Shared', 'Invoke-Main', $null)
        $plan.Script | Should -BeExactly @('Tool.ps1', 'Shared.ps1', 'Tool.ps1', $null)
    }

    It 'adds function-specific stubs to the defaults' {
        $plan[0].Stub | Should -BeExactly @('return', 'return $true')
        $plan[1].Stub | Should -BeExactly @('return')
    }

    It 'gives an unmapped Describe no stubs' {
        $plan[3].Stub.Count | Should -Be 0
    }

    It 'limits the plan to the selected functions' {
        @(Get-ProofPlan -Script $sources -Configuration $configuration -Function 'Get-Shared').Describe |
            Should -BeExactly @('Get-Shared')
    }
}

Describe 'Get-ProofReport' {
    BeforeAll {
        $script:entry = [pscustomobject]@{ TestFile = 'T.Tests.ps1'; Describe = 'F'; Function = 'F'; Script = 'T.ps1'; Stub = @('return') }
        function New-Test {
            param ([string] $Path, [string] $Result = 'Passed')
            [pscustomobject]@{ Path = $Path; Describe = 'F'; Result = $Result }
        }
    }

    It 'reports nothing when every test failed under some stub' {
        $runs = @(
            [pscustomobject]@{ Describe = 'F'; Stub = 'return'; Test = @((New-Test 'F.a' 'Failed'), (New-Test 'F.b')) }
            [pscustomobject]@{ Describe = 'F'; Stub = 'x'; Test = @((New-Test 'F.a'), (New-Test 'F.b' 'Failed')) }
        )
        @(Get-ProofReport -Plan @($entry) -Baseline @((New-Test 'F.a'), (New-Test 'F.b')) -Run $runs).Count | Should -Be 0
    }

    It 'reports a test that never failed as Unproven' {
        $runs = @([pscustomobject]@{ Describe = 'F'; Stub = 'return'; Test = @((New-Test 'F.a' 'Failed'), (New-Test 'F.b')) })
        $problem = Get-ProofReport -Plan @($entry) -Baseline @((New-Test 'F.a'), (New-Test 'F.b')) -Run $runs
        $problem.Kind | Should -BeExactly 'Unproven'
        $problem.Detail | Should -BeExactly 'F.b'
    }

    It 'reports a stub that no test caught as Uncaught' {
        $runs = @(
            [pscustomobject]@{ Describe = 'F'; Stub = 'return'; Test = @(New-Test 'F.a' 'Failed') }
            [pscustomobject]@{ Describe = 'F'; Stub = 'quiet'; Test = @(New-Test 'F.a') }
        )
        $problem = Get-ProofReport -Plan @($entry) -Baseline @(New-Test 'F.a') -Run $runs
        $problem.Kind | Should -BeExactly 'Uncaught'
        $problem.Detail | Should -BeExactly 'quiet'
    }

    It 'reports baseline failures, empty baselines and runs without results as Failed' {
        $other = [pscustomobject]@{ TestFile = 'T.Tests.ps1'; Describe = 'G'; Function = 'G'; Script = 'T.ps1'; Stub = @('return') }
        $runs = @([pscustomobject]@{ Describe = 'F'; Stub = 'return'; Test = $null })
        $problems = @(Get-ProofReport -Plan @($entry, $other) -Baseline @(New-Test 'F.a' 'Failed') -Run $runs)
        $problems.Kind | Should -BeExactly @('Failed', 'Failed', 'Failed')
        $problems.Detail | Should -BeExactly @('Baseline Failed: F.a', 'Stub run produced no results: return', 'Baseline produced no tests.')
    }

    It 'reports a Describe without a function as Unmapped' {
        $unmapped = [pscustomobject]@{ TestFile = 'T.Tests.ps1'; Describe = 'X'; Function = $null; Script = $null; Stub = @() }
        (Get-ProofReport -Plan @($unmapped) -Baseline @() -Run @()).Kind | Should -BeExactly 'Unmapped'
    }
}
