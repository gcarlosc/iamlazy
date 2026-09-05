#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 2 (the log exists), Guarantee 4 (the scope gate
# is audible) and Guarantee 5 (circuit breaker).
#
# Fires on every Stop -- which is every assistant turn, not only the real close
# of a run. Guarded twice: this SESSION must have an active run, and the turn
# must actually BE the close (see hk_close_signal in lib.sh). Clearing the run
# file is what marks the run flushed to any later Stop in the session, reusing
# that same guard instead of a second state file.
#
# SCOPE, stated honestly: this writes the MECHANICAL skeleton -- identity,
# timing, intervention count, files/lines changed, weighted cost. It does NOT
# write critic_findings or gate_verdict: those are semantic and still need a
# place on disk for the model to leave them. This guarantees the LINE exists,
# not that it is complete.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard "$payload" || exit 0
TMP="$HK_RUN_TMP"

# stop_hook_active=true means THIS Stop is itself the result of a blocking hook
# on a prior Stop. Skip, so the breaker and the scope gate can never loop.
hk_bool_true "$payload" "stop_hook_active" && exit 0

sid=$(hk_field "$payload" "session_id")
cwd=$(hk_field "$payload" "cwd")
tpath=$(hk_field "$payload" "transcript_path")
# The work may live somewhere other than the session's cwd (see hk_project_root).
root=$(hk_project_root "$TMP" "$cwd")
contract="${root}/.iamlazy/contract.md"
base=$(hk_field_file "$TMP" "base_ref")
ubase=$(hk_untracked_file "$TMP")

# The stage this turn reached, kept so a run records where it got to instead of
# just that it ended. Overwritten every turn; a sidecar file rather than a JSON
# field so nothing has to rewrite the object in place.
#
# Read back from the sidecar, never from this turn's variable. The first real
# run logged `stage_reached: ""` because it closed on a turn that carried no
# banner ("the critic is still running"), while the sidecar correctly held
# EJECUCIÓN from the turn before. hk_flush_abandoned already read the sidecar;
# this path did not, and the two disagreeing is how the empty value shipped.
turn_stage=$(hk_stage "$payload")
[ -n "$turn_stage" ] && printf '%s' "$turn_stage" > "$(hk_stage_file "$TMP")"
stage=$(cat "$(hk_stage_file "$TMP")" 2>/dev/null)

# Whether the Critic has returned. Recorded by subagent-done.sh on SubagentStop;
# hk_close_signal refuses to close a contract run before the review lands.
HK_CRITIC_DONE=$(hk_json_num "$TMP" "critic_done")
critic_findings=$(cat "$(hk_findings_file "$TMP")" 2>/dev/null)

# --- changed-file accounting (needed by the circuit breaker, so computed first)
files_changed=""
lines_changed=""
if [ -n "$root" ] && [ ! -d "$root/.git" ]; then
  # No repository: lines_changed, the scope ledger and any chance of undo are
  # all unavailable. Verified on a real run -- a new project was built without
  # `git init`, and the close reported 0 lines for 132 real ones while the
  # scope gate passed everything. A guarantee that is off must say so, ONCE:
  # the same run then repeated the warning on all 33 of its turns.
  if ! grep -q '"nogit_warned"' "$TMP" 2>/dev/null; then
    hk_set_field "$TMP" "nogit_warned" "1"
    printf '{"systemMessage":"iamlazy: %s no es un repositorio git. lines_changed, el registro de alcance y el undo no estan disponibles, asi que esta corrida trabaja con sus garantias degradadas. Corre git init y un commit inicial antes de seguir."}\n' "$root"
  fi
fi
if [ -n "$base" ]; then
  files_changed=$(hk_changed_files "$root" "$base" "$ubase" | grep -c . | tr -d ' ')
  lines_changed=$(hk_changed_lines "$root" "$base" "$ubase")
fi

# --- weighted cost of THIS run (delta, not the whole session)
run_tokens=""
if end_tokens=$(hk_weighted_tokens "$tpath"); then
  st=$(hk_json_num "$TMP" "start_tokens")
  run_tokens=$((end_tokens - ${st:-0}))
fi

