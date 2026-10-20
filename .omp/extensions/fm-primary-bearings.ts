// Firstmate's /bearings for omp (Oh My Pi): plain `/bearings` prints the
// captain's daily one-screen brief straight into the transcript, with no model
// turn. `/bearings <options>` (file, include PRs) still asks the agent to run
// the bearings skill with those options, because those modes are the skill's.
//
// This file is presentation only, deliberately. The text comes from
// bin/fm-brief-daily.sh, which renders it from bin/fm-queue.sh's own model, so
// the brief, the pinned line (.omp/extensions/fm-primary-queue-line.ts) and the
// queue program read one decisions list; nothing about ranking, grouping or
// counting lives here.
//
// The seam is omp's own: pi.registerCommand(name, {handler}) claims the bare
// `/bearings` slash command (omp names skills `/skill:<name>`, so there is no
// collision), and pi.sendMessage({customType, content, display: true}) with no
// `deliverAs` renders in the transcript immediately without starting a turn.
// Verified against the installed @oh-my-pi/pi-coding-agent 18.9.1
// (src/extensibility/extensions/types.ts: registerCommand, sendMessage).
//
// The read is the whole fleet through the canonical snapshot, which costs tens
// of seconds on a real fleet, so it runs through the shared asynchronous exec
// helper and never blocks repaint or key echo. One brief at a time: a second
// `/bearings` while one is being read says so instead of starting another read.
//
// Worker panes never register it: bin/fm-spawn.sh marks every ship and scout
// pane with FM_TASK_ID, and a worker's fleet is not its business.
//
// Environment:
//   FM_HOME                 home to read (default: the root this file loaded from).
//   FM_ROOT_OVERRIDE        code root that holds bin/ (default: this file's root).
//   FM_BRIEF_DAILY_CMD      program to run (default <root>/bin/fm-brief-daily.sh).
import { runCommandAsync, type AsyncExecResult } from "../../.pi/extensions/lib/fm-async-exec.ts";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const BRIEF_MESSAGE_TYPE = "firstmate-daily-brief";

const extensionFile = fileURLToPath(import.meta.url);
const root = process.env.FM_ROOT_OVERRIDE || resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || root;
const command = process.env.FM_BRIEF_DAILY_CMD || `${root}/bin/fm-brief-daily.sh`;

/** The text the agent receives when /bearings carries options the skill owns. */
export function skillRequest(args: string): string {
  return `Run the bearings skill (skill://bearings) for: /bearings ${args}`;
}

/** Run the brief program once. Its stdout on success, its first stderr line otherwise. */
export async function readBrief(run?: () => Promise<AsyncExecResult>): Promise<{ ok: boolean; text: string }> {
  const exec = run ?? (() => runCommandAsync(command, [], { cwd: fmHome, env: { ...process.env, FM_HOME: fmHome } }));
  const result = await exec();
  if (result.status !== 0) {
    const reason = result.stderr.split("\n").find((line) => line.trim() !== "") ?? `exit ${result.status ?? "signal"}`;
    return { ok: false, text: reason };
  }
  return { ok: true, text: result.stdout.replace(/\s+$/, "") };
}

/** The slice of omp's command context this command touches. */
interface BriefCommandContext {
  ui?: { notify?: (message: string, level?: "info" | "warning" | "error") => void };
}

/** The slice of omp's ExtensionAPI this file uses. */
interface BriefExtensionApi {
  registerCommand?: (
    name: string,
    options: { description?: string; handler: (args: string, ctx: BriefCommandContext) => Promise<void> },
  ) => void;
  sendMessage: (
    message: { customType: string; content: string; display: boolean },
    options?: { triggerTurn?: boolean },
  ) => void;
  sendUserMessage: (content: string) => void;
}

export default function firstmateBearings(pi: BriefExtensionApi): void {
  if (process.env.FM_TASK_ID) return;
  if (!existsSync(command)) return;

  let reading = false;
  pi.registerCommand?.("bearings", {
    description: "Daily one-screen brief: next action, top decisions, wins. /bearings <options> runs the bearings skill.",
    handler: async (args: string, ctx: BriefCommandContext) => {
      const options = (args ?? "").trim();
      if (options !== "") {
        pi.sendUserMessage(skillRequest(options));
        return;
      }
      if (reading) {
        ctx?.ui?.notify?.("The daily brief is already being read.", "info");
        return;
      }
      reading = true;
      ctx?.ui?.notify?.("Reading the fleet for the daily brief...", "info");
      try {
        const { ok, text } = await readBrief();
        if (!ok) {
          ctx?.ui?.notify?.(`The daily brief could not be read: ${text}`, "error");
          return;
        }
        pi.sendMessage({ customType: BRIEF_MESSAGE_TYPE, content: text, display: true }, { triggerTurn: false });
      } finally {
        reading = false;
      }
    },
  });
}
