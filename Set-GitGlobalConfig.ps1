#Requires -Version 7.0

[CmdletBinding()]
param (
    # Defaults to the GitHub profile name (or login if no name is set).
    [string] $UserName,

    # Preview all changes without writing any git configuration.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# Git Global Configuration
# Windows + WSL + VS Code + GitHub
# ============================================================================

# --- Helpers ----------------------------------------------------------------

function Invoke-Git {
    & git @args
}

function Invoke-Gh {
    & gh @args
}

function Assert-Precondition {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or not available in PATH.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is not installed or not available in PATH.'
    }

    if ($IsWindows) {
        $PSNativeCommandUseErrorActionPreference = $false
        Invoke-Git credential-manager --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Git Credential Manager is not available. Install it before configuring Git.'
        }
    }

    Invoke-Gh auth status 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
    }
}

function Get-GitHubIdentity {
    $json = Invoke-Gh api user

    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read the GitHub user profile.'
    }

    $user = $json | ConvertFrom-Json
    $login = $user.PSObject.Properties['login']?.Value
    $id = $user.PSObject.Properties['id']?.Value
    $profileName = $user.PSObject.Properties['name']?.Value

    if ([string]::IsNullOrWhiteSpace($login) -or -not $id) {
        throw 'Could not determine the GitHub noreply email address.'
    }

    # The profile name is optional on GitHub; fall back to the login.
    $name = if ([string]::IsNullOrWhiteSpace($profileName)) { $login } else { $profileName.Trim() }

    [pscustomobject]@{
        Name = $name
        Email = "$id+$login@users.noreply.github.com"
    }
}

function Get-GitConfigPlan {
    param (
        [Parameter(Mandatory)]
        [string] $UserName,

        [Parameter(Mandatory)]
        [string] $Email
    )

    # Ordered list of [key, value, description].
    @(
        , @('user.name', $UserName, 'Identity')
        , @('user.email', $Email, 'Identity')
        # Keep LF in the working tree; normalize CRLF to LF on commit.
        , @('core.autocrlf', 'input', 'Line endings')
        # Warn if line-ending conversion could be unsafe.
        , @('core.safecrlf', 'warn', 'Line endings')
        , @('init.defaultBranch', 'main', 'Default branch')
        # Rebase local commits on top of the remote branch during pull.
        , @('pull.rebase', 'true', 'Pull / Rebase')
        # Stash uncommitted changes before rebase and restore afterwards.
        , @('rebase.autoStash', 'true', 'Pull / Rebase')
        # Set upstream tracking on first push.
        , @('push.autoSetupRemote', 'true', 'Push')
        , @('push.default', 'simple', 'Push')
        , @('push.followTags', 'true', 'Push')
        # Remove remote-tracking branches and tags deleted on the remote.
        , @('fetch.prune', 'true', 'Fetch')
        , @('fetch.pruneTags', 'true', 'Fetch')
        , @('fetch.writeCommitGraph', 'true', 'Fetch')
        , @('transfer.fsckObjects', 'true', 'Security')
        , @('protocol.file.allow', 'user', 'Security')
        if ($IsWindows) {
            , @('credential.helper', 'manager', 'Security')
            , @('core.longpaths', 'true', 'Windows')
        }
        # Reuse manually resolved conflicts; show base + both sides.
        , @('rerere.enabled', 'true', 'Merge / Conflicts')
        , @('merge.conflictStyle', 'zdiff3', 'Merge / Conflicts')
        , @('diff.algorithm', 'histogram', 'Diff')
        , @('core.editor', 'code --wait', 'Editor')
        , @('color.ui', 'auto', 'UI')
    ) | ForEach-Object {
        [pscustomobject]@{ Key = $_[0]; Value = $_[1]; Section = $_[2] }
    }
}

function Invoke-GitConfigPlan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Plan,

        [switch] $DryRun
    )

    foreach ($entry in $Plan) {
        if ($entry.Key -eq 'credential.helper') {
            if ($DryRun) {
                Write-Host "[DRY RUN] git config --global --replace-all credential.helper ''" -ForegroundColor Yellow
                Write-Host "[DRY RUN] git config --global --add credential.helper '$($entry.Value)'" -ForegroundColor Yellow
                continue
            }

            Invoke-Git config --global --replace-all credential.helper ''
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to reset git config 'credential.helper'."
            }
            Invoke-Git config --global --add credential.helper $entry.Value
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to set git config 'credential.helper'."
            }
            continue
        }

        if ($DryRun) {
            Write-Host "[DRY RUN] git config --global $($entry.Key) '$($entry.Value)'" -ForegroundColor Yellow
            continue
        }

        Invoke-Git config --global $entry.Key $entry.Value

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set git config '$($entry.Key)'."
        }
    }
}

function Show-GitConfigResult {
    Write-Host ''
    Write-Host 'Git configuration complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Identity' -ForegroundColor Cyan
    Write-Host "  Name : $(Invoke-Git config --global user.name)"
    Write-Host "  Email: $(Invoke-Git config --global user.email)"
    Write-Host ''
    Write-Host 'Global configuration' -ForegroundColor Cyan
    Invoke-Git config --global --list
    Write-Host ''
    Write-Host 'Configuration sources' -ForegroundColor Cyan
    Invoke-Git config --list --show-origin
}

function Invoke-Main {
    [CmdletBinding()]
    param (
        [string] $UserName,
        [switch] $DryRun
    )

    Assert-Precondition

    $identity = Get-GitHubIdentity

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $UserName = $identity.Name
    }

    $plan = Get-GitConfigPlan -UserName $UserName -Email $identity.Email

    if ($DryRun) {
        Write-Host 'Dry run: no changes will be written.' -ForegroundColor Yellow
    }

    Invoke-GitConfigPlan -Plan $plan -DryRun:$DryRun

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry run complete. Nothing was changed.' -ForegroundColor Yellow
        return
    }

    Show-GitConfigResult
}

# Skip execution when dot-sourced (e.g. by Pester).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -UserName $UserName -DryRun:$DryRun
}
