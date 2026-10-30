#!/usr/bin/env bash
# Telegram delivery through a loopback Bot API and the real inbox executable.
# Covers chat isolation, capture, retry/backoff persistence, real HTTP timeout,
# durable failure notices, restart deduplication, manual recovery, and chunking.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if ! command -v bun >/dev/null 2>&1; then
  printf 'skip - Telegram bridge requires Bun\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-telegram-bridge)
cat > "$TMP_ROOT/scenario.mjs" <<'JS'
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
const [root, temp] = process.argv.slice(2);
const home = join(temp, 'home');
await mkdir(home);
await writeFile(join(home, '.env'), '');
const sends = [];
const rejections = [];
const held = [];
let receiptAttempts = 0;
let rejectAttempts = 0;
let allowRecovery = false;
let child;
let startingOffset = null;
const updates = [
  { update_id: 201, message: { chat: { id: 999 }, text: 'not authorized' } },
  { update_id: 202, message: { chat: { id: 123 }, text: 'phone test\n$(not shell)' } },
];
const server = Bun.serve({ hostname: '127.0.0.1', port: 0, async fetch(request) {
  const body = await request.json();
  if (request.url.endsWith('/getUpdates')) {
    if (startingOffset === null) startingOffset = body.offset;
    await Bun.sleep(100);
    return Response.json({ ok: true, result: updates.filter(u => u.update_id >= body.offset) });
  }
  if (body.text.startsWith('got it') && ++receiptAttempts === 1) {
    rejections.push(Date.now());
    return Response.json({ ok: false, error_code: 429, parameters: { retry_after: 2 } }, { status: 429 });
  }
  if (body.text === 'reject until manual recovery' && !allowRecovery) {
    rejectAttempts++;
    rejections.push(Date.now());
    return Response.json({ ok: false, error_code: 503 }, { status: 503 });
  }
  sends.push({ ...body, at: Date.now(), id: 1000 + sends.length });
  if (body.text === 'accepted before timeout') {
    // Deliberately accept the message but never return headers: the client must
    // hit its real 45-second deadline, not mistake an HTTP rejection for timeout.
    await new Promise(resolve => held.push(resolve));
  }
  return Response.json({ ok: true, result: { message_id: sends.at(-1).id } });
}});
const env = { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: join(home, 'state'),
  FM_DATA_OVERRIDE: join(home, 'data'), FM_CONFIG_OVERRIDE: join(home, 'config'),
  FM_TELEGRAM_API_BASE: `http://127.0.0.1:${server.port}`, FM_TELEGRAM_BOT_TOKEN: '123:test', FM_TELEGRAM_CHAT_ID: '123' };
