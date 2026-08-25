#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 1: one writer.
#
# PreToolUse on the sub-agent tool. Denies every sub-agent except the Critic.
# This replaces rule 6, which was prose and was violated 7 times across 2 runs.
#
# Matcher note, verified against real transcripts (2026-08-25): the tool is named
# `Agent` in this Claude Code build, NOT `Task`. The official hooks documentation
# uses `Task` in all of its examples. A hook matching only `Task` never fires --
# silently. Both names are accepted here so the guarantee survives a rename.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard || hk_allow

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
  hk_allow
fi

hk_deny "iamlazy: the Critic is the only sub-agent a run may spawn. Refused subagent_type='${sub:-unknown}'. Narrow the search and do it in this thread."
