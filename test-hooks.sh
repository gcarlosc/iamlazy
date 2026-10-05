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
  printf '{"schema_version":4,"session_id":"%s","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
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
  printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
    "$2/t.jsonl" "$2" "$(date +%s)" > "$(runfile "$1" s)"
}

# mark_critic_asked <home> <sid> -- simulate guard-agent.sh having already
# fired for the Critic on a run opened via the real open-run.sh (which does
# not set this itself; only guard-agent.sh does). Tests unrelated to the
# ask/decline mechanism use this so they keep testing what they were written
# for, matching what a real run looks like by the time it reaches the close.
mark_critic_asked() {
  f="$(runfile "$1" "${2:-sid-x}")"
  sed 's/}$/,"critic_asked":1}/' "$f" > "$f.new" && mv "$f.new" "$f"
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
# El archivo tiene que EXISTIR y no contener el patron: un archivo que nunca se
# escribio pasaria cualquier afirmacion de ausencia sin probar nada.
assert_ungrep() {
  if [ ! -f "$2" ]; then no "$3 (el archivo no existe: $2)"
  elif grep -q "$1" "$2" 2>/dev/null; then no "$3 (match inesperado de '$1' en $2)"
  else ok "$3"; fi
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
  # $SRC quoted INSIDE the expansion too: same class of bug as hk_rel_path
  # (SC2295) -- a checkout path with a glob character would read as a pattern
  # here instead of literal text, and the strip would silently fail.
  s="${f#"$SRC"/}"
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

# OpenCode V2 puede lanzar un sub-agente en background: el tool vuelve
# "running" al instante y el trabajo termina fuera de banda, asi que sus
# hallazgos NUNCA llegan por SubagentStop. Permitirlo cerraria la corrida como
# "desvio declarado" con una revision todavia en vuelo -- la degradacion
# silenciosa que la Capa 0 existe para eliminar. Se deniega ANTES de la rama
# del Critico, asi que un intento rechazado tampoco graba critic_asked.
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\",\"background\":true}}" \
  "deniega al Critico en background"
assert_deny "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\",\"background\":true}}" \
  "deniega cualquier sub-agente en background"
# background:false es el modo normal y no debe confundirse con el denegado.
assert_ask "$ACTIVE" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\",\"background\":false}}" \
  "background:false sigue siendo el camino normal del Critico"

# CRITIC_ASK=0 quita la pregunta (costo 7,5 minutos de espera en una corrida
# real) pero NO la prueba del intento: critic_asked se graba igual.
NOASK="$(mktmp)"
open_run "$NOASK" "$NOASK" 30
sed 's/,"critic_asked":1//' "$(runfile "$NOASK")" > "$(runfile "$NOASK").new" && mv "$(runfile "$NOASK").new" "$(runfile "$NOASK")"
printf 'CRITIC_ASK=0\n' > "$NOASK/.iamlazy/config"
assert_allow "$NOASK" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\"}}" \
  "con CRITIC_ASK=0 el Critic se lanza sin preguntar"
assert_grep '"critic_asked":1' "$(runfile "$NOASK")" "y el intento queda registrado igual"
assert_deny "$NOASK" \
  "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\"}}" \
  "CRITIC_ASK=0 no abre la puerta a otros sub-agentes"

# open_run graba critic_asked:1 de entrada; para probar que el rechazo NO lo
# graba hay que SACAR el campo primero -- el mismo patron que usa el E2E de
# abajo, que ya demuestra que sobre este fixture un intento en foreground SI
# lo escribe. Sin eso, la afirmacion no tendria dientes.
BG="$(mktmp)"
open_run "$BG" "$BG" 30
sed 's/,"critic_asked":1//' "$(runfile "$BG")" > "$(runfile "$BG").new" \
  && mv "$(runfile "$BG").new" "$(runfile "$BG")"
run_guard "$BG" "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\",\"background\":true}}" >/dev/null
assert_ungrep '"critic_asked"' "$(runfile "$BG")" \
  "un intento en background NO graba critic_asked (no fue un intento valido)"

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
# Lo que la primera version dejaba pasar (auditoria del 2026-10-03).
assert_cdeny 'find . -name *.tmp -delete'
assert_cdeny 'find src -type f -fprint lista.txt'
assert_cdeny 'sort -o ordenado.txt datos.txt'
assert_cdeny 'rsync -a src/ /tmp/copia'
assert_cdeny 'install -m 755 bin/tool /usr/local/bin/tool'
assert_cdeny 'patch -p1 < fix.diff'
assert_cdeny 'tar -xzf dist.tgz'
assert_cdeny 'tar -czf salida.tgz src'
assert_cdeny 'tar --extract -f x.tar'
assert_cdeny 'unzip release.zip'
assert_cdeny 'git revert HEAD'
assert_cdeny 'git gc'
assert_cdeny 'git update-ref refs/heads/x HEAD'
assert_cdeny 'git worktree add ../wt'
assert_cdeny 'git notes add -m nota'
assert_cdeny 'git submodule update --init'

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
# Y sus formas de solo lectura siguen pasando.
assert_callow 'find . -name *.ts'
assert_callow 'sort datos.txt'
assert_callow 'tar -tzf dist.tgz'
assert_callow 'unzip -l release.zip'
assert_callow 'git worktree list'
assert_callow 'git notes show HEAD'
assert_callow 'git submodule status'
assert_callow 'rg -n install src/'
assert_callow 'cat docs/patch-notes.md'
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
# shellcheck disable=SC2016  # grep pattern, not shell expansion
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

# Un archivo de corrida sin session_id no nombra ninguna corrida. Se limpia y
# no se registra: el log real tiene cuatro lineas abandoned con session_id,
# cwd y duracion vacios, contadas en cada tally hasta que alguien las vio.
NOSID="$(mktmp)"
mkdir -p "$NOSID/.iamlazy/active"
printf '{"schema_version":5,"start_epoch":%s,"outcome":"incomplete"}' "$(($(date +%s)-90000))" \
  > "$NOSID/.iamlazy/active/basura.json"
printf '{"outcome":"incomplete"}' > "$NOSID/.iamlazy/active/vacia.json"
run_open "$NOSID" '{"hook_event_name":"UserPromptSubmit","session_id":"otra","transcript_path":"/x.jsonl","cwd":"'"$NOSID"'","prompt":"hola"}'
assert_absent "$NOSID/.iamlazy/active/basura.json" "un archivo de corrida sin session_id se limpia en el barrido"
assert_absent "$NOSID/.iamlazy/active/vacia.json" "uno sin session_id ni start_epoch tambien"
assert_absent "$NOSID/.iamlazy/runs.jsonl" "y ninguno llega al log como corrida abandonada"

echo
echo "un cierre no se cuenta dos veces — el mismo run, invocado concurrentemente"

# Reproduce el bug real: un run de OpenCode V2 quedo logueado TRES veces,
# byte-identico, porque el daemon instancia el plugin mas de una vez y cada
# instancia vio el mismo evento terminal. flush-run.sh pasaba hk_guard,
# calculaba el mismo cierre y appendeaba su propia linea, todas antes de que
# cualquiera borrara el archivo del run. hk_claim_close cierra esa ventana con
# `>` bajo noclobber (O_EXCL), atomico sin libreria de locks.
CONC="$(mkrepo)"
mkdir -p "$CONC/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$CONC/.iamlazy/contract.md"
open_run "$CONC" "$CONC" 5
set_base "$CONC" "sid-x" "$CONC"
CONC_PAYLOAD="$(stop_payload "$CONC" "$CLOSE_MSG")"
for _ in 1 2 3 4 5 6; do
  run_flush "$CONC" "$CONC_PAYLOAD" >/dev/null &
done
wait
n=$(grep -c '"session_id":"sid-x"' "$CONC/.iamlazy/runs.jsonl" 2>/dev/null)
if [ "${n:-0}" = "1" ]; then ok "seis flush-run.sh concurrentes sobre el mismo cierre -> una sola linea"
else no "seis invocaciones concurrentes escribieron $n lineas, no 1"; fi
assert_absent "$(runfile "$CONC" sid-x)" "y el archivo del run quedo limpio, no huerfano"
rf="$(runfile "$CONC" sid-x)"
assert_absent "${rf%.json}.closing" "la marca de claim se limpia junto con el resto"

# El mismo defecto, en el OTRO lugar que hace log_append + run_clear: una
# corrida vieja, barrida por varios /iamlazy concurrentes en sesiones
# distintas (hk_sweep_stale recorre TODOS los archivos activos en cada uno).
CONCSTALE="$(mktmp)"
mkdir -p "$CONCSTALE/.iamlazy/active"
printf '{"schema_version":8,"session_id":"vieja-conc","transcript_path":"/x.jsonl","cwd":"%s","start_epoch":%s,"outcome":"incomplete"}' \
  "$CONCSTALE" "$(($(date +%s)-90000))" > "$(runfile "$CONCSTALE" vieja-conc)"
for i in 1 2 3 4 5 6; do
  run_open "$CONCSTALE" '{"hook_event_name":"UserPromptSubmit","session_id":"otra-'"$i"'","transcript_path":"/z.jsonl","cwd":"'"$CONCSTALE"'","prompt":"hola"}' >/dev/null &
done
wait
n=$(grep -c '"session_id":"vieja-conc"' "$CONCSTALE/.iamlazy/runs.jsonl" 2>/dev/null)
if [ "${n:-0}" = "1" ]; then ok "seis barridos concurrentes sobre la misma corrida vieja -> una sola linea abandoned"
else no "seis barridos concurrentes escribieron $n lineas, no 1"; fi

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

# A project path holding a glob-special character (a folder named "Client
# [Acme]" is not exotic) used to defeat the prefix strip: `${2#$1/}` reads an
# unquoted $1 as a PATTERN, not literal text, so the path never stripped and
# the absolute path leaked into the journal instead of a relative one.
GLOB_DIR="$(mktmp)/proj [x]"
mkdir -p "$GLOB_DIR"
open_run "$GLOB_DIR" "$GLOB_DIR" 5
run_track "$GLOB_DIR" '{"hook_event_name":"PostToolUse","session_id":"sid-x","tool_name":"Edit","cwd":"'"$GLOB_DIR"'","tool_input":{"file_path":"'"$GLOB_DIR"'/src/foo.ts"}}'
assert_grep 'Edit src/foo.ts' "$GLOB_DIR/.iamlazy/journal.md" \
  "un path de proyecto con caracteres de glob ([, ]) igual se traza relativo"

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
# shellcheck disable=SC2016  # literal markdown, not shell expansion
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

# El bug real que esto arregla (2026-09-11): una corrida en produccion cerro
# con "el humano decidio no revisar" en el journal, pero CERO llamadas a la
# tool Agent/Task en todo el transcript -- a nadie se le pregunto nada. El
# modelo se auto-otorgo el permiso que "declarado como desviacion" existe para
# pedir. Sin critic_asked, el banner de CIERRE por si solo no alcanza.
NEVER="$(mkrepo)"
mkdir -p "$NEVER/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$NEVER/.iamlazy/contract.md"
open_run "$NEVER" "$NEVER" 5   # NO se llama a mark_critic_asked: nunca se pregunto
sed 's/,"critic_asked":1//' "$(runfile "$NEVER")" > "$(runfile "$NEVER").new" && mv "$(runfile "$NEVER").new" "$(runfile "$NEVER")"
set_base "$NEVER" "sid-x" "$NEVER"
neverout="$(run_flush "$NEVER" "$(stop_payload "$NEVER" "$CLOSE_MSG")")"
if [ -f "$(runfile "$NEVER")" ]; then ok "sin pedirle nada al Critic, el banner de CIERRE NO cierra"
else no "cerro sin que el Critic fuera invocado ni una vez (el bug real)"; fi
case "$neverout" in
  *'nunca fue invocado'*) ok "el bloqueo NOMBRA que el Critic nunca fue invocado" ;;
  *) no "no se explico por que se bloqueo (obtuvo: ${neverout:-<vacio>})" ;;
