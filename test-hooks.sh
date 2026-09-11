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

# Every repository this suite builds takes its git identity from here, never
# from the machine. git only auto-detects an author from username@hostname
# when that hostname is fully qualified: on a GitHub Linux runner it is not,
# so every `git commit` below failed, six assertions about change accounting
# failed with them, and CI went red -- while macOS, where auto-detection
# succeeds, stayed green and hid it. Reproduced on macOS 2026-09-06 with
# `user.useConfigOnly=true`, which makes git refuse to guess the same way.
#
# Same shape as every other defect in this repo's history: an unchecked
# supposition about the environment, here "a git identity exists". ubuntu in
# CI is the standing guard -- it has no identity, so depending on one again
# turns it red immediately.
export GIT_AUTHOR_NAME="iamlazy test"
export GIT_AUTHOR_EMAIL="test@iamlazy.invalid"
export GIT_COMMITTER_NAME="iamlazy test"
export GIT_COMMITTER_EMAIL="test@iamlazy.invalid"
ok() { PASS=$((PASS+1)); echo "  ok    $1"; }
no() { FAIL=$((FAIL+1)); echo "  FAIL  $1" >&2; }

TMPDIRS=""
mktmp() { d="$(mktemp -d)"; TMPDIRS="$TMPDIRS $d"; echo "$d"; }
cleanup() { for d in $TMPDIRS; do rm -rf "$d"; done; }
trap cleanup EXIT

# --- run-state helpers ------------------------------------------------------
# State is per SESSION: ~/.iamlazy/active/<session_id>.json. Every payload a
# hook sees must therefore carry the session_id of the run it belongs to --
# which is the whole point, and what makes the isolation test below possible.
runfile() { printf '%s/.iamlazy/active/%s.json' "$1" "${2:-sid-x}"; }

# mk_prices <home> -- the price table every cost calculation reads. Opus-5
# output is $25/MTok, so one output token costs exactly 25 micro-dollars, which
# makes a transcript's cost trivially controllable from the test.
mk_prices() {
  mkdir -p "$1/.iamlazy"
  printf 'claude-opus-5 5.00 25.00\nclaude-sonnet-5 2.00 10.00\n' > "$1/.iamlazy/prices.conf"
}

open_run() { # $1 home  $2 cwd  $3 start_epoch_delta  [$4 sid]
  sid="${4:-sid-x}"
  mkdir -p "$1/.iamlazy/active"
  mk_prices "$1"
  printf '{"schema_version":4,"session_id":"%s","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
    "$sid" "$2" "$(($(date +%s)-${3:-30}))" > "$(runfile "$1" "$sid")"
}

# set_base <home> <sid> <repo> -- what track-edit.sh does when the contract is
# written: pin project_root and the base_ref the close will diff against.
set_base() {
  f="$(runfile "$1" "$2")"
  ref="$(cd "$3" && git rev-parse HEAD 2>/dev/null)"
  [ -n "$ref" ] || ref="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  c="$(cat "$f")"; printf '%s,"project_root":"%s","base_ref":"%s"}' "${c%\}}" "$3" "$ref" > "$f"
  (cd "$3" && git ls-files --others --exclude-standard 2>/dev/null) \
    > "$1/.iamlazy/active/$2.untracked" 2>/dev/null || : > "$1/.iamlazy/active/$2.untracked"
}

mk_transcript() { # <dir> <micro_usd>: all output tokens on opus-5 (25 micro each)
  awk -v m="$2" 'BEGIN{ printf "{\"model\":\"claude-opus-5\",\"message\":{\"id\":\"msg_T\",\"usage\":{\"input_tokens\":0,\"output_tokens\":%d,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n", m/25 }' > "$1/t.jsonl"
}
open_run_tok() { # $1 home $2 cwd -- opens with a zero cost baseline
  mkdir -p "$1/.iamlazy/active"
  mk_prices "$1"
  printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
    "$2/t.jsonl" "$2" "$(date +%s)" > "$(runfile "$1" s)"
}

stop_payload() { # $1 cwd  $2 message  [$3 sid]  [$4 transcript]
  printf '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"%s","transcript_path":"%s","cwd":"%s","last_assistant_message":"%s"}' \
    "${3:-sid-x}" "${4:-/x.jsonl}" "$1" "$2"
}
CLOSE_MSG='── CIERRE · claude-opus-5 · high ──'
run_flush() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/flush-run.sh" 2>/dev/null; }
flush_rc()  { printf '%s' "$2" | HOME="$1" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1; echo "$?"; }
run_track() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/track-edit.sh" 2>/dev/null; }
run_open()  { printf '%s' "$2" | HOME="$1" "$SRC/hooks/open-run.sh" 2>/dev/null; }
run_end()   { printf '%s' "$2" | HOME="$1" "$SRC/hooks/end-run.sh" 2>/dev/null; }
run_subagent() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/subagent-done.sh" 2>/dev/null; }
critic_stop() { # $1 sid  $2 last_assistant_message
  printf '{"hook_event_name":"SubagentStop","session_id":"%s","agent_id":"ag_1","agent_type":"iamlazy-critic","last_assistant_message":"%s"}' "$1" "$2"
}
run_guard() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/guard-agent.sh" 2>/dev/null; }

assert_deny() {
  out="$(run_guard "$1" "$2")"
  case "$out" in
    *'"permissionDecision":"deny"'*) ok "$3" ;;
    *) no "$3 (esperaba deny, obtuvo: ${out:-<vacio>})" ;;
  esac
}
assert_allow() {
  out="$(run_guard "$1" "$2")"
  if [ -z "$out" ]; then ok "$3"; else no "$3 (esperaba sin decision, obtuvo: $out)"; fi
}
assert_ask() {
  out="$(run_guard "$1" "$2")"
  case "$out" in
    *'"permissionDecision":"ask"'*) ok "$3" ;;
    *) no "$3 (esperaba ask, obtuvo: ${out:-<vacio>})" ;;
  esac
}
assert_grep() {
  if [ -f "$2" ] && grep -q "$1" "$2" 2>/dev/null; then ok "$3"
  else no "$3 (no match for '$1' in $2)"; fi
}
assert_absent() {
  if [ -f "$1" ]; then no "$2 (still present: $1)"; else ok "$2"; fi
}

mkrepo() { # -> a git repo with one commit
  d="$(mktmp)"; git init -q "$d" >/dev/null 2>&1
  git -C "$d" commit -q --allow-empty -m base
  echo "$d"
}

ACTIVE="$(mktmp)"; open_run "$ACTIVE" "$ACTIVE" 30
IDLE="$(mktmp)"

# Discovered, not assumed. test.sh exports this when it drives the suite, but
# run standalone we have to find it ourselves -- and asking for a locale the
# system lacks makes bash fall back to C without failing, which would test the
# C locale twice and report it as two.
if [ -z "${UTF8_LOCALE:-}" ]; then
  UTF8_LOCALE=""
  for cand in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if locale -a 2>/dev/null | grep -qix "$cand"; then UTF8_LOCALE="$cand"; break; fi
  done
fi

