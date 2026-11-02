/**
 * Coffee Shop guard.
 *
 * Installed by guard/install.sh and configured by .pi/coffee-shop-guard.json.
 * Edit the policy, not this file. The installed copy is excluded locally with
 * git info/exclude, so it is never committed to the target project.
 *
 * Three jobs:
 *   1. block commands the policy forbids, unless the escape token is present;
 *   2. append the project's last Rachel verdict to every bash result, so the
 *      verdict arrives without the agent having to remember to ask;
 *   3. announce the active rules once per session.
 *
 * Everything here fails open: a broken policy or a missing evidence directory
 * means no blocking and no annotation, never a broken session.
 */
import { execFileSync } from "node:child_process";
import type { Dirent } from "node:fs";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

export type Mode = "annotate" | "block";

export interface Rule {
  id: string;
  tool?: string;
  command?: string;
  mode?: Mode;
  message?: string;
  /** Blocking needs a resolved Rachel project to name, so the rule can ask for one. */
  requiresProject?: boolean;
}

export interface Policy {
  version: number;
  mode: Mode;
  escape: string;
  /** A commit needs a fresh, passing verdict unless this is false. */
  requireFreshVerdict?: boolean;
  /** Stages the verdict must have run. Default ["check"], the cheap universal one. */
  requireStages?: string[];
  rules: Rule[];
}

export interface Decision {
  action: "allow" | "block" | "annotate";
  rule?: string;
  reason?: string;
  requiresProject?: boolean;
}

export interface LastVerdict {
  line: string;
  ageMs: number;
  dir: string;
}

export const DEFAULT_POLICY: Policy = { version: 1, mode: "annotate", escape: "CS_RAW=1", rules: [] };

/** parsePolicy never throws: a bad policy means "no rules", not "no session". */
export function parsePolicy(text: string): Policy {
  try {
    const raw = JSON.parse(text);
    const rules: Rule[] = Array.isArray(raw?.rules)
      ? raw.rules.filter((rule: any) => rule && typeof rule.id === "string")
      : [];
    return {
      version: Number(raw?.version ?? 1),
      mode: raw?.mode === "block" ? "block" : "annotate",
      escape: typeof raw?.escape === "string" && raw.escape ? raw.escape : DEFAULT_POLICY.escape,
      requireFreshVerdict: raw?.requireFreshVerdict !== false,
      requireStages: Array.isArray(raw?.requireStages)
        ? raw.requireStages.filter((stage: any) => typeof stage === "string")
        : ["check"],
      rules,
    };
  } catch {
    return DEFAULT_POLICY;
  }
}

export function loadPolicy(path: string): Policy {
  try {
    return parsePolicy(readFileSync(path, "utf8"));
  } catch {
    return DEFAULT_POLICY;
  }
}

/**
 * evaluate is pure so guard/selftest.ts can test it without Pi.
 * A rule blocks only when both the rule and the policy ask for blocking; any
 * other match downgrades to annotation. The escape token always wins.
 */
export function evaluate(policy: Policy, command: string, tool = "bash"): Decision {
  if (policy.escape && command.includes(policy.escape)) {
    return { action: "allow" };
  }
  for (const rule of policy.rules) {
    if ((rule.tool ?? "bash") !== tool || !rule.command) continue;
    let matches = false;
    try {
      matches = new RegExp(rule.command, "i").test(command);
    } catch {
      continue;
    }
    if (!matches) continue;
    const blocked = (rule.mode ?? "block") === "block" && policy.mode === "block";
    if (blocked) {
      return {
        action: "block",
        rule: rule.id,
        requiresProject: rule.requiresProject ?? true,
        reason:
          `Coffee Shop rule "${rule.id}": ${rule.message ?? "this command is not allowed here."}` +
          ` If the user explicitly asked for this command, re-run it with ${policy.escape}.`,
      };
    }
    return { action: "annotate", rule: rule.id };
  }
  return { action: "allow" };
}

/** lastVerdict reads the newest evidence run; null means this project has none. */
export function lastVerdict(project: string, now = Date.now()): LastVerdict | null {
  const base = join(project, ".rachel", "evidence");
  let names: string[];
  try {
    names = readdirSync(base)
      .filter((name) => {
        try {
          return statSync(join(base, name)).isDirectory();
        } catch {
          return false;
        }
      })
      .sort();
  } catch {
    return null;
  }
  if (names.length === 0) return null;
  const newest = names[names.length - 1];
  try {
    const manifest = JSON.parse(readFileSync(join(base, newest, "manifest.json"), "utf8"));
    const verdict: string[] = Array.isArray(manifest?.verdict) ? manifest.verdict : [];
    const started = Number(manifest?.started_ns ?? 0) / 1e6;
    return {
      line: verdict[0] ?? "no verdict lines",
      ageMs: started > 0 ? Math.max(0, now - started) : 0,
      dir: newest,
    };
  } catch {
    return null;
  }
}

