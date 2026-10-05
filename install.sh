#!/usr/bin/env bash
# iamlazy installer — bash 3.2 compatible. Zero external deps (coreutils only;
# curl is needed only for the curl|bash remote path). Idempotent via the
# `iamlazy-managed` marker embedded in every generated file's frontmatter.
set -eu

MARKER="iamlazy-managed"

# /iamlazy and /iamlazy-review are SKILLS (2026-10-04). Claude Code merged
# custom commands into skills -- a command file and a skill folder create the
# same /name, and the skill wins a name conflict -- and clients that drive
# Claude Code, MonoCode 0.7.0 among them, list skills only: /iamlazy was
# installed, working, and absent from their menu. CC_CMD_DIR stays for one job:
# removing the command files an older install left there.
CC_SKILL_DIR="${HOME}/.claude/skills"
CC_CMD_DIR="${HOME}/.claude/commands"
CC_AGENT_DIR="${HOME}/.claude/agents"
OC_CMD_DIR="${HOME}/.config/opencode/commands"
OC_AGENT_DIR="${HOME}/.config/opencode/agents"
OC_HOOK_DIR="${HOME}/.config/opencode/iamlazy-hooks"
OC_PLUGIN_DIR="${HOME}/.config/opencode/plugins"
LOG_DIR="${HOME}/.iamlazy"
CC_HOOK_DIR="${HOME}/.claude/iamlazy-hooks"

# Files that make up the payload (relative to the repo root).
PAYLOAD="core/iamlazy.md core/iamlazy-review.md critic/iamlazy-critic.md \
hooks/lib.sh hooks/guard-agent.sh hooks/open-run.sh hooks/track-edit.sh hooks/flush-run.sh \
hooks/end-run.sh hooks/subagent-done.sh hooks/guard-critic-bash.sh hooks/host-cost.sh \
hooks/merge-settings.sh adapters/opencode/iamlazy.ts \
templates/claude-code/skill-iamlazy.frontmatter \
templates/claude-code/skill-review.frontmatter \
templates/claude-code/agent-critic.frontmatter \
templates/claude-code/guarantees.md templates/claude-code/gate.md \
templates/opencode/primary-iamlazy.frontmatter \
templates/opencode/command-iamlazy.frontmatter \
templates/opencode/command-review.frontmatter \
templates/opencode/subagent-critic.frontmatter \
templates/opencode/guarantees.md templates/opencode/gate.md \
models.conf prices.conf DELTAS.md"

# oc_major -> OpenCode's MAJOR version number, empty when it cannot be read.
#
# The two adapter shapes are not interchangeable, and the daemon says which one
# it wants only by refusing the other -- into its own log, where nobody looks.
# V1 is a loose module whose exports must all be functions; V2 needs
# `export default Plugin.define({id, setup})`. Deploying V1 on a 2.x daemon
# gets "Plugin must export a default definition with an id and an effect or
# setup function" and zero Layer 0, after install.sh has printed "listo."
# Confirmed against the real v2.0.1 binary with the unmodified V1 adapter, and
# corroborated by an unrelated plugin of the same shape failing identically.
#
# This is a GUARD, not a switch. Both official channels still serve 1.x
# (curl|bash resolves releases/latest = v1.18.31; `npm i -g opencode-ai` =
# 1.18.31, undeprecated), and 2.x ships under renamed packages
# (`@opencode/cli`), so V1 remains the correct default for most installs.
# See DELTAS.md Candidate 19.
#
# Empty means "no evidence", never "old" -- a binary that is absent or whose
# output does not parse is not a 1.x binary, and guessing either way is the
# exact mistake this exists to stop.
oc_major() {
  command -v opencode >/dev/null 2>&1 || return 0
  opencode --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true
}

# --------------------------------------------------------------------- check
#
# What is INSTALLED is what runs, and it drifts from the repo silently: three
# times in one day a fix was committed, the suite went green, and the machine
# kept running the previous bytes -- once leaving a run unable to close at all.
# Nothing said so. This turns the project's own principle, "verify against the
# running build, not the documentation", into a command.
#
# It reports and exits non-zero; it never repairs. Repairing is what install.sh
# is for, and a checker that silently fixes things is a checker you stop reading.
CHECK_FAIL=0
c_ok()   { echo "  ok    $1"; }
c_bad()  { echo "  MAL   $1" >&2; CHECK_FAIL=1; }
c_skip() { echo "  --    $1"; }

# c_same <repo file> <installed file> <label>
c_same() {
  if [ ! -f "$2" ]; then c_bad "$3: no instalado ($2)"
  elif cmp -s "$1" "$2"; then c_ok "$3"
  else c_bad "$3: la copia instalada difiere de este repo"; fi
}

# c_adapter_matches_daemon <V1|V2> -- the installed adapter shape against the
# daemon that has to load it. This asks the binary BEFORE anything fails, where
# c_load_failure below can only report a failure that already happened: a fresh
# install on the wrong daemon has no log line yet, so without this the check
# says "nunca fallo al cargar" about a plugin that cannot possibly load.
c_adapter_matches_daemon() {
  cam_major="$(oc_major)"
  if [ -z "$cam_major" ]; then
    c_skip "no pude leer la version de OpenCode: no puedo verificar que el adaptador $1 sea el que este daemon carga"
  elif [ "$1" = "V1" ] && [ "$cam_major" -ge 2 ]; then
    c_bad "hay un adaptador V1 instalado y este OpenCode es ${cam_major}.x: el daemon lo rechaza entero (DELTAS Candidate 19). Usa --tool=opencode-v2"
  elif [ "$1" = "V2" ] && [ "$cam_major" -lt 2 ]; then
    c_bad "hay un adaptador V2 instalado y este OpenCode es ${cam_major}.x: ese daemon espera la forma V1. Usa --tool=opencode"
  else
    c_ok "el adaptador $1 corresponde a OpenCode ${cam_major}.x"
  fi
}

