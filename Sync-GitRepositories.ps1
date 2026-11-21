#Requires -Version 7.0

<#
.SYNOPSIS
    Synchronizes GitHub repositories into bare repositories and branch worktrees.
.DESCRIPTION
    Synchronizes either every non-fork repository of a GitHub user or
    organization, or a single repository selected by URL. Repositories are
    placed under <TargetDirectory>\<owner>\<repository>, using the owner and
    repository names as GitHub returns them.
    Clones missing repositories, or prunes worktree metadata and fetches existing
    bare repositories with --prune. Creates worktrees for origin branches except
    HEAD and dependabot/*; existing worktrees are not pulled, reset or rebased.
    Adds missing origin tracking for existing local branches without replacing
    explicit upstream configuration. Requires Git and authenticated gh on PATH.
.PARAMETER GitHubOwner
    GitHub user or organization whose non-fork repositories are synchronized,
    given as a name or a github.com owner URL such as https://github.com/Owner.
    Defaults to Owner. Cannot be combined with Url.
.PARAMETER Url
    github.com location selecting what to synchronize. An owner URL such as
    https://github.com/Owner behaves like GitHubOwner. A repository URL such as
    https://github.com/Owner/Repo, or a branch URL such as
    https://github.com/Owner/Repo/tree/feature/login, synchronizes only that
    repository with all its branches. HTTPS, SSH and scheme-less forms, a
    trailing slash and a .git suffix are accepted. An explicitly selected fork
    is synchronized.
.PARAMETER BranchOnly
    With a branch URL, creates or checks only that branch's worktree. The bare
    repository is still cloned or fetched completely. The branch is created even
    if it matches an ignored pattern such as dependabot/*. Requires a branch URL.
.PARAMETER TargetDirectory
    Root directory containing one folder per owner. Defaults to C:\GIT, so
    Owner/Repo is placed in C:\GIT\Owner\github. Each repository folder
    contains a bare .git repository and worktrees named after branch paths,
    such as C:\GIT\Owner\github\feature\login for branch feature/login.
.PARAMETER DryRun
    Reports actions without cloning, fetching, changing configuration or creating
    directories. Still queries GitHub and reads local Git metadata. Uncloned
    repositories have unknown branches; existing ones use the last fetched refs.
.EXAMPLE
    .\Sync-GitRepositories.ps1 -DryRun
    Previews synchronization of Owner's repositories into C:\GIT\Owner.
.EXAMPLE
    .\Sync-GitRepositories.ps1 -GitHubOwner Owner -TargetDirectory C:\GIT
    Synchronizes every non-fork Owner repository into C:\GIT\Owner.
.EXAMPLE
    .\Sync-GitRepositories.ps1 -Url https://github.com/Owner/Repo
    Synchronizes only Owner/Repo, with worktrees for all its branches.
.EXAMPLE
    .\Sync-GitRepositories.ps1 -Url https://github.com/Owner/Repo/tree/feature/login -BranchOnly
    Synchronizes Owner/Repo and creates only the feature/login worktree.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.String
    Native Git progress/output can reach the pipeline; status is written to the
    host and skipped or failed operations are reported as warnings.
.NOTES
    Invalid owner or URL input is rejected before GitHub is contacted. Existing
    bare repositories are checked against the requested GitHub origin before
    changes. An existing unregistered worktree path is skipped, not
    overwritten. Repository and worktree failures are reported while independent
    repositories continue; any incomplete run exits with an error. Earlier
    changes are not rolled back. Dot-source the script to load functions without
    synchronizing.
.LINK
    https://git-scm.com/docs/git-worktree
#>
[CmdletBinding(DefaultParameterSetName = 'Owner')]
param (
    [Parameter(ParameterSetName = 'Owner')]
    [string] $GitHubOwner = 'Owner',

    [Parameter(Mandatory, ParameterSetName = 'Url')]
    [string] $Url,

    [Parameter(ParameterSetName = 'Url')]
    [switch] $BranchOnly,

    [string] $TargetDirectory = 'C:\GIT',

    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitTooling.Common.ps1')


# ============================================================================
# Pure steps: no Git, GitHub or file system access
# ============================================================================

function Get-OwnerRepositoryEndpoint {
    <#
    .SYNOPSIS
        Returns the GitHub API endpoint listing an owner's own repositories.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Owner,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $OwnerType
    )

    $encodedOwner = [uri]::EscapeDataString($Owner)
    # type=owner (users) and type=sources (organizations) exclude repositories
    # the account only collaborates on; forks are filtered separately.
    switch ($OwnerType) {
        'User' { return "users/$encodedOwner/repos?type=owner&per_page=100" }
        'Organization' { return "orgs/$encodedOwner/repos?type=sources&per_page=100" }
        default { throw "GitHub returned an unsupported owner type for '$Owner'." }
    }
}


function ConvertFrom-RepositoryRecord {
    <#
    .SYNOPSIS
        Converts a GitHub API repository record into name, nameWithOwner and fork.
    #>
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        $Record
    )

    if ($Record -isnot [System.Collections.IDictionary] -or
        -not $Record.Contains('name') -or
        -not $Record.Contains('full_name') -or
        -not $Record.Contains('fork')) {
        throw 'GitHub returned an unexpected repository record.'
    }

    return [pscustomobject]@{
        name = [string] $Record['name']
        nameWithOwner = [string] $Record['full_name']
        fork = [bool] $Record['fork']
    }
}


function Select-SourceRepository {
    <#
    .SYNOPSIS
        Returns non-fork repositories sorted by name.
    #>
    param (
        [AllowEmptyCollection()]
        [object[]] $Repository = @()
    )

    return @(
        $Repository |
            Where-Object { -not $_.fork } |
            Sort-Object name |
            Select-Object name, nameWithOwner
    )
}


function Get-RepositoryLayout {
    <#
    .SYNOPSIS
        Returns the repository folder and bare repository path for owner/name.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [Parameter(Mandatory)]
        [string] $NameWithOwner
    )

    $owner, $name = $NameWithOwner -split '/', 2
    $root = Join-Path (Join-Path $TargetDirectory $owner) $name
    return [pscustomobject]@{
        RepositoryRoot = $root
        BareRepository = Join-Path $root '.git'
    }
}


function Test-OriginIdentity {
    <#
    .SYNOPSIS
        Tests whether a remote URL identifies the given GitHub owner/name.
    #>
    param (
        [AllowEmptyString()]
        [string] $OriginUrl,

        [Parameter(Mandatory)]
        [string] $NameWithOwner
    )

    if ([string]::IsNullOrWhiteSpace($OriginUrl)) {
        return $false
    }
    try {
        $location = ConvertFrom-GitHubLocation -Location $OriginUrl
    }
    catch {
        return $false
    }
    if ($null -eq $location.Repository -or $null -ne $location.Branch) {
        return $false
    }

    return "$($location.Owner)/$($location.Repository)".Equals(
        $NameWithOwner,
        [StringComparison]::OrdinalIgnoreCase
    )
}


function Test-IgnoredBranch {
    param (
        [Parameter(Mandatory)]
        [string] $Branch
    )

    return $Branch -eq 'HEAD' -or $Branch -like 'dependabot/*'
}


function Get-WorktreeBranchPlan {
    <#
    .SYNOPSIS
        Decides which origin branches get a worktree.
    .DESCRIPTION
        Without Branch, returns every branch with Ignored set for HEAD and
        dependabot/*. With Branch, returns only that branch, compared ordinally,
        or nothing when origin does not have it.
    #>
    param (
        [AllowEmptyCollection()]
        [string[]] $RemoteBranch = @(),

        [string] $Branch
    )

    if (-not [string]::IsNullOrEmpty($Branch)) {
        if ($RemoteBranch -ccontains $Branch) {
            return [pscustomobject]@{ Branch = $Branch; Ignored = $false }
        }
        return
    }

    foreach ($candidate in $RemoteBranch) {
        [pscustomobject]@{
            Branch = $candidate
            Ignored = Test-IgnoredBranch -Branch $candidate
        }
    }
}


function Test-WorktreeRegistered {
    <#
    .SYNOPSIS
        Tests whether a worktree record exists for a path and, if given, branch.
    .DESCRIPTION
        Paths are normalized and compared with Comparison; branches are compared
        ordinally so case-distinct branches are never treated as the same.
    #>
    param (
        [AllowEmptyCollection()]
        [object[]] $Worktree = @(),

        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Branch,

        [StringComparison] $Comparison = (Get-PathComparison)
    )

    $target = ConvertTo-NormalizedPath -Path $Path
    foreach ($record in $Worktree) {
        if ((ConvertTo-NormalizedPath -Path $record.Path).Equals($target, $Comparison) -and
            ([string]::IsNullOrEmpty($Branch) -or
            [string]::Equals($record.Branch, $Branch, [StringComparison]::Ordinal))) {
            return $true
        }
    }
    return $false
}


function Test-UpstreamConfigured {
    <#
    .SYNOPSIS
        Interprets `git config --get` exit codes for branch.<name>.remote and .merge.
    .DESCRIPTION
        Returns $true when any setting exists (exit code 0), $false when all are
        unset (exit code 1), and throws for any other exit code.
    #>
    param (
        [Parameter(Mandatory)]
        [int[]] $ExitCode
    )

    foreach ($code in $ExitCode) {
        if ($code -eq 0) {
            return $true
        }
        if ($code -ne 1) {
            throw "Could not read upstream configuration (git exit code $code)."
        }
    }
    return $false
}


function Get-WorktreeAddCommand {
    <#
    .SYNOPSIS
        Returns the status message and git arguments that create a branch worktree.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $WorktreePath,

        [Parameter(Mandatory)]
        [string] $Branch,

        [switch] $LocalBranchExists
    )

    if ($LocalBranchExists) {
        return [pscustomobject]@{
            Message = "WORKTREE $Branch"
            Arguments = @('-C', $BareRepository, 'worktree', 'add', $WorktreePath, $Branch)
        }
    }

    return [pscustomobject]@{
        Message = "WORKTREE $Branch -> origin/$Branch"
        Arguments = @(
            '-C', $BareRepository, 'worktree', 'add',
            '--track', '-b', $Branch, $WorktreePath, "origin/$Branch"
        )
    }
}


function Get-SyncFailureMessage {
    param (
        [Parameter(Mandatory)]
        [string[]] $FailedRepository
    )

    return "Synchronization incomplete for $($FailedRepository.Count) " +
    "repository/repositories: $($FailedRepository -join ', '). Review the warnings and retry."
}


# ============================================================================
# Git and GitHub boundaries
# ============================================================================

function Write-DryRun {
    param (
        [Parameter(Mandatory)]
        [string] $Message
    )

    Write-Host "  [DRY RUN] $Message" -ForegroundColor Yellow
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


function Invoke-GhJson {
    param (
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $ErrorMessage
    )

    $json = Invoke-Gh -Arguments $Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
    return ConvertFrom-Json -InputObject ($json -join [Environment]::NewLine) -AsHashtable -NoEnumerate
}


function Get-RemoteRepository {
    param (
        [Parameter(Mandatory)]
        [string] $Owner
    )

    $ownerProfile = Invoke-GhJson -Arguments @('api', "users/$([uri]::EscapeDataString($Owner))") `
        -ErrorMessage "Could not determine whether '$Owner' is a GitHub user or organization."
    $endpoint = Get-OwnerRepositoryEndpoint -Owner $Owner -OwnerType ([string] $ownerProfile['type'])
    $pages = Invoke-GhJson -Arguments @('api', '--paginate', '--slurp', $endpoint) `
        -ErrorMessage "Could not retrieve repositories for '$Owner'."

    $records = foreach ($page in $pages) {
        foreach ($record in $page) {
            ConvertFrom-RepositoryRecord -Record $record
        }
    }
    return Select-SourceRepository -Repository @($records)
}


function Get-GitHubRepository {
    param (
        [Parameter(Mandatory)]
        [string] $Owner,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    $endpoint = "repos/$([uri]::EscapeDataString($Owner))/$([uri]::EscapeDataString($Repository))"
    $record = Invoke-GhJson -Arguments @('api', $endpoint) `
        -ErrorMessage "Could not retrieve repository '$Owner/$Repository'."
    return ConvertFrom-RepositoryRecord -Record $record | Select-Object name, nameWithOwner
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
        [string] $WorktreePath,

        [string] $Branch
    )

    $listing = Invoke-Git -Arguments @(
        '-C', $BareRepository, 'worktree', 'list', '--porcelain', '-z'
    )
    return Test-WorktreeRegistered -Worktree @(ConvertFrom-GitWorktreeList -Text $listing) `
        -Path $WorktreePath -Branch $Branch
}


function Test-GitHubRepositoryOrigin {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository,

        [Parameter(Mandatory)]
        [string] $RepositoryNameWithOwner
    )

    # Read the configured URL, not the insteadOf-expanded one: it states which
    # repository origin is meant to be.
    $originUrl = Invoke-Git -AllowFailure -Arguments @(
        '-C', $BareRepository, 'config', '--get', 'remote.origin.url'
    )
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return Test-OriginIdentity -OriginUrl ([string] $originUrl) -NameWithOwner $RepositoryNameWithOwner
}


function Get-RemoteBranch {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository
    )

    # Symbolic refs such as origin/HEAD (written by fetch since Git 2.48) print an empty line.
    $branches = Invoke-Git -AllowFailure -Arguments @(
        '-C', $BareRepository,
        'for-each-ref', '--format=%(if)%(symref)%(then)%(else)%(refname:strip=3)%(end)', 'refs/remotes/origin/'
    )

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    # The comma keeps an empty list distinguishable from the $null failure result.
    return , @(
        $branches |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique -CaseSensitive
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

    $exitCodes = foreach ($setting in @('remote', 'merge')) {
        Invoke-Git -AllowFailure -Arguments @(
            '-C', $BareRepository, 'config', '--get', "branch.$Branch.$setting"
        ) | Out-Null
        $LASTEXITCODE
    }
    if (Test-UpstreamConfigured -ExitCode $exitCodes) {
        return
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

    if (Test-ExistingWorktree -BareRepository $BareRepository -WorktreePath $worktreePath -Branch $Branch) {
        Write-Host "  SKIP     $Branch - worktree already registered" -ForegroundColor DarkGray
        return $true
    }

    if (Test-Path -LiteralPath $worktreePath) {
        Write-Warning (
            "Cannot create worktree '$Branch': " +
            "'$worktreePath' already exists but is not a registered worktree."
        )
        return $false
    }

    $command = Get-WorktreeAddCommand -BareRepository $BareRepository -WorktreePath $worktreePath `
        -Branch $Branch -LocalBranchExists:$localBranchExists

    if ($DryRun) {
        Write-DryRun $command.Message
        return $true
    }

    Write-Host "  $($command.Message)" -ForegroundColor Green

    New-Item -ItemType Directory -Path (Split-Path -Parent $worktreePath) -Force | Out-Null

    Invoke-Git -AllowFailure -Arguments $command.Arguments | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to create worktree for ${RepositoryName}:$Branch"
        return $false
    }

    return $true
}


function Sync-Repository {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Repository,

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        # Create or check only this branch's worktree.
        [string] $Branch,

        [switch] $DryRun
    )

    $layout = Get-RepositoryLayout -TargetDirectory $TargetDirectory -NameWithOwner $Repository.nameWithOwner
    $repositoryRoot = $layout.RepositoryRoot
    $bareRepository = $layout.BareRepository

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
            return $false
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
            return $true
        }

        Write-Host '  CLONE    bare repository' -ForegroundColor Cyan

        New-Item -ItemType Directory -Path $repositoryRoot -Force | Out-Null

        Invoke-Gh -Arguments @(
            'repo', 'clone', $Repository.nameWithOwner, $bareRepository, '--', '--bare'
        ) | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to clone $($Repository.nameWithOwner)."
            return $false
        }
    }

    if (-not (Test-GitHubRepositoryOrigin -BareRepository $bareRepository -RepositoryNameWithOwner $Repository.nameWithOwner)) {
        Write-Warning (
            "Repository '$($Repository.nameWithOwner)' was skipped because its origin " +
            'does not identify the expected GitHub repository.'
        )
        return $false
    }

    if (-not $DryRun) {
        # Also applied to repositories created by earlier versions of the script.
        Invoke-Git -Arguments @(
            '-C', $bareRepository,
            'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*'
        )

        # Remove metadata for worktrees whose folders were removed manually.
        Invoke-Git -Arguments @('-C', $bareRepository, 'worktree', 'prune') | Out-Null

        Invoke-Git -Arguments @('-C', $bareRepository, 'fetch', 'origin', '--prune') | Out-Null
    }

    $branches = Get-RemoteBranch -BareRepository $bareRepository
    if ($null -eq $branches) {
        Write-Warning "Could not read branches for $($Repository.nameWithOwner)."
        return $false
    }

    $plan = @(Get-WorktreeBranchPlan -RemoteBranch $branches -Branch $Branch)
    if (-not [string]::IsNullOrEmpty($Branch) -and $plan.Count -eq 0) {
        Write-Warning "Branch '$Branch' does not exist on origin for $($Repository.nameWithOwner)."
        return $false
    }

    if ($plan.Count -eq 0) {
        Write-Host '  EMPTY    repository has no branches' -ForegroundColor DarkGray
        return $true
    }

    $repositorySucceeded = $true
    foreach ($entry in $plan) {
        if ($entry.Ignored) {
            Write-Host "  IGNORE   $($entry.Branch)" -ForegroundColor DarkGray
            continue
        }

        $worktreeSucceeded = New-BranchWorktree `
            -BareRepository $bareRepository `
            -RepositoryRoot $repositoryRoot `
            -RepositoryName $Repository.nameWithOwner `
            -Branch $entry.Branch `
            -DryRun:$DryRun
        if (-not $worktreeSucceeded) {
            $repositorySucceeded = $false
        }
    }

    return $repositorySucceeded
}


function Invoke-RepositorySync {
    <#
    .SYNOPSIS
        Synchronizes each repository, continuing after failures, and throws if any failed.
    #>
    param (
        [AllowEmptyCollection()]
        [object[]] $Repository = @(),

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [string] $Branch,

        [switch] $DryRun
    )

    $failedRepositories = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Repository) {
        try {
            $succeeded = Sync-Repository -Repository $entry -TargetDirectory $TargetDirectory `
                -Branch $Branch -DryRun:$DryRun
            if (-not $succeeded) {
                $failedRepositories.Add($entry.nameWithOwner)
            }
        }
        catch {
            Write-Warning "Failed to synchronize '$($entry.nameWithOwner)': $($_.Exception.Message)"
            $failedRepositories.Add($entry.nameWithOwner)
        }
    }

    if ($failedRepositories.Count -gt 0) {
        throw (Get-SyncFailureMessage -FailedRepository $failedRepositories)
    }
}


function Invoke-Main {
    param (
        [string] $GitHubOwner,

        [string] $Url,

        [switch] $BranchOnly,

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [switch] $DryRun
    )

    $target = Resolve-GitHubTarget -GitHubOwner $GitHubOwner -Url $Url -BranchOnly:$BranchOnly

    Assert-Prerequisite

    if ($DryRun) {
        Write-Host 'Dry run: no changes will be made.' -ForegroundColor Yellow
    }

    Write-Host ''
    if ($null -ne $target.Repository) {
        Write-Host "Reading repository $($target.Owner)/$($target.Repository)..." -ForegroundColor Cyan
        $repositories = @(Get-GitHubRepository -Owner $target.Owner -Repository $target.Repository)
    }
    else {
        Write-Host "Reading non-fork repositories owned by $($target.Owner)..." -ForegroundColor Cyan
        $repositories = @(Get-RemoteRepository -Owner $target.Owner)
    }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
    }

    Invoke-RepositorySync -Repository $repositories -TargetDirectory $TargetDirectory `
        -Branch $target.Branch -DryRun:$DryRun

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
    $mainArguments = @{
        TargetDirectory = $TargetDirectory
        DryRun = $DryRun
    }
    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $mainArguments.Url = $Url
        $mainArguments.BranchOnly = $BranchOnly
    }
    else {
        $mainArguments.GitHubOwner = $GitHubOwner
    }
    Invoke-Main @mainArguments
}
