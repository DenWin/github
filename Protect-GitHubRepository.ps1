#Requires -Version 7.0

<#
.SYNOPSIS
    Audits and hardens GitHub repository settings.
.DESCRIPTION
    Audits an explicit GitHub.com repository through gh and applies supported
    remediations only with -Apply. Remediation may require administration access.
    The default branch is protected against direct pushes by requiring pull
    request reviews and blocking force pushes and branch deletion.
.PARAMETER Repository
    Explicit GitHub.com target as owner/name or as a repository or branch URL,
    such as https://github.com/Owner/Repo or
    https://github.com/Owner/Repo/tree/main; a branch in the URL is ignored.
    An owner-only URL is rejected. The target is never inferred from local Git configuration.
.PARAMETER Apply
    Applies supported GitHub remediations for findings. Does not rewrite YAML.
    Supports common WhatIf and Confirm parameters. Action-source remediation
    replaces third-party allowlist exceptions with GitHub-owned actions plus
    ossf/scorecard-action@*, while preserving disabled or local-only policies.
.PARAMETER FailOnFinding
    Throws after emitting findings if any have status Fail or Unknown, including
    manual-review checks. An Applied status is not a verified clean audit.
.EXAMPLE
    .\Protect-GitHubRepository.ps1 -Repository Owner/Repo
    Audits the explicit GitHub target without changing it.
.EXAMPLE
    .\Protect-GitHubRepository.ps1 -Repository https://github.com/Owner/Repo -Apply -WhatIf
    Previews supported GitHub setting changes.
.INPUTS
    None. This script does not accept pipeline input.
.OUTPUTS
    System.Management.Automation.PSCustomObject
    Findings with Id, Severity, Target, Status, Message and Fix properties.
    Status is Fail, Unknown or Applied; successful checks generally emit nothing.
.NOTES
    This is a policy audit, not a security certification. Branch protection
    remediation is supported for the default branch. Required status checks
    are not guessed. Applied means an API accepted a change: rerun the
    audit to verify it. Errors stop remediation without rolling back earlier
    changes. Hooks inspect the working tree, can be bypassed and do not replace CI.
    Dot-source the script to load functions without starting an audit.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $Repository,
    [switch] $Apply,
    [switch] $FailOnFinding
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GitTooling.Common.ps1')


# ============================================================================
# Pure steps: no file system, Git or GitHub access
# ============================================================================

function New-SecurityFinding {
    param (
        [string] $Id,
        [string] $Severity,
        [string] $Target,
        [string] $Message,
        [string] $Status = 'Fail',
        [hashtable] $Fix
    )

    [pscustomobject]@{
        Id = $Id
        Severity = $Severity
        Target = $Target
        Status = $Status
        Message = $Message
        Fix = $Fix
    }
}


function Resolve-SecurityTarget {
    <#
    .SYNOPSIS
        Returns owner/name from owner/name or a github.com repository or branch URL.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Repository
    )

    $location = ConvertFrom-GitHubLocation -Location $Repository
    if ($null -eq $location.Repository) {
        throw "'$Repository' names only an owner; specify owner/name or a repository URL."
    }
    return "$($location.Owner)/$($location.Repository)"
}


function Test-ReadOnlyPermission {
    param ($Permission)

    if ($Permission -is [System.Collections.IDictionary]) {
        return @($Permission.Values | Where-Object { $_ -notin @('read', 'none') }).Count -eq 0
    }
    return $Permission -eq 'read-all'
}


