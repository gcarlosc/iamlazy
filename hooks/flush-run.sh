#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 2: the log exists.
#
# Fires on every Stop -- which is every assistant turn, not only the real
# close of a run. Guarded twice: hk_guard (a run must be active) and
# hk_close_signal (this turn must actually BE the close, not an intermediate
# one -- see lib.sh for the two mechanical signals). Deleting run.tmp.json is
# what marks the run as flushed to any later Stop in the same session, reusing
# hk_guard instead of a second state file.
#
# SCOPE, stated honestly: this writes the MECHANICAL skeleton only --
# session_id, transcript_path, timestamp, duration, human_interventions,
# files/lines changed. It does NOT write task_summary, reversibility,
# critic_mode, critic_findings or gate_verdict -- those are semantic and
# still need a place for the model to leave them on disk (a follow-up, not
# invented here). This guarantees the LINE exists, not that it is complete.
set -u
. "$(dirname "$0")/lib.sh"

RUNS_DIR="${HOME}/.iamlazy"
TMP="${RUNS_DIR}/run.tmp.json"
LOG="${RUNS_DIR}/runs.jsonl"

payload=$(cat)

[ -f "$TMP" ] || exit 0

# stop_hook_active=true means THIS Stop event is itself the result of a
# blocking hook (exit 2) on a prior Stop -- skip to avoid ever double-flushing
# in that chain. This hook never blocks, but the check is cheap and correct.
hk_bool_true "$payload" "stop_hook_active" && exit 0

cwd=$(hk_field "$payload" "cwd")
contract="${cwd}/.iamlazy/contract.md"

signal=$(hk_close_signal "$payload" "$contract" "$cwd") || exit 0

sid=$(hk_field "$payload" "session_id")
tpath=$(hk_field "$payload" "transcript_path")
start_epoch=$(grep -o '"start_epoch":[0-9]*' "$TMP" | head -1 | grep -o '[0-9]*$')
now_epoch=$(date +%s)
duration=""
[ -n "$start_epoch" ] && duration=$((now_epoch - start_epoch))

human_interventions=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  human_interventions=$(grep -c 'Request interrupted by user' "$tpath" 2>/dev/null)
  human_interventions=${human_interventions:-0}
fi

files_changed=""
lines_changed=""
if [ -n "$cwd" ] && [ -d "$cwd/.git" ]; then
  # -N stages untracked files as intent-to-add so `git diff --stat` sees them
  # too -- otherwise a brand-new file is invisible to the size floor (verified
  # 2026-08-25: the old `git diff --stat` alone missed an 800-line new file).
  # `.iamlazy/` is excluded explicitly: PROJECT.md says it belongs in
  # .gitignore, but that is a prose requirement the hook cannot assume is
  # honored -- without the exclusion, the harness's own state file counts as
  # the human's change (verified: 3 files/52 lines instead of 2/51).
  stat_out=$(cd "$cwd" && git add -A -N -- . ':!.iamlazy' >/dev/null 2>&1; git diff --stat -- . ':!.iamlazy' 2>/dev/null | tail -1)
  files_changed=$(printf '%s' "$stat_out" | grep -o '[0-9]* file' | grep -o '[0-9]*')
  lines_changed=$(printf '%s' "$stat_out" | grep -o '[0-9]* insertion\|[0-9]* deletion' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
fi

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '{"schema_version":1,"session_id":"%s","transcript_path":"%s","cwd":"%s","timestamp":"%s","duration_seconds":%s,"human_interventions":%s,"files_changed":%s,"lines_changed":%s,"close_detected_via":"%s","outcome":"flushed"}\n' \
  "$sid" "$tpath" "$cwd" "$now_iso" "${duration:-null}" "$human_interventions" "${files_changed:-0}" "${lines_changed:-0}" "$signal" >> "$LOG"

rm -f "$TMP"
exit 0