# c_load_failure <plugin file> -- shared by both OpenCode adapter shapes. A
# load failure only matters if it happened to the bytes installed NOW: the
# log keeps every past one forever, and reporting those would make this check
# cry wolf about a bug already fixed -- a guarantee firing outside its domain
# is a defect, this project's own rule. ISO-8601 UTC strings compare
# correctly as strings, so the whole thing is one lexicographic comparison
# against the plugin file's own mtime.
c_load_failure() {
  oc_log="$HOME/.local/share/opencode/log/opencode.log"
  # Keyed on target= being EXACTLY this plugin, not on the line mentioning
  # "iamlazy" anywhere. The old pattern also matched a differently-named file
  # in the same directory -- a probe, a backup, a fork -- and reported ITS
  # failure as the installed adapter's. Found by tripping it for real: a
  # throwaway iamlazy-v1-probe.ts, deployed while proving V1 cannot load on a
  # 2.x daemon, made --check fail about a bundle that was loading fine.
  #
  # awk compares the field as a literal string, so a path full of regex
  # metacharacters needs no escaping, and target= is matched wherever it sits
  # rather than assuming another field always follows it.
  last_fail="$(awk -v want="target=$1" '
    index($0, "\"failed to load plugin\"") == 0 { next }
    {
      for (i = 2; i <= NF; i++)
        if ($i == want) { ts = $1; sub(/^timestamp=/, "", ts); print ts; break }
    }
  ' "$oc_log" 2>/dev/null | tail -1)"
  if [ -z "$last_fail" ]; then
    c_ok "opencode nunca fallo al cargar el plugin"
    return 0
  fi
  # `stat -f %m` is BSD. On GNU, `-f` is --file-system, so "%m" becomes a FILE
  # operand that fails while the real file's filesystem block STILL goes to
  # stdout -- a bare `a || b` captures that garbage together with the epoch,
  # every later parse fails, and under `set -e` the failing assignment took the
  # whole check down mid-run. Silently, and only on the platform CI runs: the
  # branch below was unreachable on Linux until a test finally reached it.
  # So each form is taken only if it yields a plain integer, and nothing here
  # is allowed to abort.
  mtime="$(stat -f %m "$1" 2>/dev/null || true)"
  case "$mtime" in ""|*[!0-9]*) mtime="$(stat -c %Y "$1" 2>/dev/null || true)" ;; esac
  case "$mtime" in ""|*[!0-9]*) mtime="" ;; esac
  installed_at=""
  if [ -n "$mtime" ]; then
    # Same split: BSD `date -r` reads an epoch, GNU `-r` reads a FILE and needs
    # `-d @epoch` instead. Shape-checked rather than trusted, for the same reason.
    installed_at="$(date -u -r "$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    case "$installed_at" in
      [0-9][0-9][0-9][0-9]-*) ;;
      *) installed_at="$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" ;;
    esac
    case "$installed_at" in [0-9][0-9][0-9][0-9]-*) ;; *) installed_at="" ;; esac
  fi
  if [ -z "$installed_at" ]; then
    # Saying "no failures since this install" here would be a lie: there IS a
    # failure, what is missing is the date to compare it against.
    c_skip "hay una falla de carga ($last_fail) pero no pude leer la fecha del adaptador para compararla"
  elif awk -v a="$last_fail" -v b="$installed_at" 'BEGIN{exit !(a>b)}'; then
    c_bad "opencode fallo al cargar el plugin en $last_fail, DESPUES de instalar estos bytes"
  else
    c_ok "sin fallas de carga desde que se instalo este adaptador (la ultima fue $last_fail)"
  fi
}

