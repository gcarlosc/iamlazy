# Plan — `--model` flag para install.sh (modelo unificado orquestador+critic)

## Context

Hoy, para cambiar el modelo del harness hay que editar `models.conf` a mano (4 variables:
main/critic × Claude Code/OpenCode) y re-correr `./install.sh`. El usuario quiere un **comando**
que reciba **un** modelo y lo aplique a **ambos roles a la vez** — orquestador (hilo principal) y
Critic. Decisión tomada: el comando **persiste** la elección en `models.conf` **y reinstala** en
un solo paso.

Restricción real del dominio: Claude Code usa ids Anthropic pelados (`claude-opus-4-8`) y OpenCode
usa `provider/model` (`deepseek/deepseek-v4-pro`) — namespaces incompatibles. Por eso un `--model`
apunta a **una** herramienta por invocación.

Reversibilidad: **media** (feature acotada, git-reversible, sin datos/producción).

## Approach (recomendado)

Flag `--model=<id>` en `install.sh`. Sin script aparte (mantiene "un comando, bash+files, cero
deps").

### Cambios en `install.sh`

1. **Init + parsing** (loop args ~L94-101): agregar `MODEL_OVERRIDE=""` y un case nuevo
   `--model=*) MODEL_OVERRIDE="${arg#--model=}" ;;` antes del catch-all `*)`.

2. **Aplicación en memoria** (después de resolver `do_claude`/`do_opencode`, ~L152, antes de la
   sección install L154): si `MODEL_OVERRIDE` no vacío:
   - Exigir **exactamente una** herramienta activa. Si `do_claude=1 && do_opencode=1` → error:
     `--model requires a single --tool=claude|opencode`, exit 1.
   - Pisar en memoria las 2 vars del rol de esa herramienta:
     - claude → `CC_MAIN_MODEL=$MODEL_OVERRIDE; CC_CRITIC_MODEL=$MODEL_OVERRIDE`
     - opencode → `OC_MAIN_MODEL=$MODEL_OVERRIDE; OC_CRITIC_MODEL=$MODEL_OVERRIDE`

3. **Persistencia a `models.conf`** (solo clone+run, `[ -n "$SCRIPT_DIR" ]`; en `curl|bash` `SRC`
   es temp descartable → skip): reescribir las 2 líneas afectadas con `sed → tmp → mv` (portable,
   **sin `-i`** — macOS bash 3.2). Patrón:
   ```
   sed -e 's|^CC_MAIN_MODEL=.*|CC_MAIN_MODEL="'"$MODEL_OVERRIDE"'"|' \
       -e 's|^CC_CRITIC_MODEL=.*|CC_CRITIC_MODEL="'"$MODEL_OVERRIDE"'"|' \
       "$SRC/models.conf" > "$tmp" && mv "$tmp" "$SRC/models.conf"
   ```
   Reusar el idioma de `render()` (L36-39) y del tmp+mv de `write_file()` (L42-54).

4. **usage()** (L27-32): documentar `--model=<id>` (requiere `--tool` único; fija main+critic).

### Docs

5. `README.md:113` — sección "Models and credentials": agregar alternativa
   `./install.sh --tool=claude --model=<id>` junto a la edición manual.

6. `PROJECT.md` — mini-ADR "Comando de modelo unificado (`--model`)". **Va como diff separado con
   aprobación explícita** (invariante regla 5: PROJECT.md nunca se edita sin diff + OK).

## Discarded alternatives

- Script `iamlazy-set-model` aparte → más superficie, rompe "un comando".
- `sed -i` in-place → no portable en macOS (necesita `-i ''`); install.sh nunca lo usa.
- Flag por rol (`--main-model`/`--critic-model`) → contradice "uno aplica a ambos".

## Load-bearing claims (verificadas read-only)

- **C1** — 4 vars existen y se sourcean en L133. `rg -n 'MODEL' models.conf` →
  `CC_MAIN_MODEL`, `CC_CRITIC_MODEL`, `OC_MAIN_MODEL`, `OC_CRITIC_MODEL`. ✓
- **C2** — install.sh nunca usa `sed -i`. `rg -n 'sed' install.sh` → única línea L38 sin `-i`. ✓
- **C3** — arg loop rechaza desconocidos y `TOOL=auto` puede prender ambas. `rg -n 'tool=|unknown
  arg|TOOL='` → `L94 TOOL="auto"`, `L97 --tool=*`, `L99 unknown arg`. ✓

## Verification (end-to-end, HOME aislado)

- Sintaxis: `bash -n install.sh`.
- Aplicar: `HOME=$(mktemp -d) ./install.sh --tool=claude --model=claude-sonnet-5` →
  - stdout muestra `Claude Code -> claude-sonnet-5 (main) / claude-sonnet-5 (critic)`.
  - `rg 'MODEL' models.conf` → CC_* = `claude-sonnet-5` (persistido); OC_* intactos.
  - `rg 'model:' $HOME/.claude/commands/iamlazy.md $HOME/.claude/agents/iamlazy-critic.md` →
    `claude-sonnet-5`.
- Error path: `./install.sh --tool=both --model=x` → falla pidiendo `--tool` único.
- Restaurar `models.conf` a opus tras la prueba (o dejar el valor elegido por el usuario).

## Critic

Post-diff: toca `install.sh` (no matchea globs sensibles) y el diff es < 400 líneas →
Critic en modo **same-thread-reset** (base de reversibilidad media). Re-lee diff + este plan desde
disco y re-corre C1-C3.
