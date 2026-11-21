#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# No mocks: pure steps receive plain data, YAML is parsed by the real
# powershell-yaml module, and hook installation runs against real Git.
# The gh-backed composition (Get-GitHubSecurityFinding, the remediation apply
# loop) is deliberately not unit-tested; its decisions live in the steps below.

BeforeAll {
    . "$PSScriptRoot\Invoke-RepositorySecurity.ps1"
    $dependencies = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevelopmentDependencies.psd1')
    Import-Module powershell-yaml -RequiredVersion $dependencies['powershell-yaml'] -ErrorAction Stop

    function New-ApiResponse {
        param ($Data, [string] $ErrorText)
        [pscustomobject]@{ Success = -not $ErrorText; Data = $Data; Error = $ErrorText }
    }

    function Get-WorkflowFindingId {
        param ([string] $Yaml)
        @(Get-WorkflowFinding -Workflow (ConvertFrom-Yaml $Yaml) -Name 'ci.yml' | ForEach-Object Id)
    }

    $script:pin = '3d3c42e5aac5ba805825da76410c181273ba90b1'
    $script:safeWorkflow = @"
on: pull_request
permissions: {}
jobs:
  checks:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@$pin
        with:
          persist-credentials: false
      - run: echo "hello"
"@
}

Describe 'Resolve-SecurityTarget' {
    It 'returns owner/name for <Repository>' -ForEach @(
        @{ Repository = 'example/github' }
        @{ Repository = 'https://github.com/example/github' }
        @{ Repository = 'https://github.com/example/github/' }
        @{ Repository = 'https://github.com/example/github/tree/feature/git-workflow-tooling' }
    ) {
        Resolve-SecurityTarget -Repository $Repository | Should -BeExactly 'example/github'
    }

    It 'rejects an owner-only URL instead of guessing a repository' {
        { Resolve-SecurityTarget -Repository 'https://github.com/example' } |
            Should -Throw '*names only an owner*'
    }
}

Describe 'Test-ReadOnlyPermission' {
    It 'returns <Expected> for <Name>' -ForEach @(
        @{ Name = 'read-all'; Permission = 'read-all'; Expected = $true }
        @{ Name = 'write-all'; Permission = 'write-all'; Expected = $false }
        @{ Name = 'an absent block'; Permission = $null; Expected = $false }
        @{ Name = 'an empty map'; Permission = @{}; Expected = $true }
        @{ Name = 'read and none scopes'; Permission = @{ contents = 'read'; packages = 'none' }; Expected = $true }
        @{ Name = 'a write scope'; Permission = @{ contents = 'read'; issues = 'write' }; Expected = $false }
    ) {
        Test-ReadOnlyPermission $Permission | Should -BeExactly $Expected
    }
}

Describe 'Get-StepFinding' {
    It 'returns nothing for a pinned checkout without persisted credentials' {
        $step = @{ uses = "actions/checkout@$pin"; with = @{ 'persist-credentials' = $false } }
        @(Get-StepFinding -Step $step -Target 't').Count | Should -Be 0
    }

    It 'reports <Id> for <Name>' -ForEach @(
        @{ Name = 'a tag pin'; Step = @{ uses = 'owner/action@v4' }; Id = 'action.pin' }
        @{ Name = 'a 64-character pin'; Step = @{ uses = "owner/action@$('a' * 64)" }; Id = 'action.pin' }
        @{ Name = 'an undigested container'; Step = @{ uses = 'docker://alpine:3' }; Id = 'action.pin' }
        @{ Name = 'an inline expression'; Step = @{ run = 'echo "${{ github.head_ref }}"' }; Id = 'step.expression' }
        @{ Name = 'checkout without with'; Step = @{ uses = "actions/checkout@$('b' * 40)" }; Id = 'checkout.credentials' }
        @{ Name = 'checkout with other options'; Step = @{ uses = "actions/checkout@$('b' * 40)"; with = @{ 'fetch-depth' = 1 } }; Id = 'checkout.credentials' }
    ) {
        @(Get-StepFinding -Step $Step -Target 'ci.yml:job').Id | Should -BeExactly @($Id)
    }

    It 'accepts a container pinned to a SHA-256 digest and local actions' {
        @(Get-StepFinding -Step @{ uses = "docker://alpine@sha256:$('c' * 64)" } -Target 't').Count | Should -Be 0
        @(Get-StepFinding -Step @{ uses = './local-action' } -Target 't').Count | Should -Be 0
    }

    It 'reports the finding against the given target' {
        (Get-StepFinding -Step @{ uses = 'owner/action@v4' } -Target 'ci.yml:build').Target |
            Should -BeExactly 'ci.yml:build'
    }
}

