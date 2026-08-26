#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 3: an unbiased trace.
#
# Fires on PostToolUse for Edit/Write. Appends one mechanical line per edit to
# .iamlazy/journal.md as a side effect of the edit itself -- never redacted
# from memory at close time. A trace the builder writes about its own work
# from memory has exactly the bias the separate revisor exists to remove; a
# trace that accumulates while the work happens does not.
#
# This hook writes only the mechanical half (what, when). The model's own
# edits to journal.md -- decisions, and especially what was tried and
# abandoned -- are the other half, and are skipped here (see the .iamlazy/
# guard below) so the hook never logs the harness writing to its own ledger
# as if it were a code change.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)
hk_guard || hk_allow

cwd=$(hk_field "$payload" "cwd")
tool=$(hk_field "$payload" "tool_name")
fpath=$(hk_field "$payload" "file_path")
[ -n "$cwd" ] && [ -n "$fpath" ] || hk_allow

case "$fpath" in
  "$cwd"/.iamlazy/*) hk_allow ;;
esac

rel=$(hk_rel_path "$cwd" "$fpath")
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hk_journal_append "$cwd" "${now} ${tool} ${rel}"

hk_allow