run_check() {
  echo "iamlazy check  (repositorio: $SRC)"

  echo "claude code"
  if [ -d "$CC_HOOK_DIR" ]; then
    for h in "$SRC"/hooks/*.sh; do
      c_same "$h" "$CC_HOOK_DIR/$(basename "$h")" "hook actualizado: $(basename "$h")"
    done
    for h in open-run guard-agent guard-critic-bash track-edit flush-run end-run subagent-done; do
      if grep -q "iamlazy-hooks/$h.sh" "$HOME/.claude/settings.json" 2>/dev/null; then
        c_ok "registrado: $h.sh"
      else c_bad "instalado pero NO registrado en settings.json: $h.sh"; fi
    done
    # A guarantee that can be switched off is worth saying out loud.
    if grep -q '"disableAllHooks"[[:space:]]*:[[:space:]]*true' "$HOME/.claude/settings.json" 2>/dev/null; then
      c_bad "disableAllHooks esta en true: Layer 0 esta instalado pero inerte"
    else c_ok "los hooks no estan deshabilitados"; fi
    if [ -f "$CC_SKILL_DIR/iamlazy/SKILL.md" ]; then
      if grep -q '{{' "$CC_SKILL_DIR/iamlazy/SKILL.md"; then c_bad "el prompt instalado tiene un token sin completar"
      else c_ok "prompt compuesto, sin tokens pendientes"; fi
      # Only a human may start a run. A skill the model can invoke by itself
      # starts with no /iamlazy in the prompt, so open-run.sh never opens the
      # run and the harness works with every guarantee off, silently.
      if grep -q '^disable-model-invocation: true$' "$CC_SKILL_DIR/iamlazy/SKILL.md"; then
        c_ok "/iamlazy solo lo puede lanzar un humano"
      else c_bad "el skill /iamlazy no tiene disable-model-invocation: true: el modelo podria lanzarlo sin abrir la corrida"; fi
    else c_bad "prompt no instalado: $CC_SKILL_DIR/iamlazy/SKILL.md"; fi
    for old in iamlazy.md iamlazy-review.md; do
      if [ -f "$CC_CMD_DIR/$old" ] && grep -q "$MARKER" "$CC_CMD_DIR/$old" 2>/dev/null; then
        c_bad "queda el comando viejo $CC_CMD_DIR/$old: corre install.sh para pasarlo a skill"
      fi
    done
  else
    c_skip "claude code: no hay directorio de hooks, no hay nada instalado"
  fi

  echo "opencode"
  if [ -d "$OC_HOOK_DIR" ]; then
    for h in "$SRC"/hooks/*.sh; do
      c_same "$h" "$OC_HOOK_DIR/$(basename "$h")" "hook actualizado: $(basename "$h")"
    done
    # Two adapter shapes can be installed here: V1's loose, dependency-free
    # iamlazy.ts, or V2's bundled iamlazy.js (adapters/opencode-v2/). They are
    # mutually exclusive on purpose -- the daemon must never find both -- so
    # disk state, not a remembered install choice, decides which checks run.
    if [ -f "$OC_PLUGIN_DIR/iamlazy.js" ]; then
      # V2's deployed file is a bundle: comparing it byte-for-byte against the
      # source would mean rebuilding here, which needs bun and a network
      # `bun install` -- this check stays read-only and cheap, so it verifies
      # the invariants a bad V2 install actually broke in production instead.
      if grep -q "$MARKER" "$OC_PLUGIN_DIR/iamlazy.js" 2>/dev/null; then
        c_ok "adaptador V2 instalado por este instalador"
      else c_bad "hay un adaptador V2 pero no es nuestro: $OC_PLUGIN_DIR/iamlazy.js"; fi
      if grep -q '"@opencode/plugin"' "$OC_PLUGIN_DIR/iamlazy.js" 2>/dev/null; then
        c_bad "el adaptador V2 todavia importa @opencode/plugin: no se empaqueto, y el daemon no puede cargarlo"
      else c_ok "el adaptador V2 parece empaquetado (sin import de @opencode/plugin sin resolver)"; fi
      if [ -f "$OC_PLUGIN_DIR/iamlazy.ts" ] || [ -d "$OC_PLUGIN_DIR/iamlazy" ]; then
        c_bad "queda la forma vieja del adaptador V1 junto al V2 ($OC_PLUGIN_DIR/iamlazy.ts o iamlazy/): el daemon va a intentar cargar los dos"
      else c_ok "no queda ninguna forma vieja del adaptador V1 junto al V2"; fi
      if [ -f "$OC_CMD_DIR/iamlazy.md" ]; then
        c_bad "commands/iamlazy.md esta presente: duplica el comando /iamlazy que el plugin V2 ya registra solo"
      else c_ok "no hay commands/iamlazy.md duplicado (V2 registra /iamlazy por su cuenta)"; fi
      c_adapter_matches_daemon V2
      c_load_failure "$OC_PLUGIN_DIR/iamlazy.js"
    elif [ -f "$OC_PLUGIN_DIR/iamlazy.ts" ]; then
      c_same "$SRC/adapters/opencode/iamlazy.ts" "$OC_PLUGIN_DIR/iamlazy.ts" "adaptador actualizado"
      # The adapter is the registration on this host, and OpenCode refuses a
      # module whose exports are not all functions -- silently, into its own log.
      if grep -qE '^export (const|let|var) [A-Za-z_]+ *(:[^=]*)?= *["`0-9]' "$OC_PLUGIN_DIR/iamlazy.ts"; then
        c_bad "el adaptador exporta algo que no es una funcion: OpenCode va a rechazar todo el plugin"
      else c_ok "las exportaciones del adaptador parecen funciones"; fi
      c_adapter_matches_daemon V1
      c_load_failure "$OC_PLUGIN_DIR/iamlazy.ts"
    else
      c_bad "hay hooks de opencode instalados pero no se encontro ningun adaptador (ni iamlazy.ts ni iamlazy.js en $OC_PLUGIN_DIR)"
    fi
  else
    c_skip "opencode: no hay directorio de hooks, no hay nada instalado"
  fi

  echo "estado"
  # A crashed hook exits 0 by design (see hk_on_exit in lib.sh), so this log is
  # the only place a crash shows. Reported, never cleared: delete it once read.
  if [ -s "$LOG_DIR/hooks.log" ]; then
    c_bad "hay $(wc -l < "$LOG_DIR/hooks.log" | tr -d ' ') falla(s) de hooks en $LOG_DIR/hooks.log; la ultima: $(tail -n 1 "$LOG_DIR/hooks.log"). Borralo cuando lo hayas revisado"
  else c_ok "ningun hook fallo"; fi
  if [ -f "$LOG_DIR/prices.conf" ]; then c_ok "tabla de precios presente"
  else c_bad "no hay tabla de precios: todo costo va a quedar null ($LOG_DIR/prices.conf)"; fi
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    c_ok "hay un parser de JSON disponible para el instalador"
  else c_bad "no hay python: el instalador no puede registrar los hooks"; fi
  n_active=0
  for f in "$LOG_DIR"/active/*.json; do [ -f "$f" ] && n_active=$((n_active + 1)); done
  if [ "$n_active" -eq 0 ]; then c_ok "no quedo ninguna corrida abierta"
  else c_skip "$n_active corrida(s) abierta(s) ahora mismo (normal a mitad de una corrida; las viejas se barren a las 24h)"; fi
  # The close-by-banner path has died three times, twice over encoding. Prove the
  # separator in the prompt still matches the pattern the hook greps for, in THIS
  # locale -- which is the one production runs in, and not CI's.
  if printf '── CIERRE · m · high ──' | grep -Eq '─[^"]{0,60}(CLOSE|CIERRE)|(CLOSE|CIERRE)[^"]{0,60}─'; then
    c_ok "el banner de cierre matchea bajo este locale (${LC_ALL:-${LANG:-unset}})"
  else c_bad "el banner de cierre NO matchea bajo este locale: el camino de cierre esta muerto aqui"; fi

  echo
  if [ "$CHECK_FAIL" -eq 0 ]; then echo "todo bien."; else echo "SE ENCONTRARON PROBLEMAS -- corre install.sh para alinear esta maquina con el repo." >&2; fi
  return "$CHECK_FAIL"
}

usage() {
  cat <<'EOF'
instalador de iamlazy
  uso: install.sh [--tool=claude|opencode|opencode-v2|both] [--model=<id>] [--no-hooks]
       install.sh --check
  --check compara lo INSTALADO contra este repo y reporta el desvio,
    sin cambiar nada. Sale con codigo distinto de cero si algo esta mal.
  Auto-detecta las herramientas instaladas cuando se omite --tool -- EXCEPTO
    opencode-v2, que nunca se auto-selecciona. Apunta a la API nativa v2.0.x
    del plugin de OpenCode (un host candidato, no comprometido -- ver
    PROJECT.md) y necesita un checkout clonado mas bun para construir su
    adaptador; siempre requiere este flag exacto. `--tool=opencode` sigue
    significando OpenCode V1.
  Las dos formas de adaptador no son intercambiables, y un daemon OpenCode 2.x
    RECHAZA el plugin V1 entero -- Layer 0 quedaria instalado y muerto. Por eso
    se lee `opencode --version` antes de escribir nada: si es 2.x, --tool=auto
    omite OpenCode (e instala el resto) y un --tool explicito se niega y sale.
    Si la version no se puede leer, se instala V1 igual: no tener evidencia no
    es evidencia de 2.x. --check compara lo mismo, sin esperar a que falle.
  --model=<id> fija AMBOS roles (principal + critico) para una sola
    herramienta, persiste la eleccion en models.conf, y reinstala. Requiere
    un solo --tool (claude, opencode u opencode-v2) porque los namespaces de
    model-id difieren por herramienta, no por version del adaptador --
    opencode-v2 comparte el de OpenCode.
  Los hooks de Layer 0 se instalan y registran POR DEFECTO. En Claude Code se
    registran en settings.json; en OpenCode un plugin traduce sus eventos a
    los mismos hooks. Son lo que hace que las garantias del harness sean
    garantias de verdad y no pedidos, asi que no son un extra opcional. Tu
    settings.json se respalda antes, se valida despues, y tus propios hooks
    quedan intactos.
  --no-hooks los omite. El harness igual funciona, pero cada garantia
    degrada a prosa -- el modo de falla que Layer 0 existe para eliminar.
  Para instalaciones por curl|bash, fija IAMLAZY_RAW_BASE a la URL base de
    los archivos crudos. opencode-v2 se rechaza bajo curl|bash: su adaptador
    tiene una dependencia npm real que hay que empaquetar desde un checkout
    real, y aqui no hay con que construirla. Clona el repo en su lugar.
EOF
}

# Substitute model tokens. `|` delimiter because model ids contain `/`.
# An EMPTY model drops its `model:` line instead, so the host's own default
# applies: a command runs on the session model, an OpenCode primary agent on
# the configured default, an OpenCode subagent on the agent that invoked it.
# Pinning a model by default broke the command for anyone without access to
# that exact id, which is the default for almost everyone who installs this.
render() {
  # $1 template, $2 main model, $3 critic model, [$4 critic effort]
  r_main="s|{{MAIN_MODEL}}|$2|g"; r_crit="s|{{CRITIC_MODEL}}|$3|g"; r_eff="s|{{CRITIC_EFFORT}}|${4:-}|g"
  [ -n "$2" ] || r_main="/{{MAIN_MODEL}}/d"
  [ -n "$3" ] || r_crit="/{{CRITIC_MODEL}}/d"
  [ -n "${4:-}" ] || r_eff="/{{CRITIC_EFFORT}}/d"
  sed -e "$r_main" -e "$r_crit" -e "$r_eff" "$1"
}

# Compose the core body for ONE host: {{GUARANTEES}} and {{GATE}} are replaced
# by that host's files.
#
# Why the core is tokenised at all: its opening section used to state, flatly,
# that hooks enforce a list of things. That is true on Claude Code and false
# anywhere without Layer 0 -- so the same bytes were a description on one host
# and a lie on another. Two prompts would fix the lie and reintroduce drift,
# which this repo has already paid for three times (the A5 banner, the locale
# regex, the close firing before the review). One source, two small inserts,
# and a test that every token gets filled.
#
# $1 core body, $2 guarantees file, $3 gate file
compose_core() {
  awk -v g="$2" -v t="$3" '''
    # `<!-- hooks: ... -->` is a verification marker, not prompt text: the suite
    # compares it against the hooks merge-settings.sh actually registers, so a
    # new hook whose guarantee nobody wrote down fails the build. The model
    # never needs to read it, so it is dropped here.
    /\{\{GUARANTEES\}\}/ { while ((getline line < g) > 0) if (line !~ /^<!-- hooks:/) print line; close(g); next }
    /\{\{GATE\}\}/       { while ((getline line < t) > 0) print line; close(t); next }
    { print }
  ''' "$1"
}

# Write stdin to $1, but never clobber a pre-existing file that is not ours.
write_file() {
  dest="$1"
  tmp="$(mktemp 2>/dev/null || echo "${dest}.ilztmp.$$")"
  cat > "$tmp"
  if [ -f "$dest" ] && ! grep -q "$MARKER" "$dest" 2>/dev/null; then
    echo "  SALTEADO (ya existe, no es $MARKER): $dest" >&2
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  echo "  escribi $dest"
}

# A command file left by an older install is removed only once the skill that
# replaces it is ours: if write_file skipped the skill because someone else's
# is there, deleting the command would leave the human with no /iamlazy at all.
migrate_claude_commands() {
  for pair in "iamlazy.md:iamlazy" "iamlazy-review.md:iamlazy-review"; do
    old="$CC_CMD_DIR/${pair%%:*}"; skill="$CC_SKILL_DIR/${pair##*:}/SKILL.md"
    if [ -f "$old" ] && grep -q "$MARKER" "$old" 2>/dev/null && grep -q "$MARKER" "$skill" 2>/dev/null; then
      rm -f "$old"
      echo "  elimine $old -- ahora es el skill ${pair##*:}"
    fi
  done
}

install_claude() {
  # The Critic gets `inherit`, not an omitted line: per the sub-agent docs an
  # omitted model lets CLAUDE_CODE_SUBAGENT_MODEL decide, while `inherit` in
  # the frontmatter outranks it and always means "the session's model".
  cc_critic="${CC_CRITIC_MODEL:-inherit}"
  mkdir -p "$CC_SKILL_DIR" "$CC_AGENT_DIR"
  {
    render "$SRC/templates/claude-code/skill-iamlazy.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    compose_core "$SRC/core/iamlazy.md" \
      "$SRC/templates/claude-code/guarantees.md" "$SRC/templates/claude-code/gate.md"
    # shellcheck disable=SC2016  # $ARGUMENTS is Claude Code's own placeholder, not ours
    printf '\n\n---\n\n**Request:** $ARGUMENTS\n'
  } | write_file "$CC_SKILL_DIR/iamlazy/SKILL.md"
  {
    render "$SRC/templates/claude-code/skill-review.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/core/iamlazy-review.md"
  } | write_file "$CC_SKILL_DIR/iamlazy-review/SKILL.md"
  {
    render "$SRC/templates/claude-code/agent-critic.frontmatter" "$CC_MAIN_MODEL" "$cc_critic" "${CC_CRITIC_EFFORT:-}"
    cat "$SRC/critic/iamlazy-critic.md"
  } | write_file "$CC_AGENT_DIR/iamlazy-critic.md"
  migrate_claude_commands
}

# Shared by both OpenCode adapter versions: the agent prompts (Layer 1 body +
# the Critic) are the same regardless of which plugin API registers them --
# confirmed live, a real V2 run used the "iamlazy" agent and its Critic ran on
# the pinned OC_CRITIC_MODEL exactly like V1.
install_opencode_agents() {
  mkdir -p "$OC_AGENT_DIR"
  {
    render "$SRC/templates/opencode/primary-iamlazy.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    compose_core "$SRC/core/iamlazy.md" \
      "$SRC/templates/opencode/guarantees.md" "$SRC/templates/opencode/gate.md"
  } | write_file "$OC_AGENT_DIR/iamlazy.md"
  {
    render "$SRC/templates/opencode/subagent-critic.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/critic/iamlazy-critic.md"
  } | write_file "$OC_AGENT_DIR/iamlazy-critic.md"
}

# /iamlazy-review is a plain command on both versions -- neither plugin
# registers it itself, unlike /iamlazy on V2.
install_opencode_review_command() {
  mkdir -p "$OC_CMD_DIR"
  {
    render "$SRC/templates/opencode/command-review.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/core/iamlazy-review.md"
  } | write_file "$OC_CMD_DIR/iamlazy-review.md"
}

install_opencode() {
  install_opencode_agents
  mkdir -p "$OC_CMD_DIR"
  {
    render "$SRC/templates/opencode/command-iamlazy.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    # shellcheck disable=SC2016  # $ARGUMENTS is OpenCode's own placeholder, not ours
    printf '\n$ARGUMENTS\n'
  } | write_file "$OC_CMD_DIR/iamlazy.md"
  install_opencode_review_command
}

# V2's plugin registers /iamlazy itself (ctx.command.transform); a static
# commands/iamlazy.md here would duplicate it. See adapters/opencode-v2/README.md.
install_opencode_v2() {
  install_opencode_agents
  install_opencode_review_command
}


# copy_hooks <dir> -- every script in hooks/, globbed. A list you have to
# remember to extend is how a new hook lands in the repo and never installs.
copy_hooks() {
  mkdir -p "$1"
  for h in "$SRC"/hooks/*.sh; do
    n="$(basename "$h")"
    cp "$h" "$1/$n"
    chmod +x "$1/$n"
    echo "  escribi $1/$n"
  done
}

install_hooks() {
  copy_hooks "$CC_HOOK_DIR"
  # Registering is part of installing. A hook script nobody invokes is a file,
  # not a guarantee.
  if "$CC_HOOK_DIR/merge-settings.sh" "$HOME/.claude/settings.json" "$CC_HOOK_DIR"; then
    HOOKS_REGISTERED=1
  else
    HOOKS_REGISTERED=0
  fi
}

# OpenCode has no settings.json hooks block; it has plugins. The adapter IS the
# registration there: it translates OpenCode's events into the payloads the same
# hooks already read, so Layer 0 stays one implementation with two entry points.
#
# V1 and V2's adapters are mutually exclusive shapes at the SAME plugin
# directory, and OpenCode auto-discovers every loose file in it -- leaving the
# other version's file behind means the daemon tries to load both. Each
# installer removes the other's shape before writing its own, so switching
# between them on one machine always ends in a clean, unambiguous state.
install_opencode_hooks() {
  copy_hooks "$OC_HOOK_DIR"
  if [ -f "$OC_PLUGIN_DIR/iamlazy.js" ]; then
    rm -f "$OC_PLUGIN_DIR/iamlazy.js"
    echo "  elimine el adaptador V2 viejo ($OC_PLUGIN_DIR/iamlazy.js) -- V1 carga solo iamlazy.ts"
  fi
  write_file "$OC_PLUGIN_DIR/iamlazy.ts" < "$SRC/adapters/opencode/iamlazy.ts"
}

# The V2 adapter has a real runtime import (@opencode/plugin) the daemon
# cannot resolve when it dynamically loads a local plugin file or directory --
# see adapters/opencode-v2/README.md. It must be bundled into one
# dependency-free file first, which needs bun and a real checkout: curl|bash
# has neither a .git nor adapters/opencode-v2/package.json to build from, so
# this refuses cleanly there rather than deploying something broken.
build_opencode_v2_plugin() {
  v2dir="$SRC/adapters/opencode-v2"
  if [ ! -d "$SRC/.git" ]; then
    echo "iamlazy: opencode-v2 necesita un checkout clonado para construirse (curl|bash no tiene ninguno)." >&2
    echo "  Clona el repo y corre install.sh --tool=opencode-v2 desde ahi." >&2
    exit 1
  fi
  if ! command -v bun >/dev/null 2>&1; then
    echo "iamlazy: opencode-v2 necesita bun para construir su adaptador (https://bun.sh)." >&2
    echo "  @opencode/plugin es una dependencia solo de build -- nunca queda en el bundle final." >&2
    exit 1
  fi
  ( cd "$v2dir" && ./build.sh ) || { echo "iamlazy: fallo la construccion del adaptador OpenCode V2." >&2; exit 1; }
}

install_opencode_v2_hooks() {
  v2dir="$SRC/adapters/opencode-v2"
  copy_hooks "$OC_HOOK_DIR"
  build_opencode_v2_plugin
  if [ -f "$OC_PLUGIN_DIR/iamlazy.ts" ] || [ -d "$OC_PLUGIN_DIR/iamlazy" ]; then
    rm -rf "$OC_PLUGIN_DIR/iamlazy.ts" "$OC_PLUGIN_DIR/iamlazy"
    echo "  elimine la forma vieja del adaptador V1 ($OC_PLUGIN_DIR/iamlazy.ts o iamlazy/) -- V2 carga solo iamlazy.js"
  fi
  # V2 registers /iamlazy itself; a leftover static command file from a
  # previous V1 install would duplicate it -- confirmed the exact failure the
  # original V1->V2 migration had to fix by hand.
  if [ -f "$OC_CMD_DIR/iamlazy.md" ] && grep -q "$MARKER" "$OC_CMD_DIR/iamlazy.md" 2>/dev/null; then
    rm -f "$OC_CMD_DIR/iamlazy.md"
    echo "  elimine $OC_CMD_DIR/iamlazy.md -- el plugin de V2 registra /iamlazy por su cuenta"
  fi
  write_file "$OC_PLUGIN_DIR/iamlazy.js" < "$v2dir/dist/iamlazy.js"
}

print_hook_block() {
  if [ "$HOOKS_REGISTERED" -eq 1 ]; then
    cat <<EOF

  LAYER 0 ACTIVO. Esto corre por ti ahora, no depende de tu disciplina:
    - solo el Critic puede spawnearse como sub-agente, y su Bash no puede escribir
    - el log de la corrida se escribe, derivado, en cada cierre
    - cada edicion queda trazada en .iamlazy/journal.md
    - una corrida no puede cerrar con un archivo fuera de su Scope declarado, y se AVISA
    - una corrida que termina sin cerrar queda registrada como abandoned, no se pierde
    - una corrida con contrato no puede cerrar antes de que vuelva su revision
    - el harness se niega a arrancar bajo un permission bypass
    - una corrida que gasta plata sin avanzar se frena y se le pide replantear
  El estado de la corrida es por SESION, bajo ~/.iamlazy/active/ -- una corrida
  abierta en una sesion ya no cambia el comportamiento de ninguna otra.
EOF
  else
    cat <<EOF

  SCRIPTS DE LAYER 0 INSTALADOS, PERO NO REGISTRADOS.
  No se encontro un parser de JSON (python3/python), asi que settings.json
  quedo intacto. Agrega este bloque "hooks" a ~/.claude/settings.json a mano,
  o el harness corre con sus garantias degradadas a prosa:

  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/open-run.sh" } ] }
    ],
    "PreToolUse": [
      { "matcher": "^(Agent|Task)$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/guard-agent.sh" } ] },
      { "matcher": "^Bash\$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/guard-critic-bash.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "^(Edit|Write|MultiEdit|NotebookEdit)\$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/track-edit.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/flush-run.sh" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/end-run.sh" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/subagent-done.sh" } ] }
    ]
  }
EOF
  fi
}

# ---------- parse args ----------
TOOL="auto"
MODEL_OVERRIDE=""
WITH_HOOKS=1
HOOKS_REGISTERED=0
DO_CHECK=0
for arg in "$@"; do
  case "$arg" in
    --tool=*) TOOL="${arg#--tool=}" ;;
    --model=*) MODEL_OVERRIDE="${arg#--model=}" ;;
    --with-hooks) WITH_HOOKS=1 ;;
    --no-hooks) WITH_HOOKS=0 ;;
    --check) DO_CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "iamlazy: argumento desconocido: $arg" >&2; usage; exit 1 ;;
  esac
done

# ---------- platform ----------
# Native Windows is refused before anything is written. Layer 0 is bash run by
# the host on every event, with POSIX paths, `find -newer`, `git` and a bash
# 3.2+ under it; under Git Bash or Cygwin none of that is tested, and a hook
# that fails there fails open on every guarantee. WSL is Linux and works as
# Linux. An unsupported platform said up front beats a silent, half-working
# install.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "iamlazy: Windows nativo no esta soportado. Los hooks son bash y aqui no hay como garantizarlos." >&2
    echo "  Usa WSL (Linux dentro de Windows): ahi iamlazy se instala y funciona como en Linux." >&2
    exit 1
    ;;
esac

# ---------- locate source (clone+run vs curl|bash) ----------
SCRIPT_DIR=""
case "$0" in
  # `|| SCRIPT_DIR=""` rather than a trailing `|| true` INSIDE the substitution:
  # under `set -e` the point is only to keep an unreachable directory from
  # aborting the script, and `A && B || C` reads as if-then-else while actually
  # running C whenever B fails too (SC2015).
  */*) SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR="" ;;
