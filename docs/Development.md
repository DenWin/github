# Development and helper scripts

The [README](../README.md) documents the user-facing Git features. This guide
covers contributor tooling, test scripts and repository maintenance.

Every PowerShell script has comment-based help. From the repository root, use:

```powershell
Get-Help .\Invoke-Checks.ps1 -Full
Get-Help .\Set-GitGlobalConfig.ps1 -Examples
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
| [`Set-GitGlobalConfig.Tests.ps1`](../Set-GitGlobalConfig.Tests.ps1) | Identity, plan and command steps; applies the plan to temporary `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` files, never your configuration. |
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
workflow files and, optionally, explicit GitHub.com repository settings. Its
parameters are:

| Parameter | Meaning |
| --- | --- |
| `-Path` | Local repository root; defaults to the script directory. |
| `-Repository` | Explicit GitHub target as `owner/name` or a repository or branch URL (the branch is ignored); required unless `-LocalOnly` is used. Never inferred from local remotes. |
| `-LocalOnly` | No GitHub API calls or authentication required. |
| `-Apply` | Apply supported GitHub remediations; never rewrites workflow YAML. Supports `-WhatIf` and `-Confirm`. |
| `-InstallHooks` | Opt into local hooks; requires `-Apply`. |
| `-FailOnFinding` | Fail on unresolved `Fail` or `Unknown` findings. |

```powershell
.\Invoke-RepositorySecurity.ps1 -LocalOnly
.\Invoke-RepositorySecurity.ps1 -LocalOnly -FailOnFinding
.\Invoke-RepositorySecurity.ps1 -Repository Owner/Repo |
    Format-Table Id, Severity, Status, Message -Wrap
.\Invoke-RepositorySecurity.ps1 -Repository Owner/Repo -Apply -WhatIf
.\Invoke-RepositorySecurity.ps1 -Repository Owner/Repo -Apply -Confirm
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
token privileges and PR approval, Dependabot updates/alerts, secret scanning/push
protection, private vulnerability reporting and deletion of merged head branches.
`-Apply` can enable those features and restrict actions to GitHub-owned sources
plus `ossf/scorecard-action@*`, preserving disabled Actions and local-only policies.
This **replaces other third-party allowlist exceptions**; review the preview
before applying to other repositories. SHA pin enforcement remains required.
Unsupported or inaccessible features are reported, not silently treated as secure.

Dependabot security updates use the dedicated `automated-security-fixes`
endpoint. Disabled or paused updates produce a remediable finding; inaccessible
or incomplete responses remain `Unknown`.

Branch protection is deliberately a manual-review finding, even when a ruleset
exists. In GitHub Settings > Rules > Rulesets, protect the default branch with
required PRs, required CI checks, force-push/deletion prevention and reviewed
bypass permissions. Review requirements should suit the maintainer count:
requiring another person's approval can block a solo maintainer. CODEOWNERS alone
does not enforce reviews.

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

[`ci.yml`](../.github/workflows/ci.yml) runs the full tier on Windows and Linux
with verified modules. The proof tier runs on Linux for pushes to `main` and on
demand (**Actions > CI > Run workflow**). Jobs grant only `contents: read`, do
not persist Git credentials and limit runtime and artifact retention.

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
