# Git setup scripts

PowerShell 7 scripts to set up a developer machine (Windows + WSL + VS Code + GitHub).

| Script | Purpose |
| --- | --- |
| `Set-GitGlobalConfig.ps1` | Applies a consistent global Git configuration; identity is derived from your GitHub profile. |
| `Sync-GitRepositories.ps1` | Clones all your non-fork GitHub repositories, or one selected by URL, as bare repositories and creates one worktree per remote branch. |
| `Remove-StaleGitWorktree.ps1` | Previews or removes clean worktrees whose tracked origin branch was deleted, preserving local branches. |

The setup and sync scripts support `-DryRun`, which prints what would happen without
changing anything. Worktree cleanup previews by default and requires `-Apply`.

## Requirements

- [PowerShell 7+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
- [Git 2.37 or newer](https://git-scm.com/)
- [GitHub CLI](https://cli.github.com/), authenticated (`gh auth login`)
- On Windows, [Git Credential Manager](https://github.com/git-ecosystem/git-credential-manager)
  for global Git configuration.

Contributor setup, checks, test suites and maintenance helpers are documented in
the [development guide](docs/Development.md).

Each script includes command-line help with parameters, examples and safety notes:

```powershell
Get-Help .\Set-GitGlobalConfig.ps1 -Full
Get-Help .\Sync-GitRepositories.ps1 -Examples
Get-Help .\Remove-StaleGitWorktree.ps1 -Full
```

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

Settings applied: LF line endings (`core.autocrlf=input`), default branch `main`, pull with rebase and autostash, automatic upstream and annotated tag following on push, prune and write a commit graph on fetch, object verification (`transfer.fsckObjects=true`), local-file protocol restricted to user-initiated operations, `rerere`, `zdiff3` conflict style, `histogram` diff, VS Code as editor, colored UI. On Windows, long paths are enabled. See `Get-GitConfigPlan` for the full list. Following tags may push additional annotated tags.

On Windows the script replaces global credential helpers with Git Credential
Manager, resetting helpers inherited from system configuration first. It fails
before applying changes if the manager is unavailable. Repository, worktree,
URL-specific and command-line configuration can still override or add helpers;
review those separately. Existing plaintext credential files are not removed.
Other platforms keep their existing credential-helper configuration.

### Sync-GitRepositories.ps1

```powershell
# Preview
./Sync-GitRepositories.ps1 -DryRun

# Sync every non-fork repository of an owner into C:\Repositories\example\<repo>
./Sync-GitRepositories.ps1 -GitHubOwner example -TargetDirectory C:\Repositories
./Sync-GitRepositories.ps1 -Url https://github.com/example -TargetDirectory C:\Repositories

# Sync one repository: bare clone and a worktree for every branch
./Sync-GitRepositories.ps1 -Url https://github.com/example/github

# Sync one repository, but create or check only one branch's worktree
./Sync-GitRepositories.ps1 -Url https://github.com/example/github/tree/feature/login -BranchOnly
```

| Parameter | Default | Description |
| --- | --- | --- |
| `-GitHubOwner` | `example` | Account whose non-fork repositories are synced; a name or an owner URL. |
| `-Url` | none | Owner, repository or branch URL; replaces `-GitHubOwner`. See below. |
| `-BranchOnly` | off | With a branch URL, create or check only that branch's worktree. |
| `-TargetDirectory` | `C:\Repositories` | Root directory; each owner gets its own subfolder. |
| `-DryRun` | off | Report actions without cloning, fetching or creating worktrees. |

`-Url` accepts HTTPS, SSH (`git@github.com:owner/repo.git`) and scheme-less
(`github.com/owner/repo`) forms, with or without a trailing slash or `.git` suffix:

| URL | Selects |
| --- | --- |
| `https://github.com/example` | Every non-fork repository of the owner, like `-GitHubOwner`. |
| `https://github.com/example/github` | Only that repository, with all its branches. |
| `https://github.com/example/github/tree/feature/login` | Only that repository with all its branches; with `-BranchOnly`, only that branch's worktree. |

The bare repository is always cloned or fetched completely, also with `-BranchOnly`.
An explicitly selected repository is synced even if it is a fork.

Resulting layout:

```text
<TargetDirectory>\<owner>\<repo>\.git              bare repository
<TargetDirectory>\<owner>\<repo>\main              worktree for main
<TargetDirectory>\<owner>\<repo>\feature\login     worktree for feature/login
```

> **Changed:** `-TargetDirectory` is now the parent of the owner folder. The
> default `C:\Repositories` gives the same `C:\Repositories\example\<repo>` paths as before, but an
> explicit `-TargetDirectory C:\Repositories\example` now syncs into `C:\Repositories\example\example`.
> Pass `C:\Repositories` instead. `Remove-StaleGitWorktree.ps1` no longer accepts a single
> repository folder as `-TargetDirectory`; select it with `-Url`.

Behavior:

- All owner repositories are listed using GitHub API pagination; forks are excluded.
- Existing bare repositories are checked against the requested GitHub origin before any fetch or configuration change.
- Existing bare repositories are fetched with `--prune`; existing worktrees are never modified.
- Local branches without tracking configuration are set to track the matching origin
  branch, including branches from a bare clone and already-registered worktrees.
  Explicit tracking configuration is preserved; `-DryRun` only previews missing upstreams.
- `HEAD` and `dependabot/*` branches are ignored.
- A path that exists but is not a registered worktree is skipped with a warning.
- In dry-run mode, repositories that are not cloned yet are reported as "would clone" (their branches are unknown), and already-cloned repositories use the branches from the last fetch.
- Independent repository operations continue after a repository fails, but any incomplete sync is reported with a non-zero exit so callers cannot mistake partial work for success.

### Remove-StaleGitWorktree.ps1

```powershell
# Preview every repository of the owner in C:\Repositories\example (defaults: example, C:\Repositories)
.\Remove-StaleGitWorktree.ps1 -GitHubOwner example -TargetDirectory C:\Repositories

# Apply cleanup, or limit it to one repository or one branch selected by URL
.\Remove-StaleGitWorktree.ps1 -Apply
.\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github -Apply -WhatIf
.\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github/tree/feature/login -BranchOnly -Apply

# Optionally preview, then delete eligible merged local branches as well
.\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github -DeleteMergedBranch
.\Remove-StaleGitWorktree.ps1 -Url https://github.com/example/github -DeleteMergedBranch -Apply
```

`-GitHubOwner`, `-Url`, `-BranchOnly` and `-TargetDirectory` select repositories
the same way as for `Sync-GitRepositories.ps1`; a repository URL inspects only
that repository, and a branch URL with `-BranchOnly` only that branch's worktree.
Owner and repository folders are matched ignoring case.

Requires Git and read access to each repository's origin. Queries origin directly,
without fetching or trusting stale remote-tracking refs; remote errors stop cleanup.
An empty remote branch listing also skips cleanup, even for an empty repository.
Only registered worktrees tracking an origin branch that no longer exists are
eligible. Local-only branches, detached worktrees and other remotes are left alone.

Cleanup uses `git worktree remove` without force, not recursive folder deletion.
By default it preserves local branches and commits, including unpushed commits. It skips
locked or missing worktrees, the current directory and its ancestors, paths outside
the repository root, symbolic links/junctions below that root, worktrees containing
other registered worktrees, and any worktree with modified, untracked or ignored
files (including test results). Review or relocate those files before retrying.
Unregistered folders and empty parent folders are not removed. Close editors and
stop processes using a candidate worktree before applying cleanup.

`-DeleteMergedBranch` additionally attempts `git branch -d` after a worktree is
removed, but only if the local branch is an ancestor of the current remote
default-branch commit. If the remote HEAD is unavailable, its commit is not
available locally, or Git refuses deletion, the branch is preserved and a
warning is shown. Squash-merged branches and unmerged commits are preserved.
The branch deletion is separately subject to `-WhatIf` and `-Confirm`.

## Contributing and security

See the [development guide](docs/Development.md) for setup, checks, helper-script
usage, opt-in Git hooks and dependency maintenance. For private vulnerability
reporting, see [SECURITY.md](.github/SECURITY.md).

## License

[MIT](LICENSE)