esac

CLEANUP_TMP=""
cleanup() { [ -n "$CLEANUP_TMP" ] && rm -rf "$CLEANUP_TMP"; return 0; }
trap cleanup EXIT

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/core/iamlazy.md" ]; then
  SRC="$SCRIPT_DIR"
else
  RAW="${IAMLAZY_RAW_BASE:-}"
  if [ -z "$RAW" ]; then
    echo "iamlazy: corre esto desde un repo clonado, o fija IAMLAZY_RAW_BASE para instalar por curl|bash." >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "iamlazy: se necesita curl para instalar de forma remota." >&2; exit 1; }
  CLEANUP_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/iamlazy.$$")"
  mkdir -p "$CLEANUP_TMP"
  for rel in $PAYLOAD; do
    mkdir -p "$CLEANUP_TMP/$(dirname "$rel")"
    curl -fsSL "$RAW/$rel" -o "$CLEANUP_TMP/$rel" \
      || { echo "iamlazy: no se pudo bajar $rel desde $RAW" >&2; exit 1; }
  done
  SRC="$CLEANUP_TMP"
fi

# --check reads only; it must run before anything decides to write.
if [ "$DO_CHECK" -eq 1 ]; then
  run_check
  exit $?
fi

# ---------- models ----------
# shellcheck source=models.conf
. "$SRC/models.conf"

