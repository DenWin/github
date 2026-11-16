#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . "$PSScriptRoot\Invoke-RepositorySecurity.ps1"

    function Write-TestWorkflow {
        param ([string] $Text)
        $directory = Join-Path (Join-Path $TestDrive '.github') 'workflows'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $directory 'ci.yml') -Value $Text
    }

    $script:safeWorkflow = @'
on: pull_request
permissions: {}
jobs:
  checks:
    permissions:
      contents: read
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - run: echo "hello"
'@
}

Describe 'Workflow hardening audit' {
    It 'accepts pinned actions, read-only permissions and credential-free checkout' {
        Write-TestWorkflow $safeWorkflow
        @(Get-WorkflowSecurityFinding -Path $TestDrive).Count | Should -Be 0
    }

    It 'reports mutable pins and default persisted checkout credentials' {
        Write-TestWorkflow ($safeWorkflow.Replace(
                'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1', 'actions/checkout@v7'
            ).Replace('persist-credentials: false', 'fetch-depth: 1'))
        $ids = @(Get-WorkflowSecurityFinding -Path $TestDrive).Id
        $ids | Should -Contain 'action.pin'
        $ids | Should -Contain 'checkout.credentials'
    }

    It 'does not mistake a 64-character string for an action commit SHA' {
        Write-TestWorkflow ($safeWorkflow.Replace(
                '3d3c42e5aac5ba805825da76410c181273ba90b1', ('a' * 64)
            ))
        @(Get-WorkflowSecurityFinding -Path $TestDrive).Id | Should -Contain 'action.pin'
    }

    It 'flags privileged triggers, write tokens and inline expressions' {
        Write-TestWorkflow ($safeWorkflow.Replace(
                'on: pull_request', 'on: pull_request_target'
            ).Replace('contents: read', 'contents: write').Replace(
                'echo "hello"', 'echo "${{ github.event.pull_request.title }}"'
            ))
        $ids = @(Get-WorkflowSecurityFinding -Path $TestDrive).Id
        $ids | Should -Contain 'workflow.privileged-trigger'
        $ids | Should -Contain 'job.permissions'
        $ids | Should -Contain 'step.expression'
    }

    It 'requires explicit workflow permissions and a bounded timeout' {
        Write-TestWorkflow ($safeWorkflow.Replace('permissions: {}', '').Replace('timeout-minutes: 15', 'timeout-minutes: 360'))
        $ids = @(Get-WorkflowSecurityFinding -Path $TestDrive).Id
        $ids | Should -Contain 'workflow.permissions'
        $ids | Should -Contain 'job.timeout'
    }

    It 'checks reusable workflows and container digests' {
        Write-TestWorkflow @'
on: pull_request
permissions: {}
jobs:
  reusable:
    uses: owner/repo/.github/workflows/test.yml@main
  container:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: docker://alpine:latest
'@
        $ids = @(Get-WorkflowSecurityFinding -Path $TestDrive).Id
        $ids | Should -Contain 'workflow.pin'
        $ids | Should -Contain 'action.pin'
    }

    It 'fails visibly on malformed YAML rather than passing the audit' {
        Write-TestWorkflow 'jobs: ['
        { Get-WorkflowSecurityFinding -Path $TestDrive } | Should -Throw
    }
}

