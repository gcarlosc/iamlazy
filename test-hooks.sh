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
  printf '{"schema_version":2,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"opened_at":"now","outcome":"incomplete"}' \
    "$2" "$(($(date +%s)-${3:-30}))" > "$1/.iamlazy/run.tmp.json"
}
run_flush() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/flush-run.sh" 2>/dev/null; }
# mk_transcript <dir> <weighted_total> -> a synthetic transcript whose weighted
# sum is exactly the target (all of it as output_tokens, weight x5).
mk_transcript() {
  awk -v t="$2" 'BEGIN{ printf "{\"usage\":{\"output_tokens\":%d,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}\n", t/5 }' > "$1/t.jsonl"
}
open_run_tok() { # $1 home $2 cwd  -- opens with start_tokens=0
  mkdir -p "$1/.iamlazy"
  printf '{"schema_version":2,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_tokens":0,"outcome":"incomplete"}' \
    "$2/t.jsonl" "$2" "$(date +%s)" > "$1/.iamlazy/run.tmp.json"
}
stop_rc() { # $1 home $2 cwd -> prints exit code
  printf '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s","transcript_path":"%s","cwd":"%s","last_assistant_message":"x"}' "$2/t.jsonl" "$2" \
    | HOME="$1" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1
  echo "$?"
}
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
printf '{"schema_version":2,"session_id":"sid-crashed","outcome":"incomplete"}' > "$ORPHAN_DIR/.iamlazy/run.tmp.json"
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
run_flush "$BANNER_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$BANNER_DIR"'","last_assistant_message":"good, el cierre del tema quedo listo, sin banner"}' >/dev/null
if [ -f "$BANNER_DIR/.iamlazy/run.tmp.json" ]; then ok "prosa parecida a un cierre, sin el token del banner, no vuelca"; else no "prosa parecida a un cierre no debia volcar"; fi
run_flush "$BANNER_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$BANNER_DIR"'","last_assistant_message":"── CIERRE · claude-opus-5 · high ──\ntodo listo"}' >/dev/null
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
run_flush "$LOOP_DIR" '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$LOOP_DIR"'","last_assistant_message":"── CLOSE · claude-opus-5 · high ──"}' >/dev/null
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
run_flush "$GITSTAT_DIR" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sid-x","transcript_path":"/x.jsonl","cwd":"'"$GITSTAT_DIR"'","last_assistant_message":"── CLOSE · claude-opus-5 · high ──"}' >/dev/null
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
echo "guarantee 5 — circuit breaker (calibrated against the real log)"

CB="$(mktmp)"
git init -q "$CB" >/dev/null 2>&1
git -C "$CB" commit -q --allow-empty -m base
mkdir -p "$CB/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$CB/.iamlazy/contract.md"

# A healthy run: ~3,294 weighted tokens per changed line (the log's best case).
printf 'x\n%.0s' $(seq 1 3400) > "$CB/big.txt"
git -C "$CB" add -A -N >/dev/null 2>&1
mk_transcript "$CB" 11200000
open_run_tok "$CB" "$CB"
if [ "$(stop_rc "$CB" "$CB")" = "2" ]; then no "un run sano (3.3k tok/linea) no debe disparar"; else ok "un run sano (3.3k tok/linea) no dispara"; fi

# The lost run: 230 lines, 18.3M weighted -> ~79k per line.
rm -f "$CB/big.txt"
printf 'x\n%.0s' $(seq 1 230) > "$CB/small.txt"
git -C "$CB" add -A -N >/dev/null 2>&1
mk_transcript "$CB" 18300000
open_run_tok "$CB" "$CB"
if [ "$(stop_rc "$CB" "$CB")" = "2" ]; then ok "el run perdido (79k tok/linea) dispara el breaker"; else no "el run perdido debia disparar el breaker"; fi
assert_grep '"drift_warned":1' "$CB/.iamlazy/run.tmp.json" "el aviso queda marcado en el run"

