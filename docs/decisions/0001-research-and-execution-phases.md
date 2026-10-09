# 0001. Research and execution phases

Status: Proposed
Date: 2026-10-08

## Context

An Order that is too large for one Shot needs research before anyone changes code, and then several small, verified changes that land as separate commits. Today a Recipe is fixed when the Brew starts, Workers never commit, and Blend gathers Shot changes from Stations after review. None of that supports this flow.

The flow is named in `PLAN.md` (v0.3, item 5): Grind, Cupping, Dial-in, Pull, Taste, Blend.

## Decision

1. **A Brew has phases.** The first phase runs Cupping Shots. When every Cupping Shot is terminal, the Barista runs Dial-in, which adds Pull Shots to the same Brew. Pulls run within the Scale limit, and dependent Pulls run in sequence.
2. **Shots have a kind.** `research` marks a Cupping Shot. `execution` marks a Pull. A Recipe may omit the kind, which means `execution`, so existing Recipes keep their meaning.
3. **Cupping has no side effects.** A research Shot runs Pi with the read-only tools `read`, `grep`, `find` and `ls`, as the Filter's review does. It may not write files, run shell commands, or write to package caches. Its Station must be unchanged when it finishes; if it is not, the Shot is `incomplete`. Its findings are its report.
4. **Taste is the Pull's own check.** A Pull runs its verification commands before it commits. Commands that fail, or are not discovered, make the Pull `incomplete` and it makes no commit. Filter still reviews each Pull's changes after it finishes, so Taste does not replace Filter.
5. **Pulls commit; nothing else does.** A Pull that passes Taste commits its changes on its own branch in its own Station. This replaces the rule that Workers never commit. Research Shots never commit.
6. **Blend combines commits.** Blend takes a Brew's Pull commits, in dependency order, and applies them to the retained integration worktree as one commit. A conflict or a failed apply leaves the tabs, Stations and state intact, as before. This replaces the rule that Blend gathers Shot changes from Stations.
7. **The Register and Receipt accept Shots added during a Brew.** A new Receipt event, `shot_added`, records each Pull with its phase and origin. A Brew is complete when every phase is terminal.

## Consequences

`docs/architecture.md` must change in these sections, in the same change as the code:

- **Architecture diagram:** add the phases, Dial-in, and the Pull commits feeding Blend.
- **Components:** add Cupper, Dial-in, Pull and Taste.
- **Recipe contract:** a Recipe may declare a Shot's kind; Pulls are added by Dial-in and carry `origin: dial-in`.
- **Shot lifecycle:** add the two kinds, and the new `incomplete` causes (Taste failed, Cupping changed its Station).
- **Data flow:** add the phase barrier between Cupping and Pulls.
- **Blend:** redefine it as combining commits (decision 6).
- **Safety boundaries:** replace "Workers do not commit" with "only Pulls commit, after Taste", and add the Cupping rule.
- **Tray:** list the Cupping findings and each Pull's commit.

`specs/UBIQUITOUS_LANGUAGE_LATEST.md` gains Grind, Cupping, Dial-in, Pull and Taste, and Blend's definition changes.

## Open questions

- **Taste commands.** Should Taste reuse the Filter's discovery, which finds commands from the repository's own manifests? If so, a repository with no discoverable checks cannot run Pulls.
- **Overlapping Pulls.** Two Pulls may change the same file. Dial-in must either avoid overlapping paths or leave the conflict to Blend. The choice needs an explicit rule.
- **Machine-wide Scale.** Covered by v0.3 item 4; a phase barrier does not change it.
- **Dial-in as a Worker step.** Left to the Barista for now.
