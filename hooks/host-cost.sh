#!/usr/bin/env bash
# iamlazy Layer 0 — a host that prices its own messages hands the figure over.
#
# Claude Code exposes no per-message cost, so flush-run.sh derives it from the
# transcript and prices.conf. OpenCode prices every assistant message itself
# (`cost`, `tokens{input,output,reasoning,cache{read,write}}`, verified in its
# SQLite store 2026-09-05), and pricing it a second time from our table would
# produce two figures that disagree. Its adapter therefore sends each completed
# message here, once, and this hook accumulates the run's total in the
# <sid>.cost sidecar that flush-run.sh already prefers over the transcript.
#
# The arithmetic lives here, not in the adapter, on purpose: the sidecar's path,
# its KEY=value shape and its lifetime (cleared with the run) are Layer 0's, and
# a second implementation of any of them in TypeScript is the drift this repo
# keeps paying for. Accumulating on disk also survives a plugin reload mid-run.
# De-duplication by message id is the adapter's job, because only it sees ids.
#
# The payload carries the ROOT session's id: the Critic's messages arrive from a
# child session and the adapter maps them to the run that spawned it, so the
# reviewer's cost lands in the run's figure -- it was 14% of one measured run,
# and invisible.
set -u
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"
hk_crash_guard

payload=$(cat)

hk_guard "$payload" || exit 0
[ "$(hk_field "$payload" "hook_event_name")" = "HostCost" ] || exit 0

f=$(hk_cost_file "$HK_RUN_TMP")

# add <key> -> the stored value plus this payload's delta, as a KEY=value line.
add() {
  local cur delta
  cur=$(hk_kv "$f" "$1"); cur=${cur:-0}
  delta=$(hk_num "$payload" "$1"); delta=${delta:-0}
  printf '%s=%s\n' "$1" $((cur + delta))
}

# Which model produced this message. A host that prices its own messages has no
# Claude-style transcript for the close to count models from, so the tally is
# accumulated here message by message -- the same trade already made for cost.
# Absent stays absent: a host that sends no model contributes nothing rather
# than an "unknown" bucket that would read like a real model in the log.
model=$(hk_field "$payload" "model")
models=$(hk_kv "$f" models)
if [ -n "$model" ]; then models=$(hk_models_bump "$models" "$model"); fi

# Every line here is an `if`, never a `[ … ] && …`: a trailing test that fails
# makes the whole group exit non-zero, the `&& mv` never runs, and the sidecar
# silently stops accumulating anything at all -- cost included. Caught by the
# cost tests, which had nothing to do with models.
{
  add cost_micro
  add tokens_output
  add tokens_cache_write
  add tokens_cache_read
  if [ -n "$models" ]; then printf 'models=%s\n' "$models"; fi
} > "$f.new" && mv "$f.new" "$f"

exit 0
