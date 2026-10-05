# iamlazy

[![test](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml/badge.svg)](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml)

**Le das una tarea. Apruebas un plan de una página. No puede cerrarla fuera de ese plan.**

Un harness para **Claude Code** y **OpenCode**. Un comando para instalarlo, cero dependencias:
bash y archivos.

```sh
git clone https://github.com/gcarlosc/iamlazy iamlazy && cd iamlazy && ./install.sh
```

```
/iamlazy agrega soporte para --lang=de en greet.sh
```

### Qué obtienes

- **Un plan antes del código.** Los archivos en alcance, qué significa "terminado", y el comando
  exacto que lo prueba. Lo apruebas o lo corriges: un minuto ahora, en lugar de una tarde revisando
  un diff que no pediste.
- **No puede salirse del alcance.** Si tocó un archivo que no aprobaste, la corrida no cierra: lo
  declara. No es una línea en el prompt pidiendo buena conducta — es un hook que corre siempre.
- **Lo revisa otro agente.** Uno separado, que lee el diff en frío y busca qué más dependía de lo
  que cambió. El que escribió el código no firma su propia revisión.
- **Números, no impresiones.** Cada corrida deja en `runs.jsonl` el costo real en dólares, la
  duración, los archivos tocados y los hallazgos del revisor. Sabes qué costó, no qué te pareció.

### El número que lo explica

La peor corrida registrada tardó casi dos horas en producir 230 líneas, después de siete intentos:
**24 veces más cara por línea** que una normal. Eso no se nota sin medirlo, y no se corta sin algo
que lo corte. iamlazy hace las dos cosas.

---

**Todo lo que sigue es el detalle: cómo funciona, cómo se instala y qué garantiza.**

Corre **una tarea de punta a punta** —analizar, preguntar, contratar, aprobar, ejecutar,
revisar— en un solo hilo. Sin MCP: un archivo TypeScript le permite a OpenCode correr el mismo
bash que Claude Code.

## El modelo mental (una página)

iamlazy no es un pipeline de agentes ni interpreta personajes. Es un ingeniero senior trabajando en
una tarea, con un **contrato** en el medio: lo que acordaste hacer, firmado antes de escribir
código, y verificado contra la realidad al final.

Deliberadamente **no** está hecho para sesiones de varias horas: una corrida larga es un
síntoma, no un logro — y el número de arriba es lo que pasa cuando nadie la corta. Hacerlo
visible, y frenarlo, es el punto.

**Un hilo, y un solo escritor.** El valor está en la cadena —plan, diff, revisión— sostenida en un
*único* contexto; si lo partes entre agentes delegados, cada uno vuelve a deducir lo que el anterior
ya sabía. Por eso ningún sub-agente salvo el revisor puede lanzarse, y por eso es un hook y no un
pedido. Un escritor delegado además esconde su propio costo: `runs.jsonl` contabiliza el hilo
principal, así que el trabajo delegado nunca llega al número con el que juzgarías si el harness
vale la pena. Si una búsqueda se siente demasiado grande para este hilo, redúcela — no la
delegues.

### Dos capas, y la diferencia importa

El harness separa lo que **garantiza** de lo que **pide** — porque cinco de sus seis viejas "reglas
inviolables" eran prosa, y la más violada de todas era la que estaba declarada como ley.

| Capa 0 — garantizado | Capa 1 — pedido |
|---|---|
| Scripts de hook que no puedes saltear | El prompt: criterio |
| Solo el revisor puede lanzarse, y lanzarlo pregunta primero | Cómo analizar, qué preguntar |
| Identidad de la corrida, tiempos y la línea de log | Cómo escribir el contrato |
| Cada edición trazada automáticamente | Ediciones quirúrgicas, qué recibe el revisor |
| No cierra mientras haya un archivo fuera del scope declarado | Tono, orden, conclusiones primero |
| Se niega a arrancar bajo un bypass de permisos | |

La regla que decide dónde va cada cosa: **¿puede un comando decir si se cumplió?** Si sí y se puede
prevenir, es una garantía. Si sí pero solo después, es protocolo. Si no, es estilo — y no se le
llama ley. **Nada se promueve por ser importante.**

La prosa no es el enemigo; la *longitud* sí. La corrida corta del log obedeció cada instrucción en
prosa, banner incluido. Las largas omitieron el log, el banner y la línea de costo. Así que la
Capa 0 no vigila cada regla — cuida el **perímetro** que mantiene la tarea acotada, y deja que el
criterio sea criterio.

