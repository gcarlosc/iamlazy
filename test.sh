#!/usr/bin/env bash
# iamlazy test suite — installer, file composition, and the declared invariants.
# Same constraints as the rest of the project: bash 3.2, coreutils only, zero deps.
#
# Scope, stated honestly: this covers install/uninstall mechanics, model projection,
# anti-clobber, idempotency and the file-level invariants from PROJECT.md, and it
# delegates to test-hooks.sh for the Layer 0 runtime decisions. What it still does NOT
# do is execute a live /iamlazy run: the contract, the gate and the review remain
# correct by construction of the prompt. Layer 0 closed part of that debt -- a hook
# script reading JSON on stdin is testable in a way a prompt never was -- but the
# end-to-end path is still unexercised.
#
#   usage: ./test.sh
#   exit 0 = all passed, 1 = at least one failure

set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL  $1" >&2; }

# assert_file <path> <description>
assert_file() {
  if [ -f "$1" ]; then ok "$2"; else no "$2 (missing: $1)"; fi
}
# assert_absent <path> <description>
assert_absent() {
  if [ -f "$1" ]; then no "$2 (still present: $1)"; else ok "$2"; fi
}
# assert_grep <pattern> <file> <description>
assert_grep() {
  if [ -f "$2" ] && grep -q "$1" "$2" 2>/dev/null; then ok "$3"
  else no "$3 (no match for '$1' in $2)"; fi
}
# assert_no_grep <pattern> <file> <description>
assert_no_grep() {
  if [ -f "$2" ] && grep -q "$1" "$2" 2>/dev/null; then no "$3 (unexpected '$1' in $2)"
  else ok "$3"; fi
}