echo "sintaxis"
for f in "$SRC"/hooks/*.sh "$SRC"/test-hooks.sh; do
  s="${f#$SRC/}"
  if bash -n "$f" 2>/dev/null; then ok "$s parsea"; else no "$s parsea"; fi
done

echo
echo "guarantee 1 — one writer"

G='"hook_event_name":"PreToolUse","session_id":"sid-x"'
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\",\"description\":\"map things\"}}" \
  "deniega Agent/Explore durante una corrida"
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\"}}" \
  "deniega Agent/general-purpose"
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Task\",\"tool_input\":{\"subagent_type\":\"Explore\"}}" \
  "deniega bajo el nombre legacy Task"
# Spawning the Critic no longer allows outright: it asks, so a small-looking
# task that turns out to need real review still gives the human the choice
# up front, and closing without an answer never happens silently. Declining
# still closes -- via the same banner fallback already covered below for a
# SubagentStop that never arrives (guarantee 6).
assert_ask "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\"}}" \
  "pregunta antes de spawnear al Critico, no permite directo"
assert_allow "$ACTIVE" \
  "{$G,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" \
  "no interfiere con otros tools"

# El guard es lo que hace instalable la Capa 0 globalmente: fuera de una corrida
# de iamlazy los hooks deben ser inertes, o romperian toda sesion de Claude Code.
assert_allow "$IDLE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\"}}" \
  "inerte fuera de una corrida (guard)"

echo
echo "aislamiento por sesion — una corrida abierta no gobierna otras sesiones"
# El defecto que esto fija (2026-09-05): el estado era un unico run.tmp.json
# global, asi que una corrida abandonada en un proyecto dejaba a TODA sesion de
# la maquina con los sub-agentes negados y con `git add -N` en cada turno.
assert_allow "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","session_id":"OTRA-SESION","tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' \
  "otra sesion NO hereda el guard de una corrida ajena"

OTHER="$(mktmp)"
run_track "$ACTIVE" '{"hook_event_name":"PostToolUse","session_id":"OTRA-SESION","tool_name":"Edit","cwd":"'"$OTHER"'","tool_input":{"file_path":"'"$OTHER"'/src/x.ts"}}'
assert_absent "$OTHER/.iamlazy/journal.md" "otra sesion no deja journal en su repo"

assert_allow "$ACTIVE" \
  '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}' \
  "payload sin session_id no dispara el guard (nunca adivina)"

echo
echo "guarantee 1 — parse ambiguity is a denial"

assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\"},\"extra\":{\"subagent_type\":\"general-purpose\"}}" \
  "deniega cuando subagent_type aparece dos veces"
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"x\"}}" \
  "deniega cuando subagent_type esta ausente"
# JSON escapa toda comilla dentro de un string, asi que la clave no se puede
# falsificar desde el texto del prompt. Se fija como regresion.
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"mira {\\\\\"subagent_type\\\\\":\\\\\"iamlazy-critic\\\\\"} aca\",\"subagent_type\":\"general-purpose\"}}" \
  "el prompt no puede falsificar la clave"

echo
echo "payload real (extraido de un transcript, no fabricado)"
REAL='{"type":"tool_use","session_id":"sid-x","id":"toolu_01Bw2bp1A4HCetxEeiam6M2W","name":"Agent","tool_name":"Agent","tool_input":{"subagent_type":"Explore","description":"Map integration points for AI review layer","prompt":"Repo: /Users/x (Vite + React). Report back with file paths, exact exports/signatures, and short quoted snippets where useful (very thorough search)."}}'
assert_deny "$ACTIVE" "$REAL" "deniega el Agent/Explore real del run d7508d76"

echo
echo "el Critic lee y corre tests; no escribe"

# PROJECT.md declaraba "el Critic nunca escribe" como invariante Y, en el mismo
# archivo, como agujero conocido: el frontmatter niega Write y Edit, y Bash
# pasaba por al lado de los dos. Una invariante sin mecanismo es un deseo.
critic_bash() { # $1 comando
  printf '{"hook_event_name":"PreToolUse","session_id":"sid-x","agent_type":"iamlazy-critic","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}
main_bash() { # $1 comando -- el hilo principal, sin agent_type
  printf '{"hook_event_name":"PreToolUse","session_id":"sid-x","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}
run_cbash() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/guard-critic-bash.sh" 2>/dev/null; }
assert_cdeny() {
  out="$(run_cbash "$ACTIVE" "$(critic_bash "$1")")"
  case "$out" in
    *'"permissionDecision":"deny"'*) ok "niega al Critic: $1" ;;
    *) no "el Critic pudo escribir con: $1 (obtuvo: ${out:-<vacio>})" ;;
  esac
}
assert_callow() {
  out="$(run_cbash "$ACTIVE" "$(critic_bash "$1")")"
  if [ -z "$out" ]; then ok "permite al Critic: $1"
  else no "bloqueo una lectura legitima del Critic: $1"; fi
}

# Escrituras: lo que la invariante siempre prometio y nadie hacia cumplir.
assert_cdeny 'echo parche > src/a.ts'
assert_cdeny 'cat fixture.json >> src/data.json'
assert_cdeny 'npm test | tee salida.log'
assert_cdeny 'rm -rf node_modules'
assert_cdeny 'mv src/a.ts src/b.ts'
assert_cdeny 'cp -r src /tmp/copia'
assert_cdeny 'mkdir -p src/nuevo'
assert_cdeny 'touch src/nuevo.ts'
assert_cdeny 'chmod +x script.sh'
assert_cdeny 'sed -i.bak s/foo/bar/ src/a.ts'
assert_cdeny 'perl -pi -e s/foo/bar/ src/a.ts'
assert_cdeny 'npm install lodash'
assert_cdeny 'pip3 install requests'
assert_cdeny 'go get github.com/x/y'
assert_cdeny 'wget https://example.com/x.tar.gz'
assert_cdeny 'curl https://example.com/x -o x.tar.gz'
# git: mutar el indice es escribir, y un intent-to-add deja `git stash` roto.
assert_cdeny 'git add -A -N'
assert_cdeny 'git commit -m fix'
assert_cdeny 'git checkout -- src/a.ts'
assert_cdeny 'git reset --hard'
assert_cdeny 'git stash'
assert_cdeny 'git apply parche.diff'
assert_cdeny 'git clean -fd'

# Lecturas y tests: el Critic tiene que poder hacer su trabajo. Un falso
# positivo aca lo deja inutil, que es peor que el agujero que cerramos.
assert_callow 'git diff HEAD'
assert_callow 'git diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904'
assert_callow 'git ls-files --others --exclude-standard'
assert_callow 'git log --oneline -5'
assert_callow 'git rev-parse HEAD'
assert_callow 'git show --stat HEAD'
assert_callow 'npm test'
assert_callow 'npm run build'
assert_callow './test.sh'
assert_callow 'cargo test'
assert_callow 'go test ./...'
assert_callow 'rg -n listMembers src/'
assert_callow 'grep -rn TODO src/'
assert_callow 'cat src/a.ts'
assert_callow 'sed -n 40,60p src/a.ts'
# Redirigir a /dev/null y a stderr no es escribir un archivo.
assert_callow 'npm test 2>/dev/null'
assert_callow 'git diff --stat > /dev/null'
assert_callow 'npm run lint 2>&1'

# El hilo principal SI escribe: es quien construye. El guard es del Critic.
out="$(run_cbash "$ACTIVE" "$(main_bash "echo x > src/a.ts")")"
if [ -z "$out" ]; then ok "el hilo principal puede escribir (el guard es solo del Critic)"
else no "el guard bloqueo al hilo principal, que es quien construye"; fi

# Y fuera de una corrida, inerte como todo Layer 0.
out="$(run_cbash "$IDLE" "$(critic_bash "rm -rf /tmp/x")")"
if [ -z "$out" ]; then ok "inerte fuera de una corrida"
else no "actuo fuera de una corrida de iamlazy"; fi

echo
echo "acuerdo Layer 0 / Layer 1 — el prompt del Critic no pide lo que el guard niega"

# El mismo desacuerdo que el test de etapas, en otra superficie. Antes de este
# guard el prompt del Critic decia literalmente "`git add -A -N` first so new
# files are visible" -- una instruccion que el guard rechaza. Cuando las dos
# capas se contradicen, el modelo obedece al prompt y choca con el hook.
#
# CONVENCION que esto impone, y que el prompt del Critic tiene que respetar:
# **backticks = comando que el Critic puede correr.** Lo que se le prohibe se
# nombra en prosa, sin backticks. Sin esa regla el extractor no puede saber si
# un comando esta siendo mandado o desaconsejado, y una advertencia bien escrita
# ("nunca `git add -N`") se leeria como una contradiccion. La forma del prompt
# esta bajo nuestro control, la heuristica de leerlo no.
crit_cmds="$(grep -o '`[^`]*`' "$SRC/critic/iamlazy-critic.md" | tr -d '`' \
  | grep -E '^(git|npm|pnpm|yarn|cargo|go|rg|grep|cat|sed|awk|head|tail|find|fd)([[:space:]]|$)' \
  | sort -u)"
n_cmds="$(printf '%s\n' "$crit_cmds" | grep -c .)"
if [ "$n_cmds" -ge 1 ]; then ok "el prompt del Critic nombra comandos concretos ($n_cmds)"
else no "no se extrajo ningun comando del prompt del Critic: este bloque seria vacio"; fi

oldifs="$IFS"; IFS='
'
for c in $crit_cmds; do
  out="$(run_cbash "$ACTIVE" "$(critic_bash "$c")")"
  if [ -z "$out" ]; then ok "el prompt pide '$c' y el guard lo permite"
  else no "el prompt del Critic pide '$c' y el guard lo NIEGA: las dos capas se contradicen"; fi
done
IFS="$oldifs"

echo
echo "guarantee 7 — session identified at open"

OPEN_DIR="$(mktmp)"
run_open "$OPEN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-open","transcript_path":"/x.jsonl","cwd":"'"$OPEN_DIR"'","prompt":"hola, no es una tarea"}'
assert_absent "$(runfile "$OPEN_DIR" sid-open)" "un prompt normal no abre corrida"

run_open "$OPEN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-open","transcript_path":"/x.jsonl","cwd":"'"$OPEN_DIR"'","prompt":"/iamlazy arreglar el login"}'
assert_grep '"session_id":"sid-open"' "$(runfile "$OPEN_DIR" sid-open)" "/iamlazy abre corrida con el session_id real"
assert_grep '"outcome":"incomplete"' "$(runfile "$OPEN_DIR" sid-open)" "el tmp arranca incomplete"

# Una segunda corrida en la misma sesion cierra el libro de la primera.
run_open "$OPEN_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-open","transcript_path":"/y.jsonl","cwd":"'"$OPEN_DIR"'","prompt":"/iamlazy otra tarea"}'
assert_grep '"outcome":"abandoned"' "$OPEN_DIR/.iamlazy/runs.jsonl" "un segundo /iamlazy registra la anterior como abandoned"
assert_grep '"transcript_path":"/y.jsonl"' "$(runfile "$OPEN_DIR" sid-open)" "la corrida nueva reemplaza a la vieja"

echo
echo "fin de corrida — abandonada es un resultado, no un silencio"

# SessionEnd: la sesion termina sin cerrar. Antes el archivo de estado sobrevivia
# hasta el proximo /iamlazy y, siendo global, mantenia armadas las garantias en
# todas las demas sesiones. Verificado en vivo el 2026-09-05.
END_DIR="$(mktmp)"
open_run "$END_DIR" "$END_DIR" 100 "sid-end"
printf 'CIERRE_PARCIAL' > "$END_DIR/.iamlazy/active/sid-end.stage"
run_end "$END_DIR" '{"hook_event_name":"SessionEnd","session_id":"sid-end","reason":"logout","cwd":"'"$END_DIR"'"}'
assert_absent "$(runfile "$END_DIR" sid-end)" "SessionEnd limpia el estado de la corrida"
assert_grep '"outcome":"abandoned"' "$END_DIR/.iamlazy/runs.jsonl" "SessionEnd registra la corrida como abandoned"
assert_grep '"stage_reached":"CIERRE_PARCIAL"' "$END_DIR/.iamlazy/runs.jsonl" "la corrida abandonada dice en que etapa murio"
assert_grep '"host":"claude-code"' "$END_DIR/.iamlazy/runs.jsonl" "sin host declarado, la abandonada es claude-code"

# Una corrida de OpenCode que se abandona debe seguir siendo OpenCode en el
# log. Faltaba: hk_flush_abandoned nunca leia el campo, asi que TODA corrida
# de OpenCode que terminara sin cerrar se atribuia a claude-code -- encontrado
# auditando runs.jsonl, no por un test. /iamlazy-review agrupa por este campo,
# asi que una linea mal atribuida corrompe un conteo por host, no que se vea
# incompleta.
ENDOC="$(mktmp)"
run_open "$ENDOC" '{"hook_event_name":"UserPromptSubmit","host":"opencode","session_id":"sid-oc","transcript_path":"","cwd":"'"$ENDOC"'","prompt":"/iamlazy tarea"}'
printf 'EJECUCION' > "$ENDOC/.iamlazy/active/sid-oc.stage"
run_end "$ENDOC" '{"hook_event_name":"SessionEnd","session_id":"sid-oc","reason":"logout","cwd":"'"$ENDOC"'"}'
assert_grep '"host":"opencode"' "$ENDOC/.iamlazy/runs.jsonl" "una corrida de OpenCode abandonada sigue siendo opencode en el log"

# SessionEnd de una sesion sin corrida no debe escribir nada.
END2="$(mktmp)"
run_end "$END2" '{"hook_event_name":"SessionEnd","session_id":"sin-corrida","reason":"clear"}'
assert_absent "$END2/.iamlazy/runs.jsonl" "SessionEnd sin corrida activa no escribe nada"

# Proceso matado: no hay SessionEnd. El barrido por antiguedad es el otro
# mecanismo, y falla distinto.
STALE="$(mktmp)"
mkdir -p "$STALE/.iamlazy/active"
printf '{"schema_version":3,"session_id":"vieja","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"outcome":"incomplete"}' \
  "$STALE" "$(($(date +%s)-90000))" > "$(runfile "$STALE" vieja)"
open_run "$STALE" "$STALE" 60 "reciente"
run_open "$STALE" '{"hook_event_name":"UserPromptSubmit","session_id":"otra","transcript_path":"/z.jsonl","cwd":"'"$STALE"'","prompt":"hola"}'
assert_absent "$(runfile "$STALE" vieja)" "el barrido recupera una corrida de mas de 24h"
assert_grep '"session_id":"vieja"' "$STALE/.iamlazy/runs.jsonl" "la corrida vieja llega al log como abandoned"
if [ -f "$(runfile "$STALE" reciente)" ]; then ok "el barrido NO toca una corrida reciente de otra sesion"
else no "el barrido se llevo puesta una corrida viva"; fi

# Migracion: el run.tmp.json global del layout anterior se recupera una vez.
LEG="$(mktmp)"
mkdir -p "$LEG/.iamlazy"
printf '{"schema_version":1,"session_id":"legacy-sid","cwd":"%s","start_epoch":%s,"outcome":"incomplete"}' \
  "$LEG" "$(date +%s)" > "$LEG/.iamlazy/run.tmp.json"
run_open "$LEG" '{"hook_event_name":"UserPromptSubmit","session_id":"nueva","transcript_path":"/x.jsonl","cwd":"'"$LEG"'","prompt":"hola"}'
assert_absent "$LEG/.iamlazy/run.tmp.json" "el run.tmp.json del layout viejo se migra"
assert_grep 'legacy-sid' "$LEG/.iamlazy/runs.jsonl" "la corrida del layout viejo queda registrada"

echo
echo "guarantee 2 — the log exists (mechanical skeleton)"

MID_DIR="$(mktmp)"
open_run "$MID_DIR" "$MID_DIR" 10
run_flush "$MID_DIR" "$(stop_payload "$MID_DIR" 'trabajando en el paso 2...')" >/dev/null
if [ -f "$(runfile "$MID_DIR")" ]; then ok "turno intermedio no vuelca"; else no "turno intermedio no vuelca (volco de mas)"; fi

BANNER_DIR="$(mktmp)"
open_run "$BANNER_DIR" "$BANNER_DIR" 10
run_flush "$BANNER_DIR" "$(stop_payload "$BANNER_DIR" 'good, el cierre del tema quedo listo, sin banner')" >/dev/null
if [ -f "$(runfile "$BANNER_DIR")" ]; then ok "prosa parecida a un cierre, sin el token del banner, no vuelca"; else no "prosa parecida a un cierre no debia volcar"; fi
run_flush "$BANNER_DIR" "$(stop_payload "$BANNER_DIR" '── CIERRE · claude-opus-5 · high ──\ntodo listo')" >/dev/null
assert_absent "$(runfile "$BANNER_DIR")" "cierre via banner borra el estado"
assert_grep '"close_detected_via":"banner"' "$BANNER_DIR/.iamlazy/runs.jsonl" "cierre via banner queda registrado"

CONTRACT_DIR="$(mkrepo)"
open_run "$CONTRACT_DIR" "$CONTRACT_DIR" 10
set_base "$CONTRACT_DIR" "sid-x" "$CONTRACT_DIR"
mkdir -p "$CONTRACT_DIR/.iamlazy"
printf '## Grupos\n- [x] grupo 1\n- [ ] grupo 2\n' > "$CONTRACT_DIR/.iamlazy/contract.md"
run_flush "$CONTRACT_DIR" "$(stop_payload "$CONTRACT_DIR" 'grupo 1 listo')" >/dev/null
if [ -f "$(runfile "$CONTRACT_DIR")" ]; then ok "contrato con grupo pendiente no vuelca"; else no "contrato con grupo pendiente no debia volcar"; fi
printf '## Grupos\n- [x] grupo 1\n- [x] grupo 2\n' > "$CONTRACT_DIR/.iamlazy/contract.md"
run_flush "$CONTRACT_DIR" "$(stop_payload "$CONTRACT_DIR" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$CONTRACT_DIR")" "todos los grupos resueltos cierra"
assert_grep '"close_detected_via":"contract"' "$CONTRACT_DIR/.iamlazy/runs.jsonl" "cierre via contrato queda registrado"

# Un contrato de la corrida ANTERIOR no cierra la siguiente. contract.md
# sobrevive al cierre, asi que la corrida que arranca despues en el mismo
# proyecto encontraba un contrato con todo tildado y sin violaciones en su
# PRIMER turno, y cerraba de una -- registrando una corrida que no hizo nada,
# con el resumen de la tarea anterior. Encontrado con un smoke test, no leyendo.
STALECON="$(mkrepo)"
mkdir -p "$STALECON/.iamlazy"
printf '# Task\ntarea vieja, ya cerrada\n## Grupos\n- [x] g1\n' > "$STALECON/.iamlazy/contract.md"
open_run "$STALECON" "$STALECON" 5     # corrida nueva: todavia no escribio SU contrato
run_flush "$STALECON" "$(stop_payload "$STALECON" 'arrancando el analisis')" >/dev/null
if [ -f "$(runfile "$STALECON")" ]; then ok "el contrato de una corrida anterior no cierra la nueva"
else no "la corrida cerro con el contrato de la anterior (registro una tarea ajena)"; fi

# stop_hook_active=true marca el turno que EXISTE porque un hook bloqueo el
# anterior. Ese turno no debe volver a bloquear -- ese es el loop que la bandera
# previene -- pero SI debe poder cerrar: es exactamente el turno donde el modelo
# resuelve el desvio que el gate le senalo. Saltearlo entero dejaba la corrida
# abierta con el trabajo terminado, y se registraba `abandoned`.
#
# Encontrado el 2026-09-06 en la primera corrida de la historia del proyecto en
# que el gate bloqueo un cierre de verdad (OpenCode): bloqueo por README.md
# fuera de Scope, el modelo lo revirtio en el turno siguiente, y ese turno se
# tiro a la basura.
loop_payload() { # $1 cwd  $2 mensaje
  printf '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"sid-x","transcript_path":"","cwd":"%s","last_assistant_message":"%s"}' "$1" "$2"
}

LOOPOK="$(mkrepo)"
mkdir -p "$LOOPOK/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$LOOPOK/.iamlazy/contract.md"
open_run "$LOOPOK" "$LOOPOK" 10; set_base "$LOOPOK" "sid-x" "$LOOPOK"
loop_payload "$LOOPOK" "$CLOSE_MSG" | HOME="$LOOPOK" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1
assert_grep '"outcome":"flushed"' "$LOOPOK/.iamlazy/runs.jsonl" "el turno que sigue a un bloqueo puede cerrar la corrida"
assert_absent "$(runfile "$LOOPOK")" "y la corrida queda cerrada, no abandonada"

# ...pero con bloqueadores todavia sin resolver, ese mismo turno calla: si
# volviera a emitir `decision: block` el host lo haria continuar otra vez, que
# es el bucle. Callar es correcto porque el aviso anterior ya se dio.
LOOPQ="$(mkrepo)"
mkdir -p "$LOOPQ/.iamlazy"
printf '## Groups\n- [ ] g1\n' > "$LOOPQ/.iamlazy/contract.md"
open_run "$LOOPQ" "$LOOPQ" 10; set_base "$LOOPQ" "sid-x" "$LOOPQ"
loopout="$(loop_payload "$LOOPQ" "$CLOSE_MSG" | HOME="$LOOPQ" "$SRC/hooks/flush-run.sh" 2>&1)"
if [ -z "$loopout" ]; then ok "con bloqueadores pendientes, ese turno no vuelve a bloquear (evita el loop)"
else no "volvio a bloquear en el turno posterior a un bloqueo (obtuvo: $loopout)"; fi
if [ -f "$(runfile "$LOOPQ")" ]; then ok "y la corrida sigue abierta, como debe"; else no "cerro con bloqueadores pendientes"; fi

echo
echo "guarantee 2 — real payloads and real git"

SELFCTRL_DIR="$(mktmp)"
open_run "$SELFCTRL_DIR" "$SELFCTRL_DIR" 10
run_flush "$SELFCTRL_DIR" "$(stop_payload "$SELFCTRL_DIR" 'Garantia 1 de 7, probada de punta a punta. Agent Explore fue RECHAZADO por el hook.')" >/dev/null
if [ -f "$(runfile "$SELFCTRL_DIR")" ]; then ok "un reporte de progreso real (no cierre) no dispara el flush"; else no "un reporte de progreso disparo el flush por error (falso positivo)"; fi

GITSTAT_DIR="$(mkrepo)"
echo "existente" > "$GITSTAT_DIR/a.txt"; git -C "$GITSTAT_DIR" add -A; git -C "$GITSTAT_DIR" commit -q -m a
open_run "$GITSTAT_DIR" "$GITSTAT_DIR" 5
set_base "$GITSTAT_DIR" "sid-x" "$GITSTAT_DIR"
echo "cambio" >> "$GITSTAT_DIR/a.txt"
printf 'x\n%.0s' $(seq 1 50) > "$GITSTAT_DIR/nuevo.txt"
run_flush "$GITSTAT_DIR" "$(stop_payload "$GITSTAT_DIR" '── CLOSE · claude-opus-5 · high ──')" >/dev/null
assert_grep '"files_changed":2' "$GITSTAT_DIR/.iamlazy/runs.jsonl" "files_changed cuenta el modificado y el nuevo"
assert_grep '"lines_changed":51' "$GITSTAT_DIR/.iamlazy/runs.jsonl" "lines_changed ve el archivo NUEVO"

echo
echo "contabilidad contra base_ref — staging y commits siguen siendo visibles"

# El defecto (verificado 2026-09-05 en dos corridas reales del log): `git diff`
# sin ref muestra SOLO lo no indexado, asi que un `git add` o un `git commit` a
# mitad de la corrida dejaba files/lines en 0, el gate de alcance sin nada que
# comparar y el breaker dividiendo por cero lineas.
STAGED="$(mkrepo)"
echo base > "$STAGED/a.txt"; git -C "$STAGED" add -A; git -C "$STAGED" commit -q -m init
open_run "$STAGED" "$STAGED" 5
set_base "$STAGED" "sid-x" "$STAGED"
printf 'l\n%.0s' $(seq 1 20) >> "$STAGED/a.txt"
git -C "$STAGED" add -A                       # indexado: el viejo `git diff` ya no lo veia
run_flush "$STAGED" "$(stop_payload "$STAGED" '── CLOSE · x ──')" >/dev/null
assert_grep '"lines_changed":20' "$STAGED/.iamlazy/runs.jsonl" "un cambio INDEXADO sigue contando"

COMMITTED="$(mkrepo)"
echo base > "$COMMITTED/a.txt"; git -C "$COMMITTED" add -A; git -C "$COMMITTED" commit -q -m init
open_run "$COMMITTED" "$COMMITTED" 5
set_base "$COMMITTED" "sid-x" "$COMMITTED"
printf 'l\n%.0s' $(seq 1 30) >> "$COMMITTED/a.txt"
git -C "$COMMITTED" add -A; git -C "$COMMITTED" commit -q -m "trabajo del grupo 1"
run_flush "$COMMITTED" "$(stop_payload "$COMMITTED" '── CLOSE · x ──')" >/dev/null
assert_grep '"lines_changed":30' "$COMMITTED/.iamlazy/runs.jsonl" "un cambio COMMITEADO sigue contando (commit por grupo)"

# Lo que ya estaba sin rastrear ANTES del contrato no es cambio de la corrida.
PREEX="$(mkrepo)"
echo previo > "$PREEX/.env.local"
open_run "$PREEX" "$PREEX" 5
set_base "$PREEX" "sid-x" "$PREEX"           # la base recuerda .env.local
printf 'n\n%.0s' $(seq 1 7) > "$PREEX/nuevo.ts"
run_flush "$PREEX" "$(stop_payload "$PREEX" '── CLOSE · x ──')" >/dev/null
assert_grep '"files_changed":1' "$PREEX/.iamlazy/runs.jsonl" "un no-rastreado preexistente no cuenta como cambio de la corrida"

# `git add -A -N` mutaba el indice del usuario y rompia `git stash`.
STASH="$(mkrepo)"
echo base > "$STASH/a.txt"; git -C "$STASH" add -A; git -C "$STASH" commit -q -m init
open_run "$STASH" "$STASH" 5
set_base "$STASH" "sid-x" "$STASH"
echo cambio >> "$STASH/a.txt"; echo nuevo > "$STASH/n.txt"
run_flush "$STASH" "$(stop_payload "$STASH" 'trabajando')" >/dev/null
if git -C "$STASH" stash >/dev/null 2>&1; then ok "tras un Stop, git stash del usuario sigue funcionando"
else no "el hook dejo el indice roto: git stash falla"; fi

echo
echo "guarantee 3 — unbiased trace"

TRACE_DIR="$(mktmp)"
open_run "$TRACE_DIR" "$TRACE_DIR" 5
run_track "$TRACE_DIR" '{"hook_event_name":"PostToolUse","session_id":"sid-x","tool_name":"Edit","cwd":"'"$TRACE_DIR"'","tool_input":{"file_path":"'"$TRACE_DIR"'/src/foo.ts"}}'
assert_grep 'Edit src/foo.ts' "$TRACE_DIR/.iamlazy/journal.md" "un Edit en corrida activa se traza"

NOTRACE_DIR="$(mktmp)"
run_track "$NOTRACE_DIR" '{"hook_event_name":"PostToolUse","session_id":"sid-x","tool_name":"Edit","cwd":"'"$NOTRACE_DIR"'","tool_input":{"file_path":"'"$NOTRACE_DIR"'/src/foo.ts"}}'
assert_absent "$NOTRACE_DIR/.iamlazy/journal.md" "sin corrida activa no traza nada"

SELFEDIT_DIR="$(mkrepo)"
open_run "$SELFEDIT_DIR" "$SELFEDIT_DIR" 5
run_track "$SELFEDIT_DIR" '{"hook_event_name":"PostToolUse","session_id":"sid-x","tool_name":"Write","cwd":"'"$SELFEDIT_DIR"'","tool_input":{"file_path":"'"$SELFEDIT_DIR"'/.iamlazy/contract.md"}}'
if [ -f "$SELFEDIT_DIR/.iamlazy/journal.md" ]; then no "el harness escribiendo su propio .iamlazy/ no debia trazarse"; else ok "el harness escribiendo su propio .iamlazy/ no se traza"; fi
assert_grep '"base_ref"' "$(runfile "$SELFEDIT_DIR")" "escribir el contrato fija el base_ref"

echo
echo "guarantee 4 — scope ledger (real git)"

SCOPE_DIR="$(mkrepo)"
mkdir -p "$SCOPE_DIR/src"
echo base > "$SCOPE_DIR/src/a.ts"; git -C "$SCOPE_DIR" add -A; git -C "$SCOPE_DIR" commit -q -m init
mkdir -p "$SCOPE_DIR/.iamlazy"
printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n' > "$SCOPE_DIR/.iamlazy/contract.md"
open_run "$SCOPE_DIR" "$SCOPE_DIR" 5
set_base "$SCOPE_DIR" "sid-x" "$SCOPE_DIR"
echo cambio >> "$SCOPE_DIR/src/a.ts"
run_flush "$SCOPE_DIR" "$(stop_payload "$SCOPE_DIR" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$SCOPE_DIR")" "cambio dentro del Scope declarado cierra"

# El orden importa y refleja el real: la base se toma al escribir el contrato,
# ANTES de tocar nada. Un archivo que ya estaba sin rastrear cuando se firmo el
# contrato no es un desvio de esta corrida -- es parte del terreno.
open_run "$SCOPE_DIR" "$SCOPE_DIR" 5
set_base "$SCOPE_DIR" "sid-x" "$SCOPE_DIR"
echo fuera > "$SCOPE_DIR/otra_cosa.ts"
run_flush "$SCOPE_DIR" "$(stop_payload "$SCOPE_DIR" "$CLOSE_MSG")" >/dev/null
if [ -f "$(runfile "$SCOPE_DIR")" ]; then ok "archivo fuera del Scope declarado detiene el cierre"; else no "un desvio no declarado cerro igual (deberia frenar)"; fi

printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n- otra_cosa.ts\n' > "$SCOPE_DIR/.iamlazy/contract.md"
run_flush "$SCOPE_DIR" "$(stop_payload "$SCOPE_DIR" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$SCOPE_DIR")" "declarar el desvio en Scope desbloquea el cierre"

UNSCOPED_DIR="$(mkrepo)"
echo x > "$UNSCOPED_DIR/a.txt"
mkdir -p "$UNSCOPED_DIR/.iamlazy"
printf '## Grupos\n- [x] g1\n' > "$UNSCOPED_DIR/.iamlazy/contract.md"
open_run "$UNSCOPED_DIR" "$UNSCOPED_DIR" 5
set_base "$UNSCOPED_DIR" "sid-x" "$UNSCOPED_DIR"
run_flush "$UNSCOPED_DIR" "$(stop_payload "$UNSCOPED_DIR" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$UNSCOPED_DIR")" "sin seccion Scope declarada, el cierre no se bloquea (unscoped != violacion)"

echo
echo "guarantee 4 — patrones de Scope como los escribe un modelo"

# Dos habitos inofensivos producian violaciones fantasma (verificado 2026-09-05):
# envolver la ruta en backticks, y escribir un directorio con barra final.
for variant in '- `src/*`' '- src/' '- src/  '; do
  PAT="$(mkrepo)"
  mkdir -p "$PAT/src" "$PAT/.iamlazy"
  echo base > "$PAT/src/a.ts"; git -C "$PAT" add -A; git -C "$PAT" commit -q -m init
  printf '## Grupos\n- [x] g1\n## Scope\n%s\n' "$variant" > "$PAT/.iamlazy/contract.md"
  open_run "$PAT" "$PAT" 5
  set_base "$PAT" "sid-x" "$PAT"
  echo cambio >> "$PAT/src/a.ts"
  run_flush "$PAT" "$(stop_payload "$PAT" "$CLOSE_MSG")" >/dev/null
  assert_absent "$(runfile "$PAT")" "patron '$variant' cubre src/a.ts"
done

echo
echo "guarantee 4 — el gate es audible, y solo cuando corresponde"

# El defecto: el gate devolvia exit 0 sin decir nada. El modelo creia haber
# terminado y la corrida quedaba abierta sin explicacion.
AUD="$(mkrepo)"
mkdir -p "$AUD/src" "$AUD/.iamlazy"
echo base > "$AUD/src/a.ts"; git -C "$AUD" add -A; git -C "$AUD" commit -q -m init
printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n' > "$AUD/.iamlazy/contract.md"
open_run "$AUD" "$AUD" 5
set_base "$AUD" "sid-x" "$AUD"
echo fuera > "$AUD/config.yml"
out="$(run_flush "$AUD" "$(stop_payload "$AUD" '── CIERRE · claude-opus-5 · high ──')")"
case "$out" in
  *'"decision":"block"'*config.yml*) ok "al intentar cerrar, el gate NOMBRA el archivo fuera de scope" ;;
  *) no "el gate no explico el bloqueo (obtuvo: ${out:-<vacio>})" ;;
esac
case "$out" in
  *'"systemMessage"'*) ok "el bloqueo tambien va por systemMessage (nivel superior)" ;;
  *) no "falta systemMessage en el bloqueo" ;;
esac

# Y no repite la misma lista dos veces.
out2="$(run_flush "$AUD" "$(stop_payload "$AUD" '── CIERRE · claude-opus-5 · high ──')")"
if [ -z "$out2" ]; then ok "el gate no repite el mismo bloqueo"; else no "el gate repitio la misma lista"; fi

# Un desvio NUEVO si es informacion nueva.
echo otro > "$AUD/otro.yml"
out3="$(run_flush "$AUD" "$(stop_payload "$AUD" '── CIERRE · claude-opus-5 · high ──')")"
case "$out3" in
  *otro.yml*) ok "un desvio nuevo si vuelve a avisar" ;;
  *) no "un desvio nuevo debia avisar de nuevo" ;;
esac

# Lo critico: a mitad de corrida los grupos ESTAN abiertos a proposito. Un hook
# que bloquee esos turnos deja al humano sin poder intervenir.
MID="$(mkrepo)"
mkdir -p "$MID/.iamlazy"
printf '## Grupos\n- [x] g1\n- [ ] g2\n' > "$MID/.iamlazy/contract.md"
open_run "$MID" "$MID" 5
set_base "$MID" "sid-x" "$MID"
rc="$(flush_rc "$MID" "$(stop_payload "$MID" 'termine el grupo 1, sigo con el 2')")"
if [ "$rc" = "0" ]; then ok "a mitad de corrida el gate NO bloquea el turno"
else no "el gate bloqueo un turno intermedio (rc=$rc): la sesion queda en una cinta sin fin"; fi

echo
echo "la corrida no cierra antes de que vuelva la revision"

# Reproduce la primera corrida real del harness reformado (git-diff-viewer,
# 2026-09-05), al segundo:
#   06:50:30  contract.md escrito con su grupo en - [x]
#   06:50:44  iamlazy-critic lanzado en BACKGROUND -> el turno termino
#   06:51:01  Stop: contrato completo, sin violaciones -> CERRO LA CORRIDA
# La revision seguia corriendo. El log declaro `outcome: flushed` para una
# tarea cuya revision nunca llego y cuya etapa CIERRE nunca ocurrio.
REV="$(mkrepo)"
mkdir -p "$REV/src" "$REV/.iamlazy"
echo base > "$REV/src/a.ts"; git -C "$REV" add -A; git -C "$REV" commit -q -m init
printf '# Task\nmaximizar el diff\n## Scope\n- src/*\n## Groups\n- [x] toggle\n' > "$REV/.iamlazy/contract.md"
open_run "$REV" "$REV" 5
set_base "$REV" "sid-x" "$REV"
echo cambio >> "$REV/src/a.ts"

run_flush "$REV" "$(stop_payload "$REV" 'El critic sigue corriendo en background. Aviso al usuario y quedo a la espera.')" >/dev/null
if [ -f "$(runfile "$REV")" ]; then ok "con el critic todavia corriendo, la corrida NO cierra"
else no "cerro con la revision en vuelo (el log mentiria: flushed sin review)"; fi

# La etapa se acumula en el sidecar, no en el turno que cierra.
run_flush "$REV" "$(stop_payload "$REV" '── EJECUCIÓN · claude-opus-5 · high ──\nsigo')" >/dev/null

run_subagent "$REV" "$(critic_stop sid-x 'Revise adversarialmente ReviewView.tsx. findings: 0/2/1/0')"
assert_grep '"critic_done":1' "$(runfile "$REV")" "SubagentStop del critic marca la revision como hecha"
assert_grep '0/2/1/0' "$REV/.iamlazy/active/sid-x.findings" "el tally del critic se deriva de su propio mensaje final"

run_flush "$REV" "$(stop_payload "$REV" 'reporte de entrega, sin banner')" >/dev/null
assert_absent "$(runfile "$REV")" "con la revision devuelta, la corrida ya puede cerrar"
assert_grep '"critic_findings":"0/2/1/0"' "$REV/.iamlazy/runs.jsonl" "critic_findings llega al log"
# stage_reached salio vacio en la corrida real: el turno de cierre no tenia
# banner y el flush usaba la variable del turno en vez del sidecar acumulado.
assert_grep '"stage_reached":"EJECUCIÓN"' "$REV/.iamlazy/runs.jsonl" "stage_reached sale del sidecar, no del turno que cierra"

# El respaldo importa tanto como el guard: si este build no emite SubagentStop,
# o su payload no trae el session_id del padre, `critic_done` no llega nunca --
# y sin esta salida toda corrida quedaria abierta hasta el barrido de 24h. Desde
# que el guard PREGUNTA antes de spawnear al Critico (2026-09-11), este mismo
# camino es tambien el que cierra cuando el humano dice que no: para el flush,
# "el canal fallo" y "el humano declino" son indistinguibles, y las dos deben
# poder cerrar.
FB="$(mkrepo)"
mkdir -p "$FB/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$FB/.iamlazy/contract.md"
open_run "$FB" "$FB" 5
set_base "$FB" "sid-x" "$FB"
run_flush "$FB" "$(stop_payload "$FB" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$FB")" "sin SubagentStop, el banner de CIERRE sigue cerrando (respaldo)"

# Un sub-agente que no es el critic no cuenta como revision.
NC="$(mkrepo)"
mkdir -p "$NC/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$NC/.iamlazy/contract.md"
open_run "$NC" "$NC" 5
set_base "$NC" "sid-x" "$NC"
run_subagent "$NC" '{"hook_event_name":"SubagentStop","session_id":"sid-x","agent_type":"Explore","last_assistant_message":"findings: 9/9/9/9"}'
run_flush "$NC" "$(stop_payload "$NC" 'termine')" >/dev/null
if [ -f "$(runfile "$NC")" ]; then ok "otro sub-agente no cuenta como la revision"
else no "un sub-agente cualquiera destrabo el cierre"; fi

echo
echo "guarantee 6 — never under a permission bypass"

BYPASS_DIR="$(mktmp)"
run_open "$BYPASS_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BYPASS_DIR"'","permission_mode":"bypassPermissions","prompt":"/iamlazy hacer algo"}'
assert_absent "$(runfile "$BYPASS_DIR" s)" "bypassPermissions no abre corrida"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$BYPASS_DIR"'","permission_mode":"bypassPermissions","prompt":"/iamlazy x"}' | HOME="$BYPASS_DIR" "$SRC/hooks/open-run.sh" >/dev/null 2>&1
if [ "$?" = "2" ]; then ok "bypassPermissions bloquea con exit 2"; else no "bypassPermissions debia salir con 2"; fi

NORMAL_DIR="$(mktmp)"
run_open "$NORMAL_DIR" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$NORMAL_DIR"'","permission_mode":"default","prompt":"/iamlazy hacer algo"}'
assert_grep '"session_id":"s"' "$(runfile "$NORMAL_DIR" s)" "permission_mode normal abre corrida"

echo
echo "contexto inyectado — el estado deja de ser invisible"

CTX="$(mkrepo)"
mkdir -p "$CTX/src" "$CTX/.iamlazy"
echo base > "$CTX/src/a.ts"; git -C "$CTX" add -A; git -C "$CTX" commit -q -m init
printf '## Grupos\n- [x] g1\n## Scope\n- src/*\n' > "$CTX/.iamlazy/contract.md"
open_run "$CTX" "$CTX" 5 "s"
set_base "$CTX" "s" "$CTX"
echo fuera > "$CTX/config.yml"
out="$(run_open "$CTX" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$CTX"'","prompt":"segui"}')"
case "$out" in
  *"NO puede cerrar"*config.yml*) ok "durante la corrida, el prompt siguiente lleva el estado y el desvio" ;;
  *) no "no se inyecto el estado de la corrida (obtuvo: ${out:-<vacio>})" ;;
esac
out="$(run_open "$IDLE" '{"hook_event_name":"UserPromptSubmit","session_id":"nadie","transcript_path":"/x.jsonl","cwd":"'"$IDLE"'","prompt":"hola"}')"
if [ -z "$out" ]; then ok "sin corrida activa no se inyecta nada"; else no "se inyecto contexto sin corrida (obtuvo: $out)"; fi

echo
echo "guarantee 5 — circuit breaker (calibrado en dolares, sobre corridas medidas)"

CB="$(mkrepo)"
mkdir -p "$CB/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$CB/.iamlazy/contract.md"

# Sana: 100 lineas por $3.50 -> $0.035/linea. Pasa el piso de costo y queda
# debajo del umbral. Las cuatro corridas reales medidas van de 0,0226 a 0,0647.
printf 'x\n%.0s' $(seq 1 100) > "$CB/big.txt"
mk_transcript "$CB" 3500000
open_run_tok "$CB" "$CB"; set_base "$CB" "s" "$CB"; rm -f "$CB/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$CB" "$(stop_payload "$CB" "$CLOSE_MSG" s "$CB/t.jsonl")")" = "2" ]; then no "una corrida sana (\$0,035/linea) no debe disparar"; else ok "una corrida sana (\$0,035/linea) no dispara"; fi

# La corrida perdida: 230 lineas, ~\$23,69 -> \$0,103/linea.
rm -f "$CB/big.txt"
printf 'x\n%.0s' $(seq 1 230) > "$CB/small.txt"
mk_transcript "$CB" 23690000
open_run_tok "$CB" "$CB"; set_base "$CB" "s" "$CB"; rm -f "$CB/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$CB" "$(stop_payload "$CB" "$CLOSE_MSG" s "$CB/t.jsonl")")" = "2" ]; then ok "la corrida perdida (\$0,103/linea) dispara el breaker"; else no "la corrida perdida debia disparar el breaker"; fi
assert_grep '"drift_warned":1' "$(runfile "$CB" s)" "el aviso queda marcado en el run"

if [ "$(flush_rc "$CB" "$(stop_payload "$CB" "$CLOSE_MSG" s "$CB/t.jsonl")")" = "2" ]; then no "el breaker no debe repetir el aviso"; else ok "el breaker avisa una sola vez"; fi

# El breaker tampoco habla en el turno que EXISTE porque un hook bloqueo el
# anterior: seria el mismo bucle que la bandera previene. Se prueba con una
# corrida virgen (sin drift_warned), asi que lo unico que puede callarlo es
# stop_hook_active.
CBL="$(mkrepo)"
mkdir -p "$CBL/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$CBL/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 230) > "$CBL/small.txt"
mk_transcript "$CBL" 23690000
open_run_tok "$CBL" "$CBL"; set_base "$CBL" "s" "$CBL"; rm -f "$CBL/.iamlazy/active/s.untracked"
cbl_payload="$(printf '{"hook_event_name":"Stop","stop_hook_active":true,"session_id":"s","transcript_path":"%s","cwd":"%s","last_assistant_message":"%s"}' "$CBL/t.jsonl" "$CBL" "$CLOSE_MSG")"
if [ "$(printf '%s' "$cbl_payload" | HOME="$CBL" "$SRC/hooks/flush-run.sh" >/dev/null 2>&1; echo $?)" = "2" ]; then
  no "el breaker no debe disparar en el turno posterior a un bloqueo"
else ok "el breaker calla en el turno posterior a un bloqueo"; fi
assert_absent "$(runfile "$CB" s)" "tras avisar, el cierre sigue siendo posible"
assert_grep '"cost_usd":23.6900' "$CB/.iamlazy/runs.jsonl" "cost_usd (delta de la corrida) llega al log"
assert_grep '"drift_fired":1' "$CB/.iamlazy/runs.jsonl" "la linea recuerda que el breaker disparo"

# Una corrida que cruzo el breaker y ADEMAS nunca cerro es la corrida enferma
# canonica: cara, sin avance y abandonada. El dato vive en el archivo de la
# corrida, que se borra al volcarla, asi que tiene que viajar a la linea.
CBA="$(mkrepo)"
open_run "$CBA" "$CBA" 30 s
sed 's/}$/,"drift_warned":1}/' "$(runfile "$CBA" s)" > "$CBA/rf.tmp" && mv "$CBA/rf.tmp" "$(runfile "$CBA" s)"
run_end "$CBA" '{"hook_event_name":"SessionEnd","session_id":"s","cwd":"'"$CBA"'"}'
assert_grep '"drift_fired":1' "$CBA/.iamlazy/runs.jsonl" "una corrida abandonada recuerda que el breaker disparo"
assert_grep '"schema_version":6' "$CBA/.iamlazy/runs.jsonl" "la linea abandonada declara el schema vigente"
assert_grep '"tokens_output":947600' "$CB/.iamlazy/runs.jsonl" "los componentes crudos quedan para poder reprecificar"

# Debajo del piso de lineas el ratio es ruido: el costo por linea SUBE cuanto
# mas chica es la tarea, porque el costo fijo de leer/planificar/revisar no
# escala. Es lo que salva a las tareas chicas de un falso positivo.
CB2="$(mkrepo)"
printf 'x\n%.0s' $(seq 1 10) > "$CB2/tiny.txt"
mk_transcript "$CB2" 5000000
open_run_tok "$CB2" "$CB2"; set_base "$CB2" "s" "$CB2"; rm -f "$CB2/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$CB2" "$(stop_payload "$CB2" "$CLOSE_MSG" s "$CB2/t.jsonl")")" = "2" ]; then no "con 10 lineas el ratio es ruido, no debe disparar"; else ok "bajo el piso de lineas no dispara (tarea chica)"; fi

# Y debajo del piso de COSTO tampoco: el breaker es "caro Y sin avance".
CB2b="$(mkrepo)"
printf 'x\n%.0s' $(seq 1 60) > "$CB2b/f.txt"
mk_transcript "$CB2b" 2000000
open_run_tok "$CB2b" "$CB2b"; set_base "$CB2b" "s" "$CB2b"; rm -f "$CB2b/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$CB2b" "$(stop_payload "$CB2b" "$CLOSE_MSG" s "$CB2b/t.jsonl")")" = "2" ]; then no "bajo el piso de costo no debe disparar"; else ok "bajo el piso de costo no dispara (barato aunque improductivo)"; fi

# El delta importa: una SEGUNDA corrida en la misma sesion no hereda el costo
# de la primera. Verificado en vivo -- el /iamlazy-review tipeado despues sumo
# \$0,90 que correctamente quedaron afuera.
CB3="$(mkrepo)"
printf 'x\n%.0s' $(seq 1 230) > "$CB3/f.txt"
mk_transcript "$CB3" 23690000
mkdir -p "$CB3/.iamlazy/active"; mk_prices "$CB3"
printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":22000000,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
  "$CB3/t.jsonl" "$CB3" "$(date +%s)" > "$(runfile "$CB3" s)"
set_base "$CB3" "s" "$CB3"; rm -f "$CB3/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$CB3" "$(stop_payload "$CB3" "$CLOSE_MSG" s "$CB3/t.jsonl")")" = "2" ]; then no "una 2da corrida no debe heredar el costo de la 1ra (usar delta)"; else ok "el breaker mide el DELTA de la corrida, no el total de sesion"; fi

echo
echo "costo — un modelo sin precio no produce un total parcial"

# El pecado que este bloque previene: sumar lo que se reconoce y presentarlo
# como el costo de la corrida. Un numero confiadamente bajo es peor que ninguno,
# y este proyecto ya publico dos numeros equivocados sobre si mismo.
UNP="$(mkrepo)"
mkdir -p "$UNP/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$UNP/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 20) > "$UNP/f.txt"
open_run_tok "$UNP" "$UNP"; set_base "$UNP" "s" "$UNP"; rm -f "$UNP/.iamlazy/active/s.untracked"
printf '{"model":"modelo-del-futuro","message":{"id":"msg_X","usage":{"input_tokens":0,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$UNP/t.jsonl"
run_flush "$UNP" "$(stop_payload "$UNP" "$CLOSE_MSG" s "$UNP/t.jsonl")" >/dev/null
assert_grep '"cost_usd":null' "$UNP/.iamlazy/runs.jsonl" "un modelo sin precio da cost_usd null, no un total parcial"
assert_grep 'modelo-del-futuro' "$UNP/.iamlazy/runs.jsonl" "el log NOMBRA el modelo que falta en prices.conf"
assert_grep '"tokens_output":1000' "$UNP/.iamlazy/runs.jsonl" "los componentes crudos se guardan igual, para reprecificar despues"

echo "guarantee 2 — derived semantic fields"

SEM="$(mkrepo)"
SEMT="$(mktmp)"
mkdir -p "$SEM/.iamlazy" "$SEM/src"
printf '# Task\nAdd rate limiting to the "login" endpoint\n\n## Scope\n- src/*\n\n## Groups\n- [x] limiter\n' > "$SEM/.iamlazy/contract.md"
printf '# P\n' > "$SEM/PROJECT.md"
git -C "$SEM" add -A; git -C "$SEM" commit -q -m init
mkdir -p "$SEM/.iamlazy/active"
mk_transcript "$SEMT" 500000
mk_prices "$SEM"
printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
  "$SEMT/t.jsonl" "$SEM" "$(date +%s)" > "$(runfile "$SEM" s)"
set_base "$SEM" "s" "$SEM"
echo x > "$SEM/src/a.rb"
echo c >> "$SEM/PROJECT.md"
run_flush "$SEM" "$(stop_payload "$SEM" "$CLOSE_MSG" s "$SEMT/t.jsonl")" >/dev/null
assert_grep '"task_summary":"Add rate limiting to the \\"login\\" endpoint"' "$SEM/.iamlazy/runs.jsonl" \
  "task_summary derivado del contrato, con las comillas ESCAPADAS (no borradas)"
assert_grep '"project_md":"updated"' "$SEM/.iamlazy/runs.jsonl" "project_md derivado del diff"
assert_grep '"schema_version":6' "$SEM/.iamlazy/runs.jsonl" "la linea declara su schema"
assert_grep '"cost_usd":0.5000' "$SEM/.iamlazy/runs.jsonl" "cost_usd derivado del transcript y la tabla de precios"
assert_grep '"close_detected_via":"contract"' "$SEM/.iamlazy/runs.jsonl" \
  "PROJECT.md modificado no bloquea el cierre (es parte del cierre)"
assert_grep '"base_ref"' "$SEM/.iamlazy/runs.jsonl" "el log registra contra que base se midio"

if command -v python3 >/dev/null 2>&1; then
  if python3 -c "
import json,sys
for l in open('$SEM/.iamlazy/runs.jsonl'):
    l=l.strip()
    if l: json.loads(l)
" 2>/dev/null; then ok "la linea del log es JSON valido"
  else no "la linea del log NO es JSON valido"; fi
else
  no "python3 ausente: no se pudo validar el JSON del log"
fi

echo
echo "project_root — the session cwd is NOT always the project"

# Regresion de la primera corrida real: /iamlazy se invoco desde ~/dev/iamlazy y
# se le pidio construir en ~/dev/iamlazy-stats. Todos los hooks contabilizaban
# contra el cwd de la sesion.
SESS="$(mktmp)"
PROJ="$(mkrepo)"
mkdir -p "$PROJ/src"
open_run "$SESS" "$SESS" 5 "s"

run_track "$SESS" '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Write","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$PROJ"'/.iamlazy/contract.md"}}'
assert_grep '"project_root"' "$(runfile "$SESS" s)" "escribir el contrato registra el project_root"
assert_grep '"base_ref"' "$(runfile "$SESS" s)" "escribir el contrato registra el base_ref del proyecto"

mkdir -p "$PROJ/.iamlazy"
run_track "$SESS" '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$PROJ"'/src/a.py"}}'
assert_grep 'Edit src/a.py' "$PROJ/.iamlazy/journal.md" "el journal va al proyecto, no al cwd de la sesion"
assert_absent "$SESS/.iamlazy/journal.md" "no se escribe journal en el cwd de la sesion"

run_track "$SESS" '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Write","cwd":"'"$SESS"'","tool_input":{"file_path":"'"$SESS"'/plans/scratch.md"}}'
if grep -q 'scratch.md' "$PROJ/.iamlazy/journal.md" 2>/dev/null; then
  no "archivos fuera del proyecto no deben trazarse"
else
  ok "archivos fuera del proyecto no se trazan"
fi

printf '## Groups\n- [x] g1\n' > "$PROJ/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 30) > "$PROJ/src/a.py"
run_flush "$SESS" "$(stop_payload "$SESS" "$CLOSE_MSG" s)" >/dev/null
assert_absent "$(runfile "$SESS" s)" "el cierre encuentra el contrato en el proyecto"
assert_grep '"lines_changed":30' "$SESS/.iamlazy/runs.jsonl" "las lineas se cuentan del proyecto, no del cwd"

echo
echo "close banner — matches the real banner, not prose, IN EVERY LOCALE"

# El fallo que este bloque fija: la regex usaba \xe2\x94\x80, que BSD grep
# interpreta bajo LC_ALL=C y NO bajo un locale UTF-8 -- que es donde los hooks
# realmente corren. La suite pasaba en el locale C de CI mientras el camino
# estaba muerto en produccion. Tercera vez que este cierre muere en silencio.
for loc in C en_US.UTF-8; do
  BAN="$(mktmp)"
  open_run "$BAN" "$BAN" 5
  LC_ALL="$loc" run_flush "$BAN" "$(stop_payload "$BAN" 'el cierre del tema quedo listo')" >/dev/null
  if [ -f "$(runfile "$BAN")" ]; then ok "[$loc] la palabra suelta CIERRE en prosa no cierra"; else no "[$loc] prosa suelta no debia cerrar"; fi
  LC_ALL="$loc" run_flush "$BAN" "$(stop_payload "$BAN" '── CIERRE · claude-opus-5 · high ──')" >/dev/null
  assert_absent "$(runfile "$BAN")" "[$loc] el banner real si cierra"
done

echo
echo "acuerdo Layer 0 / Layer 1 — el vocabulario de etapas es UNO solo"

# Esto es lo unico en la suite que lee las DOS capas y las compara.
#
# El mismo defecto aparecio tres veces y cada vez se arreglo el caso puntual,
# nunca el generador:
#   - el prompt dejo de emitir `A5`, la regex seguia buscandolo: camino de
#     cierre muerto durante una corrida entera
#   - la regex usaba bytes escapados (\xe2\x94\x80), que BSD grep ignora bajo
#     locale UTF-8: muerto en produccion, verde en el locale C de CI
#   - el ejemplo del propio prompt usaba `PLAN`, una etapa que su lista no
#     define, y el modelo copio el ejemplo
#
# El vocabulario es extraible de los dos lados, asi que por la regla del propio
# proyecto esto no va en prosa: va en un comando.

# TODO sale del PROMPT: el separador, las etapas, Y cual de ellas es el cierre.
#
# La primera version de este bloque extraia las etapas del prompt y despues
# comparaba contra un `case CLOSE|CIERRE)` escrito aca. Verificacion por
# mutacion: renombrar CIERRE en el prompt sin tocar los hooks NO fallaba, y
# hacer que REVIEW cerrara tampoco. El test tenia exactamente la enfermedad que
# vino a curar -- una copia local del vocabulario probando que coincide consigo
# misma. La etapa de cierre se deriva por POSICION: es la ultima de cada lista,
# porque el orden del prompt es el orden de sus secciones y cerrar es la ultima.
PROMPT="$SRC/core/iamlazy.md"
PROMPT_BANNER="$(grep -o '`──[^`]*──`' "$PROMPT" | head -1 | tr -d '`')"
SEP="$(printf '%s' "$PROMPT_BANNER" | grep -o '^[^ ]*')"

stage_list() { # $1 sed-expr -> una etapa por linea, en orden
  sed -n "$1" "$PROMPT" \
    | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -v '^$'
}
EN_STAGES="$(stage_list 's/.*(EN: *\([^·]*\)·.*/\1/p')"
ES_STAGES="$(stage_list 's/^ES: *\([^)]*\)).*/\1/p')"
STAGES="$(printf '%s\n%s\n' "$EN_STAGES" "$ES_STAGES")"
EN_CLOSE="$(printf '%s\n' "$EN_STAGES" | tail -1)"
ES_CLOSE="$(printf '%s\n' "$ES_STAGES" | tail -1)"

