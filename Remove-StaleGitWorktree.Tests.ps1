#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests stale worktree cleanup steps and their composition against real Git.
.DESCRIPTION
    Pure steps such as folder matching, ls-remote and for-each-ref parsing,
    candidate selection and location safety are tested with plain input and
    output. Removal, repository selection and the script entry point are tested
    one layer up, tagged Integration, against fresh local origin and managed bare
    repositories. Nothing is mocked; host and warning output is captured from
    the PowerShell streams.
.EXAMPLE
    Invoke-Pester -Path .\Remove-StaleGitWorktree.Tests.ps1 -ExcludeTagFilter Integration
    Runs only the fast pure-step tests.
.INPUTS
    None. Run this file through Pester rather than invoking it directly.
.OUTPUTS
    None. Pester reports results; use Invoke-Pester -PassThru for result objects.
.NOTES
    Requires PowerShell 7 and Pester; integration tests require Git. Fixtures
    live in Pester's TestDrive, not GitHub or the developer's repositories, and
    include worktree and branch removal within that temporary area.
#>
BeforeAll {
    . "$PSScriptRoot\Remove-StaleGitWorktree.ps1"
    . "$PSScriptRoot\GitTooling.TestHelpers.ps1"

    # <root>\o\managed is a bare-layout repository whose 'deleted' worktree tracks a
    # branch already deleted on <root>\remote.
    function New-CleanupFixture {
        param ([string] $Root = (Join-Path $TestDrive ([guid]::NewGuid().ToString())), [string] $Name = 'managed')

        $remote = Join-Path $Root "remote-$Name"
        $repository = Join-Path (Join-Path $Root 'o') $Name
        $bare = Join-Path $repository '.git'
        $worktree = Join-Path $repository 'feature with spaces'
        New-SourceRepository -Path $remote -Branch @('deleted')
        Invoke-Git -Arguments @('init', '--quiet', '--bare', '--initial-branch=main', $bare) | Out-Null
        Invoke-Git -Arguments @('-C', $bare, 'remote', 'add', 'origin', $remote)
        Invoke-Git -Arguments @('-C', $bare, 'fetch', '--quiet', 'origin') 2>$null
        Add-TrackingWorktree -Bare $bare -Branch 'deleted' -Path $worktree
        Invoke-Git -Arguments @('-C', $remote, 'branch', '-D', 'deleted') | Out-Null
        [pscustomobject]@{
            Root = $Root
            Remote = $remote
            Repository = $repository
            Bare = $bare
            Worktree = $worktree
        }
    }

    function Add-TrackingWorktree {
        param ([string] $Bare, [string] $Branch, [string] $Path)

        Invoke-Git -Arguments @(
            '-C', $Bare, 'worktree', 'add', '--quiet', '--track', '-b', $Branch, $Path, "origin/$Branch"
        ) 2>$null | Out-Null
    }

    function Test-LocalBranch {
        param ([string] $Bare, [string] $Branch)

        Invoke-Git -AllowFailure -Arguments @('-C', $Bare, 'show-ref', '--verify', '--quiet', "refs/heads/$Branch")
        return $LASTEXITCODE -eq 0
    }
}

# ============================================================================
# Pure steps
# ============================================================================

Describe 'Select-DirectoryName' {
    It 'returns <Expected> for <Name> among <Candidate>' -ForEach @(
        @{ Name = 'example'; Candidate = @('example', 'example'); Expected = 'example' }
        @{ Name = 'example'; Candidate = @('example', 'other'); Expected = 'example' }
        @{ Name = 'github'; Candidate = @('github'); Expected = 'github' }
    ) {
        Select-DirectoryName -Name $Name -Candidate $Candidate | Should -BeExactly $Expected
    }

    It 'returns null when nothing matches' {
        Select-DirectoryName -Name 'missing' -Candidate @('example') | Should -BeNullOrEmpty
        Select-DirectoryName -Name 'missing' -Candidate @() | Should -BeNullOrEmpty
    }

    It 'rejects several case-only matches' {
        { Select-DirectoryName -Name 'example' -Candidate @('Example', 'EXAMPLE') } | Should -Throw '*Several folders*'
    }
}

Describe 'ConvertFrom-RemoteHeadList' {
    It 'returns branch names, including nested and case-distinct ones' {
        $branches = ConvertFrom-RemoteHeadList -Line @(
            "$('a' * 40)`trefs/heads/main"
            "$('b' * 40)`trefs/heads/feature/login"
            "$('c' * 64)`trefs/heads/Feature"
        )
        $branches | Should -BeExactly @('main', 'feature/login', 'Feature')
    }

    It 'returns an empty list, not null, for no lines' {
        $branches = ConvertFrom-RemoteHeadList -Line @()
        $null -eq $branches | Should -BeFalse
        $branches.Count | Should -Be 0
    }

    It 'rejects an unexpected line' {
        { ConvertFrom-RemoteHeadList -Line @("$('a' * 40)`trefs/tags/v1") } | Should -Throw '*Unexpected remote branch line*'
    }
}

