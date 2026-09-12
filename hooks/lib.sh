#!/usr/bin/env bash
# iamlazy Layer 0 — shared helpers for hook scripts.
# Constraints, same as the rest of the project: bash 3.2, coreutils only, NO jq.
#
# Every hook script sources this, then calls hk_guard with the payload: outside
# an active iamlazy run the hooks must be inert, because they are registered
# globally and would otherwise fire on every session.

HK_DIR="${HOME}/.iamlazy"
HK_ACTIVE_DIR="${HK_DIR}/active"
HK_LOG="${HK_DIR}/runs.jsonl"
# Pre-2026-09-05 layout: one global run file. Only read, to migrate it away.
HK_LEGACY_TMP="${HK_DIR}/run.tmp.json"

# Set by hk_guard to THIS session's run file. Empty until then.
HK_RUN_TMP=""

# Set by the caller before hk_close_signal: "1" when the Critic has returned.
HK_CRITIC_DONE=""

# Set by the caller before hk_close_signal: "1" when guard-agent.sh actually
# asked about spawning the Critic THIS run -- proof of an attempt, never the
# model's word for it. Without this, "declare the decline and close" (added
# 2026-09-11) was a prose escape hatch a model could grant itself: a real run
# closed with "the human decided not to review" in the journal while zero
# Task/Agent calls appear anywhere in its transcript. The human was never
# asked. See hk_close_signal.
HK_CRITIC_ASKED=""

# Git's empty-tree hash. The base_ref for a repository with no commits yet, so
# a greenfield run still has something to diff against.
HK_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# A run whose session died without SessionEnd. 24h is deliberately generous:
# now that state is per-session a stale file harms nobody else, so the sweep is
# log hygiene, not a safety mechanism, and flushing a live run would lose it.
HK_STALE_SECONDS=86400

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

# hk_num <payload> <field> -> integer value of an unquoted numeric field, empty
# if absent. The string-payload twin of hk_json_num, which reads a file.
hk_num() {
  printf '%s' "$1" | grep -o "\"$2\":[0-9]*" | head -1 | grep -o '[0-9]*$'
}

# hk_field_file <file> <field> -> string value of a field read from a FILE.
hk_field_file() {
  [ -f "$1" ] || return 0
  grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed 's/^[^:]*:"//; s/"$//'
}

# hk_json_num <file> <key> -> integer value of a numeric JSON field.
hk_json_num() {
  grep -o "\"$2\":[0-9]*" "$1" 2>/dev/null | head -1 | grep -o '[0-9]*$'
}

# hk_json_esc <string> -> the string with backslashes and quotes escaped, safe
# to place inside a JSON string. This file builds JSON without a parser, so
# every value that reaches the log has to be made safe on the way in.
hk_json_esc() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'
}

# ------------------------------------------------------------ run state
#
# One file per SESSION, under ~/.iamlazy/active/. It used to be a single global
# run.tmp.json, and that was the bug: any session on the machine inherited an
# open run's guarantees -- sub-agents denied, edits traced into whatever repo
# happened to be open, `git add -N` run on every turn. Verified 2026-09-05, an
# abandoned run from one project kept the guard armed in every other session
# for hours, including sessions that had nothing to do with iamlazy.
#
# Four files make up a run's state, all sharing the session's stem:
#   <sid>.json       identity, timing, project_root, base_ref
#   <sid>.untracked  files already untracked when the contract was written
#   <sid>.gate       the last close-blocker set the model was told about
#   <sid>.stage      the last stage banner seen, for abandoned runs

# hk_run_file <session_id> -> path of that session's run file.
# The id is sanitised because it becomes a filename: a payload is input, and
# input never gets to choose a path.
hk_run_file() {
  printf '%s/%s.json' "$HK_ACTIVE_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"
}

hk_untracked_file() { printf '%s.untracked' "${1%.json}"; }
hk_gate_file()      { printf '%s.gate' "${1%.json}"; }
hk_stage_file()     { printf '%s.stage' "${1%.json}"; }
hk_findings_file()  { printf '%s.findings' "${1%.json}"; }

# <sid>.cost -- written by a HOST ADAPTER, never by these hooks. Claude Code has
# no per-message cost, so the hooks derive it from the transcript and the price
# table; OpenCode and Pi compute cost per message themselves and hand it over.
# When this file exists it is the run's cost, Critic included, delta applied --
# the adapter owns that arithmetic because it can see the child sessions. Shape:
# KEY=value lines: cost_micro, tokens_output, tokens_cache_write,
# tokens_cache_read. Deriving a second figure from prices.conf on top of a host
# that already priced the run would produce two numbers that disagree.
hk_cost_file()      { printf '%s.cost' "${1%.json}"; }