# ---------- pick tools ----------
do_claude=0
do_opencode=0
do_opencode_v2=0
case "$TOOL" in
  claude) do_claude=1 ;;
  opencode) do_opencode=1 ;;
  opencode-v2) do_opencode_v2=1 ;;
  both) do_claude=1; do_opencode=1 ;;
  # opencode-v2 is deliberately NEVER auto-selected, even with opencode
  # present: it is still a candidate host (PROJECT.md), needs bun and a real
  # checkout to build, and V1/V2 are mutually exclusive at the same plugin
  # path -- auto-picking one for you is exactly the silent promotion this
  # project's own backlog convention refuses. Ask for it by name.
  auto)
    if command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then do_claude=1; fi
    if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then do_opencode=1; fi
    ;;
  *) echo "iamlazy: --tool=$TOOL desconocido (usa claude|opencode|opencode-v2|both)" >&2; exit 1 ;;
esac

# A 2.x daemon does not degrade the V1 adapter, it refuses it outright, before
# a single hook runs. Checked here -- after the tool is picked, before any file
# is written -- so the outcome is never a half-install.
#
# `auto` and an explicit --tool are answered differently on purpose. `auto`
# GUESSED that "opencode exists" means V1; correcting a wrong guess is not an
# error, so it drops the OpenCode half and still installs whatever else was
# asked for. Naming the tool ASSERTS it, and an assertion that cannot be
# honoured exits -- the same standard build_opencode_v2_plugin already applies
# to a missing bun. An unreadable version installs V1 unchanged: no evidence is
# not evidence of 2.x, and --check catches a real load failure afterwards.
if [ "$do_opencode" -eq 1 ]; then
  oc_seen="$(oc_major)"
  if [ -n "$oc_seen" ] && [ "$oc_seen" -ge 2 ]; then
    if [ "$TOOL" = "auto" ]; then
      do_opencode=0
      echo "iamlazy: detecte OpenCode ${oc_seen}.x, que no puede cargar el adaptador V1 -- omito OpenCode." >&2
      echo "  Para Layer 0 en OpenCode ${oc_seen}.x: install.sh --tool=opencode-v2 (necesita bun y un checkout clonado)." >&2
    else
      echo "iamlazy: --tool=$TOOL instala el adaptador V1, y este OpenCode es ${oc_seen}.x." >&2
      echo "  Un daemon ${oc_seen}.x rechaza ese plugin entero, asi que Layer 0 quedaria instalado y MUERTO," >&2
      echo "  sin avisar (ver DELTAS.md Candidate 19). Corre install.sh --tool=opencode-v2 para este host," >&2
      echo "  y --tool=claude aparte si tambien querias Claude Code." >&2
      exit 1
    fi
  fi