### Los tres archivos

- **`PROJECT.md`** (raíz del repo, versionado) — lo que el harness sabe de tu proyecto: dónde están
  las cosas, qué comandos funcionan, las restricciones, y **qué revisar aquí**, que crece con cada
  hallazgo. Solo entra lo que habría acortado el reconocimiento, evitado una pregunta o cambiado un
  paso; todo lo demás es un diario, no memoria. Nunca se edita sin mostrarte el diff.
- **`.iamlazy/contract.md`** — la tarea: terreno, preguntas resueltas, opciones descartadas, el
  **scope** declarado, los **grupos** (cada uno con el comando que prueba que está hecho), y los
  **claims** que sostienen el peso, con su salida real. **Esto es lo que apruebas.**
- **`.iamlazy/journal.md`** — solo se le agrega, se escribe mientras el trabajo pasa, nunca se
  reescribe al final. Incluye lo que se intentó y se **abandonó** — eso que un revisor nunca puede
  reconstruir desde un diff.

### El flujo

1. **Análisis** — lee `PROJECT.md`, explora lo que falta, y después decide **cómo se parte el
   trabajo en grupos**. Un grupo comparte contexto de trabajo, tiene su propio comando de
   aceptación, y deja el repo válido por sí solo. Si tu pedido en realidad son varias tareas, lo
   dice en vez de aceptar una épica como tarea.
2. **Preguntas** — un único bloque, nunca rondas, cada una con su recomendación, y solo después del
   reconocimiento. **Sin zonas grises:** cada paso tiene que trazarse a un hecho observado, una
   pregunta respondida o `PROJECT.md`. Ningún paso puede apoyarse en una suposición.
3. **Contrato** — escrito a disco, con la forma de arriba.
4. **Aprobación** — tu gate, sobre el plan mode nativo. Lees **comandos, no párrafos** — que es la
   respuesta a por qué el gate viejo no rechazó un plan ni una vez en 27 corridas: leer prosa
   cansa, leer `rspec spec/services/rate_limiter_spec.rb` toma tres segundos.
5. **Ejecución** — grupo por grupo, releyendo el contrato desde el disco. Un path fuera del scope
   declarado frena el trabajo en lugar de absorberse. **Dos intentos, y para:** un segundo intento
   tiene que declarar qué cambia en la hipótesis; un tercero significa que la hipótesis está mal.
6. **Revisión** — siempre un sub-agente **aparte** y de solo lectura, nunca un "reset" del mismo
   hilo. **Lanzarlo pregunta primero:** si lo apruebas, la corrida no puede cerrar antes de que
   vuelva; si lo rechazas, cierra sin revisión, como desvío declarado. Recibe el contrato y el
   journal **como claims a poner a prueba, no como contexto a creer**, y **deriva su propio diff**
   desde los paths — no eliges qué ve tu auditor.
7. **Cierre** — el reporte, más la actualización propuesta de `PROJECT.md` como diff.

**Para qué sirve el revisor.** Tú puedes probar si la funcionalidad anda. Lo que no puedes ver es
*qué más dependía de lo que cambió* — así que ese es su trabajo principal: elige las 3–5 cosas más
riesgosas que toca el diff, busca sus otros llamadores, y dice cuáles verificó y cuáles dejó
quietas. Los contratos implícitos cuentan tanto como las firmas. Una lista cuyo orden usa otra
funcionalidad es una dependencia real aunque nada la declare, y es exactamente la rotura que
sobrevive a una prueba manual y falla en producción. Tiene que producir un hallazgo real o mostrar
su búsqueda adversarial; un "se ve bien" pelado es un veredicto inválido.

## Instalación

Funciona en macOS y Linux. En Windows, dentro de WSL; el instalador rechaza Windows nativo, porque
los hooks son bash y ahí no hay cómo garantizarlos.

Clona y ejecuta (totalmente offline):

```sh
git clone https://github.com/gcarlosc/iamlazy iamlazy && cd iamlazy
./install.sh
```

O fuerza una herramienta específica:

```sh
./install.sh --tool=claude      # o --tool=opencode, --tool=opencode-v2, o --tool=both
```

`curl | bash` (fija la URL base de los archivos crudos de tu fork/repo):

```sh
IAMLAZY_RAW_BASE="https://raw.example/iamlazy/main" curl -fsSL https://raw.example/iamlazy/main/install.sh | bash
```

