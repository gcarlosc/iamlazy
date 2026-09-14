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

# cp_repo <dest> -- a few tests need a disposable copy of the whole repo
# (rewriting models.conf in place, or simulating a checkout with no .git).
# adapters/opencode-v2/node_modules is a real (if gitignored) directory once
# built -- 213MB on this machine -- and `cp -R` copying it made this suite
# 8+ seconds slower per call for a directory neither test needs. `tar` piping
# through an exclude list copies only what the tests actually read.
cp_repo() {
  tar -C "$SRC" -c --exclude=.git --exclude=adapters/opencode-v2/node_modules \
    --exclude=adapters/opencode-v2/dist -f - . 2>/dev/null | tar -C "$1" -xf - 2>/dev/null
}

# ---------------------------------------------------------------- syntax
echo "syntax"
# Globbed, not listed. A list you have to remember to extend is the failure mode
# this project keeps paying for -- a new hook would simply never be checked.
for s in "$SRC"/*.sh "$SRC"/hooks/*.sh; do
  n="$(basename "$s")"
  if bash -n "$s" 2>/dev/null; then ok "$n parses"; else no "$n parses"; fi
done

# Every hook has to be executable in the repo, or the installer copies a file
# that cannot run and the guarantee is silently off.
for s in "$SRC"/hooks/*.sh; do
  n="$(basename "$s")"
  if [ -x "$s" ]; then ok "$n is executable"; else no "$n is not executable"; fi
done

# Every hook the installer copies must also be registered -- by merge-settings.sh
# on Claude Code, or invoked by an OpenCode adapter -- or it lands on disk and
# never runs. lib.sh and the installer helper are the only two that are sourced
# rather than registered. V1 is the adapter used for THIS check and the two
# below it (both adapters invoke the identical hook set, verified separately
# below, so checking one is representative here); ADAPTERS covers both for the
# checks where "both, explicitly" is the actual point -- existence and purity.
ADAPTER="$SRC/adapters/opencode/iamlazy.ts"
ADAPTERS="$SRC/adapters/opencode/iamlazy.ts:V1 $SRC/adapters/opencode-v2/iamlazy.ts:V2"
for s in "$SRC"/hooks/*.sh; do
  n="$(basename "$s")"
  case "$n" in lib.sh|merge-settings.sh) continue ;; esac
  if grep -q "\"$n\"" "$SRC/hooks/merge-settings.sh" || grep -q "\"$n\"" "$ADAPTER"; then
    ok "$n is registered by the installer or invoked by the adapter"
  else no "$n is installed but never registered (a file, not a guarantee)"; fi
done

# ------------------------------------------------------- source invariants
echo
echo "source invariants"
# The budget applies to prose-of-judgement only: mechanical accounting moved to
# hooks/, which is why this dropped from 250 to 200. Design pressure, not a number
# to negotiate -- a new rule must evict another or become structure.
#
# Measured on the COMPOSED body, per host, not on the source. The source now
# carries {{GUARANTEES}} and {{GATE}}; what the model reads is the source with
# each token replaced by that host's file, so that is what the budget governs.
# Composition is one token per line replaced by one whole file, so the arithmetic
# below is exact -- and it deliberately does not re-implement compose_core, which
# would be the copy this repo keeps paying for.
core_src="$(wc -l < "$SRC/core/iamlazy.md" | tr -d ' ')"
for host in claude-code opencode; do
  g="$SRC/templates/$host/guarantees.md"; t="$SRC/templates/$host/gate.md"
  if [ ! -f "$g" ] || [ ! -f "$t" ]; then
    no "host $host is missing guarantees.md or gate.md"
    continue
  fi
  # the marker line is stripped at compose time, so it does not count
  gl="$(grep -cv '^<!-- hooks:' "$g" | tr -d ' ')"
  tl="$(wc -l < "$t" | tr -d ' ')"
  composed=$((core_src - 2 + gl + tl))
  if [ "$composed" -le 200 ]; then ok "core budget ($host): $composed <= 200"
  else no "core budget exceeded ($host): $composed > 200"; fi
done

# The tokens must exist, or composition silently produces a prompt with no
# guarantees section at all and every host looks identical.
assert_grep '{{GUARANTEES}}' "$SRC/core/iamlazy.md" "core declares the {{GUARANTEES}} token"
assert_grep '{{GATE}}'       "$SRC/core/iamlazy.md" "core declares the {{GATE}} token"

# Layer 0 / Layer 1 agreement, third surface. The core used to open with "Hooks
# enforce five things for you" while merge-settings.sh registered seven hooks --
# the guarantees text and the hooks it describes had drifted apart, each looking
# correct alone. The marker in the template names the hooks whose guarantees it
# declares; these two lists must match exactly.
registered="$(sed -n 's/.*"\([a-z-]*\.sh\)".*/\1/p' "$SRC/hooks/merge-settings.sh" | sort -u)"
declared="$(sed -n 's/^<!-- hooks: \(.*\) -->$/\1/p' "$SRC/templates/claude-code/guarantees.md" | tr ' ' '\n' | grep -v '^$' | sort -u)"
if [ "$registered" = "$declared" ]; then
  ok "the guarantees text names exactly the hooks that are registered"