esac

# End-to-end: guard-agent.sh REAL pregunta y GRABA la prueba; flush-run.sh REAL
# la lee y cierra. Ningun test hasta aca conectaba ambos hooks -- todos
# fabricaban critic_asked a mano en el archivo de la corrida.
E2E="$(mkrepo)"
mkdir -p "$E2E/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$E2E/.iamlazy/contract.md"
open_run "$E2E" "$E2E" 5
sed 's/,"critic_asked":1//' "$(runfile "$E2E")" > "$(runfile "$E2E").new" && mv "$(runfile "$E2E").new" "$(runfile "$E2E")"
set_base "$E2E" "sid-x" "$E2E"
run_guard "$E2E" "{$G,\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"iamlazy-critic\"}}" >/dev/null
assert_grep '"critic_asked":1' "$(runfile "$E2E")" "guard-agent.sh real graba la prueba de la pregunta"
run_flush "$E2E" "$(stop_payload "$E2E" "$CLOSE_MSG")" >/dev/null
assert_absent "$(runfile "$E2E")" "y con esa prueba, flush-run.sh real cierra por el banner"

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
echo "contrato escrito por cualquier via — no solo por Edit/Write"

# Corrida real (sperant, 2026-10-03): el modelo escribio el contrato con
# `cp plan.md .iamlazy/contract.md` desde Bash. track-edit.sh no lo vio, no
# hubo base_ref, y con eso se apagaron el gate de alcance, el breaker por ratio
# y el cierre por contrato: el log dijo 0 archivos sobre 3 reales y cerro por
# banner. El marcador de apertura se envejece en cada caso para que el orden
# "antes / despues de abrir" no dependa de la precision del reloj del sistema.
# -c: never CREATE the marker. A helper that creates it would hide an
# open-run.sh that stopped writing it -- which is exactly how this test once
# let that mutation through.
age_marker() { touch -c -t 202001010000 "$1/.iamlazy/active/$2.opened"; }
open_real() { # $1 dir  $2 sid  [$3 transcript]
  run_open "$1" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$2"'","transcript_path":"'"${3:-/x.jsonl}"'","cwd":"'"$1"'","prompt":"/iamlazy tarea"}'
  mark_critic_asked "$1" "$2"
  age_marker "$1" "$2"
}

CPC="$(mkrepo)"
mkdir -p "$CPC/src"; echo base > "$CPC/src/a.ts"; git -C "$CPC" add -A; git -C "$CPC" commit -q -m init
open_real "$CPC" sid-cp
mkdir -p "$CPC/.iamlazy"
printf '# Task\nx\n## Scope\n- src/*\n## Groups\n- [x] g1\n' > "$CPC/.iamlazy/contract.md"
echo cambio >> "$CPC/src/a.ts"
run_flush "$CPC" "$(stop_payload "$CPC" "$CLOSE_MSG" sid-cp)" >/dev/null
assert_grep '"close_detected_via":"contract"' "$CPC/.iamlazy/runs.jsonl" "un contrato escrito por Bash cierra por contrato, no por banner"
assert_grep '"files_changed":1' "$CPC/.iamlazy/runs.jsonl" "y su cambio se cuenta contra el base_ref de la apertura"

# Un contrato que ya estaba en disco antes de abrir es de la corrida anterior.
# Adoptarlo es el bug del smoke test de 2026-09-05: un contrato viejo, con todo
# marcado, cerraba la corrida nueva en su primer turno.
STC="$(mkrepo)"
mkdir -p "$STC/.iamlazy"
printf '# Task\nvieja\n## Groups\n- [x] g1\n' > "$STC/.iamlazy/contract.md"
touch -t 201901010000 "$STC/.iamlazy/contract.md"
open_real "$STC" sid-st
run_flush "$STC" "$(stop_payload "$STC" 'analizando' sid-st)" >/dev/null
if [ -f "$(runfile "$STC" sid-st)" ]; then ok "un contrato anterior a la apertura no cierra la corrida nueva"
else no "un contrato viejo cerro la corrida nueva en su primer turno"; fi
assert_ungrep '"base_ref"' "$(runfile "$STC" sid-st)" "y no se adopta como contrato de esta corrida"

# La linea base de archivos sin seguimiento se toma al ABRIR. Tomada al adoptar
# el contrato, un archivo creado por la corrida antes del contrato pasaria por
# preexistente: invisible para el gate de alcance.
NEWF="$(mkrepo)"
mkdir -p "$NEWF/src"; echo base > "$NEWF/src/a.ts"; git -C "$NEWF" add -A; git -C "$NEWF" commit -q -m init
open_real "$NEWF" sid-nf
echo nuevo > "$NEWF/extra.txt"
mkdir -p "$NEWF/.iamlazy"
printf '# Task\nx\n## Scope\n- src/*\n## Groups\n- [x] g1\n' > "$NEWF/.iamlazy/contract.md"
out="$(run_flush "$NEWF" "$(stop_payload "$NEWF" "$CLOSE_MSG" sid-nf)")"
case "$out" in
  *extra.txt*) ok "un archivo creado antes del contrato sigue fuera de alcance, y se nombra" ;;
  *) no "un archivo creado antes del contrato se tomo por preexistente (obtuvo: ${out:-<vacio>})" ;;
esac

echo
echo "un cliente que pega el skill en vez de enviar /iamlazy (MonoCode)"

