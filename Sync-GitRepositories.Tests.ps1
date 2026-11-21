#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests repository synchronization, branch worktrees and upstream tracking.
.DESCRIPTION
    Pure steps such as target resolution, repository selection, origin identity
    and branch planning are tested with plain input and output. Functions that
    call Git are tested one layer up against real local repositories tagged
    Integration. Nothing is mocked: managed repositories use a GitHub origin URL
    redirected to a local source with url.<path>.insteadOf, so no network is used.
    Functions calling gh (repository discovery, cloning, prerequisites) are thin
    compositions of tested steps and are not exercised here.
.EXAMPLE
    Invoke-Pester -Path .\Sync-GitRepositories.Tests.ps1 -ExcludeTagFilter Integration
    Runs only the fast pure-step tests.
.INPUTS
    None. Run this file through Pester rather than invoking it directly.
.OUTPUTS
    None. Pester reports results; use Invoke-Pester -PassThru for result objects.
.NOTES
    Requires PowerShell 7 and Pester; integration tests require Git. Fixtures
    live in Pester's TestDrive; no GitHub repository is contacted or cloned.
#>
BeforeAll {
    . "$PSScriptRoot\Sync-GitRepositories.ps1"
    . "$PSScriptRoot\GitTooling.TestHelpers.ps1"

    # A managed bare repository whose origin is a GitHub URL redirected to a local source.
    function New-ManagedRepository {
        param ([string] $TargetDirectory, [string] $NameWithOwner, [string] $Source, [switch] $Reftable)

        $layout = Get-RepositoryLayout -TargetDirectory $TargetDirectory -NameWithOwner $NameWithOwner
        $format = if ($Reftable) { 'reftable' } else { 'files' }
        Invoke-Git -Arguments @('clone', '--quiet', '--bare', "--ref-format=$format", $Source, $layout.BareRepository) 2>$null
        $originUrl = "https://github.com/$NameWithOwner.git"
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'remote', 'set-url', 'origin', $originUrl)
        Invoke-Git -Arguments @(
            '-C', $layout.BareRepository, 'config', "url.$($Source.Replace('\', '/')).insteadOf", $originUrl
        )
        $layout
    }
}

# ============================================================================
# Pure steps
# ============================================================================

Describe 'Get-OwnerRepositoryEndpoint' {
    It 'lists owned repositories for a user' {
        Get-OwnerRepositoryEndpoint -Owner o -OwnerType User |
            Should -BeExactly 'users/o/repos?type=owner&per_page=100'
    }

    It 'lists source repositories for an organization' {
        Get-OwnerRepositoryEndpoint -Owner o -OwnerType Organization |
            Should -BeExactly 'orgs/o/repos?type=sources&per_page=100'
    }

    It 'rejects other owner types' {
        { Get-OwnerRepositoryEndpoint -Owner o -OwnerType Bot } | Should -Throw '*unsupported owner type*'
    }
}

Describe 'ConvertFrom-RepositoryRecord' {
    It 'keeps name, full name and fork flag' {
        $repository = ConvertFrom-RepositoryRecord -Record @{ name = 'r'; full_name = 'O/r'; fork = $true }
        "$($repository.name)|$($repository.nameWithOwner)|$($repository.fork)" | Should -BeExactly 'r|O/r|True'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a record without fork'; Record = @{ name = 'r'; full_name = 'o/r' } }
        @{ Case = 'a record without full_name'; Record = @{ name = 'r'; fork = $false } }
        @{ Case = 'a non-object record'; Record = 'r' }
        @{ Case = 'a null record'; Record = $null }
    ) {
        { ConvertFrom-RepositoryRecord -Record $Record } | Should -Throw '*unexpected repository record*'
    }
}

Describe 'Select-SourceRepository' {
    It 'excludes forks and sorts by name' {
        $selected = Select-SourceRepository -Repository @(
            [pscustomobject]@{ name = 'b'; nameWithOwner = 'o/b'; fork = $false }
            [pscustomobject]@{ name = 'f'; nameWithOwner = 'o/f'; fork = $true }
            [pscustomobject]@{ name = 'a'; nameWithOwner = 'o/a'; fork = $false }
        )
        $selected.nameWithOwner | Should -Be @('o/a', 'o/b')
    }

    It 'returns nothing for no repositories' {
        @(Select-SourceRepository -Repository @()).Count | Should -Be 0
    }
}

