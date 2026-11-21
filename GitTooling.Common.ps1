#Requires -Version 7.0

<#
.SYNOPSIS
    Shared helpers for the Git workflow scripts.
.DESCRIPTION
    Provides native Git/gh wrappers, parsing of GitHub owner, repository and
    branch locations, and parsing of Git worktree listings. Parsing functions
    are pure: they take text and return objects without calling Git or GitHub.
    Dot-sourced by Sync-GitRepositories.ps1, Remove-StaleGitWorktree.ps1,
    Invoke-RepositorySecurity.ps1 and Set-GitGlobalConfig.ps1; it performs no
    action when loaded.
.EXAMPLE
    . .\GitTooling.Common.ps1
    ConvertFrom-GitHubLocation 'https://github.com/DenWin/github/tree/feature/x'
    Returns Owner DenWin, Repository github and Branch feature/x.
.INPUTS
    None.
.OUTPUTS
    None when dot-sourced; see the individual functions.
.NOTES
    Requires PowerShell 7. Only github.com locations are accepted.
#>

Set-StrictMode -Version Latest

function Invoke-Git {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    # Keep non-zero exit codes inspectable instead of turning them into errors.
    $PSNativeCommandUseErrorActionPreference = $false
    & git @Arguments

    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}


function Invoke-Gh {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments
    )

    $PSNativeCommandUseErrorActionPreference = $false
    & gh @Arguments
}


function Get-PathComparison {
    if ($IsWindows) {
        return [StringComparison]::OrdinalIgnoreCase
    }
    return [StringComparison]::Ordinal
}


function ConvertTo-NormalizedPath {
    param (
        [Parameter(Mandatory)]
        [string] $Path
    )

    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}


function Get-GitHubLocationPath {
    <#
    .SYNOPSIS
        Returns the path part of a GitHub location, without host, query or fragment.
    .DESCRIPTION
        Accepts https://, http://, ssh://git@, git:// and scheme-less github.com
        forms, the SCP-like git@github.com: form, and plain owner or owner/name
        text. Throws for any other host.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Location
    )

    $text = $Location.Trim()
    $hostPattern = '^(?:(?:https?|ssh|git)://(?:[^/@]+@)?(?:www\.)?github\.com(?::\d+)?/|(?:www\.)?github\.com[/:]|git@github\.com:)'
    if ($text -match $hostPattern) {
        $path = $text.Substring($Matches[0].Length)
    }
    elseif ($text -match '^[a-z][a-z0-9+.-]*://|^[^/]+@[^/]+:') {
        throw "'$Location' is not a github.com location."
    }
    else {
        $path = $text
    }

    return ($path -split '[?#]', 2)[0].Trim('/')
}


function ConvertFrom-GitHubPath {
    <#
    .SYNOPSIS
        Splits owner[/name[.git][/tree/branch]] into Owner, Repository and Branch.
    .DESCRIPTION
        Repository and Branch are $null when absent. Branch is everything after
        /tree/, URL-decoded, so it may contain slashes. Throws for an empty or
        invalid owner or name, and for any other repository subpath.
    #>
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    $segments = @($Path.Trim('/') -split '/' | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) {
        throw 'A GitHub owner is required.'
    }

    $owner = $segments[0]
    if ($owner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$') {
        throw "'$owner' is not a valid GitHub owner."
    }

    $repository = $null
    $branch = $null
    if ($segments.Count -ge 2) {
        $repository = $segments[1]
        if ($segments.Count -eq 2 -and $repository.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
            $repository = $repository.Substring(0, $repository.Length - 4)
        }
        if ($repository -notmatch '^[A-Za-z0-9_.-]+$' -or $repository -in @('.', '..')) {
            throw "'$repository' is not a valid GitHub repository name."
        }
    }

    if ($segments.Count -ge 3) {
        if ($segments[2] -cne 'tree' -or $segments.Count -lt 4) {
            throw "Unsupported GitHub repository path '$Path'; use owner/name or owner/name/tree/branch."
        }
        $branch = [uri]::UnescapeDataString(($segments[3..($segments.Count - 1)] -join '/'))
    }

    return [pscustomobject]@{
        Owner = $owner
        Repository = $repository
        Branch = $branch
    }
}


function ConvertFrom-GitHubLocation {
    <#
    .SYNOPSIS
        Parses a GitHub URL, remote URL, owner or owner/name into its parts.
    .EXAMPLE
        ConvertFrom-GitHubLocation 'git@github.com:DenWin/github.git'
        Returns Owner DenWin, Repository github and no Branch.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Location
    )

    return ConvertFrom-GitHubPath -Path (Get-GitHubLocationPath -Location $Location)
}


function ConvertFrom-GitWorktreeList {
    <#
    .SYNOPSIS
        Parses `git worktree list --porcelain -z` output into worktree records.
    .OUTPUTS
        Objects with Path, Branch ('' when detached or bare), Bare and Locked.
    #>
    param (
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text = @()
    )

    $entry = $null
    foreach ($field in (($Text -join '') -split "`0")) {
        if ($field.StartsWith('worktree ')) {
            if ($null -ne $entry) {
                [pscustomobject] $entry
            }
            $entry = [ordered]@{
                Path = $field.Substring(9)
                Branch = ''
                Bare = $false
                Locked = $false
            }
        }
        elseif ($null -eq $entry) {
            continue
        }
        elseif ($field.StartsWith('branch refs/heads/')) {
            $entry.Branch = $field.Substring(18)
        }
        elseif ($field -ceq 'bare') {
            $entry.Bare = $true
        }
        elseif ($field -match '^locked(?: |$)') {
            $entry.Locked = $true
        }
    }
    if ($null -ne $entry) {
        [pscustomobject] $entry
    }
}


function Resolve-GitHubTarget {
    <#
    .SYNOPSIS
        Validates owner/URL script input and returns the selected Owner, Repository and Branch.
    .DESCRIPTION
        Repository is $null for a whole owner. Branch is set only with BranchOnly.
    #>
    param (
        [string] $GitHubOwner,

        [string] $Url,

        [switch] $BranchOnly
    )

    if (-not [string]::IsNullOrWhiteSpace($Url)) {
        $location = ConvertFrom-GitHubLocation -Location $Url
    }
    else {
        $location = ConvertFrom-GitHubLocation -Location $GitHubOwner
        if ($null -ne $location.Repository) {
            throw "GitHubOwner '$GitHubOwner' names a repository; use -Url to select a single repository."
        }
    }

    if ($BranchOnly -and $null -eq $location.Branch) {
        throw '-BranchOnly requires a branch URL such as https://github.com/owner/name/tree/branch.'
    }

    return [pscustomobject]@{
        Owner = $location.Owner
        Repository = $location.Repository
        Branch = if ($BranchOnly) { $location.Branch } else { $null }
    }
}