# MonoCode 0.7.0 no envia /iamlazy: envia su propio preambulo y el SKILL.md
# completo, frontmatter incluido, con $ARGUMENTS sin reemplazar. Forma real
# medida el 2026-10-05. Sin detector, el modelo seguia todo el protocolo sin
# ninguna garantia y sin aviso.
mono_payload() { # $1 dir  $2 sid  $3 permission_mode  $4 nombre del skill
  # shellcheck disable=SC2016  # $ARGUMENTS is the literal MonoCode leaves in place
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"/x.jsonl","cwd":"%s","permission_mode":"%s","prompt":"The user invoked skill(s) with /name. Follow every instruction in each skill body.\\n\\n## /%s\\n\\n---\\nname: %s\\ndescription: x\\ndisable-model-invocation: true\\n# iamlazy-managed\\n---\\n# cuerpo\\n\\n**Request:** $ARGUMENTS\\n"}' \
    "$2" "$1" "$3" "$4" "$4"
}
MONO="$(mkrepo)"
run_open "$MONO" "$(mono_payload "$MONO" sid-mono default iamlazy)" >/dev/null
if [ -f "$(runfile "$MONO" sid-mono)" ]; then ok "un skill pegado por el cliente abre la corrida igual que /iamlazy"
else no "un skill pegado por el cliente no abrio la corrida: el harness corre sin garantias"; fi

MONB="$(mkrepo)"
printf '%s' "$(mono_payload "$MONB" sid-monb bypassPermissions iamlazy)" | HOME="$MONB" "$SRC/hooks/open-run.sh" >/dev/null 2>&1; monb_rc=$?
if [ "$monb_rc" = "2" ] && [ ! -f "$(runfile "$MONB" sid-monb)" ]; then
  ok "pegado bajo bypass, se rechaza en voz alta en vez de correr sin garantias"
else no "pegado bajo bypass no se rechazo (rc=$monb_rc)"; fi

MONR="$(mkrepo)"
run_open "$MONR" "$(mono_payload "$MONR" sid-monr default iamlazy-review)" >/dev/null
assert_absent "$(runfile "$MONR" sid-monr)" "el skill iamlazy-review pegado no abre una corrida"

MONT="$(mkrepo)"
run_open "$MONT" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-mont","transcript_path":"/x.jsonl","cwd":"'"$MONT"'","prompt":"en el SKILL.md puse name: iamlazy\\n y nada mas"}' >/dev/null
assert_absent "$(runfile "$MONT" sid-mont)" "un prompt que solo menciona el nombre, sin el marcador, no abre corrida"

echo
echo "historial — el contrato y el journal anteriores se archivan al abrir"

ARC="$(mkrepo)"
mkdir -p "$ARC/.iamlazy"
printf '# Task\nanterior\n' > "$ARC/.iamlazy/contract.md"
printf 'journal anterior\n' > "$ARC/.iamlazy/journal.md"
run_open "$ARC" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-arc","transcript_path":"/x.jsonl","cwd":"'"$ARC"'","prompt":"/iamlazy tarea nueva"}'
assert_absent "$ARC/.iamlazy/contract.md" "al abrir, el contrato anterior sale de .iamlazy/"
assert_absent "$ARC/.iamlazy/journal.md" "y el journal anterior tambien: el Critic recibe solo el de esta corrida"
arc_hist="$(find "$ARC/.iamlazy/history" -name contract.md 2>/dev/null | head -1)"
if [ -n "$arc_hist" ] && grep -q anterior "$arc_hist" && [ -f "$(dirname "$arc_hist")/journal.md" ]; then
  ok "los dos quedan archivados juntos en .iamlazy/history/<fecha>/"
else no "el contrato y el journal anteriores no quedaron archivados juntos"; fi

# Otra sesion con una corrida abierta en el mismo directorio: se avisa al
# humano, y NO se archiva nada, porque esos archivos son de la otra corrida.
TWR="$(mkrepo)"
run_open "$TWR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-a","transcript_path":"/x.jsonl","cwd":"'"$TWR"'","prompt":"/iamlazy tarea a"}'
mkdir -p "$TWR/.iamlazy"; printf '# Task\nde a\n' > "$TWR/.iamlazy/contract.md"
out="$(run_open "$TWR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-b","transcript_path":"/x.jsonl","cwd":"'"$TWR"'","prompt":"/iamlazy tarea b"}')"
case "$out" in
  *'"systemMessage"'*'otra sesion'*sid-a*) ok "una segunda corrida en el mismo directorio avisa al humano, nombrando la otra sesion" ;;
  *) no "dos corridas en el mismo directorio no avisaron (obtuvo: ${out:-<vacio>})" ;;
esac
assert_grep 'de a' "$TWR/.iamlazy/contract.md" "y no archiva el contrato vivo de la otra corrida"
OTH="$(mkrepo)"
out="$(run_open "$TWR" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-c","transcript_path":"/x.jsonl","cwd":"'"$OTH"'","prompt":"/iamlazy en otro repo"}')"
if [ -z "$out" ]; then ok "una corrida en otro directorio no avisa nada"
else no "aviso de corrida simultanea fuera de su directorio: $out"; fi

echo
echo "el Critic en segundo plano — se lee de sus propios archivos"

# Claude Code 2.1.287 corre el Critic en segundo plano y devuelve su informe
# con una llamada a SubagentHandback. El tally viaja ahi dentro, no en el
# ultimo texto del Critic, y el log real quedo vacio sobre un 0/1/3/5. La
# primera linea de su transcript (prompt_snapshot) lista sus herramientas,
# SubagentHandback incluida, y el ejemplo de tally de su prompt.
crit_dir() { # $1 dir -> crea la sesion y devuelve el directorio de sub-agentes
  : > "$1/sess.jsonl"; mkdir -p "$1/sess/subagents"; printf '%s' "$1/sess/subagents"
}
crit_meta() { # $1 subagents dir  $2 id  [$3 requestShape]
  printf '{"agentType":"iamlazy-critic","description":"r","toolUseId":"toolu_%s","spawnDepth":1,"requestShape":"%s","requestNonInteractive":true}' \
    "$2" "${3:-background}" > "$1/agent-$2.meta.json"
}
crit_snapshot() { # $1 subagents dir  $2 id
  printf '{"type":"attachment","attachment":{"type":"prompt_snapshot","tools":[{"name":"SubagentHandback"}],"system":"Close with your own tally: findings: 9/9/9/9"}}\n' \
    > "$1/agent-$2.jsonl"
}
crit_handback() { # $1 subagents dir  $2 id  $3 tally
  printf '{"type":"assistant","message":{"id":"msg_%s","model":"claude-opus-5","content":[{"type":"tool_use","id":"toolu_h%s","name":"SubagentHandback","input":{"message":"Informe.\\nfindings: %s"}}],"usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
    "$2" "$2" "$3" >> "$1/agent-$2.jsonl"
}
crit_contract() { mkdir -p "$1/.iamlazy"; printf '# Task\nx\n## Groups\n- [x] g1\n' > "$1/.iamlazy/contract.md"; }

CRH="$(mkrepo)"; SUBD="$(crit_dir "$CRH")"
open_real "$CRH" sid-cr "$CRH/sess.jsonl"; crit_contract "$CRH"
crit_meta "$SUBD" aaa; crit_snapshot "$SUBD" aaa; crit_handback "$SUBD" aaa "0/1/3/5"
run_flush "$CRH" "$(stop_payload "$CRH" "$CLOSE_MSG" sid-cr "$CRH/sess.jsonl")" >/dev/null
assert_grep '"critic_findings":"0/1/3/5"' "$CRH/.iamlazy/runs.jsonl" "el tally del Critic se lee de su SubagentHandback"
assert_grep '"close_detected_via":"contract"' "$CRH/.iamlazy/runs.jsonl" "y la corrida cierra por contrato con la revision devuelta"

# Mientras revisa, ningun cierre pasa: ni con el banner. Su prompt_snapshot ya
# nombra SubagentHandback; leerlo como "termino" cerraba a los tres segundos.
CRR="$(mkrepo)"; SUBD="$(crit_dir "$CRR")"
open_real "$CRR" sid-rr "$CRR/sess.jsonl"; crit_contract "$CRR"
crit_meta "$SUBD" bbb; crit_snapshot "$SUBD" bbb
out="$(run_flush "$CRR" "$(stop_payload "$CRR" "$CLOSE_MSG" sid-rr "$CRR/sess.jsonl")")"
if [ -f "$(runfile "$CRR" sid-rr)" ]; then ok "con el Critic revisando en segundo plano, el banner de CIERRE no cierra"
else no "la corrida cerro mientras el Critic seguia revisando"; fi
case "$out" in
  *'sigue revisando'*) ok "el bloqueo dice que el Critic sigue revisando" ;;
  *) no "el bloqueo no explico que el Critic sigue revisando (obtuvo: ${out:-<vacio>})" ;;
esac
assert_absent "$CRR/.iamlazy/active/sid-rr.findings" "la lista de herramientas no se toma por un informe"

# Termino sin devolver informe: su aviso de tarea ya trae <status>. No esta
# revisando, asi que vale el camino de "se pregunto y no hubo revision".
CRN="$(mkrepo)"; SUBD="$(crit_dir "$CRN")"
open_real "$CRN" sid-nn "$CRN/sess.jsonl"; crit_contract "$CRN"
crit_meta "$SUBD" ccc; crit_snapshot "$SUBD" ccc
printf '{"type":"queue-operation","content":"<task-notification>\\n<task-id>ccc</task-id>\\n<status>failed</status>\\n</task-notification>"}\n' >> "$CRN/sess.jsonl"
run_flush "$CRN" "$(stop_payload "$CRN" "$CLOSE_MSG" sid-nn "$CRN/sess.jsonl")" >/dev/null
assert_absent "$(runfile "$CRN" sid-nn)" "un Critic que termino sin informe no retiene la corrida"