banner_for() { printf '%s %s · claude-opus-5 · high %s' "$SEP" "$1" "$SEP"; }

# Guardias contra el test vacio: si el prompt se reformatea y la extraccion deja
# de encontrar nada, los bucles corren cero veces y la suite pasaria sin haber
# probado nada. Un test que se apaga solo es peor que no tenerlo.
n_en="$(printf '%s\n' "$EN_STAGES" | grep -c .)"
n_es="$(printf '%s\n' "$ES_STAGES" | grep -c .)"
if [ "$n_en" -ge 2 ] && [ "$n_es" -ge 2 ]; then ok "el prompt declara su vocabulario de etapas ($n_en EN / $n_es ES)"
else no "no se pudieron extraer las etapas del prompt (EN=$n_en ES=$n_es): el resto de este bloque seria vacio"; fi
# Una traduccion que se perdio es un desacuerdo tambien.
if [ "$n_en" = "$n_es" ]; then ok "las dos listas de etapas tienen el mismo largo"
else no "las listas de etapas no coinciden en largo (EN=$n_en ES=$n_es): falta una traduccion"; fi
if [ -n "$SEP" ]; then ok "el separador del banner sale del prompt ('$SEP')"
else no "no se pudo extraer el separador del banner del prompt"; fi
if [ -n "$EN_CLOSE" ] && [ -n "$ES_CLOSE" ]; then ok "la etapa de cierre se deriva del prompt ($EN_CLOSE / $ES_CLOSE)"
else no "no se pudo derivar la etapa de cierre del prompt"; fi

