#Requires -Version 7.0

<#
.SYNOPSIS
    Previews or removes clean worktrees whose tracked origin branch was deleted.
.DESCRIPTION
    Inspects repositories in the <TargetDirectory>\<owner>\<repository> layout
    created by Sync-GitRepositories.ps1, each with a bare .git directory. Selects
    every repository of an owner, or a single repository by URL. Queries origin
    directly without fetching, including in preview mode; stale local
    remote-tracking refs do not prove deletion.
    Only registered worktrees tracking missing origin branches are eligible.
    Skips locked, missing, dirty (including ignored files), detached, local-only,
    outside-root and nested worktrees, the current directory and its ancestors,
    and paths traversing symbolic links or junctions below the repository root.
    Requires Git on PATH and read access to each origin. Empty remote branch
    listings skip cleanup; remote errors stop it.
.PARAMETER GitHubOwner
    Owner whose local repositories are inspected, given as a name or a
    github.com owner URL such as https://github.com/example. Defaults to example.
    Cannot be combined with Url.
.PARAMETER Url
    github.com location selecting what to inspect. An owner URL behaves like
    GitHubOwner. A repository URL such as https://github.com/example/github, or a
    branch URL such as https://github.com/example/github/tree/feature/login,
    inspects only that repository. HTTPS, SSH and scheme-less forms, a trailing
    slash and a .git suffix are accepted.
.PARAMETER BranchOnly
    With a branch URL, considers only the worktree of that branch. Requires a
    branch URL.
.PARAMETER TargetDirectory
    Root directory containing one folder per owner. Defaults to C:\Repositories, so
    example/github is inspected in C:\Repositories\example\github. Owner and repository
    folders are matched case-insensitively when no exact match exists. The owner
    and repository folders must not be symbolic links or junctions.
.PARAMETER Apply
    Removes eligible worktrees with git worktree remove, without force. Without
    this switch, only reports candidates. Supports the common WhatIf and Confirm
    parameters for removal operations.
.PARAMETER DeleteMergedBranch
    Also considers deleting a removed worktree's local branch with git branch -d.
    Requires proof that it is an ancestor of origin's current default-branch
    commit, which must be available locally. Without Apply, previews only.
    Missing proof or Git refusal preserves the branch and reports a warning.
.EXAMPLE
    .\Remove-StaleGitWorktree.ps1
    Previews eligible worktrees across example's repositories in C:\Repositories\example.
.EXAMPLE
    .\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github -Apply -WhatIf
    Exercises removal planning for example/github without removing worktrees.
.EXAMPLE
    .\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github/tree/feature/login -BranchOnly -Apply
    Removes the feature/login worktree if its origin branch was deleted.
.EXAMPLE
    .\Remove-StaleGitWorktree.ps1 -GitHubOwner example -TargetDirectory C:\Repositories -Apply -DeleteMergedBranch -Confirm
    Confirms eligible worktree removals and separately confirms branch deletions.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.String
    Native Git operations can emit text. Previews and removal status are written
    to the host; skipped unsafe candidates are reported as warnings.
.NOTES
    Local branches and commits are preserved unless DeleteMergedBranch permits
    deletion. Unregistered folders and empty parent folders are never removed.
    Close editors and stop processes using candidates before applying cleanup.
    A missing owner folder is reported as a warning; a missing repository
    selected by URL is an error. Errors stop execution without undoing completed
    removals. Dot-sourcing loads functions without starting cleanup.
.LINK
    https://git-scm.com/docs/git-worktree
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Owner')]
param (
    [Parameter(ParameterSetName = 'Owner')]
    [string] $GitHubOwner = 'example',

    [Parameter(Mandatory, ParameterSetName = 'Url')]
    [string] $Url,

    [Parameter(ParameterSetName = 'Url')]
    [switch] $BranchOnly,

    [string] $TargetDirectory = 'C:\Repositories',

    [switch] $Apply,

    [switch] $DeleteMergedBranch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitTooling.Common.ps1')


# ============================================================================
# Pure steps: no Git or file system access
# ============================================================================

function Select-DirectoryName {
    <#
    .SYNOPSIS
        Returns the candidate folder name matching Name exactly, else ignoring case.
    .DESCRIPTION
        Returns $null when nothing matches. Throws when several candidates match
        only ignoring case, because the intended folder is then ambiguous.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Name,

        [AllowEmptyCollection()]
        [string[]] $Candidate = @()
    )

    if ($Candidate -ccontains $Name) {
        return $Name
    }
    $found = @($Candidate | Where-Object { $_.Equals($Name, [StringComparison]::OrdinalIgnoreCase) })
    if ($found.Count -gt 1) {
        throw "Several folders match '$Name' ignoring case: $($found -join ', ')."
    }
    if ($found.Count -eq 1) {
        return $found[0]
    }
    return $null
}