# Muerto: sin informe, sin aviso, y sus archivos quietos hace mas de 30 minutos.
CRD="$(mkrepo)"; SUBD="$(crit_dir "$CRD")"
open_real "$CRD" sid-dd "$CRD/sess.jsonl"; crit_contract "$CRD"
crit_meta "$SUBD" ddd; crit_snapshot "$SUBD" ddd
touch -t 202101010000 "$SUBD/agent-ddd.meta.json" "$SUBD/agent-ddd.jsonl"
run_flush "$CRD" "$(stop_payload "$CRD" "$CLOSE_MSG" sid-dd "$CRD/sess.jsonl")" >/dev/null
assert_absent "$(runfile "$CRD" sid-dd)" "un Critic quieto hace mas de 30 minutos se da por muerto"

# Un Critic de una corrida anterior en la misma sesion no cuenta para esta.
CRO="$(mkrepo)"; SUBD="$(crit_dir "$CRO")"
crit_meta "$SUBD" eee; crit_snapshot "$SUBD" eee; crit_handback "$SUBD" eee "7/7/7/7"
touch -t 201901010000 "$SUBD/agent-eee.meta.json"
open_real "$CRO" sid-oo "$CRO/sess.jsonl"; crit_contract "$CRO"
run_flush "$CRO" "$(stop_payload "$CRO" "$CLOSE_MSG" sid-oo "$CRO/sess.jsonl")" >/dev/null
assert_ungrep '7/7/7/7' "$CRO/.iamlazy/runs.jsonl" "el informe de un Critic anterior a esta corrida no se le atribuye"

echo
echo "un hook que se cae sale con 0 y deja constancia"

# Los hooks estan registrados globalmente: un crash salia con 1 y la sesion
# mostraba un error de hook aunque no tuviera nada que ver con iamlazy.
CRASH="$(mktmp)"
# shellcheck disable=SC2016  # $NO_EXISTE belongs to the generated script, unexpanded on purpose
printf '#!/usr/bin/env bash\nset -u\n. "%s/hooks/lib.sh"\nhk_crash_guard\necho "$NO_EXISTE"\n' "$SRC" > "$CRASH/boom.sh"
chmod +x "$CRASH/boom.sh"
HOME="$CRASH" "$CRASH/boom.sh" </dev/null >/dev/null 2>&1; crash_rc=$?
if [ "$crash_rc" = "0" ]; then ok "un hook que se cae sale con 0, no con un error en cada sesion"
else no "un hook que se cae salio con $crash_rc"; fi
assert_grep 'boom.sh exit=1' "$CRASH/.iamlazy/hooks.log" "y la falla queda en ~/.iamlazy/hooks.log, con el hook y el codigo"
printf '#!/usr/bin/env bash\nset -u\n. "%s/hooks/lib.sh"\nhk_crash_guard\nexit 2\n' "$SRC" > "$CRASH/block.sh"
chmod +x "$CRASH/block.sh"
HOME="$CRASH" "$CRASH/block.sh" </dev/null >/dev/null 2>&1; block_rc=$?
if [ "$block_rc" = "2" ]; then ok "un bloqueo deliberado (exit 2) pasa intacto"
else no "la trampa se trago un exit 2 deliberado (obtuvo $block_rc)"; fi

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

# Grupos abiertos a mitad de corrida son el plan funcionando, no una alarma.
GRP="$(mkrepo)"
mkdir -p "$GRP/.iamlazy"
printf '## Grupos\n- [x] g1\n- [ ] g2\n' > "$GRP/.iamlazy/contract.md"
open_run "$GRP" "$GRP" 5 "s"; set_base "$GRP" "s" "$GRP"
out="$(run_open "$GRP" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$GRP"'","prompt":"sigue"}')"
case "$out" in
  *"NO puede cerrar"*) no "con solo grupos abiertos, la linea alarma como si hubiera un desvio: $out" ;;
  *"Grupos sin marcar: 1"*) ok "con solo grupos abiertos, la linea los cuenta sin alarmar" ;;
  *) no "la linea no conto los grupos abiertos (obtuvo: ${out:-<vacio>})" ;;
esac

# Un contrato que esta corrida no escribio no se describe como suyo. Corrida
# real (sperant, 2026-10-03): no escribio contrato, y esta linea le dijo al
# modelo que "el contrato esta completo" leyendo el de la corrida anterior.
STL="$(mkrepo)"
mkdir -p "$STL/.iamlazy"
printf '# Task\nla tarea de ayer\n## Groups\n- [x] g1\n' > "$STL/.iamlazy/contract.md"
open_run "$STL" "$STL" 5 "s"
out="$(run_open "$STL" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$STL"'","prompt":"sigue"}')"
case "$out" in
  *"completo"*) no "un contrato ajeno se describio como completo: $out" ;;
  *"todavia no escribio su contrato"*) ok "un contrato que esta corrida no escribio no se describe como suyo" ;;
  *) no "la linea no dijo que falta el contrato de esta corrida (obtuvo: ${out:-<vacio>})" ;;
esac
# Y el log no toma su tarea: esa corrida cerro por banner con el resumen ajeno.
run_flush "$STL" "$(stop_payload "$STL" "$CLOSE_MSG" s)" >/dev/null
assert_ungrep 'la tarea de ayer' "$STL/.iamlazy/runs.jsonl" "task_summary no sale de un contrato que esta corrida no escribio"

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
assert_grep '"schema_version":10' "$CBA/.iamlazy/runs.jsonl" "la linea abandonada declara el schema vigente"
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
printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":22000000,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
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

# Sin precio, el breaker por costo queda apagado: el ratio y el techo en dolares
# necesitan un costo. Eso pasaba en silencio, y es el caso normal el dia que
# sale un modelo nuevo. Se avisa al humano UNA vez, a mitad de corrida, para que
# lo arregle mientras todavia sirve.
UNW="$(mkrepo)"
mkdir -p "$UNW/.iamlazy"
printf '## Groups\n- [ ] g1\n' > "$UNW/.iamlazy/contract.md"
open_run_tok "$UNW" "$UNW"; set_base "$UNW" "s" "$UNW"
printf '{"model":"modelo-del-futuro","message":{"id":"msg_X","usage":{"input_tokens":0,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$UNW/t.jsonl"
out="$(run_flush "$UNW" "$(stop_payload "$UNW" 'sigo con g1' s "$UNW/t.jsonl")")"
case "$out" in
  *'"systemMessage"'*'no hay precio'*modelo-del-futuro*) ok "un modelo sin precio se avisa al humano, nombrandolo, a mitad de corrida" ;;
  *) no "el breaker quedo ciego sin avisar (obtuvo: ${out:-<vacio>})" ;;
esac
out="$(run_flush "$UNW" "$(stop_payload "$UNW" 'sigo con g1' s "$UNW/t.jsonl")")"
if [ -z "$out" ]; then ok "el aviso de modelo sin precio no se repite"
else no "el aviso de modelo sin precio se repitio: $out"; fi

# Y con todo valorado no se dice nada: un aviso que salta fuera de su dominio
# es un defecto.
PRI="$(mkrepo)"
mkdir -p "$PRI/.iamlazy"
printf '## Groups\n- [ ] g1\n' > "$PRI/.iamlazy/contract.md"
open_run_tok "$PRI" "$PRI"; set_base "$PRI" "s" "$PRI"
mk_transcript "$PRI" 25000
out="$(run_flush "$PRI" "$(stop_payload "$PRI" 'sigo con g1' s "$PRI/t.jsonl")")"
if [ -z "$out" ]; then ok "con todos los modelos valorados no hay aviso"
else no "aviso de precio sin que falte ninguno: $out"; fi

# Dos avisos en el mismo Stop salen en UN solo JSON. Antes cada uno imprimia el
# suyo, y dos objetos seguidos no son JSON valido: no se mostraba ninguno.
TWO="$(mktmp)"
mkdir -p "$TWO/.iamlazy"
open_run_tok "$TWO" "$TWO"
printf '{"model":"modelo-del-futuro","message":{"id":"msg_X","usage":{"input_tokens":0,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' > "$TWO/t.jsonl"
out="$(run_flush "$TWO" "$(stop_payload "$TWO" 'turno' s "$TWO/t.jsonl")")"
n_json="$(printf '%s\n' "$out" | grep -c '^{')"
case "$out" in
  *'no es un repositorio git'*'modelo-del-futuro'*|*'modelo-del-futuro'*'no es un repositorio git'*)
    if [ "$n_json" = "1" ]; then ok "dos avisos en el mismo Stop salen en un solo JSON"
    else no "dos avisos salieron en $n_json objetos JSON: la salida no es JSON valido"; fi ;;
  *) no "faltaba alguno de los dos avisos (obtuvo: ${out:-<vacio>})" ;;
