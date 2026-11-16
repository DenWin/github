#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\Sync-GitRepositories.ps1"
}

Describe 'Assert-Prerequisite' {
    It 'throws when git is missing' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'git' }
        { Assert-Prerequisite } | Should -Throw '*Git is not installed*'
    }

    It 'throws when gh is missing' {
        Mock Get-Command { 'git' } -ParameterFilter { $Name -eq 'git' }
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        { Assert-Prerequisite } | Should -Throw '*GitHub CLI is not installed*'
    }

    It 'throws when gh is not authenticated' {
        Mock Get-Command { 'x' }
        Mock Invoke-Gh { $global:LASTEXITCODE = 1 }
        { Assert-Prerequisite } | Should -Throw '*not authenticated*'
    }

    It 'passes when authenticated' {
        Mock Get-Command { 'x' }
        Mock Invoke-Gh { $global:LASTEXITCODE = 0 }
        { Assert-Prerequisite } | Should -Not -Throw
    }
}

Describe 'Get-RemoteRepository' {
    It 'returns repositories sorted by name' {
        Mock Invoke-Gh {
            $global:LASTEXITCODE = 0
            '[{"name":"b","nameWithOwner":"o/b"},{"name":"a","nameWithOwner":"o/a"}]'
        }
        (Get-RemoteRepository -Owner o).name | Should -Be @('a', 'b')
    }

    It 'throws when gh fails' {
        Mock Invoke-Gh { $global:LASTEXITCODE = 1 }
        { Get-RemoteRepository -Owner o } | Should -Throw "*Could not retrieve repositories for 'o'*"
    }
}

Describe 'Test-IgnoredBranch' {
    It 'returns <Expected> for <Branch>' -ForEach @(
        @{ Branch = 'HEAD'; Expected = $true }
        @{ Branch = 'dependabot/npm/foo'; Expected = $true }
        @{ Branch = 'main'; Expected = $false }
        @{ Branch = 'feature/login'; Expected = $false }
    ) {
        Test-IgnoredBranch -Branch $Branch | Should -Be $Expected
    }
}

Describe 'Test-LocalGitBranch' {
    It 'returns true when the ref exists' {
        Mock Invoke-Git { $global:LASTEXITCODE = 0 }
        Test-LocalGitBranch -BareRepository 'C:\r\.git' -Branch main | Should -BeTrue
    }

    It 'returns false when the ref is missing' {
        Mock Invoke-Git { $global:LASTEXITCODE = 1 }
        Test-LocalGitBranch -BareRepository 'C:\r\.git' -Branch main | Should -BeFalse
    }
}

Describe 'Test-ExistingWorktree' {
    BeforeAll {
        $script:worktreeRoot = Join-Path $TestDrive 'GIT r'
        $registeredWorktree = Join-Path $worktreeRoot 'feature'
        $registeredWorktree = Join-Path $registeredWorktree 'login'
        $script:registeredWorktree = $registeredWorktree
        $script:porcelain = @(
            "worktree $(Join-Path $worktreeRoot '.git')"
            'bare'
            ''
            "worktree $($registeredWorktree.Replace('\', '/'))"
            'HEAD abc'
            'branch refs/heads/feature/login'
        )
    }

    It 'finds a registered worktree regardless of separators' {
        Mock Invoke-Git { $porcelain }
        Test-ExistingWorktree -BareRepository (Join-Path $worktreeRoot '.git') -WorktreePath $registeredWorktree |
            Should -BeTrue
    }

    It 'returns false for an unregistered path' {
        Mock Invoke-Git { $porcelain }
        Test-ExistingWorktree -BareRepository (Join-Path $worktreeRoot '.git') -WorktreePath (Join-Path $worktreeRoot 'other') |
            Should -BeFalse
    }
}

Describe 'Get-RemoteBranch' {
    It 'returns sorted unique non-empty branches' {
        Mock Invoke-Git { $global:LASTEXITCODE = 0; 'main', '', 'dev', 'main' }
        Get-RemoteBranch -BareRepository 'x' | Should -Be @('dev', 'main')
    }

    It 'returns null on failure' {
        Mock Invoke-Git { $global:LASTEXITCODE = 1 }
        Get-RemoteBranch -BareRepository 'x' | Should -BeNullOrEmpty
    }
}