Describe 'Get-JobFinding' {
    BeforeEach {
        $script:job = @{ 'runs-on' = 'ubuntu-latest'; 'timeout-minutes' = 15; steps = @() }
    }

    It 'returns nothing for a bounded hosted job without steps' {
        @(Get-JobFinding -Job $job -Target 't').Count | Should -Be 0
    }

    It 'reports a timeout of <Timeout>' -ForEach @(
        @{ Timeout = 0 }, @{ Timeout = 31 }, @{ Timeout = '15' }
    ) {
        $job['timeout-minutes'] = $Timeout
        @(Get-JobFinding -Job $job -Target 't').Id | Should -BeExactly @('job.timeout')
    }

    It 'reports a missing timeout' {
        $job.Remove('timeout-minutes')
        @(Get-JobFinding -Job $job -Target 't').Id | Should -BeExactly @('job.timeout')
    }

    It 'reports self-hosted runners, also inside a label list' {
        $job['runs-on'] = @('self-hosted', 'linux')
        @(Get-JobFinding -Job $job -Target 't').Id | Should -BeExactly @('job.runner')
    }

    It 'reports write permissions' {
        $job['permissions'] = @{ contents = 'write' }
        @(Get-JobFinding -Job $job -Target 't').Id | Should -BeExactly @('job.permissions')
    }

    It 'passes its target to step findings' {
        $job['steps'] = @(@{ uses = 'owner/action@v4' })
        $finding = Get-JobFinding -Job $job -Target 'ci.yml:build'
        $finding.Id | Should -BeExactly 'action.pin'
        $finding.Target | Should -BeExactly 'ci.yml:build'
    }

    It 'checks only the pin of a reusable workflow, not timeout or runner' {
        $reusable = @{ uses = 'owner/repo/.github/workflows/w.yml@main' }
        @(Get-JobFinding -Job $reusable -Target 't').Id | Should -BeExactly @('workflow.pin')
        @(Get-JobFinding -Job @{ uses = "owner/repo/.github/workflows/w.yml@$pin" } -Target 't').Count | Should -Be 0
    }
}

Describe 'Get-WorkflowFinding' {
    It 'returns nothing for the safe workflow' {
        @(Get-WorkflowFindingId $safeWorkflow).Count | Should -Be 0
    }

    It 'reports <Id> for <Name>' -ForEach @(
        @{ Name = 'missing permissions'; From = 'permissions: {}'; To = ''; Id = 'workflow.permissions' }
        @{ Name = 'pull_request_target'; From = 'on: pull_request'; To = 'on: pull_request_target'; Id = 'workflow.privileged-trigger' }
        @{ Name = 'workflow_run in a map'; From = 'on: pull_request'; To = "on:`n  workflow_run:`n    workflows: [ci]"; Id = 'workflow.privileged-trigger' }
    ) {
        Get-WorkflowFindingId ($safeWorkflow.Replace($From, $To)) | Should -BeExactly @($Id)
    }

    It 'names each job finding after the workflow and job' {
        $yaml = $safeWorkflow.Replace('timeout-minutes: 15', 'timeout-minutes: 60')
        (Get-WorkflowFinding -Workflow (ConvertFrom-Yaml $yaml) -Name 'ci.yml').Target | Should -BeExactly 'ci.yml:checks'
    }

    It 'rejects a document without a jobs map as <Name>' -ForEach @(
        @{ Name = 'a scalar'; Workflow = 'text' }
        @{ Name = 'a map without jobs'; Workflow = @{ on = 'push' } }
    ) {
        { Get-WorkflowFinding -Workflow $Workflow -Name 'bad.yml' } | Should -Throw 'Invalid workflow structure: bad.yml'
    }
}