# ---------------------------------------------------------------- Guarantee 5
# Circuit breaker. Persisting without a new hypothesis is the failure, not the
# virtue. The signal is arithmetic, not judgement: weighted cost per changed
# line.
#
# RECALIBRATED 2026-08-27 against de-duplicated counts. The first calibration
# used a token sum that double-counted usage blocks (~4x high), so both the
# healthy baseline and the threshold were inflated by the same error and the
# ratio happened to look sane. Real figures, recomputed from the transcripts:
#   iamlazy-stats   1,457,005 / 389 lines =  3,745
#   rotaturno       955,723   / 132 lines =  7,240
#   the lost run    4,751,120 / 230 lines = 20,657   <- 7 attempts, ~2 hours
# 14,000 sits about 2x above the worst healthy run and comfortably below the
# lost one. Three data points is thin: if this fires on a run that was fine,
# the threshold is wrong, not the run.
#
# Note what this catches that an acceptance-command check cannot: that run
# logged validation_result=passed on all seven attempts. The tests kept
# passing; it was failing in the browser. "The command failed twice" would
# never have fired. Cost per line did.
DRIFT_RATIO=14000
DRIFT_MIN_LINES=50
DRIFT_MIN_TOKENS=1000000

if ! grep -q '"drift_warned"' "$TMP" 2>/dev/null \
   && [ -n "$run_tokens" ] \
   && [ "$run_tokens" -ge "$DRIFT_MIN_TOKENS" ] \
   && [ "${lines_changed:-0}" -ge "$DRIFT_MIN_LINES" ]; then
  ratio=$((run_tokens / lines_changed))
  if [ "$ratio" -ge "$DRIFT_RATIO" ]; then
    # Mark before blocking, so this warns once and never nags again.
    hk_set_field "$TMP" "drift_warned" "1"
    # `decision`/`reason` is the documented decision-control shape for Stop;
    # `systemMessage` is a TOP-LEVEL field, not one nested inside
    # hookSpecificOutput, which is where this used to put it. Per the hooks
    # reference, on exit 2 the blocking message is the JSON reason when there
    # is one and stderr otherwise -- so all three channels agree here instead
    # of relying on whichever one the build happens to honour.
    printf '{"decision":"block","reason":"iamlazy: esta corrida gasta %s tokens ponderados por linea cambiada (las sanas estan entre 3.000 y 5.500). El esfuerzo se esta yendo en intentos, no en avance. Deja de implementar y decilo claro: cual es la hipotesis, por que fallo el ultimo intento, y que CAMBIA ahora. Si la respuesta honesta es -probar otra cosa-, la hipotesis esta mal: volve al humano con lo que quedo descartado.","systemMessage":"iamlazy: %s tokens ponderados por linea cambiada. Circuit breaker disparado."}\n' "$ratio" "$ratio"
    cat >&2 <<MSG
iamlazy: this run is spending ${ratio} weighted tokens per changed line. Healthy runs sit
around 3,000-5,500. That ratio means the effort is going into attempts, not progress.

Stop implementing. Before the next edit, state plainly: what is the hypothesis, why did the
last attempt fail, and what CHANGES in the hypothesis now? If the honest answer is "try
something else", the hypothesis is wrong -- take it back to the human with what has been
ruled out, rather than making another attempt.
MSG
    exit 2
  fi
fi

