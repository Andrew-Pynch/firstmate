// Firstmate's always-visible line for omp (Oh My Pi): one conditional line
// pinned above the editor naming the single most urgent thing waiting on the
// captain, plus how many more are waiting. It disappears entirely when nothing
// is waiting.
//
// This file is presentation only, deliberately. The text comes from
// bin/fm-queue-line.sh, which renders it from bin/fm-queue.sh's own model, so
// the pinned count and the queue program's count cannot disagree; nothing about
// what is urgent or how it is counted lives here.
//
// The seam is the one the captain's own ~/.omp config already uses twice
// (human-todos.js, session-objective.js): ctx.ui.setWidget(key, lines,
// {placement: "aboveEditor"}), cleared with setWidget(key, undefined). Verified
// against the installed @oh-my-pi/pi-coding-agent 18.1.14
// (types/extensibility/extensions/types.d.ts: ExtensionUIContext.setWidget,
// WidgetPlacement, readonly theme).
//
// Why the refresh is asynchronous and rate-limited: every read is the whole
// fleet through the canonical snapshot (bin/fm-queue.sh --json), which costs
// seconds of CPU on a real fleet - measured at 14.5s wall and roughly 1.5 cores
// on 2026-09-15 against a 154-row queue. Pi-family extensions run on the TUI's
// own thread, so a synchronous read would freeze repaint and key echo for that
// whole time; the shared helper below is the one owner of that replacement. A
// refresh also coalesces: at most one read is in flight, a trigger during a read
// queues one follow-up, and FM_QUEUE_LINE_MIN_INTERVAL_MS is the shortest gap
// between two reads - set several times the read cost, so a busy session turning
// every few seconds cannot run the snapshot back to back. An idle pane re-reads
// every FM_QUEUE_LINE_POLL_MS.
//
// A failed or unreadable read leaves the pinned line exactly as it was rather
// than clearing it: a transient failure is not evidence that the queue emptied,
// and the next trigger or poll repairs the line. The queue program remains the
// authority; this line is a glance, not the record.
//
// Worker panes never render it. bin/fm-spawn.sh marks every ship and scout pane
// with FM_TASK_ID and a secondmate is not marked, so the marker is the
// structural discriminator between a supervisor session, whose queue is the
// captain's, and a worker session, whose queue is not its business; the marker
// also keeps a fleet read out of every worker pane. A session in the home that
// does not hold the home lock does still render it, and that is deliberate: the
// ownership proof belongs to the supervision surface, and this file does not
// reimplement it to save one bounded read per refresh.
//
// Environment:
//   FM_HOME                    home to read (default: the root this file loaded from).
//   FM_ROOT_OVERRIDE           code root that holds bin/ (default: this file's root).
//   FM_QUEUE_LINE_CMD          program to run (default <root>/bin/fm-queue-line.sh).
//                              A test or a host with an unusual layout overrides it.
//   FM_QUEUE_LINE_MIN_INTERVAL_MS  shortest gap between two reads (default 60000).
//   FM_QUEUE_LINE_POLL_MS      idle re-read cadence (default 120000).
import { runCommandAsync, type AsyncExecResult } from "../../.pi/extensions/lib/fm-async-exec.ts";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const WIDGET_KEY = "firstmate-queue-line";

const extensionFile = fileURLToPath(import.meta.url);
const root = process.env.FM_ROOT_OVERRIDE || resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || root;
const command = process.env.FM_QUEUE_LINE_CMD || `${root}/bin/fm-queue-line.sh`;

function positiveInteger(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

const minIntervalMs = positiveInteger("FM_QUEUE_LINE_MIN_INTERVAL_MS", 60_000);
const pollMs = positiveInteger("FM_QUEUE_LINE_POLL_MS", 120_000);

export interface QueueLineState {
  inFlight: boolean;
  pending: boolean;
  lastStart: number;
  timer: ReturnType<typeof setTimeout> | null;
  interval: ReturnType<typeof setInterval> | null;
}

export function newState(): QueueLineState {
  return { inFlight: false, pending: false, lastStart: 0, timer: null, interval: null };
}

/** Pin one line above the editor, or clear the pin. Returns whether the surface took it. */
export function applyLine(ctx: any, line: string): boolean {
  if (!ctx?.hasUI) return false;
  if (line === "") ctx.ui.setWidget(WIDGET_KEY, undefined);
  else ctx.ui.setWidget(WIDGET_KEY, [line], { placement: "aboveEditor" });
  return true;
}

export interface QueueLineRead {
  ok: boolean;
  line: string;
}

/** Run the line program once. A non-zero exit or a missing program is a failure. */
export async function readLine(run?: () => Promise<AsyncExecResult>): Promise<QueueLineRead> {
  if (!run && !existsSync(command)) return { ok: false, line: "" };
  const exec = run ?? (() => runCommandAsync(command, [], { cwd: fmHome, env: { ...process.env, FM_HOME: fmHome } }));
  const result = await exec();
  if (result.status !== 0) return { ok: false, line: "" };
  return { ok: true, line: result.stdout.trim() };
}

/** Read and apply. A failed read leaves the pinned line untouched. */
export async function refresh(ctx: any, run?: () => Promise<AsyncExecResult>): Promise<"shown" | "cleared" | "failed"> {
  const { ok, line } = await readLine(run);
  if (!ok) return "failed";
  applyLine(ctx, line);
  return line === "" ? "cleared" : "shown";
}

/**
 * The refresh gate: single-flight, one coalesced follow-up, and a floor on how
 * often a whole-fleet read may happen. Returns the read it performed, if any.
 */
export async function trigger(ctx: any, state: QueueLineState, run?: () => Promise<AsyncExecResult>): Promise<void> {
  if (state.inFlight) {
    state.pending = true;
    return;
  }
  const wait = state.lastStart + minIntervalMs - Date.now();
  if (wait > 0) {
    if (state.timer === null) {
      state.timer = setTimeout(() => {
        state.timer = null;
        void trigger(ctx, state, run);
      }, wait);
      state.timer.unref?.();
    }
    return;
  }
  state.lastStart = Date.now();
  state.inFlight = true;
  try {
    await refresh(ctx, run);
  } finally {
    state.inFlight = false;
    if (state.pending) {
      state.pending = false;
      void trigger(ctx, state, run);
    }
  }
}

function stopTimers(state: QueueLineState): void {
  if (state.timer !== null) {
    clearTimeout(state.timer);
    state.timer = null;
  }
  if (state.interval !== null) {
    clearInterval(state.interval);
    state.interval = null;
  }
}

export default function firstmateQueueLine(pi: any): void {
  // A worker pane's queue is not the captain's, and a fleet read per worker is
  // pure cost. bin/fm-spawn.sh marks ship and scout panes; secondmates are not
  // marked, so a secondmate home still renders its own queue.
  if (process.env.FM_TASK_ID) return;
  if (!existsSync(command)) return;

  const state = newState();
  // Both handlers return immediately. omp awaits every extension handler under a
  // timeout budget (extensibility/extensions/runner.ts, emit), so returning the
  // read here would stall the session start or the turn end for the length of a
  // whole-fleet read instead of only delaying this line.
  pi.on?.("session_start", (_event: unknown, ctx: any) => {
    stopTimers(state);
    state.interval = setInterval(() => void trigger(ctx, state), pollMs);
    state.interval.unref?.();
    void trigger(ctx, state);
  });
  pi.on?.("turn_end", (_event: unknown, ctx: any) => {
    void trigger(ctx, state);
  });
  pi.on?.("session_shutdown", () => stopTimers(state));
}
