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
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard "$payload" || exit 0
TMP="$HK_RUN_TMP"

# stop_hook_active=true means THIS Stop is itself the result of a blocking hook
# on a prior Stop. It must not block AGAIN -- that is the loop the flag exists
# to prevent -- but it must still be allowed to CLOSE, and skipping the turn
# outright was wrong.
#
# Only a real run could show it, and it took the first time the scope gate ever
# blocked a close on any host (OpenCode, 2026-09-06): the gate refused a close
# over a file outside ## Scope, the model read the reason and reverted the file
# on the very next turn -- and that turn, the one where the run finally became
# closeable, was thrown away. The run stayed open with its work finished and was
# later logged as `abandoned`.
#
# Nothing loops without this early exit: the breaker marks `drift_warned` once
# and the gate keeps the last blocker set in its sidecar, so neither speaks
# twice for the same reason. This flag now suppresses only the speaking.
stop_active=0
hk_bool_true "$payload" "stop_hook_active" && stop_active=1

sid=$(hk_field "$payload" "session_id")
cwd=$(hk_field "$payload" "cwd")
tpath=$(hk_field "$payload" "transcript_path")
# A contract written by Bash never passed through track-edit.sh; pin its base
# here, before anything reads base_ref (see hk_adopt_contract).
hk_adopt_contract "$TMP" "$cwd"
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

# Whether the Critic has returned, or is still reviewing in the background. Read
# from its own files first (hk_critic_pull), because a background Critic hands
# its report back through a tool call that SubagentStop's payload does not carry.
hk_critic_pull "$TMP" "$tpath"
# Whether the Critic has returned. Recorded by subagent-done.sh on SubagentStop,
# or by hk_critic_pull above; hk_close_signal refuses to close a contract run
# before the review lands.
HK_CRITIC_DONE=$(hk_json_num "$TMP" "critic_done")
# Whether guard-agent.sh actually asked about it THIS run. Recorded on
# PreToolUse, before the human answers -- proof an attempt happened, which is
# what makes "declared as a deviation" honest instead of self-granted.
HK_CRITIC_ASKED=$(hk_json_num "$TMP" "critic_asked")
critic_findings=$(cat "$(hk_findings_file "$TMP")" 2>/dev/null)

# --- notices for the human: a guarantee that is off says so, ONCE per run.
#
# Collected here and printed as ONE systemMessage at the exit-0 points, never
# printed where they are found. Each used to print its own JSON object, and the
# hooks reference parses stdout as a single JSON value: two notices on the same
# Stop, or a notice followed by a block, made the whole output unparseable and
# the human saw neither. A notice is marked as said only when it is printed, so
# one deferred by a block (exit 2) is said on the next Stop instead of lost.
notices=""
notice_flags=""
add_notice() { # <flag> <text, already JSON-safe>
  grep -q "\"$1\"" "$TMP" 2>/dev/null && return 0
  notices="${notices:+$notices }$2"
  notice_flags="$notice_flags $1"
}
emit_notices() {
  [ -n "$notices" ] || return 0
  for k in $notice_flags; do hk_set_field "$TMP" "$k" "1"; done
  printf '{"systemMessage":"%s"}\n' "$notices"
}

# --- changed-file accounting (needed by the circuit breaker, so computed first)
files_changed=""
lines_changed=""
if [ -n "$root" ] && [ ! -d "$root/.git" ]; then
  # No repository: lines_changed, the scope ledger and any chance of undo are
  # all unavailable. Verified on a real run -- a new project was built without
  # `git init`, and the close reported 0 lines for 132 real ones while the
  # scope gate passed everything. A guarantee that is off must say so, ONCE:
  # the same run then repeated the warning on all 33 of its turns.
  add_notice nogit_warned "iamlazy: $(hk_json_esc "$root") no es un repositorio git. lines_changed, el registro de alcance y el undo no estan disponibles, asi que esta corrida trabaja con sus garantias degradadas. Corre git init y un commit inicial antes de seguir."
fi
if [ -n "$base" ]; then
  files_changed=$(hk_changed_files "$root" "$base" "$ubase" | grep -c . | tr -d ' ')
  lines_changed=$(hk_changed_lines "$root" "$base" "$ubase")
fi