else
  no "guarantees text and registered hooks disagree -- registered: $(echo "$registered" | tr '\n' ' ')| declared: $(echo "$declared" | tr '\n' ' ')"
fi

# Fifth surface, same shape: the OpenCode prompt names the hooks its adapter
# invokes. The adapter is the registration on that host, so the two lists must
# match exactly, and every hook it names must exist.
declared_oc="$(sed -n 's/^<!-- hooks: \(.*\) -->$/\1/p' "$SRC/templates/opencode/guarantees.md" | tr ' ' '\n' | grep -v '^$' | sort -u)"
invoked="$(grep -o '"[a-z-]*\.sh"' "$ADAPTER" | tr -d '"' | sort -u)"
if [ "$invoked" = "$declared_oc" ]; then
  ok "opencode: the guarantees text names exactly the hooks the adapter invokes"
else
  no "opencode: guarantees text and adapter disagree -- invoked: $(echo "$invoked" | tr '\n' ' ')| declared: $(echo "$declared_oc" | tr '\n' ' ')"
fi
for hname in $invoked; do
  assert_file "$SRC/hooks/$hname" "adapter invokes a hook that exists: $hname"
done

# The adapter translates and never decides. If it knew what closing means, what
# a scope deviation is or when the breaker fires, Layer 0 would have two
# implementations -- and this repo has paid for two copies four times already.
if grep -Eq 'Scope|base_ref|DRIFT|CIERRE' "$ADAPTER"; then
  no "the adapter contains harness logic (Scope|base_ref|DRIFT|CIERRE) -- it must translate, never decide"
else
  ok "the adapter translates and never decides (no Scope|base_ref|DRIFT|CIERRE)"
fi

# Both OpenCode adapters, explicitly: hook existence and purity checked above
# only ran against V1. A translator nobody's invariants ever touched is the
# exact false green the V1 bun-test section's own comment refuses to accept
# for `bun` -- the same standard applies here, to V2.
v1_invoked=""
for pair in $ADAPTERS; do
  a="${pair%%:*}"; lbl="${pair##*:}"
  if [ ! -f "$a" ]; then no "$lbl adapter missing: $a"; continue; fi
  inv="$(grep -o '"[a-z-]*\.sh"' "$a" | tr -d '"' | sort -u)"
  for hname in $inv; do
    assert_file "$SRC/hooks/$hname" "$lbl adapter invokes a hook that exists: $hname"
  done
  if grep -Eq 'Scope|base_ref|DRIFT|CIERRE' "$a"; then
    no "$lbl adapter contains harness logic (Scope|base_ref|DRIFT|CIERRE) -- it must translate, never decide"
  else
    ok "$lbl adapter translates and never decides (no Scope|base_ref|DRIFT|CIERRE)"
  fi
  if [ "$lbl" = "V1" ]; then v1_invoked="$inv"; fi
  if [ "$lbl" = "V2" ]; then
    if [ "$inv" = "$v1_invoked" ]; then ok "V1 and V2 invoke the identical hook set"
    else no "V1/V2 hook sets differ -- V1: $(echo "$v1_invoked" | tr '\n' ' ')| V2: $(echo "$inv" | tr '\n' ' ')"; fi
  fi