for loc in C ${UTF8_LOCALE:-C}; do
  for st in $STAGES; do
    b="$(banner_for "$st")"
    got="$(LC_ALL="$loc" bash -c '. "'"$SRC"'/hooks/lib.sh"; hk_stage "$1"' _ "$b")"
    if [ "$got" = "$st" ]; then ok "[$loc] hk_stage reconoce $st"
    else no "[$loc] hk_stage no reconoce $st (obtuvo '${got:-<vacio>}')"; fi

    # Solo la ultima etapa de cada lista cierra. Que REVIEW o EJECUCIÓN
    # dispararan el cierre volveria a producir el bug de ayer por otro camino.
    if LC_ALL="$loc" bash -c '. "'"$SRC"'/hooks/lib.sh"; hk_has_close_banner "$1"' _ "$b"; then
      closes=1
    else closes=0; fi
    if [ "$st" = "$EN_CLOSE" ] || [ "$st" = "$ES_CLOSE" ]; then exp=1; else exp=0; fi
    if [ "$closes" = "$exp" ]; then
      [ "$exp" = 1 ] && ok "[$loc] $st dispara el cierre" || ok "[$loc] $st NO dispara el cierre"
    else
      [ "$exp" = 1 ] && no "[$loc] $st debia disparar el cierre (los hooks no conocen la etapa que el prompt declara)" \
                     || no "[$loc] $st NO debia disparar el cierre"
    fi
  done