fi

if [ "$do_claude" -eq 0 ] && [ "$do_opencode" -eq 0 ] && [ "$do_opencode_v2" -eq 0 ]; then
  echo "iamlazy: no se detecto ni claude ni opencode. Forzalo con --tool=claude|opencode|opencode-v2|both." >&2
  exit 1
fi

# ---------- --model override (both roles, single tool) ----------
# Rewrite two models.conf lines portably (sed -> tmp -> mv; no `sed -i`, macOS bash 3.2).
persist_model() {
  # $1 main-var name, $2 critic-var name, $3 value, $4 conf path
  ptmp="$(mktemp 2>/dev/null || echo "$4.ilztmp.$$")"
  sed -e "s|^$1=.*|$1=\"$3\"|" -e "s|^$2=.*|$2=\"$3\"|" "$4" > "$ptmp" \
    && mv "$ptmp" "$4"
}

if [ -n "$MODEL_OVERRIDE" ]; then
  if [ "$do_claude" -eq 1 ] && { [ "$do_opencode" -eq 1 ] || [ "$do_opencode_v2" -eq 1 ]; }; then
    echo "iamlazy: --model requiere un solo --tool=claude|opencode|opencode-v2 (los namespaces difieren)." >&2
    exit 1
  fi
  if [ "$do_claude" -eq 1 ]; then
    CC_MAIN_MODEL="$MODEL_OVERRIDE"; CC_CRITIC_MODEL="$MODEL_OVERRIDE"
    if [ -n "$SCRIPT_DIR" ]; then persist_model CC_MAIN_MODEL CC_CRITIC_MODEL "$MODEL_OVERRIDE" "$SRC/models.conf"; fi
  else
    OC_MAIN_MODEL="$MODEL_OVERRIDE"; OC_CRITIC_MODEL="$MODEL_OVERRIDE"
    if [ -n "$SCRIPT_DIR" ]; then persist_model OC_MAIN_MODEL OC_CRITIC_MODEL "$MODEL_OVERRIDE" "$SRC/models.conf"; fi
  fi
