#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 7: the run is identified by real data, not by a
# heuristic. Also lays the ground for Guarantee 2 (the log exists), and is the
# one place the model is told what the harness currently knows about its run.
#
# Fires on UserPromptSubmit. SessionStart cannot do this job: it fires before
# the human has typed anything, so it cannot know this session will invoke
# /iamlazy. UserPromptSubmit sees the raw prompt (slash-command expansion is a
# separate, later event per the hooks doc), so matching "/iamlazy" here is the
# earliest point where "a run is starting" is a fact, not a guess.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)

ev=$(hk_field "$payload" "hook_event_name")
[ "$ev" = "UserPromptSubmit" ] || hk_allow

sid=$(hk_field "$payload" "session_id")
tpath=$(hk_field "$payload" "transcript_path")
cwd=$(hk_field "$payload" "cwd")

# Prefix check only -- never fully extract the free-text prompt field, it may
# contain escaped quotes lib.sh's naive parser cannot handle safely.
is_iamlazy=0
case "$payload" in
  *'"prompt":"/iamlazy '*|*'"prompt":"/iamlazy"'*) is_iamlazy=1 ;;
esac

# Runs whose session died without SessionEnd, and the pre-2026-09-05 global
# run file, are reclaimed here. Cheap: a listing of a small directory.
mkdir -p "$HK_ACTIVE_DIR"
hk_sweep_stale

# ---------------------------------------------------------- active run status
# During a run, one line of context per turn. This is the channel that was
# missing: the scope gate and the group ledger could block a close, and the
# model was never told -- flush-run.sh returned exit 0 with no output, so the
# run simply would not end and nothing said why. UserPromptSubmit stdout is
# added to the model's context (hooks reference), so this is where the state
# stops being invisible. One line, and only while a run is open.
if [ -n "$sid" ]; then
  run_file=$(hk_run_file "$sid")
  if [ -f "$run_file" ] && [ "$is_iamlazy" = "0" ]; then
    root=$(hk_project_root "$run_file" "$cwd")
    base=$(hk_field_file "$run_file" "base_ref")
    ubase=$(hk_untracked_file "$run_file")
    contract="${root}/.iamlazy/contract.md"
    blockers=$(hk_close_blockers "$root" "$contract" "$base" "$ubase" | tr '\n' ';')
    if [ -n "$blockers" ]; then
      printf 'iamlazy: corrida activa en %s (base %s). NO puede cerrar todavia -- %s Declara el desvio en ## Scope del contrato o revierte el archivo.\n' \
        "$root" "${base:-sin base}" "$blockers"
    elif [ -f "$contract" ]; then
      printf 'iamlazy: corrida activa en %s (base %s). El contrato esta completo y todo lo cambiado cae dentro del ## Scope declarado.\n' \
        "$root" "${base:-sin base}"
    else
      printf 'iamlazy: corrida activa en %s. Todavia no hay contrato en disco.\n' "$root"
    fi
    hk_allow
  fi
fi

[ "$is_iamlazy" = "1" ] || hk_allow

# Guarantee 6: never under a permission bypass.
# PROJECT.md declares "iamlazy must not be run under
# --dangerously-skip-permissions" as an invariant, but nothing ever enforced
# it -- it was a written wish. The gate's whole strength on Claude Code comes
# from native plan mode, and a bypass removes it, so a run that starts this
# way is a run without its one structural guarantee. Refusing to OPEN is the
# honest response: better no run than a run that silently is not the harness.
# UserPromptSubmit cannot emit permissionDecision (PreToolUse only), so this
# blocks with exit 2, which is that event's documented blocking channel.
if printf '%s' "$payload" | grep -q '"permission_mode":"bypassPermissions"'; then
  echo "iamlazy: refusing to start under a permission bypass. The gate rides on native plan mode; bypassing permissions removes the only structural guarantee the harness has. Restart without --dangerously-skip-permissions." >&2
  exit 2
fi

[ -n "$sid" ] && [ -n "$tpath" ] || hk_allow  # malformed payload: do nothing, never guess

RUN_FILE=$(hk_run_file "$sid")

# A second /iamlazy in the same session closes the book on the first one. It
# never reached its own close, so it is abandoned, not incomplete -- and it
# gets a real log line saying which stage it died at.
[ -f "$RUN_FILE" ] && hk_flush_abandoned "$RUN_FILE"

now_epoch=$(date +%s)
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The transcript accumulates the WHOLE session, not this run. Recording the
# baseline at open lets the close measure the delta -- otherwise a second
# /iamlazy in the same session would inherit the first one's cost and the drift
# check would fire on the wrong run. Verified on the 2026-09-05 run: the
# /iamlazy-review typed afterwards added $0.90 that correctly stayed out.
#
# cost_priced records whether the baseline could be priced at all. If a model in
# the transcript is missing from prices.conf there is no baseline, and a delta
# taken against a missing baseline would silently bill this run for the whole
# session. The close reports null instead.
start_cost=$(hk_cost_micro "$tpath")
if [ -n "$start_cost" ]; then cost_priced=1; else cost_priced=0; start_cost=0; fi

set -- $(hk_token_components "$tpath" 2>/dev/null)
start_out="${1:-0}"; start_cw="${2:-0}"; start_cr="${3:-0}"

# Same reasoning for interruptions: the marker accumulates over the session, so
# the close subtracts this baseline instead of reporting the session's total.
# The field audit of 2026-08-21 found human_interventions undercounting; it was
# then derived from the transcript marker but never made a delta.
start_interventions=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  start_interventions=$(grep -c 'Request interrupted by user' "$tpath" 2>/dev/null | tr -d ' ')
fi

printf '{"schema_version":4,"session_id":"%s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":%s,"cost_priced":%s,"start_out":%s,"start_cw":%s,"start_cr":%s,"start_interventions":%s,"opened_at":"%s","outcome":"incomplete"}' \
  "$(hk_json_esc "$sid")" "$(hk_json_esc "$tpath")" "$(hk_json_esc "$cwd")" \
  "$now_epoch" "$start_cost" "$cost_priced" "$start_out" "$start_cw" "$start_cr" \
  "${start_interventions:-0}" "$now_iso" > "$RUN_FILE"

hk_allow