Describe 'Get-RepositoryLayout' {
    It 'places the repository below an owner folder' {
        $layout = Get-RepositoryLayout -TargetDirectory 'root' -NameWithOwner 'Owner/Repo'
        $layout.RepositoryRoot | Should -BeExactly (Join-Path (Join-Path 'root' 'Owner') 'Repo')
        $layout.BareRepository | Should -BeExactly (Join-Path $layout.RepositoryRoot '.git')
    }
}

Describe 'Test-OriginIdentity' {
    It 'accepts <OriginUrl>' -ForEach @(
        @{ OriginUrl = 'https://github.com/o/r.git' }
        @{ OriginUrl = 'https://github.com/o/r/' }
        @{ OriginUrl = 'git@github.com:o/r.git' }
        @{ OriginUrl = 'ssh://git@github.com/O/R' }
    ) {
        Test-OriginIdentity -OriginUrl $OriginUrl -NameWithOwner 'o/r' | Should -BeTrue
    }

    It 'rejects <OriginUrl>' -ForEach @(
        @{ OriginUrl = 'https://github.com/other/r.git' }
        @{ OriginUrl = 'https://github.com/o/r-other' }
        @{ OriginUrl = 'https://github.example.com/o/r.git' }
        @{ OriginUrl = 'https://github.com/o' }
        @{ OriginUrl = 'https://github.com/o/r/tree/main' }
        @{ OriginUrl = 'C:/source/r' }
        @{ OriginUrl = '' }
    ) {
        Test-OriginIdentity -OriginUrl $OriginUrl -NameWithOwner 'o/r' | Should -BeFalse
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

Describe 'Get-WorktreeBranchPlan' {
    It 'plans every branch and marks ignored ones' {
        $plan = Get-WorktreeBranchPlan -RemoteBranch @('HEAD', 'dependabot/x', 'main')
        ($plan | ForEach-Object { "$($_.Branch)=$($_.Ignored)" }) |
            Should -Be @('HEAD=True', 'dependabot/x=True', 'main=False')
    }

    It 'plans only the requested branch, even an otherwise ignored one' -ForEach @(
        @{ Branch = 'feature/login' }
        @{ Branch = 'dependabot/x' }
    ) {
        $plan = @(Get-WorktreeBranchPlan -RemoteBranch @('main', 'feature/login', 'dependabot/x') -Branch $Branch)
        ($plan | ForEach-Object { "$($_.Branch)=$($_.Ignored)" }) | Should -Be @("$Branch=False")
    }

    It 'plans nothing when the requested branch is <Case>' -ForEach @(
        @{ Case = 'missing'; Branch = 'feature/other' }
        @{ Case = 'only present with different case'; Branch = 'Main' }
    ) {
        @(Get-WorktreeBranchPlan -RemoteBranch @('main') -Branch $Branch).Count | Should -Be 0
    }
}

Describe 'Test-WorktreeRegistered' {
    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) 'GIT r'
        $script:path = Join-Path (Join-Path $root 'feature') 'login'
        $script:worktrees = @(
            [pscustomobject]@{ Path = Join-Path $root '.git'; Branch = '' }
            [pscustomobject]@{ Path = "$($path.Replace('\', '/'))/"; Branch = 'feature/login' }
        )
    }

    It 'finds a path regardless of separators and trailing separators' {
        Test-WorktreeRegistered -Worktree $worktrees -Path $path -Comparison Ordinal | Should -BeTrue
    }

    It 'requires the exact branch when one is given' {
        Test-WorktreeRegistered -Worktree $worktrees -Path $path -Branch 'feature/login' -Comparison Ordinal |
            Should -BeTrue
        Test-WorktreeRegistered -Worktree $worktrees -Path $path -Branch 'Feature/Login' -Comparison OrdinalIgnoreCase |
            Should -BeFalse
    }

    It 'compares path case using the platform comparison' {
        Test-WorktreeRegistered -Worktree $worktrees -Path $path.ToUpperInvariant() -Comparison OrdinalIgnoreCase |
            Should -BeTrue
        Test-WorktreeRegistered -Worktree $worktrees -Path $path.ToUpperInvariant() -Comparison Ordinal |
            Should -BeFalse
    }

    It 'returns false for <Case>' -ForEach @(
        @{ Case = 'an unregistered path'; Records = $null; Child = 'other' }
        @{ Case = 'no worktrees'; Records = @(); Child = 'feature' }
    ) {
        $records = if ($null -eq $Records) { $worktrees } else { $Records }
        Test-WorktreeRegistered -Worktree $records -Path (Join-Path $root $Child) -Comparison Ordinal |
            Should -BeFalse
    }
}

