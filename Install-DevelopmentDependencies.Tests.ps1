#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests verified development-module installation with local archive fixtures.
.DESCRIPTION
    Exercises pin-file consistency, matching and mismatched SHA-512 pins, refusal
    to overwrite an installed version, and temporary cleanup that preserves the
    installation error. Archives are real zip files created in Pester's TestDrive.
    Nothing is mocked; the Gallery download in Install-DevelopmentModule is the
    untested network boundary.
.EXAMPLE
    Invoke-Pester -Path .\Install-DevelopmentDependencies.Tests.ps1
    Runs only the installer tests.
.INPUTS
    None. Run this file through Pester rather than invoking it directly.
.OUTPUTS
    None. Pester reports results; use Invoke-Pester -PassThru for result objects.
.NOTES
    Requires PowerShell 7 and Pester. Use the repository-pinned Pester version.
    Fixture files are managed by Pester's TestDrive.
#>
BeforeAll {
    . "$PSScriptRoot\Install-DevelopmentDependencies.ps1" -Destination $TestDrive
}

Describe 'Get-DependencyPinProblem' {
    BeforeAll {
        $script:pins = @{ Pester = @{ Version = '6.2.0'; SHA512 = 'x' } }
    }

    It 'returns nothing when every version has its hash pin' {
        Get-DependencyPinProblem -Dependency @{ Pester = '6.2.0' } -Hash $pins | Should -BeNullOrEmpty
    }

    It 'reports <Name>' -ForEach @(
        @{ Name = 'a different count'; Dependency = @{ Pester = '6.2.0'; Other = '1.0.0' }; Expected = 'Dependency versions and package hash pins do not match.' }
        @{ Name = 'a missing pin'; Dependency = @{ Other = '1.0.0' }; Expected = "Missing or mismatched package hash pin for 'Other'." }
        @{ Name = 'a version mismatch'; Dependency = @{ Pester = '6.3.0' }; Expected = "Missing or mismatched package hash pin for 'Pester'." }
    ) {
        Get-DependencyPinProblem -Dependency $Dependency -Hash $pins | Should -BeExactly $Expected
    }
}

Describe 'Install-ModuleArchive' {
    BeforeEach {
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $source | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'Example.psd1') -Value "@{ ModuleVersion = '1.0.0' }"
        $script:testArchive = Join-Path $TestDrive "$([guid]::NewGuid()).zip"
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $testArchive)
        $script:hash = (Get-FileHash -LiteralPath $testArchive -Algorithm SHA512).Hash
        $script:testDestination = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:work = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $work | Out-Null

        function Install-Example {
            param ([string] $SHA512 = $hash, [string] $Name = 'Example')
            Install-ModuleArchive -Archive $testArchive -Name $Name -Version 1.0.0 -SHA512 $SHA512 `
                -Destination $testDestination -WorkingDirectory $work 6>$null
        }
    }

    It 'installs the archive matching the pinned hash' {
        Install-Example
        Test-Path -LiteralPath (Join-Path $testDestination 'Example\1.0.0\Example.psd1') | Should -BeTrue
    }

    It 'rejects a modified archive without installing it' {
        { Install-Example -SHA512 ('0' * 128) } | Should -Throw '*SHA-512 mismatch*'
        Test-Path -LiteralPath $testDestination | Should -BeFalse
    }

    It 'rejects an archive without the module manifest without installing it' {
        { Install-Example -Name 'Other' } | Should -Throw '*does not contain its module manifest*'
        Test-Path -LiteralPath $testDestination | Should -BeFalse
    }

    It 'refuses to overwrite an existing module version' {
        Install-Example
        { Install-Example } | Should -Throw '*already exists*'
    }
}

Describe 'Remove-TemporaryDirectory' {
    It 'removes the directory' {
        $path = Join-Path $TestDrive 'temporary'
        New-Item -ItemType Directory -Path (Join-Path $path 'nested') -Force | Out-Null
        Remove-TemporaryDirectory -Path $path
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'throws a removal failure when there is no installation error' {
        { Remove-TemporaryDirectory -Path (Join-Path $TestDrive 'missing') } | Should -Throw
    }

    It 'reports a removal failure without throwing when an installation error exists' {
        $output = Remove-TemporaryDirectory -Path (Join-Path $TestDrive 'missing') -InstallationError 'install failed' 2>&1
        "$output" | Should -BeLike '*Could not remove temporary directory*installation error is preserved*'
    }
}