function Get-StepFinding {
    <#
    .SYNOPSIS
        Audits one parsed workflow step: inline expressions, pins and checkout credentials.
    #>
    param (
        [System.Collections.IDictionary] $Step,

        [Parameter(Mandatory)]
        [string] $Target
    )

    if ($null -eq $Step) {
        return
    }
    if ($Step.Contains('run') -and [string] $Step['run'] -match '\$\{\{') {
        New-SecurityFinding 'step.expression' 'Medium' $Target 'Pass expressions through environment variables, not inline shell code.'
    }
    if (-not $Step.Contains('uses')) {
        return
    }
    $uses = [string] $Step['uses']
    if ($uses.StartsWith('./')) {
        return
    }
    if ($uses.StartsWith('docker://')) {
        if ($uses -notmatch '@sha256:[a-fA-F0-9]{64}$') {
            New-SecurityFinding 'action.pin' 'Medium' $Target "Pin container action to a SHA-256 digest: $uses"
        }
    }
    elseif ($uses -notmatch '@[a-fA-F0-9]{40}$') {
        New-SecurityFinding 'action.pin' 'Medium' $Target "Pin action to a full commit SHA: $uses"
    }
    if ($uses -like 'actions/checkout@*' -and
        (-not $Step.Contains('with') -or
        $Step['with'] -isnot [System.Collections.IDictionary] -or
        $Step['with']['persist-credentials'] -notin @($false, 'false'))) {
        New-SecurityFinding 'checkout.credentials' 'Medium' $Target 'Set persist-credentials: false.'
    }
}


function Get-JobFinding {
    <#
    .SYNOPSIS
        Audits one parsed workflow job and its steps.
    .DESCRIPTION
        A reusable-workflow job (uses:) is checked only for permissions and its pin.
    #>
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Job,

        [Parameter(Mandatory)]
        [string] $Target
    )

    if ($Job.Contains('permissions') -and -not (Test-ReadOnlyPermission $Job['permissions'])) {
        New-SecurityFinding 'job.permissions' 'Medium' $Target 'Write permissions require manual least-privilege review.'
    }
    if ($Job.Contains('uses')) {
        $uses = [string] $Job['uses']
        if (-not $uses.StartsWith('./') -and $uses -notmatch '@[a-fA-F0-9]{40}$') {
            New-SecurityFinding 'workflow.pin' 'Medium' $Target 'Pin reusable workflows to a full commit SHA.'
        }
        return
    }
    if (-not $Job.Contains('timeout-minutes') -or
        $Job['timeout-minutes'] -isnot [ValueType] -or
        $Job['timeout-minutes'] -le 0 -or $Job['timeout-minutes'] -gt 30) {
        New-SecurityFinding 'job.timeout' 'Low' $Target 'Use a numeric job timeout between 1 and 30 minutes.'
    }
    if (($Job['runs-on'] | ConvertTo-Json -Compress) -match 'self-hosted') {
        New-SecurityFinding 'job.runner' 'High' $Target 'Self-hosted runners require isolation from untrusted pull requests.'
    }
    if ($Job.Contains('steps')) {
        foreach ($step in @($Job['steps'])) {
            Get-StepFinding -Step $step -Target $Target
        }
    }
}


