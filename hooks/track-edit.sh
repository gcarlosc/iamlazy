#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 3: an unbiased trace.
#
# Fires on PostToolUse for Edit/Write/MultiEdit/NotebookEdit. Appends one
# mechanical line per edit to .iamlazy/journal.md as a side effect of the edit
# itself -- never redacted from memory at close time. A trace the builder
# writes about its own work from memory has exactly the bias the separate
# revisor exists to remove; a trace that accumulates while the work happens
# does not.
#
# This hook writes only the mechanical half (what, when). The model's own
# edits to journal.md -- decisions, and especially what was tried and
# abandoned -- are the other half, and are skipped here (see the .iamlazy/
# guard below) so the hook never logs the harness writing to its own ledger
# as if it were a code change.
set -u
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"

payload=$(cat)
hk_guard "$payload" || hk_allow

cwd=$(hk_field "$payload" "cwd")
tool=$(hk_field "$payload" "tool_name")
fpath=$(hk_field "$payload" "file_path")
[ -n "$fpath" ] || hk_allow

# Writing the contract is what declares where the project lives, and what the
# run is accountable for. It is the first file the harness writes after the
# gate, so every later edit is accounted against the right repo -- even when
# the session started elsewhere -- and base_ref pins the repository state the
# close will diff against.
case "$fpath" in
  */.iamlazy/contract.md)
    proj="${fpath%/.iamlazy/contract.md}"
    if [ -d "$proj" ]; then
      hk_set_project_root "$HK_RUN_TMP" "$proj"
      hk_set_base "$HK_RUN_TMP" "$proj"
    fi
    hk_allow
    ;;
esac

root=$(hk_project_root "$HK_RUN_TMP" "$cwd")
[ -n "$root" ] || hk_allow

# Only trace files inside the project. The harness's own state, and anything
# the host writes elsewhere (plan-mode scratch files under ~/.claude/plans/),
# are not the human's change and do not belong in the record.
case "$fpath" in
  "$root"/.iamlazy/*) hk_allow ;;
  "$root"/*) ;;
  *) hk_allow ;;
esac

rel=$(hk_rel_path "$root" "$fpath")
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hk_journal_append "$root" "${now} ${tool} ${rel}"

hk_allow
