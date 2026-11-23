---
type: Feature dossier
title: F000 - Cross-cutting quality
description: Quality requirements and verification across features.
status: draft
version: "0.1"
---

# F000 - Cross-cutting quality

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Non-functional requirements](#non-functional-requirements)
  - [NFR-0004: Remove worktrees without force](#nfr-0004-remove-worktrees-without-force)
  - [NFR-0005: Keep previews non-mutating](#nfr-0005-keep-previews-non-mutating)
  - [NFR-0006: Report operation failures](#nfr-0006-report-operation-failures)
  - [NFR-0007: Distinguish unverified security states](#nfr-0007-distinguish-unverified-security-states)
  - [NFR-0008: Limit CI token permissions](#nfr-0008-limit-ci-token-permissions)
  - [NFR-0009: Run CI on Windows and Linux](#nfr-0009-run-ci-on-windows-and-linux)
  - [NFR-0010: Use isolated real-Git test fixtures](#nfr-0010-use-isolated-real-git-test-fixtures)
  - [NFR-0011: Document script help](#nfr-0011-document-script-help)
- [Specification](#specification)
  - [SPEC-0006: Cross-cutting quality and verification](#spec-0006-cross-cutting-quality-and-verification)
- [Delivery plan](#delivery-plan)
  - [PLAN-0006: Cross-cutting quality and verification](#plan-0006-cross-cutting-quality-and-verification)

## Goal

F000 establishes shared quality guarantees for F001-F005 so that operations
remain safe, failures are visible, and results can be trusted across supported
platforms. It brings together safeguards such as non-mutating previews,
non-forced cleanup, explicit reporting of failures and unverified security
states, least-privilege CI, cross-platform checks, isolated real-Git tests,
and discoverable script help. These constraints complement the feature goals;
they do not introduce a separate user operation.

**Example:** A cleanup preview must leave worktrees and Git state unchanged,
and an unsafe worktree must not be force-removed. If a live security check
cannot be verified, it remains unknown rather than passing; CI then exercises
the checks on Windows and Linux with only the permissions it needs.

**Stakeholder:** Developer

Rely on consistent safeguards across Git operations, including previews that
do not mutate state and clear reports when an operation cannot complete safely.

**Stakeholder:** Maintainer

Verify the tools through repeatable, isolated tests and cross-platform CI, with
failures and security uncertainty surfaced rather than hidden.

## Non-functional requirements

<a id="nfr-0004-remove-worktrees-without-force"></a>
### NFR-0004: Remove worktrees without force

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Related features** | [F003 - Stale worktree cleanup](../F003%20-%20Stale%20worktree%20cleanup/README.md#goal) |
| **Requirement** | Cleanup shall use non-forced Git worktree removal so that Git can reject unsafe removal. |
| **Acceptance criteria** | Inspect the Git invocation and test that dirty worktrees remain untouched. |

<a id="nfr-0005-keep-previews-non-mutating"></a>
### NFR-0005: Keep previews non-mutating

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Related features** | [F001 - Git configuration](../F001%20-%20Git%20configuration/README.md#goal), [F002 - Repository cloning and synchronization](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#goal), [F003 - Stale worktree cleanup](../F003%20-%20Stale%20worktree%20cleanup/README.md#goal), [F004 - Repository security](../F004%20-%20Repository%20security/README.md#goal) |
| **Requirement** | Preview modes shall not perform the changes they preview, even though reads and remote queries may occur. |
| **Acceptance criteria** | For each preview mode, compare local configuration, filesystem, Git, and remote state before and after the operation. |

<a id="nfr-0006-report-operation-failures"></a>
### NFR-0006: Report operation failures

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Related features** | [F005 - Developer tooling](../F005%20-%20Developer%20tooling/README.md#goal) |
| **Requirement** | An operation shall expose failures instead of reporting incomplete work as successful. |
| **Acceptance criteria** | Inject failures at external-operation boundaries and verify a non-success result and actionable diagnostics. |

<a id="nfr-0007-distinguish-unverified-security-states"></a>
### NFR-0007: Distinguish unverified security states

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Related features** | [F004 - Repository security](../F004%20-%20Repository%20security/README.md#goal) |
| **Requirement** | Live security checks shall distinguish an unverified state from a passing state. |
| **Acceptance criteria** | Exercise inaccessible and unsupported settings; verify they are reported as unknown and can fail enforcement. |

<a id="nfr-0008-limit-ci-token-permissions"></a>
### NFR-0008: Limit CI token permissions

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Related features** | [F004 - Repository security](../F004%20-%20Repository%20security/README.md#goal) |
| **Requirement** | CI shall grant only the workflow-token permissions required by each job. |
| **Acceptance criteria** | Inspect workflow permission declarations and verify least privilege in pull-request checks. |

<a id="nfr-0009-run-ci-on-windows-and-linux"></a>
### NFR-0009: Run CI on Windows and Linux

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | Medium |
| **Related features** | [F005 - Developer tooling](../F005%20-%20Developer%20tooling/README.md#goal) |
| **Requirement** | The checks job shall run on both Windows and Linux. |
| **Acceptance criteria** | Execute the same required check tier on both operating systems in CI. |

<a id="nfr-0010-use-isolated-real-git-test-fixtures"></a>
### NFR-0010: Use isolated real-Git test fixtures

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | Medium |
| **Related features** | [F005 - Developer tooling](../F005%20-%20Developer%20tooling/README.md#goal) |
| **Requirement** | Tests shall exercise pure steps directly and integration boundaries with isolated real local Git fixtures rather than mocks. |
| **Acceptance criteria** | Review test design and run integration tests using temporary local repositories and configuration files. |

<a id="nfr-0011-document-script-help"></a>
### NFR-0011: Document script help

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | Medium |
| **Related features** | [F005 - Developer tooling](../F005%20-%20Developer%20tooling/README.md#goal) |
| **Requirement** | Each executable script shall expose discoverable PowerShell help describing its operation and parameters. |
| **Acceptance criteria** | Use `Get-Help -Full` for each entry point and verify parameters, examples, prerequisites, outputs, and side effects are documented. |

## Specification

<a id="spec-0006-cross-cutting-quality-and-verification"></a>
### SPEC-0006 - Cross-cutting quality and verification

**Status:** Draft.

This specification defines quality constraints shared by the feature
specifications for [Git configuration](../F001%20-%20Git%20configuration/README.md#spec-0001-git-identity-and-global-configuration),
[repository synchronization](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#spec-0002-repository-cloning-and-synchronization),
[worktree cleanup](../F003%20-%20Stale%20worktree%20cleanup/README.md#spec-0003-stale-worktree-cleanup),
[security](../F004%20-%20Repository%20security/README.md#spec-0004-repository-security-audit-and-remediation), and
[developer tooling](../F005%20-%20Developer%20tooling/README.md#spec-0005-reproducible-developer-tooling).

#### Shared design constraints

- Mutating operations must not use forced worktree removal; previews may read
  local or remote state but must not perform their corresponding writes.
- Operation failures and partial completion must be reported explicitly.
  Unknown security states must remain distinct from passed checks.
- Tests use isolated local Git repositories and configuration; managed
  repositories and developer global configuration are not test fixtures.
- CI limits token permissions and runs the required checks on Windows and Linux.
- Every PowerShell script entry point provides discoverable comment-based help
  for parameters, prerequisites, outputs, and side effects.

Shared behavior includes GitHub location and worktree-list parsing. Pure
selection and planning remain separable from Git, GitHub CLI, and filesystem
boundaries.

#### Shared operation contracts

Pass native command arguments as structured values and handle their exit
statuses explicitly. The shared selector and GitHub location format are specified by
[SPEC-0002](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#spec-0002-repository-cloning-and-synchronization).
Normalize filesystem paths to full paths without trailing separators; compare
paths case-insensitively on Windows and ordinally elsewhere. Parse Git's
registered worktree information into path, branch, bare and locked properties,
preserving embedded whitespace. Loading entry points for tests performs no
operation.

The shared test helpers capture normal, warning and host output separately.
Temporary source repositories start on `main` with one empty commit using a
test-only identity; optional branches and reftable fixtures allow testing
case-distinct refs. No managed repository is a test fixture.

**Open compatibility issue:** the
[Git 2.37 init reference](https://git-scm.com/docs/git-init/2.37.0) does not
document the ref-format selection option, while the
[Git 2.44 reference](https://git-scm.com/docs/git-init/2.44.0) does. The
maintainer must verify the minimum Git version for reftable fixtures and keep
ordinary fixtures compatible with the supported Git version; the Git 2.37
product prerequisite alone does not establish reftable test compatibility.

Repository formatting defaults to UTF-8, LF, final newline, four-space
indentation and trimmed trailing whitespace. YAML and JSON use two spaces;
Markdown retains trailing whitespace. Git attributes normalize text to LF,
explicitly including PowerShell scripts, data files, Markdown and hook files.

#### CI, hooks and repository controls

The following proposed delivery configuration does not assume that external
services or branch protection are already configured. All GitHub Actions use
full commit SHA pins and workflow-level permissions are empty.

| Workflow/job | Trigger and runner | Contract |
| --- | --- | --- |
| CI / dependency-review | Pull request; Ubuntu | `contents: read`, 10-minute timeout; checkout without persisted credentials; dependency review fails for runtime, development or unknown scopes. |
| CI / checks | Push to `main`, pull request, or manual dispatch; Windows and Ubuntu matrix | `contents: read`, 15-minute timeout, fail-fast disabled; install verified modules, run the full tier, and upload each OS's test results even on failure with 7-day retention. |
| CI / proof | Push to `main` or manual dispatch, not pull requests; Ubuntu | `contents: read`, 30-minute timeout; install verified modules and run proof without audit, analysis, or the ordinary test run. |
| OpenSSF Scorecard | Push to `main` or weekly Monday 03:30 UTC; Ubuntu | `contents: read`, 15-minute timeout; write JSON without publishing it, upload as a 7-day artifact and fail if the file is absent. |

CI cancels in-progress runs in the same workflow/ref group. Its checkout,
dependency-review, upload-artifact and Scorecard action pins respectively are
`3d3c42e5aac5ba805825da76410c181273ba90b1`,
`a1d282b36b6f3519aa1f3fc636f609c47dddb294`,
`cf430e030ddbb5b0abf93d22962f4752f3646cd9`, and
`fa7117db83c52d787ae5a89f350999701505d78e`. Scorecard's own container image
is tag-referenced and is not pinned by that action SHA. Dependabot checks
GitHub Actions weekly at the repository root, groups updates and uses a
seven-day default cooldown.

The opt-in pre-commit hook checks staged whitespace, then runs the audit and
analysis without the ordinary test run; pre-push runs the default fast check.
Both run from the Git root using PowerShell without a profile, inspect the
working tree, and can be bypassed. Hook installation and protection of an existing hook path are
specified by [SPEC-0004](../F004%20-%20Repository%20security/README.md#spec-0004-repository-security-audit-and-remediation).

#### Verification

Verify each preview against before/after state at its mutation boundary. Exercise
operation failures and partial outcomes. Run isolated real-Git integration
tests, inspect CI permissions and platform results, and check help for every
script entry point. Applicable measurable performance, reliability,
accessibility, recovery, and cost targets remain open for stakeholder agreement.

## Delivery plan

<a id="plan-0006-cross-cutting-quality-and-verification"></a>
### PLAN-0006 - Cross-cutting quality and verification

**Status:** Draft.

Its integration gates depend on the feature plans for [Git configuration](../F001%20-%20Git%20configuration/README.md#plan-0001-git-identity-and-global-configuration),
[repository synchronization](../F002%20-%20Repository%20cloning%20and%20synchronization/README.md#plan-0002-repository-cloning-and-synchronization),
[worktree cleanup](../F003%20-%20Stale%20worktree%20cleanup/README.md#plan-0003-stale-worktree-cleanup),
[security](../F004%20-%20Repository%20security/README.md#plan-0004-repository-security-audit-and-remediation), and
[developer tooling](../F005%20-%20Developer%20tooling/README.md#plan-0005-reproducible-developer-tooling).

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Enforce safe shared behavior | NFR-0004 through NFR-0007 | Verify non-forced removal, non-mutating previews, explicit failure reporting, and distinct unknown security states in their owning feature tests. | PLAN-0001 through PLAN-0005 |
| 2. Establish isolated quality gates | NFR-0010 | Run tests against isolated real-Git fixtures and verify they do not alter managed repositories or developer-global configuration. | Step 1 |
| 3. Configure least-privilege CI | NFR-0008, NFR-0009 | Limit workflow token permissions and run required checks on Windows and Linux; inspect successful and failing CI paths. | Step 2 |
| 4. Complete entry-point documentation | NFR-0011 | Verify every script has discoverable comment-based help for parameters, prerequisites, outputs, and side effects. | PLAN-0001 through PLAN-0005 |
| 5. Perform release verification | NFR-0004 through NFR-0011 | Run the full and proof tiers, review both platform results, and resolve or explicitly record remaining verification gaps. | Steps 1-4 |

The maintainer confirms any measurable reliability, accessibility, performance,
recovery, or cost thresholds before they become release gates.