# --- cost of THIS run, in micro-dollars (delta, not the whole session)
#
# Dollars replaced `tokens_weighted` on 2026-09-05. The old unit normalised
# every model to input-token-equivalents, so a Sonnet token and an Opus token
# counted the same while costing 2.5x apart -- one measured run was 86%
# Sonnet-weighted, and pricing its figure at Opus rates read $6.07 against a
# real $3.02. See prices.conf. The Critic's own transcript is added in: it was
# 14% of that run's cost and entirely invisible before.
run_cost=""
unpriced=""
scan_models=""
did_scan=0
COSTF=$(hk_cost_file "$TMP")
if [ -f "$COSTF" ]; then
  # A host adapter priced this run (see hk_cost_file). Its figure is the run's
  # figure: it already includes sub-agents and already subtracted the baseline.
  run_cost=$(hk_kv "$COSTF" cost_micro)
  d_out=$(hk_kv "$COSTF" tokens_output)
  d_cw=$(hk_kv "$COSTF" tokens_cache_write)
  d_cr=$(hk_kv "$COSTF" tokens_cache_read)
  d_out=${d_out:-0}; d_cw=${d_cw:-0}; d_cr=${d_cr:-0}
else
  # One pass over the transcript instead of three: hk_cost_micro,
  # hk_token_components and hk_model_counts all walked the same "usage":{
  # lines, de-duplicated by the same message id, just to extract different
  # fields from each turn -- see hk_transcript_scan in lib.sh. Measured on a
  # real 17MB transcript: the three separate scans took ~1.5s; this one pass
  # takes ~0.6s, on every Stop.
  did_scan=1
  scan_out=$(hk_transcript_scan "$tpath")
  scan_cost=$(printf '%s\n' "$scan_out" | sed -n '1p')
  scan_tok=$(printf '%s\n' "$scan_out" | sed -n '2p')
  scan_models=$(printf '%s\n' "$scan_out" | sed -n '3p')

  if [ "$(hk_json_num "$TMP" "cost_priced")" = "1" ] && [ "$scan_cost" != "NULL" ] && [ -n "$scan_cost" ]; then
    sub_cost=$(hk_subagent_cost_micro "$tpath")
    if [ -n "$sub_cost" ]; then
      sc=$(hk_json_num "$TMP" "start_cost")
      run_cost=$((scan_cost - ${sc:-0} + sub_cost))
    fi
  fi
  [ -n "$run_cost" ] || unpriced=$(hk_unpriced_run "$tpath")

  # Without a price the cost is null, and a null cost switches off the ratio
  # and the dollar ceiling below: only the duration ceiling is left. That used
  # to happen in silence, and it is the ordinary case the day a new model ships
  # -- this repo's own session on claude-opus-5-5 was one. prices.conf is
  # config, read on every Stop, so the fix needs no reinstall.
  if [ -n "$unpriced" ]; then
    add_notice unpriced_warned "iamlazy: no hay precio en ~/.iamlazy/prices.conf para $(hk_json_esc "$unpriced"). El costo de esta corrida queda null, y el circuit breaker por costo no puede actuar: solo queda el techo de duracion. Agrega el modelo a prices.conf; no hace falta reinstalar."
  fi

  # Raw components, as deltas, so the run can be repriced after a table fix.
  # shellcheck disable=SC2086  # word splitting is the point: "N N N" into $1 $2 $3
  set -- $scan_tok
  d_out=$(( ${1:-0} - $(hk_json_num "$TMP" "start_out"|| echo 0) ))
  d_cw=$((  ${2:-0} - $(hk_json_num "$TMP" "start_cw" || echo 0) ))
  d_cr=$((  ${3:-0} - $(hk_json_num "$TMP" "start_cr" || echo 0) ))
  [ "$d_out" -lt 0 ] && d_out=0; [ "$d_cw" -lt 0 ] && d_cw=0; [ "$d_cr" -lt 0 ] && d_cr=0
fi
host=$(hk_field_file "$TMP" "host"); [ -n "$host" ] || host="claude-code"

