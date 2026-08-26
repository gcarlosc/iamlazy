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

open_run() { # $1 home $2 cwd $3 start_epoch_delta_seconds
  mkdir -p "$1/.iamlazy"
  printf '{"schema_version":1,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"opened_at":"now","outcome":"incomplete"}' \
    "$2" "$(($(date +%s)-${3:-30}))" > "$1/.iamlazy/run.tmp.json"
}
run_flush() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/flush-run.sh" 2>/dev/null; }
run_track() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/track-edit.sh" 2>/dev/null; }
run_open()  { printf '%s' "$2" | HOME="$1" "$SRC/hooks/open-run.sh" 2>/dev/null; }

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
# assert_grep <pattern> <file> <description>
assert_grep() {
  if [ -f "$2" ] && grep -q "$1" "$2" 2>/dev/null; then ok "$3"
  else no "$3 (no match for '$1' in $2)"; fi
}
# assert_absent <path> <description>
assert_absent() {
  if [ -f "$1" ]; then no "$2 (still present: $1)"; else ok "$2"; fi
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
echo "guarantee 7 — session identified at open"

OPEN_DIR="$(mktmp)"
run_open "$OPEN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-open","transcript_path":"/x.jsonl","cwd":"'"$OPEN_DIR"'","prompt":"hola, no es una tarea"}'
if [ -f "$OPEN_DIR/.iamlazy/run.tmp.json" ]; then no "un prompt normal no abre corrida"; else ok "un prompt normal no abre corrida"; fi

run_open "$OPEN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-open","transcript_path":"/x.jsonl","cwd":"'"$OPEN_DIR"'","prompt":"/iamlazy arreglar el login"}'
assert_grep '"session_id":"sid-open"' "$OPEN_DIR/.iamlazy/run.tmp.json" "/iamlazy abre corrida con el session_id real"
assert_grep '"outcome":"incomplete"' "$OPEN_DIR/.iamlazy/run.tmp.json" "el tmp arranca incomplete"

ORPHAN_DIR="$(mktmp)"
mkdir -p "$ORPHAN_DIR/.iamlazy"
printf '{"schema_version":1,"session_id":"sid-crashed","outcome":"incomplete"}' > "$ORPHAN_DIR/.iamlazy/run.tmp.json"
run_open "$ORPHAN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-new","transcript_path":"/y.jsonl","cwd":"'"$ORPHAN_DIR"'","prompt":"/iamlazy otra tarea"}'
assert_grep 'sid-crashed' "$ORPHAN_DIR/.iamlazy/runs.jsonl" "corrida huerfana recuperada a runs.jsonl"
assert_grep 'sid-new' "$ORPHAN_DIR/.iamlazy/run.tmp.json" "el tmp nuevo tiene la sesion correcta, no la huerfana"

echo
echo "guarantee 2 — the log exists (mechanical skeleton)"

MID_DIR="$(mktmp)"
open_run "$MID_DIR" "$MID_DIR" 10
out=$(run_flush "$MID_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$MID_DIR"'","last_assistant_message":"trabajando en el paso 2..."}')
if [ -f "$MID_DIR/.iamlazy/run.tmp.json" ]; then ok "turno intermedio no vuelca"; else no "turno intermedio no vuelca (volco de mas)"; fi

BANNER_DIR="$(mktmp)"
open_run "$BANNER_DIR" "$BANNER_DIR" 10
run_flush "$BANNER_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$BANNER_DIR"'","last_assistant_message":"good, todo listo. algo random que no es el cierre real"}' >/dev/null
if [ -f "$BANNER_DIR/.iamlazy/run.tmp.json" ]; then ok "prosa parecida a un cierre, sin el token del banner, no vuelca"; else no "prosa parecida a un cierre no debia volcar"; fi
run_flush "$BANNER_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$BANNER_DIR"'","last_assistant_message":"-- A5 -- CIERRE --\ntodo listo"}' >/dev/null
assert_absent "$BANNER_DIR/.iamlazy/run.tmp.json" "cierre via banner borra el tmp"
assert_grep '"close_detected_via":"banner"' "$BANNER_DIR/.iamlazy/runs.jsonl" "cierre via banner queda registrado"

