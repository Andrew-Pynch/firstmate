#!/usr/bin/env bun
// Usage: fm-telegram-bridge.ts [send <text> | resend <note-id> <reply|receipt> <chunk-index>]
// Requires FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CHAT_ID; FM_HOME defaults to
// the code root. FM_STATE_OVERRIDE selects a sandbox, as it does for fm-inbox.
// FM_TELEGRAM_API_BASE is a loopback-only Bot API test seam.
// Long polling queues allowed-chat text through fm-inbox's idempotent note API.
// Replies use its receipts API, including handled notes, not a second queue.
// State: .telegram-offset and .telegram-sent/<delivery>-<chunk>.json.
// Definite API rejections retry at most three times, after 2s and 4s (or the
// server's longer retry_after). Attempts and backoff survive process restarts.
// Timeout/abort, interrupted sends, and exhausted retries create one idempotent
// supervisor inbox note with a manual resend command. Uncertain sends are never
// retried automatically: Telegram has no sendMessage idempotency key.
// Positional send text cannot start with --. Empty or option-only legacy
// replies are withheld with a supervisor notice, never sent or manually replayed.
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const home = process.env.FM_HOME || root;
const state = process.env.FM_STATE_OVERRIDE || join(home, "state");
const token = process.env.FM_TELEGRAM_BOT_TOKEN || "";
const chat = process.env.FM_TELEGRAM_CHAT_ID || "";
const sentDir = join(state, ".telegram-sent");
const offsetPath = join(state, ".telegram-offset");
const invalidReplies = new Set<string>();

class Rejected extends Error {
  constructor(message: string, readonly retryAfter: number) { super(message); }
}
class Deferred extends Error {}

type NoteReceipt = { id: string; saved: boolean; announced: boolean };
type InboxReceipts = {
  pending: InboxNote[];
  handled: InboxNote[];
};
type InboxNote = { id: string; body: string; request_id: string | null; reply: { body: string } | null };
type Delivery = { noteId: string; requestId: string; kind: "reply" | "receipt" };
type SendRecord = {
  status?: "sending" | "retry" | "uncertain" | "failed";
  message_id?: number;
  attempts?: number;
  nextAt?: number;
  notified?: boolean;
};

async function saved(path: string): Promise<string | null> {
  try { return await readFile(path, "utf8"); }
  catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") return null;
    throw error;
  }
}

async function atomic(path: string, text: string) {
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, text, { mode: 0o600 });
  await rename(temporary, path);
}

function apiBase() {
  const override = process.env.FM_TELEGRAM_API_BASE;
  if (!override) return "https://api.telegram.org";
  const url = new URL(override);
  if (!['127.0.0.1', '[::1]'].includes(url.hostname) || url.protocol !== "http:") {
    throw new Error("FM_TELEGRAM_API_BASE must be an HTTP loopback URL");
  }
  return url.origin;
}

async function api(method: string, body: object): Promise<unknown> {
  // Never log fetch errors: their URL contains the bot credential.
  let response: Response;
  try {
    response = await fetch(`${apiBase()}/bot${token}/${method}`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(45000),
    });
  } catch { throw new Error(`${method}: transport failed (delivery may be uncertain)`); }
  let data: unknown;
  try { data = await response.json(); }
  catch { throw new Error(`${method}: invalid response (delivery may be uncertain)`); }
  if (typeof data !== "object" || data === null || !("ok" in data)) throw new Error(`${method}: malformed response`);
  if (!response.ok && data.ok === false && "error_code" in data && typeof data.error_code === "number") {
    const parameters = "parameters" in data ? data.parameters : null;
    const retryAfter = typeof parameters === "object" && parameters !== null &&
      "retry_after" in parameters && typeof parameters.retry_after === "number" &&
      Number.isFinite(parameters.retry_after) ? Math.max(0, parameters.retry_after) : 0;
    throw new Rejected(`${method}: rejected (HTTP ${response.status})`, retryAfter);
  }
  if (!response.ok || data.ok !== true || !("result" in data)) throw new Error(`${method}: unconfirmed response`);
  return data.result;
}

