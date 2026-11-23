---
type: Feature index
title: "Git workflow tooling: features and requirements"
description: Scope, terminology, and dependencies shared across the features.
status: draft
---

# Git workflow tooling: features and requirements

## Contents

- [Feature dossiers](#feature-dossiers)
- [Purpose and scope](#purpose-and-scope)
- [Glossary](#glossary)
- [Priorities and open decisions](#priorities-and-open-decisions)

This index captures the shared scope and terminology and links to the feature
documents. Each feature's README is the dossier for its goal, requirements,
specification, and plan unless an artifact needs an independent lifecycle or
the combined dossier becomes difficult to navigate.

`F000` is reserved for common, cross-cutting requirements. Numbered feature
identifiers (`F001`, `F002`, ...) are assigned sequentially, are globally
unique within this repository, and are never reused. Each atomic
functional requirement has a stable `FR-NNNN` ID; each non-functional
requirement has a stable `NFR-NNNN` ID. Each feature has one requirements set with headed, anchored entries in its
dossier by default. The FR or NFR section supplies the type; the feature folder
supplies feature context. Status, priority, and goal or source are recorded at
the narrowest scope where they differ. `FR` and `NFR` have separate sequential
ID series and are never reused or renumbered.

## Feature dossiers

F000, F004, and F005 are unapproved proposals, not confirmed feature scope.
They are retained for review only.

| Feature | Scope and requirement range |
| --- | --- |
| [F001 - Git configuration](F001%20-%20Git%20configuration/README.md) | Git identity and global defaults; FR-0001 through FR-0011, FR-0032, NFR-0001 |
| [F002 - Repository cloning and synchronization](F002%20-%20Repository%20cloning%20and%20synchronization/README.md) | Repository selection, bare clones, and branch worktrees; FR-0012 through FR-0021 |
| [F003 - Stale worktree cleanup](F003%20-%20Stale%20worktree%20cleanup/README.md) | Safe preview and cleanup of stale worktrees; FR-0022 through FR-0025 |
| [F004 - Repository security](F004%20-%20Repository%20security/README.md) | Workflow audit and opt-in security remediations; FR-0026 through FR-0029, NFR-0002 |
| [F005 - Developer tooling](F005%20-%20Developer%20tooling/README.md) | Verified dependencies and automated checks; FR-0030, FR-0031, NFR-0003 |
| [F000 - Cross-cutting quality](F000%20-%20Cross-cutting%20quality/README.md) | Quality requirements applying across features; NFR-0004 through NFR-0011 |

Stakeholder goals are documented in their owning feature folders.

## Purpose and scope

The system has distinct capabilities: configure a developer's Git identity and
defaults; clone or synchronize GitHub repositories as branch worktrees; clean
stale worktrees without losing local work; audit repository security; and run
reproducible development checks.

**Stakeholders:** developers using GitHub repositories; maintainers responsible
for the tooling and its quality; GitHub administrators responsible for
repository settings. The maintainer shall confirm stakeholder representation
and priorities.

**Out of scope:** managing GitHub Enterprise hosts; synchronizing working-tree
contents with remote changes; force-removing worktrees; transactional rollback;
certifying repository security; automatically fixing workflow YAML; and
recovering changes already made by a failed operation.

**Dependencies and constraints:** PowerShell 7+, Git 2.37+, and, where GitHub
API access is needed, authenticated GitHub CLI. F001 also specifies GitLab as
an identity provider; its integration and authentication are not yet
specified. Windows global configuration also requires Git Credential Manager.
Network access and permissions depend on the operation. Development checks require the pinned PowerShell modules. See
the [user guide](../../README.md#requirements) and
[development guide](../Development.md#development-environment).

**Assumptions:** users can review previews and have permission to change their
own Git configuration and selected repositories. The default GitHub owner and
local root directory require maintainer confirmation.

## Glossary

| Term | Meaning |
| --- | --- |
| Owner | A GitHub user or organization owning repositories. |
| Bare repository | A Git repository without its own working tree; here it resides in the repository folder's `.git` directory. |
| Worktree | A registered Git working directory associated with a branch, or a detached commit. |
| Upstream | A local branch's configured remote and merge branch. |
| Stale worktree | A registered branch worktree whose configured origin upstream branch no longer exists on origin. Staleness alone does not imply removal eligibility. |
| Preview | Reporting intended actions without making the corresponding changes; it may still read local state or query a remote. |
| Finding | A security-audit result identifying a failed check, an unknown state, or an applied change. |

## Priorities and open decisions

Requirement priorities use `High`, `Medium`, or `Low` and are reviewed with
the requirements. These values express relative importance; obligation words
such as `shall`/`must`, `should`, and `may` belong in the requirement statement
and are not priority values. Quantitative performance, availability,
recovery-time, accessibility, and cost targets remain open. The maintainer and
users shall decide which apply and set measurable thresholds before making
those qualities acceptance gates.

| Decision or risk | Proposed owner | Next step |
| --- | --- | --- |
| Confirm stakeholder representation and priorities. | Repository maintainer | Review and adjust High, Medium, or Low values as needed. |
| Define applicable performance, reliability, accessibility, support, and cost targets. | Repository maintainer / users | Identify scenarios and set measurable targets, or document that a quality is out of scope. |
| Live GitHub and Gallery interactions can fail because of API changes, permissions, or network conditions. | Repository maintainer | Define safe integration verification in a dedicated test environment. |
| Filesystem link and junction behavior varies by platform and permissions. | Repository maintainer | Confirm supported platforms and add platform-appropriate safety tests. |
| Configuration, removals, and GitHub setting changes can be partially applied on failure. | Developer / GitHub administrator | Decide whether stronger recovery guarantees are required; document safe retry procedures. |

When revising a requirement, assess its specification, tests, user
documentation, and affected plan items together. Keep IDs stable; retire rather
than reuse them.