Describe 'Get-WorkflowSecurityFinding' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive "repo-$([guid]::NewGuid().ToString('N'))"
        $script:workflowDirectory = Join-Path (Join-Path $directory '.github') 'workflows'
        New-Item -ItemType Directory -Path $workflowDirectory -Force | Out-Null
    }

    It 'reads .yml and .yaml files and ignores other files' {
        $unsafe = $safeWorkflow.Replace('timeout-minutes: 15', 'timeout-minutes: 60')
        Set-Content -LiteralPath (Join-Path $workflowDirectory 'a.yml') -Value $unsafe
        Set-Content -LiteralPath (Join-Path $workflowDirectory 'b.yaml') -Value $unsafe
        Set-Content -LiteralPath (Join-Path $workflowDirectory 'c.txt') -Value $unsafe
        @(Get-WorkflowSecurityFinding -Path $directory).Target | Should -BeExactly @('a.yml:checks', 'b.yaml:checks')
    }

    It 'reports a missing workflow directory' {
        Remove-Item -LiteralPath $workflowDirectory
        @(Get-WorkflowSecurityFinding -Path $directory).Id | Should -BeExactly @('workflow.missing')
    }

    It 'fails visibly on malformed YAML rather than passing the audit' {
        Set-Content -LiteralPath (Join-Path $workflowDirectory 'ci.yml') -Value "jobs: [unterminated"
        { Get-WorkflowSecurityFinding -Path $directory } | Should -Throw
    }
}

Describe 'Get-ActionPolicyData' {
    It 'returns the data of a successful response with enabled and allowed_actions' {
        $data = @{ enabled = $true; allowed_actions = 'selected' }
        Get-ActionPolicyData -Response (New-ApiResponse $data) | Should -Be $data
    }

    It 'returns null for <Name>' -ForEach @(
        @{ Name = 'no response'; Response = $null }
        @{ Name = 'a failed response'; Response = [pscustomobject]@{ Success = $false; Data = $null; Error = 'HTTP 403' } }
        @{ Name = 'an empty response'; Response = [pscustomobject]@{ Success = $true; Data = $null; Error = $null } }
        @{ Name = 'missing allowed_actions'; Response = [pscustomobject]@{ Success = $true; Data = @{ enabled = $true }; Error = $null } }
    ) {
        Get-ActionPolicyData -Response $Response | Should -BeNullOrEmpty
    }
}

Describe 'Get-GitHubSecurityCheck' {
    BeforeAll {
        function Get-Check {
            param ([string] $Id, $ActionPolicy)
            Get-GitHubSecurityCheck -Repository 'o/r' -ActionPolicy $ActionPolicy | Where-Object { $_.Id -eq $Id }
        }
    }

    It 'targets the given repository' {
        (Get-Check 'github.workflow-token').Endpoint | Should -BeExactly 'repos/o/r/actions/permissions/workflow'
    }

    It 'plans the actions policy as <Expected> for <Name>' -ForEach @(
        @{ Name = 'an unknown policy'; Policy = $null; Expected = @{ enabled = $false; allowed_actions = 'selected' } }
        @{ Name = 'disabled Actions'; Policy = @{ enabled = $false; allowed_actions = 'all' }; Expected = @{ enabled = $false; allowed_actions = 'selected' } }
        @{ Name = 'enabled Actions'; Policy = @{ enabled = $true; allowed_actions = 'all' }; Expected = @{ enabled = $true; allowed_actions = 'selected' } }
        @{ Name = 'a local-only policy'; Policy = @{ enabled = $true; allowed_actions = 'local_only' }; Expected = @{ enabled = $true; allowed_actions = 'local_only' } }
    ) {
        $body = (Get-Check 'github.actions-policy' $Policy).Fix.Body
        $body['enabled'] | Should -BeExactly $Expected.enabled
        $body['allowed_actions'] | Should -BeExactly $Expected.allowed_actions
        $body['sha_pinning_required'] | Should -BeTrue
    }

    It '<Id> test returns <Expected> for <Name>' -ForEach @(
        @{ Id = 'github.workflow-token'; Name = 'read-only without approval'; Expected = $true; Data = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false } }
        @{ Id = 'github.workflow-token'; Name = 'read-only with approval'; Expected = $false; Data = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $true } }
        @{ Id = 'github.workflow-token'; Name = 'write token'; Expected = $false; Data = @{ default_workflow_permissions = 'write'; can_approve_pull_request_reviews = $false } }
        @{ Id = 'github.action-sources'; Name = 'only the Scorecard exception'; Expected = $true; Data = @{ github_owned_allowed = $true; verified_allowed = $false; patterns_allowed = @('ossf/scorecard-action@*') } }
        @{ Id = 'github.action-sources'; Name = 'an extra pattern'; Expected = $false; Data = @{ github_owned_allowed = $true; verified_allowed = $false; patterns_allowed = @('ossf/scorecard-action@*', 'x/y@*') } }
        @{ Id = 'github.action-sources'; Name = 'verified creators allowed'; Expected = $false; Data = @{ github_owned_allowed = $true; verified_allowed = $true; patterns_allowed = @('ossf/scorecard-action@*') } }
        @{ Id = 'github.dependabot'; Name = 'enabled and unpaused'; Expected = $true; Data = @{ enabled = $true; paused = $false } }
        @{ Id = 'github.dependabot'; Name = 'paused'; Expected = $false; Data = @{ enabled = $true; paused = $true } }
        @{ Id = 'github.dependabot'; Name = 'disabled'; Expected = $false; Data = @{ enabled = $false; paused = $false } }
        @{ Id = 'github.delete-merged-branches'; Name = 'enabled'; Expected = $true; Data = @{ delete_branch_on_merge = $true } }
        @{ Id = 'github.delete-merged-branches'; Name = 'disabled'; Expected = $false; Data = @{ delete_branch_on_merge = $false } }
        @{ Id = 'github.actions-policy'; Name = 'selected with pins'; Expected = $true; Data = @{ allowed_actions = 'selected'; sha_pinning_required = $true } }
        @{ Id = 'github.actions-policy'; Name = 'all actions'; Expected = $false; Data = @{ allowed_actions = 'all'; sha_pinning_required = $true } }
    ) {
        & (Get-Check $Id).Test $Data | Should -BeExactly $Expected
    }
}