Describe 'Get-RemoteDefaultCommit' {
    BeforeAll {
        $commit = 'a' * 40
        $script:heads = @("$commit`trefs/heads/main", "$('b' * 40)`trefs/heads/other")
    }

    It 'returns the commit of the branch HEAD points to' {
        Get-RemoteDefaultCommit -SymrefLine @("ref: refs/heads/main`tHEAD", "$commit`tHEAD") -HeadLine $heads |
            Should -BeExactly $commit
    }

    It 'returns null when <Case>' -ForEach @(
        @{ Case = 'HEAD is not symbolic'; Symref = @("$('a' * 40)`tHEAD") }
        @{ Case = 'HEAD has no commit'; Symref = @("ref: refs/heads/main`tHEAD") }
        @{ Case = 'HEAD names a missing branch'; Symref = @("ref: refs/heads/gone`tHEAD", "$('a' * 40)`tHEAD") }
        @{ Case = 'the branch has another commit'; Symref = @("ref: refs/heads/other`tHEAD", "$('a' * 40)`tHEAD") }
        @{ Case = 'nothing was returned'; Symref = @() }
    ) {
        Get-RemoteDefaultCommit -SymrefLine $Symref -HeadLine $heads | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-UpstreamList' {
    It 'maps local branches to their upstream, keeping case-distinct names apart' {
        $upstreams = ConvertFrom-UpstreamList -Line @(
            "refs/heads/main`trefs/remotes/origin/main"
            "refs/heads/Main`t"
            "refs/heads/feature/x`trefs/remotes/fork/feature/x"
        )
        $upstreams.Count | Should -Be 3
        $upstreams['main'] | Should -BeExactly 'refs/remotes/origin/main'
        $upstreams['Main'] | Should -BeExactly ''
        $upstreams['feature/x'] | Should -BeExactly 'refs/remotes/fork/feature/x'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a line without a tab'; Line = 'refs/heads/main' }
        @{ Case = 'a non-branch ref'; Line = "refs/tags/v1`t" }
    ) {
        { ConvertFrom-UpstreamList -Line @($Line) } | Should -Throw '*Unexpected local branch line*'
    }
}

Describe 'Test-StaleWorktreeCandidate' {
    BeforeAll {
        $script:upstreams = ConvertFrom-UpstreamList -Line @(
            "refs/heads/gone`trefs/remotes/origin/gone"
            "refs/heads/kept`trefs/remotes/origin/kept"
            "refs/heads/local`t"
            "refs/heads/forked`trefs/remotes/fork/forked"
            "refs/heads/Gone`trefs/remotes/origin/Gone"
        )
        $script:remote = @('kept', 'Gone')
    }

    It 'returns <Expected> for branch <Branch>' -ForEach @(
        @{ Branch = 'gone'; Expected = $true }
        @{ Branch = 'kept'; Expected = $false }
        @{ Branch = 'Gone'; Expected = $false }
        @{ Branch = 'local'; Expected = $false }
        @{ Branch = 'forked'; Expected = $false }
        @{ Branch = 'unknown'; Expected = $false }
        @{ Branch = ''; Expected = $false }
    ) {
        Test-StaleWorktreeCandidate -Worktree ([pscustomobject]@{ Branch = $Branch }) -Upstream $upstreams -RemoteBranch $remote |
            Should -Be $Expected
    }

    It 'with a selected branch, accepts only that branch: <Selected>' -ForEach @(
        @{ Selected = 'gone'; Expected = $true }
        @{ Selected = 'Gone'; Expected = $false }
        @{ Selected = 'other'; Expected = $false }
    ) {
        Test-StaleWorktreeCandidate -Worktree ([pscustomobject]@{ Branch = 'gone' }) -Upstream $upstreams `
            -RemoteBranch $remote -Branch $Selected | Should -Be $Expected
    }
}

Describe 'Get-WorktreeLocationSkipReason' {
    BeforeAll {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) 'o\r'
        $script:path = Join-Path $root 'feature'
    }

    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'a clean location'; Options = @{}; Expected = '' }
        @{ Case = 'a sibling of the root'; Options = @{ Path = '..\other' }; Expected = 'outside the managed worktree folders' }
        @{ Case = 'a root-prefixed sibling'; Options = @{ Path = '..\r-other\feature' }; Expected = 'outside the managed worktree folders' }
        @{ Case = 'the root itself'; Options = @{ Path = '.' }; Expected = 'outside the managed worktree folders' }
        @{ Case = 'the bare repository'; Options = @{ Path = '.git' }; Expected = 'outside the managed worktree folders' }
        @{ Case = 'inside the bare repository'; Options = @{ Path = '.git\worktrees\x' }; Expected = 'outside the managed worktree folders' }
        @{ Case = 'a locked worktree'; Options = @{ Locked = $true }; Expected = 'locked' }
        @{ Case = 'the current directory'; Options = @{ Current = 'feature' }; Expected = 'contains the current directory' }
        @{ Case = 'an ancestor of the current directory'; Options = @{ Current = 'feature\src' }; Expected = 'contains the current directory' }
        @{ Case = 'a prefix-named sibling of the current directory'; Options = @{ Current = 'feature-2' }; Expected = '' }
        @{ Case = 'a nested worktree'; Options = @{ Other = 'feature\nested' }; Expected = 'contains another registered worktree' }
        @{ Case = 'itself among other worktrees'; Options = @{ Other = 'feature' }; Expected = '' }
    ) {
        $arguments = @{
            Path = if ($Options['Path']) { Join-Path $root $Options['Path'] } else { $path }
            RepositoryRoot = $root
            Locked = [bool] $Options['Locked']
        }
        if ($Options['Current']) { $arguments.CurrentPath = Join-Path $root $Options['Current'] }
        if ($Options['Other']) { $arguments.OtherPath = @(Join-Path $root $Options['Other']) }
        Get-WorktreeLocationSkipReason @arguments | Should -BeExactly $Expected
    }

    It 'accepts the forward slashes Git reports on Windows' {
        Get-WorktreeLocationSkipReason -Path $path.Replace('\', '/') -RepositoryRoot $root | Should -BeExactly ''
    }
}

# ============================================================================
# Real Git, one layer up
# ============================================================================

Describe 'Remove-StaleRepositoryWorktree' -Tag Integration {
    BeforeEach {
        $script:fixture = New-CleanupFixture
    }

    It 'previews without removing the folder or stale tracking ref' {
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/remotes/origin/deleted') |
            Should -Not -BeNullOrEmpty
        $run.Host | Should -Be @("[DRY RUN] Would remove '$($fixture.Worktree)' (branch is preserved for 'deleted').")
    }

    It 'removes the registered worktree but retains its local branch' {
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeTrue
        $run.Host | Should -Contain "Local branch 'deleted' is preserved."
    }

    It 'deletes an opted-in branch only after it is merged into the remote default branch' {
        $null = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeFalse
    }

    It 'preserves unmerged commits even if the stale upstream contains them' {
        Invoke-Git -Arguments @(
            '-C', $fixture.Worktree, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '--quiet', '--allow-empty', '-m', 'Unmerged'
        ) | Out-Null
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'update-ref', 'refs/remotes/origin/deleted', 'refs/heads/deleted')
        $null = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeTrue
    }

    It 'preserves the branch when the remote default branch cannot be determined' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'symbolic-ref', 'HEAD', 'refs/heads/missing')
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeTrue
        $run.Warning | Should -BeLike "*default branch*preserved*"
    }

    It 'previews opted-in branch deletion without removing anything' {
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -DeleteMergedBranch }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeTrue
        $run.Host | Should -BeLike '*would attempt safe branch deletion*'
    }

    It 'honors WhatIf when applying' {
        $null = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch -WhatIf }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Test-LocalBranch -Bare $fixture.Bare -Branch 'deleted' | Should -BeTrue
    }

    It 'keeps worktrees whose remote branch still exists' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'branch', 'deleted')
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Host.Count | Should -Be 0
    }

    It 'with a selected branch, removes only that branch''s worktree' {
        $other = Join-Path $fixture.Repository 'other'
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'branch', 'other')
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'fetch', '--quiet', 'origin') 2>$null
        Add-TrackingWorktree -Bare $fixture.Bare -Branch 'other' -Path $other
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'branch', '-D', 'other') | Out-Null

        $null = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Branch 'other' -Apply }
        Test-Path -LiteralPath $other | Should -BeFalse
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'reports a selected branch without a stale worktree' {
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Branch 'main' -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Host | Should -Be @("No stale worktree for branch 'main' in '$($fixture.Repository)'.")
    }

    It 'skips <Kind> files' -ForEach @(
        @{ Kind = 'untracked'; Name = 'notes.txt' }
        @{ Kind = 'ignored'; Name = 'scratch.log' }
        @{ Kind = 'staged'; Name = 'staged.txt' }
    ) {
        if ($Kind -eq 'ignored') {
            '*.log' | Set-Content -LiteralPath (Join-Path $fixture.Bare 'info\exclude')
        }
        'preserve me' | Set-Content -LiteralPath (Join-Path $fixture.Worktree $Name)
        if ($Kind -eq 'staged') {
            Invoke-Git -Arguments @('-C', $fixture.Worktree, 'add', $Name)
        }
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Warning | Should -Be @("Skipping '$($fixture.Worktree)': contains changes, untracked files or ignored files.")
    }

    It 'skips a location the safety rules reject: <Case>' -ForEach @(
        @{ Case = 'locked'; Reason = 'locked' }
        @{ Case = 'current directory'; Reason = 'contains the current directory' }
    ) {
        if ($Case -eq 'locked') {
            Invoke-Git -Arguments @('-C', $fixture.Bare, 'worktree', 'lock', $fixture.Worktree)
            $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        }
        else {
            Push-Location -LiteralPath $fixture.Worktree
            try {
                $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
            }
            finally {
                Pop-Location
            }
        }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Warning | Should -Be @("Skipping '$($fixture.Worktree)': $Reason.")
    }

    It 'detects a nested worktree, also under WhatIf' {
        $nested = Join-Path $fixture.Worktree 'nested'
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'worktree', 'add', '--quiet', '--detach', $nested, 'origin/main') 2>$null | Out-Null
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -WhatIf }
        $run.Warning | Should -Be @("Skipping '$($fixture.Worktree)': contains another registered worktree.")
    }

    It 'keeps detached worktrees' {
        Invoke-Git -Arguments @('-C', $fixture.Worktree, 'checkout', '--quiet', '--detach') 2>$null
        $null = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'stops without deleting when origin cannot be read' {
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'remote', 'set-url', 'origin', (Join-Path $fixture.Root 'missing'))
        { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply 2>$null } |
            Should -Throw "Cannot inspect '$($fixture.Repository)': Git command failed*"
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'keeps worktrees when origin returns no branches' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'update-ref', '-d', 'refs/heads/main')
        $run = Invoke-Captured { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Warning | Should -BeLike '*no branches*refusing cleanup*'
    }
}

Describe 'Invoke-WorktreeCleanup' -Tag Integration {
    BeforeEach {
        $script:fixture = New-CleanupFixture
        $script:second = New-CleanupFixture -Root $fixture.Root -Name 'second'
    }

    It 'inspects every repository in the owner folder, matched ignoring case' {
        $null = Invoke-Captured { Invoke-WorktreeCleanup -GitHubOwner 'O' -TargetDirectory $fixture.Root -Apply }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-Path -LiteralPath $second.Worktree | Should -BeFalse
    }

    It 'inspects only the repository selected by URL' {
        $null = Invoke-Captured {
            Invoke-WorktreeCleanup -Url 'https://github.com/o/second/' -TargetDirectory $fixture.Root -Apply
        }
        Test-Path -LiteralPath $second.Worktree | Should -BeFalse
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'with BranchOnly, inspects only the branch selected by URL' {
        $null = Invoke-Captured {
            Invoke-WorktreeCleanup -Url 'https://github.com/o/second/tree/main' -BranchOnly -TargetDirectory $fixture.Root -Apply
        }
        Test-Path -LiteralPath $second.Worktree | Should -BeTrue
    }

    It 'rejects a selected repository without a bare .git folder' {
        { Invoke-WorktreeCleanup -Url 'https://github.com/o/missing' -TargetDirectory $fixture.Root } |
            Should -Throw "*No repository folder*'o/missing'*"
    }

    It 'warns when the owner folder is missing' {
        $run = Invoke-Captured { Invoke-WorktreeCleanup -GitHubOwner 'nobody' -TargetDirectory $fixture.Root -Apply }
        $run.Warning | Should -Be @("No folder for owner 'nobody' found in '$($fixture.Root)'.")
    }

    It 'honors WhatIf after finding the repositories' {
        $run = Invoke-Captured { Invoke-WorktreeCleanup -GitHubOwner 'o' -TargetDirectory $fixture.Root -Apply -WhatIf }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        $run.Warning | Should -BeNullOrEmpty
    }
}

Describe 'Remove-StaleGitWorktree.ps1' -Tag Integration {
    It 'passes a repository URL and TargetDirectory through to the cleanup' {
        $fixture = New-CleanupFixture
        $other = New-CleanupFixture -Root $fixture.Root -Name 'other'
        $null = Invoke-Captured {
            & "$PSScriptRoot\Remove-StaleGitWorktree.ps1" -Url 'github.com/o/managed' -TargetDirectory $fixture.Root -Apply
        }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Test-Path -LiteralPath $other.Worktree | Should -BeTrue
    }
}
