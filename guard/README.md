# Coffee Shop guard

A Pi project extension that enforces the repository rules that agents otherwise
ignore. Prompt rules live in `AGENTS.md`; this makes two of them mechanical.

## Coffee Shop installs it with `--enforce`

This repository is the harness, so Rachel is the default verification path here:

```sh
guard/install.sh . --enforce
```

That blocks raw `odin`/`go`/`bun` build, check and test commands (escape: `CS_RAW=1`)
and puts the commit gates in blocking mode, so a commit needs a fresh, passing
`rachel verify` verdict. Target projects get the same guard only if their owner
asks for it.

## Where it goes

Install it into **Coffee Shop only**, not into the projects Coffee Shop works on:

```sh
guard/install.sh .            # annotate: allow, but attach the verdict
guard/install.sh . --enforce  # block raw build/test commands
guard/install.sh . --uninstall
```

A session started in Coffee Shop can be asked to work on another repository. The
guard resolves the target project **per command** (`cd`, `git -C`, absolute paths,
then a walk up to the nearest justfile), reads *that* project's evidence, and
blocks only when that project is a Rachel project. A command that names a
non-Rachel directory resolves to nothing, so the harness stays out of the way.

That is why nothing is installed into the target project: the rules travel with
the session, not with the repository being edited.

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

1. **Pushes a changed verdict into the context** on every turn start
   (`pi.sendMessage(..., {triggerTurn: false})`), reading `.rachel/last.json`,
   which Rachel writes after every verify, pass or fail. One line, no extra turn,
   and the agent never has to remember to go looking.
2. **Annotates only the commands that duplicate Rachel** — the ones a rule already
   matches. Annotating every bash result pays the cost on every call and collects
   the benefit only when the call was a redundant check.
3. **Blocks** commands the policy forbids, when installed with `--enforce`. The
   block message names the rule and the alternative, and the escape token.
4. **Announces** the active rules once per session, so the agent knows enforcement
   exists.

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

## Gates on `git commit`

A commit is the point of no return, so it gets checks rather than advice. When a
command is `git commit`, the guard evaluates four gates:

- **fresh verdict** — the newest verdict must be newer than the newest `.odin` file
  or justfile. A verdict older than the source is *stale* and does not count;
- **passing verdict** — `ok: true` in `.rachel/last.json`;
- **required stages** — `requireStages` in the policy, default `["check"]`. Where
  the test recipe is cheap, ask for `["check", "test"]`;
- **not a merged branch** — if `gh pr view <branch>` reports `MERGED`, the commit
  is refused with "create a new branch". This is the mistake the guard's author
  made four times in one session.

In `annotate` mode each gate appends a warning to the commit's output; in `block`
mode it refuses the command. `CS_RAW=1` overrides everything, deliberately.

## Token shape

The point is transport, not content: Rachel delivers the same diagnostics, so it
cannot reduce the tokens needed to fix an error. It can reduce:

- **turns**: a verdict that arrives with `triggerTurn: false` costs no tool call,
  and replaces an `odin check` / `just test` round trip;
- **output**: one summary line, no snippets, capped errors;
- **repetition**: the same verdict is pushed once, and only rule-matched commands
  carry an annotation.

Measured caveat: in the session that produced this guard I read one verdict and
then ran the compiler myself anyway. The saving exists only if the pushed verdict
is actually used instead of the raw command.

## Limits

- **Blocking is best effort.** It matches the command string. `bash -c "odin
  check"`, `env -i …`, or a `just` recipe that shells out to `odin` all pass. The
  evidence gate is the guarantee; this is the speed bump.
- **The commit gate is the reliable part.** It does not depend on the agent
  choosing to run anything; a commit either has a fresh verdict or it does not.
- **Annotation is now narrow** — only commands a rule matches, never Rachel's own
  run. That is deliberate: annotating everything pays on every call.
- **The merged-branch gate needs `gh` and a network**, fails open to "unknown",
  caches per branch for a minute, and skips `main`.
- **Staleness walks up to 5000 source files**, so a huge tree makes the gate
  lenient rather than wrong.
- **The default stage requirement is `check`**, so a commit can pass on a
  compile-only verdict unless the policy asks for `test` too.
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