function chunks(text: string): string[] {
  const parts: string[] = [];
  while (text.length) {
    let end = Math.min(4000, text.length);
    // Do not split a UTF-16 surrogate pair.
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
    parts.push(text.slice(0, end));
    text = text.slice(end);
  }
  return parts;
}

function messageProblem(text: string): string | undefined {
  if (!text.trim()) return "message is empty";
  const tokens = text.trim().split(/\s+/);
  const hasOption = tokens.some(token => token.startsWith("--"));
  const commandOnly = tokens.every((token, index) =>
    token.startsWith("--") ||
    /^(?:\/|\.\.?\/|~\/|[\w.-]+\/)\S+$/.test(token) ||
    (index > 0 && tokens[index - 1] === "--body-file"));
  if (hasOption && commandOnly) return "message contains only command options and file operands";
}

async function withholdReply(note: InboxNote, reason: string) {
  if (invalidReplies.has(note.id)) return;
  const notice = await inbox<NoteReceipt>([
    "note", "--request-id", `telegram-invalid-${note.request_id}`, "--json", "-",
  ], [
    `Telegram reply withheld: ${reason}.`,
    `Reply/note id: ${note.id}`,
    `Request id: ${note.request_id}`,
    "Automatic delivery of this body is now blocked. Publish corrected reply text with fm-telegram-send.sh.",
  ].join("\n"));
  if (!notice.saved || !notice.announced) throw new Error("invalid reply notice was not announced");
  invalidReplies.add(note.id);
}

function deliveryKey(delivery: Delivery) {
  // Preserve the marker names written by the original bridge.
  return delivery.kind === "reply" ? `reply-${delivery.requestId}` : `receipt-${delivery.requestId.slice(3)}`;
}

async function notifyFailure(marker: string, record: SendRecord, delivery: Delivery, index: number) {
  if (record.notified) return;
  const command = [
    `FM_HOME=${home}`, process.execPath, `--env-file=${join(home, ".env")}`,
    join(root, "bin/fm-telegram-bridge.ts"), "resend", delivery.noteId, delivery.kind, String(index),
  ].map(value => `'${value.replaceAll("'", "'\\''")}'`).join(" ");
  const body = [
    `Telegram ${delivery.kind} delivery ${record.status === "failed" ? "failed after 3 rejected attempts" : "is uncertain; it may already be in the chat"}.`,
    `Reply/note id: ${delivery.noteId}`,
    `Request id: ${delivery.requestId}`,
    `Chunk index: ${index}. Automatic sends stopped at this chunk.`,
    "Check the Telegram chat before resending; an uncertain send may have succeeded.",
    `Retry command: env ${command}`,
  ].join("\n");
  const receipt = await inbox<NoteReceipt>([
    "note", "--request-id", `telegram-failure-${deliveryKey(delivery)}-${index}`, "--json", "-",
  ], body);
  if (!receipt.saved || !receipt.announced) throw new Error("delivery failure notice was not announced");
  await atomic(marker, JSON.stringify({ ...record, notified: true }) + "\n");
  console.error(`telegram: delivery stopped; supervisor notified for ${delivery.noteId} chunk ${index}`);
}