done

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
assert_file "$H/.config/opencode/plugins/iamlazy.ts"        "opencode: plugin installed"
assert_file "$H/.config/opencode/iamlazy-hooks/host-cost.sh" "opencode: hooks installed beside the plugin"
assert_grep "iamlazy-managed" "$H/.config/opencode/plugins/iamlazy.ts" "opencode: plugin carries the marker"
if cmp -s "$H/.config/opencode/plugins/iamlazy.ts" "$SRC/adapters/opencode/iamlazy.ts"; then
  ok "opencode: installed plugin is byte-identical to the repo's"
else no "opencode: installed plugin differs from the repo's"; fi
# Two hosts, one Layer 0: the two copies of the hooks must be the same bytes.
if cmp -s "$H/.config/opencode/iamlazy-hooks/lib.sh" "$H/.claude/iamlazy-hooks/lib.sh"; then
  ok "both hosts run the same lib.sh"
else no "the two hook copies differ (lib.sh)"; fi
assert_file "$H/.iamlazy/DELTAS.md"                 "DELTAS mirror created"
assert_file "$H/.iamlazy/prices.conf"               "price table installed"
assert_file "$H/.iamlazy/hooks_version"             "hooks_version stamped"
if [ "$(cat "$H/.iamlazy/hooks_version" 2>/dev/null)" = "$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null)" ]; then
  ok "hooks_version is this checkout's git SHA"
else no "hooks_version does not match \`git rev-parse --short HEAD\`"; fi

# prices.conf is CONFIG, not a generated mirror. The human edits it when rates
# change, and an installer that overwrites that edit makes the cost figure
# quietly wrong -- the exact failure this project keeps paying for.
printf 'claude-opus-5 99.00 99.00\n' > "$H/.iamlazy/prices.conf"
HOME="$H" "$SRC/install.sh" --tool=both >/dev/null 2>&1
assert_grep "99.00" "$H/.iamlazy/prices.conf" "re-install does NOT clobber your edited price table"

# Model projection: the placeholder must be gone and the configured id present.
# shellcheck source=models.conf
. "$SRC/models.conf"
assert_no_grep "{{MAIN_MODEL}}"   "$H/.claude/commands/iamlazy.md" "no unsubstituted MAIN_MODEL"
assert_no_grep "{{CRITIC_MODEL}}" "$H/.claude/agents/iamlazy-critic.md" "no unsubstituted CRITIC_MODEL"
assert_grep "model: $CC_MAIN_MODEL"   "$H/.claude/commands/iamlazy.md"      "main model projected"
assert_grep "model: $CC_CRITIC_MODEL" "$H/.claude/agents/iamlazy-critic.md" "critic model projected"

# Composition: frontmatter + full body + argument hook, in that order.
assert_grep "What is guaranteed vs what is asked" \
  "$H/.claude/commands/iamlazy.md" "core body composed in"

# Composition, per host. The prompt must never ship an unfilled token, must not
# carry the verification marker, and must tell each host the truth about itself:
# on Claude Code the guarantees are enforced, on OpenCode they are requests.
for f in "$H/.claude/commands/iamlazy.md" "$H/.config/opencode/agents/iamlazy.md"; do
  n="$(basename "$(dirname "$f")")"
  assert_no_grep '{{' "$f" "no unfilled token ($n)"
  assert_no_grep '<!-- hooks:' "$f" "verification marker stays out of the prompt ($n)"
