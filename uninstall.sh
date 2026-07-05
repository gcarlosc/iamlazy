#!/usr/bin/env bash
# ledger uninstaller — removes only files that carry the `ledger-managed`
# marker. Never touches ~/.ledger/runs.jsonl and never touches any PROJECT.md.
set -eu

MARKER="ledger-managed"

TARGETS="\
${HOME}/.claude/commands/ledger.md \
${HOME}/.claude/commands/ledger-review.md \
${HOME}/.claude/agents/ledger-critic.md \
${HOME}/.config/opencode/commands/ledger.md \
${HOME}/.config/opencode/commands/ledger-review.md \
${HOME}/.config/opencode/agents/ledger.md \
${HOME}/.config/opencode/agents/ledger-critic.md"

remove_if_managed() {
  f="$1"
  if [ ! -f "$f" ]; then
    return 0
  fi
  if grep -q "$MARKER" "$f" 2>/dev/null; then
    rm -f "$f"
    echo "  removed $f"
  else
    echo "  SKIP (not $MARKER): $f" >&2
  fi
}

echo "ledger uninstaller"
for t in $TARGETS; do
  remove_if_managed "$t"
done

echo
echo "done. Your data was left untouched:"
echo "  ~/.ledger/runs.jsonl  (run log)"
echo "  any PROJECT.md         (project ground truth)"