# WHICH models answered this run, as a delta against the baseline taken at open.
# Two sources, same precedence the cost already uses: a host that prices its own
# messages also names their model (see host-cost.sh), and only a host with a
# Claude-style transcript can be counted from one. Empty is the honest value on
# a host that offers neither -- the same posture as a null cost.
models_seen=$(hk_kv "$COSTF" models)
if [ -z "$models_seen" ]; then
  if [ "$did_scan" = "1" ]; then
    # Reuse the main transcript's tally from the scan above; only the (small)
    # sub-agent transcripts still need their own pass.
    run_models=$( { printf '%s\n' "$scan_models"; hk_models_subagents "$tpath"; } | hk_models_sum )
  else
    run_models=$(hk_models_run "$tpath")
  fi
  models_seen=$(hk_models_delta "$run_models" "$(hk_field_file "$TMP" "start_models")")
fi

# ---------------------------------------------------------------- Guarantee 5
# Circuit breaker. Persisting without a new hypothesis is the failure, not the
# virtue. The signal is arithmetic, not judgement: weighted cost per changed
# line.
#
# RECALIBRATED 2026-09-05 in dollars, from four measured run deltas (Critic
# included, post-close activity excluded):
#   27 lines  $0.0647/line     <- healthy; below the line floor, never checked
#   48 lines  $0.0301/line
#   66 lines  $0.0393/line
#  156 lines  $0.0226/line
# Cost per line FALLS as a run grows -- the fixed cost of reading, planning,
# contracting and reviewing does not scale with lines, which is why the floors
# carry more weight than the ratio. Above the 50-line floor the worst healthy
# run is $0.0393, so the threshold sits at 2x that. The lost run (4.75M weighted
# over 230 lines, Opus-priced ~$23.75) computes to $0.103/line and still fires.
#
# Four points is thin and they are all from two projects: if this fires on a run
# that was fine, the threshold is wrong, not the run.
#
# Note what this catches that an acceptance-command check cannot: that run
# logged validation_result=passed on all seven attempts. The tests kept
# passing; it was failing in the browser. "The command failed twice" would
# never have fired. Cost per line did.
#
# The three numbers are DEFAULTS, overridable in ~/.iamlazy/config (KEY=value,
# read with the same helper as every other sidecar). Recalibrating used to mean
# editing the installed script and reinstalling, which is why four thin data
# points have gone unchallenged since August -- and why the breaker is still the
# one guarantee never exercised in production, on any host: reproducing it costs
# a $3 run. A config file makes it a cheap experiment instead of an expensive
# one. Whatever ends up in effect is logged with the run, because a breaker that
# did not fire is only explainable if you know what it was measured against.
DRIFT_MICRO_PER_LINE=80000      # $0.08 per changed line
DRIFT_MIN_LINES=50
DRIFT_MIN_COST=3000000          # $3.00 -- "expensive AND unproductive"

# Two ABSOLUTE ceilings, added 2026-09-18, because the ratio is blind to the
# symptom this harness says it exists to stop. PROJECT.md's Purpose is explicit:
# "explicitly NOT built for multi-hour sessions: a long run is a symptom, not
# the use case, and making that visible and stopping it is the point." Nothing
# measured that. A run can be long, expensive and productive all at once, and
# cost-per-line stays healthy the whole way down -- the fixed cost of reading,
# planning and reviewing does not scale with lines, so the ratio FALLS as a run
# grows. The breaker was structurally incapable of firing on the one shape the
# Purpose names.
#
# Calibrated against the 21 closed runs in runs.jsonl, same standard as the
# ratio: a threshold that fires on a run that was fine is the wrong threshold.
# The healthy ceiling on Claude Code is 2094s and $5.07; the 2026-09-18 run was
# 6386s and $12.87 with drift_fired:0 and a perfectly healthy $0.0296/line.
# Both numbers below sit between the two clusters -- 1.7x and 2x clear of the
# worst healthy run, and each would have fired on exactly that one run out of
# 21. OpenCode's runs are all far below either, so this is inert there today.
DRIFT_MAX_SECONDS=3600          # 1h -- past this it is a session, not a task
DRIFT_MAX_COST=10000000         # $10.00 absolute, however productive

hk_conf() {
  local v
  v=$(hk_kv "${HK_DIR}/config" "$1")
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}
v=$(hk_conf DRIFT_MICRO_PER_LINE); [ -n "$v" ] && DRIFT_MICRO_PER_LINE="$v"
v=$(hk_conf DRIFT_MIN_LINES);      [ -n "$v" ] && DRIFT_MIN_LINES="$v"
v=$(hk_conf DRIFT_MIN_COST);       [ -n "$v" ] && DRIFT_MIN_COST="$v"
v=$(hk_conf DRIFT_MAX_SECONDS);    [ -n "$v" ] && DRIFT_MAX_SECONDS="$v"
v=$(hk_conf DRIFT_MAX_COST);       [ -n "$v" ] && DRIFT_MAX_COST="$v"
drift_thresholds="${DRIFT_MICRO_PER_LINE}/${DRIFT_MIN_LINES}/${DRIFT_MIN_COST}/${DRIFT_MAX_SECONDS}/${DRIFT_MAX_COST}"