# hk_run_clear <run_file> -> remove a run and all of its sidecars.
hk_run_clear() {
  rm -f "$1" "$(hk_untracked_file "$1")" "$(hk_gate_file "$1")" \
        "$(hk_stage_file "$1")" "$(hk_findings_file "$1")" "$(hk_cost_file "$1")"
}

# hk_kv <file> <key> -> value of a KEY=value line, empty if absent.
hk_kv() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# hk_guard <payload> -> 0 when THIS session has an active run, 1 otherwise.
# Sets HK_RUN_TMP to that session's run file.
hk_guard() {
  local hk_sid
  hk_sid=$(hk_field "$1" "session_id")
  [ -n "$hk_sid" ] || return 1
  HK_RUN_TMP=$(hk_run_file "$hk_sid")
  [ -f "$HK_RUN_TMP" ]
}

# hk_set_field <file> <key> <json_value> -> add the field if absent, idempotently.
# The value must already be valid JSON (quoted string or number). Built by
# stripping the closing brace and appending, rather than by sed substitution:
# a path containing `&` or `|` corrupts a sed replacement, and paths are
# exactly what this records.
hk_set_field() {
  local f k v content
  f="$1"; k="$2"; v="$3"
  [ -f "$f" ] || return 0
  grep -q "\"$k\":" "$f" 2>/dev/null && return 0
  content=$(cat "$f")
  case "$content" in
    *'}')
      printf '%s,"%s":%s}' "${content%\}}" "$k" "$v" > "$f.new" 2>/dev/null \
        && mv "$f.new" "$f"
      ;;
  esac
}

# hk_project_root <run_file> <cwd> -> the directory the WORK is happening in.
# NOT the same as cwd: a session started in ~/dev/foo can be told to build a
# project in ~/dev/bar, and every hook that assumed cwd==project silently
# accounted for the wrong repo. Found on the first real run: the journal landed
# in one repo while the contract lived in another, the close looked for the
# contract where it was not, and the circuit breaker divided by the line count
# of an unrelated repo. Falls back to cwd, which is correct for the common case.
hk_project_root() {
  local root
  root=$(hk_field_file "$1" "project_root")
  if [ -n "$root" ] && [ -d "$root" ]; then printf '%s' "$root"; else printf '%s' "$2"; fi
}

# hk_set_project_root <run_file> <root> -> record it once, idempotently.
hk_set_project_root() {
  hk_set_field "$1" "project_root" "\"$(hk_json_esc "$2")\""
}

# hk_set_base <run_file> <root> -> record base_ref and the untracked baseline.
#
# base_ref is taken when the contract is written, which is the first thing the
# harness puts on disk after the gate, so it marks the repository state the run
# is accountable for. Everything downstream diffs against it instead of against
# the index -- see hk_changed_files for why that matters.
hk_set_base() {
  local f root ref
  f="$1"; root="$2"
  grep -q '"base_ref"' "$f" 2>/dev/null && return 0
  ref=$(cd "$root" 2>/dev/null && git rev-parse HEAD 2>/dev/null)
  [ -n "$ref" ] || ref="$HK_EMPTY_TREE"
  hk_set_field "$f" "base_ref" "\"$ref\""
  (cd "$root" 2>/dev/null && git ls-files --others --exclude-standard 2>/dev/null) \
    > "$(hk_untracked_file "$f")" 2>/dev/null || : > "$(hk_untracked_file "$f")"
}

hk_deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# hk_ask <reason> -> permissionDecision "ask": Claude Code shows the human a
# real approval prompt before the tool runs, carrying this reason. Confirmed
# against the hooks schema in the installed plugin-dev skill (allow|deny|ask);
# not yet confirmed live, same "documented, not observed" caveat this project
# already carries for Stop's decision:block -- verify on a real run before
# trusting the UI text, not just the JSON shape.
#
# A host whose adapter only recognises "deny" (OpenCode today) degrades this
# to an allow: the tool runs with no prompt, exactly as before this existed.
# That is deliberate, not a gap -- see the OpenCode adapter's own comment.
hk_ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

hk_allow() { exit 0; }

# ------------------------------------------------------- change accounting

