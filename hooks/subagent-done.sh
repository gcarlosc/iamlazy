#!/usr/bin/env bash
# iamlazy Layer 0 — the review actually happened.
#
# Fires on SubagentStop. Records that the Critic returned, and its own tally.
#
# Why this exists, from the first real run of the reworked harness
# (git-diff-viewer, 2026-09-05):
#
#   06:50:30  contract.md written with its group ticked `- [x]`
#   06:50:44  iamlazy-critic spawned -- in the BACKGROUND, so the turn ended
#   06:51:01  Stop fired. Contract complete, no scope violations -> RUN CLOSED
#
# The review was still running. The run logged `outcome: flushed` and
# `close_detected_via: contract` for a task whose review never landed and whose
# CLOSE stage never happened. Nothing lied: "every box ticked" was true. It was
# just never sufficient, and Layer 1 says so plainly -- review is section 6 and
# close is section 7, both AFTER the execution that ticks the boxes.
#
# Verified on live Claude Code runs (see PROJECT.md): both that this build
# emits SubagentStop, and that its payload carries the PARENT session_id
# rather than the sub-agent's -- three real runs show non-empty
# critic_findings, which only happens if hk_guard's session_id lookup below
# matched the parent's run file. The close path stays written so that being
# wrong about either would have cost nothing: it falls back to the CLOSE
# banner, so a run can never be trapped open by an event that does not arrive.
set -u
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"
hk_crash_guard

payload=$(cat)

hk_guard "$payload" || exit 0

[ "$(hk_field "$payload" "agent_type")" = "iamlazy-critic" ] || exit 0

hk_set_field "$HK_RUN_TMP" "critic_done" "1"

# The tally, straight from the Critic's own closing line. A transcript grep for
# it also matches the EXAMPLE inside the Critic's prompt -- verified 2026-08-25,
# it returned 0/1/3/0 from documentation rather than from a review. Reading
# last_assistant_message on this event does not have that false positive,
# because it is the sub-agent's final text and nothing else.
findings=$(printf '%s' "$payload" \
  | grep -Eo 'findings: [0-9]+/[0-9]+/[0-9]+/[0-9]+' \
  | tail -1 \
  | sed 's/^findings: //')
[ -n "$findings" ] && printf '%s' "$findings" > "$(hk_findings_file "$HK_RUN_TMP")"

exit 0
