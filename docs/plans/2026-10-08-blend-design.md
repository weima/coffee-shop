# Blend: consolidate a Brew into one commit

**Status:** Proposed. The name and one-commit outcome are agreed; implementation has not started.

## Goal

After the Barista reviews a Brew's Tray, provide one explicit action that gathers the Shot changes into one local commit, closes the completed Herdr tabs, removes the per-Shot Station worktrees, and leaves one integration worktree for the owner to push and use for a PR.

## Proposed command

```sh
coffee-shop blend <brew-id>
```

`collect` remains the review and evidence step. `blend` is a separate, explicit integration step. Workers continue not to commit; Blend creates one commit from their combined Station changes. It never pushes, opens a PR, or removes the final integration worktree.

## Proposed flow

1. Require a terminal Brew and a completed `collect`; the Barista reviews the Tray and invokes `blend`.
2. Create one integration worktree from the Brew's recorded Beans base commit.
3. Apply every Shot's tracked, untracked, and deleted-file changes in Recipe order, then create exactly one commit containing the combined result.
4. Only after that commit succeeds, close this Brew's Herdr tabs and remove its per-Shot Station worktrees. Preserve Brew state, reports, and Filter evidence.
5. Print the commit hash and integration-worktree path. Leave that worktree available for the owner to push and create a PR. Remove it only after a separate, explicit request once the owner is done with it.

The operation is scoped to one Brew; it does not clean up Stations from other or historical Brews.

## Failure behavior

If a Shot is not eligible for delivery, changes conflict, or the combined commit cannot be created, stop before removing Stations or closing tabs. Keep the original worktrees and Brew state available for inspection or recovery. A successful commit is the gate for cleanup.

## Open decisions

- Should Blend require every Shot to be `completed`, or allow the Barista to select completed Shots from a partially failed Brew? Recommended: require all Shots to be completed for the first version.
- Should the commit subject be supplied with `--message`, or derived from the Order? Recommended: require an explicit Conventional Commit subject rather than guessing a change type.
- Where should the integration worktree live? Recommended: under the Brew state directory, with its path printed by Blend.
- Should cleanup remove per-Shot branch refs as well as their worktrees? The request specifies worktree removal; recommended: retain branch refs until a separate cleanup policy is approved.

## Verification goals

- A successful multi-Shot Brew yields one integration worktree and exactly one commit containing all Shot changes.
- Herdr tabs and per-Shot worktrees are removed only after the commit succeeds; Brew state and reports remain readable.
- A conflict, failed Shot, or commit error preserves the source Stations and does not push or create a PR.
- Repeating `blend` cannot create a second delivery commit or delete the retained integration worktree.