async function send(text: string, delivery?: Delivery) {
  const ids: number[] = [];
  for (const [index, part] of chunks(text).entries()) {
    const marker = delivery ? join(sentDir, `${deliveryKey(delivery)}-${index}.json`) : null;
    let attempts = 0;
    if (marker && delivery) {
      const previous = await saved(marker);
      if (previous !== null) {
        // Private records are written only here; old successful markers contain just message_id.
        const record = JSON.parse(previous) as SendRecord;
        if (typeof record.message_id === "number") {
          ids.push(record.message_id);
          continue;
        }
        if (record.status !== "retry") {
          await notifyFailure(marker, { ...record, status: record.status === "failed" ? "failed" : "uncertain" }, delivery, index);
          return ids;
        }
        if ((record.nextAt || 0) > Date.now()) throw new Deferred();
        attempts = record.attempts || 0;
      }
      attempts++;
      const sending = JSON.stringify({ status: "sending", attempts }) + "\n";
      if (previous === null) await writeFile(marker, sending, { mode: 0o600, flag: "wx" });
      else await atomic(marker, sending);
    }
    let messageId: number;
    try {
      const result = await api("sendMessage", { chat_id: chat, text: part });
      if (typeof result !== "object" || result === null || !("message_id" in result) ||
          typeof result.message_id !== "number" || !Number.isSafeInteger(result.message_id)) {
        throw new Error("sendMessage: missing message id");
      }
      messageId = result.message_id;
    } catch (error) {
      if (!marker || !delivery) throw error;
      if (error instanceof Rejected && attempts < 3) {
        const delay = Math.max(2000 * 2 ** (attempts - 1), error.retryAfter * 1000);
        await atomic(marker, JSON.stringify({ status: "retry", attempts, nextAt: Date.now() + delay }) + "\n");
        throw new Deferred();
      }
      const record: SendRecord = { status: error instanceof Rejected ? "failed" : "uncertain", attempts };
      await atomic(marker, JSON.stringify(record) + "\n");
      await notifyFailure(marker, record, delivery, index);
      return ids;
    }
    if (marker) await atomic(marker, JSON.stringify({ message_id: messageId }) + "\n");
    ids.push(messageId);
  }
  return ids;
}

async function resend(noteId: string, kind: string, rawIndex: string) {
  if ((kind !== "reply" && kind !== "receipt") || !/^(0|[1-9]\d*)$/.test(rawIndex)) {
    throw new Error("resend requires a note id, reply|receipt, and a nonnegative chunk index");
  }
  const receipts = await inbox<InboxReceipts>(["receipts", "--all-pending", "--all-handled", "--all-replies"]);
  const note = [...receipts.pending, ...receipts.handled].find(item => item.id === noteId);
  if (!note?.request_id || !/^tg-\d+$/.test(note.request_id)) throw new Error("Telegram note not found");
  const delivery: Delivery = { noteId, requestId: note.request_id, kind };
  const text = kind === "reply" ? note.reply?.body || "" : `got it, #${note.id}`;
  const problem = messageProblem(text);
  if (problem) throw new Error(`refusing resend: ${problem}`);
  const part = chunks(text)[Number(rawIndex)];
  if (!part) throw new Error("resend chunk not found");
  const marker = join(sentDir, `${deliveryKey(delivery)}-${rawIndex}.json`);
  const previous = await saved(marker);
  if (!previous) throw new Error("resend requires a stopped delivery marker");
  const record = JSON.parse(previous) as SendRecord;
  if (record.message_id || !record.notified || !["uncertain", "failed"].includes(record.status || "")) {
    throw new Error("resend requires an announced failed or uncertain delivery");
  }
  // Claim before the manual attempt too: an interrupted command must not leave a reusable retry.
  await atomic(marker, JSON.stringify({ status: "sending", attempts: record.attempts, notified: true }) + "\n");
  try {
    const ids = await send(part);
    await atomic(marker, JSON.stringify({ message_id: ids[0] }) + "\n");
    return ids;
  } catch (error) {
    await atomic(marker, JSON.stringify({ ...record, status: "uncertain", notified: true }) + "\n");
    throw error;
  }
}

async function inbox<T>(args: string[], input = ""): Promise<T> {
  const child = Bun.spawn(["bash", join(root, "bin/fm-inbox.sh"), ...args], {
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state },
    stdin: new Blob([input]), stdout: "pipe", stderr: "pipe",
  });
  const [output, , code] = await Promise.all([
    new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited,
  ]);
  if (code !== 0) throw new Error(`fm-inbox ${args[0]} failed (${code})`);
  // The colocated fm-inbox.sh owns and validates these JSON output contracts.
  return JSON.parse(output) as T;
}

