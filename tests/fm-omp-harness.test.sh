#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp publishes no marker; the anchored process name `omp` is the ancestry
#      evidence, and ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names no -e at all.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one hidden custom follow-up, never a user message;
#      a wake replayed after a restart never names a cleaned-up task's status
#      file and is dropped once every row it pointed at is acknowledged.
#   8. A secondmate launch proves both preconditions of the auto-discovery it
#      depends on: an installed omp at or past the verified release, and a home
#      that carries both tracked .omp/extensions files.
#   9. Both legs of a remote secondmate launch accept omp and keep every other
#      refusal: the adapter allowlist has one owner across the transport.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  pass "session lock and tmux liveness: omp is anchored, decoys stay out"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog, prints
# the requested version banner (empty = a build that answers `--version` with
# nothing), and exits 0 for everything else (the launch itself is only recorded
# by the fake tmux).
make_fake_omp() {  # <fakebin> [version]
  local version=${2-18.1.18}
  cat > "$1/omp" <<SH
#!/usr/bin/env bash
case "\$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
  --version)
    [ -z '$version' ] || printf 'omp v%s\n' '$version'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

# A seeded secondmate home, including the two tracked supervision extensions a
# real Firstmate home carries: omp loads a secondmate's watcher and turn-end
# guard only by auto-discovering that directory.
seed_omp_secondmate_home() {  # <home> <id> [--no-extensions]
  local home=$1 id=$2 mode=${3-}
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  [ "$mode" = --no-extensions ] && return 0
  mkdir -p "$home/.omp/extensions"
  printf '// watch\n' > "$home/.omp/extensions/fm-primary-omp-watch.ts"
  printf '// turnend\n' > "$home/.omp/extensions/fm-primary-turnend-guard.ts"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$WT_DIR'" \
    "omp launch did not carry the tracked posture overlay, --auto-approve, and the pinned working directory"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

# FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
# live Herdr environment; without it auto-detection would spawn a real pane.
run_secondmate_spawn() {  # <world> <fakebin> <launch-log> <spawn-args...>
  local world=$1 fakebin=$2 launchlog=$3
  shift 3
  PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" "$@" --secondmate 2>&1
}

make_secondmate_world() {  # <name> [omp-version] [--no-extensions] -> "<world>|<home>|<fakebin>|<launch-log>"
  local name=$1 version=${2-18.1.18} mode=${3-} world home fakebin
  world="$TMP_ROOT/$name"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  seed_omp_secondmate_home "$home" sm "$mode"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin" "$version"
  : > "$world/launch.log"
  printf '%s|%s|%s|%s\n' "$world" "$home" "$fakebin" "$world/launch.log"
}

read_secondmate_world() {
  IFS='|' read -r SM_WORLD SM_HOME SM_FAKEBIN SM_LAUNCH_LOG <<EOF
$1
EOF
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home, and must
  # name NO -e, because omp auto-discovers the home's tracked .omp/extensions
  # and a file named both ways loads twice.
  local out status launch
  read_secondmate_world "$(make_secondmate_world secondmate)"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$SM_WORLD/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$SM_LAUNCH_LOG")
  case "$launch" in
    *" -e "*) fail "an omp secondmate launch must name no -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$SM_HOME'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$SM_FAKEBIN/omp'" "secondmate launch lost the omp marker or executable"
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_absent "$SM_WORLD/home/state/sm.omp-ext.ts" "a secondmate must not receive a per-task worker extension"
  pass "fm-spawn: a real omp secondmate launch relies on auto-discovery while crewmates load one -e"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local out status
  read_secondmate_world "$(make_secondmate_world secondmate-config-model)"
  printf 'omp openai-codex/gpt-nope\n' > "$SM_WORLD/home/config/secondmate-harness"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME")
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$SM_WORLD/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$SM_LAUNCH_LOG" ] || fail "a refused secondmate spawn must record no launch: $(cat "$SM_LAUNCH_LOG")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# A secondmate names no -e, so auto-discovery is the ONLY path its watcher and
# turn-end guard can load by. Both preconditions of that discovery are proven
# per launch: a home that actually carries the tracked extensions, and an
# installed omp at or past the release where the discovery itself was verified.
# Either one missing would otherwise stand up an unsupervised firstmate
# instance and report success - the exact failure a remote route cannot see.
test_secondmate_requires_discoverable_supervision_extensions() {
  local out status
  read_secondmate_world "$(make_secondmate_world secondmate-no-extensions 18.1.18 --no-extensions)"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  status=$?
  expect_code 1 "$status" "an omp secondmate home without the tracked extensions must refuse: $out"
  assert_contains "$out" "is missing .omp/extensions/fm-primary-omp-watch.ts, .omp/extensions/fm-primary-turnend-guard.ts" \
    "the refusal did not name both missing supervision extensions: $out"
  assert_absent "$SM_WORLD/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$SM_LAUNCH_LOG" ] || fail "a refused secondmate spawn must record no launch: $(cat "$SM_LAUNCH_LOG")"

  read_secondmate_world "$(make_secondmate_world secondmate-half-extensions)"
  rm -f "$SM_HOME/.omp/extensions/fm-primary-turnend-guard.ts"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  status=$?
  expect_code 1 "$status" "a home carrying only one supervision extension must refuse: $out"
  assert_contains "$out" "is missing .omp/extensions/fm-primary-turnend-guard.ts" \
    "the refusal did not name the one missing extension: $out"
  case "$out" in
    *fm-primary-omp-watch.ts*) fail "the refusal named an extension the home actually carries: $out" ;;
  esac
  pass "fm-spawn: an omp secondmate refuses a home whose supervision extensions cannot be auto-discovered"
}