done
assert_grep "Hooks enforce these for you"  "$H/.claude/commands/iamlazy.md"      "claude: guarantees are stated as enforced"
assert_grep "Enter plan mode first" "$H/.claude/commands/iamlazy.md"              "claude: the gate is native plan mode"
assert_grep "plugin enforces these for you" "$H/.config/opencode/agents/iamlazy.md" "opencode: guarantees are stated as enforced by the plugin"
assert_grep "no such mode"                 "$H/.config/opencode/agents/iamlazy.md" "opencode: says plainly there is no bypass refusal"
assert_no_grep "refuses to start under"    "$H/.config/opencode/agents/iamlazy.md" "opencode: never claims the bypass refusal"
assert_grep "plan\` agent first"           "$H/.config/opencode/agents/iamlazy.md" "opencode: the gate is its own plan agent"
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
mkdir -p "$H2/.config/opencode/plugins"
echo "// SOMEONE ELSE'S PLUGIN" > "$H2/.config/opencode/plugins/iamlazy.ts"
HOME="$H2" "$SRC/install.sh" --tool=both >/dev/null 2>&1
assert_grep "SOMEONE ELSE'S FILE" "$H2/.claude/commands/iamlazy.md" "unmarked file is not clobbered"
assert_grep "SOMEONE ELSE'S PLUGIN" "$H2/.config/opencode/plugins/iamlazy.ts" "unmarked plugin is not clobbered"

# ------------------------------------------------------- --model override
# Runs against a COPY of the repo: persist_model rewrites models.conf in place, and a
# test must never mutate the working tree it is testing.
echo
echo "--model override"
CP="$(mktmp)"
cp_repo "$CP"
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

# ------------------------------------------------------- install --check
# What is INSTALLED is what runs, and it drifts from the repo silently. Three
# times in one day a fix was committed, this suite went green, and the machine
# kept running the previous bytes -- once leaving a real run unable to close.
echo
echo "install --check (the drift doctor)"
HC1="$(mktmp)"
HOME="$HC1" "$SRC/install.sh" --tool=both >/dev/null 2>&1
if HOME="$HC1" "$SRC/install.sh" --check >/dev/null 2>&1; then ok "--check passes right after an install"
else no "--check fails on a machine the installer just set up"; fi

printf '\n# drifted\n' >> "$HC1/.claude/iamlazy-hooks/flush-run.sh"
checkout="$(HOME="$HC1" "$SRC/install.sh" --check 2>&1)"; check_rc=$?
if [ "$check_rc" -eq 0 ]; then no "--check missed a hook that differs from the repo"
else
  case "$checkout" in
    *flush-run.sh*) ok "--check catches a drifted hook and names it" ;;
    *) no "--check failed without naming the drifted hook" ;;
  esac
fi
# It reports; it never repairs. A checker that silently fixes things is one you
# stop reading, and the repair belongs to the installer.
assert_grep '# drifted' "$HC1/.claude/iamlazy-hooks/flush-run.sh" "--check reports, never repairs"

# A hook on disk that nobody invokes is a file, not a guarantee.
HC2="$(mktmp)"
HOME="$HC2" "$SRC/install.sh" --tool=claude >/dev/null 2>&1
python3 - "$HC2/.claude/settings.json" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["hooks"]["Stop"]=[]
json.dump(d,open(p,"w"))
PY
if HOME="$HC2" "$SRC/install.sh" --check >/dev/null 2>&1; then
  no "--check missed an installed hook that is no longer registered"
else ok "--check catches an installed hook that is no longer registered"; fi