Describe 'Get-ActionSourceDecision' {
    It 'returns <Expected> for <Name>' -ForEach @(
        @{ Name = 'an unknown policy'; Policy = $null; Expected = 'Query' }
        @{ Name = 'selected actions'; Policy = @{ allowed_actions = 'selected' }; Expected = 'Query' }
        @{ Name = 'local-only actions'; Policy = @{ allowed_actions = 'local_only' }; Expected = 'Skip' }
        @{ Name = 'all actions'; Policy = @{ allowed_actions = 'all' }; Expected = 'Fail' }
    ) {
        Get-ActionSourceDecision -ActionPolicy $Policy | Should -BeExactly $Expected
    }
}

Describe 'Get-MissingSettingKey' {
    It 'returns only the absent dotted keys' {
        $data = @{ a = @{ b = 1 }; c = $null }
        @(Get-MissingSettingKey -Data $data -Key @('a.b', 'a.x', 'c', 'c.d', 'z')) |
            Should -BeExactly @('a.x', 'c.d', 'z')
    }

    It 'returns every key for missing data' {
        @(Get-MissingSettingKey -Data $null -Key @('a', 'b')) | Should -BeExactly @('a', 'b')
    }
}

Describe 'Get-SettingFinding' {
    BeforeAll {
        $script:check = @{
            Id = 'x.check'; Message = 'Fix it.'; Required = @('on')
            Test = { param ($data) $data['on'] -eq $true }
            Fix = @{ Endpoint = 'repos/o/r/x'; Method = 'PUT' }
        }
    }

    It 'returns nothing when the setting passes' {
        Get-SettingFinding -Check $check -Response (New-ApiResponse @{ on = $true }) -Repository 'o/r' | Should -BeNullOrEmpty
    }

    It 'returns a failing finding with the fix when the setting fails' {
        $finding = Get-SettingFinding -Check $check -Response (New-ApiResponse @{ on = $false }) -Repository 'o/r'
        $finding.Status | Should -BeExactly 'Fail'
        $finding.Fix | Should -Be $check.Fix
    }

    It 'returns Unknown without a fix for <Name>' -ForEach @(
        @{ Name = 'an inaccessible setting'; Data = $null; ErrorText = 'HTTP 403'; Message = '*API check unavailable: HTTP 403' }
        @{ Name = 'an unsupported setting'; Data = @{ other = 1 }; ErrorText = $null; Message = 'Unavailable or unsupported settings: on' }
        @{ Name = 'an empty response'; Data = $null; ErrorText = $null; Message = 'Unavailable or unsupported settings: on' }
    ) {
        $finding = Get-SettingFinding -Check $check -Response (New-ApiResponse $Data $ErrorText) -Repository 'o/r'
        $finding.Status | Should -BeExactly 'Unknown'
        $finding.Fix | Should -BeNullOrEmpty
        $finding.Message | Should -BeLike $Message
    }
}

