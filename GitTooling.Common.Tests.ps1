#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests the shared GitHub location and Git worktree parsing helpers.
.DESCRIPTION
    Location and worktree parsing are pure and tested with plain text. The Git
    wrapper is tested against the real Git executable; nothing is mocked.
.EXAMPLE
    Invoke-Pester -Path .\GitTooling.Common.Tests.ps1
    Runs the shared helper tests.
.INPUTS
    None. Run this file through Pester rather than invoking it directly.
.OUTPUTS
    None. Pester reports results; use Invoke-Pester -PassThru for result objects.
.NOTES
    Requires PowerShell 7, Pester and Git on PATH for the Invoke-Git tests.
#>
BeforeAll {
    . "$PSScriptRoot\GitTooling.Common.ps1"
}

Describe 'Get-GitHubLocationPath' {
    It 'returns <Expected> for <Location>' -ForEach @(
        @{ Location = 'https://github.com/example'; Expected = 'example' }
        @{ Location = 'https://github.com/example/'; Expected = 'example' }
        @{ Location = 'https://github.com/example/github'; Expected = 'example/github' }
        @{ Location = 'https://github.com/example/github/tree/feature/git-workflow-tooling'; Expected = 'example/github/tree/feature/git-workflow-tooling' }
        @{ Location = 'github.com/example/github/'; Expected = 'example/github' }
        @{ Location = 'github.com:example/github'; Expected = 'example/github' }
        @{ Location = 'http://www.github.com/o/r'; Expected = 'o/r' }
        @{ Location = 'git@github.com:o/r.git'; Expected = 'o/r.git' }
        @{ Location = 'ssh://git@github.com/o/r'; Expected = 'o/r' }
        @{ Location = 'https://token@github.com/o/r?tab=readme#top'; Expected = 'o/r' }
        @{ Location = ' example '; Expected = 'example' }
        @{ Location = 'o/r/'; Expected = 'o/r' }
    ) {
        Get-GitHubLocationPath -Location $Location | Should -BeExactly $Expected
    }

    It 'rejects a host other than github.com: <Location>' -ForEach @(
        @{ Location = 'https://gitlab.com/o/r' }
        @{ Location = 'https://github.example.com/o/r' }
        @{ Location = 'git@gitlab.com:o/r.git' }
    ) {
        { Get-GitHubLocationPath -Location $Location } | Should -Throw '*is not a github.com location*'
    }
}

Describe 'ConvertFrom-GitHubPath' {
    It 'splits <Path>' -ForEach @(
        @{ Path = 'example'; Expected = 'example||' }
        @{ Path = 'example/github'; Expected = 'example|github|' }
        @{ Path = 'o/r.git'; Expected = 'o|r|' }
        @{ Path = 'o/my.repo'; Expected = 'o|my.repo|' }
        @{ Path = 'o/r/tree/main'; Expected = 'o|r|main' }
        @{ Path = 'o/r/tree/feature/login/'; Expected = 'o|r|feature/login' }
        @{ Path = 'o/r/tree/feature%23x'; Expected = 'o|r|feature#x' }
    ) {
        $location = ConvertFrom-GitHubPath -Path $Path
        "$($location.Owner)|$($location.Repository)|$($location.Branch)" | Should -BeExactly $Expected
    }

    It 'returns null, not empty, for absent parts' {
        $location = ConvertFrom-GitHubPath -Path 'example'
        $null -eq $location.Repository | Should -BeTrue
        $null -eq $location.Branch | Should -BeTrue
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an empty path'; Path = ''; Message = '*owner is required*' }
        @{ Case = 'an invalid owner'; Path = 'bad_owner/r'; Message = '*not a valid GitHub owner*' }
        @{ Case = 'a dot repository'; Path = 'o/..'; Message = '*not a valid GitHub repository name*' }
        @{ Case = 'another repository page'; Path = 'o/r/issues'; Message = '*Unsupported GitHub repository path*' }
        @{ Case = 'a tree path without branch'; Path = 'o/r/tree'; Message = '*Unsupported GitHub repository path*' }
        @{ Case = 'a differently cased tree segment'; Path = 'o/r/Tree/main'; Message = '*Unsupported GitHub repository path*' }
    ) {
        { ConvertFrom-GitHubPath -Path $Path } | Should -Throw $Message
    }
}