function ConvertFrom-RemoteHeadList {
    <#
    .SYNOPSIS
        Parses `git ls-remote --heads` lines into origin branch names.
    #>
    param (
        [AllowEmptyCollection()]
        [string[]] $Line = @()
    )

    $branches = foreach ($entry in $Line) {
        if ($entry -cnotmatch '^[0-9a-f]+\trefs/heads/(.+)$') {
            throw "Unexpected remote branch line: '$entry'"
        }
        $Matches[1]
    }
    # The comma keeps an empty list from collapsing to $null.
    return , @($branches)
}


function Get-RemoteDefaultCommit {
    <#
    .SYNOPSIS
        Returns origin's default-branch commit, or $null when it is not proven.
    .DESCRIPTION
        SymrefLine is `git ls-remote --symref origin HEAD` output and HeadLine is
        `git ls-remote --heads origin` output. The commit is returned only when
        HEAD names exactly one branch and that branch has the same commit.
    #>
    param (
        [AllowEmptyCollection()]
        [string[]] $SymrefLine = @(),

        [AllowEmptyCollection()]
        [string[]] $HeadLine = @()
    )

    $headRef = @($SymrefLine | Where-Object { $_ -cmatch '^ref: refs/heads/.+\tHEAD$' })
    $headCommit = @($SymrefLine | Where-Object { $_ -cmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})\tHEAD$' })
    if ($headRef.Count -ne 1 -or $headCommit.Count -ne 1) {
        return $null
    }

    $branchRef = ($headRef[0] -split "`t", 2)[0].Substring(5)
    $commit = ($headCommit[0] -split "`t", 2)[0]
    if ($HeadLine -ccontains "$commit`t$branchRef") {
        return $commit
    }
    return $null
}


function ConvertFrom-UpstreamList {
    <#
    .SYNOPSIS
        Parses `git for-each-ref --format=%(refname)%09%(upstream) refs/heads/` lines.
    .OUTPUTS
        An ordinal dictionary from local branch name to upstream ref ('' when none).
    #>
    param (
        [AllowEmptyCollection()]
        [string[]] $Line = @()
    )

    $upstreams = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Line) {
        $parts = $entry -split "`t", 2
        if ($parts.Count -ne 2 -or -not $parts[0].StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
            throw "Unexpected local branch line: '$entry'"
        }
        $upstreams[$parts[0].Substring(11)] = $parts[1]
    }
    # PowerShell does not enumerate dictionaries, so the caller receives it whole.
    return $upstreams
}


function Test-StaleWorktreeCandidate {
    <#
    .SYNOPSIS
        Tests whether a worktree's branch tracks an origin branch that no longer exists.
    .DESCRIPTION
        Detached and bare worktrees, local-only branches and branches tracking
        another remote are never candidates. With Branch, only that branch
        (compared ordinally) can be a candidate.
    #>
    param (
        [Parameter(Mandatory)]
        [object] $Worktree,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Upstream,

        [AllowEmptyCollection()]
        [string[]] $RemoteBranch = @(),

        [string] $Branch
    )

    if ([string]::IsNullOrEmpty($Worktree.Branch)) {
        return $false
    }
    if (-not [string]::IsNullOrEmpty($Branch) -and $Worktree.Branch -cne $Branch) {
        return $false
    }
    if (-not $Upstream.ContainsKey($Worktree.Branch)) {
        return $false
    }
    $tracked = $Upstream[$Worktree.Branch]
    if (-not $tracked.StartsWith('refs/remotes/origin/', [StringComparison]::Ordinal)) {
        return $false
    }
    return -not ($RemoteBranch -ccontains $tracked.Substring(20))
}


function Get-WorktreeLocationSkipReason {
    <#
    .SYNOPSIS
        Returns why a worktree location is unsafe to remove, or '' when it is not.
    .DESCRIPTION
        Checks, in order: outside the repository folder or inside the bare
        repository, locked, containing the current directory, and containing
        another registered worktree. File system checks are left to the caller.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [string] $CurrentPath,

        [switch] $Locked,

        [AllowEmptyCollection()]
        [string[]] $OtherPath = @(),

        [StringComparison] $Comparison = (Get-PathComparison)
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $target = ConvertTo-NormalizedPath -Path $Path
    $root = ConvertTo-NormalizedPath -Path $RepositoryRoot
    $bare = Join-Path $root '.git'

    if (-not $target.StartsWith("$root$separator", $Comparison) -or
        $target.Equals($bare, $Comparison) -or
        $target.StartsWith("$bare$separator", $Comparison)) {
        return 'outside the managed worktree folders'
    }
    if ($Locked) {
        return 'locked'
    }
    if (-not [string]::IsNullOrEmpty($CurrentPath)) {
        $current = ConvertTo-NormalizedPath -Path $CurrentPath
        if ($current.Equals($target, $Comparison) -or $current.StartsWith("$target$separator", $Comparison)) {
            return 'contains the current directory'
        }
    }
    foreach ($other in $OtherPath) {
        if ((ConvertTo-NormalizedPath -Path $other).StartsWith("$target$separator", $Comparison)) {
            return 'contains another registered worktree'
        }
    }
    return ''
}