function Get-WorkflowFinding {
    <#
    .SYNOPSIS
        Audits one parsed workflow: permissions, privileged triggers and every job.
    #>
    param (
        $Workflow,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($Workflow -isnot [System.Collections.IDictionary] -or
        $Workflow['jobs'] -isnot [System.Collections.IDictionary]) {
        throw "Invalid workflow structure: $Name"
    }
    if (-not (Test-ReadOnlyPermission $Workflow['permissions'])) {
        New-SecurityFinding 'workflow.permissions' 'Medium' $Name 'Set explicit read-only or empty workflow permissions.'
    }
    $events = $Workflow['on']
    $eventNames = if ($events -is [System.Collections.IDictionary]) { @($events.Keys) } else { @($events) }
    if (@($eventNames | Where-Object { $_ -in @('pull_request_target', 'workflow_run') }).Count) {
        New-SecurityFinding 'workflow.privileged-trigger' 'High' $Name 'Privileged trigger requires manual trust-boundary review.'
    }
    foreach ($jobName in $Workflow['jobs'].Keys) {
        Get-JobFinding -Job $Workflow['jobs'][$jobName] -Target "${Name}:$jobName"
    }
}


function Get-ActionPolicyData {
    <#
    .SYNOPSIS
        Returns the actions/permissions data when it is usable for planning, else $null.
    #>
    param ($Response)

    if ($null -ne $Response -and $Response.Success -and $Response.Data -is [System.Collections.IDictionary] -and
        $Response.Data.Contains('enabled') -and $Response.Data.Contains('allowed_actions')) {
        return $Response.Data
    }
    return $null
}


function Get-GitHubSecurityCheck {
    <#
    .SYNOPSIS
        Returns the GitHub setting checks with their endpoint, required keys, test and fix.
    .DESCRIPTION
        ActionPolicy is the current actions/permissions data or $null. It is used
        to preserve disabled Actions and local-only policies in the planned fix;
        without it, the fix keeps Actions disabled.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Repository,

        [System.Collections.IDictionary] $ActionPolicy
    )

    $base = "repos/$Repository"
    @(
        @{
            Id = 'github.actions-policy'; Endpoint = "$base/actions/permissions"
            Required = @('enabled', 'sha_pinning_required', 'allowed_actions')
            Test = { param ($data) $data['sha_pinning_required'] -eq $true -and $data['allowed_actions'] -in @('selected', 'local_only') }
            Message = 'Require action SHA pins and restricted action sources; preserve disabled Actions and local-only policies.'
            Fix = @{ Endpoint = "$base/actions/permissions"; Method = 'PUT'
                Body = @{
                    enabled = if ($null -ne $ActionPolicy) { $ActionPolicy['enabled'] } else { $false }
                    allowed_actions = if ($null -ne $ActionPolicy -and $ActionPolicy['allowed_actions'] -eq 'local_only') { 'local_only' } else { 'selected' }
                    sha_pinning_required = $true
                }
            }
        }
        @{
            Id = 'github.workflow-token'; Endpoint = "$base/actions/permissions/workflow"
            Required = @('default_workflow_permissions', 'can_approve_pull_request_reviews')
            Test = { param ($data) $data['default_workflow_permissions'] -eq 'read' -and $data['can_approve_pull_request_reviews'] -eq $false }
            Message = 'Use read-only workflow tokens and disable workflow PR approval.'
            Fix = @{ Endpoint = "$base/actions/permissions/workflow"; Method = 'PUT'
                Body = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
            }
        }
        @{
            Id = 'github.fork-pr-workflows'; Endpoint = "$base/actions/permissions/fork-pr-contributor-approval"
            Required = @('approval_policy')
            Test = { param ($data) $data['approval_policy'] -eq 'first_time_contributors_new_to_github' }
            Message = 'Require fork pull-request workflow approval only for contributors new to GitHub.'
            Fix = @{ Endpoint = "$base/actions/permissions/fork-pr-contributor-approval"; Method = 'PUT'
                Body = @{ approval_policy = 'first_time_contributors_new_to_github' }
            }
        }
        @{
            Id = 'github.action-sources'; Endpoint = "$base/actions/permissions/selected-actions"
            Required = @('github_owned_allowed', 'verified_allowed', 'patterns_allowed')
            Test = { param ($data) $data['github_owned_allowed'] -eq $true -and
                $data['verified_allowed'] -eq $false -and @($data['patterns_allowed']).Count -eq 1 -and
                $data['patterns_allowed'][0] -eq 'ossf/scorecard-action@*' }
            Message = 'Restrict selected action sources to GitHub-owned actions and the explicit OpenSSF Scorecard exception.'
            Fix = @{ Endpoint = "$base/actions/permissions/selected-actions"; Method = 'PUT'
                Body = @{ github_owned_allowed = $true; verified_allowed = $false; patterns_allowed = @('ossf/scorecard-action@*') }
            }
        }
        @{
            Id = 'github.dependabot'; Endpoint = "$base/automated-security-fixes"
            Required = @('enabled', 'paused')
            Test = { param ($data) $data['enabled'] -eq $true -and $data['paused'] -eq $false }
            Message = 'Enable or resume Dependabot security updates (vulnerability alerts must also be enabled).'
            Fix = @{ Endpoint = "$base/automated-security-fixes"; Method = 'PUT' }
        }
        @{
            Id = 'github.secret-scanning'; Endpoint = $base
            Required = @('security_and_analysis.secret_scanning.status', 'security_and_analysis.secret_scanning_push_protection.status')
            Test = { param ($data) $data['security_and_analysis']['secret_scanning']['status'] -eq 'enabled' -and
                $data['security_and_analysis']['secret_scanning_push_protection']['status'] -eq 'enabled' }
            Message = 'Enable secret scanning and push protection where supported by the repository plan.'
            Fix = @{ Endpoint = $base; Method = 'PATCH'; Body = @{ security_and_analysis = @{
                        secret_scanning = @{ status = 'enabled' }; secret_scanning_push_protection = @{ status = 'enabled' }
                    }
                }
            }
        }
        @{
            Id = 'github.private-reporting'; Endpoint = "$base/private-vulnerability-reporting"
            Required = @('enabled')
            Test = { param ($data) $data['enabled'] -eq $true }
            Message = 'Enable private vulnerability reporting for this public repository.'
            Fix = @{ Endpoint = "$base/private-vulnerability-reporting"; Method = 'PUT' }
        }
        @{
            Id = 'github.delete-merged-branches'; Endpoint = $base
            Required = @('delete_branch_on_merge')
            Test = { param ($data) $data['delete_branch_on_merge'] -eq $true }
            Message = 'Automatically delete head branches after pull requests are merged.'
            Fix = @{ Endpoint = $base; Method = 'PATCH'; Body = @{ delete_branch_on_merge = $true } }
        }
    )
}