Describe 'Test-UpstreamConfigured' {
    It 'returns <Expected> for exit codes <Codes>' -ForEach @(
        @{ Codes = @(0, 1); Expected = $true }
        @{ Codes = @(1, 0); Expected = $true }
        @{ Codes = @(0, 128); Expected = $true }
        @{ Codes = @(1, 1); Expected = $false }
    ) {
        Test-UpstreamConfigured -ExitCode $Codes | Should -Be $Expected
    }

    It 'throws when Git cannot read the configuration (exit codes <Codes>)' -ForEach @(
        @{ Codes = @(128) }
        @{ Codes = @(1, 3) }
        @{ Codes = @(-1) }
    ) {
        { Test-UpstreamConfigured -ExitCode $Codes } | Should -Throw '*Could not read upstream configuration*'
    }
}

Describe 'Get-WorktreeAddCommand' {
    It 'checks out an existing local branch' {
        $command = Get-WorktreeAddCommand -BareRepository b -WorktreePath p -Branch 'feature/x' -LocalBranchExists
        $command.Message | Should -BeExactly 'WORKTREE feature/x'
        $command.Arguments | Should -Be @('-C', 'b', 'worktree', 'add', 'p', 'feature/x')
    }

    It 'creates a tracking branch from origin' {
        $command = Get-WorktreeAddCommand -BareRepository b -WorktreePath p -Branch 'feature/x'
        $command.Message | Should -BeExactly 'WORKTREE feature/x -> origin/feature/x'
        $command.Arguments | Should -Be @(
            '-C', 'b', 'worktree', 'add', '--track', '-b', 'feature/x', 'p', 'origin/feature/x'
        )
    }
}

Describe 'Get-SyncFailureMessage' {
    It 'names the count and every failed repository' {
        Get-SyncFailureMessage -FailedRepository @('o/a', 'o/c') |
            Should -BeLike 'Synchronization incomplete for 2 repository/repositories: o/a, o/c.*'
    }
}

# ============================================================================
# Real Git, one layer up
# ============================================================================

Describe 'Get-RemoteBranch' -Tag Integration {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-SourceRepository -Path (Join-Path $root 'source') -Branch @('feature/login', 'Feature') -Reftable
        $script:layout = New-ManagedRepository -TargetDirectory $root -NameWithOwner 'o/r' -Source (Join-Path $root 'source') -Reftable
        Invoke-Git -Arguments @(
            '-C', $layout.BareRepository, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*'
        )
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'fetch', '--quiet', 'origin') 2>$null
    }

    It 'returns nested and case-distinct origin branches, sorted, without origin/HEAD' {
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'remote', 'set-head', 'origin', 'main')
        $branches = Get-RemoteBranch -BareRepository $layout.BareRepository
        $branches | Should -Be @('Feature', 'feature/login', 'main')
    }

    It 'returns an empty list, not a failure, when origin has no fetched branches' {
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'update-ref', '-d', 'refs/remotes/origin/main')
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'update-ref', '-d', 'refs/remotes/origin/feature/login')
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'update-ref', '-d', 'refs/remotes/origin/Feature')
        $branches = Get-RemoteBranch -BareRepository $layout.BareRepository
        $null -eq $branches | Should -BeFalse
        $branches.Count | Should -Be 0
    }

    It 'returns null when Git cannot read the repository' {
        Get-RemoteBranch -BareRepository (Join-Path $TestDrive 'missing') 2>$null | Should -BeNullOrEmpty
    }
}