# hk_changed_files <root> <base_ref> <untracked_baseline> -> changed paths.
#
# Diffed against base_ref, NOT against the index. `git diff` with no ref shows
# only UNSTAGED work, so `git add` or `git commit` during a run made every
# change invisible. Verified 2026-09-05: two logged runs closed reporting
# 0 files / 0 lines over code that was really written -- which also meant the
# scope gate had nothing to check and the circuit breaker divided by zero.
#
# There is no `git add -A -N` here any more either. It made new files visible
# to `git diff --stat`, but as a side effect it mutated the user's index on
# every turn: with an intent-to-add entry present `git stash` fails outright
# with "Cannot save the current worktree state". New files now come from
# `git ls-files --others` minus the ones that were already there at base.
hk_changed_files() {
  local root base basefile
  root="$1"; base="$2"; basefile="$3"
  [ -n "$root" ] && [ -d "$root/.git" ] || return 0
  ( cd "$root" 2>/dev/null || exit 0
    git diff --name-only "$base" 2>/dev/null
    if [ -s "$basefile" ]; then
      git ls-files --others --exclude-standard 2>/dev/null | grep -Fxv -f "$basefile" 2>/dev/null
    else
      git ls-files --others --exclude-standard 2>/dev/null
    fi
  ) | grep -v '^\.iamlazy/' | grep -v '^PROJECT\.md$' | sort -u
}

# hk_changed_lines <root> <base_ref> <untracked_baseline> -> insertions+deletions.
# Tracked files come from --numstat against base_ref; files created during the
# run are counted with awk (NR, not `wc -l`, so a file with no trailing newline
# is not undercounted by one).
hk_changed_lines() {
  local root base basefile
  root="$1"; base="$2"; basefile="$3"
  [ -n "$root" ] && [ -d "$root/.git" ] || return 0
  ( cd "$root" 2>/dev/null || exit 0
    git diff --numstat "$base" 2>/dev/null \
      | awk '$3 !~ /^\.iamlazy\// && $3 != "PROJECT.md" && $1 ~ /^[0-9]+$/ { s += $1 + $2 } END { print s+0 }'
    hk_changed_files "$root" "$base" "$basefile" | while IFS= read -r nf; do
      [ -f "$nf" ] && [ -z "$(git ls-files -- "$nf" 2>/dev/null)" ] \
        && awk 'END{print NR+0}' "$nf" 2>/dev/null
    done
  ) | awk '{ s += $1 } END { print s+0 }'
}

# ------------------------------------------------------------ scope ledger

