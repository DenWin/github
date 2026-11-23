---
type: Feature dossier
title: F002 - Repository cloning and synchronization
description: Repository selection, bare clones, and branch worktrees.
status: stable
version: "1.0"
verified:
  - by: "human:Dennis Winter"
    at: "2026-11-19T22:37:09.452+01:00"
---

# F002 - Repository cloning and synchronization

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 1.0 | stable | Document verified. |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Functional requirements](#functional-requirements)
  - [FR-0012: Repository selection](#fr-0012-repository-selection)
  - [FR-0013: Branch worktree selection](#fr-0013-branch-selection)
  - [FR-0014: Bare repository clone](#fr-0014-bare-repository-clone)
  - [FR-0015: Preserve existing worktree contents](#fr-0015-preserve-existing-worktree-contents)
  - [FR-0016: Preserve branch upstreams](#fr-0016-preserve-branch-upstreams)
  - [FR-0017: Verify repository origin](#fr-0017-verify-repository-origin)
  - [FR-0018: Synchronization preview](#fr-0018-synchronization-preview)
  - [FR-0019: Report incomplete synchronization](#fr-0019-report-incomplete-synchronization)
  - [FR-0020: Protect occupied worktree paths](#fr-0020-protect-occupied-worktree-paths)
  - [FR-0021: Create worktrees for remote branches](#fr-0021-create-worktrees-for-remote-branches)
- [Specification](#specification)
  - [SPEC-0002: Repository cloning and synchronization](#spec-0002-repository-cloning-and-synchronization)
- [Delivery plan](#delivery-plan)
  - [PLAN-0002: Repository cloning and synchronization](#plan-0002-repository-cloning-and-synchronization)
- [Delivered](#delivered)

## Goal

F002 turns selected GitHub repositories into predictable local workspaces.
It manages bare repository clones and branch worktrees in a consistent layout,
fetches updates without overwriting existing worktree contents, and preserves
configured branch upstreams. Developers can synchronize an owner's eligible
repositories or select one repository or branch explicitly; preview reports
planned work without changing the local state.

**Example:** An owner-wide synchronization creates local worktrees for
eligible remote branches while leaving existing worktree contents alone. If
the developer instead selects a repository URL, that repository is selected
even when it is a fork; a branch-only selection can limit worktree creation to
one branch.

**Stakeholder:** Developer

Work with selected GitHub repositories locally without manually managing bare
clones, fetches, branch tracking, and one worktree per branch, while keeping
existing work safe.

## Functional requirements

<a id="fr-0012-repository-selection"></a>
### FR-0012: Repository selection

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall select repositories according to the developer's owner or explicit repository selection. |
| **Acceptance criteria** | An owner selection includes owned non-forks and excludes forks; explicitly selecting a repository includes it whether or not it is a fork. When both an owner and an explicit location are supplied, the location determines the selection. |

<a id="fr-0013-branch-selection"></a>
### FR-0013: Branch worktree selection

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall select branch worktrees according to the developer's explicit branch selection or the default branch exclusions. |
| **Acceptance criteria** | Without a selected branch, `HEAD` and `dependabot/*` are excluded; branch-only selection selects the named existing branch even when normally excluded and is rejected without a branch URL. |

<a id="fr-0014-bare-repository-clone"></a>
### FR-0014: Bare repository clone

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall clone a selected remote repository as a bare repository under the selected root, owner, and repository path. |
| **Acceptance criteria** | Test the clone layout and origin using a temporary local remote; verify the remote repository is not modified. |

<a id="fr-0015-preserve-existing-worktree-contents"></a>
### FR-0015: Preserve existing worktree contents

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall leave existing worktree contents unchanged during synchronization. |
| **Acceptance criteria** | Inspection and integration test: synchronization does not pull, reset, or rebase an existing worktree; a repeat run is idempotent. |

<a id="fr-0016-preserve-branch-upstreams"></a>
### FR-0016: Preserve branch upstreams

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall preserve explicitly configured branch upstreams. |
| **Acceptance criteria** | Integration test: a preconfigured upstream remains unchanged; a missing origin upstream is configured. |

<a id="fr-0017-verify-repository-origin"></a>
### FR-0017: Verify repository origin

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall refuse to fetch or reconfigure an existing bare repository whose origin does not identify the selected GitHub repository. |
| **Acceptance criteria** | Integration test: a mismatched origin causes failure before fetch. |

<a id="fr-0018-synchronization-preview"></a>
### FR-0018: Synchronization preview

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall provide a synchronization preview that does not clone, fetch, create directories, or change configuration. |
| **Acceptance criteria** | Integration test: local state is unchanged in dry-run mode; an uncloned repository is reported without assuming its branches. |

<a id="fr-0019-report-incomplete-synchronization"></a>
### FR-0019: Report incomplete synchronization

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall report an incomplete synchronization as a failure. |
| **Acceptance criteria** | Integration test: after one repository fails, independent repositories continue and the overall run fails. |

<a id="fr-0020-protect-occupied-worktree-paths"></a>
### FR-0020: Protect occupied worktree paths

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall not overwrite a path that is not the selected registered worktree. |
| **Acceptance criteria** | Integration test: an occupied unregistered path is retained and the incomplete synchronization is reported. |

<a id="fr-0021-create-worktrees-for-remote-branches"></a>
### FR-0021: Create worktrees for remote branches

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall create a registered worktree for each selected remote branch using the branch name as the worktree's relative path. |
| **Acceptance criteria** | Test with temporary branches, including nested branch names; verify each worktree is registered to the expected branch. |

## Specification

<a id="spec-0002-repository-cloning-and-synchronization"></a>
### SPEC-0002 - Repository cloning and synchronization

**Status:** Draft.

This specification defines repository selection, bare cloning, fetch, and
branch-worktree creation.

#### Design

The synchronization operation accepts an owner, repository, or branch
selector, or enumerates the selected GitHub owner's repositories. Proposed
defaults are `DenWin` and `C:\GIT`, pending maintainer confirmation. An
explicit GitHub location selects an owner, repository, or branch; branch-only
selection limits synchronization to that branch. Preview reports planned
work without writing.

Each repository uses a bare clone at
`<root>\<owner>\<repository>\.git`. Branch worktrees are created under the
repository directory using branch path segments. The operation verifies an
existing bare repository's origin before fetching. Fetch prunes deleted remote
references, preserves configured upstreams, and adds missing origin tracking.
Existing worktree contents are not updated. `HEAD` and `dependabot/*` are
excluded by default; an explicitly selected branch may be included.

#### Interface and selection contract

The interface accepts an owner selector, an explicit location, or both. When
both are supplied, the explicit location takes precedence and the owner
selector is ignored. The owner selector must resolve to an owner only when
used; the explicit location may select an owner, repository, or
`/tree/<branch>`. An invalid explicit location is rejected without falling
back to the owner selector. Branch-only selection requires an explicit branch
location. Without branch-only selection, a branch URL selects the repository
but all eligible branches. The root directory is configurable, and preview is
opt-in. The owner and root defaults remain proposed, pending stakeholder
confirmation; interface option names are to be chosen during design.

Selection accepts plain `owner` or `owner/repository`, GitHub.com HTTP,
HTTPS, SSH and Git URLs, scheme-less GitHub.com paths, and
`git@github.com:owner/repository.git`. It removes query and fragment, trims
outer slashes, removes `.git` from a two-segment repository path, and
URL-decodes the entire branch after `/tree/`. Owner is 1-39 ASCII
letters/digits/hyphens, beginning with a letter or digit; repository names use
ASCII letters/digits, `_`, `.` and `-`, excluding `.` and `..`. Other explicit
hosts and repository subpaths are rejected. Validate before querying GitHub.

Require Git and authenticated GitHub CLI even for preview. Resolve whether
the owner is a user or organization and retrieve all pages of its owned
repositories. Reject other owner types and records missing the repository
name, full name, or fork status; filter forks and sort by name. For an
explicit repository, retrieve that repository and include it even when it is
a fork. Use the returned full name for paths and cloning.

#### Repository and worktree behavior

1. For each selected repository independently, locate
   `<root>/<owner>/<repository>/.git`. If it exists, require a bare Git
   repository; otherwise create a bare clone of the selected repository. A
   preview of an absent clone reports the clone but cannot enumerate its
   branches.
2. Before updating either an existing or newly cloned repository, parse its
   configured `remote.origin.url` without expanding Git `insteadOf`; require
   the same GitHub owner/repository, compared case-insensitively. A missing,
   malformed or mismatched origin fails this repository.
3. Outside preview, set `remote.origin.fetch` to
   `+refs/heads/*:refs/remotes/origin/*`, prune stale worktree metadata, then
   fetch origin and prune stale remote-tracking refs. Read non-symbolic refs under
   `refs/remotes/origin/`, preserving case-distinct branch names. Preview of
   an existing clone uses its last-fetched refs and never updates them.
4. Without a selected branch, skip `HEAD` and `dependabot/*`; with a branch,
   match its name case-sensitively, including normally excluded branches, and
   fail the repository if it is absent. An empty unfiltered list is successful.
5. The worktree path is the repository root joined with the branch name,
   including nested path segments. An existing local branch keeps any
   configured `branch.<name>.remote` or `.merge`; if neither is configured,
   set its upstream to `origin/<name>` before checking the worktree.
   A registered worktree at the target path for the exact branch is left
   untouched. An occupied path not registered for that branch is a failure.
   Otherwise add the existing local branch or create a new tracking branch
   from `origin/<name>`. Path comparison follows the OS; branch comparison is
   ordinal and case-sensitive.

Preview does not create even parent directories or set upstreams. Failed
branches do not prevent other branches from being attempted; failed
repositories do not prevent independent repositories from being attempted.
The final error identifies all incomplete repositories. Completed clones,
fetches and worktrees are not rolled back.

#### Failure and safety behavior

Unsupported selectors and non-GitHub hosts are rejected. An occupied path that
is not the registered worktree for the selected repository and branch is never
overwritten. Repository failures are reported while independent repositories
may continue; the overall operation reports failure if any repository is
incomplete. Preview can read local and remote state but performs no mutations.

#### Verification

Test selector parsing, repository and branch selection, including location
precedence when both selectors are supplied with different owners, an
owner-only location, an invalid explicit location, and the branch-only and
preview behaviors. Use temporary local bare repositories and worktrees to
verify clone/fetch behavior, upstream preservation, occupied-path refusal,
previews, and independent failure reporting. Verify GitHub response handling
separately from live API access.

## Delivery plan

<a id="plan-0002-repository-cloning-and-synchronization"></a>
### PLAN-0002 - Repository cloning and synchronization

**Status:** Draft.

The maintainer confirms proposed owner and root-directory defaults before they
are treated as final.

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Confirm selectors and layout | FR-0012 through FR-0014 | Confirm accepted GitHub URL forms, branch exclusions and proposed `DenWin`/`C:\GIT` defaults; tests cover target selection and bare-clone layout. | None |
| 2. Implement repository synchronization | FR-0015 through FR-0019 | Verify origins, fetch and preserve upstreams; tests cover preview, existing worktrees, and incomplete independent repositories. | Step 1 |
| 3. Create branch worktrees safely | FR-0020, FR-0021 | Create missing remote-branch worktrees and refuse occupied unregistered paths; integration tests use temporary local bare remotes. | Step 2 |
| 4. Verify selection paths | FR-0012 through FR-0021 | Exercise owner enumeration, repository and branch selection, location precedence, exclusions, failure handling, and script help against isolated fixtures. | Steps 1-3 |

This feature establishes the repository layout used by
[stale-worktree cleanup](../F003%20-%20Stale%20worktree%20cleanup/README.md#plan-0003-stale-worktree-cleanup).
Live GitHub access is not required for ordinary automated tests.

## Delivered

| Deliverable | Purpose |
| --- | --- |
| [Sync-GitRepositories.ps1](../../../Sync-GitRepositories.ps1) | Selects GitHub repositories, synchronizes bare clones, and creates branch worktrees. |
| [Sync-GitRepositories.Tests.ps1](../../../Sync-GitRepositories.Tests.ps1) | Verifies selection, synchronization, worktree safety, previews, and failure handling. |

