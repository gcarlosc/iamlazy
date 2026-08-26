#!/usr/bin/env bash
# iamlazy Layer 0 — shared helpers for hook scripts.
# Constraints, same as the rest of the project: bash 3.2, coreutils only, NO jq.
#
# Every hook script sources this, then calls hk_guard first: outside an active
# iamlazy run the hooks must be inert, because they are registered globally and
# would otherwise fire on every session.

HK_RUN_TMP="${HOME}/.iamlazy/run.tmp.json"

# hk_field <payload> <field> -> prints the string value, empty if absent.
# Reads the FIRST occurrence. Sufficient for identifier-shaped fields
# (hook_event_name, tool_name, subagent_type, session_id, permission_mode);
# never use it for free-text fields, which may contain escaped quotes.
hk_field() {
  printf '%s' "$1" \
    | grep -o "\"$2\":\"[^\"]*\"" \
    | head -1 \
    | sed 's/^[^:]*:"//; s/"$//'
}

# hk_count <payload> <field> -> how many times the field appears as a key.
# A security decision must never rest on an ambiguous parse: when a field the
# decision depends on appears more than once, the caller denies rather than
# picking one. Fail-safe, and consistent with the harness principle that false
# positives cost tokens, never safety.
hk_count() {
  printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | wc -l | tr -d ' '
}

# hk_bool_true <payload> <field> -> 0 if the field is the JSON boolean `true`.
# JSON booleans are unquoted (`"field":true`), unlike every other field this
# project reads -- hk_field's quoted-value regex silently returns empty
# against one, which reads as "false" without ever checking. Found the hard
# way: stop_hook_active is a boolean, and a payload fixture that happened to
# carry `false` made the bug invisible until a `true` fixture was added.
hk_bool_true() {
  case "$1" in
    *"\"$2\":true"*) return 0 ;;
    *) return 1 ;;
  esac
}

# hk_guard -> returns 0 when an iamlazy run is active, 1 otherwise.
hk_guard() {
  [ -f "$HK_RUN_TMP" ]
}

# hk_deny <reason> -> emit a PreToolUse denial and stop.
hk_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# hk_allow -> no decision; the normal permission flow applies.
hk_allow() { exit 0; }

# hk_close_signal <payload> <contract_path> <cwd> -> "contract"|"banner"|"" (none)
# Stop fires after EVERY assistant turn, not just at the real close of a run --
# a naive "flush on Stop" would write many lines per run. Two mechanical
# signals distinguish an actual close, checked in order:
#   1. contract.md exists, every group checkbox is resolved (`- [x]`), AND
#      every changed file is covered by a declared Scope pattern -- an
#      undeclared touch is a real deviation, and "el alcance se firma en el
#      gate; despues, todo es desvio declarado" means it blocks close, not
#      a checkbox. This is the Guarantee-4 scope gate: it does not undo the
#      edit (PostToolUse cannot), it refuses to let the run call itself done
#      until the deviation is declared (Scope updated) or reverted.
#   2. no contract exists (the trivial/high-reversibility path has none) and
#      the turn's own text carries the close banner (`A5` near `CLOSE`/`CIERRE`).
#      Weaker than (1) -- it trusts a banner token, not free prose -- kept only
#      as the floor for the path that has no ledger to check.
hk_close_signal() {
  payload="$1"; contract="$2"; cwd="$3"
  if [ -f "$contract" ]; then
    if grep -q -- '- \[ \]' "$contract" 2>/dev/null; then
      return 1
    fi
    if [ -n "$(hk_scope_violations "$cwd" "$contract")" ]; then
      return 1
    fi
    echo "contract"; return 0
  fi
  if printf '%s' "$payload" | grep -Eq 'A5.{0,12}(CLOSE|CIERRE)'; then
    echo "banner"; return 0
  fi
  return 1
}

# hk_journal_append <cwd> <line> -> append one line to .iamlazy/journal.md.
# Append-only, written as a side effect of the edit itself -- never redacted
# from memory at close time, which is what makes it trustworthy to a revisor
# who did not do the work: a trace written after the fact is a story, not a
# record.
hk_journal_append() {
  cwd="$1"; line="$2"
  mkdir -p "${cwd}/.iamlazy"
  printf '%s\n' "$line" >> "${cwd}/.iamlazy/journal.md"
}

# hk_rel_path <cwd> <abs_path> -> path relative to cwd, or the absolute path
# unchanged if it does not live under cwd.
hk_rel_path() {
  case "$2" in
    "$1"/*) printf '%s' "${2#$1/}" ;;
    *) printf '%s' "$2" ;;
  esac
}

# hk_scope_patterns <contract_path> -> one declared Scope pattern per line.
# Reads the "## Scope" section: a line per path/glob under that heading,
# until the next "## " heading. No section, or no contract, means "scope not
# declared" -- callers must treat that as unscoped, never as a violation.
hk_scope_patterns() {
  contract="$1"
  [ -f "$contract" ] || return 1
  awk '
    /^## Scope/ { insec=1; next }
    /^## / { insec=0 }
    insec && /^- / { sub(/^- /, ""); print }
  ' "$contract"
}

# hk_scope_violations <cwd> <contract_path> -> changed paths NOT covered by
# any declared Scope pattern, one per line. Empty output means either
# everything is covered, or scope was never declared (both are "no violation"
# -- an undeclared scope cannot be violated, only an unmet one can).
hk_scope_violations() {
  cwd="$1"; contract="$2"
  patterns=$(hk_scope_patterns "$contract") || return 0
  [ -n "$patterns" ] || return 0
  changed=$(cd "$cwd" && git diff --name-only -- . ':!.iamlazy' 2>/dev/null)
  [ -n "$changed" ] || return 0
  printf '%s\n' "$changed" | while IFS= read -r f; do
    matched=0
    printf '%s\n' "$patterns" | while IFS= read -r pat; do
      case "$f" in
        $pat) echo matched; break ;;
      esac
    done | grep -q matched && matched=1
    [ "$matched" = 0 ] && printf '%s\n' "$f"
  done
}