esac

# El README prometia que iamlazy propone .iamlazy/ en el .gitignore si falta, y
# nada lo hacia. Se dice al cerrar, una vez por corrida.
GIG="$(mkrepo)"
mkdir -p "$GIG/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$GIG/.iamlazy/contract.md"
open_run "$GIG" "$GIG" 5; set_base "$GIG" "sid-x" "$GIG"
out="$(run_flush "$GIG" "$(stop_payload "$GIG" "$CLOSE_MSG")")"
case "$out" in
  *'"systemMessage"'*'.gitignore'*) ok "al cerrar, propone .iamlazy/ en el .gitignore si falta" ;;
  *) no "no propuso .iamlazy/ en el .gitignore (obtuvo: ${out:-<vacio>})" ;;
esac
GIG2="$(mkrepo)"
mkdir -p "$GIG2/.iamlazy"
printf '.iamlazy/\n' > "$GIG2/.gitignore"
printf '## Groups\n- [x] g1\n## Scope\n- .gitignore\n' > "$GIG2/.iamlazy/contract.md"
open_run "$GIG2" "$GIG2" 5; set_base "$GIG2" "sid-x" "$GIG2"
out="$(run_flush "$GIG2" "$(stop_payload "$GIG2" "$CLOSE_MSG")")"
case "$out" in
  *'.gitignore'*) no "propuso el .gitignore en un repo que ya ignora .iamlazy/" ;;
  *) ok "si .iamlazy/ ya esta ignorado, no dice nada" ;;
esac

echo "guarantee 2 — models seen"

# Que modelo respondio, y cuantas veces. La cuenta es lo que identifica la
# etapa: una lista pelada solo dice que los dos aparecieron.
#
# El transcript trae msg_4 dos veces -- un mensaje se registra una vez por chunk
# de streaming, asi que contarlos crudos inventa turnos que no existieron.
MOD="$(mkrepo)"
MODT="$(mktmp)"
mkdir -p "$MOD/.iamlazy" "$MOD/.iamlazy/active"
mk_prices "$MOD"
printf '## Groups\n- [x] g1\n' > "$MOD/.iamlazy/contract.md"
{
  printf '{"model":"claude-sonnet-5","message":{"id":"msg_1","usage":{"output_tokens":1}}}\n'
  printf '{"model":"claude-sonnet-5","message":{"id":"msg_2","usage":{"output_tokens":1}}}\n'
  printf '{"model":"claude-sonnet-5","message":{"id":"msg_3","usage":{"output_tokens":1}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_4","usage":{"output_tokens":1}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_4","usage":{"output_tokens":1}}}\n'
} > "$MODT/t.jsonl"
printf '{"schema_version":5,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"start_models":"","critic_asked":1,"outcome":"incomplete"}' \
  "$MODT/t.jsonl" "$MOD" "$(date +%s)" > "$(runfile "$MOD" s)"
set_base "$MOD" "s" "$MOD"
run_flush "$MOD" "$(stop_payload "$MOD" "$CLOSE_MSG" s "$MODT/t.jsonl")" >/dev/null
assert_grep '"models_seen":"claude-sonnet-5:3 claude-opus-5:1"' "$MOD/.iamlazy/runs.jsonl" \
  "el log nombra cada modelo con cuantos mensajes respondio, el mas usado primero"

# El transcript acumula toda la SESION, no la corrida: lo que ya estaba antes de
# abrir no se cobra aca. Mismo delta que el costo y las intervenciones.
# Con la base restada quedan 1 y 1, y el empate se rompe por nombre para que el
# campo sea estable entre corridas.
MODB="$(mkrepo)"
mkdir -p "$MODB/.iamlazy" "$MODB/.iamlazy/active"
mk_prices "$MODB"
printf '## Groups\n- [x] g1\n' > "$MODB/.iamlazy/contract.md"
printf '{"schema_version":5,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"start_models":"claude-sonnet-5:2","critic_asked":1,"outcome":"incomplete"}' \
  "$MODT/t.jsonl" "$MODB" "$(date +%s)" > "$(runfile "$MODB" s)"
set_base "$MODB" "s" "$MODB"
run_flush "$MODB" "$(stop_payload "$MODB" "$CLOSE_MSG" s "$MODT/t.jsonl")" >/dev/null
assert_grep '"models_seen":"claude-opus-5:1 claude-sonnet-5:1"' "$MODB/.iamlazy/runs.jsonl" \
  "lo que el modelo ya habia gastado antes de abrir la corrida no cuenta como suyo"

# El Critic corre en su propio transcript, y suele ser el unico modelo que una
# corrida decorrelaciona a proposito: omitirlo esconde justo el split que este
# campo existe para mostrar.
MODS="$(mkrepo)"
MODST="$(mktmp)"
mkdir -p "$MODS/.iamlazy" "$MODS/.iamlazy/active" "$MODST/t/subagents"
mk_prices "$MODS"
printf '## Groups\n- [x] g1\n' > "$MODS/.iamlazy/contract.md"
printf '{"model":"claude-sonnet-5","message":{"id":"msg_9","usage":{"output_tokens":1}}}\n' > "$MODST/t.jsonl"
printf '{"model":"claude-opus-5","message":{"id":"msg_C","usage":{"output_tokens":1}}}\n' > "$MODST/t/subagents/c.jsonl"
printf '{"schema_version":5,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"start_models":"","critic_asked":1,"outcome":"incomplete"}' \
  "$MODST/t.jsonl" "$MODS" "$(date +%s)" > "$(runfile "$MODS" s)"
set_base "$MODS" "s" "$MODS"
run_flush "$MODS" "$(stop_payload "$MODS" "$CLOSE_MSG" s "$MODST/t.jsonl")" >/dev/null
assert_grep 'claude-opus-5:1' "$MODS/.iamlazy/runs.jsonl" \
  "el modelo del Critic, que corre en su propio transcript, entra en la cuenta"

# Una corrida abandonada es donde mas importa saber que modelo quemo los tokens:
# las dos lineas mas largas del log nunca cerraron.
MODA="$(mkrepo)"
MODAT="$(mktmp)"
mkdir -p "$MODA/.iamlazy/active"
mk_prices "$MODA"
printf '{"model":"claude-opus-5","message":{"id":"msg_A","usage":{"output_tokens":1}}}\n' > "$MODAT/t.jsonl"
printf '{"schema_version":5,"session_id":"ab","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"start_models":"","outcome":"incomplete"}' \
  "$MODAT/t.jsonl" "$MODA" "$(date +%s)" > "$(runfile "$MODA" ab)"
run_end "$MODA" '{"hook_event_name":"SessionEnd","session_id":"ab","cwd":"'"$MODA"'"}'
assert_grep '"models_seen":"claude-opus-5:1"' "$MODA/.iamlazy/runs.jsonl" \
  "la corrida abandonada tambien registra con que modelo se gasto"

echo "guarantee 2 — hooks_version"

# Stamped once by install.sh at ~/.iamlazy/hooks_version, read back at every
# close: not what --check compares (that is byte-for-byte, strictly more
# precise), but the question --check cannot answer -- which version of the
# enforcement code produced THIS log line, for a run reviewed after a fix
# landed.
HV="$(mkrepo)"
mkdir -p "$HV/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$HV/.iamlazy/contract.md"
open_run "$HV" "$HV" 5
set_base "$HV" "sid-x" "$HV"
printf 'abc1234\n' > "$HV/.iamlazy/hooks_version"
run_flush "$HV" "$(stop_payload "$HV" "$CLOSE_MSG")" >/dev/null
assert_grep '"hooks_version":"abc1234"' "$HV/.iamlazy/runs.jsonl" \
  "el cierre estampa la version de los hooks que lo escribieron"

HVA="$(mkrepo)"
mkdir -p "$HVA/.iamlazy"
open_run "$HVA" "$HVA" 5
printf 'def5678\n' > "$HVA/.iamlazy/hooks_version"
run_end "$HVA" '{"hook_event_name":"SessionEnd","session_id":"sid-x","cwd":"'"$HVA"'"}'
assert_grep '"hooks_version":"def5678"' "$HVA/.iamlazy/runs.jsonl" \
  "la corrida abandonada tambien estampa la version de los hooks"

# Un install anterior a este campo no dejo el archivo: vacio, no un valor
# inventado.
HVN="$(mkrepo)"
mkdir -p "$HVN/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$HVN/.iamlazy/contract.md"
open_run "$HVN" "$HVN" 5
set_base "$HVN" "sid-x" "$HVN"
run_flush "$HVN" "$(stop_payload "$HVN" "$CLOSE_MSG")" >/dev/null
assert_grep '"hooks_version":""' "$HVN/.iamlazy/runs.jsonl" \
  "sin archivo hooks_version, el campo queda vacio, no inventado"

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
printf '{"schema_version":4,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
  "$SEMT/t.jsonl" "$SEM" "$(date +%s)" > "$(runfile "$SEM" s)"
