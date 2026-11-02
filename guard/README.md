# Coffee Shop guard

A Pi project extension that enforces the repository rules that agents otherwise
ignore. Prompt rules live in `AGENTS.md`; this makes two of them mechanical.

## Install

```sh
guard/install.sh <project-dir>          # annotate: allow, but attach the verdict
guard/install.sh <project-dir> --enforce # block raw build/test commands
guard/install.sh <project-dir> --uninstall
```

The installer writes two files into the target project and adds them, plus
`.rachel/`, to the repository's **local** exclude (`.git/info/exclude`). Nothing
is added to `.gitignore` and nothing is committed to the target repository.

```
<project>/.pi/extensions/coffee-shop-guard.ts   the extension (copy of guard/)
<project>/.pi/coffee-shop-guard.json            the policy (edit this)
```

For a worktree, `git rev-parse --git-path info/exclude` resolves to the shared
common directory, so the exclusion applies to every worktree of that repository.

## What it does

1. **Annotates every bash result** with the project's last Rachel verdict and its
   age, read from `.rachel/evidence/*/manifest.json`. The verdict arrives without
   the agent having to remember to ask for it, which is the failure this exists to
   fix.
2. **Blocks** commands the policy forbids, when installed with `--enforce`. The
   block message names the rule and the alternative, and the escape token.
3. **Announces** the active rules once per session with `sendMessage`, so the agent
   knows enforcement exists.

## Policy

`guard/policy.json` ships two rules: no raw `odin|go|cargo|bun|npm|pnpm|yarn
build|check|test`, and no raw `git worktree`. Add rules as data:

```json
{
  "id": "no-raw-build",
  "tool": "bash",
  "command": "(^|[;&|]\\s*)(odin|go|bun)\\s+(build|check|test)",
  "mode": "block",
  "message": "use `rachel verify <dir>` and read its verdict"
}
```

`mode` at the top level decides whether a block rule blocks (`block`) or only
annotates (`annotate`). A rule may set `"mode": "annotate"` to never block.

## Limits

- **Blocking is best effort.** It matches the command string. `bash -c "odin
  check"`, `env -i …`, or a `just` recipe that shells out to `odin` all pass. The
  evidence gate is the guarantee; this is the speed bump.
- **Annotation is the reliable part.** It runs on every bash result and cannot be
  routed around, because it does not depend on the command.
- **`CS_RAW=1` in a command always allows it.** A harness that cannot be
  overridden when it is wrong gets worked around silently.
- **The extension fails open.** A broken policy or missing evidence directory
  means no rules and no annotation, never a broken session.
- **No watcher management.** It reads evidence that Rachel already wrote; it does
  not start Rachel.

## Self-test

```sh
bun run guard/selftest.ts
```

Tests the pure parts: rule matching, escape handling, annotate-mode downgrade,
malformed policy, and reading the newest verdict from evidence.
