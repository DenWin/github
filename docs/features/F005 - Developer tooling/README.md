---
type: Feature dossier
title: F005 - Developer tooling
description: Reproducible development checks and dependencies.
status: draft
version: "0.1"
---

# F005 - Developer tooling

## Changelog

| Date | Version | Status | Change |
| --- | --- | --- | --- |
| 2026-11-19 | 0.1 | draft | Initial draft created. |

## Contents

- [Goal](#goal)
- [Functional requirements](#functional-requirements)
  - [FR-0030: Provide test tiers](#fr-0030-provide-test-tiers)
  - [FR-0031: Install pinned development modules](#fr-0031-install-pinned-modules)
- [Non-functional requirements](#non-functional-requirements)
  - [NFR-0003: Verify dependency archive hashes](#nfr-0003-verify-dependency-archive-hashes)
- [Specification](#specification)
  - [SPEC-0005: Reproducible developer tooling](#spec-0005-reproducible-developer-tooling)
- [Delivery plan](#delivery-plan)
  - [PLAN-0005: Reproducible developer tooling](#plan-0005-reproducible-developer-tooling)

## Goal

F005 gives maintainers a repeatable way to prepare development dependencies
and verify changes before delivery. It installs explicitly pinned modules only
after checking their archive hashes and manifests, and provides fast, full,
and proof check tiers so developers can get quick feedback while CI can run
broader integration and test-proof checks.

**Example:** A maintainer installs pinned modules into a fresh destination,
then runs the fast checks during development. CI can run the full suite on
Windows and Linux, while the proof tier challenges tests with incorrect
implementations to reveal tests that would not catch regressions.

**Stakeholder:** Maintainer

Prepare a reproducible development environment and obtain useful, dependable
evidence that changes pass the required checks before delivery.

## Functional requirements

<a id="fr-0030-provide-test-tiers"></a>
### FR-0030: Provide test tiers

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall provide fast, full, and test-proof check tiers. |
| **Acceptance criteria** | Inspection and test: the check runner selects the documented tiers and the proof reports tests not shown to fail under stubs. |

<a id="fr-0031-install-pinned-modules"></a>
### FR-0031: Install pinned development modules

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall install the explicitly pinned development modules into a caller-selected module root without overwriting an existing version. |
| **Acceptance criteria** | A fresh destination receives the pinned versioned modules; an existing destination version is refused. |

## Non-functional requirements

<a id="nfr-0003-verify-dependency-archive-hashes"></a>
### NFR-0003: Verify dependency archive hashes

| Section | Details |
| --- | --- |
| **Status** | Draft |
| **Priority** | High |
| **Requirement** | The system shall verify a pinned module archive's SHA-512 before installing it. |
| **Acceptance criteria** | A modified archive is rejected without installing that module. |

## Specification

<a id="spec-0005-reproducible-developer-tooling"></a>
### SPEC-0005 - Reproducible developer tooling

**Status:** Draft.

#### Summary

This specification defines verified installation of pinned development
dependencies and repeatable local quality checks.

#### Design

The dependency installation operation obtains pinned PowerShell Gallery
archives, verifies SHA-512 before extraction, checks the expected module
manifest, and installs under `<Destination>\<Module>\<Version>`. It does not
overwrite existing versions, import modules, modify `PSModulePath`, or install
implicit dependencies.

The checks operation provides fast, full, and proof tiers. The fast tier runs
the local workflow audit, PSScriptAnalyzer, and unit tests. The full tier adds
integration tests against real local Git repositories; the proof tier adds
test-failure proofs. Coverage output is diagnostic and does not establish a
quality threshold.

#### Dependency installer contract

The PowerShell 7 installer requires a destination and obtains each exact
version from PowerShell Gallery. The proposed version and hash data shall
contain the following pins; update the authoritative pin data and this table
together when the reviewed pins change.
The SHA-512 is of the downloaded archive, not the extracted directory.

| Module | Version | SHA-512 |
| --- | --- | --- |
| Pester | `6.2.0` | `BBD9E5F171B6B8CBFCE9CD5F4183AC9CA71FB3C69C1964D6BA1C728C89B40EA2DDAB9BD1FEAF5DCCFAAB35FD2B677EA0CD7705DF20ACD241F9DC58D0F9FB13E8` |
| PSScriptAnalyzer | `1.25.0` | `E7FB573262E604BAB29914AE62921D24B97C2F88B519B41277B403EF6CE163F14B7D1B36DC73449A68E5AE5A8D9502891B10C264131FD1813ADF29BF131C1663` |
| powershell-yaml | `0.4.12` | `55CE432F2C3B84BB022FAC85952BF3B1D5145A681FAA8337E579916AFB4A3B3DFB187060DE9FAF5B168EFFDC12F0C6E9B735ACA5D5017154464AA01D9499AD52` |

Before downloading, require matching module names and versions in the version
and hash tables. Validate module names as letters/digits followed by
letters/digits, dot or hyphen, versions as three numeric components, and
hashes as 128 hex digits. Refuse an existing `<Destination>/<Name>/<Version>`,
verify SHA-512 before extracting, and require a root `<Name>.psd1` in the
archive. Use isolated temporary storage and clean temporary files even on
failure. If cleanup also fails,
report it without replacing the installation error. Already installed modules
are not rolled back; the installer does not import modules, change
`PSModulePath`, or install transitive dependencies. Pins detect changes but do
not independently establish publisher trust.

#### Checks and proofs contract

The checks operation imports all pinned modules even if checks are skipped.
By default, enforce the local workflow audit, analyze every PowerShell script
recursively using the repository analyzer configuration, and run Pester
excluding `Integration` tests. The interface permits skipping both audit and
analysis together, skipping Pester and its reports, selecting the full tier,
requesting coverage, and requesting proof. The full tier includes integration
tests and writes `TestResults/testResults.xml`. Coverage additionally writes
`TestResults/coverage.xml` as a diagnostic, not a threshold. Proof runs even
when Pester is skipped; full and proof can be combined. Interface option names
are to be chosen during design.
Audit/import errors terminate immediately; analyzer findings, non-passing
Pester results and proof problems of kinds `Failed`, `Uncaught` or `Unproven`
produce exit code 1.

The analyzer enables Error, Warning and Information severities, and only these
rules: `PSAvoidUsingCmdletAliases`, `PSAvoidGlobalVars`,
`PSUseDeclaredVarsMoreThanAssignments`, `PSUseApprovedVerbs`,
`PSUseSingularNouns`, `PSAvoidUsingInvokeExpression`,
`PSAvoidUsingPlainTextForPassword`, `PSMisleadingBacktick`,
`PSUseCompatibleSyntax`, `PSPlaceOpenBrace`, `PSPlaceCloseBrace`,
`PSUseConsistentIndentation`, `PSUseConsistentWhitespace`, and
`PSAvoidTrailingWhitespace`. Syntax targets PowerShell 7.0. Enable the
formatting rules with these options: opening braces on the same line and a
newline after them, closing braces followed by a newline, and both brace
rules ignore one-line blocks; allow an empty line before a closing brace.
Indent with four spaces and increase indentation on the first line of a
continued pipeline. Check whitespace around opening braces, opening
parentheses, operators, separators, inner braces and pipes. The
[PSScriptAnalyzer rule reference](https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/readme)
defines these external identifiers.

The Pester configuration discovers tests under the script root, returns
results, exits by default, uses detailed output and writes NUnit XML. Coverage
is off by default and includes root product scripts, excluding tests and
test tooling. Automated integration fixtures use temporary real Git
repositories and isolated global/system Git configuration, never the
developer's repositories or global configuration.

The proof operation accepts an optional list of function names and a parallel
process limit from 1 to 64 (default processor count). Associate each top-level
Pester `Describe` with the function it tests, including any needed explicit
mappings. For each mapped group, run a baseline and challenge the function
with empty-result and unexpected-result stubs plus behavior-specific stubs.
Run proofs in isolated noninteractive PowerShell processes with the pinned
Pester version and compare expanded test paths:

| Kind | Condition | Fails proof? |
| --- | --- | --- |
| `Failed` | Baseline failure, no baseline tests, or stub run without results | Yes |
| `Unproven` | A baseline-passing test fails under none of its stubs | Yes |
| `Uncaught` | A stub causes no test in the Describe to fail | Yes |
| `Unmapped` | No target function was found for a Describe | No; report for review |

Behavior-specific stubs must challenge negative assertions: hook installation
ignores preview, cleanup removes protected worktrees or ignores selection,
worktree creation overwrites upstream, and synchronization falsely reports
failure. Report the affected Describe, function and detail. Proof measures
whether tests detect these chosen wrong implementations, not correctness for
all possible defects.

#### Failure and safety behavior

Hash, manifest, network, and filesystem failures stop installation. Already
installed modules remain in place. Temporary downloads are cleaned up and
cleanup errors are reported without masking the original failure. Check
failures, analyzer findings, and unproven tests produce a nonzero result.

#### Verification

Test installation using local valid, modified, and malformed archive fixtures,
including overwrite refusal. Run each check tier against isolated fixtures and
verify that failures are propagated to the caller.


## Delivery plan

<a id="plan-0005-reproducible-developer-tooling"></a>
### PLAN-0005 - Reproducible developer tooling

**Status:** Draft.

#### Work breakdown

| Step | Requirements | Work and exit evidence | Depends on |
| --- | --- | --- | --- |
| 1. Confirm and verify dependency inputs | FR-0031, NFR-0003 | Review proposed module versions, archive hashes and expected manifests; tests cover valid, modified, and malformed local archives. | None |
| 2. Implement safe installation | FR-0031, NFR-0003 | Install only verified modules to a fresh destination; test overwrite refusal, cleanup, and failure reporting. | Step 1 |
| 3. Provide test tiers | FR-0030 | Implement fast and full check tiers with isolated unit and real-Git integration tests; document command behavior. | Steps 1-2 |
| 4. Verify the developer workflow | FR-0030, FR-0031, NFR-0003 | Install into a fresh destination and run the applicable checks; failures must produce a failing exit status. | Steps 1-3 |

Integrate cross-platform CI and shared quality gates through
[PLAN-0006](../F000%20-%20Cross-cutting%20quality/README.md#plan-0006-cross-cutting-quality-and-verification).

