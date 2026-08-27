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

# hk_project_root <tmp> <cwd> -> the directory the WORK is happening in.
# NOT the same as cwd: a session started in ~/dev/foo can be told to build a
# project in ~/dev/bar, and every hook that assumed cwd==project silently
# accounted for the wrong repo. Found on the first real run: the journal landed
# in one repo while the contract lived in another, the close looked for the
# contract where it was not, and the circuit breaker divided by the line count
# of an unrelated repo. Falls back to cwd, which is correct for the common case.
hk_project_root() {
  root=$(hk_field_file "$1" "project_root")
  if [ -n "$root" ] && [ -d "$root" ]; then printf '%s' "$root"; else printf '%s' "$2"; fi
}

# hk_field_file <file> <field> -> string value of a field read from a FILE.
hk_field_file() {
  [ -f "$1" ] || return 0
  grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/^[^:]*:"//; s/"$//'
}

# hk_set_project_root <tmp> <root> -> record it once, idempotently.
hk_set_project_root() {
  grep -q '"project_root"' "$1" 2>/dev/null && return 0
  tmp_new="$1.new"
  sed "s|\"outcome\":\"incomplete\"|\"project_root\":\"$2\",\"outcome\":\"incomplete\"|" "$1" > "$tmp_new" 2>/dev/null \
    && mv "$tmp_new" "$1"
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
#   2. no contract exists (the trivial path has none) and the turn's own text
#      carries the CLOSE banner. Weaker than (1) -- it trusts a banner token,
#      not free prose -- kept only as the floor for the path with no ledger.
#      The pattern matches the banner's box-drawing rule next to the stage name,
#      never the bare word, so prose mentioning "cierre" cannot close a run.
#      It previously looked for `A5`, which the rewritten prompt stopped
#      emitting -- the path was dead for a whole real run before that surfaced.
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
  if printf '%s' "$payload" | grep -Eq '\xe2\x94\x80[^"]{0,60}(CLOSE|CIERRE)|(CLOSE|CIERRE)[^"]{0,60}\xe2\x94\x80'; then
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
  # PROJECT.md is excluded alongside .iamlazy/: updating the project model is
  # part of the CLOSE protocol, not a deviation from the task's scope. Without
  # this, every run that does what the close step asks would block its own
  # close -- a structural false positive found by running the real flow, not by
  # reading the code. PROJECT.md has its own protection: it is never edited
  # without showing the diff and getting approval.
  changed=$(cd "$cwd" && git diff --name-only -- . ':!.iamlazy' ':!PROJECT.md' 2>/dev/null)
  [ -n "$changed" ] || return 0

  # Plain nested `for` loops, splitting on newlines only so paths with spaces
  # survive. Deliberately not `printf | while read`: that puts the match flag
  # inside a pipeline, i.e. a subshell, where assignments to it are discarded.
  #
  # Note for anyone testing this by hand: `case $f in $pat)` glob-matches in
  # bash but NOT in zsh, which needs ${~pat}. The hooks always run under bash;
  # sourcing this file into an interactive zsh will make every path look like
  # a violation and send you hunting a bug that is not there.
  oldifs="$IFS"
  IFS='
'
  for f in $changed; do
    ok=0
    for pat in $patterns; do
      case "$f" in
        $pat) ok=1; break ;;
      esac
    done
    [ "$ok" = 0 ] && printf '%s\n' "$f"
  done
  IFS="$oldifs"
  return 0
}

# hk_weighted_tokens <transcript_path> -> weighted token total, or empty.
# Weights follow the project's cost model: output x5, cache_creation x1.25,
# cache_read x0.1. Raw sums overstate spend by roughly 4x, which is why the
# weighting is not optional. Empty output means "could not read" -- callers
# must skip the check rather than treat it as zero.
#
# Deduplicated by message id, and that is not a detail: a transcript records
# the same assistant message several times (streaming plus final), so a plain
# `grep | awk` over the token fields counts each usage block more than once.
# Measured 2026-08-27 on a real run: 75 usage blocks for 40 unique messages,
# reporting 1,176,836 weighted against an actual 561,234 -- a 2.1x
# overstatement. That number feeds the circuit breaker's threshold and A5's
# cost line, so an inflated count means false alarms and a lie in the log.
# This project already shipped one wrong token count; not twice.
hk_weighted_tokens() {
  t="$1"
  [ -n "$t" ] && [ -f "$t" ] || return 1
  awk '
    # one JSON object per line; take the first usage block per message id
    {
      id = ""
      if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) {
        id = substr($0, RSTART, RLENGTH)
      }
      if (!match($0, /"usage":\{/)) next
      if (id != "" && (id in seen)) next
      if (id != "") seen[id] = 1

      o = c = r = 0
      if (match($0, /"output_tokens":[0-9]+/))
        o = substr($0, RSTART + 16, RLENGTH - 16)
      if (match($0, /"cache_creation_input_tokens":[0-9]+/))
        c = substr($0, RSTART + 30, RLENGTH - 30)
      if (match($0, /"cache_read_input_tokens":[0-9]+/))
        r = substr($0, RSTART + 26, RLENGTH - 26)
      total += o * 5 + c * 1.25 + r * 0.1
    }
    END { printf "%d", total + 0 }
  ' "$t"
}

# hk_json_num <file> <key> -> integer value of a numeric JSON field.
hk_json_num() {
  grep -o "\"$2\":[0-9]*" "$1" 2>/dev/null | head -1 | grep -o '[0-9]*$'
}