# Elapsed time is needed HERE, before the close signal, so the ceiling can fire
# mid-run. The real close recomputes duration from the same baseline below.
now_epoch=$(date +%s)
start_epoch=$(hk_json_num "$TMP" "start_epoch")
elapsed=0
[ -n "$start_epoch" ] && elapsed=$((now_epoch - start_epoch))

# WHICH ceiling tripped, so the log can say. Without it a recalibration cannot
# tell a ratio breach from a duration one, and the ratio's own thresholds went
# four runs unchallenged precisely because nothing recorded what they measured.
# Ratio first: it is the most specific diagnosis and the only one with a
# prescribed remedy. All three share one `drift_warned` flag -- they are the
# same sentence to the model ("this run is sick, stop and re-plan"), and two
# blocks in a row would be nagging, which this hook already refuses to do.
drift_reason=""
if ! grep -q '"drift_warned"' "$TMP" 2>/dev/null && [ "$stop_active" = 0 ]; then
  if [ -n "$run_cost" ] \
     && [ "$run_cost" -ge "$DRIFT_MIN_COST" ] \
     && [ "${lines_changed:-0}" -ge "$DRIFT_MIN_LINES" ] \
     && [ $((run_cost / lines_changed)) -ge "$DRIFT_MICRO_PER_LINE" ]; then
    drift_reason="ratio"
  elif [ "$elapsed" -ge "$DRIFT_MAX_SECONDS" ]; then
    drift_reason="duration"
  elif [ -n "$run_cost" ] && [ "$run_cost" -ge "$DRIFT_MAX_COST" ]; then
    drift_reason="cost"
  fi
fi

if [ -n "$drift_reason" ]; then
  # Mark before blocking, so this warns once and never nags again.
  hk_set_field "$TMP" "drift_warned" "1"
  hk_set_field "$TMP" "drift_reason" "\"$drift_reason\""
  # `decision`/`reason` is the documented decision-control shape for Stop;
  # `systemMessage` is a TOP-LEVEL field, not one nested inside
  # hookSpecificOutput, which is where this used to put it. Per the hooks
  # reference, on exit 2 the blocking message is the JSON reason when there
  # is one and stderr otherwise -- so all three channels agree here instead
  # of relying on whichever one the build happens to honour.
  case "$drift_reason" in
    ratio)
      usd_line=$(hk_micro_to_usd $((run_cost / lines_changed)))
      printf '{"decision":"block","reason":"iamlazy: esta corrida lleva gastados %s dolares por linea cambiada (las sanas estan entre 0,02 y 0,04). El esfuerzo se esta yendo en intentos, no en avance. Deja de implementar y dilo claro: cual es la hipotesis, por que fallo el ultimo intento, y que CAMBIA ahora. Si la respuesta honesta es -probar otra cosa-, la hipotesis esta mal: vuelve al humano con lo que quedo descartado.","systemMessage":"iamlazy: %s USD por linea cambiada. Circuit breaker disparado."}\n' "$usd_line" "$usd_line"
      cat >&2 <<MSG
iamlazy: esta corrida lleva gastados $usd_line dolares por linea cambiada. Las
sanas estan entre 0,02 y 0,04. Ese ratio significa que el esfuerzo se esta yendo en intentos y
no en avance.

