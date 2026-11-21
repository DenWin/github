# Development and helper scripts

The [README](../README.md) documents the user-facing Git features. This guide
covers contributor tooling, test scripts and repository maintenance.

Every PowerShell script has comment-based help. From the repository root, use:

```powershell
Get-Help .\Invoke-Checks.ps1 -Full
Get-Help .\Set-GitConfig.ps1 -Examples
```

Help describes parameters, Owners, outputs, prerequisites and side effects.
Run test files through Pester rather than executing them directly.

## Development environment

Use PowerShell 7 and the exact module versions pinned in
[`DevelopmentDependencies.psd1`](../DevelopmentDependencies.psd1): Pester,
PSScriptAnalyzer and powershell-yaml.

Open the repository folder in VS Code and run **Extensions: Show Recommended
Extensions** to install the recommendations in
[`.vscode/extensions.json`](../.vscode/extensions.json):

- **PowerShell** (`ms-vscode.powershell`): language support, debugging and analysis.
- **EditorConfig** (`EditorConfig.EditorConfig`): repository formatting rules.
- **YAML** (`redhat.vscode-yaml`): workflow and Dependabot validation/completion.

Recommendations do not install extensions automatically or isolate them from
other repositories. Select a dedicated VS Code profile before installing if you
want a separate extension set. PowerShell modules are installed separately.

## Installing verified dependencies

[`Install-DevelopmentDependencies.ps1`](../Install-DevelopmentDependencies.ps1)
downloads the pinned Gallery module archives, verifies SHA-512 before extracting
them, checks for the expected manifest and installs under
`<Destination>\<Module>\<Version>`. It does not import modules, modify
`PSModulePath`, or download implicit dependencies.

```powershell
# Use a fresh destination; existing module versions are not overwritten.
$modules = Join-Path $HOME 'verified-powershell-modules'
.\Install-DevelopmentDependencies.ps1 -Destination $modules
$env:PSModulePath = "$modules$([System.IO.Path]::PathSeparator)$env:PSModulePath"
```

Network, hash, manifest and filesystem failures stop installation. Temporary
downloads are cleaned up; if cleanup fails, the temporary path is reported without
replacing the installation error. Modules already installed remain installed.

## Running checks

[`Invoke-Checks.ps1`](../Invoke-Checks.ps1) imports all pinned modules and runs
the checks in three tiers. The skip switches do not skip module imports.

| Tier | Command | Runs | When |
| --- | --- | --- | --- |
| Fast | `.\Invoke-Checks.ps1` | Workflow audit, PSScriptAnalyzer, unit tests (seconds) | Every change; pre-push hook |
| Full | `.\Invoke-Checks.ps1 -Full` | Adds `Integration` tests against real Git repositories and NUnit test results | Before pushing; CI on every PR and push to `main` |
| Proof | `.\Invoke-Checks.ps1 -Full -Proof` | Adds proof that every test can fail (minutes) | Before merging and releases; CI on pushes to `main` and manual runs |

```powershell
.\Invoke-Checks.ps1 -SkipTests       # Workflow audit and script analysis only
.\Invoke-Checks.ps1 -SkipLint        # Fast tests only
.\Invoke-Checks.ps1 -Full -Coverage  # Also write TestResults/coverage.xml
```

`-SkipLint` skips **both** the workflow audit and PSScriptAnalyzer. Analyzer
findings, non-passing tests or unproven tests cause exit code 1. Audit/import
errors terminate immediately. Run in a separate `pwsh` process if an exit must
not close your shell.

[`PesterConfiguration.ps1`](../PesterConfiguration.ps1) returns a configuration;
it does not run tests itself. It enables detailed output, pass-through results,
process exit and NUnit XML written to `TestResults/testResults.xml`.

```powershell
Invoke-Pester -Configuration (.\PesterConfiguration.ps1)

# For an interactive run that must not exit the shell:
$configuration = & .\PesterConfiguration.ps1
$configuration.Run.Exit = $false
$result = Invoke-Pester -Configuration $configuration

# Run a single test file, or only its fast tests:
Invoke-Pester -Path .\Sync-GitRepositories.Tests.ps1
Invoke-Pester -Path .\Sync-GitRepositories.Tests.ps1 -ExcludeTagFilter Integration
```

### Testing principles

- **A test must be able to fail.** A passing test only means something if it
  fails when the result is wrong. Write the test before the code and watch it
  fail. For existing code, [`Invoke-TestProof.ps1`](../Invoke-TestProof.ps1)
  proves this automatically (see below).