set_base "$SEM" "s" "$SEM"
echo x > "$SEM/src/a.rb"
echo c >> "$SEM/PROJECT.md"
run_flush "$SEM" "$(stop_payload "$SEM" "$CLOSE_MSG" s "$SEMT/t.jsonl")" >/dev/null
assert_grep '"task_summary":"Add rate limiting to the \\"login\\" endpoint"' "$SEM/.iamlazy/runs.jsonl" \
  "task_summary derivado del contrato, con las comillas ESCAPADAS (no borradas)"
assert_grep '"project_md":"updated"' "$SEM/.iamlazy/runs.jsonl" "project_md derivado del diff"
assert_grep '"schema_version":10' "$SEM/.iamlazy/runs.jsonl" "la linea declara su schema"
assert_grep '"cost_usd":0.5000' "$SEM/.iamlazy/runs.jsonl" "cost_usd derivado del transcript y la tabla de precios"
assert_grep '"close_detected_via":"contract"' "$SEM/.iamlazy/runs.jsonl" \
  "PROJECT.md modificado no bloquea el cierre (es parte del cierre)"
assert_grep '"base_ref"' "$SEM/.iamlazy/runs.jsonl" "el log registra contra que base se midio"

# task_summary no puede partir un caracter UTF-8 multibyte al truncar a 160.
# `cut -c1-160` bajo un locale de bytes (C) cuenta BYTES, no caracteres: un
# acento que caiga justo en el limite deja un byte de cabecera colgado sin su
# continuacion, invalido dentro del JSON. Los contratos se escriben en el
# idioma del humano, y el de este proyecto es espanol.
UTFB="$(mkrepo)"
UTFBT="$(mktmp)"
mkdir -p "$UTFB/.iamlazy" "$UTFB/.iamlazy/active"
filler=$(printf 'x%.0s' $(seq 1 159))
printf '# Task\n%so resto del texto que sigue despues del corte\n\n## Groups\n- [x] g1\n' \
  "${filler}ó" > "$UTFB/.iamlazy/contract.md"
mk_transcript "$UTFBT" 100000
mk_prices "$UTFB"
printf '{"schema_version":5,"session_id":"s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":1,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"start_models":"","critic_asked":1,"outcome":"incomplete"}' \
  "$UTFBT/t.jsonl" "$UTFB" "$(date +%s)" > "$(runfile "$UTFB" s)"
set_base "$UTFB" "s" "$UTFB"
LC_ALL=C run_flush "$UTFB" "$(stop_payload "$UTFB" "$CLOSE_MSG" s "$UTFBT/t.jsonl")" >/dev/null
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "
import json
for l in open('$UTFB/.iamlazy/runs.jsonl', encoding='utf-8'):
    l = l.strip()
    if l: json.loads(l)
" 2>/dev/null; then ok "task_summary no parte un caracter UTF-8 al truncar (LC_ALL=C)"
  else no "task_summary partio un caracter UTF-8 al truncar bajo LC_ALL=C"; fi
else
  no "python3 ausente: no se pudo validar el UTF-8 de task_summary"
fi

# hk_utf8_cut, directo. El test end-to-end de arriba SOLO falla donde `cut -c`
# es byte-based -- o sea en Linux, nunca en macOS, cuyo cut BSD si respeta el
# locale. Eso lo dejo verde durante un dia entero mientras CI estaba en rojo.
# Estas afirmaciones ejercitan el helper contra bytes elegidos a mano, asi que
# tienen dientes en TODA plataforma.
cut_case() { # $1 label  $2 bytes (formato de printf)  $3 n  $4 esperado
  # shellcheck disable=SC2059  # el argumento ES el formato: asi se expanden los
  # escapes octales que construyen los bytes exactos que se quieren probar
  got=$(printf "$2" | ( . "$SRC/hooks/lib.sh"; hk_utf8_cut "$3" ))
  if [ "$got" = "$4" ]; then ok "hk_utf8_cut: $1"
  else no "hk_utf8_cut: $1 (esperaba '$4', obtuvo '$got')"; fi
}
# El corte cae DENTRO de una 'o' acentuada (2 bytes): se descarta entera.
cut_case "descarta un caracter partido al medio" 'abcdefghi\303\263XYZ\n' 10 "abcdefghi"
# El mismo caracter, completo justo en el limite: se conserva, no se sobre-corta.
cut_case "conserva un caracter completo en el limite" 'abcdefgh\303\263XYZ\n' 10 "$(printf 'abcdefgh\303\263')"
# Un emoji de 4 bytes partido: tambien entero.
cut_case "descarta un emoji partido" 'abcdefgh\360\237\232\200ZZ\n' 10 "abcdefgh"
cut_case "corte limpio en ASCII" 'abcdefghijKLM\n' 10 "abcdefghij"
cut_case "entrada mas corta que el limite" 'abc\n' 10 "abc"

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
# shellcheck disable=SC2016  # grep pattern, not shell expansion
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
      if [ "$exp" = 1 ]; then ok "[$loc] $st dispara el cierre"
      else ok "[$loc] $st NO dispara el cierre"; fi
    else
      if [ "$exp" = 1 ]; then no "[$loc] $st debia disparar el cierre (los hooks no conocen la etapa que el prompt declara)"
      else no "[$loc] $st NO debia disparar el cierre"; fi
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

# El ULTIMO registro de un mensaje trae su uso final. El transcript escribe un
# registro por bloque de contenido, cada uno con el uso de ese momento: en el
# Critic real el primero decia 1 token de salida y el ultimo 168.
{
  printf '{"model":"claude-opus-5","message":{"id":"msg_L","usage":{"input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_L","usage":{"input_tokens":0,"output_tokens":168,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
} > "$DEDUP/last.jsonl"
gotl=$(. "$SRC/hooks/lib.sh"; hk_token_components "$DEDUP/last.jsonl")
gotlc=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/last.jsonl" "$PRICES")
gotlm=$(. "$SRC/hooks/lib.sh"; hk_model_counts "$DEDUP/last.jsonl")
gotls=$(. "$SRC/hooks/lib.sh"; hk_transcript_scan "$DEDUP/last.jsonl" "$PRICES" | sed -n '2p')
# 168 x \$25/MTok = 4.200 micro-dolares; con el primer registro serian 25.
if [ "$gotl" = "168 0 0" ] && [ "$gotlc" = "4200" ] && [ "$gotls" = "168 0 0" ]; then
  ok "un mensaje se cuenta por su ULTIMO registro, el del uso final"
else no "se conto un registro parcial: componentes '$gotl', costo '$gotlc', escaneo '$gotls'"; fi
if [ "$gotlm" = "claude-opus-5:1 " ]; then ok "y sigue contando un mensaje, no dos"
else no "dos registros del mismo mensaje se contaron dos veces: '$gotlm'"; fi

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

# TTL de 1 hora. Toda escritura de cache en dos transcripts reales de Claude
# Code (medido 2026-10-02) era de 1 h, que vale x2 y no x1,25. El transcript lo
# dice por mensaje: ephemeral_1h_input_tokens, y el resto es de 5 minutos.
printf '{"model":"claude-opus-5","message":{"id":"msg_H","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":600}}}}\n' > "$DEDUP/h.jsonl"
goth=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/h.jsonl" "$PRICES")
# 400x5x1,25 + 600x5x2 = 2.500 + 6.000 = 8.500 micro
if [ "$goth" = "8500" ]; then ok "la escritura de cache de 1 h vale x2, la de 5 min x1,25"
else no "TTL de cache mal valorado: esperaba 8500, obtuvo $goth"; fi

# Lectura de cache por modelo. Opus 5.5 lee a 0,05x y Fable 5.1 a 0,025x; con
# la lectura cerca del 90% de los tokens, el 0,1x fijo triplicaba una corrida
# de Fable. La cuarta columna de prices.conf es el precio de lectura.
printf 'claude-opus-5-5 4.00 20.00 0.20\nclaude-opus-5 5.00 25.00\n' > "$DEDUP/p4.conf"
printf '{"model":"claude-opus-5-5","message":{"id":"msg_R4","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000000}}}\n' > "$DEDUP/r4.jsonl"
gotr=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/r4.jsonl" "$DEDUP/p4.conf")
# 1.000.000 x \$0,20/MTok = 200.000 micro. Con el 0,1x fijo darian 400.000.
if [ "$gotr" = "200000" ]; then ok "la cuarta columna de prices.conf fija el precio de lectura de cache"
else no "lectura de cache por modelo ignorada: esperaba 200000, obtuvo $gotr"; fi

