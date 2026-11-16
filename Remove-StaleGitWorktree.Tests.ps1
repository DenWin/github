#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\Remove-StaleGitWorktree.ps1"

    function New-CleanupFixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $remote = Join-Path $root 'remote'
        $repository = Join-Path $root 'managed'
        $bare = Join-Path $repository '.git'
        $worktree = Join-Path $repository 'feature with spaces'
        Invoke-Git -Arguments @('init', '--initial-branch=main', $remote) | Out-Null
        Invoke-Git -Arguments @(
            '-C', $remote, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'Initial'
        ) | Out-Null
        Invoke-Git -Arguments @('-C', $remote, 'branch', 'deleted')
        Invoke-Git -Arguments @('init', '--bare', '--initial-branch=main', $bare) | Out-Null
        Invoke-Git -Arguments @('-C', $bare, 'remote', 'add', 'origin', $remote)
        Invoke-Git -Arguments @('-C', $bare, 'fetch', 'origin') 2>$null
        Invoke-Git -Arguments @(
            '-C', $bare, 'worktree', 'add', '--track', '-b', 'deleted', $worktree, 'origin/deleted'
        ) 2>$null | Out-Null
        Invoke-Git -Arguments @('-C', $remote, 'branch', '-D', 'deleted') | Out-Null
        [pscustomobject]@{
            Root = $root
            Remote = $remote
            Repository = $repository
            Bare = $bare
            Worktree = $worktree
        }
    }
}

Describe 'Stale worktree cleanup' {
    BeforeEach {
        $script:fixture = New-CleanupFixture
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'previews without removing the folder or stale tracking ref' {
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/remotes/origin/deleted') |
            Should -Not -BeNullOrEmpty
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -like '*Would remove*' }
    }

    It 'removes the registered worktree but retains its local branch and commits' {
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        @(Get-RegisteredWorktree -BareRepository $fixture.Bare).Path | Should -Not -Contain $fixture.Worktree
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/heads/deleted') |
            Should -Not -BeNullOrEmpty
    }

    It 'deletes an opted-in branch only after it is merged into the remote default branch' {
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Invoke-Git -AllowFailure -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', '--quiet', 'refs/heads/deleted')
        $LASTEXITCODE | Should -Be 1
    }

    It 'preserves unmerged commits even if the stale upstream contains them' {
        Invoke-Git -Arguments @(
            '-C', $fixture.Worktree, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'Unmerged'
        ) | Out-Null
        Invoke-Git -Arguments @(
            '-C', $fixture.Bare, 'update-ref', 'refs/remotes/origin/deleted', 'refs/heads/deleted'
        )
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/heads/deleted') |
            Should -Not -BeNullOrEmpty
    }

    It 'preserves the branch when the remote default branch cannot be determined' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'symbolic-ref', 'HEAD', 'refs/heads/missing')
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -DeleteMergedBranch
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/heads/deleted') |
            Should -Not -BeNullOrEmpty
        Should -Invoke Write-Warning -ParameterFilter { $Message -like '*default branch*preserved*' }
    }

    It 'previews opted-in branch deletion without removing anything' {
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -DeleteMergedBranch
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/heads/deleted') |
            Should -Not -BeNullOrEmpty
        Should -Invoke Write-Host -ParameterFilter { $Object -like '*would attempt safe branch deletion*' }
    }

    It 'honors WhatIf for opted-in branch deletion' {
        Invoke-WorktreeCleanup -TargetDirectory $fixture.Repository -Apply -DeleteMergedBranch -WhatIf
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'show-ref', '--verify', 'refs/heads/deleted') |
            Should -Not -BeNullOrEmpty
    }

    It 'honors WhatIf when applying' {
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply -WhatIf
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'keeps worktrees whose remote branch still exists' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'branch', 'deleted')
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Should -Invoke Write-Host -Times 0
    }

    It 'keeps local-only branches' {
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'branch', '--unset-upstream', 'deleted')
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
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
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*contains changes*' }
    }

    It 'skips locked worktrees' {
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'worktree', 'lock', $fixture.Worktree)
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*locked*' }
    }

    It 'keeps detached worktrees' {
        Invoke-Git -Arguments @('-C', $fixture.Worktree, 'checkout', '--detach') 2>$null
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'skips worktrees outside the repository root' {
        $outside = Join-Path $fixture.Root 'outside'
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'worktree', 'move', $fixture.Worktree, $outside)
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $outside | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*outside*' }
    }

    It 'skips a worktree containing another registered worktree' {
        $nested = Join-Path $fixture.Worktree 'nested'
        Invoke-Git -Arguments @(
            '-C', $fixture.Bare, 'worktree', 'add', '--detach', $nested, 'origin/main'
        ) 2>$null | Out-Null
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $nested | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*another registered worktree*' }
    }

    It 'skips the current directory' {
        Push-Location -LiteralPath $fixture.Worktree
        try {
            Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        }
        finally {
            Pop-Location
        }
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*current directory*' }
    }

    It 'stops without deleting when origin cannot be read' {
        Invoke-Git -Arguments @('-C', $fixture.Bare, 'remote', 'set-url', 'origin', (Join-Path $fixture.Root 'missing'))
        { Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply 2>$null } |
            Should -Throw '*Git command failed*'
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }

    It 'keeps worktrees when origin returns no branches' {
        Invoke-Git -Arguments @('-C', $fixture.Remote, 'update-ref', '-d', 'refs/heads/main')
        Remove-StaleRepositoryWorktree -RepositoryRoot $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
        Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*no branches*refusing cleanup*' }
    }

    It 'discovers repositories directly below a chosen target' {
        Invoke-WorktreeCleanup -TargetDirectory $fixture.Root -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
    }

    It 'accepts a single repository root' {
        & "$PSScriptRoot\Remove-StaleGitWorktree.ps1" -TargetDirectory $fixture.Repository -Apply
        Test-Path -LiteralPath $fixture.Worktree | Should -BeFalse
    }

    It 'honors WhatIf through the main entry point' {
        Invoke-WorktreeCleanup -TargetDirectory $fixture.Repository -Apply -WhatIf
        Test-Path -LiteralPath $fixture.Worktree | Should -BeTrue
    }
}
