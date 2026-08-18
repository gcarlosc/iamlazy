# PLAN — instrumentación de métricas (Paso 1)

**Objetivo:** solo el Paso 1 (instrumentación pasiva del log que iamlazy ya escribe).
Paso 2 (`## Expected scope`) y Paso 3 (comparador de scope drift) NO se implementan —
van a `DELTAS.md` con trigger.

## Pasos

1. Extender el shape JSON `:211` con los 11 campos nuevos (una línea, más larga).
2. Extender el bloque de valores `:214-217`: cada campo con su lista, mismo estilo `·`
   terco del bloque existente.
3. Nota de auto-reporte (2 líneas cerca del flush): el log es el reporte del agente sobre
   sí mismo, no telemetría independiente; se escribe con la misma honestidad que exige el
   resto del harness, incluidos los propios fallos.
4. `duration_seconds` con epoch persistido en `run.tmp.json` al inicio de sesión (no
   `date +%s` en A1 cargado en contexto). En A5: nuevo `date +%s` y resta.
5. Pagar el presupuesto (~8-11 líneas) por evicción de **duplicación o ejemplo**, nunca de
   regla. El Baton (`:117-122`) no se toca.
6. Verificar net-zero: `wc -l ≤ 250` + medir crecimiento de `:211` en líneas equivalentes.
7. `PROJECT.md`: mini-ADR con diff, esperando aprobación (regla 5). `DELTAS.md`: candidatos
   4-7 con trigger observable.

## Campos nuevos (11)

| Campo | Valores | Nota |
|---|---|---|
| `duration_seconds` | entero | epoch en disco, no en contexto |
| `reversibility_final` | `high\|medium\|low` | re-declaración durante construcción (regla 1) |
| `critic_findings_count` | entero | `0` es válido: búsqueda adversarial sin hallazgos |
| `files_changed` | entero | de `git diff --stat` |
| `lines_changed` | entero | insertions + deletions |
| `retries` | entero `0-2` | ciclos Critic↔build, cap en `:188` |
| `human_interventions` | entero | mensajes que cambiaron el rumbo (no la aprobación del gate) |
| `validation_result` | `passed\|failed\|not_run\|n/a` | |
| `session_id` | string | glob **scopeado al proyecto**, no global |
| `tokens_total` | entero | Σ de `input+cache_creation+cache_read+output` sobre todos los turnos assistant |

Primero en caer si no entra presupuesto: `human_interventions` (definición más blanda).

## Load-bearing claims (verificados, salida real)

| Claim | Comando | Salida |
|---|---|---|
| L1: archivo en cap, adición net-zero | `wc -l < core/iamlazy.md` | `250` |
| L5a: session_id vía glob **scopeado** | `ls -t ~/.claude/projects/-Users-giancarlo-development-iamlazy/*.jsonl \| head -1` | `b2e0dc63…` ✅ |
| L5b: usage con tokens | `rg -c '"usage"'` sobre el transcript | `4`, con `input/output/cache_*` ✅ |

## Alternativas descartadas

- Versionar el esquema — innecesario (L3: `/iamlazy-review` parsea por nombre).
- Adelantar `## Expected scope` — contamina el baseline de las 5 features de medición.
- Glob global para `session_id` — roto, devuelve el observer de claude-mem en vez de la
  sesión activa (ver GROUND, corrección 1).

## Riesgo declarado

El riesgo real está en el Paso 5: comprimir prosa en un archivo sin holgura es donde se
pierde matiz. Las evicciones se muestran por separado en el diff; `wc -l` prueba que el
presupuesto cuadra, no que el significado sobrevivió.

## Aprobación

Aprobado por el humano: incluir `tokens_total` con la definición precisa (11 campos totales).