# ---------------------------------------------------------------- Guarantee 2
if ! signal=$(hk_close_signal "$payload" "$contract" "$root" "$base" "$ubase"); then

  # ------------------------------------------------------------- Guarantee 4
  # The scope gate, made audible. It used to return exit 0 with no output: a
  # file outside ## Scope, or an unticked group, silently kept the run open
  # while the model believed it had finished.
  #
  # It speaks ONLY when the turn carries the CLOSE banner -- when the model
  # thinks it is done. Blocking every Stop that has pending groups would be
  # worse than the silence: mid-run the groups are SUPPOSED to be open, and a
  # hook that refuses those turns traps the session in a treadmill where the
  # human can never get a word in. "You believe you are closing and you are
  # not, here is why" is the only moment the interruption earns its cost.
  #
  # Warned once per DISTINCT blocker set: if the model resolves one deviation
  # and introduces another, that is new information and gets said. Repeating
  # the same list is not.
  if hk_has_close_banner "$payload"; then
    blockers=$(hk_close_blockers "$root" "$contract" "$base" "$ubase")
    if [ -n "$blockers" ]; then
      gate=$(hk_gate_file "$TMP")
      if [ "$blockers" != "$(cat "$gate" 2>/dev/null)" ]; then
        printf '%s' "$blockers" > "$gate"
        one_line=$(printf '%s' "$blockers" | tr '\n' ' ' | tr -d '\\"')
        printf '{"decision":"block","reason":"iamlazy: la corrida no puede cerrar todavia. %s Declara el desvio agregando la ruta a ## Scope en .iamlazy/contract.md con su justificacion, o revertí el archivo. Marca los grupos con - [x] a medida que su comando de aceptacion pasa.","systemMessage":"iamlazy: cierre bloqueado -- %s"}\n' \
          "$one_line" "$one_line"
        printf 'iamlazy: close blocked -- %s\n' "$one_line" >&2
        exit 2
      fi
    fi
  fi
  exit 0
fi

start_epoch=$(hk_json_num "$TMP" "start_epoch")
now_epoch=$(date +%s)
duration=""
[ -n "$start_epoch" ] && duration=$((now_epoch - start_epoch))

# Counted as a DELTA, like the token cost: the transcript accumulates the whole
# session, so a second run in it would otherwise inherit the first one's
# interruptions.
human_interventions=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  hi_now=$(grep -c 'Request interrupted by user' "$tpath" 2>/dev/null | tr -d ' ')
  hi_start=$(hk_json_num "$TMP" "start_interventions")
  human_interventions=$(( ${hi_now:-0} - ${hi_start:-0} ))
  [ "$human_interventions" -lt 0 ] && human_interventions=0
fi

# --- semantic fields, derived only where derivation is trustworthy
# task_summary comes from the contract's own "# Task" heading: the model
# already wrote it there and the human approved it, so it is a record, not a
# self-report.
task_summary=""
if [ -f "$contract" ]; then
  task_summary=$(awk '/^# Task/{f=1;next} /^#/{if(f)exit} f&&NF{print;exit}' "$contract" \
    | tr '\t' ' ' | cut -c1-160)
  task_summary=$(hk_json_esc "$task_summary")
fi

# project_md: absent / read / updated, decided by the diff, never by opinion.
project_md="absent"
if [ -f "${root}/PROJECT.md" ]; then
  project_md="read"
  if [ -n "$base" ] && (cd "$root" && git diff --name-only "$base" -- PROJECT.md 2>/dev/null | grep -q .); then
    project_md="updated"
  fi
fi

# critic_findings now comes from SubagentStop's own last_assistant_message
# (see subagent-done.sh), which is the Critic's closing text and nothing else --
# so it does not hit the false positive that blocked this before, where a
# transcript grep also matched the EXAMPLE inside the Critic's own prompt
# (verified 2026-08-25: it returned 0/1/3/0 from documentation, not a review).
# It is empty when the Critic never ran or never emitted a tally, and empty is
# the honest value there.
#
# Still NOT derived: gate_verdict. It would come from ExitPlanMode, whose
# payload shape is unconfirmed. An absent field is honest; a confidently wrong
# one is not, and this project already shipped a token count wrong in 7/7 runs.

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

hk_log_append "$(printf '{"schema_version":3,"timestamp":"%s","task_summary":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","base_ref":"%s","duration_seconds":%s,"human_interventions":%s,"files_changed":%s,"lines_changed":%s,"tokens_weighted":%s,"project_md":"%s","stage_reached":"%s","critic_findings":"%s","close_detected_via":"%s","outcome":"flushed"}' \
  "$now_iso" "$task_summary" "$(hk_json_esc "$sid")" "$(hk_json_esc "$tpath")" \
  "$(hk_json_esc "$root")" "$(hk_json_esc "$base")" \
  "${duration:-null}" "$human_interventions" "${files_changed:-0}" "${lines_changed:-0}" \
  "${run_tokens:-null}" "$project_md" "$(hk_json_esc "$stage")" \
  "$(hk_json_esc "$critic_findings")" "$signal")"

hk_run_clear "$TMP"
exit 0