# ---------------------------------------------------------------- uninstall
echo
echo "uninstall"
printf '{"probe":"user data"}\n' > "$H/.iamlazy/runs.jsonl"
HOME="$H" "$SRC/uninstall.sh" >/dev/null 2>&1
assert_absent "$H/.claude/commands/iamlazy.md"      "claude command removed"
assert_absent "$H/.claude/agents/iamlazy-critic.md" "claude critic removed"
assert_absent "$H/.config/opencode/agents/iamlazy.md" "opencode primary removed"
assert_absent "$H/.config/opencode/plugins/iamlazy.ts" "opencode plugin removed"
if [ -d "$H/.config/opencode/iamlazy-hooks" ]; then no "opencode hook dir removed"
else ok "opencode hook dir removed"; fi
assert_absent "$H/.iamlazy/DELTAS.md"               "DELTAS mirror removed"
assert_absent "$H/.iamlazy/hooks_version"           "hooks_version stamp removed"
assert_grep "user data" "$H/.iamlazy/runs.jsonl"    "runs.jsonl preserved (invariant)"

# Uninstall must refuse to remove a file that is not ours.
HOME="$H2" "$SRC/uninstall.sh" >/dev/null 2>&1
assert_grep "SOMEONE ELSE'S FILE" "$H2/.claude/commands/iamlazy.md" "unmarked file survives uninstall"
assert_grep "SOMEONE ELSE'S PLUGIN" "$H2/.config/opencode/plugins/iamlazy.ts" "unmarked plugin survives uninstall"

# ------------------------------------------------------ install: opencode-v2
# V1 and V2 are mutually exclusive shapes at the same plugin path: the daemon
# auto-discovers every loose file in plugins/, so leaving the other version's
# file behind means it tries to load both. bun is a hard requirement here,
# same as the V1 adapter's own bun-test section below -- not skipped when
# missing, because a translator nobody built is a false green.
echo
echo "install --tool=opencode-v2"
if command -v bun >/dev/null 2>&1; then
  ok "bun available: $(bun --version)"
  V2H="$(mktmp)"
  if v2out="$(HOME="$V2H" "$SRC/install.sh" --tool=opencode-v2 2>&1)"; then
    ok "opencode-v2 install succeeds"
  else
    no "opencode-v2 install failed"
    printf '%s\n' "$v2out" | tail -20 >&2
  fi
  assert_file   "$V2H/.config/opencode/plugins/iamlazy.js"        "opencode-v2: bundled plugin installed"
  assert_absent "$V2H/.config/opencode/plugins/iamlazy.ts"        "opencode-v2: no V1 adapter shape alongside it"
  assert_absent "$V2H/.config/opencode/commands/iamlazy.md"       "opencode-v2: no duplicate /iamlazy command (the plugin registers it)"
  assert_file   "$V2H/.config/opencode/commands/iamlazy-review.md" "opencode-v2: /iamlazy-review is still a plain command"
  assert_file   "$V2H/.config/opencode/agents/iamlazy.md"         "opencode-v2: primary agent installed"
  assert_file   "$V2H/.config/opencode/agents/iamlazy-critic.md"  "opencode-v2: critic agent installed"
  assert_file   "$V2H/.config/opencode/iamlazy-hooks/host-cost.sh" "opencode-v2: hooks installed beside the plugin"
  # bun build strips top-level comments, including the marker -- build.sh
  # re-adds it so write_file/uninstall.sh can still tell this file is ours.
  assert_grep "iamlazy-managed" "$V2H/.config/opencode/plugins/iamlazy.js" "opencode-v2: plugin carries the marker"
  assert_no_grep '"@opencode/plugin"' "$V2H/.config/opencode/plugins/iamlazy.js" "opencode-v2: bundle has no unresolved import left"

  if HOME="$V2H" "$SRC/install.sh" --check >/dev/null 2>&1; then ok "--check passes right after an opencode-v2 install"
  else no "--check fails on a machine opencode-v2 just set up"; fi

  # Switching hosts on the SAME machine must never leave two adapter shapes,
  # in either direction.
  HOME="$V2H" "$SRC/install.sh" --tool=opencode >/dev/null 2>&1
  assert_file   "$V2H/.config/opencode/plugins/iamlazy.ts"   "switch to V1: adapter written"
  assert_absent "$V2H/.config/opencode/plugins/iamlazy.js"   "switch to V1: V2's bundle removed"
  assert_file   "$V2H/.config/opencode/commands/iamlazy.md"  "switch to V1: command file restored"

  HOME="$V2H" "$SRC/install.sh" --tool=opencode-v2 >/dev/null 2>&1
  assert_file   "$V2H/.config/opencode/plugins/iamlazy.js"   "switch back to V2: bundle written"
  assert_absent "$V2H/.config/opencode/plugins/iamlazy.ts"   "switch back to V2: V1's adapter removed"
  assert_absent "$V2H/.config/opencode/commands/iamlazy.md"  "switch back to V2: command file removed again"

  HOME="$V2H" "$SRC/uninstall.sh" >/dev/null 2>&1
  assert_absent "$V2H/.config/opencode/plugins/iamlazy.js"   "uninstall: V2 bundle removed"
  if [ -d "$V2H/.config/opencode/iamlazy-hooks" ]; then no "uninstall: opencode-v2 hook dir removed"
  else ok "uninstall: opencode-v2 hook dir removed"; fi