fi

# ---------- install ----------
mkdir -p "$LOG_DIR"
# /iamlazy-review sweeps the backlog's triggers against the run log, so the candidates have to
# be readable from any project. The repo copy stays the source of truth; this one is a mirror.
if [ -f "$SRC/DELTAS.md" ]; then cp "$SRC/DELTAS.md" "$LOG_DIR/DELTAS.md"; fi
# The price table is CONFIG, not a generated mirror: never clobber it. Prices
# change and the human edits this file; overwriting their edit on every install
# is how a cost figure goes quietly wrong.
if [ -f "$SRC/prices.conf" ] && [ ! -f "$LOG_DIR/prices.conf" ]; then
  cp "$SRC/prices.conf" "$LOG_DIR/prices.conf"
  echo "  escribi $LOG_DIR/prices.conf"
elif [ -f "$LOG_DIR/prices.conf" ]; then
  echo "  mantuve $LOG_DIR/prices.conf (es tuyo; no lo pise)"
fi
echo "instalador de iamlazy  (fuente: $SRC)"
if [ "$do_claude" -eq 1 ]; then
  echo "Claude Code -> ${CC_MAIN_MODEL:-modelo de la sesion} (principal) / ${CC_CRITIC_MODEL:-modelo de la sesion} (critico)"
  install_claude
fi
if [ "$do_opencode" -eq 1 ]; then
  echo "OpenCode -> ${OC_MAIN_MODEL:-modelo por defecto de OpenCode} (principal) / ${OC_CRITIC_MODEL:-el del agente principal} (critico)"
  install_opencode
fi
if [ "$do_opencode_v2" -eq 1 ]; then
  echo "OpenCode V2 -> ${OC_MAIN_MODEL:-modelo por defecto de OpenCode} (principal) / ${OC_CRITIC_MODEL:-el del agente principal} (critico)"
  install_opencode_v2
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_claude" -eq 1 ]; then
  install_hooks
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
  install_opencode_hooks
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode_v2" -eq 1 ]; then
  install_opencode_v2_hooks
fi