done

# El ejemplo que el prompt le muestra al modelo tiene que usar una etapa que el
# prompt define. Cuando no coinciden gana el ejemplo: la corrida real del
# 2026-09-05 emitio `PLAN` porque el ejemplo decia PLAN, y `PLAN` no estaba en
# la lista de seis.
ex_stage="$(printf '%s' "$PROMPT_BANNER" | sed -e "s/^$SEP //" -e 's/ ·.*//')"
if printf '%s\n' "$STAGES" | grep -qx "$ex_stage"; then
  ok "el banner de ejemplo usa una etapa declarada ($ex_stage)"
else
  no "el banner de ejemplo usa '$ex_stage', que el prompt no declara: el modelo copia el ejemplo"
fi

echo
echo "stage_reached — se registra la etapa, tambien una que el prompt no define"

STG="$(mktmp)"
open_run "$STG" "$STG" 5
run_flush "$STG" "$(stop_payload "$STG" '── EVALUACIÓN · claude-sonnet-5 · high ──\nanalizando')" >/dev/null
assert_grep 'EVALUACIÓN' "$STG/.iamlazy/active/sid-x.stage" "la etapa del turno queda registrada tal cual se emitio"

echo
echo "no git — a switched-off guarantee must say so, ONCE"

NOGIT="$(mktmp)"
mkdir -p "$NOGIT/.iamlazy" "$NOGIT/src"
printf 'x\n%.0s' $(seq 1 40) > "$NOGIT/src/a.ts"
printf '## Groups\n- [x] g1\n' > "$NOGIT/.iamlazy/contract.md"
open_run "$NOGIT" "$NOGIT" 5
# Sin git, hk_set_base igual fija base_ref: cae al hash del arbol vacio. Es lo
# que hace track-edit.sh al escribir el contrato, con o sin repositorio.
set_base "$NOGIT" "sid-x" "$NOGIT"
out=$(run_flush "$NOGIT" "$(stop_payload "$NOGIT" "$CLOSE_MSG")")
case "$out" in
  *"no es un repositorio git"*) ok "un proyecto sin git avisa que las garantias estan degradadas" ;;
  *) no "un proyecto sin git debe avisar (obtuvo: ${out:-<vacio>})" ;;
