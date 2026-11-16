#Requires -Version 7.0

[CmdletBinding()]
param (
    [string] $GitHubOwner = 'DenWin',

    [string] $TargetDirectory = 'C:\GIT\DenWin',

    # Preview all actions without cloning, fetching or creating anything.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


# ============================================================================
# Helper functions
# ============================================================================

function Invoke-Git {
    param (
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    & git @Arguments

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}


function Invoke-Gh {
    param (
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    & gh @Arguments
}


function Write-DryRun {
    param (
        [Parameter(Mandatory)]
        [string] $Message
    )

    Write-Host "  [DRY RUN] $Message" -ForegroundColor Yellow
}


function Test-LocalGitBranch {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $Branch
    )

    Invoke-Git -AllowFailure -Arguments @(
        '-C', $BareRepository,
        'show-ref', '--verify', '--quiet', "refs/heads/$Branch"
    ) | Out-Null

    return $LASTEXITCODE -eq 0
}


function Test-ExistingWorktree {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $WorktreePath
    )

    $normalizedTargetPath = [System.IO.Path]::GetFullPath(
        $WorktreePath
    ).TrimEnd('\', '/')

    $worktrees = Invoke-Git -Arguments @(
        '-C', $BareRepository,
        'worktree', 'list', '--porcelain'
    )

    foreach ($line in $worktrees) {
        if ($line -notmatch '^worktree (.+)$') {
            continue
        }

        $registeredPath = [System.IO.Path]::GetFullPath(
            $Matches[1]
        ).TrimEnd('\', '/')

        if ($registeredPath -eq $normalizedTargetPath) {
            return $true
        }
    }

    return $false
}


function Assert-Prerequisite {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or is not available in PATH.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI is not installed or is not available in PATH.'
    }

    Invoke-Gh -Arguments @('auth', 'status') 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
    }
}


function Get-RemoteRepository {
    param (
        [Parameter(Mandatory)]
        [string] $Owner
    )

    $json = Invoke-Gh -Arguments @(
        'repo', 'list', $Owner,
        '--source', '--limit', '1000',
        '--json', 'name,nameWithOwner'
    )

    if ($LASTEXITCODE -ne 0) {
        throw "Could not retrieve repositories for '$Owner'."
    }

    return @($json | ConvertFrom-Json | Sort-Object name)
}


function Test-IgnoredBranch {
    param (
        [Parameter(Mandatory)]
        [string] $Branch
    )

    return $Branch -eq 'HEAD' -or $Branch -like 'dependabot/*'
}


function Get-RemoteBranch {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository
    )

    $branches = Invoke-Git -AllowFailure -Arguments @(
        '-C', $BareRepository,
        'for-each-ref', '--format=%(refname:strip=3)', 'refs/remotes/origin/'
    )

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return @(
        $branches |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}


function Set-BranchUpstream {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $Branch,

        [switch] $DryRun
    )

    foreach ($setting in @('remote', 'merge')) {
        Invoke-Git -AllowFailure -Arguments @(
            '-C', $BareRepository, 'config', '--get', "branch.$Branch.$setting"
        ) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($LASTEXITCODE -ne 1) {
            throw "Could not read upstream configuration for '$Branch'."
        }
    }

    if ($DryRun) {
        Write-DryRun "UPSTREAM $Branch -> origin/$Branch"
        return
    }

    Invoke-Git -Arguments @(
        '-C', $BareRepository, 'branch', "--set-upstream-to=origin/$Branch", '--', $Branch
    ) | Out-Null
}


function New-BranchWorktree {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $RepositoryName,

        [Parameter(Mandatory)]
        [string] $Branch,

        [switch] $DryRun
    )

    # Branch names such as feature/login intentionally produce:
    #   <repository>\feature\login
    $worktreePath = Join-Path $RepositoryRoot $Branch

    $localBranchExists = Test-LocalGitBranch -BareRepository $BareRepository -Branch $Branch
    if ($localBranchExists) {
        Set-BranchUpstream -BareRepository $BareRepository -Branch $Branch -DryRun:$DryRun
    }

    if (Test-ExistingWorktree -BareRepository $BareRepository -WorktreePath $worktreePath) {
        Write-Host "  SKIP     $Branch - worktree already registered" -ForegroundColor DarkGray
        return
    }

    if (Test-Path -LiteralPath $worktreePath) {
        Write-Warning (
            "Cannot create worktree '$Branch': " +
            "'$worktreePath' already exists but is not a registered worktree."
        )
        return
    }

    if ($localBranchExists) {
        $message = "WORKTREE $Branch"
        $gitArguments = @('-C', $BareRepository, 'worktree', 'add', $worktreePath, $Branch)
    }
    else {
        $message = "WORKTREE $Branch -> origin/$Branch"
        $gitArguments = @(
            '-C', $BareRepository, 'worktree', 'add',
            '--track', '-b', $Branch, $worktreePath, "origin/$Branch"
        )
    }

    if ($DryRun) {
        Write-DryRun $message
        return
    }

    Write-Host "  $message" -ForegroundColor Green

    New-Item -ItemType Directory -Path (Split-Path -Parent $worktreePath) -Force | Out-Null

    Invoke-Git -AllowFailure -Arguments $gitArguments

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to create worktree for ${RepositoryName}:$Branch"
    }
}


