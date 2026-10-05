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
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"
hk_crash_guard

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
  hk_deny "iamlazy: no se pudo determinar subagent_type sin ambiguedad. Rechazado."
fi

sub=$(hk_field "$payload" "subagent_type")

# A background sub-agent is refused BEFORE the Critic branch, so a refused
# attempt never records critic_asked (2026-09-16). OpenCode V2 can launch a
# delegation with background:true: the tool returns "running" immediately and
# the work finishes out of band. That mode is incompatible with this
# guarantee's shape -- the close gate waits for findings to arrive through
# SubagentStop, and a background spawn never sends any. Allowing it would let
# the run close as a "declared deviation" while a review was still in flight,
# which is precisely the silent degradation Layer 0 exists to remove: the
# human would read "closed without review" and never learn one had been
# started. Claude Code's Agent tool carries no such field, so this is inert
# there. Matching `true` ANYWHERE in the payload is the fail-safe direction --
# a payload carrying the field twice denies rather than picking one, exactly
# like the subagent_type ambiguity above.
if hk_bool_true "$payload" "background"; then
  hk_deny "iamlazy: el sub-agente de una corrida no puede correr en segundo plano -- sus hallazgos nunca llegarian a la puerta de cierre, y la corrida cerraria como si no se hubiera intentado revision. Debe correr en primer plano."
fi

if [ "$sub" = "iamlazy-critic" ]; then
  # Recorded BEFORE the ask, not after: this is proof an attempt happened,
  # not proof of what the human answered. hk_close_signal reads it to refuse
  # "declared as a deviation" when nothing was ever attempted -- see lib.sh.
  hk_set_field "$HK_RUN_TMP" "critic_asked" "1"
  # CRITIC_ASK=0 in ~/.iamlazy/config skips the question and lets the spawn
  # through. The question cost a real run seven and a half minutes of waiting
  # (sperant, 2026-10-02): the review could not start until a human came back
  # to approve it. The attempt is still recorded above, so the close keeps its
  # proof that a review was tried.
  if [ "$(hk_kv "${HK_DIR}/config" CRITIC_ASK)" = "0" ]; then
    hk_allow
  fi
  hk_ask "iamlazy: se va a lanzar el Critic para revisar el diff de esta corrida. Apruebalo para tener una revision independiente antes de cerrar; si lo rechazas, la corrida cierra sin revision, como desvio declarado."
fi

hk_deny "iamlazy: el Critic es el unico sub-agente que una corrida puede lanzar. Rechazado subagent_type='${sub:-desconocido}'. Acota la busqueda y hazla en este mismo hilo."