Deja de implementar. Antes de la proxima edicion, dilo claro: cual es la hipotesis, por que
fallo el ultimo intento, y que CAMBIA en la hipotesis ahora. Si la respuesta honesta es
-probar otra cosa-, la hipotesis esta mal: vuelve al humano con lo que quedo descartado, en
lugar de hacer un intento mas.
MSG
      ;;
    duration)
      mins=$((elapsed / 60))
      printf '{"decision":"block","reason":"iamlazy: esta corrida lleva %s minutos abierta. El harness esta hecho para UNA tarea de punta a punta, no para una sesion de horas: una corrida larga es el sintoma, no el caso de uso. Cierra lo que ya este completo y declara el resto como una tarea aparte, con su propio contrato. Si de verdad falta poco, dilo y sigue; el aviso no se repite.","systemMessage":"iamlazy: %s minutos abiertos. Circuit breaker por duracion."}\n' "$mins" "$mins"
      printf 'iamlazy: esta corrida lleva %s minutos abierta. El harness esta hecho para una tarea, no para una sesion de horas: corta aqui y declara el resto como tarea aparte.\n' "$mins" >&2
      ;;
    cost)
      usd_total=$(hk_micro_to_usd "$run_cost")
      printf '{"decision":"block","reason":"iamlazy: esta corrida lleva gastados %s dolares en total. El ratio por linea puede verse sano y aun asi ser demasiado dinero para una sola tarea. Cierra lo que ya este completo y declara el resto como una tarea aparte, con su propio contrato. Si el gasto esta justificado, dilo y sigue; el aviso no se repite.","systemMessage":"iamlazy: %s USD en total. Circuit breaker por costo."}\n' "$usd_total" "$usd_total"
      printf 'iamlazy: esta corrida lleva gastados %s dolares en total. Corta aqui y declara el resto como tarea aparte.\n' "$usd_total" >&2
      ;;
  esac
  exit 2
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
  if [ "$stop_active" = 0 ] && hk_has_close_banner "$payload"; then
    blockers=$(hk_close_blockers "$root" "$contract" "$base" "$ubase")
    # Same silent-block failure this section already exists to fix, on a new
    # surface: a run closed 2026-09-11 claiming "the human declined the
    # Critic" with zero Task/Agent calls anywhere in its transcript -- nobody
    # was ever asked. HK_CRITIC_ASKED is proof an attempt happened; its
    # absence is named here exactly like a missing group or an out-of-scope
    # file, not left for hk_close_signal to refuse in silence.
    if [ "$HK_CRITIC_DONE" != "1" ] && [ "$HK_CRITIC_ASKED" != "1" ]; then
      crit_line="el Critic nunca fue invocado en esta corrida: no hay una llamada real a la tool que este hook haya visto"
      if [ -n "$blockers" ]; then blockers=$(printf '%s\n%s' "$blockers" "$crit_line")
      else blockers="$crit_line"; fi
    fi
    if [ "$HK_CRITIC_RUNNING" = "1" ]; then
      crit_line="el Critic sigue revisando en segundo plano: espera su informe y recien despues cierra"
      if [ -n "$blockers" ]; then blockers=$(printf '%s\n%s' "$blockers" "$crit_line")
      else blockers="$crit_line"; fi
    fi
    if [ -n "$blockers" ]; then
      gate=$(hk_gate_file "$TMP")
      if [ "$blockers" != "$(cat "$gate" 2>/dev/null)" ]; then
        printf '%s' "$blockers" > "$gate"
        one_line=$(printf '%s' "$blockers" | tr '\n' ' ' | tr -d '\\"')
        printf '{"decision":"block","reason":"iamlazy: la corrida no puede cerrar todavia. %s Si es alcance o grupos: declara el desvio en ## Scope con su justificacion, o revierte el archivo, y marca los grupos con - [x]. Si es el Critic: lanza el sub-agente de verdad -- si te rechaza, recien ahi puedes cerrar sin revision.","systemMessage":"iamlazy: cierre bloqueado -- %s"}\n' \
          "$one_line" "$one_line"
        printf 'iamlazy: cierre bloqueado -- %s\n' "$one_line" >&2
        exit 2
      fi
    fi
  fi
  emit_notices
  exit 0
fi

# hk_close_signal just confirmed THIS Stop is the real close. A host can
# deliver the same terminal event to this hook more than once for one
# session -- OpenCode's daemon instantiates its plugin repeatedly, and every
# instance's subscription sees the same event -- so without a claim here,
# every concurrent invocation would compute the same close and each append
# its own line below before any of them reached hk_run_clear. Reproduced in
# production: one real run logged three times, byte-identical. The loser
# exits clean: the close it wanted already happened, on another invocation.
hk_claim_close "$TMP" || exit 0

# start_epoch and now_epoch were read above, for the duration ceiling. `elapsed`
# is that same subtraction; duration stays empty when the run file carried no
# baseline, which is the honest value and what the log expects.
duration=""
[ -n "$start_epoch" ] && duration="$elapsed"