El instalador:
- auto-detecta `claude` y `opencode` (V1). `opencode-v2` apunta en cambio a la API nativa de
  plugins v2.0.x de OpenCode —un host candidato, no comprometido (ver `PROJECT.md`)— así que
  siempre necesita el flag explícito, más `bun` y un checkout real para construir su adaptador;
  nunca se auto-selecciona,
- **lee `opencode --version` antes de escribir nada, porque las dos formas de adaptador no son
  intercambiables**: un daemon de OpenCode **2.x** rechaza el plugin V1 de plano, lo que dejaría la
  Capa 0 instalada y muerta. En 2.x, la auto-detección omite OpenCode y te indica ejecutar
  `--tool=opencode-v2`; un `--tool=opencode`/`--tool=both` explícito se niega en lugar de instalar
  algo que no puede cargar. Si la versión no se puede leer, se instala V1 como antes. `--check`
  verifica el mismo emparejamiento, así que un desajuste se reporta en vez de descubrirse después,
- en Claude Code instala `/iamlazy` y `/iamlazy-review` como **skills**, y el sub-agente Critic; en
  OpenCode, sus comandos y agentes. Un skill aparece en cualquier cliente que liste skills, MonoCode
  incluido, y solo lo puede lanzar un humano. Si una instalación anterior dejó los comandos en
  `~/.claude/commands/`, el instalador los reemplaza por los skills,
- instala la Capa 0: los hooks, registrados en el `settings.json` de Claude Code, o detrás del
  plugin en OpenCode,
- proyecta `models.conf` en el frontmatter de cada archivo,
- es **idempotente** (ejecútalo cuando quieras) y **nunca sobrescribe** un archivo que no sea de
  iamlazy,
- crea `~/.iamlazy/` para el log de corridas,
- estampa `~/.iamlazy/hooks_version` (un SHA de git, o una huella de contenido en una instalación
  por `curl|bash` sin `.git`) para que cada línea del log pueda decir qué versión del código de
  enforcement la escribió.

## Uso

```
/iamlazy <tu tarea>       # ejecuta el harness completo
/iamlazy-review           # muestra las últimas 20 corridas, legible
```

En Claude Code los dos son skills con `disable-model-invocation: true`: los lanzas tú, nunca el
modelo por su cuenta. No es un detalle de estilo. La Capa 0 abre la corrida cuando tu prompt empieza
con `/iamlazy`, y un skill lanzado por el modelo no pasa por ahí: el harness trabajaría sin ninguna
garantía y sin avisar.

Nunca ves mecánica interna — ni ids de sesión, ni estados, ni charla de protocolo. Ves un bloque de
preguntas (cada una con su recomendación), el contrato con sus comandos de aceptación y sus claims
(en el gate), la entrega, y el cierre. Cada etapa abre con un banner que declara el modelo y el
esfuerzo; el modelo que corrió de verdad está en `models_seen`, en `runs.jsonl`.

Durante una tarea, `.iamlazy/` en la raíz de tu proyecto guarda el contrato aprobado —persistido
**textual, tal como lo aprobaste**— y el journal, para que el revisor trabaje contra eso y para que
tú lo inspecciones después. Agrega `.iamlazy/` a tu `.gitignore` (si falta, iamlazy te lo avisa al cerrar la corrida, en Claude Code y en OpenCode V1).

## Modelos y credenciales

**Por defecto, iamlazy no fija ningún modelo.** `/iamlazy` corre en el modelo de tu sesión, y el
Critic hereda ese mismo modelo. En OpenCode, el agente `iamlazy` usa el modelo que tengas
configurado, y el Critic usa el del agente que lo lanza. Antes venían fijados, y un modelo fijado
rompe el comando para quien no tiene acceso a ese id exacto.

Para fijar uno, edita `models.conf` y vuelve a ejecutar `./install.sh`, o hazlo en un solo comando:

```sh
./install.sh --tool=claude --model=claude-opus-5-5
```

`--model` fija los dos roles de una herramienta y guarda la elección en `models.conf`. Claude Code
toma ids de Anthropic. OpenCode toma `provider/model`, tal como lo lista `opencode models`.

| Rol en Claude Code | Sin fijar, que es el default | Fijado |
|---|---|---|
| Planner | modelo de la sesión | `CC_MAIN_MODEL`, solo en el turno del planner |
| Builder | modelo de la sesión | sigue siendo el de la sesión |
| Critic | `model: inherit`, el de la sesión | `CC_CRITIC_MODEL`, en toda la revisión |

