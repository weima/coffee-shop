---
name: taste-driven-development
description: "Trigger: test authoring, unit tests, component tests, Playwright, E2E tests. Guide Workers to derive repository-conforming tests from the task and standards.md."
license: Apache-2.0
metadata:
  author: "Coffee Shop"
  version: "1.0"
---

## Activation Contract

Use when a Worker is assigned a Shot to derive, add, or change tests for a Beans repository, especially an MFE.

## Hard Rules

- Read the repository-root `standards.md`, existing tests, manifests, and test configuration before choosing a test approach.
- Preserve the repository's frameworks, scripts, commands, and configuration. Do not install dependencies or rewrite test setup.
- Test public behavior. Keep unit/component checks separate from browser-level checks.
- If `standards.md` or required test setup is missing, report the gap; do not invent project policy.

## Decision Gates

| Behavior | Test approach |
| --- | --- |
| Logic, component state, or API-boundary behavior | Use the repository's existing unit/component framework. |
| Real browser behavior not proven by unit/component tests | Add a small Playwright scenario only when the repository already supports it; follow its Playwright skill and conventions when available. |
| Test command or framework is unclear | Inspect existing scripts and configs; report ambiguity instead of changing them. |

## Execution Steps

1. Translate the Shot and `standards.md` into observable behaviors and acceptance scenarios.
2. For behavior changes, write a focused unit/component test first, confirm the expected failure, then implement the minimum change and refactor while green.
3. For E2E coverage, describe the user-visible scenario in Given/When/Then terms, then implement it with the repository's existing browser-test conventions. Do not duplicate logic already covered below the browser layer.
4. Run focused checks using existing repository commands. Filter owns discovery and execution of the repository's full existing unit/component and E2E suites.

## Output Contract

Report the test files changed, why each behavior belongs at that test level, commands and outcomes, and any missing standards or setup. Keep failing evidence visible; do not weaken a test just to make it pass.

## References

- [Coffee Shop architecture](../../docs/architecture.md)
- [Coffee Shop vocabulary](../../specs/UBIQUITOUS_LANGUAGE_LATEST.md)