function Get-ActionSourceDecision {
    <#
    .SYNOPSIS
        Decides how to audit selected action sources from the actions policy.
    .OUTPUTS
        'Skip' for local-only policies (sources are irrelevant), 'Fail' when all
        actions are allowed (the selected list is not in effect), else 'Query'.
    #>
    param (
        [System.Collections.IDictionary] $ActionPolicy
    )

    if ($null -ne $ActionPolicy) {
        switch ($ActionPolicy['allowed_actions']) {
            'local_only' { return 'Skip' }
            'all' { return 'Fail' }
        }
    }
    return 'Query'
}


function Get-MissingSettingKey {
    <#
    .SYNOPSIS
        Returns the dotted keys, such as a.b.c, that are absent from nested API data.
    #>
    param (
        $Data,

        [string[]] $Key = @()
    )

    foreach ($dottedKey in $Key) {
        $value = $Data
        foreach ($part in $dottedKey.Split('.')) {
            if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($part)) {
                $dottedKey
                break
            }
            $value = $value[$part]
        }
    }
}


function Get-SettingFinding {
    <#
    .SYNOPSIS
        Turns one check's API response into a finding, or nothing when it passes.
    .DESCRIPTION
        A failed call or missing setting is Unknown without a fix, so inaccessible
        or unsupported settings are never reported as passing or written blindly.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable] $Check,

        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    if (-not $Response.Success) {
        return New-SecurityFinding $Check.Id 'Medium' $Repository "$($Check.Message) API check unavailable: $($Response.Error)" 'Unknown'
    }
    $missing = @(Get-MissingSettingKey -Data $Response.Data -Key $Check.Required)
    if ($missing.Count) {
        return New-SecurityFinding $Check.Id 'Medium' $Repository "Unavailable or unsupported settings: $($missing -join ', ')" 'Unknown'
    }
    if (-not (& $Check.Test $Response.Data)) {
        return New-SecurityFinding $Check.Id 'Medium' $Repository $Check.Message -Fix $Check.Fix
    }
}