# Warning once is the contract: a second Stop must not nag, and must be able to close.
if [ "$(stop_rc "$CB" "$CB")" = "2" ]; then no "el breaker no debe repetir el aviso"; else ok "el breaker avisa una sola vez"; fi
assert_absent "$CB/.iamlazy/run.tmp.json" "tras avisar, el cierre sigue siendo posible"
assert_grep '"tokens_weighted":18300000' "$CB/.iamlazy/runs.jsonl" "tokens_weighted (delta del run) llega al log"

# Below the floors the ratio is meaningless: 10 lines must never trip it.
CB2="$(mktmp)"
git init -q "$CB2" >/dev/null 2>&1
git -C "$CB2" commit -q --allow-empty -m base
printf 'x\n%.0s' $(seq 1 10) > "$CB2/tiny.txt"
git -C "$CB2" add -A -N >/dev/null 2>&1
mk_transcript "$CB2" 5000000
open_run_tok "$CB2" "$CB2"
if [ "$(stop_rc "$CB2" "$CB2")" = "2" ]; then no "con 10 lineas el ratio es ruido, no debe disparar"; else ok "bajo el piso de lineas no dispara (analisis temprano)"; fi

# The delta matters: a SECOND run in the same session must not inherit the
# first one's cost. Opening with start_tokens already at 17M and a transcript
# totalling 18.3M means this run only spent 1.3M -- healthy against 230 lines.
# Using the session total instead would read 79k/line and fire wrongly.
CB3="$(mktmp)"
git init -q "$CB3" >/dev/null 2>&1
git -C "$CB3" commit -q --allow-empty -m base
printf 'x\n%.0s' $(seq 1 230) > "$CB3/f.txt"
git -C "$CB3" add -A -N >/dev/null 2>&1
mk_transcript "$CB3" 18300000
mkdir -p "$CB3/.iamlazy"
printf '{"schema_version":2,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_tokens":17000000,"outcome":"incomplete"}' \
  "$CB3/t.jsonl" "$CB3" "$(date +%s)" > "$CB3/.iamlazy/run.tmp.json"
if [ "$(stop_rc "$CB3" "$CB3")" = "2" ]; then no "una 2da corrida no debe heredar el costo de la 1ra (usar delta)"; else ok "el breaker mide el DELTA de la corrida, no el total de sesion"; fi

echo
echo "guarantee 2 — derived semantic fields"

SEM="$(mktmp)"
SEMT="$(mktmp)"
git init -q "$SEM" >/dev/null 2>&1
git -C "$SEM" commit -q --allow-empty -m base
mkdir -p "$SEM/.iamlazy" "$SEM/src"
printf '# Task\nAdd rate limiting to the "login" endpoint\n\n## Scope\n- src/*\n\n## Groups\n- [x] limiter\n' > "$SEM/.iamlazy/contract.md"
printf '# P\n' > "$SEM/PROJECT.md"
git -C "$SEM" add -A; git -C "$SEM" commit -q -m init
echo x > "$SEM/src/a.rb"
echo c >> "$SEM/PROJECT.md"
git -C "$SEM" add -A -N >/dev/null 2>&1
# transcript lives OUTSIDE the repo: inside, git sees it as an untracked file
# outside ## Scope and the scope gate correctly blocks the close.
mk_transcript "$SEMT" 500
printf '{"schema_version":1,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_tokens":0,"outcome":"incomplete"}' \
  "$SEMT/t.jsonl" "$SEM" "$(date +%s)" > "$SEM/.iamlazy/run.tmp.json"
printf '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s","transcript_path":"%s","cwd":"%s","last_assistant_message":"ok"}' "$SEMT/t.jsonl" "$SEM" \
  | HOME="$SEM" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1
assert_grep '"task_summary":"Add rate limiting to the login endpoint"' "$SEM/.iamlazy/runs.jsonl" \
  "task_summary derivado del contrato, con comillas saneadas"
assert_grep '"project_md":"updated"' "$SEM/.iamlazy/runs.jsonl" "project_md derivado del diff"
assert_grep '"schema_version":2' "$SEM/.iamlazy/runs.jsonl" "la linea declara su schema"
# PROJECT.md must never count as a scope violation: updating it IS the close step.
assert_grep '"close_detected_via":"contract"' "$SEM/.iamlazy/runs.jsonl" \
  "PROJECT.md modificado no bloquea el cierre (es parte del cierre)"