Describe 'Resolve-GitHubTarget' {
    It 'resolves <Case>' -ForEach @(
        @{ Case = 'an owner name'; Owner = 'example'; Url = ''; BranchOnly = $false; Expected = 'example||' }
        @{ Case = 'an owner URL given as owner'; Owner = 'https://github.com/example/'; Url = ''; BranchOnly = $false; Expected = 'example||' }
        @{ Case = 'URL A'; Owner = ''; Url = 'https://github.com/example'; BranchOnly = $false; Expected = 'example||' }
        @{ Case = 'URL B1'; Owner = ''; Url = 'https://github.com/example/github/'; BranchOnly = $false; Expected = 'example|github|' }
        @{ Case = 'URL B2 without BranchOnly'; Owner = ''; Url = 'https://github.com/example/github/tree/feature/git-workflow-tooling'; BranchOnly = $false; Expected = 'example|github|' }
        @{ Case = 'URL B2 with BranchOnly'; Owner = ''; Url = 'https://github.com/example/github/tree/feature/git-workflow-tooling/'; BranchOnly = $true; Expected = 'example|github|feature/git-workflow-tooling' }
        @{ Case = 'a URL in place of a default owner'; Owner = 'example'; Url = 'github.com/other/repo'; BranchOnly = $false; Expected = 'other|repo|' }
    ) {
        $target = Resolve-GitHubTarget -GitHubOwner $Owner -Url $Url -BranchOnly:$BranchOnly
        "$($target.Owner)|$($target.Repository)|$($target.Branch)" | Should -BeExactly $Expected
    }

    It 'rejects a repository passed as owner' {
        { Resolve-GitHubTarget -GitHubOwner 'example/github' } | Should -Throw '*use -Url*'
    }

    It 'rejects -BranchOnly without a branch URL' {
        { Resolve-GitHubTarget -Url 'https://github.com/example/github' -BranchOnly } |
            Should -Throw '*-BranchOnly requires a branch URL*'
    }
}

Describe 'ConvertFrom-GitWorktreeList' {
    It 'parses bare, branch, detached and locked records' {
        $text = @(
            'worktree /r/.git', 'bare', ''
            'worktree /r/feature # café', 'HEAD abc', 'branch refs/heads/feature/login', 'locked reason', ''
            'worktree /r/detached', 'HEAD def', 'detached', ''
        ) -join "`0"
        $records = @(ConvertFrom-GitWorktreeList -Text $text)
        ($records | ForEach-Object { "$($_.Path)|$($_.Branch)|$($_.Bare)|$($_.Locked)" }) | Should -Be @(
            '/r/.git||True|False'
            '/r/feature # café|feature/login|False|True'
            '/r/detached||False|False'
        )
    }

    It 'joins output that PowerShell split into several strings' {
        $records = @(ConvertFrom-GitWorktreeList -Text @("worktree /a`0branch refs/he", "ads/main`0"))
        $records.Branch | Should -BeExactly 'main'
    }

    It 'returns nothing for empty output' {
        @(ConvertFrom-GitWorktreeList -Text @()).Count | Should -Be 0
        @(ConvertFrom-GitWorktreeList -Text '').Count | Should -Be 0
    }
}

Describe 'Invoke-Git' -Tag Integration {
    It 'throws when Git fails without AllowFailure' {
        { Invoke-Git -Arguments @('not-a-git-command') 2>$null } | Should -Throw '*Git command failed: git not-a-git-command*'
    }

    It 'keeps the exit code inspectable with AllowFailure, even when native errors are enabled' {
        $PSNativeCommandUseErrorActionPreference = $true
        { Invoke-Git -AllowFailure -Arguments @('not-a-git-command') 2>$null } | Should -Not -Throw
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'passes an empty argument through to Git' {
        Invoke-Git -Arguments @('rev-parse', '--sq-quote', 'a', '') | Should -BeExactly " 'a' ''"
    }
}
