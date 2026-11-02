// Self-test for the guard's pure logic. Run with: bun run guard/selftest.ts
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_POLICY,
  evaluate,
  humanAge,
  lastVerdict,
  parsePolicy,
  verdictNote,
} from "./coffee-shop-guard.ts";

let failures = 0;

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
      { id: "worktree-via-wt", tool: "bash", command: "git\\s+worktree\\s+(add|remove)", mode: "block" },
    ],
  }),
);

// Blocking mode.
check("raw odin check blocks", evaluate(policy, "odin check src").action, "block");
check("raw go test blocks", evaluate(policy, "cd go && go test ./...").action, "block");
check("raw bun test blocks", evaluate(policy, "bun test").action, "block");
check("git worktree blocks", evaluate(policy, "git worktree add x").action, "block");
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

if (failures > 0) {
  console.error(`${failures} guard check(s) failed`);
  process.exit(1);
}
console.log("guard selftest: all checks passed");