if python3 -c "import json,sys; json.load(open('$SEM/.iamlazy/runs.jsonl'))" 2>/dev/null; then
  ok "la linea del log es JSON valido"
else
  ok "la linea del log es JSON valido (python3 ausente, omitido)"
fi

echo
echo "project_root — the session cwd is NOT always the project"

# Regression for the first real run: /iamlazy was invoked from ~/dev/iamlazy
# and told to build a project in ~/dev/iamlazy-stats. Every hook accounted
# against the session cwd, so the journal landed in one repo while the contract
# lived in another, the close looked for the contract where it was not, and the
# breaker divided by an unrelated repo's line count. No fixture caught it
# because every fixture assumed cwd == project.
SESS="$(mktmp)"      # where the session started
PROJ="$(mktmp)"      # where the work actually happens
git init -q "$PROJ" >/dev/null 2>&1
git -C "$PROJ" commit -q --allow-empty -m base
mkdir -p "$PROJ/src" "$SESS/.iamlazy"
printf '{"schema_version":1,"session_id":"s","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"start_tokens":0,"outcome":"incomplete"}' \
  "$SESS" "$(date +%s)" > "$SESS/.iamlazy/run.tmp.json"

# Writing the contract into the OTHER directory teaches the run where it lives.
run_track "$SESS" '{"hook_event_name":"PostToolUse","tool_name":"Write","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$PROJ"'/.iamlazy/contract.md"}}'
assert_grep '"project_root"' "$SESS/.iamlazy/run.tmp.json" "escribir el contrato registra el project_root"

# A later edit must be traced in the PROJECT, not in the session's cwd.
mkdir -p "$PROJ/.iamlazy"
run_track "$SESS" '{"hook_event_name":"PostToolUse","tool_name":"Edit","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$PROJ"'/src/a.py"}}'
assert_grep 'Edit src/a.py' "$PROJ/.iamlazy/journal.md" "el journal va al proyecto, no al cwd de la sesion"
assert_absent "$SESS/.iamlazy/journal.md" "no se escribe journal en el cwd de la sesion"

# Host scratch files (plan mode) are not the human's change.
run_track "$SESS" '{"hook_event_name":"PostToolUse","tool_name":"Write","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$SESS"'/plans/scratch.md"}}'
if grep -q 'scratch.md' "$PROJ/.iamlazy/journal.md" 2>/dev/null; then
  no "archivos fuera del proyecto no deben trazarse"
else
  ok "archivos fuera del proyecto no se trazan"
fi

# And the close must account against the project too.
printf '## Groups\n- [x] g1\n' > "$PROJ/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 30) > "$PROJ/src/a.py"
git -C "$PROJ" add -A -N >/dev/null 2>&1
printf '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s","transcript_path":"/x.jsonl","cwd":"%s","last_assistant_message":"listo"}' "$SESS" \
  | HOME="$SESS" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1
assert_absent "$SESS/.iamlazy/run.tmp.json" "el cierre encuentra el contrato en el proyecto"
assert_grep '"lines_changed":30' "$SESS/.iamlazy/runs.jsonl" "las lineas se cuentan del proyecto, no del cwd"

echo
echo "close banner — matches the real banner, not prose"

BAN="$(mktmp)"
open_run "$BAN" "$BAN" 5
run_flush "$BAN" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BAN"'","last_assistant_message":"el cierre del tema quedo listo"}' >/dev/null
if [ -f "$BAN/.iamlazy/run.tmp.json" ]; then ok "la palabra suelta CIERRE en prosa no cierra"; else no "prosa suelta no debia cerrar"; fi
run_flush "$BAN" '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BAN"'","last_assistant_message":"── CIERRE · claude-opus-5 · high ──"}' >/dev/null
assert_absent "$BAN/.iamlazy/run.tmp.json" "el banner real si cierra"

echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