**Hasta dónde llega un modelo fijado.** El `model:` de un comando vale solo para el turno actual, y
el gate es un turno nuevo. Por eso `CC_MAIN_MODEL` cubre al planner y el builder corre en el modelo
de la sesión. El modelo de un sub-agente, en cambio, vale para toda su revisión. El Critic usa
`inherit` y no omite el campo: según la documentación de Claude Code, un campo omitido deja decidir a
`CLAUDE_CODE_SUBAGENT_MODEL`, y `inherit` tiene prioridad sobre esa variable.

**Para dividir planner y builder, usa la sesión.** Pon `"model": "opusplan"` en
`~/.claude/settings.json`: Opus en plan mode y Sonnet en la ejecución. El gate de iamlazy va sobre
el plan mode nativo, así que el cambio cae justo en el límite entre plan y build.

**El esfuerzo del Critic.** Hereda el de la sesión. Con `xhigh`, una revisión real tardó nueve
minutos en 37 turnos seguidos. Para bajarlo, pon `CC_CRITIC_EFFORT="high"` en `models.conf` y
reinstala; llega al frontmatter del Critic como `effort:`.

**Qué modelo corrió de verdad.** Mira `models_seen` en `runs.jsonl`: se cuenta desde el transcript.
Cada banner de etapa declara un modelo, pero lo escribe el propio modelo, y el de CIERRE ya nombró
en tres corridas un modelo que no lo escribió (candidato 17 de `DELTAS.md`).

**OpenCode no divide planner y builder por su cuenta.** El gate te manda al agente `plan` que
OpenCode trae de fábrica, y ese agente no fija modelo: hereda el de la sesión en vivo, el mismo que
usa `iamlazy`. Para separarlos, fija el agente de fábrica en tu propio `opencode.json`:

```json
{ "agent": { "plan": { "model": "provider/modelo" } } }
```

El instalador no puede hacerlo por ti, porque nunca escribe configuración del usuario.

> **OpenCode necesita una credencial para su provider, que configuras tú**: una API key en tu
> entorno o en `opencode.json`. El instalador no configura credenciales.

## El gate no es opcional

iamlazy **no** escribe código hasta que apruebes el contrato, salvo en cambios trivialmente
reversibles. En Claude Code el gate va montado sobre el **plan mode nativo** — estructura impuesta
por la plataforma, no prosa imitándola.

**No ejecutes iamlazy bajo `--dangerously-skip-permissions` (ni ningún modo de bypass).** Elimina el
gate estructural sobre el que está construido el harness. Con la Capa 0 instalada esto ya no es un
pedido: el harness **se niega a arrancar** bajo un bypass de permisos.

## Capa 0

Instalada y registrada **por default**. No hay un paso extra, y eso es a propósito: una garantía
que tienes que acordarte de encender no es una garantía, y la falla es silenciosa — dos
instalaciones se ven idénticas mientras solo una impone algo.

El instalador respalda tu `settings.json`, valida el resultado antes de reemplazarlo, restaura el
backup si algo sale mal, y **nunca toca tus propios hooks ni tu configuración**. `./uninstall.sh`
los desregistra de vuelta, con el mismo cuidado.

```sh
./install.sh --tool=claude --no-hooks   # optar por NO tenerlos, si de verdad lo quieres
```

Sin ellos el harness igual corre, pero cada garantía degrada de vuelta a prosa — exactamente el
modo de falla que la Capa 0 existe para eliminar.