Describe 'Get-AlertFinding' {
    It 'returns nothing when alerts are enabled' {
        Get-AlertFinding -Response (New-ApiResponse $null) -Repository 'o/r' | Should -BeNullOrEmpty
    }

    It 'offers to enable alerts when GitHub reports them disabled' {
        $finding = Get-AlertFinding -Response (New-ApiResponse $null 'HTTP 404: Vulnerability alerts are disabled.') -Repository 'o/r'
        $finding.Status | Should -BeExactly 'Fail'
        $finding.Fix.Endpoint | Should -BeExactly 'repos/o/r/vulnerability-alerts'
    }

    It 'reports a generic failure as Unknown without a fix' {
        $finding = Get-AlertFinding -Response (New-ApiResponse $null 'HTTP 404: Not Found') -Repository 'o/r'
        $finding.Status | Should -BeExactly 'Unknown'
        $finding.Fix | Should -BeNullOrEmpty
    }
}

Describe 'Get-DefaultBranchName' {
    It 'returns the default branch' {
        Get-DefaultBranchName -Response (New-ApiResponse @{ default_branch = 'main' }) | Should -BeExactly 'main'
    }

    It 'returns null for <Name>' -ForEach @(
        @{ Name = 'a failed response'; Data = $null; ErrorText = 'HTTP 404' }
        @{ Name = 'a blank branch'; Data = @{ default_branch = ' ' }; ErrorText = $null }
        @{ Name = 'a missing branch'; Data = @{}; ErrorText = $null }
    ) {
        Get-DefaultBranchName -Response (New-ApiResponse $Data $ErrorText) | Should -BeNullOrEmpty
    }
}

Describe 'Get-BranchProtectionFinding' {
    BeforeAll {
        $script:metadata = New-ApiResponse @{ default_branch = 'main' }
    }

    It 'is always Unknown and asks for manual review' {
        $finding = Get-BranchProtectionFinding -Repository 'o/r' -Metadata $metadata -Legacy (New-ApiResponse @{}) -Rules (New-ApiResponse @(@{ type = 'x' }))
        $finding.Status | Should -BeExactly 'Unknown'
        $finding.Message | Should -BeLike 'Manually verify*'
    }

    It 'says when neither classic protection nor rulesets are found' {
        $finding = Get-BranchProtectionFinding -Repository 'o/r' -Metadata $metadata -Legacy (New-ApiResponse $null 'HTTP 404') -Rules (New-ApiResponse @())
        $finding.Message | Should -BeLike 'No active ruleset rules found*'
    }

    It 'reports <Expected> when metadata is <Name>' -ForEach @(
        @{ Name = 'unavailable'; Metadata = [pscustomobject]@{ Success = $false; Data = $null; Error = 'HTTP 403' }; Expected = 'HTTP 403' }
        @{ Name = 'without a default branch'; Metadata = [pscustomobject]@{ Success = $true; Data = @{}; Error = $null }; Expected = 'Default branch unavailable.' }
    ) {
        (Get-BranchProtectionFinding -Repository 'o/r' -Metadata $Metadata).Message | Should -BeExactly $Expected
    }
}

Describe 'Get-RemediationRequest' {
    It 'returns nothing for a finding without a fix' {
        $finding = New-SecurityFinding 'x' 'Medium' 'o/r' 'm' 'Unknown'
        @(Get-RemediationRequest -Finding $finding -Repository 'o/r').Count | Should -Be 0
    }

    It 'returns only the fix of an ordinary finding' {
        $fix = @{ Endpoint = 'repos/o/r'; Method = 'PATCH' }
        @(Get-RemediationRequest -Finding (New-SecurityFinding 'github.delete-merged-branches' 'Medium' 'o/r' 'm' -Fix $fix) -Repository 'o/r') |
            Should -Be @($fix)
    }

    It 'enables vulnerability alerts before Dependabot security updates' {
        $fix = @{ Endpoint = 'repos/o/r/automated-security-fixes'; Method = 'PUT' }
        $requests = @(Get-RemediationRequest -Finding (New-SecurityFinding 'github.dependabot' 'Medium' 'o/r' 'm' -Fix $fix) -Repository 'o/r')
        $requests.Endpoint | Should -BeExactly @('repos/o/r/vulnerability-alerts', 'repos/o/r/automated-security-fixes')
    }
}

