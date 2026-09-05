#!/usr/bin/env bash
# iamlazy — merge (or remove) the Layer 0 hook block in a settings.json.
#
#   usage: merge-settings.sh <settings.json> <hook-dir> [--remove]
#
# Why this exists: making the guarantees opt-in, or asking a human to paste a
# JSON block, reintroduces exactly the gap Layer 0 was built to close. A
# guarantee that is easy to skip is a guarantee that gets skipped, and the
# failure is silent -- two installs look identical, one enforces nothing.
#
# Dependency note, deliberate: merging JSON correctly needs a JSON parser, and
# `sed` is not one. This project's rule is "zero new dependencies WITHOUT
# justification"; the justification here is that the alternative is a manual
# step that degrades the harness. python3 is preferred (present wherever Claude
# Code realistically runs), jq is the fallback, and if neither exists the caller
# is told to paste the block by hand rather than being silently left unhooked.
# The hooks themselves stay pure bash -- this is an installer-only dependency.
#
# Safety: always backs up, always validates the result before replacing, and
# restores the backup if anything goes wrong. Idempotent: entries pointing at
# the hook dir are replaced, never duplicated, and nothing else is touched.
set -eu

SETTINGS="${1:?usage: merge-settings.sh <settings.json> <hook-dir> [--remove]}"
HOOKDIR="${2:?missing hook dir}"
MODE="${3:-install}"

MERGE_PY='
import json, sys, collections, os

path, hookdir, mode = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        data = json.load(f, object_pairs_hook=collections.OrderedDict)
else:
    data = collections.OrderedDict()

hooks = data.get("hooks") or collections.OrderedDict()

def ours(entry):
    for h in entry.get("hooks", []):
        if hookdir in str(h.get("command", "")):
            return True
    return False

# Drop any previous iamlazy entries, leaving the user their own untouched.
for event in list(hooks.keys()):
    kept = [e for e in hooks[event] if not ours(e)]
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

if mode == "install":
    # Matchers are anchored. Per the hooks reference a matcher is tested with
    # RegExp.test, which matches anywhere in the value: bare `Agent|Task` also
    # fires on `TaskOutput` and `TaskStop`, and `Edit|Write` on `NotebookEdit`.
    # The edit matcher is widened DELIBERATELY rather than narrowed -- an edit
    # the trace does not see is a hole in Guarantee 3, and MultiEdit was one.
    spec = [
        ("UserPromptSubmit", None,                                      "open-run.sh"),
        ("PreToolUse",       "^(Agent|Task)$",                          "guard-agent.sh"),
        ("PreToolUse",       "^Bash$",                                  "guard-critic-bash.sh"),
        ("PostToolUse",      "^(Edit|Write|MultiEdit|NotebookEdit)$",   "track-edit.sh"),
        ("Stop",             None,                                      "flush-run.sh"),
        ("SessionEnd",       None,                                      "end-run.sh"),
        ("SubagentStop",     None,                                      "subagent-done.sh"),
    ]
    for event, matcher, script in spec:
        entry = collections.OrderedDict()
        if matcher:
            entry["matcher"] = matcher
        entry["hooks"] = [collections.OrderedDict(
            [("type", "command"), ("command", os.path.join(hookdir, script))]
        )]
        hooks.setdefault(event, []).append(entry)

if hooks:
    data["hooks"] = hooks
elif "hooks" in data:
    del data["hooks"]

with open(path + ".ilznew", "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

json.load(open(path + ".ilznew"))   # validate before anyone swaps it in
print("ok")
'

run_merge() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "$MERGE_PY" "$SETTINGS" "$HOOKDIR" "$MODE"
  elif command -v python >/dev/null 2>&1; then
    python -c "$MERGE_PY" "$SETTINGS" "$HOOKDIR" "$MODE"
  else
    return 3
  fi
}

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="${SETTINGS}.bak-$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

# The status has to be captured from run_merge ITSELF. Reading `$?` after an
# `if` reads the status of the `if`, which is 0 whenever the else branch runs --
# so the "no JSON parser" path below (exit 3) was unreachable, and an install
# on a machine without python reported "merge failed" instead of telling the
# human to paste the block by hand. Verified 2026-09-05 with a stubbed python3.
rc=0
run_merge >/dev/null 2>&1 || rc=$?

if [ "$rc" -eq 0 ] && [ -f "${SETTINGS}.ilznew" ]; then
  mv "${SETTINGS}.ilznew" "$SETTINGS"
  echo "  updated $SETTINGS  (backup: $(basename "$BACKUP"))"
  exit 0
fi

rm -f "${SETTINGS}.ilznew"
cp "$BACKUP" "$SETTINGS"
rm -f "$BACKUP"
if [ "$rc" = "3" ]; then
  echo "  NO JSON PARSER (python3/python) -- settings.json left untouched." >&2
  exit 3
fi
echo "  merge failed; $SETTINGS restored from backup." >&2
exit 1