else
  no "bun is required to install/test OpenCode V2 and was not found (https://bun.sh); skipping would be a false green"
fi

# --tool=opencode-v2 must refuse cleanly without a real checkout (curl|bash
# has no adapters/opencode-v2/package.json to build from). This check fires
# before bun is even probed, so it needs neither bun nor network to test, and
# runs unconditionally.
NOGIT="$(mktmp)"
cp_repo "$NOGIT"
NOGITH="$(mktmp)"
if v2refusal="$(HOME="$NOGITH" "$NOGIT/install.sh" --tool=opencode-v2 2>&1)"; then
  no "opencode-v2 without a git checkout should refuse, not succeed"
else
  case "$v2refusal" in
    *"checkout clonado"*) ok "opencode-v2 refuses cleanly without a git checkout, and says why" ;;
    *) no "opencode-v2 refused without a git checkout, but did not explain why" ;;
  esac
fi

# ------------------------------------------------------- layer 0 (hooks)
# The hook suite is a separate file because it tests runtime decisions, not
# install mechanics. Running it here means one command still covers everything.
echo
echo "layer 0 (delegating to test-hooks.sh)"
#
# Run under BOTH locales, and print the failing assertions instead of a summary
# line. Both halves of that come from the same incident: the close-by-banner
# regex used `\xe2\x94\x80`, which BSD grep honours under LC_ALL=C and silently
# does not under UTF-8 -- so the path was dead wherever the hooks actually run
# while CI's C locale went green. And when it finally did fail, this delegation
# reported one opaque line, so `main` stayed red for nine days.
#
# The UTF-8 locale is DISCOVERED, not assumed. Asking for one the system does
# not have makes bash fall back to C without failing, which would turn this
# whole matrix into decoration -- the suite would report two locales and have
# tested one, which is the same class of false green the regex bug lived in.
UTF8_LOCALE=""
for cand in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if locale -a 2>/dev/null | grep -qix "$cand"; then UTF8_LOCALE="$cand"; break; fi
done
if [ -n "$UTF8_LOCALE" ]; then
  ok "UTF-8 locale for the matrix: $UTF8_LOCALE"
else
  no "no UTF-8 locale on this system: the close-banner path cannot be tested where it actually runs"
fi

