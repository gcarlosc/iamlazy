# GROUND — instrumentación de métricas (Paso 1)

| # | Hecho | Tag |
|---|---|---|
| G1 | `core/iamlazy.md` = **250** líneas (cap duro) | `[observed: wc -l]` |
| G2 | Shape en `:211`, **300 chars**, 10 campos originales | `[observed: awk]` |
| G3 | **Ningún** campo nuevo presente; repo en baseline limpio | `[observed: rg]` |
| G4 | git limpio; sin commit de métricas — trabajo previo de memoria no aterrizó en el repo | `[observed: git log/status]` |
| L5a | Transcript existe, nombre = session id | `[observed]` ✅ **con corrección** |
| L5b | Entradas llevan `usage` con conteo de tokens | `[observed]` ✅ **con corrección** |

## Correcciones al mecanismo L5 (hallazgo del gate)

1. **`session_id` — el glob global está roto.** `ls -t ~/.claude/projects/*/*.jsonl | head -1`
   devuelve el transcript del observer de claude-mem (corre en background permanentemente,
   casi siempre gana el `head -1`), no el de la sesión activa. **Fix:** scopear al directorio
   del proyecto: `ls -t ~/.claude/projects/<slug-del-proyecto>/*.jsonl | head -1`. Verificado:
   el global devolvía `4a32f07d…` (observer), el scopeado devuelve `b2e0dc63…` (sesión real).

2. **`tokens_total` — "suma de usage" estaba subespecificado.** Cada turno lleva
   `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`.
   Definición precisa: **Σ de los cuatro campos sobre todos los turnos del assistant** = total
   de tokens procesados (proxy de costo real, no facturación exacta).

**Resultado:** set final = **11 campos nuevos** (9 originales del plan + `session_id` +
`tokens_total`), ambos L5 con mecanismo corregido. Aprobado por el humano.