- **Test small steps, not whole answers.** Scripts are layered into pure steps
  (parse, select, plan, format) and thin boundaries that run Git or `gh`. Each
  step is tested directly with plain input; a function that only combines
  tested steps is covered by fewer, broader tests one layer up.
- **No mocks.** Pure steps need none. Boundaries are tested against real local
  Git repositories, configuration files and module archives in Pester's
  `TestDrive`. Third-party code (Git, powershell-yaml, Pester) is used as is.
- **Coverage is not a goal.** It shows which lines ran, not whether a test
  detects a wrong result, so there is no coverage threshold. `-Coverage` writes
  a report for finding untested code; the proof is the quality gate.

### Proving tests

[`Invoke-TestProof.ps1`](../Invoke-TestProof.ps1) runs every `Describe` block
once unchanged and once per stub of its function. Each stub replaces the
function body in a temporary copy of the scripts, keeping the parameters, with
code that returns no result, a slightly wrong result, or does something the
tests forbid. Every test that passes must fail under at least one stub.

```powershell
.\Invoke-TestProof.ps1                                   # Every mapped function
pwsh -Command "& ./Invoke-TestProof.ps1 -Function Select-DirectoryName, Get-RemoteBranch"
```

A `Describe` maps to the function with the same name.
[`TestProofs.psd1`](../TestProofs.psd1) maps other `Describe` names to a
function and adds stubs per function. Tests asserting that something is **not**
done (for Owner under `-WhatIf`, or keeping a worktree) pass against a stub
that does nothing; prove them with a stub that does it anyway. The report lists
`Unproven` tests, `Uncaught` stubs, `Failed` runs and `Unmapped` blocks; all but
`Unmapped` fail the run. The working tree is never modified.

### Test script reference

| Script | Scope and isolation |
| --- | --- |
| [`GitTooling.Common.Tests.ps1`](../GitTooling.Common.Tests.ps1) | Owner and URL parsing, target resolution, worktree-list parsing and the Git wrapper against real Git. |
| [`Set-GitConfig.Tests.ps1`](../Set-GitConfig.Tests.ps1) | Identity, plan and command steps; applies global and local plans to temporary Git configuration and repositories. |
| [`Sync-GitRepositories.Tests.ps1`](../Sync-GitRepositories.Tests.ps1) | Branch selection, layout and plan steps; real local bare clones, worktrees and upstreams tagged `Integration`. |
| [`Remove-StaleGitWorktree.Tests.ps1`](../Remove-StaleGitWorktree.Tests.ps1) | Eligibility steps; real local Git fixtures tagged `Integration` for safe removal, branch preservation/deletion, URL selection and failure paths. |
| [`Install-DevelopmentDependencies.Tests.ps1`](../Install-DevelopmentDependencies.Tests.ps1) | Pin checks and installation from local ZIP fixtures, including tampering and overwrite refusal. |
| [`Invoke-RepositorySecurity.Tests.ps1`](../Invoke-RepositorySecurity.Tests.ps1) | Workflow rules on YAML parsed by powershell-yaml, remediation requests and local Git hook fixtures. |
| [`Invoke-TestProof.Tests.ps1`](../Invoke-TestProof.Tests.ps1) | Plan, stub and report steps of the proof runner. |

[`GitTooling.TestHelpers.ps1`](../GitTooling.TestHelpers.ps1) creates the shared
Git fixtures and captures host, warning and error output.

Use the pinned Pester version. Tests require PowerShell 7 and Git on PATH;
workflow parsing needs the pinned powershell-yaml module. They do not require
live GitHub access. Do not replace these fixtures with real managed repositories.

**Not covered by tests:** code that only calls GitHub or the PowerShell Gallery
(the `gh` wrapper, `gh` queries and the security remediation API, the GitHub
identity lookup, the Gallery download). Their parsing and planning steps are tested; the calls
themselves are verified manually with `-DryRun` or `-WhatIf`.
## Repository security helper

[`Invoke-RepositorySecurity.ps1`](../Invoke-RepositorySecurity.ps1) audits local
workflow files and installs opt-in hooks. [`Protect-GitHubRepository.ps1`](../Protect-GitHubRepository.ps1)
audits and hardens explicit GitHub.com repository settings. Its
parameters are:

| Parameter | Meaning |
| --- | --- |
| `-Path` | Local repository root; defaults to the script directory. |
| `-LocalOnly` | No GitHub API calls or authentication required. |
| `-Apply` | Apply supported local hook changes; never rewrites workflow YAML. Supports `-WhatIf` and `-Confirm`. |
| `-InstallHooks` | Opt into local hooks; requires `-Apply`. |
| `-FailOnFinding` | Fail on unresolved `Fail` or `Unknown` findings. |

```powershell
.\Invoke-RepositorySecurity.ps1 -LocalOnly
.\Invoke-RepositorySecurity.ps1 -LocalOnly -FailOnFinding
.\Protect-GitHubRepository.ps1 -Repository Owner/Repo |
    Format-Table Id, Severity, Status, Message -Wrap
.\Protect-GitHubRepository.ps1 -Repository Owner/Repo -Apply -WhatIf
.\Protect-GitHubRepository.ps1 -Repository Owner/Repo -Apply -Confirm
```

Live checks need authenticated `gh` with sufficient access; remediation may
require repository administration access. Findings have `Id`, `Severity`,
`Target`, `Status`, `Message` and `Fix` properties. `Fail` means a policy check
failed; `Unknown` means access, feature availability or manual review prevents
verification. Both fail `-FailOnFinding`. `Applied` means the API accepted a
change, **not** that a fresh audit verified it. Rerun after applying changes.
Errors stop remediation without rolling back earlier accepted changes.

### Audit scope and limitations

Local checks use a YAML parser to inspect action and reusable-workflow commit
pins, Docker SHA-256 digests, credential persistence, permissions, privileged
triggers, inline script expressions, self-hosted runners and job timeouts.
They intentionally flag some legitimate advanced workflows for review. They do
not parse shell semantics, inspect nested local actions, verify commit trust,
scan history for secrets or assess downloaded code. Fix local findings manually.

GitHub checks cover action-source restrictions, SHA pin enforcement, workflow
token privileges and PR approval, fork pull-request workflow approval (only
contributors new to GitHub),
Dependabot updates/alerts, secret scanning/push protection, private vulnerability
reporting and deletion of merged head branches.
`-Apply` can enable those features and restrict actions to GitHub-owned sources
plus `ossf/scorecard-action@*`, preserving disabled Actions and local-only policies.
This **replaces other third-party allowlist exceptions**; review the preview
before applying to other repositories. SHA pin enforcement remains required.
Unsupported or inaccessible features are reported, not silently treated as secure.

Dependabot security updates use the dedicated `automated-security-fixes`
endpoint. Disabled or paused updates produce a remediable finding; inaccessible
or incomplete responses remain `Unknown`.

The protection helper can set classic branch protection on the default branch:
one approving review, stale-review dismissal, last-push approval, linear history,
administrator enforcement, and prevention of force pushes and branch deletion.
Required status checks are not guessed; configure CI-specific required checks
through a ruleset or classic protection after the check names are stable.

Remaining manual GitHub review steps:

1. Open **Settings > Rules > Rulesets** (or classic **Branches** protection).
2. Apply the ruleset to the default branch and every other release branch.
3. Require pull requests, a stable set of required CI checks, signed commits
   if the organization requires them, conversation resolution, and linear history.
4. Prevent force pushes and deletions; limit the bypass list to administrators
   or a tightly controlled team and do not allow deploy keys or apps to bypass
   branch rules.
5. Open **Settings > Actions > General** and review allowed actions, forks,
   workflow approvals, artifact retention, cache retention and runner access.
6. Open **Settings > Code security** and enable code scanning, dependency review,
   Dependabot alerts/security updates and secret scanning where supported.
7. Open **Settings > Collaborators and teams**, remove unnecessary write/admin
   access, and review deploy keys, GitHub Apps and outside collaborators.
8. Review repository visibility, forks, merge methods, auto-merge, release/tag
   protection, environments, Pages publishing, Actions secrets, variables and
   environment protection rules.

Organization-wide controls such as SAML, enforced 2FA, IP allow lists, organization
rulesets and audit-log retention must be reviewed in the organization settings;
repository tooling cannot safely infer or change organization policy.

GitHub Enterprise Server must use the same repository API through an authenticated
`gh` host rather than the public `github.com` API. Before relying on automation,
configure `gh auth login --hostname <host>` and verify the Enterprise Server API
supports every endpoint used above.

For GitLab.com or self-hosted GitLab, no repository-hardening script currently
exits in this repository. Manually configure:

1. Open **Settings > Repository > Protected branches** and protect the default
   branch and release branches.
2. Allow merge only through merge requests, disallow force pushes and deletion,
   require code-owner approval where used, and set the minimum approval count.
3. Open **Settings > Merge requests** and enable pipelines-before-merge,
   all discussions resolved, removal of source branches, merge trains if needed,
   and restrictions that prevent authors/committers from approving their own work.
4. Open **Settings > CI/CD** and restrict protected variables, runners and
   environments to protected refs and responsible teams.
5. Open **Settings > General > Visibility, project features, permissions** and
   review forks, public visibility, deployments, releases and package registries.
6. Open **Security & Compliance** and enable secret detection, dependency scanning,
   SAST, container scanning and vulnerability reporting where licensed and supported.

For bare Git, Gitea, Bitbucket Server or another generic Git host, central branch
rules are host-specific. Use server-side pre-receive/update hooks or the host API
to reject force pushes and pushes outside merge-request workflows; these controls
cannot be enforced by a local `.git/config` setting alone.

### Opt-in Git hooks

```powershell
.\Invoke-RepositorySecurity.ps1 -LocalOnly -Apply -InstallHooks -WhatIf
.\Invoke-RepositorySecurity.ps1 -LocalOnly -Apply -InstallHooks
```

Pre-commit runs the local audit, lint and staged whitespace checks; pre-push runs
the fast checks. Run `.\Invoke-Checks.ps1 -Full` for the slower integration
tier, which CI runs on pull requests and pushes to `main`. Hooks inspect the
**working tree**, not an isolated staged snapshot or every pushed commit. They need development dependencies and PowerShell
on PATH. Installation refuses to overwrite a different local `core.hooksPath` and
never installs dependencies. On Unix it marks hooks executable.

Preserve executable bits when adding hooks:

```powershell
git add --chmod=+x .githooks/pre-commit .githooks/pre-push
```

Hooks can be bypassed and do not replace protected CI. To uninstall, run
`git config --local --unset core.hooksPath`.

## CI and dependency maintenance

[`ci.yml`](../.github/workflows/ci.yml) runs the small unit/lint tier on Windows
and Linux for every pull-request commit. [`ci-main.yml`](../.github/workflows/ci-main.yml)
runs the full tier on Windows and Linux for pushes to `main`, plus the proof tier
on Linux. Both workflows support manual dispatch. Jobs grant only `contents: read`,
do not persist Git credentials and limit runtime and artifact retention.

Actions are pinned to 40-character commit SHAs. Dependabot groups weekly action
updates and waits seven days after release; security updates are not delayed by
the cooldown. Review the commit and release before merging.

Scorecard runs on main pushes and weekly without publishing to the Scorecard
API. Its JSON report is a short-lived Actions artifact. The pinned action
references a container image by tag, so its image is not protected by the action
SHA pin. Restricted Actions policies need the Scorecard exception described above.
Dependency review runs on PRs and requires GitHub's dependency graph; it does not
inspect PowerShell data-file dependencies.

Dependabot does not update PowerShell Gallery modules. Periodically review new
versions, publishers, package contents, signatures and declared dependencies.
Use a trusted independent checksum or signature where available. After review:

1. Update versions in both dependency data files.
2. Record the reviewed archive's SHA-512 in
   [`DevelopmentDependencyHashes.psd1`](../DevelopmentDependencyHashes.psd1).
3. Install into a fresh destination and run all checks.
4. Pin and review any additional dependencies explicitly; do not rely on implicit
   installation.

The current pins were recorded from Gallery metadata and checked against the
downloaded archives. They detect later changes but do not independently establish
publisher identity or prove the original archive was trustworthy.

## Contributor conventions

Use approved PowerShell verbs, singular nouns, strict mode and
`$ErrorActionPreference = 'Stop'`, with explicit operation-specific error handling.
Add or change a test with each behavior change, following the
[testing principles](#testing-principles), and run the proof for the changed
functions. Keep comment-based script help current; document helper workflows
here rather than expanding the feature README. Production feature scripts guard
their entry point when dot-sourced for tests. Shared Git/gh wrappers and URL
parsing live in [`GitTooling.Common.ps1`](../GitTooling.Common.ps1). Formatting is defined by [`.editorconfig`](../.editorconfig) and
[`.gitattributes`](../.gitattributes); lint rules are in
[`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1).

See [SECURITY.md](../.github/SECURITY.md) for private reporting guidance.