function Get-AlertFinding {
    <#
    .SYNOPSIS
        Turns the vulnerability-alerts response into a finding, or nothing when enabled.
    #>
    param (
        [Parameter(Mandatory)]
        $Response,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    if ($Response.Success) {
        return
    }
    if ($Response.Error -match 'Vulnerability alerts are disabled') {
        return New-SecurityFinding 'github.alerts' 'Medium' $Repository 'Enable vulnerability alerts.' -Fix @{
            Endpoint = "repos/$Repository/vulnerability-alerts"; Method = 'PUT'
        }
    }
    # A generic 404 can mean insufficient access. Never infer a pass or fix.
    return New-SecurityFinding 'github.alerts' 'Medium' $Repository "Cannot verify vulnerability alerts: $($Response.Error)" 'Unknown'
}


function Get-DefaultBranchName {
    param ($Response)

    if ($null -ne $Response -and $Response.Success -and $Response.Data -is [System.Collections.IDictionary] -and
        -not [string]::IsNullOrWhiteSpace($Response.Data['default_branch'])) {
        return [string] $Response.Data['default_branch']
    }
    return $null
}


function Get-BranchProtectionFinding {
    <#
    .SYNOPSIS
        Returns the always-Unknown branch protection finding with what is known.
    .DESCRIPTION
        Configuration is deliberately reported for manual review rather than
        equating the existence of rules with effective reviews, required checks
        and bypass enforcement. Legacy and Rules are $null when not queried.
    #>
    param (
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        $Metadata,

        $Legacy,

        $Rules
    )

    if (-not $Metadata.Success) {
        return New-SecurityFinding 'github.branch-protection' 'Medium' $Repository $Metadata.Error 'Unknown'
    }
    if ($null -eq (Get-DefaultBranchName -Response $Metadata)) {
        return New-SecurityFinding 'github.branch-protection' 'Medium' $Repository 'Default branch unavailable.' 'Unknown'
    }
    $branch = Get-DefaultBranchName -Response $Metadata
    $base = "repos/$Repository"
    $fix = @{
        Endpoint = "$base/branches/$([uri]::EscapeDataString($branch))/protection"
        Method = 'PUT'
        Body = @{
            required_status_checks = $null
            enforce_admins = $true
            required_pull_request_reviews = @{
                dismiss_stale_reviews = $true
                require_code_owner_reviews = $false
                required_approving_review_count = 1
                require_last_push_approval = $true
            }
            restrictions = $null
            required_linear_history = $true
            allow_force_pushes = $false
            allow_deletions = $false
            block_creations = $false
            lock_branch = $false
            allow_fork_syncing = $false
        }
    }
    $message = "Protect '$branch' with PR reviews and prevent force pushes and branch deletion."
    if ($null -ne $Legacy -and -not $Legacy.Success -and $null -ne $Rules -and $Rules.Success -and @($Rules.Data).Count -eq 0) {
        $message = "No active ruleset rules found; classic protection absent or inaccessible. $message"
    }
    if ($null -ne $Legacy -and $Legacy.Success) {
        $data = $Legacy.Data
        $protected = (
            $data -is [System.Collections.IDictionary] -and
            $data.Contains('required_pull_request_reviews') -and
            $null -ne $data['required_pull_request_reviews'] -and
            $data['allow_force_pushes'] -ne $true -and
            $data['allow_deletions'] -ne $true
        )
        if ($protected) {
            return
        }
    }
    return New-SecurityFinding 'github.branch-protection' 'High' $Repository $message 'Fail' $fix
}


function Get-RemediationRequest {
    <#
    .SYNOPSIS
        Returns the API requests, in order, that remediate a finding.
    .DESCRIPTION
        Dependabot security updates require vulnerability alerts, so alerts are
        enabled first. Findings without a fix return nothing.
    #>
    param (
        [Parameter(Mandatory)]
        [object] $Finding,

        [Parameter(Mandatory)]
        [string] $Repository
    )

    if ($null -eq $Finding.Fix) {
        return
    }
    if ($Finding.Id -eq 'github.dependabot') {
        @{ Endpoint = "repos/$Repository/vulnerability-alerts"; Method = 'PUT' }
    }
    $Finding.Fix
}


# ============================================================================
# File system, Git and GitHub boundaries, composed from the steps above
# ============================================================================

function Get-WorkflowSecurityFinding {
    param ([string] $Path)

    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    Import-Module powershell-yaml -RequiredVersion $dependencies['powershell-yaml'] -ErrorAction Stop
    $directory = Join-Path (Join-Path $Path '.github') 'workflows'
    $files = @()
    if (Test-Path -LiteralPath $directory) {
        $files = @(Get-ChildItem -LiteralPath $directory -File |
                Where-Object Extension -In @('.yml', '.yaml'))
    }
    if ($files.Count -eq 0) {
        New-SecurityFinding 'workflow.missing' 'Medium' $directory 'No workflow files found.'
    }
    foreach ($file in $files) {
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $file.FullName -Raw)
        Get-WorkflowFinding -Workflow $workflow -Name $file.Name
    }
}


