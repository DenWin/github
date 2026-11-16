# Git setup scripts

PowerShell 7 scripts to set up a developer machine (Windows + WSL + VS Code + GitHub).

| Script | Purpose |
| --- | --- |
| `Set-GitGlobalConfig.ps1` | Applies a consistent global Git configuration; identity is derived from your GitHub profile. |
| `Sync-GitRepositories.ps1` | Clones all your non-fork GitHub repositories as bare repositories and creates one worktree per remote branch. |
| `Remove-StaleGitWorktree.ps1` | Previews or removes clean worktrees whose tracked origin branch was deleted, preserving local branches. |

The setup and sync scripts support `-DryRun`, which prints what would happen without
changing anything. Worktree cleanup previews by default and requires `-Apply`.

## Requirements

- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- [Git](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/), authenticated (`gh auth login`)

Development dependencies are pinned in `DevelopmentDependencies.psd1`: Pester,
PSScriptAnalyzer, and powershell-yaml. Use a current PowerShell 7 release supported
by those module versions.

## Usage

### Set-GitGlobalConfig.ps1

```powershell
# Preview
./Set-GitGlobalConfig.ps1 -DryRun

# Apply
./Set-GitGlobalConfig.ps1

# Override the user name
./Set-GitGlobalConfig.ps1 -UserName 'Jane Doe'
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-UserName` | GitHub profile name, else GitHub login | Value for `user.name`. |
| `-DryRun` | off | Print the `git config --global` commands without running them. |

`user.email` is always the GitHub noreply address (`<id>+<login>@users.noreply.github.com`).

Settings applied: LF line endings (`core.autocrlf=input`), default branch `main`, pull with rebase and autostash, automatic upstream on push, prune on fetch (branches and tags), `rerere`, `zdiff3` conflict style, `histogram` diff, VS Code as editor, colored UI. See `Get-GitConfigPlan` for the full list.

### Sync-GitRepositories.ps1

```powershell
# Preview
./Sync-GitRepositories.ps1 -DryRun

# Sync
./Sync-GitRepositories.ps1 -GitHubOwner DenWin -TargetDirectory C:\GIT\DenWin
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-GitHubOwner` | `DenWin` | Account whose non-fork repositories are synced. |
| `-TargetDirectory` | `C:\GIT\DenWin` | Root directory for the repositories. |
| `-DryRun` | off | Report actions without cloning, fetching or creating worktrees. |

Resulting layout:

```text
<TargetDirectory>\<repo>\.git              bare repository
<TargetDirectory>\<repo>\main              worktree for main
<TargetDirectory>\<repo>\feature\login     worktree for feature/login
```

Behavior:

- Existing bare repositories are fetched with `--prune`; existing worktrees are never modified.
- `HEAD` and `dependabot/*` branches are ignored.
- A path that exists but is not a registered worktree is skipped with a warning.
- In dry-run mode, repositories that are not cloned yet are reported as "would clone" (their branches are unknown), and already-cloned repositories use the branches from the last fetch.

### Remove-StaleGitWorktree.ps1

```powershell
# Preview all repositories directly under the target directory (default: C:\GIT\DenWin)
.\Remove-StaleGitWorktree.ps1 -TargetDirectory C:\GIT\DenWin

# Apply cleanup, or limit it to a single repository root containing a bare .git directory
.\Remove-StaleGitWorktree.ps1 -TargetDirectory C:\GIT\DenWin -Apply
.\Remove-StaleGitWorktree.ps1 -TargetDirectory C:\GIT\DenWin\github -Apply -WhatIf
```

Requires Git and read access to each repository's origin. Queries origin directly,
without fetching or trusting stale remote-tracking refs; remote errors stop cleanup.
Only registered worktrees tracking an origin branch that no longer exists are
eligible. Local-only branches, detached worktrees and other remotes are left alone.

Cleanup uses `git worktree remove` without force, not recursive folder deletion.
It preserves local branches and commits, including unpushed commits. It skips
locked or missing worktrees, the current directory and its ancestors, paths outside
the repository root, symbolic links/junctions below that root, worktrees containing
other registered worktrees, and any worktree with modified, untracked or ignored
files (including test results). Review or relocate those files before retrying.
Unregistered folders and empty parent folders are not removed. Close editors and
stop processes using a candidate worktree before applying cleanup.

## Development

### VS Code

Open the repository folder in VS Code and run **Extensions: Show Recommended
Extensions** from the Command Palette to install the workspace recommendations
in [`.vscode/extensions.json`](.vscode/extensions.json):

- **PowerShell** (`ms-vscode.powershell`): language support, debugging and script analysis.
- **EditorConfig** (`EditorConfig.EditorConfig`): applies the repository's formatting rules.
- **YAML** (`redhat.vscode-yaml`): validation and completion for workflow and Dependabot files.

Recommendations do not install extensions automatically or isolate them from
other repositories. Select a dedicated VS Code profile before installing if you
want a separate extension set. PowerShell modules still need to be installed
using the commands below.

### Checks

```powershell
# Install tooling once
$dependencies = Import-PowerShellDataFile .\DevelopmentDependencies.psd1
foreach ($module in $dependencies.Keys) {
    Install-Module -Name $module -RequiredVersion $dependencies[$module] -Repository PSGallery -Scope CurrentUser
}

# Lint + tests (same as CI)
./Invoke-Checks.ps1

# Tests only, with coverage and NUnit output in TestResults/
Invoke-Pester -Configuration (./PesterConfiguration.ps1)
```