test_secondmate_refuses_unverified_or_unreadable_omp() {
  local out status
  read_secondmate_world "$(make_secondmate_world secondmate-old-omp 17.9.9)"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  status=$?
  expect_code 1 "$status" "an omp older than the verified auto-discovery release must refuse: $out"
  assert_contains "$out" "omp 17.9.9 is installed" "the refusal did not name the installed version: $out"
  assert_contains "$out" "older than omp 18.1.11" "the refusal did not name the verified floor: $out"
  assert_absent "$SM_WORLD/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$SM_LAUNCH_LOG" ] || fail "a refused secondmate spawn must record no launch: $(cat "$SM_LAUNCH_LOG")"

  # An equal version is the floor itself, not older than it.
  read_secondmate_world "$(make_secondmate_world secondmate-floor-omp 18.1.11)"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  expect_code 0 $? "the verified floor version itself must launch: $out"

  # An unreadable version cannot prove the load-bearing auto-discovery surface.
  read_secondmate_world "$(make_secondmate_world secondmate-silent-omp '')"
  out=$(run_secondmate_spawn "$SM_WORLD" "$SM_FAKEBIN" "$SM_LAUNCH_LOG" sm "$SM_HOME" omp)
  status=$?
  expect_code 1 "$status" "an unreadable omp version must refuse the spawn: $out"
  assert_contains "$out" "cannot prove this omp provides the extension auto-discovery" \
    "the unreadable-version refusal did not name the missing proof: $out"
  assert_absent "$SM_WORLD/home/state/sm.meta" "an unreadable-version refusal must publish no sm.meta"
  [ ! -s "$SM_LAUNCH_LOG" ] || fail "an unreadable-version refusal must record no launch: $(cat "$SM_LAUNCH_LOG")"
  pass "fm-spawn: an omp secondmate refuses an old or unreadable runtime before endpoint creation"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-wake-notify.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh" "$repo/bin/fm-wake-notify.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendMessage returns synchronously, not a promise.
  sendMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
