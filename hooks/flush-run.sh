#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 2 (the log exists) and Guarantee 5 (circuit breaker).
#
# Fires on every Stop -- which is every assistant turn, not only the real close
# of a run. Guarded twice: the run must be active (run.tmp.json exists), and the
# turn must actually BE the close (see hk_close_signal in lib.sh). Deleting
# run.tmp.json is what marks the run flushed to any later Stop in the session,
# reusing that same guard instead of a second state file.
#
# SCOPE, stated honestly: this writes the MECHANICAL skeleton -- identity,
# timing, intervention count, files/lines changed, weighted cost. It does NOT
# write task_summary, critic_findings or gate_verdict: those are semantic and
# still need a place on disk for the model to leave them. This guarantees the
# LINE exists, not that it is complete.
set -u
. "$(dirname "$0")/lib.sh"

RUNS_DIR="${HOME}/.iamlazy"
TMP="${RUNS_DIR}/run.tmp.json"
LOG="${RUNS_DIR}/runs.jsonl"

payload=$(cat)

[ -f "$TMP" ] || exit 0

# stop_hook_active=true means THIS Stop is itself the result of a blocking hook
# on a prior Stop. Skip, so the circuit breaker below can never loop.
hk_bool_true "$payload" "stop_hook_active" && exit 0

sid=$(hk_field "$payload" "session_id")
cwd=$(hk_field "$payload" "cwd")
tpath=$(hk_field "$payload" "transcript_path")
# The work may live somewhere other than the session's cwd (see hk_project_root).
root=$(hk_project_root "$TMP" "$cwd")
contract="${root}/.iamlazy/contract.md"

# --- changed-file accounting (needed by the circuit breaker, so computed first)
files_changed=""
lines_changed=""
if [ -n "$root" ] && [ ! -d "$root/.git" ]; then
  # No repository: lines_changed, the scope ledger and any chance of undo are
  # all unavailable. Verified on a real run -- a new project was built without
  # `git init`, and the close reported 0 lines for 132 real ones while the
  # scope gate passed everything. A guarantee that is off must say so.
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","systemMessage":"iamlazy: %s is not a git repository. lines_changed, the scope ledger and undo are all unavailable, so this run closed with its guarantees degraded. Run git init and commit before continuing."}}\n' "$root"
fi
if [ -n "$root" ] && [ -d "$root/.git" ]; then
  # -N stages untracked files as intent-to-add so `git diff --stat` sees them
  # too -- otherwise a brand-new file is invisible (verified 2026-08-25: the
  # old `git diff --stat` alone missed an 800-line new file).
  # `.iamlazy/` is excluded explicitly: PROJECT.md says it belongs in
  # .gitignore, but that is a prose requirement the hook cannot assume is
  # honored -- without it, the harness's own state file counts as the human's
  # change (verified: 3 files/52 lines instead of 2/51).
  stat_out=$(cd "$root" && git add -A -N -- . ':!.iamlazy' >/dev/null 2>&1; git diff --stat -- . ':!.iamlazy' 2>/dev/null | tail -1)
  files_changed=$(printf '%s' "$stat_out" | grep -o '[0-9]* file' | grep -o '[0-9]*')
  lines_changed=$(printf '%s' "$stat_out" | grep -o '[0-9]* insertion\|[0-9]* deletion' | grep -o '[0-9]*' | awk '{s+=$1} END {print s+0}')
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

if ! grep -q '"drift_warned":1' "$TMP" 2>/dev/null \
   && [ -n "$run_tokens" ] \
   && [ "$run_tokens" -ge "$DRIFT_MIN_TOKENS" ] \
   && [ "${lines_changed:-0}" -ge "$DRIFT_MIN_LINES" ]; then
  ratio=$((run_tokens / lines_changed))
  if [ "$ratio" -ge "$DRIFT_RATIO" ]; then
    # Mark before blocking, so this warns once and never nags again.
    tmp_new="${TMP}.new"
    sed 's/"outcome":"incomplete"/"drift_warned":1,"outcome":"incomplete"/' "$TMP" > "$tmp_new" 2>/dev/null \
      && mv "$tmp_new" "$TMP"
    # exit 2 blocks the stop but does NOT surface the text to the model --
    # verified on the first real run: the warning fired and the transcript
    # never saw it. systemMessage is the channel that actually reaches it.
    printf '{"hookSpecificOutput":{"hookEventName":"Stop","systemMessage":"iamlazy: this run is spending %s weighted tokens per changed line (healthy runs sit near 3,000-5,500). Effort is going into attempts, not progress. Stop implementing and state plainly: what is the hypothesis, why did the last attempt fail, and what CHANGES now? If the honest answer is - try something else - the hypothesis is wrong: take it back to the human with what has been ruled out."}}\n' "$ratio"
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
signal=$(hk_close_signal "$payload" "$contract" "$root") || exit 0

start_epoch=$(hk_json_num "$TMP" "start_epoch")
now_epoch=$(date +%s)
duration=""
[ -n "$start_epoch" ] && duration=$((now_epoch - start_epoch))

human_interventions=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  human_interventions=$(grep -c 'Request interrupted by user' "$tpath" 2>/dev/null)
  human_interventions=${human_interventions:-0}
fi

# --- semantic fields, derived only where derivation is trustworthy
# task_summary comes from the contract's own "# Task" heading: the model
# already wrote it there and the human approved it, so it is a record, not a
# self-report. Quotes and backslashes are stripped rather than escaped -- this
# builds JSON without jq, and a summary is not worth a parser.
task_summary=""
if [ -f "$contract" ]; then
  task_summary=$(awk '/^# Task/{f=1;next} /^#/{if(f)exit} f&&NF{print;exit}' "$contract" \
    | tr -d '"\\' | tr '\t' ' ' | cut -c1-160)
fi

# project_md: absent / read / updated, decided by the diff, never by opinion.
project_md="absent"
if [ -f "${root}/PROJECT.md" ]; then
  project_md="read"
  if (cd "$root" && git diff --name-only -- PROJECT.md 2>/dev/null | grep -q .); then
    project_md="updated"
  fi
fi

# NOT derived, deliberately: critic_findings and gate_verdict.
# The Critic's "findings: H/M/L/I" tally lives inside a sub-agent tool result,
# and a plain grep over the transcript also matches the EXAMPLE in the Critic's
# own prompt -- verified 2026-08-25, it returned 0/1/3/0 from documentation, not
# from a review. gate_verdict would come from ExitPlanMode, which this session
# never invoked, so the shape is unconfirmed. This project already shipped a
# token count that was wrong in 7 of 7 runs; a field that is absent is honest,
# a field that is confidently wrong is not.

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '{"schema_version":2,"timestamp":"%s","task_summary":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","duration_seconds":%s,"human_interventions":%s,"files_changed":%s,"lines_changed":%s,"tokens_weighted":%s,"project_md":"%s","close_detected_via":"%s","outcome":"flushed"}\n' \
  "$now_iso" "$task_summary" "$sid" "$tpath" "$root" "${duration:-null}" "$human_interventions" "${files_changed:-0}" "${lines_changed:-0}" "${run_tokens:-null}" "$project_md" "$signal" >> "$LOG"

rm -f "$TMP"
exit 0
