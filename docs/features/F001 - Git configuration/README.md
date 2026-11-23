---
type: Feature dossier
title: F001 - Git configuration
description: Git identity and global defaults.
status: stable
version: "1.0"
verified:
  - by: "human:Dennis Winter"
    at: "2026-11-19T18:53:10.773+01:00"
---

# F001 - Git configuration

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 1.0 | stable | Document verified. |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Functional requirements](#functional-requirements)
  - [FR-0001: Resolve Git identity](#fr-0001-resolve-git-identity)
  - [FR-0002: Git identity overrides](#fr-0002-git-identity-overrides)
  - [FR-0003: Git configuration preview](#fr-0003-git-configuration-preview)
  - [FR-0032: Repository-local identity](#fr-0032-repository-local-identity)
  - [FR-0004: Consistent line endings](#fr-0004-line-ending-policy)
  - [FR-0005: Branch creation and publication](#fr-0005-branch-publication)
  - [FR-0006: Rebase workflow](#fr-0006-rebase-workflow)
  - [FR-0007: Fetch maintenance](#fr-0007-fetch-maintenance)
  - [FR-0008: Git transport safety](#fr-0008-transport-safety)
  - [FR-0009: Windows credential handling](#fr-0009-windows-credentials)
  - [FR-0010: Conflict review and resolution](#fr-0010-conflict-review)
  - [FR-0011: Developer environment defaults](#fr-0011-developer-environment)
- [Non-functional requirements](#non-functional-requirements)
  - [NFR-0001: Windows credential manager prerequisite](#nfr-0001-windows-credential-manager-prerequisite)
- [Specification](#specification)
  - [SPEC-0001: Git identity and global configuration](#spec-0001-git-identity-and-global-configuration)
- [Delivery plan](#delivery-plan)
  - [PLAN-0001: Git identity and global configuration](#plan-0001-git-identity-and-global-configuration)
- [Delivered](#delivered)

## Goal

F001 makes Git ready for a developer's day-to-day work by establishing a
consistent identity and a dependable set of defaults. It covers identity
resolution, branch and pull behavior, line endings, transport safety, conflict
review, credentials, and editor behavior. When a repository needs a different
identity, that setting can be scoped to that repository; preview lets the
developer inspect intended changes before they are written.

**Example:** On a new Windows machine, a developer previews the global setup
and then applies it. Git identity is resolved from explicit values, existing
Git configuration, or the selected GitHub/GitLab profile. If Git Credential
Manager is unavailable, global changes stop before any writes. For a particular
repository, the developer can set a local identity without changing global
configuration.

**Stakeholder:** Developer

Use Git with correctly attributed commits and consistent defaults, while
retaining control over changes and the ability to set a different identity for
a specific repository.

## Functional requirements

<a id="fr-0001-git-email-from-github-identity"></a>
<a id="fr-0001-resolve-git-identity"></a>
### FR-0001: Resolve Git identity

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall resolve the Git display name and commit email from explicit overrides, existing Git configuration or a selected identity provider according to the specified precedence. |
| **Acceptance criteria** | Resolve name and email independently. Without provider-metadata preference, use each nonblank override, then the existing selected-scope value, then the global value for local mode, then provider metadata. With provider-metadata preference, use each override, then provider metadata; required provider failures are reported. GitHub and GitLab are supported, and GitHub is the default provider. When both values are already resolved without a provider, no provider authentication or access is required. |

<a id="fr-0002-git-display-name-override"></a>
<a id="fr-0002-git-identity-overrides"></a>
### FR-0002: Git identity overrides

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Low |
| **Requirement** | The system shall allow the developer to override the Git display name and commit email independently. |
| **Acceptance criteria** | A nonblank explicit value takes precedence for its field; either value can be supplied alone. Both overrides work without contacting an identity provider. |

<a id="fr-0003-git-configuration-preview"></a>
### FR-0003: Git configuration preview

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall provide a preview of the selected configuration changes without writing Git configuration. |
| **Acceptance criteria** | Integration tests: global and repository-local previews report intended changes and leave the corresponding temporary configuration files unchanged. |

<a id="fr-0032-repository-local-identity"></a>
### FR-0032: Repository-local identity

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall provide an opt-in operation that sets identity only in a selected repository's local Git configuration. |
| **Acceptance criteria** | The operation changes only the selected repository's local identity; it does not apply or change global defaults. Git's normal shared repository configuration applies to its worktrees. Invalid or absent repository targets fail before writes. |

The following requirements define defaults in support of this goal.

<a id="fr-0004-line-ending-policy"></a>
### FR-0004: Consistent line endings

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall configure a line-ending policy that normalizes committed text while warning about unsafe conversion. |
| **Acceptance criteria** | CRLF is normalized to LF on commit without converting LF to CRLF on checkout; unsafe conversion warns rather than rejects, subject to Git attributes. |

<a id="fr-0005-branch-publication"></a>
### FR-0005: Branch creation and publication

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall configure the specified default branch and branch-publication workflow. |
| **Acceptance criteria** | New repositories start on `main`; a qualifying first default push establishes an upstream, uses Git's `simple` mode, and follows eligible annotated tags. |

<a id="fr-0006-rebase-workflow"></a>
### FR-0006: Rebase workflow

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall configure a rebase-based pull workflow that protects tracked uncommitted changes with an automatic stash. |
| **Acceptance criteria** | Pull rebases divergent local history; a rebase automatically stashes tracked changes and attempts to restore them afterward. |

<a id="fr-0007-fetch-maintenance"></a>
### FR-0007: Fetch maintenance

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall configure fetch to maintain local remote-reference and commit-graph data. |
| **Acceptance criteria** | Fetch prunes stale remote-tracking refs and tags according to Git's rules and writes a commit graph; a fixture demonstrates that pruning can remove local tags absent from the remote. |

<a id="fr-0008-transport-safety"></a>
### FR-0008: Git transport safety

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | The system shall configure Git transport safeguards for object integrity and local-file access. |
| **Acceptance criteria** | Transfer object checking is enabled and the file protocol uses Git's `user` policy. |

<a id="fr-0009-windows-credentials"></a>
### FR-0009: Windows credential handling

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | On Windows, the system shall configure Git Credential Manager as the global credential helper. |
| **Acceptance criteria** | The global helper list resets inherited helpers before `manager`; other platforms' helpers are unchanged. |

<a id="fr-0010-conflict-review"></a>
### FR-0010: Conflict review and resolution

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall configure Git's specified diff and conflict-resolution workflow. |
| **Acceptance criteria** | Git uses histogram diffs, displays `zdiff3` conflict context, and reuses recorded resolutions. |

<a id="fr-0011-developer-environment"></a>
### FR-0011: Developer environment defaults

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | Medium |
| **Requirement** | The system shall configure the specified editor, output presentation and platform-specific path support. |
| **Acceptance criteria** | Git waits for VS Code editing and uses automatic color; Windows enables long paths while other platforms do not write that setting. |

## Non-functional requirements

<a id="nfr-0001-windows-credential-manager-prerequisite"></a>
### NFR-0001: Windows credential manager prerequisite

| Section | Details |
| --- | --- |
| **Status** | Approved |
| **Priority** | High |
| **Requirement** | On Windows, the system shall refuse to apply global defaults when Git Credential Manager is unavailable. |
| **Acceptance criteria** | An unavailable manager stops global configuration before writes; repository-local identity-only operations do not require it. |

## Specification

<a id="spec-0001-git-identity-and-global-configuration"></a>
### SPEC-0001 - Git identity and global configuration

**Status:** Approved.

#### Summary and requirements

This specification defines how the developer's Git identity and global
defaults are configured.

#### Design

The default operation configures global Git identity and defaults. An
explicit repository-local identity operation configures only that
repository's identity, leaving global configuration and the other defaults
untouched. Preview reports the chosen operation without writing.

Identity resolution is provider-neutral, with GitHub and GitLab as the first
providers and GitHub as the default. Providers are consulted only when needed
to resolve a non-overridden field. Git's normal precedence applies: local
configuration overrides global configuration, and repository-local settings
are shared across that repository's worktrees. No application database or
separate identity store is used.

#### Identity selection contract

Resolve `user.name` and `user.email` independently; a nonblank explicit
override always wins. A blank or whitespace-only override or existing Git
value is treated as absent. The provider metadata preference is off by
default. For each unresolved field:

| Operation | Provider metadata preference | Precedence after override |
| --- | --- | --- |
| Global | Off | Existing global value, then provider metadata |
| Local identity | Off | Existing repository-local value, then existing global value, then provider metadata |
| Either | On | Provider metadata |

Consult the selected provider only when one or both fields need metadata.
Two overrides bypass the provider even when the preference switch is present.
With the switch off, existing values can also resolve both fields without the
provider. A missing provider executable, authentication failure,
failed lookup or missing required field causes a reported failure before
writes; do not silently fall back to existing values when provider metadata
was requested or needed. Name fallback within a provider is its nonblank
trimmed profile name, then its login.

For GitLab, use the account's configured commit email from the authenticated
user profile when an email is needed. It may be personal or private depending
on the user's GitLab setting. For GitHub, the proposed address is
`<id>+<login>@users.noreply.github.com`; the provider-specific open question
below must be resolved before treating it as valid for every account. Do not
apply GitHub's address format to other providers.

The interface shall allow selecting GitHub or GitLab, providing independent
name and email overrides, selecting the default global operation or the
repository-local identity operation with an explicit target, and enabling the
provider metadata preference. Interface option names are to be chosen during
design.

For a local operation, validate the target is a Git repository before any
write and use its repository-local configuration, not worktree-specific
configuration. Read global configuration only as the stated fallback; do not
use a different repository's local settings. For a global operation, read and
write global configuration only. Validate and resolve the complete identity
and all applicable prerequisites before writing either identity field.

#### Configuration contract

The following table specifies the global settings and their application order.
It maps behavioral requirements to Git's configuration interface; higher-priority
Git configuration can override the result.
See the [Git 2.37 configuration reference](https://git-scm.com/docs/git-config/2.37.0)
for Git-owned settings and their version-specific semantics.

| Requirement | Git key | Value | Purpose |
| --- | --- | --- | --- |
| FR-0001, FR-0002, FR-0032 | `user.name` | resolved name | Commit display name in the selected identity scope |
| FR-0001, FR-0002, FR-0032 | `user.email` | resolved email | Commit email in the selected identity scope |
| FR-0004 | `core.autocrlf` | `input` | Normalize CRLF on input, not checkout |
| FR-0004 | `core.safecrlf` | `warn` | Warn on irreversible line-ending conversion |
| FR-0005 | `init.defaultBranch` | `main` | Initial branch |
| FR-0006 | `pull.rebase` | `true` | Rebase on pull |
| FR-0006 | `rebase.autoStash` | `true` | Stash and restore around rebase |
| FR-0005 | `push.autoSetupRemote` | `true` | Set missing upstream on a qualifying push |
| FR-0005 | `push.default` | `simple` | Git's simple push mode |
| FR-0005 | `push.followTags` | `true` | Include eligible annotated tags |
| FR-0007 | `fetch.prune` | `true` | Prune stale fetched refs |
| FR-0007 | `fetch.pruneTags` | `true` | Apply tag-pruning refspec; local tags may be deleted |
| FR-0007 | `fetch.writeCommitGraph` | `true` | Write commit graph after fetch |
| FR-0008 | `transfer.fsckObjects` | `true` | Check transferred objects |
| FR-0008 | `protocol.file.allow` | `user` | Restrict file transport to Git's user policy |
| FR-0009 | `credential.helper` | reset, then `manager` | Windows only; replace global helpers and reset inherited ones |
| FR-0011 | `core.longpaths` | `true` | Windows only; enable Git long paths |
| FR-0010 | `rerere.enabled` | `true` | Reuse recorded conflict resolutions |
| FR-0010 | `merge.conflictStyle` | `zdiff3` | Include base context in conflicts |
| FR-0010 | `diff.algorithm` | `histogram` | Use histogram diff |
| FR-0011 | `core.editor` | `code --wait` | Wait for VS Code editing |
| FR-0011 | `color.ui` | `auto` | Automatic terminal coloring |

Require PowerShell 7 and Git. Require provider authentication and its
integration only when metadata is needed. The global operation verifies
that Git Credential Manager is available on Windows before writing; local
identity-only operations do not require it. Preview performs the same
selection and prerequisite checks, including any needed provider lookup, then
prints the planned Git commands without writing. Apply global entries in the
specified order. On Windows, replace the global helper list with a reset
entry followed by `manager`. Apply local identity in the selected repository's
local configuration. Stop on the first write failure; on success report the
selected scope and configuration sources. Do not remove existing credential
files or modify helper configuration on other OSes.

#### Failure and safety behavior

Required authentication or profile lookup failures stop configuration. A
missing Windows credential-manager prerequisite stops a global operation
before writes. A local-only operation does not require the global
credential-manager prerequisite. Git or filesystem failures are surfaced and
stop subsequent writes; successful earlier writes are not rolled back.
Preview may read an authenticated profile but must not modify Git
configuration.

#### Verification

Test both fields independently for override, existing value and provider
precedence, including one override, two overrides, missing values and the
provider preference switch. Verify that unnecessary provider access does not
occur and that required provider failures leave configuration unchanged.
Use isolated global/system configuration and temporary repositories to test
local-to-global fallback, local-only side effects, shared worktree behavior,
both previews and the Windows prerequisite. Verify provider parsing with
fixtures; use authorized accounts only for separately approved live checks.

#### Open provider decisions

| Decision or risk | Proposed owner | Next step |
| --- | --- | --- |
| GitHub noreply addresses have more than one documented format; the ID-plus-login pattern does not describe every older account. | Maintainer | Decide how to obtain or confirm the correct account-specific commit address and what to do when it cannot be established. See [GitHub's email reference](https://docs.github.com/en/account-and-profile/reference/email-addresses-reference#your-noreply-email-address). |
| Provider integration, supported GitLab hosts, credentials and exact CLI parameter names are not yet agreed. | Maintainer | Specify and verify supported hosts, authentication and interfaces for both providers; never expose tokens in arguments, logs or previews. |
| GitLab may return a configured commit email that is not private or may omit a needed value. | Maintainer | Verify how private and unusable commit-email values are represented; missing required values fail as specified. Users may provide an explicit override. See [GitLab's users API](https://docs.gitlab.com/api/users/#retrieve-the-current-user). |

## Delivery plan

<a id="plan-0001-git-identity-and-global-configuration"></a>
### PLAN-0001 - Git identity and global configuration

**Status:** Approved.

The developer owns implementation and local verification; the maintainer
confirms acceptance.

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Resolve provider design | FR-0001, FR-0002, FR-0032 | Confirm provider hosts, authentication, CLI parameters and GitHub noreply handling; document decisions before implementation. | None |
| 2. Implement identity resolution | FR-0001, FR-0002, FR-0032 | Test each field's precedence, both providers, offline overrides, local/global isolation and failure before writes. | Step 1 |
| 3. Implement preview and global defaults | FR-0003 through FR-0011, FR-0032, NFR-0001 | Test both scopes and non-mutating previews; verify all global settings and Windows prerequisites in isolated configuration. | Step 2 |
| 4. Verify end-to-end behavior | FR-0001 through FR-0011, FR-0032, NFR-0001 | Verify both scopes, failure handling and script help; perform live provider checks only with explicit authorization. | Steps 2-3 |

No live changes to a developer's global configuration are required for
automated verification.

## Delivered

| Deliverable | Purpose |
| --- | --- |
| [Set-GitGlobalConfig.ps1](../../../Set-GitGlobalConfig.ps1) | Configures global Git identity and defaults, with an opt-in repository-local identity operation. |
| [Set-GitGlobalConfig.Tests.ps1](../../../Set-GitGlobalConfig.Tests.ps1) | Verifies identity resolution, configuration scope, previews, defaults, and failure handling. |