# Counted as a DELTA, like the token cost: the transcript accumulates the whole
# session, so a second run in it would otherwise inherit the first one's
# interruptions.
#
# `null`, never `0`, when there is no transcript to count in. OpenCode keeps its
# sessions in SQLite and its adapter sends no transcript_path, so this count is
# simply skipped there -- and a logged `0` reads as "the human never
# interrupted" when the truth is "unknowable". Same rule cost_usd already
# follows, for the same reason: this project has shipped a confidently wrong
# number twice, and `tokens_total` was removed rather than left to be believed.
human_interventions=null
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
    | tr '\t' ' ' | hk_utf8_cut 160)
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

# cost_usd is null, never partial, when a model was missing from prices.conf --
# cost_unpriced names it so the fix is obvious. The raw components are always
# written, so the run can be repriced from the record once the table is right.
if [ -n "$run_cost" ]; then
  cost_field=$(hk_micro_to_usd "$run_cost")
else
  cost_field="null"
fi

# Whether the breaker ever fired during this run. It lives in the run file as
# `drift_warned`, set the moment it blocks, and that file is deleted at the
# close -- so until now the only record that a run had been stopped and told to
# re-plan was the session transcript. The log could not say how often the
# breaker fires, which is precisely the evidence needed to recalibrate it: its
# thresholds still rest on four runs from two projects. Found the first time it
# ever fired in production (2026-09-07), by having to go to the host's own
# store to find out whether it had.
#
# `drift_reason` joins it at schema 9 (2026-09-18), when the breaker stopped
# having one trigger. A bare 0/1 cannot tell a ratio breach from a duration
# ceiling, and recalibrating needs to know which fired -- the same gap that let
# the ratio's own three numbers go four runs unchallenged. Empty when nothing
# fired, which is the honest value and what every pre-9 line effectively says.
drift_fired=0
grep -q '"drift_warned"' "$TMP" 2>/dev/null && drift_fired=1
logged_reason=$(hk_field_file "$TMP" "drift_reason")

# The README promised that iamlazy proposes `.iamlazy/` for the .gitignore
# when it is missing, and nothing did. Checked at the close, the one moment per
# run, so it can never nag mid-run. `git check-ignore` takes a path that need
# not exist, and exit 1 is the only "not ignored": an error (128) says nothing.
if [ -n "$base" ] && [ -d "$root/.git" ]; then
  gi_rc=0
  (cd "$root" && git check-ignore -q .iamlazy/contract.md) 2>/dev/null || gi_rc=$?
  if [ "$gi_rc" = 1 ]; then
    add_notice gitignore_warned "iamlazy: .iamlazy/ no esta en el .gitignore de $(hk_json_esc "$root"). Agregalo para no versionar el contrato ni el journal de cada corrida."
  fi
fi
emit_notices

hk_log_append "$(printf '{"schema_version":9,"host":"%s","timestamp":"%s","task_summary":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","base_ref":"%s","duration_seconds":%s,"human_interventions":%s,"files_changed":%s,"lines_changed":%s,"cost_usd":%s,"cost_unpriced":"%s","models_seen":"%s","tokens_output":%s,"tokens_cache_write":%s,"tokens_cache_read":%s,"project_md":"%s","stage_reached":"%s","critic_findings":"%s","close_detected_via":"%s","drift_thresholds":"%s","drift_fired":%s,"drift_reason":"%s","hooks_version":"%s","outcome":"flushed"}' \
  "$(hk_json_esc "$host")" "$now_iso" "$task_summary" "$(hk_json_esc "$sid")" "$(hk_json_esc "$tpath")" \
  "$(hk_json_esc "$root")" "$(hk_json_esc "$base")" \
  "${duration:-null}" "$human_interventions" "${files_changed:-0}" "${lines_changed:-0}" \
  "$cost_field" "$(hk_json_esc "$unpriced")" "$(hk_json_esc "$models_seen")" "$d_out" "$d_cw" "$d_cr" \
  "$project_md" "$(hk_json_esc "$stage")" \
  "$(hk_json_esc "$critic_findings")" "$signal" "$drift_thresholds" "$drift_fired" \
  "$(hk_json_esc "$logged_reason")" "$(hk_json_esc "$(hk_hooks_version)")")"

hk_run_clear "$TMP"
exit 0