Describe 'New-BranchWorktree' -Tag Integration {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-SourceRepository -Path (Join-Path $root 'source') -Branch @('feature/login')
        $script:layout = New-ManagedRepository -TargetDirectory $root -NameWithOwner 'o/r' -Source (Join-Path $root 'source')
        Invoke-Git -Arguments @(
            '-C', $layout.BareRepository, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*'
        )
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'fetch', '--quiet', 'origin') 2>$null
        $script:worktreeArguments = @{
            BareRepository = $layout.BareRepository
            RepositoryRoot = $layout.RepositoryRoot
            RepositoryName = 'o/r'
        }

        function Get-Upstream ([string] $Branch) {
            Invoke-Git -Arguments @(
                '-C', $layout.BareRepository, 'for-each-ref', '--format=%(upstream)', "refs/heads/$Branch"
            )
        }
    }

    It 'creates a tracking worktree for a branch that only exists on origin' {
        $run = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch 'feature/login' }
        $run.Result | Should -Be @($true)
        Test-Path -LiteralPath (Join-Path $layout.RepositoryRoot 'feature/login') | Should -BeTrue
        Get-Upstream 'feature/login' | Should -Be 'refs/remotes/origin/feature/login'
    }

    It 'configures origin tracking for a clone-created local branch' {
        $null = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch main }
        Get-Upstream main | Should -Be 'refs/remotes/origin/main'
    }

    It 'preserves an explicitly configured upstream' {
        Invoke-Git -Arguments @('-C', $layout.BareRepository, 'branch', '--set-upstream-to=origin/feature/login', 'main') | Out-Null
        $null = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch main }
        Get-Upstream main | Should -Be 'refs/remotes/origin/feature/login'
    }

    It 'repairs missing tracking for an already registered worktree and skips it' {
        Invoke-Git -Arguments @(
            '-C', $layout.BareRepository, 'worktree', 'add', (Join-Path $layout.RepositoryRoot 'main'), 'main'
        ) 2>$null | Out-Null
        $run = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch main }
        $run.Result | Should -Be @($true)
        $run.Host | Should -Contain '  SKIP     main - worktree already registered'
        Get-Upstream main | Should -Be 'refs/remotes/origin/main'
    }

    It 'refuses an existing folder that is not a registered worktree' {
        $folder = New-Item -ItemType Directory -Path (Join-Path $layout.RepositoryRoot 'main')
        $run = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch main }
        $run.Result | Should -Be @($false)
        $run.Warning | Should -BeLike "*'$($folder.FullName)' already exists but is not a registered worktree*"
    }

    It 'does not configure tracking or create a worktree during a dry run' {
        $run = Invoke-Captured { New-BranchWorktree @worktreeArguments -Branch main -DryRun }
        $run.Result | Should -Be @($true)
        $run.Host | Should -Contain '  [DRY RUN] UPSTREAM main -> origin/main'
        Get-Upstream main | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $layout.RepositoryRoot 'main') | Should -BeFalse
    }
}

Describe 'Test-ExistingWorktree' -Tag Integration {
    It 'recognizes a registered worktree whose path contains characters Git quotes in text output' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-SourceRepository -Path (Join-Path $root 'source')
        $layout = New-ManagedRepository -TargetDirectory $root -NameWithOwner 'o/r' -Source (Join-Path $root 'source')
        $specialPath = Join-Path $layout.RepositoryRoot 'feature # café'
        Invoke-Git -Arguments @(
            '-C', $layout.BareRepository, 'worktree', 'add', '--detach', $specialPath, 'main'
        ) 2>$null | Out-Null
        Test-ExistingWorktree -BareRepository $layout.BareRepository -WorktreePath $specialPath | Should -BeTrue
        Test-ExistingWorktree -BareRepository $layout.BareRepository -WorktreePath "$specialPath-other" | Should -BeFalse
    }
}

