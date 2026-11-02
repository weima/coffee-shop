// Self-test for the guard's pure logic. Run with: bun run guard/selftest.ts
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
  verdictNote,
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

if (failures > 0) {
  console.error(`${failures} guard check(s) failed`);
  process.exit(1);
}
console.log("guard selftest: all checks passed");
