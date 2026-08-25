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