esac
assert_grep '"lines_changed":0' "$NOGIT/.iamlazy/runs.jsonl" "sin git, lines_changed es 0 y no se inventa"

NOGIT2="$(mktmp)"
mkdir -p "$NOGIT2/.iamlazy"
open_run "$NOGIT2" "$NOGIT2" 5
run_flush "$NOGIT2" "$(stop_payload "$NOGIT2" 'turno 1')" >/dev/null
out=$(run_flush "$NOGIT2" "$(stop_payload "$NOGIT2" 'turno 2')")
if [ -z "$out" ]; then ok "el aviso de 'sin git' no se repite cada turno"
else no "el aviso de 'sin git' se repitio (33 veces en la corrida real)"; fi

echo
echo "costo — los bloques usage se deduplican por message id"

# Regresion: un transcript registra el mismo mensaje varias veces (streaming mas
# final), asi que sumar los campos de tokens con grep cuenta cada bloque de mas.
# Medido sobre una corrida real: 1.176.836 reportados contra 561.234 reales, un
# 2,1x. Ese numero alimenta el circuit breaker y la linea de costo del cierre.
DEDUP="$(mktmp)"
mk_prices "$DEDUP"
PRICES="$DEDUP/.iamlazy/prices.conf"
{
  printf '{"model":"claude-opus-5","message":{"id":"msg_A","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_A","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_A","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_B","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
} > "$DEDUP/t.jsonl"
# 2 mensajes unicos x 100 tokens de salida x \$25/MTok = 5.000 micro-dolares.
# Contando las 4 lineas darian 10.000.
got=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/t.jsonl" "$PRICES")
if [ "$got" = "5000" ]; then ok "cuenta un usage por mensaje unico (obtuvo $got)"
else no "duplicados no deduplicados: esperaba 5000, obtuvo $got"; fi
gotc=$(. "$SRC/hooks/lib.sh"; hk_token_components "$DEDUP/t.jsonl")
if [ "$gotc" = "200 0 0" ]; then ok "los componentes crudos tambien deduplican (obtuvo: $gotc)"
else no "componentes sin deduplicar: esperaba '200 0 0', obtuvo '$gotc'"; fi

