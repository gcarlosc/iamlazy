#!/usr/bin/env bash
# iamlazy uninstaller — removes only files that carry the `iamlazy-managed`
# marker. Never touches ~/.iamlazy/runs.jsonl and never touches any PROJECT.md.
set -eu

MARKER="iamlazy-managed"

TARGETS="\
${HOME}/.claude/commands/iamlazy.md \
${HOME}/.claude/commands/iamlazy-review.md \
${HOME}/.claude/agents/iamlazy-critic.md \
${HOME}/.config/opencode/commands/iamlazy.md \
${HOME}/.config/opencode/commands/iamlazy-review.md \
${HOME}/.config/opencode/agents/iamlazy.md \
${HOME}/.config/opencode/agents/iamlazy-critic.md"

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

echo "iamlazy uninstaller"
for t in $TARGETS; do
  remove_if_managed "$t"
done

echo
echo "done. Your data was left untouched:"
echo "  ~/.iamlazy/runs.jsonl  (run log)"
echo "  any PROJECT.md         (project ground truth)"
