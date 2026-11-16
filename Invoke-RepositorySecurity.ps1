#Requires -Version 7.0
<#
.SYNOPSIS
    Audits workflow files and GitHub settings; changes settings only with -Apply.
.DESCRIPTION
    Requires powershell-yaml at the version in DevelopmentDependencies.psd1.
    GitHub.com is the only supported host. Local workflow findings require manual
    fixes; automatic remediation is restricted to the listed GitHub settings and
    optional local Git hooks. Unknown checks fail -FailOnFinding.
.EXAMPLE
    .\Invoke-RepositorySecurity.ps1 -Repository DenWin/github
.EXAMPLE
    .\Invoke-RepositorySecurity.ps1 -Repository DenWin/github -Apply -WhatIf
.EXAMPLE
    .\Invoke-RepositorySecurity.ps1 -LocalOnly -Apply -InstallHooks
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $Path = $PSScriptRoot,
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository,
    [switch] $LocalOnly,
    [switch] $Apply,
    [switch] $InstallHooks,
    [switch] $FailOnFinding
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Test-ReadOnlyPermission {
    param ($Permission)

    if ($Permission -is [System.Collections.IDictionary]) {
        return @($Permission.Values | Where-Object { $_ -notin @('read', 'none') }).Count -eq 0
    }
    return $Permission -eq 'read-all'
}

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
        if ($workflow -isnot [System.Collections.IDictionary] -or
            $workflow['jobs'] -isnot [System.Collections.IDictionary]) {
            throw "Invalid workflow structure: $($file.FullName)"
        }
        if (-not (Test-ReadOnlyPermission $workflow['permissions'])) {
            New-SecurityFinding 'workflow.permissions' 'Medium' $file.Name 'Set explicit read-only or empty workflow permissions.'
        }
        $events = $workflow['on']
        $eventNames = if ($events -is [System.Collections.IDictionary]) { @($events.Keys) } else { @($events) }
        if (@($eventNames | Where-Object { $_ -in @('pull_request_target', 'workflow_run') }).Count) {
            New-SecurityFinding 'workflow.privileged-trigger' 'High' $file.Name 'Privileged trigger requires manual trust-boundary review.'
        }
        foreach ($jobName in $workflow['jobs'].Keys) {
            $job = $workflow['jobs'][$jobName]
            $target = "$($file.Name):$jobName"
            if ($job.Contains('permissions') -and -not (Test-ReadOnlyPermission $job['permissions'])) {
                New-SecurityFinding 'job.permissions' 'Medium' $target 'Write permissions require manual least-privilege review.'
            }
            if ($job.Contains('uses')) {
                $uses = [string] $job['uses']
                if (-not $uses.StartsWith('./') -and $uses -notmatch '@[a-fA-F0-9]{40}$') {
                    New-SecurityFinding 'workflow.pin' 'Medium' $target 'Pin reusable workflows to a full commit SHA.'
                }
                continue
            }
            if (-not $job.Contains('timeout-minutes') -or
                $job['timeout-minutes'] -isnot [ValueType] -or
                $job['timeout-minutes'] -le 0 -or $job['timeout-minutes'] -gt 30) {
                New-SecurityFinding 'job.timeout' 'Low' $target 'Use a numeric job timeout between 1 and 30 minutes.'
            }
            if (($job['runs-on'] | ConvertTo-Json -Compress) -match 'self-hosted') {
                New-SecurityFinding 'job.runner' 'High' $target 'Self-hosted runners require isolation from untrusted pull requests.'
            }
            foreach ($step in @($job['steps'])) {
                if ($null -eq $step) { continue }
                if ($step.Contains('run') -and [string] $step['run'] -match '\$\{\{') {
                    New-SecurityFinding 'step.expression' 'Medium' $target 'Pass expressions through environment variables, not inline shell code.'
                }
                if (-not $step.Contains('uses')) { continue }
                $uses = [string] $step['uses']
                if ($uses.StartsWith('./')) { continue }
                if ($uses.StartsWith('docker://')) {
                    if ($uses -notmatch '@sha256:[a-fA-F0-9]{64}$') {
                        New-SecurityFinding 'action.pin' 'Medium' $target "Pin container action to a SHA-256 digest: $uses"
                    }
                }
                elseif ($uses -notmatch '@[a-fA-F0-9]{40}$') {
                    New-SecurityFinding 'action.pin' 'Medium' $target "Pin action to a full commit SHA: $uses"
                }
                if ($uses -like 'actions/checkout@*' -and
                    (-not $step.Contains('with') -or
                    $step['with'] -isnot [System.Collections.IDictionary] -or
                    $step['with']['persist-credentials'] -notin @($false, 'false'))) {
                    New-SecurityFinding 'checkout.credentials' 'Medium' $target 'Set persist-credentials: false.'
                }
            }
        }
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
    $actionPolicy = Invoke-SecurityApi -Endpoint "$base/actions/permissions"
    $hasActionPolicy = $actionPolicy.Success -and $actionPolicy.Data -is [System.Collections.IDictionary] -and
    $actionPolicy.Data.Contains('enabled') -and $actionPolicy.Data.Contains('allowed_actions')
    $checks = @(
        @{
            Id = 'github.actions-policy'; Endpoint = "$base/actions/permissions"
            Required = @('enabled', 'sha_pinning_required', 'allowed_actions')
            Test = { param ($data) $data['sha_pinning_required'] -eq $true -and $data['allowed_actions'] -in @('selected', 'local_only') }
            Message = 'Require action SHA pins and restricted action sources; preserve disabled Actions and local-only policies.'
            Fix = @{ Endpoint = "$base/actions/permissions"; Method = 'PUT'
                Body = @{
                    enabled = if ($hasActionPolicy) { $actionPolicy.Data['enabled'] } else { $false }
                    allowed_actions = if ($hasActionPolicy -and $actionPolicy.Data['allowed_actions'] -eq 'local_only') { 'local_only' } else { 'selected' }
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
            Id = 'github.action-sources'; Endpoint = "$base/actions/permissions/selected-actions"
            Required = @('github_owned_allowed', 'verified_allowed', 'patterns_allowed')
            Test = { param ($data) $data['github_owned_allowed'] -eq $true -and
                $data['verified_allowed'] -eq $false -and @($data['patterns_allowed']).Count -eq 0 }
            Message = 'Restrict selected action sources to GitHub-owned actions; review exceptions explicitly.'
            Fix = @{ Endpoint = "$base/actions/permissions/selected-actions"; Method = 'PUT'
                Body = @{ github_owned_allowed = $true; verified_allowed = $false; patterns_allowed = @() }
            }
        }
        @{
            Id = 'github.dependabot'; Endpoint = $base
            Required = @('security_and_analysis.dependabot_security_updates.status')
            Test = { param ($data) $data['security_and_analysis']['dependabot_security_updates']['status'] -eq 'enabled' }
            Message = 'Enable Dependabot security updates (vulnerability alerts must also be enabled).'
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
    )
    foreach ($check in $checks) {
        if ($check.Id -eq 'github.action-sources' -and $hasActionPolicy) {
            if ($actionPolicy.Data['allowed_actions'] -eq 'local_only') { continue }
            if ($actionPolicy.Data['allowed_actions'] -eq 'all') {
                New-SecurityFinding $check.Id 'Medium' $Repository $check.Message -Fix $check.Fix
                continue
            }
        }
        $response = if ($check.Id -eq 'github.actions-policy') {
            $actionPolicy
        }
        else {
            Invoke-SecurityApi -Endpoint $check.Endpoint
        }
        if (-not $response.Success) {
            New-SecurityFinding $check.Id 'Medium' $Repository "$($check.Message) API check unavailable: $($response.Error)" 'Unknown'
            continue
        }
        $missing = @(
            foreach ($key in $check.Required) {
                $value = $response.Data
                foreach ($part in $key.Split('.')) {
                    if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($part)) {
                        $key
                        break
                    }
                    $value = $value[$part]
                }
            }
        )
        if ($missing.Count) {
            New-SecurityFinding $check.Id 'Medium' $Repository "Unavailable or unsupported settings: $($missing -join ', ')" 'Unknown'
            continue
        }
        if (-not (& $check.Test $response.Data)) {
            New-SecurityFinding $check.Id 'Medium' $Repository $check.Message -Fix $check.Fix
        }
    }

    $alerts = Invoke-SecurityApi -Endpoint "$base/vulnerability-alerts"
    if (-not $alerts.Success) {
        if ($alerts.Error -match 'Vulnerability alerts are disabled') {
            New-SecurityFinding 'github.alerts' 'Medium' $Repository 'Enable vulnerability alerts.' -Fix @{
                Endpoint = "$base/vulnerability-alerts"; Method = 'PUT'
            }
        }
        else {
            # A generic 404 can mean insufficient access. Never infer a pass or fix.
            New-SecurityFinding 'github.alerts' 'Medium' $Repository "Cannot verify vulnerability alerts: $($alerts.Error)" 'Unknown'
        }
    }
    $metadata = Invoke-SecurityApi -Endpoint $base
    if (-not $metadata.Success) {
        New-SecurityFinding 'github.branch-protection' 'Medium' $Repository $metadata.Error 'Unknown'
        return
    }
    if ($metadata.Data -isnot [System.Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace($metadata.Data['default_branch'])) {
        New-SecurityFinding 'github.branch-protection' 'Medium' $Repository 'Default branch unavailable.' 'Unknown'
        return
    }
    $branch = [uri]::EscapeDataString($metadata.Data['default_branch'])
    $legacy = Invoke-SecurityApi -Endpoint "$base/branches/$branch/protection"
    $rules = Invoke-SecurityApi -Endpoint "$base/rules/branches/$branch"
    # Deliberately report configuration for review rather than equating existence
    # with effective PR reviews, status checks, and admin/bypass enforcement.
    $message = 'Manually verify PR reviews, required CI checks, force-push/deletion prevention, and bypass actors.'
    if (-not $legacy.Success -and $rules.Success -and @($rules.Data).Count -eq 0) {
        $message = "No active ruleset rules found; classic protection absent or inaccessible. $message"
    }
    New-SecurityFinding 'github.branch-protection' 'Medium' $Repository $message 'Unknown'
}

function Invoke-RepositorySecurity {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string] $Path = $PSScriptRoot,
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository,
        [switch] $LocalOnly,
        [switch] $Apply,
        [switch] $InstallHooks,
        [switch] $FailOnFinding
    )

    if ($InstallHooks -and -not $Apply) { throw '-InstallHooks requires -Apply (use -WhatIf to preview).' }
    if (-not $LocalOnly -and [string]::IsNullOrWhiteSpace($Repository)) {
        throw 'Specify -Repository owner/name or -LocalOnly; the GitHub target is never guessed.'
    }
    $findings = @(Get-WorkflowSecurityFinding -Path $Path)
    if (-not $LocalOnly) {
        $findings += @(Get-GitHubSecurityFinding -Repository $Repository)
    }
    foreach ($finding in $findings) {
        if ($Apply -and $null -ne $finding.Fix -and
            $PSCmdlet.ShouldProcess($Repository, $finding.Message)) {
            # Dependabot updates require alerts first.
            if ($finding.Id -eq 'github.dependabot') {
                $alerts = Invoke-SecurityApi -Endpoint "repos/$Repository/vulnerability-alerts" -Method PUT
                if (-not $alerts.Success) { throw "Cannot enable vulnerability alerts: $($alerts.Error)" }
            }
            $fix = $finding.Fix
            $response = Invoke-SecurityApi @fix
            if (-not $response.Success) { throw "Remediation failed for $($finding.Id): $($response.Error)" }
            $finding.Status = 'Applied'
            $finding.Message += ' Change accepted; rerun the audit to verify.'
        }
    }
    if ($InstallHooks -and $PSCmdlet.ShouldProcess($Path, 'Set local core.hooksPath to .githooks')) {
        $hookFiles = @(
            Join-Path (Join-Path $Path '.githooks') 'pre-commit'
            Join-Path (Join-Path $Path '.githooks') 'pre-push'
        )
        foreach ($hook in $hookFiles) {
            if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) { throw "Missing hook: $hook" }
        }
        $existing = & git -C $Path config --local --get core.hooksPath
        $code = $LASTEXITCODE
        if ($code -notin @(0, 1)) { throw 'Cannot inspect local Git hook configuration.' }
        if ($code -eq 0 -and $existing -ne '.githooks') {
            throw "Refusing to overwrite existing core.hooksPath '$existing'."
        }
        if (-not $IsWindows) {
            & chmod u+x -- @hookFiles
            if ($LASTEXITCODE -ne 0) { throw 'Could not mark Git hooks executable.' }
        }
        & git -C $Path config --local core.hooksPath .githooks
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure local Git hooks.' }
        $installed = & git -C $Path config --local --get core.hooksPath
        if ($LASTEXITCODE -ne 0 -or $installed -ne '.githooks') { throw 'Hook configuration verification failed.' }
    }
    $findings
    if ($FailOnFinding -and @($findings | Where-Object Status -In @('Fail', 'Unknown')).Count) {
        throw 'Security checks found unresolved findings or checks requiring manual verification.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RepositorySecurity @PSBoundParameters
}