# El precio depende del MODELO, que es exactamente lo que la unidad ponderada
# no distinguia: mismos tokens, distinto costo.
printf '{"model":"claude-sonnet-5","message":{"id":"msg_S","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$DEDUP/s.jsonl"
gots=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/s.jsonl" "$PRICES")
# 100 x \$10/MTok = 1.000 micro. En opus-5 los mismos 100 tokens valen 2.500.
if [ "$gots" = "1000" ]; then ok "el mismo token cuesta distinto segun el modelo (sonnet 1000 vs opus 2500)"
else no "precio por modelo incorrecto: esperaba 1000, obtuvo $gots"; fi

# Cache: write x1,25 del input, read x0,1 del input.
printf '{"model":"claude-opus-5","message":{"id":"msg_C","usage":{"input_tokens":1000,"output_tokens":0,"cache_creation_input_tokens":1000,"cache_read_input_tokens":10000}}}\n' > "$DEDUP/c.jsonl"
gotk=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/c.jsonl" "$PRICES")
# 1000x5 + 1000x5x1,25 + 10000x5x0,1 = 5.000 + 6.250 + 5.000 = 16.250 micro
if [ "$gotk" = "16250" ]; then ok "aplica los multiplicadores de cache (x1,25 write / x0,1 read)"
else no "multiplicadores de cache incorrectos: esperaba 16250, obtuvo $gotk"; fi

echo "merge-settings — sin parser JSON avisa lo correcto"

# `rc=$?` despues de un `if` lee el estado del `if`, que es 0 cuando corre el
# else: la rama "sin parser" (exit 3) era inalcanzable y el instalador reportaba
# "merge failed" en una maquina sin python.
MS="$(mktmp)"
mkdir -p "$MS/bin"
# Un PATH curado que NO contiene python. Un stub que existe y falla no sirve:
# `command -v python3` igual lo encuentra y toma esa rama, que es exactamente
# como se me escapo la primera vez que lo probe a mano.
for t in bash mkdir cp date rm mv basename dirname; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MS/bin/$t"
done
echo '{"theme":"dark"}' > "$MS/settings.json"
msout=$(PATH="$MS/bin" "$SRC/hooks/merge-settings.sh" "$MS/settings.json" /x/hooks 2>&1)
msrc=$?
if [ "$msrc" = "3" ]; then ok "sin parser JSON sale con 3"; else no "sin parser JSON debia salir 3 (obtuvo $msrc)"; fi
case "$msout" in
  *"NO JSON PARSER"*) ok "sin parser JSON lo dice explicitamente" ;;
  *) no "mensaje incorrecto sin parser (obtuvo: $msout)" ;;
esac
assert_grep 'dark' "$MS/settings.json" "sin parser, settings.json queda intacto"

echo
echo "costo: el transcript se crea DESPUES del primer prompt"

# UserPromptSubmit dispara antes de que Claude Code escriba el archivo del
# transcript en una sesion nueva. Verificado 2026-09-06 sobre una corrida real:
# el archivo nacio en el mismo segundo en que la corrida abrio y el hook llego
# primero. Un transcript AUSENTE no es un precio desconocido -- es que todavia
# no se gasto nada, asi que la linea base es cero. Tratarlos igual hacia que
# toda corrida abierta como primer prompt de una sesion nueva reportara
# cost_usd null, y ademas sin nada en cost_unpriced que lo explicara.
LATE="$(mkrepo)"
mkdir -p "$LATE/.iamlazy"; mk_prices "$LATE"
run_open "$LATE" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"'"$LATE/t.jsonl"'","cwd":"'"$LATE"'","prompt":"/iamlazy tarea"}'
assert_grep '"cost_priced":1' "$(runfile "$LATE" s)" "sin transcript todavia, la linea base es cero y la corrida es tarifable"
assert_grep '"start_cost":0' "$(runfile "$LATE" s)" "y la linea base es exactamente cero, no un desconocido"
mk_transcript "$LATE" 500000            # el transcript aparece recien ahora
printf '## Groups\n- [x] g1\n' > "$LATE/.iamlazy/contract.md"
set_base "$LATE" "s" "$LATE"
run_flush "$LATE" "$(stop_payload "$LATE" "$CLOSE_MSG" s "$LATE/t.jsonl")" >/dev/null
assert_grep '"cost_usd":0.5000' "$LATE/.iamlazy/runs.jsonl" "y el cierre tarifa la corrida entera en vez de null"

# Un modelo sin precio dentro del transcript del CRITICO: su costo ya se sumaba
# a la corrida, pero solo se buscaban modelos sin precio en el transcript
# principal, asi que producia un null que el log no podia explicar.
SUBU="$(mkrepo)"
mkdir -p "$SUBU/.iamlazy"; mk_prices "$SUBU"
printf '## Groups\n- [x] g1\n' > "$SUBU/.iamlazy/contract.md"
mk_transcript "$SUBU" 100000
mkdir -p "$SUBU/t/subagents"
printf '{"model":"claude-desconocido-9","message":{"id":"msg_S","usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$SUBU/t/subagents/agent-x.jsonl"
open_run_tok "$SUBU" "$SUBU"; set_base "$SUBU" "s" "$SUBU"
run_flush "$SUBU" "$(stop_payload "$SUBU" "$CLOSE_MSG" s "$SUBU/t.jsonl")" >/dev/null
assert_grep '"cost_usd":null' "$SUBU/.iamlazy/runs.jsonl" "un modelo sin precio en el Critico deja el costo en null"
assert_grep '"cost_unpriced":"claude-desconocido-9"' "$SUBU/.iamlazy/runs.jsonl" "y el null NOMBRA al modelo, aunque viva en el transcript del Critico"

echo
echo "precios: un snapshot con fecha es el mismo modelo"

# Claude Code escribe ids con sufijo de fecha en el transcript
# (claude-haiku-4-5-20251001 aparece 9.321 veces en una semana de transcripts
# reales) y prices.conf lista la familia sin sufijo. La busqueda era exacta, asi
# que TODA corrida que tocara un snapshot habria salido con cost_usd null. Un
# -YYYYMMDD es el mismo modelo al mismo precio, por definicion; cualquier otro
# prefijo NO se normaliza, porque tarifar claude-opus-6-preview a precio de
# opus-5 seria un numero equivocado, y este proyecto prefiere no tener numero.
PSNAP="$(mktmp)"
mk_prices "$PSNAP"
printf '{"model":"claude-opus-5-20251001","message":{"id":"msg_A","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$PSNAP/t.jsonl"
snap_cost="$(HOME="$PSNAP" bash -c '. '"$SRC"'/hooks/lib.sh; hk_cost_micro "'"$PSNAP"'/t.jsonl"')"
if [ "$snap_cost" = "2500" ]; then ok "un id con -YYYYMMDD tarifa como su familia (100 tok x 25 micro)"
else no "el snapshot con fecha no tarifo (obtuvo: ${snap_cost:-<vacio>})"; fi
snap_miss="$(HOME="$PSNAP" bash -c '. '"$SRC"'/hooks/lib.sh; hk_unpriced_models "'"$PSNAP"'/t.jsonl"')"
if [ -z "$snap_miss" ]; then ok "y no se reporta como modelo sin precio"
else no "reporto como sin precio un snapshot que si tiene precio: $snap_miss"; fi

# Un modelo realmente desconocido sigue sin tarifarse, y se nombra.
PUNK="$(mktmp)"
mk_prices "$PUNK"
printf '{"model":"claude-opus-6-preview","message":{"id":"msg_B","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$PUNK/t.jsonl"
if HOME="$PUNK" bash -c '. '"$SRC"'/hooks/lib.sh; hk_cost_micro "'"$PUNK"'/t.jsonl"' >/dev/null 2>&1; then
  no "un modelo desconocido no debe tarifarse por parecido"
else ok "un modelo desconocido sigue sin tarifar, no se aproxima"; fi
unk="$(HOME="$PUNK" bash -c '. '"$SRC"'/hooks/lib.sh; hk_unpriced_models "'"$PUNK"'/t.jsonl"')"
case "$unk" in *claude-opus-6-preview*) ok "y se nombra con su id completo" ;; *) no "no nombro el modelo sin precio (obtuvo: ${unk:-<vacio>})" ;; esac

