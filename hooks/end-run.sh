#!/usr/bin/env bash
# iamlazy Layer 0 — a run that ends without closing is ABANDONED, and says so.
#
# Fires on SessionEnd. Until 2026-09-05 nothing closed the book on a run whose
# session simply stopped: the state file survived until the next /iamlazy, and
# because that state was global it kept the guarantees armed in every other
# session on the machine in the meantime. Verified that day -- a run opened at
# 05:23 in one project was still denying sub-agents and running `git add -N`
# in unrelated sessions hours later.
#
# SessionEnd covers the ordinary exits (clear, resume, logout, prompt_input_exit).
# What it cannot cover is a killed process, which is what hk_sweep_stale in
# open-run.sh is for. Two mechanisms because they fail differently.
set -u
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard "$payload" || exit 0

hk_flush_abandoned "$HK_RUN_TMP"
exit 0
