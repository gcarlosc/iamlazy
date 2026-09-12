#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 1: one writer.
#
# PreToolUse on the sub-agent tool. Denies every sub-agent except the Critic,
# whose spawn it ASKS about rather than allowing outright (2026-09-11) -- a
# real run on a small-looking task took long enough on the review that the
# human wanted the choice up front. Declining still lets the run close: the
# fallback that already exists for a SubagentStop that never arrives (see
# hk_close_signal in lib.sh) covers "the human said no" the same way it
# covers "the channel misfired" -- both mean critic_done never reaches 1.
#
# This replaces rule 6, which was prose and was violated 7 times across 2 runs.
#
# Matcher note, verified against real transcripts (2026-08-25): the tool is named
# `Agent` in this Claude Code build, NOT `Task`. The official hooks documentation
# uses `Task` in all of its examples. A hook matching only `Task` never fires --
# silently. Both names are accepted here so the guarantee survives a rename.
#
# The guard is per-SESSION (2026-09-05). It used to key off one global run file,
# so an open run denied sub-agents in every other session on the machine.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard "$payload" || hk_allow

tool=$(hk_field "$payload" "tool_name")
case "$tool" in
  Agent|Task) ;;
  *) hk_allow ;;
esac

# The whitelist is positive: the Critic passes, everything else is refused --
# including an ambiguous parse. JSON escaping already keeps the key from being
# forged inside a string value, but a payload carrying the field twice would
# let the first occurrence decide, so that case denies too.
if [ "$(hk_count "$payload" "subagent_type")" != "1" ]; then
  hk_deny "iamlazy: could not determine subagent_type unambiguously. Refused."
fi

sub=$(hk_field "$payload" "subagent_type")

if [ "$sub" = "iamlazy-critic" ]; then
  # Recorded BEFORE the ask, not after: this is proof an attempt happened,
  # not proof of what the human answered. hk_close_signal reads it to refuse
  # "declared as a deviation" when nothing was ever attempted -- see lib.sh.
  hk_set_field "$HK_RUN_TMP" "critic_asked" "1"
  hk_ask "iamlazy: about to spawn the Critic to review this run's diff. Approve for an independent review before closing; decline and the run closes without one, as a declared deviation."
fi

hk_deny "iamlazy: the Critic is the only sub-agent a run may spawn. Refused subagent_type='${sub:-unknown}'. Narrow the search and do it in this thread."
