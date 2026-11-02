// Self-test for the guard's pure logic. Run with: bun run guard/selftest.ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_POLICY,
  evaluate,
  humanAge,
  isRachelProject,
  hasJustfile,
  lastVerdict,
  parsePolicy,
  projectOf,
  resolveProject,
  shouldAnnotate,
  shouldPush,
  lastSignal,
  newestSourceMtime,
  pickPush,
  commitGate,
  currentBranch,
  prState,
  verdictNote,
  type Signal,
} from "./coffee-shop-guard.ts";

let failures = 0;

function nutrition(): string {
  return join(tmpdir(), "guard-no-such-session");
}

function check(name: string, actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    failures += 1;
    console.error(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`);
  }
}

const policy = parsePolicy(
  JSON.stringify({
    version: 1,
    mode: "block",
    escape: "CS_RAW=1",
    rules: [
      {
        id: "no-raw-build",
        tool: "bash",
        command: "(^|[;&|]\\s*)(odin|go|bun)\\s+(build|check|test)",
        mode: "block",
      },
      {
        id: "worktree-via-wt",
        tool: "bash",
        command: "git\\s+worktree\\s+(add|remove)",
        mode: "block",
        requiresProject: false,
      },
    ],
  }),
);

// Blocking mode.
check("raw odin check blocks", evaluate(policy, "odin check src").action, "block");
check("raw go test blocks", evaluate(policy, "cd go && go test ./...").action, "block");
check("raw bun test blocks", evaluate(policy, "bun test").action, "block");
check("git worktree blocks", evaluate(policy, "git worktree add x").action, "block");
check("worktree rule needs no project", evaluate(policy, "git worktree add x").requiresProject, false);
check("raw build rule needs a project", evaluate(policy, "odin check src").requiresProject, true);
check("escape allows", evaluate(policy, "CS_RAW=1 odin check src").action, "allow");

// Allowed paths.
check("just check allowed", evaluate(policy, "just check").action, "allow");
check("rachel verify allowed", evaluate(policy, "odin run src -- verify .").action, "allow");
check("odin run build script allowed", evaluate(policy, "odin run tools/gates -- report").action, "allow");
check("unrelated command allowed", evaluate(policy, "rg TODO src").action, "allow");

// Annotate mode downgrades every block to a match.
const annotate = { ...policy, mode: "annotate" as const };
check("annotate mode does not block", evaluate(annotate, "odin check src").action, "annotate");
check("annotate mode keeps allow", evaluate(annotate, "just check").action, "allow");

// Bad policy data fails open.
check("bad json is empty policy", parsePolicy("{ not json").rules.length, 0);
check("missing rules is empty policy", parsePolicy("{}").rules.length, 0);
check("default policy escape", DEFAULT_POLICY.escape, "CS_RAW=1");
check("default policy does not block", evaluate(DEFAULT_POLICY, "odin check src").action, "allow");

// Evidence annotation.
const project = mkdtempSync(join(tmpdir(), "guard-selftest-"));
try {
  check("no evidence returns null", lastVerdict(project), null);
  const run = join(project, ".rachel", "evidence", "00000000000000000001-test");
  mkdirSync(run, { recursive: true });
  writeFileSync(
    join(run, "manifest.json"),
    JSON.stringify({
      stage: "test",
      status: "fail",
      started_ns: 1_000_000_000,
      verdict: ["rachel: test fail (1 of 1 tests)", "rachel: error a.odin:1:t() boom"],
    }),
  );
  // started_ns is 1_000_000_000 ns = 1000 ms, so now=2000 ms means 1 s old.
  const last = lastVerdict(project, 2000);
  check("newest verdict line", last?.line, "rachel: test fail (1 of 1 tests)");
  check("age from manifest", last?.ageMs, 1_000);
  check("human age seconds", humanAge(1_000), "1s ago");
  check("human age minutes", humanAge(120_000), "2m ago");
  check("verdict note names evidence", verdictNote(project).includes("evidence 00000000000000000001-test"), true);
} finally {
  rmSync(project, { recursive: true, force: true });
}

// Project resolution: the guard runs in Coffee Shop and must find the project a
// command touches, because it is never installed into that project.
const sandbox = mkdtempSync(join(tmpdir(), "guard-projects-"));
try {
  const coffee = join(sandbox, "coffee-shop");
  const target = join(sandbox, "target");
  const plain = join(sandbox, "plain");
  mkdirSync(coffee, { recursive: true });
  writeFileSync(join(coffee, "justfile"), "check:\n    odin check src\n");
  mkdirSync(join(target, "src"), { recursive: true });
  writeFileSync(join(target, "justfile"), "check:\n    odin check -no-entry-point .\n");
  writeFileSync(join(target, "src", "x.odin"), "package x\n");
  mkdirSync(plain, { recursive: true });
  writeFileSync(join(plain, "package.json"), "{}\n");

  check("cd resolves the target", resolveProject(`cd ${target} && odin check .`, coffee), target);
  check("git -C resolves the target", resolveProject(`git -C ${target} status`, coffee), target);
  check("an absolute path resolves the target", resolveProject(`cat ${target}/src/x.odin`, coffee), target);
  check("no path falls back to the session dir", resolveProject("odin check src", coffee), coffee);
  check("a non-Rachel directory resolves to null", resolveProject(`cd ${plain} && npm test`, coffee), null);
  check("projectOf walks up from a file", projectOf(join(target, "src", "x.odin")), target);
  check("projectOf stops at the marker", projectOf(join(target, "src")), target);
  check("plain is not a Rachel project", isRachelProject(plain), false);
  check("guard stays quiet with no project", resolveProject(`cd ${plain} && npm test`, nutrition()), null);

  // A stray .odin file must not turn an ancestor directory into a project.
  const stray = join(sandbox, "stray");
  mkdirSync(join(stray, "nested"), { recursive: true });
  writeFileSync(join(stray, "stray.odin"), "package stray\n");
  check("odin sources alone are not a project", isRachelProject(stray), false);
  check("projectOf refuses an odin-only tree", projectOf(stray), null);
  check("a non-existent path does not resolve via its parent", resolveProject(`git worktree add ${stray}/new y`, coffee), null);
  check("justfile wins over a sibling odin file", hasJustfile(target), true);
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}

// Push-on-change and narrow annotation: the token-saving half.
const signalProject = mkdtempSync(join(tmpdir(), "guard-signal-"));
try {
  mkdirSync(join(signalProject, ".rachel"), { recursive: true });
  check("no signal file means no push", lastSignal(signalProject), null);
  check("no signal never pushes", shouldPush("", null), false);

  writeFileSync(
    join(signalProject, ".rachel", "last.json"),
    JSON.stringify({
      started_ns: 2_000_000_000,
      ok: true,
      stages: ["check", "test"],
      verdict: ["rachel: check ok (1 checked)", "rachel: test ok (29 tests)"],
    }),
  );
  const signal = lastSignal(signalProject, 3_000);
  check("signal id is the run start", signal?.id, "2000000000");
  check("signal line is the summary", signal?.line, "rachel: check ok (1 checked)");
  check("signal age", signal?.ageMs, 1_000);
  check("signal ok", signal?.ok, true);
  check("a new signal pushes", shouldPush("", signal), true);
  check("the same signal does not push twice", shouldPush("2000000000", signal), false);
  check("a passing verdict is annotated as ok", verdictNote(signalProject).includes("check ok"), true);
} finally {
  rmSync(signalProject, { recursive: true, force: true });
}

// Only commands a rule matches are annotated, never Rachel's own invocation.
check("raw check is annotated", shouldAnnotate(policy, "odin check src"), true);
check("just check is not annotated", shouldAnnotate(policy, "just check"), false);
check("ls is not annotated", shouldAnnotate(policy, "ls src"), false);
check("rachel invocation is not annotated", shouldAnnotate(policy, "rachel verify ."), false);

// Staleness: a verdict older than the newest source file describes code that no
// longer exists.
const staleProject = mkdtempSync(join(tmpdir(), "guard-stale-"));
try {
  mkdirSync(join(staleProject, ".rachel"), { recursive: true });
  writeFileSync(join(staleProject, "justfile"), "check:\n    odin check .\n");
  writeFileSync(join(staleProject, "a.odin"), "package a\n");
  const nowMs = Date.now();
  const signalFile = join(staleProject, ".rachel", "last.json");
  writeFileSync(signalFile, JSON.stringify({ started_ns: (nowMs - 60_000) * 1e6, ok: true, verdict: ["rachel: check ok (1 checked)"] }));
  check("a verdict older than the source is stale", lastSignal(staleProject, nowMs)?.stale, true);
  writeFileSync(signalFile, JSON.stringify({ started_ns: (nowMs + 60_000) * 1e6, ok: true, verdict: ["rachel: check ok (1 checked)"] }));
  check("a verdict newer than the source is fresh", lastSignal(staleProject, nowMs)?.stale, false);
  check("newest source mtime is found", newestSourceMtime(staleProject) > 0, true);
} finally {
  rmSync(staleProject, { recursive: true, force: true });
}

// Push across projects: only the newest unseen verdict is pushed.
const signal = (id: string): Signal => ({ id, line: `verdict ${id}`, ageMs: 0, ok: true, stages: ["check"], stale: false });
check("pickPush chooses the newest", pickPush([{ project: "a", signal: signal("10") }, { project: "b", signal: signal("20") }], {})?.project, "b");
check("pickPush skips what was pushed", pickPush([{ project: "a", signal: signal("10") }, { project: "b", signal: signal("20") }], { b: "20" })?.project, "a");
check("pickPush returns null when everything was pushed", pickPush([{ project: "a", signal: signal("10") }], { a: "10" }), null);
check("pickPush ignores projects without a signal", pickPush([{ project: "a", signal: null }], {}), null);

// The commit gate: the guarantee, not the annotation.
const gateSignal = (ok: boolean, stale: boolean, stages: string[] = ["check", "test"]): Signal => ({
  id: "1",
  line: "rachel: test ok (1 test)",
  ageMs: 0,
  ok,
  stages,
  stale,
});
const blockPolicy = { ...policy, mode: "block" as const, requireFreshVerdict: true };
check("commit blocked with no verdict", commitGate(blockPolicy, null).action, "block");
check("commit blocked when stale", commitGate(blockPolicy, gateSignal(true, true)).action, "block");
check("commit blocked when the verdict failed", commitGate(blockPolicy, gateSignal(false, false)).action, "block");
check("commit allowed when fresh and passing", commitGate(blockPolicy, gateSignal(true, false)).action, "allow");
check("annotate mode only warns", commitGate({ ...blockPolicy, mode: "annotate" as const }, null).action, "warn");
check("the policy can disable the gate", commitGate({ ...blockPolicy, requireFreshVerdict: false }, null).action, "allow");
check("the stale reason names the fix", commitGate(blockPolicy, gateSignal(true, true)).reason.includes("rachel verify"), true);
check("a check-only verdict satisfies the default", commitGate(blockPolicy, gateSignal(true, false, ["check"])).action, "allow");
check(
  "a policy can require tests",
  commitGate({ ...blockPolicy, requireStages: ["check", "test"] }, gateSignal(true, false, ["check"])).action,
  "block",
);
check(
  "the missing-stage reason names the stage",
  commitGate({ ...blockPolicy, requireStages: ["check", "test"] }, gateSignal(true, false, ["check"])).reason.includes("test"),
  true,
);

// Branch detection, used by the merged-branch rule.
const repo = mkdtempSync(join(tmpdir(), "guard-branch-"));
try {
  execFileSync("git", ["init", "-q", "-b", "guard-test", "."], { cwd: repo });
  execFileSync("git", ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--allow-empty", "-qm", "x"], { cwd: repo });
  check("currentBranch reads the branch", currentBranch(repo), "guard-test");
  check("prState skips main", prState("main", repo), "");
} finally {
  rmSync(repo, { recursive: true, force: true });
}

if (failures > 0) {
  console.error(`${failures} guard check(s) failed`);
  process.exit(1);
}
console.log("guard selftest: all checks passed");