# hk_scope_patterns <contract_path> -> one declared Scope pattern per line.
# Reads the "## Scope" section: a line per path/glob under that heading, until
# the next "## " heading. No section, or no contract, means "scope not
# declared" -- callers must treat that as unscoped, never as a violation.
#
# Normalised on the way out, because the contract is written by a model in
# prose and two harmless habits used to produce phantom violations (verified
# 2026-09-05): wrapping the path in backticks, and writing a directory with a
# trailing slash. Both are normalised; nothing else is. Over-normalising would
# turn a real deviation into a silent pass, and the errors are not symmetric --
# a false violation is loud and recoverable, a missed one is neither.
hk_scope_patterns() {
  local contract
  contract="$1"
  [ -f "$contract" ] || return 1
  awk '
    /^## Scope/ { insec=1; next }
    /^## / { insec=0 }
    insec && /^- / {
      sub(/^- /, "")
      gsub(/`/, "")
      sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
      if ($0 == "") next
      if ($0 ~ /\/$/) $0 = $0 "*"
      print
    }
  ' "$contract"
}

# hk_scope_violations <root> <contract> <base_ref> <untracked_baseline> ->
# changed paths NOT covered by any declared Scope pattern, one per line. Empty
# output means either everything is covered, or scope was never declared (both
# are "no violation" -- an undeclared scope cannot be violated, only an unmet
# one can).
#
# PROJECT.md and .iamlazy/ are already excluded upstream by hk_changed_files:
# updating the project model is part of the CLOSE protocol, not a deviation
# from the task's scope. Without that, every run doing what the close step asks
# would block its own close -- a structural false positive found by running the
# real flow, not by reading the code.
hk_scope_violations() {
  local root contract base basefile patterns changed oldifs ok f pat
  root="$1"; contract="$2"; base="$3"; basefile="$4"
  patterns=$(hk_scope_patterns "$contract") || return 0
  [ -n "$patterns" ] || return 0
  changed=$(hk_changed_files "$root" "$base" "$basefile")
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
      # shellcheck disable=SC2254  # $pat is meant to glob-match, not to be literal
      case "$f" in
        $pat) ok=1; break ;;
      esac
    done
    [ "$ok" = 0 ] && printf '%s\n' "$f"
  done
  IFS="$oldifs"
  return 0
}

# ------------------------------------------------------------ close signal

# hk_stage <payload> -> the stage name from this turn's banner, empty if none.
# Shape-based, not vocabulary-based: it reads whatever word sits in the banner
# position rather than matching a list, so a stage the prompt never defined
# shows up in the log as itself instead of vanishing.
hk_stage() {
  printf '%s' "$1" \
    | grep -Eo '─ [^ "]{1,20} ·' \
    | tail -1 \
    | sed -e 's/^─ //' -e 's/ ·$//' \
    | tr -d '\\"'
}

# hk_close_blockers <root> <contract> <base_ref> <untracked_baseline> ->
# one line per reason this run cannot close yet. Empty means it can.
#
# The checkbox scan covers the WHOLE contract rather than a "## Groups"
# section, and that is deliberate: the contract is written in the human's
# language, so the heading is not a fixed token. Scanning everything can
# over-block, which is loud and recoverable; scoping to a heading that does not
# match under-blocks, which is silent.
hk_close_blockers() {
  local root contract base basefile n v
  root="$1"; contract="$2"; base="$3"; basefile="$4"
  [ -f "$contract" ] || return 0
  n=$(grep -c -- '- \[ \]' "$contract" 2>/dev/null | tr -d ' ')
  [ "${n:-0}" -gt 0 ] 2>/dev/null && printf 'grupos sin marcar en el contrato: %s\n' "$n"
  v=$(hk_scope_violations "$root" "$contract" "$base" "$basefile" | tr '\n' ' ')
  [ -n "$v" ] && printf 'archivos fuera del ## Scope declarado: %s\n' "$v"
  return 0
}

# hk_has_close_banner <payload> -> 0 when this turn's text carries the CLOSE
# banner, i.e. the model believes it is finishing.
#
# The pattern uses the LITERAL box-drawing character, not a \x escape.
# `grep -E '\xe2\x94\x80'` matches under LC_ALL=C and silently does NOT under a
# UTF-8 locale, which is what the hooks actually run in -- so this path was
# dead in production while the suite went green in CI's C locale. Verified
# 2026-09-05 against BSD grep 2.6.0 under both locales. That is the third time
# this close path has died silently (it looked for `A5` before the prompt was
# rewritten to emit CIERRE/CLOSE), and the first time the cause was the
# environment rather than the token.
hk_has_close_banner() {
  printf '%s' "$1" | grep -Eq '─[^"]{0,60}(CLOSE|CIERRE)|(CLOSE|CIERRE)[^"]{0,60}─'
}

# hk_close_signal <payload> <contract> <root> <base_ref> <untracked_baseline>
#   -> "contract" | "banner" | "" (none)
#
# Stop fires after EVERY assistant turn, not just at the real close of a run --
# a naive "flush on Stop" would write many lines per run. Two mechanical
# signals distinguish an actual close, checked in order:
#   1. contract.md exists and hk_close_blockers finds nothing: every group
#      checkbox is resolved AND every changed file is covered by a declared
#      Scope pattern. This is the Guarantee-4 scope gate. It does not undo the
#      edit (PostToolUse cannot), it refuses to let the run call itself done
#      until the deviation is declared (Scope updated) or reverted.
#   2. no contract exists (the trivial path has none) and the turn's own text
#      carries the CLOSE banner. Weaker than (1) -- it trusts a banner token,
#      not free prose -- kept only as the floor for the path with no ledger.
#
# Signal (1) requires a base_ref, i.e. THIS run wrote that contract. Found by a
# smoke test on 2026-09-05: `.iamlazy/contract.md` survives the close, so the
# NEXT run in the same project met a fully-ticked contract with no violations
# on its very first turn and closed immediately -- logging a run that had done
# nothing, under the previous task's summary. A contract on disk is not this
# run's contract until this run writes it.
#
# It also requires that the run be past its REVIEW: either the Critic has
# returned (`critic_done`, set by subagent-done.sh) or the turn carries the
# CLOSE banner. Found on the first real run of the reworked harness -- the model
# ticked its group, spawned the Critic in the background, and its turn ended;
# 17 seconds later this function said "every box is ticked, nothing is out of
# scope" and closed a run whose review was still executing. Every box ticked is
# necessary and was never sufficient: Layer 1 puts review and close AFTER the
# execution that ticks them.
#
# The `or` is load-bearing, not belt-and-braces. Whether this build emits
# SubagentStop, and whether its payload carries the parent session_id, are
# unverified. If either is wrong, `critic_done` never arrives -- and without
# the banner alternative every run would hang open until the 24h sweep called
# it abandoned. A guard whose failure mode is worse than the bug is not a guard.
hk_close_signal() {
  local payload contract root base basefile
  payload="$1"; contract="$2"; root="$3"; base="$4"; basefile="$5"
  if [ -f "$contract" ] && [ -n "$base" ]; then
    [ -n "$(hk_close_blockers "$root" "$contract" "$base" "$basefile")" ] && return 1
    if [ "$HK_CRITIC_DONE" != "1" ]; then
      # Closing without a review needs Layer 0 proof an attempt happened --
      # guard-agent.sh actually asking about the Critic -- never just this
      # turn's banner and the model's say-so. HK_CRITIC_ASKED is set only by
      # that hook firing, so "asked and declined" and "asked, approved, but
      # SubagentStop never reported back" both satisfy it; "never even tried"
      # does not, and stays blocked regardless of what the banner claims.
      if [ "$HK_CRITIC_ASKED" != "1" ] || ! hk_has_close_banner "$payload"; then
        return 1
      fi
    fi
    echo "contract"; return 0
  fi
  if hk_has_close_banner "$payload"; then
    echo "banner"; return 0
  fi
  return 1
}

# hk_journal_append <root> <line> -> append one line to .iamlazy/journal.md.
# Append-only, written as a side effect of the edit itself -- never redacted
# from memory at close time, which is what makes it trustworthy to a revisor
# who did not do the work: a trace written after the fact is a story, not a
# record.
hk_journal_append() {
  local cwd line
  cwd="$1"; line="$2"
  mkdir -p "${cwd}/.iamlazy"
  printf '%s\n' "$line" >> "${cwd}/.iamlazy/journal.md"
}

# hk_rel_path <cwd> <abs_path> -> path relative to cwd, or the absolute path
# unchanged if it does not live under cwd.
hk_rel_path() {
  case "$2" in
    # $1 quoted INSIDE the expansion too, not just around it: a project path
    # containing a glob character (`[`, `]`, `*`, `?` -- not exotic, a folder
    # named "Client [Acme]" has one) would otherwise be read as a pattern by
    # the `#` operator instead of a literal prefix, and the strip would
    # silently fail -- found by shellcheck (SC2295), reproduced with such a
    # path before trusting the fix.
    "$1"/*) printf '%s' "${2#"$1"/}" ;;
    *) printf '%s' "$2" ;;
  esac
}

# ------------------------------------------------------------------ cost

# ------------------------------------------------------------------ cost

# hk_prices -> path of the price table.
hk_prices() { printf '%s/prices.conf' "$HK_DIR"; }

# hk_cost_micro <transcript> [prices] -> cost in MICRO-dollars, or nothing when
# a model in the transcript is missing from the price table.
#
# Micro-dollars because bash has no float arithmetic and the close has to
# subtract a baseline: integers make the delta exact. Divided back to dollars
# only when the line is written.
#
# Replaces `tokens_weighted`, which normalised everything to input-token
# equivalents and so priced a Sonnet token and an Opus token identically -- see
# prices.conf for the measurement that killed it. Same de-duplication by message
# id: a transcript records the same assistant message once per streaming chunk,
# and summing them naively overstated spend ~2.1x (measured 2026-08-27).
#
# Unknown model => no number at all, deliberately. Pricing the part it
# recognises and presenting that as the run's cost would be a silently low
# figure, and this project has already shipped two confidently wrong numbers.
hk_cost_micro() {
  local t prices
  t="$1"; prices="${2:-$(hk_prices)}"
  [ -n "$t" ] && [ -f "$t" ] || return 1
  [ -f "$prices" ] || return 1
  awk '
    NR==FNR {
      if ($0 ~ /^[[:space:]]*#/ || NF < 3) next
      pin[$1]=$2; pout[$1]=$3
      next
    }
    {
      if (!match($0, /"usage":\{/)) next
      id = ""
      if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) id = substr($0, RSTART, RLENGTH)
      if (id != "" && (id in seen)) next
      if (id != "") seen[id] = 1

      model = ""
      if (match($0, /"model":"[^"]+"/)) model = substr($0, RSTART+9, RLENGTH-10)
      # A trailing -YYYYMMDD is a SNAPSHOT of the same model, priced the same by
      # definition, so it is stripped before the lookup. Nothing else is: prefix
      # matching in general would let `claude-opus-6-preview` be priced at
      # opus-5 rates, and a wrong number is worse than none -- which is the
      # whole reason an unknown model reports null and names itself.
      sub(/-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/, "", model)
      if (model == "" || !(model in pin)) { bad = 1; next }

      o = c = r = i = 0
      if (match($0, /"output_tokens":[0-9]+/))               o = substr($0, RSTART+16, RLENGTH-16)
      if (match($0, /"cache_creation_input_tokens":[0-9]+/)) c = substr($0, RSTART+30, RLENGTH-30)
      if (match($0, /"cache_read_input_tokens":[0-9]+/))     r = substr($0, RSTART+26, RLENGTH-26)
      if (match($0, /"input_tokens":[0-9]+/))                i = substr($0, RSTART+15, RLENGTH-15)

      # cache write = input x1.25, cache read = input x0.1
      usd += (i * pin[model] + o * pout[model] \
              + c * pin[model] * 1.25 + r * pin[model] * 0.1) / 1000000
    }
    END { if (bad) exit 1; printf "%d", usd * 1000000 + 0.5 }
  ' "$prices" "$t" 2>/dev/null
}

# hk_unpriced_models <transcript> [prices] -> models the price table does not
# know, space separated. Names what to add instead of leaving an unexplained
# null.
hk_unpriced_models() {
  local t prices
  t="$1"; prices="${2:-$(hk_prices)}"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  [ -f "$prices" ] || return 0
  awk '
    NR==FNR { if ($0 !~ /^[[:space:]]*#/ && NF >= 3) pin[$1]=1; next }
    {
      if (!match($0, /"usage":\{/)) next
      if (!match($0, /"model":"[^"]+"/)) next
      m = substr($0, RSTART+9, RLENGTH-10)
      raw = m
      sub(/-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/, "", m)
      if (!(m in pin)) miss[raw] = 1
    }
    END { for (m in miss) printf "%s ", m }
  ' "$prices" "$t" 2>/dev/null
}

# hk_subagent_cost_micro <transcript> -> cost of every sub-agent this session
# spawned. The Critic runs in its own transcript under <session>/subagents/, so
# it was invisible to the old figure: measured 2026-09-05 it was $0.50 of a
# $3.53 run -- 14% of the cost, and the one part of the harness that has caught
# production bugs. A cost line that omits the reviewer understates every
# reviewed run.
hk_subagent_cost_micro() {
  local t dir total c f
  t="$1"
  dir="${t%.jsonl}/subagents"
  total=0
  [ -d "$dir" ] || { printf '0'; return 0; }
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    c=$(hk_cost_micro "$f") || { printf ''; return 1; }
    total=$((total + c))
  done
  printf '%s' "$total"
}

# hk_unpriced_run <transcript> -> every model the price table does not know,
# across the main transcript AND each sub-agent's, space separated.
#
# The Critic's models were invisible here while its COST was already being
# added in, so an unpriced model inside a review produced a null the log could
# not explain: `cost_usd: null` with an empty `cost_unpriced`. A null that names
# nothing is indistinguishable from a bug, and it took a real run to notice.
hk_unpriced_run() {
  local t dir f
  t="$1"
  { hk_unpriced_models "$t"
    dir="${t%.jsonl}/subagents"
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] && hk_unpriced_models "$f"
    done
  } | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# hk_micro_to_usd <micro> -> decimal dollars, 4 places, for the log line.
hk_micro_to_usd() {
  awk -v m="$1" 'BEGIN { printf "%.4f", m / 1000000 }'
}

# hk_token_components <transcript> -> "output cache_write cache_read", deduped.
# Logged as per-run deltas so any run can be REPRICED from the record after the
# price table is corrected. A cost figure you cannot recompute is a figure you
# have to trust, and this project's whole posture on its own numbers is that
# trust is the wrong thing to extend them.
hk_token_components() {
  local t
  t="$1"
  [ -n "$t" ] && [ -f "$t" ] || return 1
  awk '
    {
      if (!match($0, /"usage":\{/)) next
      id = ""
      if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) id = substr($0, RSTART, RLENGTH)
      if (id != "" && (id in seen)) next
      if (id != "") seen[id] = 1
      if (match($0, /"output_tokens":[0-9]+/))               o += substr($0, RSTART+16, RLENGTH-16)
      if (match($0, /"cache_creation_input_tokens":[0-9]+/)) c += substr($0, RSTART+30, RLENGTH-30)
      if (match($0, /"cache_read_input_tokens":[0-9]+/))     r += substr($0, RSTART+26, RLENGTH-26)
    }
    END { printf "%d %d %d", o+0, c+0, r+0 }
  ' "$t"
}

# ------------------------------------------------------- models seen
#
# WHICH model produced a run, as "model:messages model:messages", commonest
# first. The log already carried what a run cost and how long it took, but not
# what answered it -- so "which model ran the planner?" could only be settled by
# parsing a transcript by hand, which is exactly how two sessions were spent
# (2026-09-11: opusplan's switch at the gate on Claude Code, and OpenCode's
# `plan` agent inheriting the builder's model instead of the configured one).
#
# Counts, not a bare list. A list says both models appeared; the counts are what
# identify the stage -- a run reading `kimi:15 deepseek:4` puts the review on
# deepseek and everything else on kimi, which is the actual question being asked.
#
# The snapshot suffix is NOT stripped here, unlike the pricing path: pricing
# needs `claude-opus-5-20260201` to resolve to a rate, this needs to report what
# really ran.

# hk_model_counts <file> -> "model:count " per model in ONE transcript.
# De-duplicated by message id for the same reason hk_cost_micro does it: a
# transcript records the same assistant message once per streaming chunk, and
# counting them naively reports turns that never happened.
hk_model_counts() {
  local t
  t="$1"
  [ -n "$t" ] && [ -f "$t" ] || return 0
  awk '
    {
      if (!match($0, /"usage":\{/)) next
      id = ""
      if (match($0, /"id":"msg_[A-Za-z0-9_]+"/)) id = substr($0, RSTART, RLENGTH)
      if (id != "" && (id in seen)) next
      if (id != "") seen[id] = 1
      if (!match($0, /"model":"[^"]+"/)) next
      n[substr($0, RSTART+9, RLENGTH-10)]++
    }
    END { for (m in n) printf "%s:%d ", m, n[m] }
  ' "$t" 2>/dev/null
}

# hk_models_sum -> reads "model:count" tokens on stdin, adds up the repeats and
# prints them commonest first, ties broken by name so the field is stable.
# The count is matched at the END of the token, never split on the first `:`, so
# a provider-qualified id keeps working.
hk_models_sum() {
  tr ' ' '\n' | awk '
    {
      if (!match($0, /:[0-9]+$/)) next
      n[substr($0, 1, RSTART-1)] += substr($0, RSTART+1)
    }
    END { for (m in n) printf "%d %s\n", n[m], m }
  ' | sort -k1,1nr -k2,2 | awk '{ printf "%s:%s ", $2, $1 }' | sed 's/ $//'
}

# hk_models_run <transcript> -> the models of the main transcript AND every
# sub-agent's, summed. The Critic runs in its own file, and it is usually the
# one model a run deliberately decorrelated -- omitting it would hide the split
# this field exists to show.
hk_models_run() {
  local t dir f
  t="$1"
  { hk_model_counts "$t"
    dir="${t%.jsonl}/subagents"
    for f in "$dir"/*.jsonl; do
      [ -f "$f" ] && hk_model_counts "$f"
    done
  } | hk_models_sum
}

# hk_models_delta <now> <baseline> -> what THIS run added.
#
# The transcript accumulates the whole session, so the baseline taken at open is
# subtracted here -- the same shape cost and interventions already use. A model
# whose count did not grow is dropped rather than reported as zero, and a count
# that went DOWN (a compaction rewrote the file) is dropped too, which is the
# same clamp the token deltas apply.
hk_models_delta() {
  awk -v now="$1" -v base="$2" '
    BEGIN {
      c = split(base, b, " ")
      for (i = 1; i <= c; i++)
        if (match(b[i], /:[0-9]+$/)) was[substr(b[i], 1, RSTART-1)] = substr(b[i], RSTART+1)
      c = split(now, a, " ")
      for (i = 1; i <= c; i++) {
        if (!match(a[i], /:[0-9]+$/)) continue
        m = substr(a[i], 1, RSTART-1)
        d = substr(a[i], RSTART+1) - (m in was ? was[m] : 0)
        if (d > 0) printf "%s:%d ", m, d
      }
    }' | hk_models_sum
}

# hk_models_bump <current> <model> -> current with one more message for <model>.
# For hosts that price their own messages and hand them over one at a time
# (see host-cost.sh); they have no transcript for the counting path to read.
hk_models_bump() {
  printf '%s %s:1 ' "$1" "$2" | hk_models_sum
}

# ------------------------------------------------------- abandoned runs

# hk_log_append <line> -> append one JSON line, guaranteeing the separator.
# `cat tmp >> log` does not guarantee a trailing newline, and that fused 5 of
# 28 objects into unparseable lines once already (2026-08-22).
hk_log_append() {
  mkdir -p "$HK_DIR"
  [ -f "$HK_LOG" ] && [ -n "$(tail -c1 "$HK_LOG" 2>/dev/null)" ] && printf '\n' >> "$HK_LOG"
  printf '%s\n' "$1" >> "$HK_LOG"
}

# hk_flush_abandoned <run_file> -> log the run as abandoned and clear it.
#
# A run that never reached its close used to be appended verbatim, carrying
# `"outcome":"incomplete"` and whatever schema it opened with, so the log held
# a third shape nobody documented. An abandoned run is a real outcome and gets
# a real line, including the stage it died at -- which is the one thing worth
# knowing about it.
hk_flush_abandoned() {
  local f sid tpath root stage start dur fired host models
  f="$1"
  [ -f "$f" ] || return 0
  sid=$(hk_field_file "$f" "session_id")
  tpath=$(hk_field_file "$f" "transcript_path")
  root=$(hk_field_file "$f" "project_root")
  [ -n "$root" ] || root=$(hk_field_file "$f" "cwd")
  stage=$(cat "$(hk_stage_file "$f")" 2>/dev/null)
  start=$(hk_json_num "$f" "start_epoch")
  dur=null
  [ -n "$start" ] && dur=$(( $(date +%s) - start ))
  # Same schema generation as a flushed line, carrying the subset a run that
  # never closed can honestly fill. It used to claim `3` forever, which made the
  # log lie about which generation wrote it -- the reader groups by that number.
  # An abandoned run that had tripped the breaker is the canonical sick run:
  # expensive, unproductive, and it never even closed. That is worth carrying
  # into the log rather than losing with the run file.
  fired=0
  grep -q '"drift_warned"' "$f" 2>/dev/null && fired=1
  # Same default as flush-run.sh: absent means claude-code. Missing here meant
  # every abandoned OpenCode run silently misattributed to the wrong host --
  # found auditing the log, not by a test. `/iamlazy-review` groups by this
  # field, so a mislabeled line corrupts a per-host count rather than just
  # looking incomplete.
  host=$(hk_field_file "$f" "host"); [ -n "$host" ] || host="claude-code"
  # An abandoned run still spent what it spent, on some model. This is the run
  # where that matters most -- the log's two longest lines are abandoned ones --
  # so the field is filled here the same way the close fills it: the host's own
  # tally when it priced its messages, the transcript delta otherwise.
  models=$(hk_kv "$(hk_cost_file "$f")" models)
  [ -n "$models" ] || models=$(hk_models_delta "$(hk_models_run "$tpath")" "$(hk_field_file "$f" "start_models")")
  hk_log_append "$(printf '{"schema_version":7,"host":"%s","timestamp":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","duration_seconds":%s,"stage_reached":"%s","models_seen":"%s","drift_fired":%s,"outcome":"abandoned"}' \
    "$(hk_json_esc "$host")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(hk_json_esc "$sid")" "$(hk_json_esc "$tpath")" "$(hk_json_esc "$root")" \
    "$dur" "$(hk_json_esc "$stage")" "$(hk_json_esc "$models")" "$fired")"
  hk_run_clear "$f"
}

# hk_sweep_stale -> flush any run whose session died without SessionEnd, plus
# the pre-2026-09-05 global run file if one is still lying around.
hk_sweep_stale() {
  local now f st
  now=$(date +%s)
  for f in "$HK_ACTIVE_DIR"/*.json; do
    [ -f "$f" ] || continue
    st=$(hk_json_num "$f" "start_epoch")
    [ -n "$st" ] || st=0
    [ $((now - st)) -ge "$HK_STALE_SECONDS" ] && hk_flush_abandoned "$f"
  done
  if [ -f "$HK_LEGACY_TMP" ]; then
    hk_flush_abandoned "$HK_LEGACY_TMP"
  fi
  return 0
}