# ============================================================================
# Git and file system boundaries, composed from the steps above
# ============================================================================

function Test-ReparsePointBelowRoot {
    <#
    .SYNOPSIS
        Tests whether Path or any ancestor below RepositoryRoot is a symbolic link or junction.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $comparison = Get-PathComparison
    $root = ConvertTo-NormalizedPath -Path $RepositoryRoot
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item -and -not $item.FullName.TrimEnd('\', '/').Equals($root, $comparison)) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            return $true
        }
        $item = $item.Parent
    }
    return $false
}


function Remove-StaleRepositoryWorktree {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [string] $Branch,

        [switch] $Apply,

        [switch] $DeleteMergedBranch
    )

    $bareRepository = Join-Path $RepositoryRoot '.git'
    $isBare = Invoke-Git -Arguments @('-C', $bareRepository, 'rev-parse', '--is-bare-repository')
    if ($isBare -ne 'true') {
        Write-Warning "Skipping '$RepositoryRoot': .git is not a bare repository."
        return
    }

    try {
        # Query the remote even in preview mode; stale tracking refs are not evidence of deletion.
        $remoteHeads = @(Invoke-Git -Arguments @('-C', $bareRepository, 'ls-remote', '--heads', 'origin'))
        $remoteBranches = ConvertFrom-RemoteHeadList -Line $remoteHeads
        $upstreams = ConvertFrom-UpstreamList -Line @(Invoke-Git -Arguments @(
                '-C', $bareRepository, 'for-each-ref', '--format=%(refname)%09%(upstream)', 'refs/heads/'
            ))
        $worktrees = @(ConvertFrom-GitWorktreeList -Text @(Invoke-Git -Arguments @(
                    '-C', $bareRepository, 'worktree', 'list', '--porcelain', '-z'
                )))
    }
    catch {
        throw "Cannot inspect '$RepositoryRoot': $($_.Exception.Message)"
    }

    if ($remoteBranches.Count -eq 0) {
        Write-Warning "Skipping '$RepositoryRoot': origin returned no branches; refusing cleanup."
        return
    }

    $defaultCommit = $null
    if ($DeleteMergedBranch) {
        $symref = @(Invoke-Git -Arguments @('-C', $bareRepository, 'ls-remote', '--symref', 'origin', 'HEAD'))
        $defaultCommit = Get-RemoteDefaultCommit -SymrefLine $symref -HeadLine $remoteHeads
        if (-not $defaultCommit) {
            Write-Warning "Cannot determine origin's default branch for '$RepositoryRoot'; local branches will be preserved."
        }
    }

    $currentPath = $PWD.ProviderPath
    # ForEach-Object <property> honors -WhatIf and would return nothing; foreach does not.
    $otherPaths = @(foreach ($record in $worktrees) { $record.Path })
    $candidateFound = $false

    foreach ($worktree in $worktrees) {
        if (-not (Test-StaleWorktreeCandidate -Worktree $worktree -Upstream $upstreams -RemoteBranch $remoteBranches -Branch $Branch)) {
            continue
        }
        $candidateFound = $true

        $path = ConvertTo-NormalizedPath -Path $worktree.Path
        $reason = Get-WorktreeLocationSkipReason -Path $path -RepositoryRoot $RepositoryRoot `
            -CurrentPath $currentPath -Locked:$worktree.Locked -OtherPath $otherPaths
        if (-not $reason -and -not (Test-Path -LiteralPath $path -PathType Container)) {
            $reason = 'folder is missing'
        }
        if (-not $reason -and (Test-ReparsePointBelowRoot -Path $path -RepositoryRoot $RepositoryRoot)) {
            $reason = 'path contains a symbolic link or junction'
        }
        if (-not $reason) {
            $status = @(Invoke-Git -Arguments @(
                    '-C', $path, 'status', '--porcelain=v1', '--untracked-files=all', '--ignored'
                ))
            if ($status.Count -gt 0) {
                $reason = 'contains changes, untracked files or ignored files'
            }
        }
        if ($reason) {
            Write-Warning "Skipping '$path': $reason."
            continue
        }

        $deleteBranch = $false
        if ($DeleteMergedBranch -and $defaultCommit) {
            Invoke-Git -AllowFailure -Arguments @(
                '-C', $bareRepository, 'merge-base', '--is-ancestor', "refs/heads/$($worktree.Branch)", $defaultCommit
            ) 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $deleteBranch = $true
            }
            elseif ($LASTEXITCODE -ne 1) {
                Write-Warning "Cannot check whether '$($worktree.Branch)' is merged into origin's default branch; preserving it."
            }
        }

        if (-not $Apply) {
            $branchAction = if ($deleteBranch) { 'would attempt safe branch deletion' } else { 'branch is preserved' }
            Write-Host "[DRY RUN] Would remove '$path' ($branchAction for '$($worktree.Branch)')."
        }
        elseif ($PSCmdlet.ShouldProcess($path, 'Remove worktree; preserve local branch')) {
            Invoke-Git -Arguments @('-C', $bareRepository, 'worktree', 'remove', '--', $path)
            Write-Host "Removed '$path'."
            if ($deleteBranch -and $PSCmdlet.ShouldProcess($worktree.Branch, 'Delete merged local branch with git branch -d')) {
                Invoke-Git -AllowFailure -Arguments @('-C', $bareRepository, 'branch', '-d', '--', $worktree.Branch)
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Git refused to delete local branch '$($worktree.Branch)'; it is preserved."
                }
            }
            else {
                Write-Host "Local branch '$($worktree.Branch)' is preserved."
            }
        }
    }

    if (-not [string]::IsNullOrEmpty($Branch) -and -not $candidateFound) {
        Write-Host "No stale worktree for branch '$Branch' in '$RepositoryRoot'."
    }
}


function Get-ChildDirectory {
    <#
    .SYNOPSIS
        Returns the child folder matching Name (see Select-DirectoryName), rejecting links.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $children = @(Get-ChildItem -LiteralPath $Path -Directory -Force)
    $match = Select-DirectoryName -Name $Name -Candidate @(foreach ($child in $children) { $child.Name })
    if ($null -eq $match) {
        return $null
    }
    $directory = $children | Where-Object { $_.Name -ceq $match }
    if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "'$($directory.FullName)' must not be a symbolic link or junction."
    }
    return $directory
}


function Test-BareRepositoryFolder {
    param (
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo] $Directory
    )

    return -not ($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
    (Test-Path -LiteralPath (Join-Path $Directory.FullName '.git') -PathType Container)
}


function Invoke-WorktreeCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string] $GitHubOwner,

        [string] $Url,

        [switch] $BranchOnly,

        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [switch] $Apply,

        [switch] $DeleteMergedBranch
    )

    $target = Resolve-GitHubTarget -GitHubOwner $GitHubOwner -Url $Url -BranchOnly:$BranchOnly

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or is not available in PATH.'
    }
    if (-not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        throw "TargetDirectory '$TargetDirectory' does not exist or is not a directory."
    }

    $ownerDirectory = Get-ChildDirectory -Path $TargetDirectory -Name $target.Owner
    if ($null -eq $ownerDirectory) {
        Write-Warning "No folder for owner '$($target.Owner)' found in '$TargetDirectory'."
        return
    }

    if ($null -ne $target.Repository) {
        $repositoryDirectory = Get-ChildDirectory -Path $ownerDirectory.FullName -Name $target.Repository
        if ($null -eq $repositoryDirectory -or -not (Test-BareRepositoryFolder -Directory $repositoryDirectory)) {
            throw "No repository folder with a bare .git directory for '$($target.Owner)/$($target.Repository)' in '$($ownerDirectory.FullName)'."
        }
        $repositories = @($repositoryDirectory)
    }
    else {
        $repositories = @(
            Get-ChildItem -LiteralPath $ownerDirectory.FullName -Directory -Force |
                Where-Object { Test-BareRepositoryFolder -Directory $_ }
        )
        if ($repositories.Count -eq 0) {
            Write-Warning "No repositories with a bare .git directory found in '$($ownerDirectory.FullName)'."
        }
    }

    foreach ($repository in $repositories) {
        Remove-StaleRepositoryWorktree -RepositoryRoot $repository.FullName -Branch $target.Branch `
            -Apply:$Apply -DeleteMergedBranch:$DeleteMergedBranch
    }
}


# Skip execution when dot-sourced (e.g. by Pester).
if ($MyInvocation.InvocationName -ne '.') {
    $cleanupArguments = @{
        TargetDirectory = $TargetDirectory
        Apply = $Apply
        DeleteMergedBranch = $DeleteMergedBranch
    }
    if ($PSCmdlet.ParameterSetName -eq 'Url') {
        $cleanupArguments.Url = $Url
        $cleanupArguments.BranchOnly = $BranchOnly
    }
    else {
        $cleanupArguments.GitHubOwner = $GitHubOwner
    }
    Invoke-WorktreeCleanup @cleanupArguments
}