Describe 'Sync-Repository' -Tag Integration {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:target = Join-Path $root 'GIT'
        $script:source = Join-Path $root 'source'
        New-SourceRepository -Path $source -Branch @('feature/login', 'dependabot/npm/x')
        $script:repository = [pscustomobject]@{ name = 'r'; nameWithOwner = 'o/r' }
        $script:repositoryRoot = (Get-RepositoryLayout -TargetDirectory $target -NameWithOwner 'o/r').RepositoryRoot
    }

    Context 'already cloned' {
        BeforeEach {
            $script:layout = New-ManagedRepository -TargetDirectory $target -NameWithOwner 'o/r' -Source $source
        }

        It 'fetches and creates worktrees below the owner folder, ignoring HEAD and dependabot' {
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
            $run.Result | Should -Be @($true)
            Test-Path -LiteralPath (Join-Path $target 'o/r/main') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target 'o/r/feature/login') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $target 'o/r/dependabot') | Should -BeFalse
            $run.Host | Should -Contain '  IGNORE   dependabot/npm/x'
        }

        It 'is idempotent on a second run' {
            $null = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
            $run.Result | Should -Be @($true)
            $run.Host | Should -Contain '  SKIP     main - worktree already registered'
        }

        It 'creates only the requested branch worktree' {
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target -Branch 'feature/login' }
            $run.Result | Should -Be @($true)
            Test-Path -LiteralPath (Join-Path $repositoryRoot 'feature/login') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $repositoryRoot 'main') | Should -BeFalse
        }

        It 'creates an explicitly requested ignored branch' {
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target -Branch 'dependabot/npm/x' }
            $run.Result | Should -Be @($true)
            Test-Path -LiteralPath (Join-Path $repositoryRoot 'dependabot/npm/x') | Should -BeTrue
        }

        It 'fails when the requested branch does not exist on origin' {
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target -Branch 'feature/missing' }
            $run.Result | Should -Be @($false)
            $run.Warning | Should -BeLike "*Branch 'feature/missing' does not exist on origin*"
            @(Get-ChildItem -LiteralPath $repositoryRoot -Force).Name | Should -Be @('.git')
        }

        It 'refuses an origin that identifies a different repository, before fetching' {
            Invoke-Git -Arguments @('-C', $layout.BareRepository, 'remote', 'set-url', 'origin', 'https://github.com/someone-else/r.git')
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
            $run.Result | Should -Be @($false)
            $run.Warning | Should -BeLike '*origin does not identify the expected GitHub repository*'
            Invoke-Git -Arguments @('-C', $layout.BareRepository, 'for-each-ref', 'refs/remotes/') | Should -BeNullOrEmpty
        }

        It 'continues with other branches but fails when one worktree path is occupied' {
            New-Item -ItemType Directory -Path (Join-Path $repositoryRoot 'main') | Out-Null
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
            $run.Result | Should -Be @($false)
            Test-Path -LiteralPath (Join-Path $repositoryRoot 'feature/login') | Should -BeTrue
        }

        It 'changes nothing during a dry run' {
            $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target -DryRun }
            $run.Result | Should -Be @($true)
            @(Get-ChildItem -LiteralPath $repositoryRoot -Force).Name | Should -Be @('.git')
            Invoke-Git -Arguments @('-C', $layout.BareRepository, 'for-each-ref', 'refs/remotes/') | Should -BeNullOrEmpty
        }
    }

    It 'skips a .git folder that is not a bare repository' {
        New-Item -ItemType Directory -Path (Join-Path $repositoryRoot '.git') | Out-Null
        $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target }
        $run.Result | Should -Be @($false)
        $run.Warning | Should -BeLike '*is not a valid bare repository*'
    }

    It 'only reports an uncloned repository during a dry run' {
        $run = Invoke-Captured { Sync-Repository -Repository $repository -TargetDirectory $target -DryRun }
        $run.Result | Should -Be @($true)
        $run.Host | Should -Contain '  [DRY RUN] CLONE    bare repository (branches unknown until cloned)'
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe 'Invoke-RepositorySync' -Tag Integration {
    It 'continues independent repositories but fails the overall run when one is incomplete' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $target = Join-Path $root 'GIT'
        New-SourceRepository -Path (Join-Path $root 'a')
        New-SourceRepository -Path (Join-Path $root 'b')
        $null = New-ManagedRepository -TargetDirectory $target -NameWithOwner 'o/a' -Source (Join-Path $root 'a')
        $broken = New-ManagedRepository -TargetDirectory $target -NameWithOwner 'o/b' -Source (Join-Path $root 'b')
        Invoke-Git -Arguments @('-C', $broken.BareRepository, 'remote', 'set-url', 'origin', 'https://github.com/x/y.git')
        $repositories = @(
            [pscustomobject]@{ name = 'b'; nameWithOwner = 'o/b' }
            [pscustomobject]@{ name = 'a'; nameWithOwner = 'o/a' }
        )

        { Invoke-RepositorySync -Repository $repositories -TargetDirectory $target 3>$null 6>$null } |
            Should -Throw 'Synchronization incomplete for 1 repository/repositories: o/b.*'
        Test-Path -LiteralPath (Join-Path $target 'o/a/main') | Should -BeTrue
    }

    It 'succeeds when every repository synchronizes' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $target = Join-Path $root 'GIT'
        New-SourceRepository -Path (Join-Path $root 'a')
        $null = New-ManagedRepository -TargetDirectory $target -NameWithOwner 'o/a' -Source (Join-Path $root 'a')
        { Invoke-RepositorySync -Repository @([pscustomobject]@{ name = 'a'; nameWithOwner = 'o/a' }) -TargetDirectory $target 6>$null } |
            Should -Not -Throw
    }
}
