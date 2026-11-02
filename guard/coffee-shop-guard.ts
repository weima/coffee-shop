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
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

export type Mode = "annotate" | "block";

export interface Rule {
  id: string;
  tool?: string;
  command?: string;
  mode?: Mode;
  message?: string;
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

export function humanAge(ms: number): string {
  if (ms < 1000) return "just now";
  const seconds = Math.floor(ms / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  return `${Math.floor(minutes / 60)}h ago`;
}

export function verdictNote(project: string): string {
  const last = lastVerdict(project);
  if (!last) {
    return "[coffee-shop guard] no Rachel evidence in this project yet: run `rachel verify .` before claiming the work is done.";
  }
  return `[coffee-shop guard] last Rachel verdict: ${last.line} (${humanAge(last.ageMs)}, evidence ${last.dir})`;
}

export function rulesSummary(policy: Policy): string {
  if (policy.rules.length === 0) {
    return "coffee-shop guard: no rules installed";
  }
  const lines = policy.rules.map((rule) => `- ${rule.id}${rule.message ? `: ${rule.message}` : ""}`);
  return `coffee-shop guard: ${policy.rules.length} rule(s), mode=${policy.mode}\n${lines.join("\n")}`;
}

export default function (pi: any) {
  const project = process.env.COFFEE_SHOP_GUARD_PROJECT || process.cwd();
  const policy = loadPolicy(join(project, ".pi", "coffee-shop-guard.json"));

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
    const decision = evaluate(policy, String(event?.input?.command ?? ""));
    if (decision.action === "block") {
      return { block: true, reason: decision.reason };
    }
  });

  pi.on("tool_result", async (event: any) => {
    if (event?.toolName !== "bash") return;
    try {
      const note = verdictNote(project);
      const content = Array.isArray(event.content)
        ? [...event.content, { type: "text", text: note }]
        : [{ type: "text", text: note }];
      return { content, structuredContent: event.structuredContent };
    } catch {
      return undefined;
    }
  });
}