Describe 'Remediation trust boundary' {
    BeforeEach {
        Mock Get-WorkflowSecurityFinding { }
        Mock Get-GitHubSecurityFinding {
            New-SecurityFinding 'github.workflow-token' 'Medium' 'owner/repo' 'Restrict tokens.' -Fix @{
                Endpoint = 'repos/owner/repo/actions/permissions/workflow'
                Method = 'PUT'
                Body = @{ default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false }
            }
        }
        Mock Invoke-SecurityApi { [pscustomobject]@{ Success = $true; Data = $null; Error = $null } }
    }

    It 'does not mutate GitHub in audit mode' {
        $result = Invoke-RepositorySecurity -Path $TestDrive -Repository owner/repo
        $result.Status | Should -Be 'Fail'
        Should -Invoke Invoke-SecurityApi -Times 0 -Exactly
    }

    It 'does not mutate GitHub with -Apply -WhatIf' {
        $null = Invoke-RepositorySecurity -Path $TestDrive -Repository owner/repo -Apply -WhatIf
        Should -Invoke Invoke-SecurityApi -Times 0 -Exactly
    }

    It 'applies only the explicit finding remediation' {
        $result = Invoke-RepositorySecurity -Path $TestDrive -Repository owner/repo -Apply -Confirm:$false
        $result.Status | Should -Be 'Applied'
        Should -Invoke Invoke-SecurityApi -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and $Endpoint -eq 'repos/owner/repo/actions/permissions/workflow' -and
            $Body.default_workflow_permissions -eq 'read' -and -not $Body.can_approve_pull_request_reviews
        }
    }

    It 'surfaces remediation failure instead of reporting success' {
        Mock Invoke-SecurityApi { [pscustomobject]@{ Success = $false; Data = $null; Error = 'Forbidden' } }
        { Invoke-RepositorySecurity -Path $TestDrive -Repository owner/repo -Apply -Confirm:$false } |
            Should -Throw '*Remediation failed*Forbidden*'
    }

    It 'never guesses the GitHub target' {
        { Invoke-RepositorySecurity -Path $TestDrive } | Should -Throw '*Specify -Repository*'
    }

    It 'requires -Apply before hook installation' {
        { Invoke-RepositorySecurity -Path $TestDrive -LocalOnly -InstallHooks } | Should -Throw '*requires -Apply*'
    }

    It 'fails enforcement on unknown or failed checks' {
        { Invoke-RepositorySecurity -Path $TestDrive -Repository owner/repo -FailOnFinding } |
            Should -Throw '*unresolved findings*'
    }

    It 'keeps local-only checks offline' {
        Invoke-RepositorySecurity -Path $TestDrive -LocalOnly
        Should -Invoke Get-GitHubSecurityFinding -Times 0 -Exactly
    }
}

Describe 'Unavailable GitHub API checks' {
    It 'reports inaccessible settings as Unknown without automatic permission escalation' {
        Mock Invoke-SecurityApi { [pscustomobject]@{ Success = $false; Data = $null; Error = 'HTTP 403' } }
        $findings = @(Get-GitHubSecurityFinding -Repository owner/repo)
        $findings.Count | Should -BeGreaterThan 0
        @($findings | Where-Object Status -NE 'Unknown').Count | Should -Be 0
        ($findings | Where-Object Id -EQ 'github.workflow-token').Fix | Should -BeNullOrEmpty
    }

    It 'reports unsupported security feature fields as Unknown, not a pass or a writable fix' {
        Mock Invoke-SecurityApi {
            [pscustomobject]@{ Success = $true; Data = @{ default_branch = 'main' }; Error = $null }
        }
        $findings = @(Get-GitHubSecurityFinding -Repository owner/repo)
        $finding = $findings | Where-Object Id -EQ 'github.secret-scanning'
        $finding.Status | Should -Be 'Unknown'
        $finding.Fix | Should -BeNullOrEmpty
    }

    It 'reports empty API responses as Unknown instead of constructing writable defaults' {
        Mock Invoke-SecurityApi {
            [pscustomobject]@{ Success = $true; Data = $null; Error = $null }
        }
        $finding = @(Get-GitHubSecurityFinding -Repository owner/repo) |
            Where-Object Id -EQ 'github.actions-policy'
        $finding.Status | Should -Be 'Unknown'
        $finding.Fix | Should -BeNullOrEmpty
    }

    It 'preserves disabled Actions when planning stricter action permissions' {
        Mock Invoke-SecurityApi {
            param ($Endpoint)
            if ($Endpoint -like '*/actions/permissions') {
                return [pscustomobject]@{
                    Success = $true
                    Data = @{ enabled = $false; allowed_actions = 'all'; sha_pinning_required = $false }
                    Error = $null
                }
            }
            [pscustomobject]@{ Success = $false; Data = $null; Error = 'HTTP 403' }
        }
        $findings = @(Get-GitHubSecurityFinding -Repository owner/repo)
        ($findings | Where-Object Id -EQ 'github.actions-policy').Fix.Body.enabled | Should -BeFalse
        ($findings | Where-Object Id -EQ 'github.action-sources').Status | Should -Be 'Fail'
    }
}

