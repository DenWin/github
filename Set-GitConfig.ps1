#Requires -Version 7.0

<#
.SYNOPSIS
    Configures Git defaults and optional user identity.
.DESCRIPTION
    Applies defaults for line endings, branches, fetch/push, rebasing,
    conflict resolution, VS Code editing and object checks.
    By default configuration is global; use -Scope Local to configure one repository.
    Identity values come only from -UserName and -Email.
    On Windows, requires Git Credential Manager and replaces global credential
    helpers with a reset followed by manager; other platforms keep their helpers.
    Requires Git on PATH.
.PARAMETER UserName
    Sets user.name.
.PARAMETER Email
    Sets user.email.
.PARAMETER Scope
    Configures global settings by default, or local settings for -Path.
.PARAMETER Path
    Repository used with -Scope Local. Defaults to the script directory.
.PARAMETER DryRun
    Prints the planned git config commands without writing configuration.
.EXAMPLE
    .\Set-GitConfig.ps1 -DryRun
    Previews global configuration changes.
.EXAMPLE
    .\Set-GitConfig.ps1 -UserName 'Jane Doe' -Email 'jane@example.com'
    Applies the defaults with an explicit identity.
.EXAMPLE
    .\Set-GitConfig.ps1 -Scope Local -Path C:\GIT\Owner\Repo
    Applies defaults to one repository.
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
    [string] $UserName,
    [string] $Email,
    [ValidateSet('Global', 'Local')]
    [string] $Scope = 'Global',
    [string] $Path = $PSScriptRoot,
    # Preview all changes without writing any git configuration.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitTooling.Common.ps1')


# ============================================================================
# Pure steps: no Git or GitHub access
# ============================================================================

function Select-GitUserName {
    <#
    .SYNOPSIS
        Returns the explicit user name.
    #>
    param (
        [string] $UserName
    )

    if ([string]::IsNullOrWhiteSpace($UserName)) { return $null }
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
        [AllowNull()]
        [string] $UserName,

        [AllowNull()]
        [string] $Email,

        [bool] $Windows = $IsWindows,

        [ValidateSet('Global', 'Local')]
        [string] $Scope = 'Global'
    )

    # Ordered list of [key, value, description].
    $plan = @(
        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            , @('user.name', $UserName, 'Identity')
        }
        if (-not [string]::IsNullOrWhiteSpace($Email)) {
            , @('user.email', $Email, 'Identity')
        }
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
        if ($Windows -and $Scope -eq 'Global') {
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
        [object[]] $Plan,

        [ValidateSet('Global', 'Local')]
        [string] $Scope = 'Global',

        [string] $Path
    )

    $scopeArgument = if ($Scope -eq 'Local') { '--local' } else { '--global' }
    $prefix = if ($Scope -eq 'Local') { @('-C', $Path) } else { @() }

    foreach ($entry in $Plan) {
        if ($entry.Key -eq 'credential.helper') {
            [pscustomobject]@{
                Arguments = $prefix + @('config', $scopeArgument, '--replace-all', 'credential.helper', '')
                FailureMessage = "Failed to reset git config 'credential.helper'."
            }
            [pscustomobject]@{
                Arguments = $prefix + @('config', $scopeArgument, '--add', 'credential.helper', $entry.Value)
                FailureMessage = "Failed to set git config 'credential.helper'."
            }
            continue
        }
        [pscustomobject]@{
            Arguments = $prefix + @('config', $scopeArgument, $entry.Key, $entry.Value)
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
# Git boundary, composed from the steps above
# ============================================================================

function Assert-Precondition {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or not available in PATH.'
    }
}

function Assert-GitConfigPrecondition {
    param (
        [ValidateSet('Global', 'Local')]
        [string] $Scope,
        [string] $Path
    )

    Assert-Precondition
    if ($Scope -eq 'Global' -and $IsWindows) {
        Invoke-Git -AllowFailure -Arguments @('credential-manager', '--version') 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Git Credential Manager is not available. Install it before configuring Git.'
        }
    }
    if ($Scope -eq 'Local') {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw "Local Git repository path '$Path' does not exist."
        }
        Invoke-Git -AllowFailure -Arguments @('-C', $Path, 'rev-parse', '--git-dir') 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "'$Path' is not a Git repository."
        }
    }
}

function Invoke-GitConfigPlan {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Plan,

        [ValidateSet('Global', 'Local')]
        [string] $Scope = 'Global',

        [string] $Path,

        [switch] $DryRun
    )

    foreach ($command in Get-GitConfigCommand -Plan $Plan -Scope $Scope -Path $Path) {
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
    param (
        [ValidateSet('Global', 'Local')]
        [string] $Scope,
        [string] $Path
    )

    $prefix = if ($Scope -eq 'Local') { @('-C', $Path) } else { @() }
    $scopeArgument = if ($Scope -eq 'Local') { '--local' } else { '--global' }
    Write-Host ''
    Write-Host 'Git configuration complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Identity' -ForegroundColor Cyan
    Write-Host "  Name : $(Invoke-Git -AllowFailure -Arguments ($prefix + @('config', $scopeArgument, '--get', 'user.name')))"
    Write-Host "  Email: $(Invoke-Git -AllowFailure -Arguments ($prefix + @('config', $scopeArgument, '--get', 'user.email')))"
    Write-Host ''
    Write-Host "$Scope configuration" -ForegroundColor Cyan
    Invoke-Git -Arguments ($prefix + @('config', $scopeArgument, '--list'))
    Write-Host ''
    Write-Host 'Configuration sources' -ForegroundColor Cyan
    Invoke-Git -Arguments ($prefix + @('config', '--list', '--show-origin'))
}

function Invoke-Main {
    [CmdletBinding()]
    param (
        [string] $UserName,
        [string] $Email,
        [ValidateSet('Global', 'Local')]
        [string] $Scope = 'Global',
        [string] $Path,
        [switch] $DryRun
    )

    Assert-GitConfigPrecondition -Scope $Scope -Path $Path
    $UserName = Select-GitUserName -UserName $UserName
    $plan = Get-GitConfigPlan -UserName $UserName -Email $Email -Scope $Scope

    if ($DryRun) {
        Write-Host 'Dry run: no changes will be written.' -ForegroundColor Yellow
    }

    Invoke-GitConfigPlan -Plan $plan -Scope $Scope -Path $Path -DryRun:$DryRun

    if ($DryRun) {
        Write-Host ''
        Write-Host 'Dry run complete. Nothing was changed.' -ForegroundColor Yellow
        return
    }

    Show-GitConfigResult -Scope $Scope -Path $Path
}

# Skip execution when dot-sourced (e.g. by Pester).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -UserName $UserName -Email $Email -Scope $Scope -Path $Path -DryRun:$DryRun
}