function Invoke-SecurityApi {
    param (
        [string] $Endpoint,
        [string] $Method = 'GET',
        [hashtable] $Body
    )

    # Keep expected HTTP failures inspectable without treating them as success.
    $PSNativeCommandUseErrorActionPreference = $false
    $arguments = @('api', '--hostname', 'github.com', '--method', $Method,
        '-H', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint)
    if ($null -ne $Body) {
        $arguments += @('--input', '-')
        $output = $Body | ConvertTo-Json -Depth 20 -Compress | & gh @arguments 2>&1
    }
    else {
        $output = & gh @arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        return [pscustomobject]@{ Success = $false; Data = $null; Error = $text }
    }
    $data = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { ConvertFrom-Json -InputObject $text -AsHashtable }
    [pscustomobject]@{ Success = $true; Data = $data; Error = $null }
}


function Get-GitHubSecurityFinding {
    param ([string] $Repository)

    $base = "repos/$Repository"
    $actionResponse = Invoke-SecurityApi -Endpoint "$base/actions/permissions"
    $actionPolicy = Get-ActionPolicyData -Response $actionResponse

    foreach ($check in Get-GitHubSecurityCheck -Repository $Repository -ActionPolicy $actionPolicy) {
        if ($check.Id -eq 'github.action-sources') {
            $decision = Get-ActionSourceDecision -ActionPolicy $actionPolicy
            if ($decision -eq 'Skip') {
                continue
            }
            if ($decision -eq 'Fail') {
                New-SecurityFinding $check.Id 'Medium' $Repository $check.Message -Fix $check.Fix
                continue
            }
        }
        $response = if ($check.Endpoint -eq "$base/actions/permissions") {
            $actionResponse
        }
        else {
            Invoke-SecurityApi -Endpoint $check.Endpoint
        }
        Get-SettingFinding -Check $check -Response $response -Repository $Repository
    }

    Get-AlertFinding -Response (Invoke-SecurityApi -Endpoint "$base/vulnerability-alerts") -Repository $Repository

    $metadata = Invoke-SecurityApi -Endpoint $base
    $branch = Get-DefaultBranchName -Response $metadata
    $legacy = $null
    $rules = $null
    if ($null -ne $branch) {
        $escapedBranch = [uri]::EscapeDataString($branch)
        $legacy = Invoke-SecurityApi -Endpoint "$base/branches/$escapedBranch/protection"
        $rules = Invoke-SecurityApi -Endpoint "$base/rules/branches/$escapedBranch"
    }
    Get-BranchProtectionFinding -Repository $Repository -Metadata $metadata -Legacy $legacy -Rules $rules
}


function Protect-GitHubRepository {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string] $Repository,
        [switch] $Apply,
        [switch] $FailOnFinding
    )

    $target = Resolve-SecurityTarget -Repository $Repository
    $findings = @(Get-GitHubSecurityFinding -Repository $target)
    foreach ($finding in $findings) {
        $requests = @(Get-RemediationRequest -Finding $finding -Repository $target)
        if ($Apply -and $requests.Count -and $PSCmdlet.ShouldProcess($target, $finding.Message)) {
            foreach ($request in $requests) {
                $response = Invoke-SecurityApi @request
                if (-not $response.Success) {
                    throw "Remediation failed for $($finding.Id) ($($request.Method) $($request.Endpoint)): $($response.Error)"
                }
            }
            $finding.Status = 'Applied'
            $finding.Message += ' Change accepted; rerun the audit to verify.'
        }
    }
    $findings
    if ($FailOnFinding -and @($findings | Where-Object Status -In @('Fail', 'Unknown')).Count) {
        throw 'Security checks found unresolved findings or checks requiring manual verification.'
    }
}


if ($MyInvocation.InvocationName -ne '.') {
    Protect-GitHubRepository @PSBoundParameters
}