Project layout:

| File | Purpose |
| --- | --- |
| `*.ps1` | Scripts. Logic lives in functions; the entry point only runs when the script is not dot-sourced. |
| `*.Tests.ps1` | Pester tests. External tools (`git`, `gh`) are reached only through `Invoke-Git` / `Invoke-Gh`, which tests mock. |
| `PSScriptAnalyzerSettings.psd1` | Lint rules. |
| `PesterConfiguration.ps1` | Test, result and coverage settings. |
| `.editorconfig`, `.gitattributes` | Formatting and line-ending rules (LF, UTF-8). |
| `.github/workflows/ci.yml` | CI on Windows and Linux. |
| `Invoke-RepositorySecurity.ps1` | Read-only workflow/GitHub audit with opt-in remediation. |
| `DevelopmentDependencies.psd1` | Exact development module versions used locally and in CI. |
| `.githooks/` | Opt-in pre-commit and pre-push checks. |

Conventions: approved PowerShell verbs, singular nouns, strict mode, `$ErrorActionPreference = 'Stop'`. Add or change a test together with every behavior change.

## Security

```powershell
# Local workflow audit: no network or GitHub authentication required
.\Invoke-RepositorySecurity.ps1 -LocalOnly

# Fail CI on local findings (also included in Invoke-Checks.ps1)
.\Invoke-RepositorySecurity.ps1 -LocalOnly -FailOnFinding

# Audit live GitHub settings without changing anything
.\Invoke-RepositorySecurity.ps1 -Repository DenWin/github |
    Format-Table Id, Severity, Status, Message -Wrap

# Preview supported setting changes; requires repository administration access
.\Invoke-RepositorySecurity.ps1 -Repository DenWin/github -Apply -WhatIf

# Explicitly apply supported GitHub changes, prompting for confirmation
.\Invoke-RepositorySecurity.ps1 -Repository DenWin/github -Apply -Confirm

# Opt in to hooks for this local repository only
.\Invoke-RepositorySecurity.ps1 -LocalOnly -Apply -InstallHooks -WhatIf
.\Invoke-RepositorySecurity.ps1 -LocalOnly -Apply -InstallHooks
```

The GitHub target must be explicit; only GitHub.com is supported. Audit mode uses
read-only API calls. It returns structured findings, not a security certification.
`Fail` means a policy check failed; `Unknown` means access, feature availability,
or manual review prevents verification. Both fail `-FailOnFinding`.
`Applied` means the API accepted a change, **not** that a fresh audit verified it.
Rerun the audit after applying changes. Errors stop remediation; changes already
accepted by GitHub are not rolled back.

Local checks use a YAML parser to inspect action and reusable-workflow commit
pins, Docker action SHA-256 digests, credential persistence, permissions,
privileged triggers, inline script expressions, self-hosted runners, and job
timeouts. They intentionally flag some legitimate advanced workflows for review.
They do not parse shell semantics, inspect nested local actions, verify that a
commit is trustworthy, scan history for secrets, or assess downloaded code.
Local workflow findings are fixed manually; the script never rewrites YAML.

GitHub checks cover action-source restrictions, SHA pin enforcement, workflow
token privileges, Dependabot updates/alerts, secret scanning/push protection, and
private vulnerability reporting. `-Apply` can enable those features and restrict
actions to GitHub-owned sources (preserving disabled Actions and local-only
policies). This removes third-party allowlist exceptions; review the preview
before applying to other repositories. Unsupported or inaccessible features are
reported rather than silently treated as secure.

Branch protection is deliberately a **manual-review finding**, even when a
ruleset exists. In GitHub Settings > Rules > Rulesets, protect the default branch
with required PRs, required CI checks, force-push/deletion prevention, and reviewed
bypass permissions. Choose review requirements appropriate for the number of
maintainers: requiring another person's approval can block a solo maintainer.
CODEOWNERS does not enforce reviews without a corresponding branch rule.

Workflow actions are pinned to verified 40-character Git commit SHAs, not SHA-256
or SHA-512 strings. Dependabot proposes action updates; review both the commit and
the release before merging. Exact PowerShell module versions improve
reproducibility but are not cryptographic integrity pins or a transitive lockfile.
Review module upgrades separately. CI grants only `contents: read` to its checks
job, does not persist Git credentials, and limits runtime and artifact retention.

Pre-commit runs the local security audit, lint, and staged whitespace checks;
pre-push runs the full checks. Hooks inspect the **working tree**, not an isolated
snapshot of staged changes or every pushed commit. They require the development
dependencies and PowerShell on PATH. Installation refuses to overwrite a
different local `core.hooksPath`; it never installs dependencies automatically.
On Unix it marks the hook files executable. When adding these files to Git,
preserve their executable bit (`git add --chmod=+x .githooks/pre-commit .githooks/pre-push`).
Hooks can be bypassed and are not a substitute for protected CI.
To uninstall, run `git config --local --unset core.hooksPath`.

See [.github/SECURITY.md](.github/SECURITY.md) for private reporting guidance.

## License

[MIT](LICENSE)