await new Promise((r) => setTimeout(r, 2500));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (sent[0].m.customType !== "firstmate-primary-omp-watcher-wake") throw new Error(`unexpected wake type: ${sent[0].m.customType}`);
if (sent[0].m.display !== false) throw new Error("watcher wake must stay hidden from the captain transcript");
if (!sent[0].m.content.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m.content}`);
if (sent[0].o?.deliverAs !== "followUp" || sent[0].o?.triggerTurn !== true) throw new Error("wake must be a turn-triggering follow-up");
// A streaming delivery is consumed by its hidden custom message, without using
// the user role reserved for captain-authored input.
await handlers.get("message_start")({
  type: "message_start",
  message: { role: "custom", ...sent[0].m },
}, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one hidden custom follow-up"
}

# --- 7. Remote secondmate placement -------------------------------------------

# bin/fm-remote-readiness-lib.sh owns the one adapter allowlist both legs of a
# remote launch read, so these cases drive the parent gate and the host-local
# gate through their executables and assert they agree on omp. Neither reaches
# a real host: the parent leg stops at its readiness gate over a fake SSH
# boundary, and the host leg stops at its endpoint and backend checks.

make_remote_control_home() {  # <dir> <id> -> <home>
  local home=$1 id=$2
  seed_omp_secondmate_home "$home" "$id"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

remote_control() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@" 2>&1
}

test_remote_host_leg_accepts_omp() {
  local home out status
  home=$(make_remote_control_home "$TMP_ROOT/remote-host-leg/sm" rsm)

  out=$(remote_control "$home" relaunch rsm notaharness default default)
  status=$?
  expect_code 1 "$status" "an unverified runtime must still refuse a remote restart: $out"
  assert_contains "$out" "unverified remote secondmate harness: notaharness" \
    "the host leg did not refuse an unverified runtime: $out"

  # omp passes the adapter gate and stops at the endpoint requirement instead,
  # which is the next check a real restart reaches.
  out=$(remote_control "$home" relaunch rsm omp default default)
  status=$?
  expect_code 1 "$status" "a restart with no endpoint must still refuse: $out"
  case "$out" in
    *"unverified remote secondmate harness"*) fail "the host leg refused omp as an unverified runtime: $out" ;;
  esac
  assert_contains "$out" "endpoint metadata is invalid" \
    "the omp restart did not reach the endpoint check: $out"

  # The Herdr pin outranks the adapter gate for a launch, so an omp launch on
  # another backend refuses for the backend rather than the runtime.
  out=$(remote_control "$home" launch rsm omp - - tmux)
  status=$?
  expect_code 1 "$status" "a non-herdr remote launch must refuse: $out"
  assert_contains "$out" "a remote secondmate runs only on the herdr backend, not 'tmux'" \
    "the omp launch did not reach the backend pin: $out"
  pass "fm-remote-secondmate-control: the host-local launch and restart gates accept omp and keep every other refusal"
}

test_remote_parent_leg_accepts_omp() {
  local dir parent fakebin out status
  dir="$TMP_ROOT/remote-parent-leg"
  parent="$dir/parent"
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects"
  touch "$parent/state/.last-watcher-beat"
  cat > "$parent/data/secondmates.md" <<'EOF'
- rsm - Remote omp delivery (host: omp-host; root: /remote/root; home: /remote/home; scope: remote omp work; projects: none; added 2026-09-12)
EOF
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf 'check herdr-server=human: no Aqua login session exists\n'
printf 'error: this host is not ready for a remote second mate; unresolved: herdr-server\n' >&2
exit 1
SH
  chmod +x "$fakebin/fake-ssh"

  out=$(FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" rsm --secondmate --harness omp 2>&1)
  status=$?
  expect_code 1 "$status" "the remote spawn should stop at its readiness gate: $out"
  case "$out" in
    *"requires a verified harness adapter"*) fail "the parent gate refused omp before reaching readiness: $out" ;;
  esac
  assert_contains "$out" "host omp-host is not ready for a remote second mate" \
    "the omp remote spawn did not reach the host readiness gate: $out"
  assert_absent "$parent/state/rsm.meta" "a refused remote spawn must publish no task record"

  out=$(FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" rsm --secondmate --harness muse 2>&1)
  status=$?
  expect_code 1 "$status" "a crewmate-only adapter must refuse a remote secondmate spawn: $out"
  assert_contains "$out" "remote secondmate spawn requires a verified harness adapter" \
    "the parent gate accepted an adapter with no primary supervision protocol: $out"
  pass "fm-spawn: the parent remote-secondmate gate accepts omp and still refuses an adapter without a supervision protocol"
}

# The captain-visible defect: while main is busy and cannot drain, every
# actionable watcher cycle used to inject its own follow-up, even though the
# durable queue already coalesces and one acknowledgement retires every row a
# drain presented. The suppressed cycle must still arm its successor and still
# run the handling handshake; only the main injection is skipped, and only while
# the earlier notification's rows are still unacknowledged.
test_watch_extension_coalesces_unacknowledged_wakes() {
  local repo home out status
  repo="$TMP_ROOT/watch-coalesce/repo"; home="$TMP_ROOT/watch-coalesce/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # Each arm child queues a real durable row and closes actionably. The third
  # waits for the test's simulated acknowledgement before it queues anything.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --handling-delivered ]; then
  printf 'handshake %s\n' "$2" >> "${FM_HOME:?}/state/.handshakes"
  exit 0
fi
n=$(cat "${FM_HOME:?}/state/.arm-count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_HOME/state/.arm-count"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$n"
# shellcheck source=/dev/null
. "${FM_ROOT_OVERRIDE:?}/bin/fm-wake-lib.sh"
case "$n" in
  1|2)
    fm_wake_append signal "alpha-$n.status" "signal: cycle $n" || exit 1
    sleep 0.3
    printf 'signal: cycle %s\n' "$n"
    exit 0
    ;;
  3)
    i=0
    while [ ! -e "$FM_HOME/state/.ack-done" ] && [ "$i" -lt 150 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    fm_wake_append signal "alpha-3.status" "signal: cycle 3" || exit 1
    sleep 0.3
    printf 'signal: cycle 3\n'
    exit 0
    ;;
  *) sleep 30 ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  // omp sendMessage returns synchronously, not a promise.
  sendMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const settle = async (predicate, label) => {
  for (let i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`${label}: gave up; sent=${sent.length} arms=${armCount()} queue=${queueRows().length}`);
};
const armCount = () => (existsSync(`${state}/.arm-count`) ? Number(readFileSync(`${state}/.arm-count`, "utf8").trim()) : 0);
const handshakes = () => (existsSync(`${state}/.handshakes`) ? readFileSync(`${state}/.handshakes`, "utf8").trim().split("\n").filter(Boolean) : []);
const queueRows = () => (existsSync(`${state}/.wake-queue`) ? readFileSync(`${state}/.wake-queue`, "utf8").split("\n").filter(Boolean) : []);
await tool.execute();
// Cycle 1 closes actionably with one queued row: main must be told once.
await settle(() => sent.length === 1 && armCount() >= 2, "first actionable close did not deliver one follow-up");
// Cycle 2 queues another row while main has acknowledged nothing.
await settle(() => armCount() >= 3, "the suppressed cycle never armed its successor");
await new Promise((r) => setTimeout(r, 400));
if (sent.length !== 1) throw new Error(`an unacknowledged queue took ${sent.length} follow-ups: ${JSON.stringify(sent.map((s) => s.m.slice(0, 60)))}`);
if (queueRows().length !== 2) throw new Error(`the suppressed cycle lost its durable row: ${JSON.stringify(queueRows())}`);
if (handshakes().length < 2) throw new Error(`the suppressed cycle skipped its handling handshake: ${JSON.stringify(handshakes())}`);
// Main drains and acknowledges: every row the outstanding notification covered leaves the queue.
const announced = Number(execFileSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-wake-notify.sh`, "state"], { encoding: "utf8" }).trim());
if (!Number.isInteger(announced) || announced < 1) throw new Error(`no announced-through sequence was recorded: ${announced}`);
writeFileSync(`${state}/.wake-queue`, queueRows().filter((row) => Number(row.split("\t")[1]) > announced).map((r) => `${r}\n`).join(""));
writeFileSync(`${state}/.ack-done`, "");
// Cycle 3 queues a row above the acknowledged sequence: main must be told again.
await settle(() => sent.length === 2, "an acknowledged queue did not reopen delivery");
for (const wake of sent) {
  if (wake.m.customType !== "firstmate-primary-omp-watcher-wake") throw new Error(`unexpected wake type: ${wake.m.customType}`);
  if (wake.m.display !== false) throw new Error("watcher wake must stay hidden from the captain transcript");
  if (!wake.m.content.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: cycle ")) throw new Error(`unexpected wake text: ${wake.m.content}`);
  if (wake.o?.deliverAs !== "followUp" || wake.o?.triggerTurn !== true) throw new Error("wake must be a turn-triggering follow-up");
}
if (sent[0].m.content === sent[1].m.content) throw new Error("the reopened delivery repeated the suppressed cycle instead of the new one");
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension coalescing contract: $out"
  [ -z "$out" ] || fail "omp watch coalescing test printed output: $out"
  pass ".omp watch extension: one follow-up while the queue stays unacknowledged, successor and handshake preserved, delivery reopens after acknowledgement"
}