if [ -x "$SRC/test-hooks.sh" ]; then
  for loc in C ${UTF8_LOCALE:-}; do
    # Only stderr is captured: the failing assertions go there, and so does
    # anything a program the suite invoked complained about. Filtering the
    # merged output down to `FAIL` lines was hiding the second half -- when
    # git refused to commit for want of an identity, CI reported six wrong
    # numbers and swallowed the `Author identity unknown` that explained them.
    if hookerr="$(LC_ALL="$loc" "$SRC/test-hooks.sh" 2>&1 >/dev/null)"; then
      ok "test-hooks.sh passes under LC_ALL=$loc"
    else
      no "test-hooks.sh fails under LC_ALL=$loc"
      printf '%s\n' "$hookerr" | head -40 >&2
    fi
  done
else
  no "test-hooks.sh missing or not executable"
fi

# ------------------------------------------------ opencode adapter (bun test)
echo
echo "opencode adapter (delegating to bun test)"
# The adapter runs inside OpenCode's Bun, so Bun is what exercises it: each test
# feeds a real OpenCode event to the INSTALLED plugin and asserts what the REAL
# hooks did on disk -- no mocks of Layer 0. Bun is not optional here and this is
# not skipped when it is missing: a translator nobody ran, reported as green, is
# the false green this suite exists to refuse.
if command -v bun >/dev/null 2>&1; then
  ok "bun available: $(bun --version)"
  if adout="$(cd "$SRC" && bun test adapters/opencode/iamlazy.test.ts 2>&1)"; then
    ok "adapter translation suite passes ($(printf '%s\n' "$adout" | grep -Eo '[0-9]+ pass' | head -1))"
  else
    no "adapter translation suite fails (bun test)"
    printf '%s\n' "$adout" | grep -E '✗|\(fail\)|error' >&2
  fi
else
  no "bun is required to test the OpenCode adapter and was not found (https://bun.sh); skipping would be a false green"
fi

# --------------------------------------------- opencode-v2 adapter (bun test)
echo
echo "opencode-v2 adapter (delegating to bun test)"
# Same standard as V1's suite just above: bun is a hard requirement, never
# silently skipped -- a translator nobody ran, reported as green, is the
# false green this whole section exists to refuse, on either adapter version.
# The install --tool=opencode-v2 section earlier in this file already built
# dist/iamlazy.js when bun was available; this only re-checks it exists
# rather than rebuilding, so a stale bundle left by hand still gets tested
# against, not silently skipped past.
if command -v bun >/dev/null 2>&1; then
  if [ -f "$SRC/adapters/opencode-v2/dist/iamlazy.js" ]; then
    if adout="$(cd "$SRC/adapters/opencode-v2" && bun test iamlazy.test.ts 2>&1)"; then
      ok "opencode-v2 adapter translation suite passes ($(printf '%s\n' "$adout" | grep -Eo '[0-9]+ pass' | head -1))"
    else
      no "opencode-v2 adapter translation suite fails (bun test)"
      printf '%s\n' "$adout" | grep -E '✗|\(fail\)|error' >&2
    fi
  else
    no "adapters/opencode-v2/dist/iamlazy.js missing -- the install --tool=opencode-v2 section above should have built it"
  fi
else
  no "bun is required to test the OpenCode V2 adapter and was not found (https://bun.sh); skipping would be a false green"
fi