# Lineas que tienen "usage" y no son un mensaje de la API. Un aviso de agente
# en segundo plano trae su propio usage sin modelo, y un mensaje <synthetic>
# trae un usage en cero. Las dos volvian null el costo de toda la corrida, la
# primera sin nombrar ningun modelo en cost_unpriced.
{
  printf '{"type":"attachment","attachment":{"type":"queued_command","usage":{"totalTokens":57414,"toolUses":5,"durationMs":41367}}}\n'
  printf '{"message":{"model":"<synthetic>","id":"msg_Z","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_N","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
} > "$DEDUP/n.jsonl"
gotn=$(. "$SRC/hooks/lib.sh"; hk_transcript_scan "$DEDUP/n.jsonl" "$PRICES" | sed -n '1p')
if [ "$gotn" = "2500" ]; then ok "un aviso de agente y un mensaje <synthetic> no vuelven null el costo"
else no "una linea que no es mensaje anulo el costo: esperaba 2500, obtuvo $gotn"; fi
gotu=$(. "$SRC/hooks/lib.sh"; hk_unpriced_models "$DEDUP/n.jsonl" "$PRICES")
if [ -z "$gotu" ]; then ok "<synthetic> no aparece como modelo sin precio"
else no "se nombro como sin precio algo que no consumio tokens: $gotu"; fi
gotm=$(. "$SRC/hooks/lib.sh"; hk_model_counts "$DEDUP/n.jsonl")
if [ "$gotm" = "claude-opus-5:1 " ]; then ok "models_seen no cuenta mensajes que no consumieron tokens"
else no "models_seen conto lineas que no son mensajes: '$gotm'"; fi

# Sin tabla de precios el costo es NULL, nunca 0. Con NR==FNR, un primer
# archivo vacio hacia que el cargador de precios se comiera el transcript
# entero: costo 0, tokens 0, sin modelos, una corrida "gratis" en la maquina
# donde --check promete que todo costo sera null.
gotnp=$(. "$SRC/hooks/lib.sh"; hk_transcript_scan "$DEDUP/n.jsonl" "$DEDUP/no-existe.conf")
np1=$(printf '%s\n' "$gotnp" | sed -n '1p'); np2=$(printf '%s\n' "$gotnp" | sed -n '2p'); np3=$(printf '%s\n' "$gotnp" | sed -n '3p')
if [ "$np1" = "NULL" ] && [ "$np2" = "100 0 0" ] && [ "$np3" = "claude-opus-5:1 " ]; then
  ok "sin prices.conf: costo NULL, y tokens y modelos se cuentan igual"
else no "sin prices.conf: esperaba NULL / '100 0 0' / 'claude-opus-5:1 ', obtuvo $np1 / '$np2' / '$np3'"; fi
: > "$DEDUP/vacia.conf"
gotev=$(. "$SRC/hooks/lib.sh"; hk_cost_micro "$DEDUP/n.jsonl" "$DEDUP/vacia.conf")
if [ -z "$gotev" ]; then ok "con un prices.conf vacio no se inventa un costo"
else no "un prices.conf vacio produjo un costo: $gotev"; fi

echo
echo "hk_transcript_scan — una compactacion no arrastra la lectura anterior"

# El fix de rendimiento del ticket 06 fusiona hk_cost_micro + hk_token_components
# + hk_model_counts en un unico awk sobre el transcript. La trampa que el ticket
# nombra explicitamente: cualquier cache posicional (un offset de bytes, o un
# resultado guardado por path) se rompe en silencio si una compactacion reescribe
# el transcript bajo esa ventana -- el mismo motivo por el que models_seen ya es
# semantico, no posicional. Esta prueba llama a la funcion dos veces sobre el
# MISMO path: primero con un transcript, despues con ese path reescrito con
# contenido mas chico y otro modelo (la compactacion), y exige que la segunda
# lectura refleje solo lo que hay ahora.
SCAN="$(mktmp)"
mk_prices "$SCAN"
PRICES_SCAN="$SCAN/.iamlazy/prices.conf"
{
  printf '{"model":"claude-opus-5","message":{"id":"msg_1","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_2","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
  printf '{"model":"claude-opus-5","message":{"id":"msg_3","usage":{"input_tokens":0,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n'
} > "$SCAN/t.jsonl"
# 300 tokens de salida x $25/MTok = 7.500 micro-dolares.
before=$(. "$SRC/hooks/lib.sh"; hk_transcript_scan "$SCAN/t.jsonl" "$PRICES_SCAN")
before_cost=$(printf '%s\n' "$before" | sed -n '1p')
before_tok=$(printf '%s\n' "$before" | sed -n '2p')
before_models=$(printf '%s\n' "$before" | sed -n '3p')
if [ "$before_cost" = "7500" ] && [ "$before_tok" = "300 0 0" ] && [ "$before_models" = "claude-opus-5:3 " ]; then
  ok "antes de la compactacion: 3 mensajes de opus, 7.500 micro-dolares"
else
  no "lectura inicial incorrecta: costo=$before_cost tokens='$before_tok' modelos='$before_models'"
fi

# La compactacion: el MISMO path, reescrito con un solo mensaje de otro modelo.
printf '{"model":"claude-sonnet-5","message":{"id":"msg_9","usage":{"input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' \
  > "$SCAN/t.jsonl"
# 1 token de salida x $10/MTok = 10 micro-dolares.
after=$(. "$SRC/hooks/lib.sh"; hk_transcript_scan "$SCAN/t.jsonl" "$PRICES_SCAN")
after_cost=$(printf '%s\n' "$after" | sed -n '1p')
after_tok=$(printf '%s\n' "$after" | sed -n '2p')
after_models=$(printf '%s\n' "$after" | sed -n '3p')
if [ "$after_cost" = "10" ] && [ "$after_tok" = "1 0 0" ] && [ "$after_models" = "claude-sonnet-5:1 " ]; then
  ok "tras la compactacion: solo lo que hay ahora, nada de los 3 mensajes de opus que ya no estan"
else
  no "la compactacion arrastro la lectura anterior: costo=$after_cost tokens='$after_tok' modelos='$after_models'"
fi

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
  *"SIN PARSER JSON"*) ok "sin parser JSON lo dice explicitamente" ;;
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
mark_critic_asked "$LATE" s   # no es lo que este test verifica; sin esto no cierra
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
assert_grep '"drift_thresholds":"80000/50/3000000/3600/10000000"' "$DEFT/.iamlazy/runs.jsonl" "la linea registra los umbrales por defecto"
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
assert_grep '"drift_thresholds":"80000/50/3000000/3600/10000000"' "$BADT/.iamlazy/runs.jsonl" "un umbral no numerico se ignora y vale el default"

# --- techos absolutos: duracion y costo (2026-09-18) -----------------------
# El ratio es ciego al sintoma que PROJECT.md declara como el motivo del
# harness: "una corrida larga es el sintoma, no el caso de uso". El costo por
# linea BAJA cuanto mas crece una corrida, asi que una corrida larga, cara y
# productiva mantiene el ratio sano de punta a punta y el breaker no podia
# dispararle nunca. Medido: la corrida del 2026-09-18 duro 6386s y costo
# $12,87 con drift_fired:0 y $0,0296 por linea.

# Duracion: barata y sana por ratio, pero abierta mas de una hora.
# age_run <run file> <seconds> -- moves start_epoch into the past. sed to a
# temp file, the way the rest of this project rewrites files: these two lines
# used `sd`, which exists on the author's machine and on no CI runner, so the
# suite was green locally and red on every platform the first time it was pushed.
age_run() {
  sed -E "s/\"start_epoch\":[0-9]+/\"start_epoch\":$(( $(date +%s) - $2 ))/" "$1" > "$1.new" && mv "$1.new" "$1"
}
DURT="$(mkrepo)"; mk_cheap_run "$DURT"
age_run "$(runfile "$DURT" s)" 4000
if [ "$(flush_rc "$DURT" "$(stop_payload "$DURT" "$CLOSE_MSG" s "$DURT/t.jsonl")")" = "2" ]; then
  ok "una corrida de mas de una hora dispara el breaker aunque el ratio este sano"
else no "el techo de duracion no disparo sobre una corrida de 4000s"; fi
assert_grep '"drift_reason":"duration"' "$(runfile "$DURT" s)" "el run recuerda que disparo por duracion"

# Y no vuelve a hablar: misma bandera que el ratio, un aviso por corrida.
if [ "$(flush_rc "$DURT" "$(stop_payload "$DURT" "$CLOSE_MSG" s "$DURT/t.jsonl")")" = "2" ]; then
  no "el techo de duracion no debe repetir el aviso"
else ok "el techo de duracion avisa una sola vez"; fi
assert_grep '"drift_reason":"duration"' "$DURT/.iamlazy/runs.jsonl" "el motivo del breaker llega a la linea"
assert_grep '"schema_version":10' "$DURT/.iamlazy/runs.jsonl" "la linea con motivo declara el schema vigente"

# El techo mide trabajo, no reloj: 4000s abierta con 1000s esperando al humano
# son 3000s de trabajo, por debajo de la hora. Antes, una pausa de almuerzo con
# una pregunta pendiente lo disparaba al volver.
IDLT="$(mkrepo)"; mk_cheap_run "$IDLT"
age_run "$(runfile "$IDLT" s)" 4000
printf '1000' > "$IDLT/.iamlazy/active/s.idle"
if [ "$(flush_rc "$IDLT" "$(stop_payload "$IDLT" "$CLOSE_MSG" s "$IDLT/t.jsonl")")" = "2" ]; then
  no "el techo de duracion conto como trabajo la espera por el humano"