# omp binds this module's already-imported factory again for every in-process
# child session (the task tool, eval agent(), /tan): one module, two bindings,
# one process pid, so the child also passes the session-lock check. A child must
# never take the watch: it arms nothing, receives no wake, and its end
# (session_shutdown, with no session_start after it) leaves the primary armed.
test_watch_extension_child_session_never_owns_the_watch() {
  local repo home out status
  repo="$TMP_ROOT/watch-child/repo"; home="$TMP_ROOT/watch-child/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
n=$(cat "${FM_HOME:?}/state/.arm-count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_HOME/state/.arm-count"
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-%s\n' "$$" "$n"
if [ "$n" = 1 ]; then
  i=0
  while [ ! -e "$FM_HOME/state/.fire" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  printf 'signal: primary wake\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const bind = (mod) => {
  const binding = { handlers: new Map(), tool: null, sent: [] };
  mod.default({
    on(e, h) { binding.handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { binding.tool = t; },
    sendMessage(m, o) { binding.sent.push({ m, o }); return undefined; },
  });
  return binding;
};
const armCount = () => (existsSync(`${state}/.arm-count`) ? Number(readFileSync(`${state}/.arm-count`, "utf8").trim()) : 0);
const settle = async (predicate, label) => {
  for (let i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`${label}: gave up; arms=${armCount()}`);
};
const mod = await import(pathToFileURL(process.env.EXT).href);
const primary = bind(mod);
await primary.handlers.get("session_start")({}, {});
await settle(() => armCount() === 1, "the primary session_start did not arm");
const child = bind(mod);
await child.handlers.get("session_start")({}, {});
const childArm = await child.tool.execute();
if (childArm.details?.ok !== false || !/^watcher: not armed - this omp session is a child session/.test(childArm.content[0].text)) {
  throw new Error(`a child session's arm call was not refused: ${childArm.content[0].text}`);
}
await child.handlers.get("session_shutdown")({}, {});
await new Promise((r) => setTimeout(r, 300));
if (armCount() !== 1) throw new Error(`the child session started a watcher cycle of its own (arms=${armCount()})`);
const primaryArm = await primary.tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(primaryArm.content[0].text)) {
  throw new Error(`the primary lost its watcher when the child session ended: ${primaryArm.content[0].text}`);
}
writeFileSync(`${state}/.fire`, "");
await settle(() => primary.sent.length === 1, "the primary received no wake after the child session ended");
if (!primary.sent[0].m.content.includes("FIRSTMATE WATCHER WAKE: signal: primary wake")) throw new Error(`unexpected wake: ${primary.sent[0].m.content}`);
if (child.sent.length !== 0) throw new Error(`a wake was injected into the child session: ${JSON.stringify(child.sent)}`);
await primary.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension child-session contract: $out"
  [ -z "$out" ] || fail "omp watch child-session test printed output: $out"
  pass ".omp watch extension: an in-process child session never arms or receives wakes, and its end leaves the primary armed"
}

# A session_shutdown that no session_start follows, in a process that keeps
# serving turns, must not strand the watch: the next arm call (the tool, or the
# next agent start on its own) arms a fresh generation that replays the stuck
# handoff token and delivers later wakes, and a refusal names that token.
test_watch_extension_heals_shutdown_without_start() {
  local repo home out status
  repo="$TMP_ROOT/watch-orphan/repo"; home="$TMP_ROOT/watch-orphan/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # Cycle 1 queues its row, reports an actionable line, and stays up, so the
  # shutdown persists it as a handoff token whose row is still unacknowledged.
  # Cycle 2 closes on the test's cue; later cycles idle.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
n=$(cat "${FM_HOME:?}/state/.arm-count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FM_HOME/state/.arm-count"
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-%s\n' "$$" "$n"
case "$n" in
  1)
    # shellcheck source=/dev/null
    . "${FM_ROOT_OVERRIDE:?}/bin/fm-wake-lib.sh"
    fm_wake_append signal stuck.status "signal: stuck wake" || exit 1
    printf 'signal: stuck wake\n'
    sleep 30
    ;;
  2)
    i=0
    while [ ! -e "$FM_HOME/state/.fire" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    printf 'signal: after recovery\n'
    exit 0
    ;;
  *) sleep 30 ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const marker = `${state}/.omp-watch-extension-loaded`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const bind = (mod) => {
  const binding = { handlers: new Map(), tool: null, sent: [] };
  mod.default({
    on(e, h) { binding.handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { binding.tool = t; },
    sendMessage(m, o) { binding.sent.push({ m, o }); return undefined; },
  });
  return binding;
};
const armCount = () => (existsSync(`${state}/.arm-count`) ? Number(readFileSync(`${state}/.arm-count`, "utf8").trim()) : 0);
const settle = async (predicate, label) => {
  for (let i = 0; i < 200; i += 1) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`${label}: gave up; arms=${armCount()}`);
};
const mod = await import(pathToFileURL(process.env.EXT).href);
const primary = bind(mod);
await primary.handlers.get("session_start")({}, {});
await settle(() => armCount() === 1, "the primary session_start did not arm");
await new Promise((r) => setTimeout(r, 500));
await primary.handlers.get("session_shutdown")({}, {});
if (!existsSync(handoff)) throw new Error("the shutdown did not persist the pending actionable wake");
const [stuck] = JSON.parse(readFileSync(handoff, "utf8")).pending.map((pending) => pending.token);
// While another binding's generation is live, the stranded one cannot recover
// and its refusal names the token it is holding.
const replacement = bind(mod);
const refused = await primary.tool.execute();
if (refused.details?.ok !== false || !refused.content[0].text.includes(stuck) || !refused.content[0].text.includes("recovery attempted")) {
  throw new Error(`the refusal did not name the stuck token and the attempted recovery: ${refused.content[0].text}`);
}
await replacement.handlers.get("session_shutdown")({}, {});
// A short-lived process overwrote the loaded marker in the meantime.
writeFileSync(marker, `${readFileSync(marker, "utf8").split("\n")[0]}\n2147483646\n`);
const healed = await primary.tool.execute();
const text = healed.content[0].text;
if (!/^watcher: started omp extension arm child 1;/.test(text) || !text.includes(stuck)) {
  throw new Error(`the arm call after a shutdown with no session_start did not arm a fresh generation naming the stuck token: ${text}`);
}
if (readFileSync(marker, "utf8").split("\n")[1] !== String(process.pid)) throw new Error("the arm call did not reconcile the loaded marker to this session");
await settle(() => primary.sent.length === 1, "the stuck wake was not replayed");
if (!primary.sent[0].m.content.includes("FIRSTMATE WATCHER WAKE: signal: stuck wake")) throw new Error(`unexpected replay: ${primary.sent[0].m.content}`);
// Main handles the replayed wake and acknowledges its row, so the next cycle's
// wake is not covered by the replayed notification.
writeFileSync(`${state}/.wake-queue`, "");
writeFileSync(`${state}/.fire`, "");
await settle(() => primary.sent.length === 2, "wakes did not inject again after recovery");
if (!primary.sent[1].m.content.includes("FIRSTMATE WATCHER WAKE: signal: after recovery")) throw new Error(`unexpected wake: ${primary.sent[1].m.content}`);
for (const wake of primary.sent) {
  await primary.handlers.get("message_start")({ type: "message_start", message: { role: "custom", ...wake.m } }, {});
}
// The automatic path: a second stranding recovers at the next agent start.
await primary.handlers.get("session_shutdown")({}, {});
const before = armCount();
await primary.handlers.get("before_agent_start")({ prompt: "next turn" }, {});
await settle(() => armCount() === before + 1, "the next agent start did not arm a fresh generation");
const again = await primary.tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`the automatic recovery left no owned cycle: ${again.content[0].text}`);
await primary.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension shutdown-without-start contract: $out"
  [ -z "$out" ] || fail "omp watch shutdown-without-start test printed output: $out"
  pass ".omp watch extension: after a shutdown with no session_start the next arm call or agent start arms a fresh generation, replays the stuck token, and wakes inject again"
}