if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_claude" -eq 1 ]; then
  print_hook_block
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
  cat <<EOF

  LAYER 0 EN OPENCODE: $OC_PLUGIN_DIR/iamlazy.ts traduce los eventos de
  OpenCode a los mismos hooks, ahora en $OC_HOOK_DIR. Los plugins cargan al
  arrancar, asi que reinicia cualquier OpenCode corriendo. El costo viene del
  precio por mensaje del propio OpenCode. No hay rechazo de permission-bypass:
  OpenCode no tiene ese modo.
EOF
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode_v2" -eq 1 ]; then
  cat <<EOF

  LAYER 0 EN OPENCODE V2: $OC_PLUGIN_DIR/iamlazy.js (construido desde
  adapters/opencode-v2/, empaquetado -- la fuente tiene un import real a
  @opencode/plugin que el daemon no puede resolver solo) traduce los eventos
  a los mismos hooks, ahora en $OC_HOOK_DIR. El daemon cachea el estado de
  carga de un plugin durante toda la vida del proceso: ni editar este archivo
  ni llamar a POST /api/plugin/await-activation lo reevalua. Reinicia el
  daemon (opencode service restart) y confirma con:
    opencode api GET /api/plugin --param 'location[directory]=<project>'
  buscando "id":"iamlazy" y "state":{"status":"active"}. El costo viene del
  precio por mensaje del propio OpenCode. No hay rechazo de permission-bypass:
  OpenCode no tiene ese modo.
EOF
fi

# The version that WROTE a run's log line, not the version the repo currently
# is: stamped once here, read back by flush-run.sh at every close. `--check`
# already catches drift byte-for-byte, which is strictly more precise than a
# version string could be -- this is for the question `--check` cannot answer,
# which came up twice tonight: "was this weird run before or after the fix?"
# Prefer the git SHA (a clone+run install, so $SRC/.git is real and the SHA
# names an exact, inspectable commit); a curl|bash install has no .git, so
# fall back to a content fingerprint (cksum, POSIX and on every platform this
# project targets, unlike shasum/sha1sum's macOS-vs-Linux naming split) of
# every file that enforces something -- the hooks AND the OpenCode adapter,
# since both are Layer 0.
if [ "$WITH_HOOKS" -eq 1 ]; then
  mkdir -p "$LOG_DIR"
  if [ -d "$SRC/.git" ] && command -v git >/dev/null 2>&1 \
     && ver="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null)" && [ -n "$ver" ]; then
    # A SHA names a commit, and an install from a working tree with uncommitted
    # enforcement code is not that commit. Stamping the bare SHA there made the
    # log claim a version it was not running -- the author installs from a
    # working tree routinely. `-dirty` says "this commit plus changes", which is
    # the honest answer to "was this run before or after the fix".
    if [ -n "$(git -C "$SRC" status --porcelain -- hooks adapters 2>/dev/null)" ]; then
      ver="${ver}-dirty"
    fi
    printf '%s\n' "$ver" > "$LOG_DIR/hooks_version"
  else
    # Whichever OpenCode adapter this install actually chose -- V1's default,
    # unless opencode-v2 was named explicitly.
    adapter_src="$SRC/adapters/opencode/iamlazy.ts"
    [ "$do_opencode_v2" -eq 1 ] && adapter_src="$SRC/adapters/opencode-v2/iamlazy.ts"
    cat "$SRC"/hooks/*.sh "$adapter_src" 2>/dev/null \
      | cksum | awk '{print $1}' > "$LOG_DIR/hooks_version"
  fi
fi

echo
echo "listo."
echo "  directorio de log:  $LOG_DIR"
echo "  comandos: /iamlazy  /iamlazy-review"
if [ "$do_claude" -eq 1 ]; then
  echo
  if [ -n "$CC_MAIN_MODEL" ]; then
    echo "  ALCANCE DEL MODELO: '$CC_MAIN_MODEL' cubre SOLO el turno del planner. El model:"
    echo "  del frontmatter de un comando expira en tu proximo prompt -- y el gate ES un"
    echo "  prompt -- asi que el builder (A4-A5) corre en tu modelo de SESION, nunca en"
    echo "  models.conf."
  else
    echo "  MODELO: models.conf no fija ninguno, asi que /iamlazy y el Critic corren en el"
    echo "  modelo de tu sesion. Para fijar uno: install.sh --tool=claude --model=<id>."
  fi
  if grep -q '"model"' "$HOME/.claude/settings.json" 2>/dev/null; then
    echo "  OK: ~/.claude/settings.json fija un modelo de sesion, asi que el build es deterministico."
  else
    echo "  No hay un modelo de sesion fijado en ~/.claude/settings.json, asi que el build"
    echo "  corre en lo que la sesion tenga por defecto. Para fijarlo, agrega uno de estos:"
    echo "    \"model\": \"claude-opus-5\"   un solo modelo todo el camino"
    echo "    \"model\": \"opusplan\"          Opus en plan mode, Sonnet en la ejecucion"
    echo "  Un .claude/settings.json de proyecto tambien funciona, y tiene prioridad."
  fi
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    echo "  AVISO: CLAUDE_CODE_SUBAGENT_MODEL='$CLAUDE_CODE_SUBAGENT_MODEL' esta fijada. Segun la"
    echo "  documentacion, el model: del Critic tiene prioridad sobre ella; si el Critic no corre"
    echo "  en el modelo que esperas, revisa esa variable."
  fi
fi
if [ "$do_opencode" -eq 1 ] || [ "$do_opencode_v2" -eq 1 ]; then
  echo "  nota: OpenCode necesita una credencial para su provider (env u opencode.json). Este instalador no la configura."
  echo "  El analisis corre en el agente 'plan' propio de OpenCode, que no fija modelo y"
  echo "  hereda el modelo de la SESION EN VIVO -- el que entrar a 'iamlazy' acaba de fijar."
  echo "  Asi que el planner tambien corre en ${OC_MAIN_MODEL:-ese mismo modelo}, y tu default de OpenCode no"
  echo "  cambia eso. Para separarlos, fijalo en tu propio opencode.json:"
  echo "    \"agent\": { \"plan\": { \"model\": \"...\" } }"
fi