CONTRACT_DIR="$(mktmp)"
open_run "$CONTRACT_DIR" "$CONTRACT_DIR" 10
mkdir -p "$CONTRACT_DIR/.iamlazy"
printf '## Grupos\n- [x] grupo 1\n- [ ] grupo 2\n' > "$CONTRACT_DIR/.iamlazy/contract.md"
run_flush "$CONTRACT_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$CONTRACT_DIR"'","last_assistant_message":"grupo 1 listo"}' >/dev/null
if [ -f "$CONTRACT_DIR/.iamlazy/run.tmp.json" ]; then ok "contrato con grupo pendiente no vuelca"; else no "contrato con grupo pendiente no debia volcar"; fi
sed -e 's/\[ \] grupo 2/[x] grupo 2/' "$CONTRACT_DIR/.iamlazy/contract.md" > "$CONTRACT_DIR/.iamlazy/contract.md.tmp" && mv "$CONTRACT_DIR/.iamlazy/contract.md.tmp" "$CONTRACT_DIR/.iamlazy/contract.md"
run_flush "$CONTRACT_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$CONTRACT_DIR"'","last_assistant_message":"listo"}' >/dev/null
assert_absent "$CONTRACT_DIR/.iamlazy/run.tmp.json" "todos los grupos resueltos cierra"
assert_grep '"close_detected_via":"contract"' "$CONTRACT_DIR/.iamlazy/runs.jsonl" "cierre via contrato queda registrado"

LOOP_DIR="$(mktmp)"
open_run "$LOOP_DIR" "$LOOP_DIR" 10
run_flush "$LOOP_DIR" '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$LOOP_DIR"'","last_assistant_message":"-- A5 -- CLOSE --"}' >/dev/null
if [ -f "$LOOP_DIR/.iamlazy/run.tmp.json" ]; then ok "stop_hook_active=true nunca vuelca (evita el loop)"; else no "stop_hook_active=true no debia volcar"; fi

echo
echo "guarantee 2 — real payloads and real git"

SELFCTRL_DIR="$(mktmp)"
open_run "$SELFCTRL_DIR" "$SELFCTRL_DIR" 10
REAL_STOP='{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$SELFCTRL_DIR"'","last_assistant_message":"Garantia 1 de 7, probada de punta a punta. Agent Explore fue RECHAZADO por el hook."}'
run_flush "$SELFCTRL_DIR" "$REAL_STOP" >/dev/null
if [ -f "$SELFCTRL_DIR/.iamlazy/run.tmp.json" ]; then ok "un reporte de progreso real (no cierre) no dispara el flush"; else no "un reporte de progreso disparo el flush por error (falso positivo)"; fi

GITSTAT_DIR="$(mktmp)"
git init -q "$GITSTAT_DIR" >/dev/null 2>&1
git -C "$GITSTAT_DIR" commit -q --allow-empty -m base
echo "existente" > "$GITSTAT_DIR/a.txt"; git -C "$GITSTAT_DIR" add -A; git -C "$GITSTAT_DIR" commit -q -m a
echo "cambio" >> "$GITSTAT_DIR/a.txt"
printf 'x\n%.0s' $(seq 1 50) > "$GITSTAT_DIR/nuevo.txt"
open_run "$GITSTAT_DIR" "$GITSTAT_DIR" 5
run_flush "$GITSTAT_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$GITSTAT_DIR"'","last_assistant_message":"-- A5 -- CLOSE --"}' >/dev/null
assert_grep '"files_changed":2' "$GITSTAT_DIR/.iamlazy/runs.jsonl" "files_changed coincide con git diff --stat -N"
assert_grep '"lines_changed":51' "$GITSTAT_DIR/.iamlazy/runs.jsonl" "lines_changed ve el archivo NUEVO (el piso viejo no podia)"


echo
echo "guarantee 3 — unbiased trace"

TRACE_DIR="$(mktmp)"
open_run "$TRACE_DIR" "$TRACE_DIR" 5
run_track "$TRACE_DIR" '{"hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"'"$TRACE_DIR"'","tool_input":{"file_path":"'"$TRACE_DIR"'/src/foo.ts"}}'
assert_grep 'Edit src/foo.ts' "$TRACE_DIR/.iamlazy/journal.md" "un Edit en corrida activa se traza"

NOTRACE_DIR="$(mktmp)"
run_track "$NOTRACE_DIR" '{"hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"'"$NOTRACE_DIR"'","tool_input":{"file_path":"'"$NOTRACE_DIR"'/src/foo.ts"}}'
assert_absent "$NOTRACE_DIR/.iamlazy/journal.md" "sin corrida activa no traza nada"