async function poll() {
  const raw = await saved(offsetPath);
  let offset = raw === null ? 0 : Number(raw.trim());
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error("invalid .telegram-offset");
  for (;;) {
    try {
      const updates = await api("getUpdates", { offset, timeout: 30, allowed_updates: ["message"] });
      if (!Array.isArray(updates)) throw new Error("getUpdates: expected an array");
      for (const candidate of updates) {
        const update: unknown = candidate;
        if (typeof update !== "object" || update === null || !("update_id" in update) ||
            typeof update.update_id !== "number" || !Number.isSafeInteger(update.update_id)) {
          throw new Error("getUpdates: invalid update id");
        }
        if (update.update_id < offset) continue;
        const message = "message" in update ? update.message : null;
        if (typeof message === "object" && message !== null && "chat" in message &&
            typeof message.chat === "object" && message.chat !== null && "id" in message.chat &&
            String(message.chat.id) === chat && "text" in message &&
            typeof message.text === "string" && message.text.trim()) {
          const receipt = await inbox<NoteReceipt>(["note", "--request-id", `tg-${update.update_id}`, "--json", "-"], message.text);
          if (!receipt.saved || !receipt.announced || typeof receipt.id !== "string") {
            throw new Error("inbox note was not announced");
          }
          await send(`got it, #${receipt.id}`, { noteId: receipt.id, requestId: `tg-${update.update_id}`, kind: "receipt" });
          console.log(`telegram: queued tg-${update.update_id} as ${receipt.id}`);
        }
        offset = update.update_id + 1;
        await atomic(offsetPath, `${offset}\n`);
      }
    } catch (error) {
      if (!(error instanceof Deferred)) console.error(`telegram: ${(error as Error).message}`);
      await Bun.sleep(2000);
    }
  }
}

async function replies() {
  for (;;) {
    try {
      const receipts = await inbox<InboxReceipts>(["receipts", "--all-pending", "--all-handled", "--all-replies"]);
      if (!Array.isArray(receipts.pending) || !Array.isArray(receipts.handled)) {
        throw new Error("fm-inbox: malformed receipts");
      }
      for (const note of [...receipts.pending, ...receipts.handled]) {
        if (note.request_id && /^tg-\d+$/.test(note.request_id) && note.reply) {
          try {
            const problem = messageProblem(note.reply.body);
            if (problem) {
              await withholdReply(note, problem);
              continue;
            }
            await send(note.reply.body, { noteId: note.id, requestId: note.request_id, kind: "reply" });
          } catch (error) {
            if (!(error instanceof Deferred)) console.error(`telegram: ${(error as Error).message}`);
          }
        }
      }
    } catch (error) { console.error(`telegram: ${(error as Error).message}`); }
    await Bun.sleep(2000);
  }
}

try {
  if (!/^\d+:[A-Za-z0-9_-]+$/.test(token) || !/^-?\d+$/.test(chat)) {
    throw new Error("set FM_TELEGRAM_BOT_TOKEN and FM_TELEGRAM_CHAT_ID");
  }
  apiBase();
  if (process.argv[2] === "send" && process.argv.length > 3) {
    const args = process.argv.slice(3);
    if (args.some(arg => arg.startsWith("--"))) {
      throw new Error("usage: send <text>; option-looking text arguments are not accepted");
    }
    const text = args.join(" ");
    const problem = messageProblem(text);
    if (problem) throw new Error(problem);
    console.log(JSON.stringify({ message_ids: await send(text) }));
  } else if (process.argv[2] === "resend" && process.argv.length === 6) {
    console.log(JSON.stringify({ message_ids: await resend(process.argv[3], process.argv[4], process.argv[5]) }));
  } else if (process.argv.length === 2) {
    await mkdir(sentDir, { recursive: true, mode: 0o700 });
    console.log("telegram: bridge started");
    await Promise.all([poll(), replies()]);
  } else throw new Error("usage: fm-telegram-bridge.ts [send <text> | resend <note-id> <reply|receipt> <chunk-index>]");
} catch (error) {
  console.error(`telegram: ${(error as Error).message}`);
  process.exit(1);
}