**En OpenCode, la Capa 0 es el mismo bash detrás de un plugin.** Existen dos adaptadores, uno por
API de plugin: `adapters/opencode/iamlazy.ts` para V1 (`@opencode-ai/plugin`), instalado en
`~/.config/opencode/plugins/` tal cual, y `adapters/opencode-v2/iamlazy.ts` para el
`@opencode/plugin` nativo de V2. V2 necesita un paso de build antes — su adaptador tiene un import
real en runtime que el daemon de V2 no puede resolver cuando carga un plugin local
dinámicamente, así que se despacha como un único archivo empaquetado y sin dependencias; ver
`adapters/opencode-v2/README.md` para la historia completa y su propio `build.sh`. **No son
intercambiables**: cada major de daemon acepta solo su propia forma — un daemon 2.x rechaza el
plugin V1 entero con `Plugin must export a default definition with an id and an effect or setup
function`, y la falla va al log de OpenCode, no a tu terminal. Por eso el instalador chequea la
versión en lugar de suponerla. Los dos hacen la misma única cosa: traducir los eventos de OpenCode
a los payloads JSON que los hooks ya leen, invocarlos, y traducir una negación de vuelta al
`throw`
que bloquea una tool en ese host. Ninguno lee un contrato, calcula scope ni sabe del breaker —
un test
grepea cada uno buscando esas palabras y falla si aparece alguna. Lo único que difiere de Claude
Code es el costo: OpenCode tarifa cada mensaje por su cuenta, así que el adaptador reenvía cada
cifra a `host-cost.sh` en vez de que los hooks retarifen la corrida desde `prices.conf`. Dos cosas
que Claude Code tiene y OpenCode no: un modo de bypass de permisos que rechazar, y un plan mode que
deniega en lugar de preguntar — el prompt lo dice en ese host, en vez de fingir paridad.

### Cuándo te corta, y cómo ajustarlo

El breaker detiene una corrida **una sola vez**, cuando cruza alguno de estos límites. Te dice
cuál fue y por qué; después decides tú. No vuelve a hablar en esa corrida.

| Umbral | Default | Corta cuando |
|---|---|---|
| `DRIFT_MICRO_PER_LINE` | `80000` ($0,08) | el costo por línea cambiada se dispara: esfuerzo en intentos, no en avance |
| `DRIFT_MIN_LINES` | `50` | (piso) debajo de esto el ratio es ruido y no se evalúa |
| `DRIFT_MIN_COST` | `3000000` ($3,00) | (piso) debajo de esto una corrida cara no es cara |
| `DRIFT_MAX_SECONDS` | `3600` (1 h) | la corrida lleva demasiado tiempo de trabajo, sin contar las esperas por ti |
| `DRIFT_MAX_COST` | `10000000` ($10,00) | el gasto total es demasiado para una sola tarea |

Los dos últimos existen porque el costo por línea **baja** cuanto más crece una corrida: una
larga, cara y productiva mantiene el ratio sano de punta a punta, y sin un techo absoluto nada
la detenía.

Se ajustan en `~/.iamlazy/config`, una línea por umbral, sin reinstalar nada:

```sh
DRIFT_MAX_SECONDS=7200    # dos horas, si tus tareas son realmente así
```

El mismo archivo apaga la pregunta antes de lanzar al Critic, si prefieres que arranque solo:

```sh
CRITIC_ASK=0
```

Un valor no numérico se ignora y vale el default. Los umbrales vigentes quedan registrados en
cada línea de `runs.jsonl`, junto con cuál disparó: un corte que no puedes explicar contra qué
se midió no sirve para recalibrar.

## Tests

```sh
./test.sh
```

Cubre el instalador y los invariantes declarados — composición de archivos, proyección de modelos,
idempotencia, anti-pisado, `--model`, registro de hooks, y que `uninstall.sh` nunca toque tu log de
corridas. Delega en `./test-hooks.sh` las decisiones en runtime de la Capa 0, alimentadas con
payloads reales capturados y validadas por mutación en lugar de por dar verde. Corre en un `HOME`
aislado, así que no puede alterar tu configuración. Bash y coreutils, más Bun para el único
archivo que
corre bajo Bun.

El adaptador de OpenCode se ejercita con `bun test` — Bun es el runtime de OpenCode, así que es
bajo lo que el plugin realmente corre. Cada test le da un evento real de OpenCode al plugin
*instalado* y afirma qué hicieron los hooks reales en disco; nada de la Capa 0 está mockeado.
**Bun
es obligatorio**, y la suite falla en vez de omitirse cuando no está: un traductor que
nadie corrió,
reportado como verde, es el falso verde que el resto de esta suite existe para rechazar.

La mitad de la Capa 0 corre **dos veces, bajo un locale C y uno UTF-8**, y descubre qué locale UTF-8
tiene el sistema realmente en lugar de suponer uno. Eso no es ceremonia: el regex de cierre por
banner se escribió con bytes escapados, que el grep de BSD respeta bajo C y silenciosamente ignora
bajo UTF-8, así que estaba muerto justo donde los hooks corren de verdad mientras CI daba verde
durante semanas.