SELFEDIT_DIR="$(mktmp)"
open_run "$SELFEDIT_DIR" "$SELFEDIT_DIR" 5
run_track "$SELFEDIT_DIR" '{"hook_event_name":"PostToolUse","tool_name":"Write","cwd":"'"$SELFEDIT_DIR"'","tool_input":{"file_path":"'"$SELFEDIT_DIR"'/.iamlazy/contract.md"}}'
if [ -f "$SELFEDIT_DIR/.iamlazy/journal.md" ]; then no "el harness escribiendo su propio .iamlazy/ no debia trazarse"; else ok "el harness escribiendo su propio .iamlazy/ no se traza"; fi

echo
echo "guarantee 4 — scope ledger (real git)"

SCOPE_DIR="$(mktmp)"
git init -q "$SCOPE_DIR" >/dev/null 2>&1
git -C "$SCOPE_DIR" commit -q --allow-empty -m base
mkdir -p "$SCOPE_DIR/src"
echo base > "$SCOPE_DIR/src/a.ts"; git -C "$SCOPE_DIR" add -A; git -C "$SCOPE_DIR" commit -q -m init
mkdir -p "$SCOPE_DIR/.iamlazy"
printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n' > "$SCOPE_DIR/.iamlazy/contract.md"

echo cambio >> "$SCOPE_DIR/src/a.ts"
open_run "$SCOPE_DIR" "$SCOPE_DIR" 5
run_flush "$SCOPE_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$SCOPE_DIR"'","last_assistant_message":"listo"}' >/dev/null
assert_absent "$SCOPE_DIR/.iamlazy/run.tmp.json" "cambio dentro del Scope declarado cierra"

echo fuera > "$SCOPE_DIR/otra_cosa.ts"
git -C "$SCOPE_DIR" add -A -N >/dev/null 2>&1
open_run "$SCOPE_DIR" "$SCOPE_DIR" 5
run_flush "$SCOPE_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$SCOPE_DIR"'","last_assistant_message":"listo"}' >/dev/null
if [ -f "$SCOPE_DIR/.iamlazy/run.tmp.json" ]; then ok "archivo fuera del Scope declarado detiene el cierre"; else no "un desvio no declarado cerro igual (deberia frenar)"; fi

printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n- otra_cosa.ts\n' > "$SCOPE_DIR/.iamlazy/contract.md"
run_flush "$SCOPE_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$SCOPE_DIR"'","last_assistant_message":"listo"}' >/dev/null
assert_absent "$SCOPE_DIR/.iamlazy/run.tmp.json" "declarar el desvio en Scope desbloquea el cierre"

UNSCOPED_DIR="$(mktmp)"
git init -q "$UNSCOPED_DIR" >/dev/null 2>&1
git -C "$UNSCOPED_DIR" commit -q --allow-empty -m base
echo x > "$UNSCOPED_DIR/a.txt"
mkdir -p "$UNSCOPED_DIR/.iamlazy"
printf '## Grupos\n- [x] g1\n' > "$UNSCOPED_DIR/.iamlazy/contract.md"
open_run "$UNSCOPED_DIR" "$UNSCOPED_DIR" 5
run_flush "$UNSCOPED_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$UNSCOPED_DIR"'","last_assistant_message":"listo"}' >/dev/null
assert_absent "$UNSCOPED_DIR/.iamlazy/run.tmp.json" "sin seccion Scope declarada, el cierre no se bloquea (unscoped != violacion)"

echo
echo "guarantee 6 — never under a permission bypass"

BYPASS_DIR="$(mktmp)"
run_open "$BYPASS_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BYPASS_DIR"'","permission_mode":"bypassPermissions","prompt":"/iamlazy hacer algo"}'
assert_absent "$BYPASS_DIR/.iamlazy/run.tmp.json" "bypassPermissions no abre corrida"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BYPASS_DIR"'","permission_mode":"bypassPermissions","prompt":"/iamlazy x"}' | HOME="$BYPASS_DIR" "$SRC/hooks/open-run.sh" >/dev/null 2>&1
if [ "$?" = "2" ]; then ok "bypassPermissions bloquea con exit 2"; else no "bypassPermissions debia salir con 2"; fi

NORMAL_DIR="$(mktmp)"
run_open "$NORMAL_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$NORMAL_DIR"'","permission_mode":"default","prompt":"/iamlazy hacer algo"}'
assert_grep '"session_id":"s"' "$NORMAL_DIR/.iamlazy/run.tmp.json" "permission_mode normal abre corrida"

echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