function start() {
  child = Bun.spawn(['bun', join(root, 'bin/fm-telegram-bridge.ts')], { cwd: home, env, stdout: 'pipe', stderr: 'pipe' });
}
async function stop() {
  if (!child) return;
  child.kill(); await child.exited; child = null;
}
async function until(check, label, timeout = 12000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await Bun.sleep(100);
  }
  throw new Error(`timed out: ${label}`);
}
async function inbox(...args) {
  const p = Bun.spawn(['bash', join(root, 'bin/fm-inbox.sh'), ...args], { env, stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  assert.equal(code, 0, err);
  return JSON.parse(out);
}
async function records() {
  const receipts = await inbox('receipts', '--all-pending', '--all-handled', '--all-replies');
  return [...receipts.pending, ...receipts.handled];
}
try {
  start();
  await until(() => receiptAttempts === 1, 'first rejected receipt');
  await stop(); start();
  await until(() => sends.length === 1, 'receipt after restart');
  assert(sends[0].at - rejections[0] >= 1900, 'persisted backoff must survive restart');
  let notes = await records();
  assert.equal(notes.length, 1, 'foreign chat must not create a note');
  const note = notes[0];
  assert.equal(note.request_id, 'tg-202');
  assert.equal(note.body, 'phone test\n$(not shell)');
  assert.equal(sends[0].text, `got it, #${note.id}`);
  assert.equal(sends[0].chat_id, '123');
  await inbox('reply', '--json', note.id, 'accepted before timeout');
  let failure;
  await until(async () => {
    failure = (await records()).find(n => n.request_id === 'telegram-failure-reply-tg-202-0');
    return Boolean(failure);
  }, 'durable timeout notice', 60000);
  assert(failure.body.includes(note.id));
  assert(failure.body.includes('tg-202'));
  assert(failure.body.includes('Retry command: env '));
  assert.equal(sends.filter(s => s.text === 'accepted before timeout').length, 1);
  held.splice(0).forEach(resolve => resolve());
  await stop(); startingOffset = null; start();
  await until(() => startingOffset !== null, 'restart offset');
  assert.equal(startingOffset, 203);
  await Bun.sleep(2300);
  assert.equal(sends.filter(s => s.text === 'accepted before timeout').length, 1, 'no ambiguous resend after restart');
  assert.equal((await records()).filter(n => n.request_id === failure.request_id).length, 1, 'notice is idempotent');
  console.log('ok - real accepted-send timeout creates one supervisor notice and never resends after restart');

  const rejected = await inbox('note', '--request-id', 'tg-203', '--json', 'rejected reply request');
  await inbox('reply', '--json', rejected.id, 'reject until manual recovery');
  let exhausted;
  await until(async () => {
    exhausted = (await records()).find(n => n.request_id === 'telegram-failure-reply-tg-203-0');
    return Boolean(exhausted);
  }, 'exhausted retry notice');
  assert.equal(rejectAttempts, 3);
  assert(rejections.at(-2) - rejections.at(-3) >= 1900);
  assert(rejections.at(-1) - rejections.at(-2) >= 3900);
  await Bun.sleep(2300);
  assert.equal(rejectAttempts, 3, 'retry limit is durable');
  allowRecovery = true;
  const command = exhausted.body.split('\n').find(line => line.startsWith('Retry command: ')).slice(15);
  const manual = Bun.spawn(['bash', '-c', command], { env, stdout: 'pipe', stderr: 'pipe' });
  const [output, errors, code] = await Promise.all([new Response(manual.stdout).text(), new Response(manual.stderr).text(), manual.exited]);
  assert.equal(code, 0, errors);
  assert.equal(JSON.parse(output).message_ids.length, 1);
  await Bun.sleep(2300);
  assert.equal(sends.filter(s => s.text === 'reject until manual recovery').length, 1);
  console.log('ok - exactly three rejected attempts with backoff, then exact manual command sends once');

  const long = await inbox('note', '--request-id', 'tg-204', '--json', 'long answer request');
  const answer = 'x'.repeat(3999) + '🌊' + 'y'.repeat(4001);
  const before = sends.length;
  await inbox('reply', '--json', long.id, answer);
  const ack = Bun.spawn(['bash', join(root, 'bin/fm-inbox.sh'), 'drain', '--ack', long.id], { env, stdout: 'ignore', stderr: 'pipe' });
  assert.equal(await ack.exited, 0);
  await until(() => sends.length === before + 3, 'handled long reply');
  assert.equal(sends.slice(before).map(s => s.text).join(''), answer);
  assert(sends.slice(before).every(s => s.text.length <= 4000));
  await stop(); start(); await Bun.sleep(2300);
  assert.equal(sends.length, before + 3, 'completed chunks never replay');
  console.log('ok - chat filtering, capture, handled replies, Unicode splitting, and completed-send restart deduplication');

  const legacy = await inbox('note', '--request-id', 'tg-205', '--json', 'legacy malformed reply');
  const legacyBody = '--\n--body-file /var/tmp/tg-reply-slack.txt';
  const legacyFile = join(home, 'legacy-reply.txt');
  await writeFile(legacyFile, legacyBody);
  const beforeInvalid = sends.length;
  await inbox('reply', '--json', legacy.id, '--body-file', legacyFile);
  const dotted = await inbox('note', '--request-id', 'tg-208', '--json', 'dotted option reply');
  await writeFile(legacyFile, '--config.file=/var/tmp/reply.txt');
  await inbox('reply', '--json', dotted.id, '--body-file', legacyFile);
  const blank = await inbox('note', '--request-id', 'tg-206', '--json', 'legacy blank reply');
  await writeFile(join(home, 'state/inbox/.replies', blank.id),
    `id=${blank.id}\nat=2026-10-17T00:00:00Z\nseq=10000\n--\n   \n`);
  await until(async () => (await records()).filter(n => n.request_id?.startsWith('telegram-invalid-')).length === 3,
    'malformed and blank reply notices');
  assert.equal(sends.length, beforeInvalid, 'malformed replies and internal notices must never reach Telegram');
  const guarded = (await records()).find(n => n.id === legacy.id);
  assert.equal(guarded.reply.body, legacyBody, 'exercise the exact observed stored body');
  const replay = Bun.spawn(['bun', join(root, 'bin/fm-telegram-bridge.ts'), 'resend', legacy.id, 'reply', '0'],
    { cwd: home, env, stdout: 'pipe', stderr: 'pipe' });
  assert.notEqual(await replay.exited, 0, 'manual recovery cannot bypass the content guard');
  await stop(); start(); await Bun.sleep(2300);
  assert.equal(sends.length, beforeInvalid);
  assert.equal((await records()).filter(n => n.request_id?.startsWith('telegram-invalid-')).length, 3);

  for (const args of [['--', '--body-file', '/var/tmp/tg-reply-slack.txt'], [legacyBody], ['--config.file=/var/tmp/reply.txt'], ['   ']]) {
    const badSend = Bun.spawn(['bash', join(root, 'bin/fm-telegram-send.sh'), ...args],
      { cwd: home, env, stdout: 'pipe', stderr: 'pipe' });
    assert.notEqual(await badSend.exited, 0, 'direct send must refuse flags or empty text');
  }
  assert.equal(sends.length, beforeInvalid, 'direct send refusal must precede the network call');

  const valid = await inbox('note', '--request-id', 'tg-207', '--json', 'file-backed normal reply');
  const answerFile = join(home, 'answer text.txt');
  const plainAnswer = 'Reply from a file.\nUse --verbose for details.';
  await writeFile(answerFile, plainAnswer);
  await inbox('reply', '--json', valid.id, '--body-file', answerFile);
  await until(() => sends.length === beforeInvalid + 1, 'plain file-backed reply');
  assert.equal(sends.at(-1).text, plainAnswer, 'normal replies must not acquire a receipt prefix, id, or filename');
  assert(!sends.some(s => s.text.includes('Retry command:')), 'supervisor recovery commands must remain internal');
  console.log('ok - exact option-only legacy body and blank replies withheld, direct/manual bypasses refused, file reply delivered as plain text');
} finally {
  await stop(); held.splice(0).forEach(resolve => resolve()); server.stop(true);
}
JS
bun "$TMP_ROOT/scenario.mjs" "$ROOT" "$TMP_ROOT"
