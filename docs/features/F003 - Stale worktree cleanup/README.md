---
type: Feature dossier
title: F003 - Stale worktree cleanup
description: Preview and cleanup of stale worktrees without discarding local work.
status: stable
version: "1.0"
verified:
  - by: "human:Dennis Winter"
    at: "2026-11-19T23:07:36.167+01:00"
---

# F003 - Stale worktree cleanup

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 1.0 | stable | Document verified. |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Functional requirements](#functional-requirements)
  - [FR-0022: Identify stale worktrees](#fr-0022-verify-stale-worktrees)
  - [FR-0023: Protect unsafe worktrees](#fr-0023-protect-worktrees)
  - [FR-0024: Preserve local branches](#fr-0024-preserve-local-branches)
  - [FR-0025: Preview cleanup](#fr-0025-preview-cleanup)
- [Specification](#specification)
  - [SPEC-0003: Stale worktree cleanup](#spec-0003-stale-worktree-cleanup)
- [Delivery plan](#delivery-plan)
  - [PLAN-0003: Stale worktree cleanup](#plan-0003-stale-worktree-cleanup)
- [Delivered](#delivered)

## Goal

F003 helps developers reclaim space and reduce clutter after remote branches
are deleted, without sacrificing local work. It identifies stale registered
worktrees using a live origin listing, previews removals by default, and
removes only candidates that pass safety checks. Local branches remain unless
the developer separately requests deletion and the tool can prove they are
merged.

**Example:** After a feature branch is deleted from origin, a clean registered
worktree for that branch can appear in the preview and be removed explicitly.
A dirty, ignored, locked, detached, or otherwise unsafe worktree is retained;
an empty or failed origin listing does not trigger cleanup.

**Stakeholder:** Developer

Identify and clean up worktrees that are no longer needed, while protecting
local changes, branches, and any worktree whose safety cannot be established.

## Functional requirements

<a id="fr-0022-verify-stale-worktrees"></a>
### FR-0022: Identify stale worktrees

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall identify stale registered worktrees using the current origin branch listing. |
| **Acceptance criteria** | An unreachable or empty listing causes no removal; worktrees for existing origin branches, local-only branches, other remotes and detached commits are retained. |

<a id="fr-0023-protect-worktrees"></a>
### FR-0023: Protect unsafe worktrees

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall retain a stale worktree when local content or its location or registration makes removal unsafe. |
| **Acceptance criteria** | Modified, untracked and ignored files prevent removal; locked, missing, nested, outside-root, current-directory/ancestor and link-traversing candidates are skipped. Verify link traversal with an integration demonstration. |

<a id="fr-0024-preserve-local-branches"></a>
### FR-0024: Preserve local branches

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall preserve local branches during cleanup except for explicitly requested, provably merged branch deletion. |
| **Acceptance criteria** | The branch remains by default; opt-in deletion requires ancestry of the locally available current remote default-branch commit. Unmerged or unprovable branches are preserved, and Git may refuse deletion. |

<a id="fr-0025-preview-cleanup"></a>
### FR-0025: Preview cleanup

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall make worktree and branch removal an explicit, previewable operation. |
| **Acceptance criteria** | Default invocation leaves eligible worktrees and tracking refs unchanged; explicit preview of an apply operation leaves the worktree and branch intact. |

## Specification

<a id="spec-0003-stale-worktree-cleanup"></a>
### SPEC-0003 - Stale worktree cleanup

**Status:** Draft.

This specification defines how stale branch worktrees are identified and
removed without force. It is constrained by
[NFR-0004: Remove worktrees without force](../F000%20-%20Cross-cutting%20quality/README.md#nfr-0004-remove-worktrees-without-force).

#### Design

The cleanup operation queries origin directly and compares remote
branches with registered local worktrees. A worktree is only eligible after it
passes the location, lock, nesting, and cleanliness checks. A missing remote
branch alone is not sufficient for removal.

The operation previews by default. Applying changes and deleting an eligible
local branch require separate opt-ins. Explicit preview and confirmation
apply to both removal and branch deletion. Deletion requires ancestry proof
against the locally available commit of the remote default branch.

#### Interface and discovery contract

Owner, location, branch-only and target-directory selection share the
selection syntax of [SPEC-0002](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#spec-0002-repository-cloning-and-synchronization),
including its proposed owner and root defaults. When both an owner selector and
an explicit location are supplied, the location takes precedence and the owner
selector is ignored. An invalid explicit location is rejected without falling
back to the owner selector. Cleanup needs Git and origin read access, not GitHub
CLI. Applying changes and deleting merged branches are off by default. The
target directory must already exist. Interface option names are to be chosen
during design.

Look up owner and selected repository directory by exact name first, then
case-insensitively; reject ambiguous case-insensitive matches and symbolic
links/junctions for those directories. An absent owner produces a warning;
an explicitly selected absent repository or one without a `.git` directory is
an error. Owner-wide discovery considers child directories with a `.git`
directory and skips directory links. Verify each `.git` is bare.

#### Eligibility and removal behavior

1. Query origin's branch listing directly, including in preview, and validate
   each returned branch ref and object ID; a failed or malformed response
   stops the operation. An empty successful listing warns and skips that
   repository. Do not fetch or prune.
2. Read local branch upstream refs and registered worktrees.
   A candidate must have a local branch whose upstream begins
   `refs/remotes/origin/` and whose tracked branch is absent from the live
   origin listing. Compare branch names case-sensitively. An explicit branch
   selects the local branch name; detached and local-only worktrees and
   branches tracking another remote are not candidates.
3. Skip a candidate outside the repository root, within its bare `.git`,
   locked, missing, containing the current directory or another registered
   worktree, or traversing a symbolic link/junction below the root. Skip it
   if it contains modified, untracked, or ignored files. Report each skipped
   candidate.
4. Preview reports eligible removals without changing worktrees, local
   branches or tracking refs. Apply uses Git worktree removal without force
   and honors preview and confirmation; it does not recursively delete
   folders or remove empty parent directories. The local branch remains by
   default.
5. With merged-branch deletion requested, query origin's `HEAD` symref and
   commit. Accept the default commit only if its single branch ref and object
   ID match the earlier live branch listing. Verify the local branch is an ancestor of
   that locally available commit. After successful removal, request Git's
   non-forced branch deletion, honoring separate preview and confirmation;
   missing proof or Git refusal preserves the branch. A failed remote HEAD
   query is an error, whereas a successful but inconclusive response warns
   and preserves branches.

No synchronization of worktree contents or automatic rollback is performed.
Stale tracking refs do not establish remote deletion; unregistered folders
are not candidates.

#### Failure and safety behavior

An origin query error stops cleanup. An empty successful remote listing does
not cause cleanup. Worktrees with local changes, unsafe locations, locks, or
nested worktrees are preserved. Removal uses Git without force. Failures are
reported; earlier successful removals are not rolled back.

#### Verification

Use temporary local remotes and worktrees to test stale detection, empty and
failed origin queries, location precedence when both selectors are supplied,
invalid-location rejection without owner fallback, preview behavior, dirty and
ignored files, detached and locked worktrees, nested paths, links, non-forced
removal, and optional merged-branch deletion. Compare filesystem and Git state
before and after preview.

## Delivery plan

<a id="plan-0003-stale-worktree-cleanup"></a>
### PLAN-0003 - Stale worktree cleanup

**Status:** Draft.

This plan depends on the repository layout and synchronization behavior delivered
by [PLAN-0002](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#plan-0002-repository-cloning-and-synchronization).

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Determine staleness | FR-0022 | Query origin and compare branch state; tests distinguish missing, empty, and failed remote listings. | PLAN-0002 |
| 2. Enforce removal eligibility | FR-0022, FR-0023 | Check worktree registration, location, lock, nesting, and cleanliness; unsafe or changed worktrees are preserved. | Step 1 |
| 3. Implement opt-in branch deletion | FR-0024 | Preserve branches by default; test opt-in deletion only after ancestry proof against the remote default-branch commit. | Step 2 |
| 4. Verify preview and confirmation | FR-0025, NFR-0004 | Use isolated Git fixtures to verify default and explicit preview, confirmation, and non-forced removal. | Steps 1-3 |
| 5. Verify cleanup contract | FR-0022 through FR-0025 | Exercise selection, ancestry proof and safety checks against isolated real-Git fixtures, including inconclusive remote HEAD and link traversal. | Steps 1-4 |

Run integration tests only against temporary local remotes and worktrees. Never
use a managed repository or a developer's working tree as a cleanup fixture.

## Delivered

| Deliverable | Purpose |
| --- | --- |
| [Remove-StaleGitWorktree.ps1](../../../Remove-StaleGitWorktree.ps1) | Previews and removes eligible stale worktrees while preserving local work by default. |
| [Remove-StaleGitWorktree.Tests.ps1](../../../Remove-StaleGitWorktree.Tests.ps1) | Verifies stale detection, safety checks, selection, preview, and opt-in branch deletion. |