# omp persists every wake a session had not yet consumed when it ended, and the
# next session replays it. The replay carries the reason line exactly as its
# watcher cycle printed it, so a restart after a task's cleanup used to wake the
# supervisor naming that task's removed status file while the drain found
# nothing. A replay must never name a status file that no longer exists, and a
# replayed wake whose durable rows were all acknowledged must not wake at all.
test_watch_extension_restart_never_replays_a_cleaned_up_task() {
  local repo home state out status
  repo="$TMP_ROOT/watch-replay/repo"; home="$TMP_ROOT/watch-replay/home"; state="$home/state"
  install_omp_extension_fixture "$repo"
  mkdir -p "$state"
  # A cycle fires once when the test writes .fire: it queues one durable row per
  # named file, as the real watcher does before printing, then prints the list.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ -s "${FM_HOME:?}/state/.fire" ]; then
  files=$(cat "$FM_HOME/state/.fire")
  rm -f "$FM_HOME/state/.fire"
  # shellcheck source=/dev/null
  . "${FM_ROOT_OVERRIDE:?}/bin/fm-wake-lib.sh"
  for f in $files; do fm_wake_append signal "${f##*/}" "signal: $files" || exit 1; done
  sleep 0.3
  printf 'signal: %s\n' "$files"
  exit 0
fi
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # One omp session per call. "fire" receives the wake, never consumes it, and
  # ends, so the shutdown persists it. "restart" is the next session: it prints
  # every wake it was handed.
  omp_session() {  # <fire|restart>
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" SESSION_MODE=$1 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
      FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default({
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendMessage(m) { sent.push(m.content); return undefined; },
});
await handlers.get("session_start")({}, {});
if (process.env.SESSION_MODE === "fire") {
  for (let i = 0; i < 100 && sent.length === 0; i += 1) await new Promise((r) => setTimeout(r, 50));
  if (sent.length !== 1) throw new Error(`the firing session received ${sent.length} wakes`);
  await handlers.get("session_shutdown")({}, {});
  if (!existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("the unconsumed wake was not persisted");
} else {
  await new Promise((r) => setTimeout(r, 2000));
  for (const wake of sent) console.log(`WAKE ${wake.slice(wake.indexOf("FIRSTMATE WATCHER WAKE:")).split("\n")[0]}`);
  await handlers.get("session_shutdown")({}, {});
}
process.exit(0);
EOF
  }
  clean_up_task() {  # <id>: the task's status and turn-end files leave, and main acknowledges its rows
    rm -f "$state/$1.status" "$state/$1.turn-ended"
    : > "$state/.wake-queue"
  }

  # 1. Every row acknowledged: the replay has nothing left to announce.
  : > "$state/torn.status"
  printf '%s' "$state/torn.status" > "$state/.fire"
  out=$(omp_session fire); status=$?
  expect_code 0 "$status" "the first session did not receive its wake: $out"
  clean_up_task torn
  out=$(omp_session restart); status=$?
  expect_code 0 "$status" "the restarted session failed: $out"
  assert_not_contains "$out" "torn.status" "a restart replayed a wake naming a cleaned-up task's status file"
  assert_not_contains "$out" "WAKE " "a restart woke the supervisor for a wake whose rows were all acknowledged: $out"
  assert_absent "$state/extensions/omp-primary-watch/session-replacement-actionable.json" \
    "a replay that is no longer owed stayed in the handoff and would replay again"

  # 2. A newer row for a live task is still unacknowledged: the replay still
  # wakes the supervisor, naming only the status file that still exists.
  : > "$state/torn.status"; : > "$state/live.status"
  printf '%s %s' "$state/torn.status" "$state/live.status" > "$state/.fire"
  out=$(omp_session fire); status=$?
  expect_code 0 "$status" "the second firing session did not receive its wake: $out"
  clean_up_task torn
  FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal live.status "signal: $2"' \
    _ "$repo" "$state/live.status" || fail "could not queue the live task's newer row"
  out=$(omp_session restart); status=$?
  expect_code 0 "$status" "the second restarted session failed: $out"
  assert_not_contains "$out" "torn.status" "a restart replayed a wake naming a cleaned-up task's status file"
  assert_contains "$out" "WAKE FIRSTMATE WATCHER WAKE: signal: $state/live.status" \
    "a restart with an unacknowledged row did not wake the supervisor for the live task: $out"
  pass ".omp watch extension: a restart after a task's cleanup never replays its status file, and replays nothing once every row is acknowledged"
}

# The loaded markers vouch for the process in state/.lock, so a descendant omp
# that sees the lock holder in its ancestry (the `omp models` listing that
# bin/fm-spawn.sh runs from the primary's own shell loads both extensions) must
# leave them alone instead of recording its own short-lived pid.
test_extension_markers_name_only_the_lock_holder() {
  local repo home out status
  repo="$TMP_ROOT/marker-descendant/repo"; home="$TMP_ROOT/marker-descendant/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" EXT_DIR="$repo/.omp/extensions" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
// The shell that started this process holds the lock: an ancestor, not this pid.
writeFileSync(`${state}/.lock`, `${process.ppid}\n`);
const markers = [".omp-watch-extension-loaded", ".omp-turnend-extension-loaded"];
for (const name of markers) writeFileSync(`${state}/${name}`, `sha256:holder\n${process.ppid}\n`);
for (const file of ["fm-primary-omp-watch.ts", "fm-primary-turnend-guard.ts"]) {
  const mod = await import(pathToFileURL(`${process.env.EXT_DIR}/${file}`).href);
  mod.default({ on() {}, registerCommand() {}, registerTool() {}, sendMessage() {} });
}
for (const name of markers) {
  const recorded = readFileSync(`${state}/${name}`, "utf8");
  if (recorded !== `sha256:holder\n${process.ppid}\n`) throw new Error(`${name} was overwritten by a descendant of the lock holder: ${JSON.stringify(recorded)}`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp extension marker ownership contract: $out"
  [ -z "$out" ] || fail "omp extension marker test printed output: $out"
  pass ".omp extensions: a descendant of the lock holder never overwrites either loaded marker"
}

test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_secondmate_requires_discoverable_supervision_extensions
test_secondmate_refuses_unverified_or_unreadable_omp
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_coalesces_unacknowledged_wakes
test_watch_extension_child_session_never_owns_the_watch
test_watch_extension_heals_shutdown_without_start
test_watch_extension_restart_never_replays_a_cleaned_up_task
test_extension_markers_name_only_the_lock_holder
test_remote_host_leg_accepts_omp
test_remote_parent_leg_accepts_omp
