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
  const last = lastVerdict(project);
  if (!last) {
    return `[coffee-shop guard] ${label}no Rachel evidence yet: run \`rachel verify .\` before claiming the work is done.`;
  }
  return `[coffee-shop guard] ${label}last Rachel verdict: ${last.line} (${humanAge(last.ageMs)}, evidence ${last.dir})`;
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

  pi.on("tool_call", async (event: any) => {
    if (event?.toolName !== "bash") return;
    const command = String(event?.input?.command ?? "");
    const decision = evaluate(policy, command);
    if (decision.action !== "block") return;
    // A rule that needs a project to name must not block when none resolves; a
    // rule with its own alternative (wt) applies anywhere.
    if (decision.requiresProject !== false && !resolveProject(command, sessionDir)) return;
    return { block: true, reason: decision.reason };
  });

  pi.on("tool_result", async (event: any) => {
    if (event?.toolName !== "bash") return;
    try {
      const command = String(event?.input?.command ?? "");
      const project = resolveProject(command, sessionDir);
      if (!project) return undefined;
      const note = verdictNote(project, sessionDir);
      const content = Array.isArray(event.content)
        ? [...event.content, { type: "text", text: note }]
        : [{ type: "text", text: note }];
      return { content, structuredContent: event.structuredContent };
    } catch {
      return undefined;
    }
  });
}
