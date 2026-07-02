#!/usr/bin/env bash
# sextant uninstaller — removes only files that carry the `sextant-managed`
# marker. Never touches ~/.sextant/runs.jsonl and never touches any PROJECT.md.
set -eu

MARKER="sextant-managed"

TARGETS="\
${HOME}/.claude/commands/sextant.md \
${HOME}/.claude/commands/sextant-review.md \
${HOME}/.claude/agents/sextant-critic.md \
${HOME}/.config/opencode/commands/sextant.md \
${HOME}/.config/opencode/commands/sextant-review.md \
${HOME}/.config/opencode/agents/sextant.md \
${HOME}/.config/opencode/agents/sextant-critic.md"

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

echo "sextant uninstaller"
for t in $TARGETS; do
  remove_if_managed "$t"
done

echo
echo "done. Your data was left untouched:"
echo "  ~/.sextant/runs.jsonl  (run log)"
echo "  any PROJECT.md         (project ground truth)"
