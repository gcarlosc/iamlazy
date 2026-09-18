# iamlazy

[![test](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml/badge.svg)](https://github.com/gcarlosc/iamlazy/actions/workflows/test.yml)

## Qué es esto, y por qué te puede interesar

**iamlazy te ayuda a terminar bien una tarea — y después se hace a un lado.**

Vos traés la tarea y las decisiones. Él trae la disciplina: las preguntas que vale la pena hacer
antes de escribir una línea, un acuerdo escrito sobre qué significa "listo", y un reporte honesto
cuando lo está. La parte que es fácil saltearse cuando estás cansado es justo la que se encarga él.

### Cómo se siente usarlo

1. **Pedís algo.** "Agregá soporte para alemán al script de saludo."
2. **Te pregunta de vuelta — una sola vez.** Las dos o tres cosas que realmente cambian la
   respuesta, en un único bloque. No un goteo de preguntas durante veinte minutos.
3. **Escribe el trato.** Qué archivos va a tocar, qué va a significar terminado, cómo lo vas a
   verificar. Una página, en lenguaje claro.
4. **Decís dale.** O corregís el plan primero — que cuesta un minuto ahora en lugar de una tarde
   después.
5. **Trabaja, y te entrega un reporte.** Qué cambió, qué encontró un segundo revisor, cuánto costó,
   y cualquier cosa que haya hecho sin que la aprobaras.

Ese último punto es donde se fue la mayor parte del diseño, y es la razón por la que vale leer el
resto.

### El contrato es para vos, no para él

Esa página que aprobás no es papeleo. Sigue trabajando después de que la firmás.

Cuando el asistente dice que terminó, **la máquina** —no el asistente— compara lo que cambió de
verdad contra lo que acordaste. Cualquier cosa fuera del trato tiene que decirse en voz alta, en el
reporte que ya estás leyendo. No escribirse en un log que nunca vas a abrir.

Es la diferencia entre el presupuesto escrito de un albañil y su palabra. Los dos pueden ser
buenos. Solo uno se puede verificar.

### Promesas que se sostienen, y consejos que ayudan

Acá viven dos tipos de cosas, y están etiquetadas con honestidad:

| | Qué es | Ejemplo |
|---|---|---|
| **Garantizado** | Lo hace cumplir código que corre sin importar si alguien se acuerda. | El trabajo no puede declararse terminado si se cambió un archivo que nunca aprobaste. |
| **Pedido** | Buen criterio, escrito. Se suele cumplir. | "Empezá por la conclusión." |

Este proyecto aprendió a distinguirlos por las malas. En su momento tuvo seis reglas que llamaba
"inviolables" — cinco eran solo *pedidos*, y la más incumplida de todas era justamente la que
estaba escrita con las letras más grandes. Así que ahora todo lo que una máquina puede verificar lo
verifica una máquina, y el resto se llama por su nombre: consejo. Nada se promueve a promesa por
sonar importante.

### Te llevás un segundo lector, gratis

El asistente que hizo el trabajo no es quien lo aprueba. Un revisor aparte lee el cambio en frío
—sin memoria de las decisiones, sin interés en defenderlas— y reporta lo que encuentra. Ves los
hallazgos sean favorables o no, y el trabajo no puede cerrarse salteándose ese paso por lo bajo.

### Cada trabajo deja un recibo

Cuánto tardó, cuánto costó, qué cambió, qué dijo el revisor. Mediciones, no un resumen escrito de
memoria. En unas semanas eso se vuelve genuinamente útil: podés ver qué tipo de trabajo sale
fluido, y cuál cuesta calladito veinte veces más de lo que debería — algo que nadie nota a ojo.

### Por qué "iamlazy"

Porque ser vago con la *vigilancia* es lo que te ganás por no ser vago con las *decisiones*.

Seguís eligiendo qué construir y si el plan está bien — esa parte es tuya. Lo que dejás de hacer es
estar encima, releer cada cambio, y acordarte de preguntar "¿de verdad probaste eso?". Ahora eso lo
hace otra cosa, todas las veces, sin cansarse ni volverse optimista.

---

**Todo lo que sigue es para quien va a instalarlo y usarlo.**

Un harness de desarrollo de software para **Claude Code** y **OpenCode**. Corre **una tarea de
punta a punta** —analizar, preguntar, contratar, aprobar, ejecutar, revisar— en un solo hilo. Sin
MCP, sin dependencias externas. Bash y archivos, más un archivo TypeScript que le permite a
OpenCode correr ese mismo bash.

## El modelo mental (una página)

iamlazy no es un pipeline de agentes ni interpreta personajes. Es un ingeniero senior trabajando en
una tarea, con un **contrato** en el medio: lo que acordaste hacer, firmado antes de escribir
código, y verificado contra la realidad al final.

Deliberadamente **no** está hecho para sesiones de varias horas. Una corrida larga es un
síntoma. La peor del log tardó casi dos horas en producir 230 líneas en 3 archivos,
después de siete intentos distintos
— **24x peor por línea** que una corrida normal. Hacer eso visible, y frenarlo, es el punto.

**Un hilo, y un solo escritor.** El valor está en la cadena —plan, diff, revisión— sostenida en un
*único* contexto; si la partís entre agentes delegados, cada uno vuelve a deducir lo que el anterior
ya sabía. Por eso ningún sub-agente salvo el revisor puede spawnearse, y por eso es un hook y no un
pedido. Un escritor delegado además esconde su propio costo: `runs.jsonl` contabiliza el hilo
principal, así que el trabajo delegado nunca llega al número con el que juzgarías si el harness
vale la pena. Si una búsqueda se siente demasiado grande para este hilo, achicala — no la delegues.

### Dos capas, y la diferencia importa

El harness separa lo que **garantiza** de lo que **pide** — porque cinco de sus seis viejas "reglas
inviolables" eran prosa, y la más violada de todas era la que estaba declarada como ley.

| Capa 0 — garantizado | Capa 1 — pedido |
|---|---|
| Scripts de hook que no podés saltear | El prompt: criterio |
| Solo el revisor puede spawnearse, y spawnearlo pregunta primero | Cómo analizar, qué preguntar |
| Identidad de la corrida, tiempos y la línea de log | Cómo escribir el contrato |
| Cada edición trazada automáticamente | Ediciones quirúrgicas, qué recibe el revisor |
| No cierra mientras haya un archivo fuera del scope declarado | Tono, orden, conclusiones primero |
| Se niega a arrancar bajo un bypass de permisos | |

La regla que decide dónde va cada cosa: **¿puede un comando decir si se cumplió?** Si sí y se puede
prevenir, es una garantía. Si sí pero solo después, es protocolo. Si no, es estilo — y no se le
llama ley. **Nada se promueve por ser importante.**

La prosa no es el enemigo; la *longitud* sí. La corrida corta del log obedeció cada instrucción en
prosa, banner incluido. Las largas se comieron el log, el banner y la línea de costo. Así que la
Capa 0 no vigila cada regla — cuida el **perímetro** que mantiene la tarea acotada, y deja que el
criterio sea criterio.

### Los tres archivos

- **`PROJECT.md`** (raíz del repo, versionado) — lo que el harness sabe de tu proyecto: dónde están
  las cosas, qué comandos funcionan, las restricciones, y **qué revisar acá**, que crece con cada
  hallazgo. Solo entra lo que habría acortado el reconocimiento, evitado una pregunta o cambiado un
  paso; todo lo demás es un diario, no memoria. Nunca se edita sin mostrarte el diff.
- **`.iamlazy/contract.md`** — la tarea: terreno, preguntas resueltas, opciones descartadas, el
  **scope** declarado, los **grupos** (cada uno con el comando que prueba que está hecho), y los
  **claims** que sostienen el peso, con su salida real. **Esto es lo que aprobás.**
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
4. **Aprobación** — tu gate, sobre el plan mode nativo. Leés **comandos, no párrafos** — que es la
   respuesta a por qué el gate viejo no rechazó un plan ni una vez en 27 corridas: leer prosa
   cansa, leer `rspec spec/services/rate_limiter_spec.rb` toma tres segundos.
5. **Ejecución** — grupo por grupo, releyendo el contrato desde el disco. Un path fuera del scope
   declarado frena el trabajo en lugar de absorberse. **Dos intentos, y para:** un segundo intento
   tiene que declarar qué cambia en la hipótesis; un tercero significa que la hipótesis está mal.
6. **Revisión** — siempre un sub-agente **aparte** y de solo lectura, nunca un "reset" del mismo
   hilo. **Spawnearlo pregunta primero:** si lo aprobás, la corrida no puede cerrar antes de que
   vuelva; si lo rechazás, cierra sin revisión, como desvío declarado. Recibe el contrato y el
   journal **como claims a poner a prueba, no como contexto a creer**, y **deriva su propio diff**
   desde los paths — no elegís qué ve tu auditor.
7. **Cierre** — el reporte, más la actualización propuesta de `PROJECT.md` como diff.

**Para qué sirve el revisor.** Vos podés probar si la funcionalidad anda. Lo que no podés ver es
*qué más dependía de lo que cambió* — así que ese es su trabajo principal: elige las 3–5 cosas más
riesgosas que toca el diff, busca sus otros llamadores, y dice cuáles verificó y cuáles dejó
quietas. Los contratos implícitos cuentan tanto como las firmas. Una lista cuyo orden usa otra
funcionalidad es una dependencia real aunque nada la declare, y es exactamente la rotura que
sobrevive a una prueba manual y falla en producción. Tiene que producir un hallazgo real o mostrar
su búsqueda adversarial; un "se ve bien" pelado es un veredicto inválido.

## Instalación

Cloná y corré (totalmente offline):

```sh
git clone <repo> iamlazy && cd iamlazy
./install.sh
```

O forzá una herramienta específica:

```sh
./install.sh --tool=claude      # o --tool=opencode, --tool=opencode-v2, o --tool=both
```

`curl | bash` (fijá la URL base de los archivos crudos de tu fork/repo):

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
  Capa 0 instalada y muerta. En 2.x, la auto-detección saltea OpenCode y te dice que corras
  `--tool=opencode-v2`; un `--tool=opencode`/`--tool=both` explícito se niega en lugar de instalar
  algo que no puede cargar. Si la versión no se puede leer, se instala V1 como antes. `--check`
  verifica el mismo emparejamiento, así que un desajuste se reporta en vez de descubrirse después,
- escribe los comandos slash y el sub-agente Critic en sus directorios globales de configuración,
- instala la Capa 0: los hooks, registrados en el `settings.json` de Claude Code, o detrás del
  plugin en OpenCode,
- proyecta `models.conf` en el frontmatter de cada archivo,
- es **idempotente** (corrélo cuando quieras) y **nunca pisa** un archivo que no sea de iamlazy,
- crea `~/.iamlazy/` para el log de corridas,
- estampa `~/.iamlazy/hooks_version` (un SHA de git, o una huella de contenido en una instalación
  por `curl|bash` sin `.git`) para que cada línea del log pueda decir qué versión del código de
  enforcement la escribió.

## Uso

```
/iamlazy <tu tarea>       # corre el harness completo
/iamlazy-review           # muestra las últimas 20 corridas, legible
```

Nunca ves mecánica interna — ni ids de sesión, ni estados, ni charla de protocolo. Ves un bloque de
preguntas (cada una con su recomendación), el contrato con sus comandos de aceptación y sus claims
(en el gate), la entrega, y el cierre. Cada etapa abre con un banner que lleva el modelo y el
esfuerzo que la produjeron, así que un cambio de modelo se ve exactamente donde pasa.

Durante una tarea, `.iamlazy/` en la raíz de tu proyecto guarda el contrato aprobado —persistido
**textual, tal como lo aprobaste**— y el journal, para que el revisor trabaje contra eso y para que
vos lo inspecciones después. Agregá `.iamlazy/` a tu `.gitignore` (iamlazy lo propone si falta).

## Modelos y credenciales

`models.conf` mapea modelos **por herramienta** — editalo y volvé a correr `./install.sh`, o fijá
los dos roles de una herramienta en un solo comando: `./install.sh --tool=claude --model=<id>`
(persiste la elección en `models.conf`, y después reinstala). Un `--model` apunta a una sola
herramienta — Claude Code y OpenCode usan namespaces distintos de model-id.

| Rol | Lo fija | Claude Code | OpenCode |
|---|---|---|---|
| Planner (A1–A3) | `CC_MAIN_MODEL` · **tu default de OpenCode** | `claude-opus-5` | heredado por el agente `plan` |
| Builder (A4–A5) | **tu modelo de sesión** · `OC_MAIN_MODEL` | ver abajo | `opencode-go/kimi-k2.7-code` |
| Critic | `*_CRITIC_MODEL` | `claude-opus-5` | `opencode-go/deepseek-v4-pro` |

**Hasta dónde llega `models.conf` de verdad en Claude Code.** El `model:` del frontmatter de un
comando sobreescribe el modelo **solo para el turno actual** — el modelo de sesión vuelve en tu
próximo prompt, y el gate *es* un prompt. Así que `CC_MAIN_MODEL` cubre al planner, y tu **modelo
de sesión** cubre al builder. `CC_CRITIC_MODEL` es la excepción: el modelo de un sub-agente vale
para toda su corrida.

**Fijá el modelo donde es durable: en settings, no en `models.conf`.** Sin un modelo de sesión
fijado, el build corre sobre lo que la sesión tenga por default — la única fuente real de
no-determinismo acá. Poné `"model"` en `~/.claude/settings.json`, o en un `.claude/settings.json`
del proyecto, que tiene precedencia y se reaplica en cada arranque incluso por encima de un cambio
con `/model`:

| Lo que querés | Fijá |
|---|---|
| Un solo modelo todo el camino | `"model": "claude-opus-5"` |
| Planner fuerte, builder barato | `"model": "opusplan"` |

`opusplan` corre Opus durante el plan mode y cambia a Sonnet en la ejecución. Como el gate de
iamlazy va montado sobre el plan mode nativo, ese cambio cae exactamente en el límite
plan/build — una política declarada, no una moneda al aire. **Vas a ver qué modelo está
corriendo**: cada banner de artefacto lleva el modelo y el esfuerzo que lo produjeron —
`── CONTRATO · opus-5 · high ──` — leídos del transcript de la sesión, nunca adivinados. Así que el
cambio en el gate se ve exactamente donde pasa, y un cambio que esperabas y no ocurrió se ve igual
de bien. `CC_MAIN_MODEL` funciona entonces como piso: un planner fuerte incluso cuando la sesión
está en algo barato.

**OpenCode no se divide por su cuenta, y la razón vale saberla.** El `model:` del frontmatter de un
agente fija ese agente, así que `OC_MAIN_MODEL` vale para todo lo que corra como el agente
`iamlazy`. El gate te manda al agente `plan` que OpenCode trae de fábrica para el análisis — pero
ese agente **no** fija modelo, así que hereda el **modelo de la sesión en vivo**, que entrar a
`iamlazy` acaba de poner en `OC_MAIN_MODEL`. Tab no lo resetea. Por eso el planner corre sobre el
modelo del *builder* por default: medido en una corrida real, 15 mensajes de planner en
`kimi-k2.7-code` mientras el default configurado de OpenCode era `deepseek-v4-pro`. Cambiar ese
default no lo arregla.

Para conseguir la división, fijá el agente de fábrica en tu propio `opencode.json`:

```json
{ "agent": { "plan": { "model": "opencode-go/deepseek-v4-pro" } } }
```

`models.conf` no puede hacerlo por vos — el agente `plan` es de OpenCode, y el instalador nunca
escribe configuración del usuario.

**`*_CRITIC_MODEL` ahora cubre todas las revisiones.** Antes esto era la excepción y no la regla:
con tres modos de revisión, `inline` y `same-thread-reset` corrían *en el hilo principal* —17 de 29
corridas logueadas, 58%— así que bajo `opusplan` la mayoría de las revisiones pasaban calladas en
Sonnet después del gate, y nadie eligió eso. Hacer que el revisor sea **siempre un sub-agente** lo
arregló como efecto lateral: el modelo de un sub-agente vale para toda su corrida, así que lo que
fijás acá es lo que revisa tu código. También significa que revisor y builder pueden
**descorrelacionarse** a propósito — modelos distintos tienen puntos ciegos distintos, y un revisor
que comparte los del builder no puede ver lo que el builder no pudo.

> **Atención:** la variable de entorno `CLAUDE_CODE_SUBAGENT_MODEL`, cuando está seteada,
> sobreescribe `CC_CRITIC_MODEL` en silencio. Sacala del entorno si querés que aplique
> `models.conf`.

> **OpenCode necesita una credencial para su provider, que configurás vos** — una API key en tu
> entorno o en `opencode.json`. El instalador escribe el `model` en el frontmatter; **no**
> configura credenciales, y tampoco puede alcanzar el modelo del agente `plan`.

Los strings de modelo de OpenCode son exactamente lo que lista `opencode models`
(`provider/model`). Claude Code toma ids de modelo de Anthropic pelados.

## El gate no es opcional

iamlazy **no** escribe código hasta que apruebes el contrato, salvo en cambios trivialmente
reversibles. En Claude Code el gate va montado sobre el **plan mode nativo** — estructura impuesta
por la plataforma, no prosa imitándola.

**No corras iamlazy bajo `--dangerously-skip-permissions` (ni ningún modo de bypass).** Elimina el
gate estructural sobre el que está construido el harness. Con la Capa 0 instalada esto ya no es un
pedido: el harness **se niega a arrancar** bajo un bypass de permisos.

## Capa 0

Instalada y registrada **por default**. No hay un paso extra, y eso es a propósito: una garantía
que tenés que acordarte de encender no es una garantía, y la falla es silenciosa — dos
instalaciones se ven idénticas mientras solo una impone algo.

El instalador respalda tu `settings.json`, valida el resultado antes de reemplazarlo, restaura el
backup si algo sale mal, y **nunca toca tus propios hooks ni tu configuración**. `./uninstall.sh`
los desregistra de vuelta, con el mismo cuidado.

```sh
./install.sh --tool=claude --no-hooks   # optar por NO tenerlos, si de verdad querés
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
a los payloads JSON que los hooks ya leen, invocarlos, y traducir una negación de vuelta al `throw`
que bloquea una tool allá. Ninguno lee un contrato, calcula scope ni sabe del breaker — un test
grepea cada uno buscando esas palabras y falla si aparece alguna. Lo único que difiere de Claude
Code es el costo: OpenCode tarifa cada mensaje por su cuenta, así que el adaptador reenvía cada
cifra a `host-cost.sh` en vez de que los hooks retarifen la corrida desde `prices.conf`. Dos cosas
que Claude Code tiene y OpenCode no: un modo de bypass de permisos que rechazar, y un plan mode que
deniega en lugar de preguntar — el prompt lo dice en ese host, en vez de fingir paridad.

## Tests

```sh
./test.sh
```

Cubre el instalador y los invariantes declarados — composición de archivos, proyección de modelos,
idempotencia, anti-pisado, `--model`, registro de hooks, y que `uninstall.sh` nunca toque tu log de
corridas. Delega en `./test-hooks.sh` las decisiones en runtime de la Capa 0, alimentadas con
payloads reales capturados y validadas por mutación en lugar de por dar verde. Corre en un `HOME`
aislado, así que no puede alterar tu setup. Bash y coreutils, más Bun para el único archivo que
corre bajo Bun.

El adaptador de OpenCode se ejercita con `bun test` — Bun es el runtime de OpenCode, así que es
bajo lo que el plugin realmente corre. Cada test le da un evento real de OpenCode al plugin
*instalado* y afirma qué hicieron los hooks reales en disco; nada de la Capa 0 está mockeado. **Bun
es obligatorio**, y la suite falla en vez de saltearse cuando no está: un traductor que
nadie corrió,
reportado como verde, es el falso verde que el resto de esta suite existe para rechazar.

La mitad de la Capa 0 corre **dos veces, bajo un locale C y uno UTF-8**, y descubre qué locale UTF-8
tiene el sistema realmente en lugar de suponer uno. Eso no es ceremonia: el regex de cierre por
banner se escribió con bytes escapados, que el grep de BSD respeta bajo C y silenciosamente ignora
bajo UTF-8, así que estaba muerto justo donde los hooks corren de verdad mientras CI daba verde
durante semanas.

CI lo corre en cada push sobre Linux y macOS, más un job que lo invoca específicamente a través de
`/bin/bash` — ese es el bash 3.2 que este proyecto dice soportar, y `env bash` en un runner puede
resolver calladito a uno más nuevo. Un job aparte de `lint` corre `bash -n` en cada script y
`shellcheck -x` con severidad style — siguiendo los `source`, así que `lib.sh` y `models.conf`
también se chequean, no solo la línea que los incluye. Su primera corrida real encontró un bug
genuino (`hk_rel_path` fallando en silencio sobre un path de proyecto con un carácter de glob), que
es el argumento para mantenerlo en severidad style y no solo en los defaults. Localmente,
`git config core.hooksPath .githooks` instala un hook de pre-push que se niega a pushear una suite
en rojo.

Lo que **no** cubre: una corrida real de `/iamlazy`. El contrato, el gate y la revisión siguen
siendo correctos por construcción del prompt. La Capa 0 cerró parte de esa deuda —un script de hook
que lee JSON por stdin es testeable de una forma que un prompt nunca fue— pero el camino de punta a
punta sigue sin ejercitarse. Vale saberlo antes de confiar en un verde.

## Validación

No te creas el harness por fe. Durante el primer mes, corré unas cuantas tareas comparables de las
dos formas —con `/iamlazy`, y con la herramienta pelada más un buen `CLAUDE.md`— y compará tres
preguntas: ¿el gate atajó algo real? ¿hubo que deshacer trabajo? ¿cuál fue el tiempo total? Cada
corrida loguea una cifra `cost_usd` derivada del transcript de la sesión y de una tabla de precios,
no estimada, así que el costo es comparable entre corridas — y un conteo `models_seen`, así que una
corrida es comparable contra lo que realmente la respondió y no contra lo que la config decía que
la iba a responder. `runs.jsonl` + `/iamlazy-review` son la mitad de la instrumentación — y la
revisión además barre los triggers de `DELTAS.md` contra tus corridas, reportando cuáles se
dispararon, para que el backlog te avise cuando tiene evidencia en lugar de esperar que le
preguntes. Si iamlazy no gana con claridad, la conclusión correcta es recortarlo, no defenderlo.

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
  .githooks/       pre-push: se niega a pushear una suite en rojo
  .github/         CI: la suite en Linux + macOS, y bajo /bin/bash para bash 3.2
```

El cuerpo del prompt es una sola fuente para las dos herramientas. El frontmatter difiere, y dos
inserts chicos —`{{GUARANTEES}}` y `{{GATE}}`— se llenan por host para que a cada uno se le diga la
verdad sobre lo que impone; un test compara ese texto contra los hooks que cada host realmente
corre.
