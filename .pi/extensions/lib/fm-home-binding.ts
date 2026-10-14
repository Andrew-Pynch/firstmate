// Which Firstmate home this harness process serves, for the primary
// extensions. bin/fm-home-binding-lib.sh is the one owner of the resolution
// order, the served-homes record, and the per-process record; this adapter
// only gathers the inputs only an extension can see (the launch environment
// and the session's recorded home) and parses the owner's answer, so a TS and
// a shell caller can never resolve the same inputs differently.
import { spawnSync } from "node:child_process";
import { firstmateShellInvocation } from "./fm-operational-input.ts";

export type FirstmateHomeBinding =
  // warning: a bound home whose ambiguity protection could not be recorded.
  | { status: "ok"; home: string; source: "env" | "override" | "session" | "code-root"; warning: string }
  | { status: "ineligible" | "home-mismatch" | "refused"; message: string };

// The session custom entry that carries the home a session was launched for.
// It is written from an explicit FM_HOME (and carried into a new session the
// process opens) and read back on resume, when a
// restore (Herdr's resume_agents_on_restore, a hand-run `omp --resume`) has
// rerun the harness with its working directory but none of its environment.
export const FIRSTMATE_HOME_ENTRY = "firstmate-home";

type HomeEntrySessionManager = {
  getEntries?: () => unknown[];
};

type HomeBindingGlobal = typeof globalThis & {
  __firstmateLaunchFmHome?: string;
  __firstmateHomeBindings?: Map<string, FirstmateHomeBinding>;
  __firstmateLaunchOverrideConsumed?: boolean;
};
const homeBindingGlobal = globalThis as HomeBindingGlobal;

// FM_HOME as the harness was launched, captured once per process before any
// extension exports a session-bound home into process.env, so a later
// in-process session start still tells an explicit launch from a bound one.
export const launchFmHome: string = (homeBindingGlobal.__firstmateLaunchFmHome ??= process.env.FM_HOME ?? "");

// A process serves one home: the first resolved binding per code root is kept
// process-wide, so an in-process child session (whose own session carries no
// recorded home) and a re-evaluated module bind exactly what the primary did.
const processBindings = (homeBindingGlobal.__firstmateHomeBindings ??= new Map<string, FirstmateHomeBinding>());

export function consumeFirstmateLaunchOverride(): boolean {
  if (homeBindingGlobal.__firstmateLaunchOverrideConsumed) return false;
  homeBindingGlobal.__firstmateLaunchOverrideConsumed = true;
  return true;
}

export function recordedFirstmateHome(sessionManager: HomeEntrySessionManager | undefined): string {
  let entries: unknown[] = [];
  try {
    entries = sessionManager?.getEntries?.() ?? [];
  } catch {
    return "";
  }
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!entry || typeof entry !== "object" || !("type" in entry) || entry.type !== "custom") continue;
    if (!("customType" in entry) || entry.customType !== FIRSTMATE_HOME_ENTRY) continue;
    const data = "data" in entry ? entry.data : undefined;
    const home = data && typeof data === "object" && "home" in data ? data.home : undefined;
    return typeof home === "string" ? home : "";
  }
  return "";
}

// Resolve this process's home and, when the session's recorded home supplied
// it, export it into process.env: omp captures process.env into its shell spawn
// environment after every session_start handler, so the agent's own commands
// and every child an extension starts then name the same home explicitly.
export function bindFirstmateHome(
  codeRoot: string,
  sessionManager?: HomeEntrySessionManager,
): FirstmateHomeBinding {
  const bound = processBindings.get(codeRoot);
  if (bound) return bound;
  const recorded = launchFmHome ? "" : recordedFirstmateHome(sessionManager);
  const args = ["resolve", "--code-root", codeRoot, "--primary-only", "--record-pid", String(process.pid)];
  if (recorded) args.push("--recorded", recorded);
  const invocation = firstmateShellInvocation(`${codeRoot}/bin/fm-home-binding-lib.sh`, args);
  const env: NodeJS.ProcessEnv = { ...process.env };
  if (launchFmHome) env.FM_HOME = launchFmHome;
  else delete env.FM_HOME;
  let stdout = "";
  let failure = "";
  try {
    const result = spawnSync(invocation.command, invocation.args, { encoding: "utf8", env, timeout: 10000 });
    stdout = result.stdout ?? "";
    if (result.error) failure = result.error.message;
  } catch (error) {
    failure = error instanceof Error ? error.message : String(error);
  }
  const fields = new Map<string, string>();
  for (const line of stdout.split(/\r?\n/)) {
    const equals = line.indexOf("=");
    if (equals > 0 && !fields.has(line.slice(0, equals))) fields.set(line.slice(0, equals), line.slice(equals + 1));
  }
  const status = fields.get("status");
  const home = fields.get("home") ?? "";
  const source = fields.get("source");
  if (status === "ok" && home && (source === "env" || source === "override" || source === "session" || source === "code-root")) {
    // An explicit or recorded home is exported in its resolved absolute form,
    // so a later `cd` in the agent's shell cannot re-anchor a relative one.
    if (source === "session" || source === "env") process.env.FM_HOME = home;
    const binding: FirstmateHomeBinding = { status, home, source, warning: fields.get("message") ?? "" };
    processBindings.set(codeRoot, binding);
    return binding;
  }
  if (status === "ineligible" || status === "home-mismatch" || status === "refused") {
    return { status, message: fields.get("message") ?? "" };
  }
  return {
    status: "refused",
    message: `could not resolve this process's Firstmate home through ${codeRoot}/bin/fm-home-binding-lib.sh${failure ? `: ${failure}` : ""}`,
  };
}