Describe 'New-BranchWorktree' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock New-Item { }
        Mock Test-Path { $false }
        Mock Test-ExistingWorktree { $false }
        Mock Test-LocalGitBranch { $false }
        Mock Invoke-Git { $global:LASTEXITCODE = 0 }
        $script:args1 = @{
            BareRepository = (Join-Path $TestDrive '.git'); RepositoryRoot = $TestDrive
            RepositoryName = 'o/r'; Branch = 'feature/login'
        }
    }

    It 'skips registered worktrees' {
        Mock Test-ExistingWorktree { $true }
        New-BranchWorktree @args1
        Should -Invoke Invoke-Git -Times 0 -Exactly
    }

    It 'warns when the path exists but is not a worktree' {
        Mock Test-Path { $true }
        New-BranchWorktree @args1
        Should -Invoke Write-Warning -Times 1 -Exactly
        Should -Invoke Invoke-Git -Times 0 -Exactly
    }

    It 'creates a tracking worktree for a new local branch' {
        New-BranchWorktree @args1
        Should -Invoke New-Item -Times 1 -Exactly
        Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '--track' -and $Arguments -contains 'origin/feature/login'
        }
    }

    It 'reuses an existing local branch' {
        Mock Test-LocalGitBranch { $true }
        New-BranchWorktree @args1
        Should -Invoke Invoke-Git -Times 1 -Exactly -ParameterFilter {
            $Arguments -notcontains '--track' -and $Arguments[-1] -eq 'feature/login'
        }
    }

    It 'warns when git fails' {
        Mock Invoke-Git { $global:LASTEXITCODE = 1 }
        New-BranchWorktree @args1
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'changes nothing with -DryRun' {
        New-BranchWorktree @args1 -DryRun
        Should -Invoke Invoke-Git -Times 0 -Exactly
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*`[DRY RUN`]*' }
    }
}

Describe 'Sync-Repository' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock New-Item { }
        Mock Invoke-Gh { $global:LASTEXITCODE = 0 }
        Mock Invoke-Git { $global:LASTEXITCODE = 0 }
        Mock Get-RemoteBranch { @('main', 'HEAD', 'dependabot/x', 'dev') }
        Mock New-BranchWorktree { }
        $script:repo = [pscustomobject]@{ name = 'r'; nameWithOwner = 'o/r' }
    }

    Context 'repository not yet cloned' {
        BeforeEach { Mock Test-Path { $false } }

        It 'clones, fetches and creates worktrees, ignoring HEAD and dependabot' {
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive
            Should -Invoke Invoke-Gh -Times 1 -Exactly
            Should -Invoke Invoke-Git -Times 3 -Exactly
            Should -Invoke New-BranchWorktree -Times 2 -Exactly
        }

        It 'skips when clone fails' {
            Mock Invoke-Gh { $global:LASTEXITCODE = 1 }
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive
            Should -Invoke Write-Warning -Times 1 -Exactly
            Should -Invoke New-BranchWorktree -Times 0 -Exactly
        }

        It 'only reports with -DryRun' {
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive -DryRun
            Should -Invoke Invoke-Gh -Times 0 -Exactly
            Should -Invoke Invoke-Git -Times 0 -Exactly
            Should -Invoke New-Item -Times 0 -Exactly
            Should -Invoke New-BranchWorktree -Times 0 -Exactly
        }
    }

    Context 'repository already cloned' {
        BeforeEach { Mock Test-Path { $true } }

        It 'skips an invalid bare repository' {
            Mock Invoke-Git { $global:LASTEXITCODE = 0; 'false' }
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive
            Should -Invoke Write-Warning -Times 1 -Exactly
            Should -Invoke New-BranchWorktree -Times 0 -Exactly
        }

        It 'updates without writing anything with -DryRun' {
            Mock Invoke-Git { $global:LASTEXITCODE = 0; 'true' }
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive -DryRun
            Should -Invoke Invoke-Git -Times 1 -Exactly
            Should -Invoke New-BranchWorktree -Times 2 -Exactly -ParameterFilter { $DryRun }
        }

        It 'reports empty repositories' {
            Mock Invoke-Git { $global:LASTEXITCODE = 0; 'true' }
            Mock Get-RemoteBranch { @() }
            Sync-Repository -Repository $repo -TargetDirectory $TestDrive
            Should -Invoke New-BranchWorktree -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-Main' {
    BeforeEach {
        Mock Assert-Prerequisite { }
        Mock Get-RemoteRepository {
            [pscustomobject]@{ name = 'a'; nameWithOwner = 'o/a' }
            [pscustomobject]@{ name = 'b'; nameWithOwner = 'o/b' }
        }
        Mock Sync-Repository { }
        Mock New-Item { }
        Mock Write-Host { }
    }

    It 'creates the target directory and syncs every repository' {
        Invoke-Main -GitHubOwner o -TargetDirectory $TestDrive
        Should -Invoke New-Item -Times 1 -Exactly
        Should -Invoke Sync-Repository -Times 2 -Exactly -ParameterFilter { -not $DryRun }
    }

    It 'does not create the target directory with -DryRun' {
        Invoke-Main -GitHubOwner o -TargetDirectory $TestDrive -DryRun
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Sync-Repository -Times 2 -Exactly -ParameterFilter { $DryRun }
    }

    It 'stops when prerequisites fail' {
        Mock Assert-Prerequisite { throw 'nope' }
        { Invoke-Main -GitHubOwner o -TargetDirectory $TestDrive } | Should -Throw 'nope'
        Should -Invoke Sync-Repository -Times 0 -Exactly
    }
}
