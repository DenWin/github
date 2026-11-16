#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $TargetDirectory = 'C:\GIT\DenWin',

    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Sync-GitRepositories.ps1') -TargetDirectory $TargetDirectory

function Get-RegisteredWorktree {
    param (
        [Parameter(Mandatory)]
        [string] $BareRepository
    )

    $output = Invoke-Git -Arguments @(
        '-C', $BareRepository, 'worktree', 'list', '--porcelain', '-z'
    )
    $entry = $null
    foreach ($field in (($output -join "`n") -split "`0")) {
        if ($field.StartsWith('worktree ')) {
            if ($null -ne $entry) {
                [pscustomobject] $entry
            }
            $entry = @{
                Path = $field.Substring(9)
                Branch = ''
                Locked = $false
            }
        }
        elseif ($null -ne $entry -and $field.StartsWith('branch refs/heads/')) {
            $entry.Branch = $field.Substring(18)
        }
        elseif ($null -ne $entry -and $field -match '^locked(?: |$)') {
            $entry.Locked = $true
        }
    }
    if ($null -ne $entry) {
        [pscustomobject] $entry
    }
}

function Remove-StaleRepositoryWorktree {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [switch] $Apply
    )

    $bareRepository = Join-Path $RepositoryRoot '.git'
    $isBare = Invoke-Git -Arguments @('-C', $bareRepository, 'rev-parse', '--is-bare-repository')
    if ($isBare -ne 'true') {
        Write-Warning "Skipping '$RepositoryRoot': .git is not a bare repository."
        return
    }

    # Query the remote even in preview mode; stale tracking refs are not evidence of deletion.
    $remoteRefs = @(Invoke-Git -Arguments @('-C', $bareRepository, 'ls-remote', '--heads', 'origin'))
    $remoteBranches = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $remoteRefs) {
        if ($line -notmatch '^[0-9a-f]+\trefs/heads/(.+)$') {
            throw "Unexpected remote branch response for '$RepositoryRoot': $line"
        }
        [void] $remoteBranches.Add($Matches[1])
    }

    $upstreams = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $refs = Invoke-Git -Arguments @(
        '-C', $bareRepository, 'for-each-ref', '--format=%(refname)%09%(upstream)', 'refs/heads/'
    )
    foreach ($line in $refs) {
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2 -or -not $parts[0].StartsWith('refs/heads/')) {
            throw "Unexpected local branch response for '$RepositoryRoot': $line"
        }
        $upstreams[$parts[0].Substring(11)] = $parts[1]
    }

    $worktrees = @(Get-RegisteredWorktree -BareRepository $bareRepository)
    $currentPath = [System.IO.Path]::GetFullPath($PWD.ProviderPath)
    $rootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $separator = [System.IO.Path]::DirectorySeparatorChar

    foreach ($worktree in $worktrees) {
        if (-not $worktree.Branch -or -not $upstreams.ContainsKey($worktree.Branch)) {
            continue
        }
        $upstream = $upstreams[$worktree.Branch]
        if (-not $upstream.StartsWith('refs/remotes/origin/')) {
            continue
        }
        if ($remoteBranches.Contains($upstream.Substring(20))) {
            continue
        }

        $path = [System.IO.Path]::GetFullPath($worktree.Path).TrimEnd('\', '/')
        $reason = ''
        if (-not $path.StartsWith("$rootPath$separator", $comparison) -or
            $path.Equals($bareRepository, $comparison) -or
            $path.StartsWith("$bareRepository$separator", $comparison)) {
            $reason = 'outside the managed worktree folders'
        }
        elseif ($worktree.Locked) {
            $reason = 'locked'
        }
        elseif ($currentPath.Equals($path, $comparison) -or $currentPath.StartsWith("$path$separator", $comparison)) {
            $reason = 'contains the current directory'
        }
        elseif (-not (Test-Path -LiteralPath $path -PathType Container)) {
            $reason = 'folder is missing'
        }
        else {
            $ancestor = Get-Item -LiteralPath $path -Force
            while ($null -ne $ancestor -and -not $ancestor.FullName.Equals($rootPath, $comparison)) {
                if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $reason = 'path contains a symbolic link or junction'
                    break
                }
                $ancestor = $ancestor.Parent
            }
            foreach ($other in $worktrees) {
                $otherPath = [System.IO.Path]::GetFullPath($other.Path)
                if ($otherPath.StartsWith("$path$separator", $comparison)) {
                    $reason = 'contains another registered worktree'
                    break
                }
            }
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

        if (-not $Apply) {
            Write-Host "[DRY RUN] Would remove '$path' (branch '$($worktree.Branch)' is preserved)."
        }
        elseif ($PSCmdlet.ShouldProcess($path, 'Remove worktree; preserve local branch')) {
            Invoke-Git -Arguments @('-C', $bareRepository, 'worktree', 'remove', '--', $path)
            Write-Host "Removed '$path'; local branch '$($worktree.Branch)' is preserved."
        }
    }
}

function Invoke-WorktreeCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string] $TargetDirectory,

        [switch] $Apply
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or is not available in PATH.'
    }
    $target = Get-Item -LiteralPath $TargetDirectory -Force
    if (-not $target.PSIsContainer -or $target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'TargetDirectory must be a directory, not a symbolic link or junction.'
    }

    $repositories = @(
        if (Test-Path -LiteralPath (Join-Path $target.FullName '.git') -PathType Container) {
            $target
        }
        else {
            Get-ChildItem -LiteralPath $target.FullName -Directory -Force |
                Where-Object {
                    -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -and
                    (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container)
                }
        }
    )
    if ($repositories.Count -eq 0) {
        Write-Warning "No repositories with a bare .git directory found in '$TargetDirectory'."
    }
    foreach ($repository in $repositories) {
        Remove-StaleRepositoryWorktree -RepositoryRoot $repository.FullName -Apply:$Apply
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WorktreeCleanup -TargetDirectory $TargetDirectory -Apply:$Apply
}
