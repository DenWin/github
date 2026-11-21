#Requires -Version 7.0

<#
.SYNOPSIS
    Configures global Git defaults and identity from the authenticated GitHub user.
.DESCRIPTION
    Reads the GitHub profile with gh and uses its numeric ID and login to build a
    noreply email address. Applies global defaults for line endings, branches,
    fetch/push, rebasing, conflict resolution, VS Code editing and object checks.
    On Windows, requires Git Credential Manager and replaces global credential
    helpers with a reset followed by manager; other platforms keep their helpers.
    Requires Git and an authenticated GitHub CLI on PATH. Preview mode still
    checks prerequisites and reads the GitHub profile.
.PARAMETER UserName
    Overrides user.name. Defaults to the trimmed GitHub profile name, or the login
    when that name is empty. The email always comes from the GitHub identity.
.PARAMETER DryRun
    Prints the planned git config commands without writing configuration.
.EXAMPLE
    .\Set-GitGlobalConfig.ps1 -DryRun
    Previews global configuration changes for the authenticated GitHub user.
.EXAMPLE
    .\Set-GitGlobalConfig.ps1 -UserName 'Jane Doe'
    Applies the defaults with an explicit display name.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.String
    Git configuration listings after applying changes. Progress and previews are
    written to the host.
.NOTES
    Changes affect all repositories for the current OS user. Repository and
    worktree configuration can override them. Existing plaintext credential files
    are not removed. Errors stop execution; earlier changes are not rolled back.
    Dot-source the script to load its functions without applying configuration.
.LINK
    https://git-scm.com/docs/git-config
#>
[CmdletBinding()]
param (
    # Defaults to the GitHub profile name (or login if no name is set).
    [string] $UserName,

    # Preview all changes without writing any git configuration.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitTooling.Common.ps1')


# ============================================================================
# Pure steps: no Git or GitHub access
# ============================================================================

function ConvertFrom-GitHubUser {
    <#
    .SYNOPSIS
        Returns the display name and noreply email from the gh api user JSON.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Json
    )

    $user = $Json | ConvertFrom-Json
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

function Select-GitUserName {
    <#
    .SYNOPSIS
        Returns the explicit user name when given, else the GitHub identity name.
    #>
    param (
        [string] $UserName,

        [Parameter(Mandatory)]
        [string] $IdentityName
    )

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        return $IdentityName
    }
    return $UserName
}

function Get-GitConfigPlan {
    <#
    .SYNOPSIS
        Returns the ordered global settings as Key, Value and Section objects.
    .DESCRIPTION
        Windows adds Git Credential Manager and long paths. It defaults to the
        current platform and is a parameter so both plans can be inspected anywhere.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $UserName,

        [Parameter(Mandatory)]
        [string] $Email,

        [bool] $Windows = $IsWindows
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
        if ($Windows) {
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

function Get-GitConfigCommand {
    <#
    .SYNOPSIS
        Turns plan entries into git arguments, each with the message used on failure.
    .DESCRIPTION
        credential.helper becomes two commands: the reset with an empty value
        stops inherited helpers, then the plan value is added.
    #>
    param (
        [Parameter(Mandatory)]
        [object[]] $Plan
    )

    foreach ($entry in $Plan) {
        if ($entry.Key -eq 'credential.helper') {
            [pscustomobject]@{
                Arguments = @('config', '--global', '--replace-all', 'credential.helper', '')
                FailureMessage = "Failed to reset git config 'credential.helper'."
            }
            [pscustomobject]@{
                Arguments = @('config', '--global', '--add', 'credential.helper', $entry.Value)
                FailureMessage = "Failed to set git config 'credential.helper'."
            }
            continue
        }
        [pscustomobject]@{
            Arguments = @('config', '--global', $entry.Key, $entry.Value)
            FailureMessage = "Failed to set git config '$($entry.Key)'."
        }
    }
}

function Format-GitCommand {
    <#
    .SYNOPSIS
        Returns a git command line for previews, quoting the final value argument.
    #>
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Arguments
    )

    "git $($Arguments[0..($Arguments.Count - 2)] -join ' ') '$($Arguments[-1])'"
}


# ============================================================================
# Git and GitHub boundaries, composed from the steps above
# ============================================================================

function Assert-Precondition {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or not available in PATH.'
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is not installed or not available in PATH.'
    }

    if ($IsWindows) {
        Invoke-Git -AllowFailure -Arguments @('credential-manager', '--version') 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Git Credential Manager is not available. Install it before configuring Git.'
        }
    }

    Invoke-Gh -Arguments @('auth', 'status') 2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
    }
}

function Get-GitHubIdentity {
    $json = Invoke-Gh -Arguments @('api', 'user')

    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read the GitHub user profile.'
    }

    ConvertFrom-GitHubUser -Json ($json -join "`n")
}

function Invoke-GitConfigPlan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Plan,

        [switch] $DryRun
    )

    foreach ($command in Get-GitConfigCommand -Plan $Plan) {
        if ($DryRun) {
            Write-Host "[DRY RUN] $(Format-GitCommand -Arguments $command.Arguments)" -ForegroundColor Yellow
            continue
        }

        Invoke-Git -AllowFailure -Arguments $command.Arguments
        if ($LASTEXITCODE -ne 0) {
            throw $command.FailureMessage
        }
    }
}

function Show-GitConfigResult {
    Write-Host ''
    Write-Host 'Git configuration complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Identity' -ForegroundColor Cyan
    Write-Host "  Name : $(Invoke-Git -Arguments @('config', '--global', 'user.name'))"
    Write-Host "  Email: $(Invoke-Git -Arguments @('config', '--global', 'user.email'))"
    Write-Host ''
    Write-Host 'Global configuration' -ForegroundColor Cyan
    Invoke-Git -Arguments @('config', '--global', '--list')
    Write-Host ''
    Write-Host 'Configuration sources' -ForegroundColor Cyan
    Invoke-Git -Arguments @('config', '--list', '--show-origin')
}

function Invoke-Main {
    [CmdletBinding()]
    param (
        [string] $UserName,
        [switch] $DryRun
    )

    Assert-Precondition

    $identity = Get-GitHubIdentity
    $UserName = Select-GitUserName -UserName $UserName -IdentityName $identity.Name

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