TMPDIRS=""
mktmp() { d="$(mktemp -d)"; TMPDIRS="$TMPDIRS $d"; echo "$d"; }
cleanup() { for d in $TMPDIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

# ---------------------------------------------------------------- syntax
echo "syntax"
for s in install.sh uninstall.sh test.sh; do
  if bash -n "$SRC/$s" 2>/dev/null; then ok "$s parses"; else no "$s parses"; fi
done

# ------------------------------------------------------- source invariants
echo
echo "source invariants"
# The budget applies to prose-of-judgement only: mechanical accounting moved to
# hooks/, which is why this dropped from 250 to 200. Design pressure, not a number
# to negotiate -- a new rule must evict another or become structure.
core_lines="$(wc -l < "$SRC/core/iamlazy.md" | tr -d ' ')"
if [ "$core_lines" -le 200 ]; then ok "core budget: $core_lines <= 200"
else no "core budget exceeded: $core_lines > 200"; fi

# Every template must declare the idempotency marker, or uninstall can never reclaim it.
for f in "$SRC"/templates/*/*.frontmatter; do
  assert_grep "iamlazy-managed" "$f" "marker present: $(basename "$(dirname "$f")")/$(basename "$f")"
done

# The Critic is read-only by frontmatter. This is an invariant, not a preference.
assert_grep "^tools: Read, Grep, Glob, Bash$" \
  "$SRC/templates/claude-code/agent-critic.frontmatter" "critic tools are read-only (claude)"
assert_grep "write: false" \
  "$SRC/templates/opencode/subagent-critic.frontmatter" "critic cannot write (opencode)"
assert_grep "edit: false" \
  "$SRC/templates/opencode/subagent-critic.frontmatter" "critic cannot edit (opencode)"
assert_grep "edit: ask" \
  "$SRC/templates/opencode/primary-iamlazy.frontmatter" "opencode gate backstop present"

# ------------------------------------------------------------ install: both
echo
echo "install --tool=both"
H="$(mktmp)"
HOME="$H" "$SRC/install.sh" --tool=both >/dev/null 2>&1

assert_file "$H/.claude/commands/iamlazy.md"        "claude: command installed"
assert_file "$H/.claude/commands/iamlazy-review.md" "claude: review installed"
assert_file "$H/.claude/agents/iamlazy-critic.md"   "claude: critic installed"
assert_file "$H/.config/opencode/agents/iamlazy.md" "opencode: primary installed"
assert_file "$H/.config/opencode/agents/iamlazy-critic.md" "opencode: critic installed"
assert_file "$H/.config/opencode/commands/iamlazy.md"      "opencode: command installed"
assert_file "$H/.iamlazy/DELTAS.md"                 "DELTAS mirror created"

# Model projection: the placeholder must be gone and the configured id present.
. "$SRC/models.conf"
assert_no_grep "{{MAIN_MODEL}}"   "$H/.claude/commands/iamlazy.md" "no unsubstituted MAIN_MODEL"
assert_no_grep "{{CRITIC_MODEL}}" "$H/.claude/agents/iamlazy-critic.md" "no unsubstituted CRITIC_MODEL"
assert_grep "model: $CC_MAIN_MODEL"   "$H/.claude/commands/iamlazy.md"      "main model projected"
assert_grep "model: $CC_CRITIC_MODEL" "$H/.claude/agents/iamlazy-critic.md" "critic model projected"

# Composition: frontmatter + full body + argument hook, in that order.
assert_grep "What is guaranteed vs what is asked" \
  "$H/.claude/commands/iamlazy.md" "core body composed in"
assert_grep 'Request:.*ARGUMENTS'   "$H/.claude/commands/iamlazy.md" "argument hook appended"
assert_grep "Anti-condescension"    "$H/.claude/agents/iamlazy-critic.md" "critic body composed in"

# ------------------------------------------------------------- idempotency
echo
echo "idempotency"
before="$(cksum < "$H/.claude/commands/iamlazy.md")"
HOME="$H" "$SRC/install.sh" --tool=both >/dev/null 2>&1
after="$(cksum < "$H/.claude/commands/iamlazy.md")"
if [ "$before" = "$after" ]; then ok "re-install is byte-identical"
else no "re-install changed the file"; fi

# ------------------------------------------------------------ anti-clobber
echo
echo "anti-clobber"
H2="$(mktmp)"
mkdir -p "$H2/.claude/commands"
echo "SOMEONE ELSE'S FILE" > "$H2/.claude/commands/iamlazy.md"
HOME="$H2" "$SRC/install.sh" --tool=claude >/dev/null 2>&1
assert_grep "SOMEONE ELSE'S FILE" "$H2/.claude/commands/iamlazy.md" "unmarked file is not clobbered"

# ------------------------------------------------------- --model override
# Runs against a COPY of the repo: persist_model rewrites models.conf in place, and a
# test must never mutate the working tree it is testing.
echo
echo "--model override"
CP="$(mktmp)"
cp -R "$SRC/." "$CP/" 2>/dev/null
rm -rf "$CP/.git"
H3="$(mktmp)"
HOME="$H3" "$CP/install.sh" --tool=claude --model=test-model-xyz >/dev/null 2>&1
assert_grep "model: test-model-xyz" "$H3/.claude/commands/iamlazy.md"      "override applied to main"
assert_grep "model: test-model-xyz" "$H3/.claude/agents/iamlazy-critic.md" "override applied to critic"
assert_grep 'CC_MAIN_MODEL="test-model-xyz"' "$CP/models.conf" "override persisted to models.conf"
assert_grep "$CC_MAIN_MODEL" "$SRC/models.conf" "real models.conf left untouched"

# --model with two tools must be refused: the id namespaces differ.
H4="$(mktmp)"
if HOME="$H4" "$CP/install.sh" --tool=both --model=x >/dev/null 2>&1; then
  no "--model with --tool=both is refused"
else
  ok "--model with --tool=both is refused"
fi

# ---------------------------------------------------------------- uninstall
echo
echo "uninstall"
printf '{"probe":"user data"}\n' > "$H/.iamlazy/runs.jsonl"
HOME="$H" "$SRC/uninstall.sh" >/dev/null 2>&1
assert_absent "$H/.claude/commands/iamlazy.md"      "claude command removed"
assert_absent "$H/.claude/agents/iamlazy-critic.md" "claude critic removed"
assert_absent "$H/.config/opencode/agents/iamlazy.md" "opencode primary removed"
assert_absent "$H/.iamlazy/DELTAS.md"               "DELTAS mirror removed"
assert_grep "user data" "$H/.iamlazy/runs.jsonl"    "runs.jsonl preserved (invariant)"

# Uninstall must refuse to remove a file that is not ours.
HOME="$H2" "$SRC/uninstall.sh" >/dev/null 2>&1
assert_grep "SOMEONE ELSE'S FILE" "$H2/.claude/commands/iamlazy.md" "unmarked file survives uninstall"

# ------------------------------------------------------- layer 0 (hooks)
# The hook suite is a separate file because it tests runtime decisions, not
# install mechanics. Running it here means one command still covers everything.
echo
echo "layer 0 (delegating to test-hooks.sh)"
if [ -x "$SRC/test-hooks.sh" ]; then
  if "$SRC/test-hooks.sh" >/dev/null 2>&1; then
    ok "test-hooks.sh passes"
  else
    no "test-hooks.sh has failures (run ./test-hooks.sh for detail)"
  fi
else
  no "test-hooks.sh missing or not executable"
fi

# ---------------------------------------------------- install --with-hooks
echo
echo "install --with-hooks"
H5="$(mktmp)"
HOME="$H5" "$SRC/install.sh" --tool=claude --with-hooks >/dev/null 2>&1
assert_file "$H5/.claude/iamlazy-hooks/guard-agent.sh" "hooks: guard installed"
assert_file "$H5/.claude/iamlazy-hooks/lib.sh"         "hooks: lib installed"
assert_file "$H5/.claude/iamlazy-hooks/flush-run.sh"   "hooks: flush installed"
if [ -x "$H5/.claude/iamlazy-hooks/guard-agent.sh" ]; then ok "hooks are executable"
else no "hooks are executable"; fi

# opt-in must be real: a plain install leaves no hooks behind
H6="$(mktmp)"
HOME="$H6" "$SRC/install.sh" --tool=claude >/dev/null 2>&1
if [ -d "$H6/.claude/iamlazy-hooks" ]; then no "hooks are opt-in (installed without the flag)"
else ok "hooks are opt-in (absent without the flag)"; fi

# the installer must never edit settings.json
if [ -f "$H5/.claude/settings.json" ]; then no "installer left settings.json alone"
else ok "installer left settings.json alone"; fi

# uninstall reclaims the hook dir
HOME="$H5" "$SRC/uninstall.sh" >/dev/null 2>&1
if [ -d "$H5/.claude/iamlazy-hooks" ]; then no "uninstall removes the hook dir"
else ok "uninstall removes the hook dir"; fi

# ------------------------------------------------------------------ report
echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