Describe 'Invoke-RepositorySecurity' {
    BeforeAll {
        $script:localRepository = Join-Path $TestDrive 'local'
        $workflows = Join-Path (Join-Path $localRepository '.github') 'workflows'
        New-Item -ItemType Directory -Path $workflows -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $workflows 'ci.yml') -Value $safeWorkflow
    }

    It 'never guesses the GitHub target' {
        { Invoke-RepositorySecurity -Path $localRepository } | Should -Throw '*never guessed*'
    }

    It 'requires -Apply before hook installation' {
        { Invoke-RepositorySecurity -Path $localRepository -LocalOnly -InstallHooks } | Should -Throw '*requires -Apply*'
    }

    It 'rejects an owner-only target before any audit' {
        { Invoke-RepositorySecurity -Path $localRepository -Repository 'https://github.com/example' } |
            Should -Throw '*names only an owner*'
    }

    It 'audits local workflows offline with -LocalOnly' {
        @(Invoke-RepositorySecurity -Path $localRepository -LocalOnly).Count | Should -Be 0
    }

    It 'fails enforcement on a local finding only with -FailOnFinding' {
        $unsafe = Join-Path $TestDrive 'unsafe'
        $workflows = Join-Path (Join-Path $unsafe '.github') 'workflows'
        New-Item -ItemType Directory -Path $workflows -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $workflows 'ci.yml') -Value $safeWorkflow.Replace('timeout-minutes: 15', 'timeout-minutes: 60')

        @(Invoke-RepositorySecurity -Path $unsafe -LocalOnly).Id | Should -BeExactly @('job.timeout')
        { Invoke-RepositorySecurity -Path $unsafe -LocalOnly -FailOnFinding } | Should -Throw '*unresolved findings*'
    }
}

Describe 'Opt-in local hooks' -Tag 'Integration' {
    BeforeEach {
        $script:hookRepository = Join-Path $TestDrive "hooks-$([guid]::NewGuid().ToString('N'))"
        Invoke-Git -Arguments @('init', '--quiet', $hookRepository)
        $workflows = Join-Path (Join-Path $hookRepository '.github') 'workflows'
        New-Item -ItemType Directory -Path $workflows -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $workflows 'ci.yml') -Value $safeWorkflow
        New-Item -ItemType Directory -Path (Join-Path $hookRepository '.githooks') | Out-Null
        foreach ($hook in 'pre-commit', 'pre-push') {
            Set-Content -LiteralPath (Join-Path (Join-Path $hookRepository '.githooks') $hook) -Value "#!/bin/sh`nexit 0"
        }

        function Get-HooksPath {
            Invoke-Git -AllowFailure -Arguments @('-C', $hookRepository, 'config', '--local', '--get', 'core.hooksPath')
        }
    }

    It 'does not install hooks under -WhatIf' {
        Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks -WhatIf
        Get-HooksPath | Should -BeNullOrEmpty
    }

    It 'installs hooks only in the target repository configuration' {
        Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks
        Get-HooksPath | Should -BeExactly '.githooks'
    }

    It 'is idempotent when the hooks are already installed' {
        Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks
        { Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks } | Should -Not -Throw
    }

    It 'refuses to overwrite a different hooks manager' {
        Invoke-Git -Arguments @('-C', $hookRepository, 'config', '--local', 'core.hooksPath', 'existing-hooks')
        { Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks } |
            Should -Throw "*overwrite existing core.hooksPath 'existing-hooks'*"
        Get-HooksPath | Should -BeExactly 'existing-hooks'
    }

    It 'refuses to install when a hook file is missing' {
        Remove-Item -LiteralPath (Join-Path (Join-Path $hookRepository '.githooks') 'pre-push')
        { Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks } | Should -Throw '*Missing hook*'
        Get-HooksPath | Should -BeNullOrEmpty
    }
}
