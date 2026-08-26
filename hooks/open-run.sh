#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 7: the run is identified by real data, not by a
# heuristic. Also lays the ground for Guarantee 2 (the log exists).
#
# Fires on UserPromptSubmit. SessionStart cannot do this job: it fires before
# the human has typed anything, so it cannot know this session will invoke
# /iamlazy. UserPromptSubmit sees the raw prompt (slash-command expansion is a
# separate, later event per the hooks doc), so matching "/iamlazy" here is the
# earliest point where "a run is starting" is a fact, not a guess.
#
# NOT YET VERIFIED empirically: this build's exact prompt shape for a real
# /iamlazy invocation (only a plain-text UserPromptSubmit payload has been
# captured so far). The match is intentionally loose (prefix OR mid-string)
# to survive small format differences; tighten only after a real capture.
set -u
. "$(dirname "$0")/lib.sh"

RUNS_DIR="${HOME}/.iamlazy"
TMP="${RUNS_DIR}/run.tmp.json"
LOG="${RUNS_DIR}/runs.jsonl"

payload=$(cat)

ev=$(hk_field "$payload" "hook_event_name")
[ "$ev" = "UserPromptSubmit" ] || hk_allow

# Prefix check only -- never fully extract the free-text prompt field, it may
# contain escaped quotes lib.sh's naive parser cannot handle safely.
case "$payload" in
  *'"prompt":"/iamlazy '*|*'"prompt":"/iamlazy"'*) : ;;
  *) hk_allow ;;
esac

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

sid=$(hk_field "$payload" "session_id")
tpath=$(hk_field "$payload" "transcript_path")
cwd=$(hk_field "$payload" "cwd")
[ -n "$sid" ] && [ -n "$tpath" ] || hk_allow  # malformed payload: do nothing, never guess

mkdir -p "$RUNS_DIR"

# Orphan recovery: a leftover run.tmp.json means a previous run never reached
# its close (the exact failure this project already paid for twice). Whatever
# is in it, whoever's session it belongs to, it gets flushed as incomplete
# before this run starts -- unconditionally, no guessing about whose it was.
if [ -f "$TMP" ]; then
  { cat "$TMP"; printf '\n'; } >> "$LOG"
  rm -f "$TMP"
fi

now_epoch=$(date +%s)
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The transcript accumulates the WHOLE session, not this run. Recording the
# weighted total at open lets the close measure the delta -- otherwise a
# second /iamlazy in the same session would inherit the first one's cost and
# the drift check would fire on the wrong run.
start_tokens=$(hk_weighted_tokens "$tpath") || start_tokens=0

printf '{"schema_version":1,"session_id":"%s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_tokens":%s,"opened_at":"%s","outcome":"incomplete"}' \
  "$sid" "$tpath" "$cwd" "$now_epoch" "${start_tokens:-0}" "$now_iso" > "$TMP"

hk_allow
