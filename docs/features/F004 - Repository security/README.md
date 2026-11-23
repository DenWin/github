---
type: Feature dossier
title: F004 - Repository security
description: Workflow audits and deliberate repository security changes.
status: draft
version: "0.1"
---

# F004 - Repository security

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Functional requirements](#functional-requirements)
  - [FR-0026: Audit local workflow YAML](#fr-0026-audit-local-workflow-yaml)
  - [FR-0027: Live repository audit](#fr-0027-live-repository-audit)
  - [FR-0028: Require explicit security remediation](#fr-0028-require-explicit-security-remediation)
  - [FR-0029: Fail on unresolved findings when requested](#fr-0029-enforce-findings)
- [Non-functional requirements](#non-functional-requirements)
  - [NFR-0002: Preserve existing Git hook configuration](#nfr-0002-preserve-existing-git-hook-configuration)
- [Specification](#specification)
  - [SPEC-0004: Repository security audit and remediation](#spec-0004-repository-security-audit-and-remediation)
- [Delivery plan](#delivery-plan)
  - [PLAN-0004: Repository security audit and remediation](#plan-0004-repository-security-audit-and-remediation)

## Goal

F004 helps maintainers and GitHub administrators find and address repository
security gaps without treating an incomplete audit as a clean bill of health.
It combines local checks of GitHub Actions workflow files with checks of
security settings on an explicitly selected GitHub repository. Findings
distinguish failed checks from checks that could not be verified. Supported
GitHub changes can be previewed and applied only by explicit choice; workflow
files are not rewritten, and an audit should be rerun after remediation. The
feature informs security decisions but does not certify a repository as secure.

**Example:** A local audit might flag an action that is not pinned to a commit.
Separately, a GitHub administrator could check a selected repository, preview
changing its default workflow-token permissions to read-only, explicitly apply
that change, and rerun the audit. If branch protection cannot be verified, the
result remains unknown for manual review rather than being reported as secure.

**Stakeholder:** Maintainer

Maintain a reviewable process for identifying gaps in repository workflows
and policies and deciding which supported fixes should be applied.

**Stakeholder:** GitHub administrator

Assess the security settings of an explicitly selected GitHub repository and
authorize supported changes, with unverified results kept distinct from passing
checks.

## Functional requirements

<a id="fr-0026-audit-local-workflow-yaml"></a>
### FR-0026: Audit local workflow YAML

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall audit local workflow YAML without requiring GitHub access. |
| **Acceptance criteria** | Local-only mode examines workflow files; malformed YAML is reported as an error. |

<a id="fr-0027-live-repository-audit"></a>
### FR-0027: Live repository audit

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall audit the specified GitHub repository's security settings using an explicit target. |
| **Acceptance criteria** | An absent or owner-only live target is rejected rather than inferred from the local remote. For each check in the live-check contract, exercise passing, failing and unavailable responses; branch protection remains a manual-review finding. |

<a id="fr-0028-require-explicit-security-remediation"></a>
### FR-0028: Require explicit security remediation

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall apply supported security remediations only when explicitly requested. |
| **Acceptance criteria** | Inspection and demonstration: an ordinary audit makes no GitHub changes; explicit preview of remediation reports changes without applying them. |

<a id="fr-0029-enforce-findings"></a>
### FR-0029: Fail on unresolved findings when requested

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | When enforcement is requested, the system shall fail after emitting findings if any remain `Fail` or `Unknown`. |
| **Acceptance criteria** | Both statuses cause failure; `Applied` alone does not establish a verified clean audit. |

Inaccessible or unverifiable checks are governed by
[NFR-0007](../F000%20-%20Cross-cutting%20quality/README.md#nfr-0007-distinguish-unverified-security-states).

## Non-functional requirements

<a id="nfr-0002-preserve-existing-git-hook-configuration"></a>
### NFR-0002: Preserve existing Git hook configuration

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall refuse to overwrite a different local hooks configuration when installing its hooks. |
| **Acceptance criteria** | Integration test: an existing different `core.hooksPath` is preserved. |

## Specification

<a id="spec-0004-repository-security-audit-and-remediation"></a>
### SPEC-0004 - Repository security audit and remediation

**Status:** Draft.

This specification defines local workflow auditing, optional GitHub settings
checks, and explicitly requested remediations.

#### Design

The security audit examines local workflow YAML and can inspect GitHub.com
repository settings for an explicitly supplied repository. Local-only mode
disables GitHub API calls. The local repository root is selectable. Supported
remediations require an explicit apply choice; hook installation additionally
requires a separate opt-in. Enforcement controls whether unresolved findings
fail the run.

Findings expose `Id`, `Severity`, `Target`, `Status`, `Message`, and `Fix`.
Statuses distinguish failed checks, unknown/unverified states, and API-accepted
changes. Workflow YAML is audited but never rewritten. Git hook installation
must preserve an existing `core.hooksPath` configuration.

#### Interface and findings

The local path defaults to the audit entry point's directory. The explicit
GitHub.com target is an `owner/name`, repository URL or branch URL, with any
branch ignored. It is required unless local-only mode is selected and is
never inferred from the local remote. Local-only mode, applying changes,
hook installation, and enforcement are off by default. Hook installation
requires applying changes; preview and confirmation govern each supported
change. Local auditing requires the pinned `powershell-yaml`; live checks
require GitHub access. Interface option names are to be chosen during design.

Findings are objects with string `Id`, `Severity`, `Target`, `Status`,
`Message` and nullable `Fix` containing the planned request. Status is `Fail`,
`Unknown`, or `Applied`; passing checks generally emit no finding. Severity
is `High`, `Medium`, or `Low` as specified below. Emit findings before
enforcing findings; malformed YAML and invalid workflow structure
are terminating errors, not passing findings. No finding is a security
certification.

#### Local workflow checks

Inspect only `.yml` and `.yaml` files directly inside `.github/workflows`.
When none exist, emit `workflow.missing` (Medium). Parse YAML as mappings;
the root and `jobs` must be mappings. For each workflow and job apply:

| Finding ID | Severity | Condition |
| --- | --- | --- |
| `workflow.permissions` | Medium | Missing or non-read-only workflow permissions; a mapping containing only `read`/`none`, including empty, or `read-all` passes. |
| `workflow.privileged-trigger` | High | Trigger includes `pull_request_target` or `workflow_run`. |
| `job.permissions` | Medium | An explicit job permission is not read-only by the same rule. |
| `workflow.pin` | Medium | A non-local reusable workflow lacks a 40-hex commit suffix. A reusable-workflow job is not checked for timeout, runner or steps. |
| `job.timeout` | Low | A regular job lacks a numeric timeout greater than zero and at most 30 minutes. |
| `job.runner` | High | The serialized `runs-on` contains `self-hosted`. |
| `step.expression` | Medium | A `run` value contains `${{`. |
| `action.pin` | Medium | A non-local action lacks a 40-hex commit suffix, or a `docker://` action lacks an `@sha256:` suffix with 64 hex digits. |
| `checkout.credentials` | Medium | `actions/checkout@*` does not set `with.persist-credentials` to false. |

Local actions beginning `./` are exempt from pin checks. These are pattern
checks rather than shell, action-trust or nested-action analysis; findings
require manual review and workflow files are never automatically rewritten.

#### Live check and remediation contract

Refer to the [GitHub REST API documentation](https://docs.github.com/en/rest?apiVersion=2022-11-28)
for the version-specific meaning of GitHub settings. Each failed policy check
is Medium with a fix; an unsuccessful response or missing required field is
`Unknown` without a fix, except for the special cases below.

| Finding ID | Passing condition | Remediation |
| --- | --- | --- |
| `github.actions-policy` | Actions are enabled, SHA pinning is required, and allowed actions are `selected` or `local_only`. | Require SHA pins; preserve enabled and `local_only` when known, otherwise use `selected` and, if policy data is unusable, disable Actions. |
| `github.workflow-token` | Default workflow token permissions are read-only and pull-request approval is disabled. | Set those two values. |
| `github.action-sources` | Skip for `local_only`; if policy is `all`, fail without querying the selected list. Otherwise GitHub-owned actions are allowed, verified creators are not, and the only allowed pattern is `ossf/scorecard-action@*`. | Set those three values, replacing other exceptions. |
| `github.dependabot` | Automated security fixes are enabled and not paused. | Enable vulnerability alerts first, then automated security fixes. |
| `github.secret-scanning` | Secret scanning and push protection are enabled. | Enable both settings. |
| `github.private-reporting` | Private vulnerability reporting is enabled. | Enable it. |
| `github.delete-merged-branches` | Automatic deletion of merged branches is enabled. | Enable it. |
| `github.alerts` | Vulnerability alerts are enabled. An explicit disabled response is `Fail`; other errors, including generic 404, are `Unknown`. | Enable alerts only for the explicit disabled result. |
| `github.branch-protection` | Inspect the default branch, classic protection and branch rules; always emit `Unknown` requiring manual review of reviews, checks, force-push/deletion and bypass. | None. |

Run local and live checks before applying findings. Apply only findings with
fixes, in their emitted order and subject to preview and confirmation; stop on
a failed request, without rolling back earlier requests. An accepted request
changes the finding to `Applied`, not verified; rerun the audit. Preview leaves
findings unresolved. Hook installation checks that both `.githooks/pre-commit`
and `.githooks/pre-push` exist, refuses a different local `core.hooksPath`,
marks them executable on non-Windows, sets the local value to `.githooks`,
and reads it back. It does not install dependencies.

#### Failure and safety behavior

The target repository is never inferred from local remotes. Unsupported,
inaccessible, or incomplete checks remain visible as unknown rather than being
reported as secure. Remediation is opt-in and supports preview and confirmation.
An `Applied` result means the API accepted the request, not that a later audit
verified the state. Partial changes are not rolled back.

#### Verification

Use local workflow fixtures to test YAML rules and finding classification.
Test hook behavior in temporary repositories. Demonstrate GitHub API checks and
remediations only against a dedicated test repository with explicit
authorization; rerun the audit after applying changes.

## Delivery plan

<a id="plan-0004-repository-security-audit-and-remediation"></a>
### PLAN-0004 - Repository security audit and remediation

**Status:** Draft.

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Confirm policy and implement local audit | FR-0026, FR-0027, FR-0029 | Confirm proposed checks and fixes; add YAML fixture tests for local checks and clear finding messages. | None |
| 2. Require explicit API target | FR-0027, NFR-0007 | Test explicit `owner/repository` handling, local-only operation, and unknown outcomes for inaccessible or unsupported checks. | Step 1 |
| 3. Add opt-in remediation | FR-0028 | Preview supported changes, require explicit application, and test that YAML is not rewritten. | Step 2 |
| 4. Protect existing hook configuration | NFR-0002 | Test hook installation in temporary repositories and refusal to replace a different `core.hooksPath`. | Step 3 |
| 5. Verify audit and remediation | FR-0026 through FR-0029, NFR-0002, NFR-0007 | Exercise findings and remediation decisions with fixtures; demonstrate live behavior against an authorized dedicated test repository, then rerun the audit. | Steps 1-4 |

Live verification requires explicit GitHub authorization and must not modify a
managed repository.