function Sync-Repository {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Repository,

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [switch] $DryRun
    )

    $repositoryRoot = Join-Path $TargetDirectory $Repository.name
    $bareRepository = Join-Path $repositoryRoot '.git'

    Write-Host ''
    Write-Host "REPOSITORY $($Repository.nameWithOwner)" -ForegroundColor Magenta

    if (Test-Path -LiteralPath $bareRepository) {
        $isBare = Invoke-Git -AllowFailure -Arguments @(
            '-C', $bareRepository, 'rev-parse', '--is-bare-repository'
        ) 2>$null

        if ($LASTEXITCODE -ne 0 -or $isBare -ne 'true') {
            Write-Warning (
                "'$bareRepository' exists but is not a valid bare repository. " +
                'Repository skipped.'
            )
            return
        }

        if ($DryRun) {
            Write-DryRun 'UPDATE   bare repository (config, worktree prune, fetch)'
        }
        else {
            Write-Host '  UPDATE   bare repository' -ForegroundColor Yellow
        }
    }
    else {
        if ($DryRun) {
            Write-DryRun 'CLONE    bare repository (branches unknown until cloned)'
            return
        }

        Write-Host '  CLONE    bare repository' -ForegroundColor Cyan

        New-Item -ItemType Directory -Path $repositoryRoot -Force | Out-Null

        Invoke-Gh -Arguments @(
            'repo', 'clone', $Repository.nameWithOwner, $bareRepository, '--', '--bare'
        )

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to clone $($Repository.nameWithOwner)."
            return
        }
    }

    if (-not $DryRun) {
        # Also applied to repositories created by earlier versions of the script.
        Invoke-Git -Arguments @(
            '-C', $bareRepository,
            'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*'
        )

        # Remove metadata for worktrees whose folders were removed manually.
        Invoke-Git -Arguments @('-C', $bareRepository, 'worktree', 'prune')

        Invoke-Git -Arguments @('-C', $bareRepository, 'fetch', 'origin', '--prune')
    }

    $branches = @(Get-RemoteBranch -BareRepository $bareRepository)

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not read branches for $($Repository.nameWithOwner)."
        return
    }

    if ($branches.Count -eq 0) {
        Write-Host '  EMPTY    repository has no branches' -ForegroundColor DarkGray
        return
    }

    foreach ($branch in $branches) {
        if (Test-IgnoredBranch -Branch $branch) {
            Write-Host "  IGNORE   $branch" -ForegroundColor DarkGray
            continue
        }

        New-BranchWorktree `
            -BareRepository $bareRepository `
            -RepositoryRoot $repositoryRoot `
            -RepositoryName $Repository.nameWithOwner `
            -Branch $branch `
            -DryRun:$DryRun
    }
}


function Invoke-Main {
    param (
        [Parameter(Mandatory)]
        [string] $GitHubOwner,

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [switch] $DryRun
    )

    Assert-Prerequisite

    if ($DryRun) {
        Write-Host 'Dry run: no changes will be made.' -ForegroundColor Yellow
    }
    else {
        New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    }

    Write-Host ''
    Write-Host "Reading non-fork repositories owned by $GitHubOwner..." -ForegroundColor Cyan

    foreach ($repository in Get-RemoteRepository -Owner $GitHubOwner) {
        Sync-Repository -Repository $repository -TargetDirectory $TargetDirectory -DryRun:$DryRun
    }

    Write-Host ''
    if ($DryRun) {
        Write-Host 'Dry run completed. Nothing was changed.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Repository synchronization completed.' -ForegroundColor Green
    }
    Write-Host "Root directory: $TargetDirectory" -ForegroundColor Cyan
}


# Skip execution when dot-sourced (e.g. by Pester).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -GitHubOwner $GitHubOwner -TargetDirectory $TargetDirectory -DryRun:$DryRun
}