# ------------------------------------------------------ layer 0 by default
# Hooks are NOT opt-in: a guarantee that is easy to skip gets skipped, and the
# failure is silent. These assert that a plain install both installs AND
# registers them, without damaging whatever the user already had.
echo
echo "install: layer 0 is on by default"
H5="$(mktmp)"
mkdir -p "$H5/.claude"
cat > "$H5/.claude/settings.json" <<'JSON'
{"theme":"dark-ansi","permissions":{"defaultMode":"auto"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/user/own.sh"}]}]}}
JSON
HOME="$H5" "$SRC/install.sh" --tool=claude >/dev/null 2>&1

assert_file "$H5/.claude/iamlazy-hooks/guard-agent.sh"   "hooks: guard installed"
assert_file "$H5/.claude/iamlazy-hooks/flush-run.sh"     "hooks: flush installed"
assert_file "$H5/.claude/iamlazy-hooks/end-run.sh"       "hooks: session-end installed"
assert_file "$H5/.claude/iamlazy-hooks/subagent-done.sh" "hooks: subagent-done installed"
assert_file "$H5/.claude/iamlazy-hooks/merge-settings.sh" "hooks: merge helper installed"
if [ -x "$H5/.claude/iamlazy-hooks/guard-agent.sh" ]; then ok "hooks are executable"
else no "hooks are executable"; fi

# Registered, not merely copied.
assert_grep "iamlazy-hooks/open-run.sh"   "$H5/.claude/settings.json" "registered: UserPromptSubmit"
assert_grep "iamlazy-hooks/guard-agent.sh" "$H5/.claude/settings.json" "registered: PreToolUse"
assert_grep "iamlazy-hooks/track-edit.sh"  "$H5/.claude/settings.json" "registered: PostToolUse"
assert_grep "iamlazy-hooks/flush-run.sh"   "$H5/.claude/settings.json" "registered: Stop"
assert_grep "iamlazy-hooks/end-run.sh"     "$H5/.claude/settings.json" "registered: SessionEnd"
assert_grep "iamlazy-hooks/subagent-done.sh" "$H5/.claude/settings.json" "registered: SubagentStop"
# Matchers are anchored: a bare `Agent|Task` also fires on TaskOutput/TaskStop,
# and `Edit|Write` on NotebookEdit. The edit matcher is widened on purpose --
# an edit the trace never sees is a hole in Guarantee 3.
assert_grep '\^(Agent|Task)\$' "$H5/.claude/settings.json" "sub-agent matcher is anchored"
assert_grep 'MultiEdit' "$H5/.claude/settings.json" "edit matcher covers MultiEdit/NotebookEdit"

# The user's own configuration must survive untouched.
assert_grep "/user/own.sh" "$H5/.claude/settings.json" "user's own hook survives install"
assert_grep "dark-ansi"    "$H5/.claude/settings.json" "unrelated settings survive install"

# Idempotent: installing twice must not duplicate entries.
HOME="$H5" "$SRC/install.sh" --tool=claude >/dev/null 2>&1
n_open="$(grep -c "iamlazy-hooks/open-run.sh" "$H5/.claude/settings.json")"
if [ "$n_open" = "1" ]; then ok "re-install does not duplicate hook entries"
else no "re-install duplicated hook entries (found $n_open)"; fi

# --no-hooks is the escape hatch, and it must really skip.
H6="$(mktmp)"
HOME="$H6" "$SRC/install.sh" --tool=claude --no-hooks >/dev/null 2>&1
if [ -d "$H6/.claude/iamlazy-hooks" ]; then no "--no-hooks skips layer 0"
else ok "--no-hooks skips layer 0"; fi
H7="$(mktmp)"
HOME="$H7" "$SRC/install.sh" --tool=opencode --no-hooks >/dev/null 2>&1
if [ -f "$H7/.config/opencode/plugins/iamlazy.ts" ] || [ -d "$H7/.config/opencode/iamlazy-hooks" ]; then
  no "--no-hooks skips the OpenCode plugin and its hooks"
else ok "--no-hooks skips the OpenCode plugin and its hooks"; fi

# Uninstall unregisters, and again leaves the user's own hooks alone.
HOME="$H5" "$SRC/uninstall.sh" >/dev/null 2>&1
assert_no_grep "iamlazy-hooks" "$H5/.claude/settings.json" "uninstall unregisters the hooks"
assert_grep "/user/own.sh"     "$H5/.claude/settings.json" "user's own hook survives uninstall"
assert_grep "dark-ansi"        "$H5/.claude/settings.json" "unrelated settings survive uninstall"
if [ -d "$H5/.claude/iamlazy-hooks" ]; then no "uninstall removes the hook dir"
else ok "uninstall removes the hook dir"; fi

# ------------------------------------------------------------------ report
echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