else ok "el techo de duracion descuenta el tiempo esperando al humano"; fi
assert_grep '"duration_seconds":40' "$IDLT/.iamlazy/runs.jsonl" "duration_seconds sigue siendo el reloj"
assert_grep '"idle_seconds":1000' "$IDLT/.iamlazy/runs.jsonl" "y la espera queda en la linea, para explicar el techo"

# La espera se mide sola: un turno que termina sin cerrar marca la hora, y el
# prompt siguiente suma el hueco.
GAP="$(mkrepo)"
mkdir -p "$GAP/.iamlazy"; printf '## Groups\n- [ ] g1\n' > "$GAP/.iamlazy/contract.md"
open_run "$GAP" "$GAP" 30 "s"; set_base "$GAP" "s" "$GAP"
run_flush "$GAP" "$(stop_payload "$GAP" 'te pregunto algo' s)" >/dev/null
if [ -f "$GAP/.iamlazy/active/s.laststop" ]; then ok "un turno que espera al humano marca la hora"
else no "el turno que espera al humano no marco la hora"; fi
printf '%s' $(( $(date +%s) - 600 )) > "$GAP/.iamlazy/active/s.laststop"
run_open "$GAP" '{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/x.jsonl","cwd":"'"$GAP"'","prompt":"respuesta"}' >/dev/null
gap_idle="$(cat "$GAP/.iamlazy/active/s.idle" 2>/dev/null)"
if [ "${gap_idle:-0}" -ge 600 ] 2>/dev/null && [ "${gap_idle:-0}" -lt 660 ] 2>/dev/null; then
  ok "el prompt siguiente suma la espera ($gap_idle s)"
else no "la espera no se sumo bien (idle=${gap_idle:-<vacio>})"; fi
assert_absent "$GAP/.iamlazy/active/s.laststop" "y la marca se consume: un segundo prompt no la cuenta dos veces"

# Mientras el Critic revisa en segundo plano, la espera es la corrida
# trabajando: no se marca como tiempo muerto.
CRI="$(mkrepo)"; SUBD="$(crit_dir "$CRI")"
open_real "$CRI" sid-ci "$CRI/sess.jsonl"; crit_contract "$CRI"
crit_meta "$SUBD" fff; crit_snapshot "$SUBD" fff
run_flush "$CRI" "$(stop_payload "$CRI" 'el Critic esta revisando' sid-ci "$CRI/sess.jsonl")" >/dev/null
assert_absent "$CRI/.iamlazy/active/sid-ci.laststop" "con el Critic revisando, la espera no cuenta como tiempo muerto"

# Costo absoluto: pocas lineas no alcanzan el piso del ratio, pero $12 es
# demasiado para una tarea sola.
COST="$(mkrepo)"
mkdir -p "$COST/.iamlazy"
printf '## Groups\n- [x] g1\n' > "$COST/.iamlazy/contract.md"
printf 'x\n%.0s' $(seq 1 10) > "$COST/f.txt"
mk_transcript "$COST" 12870000
open_run_tok "$COST" "$COST"; set_base "$COST" "s" "$COST"; rm -f "$COST/.iamlazy/active/s.untracked"
if [ "$(flush_rc "$COST" "$(stop_payload "$COST" "$CLOSE_MSG" s "$COST/t.jsonl")")" = "2" ]; then
  ok "una corrida de \$12,87 dispara el techo de costo"
else no "el techo de costo absoluto no disparo sobre \$12,87"; fi
assert_grep '"drift_reason":"cost"' "$(runfile "$COST" s)" "el run recuerda que disparo por costo"

# Los techos son configurables como los otros tres, y un valor no numerico
# tampoco puede convertirse en umbral.
RAIS="$(mkrepo)"; mk_cheap_run "$RAIS"
age_run "$(runfile "$RAIS" s)" 4000
printf 'DRIFT_MAX_SECONDS=7200\n' > "$RAIS/.iamlazy/config"
if [ "$(flush_rc "$RAIS" "$(stop_payload "$RAIS" "$CLOSE_MSG" s "$RAIS/t.jsonl")")" = "2" ]; then
  no "subir DRIFT_MAX_SECONDS debia silenciar el techo de duracion"
else ok "DRIFT_MAX_SECONDS se puede subir desde ~/.iamlazy/config"; fi

# Una corrida sana no gana un motivo: el campo vacio es el valor honesto.
assert_grep '"drift_reason":""' "$DEFT/.iamlazy/runs.jsonl" "una corrida sana registra el motivo vacio"

echo
echo "human_interventions — delta donde se puede contar, null donde no"

# El transcript acumula TODA la sesion, asi que el campo es el delta de la
# corrida: una segunda corrida en la misma sesion heredaria las interrupciones
# de la primera. Se abre con una interrupcion ya presente y se agregan dos.
HID="$(mkrepo)"
mkdir -p "$HID/.iamlazy"; mk_prices "$HID"
printf 'Request interrupted by user\n' > "$HID/t.jsonl"
run_open "$HID" '{"hook_event_name":"UserPromptSubmit","session_id":"sid-x","transcript_path":"'"$HID/t.jsonl"'","cwd":"'"$HID"'","prompt":"/iamlazy tarea"}'
mark_critic_asked "$HID" sid-x   # no es lo que este test verifica; sin esto no cierra
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
printf '{"schema_version":4,"host":"opencode","session_id":"s","transcript_path":"","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":0,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
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
printf '{"schema_version":4,"host":"opencode","session_id":"s","transcript_path":"","cwd":"%s","start_epoch":%s,"start_cost":0,"cost_priced":0,"start_out":0,"start_cw":0,"start_cr":0,"start_interventions":0,"critic_asked":1,"outcome":"incomplete"}' \
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
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"hc","host":"opencode","cost_micro":100000,"tokens_output":10,"tokens_cache_write":1,"tokens_cache_read":5,"model":"opencode-go/kimi-k2.7-code"}'
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"hc","host":"opencode","cost_micro":250000,"tokens_output":15,"tokens_cache_write":2,"tokens_cache_read":7,"model":"opencode-go/deepseek-v4-pro"}'
assert_grep '^cost_micro=350000$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula el costo de dos mensajes"
assert_grep '^tokens_output=25$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula tokens_output"
assert_grep '^tokens_cache_write=3$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula cache_write"
assert_grep '^tokens_cache_read=12$' "$HK/.iamlazy/active/hc.cost" "host-cost acumula cache_read"
run_cost "$HK" '{"hook_event_name":"Stop","session_id":"hc","cost_micro":999999}'
assert_grep '^cost_micro=350000$' "$HK/.iamlazy/active/hc.cost" "un evento que no es HostCost no toca el sidecar"
run_cost "$HK" '{"hook_event_name":"HostCost","session_id":"nadie","cost_micro":5}'
assert_absent "$HK/.iamlazy/active/nadie.cost" "sin corrida activa, host-cost es inerte"
# Un host que tarifa sus mensajes no tiene transcript que contar, asi que la
# cuenta de modelos se acumula mensaje a mensaje aca -- mismo trade que el costo.
assert_grep '^models=opencode-go/deepseek-v4-pro:1 opencode-go/kimi-k2.7-code:1$' \
  "$HK/.iamlazy/active/hc.cost" "host-cost acumula que modelo respondio cada mensaje"
# ...y el cierre tarifa la corrida con exactamente lo acumulado.
mkdir -p "$HK/.iamlazy"; printf '## Groups\n- [x] g1\n' > "$HK/.iamlazy/contract.md"
set_base "$HK" hc "$HK"
run_flush "$HK" "$(stop_payload "$HK" "$CLOSE_MSG" hc "")" >/dev/null
assert_grep '"cost_usd":0.3500' "$HK/.iamlazy/runs.jsonl" "el cierre tarifa la corrida con lo que host-cost acumulo"
assert_grep '"models_seen":"opencode-go/deepseek-v4-pro:1 opencode-go/kimi-k2.7-code:1"' \
  "$HK/.iamlazy/runs.jsonl" "el cierre registra los modelos que el host fue informando, sin transcript"
assert_absent "$HK/.iamlazy/active/hc.cost" "el cierre limpia el sidecar acumulado"

# Un host que no manda el modelo no inventa un bucket "unknown", que en el log
# se leeria como un modelo real.
HKN="$(mkrepo)"
open_run "$HKN" "$HKN" 30 hn
run_cost "$HKN" '{"hook_event_name":"HostCost","session_id":"hn","host":"opencode","cost_micro":100,"tokens_output":1,"tokens_cache_write":0,"tokens_cache_read":0}'
assert_ungrep '^models=' "$HKN/.iamlazy/active/hn.cost" "sin modelo en el evento, no se registra ninguno"

echo
echo "----------------------------------------"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