# Y si el desconocido ADEMAS trae fecha, se reporta con el id COMPLETO: el
# humano tiene que poder pegar en prices.conf exactamente lo que vio, no una
# version recortada que no aparece en ningun transcript.
PUNKD="$(mktmp)"
mk_prices "$PUNKD"
printf '{"model":"claude-zeta-9-20260101","message":{"id":"msg_C","usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$PUNKD/t.jsonl"
unkd="$(HOME="$PUNKD" bash -c '. '"$SRC"'/hooks/lib.sh; hk_unpriced_models "'"$PUNKD"'/t.jsonl"')"
case "$unkd" in
  *claude-zeta-9-20260101*) ok "un desconocido con fecha se nombra completo, sin recortar" ;;
  *) no "reporto el id recortado en vez del real (obtuvo: ${unkd:-<vacio>})" ;;
esac

echo
echo "umbrales del breaker: config, con los defaults como respaldo"

# Recalibrar exigia editar el script instalado y reinstalar, y por eso el breaker
# sigue siendo la unica garantia nunca ejercitada en produccion en ningun host:
# reproducirla cuesta una corrida de $3. Con ~/.iamlazy/config es un experimento
# de centavos. Lo que quede en efecto se registra en la linea, porque un breaker
# que NO disparo solo se puede interpretar sabiendo contra que se midio.
mk_cheap_run() { # $1 home -- $0.10 sobre 10 lineas = $0.01/linea: sana por default
  mkdir -p "$1/.iamlazy"
  printf '## Groups\n- [x] g1\n' > "$1/.iamlazy/contract.md"
  printf 'x\n%.0s' $(seq 1 10) > "$1/f.txt"
  mk_transcript "$1" 100000
  open_run_tok "$1" "$1"; set_base "$1" "s" "$1"; rm -f "$1/.iamlazy/active/s.untracked"
}

DEFT="$(mkrepo)"; mk_cheap_run "$DEFT"
if [ "$(flush_rc "$DEFT" "$(stop_payload "$DEFT" "$CLOSE_MSG" s "$DEFT/t.jsonl")")" = "2" ]; then
  no "sin config, una corrida barata no debe disparar"
else ok "sin config valen los umbrales por defecto"; fi
assert_grep '"drift_thresholds":"80000/50/3000000"' "$DEFT/.iamlazy/runs.jsonl" "la linea registra los umbrales por defecto"
assert_grep '"drift_fired":0' "$DEFT/.iamlazy/runs.jsonl" "una corrida que no lo cruzo registra drift_fired 0"

LOWT="$(mkrepo)"; mk_cheap_run "$LOWT"
printf 'DRIFT_MICRO_PER_LINE=5000\nDRIFT_MIN_LINES=5\nDRIFT_MIN_COST=50000\n' > "$LOWT/.iamlazy/config"
if [ "$(flush_rc "$LOWT" "$(stop_payload "$LOWT" "$CLOSE_MSG" s "$LOWT/t.jsonl")")" = "2" ]; then
  ok "los umbrales de ~/.iamlazy/config bajan el piso y el breaker dispara"
else no "el breaker ignoro los umbrales del config"; fi

# Un valor no numerico no puede convertirse en un umbral: `[ x -ge y ]` con
# basura aborta la comparacion y el breaker quedaria mudo sin decirlo.
BADT="$(mkrepo)"; mk_cheap_run "$BADT"
printf 'DRIFT_MIN_LINES=muchas\nDRIFT_MICRO_PER_LINE=\n' > "$BADT/.iamlazy/config"
run_flush "$BADT" "$(stop_payload "$BADT" "$CLOSE_MSG" s "$BADT/t.jsonl")" >/dev/null
assert_grep '"drift_thresholds":"80000/50/3000000"' "$BADT/.iamlazy/runs.jsonl" "un umbral no numerico se ignora y vale el default"

echo
echo "human_interventions — delta donde se puede contar, null donde no"

# El transcript acumula TODA la sesion, asi que el campo es el delta de la
# corrida: una segunda corrida en la misma sesion heredaria las interrupciones
# de la primera. Se abre con una interrupcion ya presente y se agregan dos.
HID="$(mkrepo)"
mkdir -p "$HID/.iamlazy"; mk_prices "$HID"
printf 'Request interrupted by user\n' > "$HID/t.jsonl"
run_open "$HID" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-x","transcript_path":"'"$HID/t.jsonl"'","cwd":"'"$HID"'","prompt":"/iamlazy tarea"}'
printf 'Request interrupted by user\nRequest interrupted by user\n' >> "$HID/t.jsonl"
printf '## Groups\n- [x] g1\n' > "$HID/.iamlazy/contract.md"
set_base "$HID" "sid-x" "$HID"
run_flush "$HID" "$(stop_payload "$HID" "$CLOSE_MSG" sid-x "$HID/t.jsonl")" >/dev/null
assert_grep '"human_interventions":2' "$HID/.iamlazy/runs.jsonl" "human_interventions es el delta de la corrida, no el total de la sesion"

# Sin transcript no hay donde contar, y `0` seria una mentira: diria "el humano
# no interrumpio" cuando lo cierto es "no se puede saber". Es el mismo criterio
# que cost_usd, y la razon por la que tokens_total se retiro en vez de dejarlo.
HIN="$(mkrepo)"
mkdir -p "$HIN/.iamlazy/active"; mk_prices "$HIN"
printf '## Groups\n- [x] g1\n' > "$HIN/.iamlazy/contract.md"
printf '{"schema_version":4,"host":"opencode","session_id":"s","transcript_path":"","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":0,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
  "$HIN" "$(date +%s)" > "$(runfile "$HIN" s)"
set_base "$HIN" "s" "$HIN"
run_flush "$HIN" "$(stop_payload "$HIN" "$CLOSE_MSG" s "")" >/dev/null
assert_grep '"human_interventions":null' "$HIN/.iamlazy/runs.jsonl" "sin transcript, human_interventions es null y no 0"
if [ -f "$HIN/.iamlazy/runs.jsonl" ] && python3 -c "import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]" "$HIN/.iamlazy/runs.jsonl" 2>/dev/null; then
  ok "la linea con null sigue siendo JSON valido"
else
  no "la linea con null no parsea como JSON"
fi

echo
echo "contrato con adaptadores de host — costo provisto y campo host"

# Claude Code no da costo por mensaje: los hooks lo derivan del transcript y de
# prices.conf. OpenCode y Pi SI lo calculan ellos, y un adaptador lo entrega en
# <sid>.cost. Cuando existe, ese es el costo de la corrida -- derivar un segundo
# numero desde prices.conf encima de un host que ya la tarifo produciria dos
# cifras que no coinciden, que es peor que una sola.
HC="$(mkrepo)"
mkdir -p "$HC/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$HC/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 12) > "$HC/f.txt"
mk_transcript "$HC" 9000000          # el transcript diria $9.00...
open_run_tok "$HC" "$HC"; set_base "$HC" "s" "$HC"; rm -f "$HC/.iamlazy/active/s.untracked"
printf 'cost_micro=1234567\ntokens_output=111\ntokens_cache_write=222\ntokens_cache_read=333\n' > "$HC/.iamlazy/active/s.cost"
run_flush "$HC" "$(stop_payload "$HC" "$CLOSE_MSG" s "$HC/t.jsonl")" >/dev/null
assert_grep '"cost_usd":1.2346' "$HC/.iamlazy/runs.jsonl" "el sidecar del host gana sobre el transcript (\$1.23, no \$9.00)"
assert_grep '"tokens_output":111' "$HC/.iamlazy/runs.jsonl" "los componentes salen del sidecar, no del transcript"
assert_grep '"tokens_cache_read":333' "$HC/.iamlazy/runs.jsonl" "cache_read del sidecar"
assert_absent "$HC/.iamlazy/active/s.cost" "hk_run_clear tambien limpia el sidecar de costo"

# Sin transcript legible (cost_priced=0), el sidecar igual tarifa la corrida: un
# host que entrega costo no necesita que exista un transcript al estilo Claude.
HC2="$(mkrepo)"
mkdir -p "$HC2/.iamlazy/active"; mk_prices "$HC2"
printf '## Groups\n- [x] g1\n' > "$HC2/.iamlazy/contract.md"
printf '{"schema_version":4,"host":"opencode","session_id":"s","transcript_path":"","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":0,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"outcome":"incomplete"}' \
  "$HC2" "$(date +%s)" > "$(runfile "$HC2" s)"
set_base "$HC2" "s" "$HC2"
printf 'cost_micro=500000\n' > "$HC2/.iamlazy/active/s.cost"
run_flush "$HC2" "$(stop_payload "$HC2" "$CLOSE_MSG" s "")" >/dev/null
assert_grep '"cost_usd":0.5000' "$HC2/.iamlazy/runs.jsonl" "sin transcript, el sidecar tarifa igual"
assert_grep '"host":"opencode"' "$HC2/.iamlazy/runs.jsonl" "el host queda registrado en el log"

# El campo host: un adaptador lo agrega al payload sintetizado; Claude Code no
# lo trae, y su ausencia significa Claude Code.
HH="$(mktmp)"
run_open "$HH" '{"hook_event_name":"UserPromptSubmit","host":"opencode","session_id":"oc1","transcript_path":"","cwd":"'"$HH"'","prompt":"/iamlazy tarea"}'
assert_grep '"host":"opencode"' "$(runfile "$HH" oc1)" "open-run registra el host que declara el adaptador"
run_open "$HH" '{"hook_event_name":"UserPromptSubmit","session_id":"cc1","transcript_path":"/x.jsonl","cwd":"'"$HH"'","prompt":"/iamlazy tarea"}'
assert_grep '"host":"claude-code"' "$(runfile "$HH" cc1)" "sin campo host, es Claude Code"

# host-cost.sh acumula lo que el adaptador manda por mensaje completado. La
# aritmetica, la ruta y la forma del sidecar son de Layer 0; deduplicar por id
# de mensaje es del adaptador, que es el unico que ve ids.
run_cost() { printf '%s' "$2" | HOME="$1" "$SRC/hooks/host-cost.sh" 2>/dev/null; }
HK="$(mkrepo)"
open_run "$HK" "$HK" 30 hc
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"hc","host":"opencode","cost_micro":100000,"tokens_output":10,"tokens_cache_write":1,"tokens_cache_read":5}'
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"hc","host":"opencode","cost_micro":250000,"tokens_output":15,"tokens_cache_write":2,"tokens_cache_read":7}'
assert_grep '^cost_micro=350000$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula el costo de dos mensajes"
assert_grep '^tokens_output=25$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula tokens_output"
assert_grep '^tokens_cache_write=3$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula cache_write"
assert_grep '^tokens_cache_read=12$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula cache_read"
run_cost "$HK" '{"hook_event_name":"Stop","session_id":"hc","cost_micro":999999}'
assert_grep '^cost_micro=350000$' "$HK/.iamlazy/active/hc.cost" "un evento que no es HostCost no toca el sidecar"
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"nadie","cost_micro":5}'
assert_absent "$HK/.iamlazy/active/nadie.cost" "sin corrida activa, host-cost es inerte"
# ...y el cierre tarifa la corrida con exactamente lo acumulado.
mkdir -p "$HK/.iamlazy"; printf '## Groups\n- [x] g1\n' > "$HK/.iamlazy/contract.md"
set_base "$HK" hc "$HK"
run_flush "$HK" "$(stop_payload "$HK" "$CLOSE_MSG" hc "")" >/dev/null
assert_grep '"cost_usd":0.3500' "$HK/.iamlazy/runs.jsonl" "el cierre tarifa la corrida con lo que host-cost acumulo"
assert_absent "$HK/.iamlazy/active/hc.cost" "el cierre limpia el sidecar acumulado"

echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