Describe 'Dependabot security updates status' {
    BeforeEach {
        Mock Get-WorkflowSecurityFinding { }
        $script:dependabotState = @{ enabled = $true; paused = $false }
        $script:securityWrites = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-SecurityApi {
            param ($Endpoint, $Method)
            if ($Method -and $Method -ne 'GET') {
                $securityWrites.Add("$Method $Endpoint")
                return [pscustomobject]@{ Success = $true; Data = $null; Error = $null }
            }
            if ($Endpoint -eq 'repos/owner/repo/automated-security-fixes') {
                return [pscustomobject]@{ Success = $true; Data = $dependabotState; Error = $null }
            }
            [pscustomobject]@{ Success = $false; Data = $null; Error = 'HTTP 403' }
        }
    }

    It 'accepts enabled and unpaused security updates from the dedicated endpoint' {
        $findings = @(Get-GitHubSecurityFinding -Repository owner/repo)
        $findings.Id | Should -Not -Contain 'github.dependabot'
        Should -Invoke Invoke-SecurityApi -Times 1 -Exactly -ParameterFilter {
            $Endpoint -eq 'repos/owner/repo/automated-security-fixes' -and (-not $Method -or $Method -eq 'GET')
        }
    }

    It 'offers remediation when security updates are <State>' -ForEach @(
        @{ State = 'disabled'; Enabled = $false; Paused = $false }
        @{ State = 'paused'; Enabled = $true; Paused = $true }
    ) {
        $script:dependabotState = @{ enabled = $Enabled; paused = $Paused }
        $finding = Get-GitHubSecurityFinding -Repository owner/repo | Where-Object Id -EQ 'github.dependabot'
        $finding.Status | Should -Be 'Fail'
        $finding.Fix.Endpoint | Should -Be 'repos/owner/repo/automated-security-fixes'
        $finding.Fix.Method | Should -Be 'PUT'
        $securityWrites.Count | Should -Be 0
    }

    It 'reports missing status fields as unknown without offering a fix' {
        $script:dependabotState = @{ enabled = $true }
        $finding = Get-GitHubSecurityFinding -Repository owner/repo | Where-Object Id -EQ 'github.dependabot'
        $finding.Status | Should -Be 'Unknown'
        $finding.Fix | Should -BeNullOrEmpty
    }

    It 'enables alerts before applying the security updates remediation' {
        $script:dependabotState = @{ enabled = $false; paused = $false }
        $findings = @(Invoke-RepositorySecurity -Repository owner/repo -Apply -Confirm:$false)
        ($findings | Where-Object Id -EQ 'github.dependabot').Status | Should -Be 'Applied'
        @($securityWrites) | Should -Be @(
            'PUT repos/owner/repo/vulnerability-alerts'
            'PUT repos/owner/repo/automated-security-fixes'
        )
    }
}

Describe 'Opt-in local hooks' {
    BeforeEach {
        Mock Get-WorkflowSecurityFinding { }
        $script:hookRepository = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = & git init --quiet $hookRepository
        if ($LASTEXITCODE -ne 0) { throw 'Test repository initialization failed.' }
        New-Item -ItemType Directory -Path (Join-Path $hookRepository '.githooks') | Out-Null
        foreach ($hook in @('pre-commit', 'pre-push')) {
            Set-Content -LiteralPath (Join-Path (Join-Path $hookRepository '.githooks') $hook) -Value "#!/bin/sh`nexit 0"
        }
    }

    It 'does not install hooks under -WhatIf' {
        Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks -WhatIf
        & git -C $hookRepository config --local --get core.hooksPath
        $LASTEXITCODE | Should -Be 1
    }

    It 'installs hooks only in the target repository configuration' {
        Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks -Confirm:$false
        & git -C $hookRepository config --local --get core.hooksPath | Should -Be '.githooks'
        $LASTEXITCODE | Should -Be 0
    }

    It 'refuses to overwrite a different hooks manager' {
        & git -C $hookRepository config --local core.hooksPath existing-hooks
        { Invoke-RepositorySecurity -Path $hookRepository -LocalOnly -Apply -InstallHooks -Confirm:$false } |
            Should -Throw '*Refusing to overwrite*'
        & git -C $hookRepository config --local --get core.hooksPath | Should -Be 'existing-hooks'
    }
}