CI lo corre en cada push sobre Linux y macOS, más un job que lo invoca específicamente a través de
`/bin/bash` — ese es el bash 3.2 que este proyecto dice soportar, y `env bash` en un runner puede
resolver en silencio a uno más nuevo. Un job aparte de `lint` corre `bash -n` en cada script y
`shellcheck -x` con severidad style — siguiendo los `source`, así que `lib.sh` y `models.conf`
también se chequean, no solo la línea que los incluye. Su primera corrida real encontró un bug
genuino (`hk_rel_path` fallando en silencio sobre un path de proyecto con un carácter de glob), que
es el argumento para mantenerlo en severidad style y no solo en los defaults. Localmente,
`git config core.hooksPath .githooks` instala un hook de pre-push que se niega a publicar una suite
en rojo.

Lo que **no** cubre: una corrida real de `/iamlazy`. El contrato, el gate y la revisión siguen
siendo correctos por construcción del prompt. La Capa 0 cerró parte de esa deuda —un script de hook
que lee JSON por stdin es testeable de una forma que un prompt nunca fue— pero el camino de punta a
punta sigue sin ejercitarse. Vale saberlo antes de confiar en un verde.

## Validación

No aceptes el harness por fe. Durante el primer mes, ejecuta unas cuantas tareas comparables de
las dos formas —con `/iamlazy`, y con la herramienta sola más un buen `CLAUDE.md`— y compara tres
preguntas: ¿el gate detuvo algo real? ¿hubo que deshacer trabajo? ¿cuál fue el tiempo total? Cada
corrida loguea una cifra `cost_usd` derivada del transcript de la sesión y de una tabla de precios,
no estimada, así que el costo es comparable entre corridas — y un conteo `models_seen`, así que una
corrida es comparable contra lo que realmente la respondió y no contra lo que la config decía que
la iba a responder. `runs.jsonl` + `/iamlazy-review` son la mitad de la instrumentación — y la
revisión además barre los triggers de `DELTAS.md` contra tus corridas, reportando cuáles se
dispararon, para que el backlog avise cuando tiene evidencia en lugar de esperar que le
pregunten. Si iamlazy no gana con claridad, la conclusión correcta es recortarlo, no defenderlo.

**El mismo estándar aplica al harness mismo.** Cada idea que sonaba bien y no se adoptó vive en
`DELTAS.md` detrás de un trigger — la condición, escrita por adelantado, bajo la cual vale la pena
reabrirla. Un trigger disparado motiva una **evaluación, nunca una adopción**, y un trigger escrito
contra un campo que ya no existe se retira en lugar de quedar como si no se hubiera disparado. Es la
regla sobre la que corren las dos capas, apuntada al backlog: una idea no entra por ser importante,
entra por ser verificable.

## Desinstalación

```sh
./uninstall.sh
```

Elimina solo los archivos que llevan el marcador `iamlazy-managed`. **Nunca** borra
`~/.iamlazy/runs.jsonl` ni ningún `PROJECT.md`.

## Qué trae la caja

```
iamlazy/
  core/            cuerpo del prompt principal (5 reglas + 5 artefactos) + el cuerpo del comando de revisión
  critic/          el prompt del sub-agente Critic
  templates/       envoltorios de frontmatter por herramienta (claude-code/, opencode/)
  models.conf      mapa de modelos por herramienta (KEY="value", sourceable)
  DELTAS.md        backlog con trigger de ideas deliberadamente no adoptadas (todavía)
  docs/            decisiones fundacionales archivadas (cerradas, no se re-litigan)
  install.sh       instalador idempotente (compatible con bash 3.2)
  uninstall.sh     borrado solo por marcador, preserva tus datos
  hooks/           Capa 0: las garantías, como bash leyendo JSON por stdin
  adapters/        OpenCode: los plugins (V1, V2) que convierten sus eventos en esos payloads, y sus tests
  test.sh          el instalador y los invariantes declarados
  test-hooks.sh    decisiones en runtime de la Capa 0, validadas por mutación, bajo dos locales
  .githooks/       pre-push: se niega a publicar una suite en rojo
  .github/         CI: la suite en Linux + macOS, y bajo /bin/bash para bash 3.2
```

El cuerpo del prompt es una sola fuente para las dos herramientas. El frontmatter difiere, y dos
inserts chicos —`{{GUARANTEES}}` y `{{GATE}}`— se llenan por host para que a cada uno se le diga la
verdad sobre lo que impone; un test compara ese texto contra los hooks que cada host realmente
corre.
