#!/usr/bin/env bash
# iamlazy Layer 0 — the Critic reads and runs tests. It does not write.
#
# PreToolUse on Bash, active only inside the Critic sub-agent. Until now
# PROJECT.md declared "the Critic never has write/edit permission" as an
# invariant and listed it, in the same file, as a known hole: the frontmatter
# denies Write and Edit, and Bash walks straight around both. An invariant with
# no mechanism is a wish, and this project's own rule says a rule a command can
# check does not belong in prose.
#
# It became implementable when hooks started receiving `agent_type` inside
# sub-agents -- confirmed on a real run 2026-09-05, when SubagentStop delivered
# the Critic's findings tally.
#
# SCOPE, stated honestly: this inspects the COMMAND STRING. It stops the shell
# from writing -- redirections, rm/mv/cp, in-place sed, git mutations, package
# installs. It does NOT stop a program the Critic legitimately runs from
# writing: `npm test` may create fixtures, and that is fine and intended. This
# closes the discipline hole, not every path to disk.
set -u
. "$(dirname "$0")/lib.sh"

payload=$(cat)

hk_guard "$payload" || hk_allow

[ "$(hk_field "$payload" "tool_name")" = "Bash" ] || hk_allow

# Substring match on the exact key:value pair, deliberately, rather than
# counting occurrences the way guard-agent.sh does. The failure directions are
# opposite: there, an ambiguous parse must DENY, because the question is "may
# this sub-agent spawn". Here the question is "is this the Critic", and denying
# on ambiguity would block the main thread's Bash. If the pair appears at all,
# treat the call as the Critic's -- wrong in the safe direction.
case "$payload" in
  *'"agent_type":"iamlazy-critic"'*) ;;
  *) hk_allow ;;
esac

# The command is free text and may carry escaped quotes, so hk_field cannot be
# trusted to extract it (its own comment says so). Patterns are matched against
# the WHOLE payload instead. That over-includes the `description` field, which
# can cost a false positive on a description like "check if a > b" -- accepted:
# the harness principle is that false positives cost tokens, never safety, and
# the Critic can restate the command.
#
# Safe redirections are scrubbed first, then any surviving `>` is a file write.
scrubbed=$(printf '%s' "$payload" | sed -E \
  -e 's/[0-9]*>&[0-9-]+//g' \
  -e 's/&>>?[[:space:]]*\/dev\/null//g' \
  -e 's/[0-9]*>>?[[:space:]]*\/dev\/(null|stderr|stdout)//g')

deny_write() {
  hk_deny "iamlazy: the Critic is read-only, and that includes Bash. Refused: ${1}. Read with cat/rg/git diff, run tests, and report the finding -- you do not fix anything, and you never leave a trace in the tree you are auditing."
}

case "$scrubbed" in
  *'>'*) deny_write "a redirection that writes to a file" ;;
esac

if printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_./-])(rm|mv|cp|mkdir|rmdir|touch|ln|chmod|chown|truncate|dd|tee)([[:space:]]|$)'; then
  deny_write "a command that creates, moves or destroys files"
fi

# `-i` may be the whole flag (`sed -i`), carry a suffix (`sed -i.bak`) or be
# bundled with others (`perl -pi -e`), so the flag cluster is matched, not the
# literal two characters. Both forms slipped through the first version.
if printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_])(sed|perl|ruby)[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z]*i|--in-place)'; then
  deny_write "an in-place edit"
fi

# `git add` is denied like every other mutation, and that is not incidental:
# an intent-to-add entry leaves `git stash` failing outright with "Cannot save
# the current worktree state". The hooks stopped doing it for the same reason
# (2026-09-05); the Critic derives new files with `git ls-files --others`.
if printf '%s' "$payload" | grep -Eq 'git[[:space:]]+(add|commit|checkout|switch|restore|reset|stash|apply|am|rm|mv|merge|rebase|cherry-pick|push|pull|fetch|clean|tag|branch|init|config)'; then
  deny_write "a git command that changes the repository or the index"
fi

if printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_])(npm|pnpm|yarn|bun|pip|pip3|gem|cargo|go|composer|brew|apt|apt-get)[[:space:]]+(install|add|get|i|update|upgrade|uninstall|remove)([[:space:]]|$)'; then
  deny_write "a package install"
fi

if printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_])wget([[:space:]]|$)|curl[^|;]*[[:space:]](-[oO]|--output)([[:space:]]|$)'; then
  deny_write "a download that writes to disk"
fi

hk_allow