const PROJECT_MARKERS = ["justfile", "Justfile", ".justfile"];

export function hasJustfile(dir: string): boolean {
  return PROJECT_MARKERS.some((marker) => existsSync(join(dir, marker)));
}

/**
 * A Rachel project is a directory with a justfile, because that is what Rachel
 * runs. Odin sources alone are not enough: a stray .odin file anywhere would make
 * its ancestor a "project", and /tmp is not one. Rachel creates the justfile on
 * the first `rachel verify`, so a fresh project becomes resolvable then.
 */
export function isRachelProject(dir: string): boolean {
  return hasJustfile(dir);
}

/** projectOf walks up from an existing path to the nearest justfile, or null. */
export function projectOf(start: string): string | null {
  let dir = resolve(start);
  try {
    if (!statSync(dir).isDirectory()) dir = dirname(dir);
  } catch {
    return null;
  }
  for (;;) {
    if (hasJustfile(dir)) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function unquote(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length >= 2 && (trimmed[0] === '"' || trimmed[0] === "'") && trimmed.at(-1) === trimmed[0]) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

/**
 * resolveProject finds the project a command touches, because the guard runs in
 * Coffee Shop and must not be installed into the projects Coffee Shop works on.
 *
 * Candidates come from `cd`, `git -C`, and absolute paths. A command with no
 * mappable candidate falls back to the session directory; a command that names a
 * directory which is not a Rachel project returns null, so the guard stays out of
 * the way of ordinary repositories.
 */
export function resolveProject(command: string, sessionDir: string): string | null {
  const candidates: string[] = [];
  for (const match of command.matchAll(/\bcd\s+("[^"]+"|'[^']+'|\S+)/g)) {
    candidates.push(unquote(match[1]));
  }
  for (const match of command.matchAll(/\bgit\s+-C\s+("[^"]+"|'[^']+'|\S+)/g)) {
    candidates.push(unquote(match[1]));
  }
  for (const match of command.matchAll(/(^|\s)(\/[^\s;&|"'`]+)/g)) {
    candidates.push(match[2]);
  }
  for (const candidate of candidates) {
    if (!candidate || candidate.startsWith("-")) continue;
    const absolute = isAbsolute(candidate) ? candidate : resolve(sessionDir, candidate);
    // A path that does not exist yet (an output directory, a worktree target)
    // must not resolve through its parent: that is how /tmp became a project.
    if (!existsSync(absolute)) continue;
    const project = projectOf(absolute);
    if (project) return project;
  }
  if (candidates.length === 0) return projectOf(sessionDir);
  return null;
}

export interface Signal {
  id: string;
  line: string;
  ageMs: number;
  ok: boolean;
  /** Stages the run executed, so the gate can require more than a compile. */
  stages: string[];
  /** True when a source file changed after the run that produced this verdict. */
  stale: boolean;
}

/**
 * lastSignal reads .rachel/last.json, which Rachel writes after every verify,
 * pass or fail. This is the cheap current signal: one file, one line.
 */
export function lastSignal(project: string, now = Date.now()): Signal | null {
  try {
    const raw = JSON.parse(readFileSync(join(project, ".rachel", "last.json"), "utf8"));
    const verdict: string[] = Array.isArray(raw?.verdict) ? raw.verdict : [];
    const started = Number(raw?.started_ns ?? 0) / 1e6;
    const newest = newestSourceMtime(project);
    return {
      id: String(raw?.started_ns ?? 0),
      line: verdict[0] ?? "no verdict",
      ageMs: started > 0 ? Math.max(0, now - started) : 0,
      ok: raw?.ok === true,
      stages: Array.isArray(raw?.stages) ? raw.stages : [],
      stale: started > 0 && newest > started,
    };
  } catch {
    return null;
  }
}

const SKIP_DIRS = new Set([".git", ".rachel", ".pi", "node_modules", "build", "dist", "target", ".venv"]);

/**
 * newestSourceMtime is what "stale" means for Rachel's domain: the newest .odin
 * file or justfile in the project. A verdict older than that describes code that
 * no longer exists.
 */
export function newestSourceMtime(project: string, limit = 5000): number {
  let newest = 0;
  let seen = 0;
  const walk = (dir: string) => {
    if (seen >= limit) return;
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (seen >= limit) return;
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        walk(join(dir, entry.name));
        continue;
      }
      if (!entry.isFile()) continue;
      const name = entry.name;
      if (!name.endsWith(".odin") && !name.startsWith("justfile") && name !== "Justfile" && name !== ".justfile") continue;
      seen += 1;
      try {
        newest = Math.max(newest, statSync(join(dir, name)).mtimeMs);
      } catch {
        // A file that vanished mid-walk is not a reason to fail.
      }
    }
  };
  walk(project);
  return newest;
}

/** pickPush chooses the newest un-pushed signal across the projects seen so far. */
export function pickPush(
  candidates: Array<{ project: string; signal: Signal | null }>,
  pushed: Record<string, string>,
): { project: string; signal: Signal } | null {
  let best: { project: string; signal: Signal } | null = null;
  for (const candidate of candidates) {
    const signal = candidate.signal;
    if (!signal) continue;
    if (pushed[candidate.project] === signal.id) continue;
    if (best === null || Number(signal.id) > Number(best.signal.id)) {
      best = { project: candidate.project, signal };
    }
  }
  return best;
}

export interface Gate {
  action: "allow" | "warn" | "block";
  reason: string;
}

/**
 * commitGate is the guarantee the annotation cannot give: a commit needs a
 * verdict that passed and that is newer than the source it describes.
 */
export function commitGate(policy: Policy, signal: Signal | null): Gate {
  if (policy.requireFreshVerdict === false) return { action: "allow", reason: "" };
  const failed = (reason: string): Gate => ({ action: policy.mode === "block" ? "block" : "warn", reason });
  if (signal === null) {
    return failed("no Rachel verdict in this project yet: run `rachel verify .` before committing");
  }
  if (signal.stale) {
    return failed("the source changed after the last verdict: re-run `rachel verify .` before committing");
  }
  const required = policy.requireStages ?? ["check"];
  const missing = required.filter((stage) => !signal.stages.includes(stage));
  if (missing.length > 0) {
    return failed(`the last verdict did not run ${missing.join(", ")}: run \`rachel verify .\``);
  }
  if (!signal.ok) {
    return failed(`the last Rachel verdict failed (${signal.line}): fix it before committing`);
  }
  return { action: "allow", reason: "" };
}

export function currentBranch(cwd: string): string {
  try {
    return String(
      execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd, timeout: 5000, stdio: ["ignore", "pipe", "ignore"] }),
    ).trim();
  } catch {
    return "";
  }
}

const prStates = new Map<string, { state: string; at: number }>();

/**
 * prState reports the branch's PR state, cached for a minute. It fails open to
 * "" so an offline machine or a missing gh never blocks a commit.
 */
export function prState(branch: string, cwd: string, now = Date.now()): string {
  if (!branch || branch === "HEAD" || branch === "main") return "";
  const cached = prStates.get(branch);
  if (cached && now - cached.at < 60_000) return cached.state;
  let state = "";
  try {
    state = String(
      execFileSync("gh", ["pr", "view", branch, "--json", "state", "-q", ".state"], {
        cwd,
        timeout: 8000,
        stdio: ["ignore", "pipe", "ignore"],
      }),
    ).trim();
  } catch {
    state = "";
  }
  prStates.set(branch, { state, at: now });
  return state;
}

/** shouldPush is true only for a signal the agent has not been told about yet. */
export function shouldPush(lastPushedId: string, signal: Signal | null): boolean {
  return signal !== null && signal.id !== lastPushedId;
}

/**
 * shouldAnnotate is deliberately narrow. Annotating every bash result pays the
 * cost on every call and collects the benefit only when the call duplicated
 * Rachel. Only commands a rule already matches are annotated, and never Rachel's
 * own invocation, which prints the verdict itself.
 */
export function shouldAnnotate(policy: Policy, command: string): boolean {
  if (/^\s*rachel\b/.test(command)) return false;
  return evaluate(policy, command).action !== "allow";
}

export function humanAge(ms: number): string {
  if (ms < 1000) return "just now";
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.floor(minutes / 60)}h ago`;
}

export function verdictNote(project: string, sessionDir?: string): string {
  const label = sessionDir && project !== sessionDir ? `${project.split("/").pop()}: ` : "";
  const signal = lastSignal(project);
  if (signal) {
    return `[coffee-shop guard] ${label}${signal.line} (${humanAge(signal.ageMs)})`;
  }
  const last = lastVerdict(project);
  if (!last) {
    return `[coffee-shop guard] ${label}no Rachel verdict yet: run \`rachel verify .\` before claiming the work is done.`;
  }
  return `[coffee-shop guard] ${label}last failure evidence: ${last.line} (${humanAge(last.ageMs)}, evidence ${last.dir})`;
}

export function rulesSummary(policy: Policy): string {
  if (policy.rules.length === 0) {
    return "coffee-shop guard: no rules installed";
  }
  const lines = policy.rules.map((rule) => `- ${rule.id}${rule.message ? `: ${rule.message}` : ""}`);
  return `coffee-shop guard: ${policy.rules.length} rule(s), mode=${policy.mode}\n${lines.join("\n")}`;
}

export default function (pi: any) {
  // Deliberately the session directory, not a target project: the guard is
  // installed in Coffee Shop only, and resolves target projects per command.
  const sessionDir = process.env.COFFEE_SHOP_GUARD_PROJECT || process.cwd();
  const policy = loadPolicy(join(sessionDir, ".pi", "coffee-shop-guard.json"));

  pi.on("session_start", async () => {
    try {
      await pi.sendMessage(
        { customType: "coffee-shop-guard", content: rulesSummary(policy), display: true },
        { triggerTurn: false },
      );
    } catch {
      // Announcement is best effort; never break a session over it.
    }
  });

  // Projects seen in commands, so a push reaches the project being worked on and
  // not only the directory the session started in.
  const observed = new Set<string>([sessionDir]);
  const pushed: Record<string, string> = {};
  const pendingWarnings = new Map<string, string>();

  // Push, don't make the agent pull: a changed verdict is added to the context
  // with the next model call, which costs no extra turn.
  pi.on("turn_start", async () => {
    try {
      const candidates = Array.from(observed).map((project) => ({ project, signal: lastSignal(project) }));
      const next = pickPush(candidates, pushed);
      if (next === null) return;
      pushed[next.project] = next.signal.id;
      const stale = next.signal.stale ? ", stale" : "";
      const label = next.project === sessionDir ? "" : `${next.project.split("/").pop()}: `;
      await pi.sendMessage(
        {
          customType: "coffee-shop-guard",
          content: `${label}${next.signal.line} (${humanAge(next.signal.ageMs)}${stale})`,
          display: true,
        },
        { triggerTurn: false },
      );
    } catch {
      // A failed push must never break a turn.
    }
  });

  pi.on("tool_call", async (event: any) => {
    if (event?.toolName !== "bash") return;
    const command = String(event?.input?.command ?? "");
    const project = resolveProject(command, sessionDir);
    if (project) observed.add(project);

    // The escape token wins over every rule, including the commit gates.
    if (policy.escape && command.includes(policy.escape)) return;

    if (/^\s*git\s+commit\b/.test(command)) {
      const target = project ?? sessionDir;
      const gate = commitGate(policy, lastSignal(target));
      if (gate.action === "block") {
        return { block: true, reason: `Coffee Shop rule "fresh-verdict": ${gate.reason} (escape: ${policy.escape})` };
      }
      if (gate.action === "warn") {
        pendingWarnings.set(event.toolCallId, `[coffee-shop guard] ${gate.reason}`);
      }
      const branch = currentBranch(target);
      if (branch && prState(branch, target) === "MERGED") {
        const reason = `branch ${branch} has a merged PR: create a new branch before committing (escape: ${policy.escape})`;
        if (policy.mode === "block") {
          return { block: true, reason: `Coffee Shop rule "merged-branch": ${reason}` };
        }
        pendingWarnings.set(event.toolCallId, `[coffee-shop guard] ${reason}`);
      }
      return;
    }

    const decision = evaluate(policy, command);
    if (decision.action !== "block") return;
    // A rule that needs a project to name must not block when none resolves; a
    // rule with its own alternative (wt) applies anywhere.
    if (decision.requiresProject !== false && !project) return;
    return { block: true, reason: decision.reason };
  });

  pi.on("tool_result", async (event: any) => {
    if (event?.toolName !== "bash") return;
    try {
      const warning = pendingWarnings.get(event.toolCallId);
      if (warning !== undefined) {
        pendingWarnings.delete(event.toolCallId);
        const content = Array.isArray(event.content)
          ? [...event.content, { type: "text", text: warning }]
          : [{ type: "text", text: warning }];
        return { content, structuredContent: event.structuredContent };
      }
      const command = String(event?.input?.command ?? "");
      if (!shouldAnnotate(policy, command)) return undefined;
      const project = resolveProject(command, sessionDir);
      if (!project) return undefined;
      const signal = lastSignal(project);
      const note = verdictNote(project, sessionDir);
      const suffix = signal?.stale ? " [stale: source changed after this verdict]" : "";
      const content = Array.isArray(event.content)
        ? [...event.content, { type: "text", text: note + suffix }]
        : [{ type: "text", text: note + suffix }];
      return { content, structuredContent: event.structuredContent };
    } catch {
      return undefined;
    }
  });
}
