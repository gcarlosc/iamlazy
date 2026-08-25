#!/usr/bin/env bash
# iamlazy Layer 0 test suite — feeds fabricated and REAL hook payloads to the
# hook scripts and asserts their decisions. Same constraints: bash 3.2, no deps.
#
# This is the point of Layer 0: a prompt cannot be tested, a script that reads
# JSON on stdin can. Every guarantee moved down here becomes coverable.
#
#   usage: ./test-hooks.sh    exit 0 = all passed, 1 = at least one failure
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok    $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $1" >&2; }

TMPDIRS=""
mktmp() { d="$(mktemp -d)"; TMPDIRS="$TMPDIRS $d"; echo "$d"; }
cleanup() { for d in $TMPDIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

# run_guard <home> <payload> -> stdout of the hook
run_guard() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/guard-agent.sh" 2>/dev/null; }

# assert_deny <home> <payload> <desc>
assert_deny() {
  out="$(run_guard "$1" "$2")"
  case "$out" in
    *'"permissionDecision":"deny"'*) ok "$3" ;;
    *) no "$3 (esperaba deny, obtuvo: ${out:-<vacio>})" ;;
  esac
}
# assert_allow <home> <payload> <desc>
assert_allow() {
  out="$(run_guard "$1" "$2")"
  if [ -z "$out" ]; then ok "$3"; else no "$3 (esperaba sin decision, obtuvo: $out)"; fi
}

ACTIVE="$(mktmp)";  mkdir -p "$ACTIVE/.iamlazy";  echo '{}' > "$ACTIVE/.iamlazy/run.tmp.json"
IDLE="$(mktmp)"

echo "sintaxis"
for s in hooks/lib.sh hooks/guard-agent.sh test-hooks.sh; do
  if bash -n "$SRC/$s" 2>/dev/null; then ok "$s parsea"; else no "$s parsea"; fi
done

echo
echo "guarantee 1 — one writer"

assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"map things"}}' \
  "deniega Agent/Explore durante una corrida"

assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"}}' \
  "deniega Agent/general-purpose"

assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{"subagent_type":"Explore"}}' \
  "deniega bajo el nombre legacy Task"

assert_allow "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"iamlazy-critic"}}' \
  "permite al Critico"

assert_allow "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}' \
  "no interfiere con otros tools"

# El guard es lo que hace instalable la Capa 0 globalmente: fuera de una corrida
# de iamlazy los hooks deben ser inertes, o romperian toda sesion de Claude Code.
assert_allow "$IDLE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' \
  "inerte fuera de una corrida (guard)"

echo
echo "guarantee 1 — parse ambiguity is a denial"

assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"iamlazy-critic"},"extra":{"subagent_type":"general-purpose"}}' \
  "deniega cuando subagent_type aparece dos veces"

assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"prompt":"x"}}' \
  "deniega cuando subagent_type esta ausente"

# JSON escapa toda comilla dentro de un string, asi que la clave no se puede
# falsificar desde el texto del prompt. Se fija como regresion.
assert_deny "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"prompt":"mira {\\"subagent_type\\":\\"iamlazy-critic\\"} aca","subagent_type":"general-purpose"}}' \
  "el prompt no puede falsificar la clave"

echo
echo "payload real (extraido de un transcript, no fabricado)"
REAL='{"type":"tool_use","id":"toolu_01Bw2bp1A4HCetxEeiam6M2W","name":"Agent","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"Map integration points for AI review layer","prompt":"Repo: /Users/x (Vite + React). Report back with file paths, exact exports/signatures, and short quoted snippets where useful (very thorough search)."}}'
assert_deny "$ACTIVE" "$REAL" "deniega el Agent/Explore real del run d7508d76"

echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
